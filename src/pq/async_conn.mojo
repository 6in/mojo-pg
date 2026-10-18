"""Asynchronous PostgreSQL connection built on `PQconnectStart` and `PQsend*`.

`AsyncConnection` is the non-blocking twin of `Connection`. Where `Connection`
hands one `PQexec` to libpq and comes back with a `Result`, this one splits
every round trip into steps the caller drives: `start` opens the socket,
`poll_connect` advances the handshake, `send*` queues a command and
`poll_result` collects the results one at a time. Nothing here ever blocks
unless the caller asks it to.

Two kinds of method therefore live side by side:

- The *step* methods -- `poll_connect`, `flush`, `consume_input`, `is_busy`,
  `poll_result` -- return as soon as libpq has nothing more to do without
  waiting, and report what the caller should wait for.
- The *blocking helpers* -- `wait_readable`, `wait_writable`,
  `connect_blocking`, `fetch_all` -- do the waiting with `poll(2)` and a
  millisecond budget. Running out of budget is `PgErrorKind.TIMEOUT`, which
  leaves the connection untouched and usable.

`state()` is `pq`'s own state machine rather than a reading of libpq's:

```
Connecting --(poll_connect returns Ready)--> Idle
Idle --(send*)--> Sending or Busy
Sending --(flush returns True)--> Busy
Busy --(poll_result sees the NULL result)--> Idle
```

The last transition is the one worth remembering: a command's results are not
finished when `PQisBusy` turns 0, they are finished when `PQgetResult` returns
NULL. A multi-statement `send("SELECT 1; SELECT 2")` produces two results and
then that NULL, so the connection stays `Busy` -- and a `send` during it is
`PgErrorKind.USAGE` -- until the NULL is read.

Misuse is caught before libpq sees it. Calling a method in the wrong state
raises `USAGE` with `<method>() called while <State>`, so libpq's own
`another command is already in progress` can never turn up in a `pq` message;
`PQerrorMessage` accumulates text across calls, which would make such a
message describe an older failure. Whether the connection is still *alive* is
not second-guessed that way: a `send` on a connection the server dropped goes
to libpq and comes back as `CONNECTION` with libpq's wording.

This struct is `Movable` and not `Copyable`, like `Connection`, so one
`PGconn` has exactly one owner and `PQfinish` runs exactly once. Destruction
is `PQfinish` alone: results still queued on the connection are libpq's to
free, and a half-read command is not drained on the way out.
"""

from std.ffi import c_int
from std.time import monotonic

from pq._ffi.functions import LibpqFFI
from pq._ffi.loader import libpq_ptr
from pq._ffi.types import (
    CONNECTION_BAD,
    CStr,
    CStrArray,
    IntPtr,
    MutCStr,
    MutRawPtr,
    OidPtr,
    PGRES_POLLING_OK,
    PGRES_POLLING_READING,
    PGRES_POLLING_WRITING,
    PGconnPtr,
    PGnotify,
)
from pq._platform.poll import _reject_bad_timeout, poll_socket
from pq.connection import _SESSION_SETUP_SQL
from pq.decode_binary import _utf8_first_invalid
from pq.errors import PgError, PgErrorKind, _reject_nul
from pq.params import Param, _ParamBuffers
from pq.result import Result, ResultFormat, adopt_result


@fieldwise_init
struct AsyncState(Equatable, TrivialRegisterPassable, Writable):
    """Where an `AsyncConnection` is in its own state machine.

    An `Int` newtype with exactly four constants. It is `pq`'s bookkeeping,
    not a reading of libpq: `BUSY` in particular lasts until `poll_result`
    has seen the NULL that ends the command, which is later than `PQisBusy`
    turning 0.
    """

    var value: Int
    """Numeric discriminant of the state."""

    comptime CONNECTING = Self(0)
    """The handshake is unfinished: `poll_connect` has not returned `READY`."""

    comptime IDLE = Self(1)
    """Connected with no command in flight. The only state `send*` accepts."""

    comptime SENDING = Self(2)
    """A command is queued but not fully written; `flush` finishes it."""

    comptime BUSY = Self(3)
    """A command is on the wire and its results are not yet drained."""

    def __eq__(self, other: Self) -> Bool:
        """Compare two states for equality.

        Args:
            other: The state to compare against.

        Returns:
            True if both states have the same discriminant.
        """
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Compare two states for inequality.

        Args:
            other: The state to compare against.

        Returns:
            True if the states have different discriminants.
        """
        return self.value != other.value

    def write_to(self, mut writer: Some[Writer]):
        """Write the state's name to `writer`.

        Args:
            writer: The writer receiving the state name.
        """
        if self == Self.CONNECTING:
            writer.write("Connecting")
        elif self == Self.IDLE:
            writer.write("Idle")
        elif self == Self.SENDING:
            writer.write("Sending")
        elif self == Self.BUSY:
            writer.write("Busy")


@fieldwise_init
struct PollState(Equatable, TrivialRegisterPassable, Writable):
    """What `poll_connect` wants next.

    Three constants, and failure is not one of them: a failed handshake is a
    raised `PgErrorKind.CONNECTION`, so every returned value is a step the
    caller can act on.
    """

    var value: Int
    """Numeric discriminant of the request."""

    comptime NEED_READ = Self(0)
    """Wait until the socket is readable, then call `poll_connect` again."""

    comptime NEED_WRITE = Self(1)
    """Wait until the socket is writable, then call `poll_connect` again."""

    comptime READY = Self(2)
    """The connection is up and its session settings are pinned."""

    def __eq__(self, other: Self) -> Bool:
        """Compare two poll states for equality.

        Args:
            other: The poll state to compare against.

        Returns:
            True if both have the same discriminant.
        """
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Compare two poll states for inequality.

        Args:
            other: The poll state to compare against.

        Returns:
            True if they have different discriminants.
        """
        return self.value != other.value

    def write_to(self, mut writer: Some[Writer]):
        """Write the poll state's name to `writer`.

        Args:
            writer: The writer receiving the name.
        """
        if self == Self.NEED_READ:
            writer.write("NeedRead")
        elif self == Self.NEED_WRITE:
            writer.write("NeedWrite")
        elif self == Self.READY:
            writer.write("Ready")


@fieldwise_init
struct Notification(Copyable, Equatable, Movable, Writable):
    """One `LISTEN` / `NOTIFY` message delivered by the server.

    Both strings are owned copies: libpq hands out a `PGnotify` the caller
    must `PQfreemem`, so nothing here points into it once the value exists.
    """

    var channel: String
    """The channel the notification was sent on (`relname`)."""

    var payload: String
    """The payload, or an empty string when `NOTIFY` carried none."""

    var backend_pid: Int
    """Process ID of the server backend that sent it (`be_pid`)."""

    def __eq__(self, other: Self) -> Bool:
        """Compare two notifications field by field.

        Args:
            other: The notification to compare against.

        Returns:
            True if channel, payload and backend PID all match.
        """
        return (
            self.channel == other.channel
            and self.payload == other.payload
            and self.backend_pid == other.backend_pid
        )

    def __ne__(self, other: Self) -> Bool:
        """Compare two notifications for inequality.

        Args:
            other: The notification to compare against.

        Returns:
            True if any of the three fields differs.
        """
        return not (self == other)

    def write_to(self, mut writer: Some[Writer]):
        """Write the notification in constructor form.

        Args:
            writer: The writer receiving the text.
        """
        writer.write(
            "Notification(channel=",
            self.channel,
            ", payload=",
            self.payload,
            ", backend_pid=",
            self.backend_pid,
            ")",
        )


