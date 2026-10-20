"""Tests for `pq.pool`: `Pool` and the `PooledConnection` guard.

Fixes the observable contract of the connection pool against a live server.
`Pool.open` is a `@staticmethod` over a conninfo string or a
`Dict[String, String]`, `acquire` hands back a `PooledConnection` guard whose
destructor returns the connection, and every borrowed connection either comes
back clean or is thrown away. There is no explicit `release`: `_ = guard^` is
how a test gives one back, which is also how a caller does.

Seven properties get their own tests because they are the ones that break
quietly.

First, the size arithmetic. `size()` is always `idle() + borrowed()`, a pool
at `max_size` with nothing idle refuses to lend (`PgErrorKind.USAGE`,
`pool exhausted: all N connections are borrowed`), and `min_size` connections
exist on the server before the first `acquire`. Two guards alive at once sit
on two different backends, which `pg_backend_pid()` proves.

Second, argument checking happens *before* anything is dialled. The three
messages are exact, and `pg_stat_activity` is unchanged across all four
rejections -- a pool that validated after connecting would leave a backend
behind.

Third, a connection comes back idle or not at all. A `Transaction` dropped
uncommitted rolls itself back; a raw `execute("BEGIN")` left open is rolled
back by the pool's own release path; a connection parked in
`PQTRANS_ACTIVE` is discarded instead. The first two keep `size()` and the
backend PID; the third drops both.

Fourth, a dead backend is noticed. A terminated connection that the borrower
*used* fails with `PgErrorKind.CONNECTION` and is discarded on return. One
that was never used after the kill is discarded too, as long as the server's
close has had time to arrive -- that is what the `pg_sleep(0.05)` is for. With
no wait at all, libpq still believes the socket is fine, the connection is
pooled, and the *next* borrower's first `execute` is the one that raises; its
return then discards it. Both outcomes are covered, because that gap is
accepted rather than fixed.

Fifth, a connection terminated while idle is revived rather than lost:
`acquire` fails its health check, calls `Connection.reset()`, and hands back a
live connection on a new PID with the session settings re-sent, which
`SHOW DateStyle` reports as `ISO, YMD`.

Sixth, `max_lifetime_s` retires a connection on return and only then. At
`max_lifetime_s=1` a connection held across `pg_sleep(1.1)` is thrown away and
the next `acquire` opens a new backend; at the default `0` the same wait
changes nothing and the same PID comes back.

Seventh, `Connection` state that must survive pooling does: `_stmt_counter`
rides along with the connection, so a reused connection names its next
prepared statement `pq_stmt_2` rather than colliding with the `pq_stmt_1` an
aborted transaction left on the server (`42P05`).

All eleven forwarded methods are checked through a guard in one test, because
what matters about them is that they exist and reach the connection, not what
they do -- that is `tests/test_connection.mojo`'s job.

How connections are counted: every pool in this file adds
`application_name=pq_test_pool` to its conninfo, and the counting happens from
a separate `Connection` that carries no `application_name`, with
`SELECT pg_sleep(0.05)` immediately before the count so the server has
registered the disconnections. The count is retried a few times before it is
asserted, because the backend's exit is asynchronous.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI), falling back to the local container. An unreachable
server fails these tests; it never skips them. Every test must pass against
both PG14 and PG17, so nothing here depends on version-specific wording: only
SQLSTATEs, transaction statuses, our own messages and values are asserted.

Each test opens its own `Pool` and its own observer connection, and the tables
it makes are `CREATE TEMP TABLE`s inside the pooled session, so two test
processes -- or the two server versions -- never collide on a name. The table
names are unique to this file (`pq_pool_*`). The one test that installs a
rollback-failure handler installs it on its own pool, which keeps the handler
out of the others.
"""

from std.os import getenv, setenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pq._ffi.types import (
    CONNECTION_OK,
    CStr,
    PQTRANS_ACTIVE,
    PQTRANS_IDLE,
    PQTRANS_INTRANS,
)
from pq.connection import Connection
from pq.copy import CopyIn, CopyOut
from pq.errors import PgError, PgErrorKind
from pq.params import Param
from pq.pool import Pool, PooledConnection
from pq.prepared import PreparedStatement
from pq.result import Result, ResultFormat, Row
from pq.transaction import Transaction

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

# --- counting the pool's own backends ----------------------------------------

comptime POOL_APPLICATION_NAME: StaticString = "pq_test_pool"
"""The `application_name` every pool in this file tags its backends with.

`pg_stat_activity` is the only place a test can see how many connections the
pool really holds, and `application_name` is the only field a client can set
that makes its own backends tellable apart from everyone else's.
"""

comptime COUNT_TAGGED: StaticString = (
    "SELECT count(*) FROM pg_stat_activity WHERE datname ="
    " current_database() AND application_name = 'pq_test_pool'"
)
"""Counts the backends of this file's pools, from outside any of them."""

comptime SETTLE_SQL: StaticString = "SELECT pg_sleep(0.05)"
"""Run immediately before a count, and after a kill.

A backend's exit is asynchronous: `PQfinish` and `pg_terminate_backend` both
return before the row leaves `pg_stat_activity`, and libpq only learns a
socket died once something arrives on it.
"""

comptime COUNT_ATTEMPTS: Int = 20
"""How many times a count may be retried before it is asserted.

Twenty attempts is a second of `pg_sleep(0.05)`, which is far longer than a
local backend takes to disappear; the loop exists so a slow machine fails on
the assertion's own message rather than on a race.
"""

# --- the messages `Pool` promises --------------------------------------------

comptime POOL_CLOSED: StaticString = "pool is closed"
"""What `acquire` says after `close()`."""

comptime EXHAUSTED_TWO: StaticString = (
    "pool exhausted: all 2 connections are borrowed"
)
"""What `acquire` says when both of a two-connection pool are out."""

comptime MAX_SIZE_ZERO: StaticString = "max_size must be positive (got 0)"
"""What `open` says about `max_size=0`."""

comptime MAX_SIZE_NEGATIVE: StaticString = "max_size must be positive (got -1)"
"""What `open` says about `max_size=-1`."""

comptime MIN_SIZE_TOO_BIG: StaticString = (
    "min_size must be between 0 and max_size (got 3)"
)
"""What `open` says about `min_size=3` with `max_size=2`."""

comptime LIFETIME_NEGATIVE: StaticString = (
    "max_lifetime_s must not be negative (got -1)"
)
"""What `open` says about `max_lifetime_s=-1`."""

# --- SQL the tests run -------------------------------------------------------

comptime SELECT_ONE: StaticString = "SELECT 1"
"""The cheapest round trip that proves a connection is alive."""

comptime BACKEND_PID: StaticString = "SELECT pg_backend_pid()"
"""Identifies the backend a guard is holding, which is how reuse is seen."""

comptime SHOW_DATESTYLE: StaticString = "SHOW DateStyle"
"""Reads back the GUC `Connection.open` and `Connection.reset()` pin."""

comptime DATESTYLE: StaticString = "ISO, YMD"
"""What a connection with the session setup applied reports."""

comptime DIVIDE_BY_ZERO: StaticString = "SELECT 1/0"
"""Aborts the open transaction, which is what strands a prepared statement."""

comptime DIVISION_SQLSTATE: StaticString = "22012"
"""`division_by_zero`."""

comptime MISSING_TABLE_SQLSTATE: StaticString = "42P01"
"""`undefined_table`: what a rolled-back `CREATE TEMP TABLE` leaves behind."""

