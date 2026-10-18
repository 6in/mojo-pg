"""Leak tests: long loops over connect / query / close and the failure paths.

Every `Connection` owns a `PGconn` and every `Result` owns a `PGresult`, so a
missing `PQfinish` / `PQclear` / `PQfreemem` shows up as resident memory that
only grows. These tests run each path thousands of times and watch the
process's RSS instead of asking libpq for a count: that catches a leak no
matter which of the three frees was forgotten.

Every loop allocates and frees at least `PAYLOAD_BYTES` of libpq-owned memory
per iteration. That sizing is the whole test, not a detail: a few-KiB
`PGresult` per iteration is recycled inside glibc's free lists and never moves
RSS by a single page -- which is why a `SELECT 1` loop passed with every
`PQclear` deleted (verify round 1, measured: 9 flat samples). The payloads
below are sized so no free list can absorb the leak.

`tests/run_tests.sh` runs this file as a binary produced by `mojo build`, so
no compiler heap is resident while the loops run. The payload sizes were first
chosen against `mojo run`, which hosts the compiler in this same process and
leaves the ~100 MiB of compile-time heap it frees before `main()` runs on
glibc's free lists; they are kept that large as headroom. Running this file
under `mojo run` therefore still detects a leak, but that freed heap can
absorb the first sampling interval or two, which leaves the verdict resting
on `is_leaking`'s total-growth signal alone. The built binary keeps both
signals.

RSS is sampled from `/proc/self/statm`, which only exists on Linux. On macOS
the loops are skipped rather than reimplemented: `is_leaking` is still covered
by its own unit tests there.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI: these tests append ` password=...` to it).

Eighteen tests, in the order they run:

- Four `is_leaking` unit tests. They need no database and are declared first
  so a broken verdict fails before any loop runs.
- Four Phase 1 loops: `connect/query/close`, `failed-open`, `escape_literal`,
  `failed-execute`. These cover `PQfinish`, `PQclear` on the failure path and
  `PQfreemem`.
- Four Phase 2 loops: `execute(sql, params)`, `prepare`/`execute`/drop,
  `transaction` + `commit`, and `transaction` + implicit `ROLLBACK` on drop.
  These cover the `PGresult`s that `_ParamBuffers`, `PreparedStatement` and
  `Transaction` own on top of the ones `Result` owns -- including the two
  `__deinit__` paths that call `PQexec` directly (`DEALLOCATE` and the
  implicit `ROLLBACK`) and so have to `PQclear` without a `Result` to do it.
- Two Phase 3 loops: `binary-execute` and `zero-copy`. The first asks for
  binary results and decodes all ten columns of `PHASE3_SQL` through
  `Row.get[T]`, with a `Decimal` and a `Date` bound as parameters so the
  binary *encode* path runs too; the second reads the same statement in text
  and takes only a borrowed slice per row with `Row.get_text`. Neither adds a
  free of its own -- the point is the opposite: a decoder or a slice that
  retained the `PGresult`, or a `_ParamBuffers` the new encoders kept alive,
  would show up here and nowhere else.
- Four Phase 4 loops: `async-execute`, `async-cancel`, `notify-receive` and
  `async-drop`. `AsyncConnection` has to free in three places the synchronous
  `Connection` never reaches: the `PGcancel` that `cancel` borrows and hands
  back with `PQfreeCancel`, the `PGnotify` each notification arrives in that
  `notifications` copies out of and `PQfreemem`s, and the results still
  unread when a connection is dropped, which leaves `PQfinish` as the only
  thing that can clear them. The first loop covers none of those: it is the
  plain `send` / `fetch_all` round trip, so a `PGresult` the asynchronous
  collector failed to adopt is caught there rather than hiding behind one of
  the other three.

This file is slow by design: measured per server once the binary is built, the
Phase 1 connect loop alone is ~36 s, the other three Phase 1 loops ~4 s, the
four Phase 2 loops ~18 s, the two Phase 3 loops ~6 s and the four Phase 4
loops ~7 s, for ~72 s in total on top of the one-off `mojo build`. The
Phase 2, Phase 3 and first Phase 4 loops are cheap next to the connect loop
because they reuse one connection; `Connection.open` is what costs ~3.5 ms a
time, and the `async-drop` loop pays that again per iteration because the drop
*is* what it measures. `async-cancel` pays a second connection per iteration
too: a cancel request travels on one of its own.
"""

from std.os import getenv
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pq.async_conn import AsyncConnection, Notification
from pq.connection import Connection
from pq.errors import PgError
from pq.params import Param
from pq.prepared import PreparedStatement
from pq.result import Result, ResultFormat
from pq.transaction import Transaction
from pq.types_datetime import (
    Date,
    Interval,
    Time,
    TimeTz,
    Timestamp,
    TimestampTz,
)
from pq.types_numeric import Decimal
from pq.types_uuid import UUID

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime WRONG_PASSWORD: StaticString = "WRONG_pw_123"
"""A password that always fails authentication, to drive the failed-open path.

The loop appends `OPEN_PAYLOAD_BYTES` of filler to it; see there for why.
"""

comptime PAYLOAD_BYTES = 65536
"""Bytes of libpq-owned memory every iteration of every loop must churn.

64 KiB is the floor that keeps a forgotten free visible even under `mojo run`,
whose compiler heap the built binary no longer carries (see the module
docstring). Raising it is not free either: `ABORT_PAGES` is a threshold on the
growth measured from the *first* sample, so `PAYLOAD_BYTES` x the sampling
interval has to stay well under `ABORT_PAGES` for a leaking loop to be cut
short within a few samples -- a few hundred MiB rather than the machine.

The failed-open loop uses `OPEN_PAYLOAD_BYTES` instead: it runs 1,000
iterations rather than 10,000, so it needs more per iteration.
"""

