"""A single-threaded pool of reusable `Connection`s with RAII checkout.

`Pool.open` holds the connection parameters and a list of idle connections.
`acquire()` hands out a `PooledConnection`, a guard that owns the connection
while it is borrowed and returns it to the pool when it is destroyed. The
guard forwards the `Connection` API, so code written against a connection runs
unchanged on a borrowed one.

## Not thread safe

There is no lock anywhere in this module, and none of the counters are atomic.
Mojo 1.1.0 has no threads in its standard library, so a pool shared between
OS threads cannot be written correctly here and is not attempted: **use one
pool from one thread**. Two guards from the same pool may be alive at once --
that is the point -- but all of it has to happen on the same thread.

## Returning a connection cleans it up, or throws it away

A guard is destroyed by Mojo right after its last use, which is when
`Pool._release` runs. It decides between keeping the connection and closing
it, in this order:

1. The pool was closed while the connection was out: close it.
2. A transaction is still open (`PQTRANS_INTRANS` or `PQTRANS_INERROR`): send
   `ROLLBACK`. A failure there means the connection is gone, so it goes to the
   connection's rollback-failure handler and the connection is closed.
3. `PQstatus` is not `CONNECTION_OK`, or the transaction status is still not
   idle -- `PQTRANS_ACTIVE` for a COPY that outlived its stream handle,
   `PQTRANS_UNKNOWN` for a dead connection: close it.
4. `max_lifetime_s` is set and the connection is older than that: close it.
5. The health check below says the backend is gone: close it.

Otherwise the connection joins the idle list and the next `acquire()` hands
out the same backend, with its prepared-statement counter intact so a reused
connection never re-issues a name the server still holds.

Session state that survives a `ROLLBACK` is **not** reset: a `SET` of a GUC,
a prepared statement, a temporary table, a `LISTEN` registration or an
advisory lock taken by one borrower is still there for the next one. Undo
what the next borrower must not see, or do not set it outside a transaction.

## Health is checked without a round trip

A borrowed connection may have been terminated by the server, and asking the
server about it would cost a query per checkout. Instead `PQstatus` is read
and `PQconsumeInput` is called **twice**: measured on PG14 and PG17, the
first call consumes the backend's farewell message and still answers 1, and
only the second one reports the loss. Both calls return immediately and send
nothing. A connection that fails the check is closed on return, and one that
fails it on checkout is revived with `Connection.reset()` -- which reconnects
and re-pins the session settings -- or replaced if even that fails.

The check cannot see a termination whose notice has not arrived yet. A
connection returned in that window is handed out again and the next borrower
gets `PgErrorKind.CONNECTION` from its first command; that guard's own return
then closes it.

## Mutation through an immutable borrow

`PooledConnection` is parameterised on the pool's origin, which is immutable:
a guard borrows the pool rather than owning it, so the pool stays usable --
`acquire()` again, read `size()` -- while guards are alive. Returning a
connection has to write the pool's fields through that immutable borrow,
which is why the idle list is reached through a `MutUntrackedOrigin` pointer
and the two counters are one-element `List[Int]` cells, the same escape hatch
`Connection._next_stmt_name` uses for its statement counter.

Because the guard is bound to the pool's origin, using a guard after the pool
has been **moved away** (`var p2 = pool^`, or passing `pool^` to a function)
is a compile error (`use of uninitialized value`), and `_ = pool^` keeps the
pool alive until after the last guard.
"""

from std.ffi import c_int
from std.time import monotonic

from pq._ffi.functions import LibpqFFI
from pq._ffi.loader import libpq_ptr
from pq._ffi.types import (
    CONNECTION_OK,
    PQTRANS_IDLE,
    PQTRANS_INERROR,
    PQTRANS_INTRANS,
)
from pq.connection import Connection
from pq.copy import CopyIn, CopyOut
from pq.errors import PgError, PgErrorKind
from pq.params import Param
from pq.prepared import PreparedStatement
from pq.result import Result, ResultFormat
from pq.transaction import Transaction, _default_rollback_failure_handler


