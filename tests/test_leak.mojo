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

This file is slow by design: the main loop alone is ~35 s per server once the
binary is built, on top of the one-off `mojo build`. The `is_leaking` unit
tests need no database and are declared first so a broken verdict fails
before any loop runs.
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

Measured on PG14 and PG17, with this file run as the binary `mojo build`
produces (the only way `tests/run_tests.sh` runs it): a non-leaking loop is
stable to within 2 pages, except for a *single* one-off step of exactly 83
pages (~332 KiB) that lands at an arbitrary iteration of an arbitrary loop — a
lazy first-use allocation somewhere under libpq, not per-iteration growth. 256
pages (1 MiB) clears two such steps.

The step is why the tolerance is not tightened to 16 pages: over 16 built-binary
series (4 loops x 2 servers x 2 runs) 14 came in at 0-2 pages of total growth
and 2 showed the 83-page step, once at the 4th sample and once at the 9th.

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


# --- the loops ---------------------------------------------------------------


def test_connect_query_close_does_not_leak() raises:
    if _skip_on_macos():
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
    if _skip_on_macos():
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
    if _skip_on_macos():
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
    if _skip_on_macos():
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