comptime SELECT_PARAM_INT4: StaticString = "SELECT $1::int4"
"""The statement `prepare` is called with; two of them get named."""

comptime SELECT_PARAM_INT8: StaticString = "SELECT $1::int8"
"""The statement the forwarding test prepares."""

comptime FIRST_STMT_NAME: StaticString = "pq_stmt_1"
"""The name a fresh connection gives its first prepared statement."""

comptime SECOND_STMT_NAME: StaticString = "pq_stmt_2"
"""The name a *reused* connection must give its next one."""

comptime PG14: Int = 140000
"""Oldest server version this suite runs against."""

# --- the tables, one per test that needs one ---------------------------------

comptime CREATE_TX_TABLE: StaticString = "CREATE TEMP TABLE pq_pool_tx(x int4)"
"""Made inside a `Transaction` that is dropped, so it must not survive."""

comptime SELECT_TX_TABLE: StaticString = "SELECT x FROM pq_pool_tx"
"""Asks for the table the rollback removed."""

comptime CREATE_RAW_TABLE: StaticString = (
    "CREATE TEMP TABLE pq_pool_raw(x int4)"
)
"""Made inside a raw `BEGIN`, so the pool's own ROLLBACK must remove it."""

comptime SELECT_RAW_TABLE: StaticString = "SELECT x FROM pq_pool_raw"
"""Asks for the table the pool's ROLLBACK removed."""

comptime CREATE_COPY_TABLE: StaticString = (
    "CREATE TEMP TABLE pq_pool_copy(x int4, y int4)"
)
"""Target of the COPY that is never finished; created outside it, so it stays.
"""

comptime COPY_COPY_TABLE_IN: StaticString = "COPY pq_pool_copy FROM STDIN"
"""The stream the test abandons."""

comptime COUNT_COPY_TABLE: StaticString = "SELECT count(*) FROM pq_pool_copy"
"""Must be zero: an unfinished COPY stores nothing."""

comptime CREATE_ACTIVE_TABLE: StaticString = (
    "CREATE TEMP TABLE pq_pool_active(x int4)"
)
"""Target of the raw COPY that parks the connection in `PQTRANS_ACTIVE`."""

comptime COPY_ACTIVE_TABLE_IN: StaticString = "COPY pq_pool_active FROM STDIN"
"""Sent with `PQexec` directly, so no `CopyIn` exists to drain it."""

comptime CREATE_FWD_TABLE: StaticString = (
    "CREATE TEMP TABLE pq_pool_fwd(x int4, y int4)"
)
"""Target of the forwarded `copy_in` and source of the forwarded `copy_out`."""

comptime COPY_FWD_IN: StaticString = "COPY pq_pool_fwd FROM STDIN"
"""The statement the guard's `copy_in` accepts."""

comptime COPY_FWD_OUT: StaticString = "COPY pq_pool_fwd TO STDOUT"
"""The statement the guard's `copy_out` accepts."""

comptime FWD_ROW: StaticString = "1\t2\n"
"""The one row that goes in and comes back out, four bytes of it."""

comptime FWD_ROW_BYTES: Int = 4
"""Byte length of `FWD_ROW`, which `copy_out` must hand back unchanged."""

# --- the lifetime waits ------------------------------------------------------

comptime LIFETIME_SECONDS: Int = 1
"""`max_lifetime_s` of the pool that must retire its connection."""

comptime SLEEP_PAST_LIFETIME: StaticString = "SELECT pg_sleep(1.1)"
"""Held across this, a connection is older than `LIFETIME_SECONDS`.

1.1 rather than 1.0 because the comparison is `>=` on whole seconds and the
clock the pool reads is not the clock the sleep uses.
"""

# --- escaping ----------------------------------------------------------------

comptime ESCAPE_INPUT: StaticString = "a'b"
"""A value with the one character `escape_literal` has to double."""

comptime ESCAPE_LITERAL_OUTPUT: StaticString = "'a''b'"
"""What the server's `PQescapeLiteral` makes of `ESCAPE_INPUT`."""

comptime ESCAPE_IDENTIFIER_INPUT: StaticString = "x y"
"""An identifier that has to be quoted because of the space."""

comptime ESCAPE_IDENTIFIER_OUTPUT: StaticString = '"x y"'
"""What the server's `PQescapeIdentifier` makes of it."""

# --- the rollback-failure handler --------------------------------------------

comptime HANDLER_CALLS_VAR: StaticString = "PQ_TEST_POOL_ROLLBACK_CALLS"
"""Environment variable the counting handler records its calls in.

Mojo 1.1.0 has no module-level mutable variable -- a top-level `var` is
"global variables are not supported" -- and a `def(PgError) thin` handler
captures nothing, so the handler has no way to hand an observation back by
value. Writing to the environment is the smallest channel that survives the
destructor it is called from, exactly as in `tests/test_transaction.mojo`, and
one character per call makes "never" and "exactly once" both readable.

The handler must not `print`: the 6/6 verification stage counts the strings
`implicit ROLLBACK failed`, `WARNING:` and `warning:` in the test output.
"""

comptime CONNECTION_MARK: StaticString = "c"
"""One of these per handler call whose error was `CONNECTION`."""


# --- helpers -----------------------------------------------------------------
#
# A `TestSuite` test only declares `raises` (plain `Error`), and `PgError` does
# not implicitly convert to `Error`, so a `raises PgError` API cannot be called
# straight from a test. These wrappers translate in both directions: success
# paths re-raise as `Error`, failure paths hand the `PgError` back for
# inspection. Helpers are per file by convention; nothing here is shared with
# `test_copy.mojo`.
#
# `Pool.close`, `Pool.size`, `Pool.idle`, `Pool.borrowed` and
# `Pool.set_rollback_failure_handler` do not raise, so they are called straight
# from the tests and have no wrapper here.


def _conninfo() -> String:
    """Return the conninfo of the server under test.

    Returns:
        `PQ_TEST_CONNINFO` when set and non-empty, else `DEFAULT_CONNINFO`.
    """
    var value = getenv("PQ_TEST_CONNINFO")
    return value if value != "" else String(DEFAULT_CONNINFO)


def _pool_conninfo() -> String:
    """Return the conninfo every pool in this file opens with.

    The `application_name` goes last, so it wins over one the environment
    might already have set: libpq takes the final occurrence of a keyword.

    Returns:
        The server's conninfo plus `application_name=pq_test_pool`.
    """
    return _conninfo() + " application_name=" + String(POOL_APPLICATION_NAME)


def _pool_params() raises -> Dict[String, String]:
    """Return the pool's conninfo as the `Dict` the other overload takes.

    Tokens are separated by spaces and each token is cut at its *first* `=`, so
    a value containing `=` survives the round trip. `application_name` is put
    in as a key like any other, which is what the counting depends on.

    Returns:
        The conninfo as a `Dict`, suitable for `Pool.open(Dict, ...)`.
    """
    var params = Dict[String, String]()
    var tokens = _conninfo().split(" ")
    for token in tokens:
        var pair = String(token).split("=")
        if len(pair) < 2:
            continue
        var value = String(pair[1])
        for i in range(2, len(pair)):
            value += "="
            value += String(pair[i])
        params[String(pair[0])] = value
    params[String("application_name")] = String(POOL_APPLICATION_NAME)
    return params^


def _connect(var conninfo: String) raises -> Connection:
    """Open a plain connection, outside any pool.

    Args:
        conninfo: A libpq `key=value ...` conninfo string.

    Returns:
        The open connection.

    Raises:
        Error: If `Connection.open` raised a `PgError`.
    """
    try:
        return Connection.open(conninfo^)
    except e:
        raise Error(String(e))


