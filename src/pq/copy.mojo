"""`COPY ... FROM STDIN` and `COPY ... TO STDOUT` as RAII stream handles.

`Connection.copy_in` sends the `COPY` command and returns a `CopyIn` holding a
borrowed pointer to the connection, a flag saying whether the stream was
already ended, and a copy of the connection's rollback-failure handler --
exactly the three fields a `Transaction` carries, for the same reasons.
`CopyOut` is the mirror image. `Transaction.copy_in` / `copy_out` hand out the
same two values on the transaction's own borrow.

Both are *borrowed views* of their `Connection`: using one after the
connection has been **moved away** (`var c2 = conn^`, or passing `conn^` to a
function) is a compile error. Both are `Movable` but deliberately **not**
`Copyable`: a copy would hand the same open stream to two destructors.

## While a COPY is open, the connection accepts nothing else

libpq leaves a connection in `PQTRANS_ACTIVE` for the whole duration of a
COPY, and a `PQexec` issued in that state does not fail -- libpq silently ends
the COPY first, which **discards every row written so far** and then runs the
new command successfully. That silent data loss is why
`Connection._check_not_copying` rejects `execute`, `prepare`, `transaction`,
`copy_in` and `copy_out` with `PgErrorKind.USAGE` while a COPY is in
progress, and why `PreparedStatement.execute` does too. The COPY itself is
untouched by the rejection, so `finish()` still counts the rows that were
written.

## `CopyOut` is not an `Iterator`

The stream is driven by `next()` in a `while` loop, not by `for`. Mojo
1.1.0's `Iterator` protocol wants `__next__` to raise exactly
`StopIteration`, which leaves no way to surface a `PgError` from inside a
`for`; stashing the error to re-raise after the loop would hide a lost
connection for one more iteration. A `while` loop over `next()` is therefore
the whole API, and a failure arrives as a raise at the point it happened.

## Destruction ends the stream, and cannot raise

A destructor cannot raise, so a `CopyIn` that was never `finish`ed or
`abort`ed cancels itself with `PQputCopyEnd("aborted by pq")` and reports any
failure *other than the expected cancel* to the handler it copied at
construction, the way `Transaction.__deinit__` reports a failed implicit
`ROLLBACK`. The server answers a cancelled `COPY FROM STDIN` with SQLSTATE
`57014`, which is the normal outcome of this path and is swallowed. A
`CopyOut` destructor reads the rest of the stream and discards it, which is
what leaves the connection usable for the next command.

Both destructors do nothing at all when the COPY is already over without
their own value knowing -- which is what `Transaction.copy_in` warns about
under "the order matters": a block destroyed before its stream sends its
`ROLLBACK` through libpq, which ends the COPY on the way out. Cancelling or
draining then would draw libpq's `no COPY in progress`, a failure notice
about a connection that is perfectly healthy, so the status of the connection
is checked before anything is sent.

Every path that ends a COPY -- `finish`, `abort`, a failed `write` and both
destructors -- keeps calling `PQgetResult` until it returns NULL, so `COPY t
FROM STDIN; SELECT 42` leaves nothing queued behind the COPY's own result and
a connection whose COPY failed is idle rather than stuck.
"""

from std.ffi import c_int

from pq._ffi.functions import LibpqFFI
from pq._ffi.types import CStr, MutRawPtr, PGconnPtr, PQTRANS_ACTIVE
from pq.connection import Connection
from pq.errors import PgError, PgErrorKind, _reject_nul
from pq.result import Result, adopt_result

comptime _ALREADY_FINISHED: StaticString = "COPY already finished"
"""The `USAGE` message every method raises once the stream has ended."""

comptime _DROP_ABORT_MESSAGE: StaticString = "aborted by pq"
"""The cancel reason a `CopyIn` destructor sends to the server.

It reaches the server's log and the `57014` error text, so it says who
cancelled rather than why: the destructor has no idea why its caller never
called `finish()`.
"""

