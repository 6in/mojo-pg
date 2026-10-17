"""Tests for `pq.async_conn` against a live PostgreSQL server.

Everything here holds on PG14 and PG17 alike: the two servers differ only in
how a round trip is timed, never in a status, SQLSTATE or message this file
asserts.

Three habits the asynchronous API imposes on its tests:

- **Never assert `Sending`.** How much of a command the kernel accepts in one
  write is not reproducible, so `send` may leave the connection `Sending` or
  `Busy`. Tests loop on `flush` and assert the result instead.
- **Never assert which direction the handshake wants first.**
  `poll_connect`'s first answer is `NeedRead` or `NeedWrite` depending on how
  far the kernel got with the connect; the loop acts on the answer.
- **Elapsed time is measured with `std.time.monotonic`** (nanoseconds), and
  asserted as a lower bound plus a generous upper one, never as a window
  narrow enough for a loaded machine to miss.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only). The
timeout test additionally needs the `blackhole` service from
`tests/docker-compose.yml` on port 54399 -- a listener that accepts and then
says nothing -- and skips itself when nothing is listening there.
"""

from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import monotonic

from pq._ffi.types import CONNECTION_OK, PQTRANS_IDLE
from pq.async_conn import AsyncConnection, AsyncState, PollState
from pq.errors import PgError, PgErrorKind
from pq.params import Param
from pq.result import Result, ResultFormat

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime BLACKHOLE_CONNINFO = (
    "host=127.0.0.1 port=54399 user=pq password=pq dbname=pq_test"
)
"""A listener that accepts the TCP connection and never answers.

`tests/docker-compose.yml` runs it as `blackhole` (socat to `/dev/null`).
It is what makes a connect *timeout* -- as opposed to a refusal -- testable.
"""


# --- helpers -----------------------------------------------------------------
#
# A `TestSuite` test only declares `raises` (plain `Error`), and `PgError` does
# not implicitly convert to `Error`, so a `raises PgError` API cannot be called
# straight from a test. These wrappers translate in both directions: success
# paths re-raise as `Error`, failure paths hand the `PgError` back for
# inspection.


def _conninfo() -> String:
    """Return the conninfo of the server under test.

    Returns:
        `PQ_TEST_CONNINFO` when set and non-empty, else `DEFAULT_CONNINFO`.
    """
    var value = getenv("PQ_TEST_CONNINFO")
    return value if value != "" else String(DEFAULT_CONNINFO)


def _params() raises -> Dict[String, String]:
    """Split the conninfo of the server under test into keyword/value pairs.

    Returns:
        The conninfo as a `Dict`, suitable for `AsyncConnection.start(Dict)`.
    """
    var conninfo = _conninfo()
    var params = Dict[String, String]()
    var tokens = conninfo.split(" ")
    for token in tokens:
        var pair = String(token).split("=")
        if len(pair) < 2:
            continue
        var value = String(pair[1])
        for i in range(2, len(pair)):
            value += "="
            value += String(pair[i])
        params[String(pair[0])] = value
    return params^


def _start(var conninfo: String) raises -> AsyncConnection:
    """Begin connecting, translating a `PgError` into an `Error`.

    Args:
        conninfo: A libpq `key=value ...` conninfo string.

    Returns:
        The connection, still in state `Connecting`.

    Raises:
        Error: If `AsyncConnection.start` raised a `PgError`.
    """
    try:
        return AsyncConnection.start(conninfo^)
    except e:
        raise Error(String(e))


def _connect_blocking(
    var conninfo: String, timeout_ms: Int
) raises -> AsyncConnection:
    """Connect and wait for the handshake.

    Args:
        conninfo: A libpq `key=value ...` conninfo string.
        timeout_ms: Milliseconds allowed for the whole handshake.

    Returns:
        The connection, in state `Idle`.

    Raises:
        Error: If `connect_blocking` raised a `PgError`.
    """
    try:
        return AsyncConnection.connect_blocking(conninfo^, timeout_ms)
    except e:
        raise Error(String(e))