def _execute(conn: Connection, var sql: String) raises -> Result:
    """Run `sql` on a plain connection without parameters.

    Args:
        conn: An open connection.
        sql: The statement to run.

    Returns:
        The result of the statement.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    try:
        return conn.execute(sql^)
    except e:
        raise Error(String(e))


def _row(result: Result, i: Int) raises -> Row[origin_of(result)]:
    """Return row `i` of `result`.

    Args:
        result: The result to index.
        i: Zero-based row index.

    Returns:
        The row at that index.

    Raises:
        Error: If `result[i]` raised a `PgError`.
    """
    try:
        return result[i]
    except e:
        raise Error(String(e))


def _get[
    origin: ImmOrigin, //, T: Copyable & Deinitable
](row: Row[origin], col: Int) raises -> T:
    """Read column `col` of `row` as `T`.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.
        T: The Mojo type requested from `Row.get`.

    Args:
        row: The row to read.
        col: Zero-based column index.

    Returns:
        The decoded value.

    Raises:
        Error: If `Row.get` raised a `PgError`.
    """
    try:
        return row.get[T](col)
    except e:
        raise Error(String(e))


def _column_format(result: Result, i: Int) raises -> ResultFormat:
    """Return the wire format column `i` of `result` came back in.

    Args:
        result: The result to ask.
        i: Zero-based column index.

    Returns:
        `ResultFormat.TEXT` or `ResultFormat.BINARY`.

    Raises:
        Error: If `column_format` raised a `PgError`.
    """
    try:
        return result.column_format(i)
    except e:
        raise Error(String(e))


def _count(conn: Connection, var sql: String) raises -> Int:
    """Run a one-column `count(*)` query on a plain connection.

    Args:
        conn: The connection to count from.
        sql: A `SELECT count(*) ...` statement.

    Returns:
        The counted number of rows.

    Raises:
        Error: If the query or the decoding raised a `PgError`.
    """
    var result = _execute(conn, sql^)
    var count = _get[Int64](_row(result, 0), 0)
    _ = result^
    return Int(count)


def _settle(conn: Connection) raises:
    """Sleep 50 ms on the server, which is where the waiting belongs.

    Args:
        conn: Any open connection; the sleep is the server's, not ours.

    Raises:
        Error: If the statement raised a `PgError`.
    """
    var slept = _execute(conn, String(SETTLE_SQL))
    _ = slept^


def _tagged_connections(observer: Connection) raises -> Int:
    """Count the backends tagged `pq_test_pool`, after a short settle.

    Args:
        observer: A connection that is *not* tagged, so it never counts
          itself.

    Returns:
        How many of this file's pooled backends the server still has.

    Raises:
        Error: If either statement raised a `PgError`.
    """
    _settle(observer)
    return _count(observer, String(COUNT_TAGGED))


def _assert_tagged(observer: Connection, expected: Int) raises:
    """Assert the server holds exactly `expected` tagged backends.

    The count is retried up to `COUNT_ATTEMPTS` times because a backend's exit
    is asynchronous: the assertion is about the state the pool settles into,
    not about how fast the server gets there.

    Args:
        observer: An untagged connection to count from.
        expected: How many tagged backends there must be.

    Raises:
        Error: If the count never reaches `expected`.
    """
    var count = _tagged_connections(observer)
    for _ in range(COUNT_ATTEMPTS):
        if count == expected:
            break
        count = _tagged_connections(observer)
    assert_equal(count, expected, "backends tagged pq_test_pool")


def _terminate(killer: Connection, pid: Int32) raises:
    """Kill backend `pid` from another connection, then let the close arrive.

    The kill has to come from a second connection: a backend that terminates
    itself makes the terminating statement its own failure.

    Args:
        killer: A connection other than the victim.
        pid: The victim's `pg_backend_pid()`.

    Raises:
        Error: If the statement raised a `PgError`.
    """
    var killed = _execute(
        killer, String("SELECT pg_terminate_backend(", pid, ")")
    )
    _ = killed^


def _open_pool(
    var conninfo: String,
    max_size: Int,
    min_size: Int = 0,
    max_lifetime_s: Int = 0,
) raises -> Pool:
    """Open a pool over a conninfo string.

    Args:
        conninfo: A libpq `key=value ...` conninfo string.
        max_size: Most connections the pool may ever hold.
        min_size: How many to open before returning.
        max_lifetime_s: Seconds after which a returned connection is retired,
          or 0 for never.

    Returns:
        The open pool.

    Raises:
        Error: If `Pool.open` raised a `PgError`.
    """
    try:
        return Pool.open(
            conninfo^,
            max_size,
            min_size=min_size,
            max_lifetime_s=max_lifetime_s,
        )
    except e:
        raise Error(String(e))


def _open_pool_error(
    var conninfo: String,
    max_size: Int,
    min_size: Int = 0,
    max_lifetime_s: Int = 0,
) raises -> PgError:
    """Return the `PgError` raised by `Pool.open`.

    Args:
        conninfo: A libpq `key=value ...` conninfo string.
        max_size: Most connections the pool may ever hold.
        min_size: How many to open before returning.
        max_lifetime_s: Seconds after which a returned connection is retired.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `Pool.open` returned a pool instead of raising.
    """
    try:
        var pool = Pool.open(
            conninfo^,
            max_size,
            min_size=min_size,
            max_lifetime_s=max_lifetime_s,
        )
        _ = pool^
    except e:
        return e.copy()
    raise Error("expected a PgError from Pool.open(conninfo, ...)")


def _open_pool_params(
    params: Dict[String, String], max_size: Int, min_size: Int = 0
) raises -> Pool:
    """Open a pool over keyword/value pairs.

    Args:
        params: The conninfo as a `Dict`.
        max_size: Most connections the pool may ever hold.
        min_size: How many to open before returning.

    Returns:
        The open pool.

    Raises:
        Error: If `Pool.open` raised a `PgError`.
    """
    try:
        return Pool.open(params, max_size, min_size=min_size)
    except e:
        raise Error(String(e))


def _acquire(pool: Pool) raises -> PooledConnection[origin_of(pool)]:
    """Borrow a connection from `pool`.

    The guard is a view onto the pool: its `origin` parameter ties it to
    `pool`, so the compiler keeps the pool alive for as long as the guard is
    reachable. Dropping the guard -- `_ = guard^` -- is what returns the
    connection; there is no `release` method.

    Args:
        pool: An open pool.

    Returns:
        The guard holding the borrowed connection.

    Raises:
        Error: If `acquire` raised a `PgError`.
    """
    try:
        return pool.acquire()
    except e:
        raise Error(String(e))


def _acquire_error(pool: Pool) raises -> PgError:
    """Return the `PgError` raised by `pool.acquire()`.

    Args:
        pool: A pool that must refuse to lend.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `acquire` returned a guard instead of raising.
    """
    try:
        var guard = pool.acquire()
        _ = guard^
    except e:
        return e.copy()
    raise Error("expected a PgError from Pool.acquire()")


def _guard_execute[
    origin: ImmOrigin, //
](guard: PooledConnection[origin], var sql: String) raises -> Result:
    """Run `sql` through the guard's forwarded `execute`.

    Parameters:
        origin: Origin of the `Pool` the guard views; inferred.

    Args:
        guard: The borrowed connection.
        sql: The statement to run.

    Returns:
        The result of the statement.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    try:
        return guard.execute(sql^)
    except e:
        raise Error(String(e))