comptime OPEN_PAYLOAD_BYTES = 262144
"""Bytes of unparsable conninfo to hand the second failing open per iteration.

The failed-open loop has no `PGresult` to inflate, so it has to inflate the
`PGconn` itself, and the wrong-password open cannot do that on its own: a
failed `PGconn` is only ~40 KiB, so 1,000 of them vanished into the compiler's
freed heap and the loop passed with `PQfinish` deleted (measured). Inflating
the *password* is not the answer either -- libpq re-keys an HMAC with it on
each of SCRAM's 4,096 iterations, so a 256 KiB password cost 424 ms per open
(measured) and pushed the loop to seven minutes.

A conninfo token with no `=` is instead rejected before any round trip, and
libpq echoes it back verbatim in the connection's error message
(`missing "=" after "xxx..."`), which lives inside the `PGconn`. 256 KiB x
1,000 iterations overruns the pool for free.
"""

comptime ABORT_PAGES = 65536
"""RSS growth, in pages (256 MiB), at which a loop is cut short as leaking.

`is_leaking` only gets to speak once a loop has finished, and a leaking main
loop would ask for 64 KiB x 10,000 = 640 MiB before that. `_sample` fails on
the spot instead, so a real leak costs a few hundred MiB rather than the
machine.
"""

comptime TOLERANCE_PAGES = 256
"""How much total RSS growth (in pages) a non-leaking loop may show.

256 is a **permanent specification**, not a number to be tuned down later.

Measured on PG14 and PG17, with this file run as the binary `mojo build`
produces (the only way `tests/run_tests.sh` runs it): a non-leaking loop is
stable to within 2 pages, except for a *single* one-off step of 83-85 pages
(~332 KiB) that lands at an arbitrary iteration of an arbitrary loop, not
per-iteration growth. The cause is **unidentified**; an expansion of a glibc
arena is the guess, and nothing has been measured that confirms it.

The step is excluded by its *shape* -- one rise with a flat tail behind it,
see `is_leaking` -- and not by its size, because its size is not bounded by
anything that was measured: the x86_64 GitHub runner produced a step of 513
pages (run `39092567451`), twice what this tolerance clears, where the aarch64
runner showed 84 and the development machine 1. The tolerance stays at 256 for
the series that have no step at all: over 16 built-binary series (4 loops x
2 servers x 2 runs) 14 came in at 0-2 pages of total growth and 2 showed the
step, once at the 4th sample and once at the 9th.

Total growth, not monotonicity, is the signal that actually fires here: a real
leak moves thousands of pages per sampling interval, far past this tolerance.
The monotonic-growth check in `is_leaking` is the backup — an allocator that
serves several iterations out of a region it already holds can flatten an
interval, and a flat step there would otherwise clear the loop.
"""

comptime MAIN_ITERATIONS = 10000
"""Connect / query / close iterations in the main loop."""

comptime MAIN_WARMUP = 1000
"""Main-loop iterations run before the first RSS sample is taken."""

comptime MAIN_SAMPLES = 9
"""RSS samples taken after the main loop's warmup."""

comptime ERROR_ITERATIONS = 1000
"""Iterations per failure-path loop (open / escape / execute)."""

comptime ERROR_WARMUP = 200
"""Failure-path iterations run before the first RSS sample is taken."""

comptime ERROR_SAMPLES = 4
"""RSS samples taken after a failure-path loop's warmup."""

comptime NOTIFY_PAYLOAD_BYTES = 7000
"""Payload bytes every `NOTIFY` in the Phase 4 notify loop carries.

A `PGnotify` is one allocation holding the struct, the channel name and the
payload, so the payload is the only part of it this test can size. PostgreSQL
caps a payload at 7999 bytes (`tests/test_notify.mojo` covers the cap itself),
an eighth of `PAYLOAD_BYTES` and the most this path can churn per iteration.
At `ERROR_ITERATIONS` iterations a forgotten `PQfreemem` still strands ~7 MB,
far past `TOLERANCE_PAGES`.
"""

comptime PHASE3_SQL = (
    "SELECT repeat('x', "
    + String(PAYLOAD_BYTES)
    + ")::text,"
    + " 1.5::numeric,"
    + " '2024-01-02'::date,"
    + " '2024-01-02 03:04:05.678901'::timestamp,"
    + " '2024-01-02 03:04:05+09'::timestamptz,"
    + " '12:34:56'::time,"
    + " '12:34:56+09'::timetz,"
    + " '1 year 2 mons 3 days 04:05:06.789'::interval,"
    + " gen_random_uuid(),"
    + " '{\"a\":1}'::jsonb"
    + " WHERE $1 = 1.5 AND $2 = '2024-02-29'"
)
"""The ten-column statement both Phase 3 loops run.

Column 0 is `PAYLOAD_BYTES` wide for the same reason as everywhere else in
this file; the nine columns after it are one of each type Phase 3 decodes, so
a decoder that retained its input would be caught whichever one it was. The
two placeholders are matched by `Decimal("1.50")` and `Date(8825)`, which puts
`encode_numeric` and `encode_date` -- and the `_ParamBuffers` holding their
output -- in the loop as well. The `WHERE` is true, so the row is always
there to read.
"""


# --- RSS sampling and the leak verdict ---------------------------------------