def _connect_blocking_params(
    params: Dict[String, String], timeout_ms: Int
) raises -> AsyncConnection:
    """Connect from keyword/value parameters and wait for the handshake.

    Args:
        params: Connection parameters, taken literally.
        timeout_ms: Milliseconds allowed for the whole handshake.

    Returns:
        The connection, in state `Idle`.

    Raises:
        Error: If `connect_blocking` raised a `PgError`.
    """
    try:
        return AsyncConnection.connect_blocking(params, timeout_ms)
    except e:
        raise Error(String(e))


def _connect_blocking_error(
    var conninfo: String, timeout_ms: Int
) raises -> PgError:
    """Return the `PgError` raised by a connect that must fail.

    Args:
        conninfo: A conninfo string the connect must not succeed with.
        timeout_ms: Milliseconds allowed for the whole handshake.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the connection succeeded instead of failing.
    """
    try:
        var conn = AsyncConnection.connect_blocking(conninfo^, timeout_ms)
        _ = conn^
    except e:
        return e^
    raise Error("expected a PgError from connect_blocking")


def _poll_connect(mut conn: AsyncConnection) raises -> PollState:
    """Advance the handshake one step.

    Args:
        conn: The connecting connection.

    Returns:
        What `poll_connect` asked for.

    Raises:
        Error: If `poll_connect` raised a `PgError`.
    """
    try:
        return conn.poll_connect()
    except e:
        raise Error(String(e))