def _guard_run[
    origin: ImmOrigin, //
](guard: PooledConnection[origin], var sql: String) raises:
    """Run `sql` through the guard and throw the result away.

    Parameters:
        origin: Origin of the `Pool` the guard views; inferred.

    Args:
        guard: The borrowed connection.
        sql: A statement whose result carries nothing the caller wants.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    var result = _guard_execute(guard, sql^)
    _ = result^


def _guard_execute_error[
    origin: ImmOrigin, //
](guard: PooledConnection[origin], var sql: String) raises -> PgError:
    """Return the `PgError` raised by the guard's `execute`.

    Parameters:
        origin: Origin of the `Pool` the guard views; inferred.

    Args:
        guard: The borrowed connection.
        sql: A statement that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `execute` returned a result instead of raising.
    """
    try:
        var result = guard.execute(sql^)
        _ = result^
    except e:
        return e.copy()
    raise Error("expected a PgError from PooledConnection.execute(sql)")


def _guard_execute_params[
    origin: ImmOrigin, //
](
    guard: PooledConnection[origin],
    var sql: String,
    params: List[Param],
    result_format: ResultFormat,
) raises -> Result:
    """Run a parameterised statement through the guard.

    Parameters:
        origin: Origin of the `Pool` the guard views; inferred.

    Args:
        guard: The borrowed connection.
        sql: The statement to run, with `$1`..`$n` placeholders.
        params: The values bound to `$1`, `$2`, ... in order.
        result_format: `TEXT` or `BINARY`, forwarded unchanged.

    Returns:
        The result of the statement.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    try:
        # `params` is borrowed by `execute`, so it is passed, never moved.
        return guard.execute(sql^, params, result_format=result_format)
    except e:
        raise Error(String(e))


def _guard_escape_literal[
    origin: ImmOrigin, //
](guard: PooledConnection[origin], var s: String) raises -> String:
    """Quote `s` as a literal through the guard.

    Parameters:
        origin: Origin of the `Pool` the guard views; inferred.

    Args:
        guard: The borrowed connection.
        s: The value to quote.

    Returns:
        The quoted literal, apostrophes included.

    Raises:
        Error: If `escape_literal` raised a `PgError`.
    """
    try:
        return guard.escape_literal(s^)
    except e:
        raise Error(String(e))


def _guard_escape_identifier[
    origin: ImmOrigin, //
](guard: PooledConnection[origin], var s: String) raises -> String:
    """Quote `s` as an identifier through the guard.

    Parameters:
        origin: Origin of the `Pool` the guard views; inferred.

    Args:
        guard: The borrowed connection.
        s: The identifier to quote.

    Returns:
        The quoted identifier, double quotes included.

    Raises:
        Error: If `escape_identifier` raised a `PgError`.
    """
    try:
        return guard.escape_identifier(s^)
    except e:
        raise Error(String(e))


def _guard_transaction[
    origin: ImmOrigin, //
](guard: PooledConnection[origin]) raises -> Transaction[origin_of(guard)]:
    """Begin a transaction block through the guard.

    The block carries the *guard's* origin, not the pool's and not the
    connection's: that is what keeps a borrowed connection alive for as long
    as a block over it is reachable.

    Parameters:
        origin: Origin of the `Pool` the guard views; inferred.

    Args:
        guard: The borrowed connection.

    Returns:
        The open transaction block, with its `BEGIN` already sent.

    Raises:
        Error: If `transaction` raised a `PgError`.
    """
    try:
        return guard.transaction()
    except e:
        raise Error(String(e))


def _guard_prepare[
    origin: ImmOrigin, //
](guard: PooledConnection[origin], var sql: String) raises -> PreparedStatement[
    origin_of(guard)
]:
    """Prepare `sql` through the guard.

    Parameters:
        origin: Origin of the `Pool` the guard views; inferred.

    Args:
        guard: The borrowed connection.
        sql: Exactly one statement, using `$1`..`$n` placeholders.

    Returns:
        The prepared statement, bound to the guard's origin.

    Raises:
        Error: If `prepare` raised a `PgError`.
    """
    try:
        return guard.prepare(sql^)
    except e:
        raise Error(String(e))


def _guard_copy_in[
    origin: ImmOrigin, //
](guard: PooledConnection[origin], var sql: String) raises -> CopyIn[
    origin_of(guard)
]:
    """Start `sql` as a COPY IN through the guard.

    Parameters:
        origin: Origin of the `Pool` the guard views; inferred.

    Args:
        guard: The borrowed connection.
        sql: A `COPY ... FROM STDIN` statement.

    Returns:
        The open input stream.

    Raises:
        Error: If `copy_in` raised a `PgError`.
    """
    try:
        return guard.copy_in(sql^)
    except e:
        raise Error(String(e))


def _guard_copy_out[
    origin: ImmOrigin, //
](guard: PooledConnection[origin], var sql: String) raises -> CopyOut[
    origin_of(guard)
]:
    """Start `sql` as a COPY OUT through the guard.

    Parameters:
        origin: Origin of the `Pool` the guard views; inferred.

    Args:
        guard: The borrowed connection.
        sql: A `COPY ... TO STDOUT` statement.

    Returns:
        The open output stream.

    Raises:
        Error: If `copy_out` raised a `PgError`.
    """
    try:
        return guard.copy_out(sql^)
    except e:
        raise Error(String(e))


def _tx_execute[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var sql: String) raises -> Result:
    """Run `sql` inside `tx` without parameters.

    Parameters:
        origin: Origin of the value the block views; inferred.

    Args:
        tx: The open transaction block.
        sql: The statement to run.

    Returns:
        The result of the statement.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    try:
        return tx.execute(sql^)
    except e:
        raise Error(String(e))


def _tx_run[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var sql: String) raises:
    """Run `sql` inside `tx` and throw the result away.

    Parameters:
        origin: Origin of the value the block views; inferred.

    Args:
        tx: The open transaction block.
        sql: A statement whose result carries nothing the caller wants.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    var result = _tx_execute(tx, sql^)
    _ = result^