def rss_pages() raises -> Int:
    """Read this process's resident set size, in pages.

    Returns:
        The second field of `/proc/self/statm` (resident pages).

    Raises:
        Error: If `/proc/self/statm` cannot be read or parsed (non-Linux).
    """
    with open("/proc/self/statm", "r") as statm:
        var text = statm.read()
        var fields = text.split(" ")
        return atol(String(fields[1]))


def is_leaking(samples: List[Int], tolerance_pages: Int) -> Bool:
    """Decide whether a series of RSS samples shows a leak.

    Two independent signals, either of which is a verdict of "leaking":

    - *Monotonic growth*: every sample is strictly larger than the one before
      it. A steady per-iteration leak looks like this even when each step is
      tiny, so this catches slow leaks that stay inside the tolerance.
    - *Total growth*: the last sample exceeds the first by more than
      `tolerance_pages`. This catches a leak that grows in bursts (an
      allocator serving several iterations from one new region), where some
      adjacent steps are flat.

    Total growth has one exception, and it is a shape rather than a size: a
    series that rises exactly once and then stays flat for two or more samples
    is the one-off step described under `TOLERANCE_PAGES`, not a leak. A leak
    that grows in bursts keeps bursting, so it rises more than once over nine
    samples; a step that has stopped growing cannot be made to look like one
    by being large.

    Args:
        samples: RSS readings in pages, in the order they were taken.
        tolerance_pages: Total growth, in pages, that is still acceptable.

    Returns:
        True if the samples show a leak, False if they look stable.
    """
    if len(samples) < 2:
        return False
    var monotonic = True
    for i in range(1, len(samples)):
        if samples[i] <= samples[i - 1]:
            monotonic = False
            break
    if monotonic:
        return True
    if samples[len(samples) - 1] - samples[0] <= tolerance_pages:
        return False
    # A single one-off step: exactly one rise, with a tail of at least two
    # samples behind it. One rise is also what keeps that tail from climbing
    # back above the step -- it could not do so without rising again.
    var rises = 0
    var step_at = 0
    for i in range(1, len(samples)):
        if samples[i] > samples[i - 1]:
            rises += 1
            step_at = i
    return rises != 1 or len(samples) - step_at < 2


# --- helpers -----------------------------------------------------------------
#
# A `TestSuite` test only declares `raises` (plain `Error`), and `PgError` does
# not implicitly convert to `Error`, so a `raises PgError` API cannot be called
# straight from a test. These wrappers translate in both directions, exactly as
# in `tests/test_connection.mojo`.


def _conninfo() -> String:
    """Return the conninfo of the server under test.

    Returns:
        `PQ_TEST_CONNINFO` when set and non-empty, else `DEFAULT_CONNINFO`.
    """
    var value = getenv("PQ_TEST_CONNINFO")
    return value if value != "" else String(DEFAULT_CONNINFO)


def _connect(var conninfo: String) raises -> Connection:
    """Open a connection from a conninfo string.

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
    """Run `sql` on `conn`.

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


def _execute_params(
    conn: Connection, var sql: String, params: List[Param]
) raises -> Result:
    """Run `sql` on `conn` with bound parameters.

    Args:
        conn: An open connection.
        sql: The single statement to run.
        params: The values bound to `$1`, `$2`, ... in order.

    Returns:
        The result of the statement.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    try:
        return conn.execute(sql^, params)
    except e:
        raise Error(String(e))


def _prepare(
    conn: Connection, var sql: String
) raises -> PreparedStatement[origin_of(conn)]:
    """Prepare `sql` on `conn`, letting the server infer the parameter types.

    Args:
        conn: An open connection.
        sql: The single statement to prepare.

    Returns:
        The prepared statement.

    Raises:
        Error: If `prepare` raised a `PgError`.
    """
    try:
        return conn.prepare(sql^)
    except e:
        raise Error(String(e))


def _stmt_execute[
    origin: ImmOrigin, //
](stmt: PreparedStatement[origin], params: List[Param]) raises -> Result:
    """Execute `stmt` with bound parameters.

    Parameters:
        origin: Origin of the `Connection` the statement views; inferred.

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


def _transaction(conn: Connection) raises -> Transaction[origin_of(conn)]:
    """Begin a transaction block on `conn`.

    Args:
        conn: An idle, open connection.

    Returns:
        The open transaction block, with its `BEGIN` already sent.

    Raises:
        Error: If `transaction` raised a `PgError`.
    """
    try:
        return conn.transaction()
    except e:
        raise Error(String(e))