comptime _CANCELED_SQLSTATE: StaticString = "57014"
"""`query_canceled`, the server's answer to a `PQputCopyEnd` with a message.

This is the *expected* outcome of `abort()` and of a dropped `CopyIn`, so it
is the one SQLSTATE those two paths swallow instead of reporting.
"""


def _drain_results(pq: Pointer[LibpqFFI, MutUntrackedOrigin], conn: PGconnPtr):
    """Discard every result still queued on `conn`.

    `PQgetResult` returns NULL once the connection has nothing left to
    report, and until it does the connection is not idle. A COPY command may
    be followed by further statements in the same `PQexec` -- `COPY t FROM
    STDIN; SELECT 42` -- whose results arrive after the COPY's own, so every
    path that ends a COPY runs this.

    Args:
        pq: The libpq function table to call through.
        conn: The connection to drain.
    """
    while True:
        var res = pq[].PQgetResult(conn)
        if res.is_null():
            return
        pq[].PQclear(res)


def _drain_copy_out(
    pq: Pointer[LibpqFFI, MutUntrackedOrigin], conn: PGconnPtr
) -> Int:
    """Read and discard the rest of a `COPY ... TO STDOUT` stream.

    Each row libpq hands over is freed with `PQfreemem` immediately rather
    than copied, since the caller of this has already decided it does not
    want the data.

    Args:
        pq: The libpq function table to call through.
        conn: The connection whose COPY OUT stream is to be drained.

    Returns:
        The `PQgetCopyData` return code that ended the stream: `-1` when the
        server finished sending, `-2` when the transfer failed.
    """
    while True:
        var cell = List[Int](capacity=1)
        cell.append(0)
        var rc = Int(
            pq[].PQgetCopyData(
                conn,
                Pointer[Int, MutUntrackedOrigin](
                    unsafe_from_address=Int(cell.unsafe_ptr())
                ),
                c_int(0),
            )
        )
        if cell[0] != 0:
            pq[].PQfreemem(MutRawPtr(unsafe_from_address=cell[0]))
        _ = cell^
        if rc <= 0:
            return rc


def _copy_final_result(
    pq: Pointer[LibpqFFI, MutUntrackedOrigin], conn: PGconnPtr
) raises PgError -> Result:
    """Adopt the result a finished COPY produced and leave the connection idle.

    The result is classified exactly as `Connection._take_result` classifies
    one, with a single correction: a diagnostic that carries **no SQLSTATE**
    is reported as `PgErrorKind.CONNECTION` even when `PQstatus` still says
    the connection is fine. `adopt_result` requires both halves, which is
    right for a normal command, but a COPY whose socket died mid-transfer was
    measured to leave `PQstatus` at `CONNECTION_OK` while the only
    diagnostic libpq has is its own `could not receive data from server`
    text. Reporting that as `SERVER` would tell the caller to retry the
    statement on a connection that is gone.

    The queue is drained on both paths, so the connection is back to
    `PQTRANS_IDLE` whether this returns or raises.

    Args:
        pq: The libpq function table to call through.
        conn: The connection the COPY ran on.

    Returns:
        The `Result` of the COPY command, owning the `PGresult*`;
        `affected_rows()` is the number of rows transferred.

    Raises:
        PgError: `PgErrorKind.CONNECTION` when libpq returns no result at all
            or reports a diagnostic without an SQLSTATE, otherwise
            `PgErrorKind.SERVER` with the server's own SQLSTATE -- `22P04`
            for a malformed input row, `57014` for a cancelled COPY.
    """
    var res = pq[].PQgetResult(conn)
    var outcome: Result
    try:
        outcome = adopt_result(pq, conn, res)
    except e:
        _drain_results(pq, conn)
        if e.kind == PgErrorKind.SERVER and e.sqlstate == "":
            raise PgError(
                PgErrorKind.CONNECTION,
                e.message,
                severity=e.severity,
                detail=e.detail,
                hint=e.hint,
                position=e.position,
                context=e.context,
            )
        raise e^
    _drain_results(pq, conn)
    return outcome^