def _reject_bad_notification_text[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin], what: StaticString) raises PgError:
    """Raise unless a notification's channel or payload is valid UTF-8.

    `_validated_utf8` for text that is not a column: the same stdlib fast
    path and the same `_utf8_first_invalid` scanner behind it, with `what`
    (`"channel"` or `"payload"`) where the column index would go. A
    `SQL_ASCII` database accepts `NOTIFY ch, E'ab\\xC3\\x28'` and libpq hands
    the bytes over untouched, so without this a `Notification` could carry a
    `String` that is not UTF-8 -- while `get_text` rejects the very same bytes
    as `ENCODING`.

    The message names the offset but never the bytes, for the reason
    `_validated_utf8` gives: text that is not UTF-8 cannot be quoted in an
    error without corrupting it or spilling the payload into a log.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The notification text, without its terminating NUL.
        what: Which part of the notification it is, for the message.

    Raises:
        PgError: `PgErrorKind.ENCODING` with the message `invalid UTF-8
            at byte N of notification <what>` when `bytes` are not
            well-formed UTF-8.
    """
    try:
        _ = StringSlice[origin](from_utf8=bytes)
        return
    except:
        pass
    var offset = _utf8_first_invalid(bytes)
    if offset < 0:
        # Unreachable unless the scanner and the stdlib disagree; still a
        # rejection, just without a position to name.
        raise PgError(
            PgErrorKind.ENCODING,
            String("invalid UTF-8 of notification ", what),
        )
    raise PgError(
        PgErrorKind.ENCODING,
        String("invalid UTF-8 at byte ", offset, " of notification ", what),
    )