struct _Slot(Movable):
    """An idle connection together with the time it was opened."""

    var conn: Connection
    """The idle connection, closed by its own destructor when discarded."""

    var opened_at: Int
    """`monotonic()` reading from when the connection was opened or reset."""

    def __init__(out self, var conn: Connection, opened_at: Int):
        """Take ownership of an idle connection.

        Args:
            conn: The connection to park.
            opened_at: The `monotonic()` nanosecond reading of its opening.
        """
        self.conn = conn^
        self.opened_at = opened_at

    def take(deinit self) -> Connection:
        """Give up the connection, consuming the slot.

        A field cannot be moved out of a live value on Mojo 1.1.0 -- the
        compiler refuses to leave the rest of the slot undestroyable -- so
        handing the connection to a guard goes through this consuming method.
        Read `opened_at` before calling it.

        Returns:
            The connection the slot owned.
        """
        return self.conn^


def _is_alive(
    pq: Pointer[LibpqFFI, MutUntrackedOrigin], conn: Connection
) -> Bool:
    """Report whether `conn` still has a backend, without a round trip.

    `PQconsumeInput` is called twice because the first call consumes a pending
    fatal message from a terminated backend and still reports success; see the
    module docstring.

    Args:
        pq: The libpq table the connection was opened with.
        conn: The connection to check.

    Returns:
        True when `PQstatus` is `CONNECTION_OK` and both `PQconsumeInput`
        calls succeed.
    """
    if pq[].PQstatus(conn._conn) != CONNECTION_OK:
        return False
    if pq[].PQconsumeInput(conn._conn) != c_int(1):
        return False
    return pq[].PQconsumeInput(conn._conn) == c_int(1)


def _check_pool_sizes(
    max_size: Int, min_size: Int, max_lifetime_s: Int
) raises PgError:
    """Validate the three size arguments before any connection is opened.

    Args:
        max_size: The requested maximum number of connections.
        min_size: The requested number of connections to open up front.
        max_lifetime_s: The requested maximum connection lifetime in seconds.

    Raises:
        PgError: `PgErrorKind.USAGE` for a non-positive `max_size`, a
            `min_size` outside `0..max_size`, or a negative
            `max_lifetime_s`. Nothing is sent to any server, so a program
            that mis-sizes its pool fails before it connects.
    """
    if max_size <= 0:
        raise PgError(
            PgErrorKind.USAGE,
            String("max_size must be positive (got ", max_size, ")"),
        )
    if min_size < 0 or min_size > max_size:
        raise PgError(
            PgErrorKind.USAGE,
            String(
                "min_size must be between 0 and max_size (got ",
                min_size,
                ")",
            ),
        )
    if max_lifetime_s < 0:
        raise PgError(
            PgErrorKind.USAGE,
            String(
                "max_lifetime_s must not be negative (got ",
                max_lifetime_s,
                ")",
            ),
        )