struct CopyIn[origin: ImmOrigin](Movable):
    """An open `COPY ... FROM STDIN` stream on a live `Connection`.

    Built by `Connection.copy_in` or `Transaction.copy_in`, which have
    already sent the `COPY` command and confirmed the server is waiting for
    data. Feed it with `write`, then end it with `finish()` -- which returns
    the `Result` whose `affected_rows()` is the row count -- or with
    `abort(message)`. A value destroyed without either is cancelled, so an
    error path that simply returns cannot leave the connection stuck in a
    COPY.

    Rows are *bytes*, not values: the data has to be in whichever COPY format
    the command asked for, text by default. `write` may be called with any
    chunking at all, including a partial row, because libpq streams the bytes
    as they come.

    Nothing else may be done with the connection until the stream ends; see
    the module docstring.

    Parameters:
        origin: Immutable origin of the borrowed `Connection`.
    """

    var _conn: Pointer[Connection, Self.origin]
    """Borrowed connection the COPY stream is open on."""

    var _done: Bool
    """True once the stream ended, which disarms `__deinit__`.

    A failed `write` sets it too, after ending the COPY itself: libpq rejected
    the data but stays in the COPY state until something terminates it, so the
    `write` does that before it raises and there is nothing left for the
    destructor to send.
    """

    var _handler: def(PgError) thin
    """Handler for a failed cancel from `__deinit__`, copied at construction."""

    def __init__(
        out self,
        conn: Pointer[Connection, Self.origin],
        handler: def(PgError) thin,
    ):
        """Adopt a COPY stream whose `COPY` command has already been accepted.

        Args:
            conn: Pointer to the connection the `COPY` was sent on.
            handler: The connection's rollback-failure handler, copied here so
                that replacing it later does not change this value.
        """
        self._conn = conn
        self._done = False
        self._handler = handler

    def __deinit__(deinit self):
        """Cancel the stream unless it was already ended.

        `PQputCopyEnd` is given the `aborted by pq` reason, which makes the
        server answer with SQLSTATE `57014` -- the expected outcome of this
        path, swallowed here. Any other failure is handed to the handler this
        value copied at construction time, because a destructor cannot raise.
        The queue is drained either way, so the connection is left idle.

        A COPY that ended without this value hearing about it -- a
        `Transaction` destroyed first sends its `ROLLBACK` through libpq,
        which ends the COPY on the way -- leaves the connection out of
        `PQTRANS_ACTIVE`, and cancelling then would draw libpq's own `no COPY
        in progress`: a failure notice about a healthy connection. So the
        status is the second guard after `_done`, and nothing is sent when it
        says the stream is already over.
        """
        if self._done:
            return
        var pq = self._conn[]._pq
        var conn = self._conn[]._conn
        if pq[].PQtransactionStatus(conn) != PQTRANS_ACTIVE:
            return
        var message = String(_DROP_ABORT_MESSAGE)
        _ = pq[].PQputCopyEnd(conn, Int(message.as_c_string_span().ptr()))
        _ = message^
        try:
            _ = _copy_final_result(pq, conn)
        except e:
            if e.sqlstate != _CANCELED_SQLSTATE:
                self._handler(e)

    def _check_active(self) raises PgError:
        """Reject every method once the stream has ended.

        Called first by `write`, `finish` and `abort`, so a second `finish`
        and a `write` after a failed one both fail client-side with nothing
        sent to the server.

        Raises:
            PgError: `PgErrorKind.USAGE` (`COPY already finished`) when the
                stream was ended by `finish`, `abort`, or a failed `write`.
        """
        if self._done:
            raise PgError(PgErrorKind.USAGE, _ALREADY_FINISHED)

    def write[
        bytes_origin: ImmOrigin, //
    ](mut self, bytes: Span[UInt8, bytes_origin]) raises PgError:
        """Hand `bytes` to the server with `PQputCopyData`.

        The bytes are passed through untouched -- no row splitting, no
        escaping, no encoding conversion -- so they must already be in the
        format the `COPY` command named. An empty span is a no-op and reaches
        libpq not at all.

        libpq buffers and sends synchronously here, so a return means the
        data was accepted; it does **not** mean the server has validated it.
        A malformed row is reported by `finish()`, not by the `write` that
        carried it.

        Parameters:
            bytes_origin: Immutable origin of the caller's byte span.

        Args:
            bytes: One or more complete or partial rows, in the COPY format
                the command asked for.

        Raises:
            PgError: `PgErrorKind.USAGE` (`COPY already finished`) when the
                stream has already ended, or `PgErrorKind.CONNECTION` with
                libpq's own `PQerrorMessage` text when `PQputCopyData` failed.
                A failure ends the stream -- on libpq's side too, so the
                connection is idle rather than still in the COPY -- which
                makes every later `write`, `finish` and `abort` `USAGE` and
                every command on the connection `CONNECTION`. A connection
                lost this way is recovered with `Connection.reset()`.
        """
        self._check_active()
        if len(bytes) == 0:
            return
        var pq = self._conn[]._pq
        var conn = self._conn[]._conn
        var rc = pq[].PQputCopyData(
            conn,
            CStr(unsafe_from_address=Int(bytes.unsafe_ptr())),
            c_int(len(bytes)),
        )
        if rc != 1:
            # `PQerrorMessage` grows by one line per failure, so it is read
            # here, once, *before* the COPY is ended -- ending it appends
            # libpq's own complaint and would bury the real cause. 0 means
            # "would block", which a synchronous connection never answers.
            var reason = String(unsafe_from_utf8_ptr=pq[].PQerrorMessage(conn))
            # The data was rejected but libpq is still in the COPY state, and
            # only a `PQputCopyEnd` with its queue drained brings the
            # connection back out of `PQTRANS_ACTIVE`. Without this the
            # connection answers `a COPY is in progress` to everything for
            # ever -- a `USAGE` error about a stream that is gone, on a
            # connection that only `reset()` could recover. Both outcomes are
            # discarded: what went wrong is `reason`, not the cleanup.
            _ = pq[].PQputCopyEnd(conn, 0)
            _drain_results(pq, conn)
            self._done = True
            raise PgError(PgErrorKind.CONNECTION, reason)

    def write(mut self, s: String) raises PgError:
        """Hand the UTF-8 bytes of `s` to the server.

        A convenience over the `Span` overload for the text and CSV COPY
        formats, where rows are built as strings. The bytes go out exactly as
        `s` holds them, including any NUL byte -- `COPY` data is not a C
        string and is never truncated at one.

        Args:
            s: One or more complete or partial rows, newline-terminated as
                the text and CSV formats require.

        Raises:
            PgError: Exactly what the `Span` overload raises.
        """
        self.write(s.as_bytes())

    def finish(mut self) raises PgError -> Result:
        """End the stream normally and return the server's answer.

        `PQputCopyEnd` is sent with no error message, which tells the server
        the data is complete, and the result that comes back is the `COPY`
        command's own: `affected_rows()` is the number of rows it took. This
        is where a malformed row surfaces -- the `write` that carried it had
        no way to know -- so a COPY that fails here has stored nothing.

        Results queued behind the COPY, as in `COPY t FROM STDIN; SELECT 42`,
        are drained, so the connection is idle when this returns or raises.

        Returns:
            The `Result` of the `COPY` command, owning the `PGresult*`.

        Raises:
            PgError: `PgErrorKind.USAGE` (`COPY already finished`) when the
                stream has already ended; `PgErrorKind.CONNECTION` when
                `PQputCopyEnd` failed, when libpq returns no result at all,
                or when it reports a diagnostic without an SQLSTATE;
                `PgErrorKind.SERVER` when the server rejects the data,
                carrying its SQLSTATE -- `22P04` for a row with the wrong
                number of columns, `22P02` for a value the column's input
                function refused.
        """
        self._check_active()
        var pq = self._conn[]._pq
        var conn = self._conn[]._conn
        var rc = pq[].PQputCopyEnd(conn, 0)
        self._done = True
        if rc < 0:
            # Read first, drain second: the queue is what leaves the
            # connection idle, and draining it can replace the message that
            # says why the end failed.
            var reason = String(unsafe_from_utf8_ptr=pq[].PQerrorMessage(conn))
            _drain_results(pq, conn)
            raise PgError(PgErrorKind.CONNECTION, reason)
        return _copy_final_result(pq, conn)

    def abort(mut self, var message: String) raises PgError:
        """Cancel the stream, discarding every row written so far.

        `message` is handed to `PQputCopyEnd` as the reason, which the server
        echoes in its log and in the `COPY from stdin failed: <message>`
        error it answers with. That error carries SQLSTATE `57014` and is the
        *expected* outcome, so it is swallowed here and this returns
        normally; the connection is left idle and usable. Any other failure
        of the cancel is raised.

        Args:
            message: The reason to report to the server. Must not contain a
                NUL byte, since libpq takes it as a C string.

        Raises:
            PgError: `PgErrorKind.USAGE` (`COPY already finished`) when the
                stream has already ended; `PgErrorKind.TYPE_MISMATCH` when
                `message` contains a NUL byte, with nothing sent;
                `PgErrorKind.CONNECTION` when `PQputCopyEnd` failed or libpq
                reported a diagnostic without an SQLSTATE; or
                `PgErrorKind.SERVER` for a server error that is not the `57014`
                this path expects.
        """
        self._check_active()
        _reject_nul(message, "message")
        var pq = self._conn[]._pq
        var conn = self._conn[]._conn
        var rc = pq[].PQputCopyEnd(conn, Int(message.as_c_string_span().ptr()))
        _ = message^
        self._done = True
        if rc < 0:
            # As in `finish`: the reason before the drain that makes the
            # connection idle again.
            var reason = String(unsafe_from_utf8_ptr=pq[].PQerrorMessage(conn))
            _drain_results(pq, conn)
            raise PgError(PgErrorKind.CONNECTION, reason)
        try:
            _ = _copy_final_result(pq, conn)
        except e:
            if e.sqlstate != _CANCELED_SQLSTATE:
                raise e^


