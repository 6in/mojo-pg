"""Leak tests: long loops over connect / query / close and the failure paths.

Every `Connection` owns a `PGconn` and every `Result` owns a `PGresult`, so a
missing `PQfinish` / `PQclear` / `PQfreemem` shows up as resident memory that
only grows. These tests run each path thousands of times and watch the
process's RSS instead of asking libpq for a count: that catches a leak no
matter which of the three frees was forgotten.

RSS is sampled from `/proc/self/statm`, which only exists on Linux. On macOS
the loops are skipped rather than reimplemented: `is_leaking` is still covered
by its own unit tests there, and CI runs Linux.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI: these tests append ` password=...` to it).

This file is slow by design (the main loop alone is ~35 s per server). The
`is_leaking` unit tests need no database and are declared first so a broken
verdict fails before any loop runs.
"""

from std.os import getenv
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pq.connection import Connection
from pq.errors import PgError
from pq.result import Result

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime WRONG_PASSWORD: StaticString = "WRONG_pw_123"
"""A password that always fails authentication, to drive the failed-open path."""

comptime TOLERANCE_PAGES = 16
"""How much total RSS growth (in pages) a non-leaking loop may show.

The allocator and libpq both keep caches that settle over the first few
hundred iterations, so a flat-but-not-identical sample series is normal. 16
pages (64 KiB on Linux) is far below what a per-iteration leak of a `PGconn`
or `PGresult` would produce over a thousand iterations.
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
    return samples[len(samples) - 1] - samples[0] > tolerance_pages


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


def _skip_on_macos() -> Bool:
    """Report whether RSS sampling is unavailable, printing a skip notice.

    Returns:
        True on macOS (the caller must return without sampling).
    """
    if CompilationTarget.is_macos():
        print("SKIP: RSS sampling is Linux-only")
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


# --- the loops ---------------------------------------------------------------


def test_connect_query_close_does_not_leak() raises:
    if _skip_on_macos():
        return
    var conninfo = _conninfo()
    var every = (MAIN_ITERATIONS - MAIN_WARMUP) // MAIN_SAMPLES
    var samples = List[Int]()
    for i in range(MAIN_ITERATIONS):
        var conn = _connect(conninfo.copy())
        var result = _execute(conn, "SELECT 1")
        _ = result^
        _ = conn^
        if _is_sample_due(i, MAIN_WARMUP, every):
            samples.append(rss_pages())
    assert_equal(len(samples), MAIN_SAMPLES)
    assert_false(
        is_leaking(samples, TOLERANCE_PAGES),
        "connect/query/close RSS pages: " + _describe(samples),
    )


def test_failed_open_does_not_leak() raises:
    if _skip_on_macos():
        return
    # libpq takes the last value given for a repeated key, so appending
    # `password=...` overrides the real one.
    var conninfo = _conninfo() + " password=" + WRONG_PASSWORD
    var every = (ERROR_ITERATIONS - ERROR_WARMUP) // ERROR_SAMPLES
    var samples = List[Int]()
    for i in range(ERROR_ITERATIONS):
        var error = _open_error(conninfo.copy())
        _ = error^
        if _is_sample_due(i, ERROR_WARMUP, every):
            samples.append(rss_pages())
    assert_equal(len(samples), ERROR_SAMPLES)
    assert_false(
        is_leaking(samples, TOLERANCE_PAGES),
        "failed-open RSS pages: " + _describe(samples),
    )


def test_escape_literal_does_not_leak() raises:
    if _skip_on_macos():
        return
    var conn = _connect(_conninfo())
    var every = (ERROR_ITERATIONS - ERROR_WARMUP) // ERROR_SAMPLES
    var samples = List[Int]()
    for i in range(ERROR_ITERATIONS):
        var quoted = _escape_literal(conn, "O'Reilly")
        _ = quoted^
        if _is_sample_due(i, ERROR_WARMUP, every):
            samples.append(rss_pages())
    assert_equal(len(samples), ERROR_SAMPLES)
    assert_false(
        is_leaking(samples, TOLERANCE_PAGES),
        "escape_literal RSS pages: " + _describe(samples),
    )
    _ = conn^


def test_failed_execute_does_not_leak() raises:
    if _skip_on_macos():
        return
    var conn = _connect(_conninfo())
    var every = (ERROR_ITERATIONS - ERROR_WARMUP) // ERROR_SAMPLES
    var samples = List[Int]()
    for i in range(ERROR_ITERATIONS):
        var error = _execute_error(conn, "SELEC 1")
        _ = error^
        if _is_sample_due(i, ERROR_WARMUP, every):
            samples.append(rss_pages())
    assert_equal(len(samples), ERROR_SAMPLES)
    assert_false(
        is_leaking(samples, TOLERANCE_PAGES),
        "failed-execute RSS pages: " + _describe(samples),
    )
    _ = conn^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