struct Pool(Movable):
    """A fixed-capacity pool of synchronous connections, for one thread only.

    **This type is not thread safe**: it holds no lock and its counters are
    not atomic, so one pool belongs to one thread. The module docstring says
    why no locking is written here.

    Construct one with `Pool.open`, take connections out with `acquire()`, and
    let the returned guard go out of scope to give one back. The pool closes
    whatever it still holds when it is destroyed, so no explicit `close()` is
    needed to avoid leaking handles -- `close()` exists for closing the pool
    while the program keeps running.
    """

    var _pq: Pointer[LibpqFFI, MutUntrackedOrigin]
    """Borrowed process-wide libpq table, retained so `_release` cannot raise.
    """

    var _conninfo: String
    """Conninfo string new connections are opened with; empty in `Dict` mode.
    """

    var _params: Dict[String, String]
    """Discrete connection parameters; empty unless `_use_params` is set."""

    var _use_params: Bool
    """True when `_params` rather than `_conninfo` describes the server."""

    var _max_size: Int
    """Upper bound on `size()`: idle plus borrowed connections together."""

    var _max_lifetime_s: Int
    """Maximum connection age in seconds, or 0 to keep connections forever."""

    var _idle: List[_Slot]
    """Connections ready to hand out, each with its opening time."""

    var _borrowed: List[Int]
    """One-element cell counting the guards currently alive.

    A `List` rather than an `Int` because a guard returns its connection
    through an immutable borrow of the pool; see the module docstring.
    """

    var _closed: List[Int]
    """One-element cell, non-zero once `close()` has run."""

    var _handler: def(PgError) thin
    """Handler installed on every connection the pool opens."""

    def __init__(
        out self,
        pq: Pointer[LibpqFFI, MutUntrackedOrigin],
        var conninfo: String,
        var params: Dict[String, String],
        use_params: Bool,
        max_size: Int,
        max_lifetime_s: Int,
        var idle: List[_Slot],
    ):
        """Adopt already-validated settings and already-opened connections.

        Private: `Pool.open` is the constructor callers use, because it is
        what validates the sizes and opens the `min_size` connections.

        Args:
            pq: The libpq table the pool's connections are opened with.
            conninfo: The conninfo string, or empty in `Dict` mode.
            params: The discrete parameters, or empty in conninfo mode.
            use_params: True to connect with `params`, False with `conninfo`.
            max_size: Validated upper bound on the number of connections.
            max_lifetime_s: Validated maximum connection age in seconds.
            idle: Connections already opened for `min_size`.
        """
        self._pq = pq
        self._conninfo = conninfo^
        self._params = params^
        self._use_params = use_params
        self._max_size = max_size
        self._max_lifetime_s = max_lifetime_s
        self._idle = idle^
        self._borrowed = [0]
        self._closed = [0]
        self._handler = _default_rollback_failure_handler

    @staticmethod
    def open(
        var conninfo: String,
        max_size: Int,
        *,
        min_size: Int = 0,
        max_lifetime_s: Int = 0,
    ) raises PgError -> Pool:
        """Create a pool whose connections use a conninfo string or URI.

        The sizes are checked first, so a mis-sized pool raises without
        contacting any server. `min_size` connections are then opened one by
        one; if one of them fails, the ones already open are closed on the way
        out and nothing is left behind.

        Args:
            conninfo: The conninfo string or connection URI, exactly as
                `Connection.open(String)` takes it.
            max_size: The maximum number of connections, idle and borrowed
                together. Must be positive.
            min_size: How many connections to open immediately, from 0 to
                `max_size`.
            max_lifetime_s: Close a returned connection that is at least this
                many seconds old; 0 keeps connections for the life of the
                pool.

        Returns:
            A pool holding `min_size` idle connections.

        Raises:
            PgError: `PgErrorKind.USAGE` for an invalid size argument, before
                connecting. Otherwise whatever `Connection.open` raises for
                the first connection that fails to open.
        """
        _check_pool_sizes(max_size, min_size, max_lifetime_s)
        var idle = List[_Slot]()
        for _ in range(min_size):
            var conn = Connection.open(conninfo.copy())
            idle.append(_Slot(conn^, monotonic()))
        return Pool(
            libpq_ptr(),
            conninfo^,
            Dict[String, String](),
            False,
            max_size,
            max_lifetime_s,
            idle^,
        )

    @staticmethod
    def open(
        params: Dict[String, String],
        max_size: Int,
        *,
        min_size: Int = 0,
        max_lifetime_s: Int = 0,
    ) raises PgError -> Pool:
        """Create a pool whose connections use discrete keyword parameters.

        The `Dict` is taken literally by `Connection.open(Dict)`, so no value
        can be echoed back as a conninfo syntax error -- the form to use for
        credentials the program supplies.

        Args:
            params: Connection keywords mapped to their values, for example
                `"host"`, `"port"`, `"user"`, `"password"`, `"dbname"`.
            max_size: The maximum number of connections, idle and borrowed
                together. Must be positive.
            min_size: How many connections to open immediately, from 0 to
                `max_size`.
            max_lifetime_s: Close a returned connection that is at least this
                many seconds old; 0 keeps connections for the life of the
                pool.

        Returns:
            A pool holding `min_size` idle connections.

        Raises:
            PgError: Exactly what the `String` overload raises.
        """
        _check_pool_sizes(max_size, min_size, max_lifetime_s)
        var idle = List[_Slot]()
        for _ in range(min_size):
            var conn = Connection.open(params.copy())
            idle.append(_Slot(conn^, monotonic()))
        return Pool(
            libpq_ptr(),
            String(),
            params.copy(),
            True,
            max_size,
            max_lifetime_s,
            idle^,
        )

    def _mut_idle(self) -> Pointer[List[_Slot], MutUntrackedOrigin]:
        """Return a writable pointer at the idle list through a borrow.

        The guard that returns a connection holds the pool immutably, so the
        append in `_release` goes through here; `Connection._next_stmt_name`
        has the same shape and the same reason.

        Returns:
            A pointer at `_idle` with an untracked mutable origin.
        """
        return Pointer[List[_Slot], MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self._idle))
        )

    def _mut_borrowed(self) -> Pointer[List[Int], MutUntrackedOrigin]:
        """Return a writable pointer at the borrowed-count cell.

        Returns:
            A pointer at `_borrowed` with an untracked mutable origin.
        """
        return Pointer[List[Int], MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self._borrowed))
        )

    def _open_one(self) raises PgError -> Connection:
        """Open one connection with the pool's parameters and handler.

        Returns:
            The new connection, with the pool's rollback-failure handler
            installed.

        Raises:
            PgError: Whatever `Connection.open` raises.
        """
        var conn: Connection
        if self._use_params:
            conn = Connection.open(self._params.copy())
        else:
            conn = Connection.open(self._conninfo.copy())
        conn.set_rollback_failure_handler(self._handler)
        return conn^

    def acquire(ref self) raises PgError -> PooledConnection[origin_of(self)]:
        """Take a connection out of the pool for the caller to use.

        An idle connection is preferred, and the same backend comes back to
        whoever asks next -- so a `pg_backend_pid()` seen once is seen again.
        An idle connection that fails the health check is revived with
        `Connection.reset()`, and replaced by a new connection if the reset
        fails too. With no idle connection left, a new one is opened while the
        pool is below `max_size`.

        The returned guard borrows the pool, so `acquire()` may be called
        again while it is alive -- up to `max_size` guards at once -- and
        `size()`, `idle()` and `borrowed()` stay readable. Destroying the
        guard returns the connection; see the module docstring for the rules
        that decides whether it is kept.

        Returns:
            A `PooledConnection` bound to this pool's origin.

        Raises:
            PgError: `PgErrorKind.USAGE` (`pool is closed`) after `close()`,
                or (`pool exhausted: all N connections are borrowed`) when
                every one of the `max_size` connections is out. Otherwise
                whatever `Connection.open` raises -- for a connection opened
                because the pool had none idle, and for the replacement of an
                idle one that failed its health check. A failed
                `Connection.reset()` is never raised: it only means the
                replacement is opened instead.
        """
        if self._closed[0] != 0:
            raise PgError(PgErrorKind.USAGE, "pool is closed")
        var idle = self._mut_idle()
        var borrowed = self._mut_borrowed()
        if len(idle[]) > 0:
            var slot = idle[].pop()
            var opened_at = slot.opened_at
            var conn = slot^.take()
            if _is_alive(self._pq, conn):
                borrowed[][0] += 1
                return PooledConnection[origin_of(self)](
                    Pointer(to=self), conn^, opened_at
                )
            # The backend is gone. `PQreset` reconnects the same `PGconn*`,
            # which keeps the prepared-statement counter and costs no new
            # handle; a reset that fails leaves nothing worth keeping. Either
            # way the pool is one connection below `max_size` here, because
            # the slot has already left the idle list.
            var revived = True
            try:
                conn.reset()
            except e:
                revived = False
            if revived:
                borrowed[][0] += 1
                return PooledConnection[origin_of(self)](
                    Pointer(to=self), conn^, monotonic()
                )
            _ = conn^
            var replacement = self._open_one()
            borrowed[][0] += 1
            return PooledConnection[origin_of(self)](
                Pointer(to=self), replacement^, monotonic()
            )
        if self.size() >= self._max_size:
            raise PgError(
                PgErrorKind.USAGE,
                String(
                    "pool exhausted: all ",
                    self._max_size,
                    " connections are borrowed",
                ),
            )
        var fresh = self._open_one()
        borrowed[][0] += 1
        return PooledConnection[origin_of(self)](
            Pointer(to=self), fresh^, monotonic()
        )

    def _release(self, var conn: Connection, opened_at: Int):
        """Take a connection back from a destroyed guard.

        Called from `PooledConnection.__deinit__`, which cannot raise, so
        nothing here raises either: a failed `ROLLBACK` goes to the
        connection's rollback-failure handler and the connection is closed.
        The decision order is the one the module docstring lists.

        Args:
            conn: The connection the guard owned.
            opened_at: The `monotonic()` reading the guard carried.
        """
        self._mut_borrowed()[][0] -= 1
        if self._closed[0] != 0:
            _ = conn^
            return
        var pq = self._pq
        var ts = pq[].PQtransactionStatus(conn._conn)
        if ts == PQTRANS_INTRANS or ts == PQTRANS_INERROR:
            var rolled_back = True
            try:
                _ = conn.execute("ROLLBACK")
            except e:
                conn._rollback_failure_handler(e)
                rolled_back = False
            if not rolled_back:
                _ = conn^
                return
        if (
            pq[].PQstatus(conn._conn) != CONNECTION_OK
            or pq[].PQtransactionStatus(conn._conn) != PQTRANS_IDLE
        ):
            _ = conn^
            return
        if (
            self._max_lifetime_s > 0
            and (monotonic() - opened_at) // 1_000_000_000
            >= self._max_lifetime_s
        ):
            _ = conn^
            return
        if not _is_alive(pq, conn):
            _ = conn^
            return
        self._mut_idle()[].append(_Slot(conn^, opened_at))

    def close(mut self):
        """Close every idle connection and refuse further `acquire()` calls.

        Connections that are out stay usable until their guards are
        destroyed; each of those is then closed rather than returned, so the
        last guard to go takes the last connection with it.
        """
        while len(self._idle) > 0:
            _ = self._idle.pop()
        self._closed[0] = 1

    def size(self) -> Int:
        """Return how many connections the pool holds, idle and borrowed.

        Returns:
            `idle() + borrowed()`, never more than `max_size`.
        """
        return len(self._idle) + self._borrowed[0]

    def idle(self) -> Int:
        """Return how many connections are parked and ready to hand out.

        Returns:
            The number of idle connections.
        """
        return len(self._idle)

    def borrowed(self) -> Int:
        """Return how many guards are currently alive.

        Returns:
            The number of connections that are out.
        """
        return self._borrowed[0]

    def set_rollback_failure_handler(mut self, handler: def(PgError) thin):
        """Install the handler for a failed `ROLLBACK` on this pool's
        connections.

        The handler is applied to the connections the pool opens from now on
        and to the ones sitting idle right now. A connection that is
        **currently borrowed** keeps the handler it was handed out with, and
        so does every `Transaction`, `CopyIn` and `CopyOut` already built from
        it, because those copy the handler when they are created: install this
        before the connections it should cover are handed out.

        Args:
            handler: The function to call with the error a failed `ROLLBACK`
                produced, both the one a `Transaction` sends and the one
                `_release` sends for a guard dropped mid-transaction. It must
                not raise, which the `thin` function type enforces.
        """
        self._handler = handler
        # Indexed rather than `for ref slot in self._idle`: list iteration
        # requires a `Copyable` element and a slot owns a `Connection`.
        for i in range(len(self._idle)):
            self._idle[i].conn.set_rollback_failure_handler(handler)