struct AsyncConnection(Movable):
    """A non-blocking connection to a PostgreSQL server.

    Build one with `connect_blocking` for the simple case, or with `start`
    plus `poll_connect` to drive the handshake from an event loop. The
    connection is closed by `PQfinish` on destruction, so it must not be
    copied; move it with `^`.
    """

    var _conn: PGconnPtr
    """The owned `PGconn*`, closed exactly once on destruction."""

    var _pq: Pointer[LibpqFFI, MutUntrackedOrigin]
    """Borrowed process-wide libpq table, retained so `__deinit__` cannot raise.
    """

    var _state: AsyncState
    """`pq`'s own view of the connection; what `state()` reports."""

    var _setup_pending: Bool
    """True once the session setup `SET` is sent and not yet drained.

    `poll_connect` sets this when libpq reports the socket is up, and clears
    it when the last of the setup's results has been read. The connection
    stays `CONNECTING` for the whole of it, so no caller can send a statement
    that overtakes the `SET`.
    """

    var _connect_polled: Bool
    """Whether `PQconnectPoll` has been called on this handle yet.

    libpq asks a caller to behave as if the poll just after `PQconnectStart`
    had returned `PGRES_POLLING_WRITING`, so the first `poll_connect` answers
    `NEED_WRITE` from this flag instead of asking. Calling `PQconnectPoll`
    first reads `SO_ERROR` before the kernel has recorded a refusal, which
    costs libpq its walk to the next host in a multi-host conninfo.
    """

    var _single_row_allowed: Bool
    """Whether `set_single_row_mode` is still in its window.

    libpq keeps answering 1 after the first result has been collected, which
    would let a caller switch mode too late; this flag is the client-side
    answer instead. It goes up when a `send*` succeeds and comes down as soon
    as anything looks at the incoming data.
    """

    var _pending: List[Notification]
    """Notifications read from libpq but not yet handed to the caller.

    `wait_notification` returns one notification at a time while
    `PQnotifies` can produce several per round trip, so the surplus waits
    here rather than being dropped.
    """

    def __init__(
        out self,
        conn: PGconnPtr,
        pq: Pointer[LibpqFFI, MutUntrackedOrigin],
    ):
        """Take ownership of a `PGconn*` whose handshake is still running.

        The state starts at `CONNECTING`, so `poll_connect` has to run to
        `READY` before anything can be sent. Unlike `Connection.__init__`
        this takes no connected handle: `PQconnectStart` returns before the
        socket is usable.

        Args:
            conn: A `PGconn*` from `PQconnectStart` / `PQconnectStartParams`.
            pq: The libpq table `conn` was opened with.
        """
        self._conn = conn
        self._pq = pq
        self._state = AsyncState.CONNECTING
        self._setup_pending = False
        self._connect_polled = False
        self._single_row_allowed = False
        self._pending = List[Notification]()

    def __deinit__(deinit self):
        """Close the connection with `PQfinish` unless it is already NULL.

        Results the caller never collected are not drained first: `PQfinish`
        releases them along with the connection, which is also what makes
        dropping a connection mid-command safe.
        """
        if not self._conn.is_null():
            self._pq[].PQfinish(self._conn)

    @staticmethod
    def _adopt_start(
        pq: Pointer[LibpqFFI, MutUntrackedOrigin], conn: PGconnPtr
    ) raises PgError -> AsyncConnection:
        """Validate a `PQconnectStart` handle and put its socket in non-blocking
        mode.

        A non-NULL handle that is already `CONNECTION_BAD` failed before any
        I/O -- a conninfo libpq cannot parse, or a host name it cannot resolve
        -- and is closed here rather than handed back as a connection that can
        never poll to `READY`. `PQsetnonblocking` is only reached for a handle
        that is still alive.

        Args:
            pq: The libpq table `conn` was opened with.
            conn: The handle `PQconnectStart` returned.

        Returns:
            An `AsyncConnection` in state `CONNECTING`.

        Raises:
            PgError: `PgErrorKind.CONNECTION` when libpq returned NULL, when
                the handle is already `CONNECTION_BAD`, or when
                `PQsetnonblocking` fails. The message is libpq's own text and
                never includes the caller's connection parameters.
        """
        if conn.is_null():
            raise PgError(
                PgErrorKind.CONNECTION,
                "libpq returned NULL (out of memory)",
            )
        if pq[].PQstatus(conn) == CONNECTION_BAD:
            var message = String(unsafe_from_utf8_ptr=pq[].PQerrorMessage(conn))
            pq[].PQfinish(conn)
            raise PgError(PgErrorKind.CONNECTION, message)
        if pq[].PQsetnonblocking(conn, c_int(1)) == -1:
            var message = String(unsafe_from_utf8_ptr=pq[].PQerrorMessage(conn))
            pq[].PQfinish(conn)
            raise PgError(PgErrorKind.CONNECTION, message)
        return AsyncConnection(conn, pq)

    @staticmethod
    def start(var conninfo: String) raises PgError -> AsyncConnection:
        """Begin connecting with a libpq conninfo string or URI.

        The asynchronous counterpart of `Connection.open(String)`: it calls
        `PQconnectStart`, which returns as soon as the socket exists, so the
        handshake is still unfinished when this returns. Drive it with
        `poll_connect` until it answers `READY`, or use `connect_blocking` to
        have that loop written for you.

        Failures split in two by *when* libpq notices. A conninfo it cannot
        parse, or a host name it cannot resolve, fails here. A server that
        refuses or never answers fails later, in `poll_connect`.

        Args:
            conninfo: The conninfo string or connection URI.

        Returns:
            An `AsyncConnection` in state `CONNECTING`.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` if `conninfo` contains a NUL
                byte, `PgErrorKind.LIBPQ_LOAD` if libpq cannot be loaded, or
                `PgErrorKind.CONNECTION` when libpq rejects the parameters
                outright. `pq` never adds `conninfo` to the message, but libpq
                echoes the offending fragment of a *malformed* conninfo
                string; use `start(Dict)` for credentials the program
                supplies.
        """
        _reject_nul(conninfo, "conninfo")
        var pq = libpq_ptr()
        var conn = pq[].PQconnectStart(
            CStr(unsafe_from_address=Int(conninfo.as_c_string_span().ptr()))
        )
        _ = conninfo^
        return AsyncConnection._adopt_start(pq, conn)

    @staticmethod
    def start(params: Dict[String, String]) raises PgError -> AsyncConnection:
        """Begin connecting with discrete keyword/value parameters.

        Calls `PQconnectStartParams` with `expand_dbname` set to 0, so every
        value is taken literally and no value can be echoed back as a conninfo
        syntax error. Otherwise identical to `start(String)`: the handshake
        still has to be driven with `poll_connect`.

        Args:
            params: Connection keywords mapped to their values, for example
                `"host"`, `"port"`, `"user"`, `"password"`, `"dbname"`.

        Returns:
            An `AsyncConnection` in state `CONNECTING`.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` if any key or value contains
                a NUL byte, `PgErrorKind.LIBPQ_LOAD` if libpq cannot be
                loaded, or `PgErrorKind.CONNECTION` when libpq rejects the
                parameters outright.
        """
        for ref item in params.items():
            _reject_nul(item.key, "params key")
            _reject_nul(item.value, "params value")
        var pq = libpq_ptr()
        # as_c_string_span() is `mut self` and may reallocate to append the NUL
        # terminator, so the keys and values must be owned copies that outlive
        # the call rather than borrowed views into `params`.
        var keys = List[String]()
        var values = List[String]()
        for ref item in params.items():
            keys.append(item.key.copy())
            values.append(item.value.copy())
        var key_ptrs = List[Int]()
        var value_ptrs = List[Int]()
        for ref k in keys:
            key_ptrs.append(Int(k.as_c_string_span().ptr()))
        for ref v in values:
            value_ptrs.append(Int(v.as_c_string_span().ptr()))
        key_ptrs.append(0)
        value_ptrs.append(0)
        var conn = pq[].PQconnectStartParams(
            CStrArray(unsafe_from_address=Int(key_ptrs.unsafe_ptr())),
            CStrArray(unsafe_from_address=Int(value_ptrs.unsafe_ptr())),
            c_int(0),
        )
        _ = key_ptrs^
        _ = value_ptrs^
        _ = keys^
        _ = values^
        return AsyncConnection._adopt_start(pq, conn)

    def socket(self) -> Int:
        """Return libpq's socket descriptor, or -1 when there is none.

        Read it again before every wait rather than caching it: libpq replaces
        the descriptor while a multi-host conninfo walks its list of hosts,
        and closes it when the connection is lost.

        Returns:
            The descriptor from `PQsocket`, or -1 if the connection is closed.
        """
        return Int(self._pq[].PQsocket(self._conn))

    def state(self) -> AsyncState:
        """Return `pq`'s view of the connection.

        This is bookkeeping maintained by the methods on this struct, not a
        reading of libpq, which is why `BUSY` outlives `PQisBusy`: a command
        is finished when `poll_result` has seen its NULL result.

        Returns:
            The current `AsyncState`.
        """
        return self._state

    def status(self) -> Int:
        """Return libpq's own connection status from `PQstatus`.

        Returns:
            `CONNECTION_OK`, `CONNECTION_BAD`, or one of the intermediate
            `CONNECTION_*` constants while the handshake runs.
        """
        return Int(self._pq[].PQstatus(self._conn))

    def transaction_status(self) -> Int:
        """Return the server-side transaction status from `PQtransactionStatus`.

        Returns:
            One of the `PQTRANS_*` constants. `PQTRANS_ACTIVE` while a command
            is in flight, `PQTRANS_INERROR` after a statement inside an
            explicit transaction failed -- including one that `cancel`
            aborted.
        """
        return Int(self._pq[].PQtransactionStatus(self._conn))

    def _require_state(
        self, method: StaticString, wanted: AsyncState
    ) raises PgError:
        """Raise `USAGE` unless the connection is in `wanted`.

        Every client-side state check goes through here, so the wording is
        uniform and nothing reaches libpq in a state libpq would describe in
        its own words.

        Args:
            method: Name of the calling method, without parentheses.
            wanted: The only state in which the call is allowed.

        Raises:
            PgError: `PgErrorKind.USAGE` with `<method>() called while
                <State>` when the state differs.
        """
        if self._state != wanted:
            raise PgError(
                PgErrorKind.USAGE,
                String(method, "() called while ", self._state),
            )

    def _reject_connecting(self, method: StaticString) raises PgError:
        """Raise `USAGE` while the handshake is still running.

        Args:
            method: Name of the calling method, without parentheses.

        Raises:
            PgError: `PgErrorKind.USAGE` with `<method>() called while
                Connecting`.
        """
        if self._state == AsyncState.CONNECTING:
            raise PgError(
                PgErrorKind.USAGE,
                String(method, "() called while ", self._state),
            )

    def _reject_lost(self, method: StaticString) raises PgError:
        """Raise `CONNECTION` when the connection is already known lost.

        Asked before libpq is, so a caller that keeps polling a dead
        connection gets the same message every time. libpq appends to its
        own error buffer on every refused call, so without this the message
        from `PQerrorMessage` grows by a `connection not open` line per
        call -- the same failure, reported differently each time.

        Args:
            method: Name of the calling method, without parentheses.

        Raises:
            PgError: `PgErrorKind.CONNECTION` with `<method>() called on a
                lost connection` when `PQstatus` is `CONNECTION_BAD`.
        """
        if self._pq[].PQstatus(self._conn) == CONNECTION_BAD:
            raise PgError(
                PgErrorKind.CONNECTION,
                String(method, "() called on a lost connection"),
            )

    def _connection_error(self) -> PgError:
        """Build a `CONNECTION` error carrying libpq's current message.

        Returns:
            A `PgError` whose message is `PQerrorMessage`.
        """
        return PgError(
            PgErrorKind.CONNECTION,
            String(unsafe_from_utf8_ptr=self._pq[].PQerrorMessage(self._conn)),
        )

    def _drain_setup(mut self) raises PgError -> PollState:
        """Collect the results of the session setup `SET`, one round trip at a
        time.

        `_SESSION_SETUP_SQL` is two statements, so it answers with two results
        and then the NULL that ends the command. All three have to be read
        before the connection is `IDLE`; until then this reports what to wait
        for, exactly as `poll_connect` does for the handshake itself.

        Returns:
            `READY` once the NULL result has been read, otherwise the
            direction to wait for.

        Raises:
            PgError: `PgErrorKind.CONNECTION` when the connection is lost
                while the `SET` runs, or `PgErrorKind.SERVER` if the server
                rejects it -- the same classification the synchronous
                `Connection._adopt` produces for the same SQL.
        """
        if self._pq[].PQflush(self._conn) == 1:
            return PollState.NEED_WRITE
        while True:
            if self._pq[].PQconsumeInput(self._conn) == 0:
                raise self._connection_error()
            if self._pq[].PQisBusy(self._conn) != 0:
                return PollState.NEED_READ
            var res = self._pq[].PQgetResult(self._conn)
            if res.is_null():
                self._setup_pending = False
                self._state = AsyncState.IDLE
                return PollState.READY
            # The two SETs answer with a result each; neither carries rows, so
            # both are adopted only to have their failures classified, then
            # dropped at the end of the iteration.
            _ = adopt_result(self._pq, self._conn, res)

    def poll_connect(mut self) raises PgError -> PollState:
        """Advance the handshake by one step and report what to wait for.

        Call this after `start`, wait for the direction it asks for, then call
        it again, until it answers `READY`. The first answer is always
        `NEED_WRITE`: libpq defines the state just after `PQconnectStart` as
        if the last poll had returned `PGRES_POLLING_WRITING`, and asking
        `PQconnectPoll` before that wait reads `SO_ERROR` before the kernel
        has recorded a refusal -- measured on macOS, where the refusal then
        arrives as a failed read instead of libpq walking on to the next host
        of a multi-host conninfo.

        `READY` covers more than libpq's own `CONNECTION_OK`: once the socket
        is up, `_SESSION_SETUP_SQL` is sent as the session's first command and
        its results are drained here, so a connection that polls to `READY`
        has `DateStyle` and `IntervalStyle` pinned just like a synchronous
        one. The state stays `CONNECTING` for the whole of it.

        Calling this again after `READY` is a no-op that answers `READY`:
        `PQconnectPoll` must not be called once the connection is up.

        Returns:
            `NEED_READ` or `NEED_WRITE` to wait and call again, or `READY`
            when the connection is usable.

        Raises:
            PgError: `PgErrorKind.CONNECTION` when the handshake fails -- the
                server refused the connection, never answered, or rejected
                the credentials -- carrying libpq's own message, or
                `PgErrorKind.SERVER` if the server rejects the session setup
                `SET`.
        """
        if self._state != AsyncState.CONNECTING:
            return PollState.READY
        if self._setup_pending:
            return self._drain_setup()
        if not self._connect_polled:
            self._connect_polled = True
            return PollState.NEED_WRITE
        var polling = self._pq[].PQconnectPoll(self._conn)
        if polling == PGRES_POLLING_READING:
            return PollState.NEED_READ
        if polling == PGRES_POLLING_WRITING:
            return PollState.NEED_WRITE
        if polling != PGRES_POLLING_OK:
            # PGRES_POLLING_FAILED, the obsolete PGRES_POLLING_ACTIVE, and
            # anything a future libpq might add: all unusable connections.
            raise self._connection_error()
        var setup = String(_SESSION_SETUP_SQL)
        var sent = self._pq[].PQsendQuery(
            self._conn,
            CStr(unsafe_from_address=Int(setup.as_c_string_span().ptr())),
        )
        _ = setup^
        if sent == 0:
            raise self._connection_error()
        self._setup_pending = True
        if self._pq[].PQflush(self._conn) == 1:
            return PollState.NEED_WRITE
        return PollState.NEED_READ

    def wait_readable(self, timeout_ms: Int) raises PgError:
        """Block until the connection's socket has data to read.

        Returns as soon as a read would not block, even if the peer has also
        hung up: the pending bytes are what carry the server's last word on
        why, so libpq is left to read them and produce the real message. A
        socket that reports only hangup / error returns too -- the reason for
        the disconnect is named by the next libpq call (`PQconsumeInput`'s
        `server closed the connection unexpectedly`, `PQconnectPoll`'s
        `Connection refused`), which is kinder than a generic poll message and
        does not depend on how the platform pairs POLLHUP with POLLIN.

        In state `SENDING` this is the wrong thing to wait for -- the server
        cannot answer a command it has not fully received, so waiting for
        readability deadlocks. Call `flush` until it returns True first;
        `fetch_all` already does.

        Args:
            timeout_ms: Milliseconds to wait. `0` polls the current state;
                `-1` waits forever.

        Raises:
            PgError: `PgErrorKind.TIMEOUT` with `wait_readable timed out after
                N ms` when the budget runs out, `PgErrorKind.CONNECTION` when
                the connection has no socket, or `PgErrorKind.USAGE` when
                `timeout_ms` is outside `-1 .. TIMEOUT_MS_MAX`.
        """
        var fd = self.socket()
        if fd < 0:
            raise PgError(
                PgErrorKind.CONNECTION, "no socket: connection is closed"
            )
        var events = poll_socket(fd, True, False, timeout_ms)
        if events.timeout:
            raise PgError(
                PgErrorKind.TIMEOUT,
                String("wait_readable timed out after ", timeout_ms, " ms"),
            )

    def wait_writable(self, timeout_ms: Int) raises PgError:
        """Block until the connection's socket can accept more data.

        A socket that reports only hangup / error returns as well, rather than
        raising on its own: POSIX makes POLLHUP and POLLOUT exclusive and macOS
        follows it (Linux raises both on a socket), so a refused connect shows
        up as a bare hangup there. Letting the call return hands the diagnosis
        to the next libpq call -- `PQconnectPoll` reads `SO_ERROR` and reports
        `Connection refused`, `PQflush` fails the send -- so the caller sees the
        real cause on every platform.

        Args:
            timeout_ms: Milliseconds to wait. `0` polls the current state;
                `-1` waits forever.

        Raises:
            PgError: `PgErrorKind.TIMEOUT` with `wait_writable timed out after
                N ms` when the budget runs out, `PgErrorKind.CONNECTION` when
                the connection has no socket, or `PgErrorKind.USAGE` when
                `timeout_ms` is outside `-1 .. TIMEOUT_MS_MAX`.
        """
        var fd = self.socket()
        if fd < 0:
            raise PgError(
                PgErrorKind.CONNECTION, "no socket: connection is closed"
            )
        var events = poll_socket(fd, False, True, timeout_ms)
        if events.timeout:
            raise PgError(
                PgErrorKind.TIMEOUT,
                String("wait_writable timed out after ", timeout_ms, " ms"),
            )

    @staticmethod
    def _poll_to_ready(
        mut conn: AsyncConnection, timeout_ms: Int
    ) raises PgError:
        """Drive `poll_connect` to `READY` within one overall budget.

        The budget covers the whole handshake rather than each wait, so a
        server that answers every step slowly cannot stretch it, and a
        `TIMEOUT` from a single wait is re-worded as the connect's own.

        Args:
            conn: The connection to drive, still in state `CONNECTING`.
            timeout_ms: Milliseconds allowed for the whole handshake, `-1` for
                no limit.

        Raises:
            PgError: `PgErrorKind.TIMEOUT` with `connect_blocking timed out
                after N ms`, or whatever `poll_connect` raises.
        """
        var deadline = monotonic() + timeout_ms * 1_000_000
        while True:
            var step = conn.poll_connect()
            if step == PollState.READY:
                return
            var remaining = -1
            if timeout_ms >= 0:
                var left = deadline - monotonic()
                # Round up: a sub-millisecond remainder is still time the
                # caller allowed, and 0 would turn the wait into a probe.
                remaining = (left + 999_999) // 1_000_000 if left > 0 else 0
                if remaining <= 0:
                    raise PgError(
                        PgErrorKind.TIMEOUT,
                        String(
                            "connect_blocking timed out after ",
                            timeout_ms,
                            " ms",
                        ),
                    )
            try:
                if step == PollState.NEED_WRITE:
                    conn.wait_writable(remaining)
                else:
                    conn.wait_readable(remaining)
            except e:
                if e.kind == PgErrorKind.TIMEOUT:
                    raise PgError(
                        PgErrorKind.TIMEOUT,
                        String(
                            "connect_blocking timed out after ",
                            timeout_ms,
                            " ms",
                        ),
                    )
                raise e^

    @staticmethod
    def connect_blocking(
        var conninfo: String, timeout_ms: Int
    ) raises PgError -> AsyncConnection:
        """Connect and wait for the handshake, with a millisecond budget.

        `start` plus the `poll_connect` / `wait_*` loop, written once. The
        budget is for the whole handshake, which is what makes it an upper
        bound on how long this can take even against a server that accepts
        the TCP connection and then says nothing -- the case libpq's own
        `connect_timeout` is often expected to cover.

        A failure destroys the half-built connection on the way out, so
        `PQfinish` still runs and no handle leaks.

        `timeout_ms = 0` is a budget of nothing rather than a single look: the
        handshake needs at least one wait, so it runs out before that wait and
        raises `TIMEOUT`. This is the opposite of `wait_readable(0)`, where
        `0` means "look once and do not wait".

        Args:
            conninfo: The conninfo string or connection URI.
            timeout_ms: Milliseconds allowed for the whole handshake, at most
                `TIMEOUT_MS_MAX`, `-1` for no limit.

        Returns:
            An `AsyncConnection` in state `IDLE`, its session settings pinned.

        Raises:
            PgError: `PgErrorKind.TIMEOUT` with `connect_blocking timed out
                after N ms` when the budget runs out, or whatever `start` and
                `poll_connect` raise -- `TYPE_MISMATCH` for a NUL byte,
                `CONNECTION` for a rejected or unreachable server, `SERVER`
                when the server rejects the session settings `poll_connect`
                pins, `USAGE` when `timeout_ms` is outside
                `-1 .. TIMEOUT_MS_MAX`.
        """
        _reject_bad_timeout(timeout_ms)
        var conn = AsyncConnection.start(conninfo^)
        AsyncConnection._poll_to_ready(conn, timeout_ms)
        return conn^

    @staticmethod
    def connect_blocking(
        params: Dict[String, String], timeout_ms: Int
    ) raises PgError -> AsyncConnection:
        """Connect from keyword/value parameters and wait for the handshake.

        The `start(Dict)` counterpart of `connect_blocking(String)`; every
        value is taken literally rather than parsed.

        `timeout_ms` means what it means in `connect_blocking(String)`,
        including `0` being a budget of nothing.

        Args:
            params: Connection keywords mapped to their values.
            timeout_ms: Milliseconds allowed for the whole handshake, at most
                `TIMEOUT_MS_MAX`, `-1` for no limit.

        Returns:
            An `AsyncConnection` in state `IDLE`, its session settings pinned.

        Raises:
            PgError: Exactly what `connect_blocking(String)` documents --
                `TIMEOUT`, `CONNECTION`, `SERVER` for rejected session
                settings, `USAGE` for a budget outside `-1 ..
                TIMEOUT_MS_MAX` -- with `TYPE_MISMATCH` raised for a NUL byte
                in any key or value.
        """
        _reject_bad_timeout(timeout_ms)
        var conn = AsyncConnection.start(params)
        AsyncConnection._poll_to_ready(conn, timeout_ms)
        return conn^

    def _after_send(mut self) raises PgError:
        """Flush what was just queued and move out of `IDLE`.

        The `-1` branch is unreachable from a single thread. `PQflush` returns
        `-1` only when the status is already `CONNECTION_BAD` (`fe-exec.c`),
        and a send that fails sets `write_failed` and reports success instead
        (`pqSendSome` returns 0; `pqsecure_raw_write` answers `n = len`,
        `fe-misc.c` / `fe-secure.c`) -- so a `PQsendQuery` that just succeeded
        cannot be followed by a `-1` flush. It is still answered the way libpq
        does: libpq is in `PGASYNC_BUSY` from the moment `PQsendQuery`
        succeeds, so `pq` moves to `BUSY` too, and a caller that ignores the
        error and sends again gets `pq`'s own `USAGE` first rather than a
        second libpq error.

        Raises:
            PgError: `PgErrorKind.CONNECTION` when `PQflush` fails outright.
        """
        var flushed = self._pq[].PQflush(self._conn)
        if flushed == 0:
            self._state = AsyncState.BUSY
        elif flushed == 1:
            self._state = AsyncState.SENDING
        else:
            # -1: the command is lost along with the connection.
            self._state = AsyncState.BUSY
            raise self._connection_error()
        self._single_row_allowed = True

    def send(mut self, var sql: String) raises PgError:
        """Queue `sql` for execution without waiting for its results.

        The asynchronous counterpart of `Connection.execute(sql)`, and like it
        `sql` may hold several statements separated by semicolons -- but here
        every statement answers with its own `Result`, so `SELECT 1; SELECT 2`
        is collected as two results followed by the NULL that ends the
        command. Results always come back in text form; `send(sql, params)`
        is the overload that takes a `result_format`.

        Only `IDLE` accepts a command. A `send` during one is `USAGE` and
        nothing is written, which keeps libpq's `another command is already in
        progress` out of `pq` messages.

        Args:
            sql: One or more SQL statements.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `sql` contains a NUL
                byte, `PgErrorKind.USAGE` when the connection is not `IDLE`,
                or `PgErrorKind.CONNECTION` when libpq cannot queue or write
                the command, carrying libpq's own message.
        """
        _reject_nul(sql, "sql")
        self._require_state("send", AsyncState.IDLE)
        var sent = self._pq[].PQsendQuery(
            self._conn,
            CStr(unsafe_from_address=Int(sql.as_c_string_span().ptr())),
        )
        _ = sql^
        if sent == 0:
            raise self._connection_error()
        self._after_send()

    def send(
        mut self,
        var sql: String,
        params: List[Param],
        result_format: ResultFormat = ResultFormat.TEXT,
    ) raises PgError:
        """Queue one parameterised statement with `PQsendQueryParams`.

        Placeholders, parameter encoding and `result_format` work exactly as
        in `Connection.execute(sql, params)`: `params[0]` binds `$1`, each
        `Param` carries its own OID and wire format, and `result_format`
        applies to every column of the result. Only a single statement is
        allowed, because libpq builds an unnamed prepared statement for it.

        The parameter buffers are released as soon as the call returns. libpq
        copies every value into its own output buffer during
        `PQsendQueryParams`, so the data does not have to outlive the call
        even though the command has not been written yet.

        Args:
            sql: Exactly one SQL statement, using `$1`..`$n` placeholders.
            params: The values to bind, `params[0]` binding `$1`.
            result_format: Wire format for every column of the result,
                `ResultFormat.TEXT` by default.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `sql` contains a NUL
                byte, `PgErrorKind.USAGE` when the connection is not `IDLE`
                or when a `String` parameter's value contains a NUL byte, or
                `PgErrorKind.CONNECTION` when libpq cannot queue or write the
                command.
        """
        _reject_nul(sql, "sql")
        self._require_state("send", AsyncState.IDLE)
        var buffers = _ParamBuffers(params)
        var sent = self._pq[].PQsendQueryParams(
            self._conn,
            CStr(unsafe_from_address=Int(sql.as_c_string_span().ptr())),
            c_int(buffers.count()),
            buffers.types_ptr(),
            buffers.values_ptr(),
            buffers.lengths_ptr(),
            buffers.formats_ptr(),
            c_int(result_format.value),
        )
        _ = buffers^
        _ = sql^
        if sent == 0:
            raise self._connection_error()
        self._after_send()

    def send_prepare(
        mut self,
        var name: String,
        var sql: String,
        param_types: List[UInt32] = List[UInt32](),
    ) raises PgError:
        """Queue a `PREPARE` of `sql` under a caller-chosen `name`.

        The asynchronous counterpart of `Connection.prepare`, with two
        differences. The name is the caller's rather than generated, since
        there is no handle object to carry a generated one; and nothing is
        described afterwards, so the parameter count and types are not read
        back -- `send_prepared` leaves the arity check to the server, which
        reports a wrong count as SQLSTATE `08P01`.

        The statement is prepared when the command's results are collected,
        and the first of them is an empty `Result` whose `command_tag` is
        empty. Destroying the connection does not `DEALLOCATE` it; closing
        the session is what discards it.

        `param_types` is a hint exactly as in `PQsendPrepare`: an entry of 0
        leaves that parameter to inference, and a shorter list than the
        statement has placeholders leaves the rest to inference too.

        Args:
            name: The name to prepare the statement under.
            sql: Exactly one SQL statement, using `$1`..`$n` placeholders.
            param_types: Optional type OID hints, `param_types[0]` for `$1`.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `name` or `sql` contains
                a NUL byte, `PgErrorKind.USAGE` when the connection is not
                `IDLE`, or `PgErrorKind.CONNECTION` when libpq cannot queue or
                write the command.
        """
        _reject_nul(name, "name")
        _reject_nul(sql, "sql")
        self._require_state("send_prepare", AsyncState.IDLE)
        # One dummy element past the hints, so `unsafe_ptr()` is a valid
        # non-NULL address even for an empty list -- the same rule
        # `_ParamBuffers` follows.
        var hints = List[UInt32](capacity=len(param_types) + 1)
        for i in range(len(param_types)):
            hints.append(param_types[i])
        hints.append(UInt32(0))
        var sent = self._pq[].PQsendPrepare(
            self._conn,
            CStr(unsafe_from_address=Int(name.as_c_string_span().ptr())),
            CStr(unsafe_from_address=Int(sql.as_c_string_span().ptr())),
            c_int(len(param_types)),
            OidPtr(unsafe_from_address=Int(hints.unsafe_ptr())),
        )
        _ = hints^
        _ = name^
        _ = sql^
        if sent == 0:
            raise self._connection_error()
        self._after_send()

    def send_prepared(
        mut self,
        var name: String,
        params: List[Param],
        result_format: ResultFormat = ResultFormat.TEXT,
    ) raises PgError:
        """Queue an execution of the prepared statement `name`.

        The statement has to exist on the server already -- from an earlier
        `send_prepare` whose results were collected, or from a `PREPARE`
        statement -- and an unknown name is SQLSTATE `26000`, reported when
        the results are collected rather than here.

        Args:
            name: The name the statement was prepared under.
            params: The values to bind, `params[0]` binding `$1`.
            result_format: Wire format for every column of the result,
                `ResultFormat.TEXT` by default.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `name` contains a NUL
                byte, `PgErrorKind.USAGE` when the connection is not `IDLE`
                or when a `String` parameter's value contains a NUL byte, or
                `PgErrorKind.CONNECTION` when libpq cannot queue or write the
                command.
        """
        _reject_nul(name, "name")
        self._require_state("send_prepared", AsyncState.IDLE)
        var buffers = _ParamBuffers(params)
        var sent = self._pq[].PQsendQueryPrepared(
            self._conn,
            CStr(unsafe_from_address=Int(name.as_c_string_span().ptr())),
            c_int(buffers.count()),
            buffers.values_ptr(),
            buffers.lengths_ptr(),
            buffers.formats_ptr(),
            c_int(result_format.value),
        )
        _ = buffers^
        _ = name^
        if sent == 0:
            raise self._connection_error()
        self._after_send()

    def flush(mut self) raises PgError -> Bool:
        """Push more of a queued command onto the socket.

        Only `SENDING` has anything to push; in any other state this is a
        no-op that answers True. Whether a `send` ends up `SENDING` at all
        depends on how much the kernel accepted at once, so callers should
        treat `flush` as something to loop on rather than something that
        proves a state.

        Returns:
            True when the command is fully written -- the connection is now
            `BUSY` -- or False when the socket is full and the caller should
            wait for writability and call again.

        Raises:
            PgError: `PgErrorKind.USAGE` when the handshake is still running,
                or `PgErrorKind.CONNECTION` when the write fails.
        """
        self._reject_connecting("flush")
        if self._state != AsyncState.SENDING:
            return True
        var flushed = self._pq[].PQflush(self._conn)
        if flushed == 0:
            self._state = AsyncState.BUSY
            return True
        if flushed == 1:
            return False
        raise self._connection_error()

    def set_single_row_mode(mut self) raises PgError:
        """Ask for the command in flight to answer one row at a time.

        Must be called after a `send*` and before anything has looked at the
        incoming data -- `poll_result`, `consume_input` and `is_busy` all close
        the window, and so does the handshake not being finished. libpq's own
        `PQsetSingleRowMode` keeps answering 1 after the first result has been
        collected, where switching mode no longer does anything, so the window
        is tracked here instead of being asked of libpq.

        In single-row mode a `SELECT` of three rows answers with three results
        of one row each and then a fourth that carries none, which is the end
        of that statement rather than the end of the command.

        Raises:
            PgError: `PgErrorKind.USAGE` when the call is outside the window,
                with `set_single_row_mode() must follow send() before any
                result is read (state <State>)`.
        """
        if not self._single_row_allowed:
            raise self._single_row_error()
        if self._pq[].PQsetSingleRowMode(self._conn) == 0:
            # Not reachable while the flag above is honest: libpq refuses only
            # outside the window this struct already guards.
            raise self._single_row_error()

    def _single_row_error(self) -> PgError:
        """Build the `USAGE` error for a `set_single_row_mode` out of its window.

        Returns:
            A `PgError` naming the state the call was made in.
        """
        return PgError(
            PgErrorKind.USAGE,
            String(
                (
                    "set_single_row_mode() must follow send() before any result"
                    " is read (state "
                ),
                self._state,
                ")",
            ),
        )

    def consume_input(mut self) raises PgError:
        """Read whatever has arrived on the socket into libpq's buffer.

        This is what makes a socket that `poll` reported readable stop being
        readable, and what collects notifications the server sent while no
        command was running. It never blocks and never waits for a whole
        result: `is_busy` is the question of whether one has arrived.

        A failure here means the connection is gone, and the state is left as
        it was -- a command still counts as in flight, so `poll_result` is
        still the way to collect what the server managed to say about it.

        Raises:
            PgError: `PgErrorKind.USAGE` when the handshake is still running,
                or `PgErrorKind.CONNECTION` when the connection is lost,
                carrying libpq's own message.
        """
        self._reject_connecting("consume_input")
        if self._pq[].PQconsumeInput(self._conn) == 0:
            raise self._connection_error()
        self._single_row_allowed = False

    def is_busy(mut self) -> Bool:
        """Report whether the next result is still incomplete.

        This asks `PQisBusy`, so it answers one question only: has a complete
        result arrived in libpq's buffer. It is **not** a liveness check -- a
        connection the server dropped reads as "not busy" -- and it is not the
        end of a command either, which is `poll_result` returning None in
        state `IDLE`.

        Returns:
            True when no complete result is available yet.
        """
        self._single_row_allowed = False
        return self._pq[].PQisBusy(self._conn) != 0

    def _consume_or_end_command(mut self) raises PgError:
        """Read the socket for `poll_result`, ending the command if it is lost.

        `consume_input` leaves the state alone on failure, because a command
        whose connection merely hiccuped is still in flight. Here the question
        is different: once libpq reports the connection bad, the NULL result
        that ends the command can never arrive, so leaving the connection
        `BUSY` would make a `poll_result` loop spin forever and would answer
        every later `send` with `USAGE` instead of saying the connection is
        gone. The command is therefore ended before the error is raised.

        Raises:
            PgError: `PgErrorKind.CONNECTION` carrying libpq's own message.
        """
        if self._pq[].PQconsumeInput(self._conn) != 0:
            return
        if self._pq[].PQstatus(self._conn) == CONNECTION_BAD:
            self._state = AsyncState.IDLE
        raise self._connection_error()

    def poll_result(mut self) raises PgError -> Optional[Result]:
        """Collect the next result of the command in flight, if one is ready.

        One call does the minimum: it finishes any pending write, reads what
        has arrived, and hands back a result only if a whole one is there.
        None means one of two different things, and `state()` tells them
        apart -- `BUSY` is "nothing yet, wait for readability and call
        again", `IDLE` is "that was the last one".

        Every result of the command comes through here, so a multi-statement
        `send` is a result per statement and then the None that ends it.

        A raised server error leaves the command in flight: the NULL result
        has not been read yet, so the connection stays `BUSY` and the next
        call is what brings it back to `IDLE`. That is what makes a failed
        statement recoverable without reconnecting. A *lost* connection is
        the one exception -- no NULL result can arrive on it, so the command
        is ended and the state is `IDLE` by the time the `CONNECTION` error
        is raised, which is what keeps this loop finite.

        Returns:
            The next `Result`, or None when none is ready or the command is
            over.

        Raises:
            PgError: `PgErrorKind.USAGE` when the handshake is still running,
                or `PgErrorKind.CONNECTION` / `PgErrorKind.SERVER` under
                exactly the classification `adopt_result` applies.
        """
        self._reject_connecting("poll_result")
        if self._state == AsyncState.IDLE:
            return None
        if self._state == AsyncState.SENDING:
            if not self.flush():
                # Still unwritten. Read anything the server has sent anyway,
                # so a server that fails mid-send is noticed.
                self._consume_or_end_command()
                return None
        self._consume_or_end_command()
        self._single_row_allowed = False
        if self._pq[].PQisBusy(self._conn) != 0:
            return None
        var res = self._pq[].PQgetResult(self._conn)
        if res.is_null():
            self._state = AsyncState.IDLE
            return None
        return adopt_result(self._pq, self._conn, res)

    def cancel(self) raises PgError:
        """Ask the server to abandon the command in flight.

        The request travels on a second, short-lived connection, so it does
        not queue behind the command it cancels and returns in a millisecond
        or two. What it does *not* do is end the command on this connection:
        the server stops working and answers with SQLSTATE `57014`
        (`canceling statement due to user request`), which is collected with
        `poll_result` / `fetch_all` like any other failure. Inside an explicit
        transaction that leaves `transaction_status()` at `PQTRANS_INERROR`,
        so a `ROLLBACK` is still owed.

        A cancel with nothing in flight is deliberately not an error: a result
        can arrive in the instant between deciding to cancel and calling, and
        there is nothing harmful about the race. An `IDLE` connection
        therefore does nothing here.

        Note that the cancel request is **not encrypted**: PostgreSQL 18's
        documentation marks `PQcancel` deprecated and insecure for that
        reason. The replacement, `PQcancelBlocking`, needs libpq 17 or newer,
        which `pq`'s floor of libpq 14 does not guarantee; moving to it is a
        later decision.

        Raises:
            PgError: `PgErrorKind.USAGE` with `cancel() called while
                Connecting` during the handshake, or
                `PgErrorKind.CONNECTION` when the cancel object cannot be
                built or the request cannot be delivered -- a connection the
                server has already dropped, for one.
        """
        self._reject_connecting("cancel")
        if self._state == AsyncState.IDLE:
            return
        var handle = self._pq[].PQgetCancel(self._conn)
        if handle.is_null():
            raise self._connection_error()
        var errbuf = List[UInt8](capacity=256)
        for _i in range(256):
            errbuf.append(UInt8(0))
        var sent = self._pq[].PQcancel(
            handle,
            MutCStr(unsafe_from_address=Int(errbuf.unsafe_ptr())),
            c_int(256),
        )
        # Read the buffer before freeing the handle: PQfreeCancel may reuse the
        # memory the message was written into.
        var reason = String(
            unsafe_from_utf8_ptr=CStr(
                unsafe_from_address=Int(errbuf.unsafe_ptr())
            )
        )
        self._pq[].PQfreeCancel(handle)
        _ = errbuf^
        if sent == 0:
            raise PgError(
                PgErrorKind.CONNECTION,
                reason if reason != "" else String("PQcancel failed"),
            )

    def notifications(mut self) raises PgError -> List[Notification]:
        """Collect every `LISTEN` / `NOTIFY` message that has arrived.

        Notifications ride along with whatever else the server sends, so this
        reads the socket first and then empties libpq's queue. It may be
        called in any state but `Connecting`: a notification sent while a
        command was running is collected once that command's results have
        been read, and one sent while the connection was idle is collected
        here directly.

        One call is not a promise of every notification the server has sent --
        they arrive when they arrive -- so a test or a loop that needs *n* of
        them calls this (or `wait_notification`) until it has *n*.

        Channel and payload are checked as UTF-8 before they become a
        `Notification`, the way `Row.get_text` checks a cell: a `SQL_ASCII`
        database can deliver bytes that are not UTF-8, and that is an
        `ENCODING` error rather than a silently mangled string. Only the
        offending notification is lost -- the connection stays usable, its
        state is untouched, and notifications already collected by the same
        call are delivered by the next one.

        Returns:
            The notifications, oldest first, each with owned strings. Empty
            when none had arrived.

        Raises:
            PgError: `PgErrorKind.USAGE` with `notifications() called while
                Connecting`, `PgErrorKind.ENCODING` with `invalid UTF-8
                at byte N of notification channel` / `... payload`, or
                `PgErrorKind.CONNECTION` when the connection is lost --
                `notifications() called on a lost connection` once the
                status has turned `CONNECTION_BAD`, otherwise libpq's own
                message.
        """
        self._reject_connecting("notifications")
        self._reject_lost("notifications")
        if self._pq[].PQconsumeInput(self._conn) == 0:
            raise self._connection_error()
        var found = self._pending.copy()
        self._pending.clear()
        while True:
            var raw = self._pq[].PQnotifies(self._conn)
            if raw.is_null():
                break
            var message = Pointer[PGnotify, MutUntrackedOrigin](
                unsafe_from_address=raw._addr
            )[]
            # Both strings are copied out before the PGnotify is freed: libpq
            # hands over the allocation, text and all.
            var channel = String(
                unsafe_from_utf8_ptr=CStr(unsafe_from_address=message.relname)
            )
            var payload = String(
                unsafe_from_utf8_ptr=CStr(unsafe_from_address=message.extra)
            )
            var backend_pid = Int(message.be_pid)
            self._pq[].PQfreemem(MutRawPtr(unsafe_from_address=raw._addr))
            # Validated only after the PGnotify is freed, so the rejection
            # below cannot leak libpq's allocation. The offending notification
            # is dropped; the ones already collected go back on `_pending` so
            # the next call still delivers them.
            try:
                _reject_bad_notification_text(channel.as_bytes(), "channel")
                _reject_bad_notification_text(payload.as_bytes(), "payload")
            except e:
                self._pending = found^
                raise e^
            found.append(
                Notification(
                    channel=channel^,
                    payload=payload^,
                    backend_pid=backend_pid,
                )
            )
        return found^

    def _wait_for(
        self, readable: Bool, remaining: Int, timeout_ms: Int
    ) raises PgError:
        """Wait one direction for `fetch_all`, in `fetch_all`'s own wording.

        `remaining` is what is left of the command's budget, so a timeout here
        is the command's timeout rather than this single wait's, and the
        message says so.

        Args:
            readable: Wait for readability when True, writability when False.
            remaining: Milliseconds left of the budget, `-1` for no limit.
            timeout_ms: The caller's original budget, for the message.

        Raises:
            PgError: `PgErrorKind.TIMEOUT` with `fetch_all timed out after N
                ms`, or whatever `wait_readable` / `wait_writable` raises.
        """
        try:
            if readable:
                self.wait_readable(remaining)
            else:
                self.wait_writable(remaining)
        except e:
            if e.kind == PgErrorKind.TIMEOUT:
                raise PgError(
                    PgErrorKind.TIMEOUT,
                    String("fetch_all timed out after ", timeout_ms, " ms"),
                )
            raise e^

    def fetch_all(mut self, timeout_ms: Int) raises PgError -> List[Result]:
        """Collect every result of the command in flight, waiting as needed.

        The `send` / wait / `poll_result` loop written once: it finishes the
        write first -- waiting for *readability* while a command is still
        half-sent would deadlock -- then waits and collects until the command
        ends. The budget covers the whole command, not each wait, so a
        statement that takes longer than `timeout_ms` cannot be stretched by
        answering in instalments.

        Results are returned even when one of the statements failed. The first
        error is held back, the remaining results are collected so the command
        really is over and the connection is `IDLE`, and only then is the
        error raised -- which is why a failing statement in the middle of a
        multi-statement `send` does not leave the connection unusable. On a
        connection that is gone, draining stops at the first `CONNECTION`
        error, whether or not `PQstatus` has turned `CONNECTION_BAD` (a
        `close(2)`d socket is reported by libpq as a read failure with the
        status still `OK`).

        An `IDLE` connection has nothing in flight, so this answers with an
        empty list rather than an error.

        `timeout_ms = 0` is a budget of nothing, not a single look: the first
        thing the loop does is notice it has no time left, so it raises
        `TIMEOUT` without waiting and without collecting results libpq may
        already hold. `wait_readable(0)`, in contrast, does look once.

        Args:
            timeout_ms: Milliseconds allowed for the whole command, at most
                `TIMEOUT_MS_MAX`, `-1` for no limit.

        Returns:
            One `Result` per statement of the command, in order. Empty when
            the connection was already `IDLE`.

        Raises:
            PgError: `PgErrorKind.TIMEOUT` with `fetch_all timed out after N
                ms` when the budget runs out, `PgErrorKind.USAGE` when the
                handshake is still running or `timeout_ms` is outside
                `-1 .. TIMEOUT_MS_MAX`, or
                the first `PgErrorKind.SERVER` / `PgErrorKind.CONNECTION` the
                statements produced.
        """
        _reject_bad_timeout(timeout_ms)
        self._reject_connecting("fetch_all")
        var results = List[Result]()
        if self._state == AsyncState.IDLE:
            return results^
        var deadline = monotonic() + timeout_ms * 1_000_000
        var first_error = Optional[PgError](None)
        while True:
            var remaining = -1
            if timeout_ms >= 0:
                var left = deadline - monotonic()
                # Round up: a sub-millisecond remainder is still time the
                # caller allowed, and 0 would turn the wait into a probe.
                remaining = (left + 999_999) // 1_000_000 if left > 0 else 0
                if remaining <= 0:
                    raise PgError(
                        PgErrorKind.TIMEOUT,
                        String("fetch_all timed out after ", timeout_ms, " ms"),
                    )
            if self._state == AsyncState.SENDING:
                self._wait_for(False, remaining, timeout_ms)
                _ = self.flush()
                continue
            var got: Optional[Result]
            try:
                got = self.poll_result()
            except e:
                if not first_error:
                    first_error = e.copy()
                # Keep draining: the command is over only once the NULL
                # result has been read. A lost connection is the exception --
                # nothing more can be read, so stop and report. The kind is
                # checked as well as the status: libpq reports a read failure
                # on a `close(2)`d descriptor without turning the status BAD,
                # and polling a descriptor that is gone would spin until the
                # budget ran out.
                if (
                    e.kind == PgErrorKind.CONNECTION
                    or self._pq[].PQstatus(self._conn) == CONNECTION_BAD
                ):
                    break
                continue
            if got:
                results.append(got.take())
                continue
            if self._state == AsyncState.IDLE:
                break
            self._wait_for(True, remaining, timeout_ms)
        if first_error:
            raise first_error.take()
        return results^

    def _restore_collected(mut self, collected: List[Notification]):
        """Put the notifications of `collected` back in front of `_pending`.

        A rejection on a later round trip must not cost the caller the
        notifications of the earlier ones: what a collecting wait has in hand
        goes back ahead of what is already held, so the next call delivers
        everything in the order it arrived.

        Args:
            collected: The notifications collected so far, oldest first.
        """
        var restored = List[Notification]()
        for i in range(len(collected)):
            restored.append(collected[i].copy())
        for i in range(len(self._pending)):
            restored.append(self._pending[i].copy())
        self._pending = restored^

    def _collect_notifications(
        mut self, method: StaticString, n: Int, timeout_ms: Int
    ) raises PgError -> List[Notification]:
        """Collect up to `n` notifications on one budget.

        The `notifications` / wait loop written once, for both public waits.
        Running out of budget is **not** an error here, unlike every other
        budget in this struct: nothing arriving is the ordinary outcome of
        listening, so this answers with whatever it has -- between none and
        `n - 1` of them.

        A round trip can deliver more notifications than are asked for, so
        the surplus is held on `_pending`, oldest first, and the next call
        answers from it without touching the socket.

        Args:
            method: Name of the public method, without parentheses, for the
                messages of the entry checks.
            n: How many to collect before returning, at least 1.
            timeout_ms: Milliseconds allowed for the whole collection, at most
                `TIMEOUT_MS_MAX`. `0` looks once without waiting, `-1` waits
                forever.

        Returns:
            The notifications collected, oldest first; fewer than `n` when the
            budget ran out first.

        Raises:
            PgError: `PgErrorKind.USAGE` with `<method>() called while
                Connecting` or when `timeout_ms` is outside
                `-1 .. TIMEOUT_MS_MAX`, `PgErrorKind.ENCODING` for a
                notification whose text is not UTF-8 (see `notifications`),
                or `PgErrorKind.CONNECTION` when the connection is lost --
                `<method>() called on a lost connection` once the status has
                turned `CONNECTION_BAD`. On every raise the notifications
                collected so far are put back in front of `_pending`, so the
                next call still delivers them.
        """
        _reject_bad_timeout(timeout_ms)
        self._reject_connecting(method)
        self._reject_lost(method)
        var out = List[Notification]()
        var deadline = monotonic() + timeout_ms * 1_000_000
        while True:
            var found: List[Notification]
            try:
                found = self.notifications()
            except e:
                self._restore_collected(out)
                raise e^
            for i in range(len(found)):
                if len(out) < n:
                    out.append(found[i].copy())
                else:
                    self._pending.append(found[i].copy())
            if len(out) >= n:
                return out^
            var remaining = -1
            if timeout_ms >= 0:
                var left = deadline - monotonic()
                # Round up, as `fetch_all` does: a sub-millisecond remainder
                # is still time the caller allowed.
                remaining = (left + 999_999) // 1_000_000 if left > 0 else 0
                if remaining <= 0:
                    return out^
            try:
                self.wait_readable(remaining)
            except e:
                if e.kind == PgErrorKind.TIMEOUT:
                    return out^
                self._restore_collected(out)
                raise e^

    def wait_notification(
        mut self, timeout_ms: Int
    ) raises PgError -> Optional[Notification]:
        """Wait for one `LISTEN` / `NOTIFY` message and return it.

        `_collect_notifications` asked for one: running out of the budget is
        not an error, it is None.

        A round trip can deliver several notifications at once while this
        returns one, so the surplus is held and the next call answers from it
        without waiting.

        Args:
            timeout_ms: Milliseconds to wait in total, at most
                `TIMEOUT_MS_MAX`. `0` looks once without waiting, `-1` waits
                forever.

        Returns:
            The oldest notification, or None when the budget ran out first.

        Raises:
            PgError: `PgErrorKind.USAGE` with `wait_notification() called
                while Connecting` or when `timeout_ms` is outside
                `-1 .. TIMEOUT_MS_MAX`, `PgErrorKind.ENCODING` for a
                notification whose text is not UTF-8 (see `notifications`),
                or `PgErrorKind.CONNECTION` when the connection is lost --
                `wait_notification() called on a lost connection` once the
                status has turned `CONNECTION_BAD`.
        """
        var found = self._collect_notifications(
            "wait_notification", 1, timeout_ms
        )
        if len(found) == 0:
            return None
        return found[0].copy()

    def wait_notifications(
        mut self, n: Int, timeout_ms: Int
    ) raises PgError -> List[Notification]:
        """Wait for `n` `LISTEN` / `NOTIFY` messages and return them.

        One budget for the whole batch rather than one per notification, and
        an expired budget is an answer rather than an error: a reader that
        wants five and gets two in the time it allowed is told so, and the
        two are real. That is what distinguishes this from a `wait_notification`
        loop, which cannot tell a caller how much of its budget is left.

        The surplus of a round trip that delivers more than `n` is held, so a
        following `wait_notification` or `wait_notifications` answers from it
        without waiting. `n = Int.MAX` is therefore a way to say "everything
        that arrives within the budget" rather than an error.

        Args:
            n: How many notifications to collect, at least 1.
            timeout_ms: Milliseconds allowed for the whole batch, at most
                `TIMEOUT_MS_MAX`. `0` looks once without waiting, `-1` waits
                forever.

        Returns:
            Exactly `n` notifications, oldest first, or the 0 to `n - 1` that
            arrived before the budget ran out.

        Raises:
            PgError: `PgErrorKind.USAGE` with `wait_notifications: n must be
                at least 1 (got N)` for an `n` below 1, with
                `wait_notifications() called while Connecting`, or when
                `timeout_ms` is outside `-1 .. TIMEOUT_MS_MAX`,
                `PgErrorKind.ENCODING` for a notification whose text is not
                UTF-8 (see `notifications`) -- the ones already collected are
                kept for the next call -- or `PgErrorKind.CONNECTION` when the
                connection is lost.
        """
        _reject_bad_timeout(timeout_ms)
        if n < 1:
            raise PgError(
                PgErrorKind.USAGE,
                String(
                    "wait_notifications: n must be at least 1 (got ", n, ")"
                ),
            )
        return self._collect_notifications("wait_notifications", n, timeout_ms)