def _tx_execute[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var sql: String) raises -> Result:
    """Run `sql` inside `tx` without parameters.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

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


def _tx_commit[origin: ImmOrigin, //](mut tx: Transaction[origin]) raises:
    """Commit `tx`.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The open transaction block.

    Raises:
        Error: If `commit` raised a `PgError`.
    """
    try:
        tx.commit()
    except e:
        raise Error(String(e))


def _open_error(var conninfo: String) raises -> PgError:
    """Return the `PgError` raised by `Connection.open(conninfo)`.

    Args:
        conninfo: A conninfo string that must fail to connect.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the connection succeeded instead of failing.
    """
    try:
        var conn = Connection.open(conninfo^)
        _ = conn^
    except e:
        return e.copy()
    raise Error("expected a PgError from Connection.open(conninfo)")


def _execute_error(conn: Connection, var sql: String) raises -> PgError:
    """Return the `PgError` raised by `conn.execute(sql)`.

    Args:
        conn: An open connection.
        sql: A statement that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `execute` returned a result instead of raising.
    """
    try:
        var result = conn.execute(sql^)
        _ = result^
    except e:
        return e.copy()
    raise Error("expected a PgError from Connection.execute")


def _escape_literal(conn: Connection, var s: String) raises -> String:
    """Quote `s` as a SQL literal on `conn`.

    Args:
        conn: An open connection.
        s: The value to quote.

    Returns:
        libpq's quoted literal, surrounding quotes included.

    Raises:
        Error: If `escape_literal` raised a `PgError`.
    """
    try:
        return conn.escape_literal(s^)
    except e:
        raise Error(String(e))


def _phase3_params() raises -> List[Param]:
    """Build the two parameters `PHASE3_SQL` binds, in binary.

    Returns:
        A `numeric` and a `date` parameter, matching `$1` and `$2`.

    Raises:
        Error: If the `Decimal` literal was rejected.
    """
    try:
        return [Decimal("1.50"), Date(8825)]
    except e:
        raise Error(String(e))


def _read_binary_row(conn: Connection, params: List[Param]) raises -> Int:
    """Run `PHASE3_SQL` with binary results and decode all ten columns.

    Args:
        conn: An open connection.
        params: The parameters from `_phase3_params`.

    Returns:
        A checksum over all ten cells, so none of the reads can be dropped.

    Raises:
        Error: If the query or any of the decoding raised a `PgError`.
    """
    try:
        var result = conn.execute(
            String(PHASE3_SQL), params, result_format=ResultFormat.BINARY
        )
        var row = result[0]
        var total = row.get[String](0).byte_length()
        total += row.get[Decimal](1).dscale()
        total += Int(row.get[Date](2).days)
        total += Int(row.get[Timestamp](3).micros % 1000)
        total += Int(row.get[TimestampTz](4).micros % 1000)
        total += Int(row.get[Time](5).micros % 1000)
        total += Int(row.get[TimeTz](6).micros % 1000)
        total += Int(row.get[Interval](7).micros % 1000)
        total += Int(row.get[UUID](8).bytes[0])
        total += row.get[String](9).byte_length()
        _ = result^
        return total
    except e:
        raise Error(String(e))


def _read_text_slice(conn: Connection, params: List[Param]) raises -> Int:
    """Run `PHASE3_SQL` in text and borrow column 0 without copying it.

    Args:
        conn: An open connection.
        params: The parameters from `_phase3_params`.

    Returns:
        The byte length of column 0, read straight off the `PGresult`.

    Raises:
        Error: If the query or `get_text` raised a `PgError`.
    """
    try:
        var result = conn.execute(String(PHASE3_SQL), params)
        var total = result[0].get_text(0).byte_length()
        _ = result^
        return total
    except e:
        raise Error(String(e))


def _async_connect(var conninfo: String) raises -> AsyncConnection:
    """Open an asynchronous connection and wait out its handshake.

    Args:
        conninfo: A libpq `key=value ...` conninfo string.

    Returns:
        The connection, in state `Idle`.

    Raises:
        Error: If `connect_blocking` raised a `PgError`.
    """
    try:
        return AsyncConnection.connect_blocking(conninfo^, 5000)
    except e:
        raise Error(String(e))


def _async_send(mut conn: AsyncConnection, var sql: String) raises:
    """Queue `sql` on an idle asynchronous connection.

    Args:
        conn: The idle connection.
        sql: One or more SQL statements.

    Raises:
        Error: If `send` raised a `PgError`.
    """
    try:
        conn.send(sql^)
    except e:
        raise Error(String(e))


def _async_fetch_all(
    mut conn: AsyncConnection, timeout_ms: Int
) raises -> List[Result]:
    """Collect every result of the command in flight.

    Args:
        conn: The connection with a command in flight.
        timeout_ms: Milliseconds allowed for the whole command.

    Returns:
        One `Result` per statement.

    Raises:
        Error: If `fetch_all` raised a `PgError`.
    """
    try:
        return conn.fetch_all(timeout_ms)
    except e:
        raise Error(String(e))


def _async_cancel(mut conn: AsyncConnection) raises:
    """Ask the server to abandon the command in flight.

    Args:
        conn: The connection with a command in flight.

    Raises:
        Error: If `cancel` raised a `PgError`.
    """
    try:
        conn.cancel()
    except e:
        raise Error(String(e))


def _collect_cancelled(
    mut conn: AsyncConnection, timeout_ms: Int
) raises -> Int:
    """Collect the results of a command a `cancel` was racing.

    Either outcome is correct and both have to be accepted: the cancel request
    travels on its own connection, so it can reach the backend before the
    statement finishes (`57014`) or after it already answered (a result).

    Args:
        conn: The connection the cancel was sent on.
        timeout_ms: Milliseconds allowed for the collection.

    Returns:
        The number of results collected; 0 when the cancel won.

    Raises:
        Error: If the command failed for any reason other than being
            cancelled.
    """
    try:
        var results = conn.fetch_all(timeout_ms)
        var count = len(results)
        _ = results^
        return count
    except e:
        if e.sqlstate != "57014":
            raise Error(String(e))
        return 0


def _async_listen(mut conn: AsyncConnection, var channel: String) raises:
    """Subscribe an asynchronous connection to `channel`.

    Args:
        conn: The idle connection.
        channel: An unquoted channel name.

    Raises:
        Error: If the `LISTEN` failed.
    """
    _async_send(conn, "LISTEN " + channel)
    var results = _async_fetch_all(conn, 5000)
    assert_equal(len(results), 1)


def _async_wait_notification(
    mut conn: AsyncConnection, timeout_ms: Int
) raises -> Optional[Notification]:
    """Wait for one notification.

    Args:
        conn: The listening connection.
        timeout_ms: Milliseconds to wait in total.

    Returns:
        The oldest notification, or None when the budget ran out.

    Raises:
        Error: If `wait_notification` raised a `PgError`.
    """
    try:
        return conn.wait_notification(timeout_ms)
    except e:
        raise Error(String(e))


def _async_wait_readable(mut conn: AsyncConnection, timeout_ms: Int) raises:
    """Wait for the connection's socket to have something to read.

    Args:
        conn: The connection with a command in flight.
        timeout_ms: Milliseconds to wait at most.

    Raises:
        Error: If `wait_readable` raised a `PgError`, timeout included.
    """
    try:
        conn.wait_readable(timeout_ms)
    except e:
        raise Error(String(e))


def _async_consume_input(mut conn: AsyncConnection) raises:
    """Move whatever the server has sent into libpq's buffer.

    Args:
        conn: The connection with a command in flight.

    Raises:
        Error: If `consume_input` raised a `PgError`.
    """
    try:
        conn.consume_input()
    except e:
        raise Error(String(e))


def _notify_payload() -> String:
    """Build the exact-length payload the Phase 4 notify loop sends.

    `_payload` rounds up to the next power of two, which would overrun the
    7999 bytes PostgreSQL allows a `NOTIFY` payload, so this grows a byte at a
    time instead.

    Returns:
        `NOTIFY_PAYLOAD_BYTES` `x` bytes.
    """
    var out = String()
    while out.byte_length() < NOTIFY_PAYLOAD_BYTES:
        out += "x"
    return out^


def _skip_on_macos(name: StaticString) -> Bool:
    """Report whether RSS sampling is unavailable, printing a skip notice.

    The notice is in the `SKIP <name>: <reason>` form `tests/run_tests.sh`
    counts, so the caller has to name itself.

    Args:
        name: Name of the calling test function.

    Returns:
        True on macOS (the caller must return without sampling).
    """
    if CompilationTarget.is_macos():
        print("SKIP ", name, ": RSS sampling is Linux-only", sep="")
        return True
    return False


def _is_sample_due(iteration: Int, warmup: Int, every: Int) -> Bool:
    """Report whether an RSS sample is due after `iteration` completed.

    Args:
        iteration: Zero-based index of the iteration that just finished.
        warmup: Iterations to ignore before sampling starts.
        every: Iterations between samples once warmup is over.

    Returns:
        True if the caller should take a sample now.
    """
    var done = iteration + 1 - warmup
    return done > 0 and done % every == 0


def _describe(samples: List[Int]) -> String:
    """Render RSS samples for an assertion message.

    Args:
        samples: RSS readings in pages.

    Returns:
        The samples as `[a, b, c]`.
    """
    var out = String("[")
    for i in range(len(samples)):
        if i > 0:
            out += ", "
        out += String(samples[i])
    out += "]"
    return out^


def _sample(label: String, mut samples: List[Int]) raises:
    """Take one RSS sample, failing on the spot if the loop is running away.

    Args:
        label: Name of the loop, for the message.
        samples: The loop's samples so far; the new reading is appended.

    Raises:
        Error: If RSS has grown more than `ABORT_PAGES` past the first sample.
            The loop must not keep iterating after that.
    """
    samples.append(rss_pages())
    var grown = samples[len(samples) - 1] - samples[0]
    if grown > ABORT_PAGES:
        raise Error(
            label
            + " RSS pages: "
            + _describe(samples)
            + " — grew "
            + String(grown)
            + " pages past the first sample, over the "
            + String(ABORT_PAGES)
            + " allowed; aborting the loop (leaking)"
        )


def _payload(size: Int) -> String:
    """Build the oversized value a loop sends, quotes or raises.

    Args:
        size: Length in bytes. Rounded up to the next power of two.

    Returns:
        `size` repetitions of `x`.
    """
    var out = String("x")
    while out.byte_length() < size:
        out += out.copy()
    return out^


def _payload_bytes(size: Int) -> List[UInt8]:
    """Build the oversized `bytea` value a loop binds to a parameter.

    Args:
        size: Length in bytes.

    Returns:
        `size` bytes, the one at index `i` being `i % 251`.
    """
    var out = List[UInt8]()
    for i in range(size):
        out.append(UInt8(i % 251))
    return out^


def _assert_stable(
    label: String, samples: List[Int], expected_samples: Int
) raises:
    """Check that a loop's RSS samples show no leak.

    The series is printed even when it passes: a loop that drifts without
    tripping the verdict is the early warning for a leak, and the numbers are
    the only evidence left once the process exits.

    Args:
        label: Name of the loop, for the message.
        samples: RSS readings in pages, in the order they were taken.
        expected_samples: How many samples the loop should have taken.

    Raises:
        Error: If the sample count is wrong or the series shows a leak.
    """
    var series = label + " RSS pages: " + _describe(samples)
    print(series)
    assert_equal(len(samples), expected_samples)
    assert_false(is_leaking(samples, TOLERANCE_PAGES), series)


# --- is_leaking unit tests (no database) -------------------------------------


def test_is_leaking_detects_monotonic_growth() raises:
    var samples: List[Int] = [100, 101, 102, 103]
    assert_true(is_leaking(samples, 16))


def test_is_leaking_accepts_a_wobble() raises:
    var samples: List[Int] = [100, 100, 101, 100]
    assert_false(is_leaking(samples, 16))


def test_is_leaking_detects_growth_beyond_tolerance() raises:
    var samples: List[Int] = [100, 100, 100, 120]
    assert_true(is_leaking(samples, 16))


def test_is_leaking_accepts_flat_samples() raises:
    var samples: List[Int] = [100, 100, 100, 100]
    assert_false(is_leaking(samples, 16))


def test_is_leaking_accepts_a_single_step_plateau() raises:
    # The one-off step of `TOLERANCE_PAGES`, in the shape the x86_64 runner
    # produced it: far past the tolerance, but it rises once and stops.
    var samples: List[Int] = [100, 100, 100, 100, 613, 613, 613, 613, 613]
    assert_false(is_leaking(samples, 16))


def test_is_leaking_detects_two_steps_beyond_tolerance() raises:
    # A leak served out of regions the allocator takes in bursts: flat
    # stretches, but it rises more than once.
    var samples: List[Int] = [100, 100, 300, 300, 300, 520, 520, 520, 520]
    assert_true(is_leaking(samples, 16))


# --- the loops ---------------------------------------------------------------


def test_connect_query_close_does_not_leak() raises:
    if _skip_on_macos("test_connect_query_close_does_not_leak"):
        return
    var conninfo = _conninfo()
    # The row is PAYLOAD_BYTES wide so the PGresult a missing PQclear would
    # strand is too big for the compiler's freed heap to swallow.
    var sql = "SELECT repeat('x', " + String(PAYLOAD_BYTES) + ")"
    var every = (MAIN_ITERATIONS - MAIN_WARMUP) // MAIN_SAMPLES
    var samples = List[Int]()
    for i in range(MAIN_ITERATIONS):
        var conn = _connect(conninfo.copy())
        var result = _execute(conn, sql.copy())
        _ = result^
        _ = conn^
        if _is_sample_due(i, MAIN_WARMUP, every):
            _sample("connect/query/close", samples)
    _assert_stable("connect/query/close", samples, MAIN_SAMPLES)


def test_failed_open_does_not_leak() raises:
    if _skip_on_macos("test_failed_open_does_not_leak"):
        return
    # libpq takes the last value given for a repeated key, so appending
    # `password=...` overrides the real one.
    var rejected_conninfo = _conninfo() + " password=" + WRONG_PASSWORD
    # A trailing token with no `=`, OPEN_PAYLOAD_BYTES long: see there.
    var unparsable_conninfo = _conninfo() + " " + _payload(OPEN_PAYLOAD_BYTES)
    var every = (ERROR_ITERATIONS - ERROR_WARMUP) // ERROR_SAMPLES
    var samples = List[Int]()
    for i in range(ERROR_ITERATIONS):
        # Both failures end at the same `PQfinish` in `Connection._adopt`: a
        # `PGconn` that came back CONNECTION_BAD. Only the second one is big
        # enough to see, but the authentication failure is the realistic
        # shape, so the loop keeps covering it.
        var rejected = _open_error(rejected_conninfo.copy())
        _ = rejected^
        var unparsed = _open_error(unparsable_conninfo.copy())
        _ = unparsed^
        if _is_sample_due(i, ERROR_WARMUP, every):
            _sample("failed-open", samples)
    _assert_stable("failed-open", samples, ERROR_SAMPLES)


def test_escape_literal_does_not_leak() raises:
    if _skip_on_macos("test_escape_literal_does_not_leak"):
        return
    var conn = _connect(_conninfo())
    # Still an apostrophe to quote, but PAYLOAD_BYTES long: what PQescapeLiteral
    # hands back is what a missing PQfreemem would strand.
    var value = "O'Reilly " + _payload(PAYLOAD_BYTES)
    var every = (ERROR_ITERATIONS - ERROR_WARMUP) // ERROR_SAMPLES
    var samples = List[Int]()
    for i in range(ERROR_ITERATIONS):
        var quoted = _escape_literal(conn, value.copy())
        _ = quoted^
        if _is_sample_due(i, ERROR_WARMUP, every):
            _sample("escape_literal", samples)
    _assert_stable("escape_literal", samples, ERROR_SAMPLES)
    _ = conn^


def test_failed_execute_does_not_leak() raises:
    if _skip_on_macos("test_failed_execute_does_not_leak"):
        return
    var conn = _connect(_conninfo())
    # A raised exception carrying a PAYLOAD_BYTES message: the failing
    # PGresult, which `execute` clears on its non-success path, holds it all.
    # (A plain `SELEC 1` syntax error is only a few hundred bytes -- too small
    # to show up in RSS; `tests/test_connection.mojo` covers that path.)
    var sql = (
        "DO $$ BEGIN RAISE EXCEPTION '%', repeat('x', "
        + String(PAYLOAD_BYTES)
        + "); END $$"
    )
    var every = (ERROR_ITERATIONS - ERROR_WARMUP) // ERROR_SAMPLES
    var samples = List[Int]()
    for i in range(ERROR_ITERATIONS):
        var error = _execute_error(conn, sql.copy())
        _ = error^
        if _is_sample_due(i, ERROR_WARMUP, every):
            _sample("failed-execute", samples)
    _assert_stable("failed-execute", samples, ERROR_SAMPLES)
    _ = conn^


# --- the Phase 2 loops -------------------------------------------------------
#
# All four reuse a single connection: `Connection.open` is already covered by
# the main loop above, and at ~4 ms a round trip it is what the loop should be
# spending its time on. The payloads are PAYLOAD_BYTES wide for the same
# reason as in the Phase 1 loops -- see `PAYLOAD_BYTES`.


def test_execute_params_does_not_leak() raises:
    if _skip_on_macos("test_execute_params_does_not_leak"):
        return
    var conn = _connect(_conninfo())
    # Two owners have to free per iteration here, not one: the `_ParamBuffers`
    # holding the bound values on the way out, and the `PGresult` holding them
    # again on the way back (text format, so the bytea arrives hex-encoded and
    # the result is the wider of the two).
    var params: List[Param] = [
        _payload_bytes(PAYLOAD_BYTES),
        _payload(PAYLOAD_BYTES),
    ]
    var every = (MAIN_ITERATIONS - MAIN_WARMUP) // MAIN_SAMPLES
    var samples = List[Int]()
    for i in range(MAIN_ITERATIONS):
        var result = _execute_params(conn, "SELECT $1::bytea, $2::text", params)
        _ = result^
        if _is_sample_due(i, MAIN_WARMUP, every):
            _sample("execute(sql, params)", samples)
    _assert_stable("execute(sql, params)", samples, MAIN_SAMPLES)
    _ = conn^


def test_prepared_does_not_leak() raises:
    if _skip_on_macos("test_prepared_does_not_leak"):
        return
    var conn = _connect(_conninfo())
    # Four results per iteration: PQprepare's, PQdescribePrepared's,
    # PQexecPrepared's, and the one the DEALLOCATE in
    # `PreparedStatement.__deinit__` gets back. Only the third is big, and
    # only the fourth is cleared by hand rather than by a `Result`.
    var sql = "SELECT repeat('x', " + String(PAYLOAD_BYTES) + ") WHERE $1 = 1"
    var params: List[Param] = [Int32(1)]
    var every = (MAIN_ITERATIONS - MAIN_WARMUP) // MAIN_SAMPLES
    var samples = List[Int]()
    for i in range(MAIN_ITERATIONS):
        var stmt = _prepare(conn, sql.copy())
        var result = _stmt_execute(stmt, params)
        _ = result^
        _ = stmt^
        if _is_sample_due(i, MAIN_WARMUP, every):
            _sample("prepare/execute/drop", samples)
    _assert_stable("prepare/execute/drop", samples, MAIN_SAMPLES)
    _ = conn^


def test_transaction_commit_does_not_leak() raises:
    if _skip_on_macos("test_transaction_commit_does_not_leak"):
        return
    var conn = _connect(_conninfo())
    var sql = "SELECT repeat('x', " + String(PAYLOAD_BYTES) + ")"
    var every = (MAIN_ITERATIONS - MAIN_WARMUP) // MAIN_SAMPLES
    var samples = List[Int]()
    for i in range(MAIN_ITERATIONS):
        var tx = _transaction(conn)
        var result = _tx_execute(tx, sql.copy())
        _ = result^
        # The last use of `tx`, as the `Transaction` docstring requires: the
        # BEGIN and COMMIT results both go through `Connection.execute`, so
        # a `Result` owns them.
        _tx_commit(tx)
        if _is_sample_due(i, MAIN_WARMUP, every):
            _sample("transaction/commit", samples)
    _assert_stable("transaction/commit", samples, MAIN_SAMPLES)
    _ = conn^


def test_transaction_drop_does_not_leak() raises:
    if _skip_on_macos("test_transaction_drop_does_not_leak"):
        return
    var conn = _connect(_conninfo())
    var sql = "SELECT repeat('x', " + String(PAYLOAD_BYTES) + ")"
    var every = (MAIN_ITERATIONS - MAIN_WARMUP) // MAIN_SAMPLES
    var samples = List[Int]()
    for i in range(MAIN_ITERATIONS):
        var tx = _transaction(conn)
        var result = _tx_execute(tx, sql.copy())
        _ = result^
        # Dropping `tx` uncommitted runs the implicit ROLLBACK in
        # `Transaction.__deinit__`, which cannot raise and so calls `PQexec`
        # and `PQclear` directly instead of going through `Result`.
        _ = tx^
        if _is_sample_due(i, MAIN_WARMUP, every):
            _sample("transaction/drop", samples)
    _assert_stable("transaction/drop", samples, MAIN_SAMPLES)
    _ = conn^


# --- the Phase 3 loops -------------------------------------------------------
#
# Both reuse one connection, like the Phase 2 loops, and run the same
# statement: `PHASE3_SQL`. What differs is what the client does with the
# answer -- decode every column, or borrow one of them -- which is exactly the
# pair of paths Phase 3 added.


def test_binary_execute_does_not_leak() raises:
    if _skip_on_macos("test_binary_execute_does_not_leak"):
        return
    var conn = _connect(_conninfo())
    # Three owners per iteration: the `_ParamBuffers` holding the encoded
    # numeric and date, the `PGresult` holding the binary row, and the
    # `String`s and `List`s the decoders build out of it. Only the first two
    # are libpq's, and only they would show up as a leak here.
    var params = _phase3_params()
    var every = (MAIN_ITERATIONS - MAIN_WARMUP) // MAIN_SAMPLES
    var samples = List[Int]()
    for i in range(MAIN_ITERATIONS):
        var checksum = _read_binary_row(conn, params)
        _ = checksum
        if _is_sample_due(i, MAIN_WARMUP, every):
            _sample("binary-execute", samples)
    _assert_stable("binary-execute", samples, MAIN_SAMPLES)
    _ = conn^


def test_zero_copy_does_not_leak() raises:
    if _skip_on_macos("test_zero_copy_does_not_leak"):
        return
    var conn = _connect(_conninfo())
    # `get_text` hands back a slice of the `PGresult`'s own storage, so the
    # iteration allocates nothing of its own and the `PGresult` is the only
    # thing that has to go. A slice that kept the result alive past the end of
    # the iteration -- the one way this API could leak -- grows RSS by
    # PAYLOAD_BYTES a time.
    var params = _phase3_params()
    var every = (MAIN_ITERATIONS - MAIN_WARMUP) // MAIN_SAMPLES
    var samples = List[Int]()
    for i in range(MAIN_ITERATIONS):
        var length = _read_text_slice(conn, params)
        _ = length
        if _is_sample_due(i, MAIN_WARMUP, every):
            _sample("zero-copy", samples)
    _assert_stable("zero-copy", samples, MAIN_SAMPLES)
    _ = conn^


# --- the Phase 4 loops -------------------------------------------------------
#
# `AsyncConnection` collects its results through `PQgetResult` and owns two
# libpq allocations the synchronous side never sees -- a `PGcancel` and a
# `PGnotify` -- so each of the three frees it is responsible for gets a loop,
# plus one for the ordinary round trip. Only the drop loop reconnects per
# iteration, because the drop is the thing being measured.


def test_async_execute_does_not_leak() raises:
    if _skip_on_macos("test_async_execute_does_not_leak"):
        return
    var conn = _async_connect(_conninfo())
    # The same PAYLOAD_BYTES row as the synchronous main loop, but adopted by
    # `fetch_all` rather than `execute`: results arrive one `PQgetResult` at a
    # time and the terminating NULL has to be collected as well, so a
    # collector that stopped at the first result would strand a `PGresult`
    # here -- and only here, since the other three loops free something else.
    var sql = "SELECT repeat('x', " + String(PAYLOAD_BYTES) + ")"
    var every = (MAIN_ITERATIONS - MAIN_WARMUP) // MAIN_SAMPLES
    var samples = List[Int]()
    for i in range(MAIN_ITERATIONS):
        _async_send(conn, sql.copy())
        var results = _async_fetch_all(conn, 5000)
        _ = results^
        if _is_sample_due(i, MAIN_WARMUP, every):
            _sample("async-execute", samples)
    _assert_stable("async-execute", samples, MAIN_SAMPLES)
    _ = conn^


def test_async_cancel_does_not_leak() raises:
    if _skip_on_macos("test_async_cancel_does_not_leak"):
        return
    var conn = _async_connect(_conninfo())
    # `cancel` is the only caller of `PQgetCancel` and `PQfreeCancel`, and the
    # `PGcancel` it borrows is a few hundred bytes -- nothing this loop can
    # inflate, and far too little for RSS to see at ERROR_ITERATIONS
    # iterations: with `PQfreeCancel` deleted this loop still came in flat
    # (measured, four identical samples). So this is not where a missing
    # `PQfreeCancel` is caught; it runs the pair ERROR_ITERATIONS times to
    # show the path is stable and leaves the free itself to review.
    # `tests/test_async.mojo` covers what `cancel` does; what matters here is
    # that it is called in a loop at all.
    var every = (ERROR_ITERATIONS - ERROR_WARMUP) // ERROR_SAMPLES
    var samples = List[Int]()
    for i in range(ERROR_ITERATIONS):
        _async_send(conn, "SELECT 1")
        _async_cancel(conn)
        _ = _collect_cancelled(conn, 5000)
        if _is_sample_due(i, ERROR_WARMUP, every):
            _sample("async-cancel", samples)
    _assert_stable("async-cancel", samples, ERROR_SAMPLES)
    _ = conn^


def test_notify_receive_does_not_leak() raises:
    if _skip_on_macos("test_notify_receive_does_not_leak"):
        return
    var listener = _async_connect(_conninfo())
    var channel = String("pq_leak_notify")
    _async_listen(listener, channel.copy())
    # The notifications come from a synchronous connection, as they must: a
    # backend delivers them at commit, and this one autocommits each NOTIFY.
    var sender = _connect(_conninfo())
    var notify = "NOTIFY " + channel + ", '" + _notify_payload() + "'"
    var every = (ERROR_ITERATIONS - ERROR_WARMUP) // ERROR_SAMPLES
    var samples = List[Int]()
    for i in range(ERROR_ITERATIONS):
        var sent = _execute(sender, notify.copy())
        _ = sent^
        # Reading the payload length is what proves the `PGnotify` was there
        # to free: `notifications` copies both strings out of it and frees it
        # before returning, so a forgotten `PQfreemem` strands
        # NOTIFY_PAYLOAD_BYTES per iteration.
        var received = _async_wait_notification(listener, 2000)
        assert_true(Bool(received), "no notification within 2 s")
        assert_equal(
            received.value().payload.byte_length(), NOTIFY_PAYLOAD_BYTES
        )
        if _is_sample_due(i, ERROR_WARMUP, every):
            _sample("notify-receive", samples)
    _assert_stable("notify-receive", samples, ERROR_SAMPLES)
    _ = sender^
    _ = listener^


def test_async_drop_with_pending_results_does_not_leak() raises:
    if _skip_on_macos("test_async_drop_with_pending_results_does_not_leak"):
        return
    var conninfo = _conninfo()
    # Two statements in flight, the first PAYLOAD_BYTES wide, and neither
    # result ever collected: dropping the connection leaves the `PQfinish` in
    # `__deinit__` as the only thing that can clear them, which is exactly
    # what that one-line destructor relies on. The `consume_input` first puts
    # the results in libpq's own buffer, so the drop has something to free
    # rather than just a socket to close.
    var sql = "SELECT repeat('x', " + String(PAYLOAD_BYTES) + "); SELECT 2"
    var every = (ERROR_ITERATIONS - ERROR_WARMUP) // ERROR_SAMPLES
    var samples = List[Int]()
    for i in range(ERROR_ITERATIONS):
        var conn = _async_connect(conninfo.copy())
        _async_send(conn, sql.copy())
        _async_wait_readable(conn, 5000)
        _async_consume_input(conn)
        _ = conn^
        if _is_sample_due(i, ERROR_WARMUP, every):
            _sample("async-drop", samples)
    _assert_stable("async-drop", samples, ERROR_SAMPLES)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