def _tx_commit[origin: ImmOrigin, //](mut tx: Transaction[origin]) raises:
    """Commit `tx`.

    Parameters:
        origin: Origin of the value the block views; inferred.

    Args:
        tx: The open transaction block.

    Raises:
        Error: If `commit` raised a `PgError`.
    """
    try:
        tx.commit()
    except e:
        raise Error(String(e))


def _stmt_execute[
    origin: ImmOrigin, //
](stmt: PreparedStatement[origin], params: List[Param]) raises -> Result:
    """Execute `stmt` with bound parameters.

    Parameters:
        origin: Origin of the value the statement views; inferred.

    Args:
        stmt: The prepared statement to run.
        params: The values bound to `$1`, `$2`, ... in order.

    Returns:
        The result of the statement.

    Raises:
        Error: If `PreparedStatement.execute` raised a `PgError`.
    """
    try:
        return stmt.execute(params)
    except e:
        raise Error(String(e))


def _copy_write[
    origin: ImmOrigin, //
](mut stream: CopyIn[origin], var s: String) raises:
    """Write the UTF-8 bytes of `s` to `stream`.

    Parameters:
        origin: Origin of the value the stream views; inferred.

    Args:
        stream: The open input stream.
        s: One or more complete rows in the COPY format of the command.

    Raises:
        Error: If `write` raised a `PgError`.
    """
    try:
        stream.write(s)
    except e:
        raise Error(String(e))


def _copy_finish[
    origin: ImmOrigin, //
](mut stream: CopyIn[origin]) raises -> Result:
    """End `stream` normally and return the COPY's own result.

    Parameters:
        origin: Origin of the value the stream views; inferred.

    Args:
        stream: The open input stream.

    Returns:
        The result of the `COPY`; `affected_rows()` is the row count.

    Raises:
        Error: If `finish` raised a `PgError`.
    """
    try:
        return stream.finish()
    except e:
        raise Error(String(e))


def _copy_next[
    origin: ImmOrigin, //
](mut stream: CopyOut[origin]) raises -> Optional[List[UInt8]]:
    """Return the next row of `stream`, or `None` at its end.

    Parameters:
        origin: Origin of the value the stream views; inferred.

    Args:
        stream: The open output stream.

    Returns:
        The next row's bytes, or `None` once the server has sent everything.

    Raises:
        Error: If `next` raised a `PgError`.
    """
    try:
        return stream.next()
    except e:
        raise Error(String(e))


# --- white-box helpers -------------------------------------------------------
#
# `PooledConnection._conn` and `Connection._pq` / `._conn` are reachable from a
# test, which is the only way to put a borrowed connection into a state no
# public method can reach. `tests/test_copy.mojo` reaches for `PQsocket` the
# same way.


def _backend_pid[
    origin: ImmOrigin, //
](guard: PooledConnection[origin]) raises -> Int32:
    """Return the PID of the backend the guard is holding.

    Two guards on different backends and one guard on a reused backend are
    only distinguishable by this number, so every reuse assertion in this file
    goes through it.

    Parameters:
        origin: Origin of the `Pool` the guard views; inferred.

    Args:
        guard: The borrowed connection.

    Returns:
        The server's `pg_backend_pid()`.

    Raises:
        Error: If the query or the decoding raised a `PgError`.
    """
    var result = _guard_execute(guard, String(BACKEND_PID))
    var pid = _get[Int32](_row(result, 0), 0)
    _ = result^
    return pid


def _guard_string[
    origin: ImmOrigin, //
](guard: PooledConnection[origin], var sql: String) raises -> String:
    """Return column 0 of the first row of `sql` as a `String`.

    Parameters:
        origin: Origin of the `Pool` the guard views; inferred.

    Args:
        guard: The borrowed connection.
        sql: A statement whose first column is text.

    Returns:
        An owned copy of the cell's text.

    Raises:
        Error: If the query or the decoding raised a `PgError`.
    """
    var result = _guard_execute(guard, sql^)
    var text = _get[String](_row(result, 0), 0)
    _ = result^
    return text^


def _guard_count[
    origin: ImmOrigin, //
](guard: PooledConnection[origin], var sql: String) raises -> Int:
    """Run a one-column `count(*)` query through the guard.

    Parameters:
        origin: Origin of the `Pool` the guard views; inferred.

    Args:
        guard: The borrowed connection.
        sql: A `SELECT count(*) ...` statement.

    Returns:
        The counted number of rows.

    Raises:
        Error: If the query or the decoding raised a `PgError`.
    """
    var result = _guard_execute(guard, sql^)
    var count = _get[Int64](_row(result, 0), 0)
    _ = result^
    return Int(count)


def _send_raw[
    origin: ImmOrigin, //
](guard: PooledConnection[origin], var sql: String):
    """Send `sql` with `PQexec` and clear the result, bypassing `Connection`.

    This is how a borrowed connection is parked in `PQTRANS_ACTIVE`: a
    `COPY ... FROM STDIN` sent this way leaves libpq in `PGRES_COPY_IN` with
    no `CopyIn` in existence to drain it, which no public method can produce.
    The result is cleared rather than adopted, so nothing here can raise.

    Parameters:
        origin: Origin of the `Pool` the guard views; inferred.

    Args:
        guard: The borrowed connection.
        sql: The statement to send.
    """
    var res = guard._conn._pq[].PQexec(
        guard._conn._conn,
        CStr(unsafe_from_address=Int(sql.as_c_string_span().ptr())),
    )
    guard._conn._pq[].PQclear(res)
    _ = sql^


# --- rollback-failure handler ------------------------------------------------
#
# A non-capturing top-level function, which is what the `thin` handler type
# asks for. It appends one character per call to an environment variable: an
# empty value means "never called", and the length is the call count. The
# character records the kind, so a surprising kind is visible in a failure.
#
# It must stay silent. The verification stage greps the test output for
# `implicit ROLLBACK failed`, `WARNING:` and `warning:`, so a handler that
# printed anything would be counted as a real warning.


def _count_rollback_failure(error: PgError):
    """Append one character per failed implicit `ROLLBACK`.

    Args:
        error: The `PgError` the pool's release path produced.
    """
    var mark = String(
        CONNECTION_MARK
    ) if error.kind == PgErrorKind.CONNECTION else String("o")
    _ = setenv(
        String(HANDLER_CALLS_VAR),
        getenv(String(HANDLER_CALLS_VAR)) + mark,
        True,
    )


# --- size arithmetic and reuse -- (1) ----------------------------------------


def test_two_guards_fill_the_pool_then_the_returned_one_is_reused() raises:
    """A pool of two lends twice, refuses a third, and reuses on return.

    Everything the size accessors promise is here at once: `size()` is
    `idle() + borrowed()`, `pg_stat_activity` agrees with `size()`, and
    `max_size` is a cap on connections *opened* rather than on connections
    handed out -- the third `acquire` fails because there is nothing idle and
    nothing left to open.

    The PIDs are what make reuse observable: two guards sit on two different
    backends, and the guard that comes after a return sits on the backend that
    was returned.
    """
    var observer = _connect(_conninfo())
    var pool = _open_pool(_pool_conninfo(), 2)

    var first = _acquire(pool)
    var second = _acquire(pool)
    var first_pid = _backend_pid(first)
    var second_pid = _backend_pid(second)
    assert_true(first_pid != second_pid, "two guards, two backends")

    assert_equal(pool.size(), 2)
    assert_equal(pool.idle(), 0)
    assert_equal(pool.borrowed(), 2)
    _assert_tagged(observer, 2)

    var exhausted = _acquire_error(pool)
    assert_true(exhausted.kind == PgErrorKind.USAGE)
    assert_equal(exhausted.message, String(EXHAUSTED_TWO))
    _ = exhausted^

    # Returning one puts it in the idle list rather than closing it.
    _ = first^
    assert_equal(pool.size(), 2)
    assert_equal(pool.idle(), 1)
    assert_equal(pool.borrowed(), 1)
    _assert_tagged(observer, 2)

    var third = _acquire(pool)
    assert_equal(_backend_pid(third), first_pid)
    assert_equal(pool.idle(), 0)
    assert_equal(pool.borrowed(), 2)

    _ = third^
    _ = second^
    _ = pool^
    _ = observer^


# --- min_size -- (2) ---------------------------------------------------------


def test_min_size_opens_its_connections_before_open_returns() raises:
    """`min_size=2` has two idle connections and two backends already.

    `open` is the only place `min_size` can act, so the assertions are all
    made before the first `acquire`: a pool that filled lazily would report
    `idle() == 0` here and `pg_stat_activity` would be empty.
    """
    var observer = _connect(_conninfo())
    var pool = _open_pool(_pool_conninfo(), 2, min_size=2)

    assert_equal(pool.idle(), 2)
    assert_equal(pool.size(), 2)
    assert_equal(pool.borrowed(), 0)
    _assert_tagged(observer, 2)

    _ = pool^
    _ = observer^


# --- a dropped Transaction rolls itself back -- (3) --------------------------


def test_a_dropped_transaction_block_is_rolled_back_before_reuse() raises:
    """A `Transaction` dropped uncommitted leaves the next borrower nothing.

    This is the `Transaction` destructor's own `ROLLBACK`, not the pool's: the
    block is dropped first, so by the time the guard goes back the connection
    is already `PQTRANS_IDLE`. What the pool has to get right is that it does
    not undo any of it -- the next borrower must see a clean session, and the
    `CREATE TEMP TABLE` the block made must be gone.
    """
    var pool = _open_pool(_pool_conninfo(), 1)

    var guard = _acquire(pool)
    var tx = _guard_transaction(guard)
    _tx_run(tx, String(CREATE_TX_TABLE))
    assert_equal(guard.transaction_status(), Int(PQTRANS_INTRANS))
    # Dropping the block sends its implicit ROLLBACK; dropping the guard then
    # finds an idle connection and pools it.
    _ = tx^
    _ = guard^

    assert_equal(pool.size(), 1)
    assert_equal(pool.idle(), 1)

    var next = _acquire(pool)
    assert_equal(next.transaction_status(), Int(PQTRANS_IDLE))
    var missing = _guard_execute_error(next, String(SELECT_TX_TABLE))
    assert_true(missing.kind == PgErrorKind.SERVER)
    assert_equal(missing.sqlstate, String(MISSING_TABLE_SQLSTATE))
    _ = missing^

    _ = next^
    _ = pool^


# --- the pool's own ROLLBACK -- (4) ------------------------------------------


def test_release_rolls_back_a_raw_begin_and_keeps_the_connection() raises:
    """A guard dropped with a raw `BEGIN` open goes through `_release`.

    `execute("BEGIN")` leaves no `Transaction` behind, so nothing but the pool
    can clean up: the release path sees `PQTRANS_INTRANS` and sends the
    `ROLLBACK` itself. That is a repair, not a reason to throw the connection
    away, which is why `size()` is unchanged and the same backend comes back.
    """
    var pool = _open_pool(_pool_conninfo(), 1)

    var guard = _acquire(pool)
    var pid = _backend_pid(guard)
    _guard_run(guard, String("BEGIN"))
    _guard_run(guard, String(CREATE_RAW_TABLE))
    assert_equal(guard.transaction_status(), Int(PQTRANS_INTRANS))
    _ = guard^

    assert_equal(pool.size(), 1)
    assert_equal(pool.idle(), 1)

    var next = _acquire(pool)
    assert_equal(_backend_pid(next), pid)
    assert_equal(next.transaction_status(), Int(PQTRANS_IDLE))
    var missing = _guard_execute_error(next, String(SELECT_RAW_TABLE))
    assert_true(missing.kind == PgErrorKind.SERVER)
    assert_equal(missing.sqlstate, String(MISSING_TABLE_SQLSTATE))
    _ = missing^

    _ = next^
    _ = pool^


# --- an abandoned COPY IN -- (5) ---------------------------------------------


def test_an_unfinished_copy_in_is_cancelled_and_the_connection_kept() raises:
    """A `CopyIn` dropped without `finish()` costs the pool nothing.

    The `CopyIn` destructor cancels through `PQputCopyEnd` and drains libpq,
    so by the time the guard goes back the connection is idle again -- which
    is the whole point of that destructor. The pool therefore keeps it: the
    row that was written is not stored, and the next borrower is the same
    backend, with its temp table still there because the `CREATE` was
    autocommitted outside the COPY.
    """
    var pool = _open_pool(_pool_conninfo(), 1)

    var guard = _acquire(pool)
    var pid = _backend_pid(guard)
    _guard_run(guard, String(CREATE_COPY_TABLE))

    var stream = _guard_copy_in(guard, String(COPY_COPY_TABLE_IN))
    _copy_write(stream, String(FWD_ROW))
    _ = stream^
    _ = guard^

    assert_equal(pool.size(), 1)
    assert_equal(pool.idle(), 1)

    var next = _acquire(pool)
    assert_equal(_backend_pid(next), pid)
    assert_equal(_guard_count(next, String(COUNT_COPY_TABLE)), 0)

    _ = next^
    _ = pool^


# --- a connection left ACTIVE -- (6) ----------------------------------------


def test_a_connection_left_active_is_discarded_on_return() raises:
    """A borrowed connection parked in `PQTRANS_ACTIVE` is thrown away.

    `PQTRANS_ACTIVE` means libpq is still in the middle of something -- here a
    `COPY ... FROM STDIN` sent behind `Connection`'s back, so no destructor
    exists to drain it. The release path cannot repair that with a `ROLLBACK`,
    because the `ROLLBACK` would be read as COPY data, so the only safe answer
    is `PQfinish`: `size()` drops to zero and the next `acquire` dials a new
    backend.
    """
    var pool = _open_pool(_pool_conninfo(), 1)

    var guard = _acquire(pool)
    var pid = _backend_pid(guard)
    _guard_run(guard, String(CREATE_ACTIVE_TABLE))
    _send_raw(guard, String(COPY_ACTIVE_TABLE_IN))
    assert_equal(guard.transaction_status(), Int(PQTRANS_ACTIVE))
    _ = guard^

    assert_equal(pool.size(), 0)
    assert_equal(pool.idle(), 0)
    assert_equal(pool.borrowed(), 0)

    var next = _acquire(pool)
    assert_true(_backend_pid(next) != pid, "a new backend, not the active one")
    assert_equal(pool.size(), 1)

    _ = next^
    _ = pool^


# --- a backend killed under a working borrower -- (7) -----------------------


def test_a_terminated_borrowed_connection_is_discarded() raises:
    """A kill noticed by the borrower costs the connection, not the pool.

    libpq only learns a backend is gone when it writes to the socket, so the
    `execute` is what raises -- `PgErrorKind.CONNECTION`, the kind that says
    the error is the connection's rather than the statement's. The pool then
    has a connection whose `PQstatus` is no longer `CONNECTION_OK`, drops it,
    and opens a new one on the next `acquire`.
    """
    var pool = _open_pool(_pool_conninfo(), 1)
    var killer = _connect(_conninfo())

    var guard = _acquire(pool)
    var pid = _backend_pid(guard)
    _terminate(killer, pid)

    var lost = _guard_execute_error(guard, String(SELECT_ONE))
    assert_true(lost.kind == PgErrorKind.CONNECTION)
    _ = lost^
    _ = guard^

    assert_equal(pool.size(), 0)
    assert_equal(pool.idle(), 0)

    var next = _acquire(pool)
    assert_true(_backend_pid(next) != pid, "a new backend, not the dead one")
    var alive = _guard_execute(next, String(SELECT_ONE))
    assert_equal(_get[Int32](_row(alive, 0), 0), Int32(1))
    _ = alive^

    _ = next^
    _ = killer^
    _ = pool^


# --- a backend killed under an idle borrower -- (8) -------------------------


def test_the_health_check_catches_a_kill_the_borrower_never_saw() raises:
    """A connection killed and returned unused is caught by the health check.

    Nothing on this connection failed: the borrower asked for a PID, the
    backend died, and the guard went back without another statement. What
    notices is the release path's own check -- `PQstatus` plus two
    `PQconsumeInput` calls -- and it can only notice once the server's close
    has actually arrived, which is what the `pg_sleep(0.05)` waits for.
    """
    var pool = _open_pool(_pool_conninfo(), 1)
    var killer = _connect(_conninfo())

    var guard = _acquire(pool)
    _terminate(killer, _backend_pid(guard))
    _settle(killer)
    _ = guard^

    assert_equal(pool.size(), 0)
    assert_equal(pool.idle(), 0)

    _ = killer^
    _ = pool^


def test_a_kill_with_no_wait_is_only_seen_by_the_next_borrower() raises:
    """With no wait, the dead connection is pooled and fails on first use.

    This is the accepted gap, asserted rather than wished away: a close that
    has not reached the client yet is invisible to `PQstatus` and to
    `PQconsumeInput`, so the connection goes back to the idle list and comes
    out of the next `acquire` looking fine. The first `execute` on it raises
    `PgErrorKind.CONNECTION`, and *that* return is the one that discards it.
    """
    var pool = _open_pool(_pool_conninfo(), 1)
    var killer = _connect(_conninfo())

    var guard = _acquire(pool)
    _terminate(killer, _backend_pid(guard))
    # No settle here: the point is that libpq has not heard about it yet.
    _ = guard^
    assert_equal(pool.idle(), 1)
    assert_equal(pool.size(), 1)

    var next = _acquire(pool)
    var lost = _guard_execute_error(next, String(SELECT_ONE))
    assert_true(lost.kind == PgErrorKind.CONNECTION)
    _ = lost^
    _ = next^

    assert_equal(pool.size(), 0)
    assert_equal(pool.idle(), 0)

    _ = killer^
    _ = pool^


# --- reset on acquire -- (9) ------------------------------------------------


def test_acquire_resets_a_connection_killed_while_it_was_idle() raises:
    """A connection that died in the idle list is revived, not handed out dead.

    The health check at `acquire` is the last chance to catch a backend that
    went away while nobody was holding it, and `Connection.reset()` is the
    repair: `PQreset` dials again, the session setup is re-sent, and the
    caller gets a working connection on a new PID. `SHOW DateStyle` is the
    assertion that the *setup* was re-sent too -- a bare `PQreset` comes back
    with the server's own `ISO, MDY`.
    """
    var pool = _open_pool(_pool_conninfo(), 1, min_size=1)
    var killer = _connect(_conninfo())

    var guard = _acquire(pool)
    var pid = _backend_pid(guard)
    _ = guard^
    assert_equal(pool.idle(), 1)

    _terminate(killer, pid)
    _settle(killer)

    var revived = _acquire(pool)
    assert_true(_backend_pid(revived) != pid, "reset dials a new backend")
    assert_equal(_guard_string(revived, String(SHOW_DATESTYLE)), DATESTYLE)
    assert_equal(pool.size(), 1)

    _ = revived^
    _ = killer^
    _ = pool^


# --- max_lifetime_s -- (10) -------------------------------------------------


def test_max_lifetime_retires_a_connection_on_return() raises:
    """At `max_lifetime_s=1`, a connection held for 1.1 s is not pooled.

    The retirement happens on return rather than while the connection is out,
    which is why the sleep is run *through* the guard: a pool that checked the
    age at `acquire` instead would still pass the `idle()` assertion but hand
    the stale connection back, and the PID would not change.
    """
    var pool = _open_pool(_pool_conninfo(), 1, max_lifetime_s=LIFETIME_SECONDS)

    var guard = _acquire(pool)
    var pid = _backend_pid(guard)
    _guard_run(guard, String(SLEEP_PAST_LIFETIME))
    _ = guard^

    assert_equal(pool.idle(), 0)
    assert_equal(pool.size(), 0)

    var next = _acquire(pool)
    assert_true(_backend_pid(next) != pid, "the old backend was retired")

    _ = next^
    _ = pool^


def test_the_default_lifetime_never_retires_anything() raises:
    """At the default `max_lifetime_s=0`, age is not a reason to discard.

    Same wait, same shape, opposite outcome: zero means "no limit" rather than
    "retire immediately", so the connection goes back to the idle list and the
    same backend comes out again.
    """
    var pool = _open_pool(_pool_conninfo(), 1)

    var guard = _acquire(pool)
    var pid = _backend_pid(guard)
    _guard_run(guard, String(SLEEP_PAST_LIFETIME))
    _ = guard^

    assert_equal(pool.idle(), 1)
    assert_equal(pool.size(), 1)

    var next = _acquire(pool)
    assert_equal(_backend_pid(next), pid)

    _ = next^
    _ = pool^


# --- close() -- (11) --------------------------------------------------------


def test_close_drops_the_idle_connections_and_refuses_to_lend() raises:
    """`close()` ends the pool for every connection, out or not.

    Three things have to happen and all three are visible from outside: the
    idle connections are `PQfinish`ed, so `pg_stat_activity` loses them
    immediately; `acquire` stops working, with `pool is closed` rather than
    `pool exhausted`; and the guard still out when `close()` ran is discarded
    on return instead of being pooled -- a closed pool that accepted a
    returned connection would leak it, because nothing will ever close it
    again.
    """
    var observer = _connect(_conninfo())
    var pool = _open_pool(_pool_conninfo(), 2, min_size=2)
    _assert_tagged(observer, 2)

    var guard = _acquire(pool)
    assert_equal(pool.borrowed(), 1)
    assert_equal(pool.idle(), 1)

    pool.close()
    # Only the borrowed one is left on the server.
    _assert_tagged(observer, 1)
    assert_equal(pool.idle(), 0)
    assert_equal(pool.borrowed(), 1)
    assert_equal(pool.size(), 1)

    var closed = _acquire_error(pool)
    assert_true(closed.kind == PgErrorKind.USAGE)
    assert_equal(closed.message, String(POOL_CLOSED))
    _ = closed^

    _ = guard^
    assert_equal(pool.size(), 0)
    assert_equal(pool.idle(), 0)
    assert_equal(pool.borrowed(), 0)
    _assert_tagged(observer, 0)

    _ = pool^
    _ = observer^


# --- argument checking -- (12) ----------------------------------------------


def test_bad_sizes_are_usage_errors_before_anything_is_dialled() raises:
    """All four rejected argument sets raise `USAGE` and open no connection.

    The messages are asserted word for word because they are the contract: a
    caller reads them, and `got N` is the only place the offending value
    appears. The `pg_stat_activity` count around all four is what proves the
    check runs *first* -- a pool that validated after `min_size` connections
    were open would leave backends behind on every one of these.
    """
    var observer = _connect(_conninfo())
    var before = _tagged_connections(observer)

    var zero = _open_pool_error(_pool_conninfo(), 0)
    assert_true(zero.kind == PgErrorKind.USAGE)
    assert_equal(zero.message, String(MAX_SIZE_ZERO))
    _ = zero^

    var negative = _open_pool_error(_pool_conninfo(), -1)
    assert_true(negative.kind == PgErrorKind.USAGE)
    assert_equal(negative.message, String(MAX_SIZE_NEGATIVE))
    _ = negative^

    var too_many = _open_pool_error(_pool_conninfo(), 2, min_size=3)
    assert_true(too_many.kind == PgErrorKind.USAGE)
    assert_equal(too_many.message, String(MIN_SIZE_TOO_BIG))
    _ = too_many^

    var lifetime = _open_pool_error(_pool_conninfo(), 1, max_lifetime_s=-1)
    assert_true(lifetime.kind == PgErrorKind.USAGE)
    assert_equal(lifetime.message, String(LIFETIME_NEGATIVE))
    _ = lifetime^

    _assert_tagged(observer, before)
    _ = observer^


# --- the statement counter survives pooling -- (13) -------------------------


def test_the_statement_counter_rides_along_with_the_connection() raises:
    """A reused connection names its next statement `pq_stmt_2`.

    The hazard is specific and it only exists in a pool. `pq_stmt_1` is
    prepared inside a transaction that then aborts on `SELECT 1/0`, so the
    `DEALLOCATE` in the `PreparedStatement` destructor fails and the name is
    still on the server. If the pool handed the connection back with a fresh
    counter, the next `prepare` would ask for `pq_stmt_1` again and get
    `42P05`. Keeping `_stmt_counter` with the connection is what makes the
    second name `pq_stmt_2` instead.
    """
    var pool = _open_pool(_pool_conninfo(), 1)

    var guard = _acquire(pool)
    var pid = _backend_pid(guard)
    _guard_run(guard, String("BEGIN"))

    var stmt = _guard_prepare(guard, String(SELECT_PARAM_INT4))
    assert_equal(stmt.name(), String(FIRST_STMT_NAME))

    var aborted = _guard_execute_error(guard, String(DIVIDE_BY_ZERO))
    assert_true(aborted.kind == PgErrorKind.SERVER)
    assert_equal(aborted.sqlstate, String(DIVISION_SQLSTATE))
    _ = aborted^

    # The DEALLOCATE this sends cannot run in an aborted block, so the server
    # keeps the name.
    _ = stmt^
    _ = guard^

    assert_equal(pool.idle(), 1)

    var next = _acquire(pool)
    assert_equal(_backend_pid(next), pid)
    var second = _guard_prepare(next, String(SELECT_PARAM_INT4))
    assert_equal(second.name(), String(SECOND_STMT_NAME))
    _ = second^

    _ = next^
    _ = pool^


# --- a failed implicit ROLLBACK -- (14) -------------------------------------


def test_a_failed_implicit_rollback_reaches_the_handler_once() raises:
    """The release path's `ROLLBACK` fails loudly enough to be counted.

    `PQtransactionStatus` is libpq's own bookkeeping, so it still says
    `PQTRANS_INTRANS` after the backend is gone: the release path tries the
    `ROLLBACK`, the write fails with `PgErrorKind.CONNECTION`, and a
    destructor cannot raise -- the handler is the only way out. Exactly one
    call, and the connection is discarded rather than pooled with a
    transaction that was never closed.
    """
    _ = setenv(String(HANDLER_CALLS_VAR), "", True)

    var pool = _open_pool(_pool_conninfo(), 1)
    pool.set_rollback_failure_handler(_count_rollback_failure)
    var killer = _connect(_conninfo())

    var guard = _acquire(pool)
    var pid = _backend_pid(guard)
    _guard_run(guard, String("BEGIN"))
    assert_equal(guard.transaction_status(), Int(PQTRANS_INTRANS))

    _terminate(killer, pid)
    _settle(killer)
    # Returned without another statement: the ROLLBACK is the first thing to
    # touch the dead socket.
    _ = guard^

    assert_equal(getenv(String(HANDLER_CALLS_VAR)), String(CONNECTION_MARK))
    assert_equal(pool.size(), 0)
    assert_equal(pool.idle(), 0)

    _ = killer^
    _ = pool^


# --- the eleven forwarded methods -- (15) -----------------------------------


def test_every_forwarded_method_reaches_the_connection() raises:
    """All eleven forwards work through a guard, and none of them leak it.

    What is checked here is that the guard *has* each method and that it
    reaches the real connection -- what the methods do is
    `tests/test_connection.mojo`'s and `tests/test_copy.mojo`'s business. The
    four that hand back a view (`transaction`, `prepare`, `copy_in`,
    `copy_out`) are the interesting ones: each is bound to the guard's own
    origin, so none of them can be used to get at the `Connection` itself, and
    all four are exercised far enough to prove the view is live.
    """
    var pool = _open_pool(_pool_conninfo(), 1)
    var guard = _acquire(pool)

    # 1: execute(sql)
    var one = _guard_execute(guard, String(SELECT_ONE))
    assert_equal(_get[Int32](_row(one, 0), 0), Int32(1))
    _ = one^

    # 2: execute(sql, params, result_format=...)
    var params: List[Param] = [Int32(7)]
    var bound = _guard_execute_params(
        guard, String(SELECT_PARAM_INT4), params, ResultFormat.BINARY
    )
    assert_equal(_column_format(bound, 0), ResultFormat.BINARY)
    assert_equal(_get[Int32](_row(bound, 0), 0), Int32(7))
    _ = bound^

    # 3 and 4: the two escapers, which are round trips to libpq's own quoter.
    assert_equal(
        _guard_escape_literal(guard, String(ESCAPE_INPUT)),
        ESCAPE_LITERAL_OUTPUT,
    )
    assert_equal(
        _guard_escape_identifier(guard, String(ESCAPE_IDENTIFIER_INPUT)),
        ESCAPE_IDENTIFIER_OUTPUT,
    )

    # 5, 6, 7: the three that answer from libpq without a round trip.
    assert_true(guard.server_version() >= PG14)
    assert_equal(guard.status(), Int(CONNECTION_OK))
    assert_equal(guard.transaction_status(), Int(PQTRANS_IDLE))

    # 8: transaction()
    var tx = _guard_transaction(guard)
    var inside = _tx_execute(tx, String(SELECT_ONE))
    assert_equal(_get[Int32](_row(inside, 0), 0), Int32(1))
    _ = inside^
    _tx_commit(tx)

    # 9: prepare()
    var stmt = _guard_prepare(guard, String(SELECT_PARAM_INT8))
    var prepared = _stmt_execute(stmt, [Int(9)])
    assert_equal(_get[Int64](_row(prepared, 0), 0), Int64(9))
    _ = prepared^
    _ = stmt^

    # 10: copy_in()
    _guard_run(guard, String(CREATE_FWD_TABLE))
    var into = _guard_copy_in(guard, String(COPY_FWD_IN))
    _copy_write(into, String(FWD_ROW))
    var taken = _copy_finish(into)
    assert_equal(taken.affected_rows(), 1)
    _ = taken^
    _ = into^

    # 11: copy_out()
    var out = _guard_copy_out(guard, String(COPY_FWD_OUT))
    var row = _copy_next(out)
    assert_true(Bool(row), "the row that was just COPYed in")
    ref row_bytes = row.value()
    assert_equal(len(row_bytes), FWD_ROW_BYTES)
    assert_false(Bool(_copy_next(out)), "the end of the stream is a value")
    _ = out^

    _ = guard^
    _ = pool^


# --- the Dict overload -- (16) ----------------------------------------------


def test_open_from_keyword_pairs_pools_the_same_way() raises:
    """`Pool.open(Dict, ...)` is the same pool, built from pairs.

    The `Dict` carries `application_name` as a key like any other, so the
    counting helper can see these backends too -- which is what makes this a
    test of the overload rather than of `Connection.open(Dict)`.
    """
    var observer = _connect(_conninfo())
    var pool = _open_pool_params(_pool_params(), 1, min_size=1)

    assert_equal(pool.idle(), 1)
    _assert_tagged(observer, 1)

    var guard = _acquire(pool)
    var one = _guard_execute(guard, String(SELECT_ONE))
    assert_equal(_get[Int32](_row(one, 0), 0), Int32(1))
    _ = one^

    _ = guard^
    _ = pool^
    _ = observer^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