struct PooledConnection[origin: ImmOrigin](Movable):
    """A connection borrowed from a `Pool`, returned when this is destroyed.

    Built by `Pool.acquire`. It owns the connection for as long as it lives
    and forwards the `Connection` API, so the same code runs on a pooled and
    an unpooled connection. The connection itself is never handed out: there
    is no accessor returning a `Connection` or a reference to one, because
    returning the connection to the pool has to happen exactly once, here.

    Mojo destroys the guard right after its **last use**, which is when the
    connection goes back. A guard whose last use is earlier than the reader
    expects therefore returns its connection earlier; `_ = guard^` marks the
    point where it should still be alive.

    `Movable` but deliberately not `Copyable`: a copy would return the same
    connection twice.

    Parameters:
        origin: Immutable origin of the borrowed `Pool`.
    """

    var _pool: Pointer[Pool, Self.origin]
    """Borrowed pool the connection goes back to."""

    var _conn: Connection
    """The owned connection, moved back into the pool on destruction."""

    var _opened_at: Int
    """When the connection was opened or last reset, for `max_lifetime_s`."""

    def __init__(
        out self,
        pool: Pointer[Pool, Self.origin],
        var conn: Connection,
        opened_at: Int,
    ):
        """Adopt a connection the pool has just checked out.

        Args:
            pool: Pointer to the pool the connection belongs to.
            conn: The connection to own until this value is destroyed.
            opened_at: The `monotonic()` reading of the connection's opening.
        """
        self._pool = pool
        self._conn = conn^
        self._opened_at = opened_at

    def __deinit__(deinit self):
        """Give the connection back to the pool, which decides its fate."""
        self._pool[]._release(self._conn^, self._opened_at)

    def execute(self, var sql: String) raises PgError -> Result:
        """Delegate to `Connection.execute(sql)`.

        Args:
            sql: One or more statements separated by semicolons.

        Returns:
            The result of the last statement.

        Raises:
            PgError: Exactly what `Connection.execute` raises.
        """
        return self._conn.execute(sql^)

    def execute(
        self,
        var sql: String,
        params: List[Param],
        result_format: ResultFormat = ResultFormat.TEXT,
    ) raises PgError -> Result:
        """Delegate to `Connection.execute(sql, params, result_format)`.

        Args:
            sql: Exactly one statement, using `$1`..`$n` placeholders.
            params: The values to bind, `params[0]` for `$1`.
            result_format: Whether the server sends text or binary.

        Returns:
            The result of the statement.

        Raises:
            PgError: Exactly what `Connection.execute` raises.
        """
        return self._conn.execute(sql^, params, result_format)

    def escape_literal(self, var s: String) raises PgError -> String:
        """Delegate to `Connection.escape_literal`.

        Args:
            s: The string to quote.

        Returns:
            The quoted literal, including its surrounding quotes.

        Raises:
            PgError: Exactly what `Connection.escape_literal` raises.
        """
        return self._conn.escape_literal(s^)

    def escape_identifier(self, var s: String) raises PgError -> String:
        """Delegate to `Connection.escape_identifier`.

        Args:
            s: The identifier to quote.

        Returns:
            The quoted identifier, including its surrounding quotes.

        Raises:
            PgError: Exactly what `Connection.escape_identifier` raises.
        """
        return self._conn.escape_identifier(s^)

    def server_version(self) -> Int:
        """Delegate to `Connection.server_version`.

        Returns:
            The server version as a single integer, 0 when unknown.
        """
        return self._conn.server_version()

    def status(self) -> Int:
        """Delegate to `Connection.status`.

        Returns:
            `CONNECTION_OK` while the connection is usable, else
            `CONNECTION_BAD`.
        """
        return self._conn.status()

    def transaction_status(self) -> Int:
        """Delegate to `Connection.transaction_status`.

        Returns:
            One of the `PQTRANS_*` constants as an `Int`.
        """
        return self._conn.transaction_status()

    def _conn_ptr(ref self) -> Pointer[Connection, origin_of(self)]:
        """Return a pointer at the owned connection in the guard's origin.

        The connection lives inside the guard, so the guard's own origin is
        the right lifetime for a pointer at it; the field-path origin
        `origin_of(self._conn)` is not convertible to it, hence the rebind.
        This is what lets a `Transaction`, `PreparedStatement`, `CopyIn` or
        `CopyOut` be parameterised on the guard rather than on a nested origin
        no signature can spell.

        Returns:
            A pointer at `_conn` carrying this guard's origin.
        """
        return Pointer[Connection, origin_of(self)](
            unsafe_from_address=Int(Pointer(to=self._conn))
        )

    def transaction(ref self) raises PgError -> Transaction[origin_of(self)]:
        """Send `BEGIN` on the borrowed connection and return its block.

        The transaction is bound to the **guard's** origin, so it cannot
        outlive the checkout: the connection cannot go back to the pool while
        a transaction on it is still alive. A transaction destroyed without
        `commit()` sends `ROLLBACK` itself, before the guard returns the
        connection.

        Returns:
            A `Transaction` bound to this guard's origin.

        Raises:
            PgError: Exactly what `Connection.transaction` raises.
        """
        self._conn._transaction_parts()
        return Transaction[origin_of(self)](
            self._conn_ptr(), self._conn._rollback_failure_handler
        )

    def prepare(
        ref self,
        var sql: String,
        param_types: List[UInt32] = List[UInt32](),
    ) raises PgError -> PreparedStatement[origin_of(self)]:
        """Prepare `sql` on the borrowed connection.

        Statement names are numbered per connection and the counter travels
        with it, so a reused connection issues the next number rather than one
        the server already holds.

        Args:
            sql: Exactly one statement, using `$1`..`$n` placeholders.
            param_types: Optional type OID hints, `param_types[0]` for `$1`.

        Returns:
            A `PreparedStatement` bound to this guard's origin.

        Raises:
            PgError: Exactly what `Connection.prepare` raises.
        """
        var types = List[UInt32]()
        var name = self._conn._prepare_parts(sql^, param_types, types)
        return PreparedStatement[origin_of(self)](
            self._conn_ptr(), name^, types^
        )

    def copy_in(
        ref self, var sql: String
    ) raises PgError -> CopyIn[origin_of(self)]:
        """Start `sql` as a `COPY ... FROM STDIN` on the borrowed connection.

        The stream is bound to the guard's origin, so it is destroyed before
        the connection goes back: a stream that was never `finish`ed cancels
        itself first, which leaves the connection idle and reusable.

        Args:
            sql: A `COPY ... FROM STDIN` statement.

        Returns:
            A `CopyIn` bound to this guard's origin.

        Raises:
            PgError: Exactly what `Connection.copy_in` raises.
        """
        self._conn._copy_in_parts(sql^)
        return CopyIn[origin_of(self)](
            self._conn_ptr(), self._conn._rollback_failure_handler
        )

    def copy_out(
        ref self, var sql: String
    ) raises PgError -> CopyOut[origin_of(self)]:
        """Start `sql` as a `COPY ... TO STDOUT` on the borrowed connection.

        The stream is bound to the guard's origin, with the same consequence
        `copy_in` documents: an unfinished stream is drained before the
        connection goes back.

        Args:
            sql: A `COPY ... TO STDOUT` statement.

        Returns:
            A `CopyOut` bound to this guard's origin.

        Raises:
            PgError: Exactly what `Connection.copy_out` raises.
        """
        self._conn._copy_out_parts(sql^)
        return CopyOut[origin_of(self)](
            self._conn_ptr(), self._conn._rollback_failure_handler
        )