struct CopyOut[origin: ImmOrigin](Movable):
    """An open `COPY ... TO STDOUT` stream on a live `Connection`.

    Built by `Connection.copy_out` or `Transaction.copy_out`, which have
    already sent the `COPY` command and confirmed the server is sending data.
    Drive it with `next()` until it answers `None`:

        var stream = conn.copy_out("COPY t TO STDOUT")
        while True:
            var row = stream.next()
            if not row:
                break
            ref bytes = row.value()
            ...

    This is deliberately **not** an `Iterator`; the module docstring explains
    why `for` is not available. A value destroyed before the stream ended
    reads the rest and discards it, so the connection is usable afterwards.

    Rows are *bytes* in whichever COPY format the command asked for, newline
    terminated in the text and CSV formats.

    Nothing else may be done with the connection until the stream ends; see
    the module docstring.

    Parameters:
        origin: Immutable origin of the borrowed `Connection`.
    """

    var _conn: Pointer[Connection, Self.origin]
    """Borrowed connection the COPY stream is open on."""

    var _done: Bool
    """True once the stream ended, which disarms `__deinit__`."""

    var _handler: def(PgError) thin
    """Handler for a failure seen by `__deinit__`, copied at construction."""

    def __init__(
        out self,
        conn: Pointer[Connection, Self.origin],
        handler: def(PgError) thin,
    ):
        """Adopt a COPY stream whose `COPY` command has already been accepted.

        Args:
            conn: Pointer to the connection the `COPY` was sent on.
            handler: The connection's rollback-failure handler, copied here so
                that replacing it later does not change this value.
        """
        self._conn = conn
        self._done = False
        self._handler = handler

    def __deinit__(deinit self):
        """Read the rest of the stream and discard it, unless it already ended.

        The server is in the middle of sending and will not stop being asked
        to; the only way back to an idle connection is to consume what is
        left. A destructor cannot raise, so a transfer that failed part way
        through is handed to the handler this value copied at construction.

        As in `CopyIn.__deinit__`, a stream that something else already ended
        -- the `ROLLBACK` of a `Transaction` destroyed first -- leaves the
        connection out of `PQTRANS_ACTIVE`, and reading from a COPY that is
        over would report a failure on a healthy connection. Nothing is read
        in that case.
        """
        if self._done:
            return
        var pq = self._conn[]._pq
        var conn = self._conn[]._conn
        if pq[].PQtransactionStatus(conn) != PQTRANS_ACTIVE:
            return
        var rc = _drain_copy_out(pq, conn)
        if rc == -1:
            try:
                _ = _copy_final_result(pq, conn)
            except e:
                self._handler(e)
            return
        self._handler(
            PgError(
                PgErrorKind.CONNECTION,
                String(unsafe_from_utf8_ptr=pq[].PQerrorMessage(conn)),
            )
        )

    def _check_active(self) raises PgError:
        """Reject `next()` once the stream has ended.

        Raises:
            PgError: `PgErrorKind.USAGE` (`COPY already finished`) when the
                stream already ended, by reaching its end or by failing.
        """
        if self._done:
            raise PgError(PgErrorKind.USAGE, _ALREADY_FINISHED)

    def next(mut self) raises PgError -> Optional[List[UInt8]]:
        """Return the next row of the stream, or `None` at its end.

        Each row is copied out of the buffer libpq allocated for it, which is
        then released with `PQfreemem`, so the returned bytes outlive the
        stream and the connection. The copy is what makes the row safe to
        keep; `COPY` has no zero-copy path the way `Row.get` does, because
        libpq owns each row's buffer separately.

        Reaching the end of the stream also adopts the `COPY` command's own
        result -- which is where a mid-transfer server error surfaces -- and
        drains anything queued behind it, so the connection is idle once this
        has answered `None`.

        Returns:
            The next row's bytes, newline terminated in the text and CSV
            formats, or `None` once the server has sent everything.

        Raises:
            PgError: `PgErrorKind.USAGE` (`COPY already finished`) when the
                stream has already ended; `PgErrorKind.CONNECTION` when the
                transfer failed, carrying libpq's own `PQerrorMessage` text;
                `PgErrorKind.SERVER` when the server reports an error for the
                `COPY` itself, carrying its SQLSTATE. The stream ends on any
                of these, so a later `next()` is `USAGE`.
        """
        self._check_active()
        var pq = self._conn[]._pq
        var conn = self._conn[]._conn
        var cell = List[Int](capacity=1)
        cell.append(0)
        var rc = Int(
            pq[].PQgetCopyData(
                conn,
                Pointer[Int, MutUntrackedOrigin](
                    unsafe_from_address=Int(cell.unsafe_ptr())
                ),
                c_int(0),
            )
        )
        if rc > 0:
            var row = List[UInt8](capacity=rc)
            var src = Pointer[UInt8, ImmUntrackedOrigin](
                unsafe_from_address=cell[0]
            )
            for i in range(rc):
                row.append(src[unsafe_offset=i])
            pq[].PQfreemem(MutRawPtr(unsafe_from_address=cell[0]))
            _ = cell^
            return Optional(row^)
        if cell[0] != 0:
            pq[].PQfreemem(MutRawPtr(unsafe_from_address=cell[0]))
        _ = cell^
        self._done = True
        if rc == -1:
            # The stream ended cleanly; the COPY's own result is what reports
            # a server-side failure, and it is discarded here because
            # `copy_out` has no row count worth handing back.
            _ = _copy_final_result(pq, conn)
            return None
        # -2 is a failed transfer. 0 means "no data yet", which only an
        # asynchronous connection can answer.
        raise PgError(
            PgErrorKind.CONNECTION,
            String(unsafe_from_utf8_ptr=pq[].PQerrorMessage(conn)),
        )