def _send(mut conn: AsyncConnection, var sql: String) raises:
    """Queue `sql` on `conn`.

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


def _send_params(
    mut conn: AsyncConnection,
    var sql: String,
    params: List[Param],
    result_format: ResultFormat = ResultFormat.TEXT,
) raises:
    """Queue one parameterised statement on `conn`.

    Args:
        conn: The idle connection.
        sql: Exactly one SQL statement with `$1`..`$n` placeholders.
        params: The values to bind.
        result_format: Wire format asked of the server.

    Raises:
        Error: If `send` raised a `PgError`.
    """
    try:
        conn.send(sql^, params, result_format=result_format)
    except e:
        raise Error(String(e))


def _send_prepare(
    mut conn: AsyncConnection, var name: String, var sql: String
) raises:
    """Queue a `PREPARE` of `sql` under `name`.

    Args:
        conn: The idle connection.
        name: The name to prepare under.
        sql: Exactly one SQL statement.

    Raises:
        Error: If `send_prepare` raised a `PgError`.
    """
    try:
        conn.send_prepare(name^, sql^)
    except e:
        raise Error(String(e))


def _send_prepared(
    mut conn: AsyncConnection, var name: String, params: List[Param]
) raises:
    """Queue an execution of the prepared statement `name`.

    Args:
        conn: The idle connection.
        name: The name the statement was prepared under.
        params: The values to bind.

    Raises:
        Error: If `send_prepared` raised a `PgError`.
    """
    try:
        conn.send_prepared(name^, params)
    except e:
        raise Error(String(e))


def _send_error(mut conn: AsyncConnection, var sql: String) raises -> PgError:
    """Return the `PgError` raised by a `send` that must be rejected.

    Args:
        conn: The connection under test.
        sql: The statement that must not be accepted.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the `send` succeeded instead of failing.
    """
    try:
        conn.send(sql^)
    except e:
        return e^
    raise Error("expected a PgError from send")


def _fetch_all(
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


def _fetch_all_error(
    mut conn: AsyncConnection, timeout_ms: Int
) raises -> PgError:
    """Return the `PgError` raised by a `fetch_all` that must fail.

    Args:
        conn: The connection with a failing command in flight.
        timeout_ms: Milliseconds allowed for the whole command.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the command succeeded instead of failing.
    """
    try:
        var results = conn.fetch_all(timeout_ms)
        _ = results^
    except e:
        return e^
    raise Error("expected a PgError from fetch_all")


def _poll_result(mut conn: AsyncConnection) raises -> Optional[Result]:
    """Collect the next result of the command in flight, if one is ready.

    Args:
        conn: The connection with a command in flight.

    Returns:
        The next `Result`, or None.

    Raises:
        Error: If `poll_result` raised a `PgError`.
    """
    try:
        return conn.poll_result()
    except e:
        raise Error(String(e))


def _poll_result_error(mut conn: AsyncConnection) raises -> PgError:
    """Poll until the command in flight raises, and return that error.

    Waits for readability between polls, so a statement that takes a moment
    to fail is still collected.

    Args:
        conn: The connection with a failing command in flight.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the command produced only results and no error.
    """
    while True:
        var got: Optional[Result]
        try:
            got = conn.poll_result()
        except e:
            return e^
        if not got:
            if conn.state() == AsyncState.IDLE:
                raise Error("expected a PgError from poll_result")
            _wait_readable_allowing_timeout(conn, 2000)


def _poll_to_idle(mut conn: AsyncConnection) raises:
    """Poll until the command in flight ends, expecting no further result.

    One more `poll_result` is *not* enough to end a command: the NULL result
    that ends it may not have arrived yet, in which case the poll answers
    None while the state is still `Busy`. That is the documented meaning of
    a None, so the loop is the contract and a single call would be a timing
    assumption.

    Args:
        conn: The connection whose command should be drained.

    Raises:
        Error: If another result arrives, or a poll or wait fails.
    """
    while conn.state() != AsyncState.IDLE:
        var got = _poll_result(conn)
        assert_false(Bool(got), "an extra result arrived after the command")
        if conn.state() == AsyncState.IDLE:
            return
        _wait_readable_allowing_timeout(conn, 2000)


def _wait_readable(mut conn: AsyncConnection, timeout_ms: Int) raises:
    """Wait until the connection's socket is readable.

    Args:
        conn: The connection to wait on.
        timeout_ms: Milliseconds to wait.

    Raises:
        Error: If `wait_readable` raised a `PgError`.
    """
    try:
        conn.wait_readable(timeout_ms)
    except e:
        raise Error(String(e))


def _wait_writable(mut conn: AsyncConnection, timeout_ms: Int) raises:
    """Wait until the connection's socket is writable.

    Args:
        conn: The connection to wait on.
        timeout_ms: Milliseconds to wait.

    Raises:
        Error: If `wait_writable` raised a `PgError`.
    """
    try:
        conn.wait_writable(timeout_ms)
    except e:
        raise Error(String(e))


def _wait_readable_error(
    mut conn: AsyncConnection, timeout_ms: Int
) raises -> PgError:
    """Return the `PgError` raised by a wait that must not succeed.

    Args:
        conn: The connection to wait on.
        timeout_ms: Milliseconds to wait.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the socket became readable instead.
    """
    try:
        conn.wait_readable(timeout_ms)
    except e:
        return e^
    raise Error("expected a PgError from wait_readable")


def _wait_readable_allowing_timeout(
    mut conn: AsyncConnection, timeout_ms: Int
) raises:
    """Wait for readability, treating a timeout as nothing having happened.

    This is the shape of a hand-written poll loop: the budget bounds one
    iteration rather than the whole command, so its expiry is not a failure.

    Args:
        conn: The connection to wait on.
        timeout_ms: Milliseconds to wait before giving up on this iteration.

    Raises:
        Error: If the wait failed for any reason other than the timeout.
    """
    try:
        conn.wait_readable(timeout_ms)
    except e:
        if e.kind != PgErrorKind.TIMEOUT:
            raise Error(String(e))


def _text_at(res: Result, row: Int, col: Int) raises -> String:
    """Read one column of one row as text.

    Args:
        res: The result to read from.
        row: Zero-based row index.
        col: Zero-based column index.

    Returns:
        The column value as a `String`.

    Raises:
        Error: If the read raised a `PgError`.
    """
    try:
        return res[row].get[String](col)
    except e:
        raise Error(String(e))


def _int32_at(res: Result, row: Int, col: Int) raises -> Int32:
    """Read one column of one row as `Int32`.

    Args:
        res: The result to read from.
        row: Zero-based row index.
        col: Zero-based column index.

    Returns:
        The column value.

    Raises:
        Error: If the read raised a `PgError`.
    """
    try:
        return res[row].get[Int32](col)
    except e:
        raise Error(String(e))


def _int64_at(res: Result, row: Int, col: Int) raises -> Int64:
    """Read one column of one row as `Int64`.

    Args:
        res: The result to read from.
        row: Zero-based row index.
        col: Zero-based column index.

    Returns:
        The column value.

    Raises:
        Error: If the read raised a `PgError`.
    """
    try:
        return res[row].get[Int64](col)
    except e:
        raise Error(String(e))


def _column_format(res: Result, col: Int) raises -> ResultFormat:
    """Read the wire format one column of a result arrived in.

    Args:
        res: The result to inspect.
        col: Zero-based column index.

    Returns:
        The column's `ResultFormat`.

    Raises:
        Error: If the read raised a `PgError`.
    """
    try:
        return res.column_format(col)
    except e:
        raise Error(String(e))


def _elapsed_ms(since: Int) raises -> Int:
    """Return the milliseconds elapsed since a `monotonic()` reading.

    Args:
        since: An earlier `std.time.monotonic()` value, in nanoseconds.

    Returns:
        Whole milliseconds elapsed.
    """
    return (monotonic() - since) // 1_000_000


# --- tests -------------------------------------------------------------------


def test_connect_blocking_pins_session_settings() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    assert_true(conn.state() == AsyncState.IDLE)
    assert_equal(conn.status(), Int(CONNECTION_OK))
    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))
    assert_true(conn.socket() >= 0, "no socket on an open connection")
    # The session setup SET that poll_connect sends is two statements, so
    # both GUCs must be pinned by the time the connection is Idle.
    _send(conn, "SHOW DateStyle")
    var styles = _fetch_all(conn, 5000)
    assert_equal(len(styles), 1)
    assert_equal(_text_at(styles[0], 0, 0), "ISO, YMD")
    _send(conn, "SHOW IntervalStyle")
    var intervals = _fetch_all(conn, 5000)
    assert_equal(len(intervals), 1)
    assert_equal(_text_at(intervals[0], 0, 0), "postgres")


def test_connect_blocking_from_params() raises:
    var conn = _connect_blocking_params(_params(), 5000)
    assert_true(conn.state() == AsyncState.IDLE)
    _send(conn, "SHOW DateStyle")
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 1)
    assert_equal(_text_at(results[0], 0, 0), "ISO, YMD")


def test_manual_connect_polling() raises:
    var conn = _start(_conninfo())
    assert_true(conn.state() == AsyncState.CONNECTING)
    var step = _poll_connect(conn)
    # Which direction libpq wants first depends on how far the kernel got
    # with the connect, so only "not ready yet" is asserted.
    assert_true(
        step == PollState.NEED_READ or step == PollState.NEED_WRITE,
        "first poll_connect answered " + String(step),
    )
    while step != PollState.READY:
        if step == PollState.NEED_WRITE:
            _wait_writable(conn, 2000)
        else:
            _wait_readable(conn, 2000)
        step = _poll_connect(conn)
    assert_true(conn.state() == AsyncState.IDLE)
    # Calling it again is a no-op: PQconnectPoll must not run once the
    # connection is up.
    assert_true(_poll_connect(conn) == PollState.READY)
    assert_true(conn.state() == AsyncState.IDLE)


def test_poll_result_counts_while_sleeping() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    var started = monotonic()
    _send(conn, "SELECT pg_sleep(2), 1")
    var polls = 0
    while True:
        var got = _poll_result(conn)
        if got:
            var res = got.take()
            assert_equal(res.row_count(), 1)
            assert_equal(_int32_at(res, 0, 1), Int32(1))
            break
        assert_true(
            conn.state() == AsyncState.BUSY,
            "command ended without a result",
        )
        polls += 1
        _wait_readable_allowing_timeout(conn, 100)
    var took = _elapsed_ms(started)
    assert_true(polls >= 1, "never observed an empty poll")
    assert_true(took >= 2000, "pg_sleep(2) took only " + String(took) + " ms")
    # The NULL result is what ends the command and returns the connection.
    _poll_to_idle(conn)


def test_multi_statement_and_empty_query() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    _send(conn, "SELECT 1; SELECT 2; SELECT 3")
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 3)
    assert_equal(_int32_at(results[0], 0, 0), Int32(1))
    assert_equal(_int32_at(results[1], 0, 0), Int32(2))
    assert_equal(_int32_at(results[2], 0, 0), Int32(3))
    assert_true(conn.state() == AsyncState.IDLE)
    # An empty statement is classified by `adopt_result`, the same function
    # the synchronous path uses, so the wording is shared.
    _send(conn, "")
    var error = _fetch_all_error(conn, 5000)
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.message, "empty query")
    assert_true(conn.state() == AsyncState.IDLE)


def test_recovers_after_statement_error() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    _send(conn, "SELECT 1/0")
    var error = _poll_result_error(conn)
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.sqlstate, "22012")
    assert_true(error.message.find("division by zero") >= 0, error.message)
    # The raise left the command in flight: the NULL result has not been read
    # yet, so the connection is still Busy and polling on is what ends it.
    assert_true(conn.state() == AsyncState.BUSY)
    _poll_to_idle(conn)
    _send(conn, "SELECT 1")
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 1)
    assert_equal(_int32_at(results[0], 0, 0), Int32(1))


def test_connect_blocking_times_out() raises:
    # The blackhole listener accepts and never answers, which is the only way
    # to tell a timeout from a refusal. Skip when it is not running.
    var started = monotonic()
    var error = _connect_blocking_error(String(BLACKHOLE_CONNINFO), 500)
    var took = _elapsed_ms(started)
    if error.message.find("Connection refused") >= 0:
        print("SKIP test_connect_blocking_times_out: port 54399 refused")
        return
    assert_true(error.kind == PgErrorKind.TIMEOUT, String(error))
    assert_true(error.message.find("timed out after") >= 0, error.message)
    assert_true(took >= 500, "gave up after only " + String(took) + " ms")
    assert_true(took < 1500, "took " + String(took) + " ms for a 500 ms budget")
    # The same budget on an open connection: nothing arrives on an idle
    # socket, while a write is always possible, so only the read times out.
    var conn = _connect_blocking(_conninfo(), 5000)
    var waited = _wait_readable_error(conn, 50)
    assert_true(waited.kind == PgErrorKind.TIMEOUT, String(waited))
    assert_true(waited.message.find("timed out after") >= 0, waited.message)
    _wait_writable(conn, 0)


def test_send_params_and_prepared_statements() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    _send_params(
        conn,
        "SELECT $1::int4 + 1, $2::text",
        [Int32(41), "hello-param"],
        result_format=ResultFormat.BINARY,
    )
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 1)
    assert_true(_column_format(results[0], 0) == ResultFormat.BINARY)
    assert_equal(_int32_at(results[0], 0, 0), Int32(42))
    assert_equal(_text_at(results[0], 0, 1), "hello-param")
    # PQsendPrepare answers with one result that carries no rows and no tag.
    _send_prepare(conn, "p1", "SELECT $1::int8 * 2")
    var prepared = _fetch_all(conn, 5000)
    assert_equal(len(prepared), 1)
    assert_equal(prepared[0].command_tag(), "")
    _send_prepared(conn, "p1", [Int64(21)])
    var used = _fetch_all(conn, 5000)
    assert_equal(len(used), 1)
    assert_equal(_int64_at(used[0], 0, 0), Int64(42))
    # An unknown name is the server's error, reported when the results are
    # collected rather than when the command is queued.
    _send_prepared(conn, "nope", List[Param]())
    var error = _fetch_all_error(conn, 5000)
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.sqlstate, "26000")
    assert_true(conn.state() == AsyncState.IDLE)


def test_send_while_connecting_is_usage() raises:
    var conn = _start(_conninfo())
    assert_true(conn.state() == AsyncState.CONNECTING)
    var error = _send_error(conn, "SELECT 1")
    assert_true(error.kind == PgErrorKind.USAGE, String(error))
    assert_equal(error.message, "send() called while Connecting")
    # Nothing was sent, so there is no server diagnostic to carry, and in
    # particular libpq's own "no connection to the server" is absent.
    assert_equal(error.sqlstate, "")
    assert_false(error.message.find("no connection") >= 0)


# --- 第 2 弾は T5 ---


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
