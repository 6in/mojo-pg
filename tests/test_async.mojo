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

from std.ffi import c_int, external_call
from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import monotonic

from pq._ffi.types import (
    CONNECTION_BAD,
    CONNECTION_OK,
    PQTRANS_IDLE,
    PQTRANS_INERROR,
)
from pq.async_conn import AsyncConnection, AsyncState, PollState
from pq.connection import Connection
from pq.errors import PgError, PgErrorKind
from pq.params import Param
from pq.result import Result, ResultFormat

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime WRONG_PASSWORD: StaticString = "WRONG_pw_123"
"""A password that must never reach a `PgError.message`."""

comptime NUL_MARKER: StaticString = "AFTER_NUL_MARKER"
"""Text placed *after* an embedded NUL byte in a rejected argument.

libpq takes C strings, so everything from the NUL onwards is invisible to it.
The marker is what proves the truncated tail never reached libpq and never
came back in a message.
"""

comptime BIG_STATEMENT_BYTES = 16_000_000
"""Length of the literal in the statement that cannot be written in one go.

Far past any socket send buffer, so `send` has to leave part of the command
queued and `flush` has something to push -- which is the only way to exercise
state `SENDING` at all.
"""

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


def _cancel(mut conn: AsyncConnection) raises:
    """Ask the server to abandon whatever `conn` is running.

    Args:
        conn: The connection to cancel on.

    Raises:
        Error: If `cancel` raised a `PgError`.
    """
    try:
        conn.cancel()
    except e:
        raise Error(String(e))


def _set_single_row_mode(mut conn: AsyncConnection) raises:
    """Switch the command just sent on `conn` to one result per row.

    Args:
        conn: The connection with a freshly sent command.

    Raises:
        Error: If `set_single_row_mode` raised a `PgError`.
    """
    try:
        conn.set_single_row_mode()
    except e:
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


# --- helpers added for the second batch --------------------------------------


def _start_error(var conninfo: String) raises -> PgError:
    """Return the `PgError` raised by a `start` that must fail.

    Args:
        conninfo: A conninfo string libpq must reject outright.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `start` succeeded instead of failing.
    """
    try:
        var conn = AsyncConnection.start(conninfo^)
        _ = conn^
    except e:
        return e^
    raise Error("expected a PgError from start")


def _poll_connect_to_failure(mut conn: AsyncConnection) raises -> PgError:
    """Drive a handshake that must fail, and return the error it fails with.

    Args:
        conn: A connection in state `Connecting`.

    Returns:
        The raised `PgError`, from either the poll or a wait.

    Raises:
        Error: If the handshake completed instead.
    """
    while True:
        var step: PollState
        try:
            step = conn.poll_connect()
        except e:
            return e^
        if step == PollState.READY:
            raise Error("the handshake unexpectedly succeeded")
        try:
            if step == PollState.NEED_WRITE:
                conn.wait_writable(2000)
            else:
                conn.wait_readable(2000)
        except e:
            return e^


def _poll_to_ready(mut conn: AsyncConnection) raises:
    """Drive a handshake to completion by hand.

    Args:
        conn: A connection in state `Connecting`.

    Raises:
        Error: If a poll or a wait raised a `PgError`.
    """
    var step = _poll_connect(conn)
    while step != PollState.READY:
        if step == PollState.NEED_WRITE:
            _wait_writable(conn, 2000)
        else:
            _wait_readable(conn, 2000)
        step = _poll_connect(conn)


def _send_prepare_error(
    mut conn: AsyncConnection, var name: String, var sql: String
) raises -> PgError:
    """Return the `PgError` raised by a `send_prepare` that must be rejected.

    Args:
        conn: The connection under test.
        name: The name to prepare under.
        sql: The statement that must not be accepted.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the `send_prepare` succeeded instead of failing.
    """
    try:
        conn.send_prepare(name^, sql^)
    except e:
        return e^
    raise Error("expected a PgError from send_prepare")


def _send_prepared_error(
    mut conn: AsyncConnection, var name: String, params: List[Param]
) raises -> PgError:
    """Return the `PgError` raised by a `send_prepared` that must be rejected.

    Args:
        conn: The connection under test.
        name: The name the statement was prepared under.
        params: The values to bind.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the `send_prepared` succeeded instead of failing.
    """
    try:
        conn.send_prepared(name^, params)
    except e:
        return e^
    raise Error("expected a PgError from send_prepared")


def _flush(mut conn: AsyncConnection) raises -> Bool:
    """Push more of a queued command onto the socket.

    Args:
        conn: The connection with a command queued.

    Returns:
        True once the command is fully written.

    Raises:
        Error: If `flush` raised a `PgError`.
    """
    try:
        return conn.flush()
    except e:
        raise Error(String(e))


def _consume_input(mut conn: AsyncConnection) raises:
    """Read whatever has arrived on the socket into libpq's buffer.

    Args:
        conn: The connection to read on.

    Raises:
        Error: If `consume_input` raised a `PgError`.
    """
    try:
        conn.consume_input()
    except e:
        raise Error(String(e))


def _consume_input_error(mut conn: AsyncConnection) raises -> PgError:
    """Return the `PgError` raised by a `consume_input` that must be refused.

    Args:
        conn: The connection under test.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the call succeeded instead of failing.
    """
    try:
        conn.consume_input()
    except e:
        return e^
    raise Error("expected a PgError from consume_input")


def _pause_until_readable(mut conn: AsyncConnection, timeout_ms: Int):
    """Wait a little for the socket, swallowing whatever the wait says.

    Used only to pace a retry loop: a timeout means nothing has arrived yet,
    and a lost connection is what the loop is waiting to observe through a
    real API call, so neither is an error here.

    Args:
        conn: The connection to wait on.
        timeout_ms: Milliseconds to wait at most.
    """
    try:
        conn.wait_readable(timeout_ms)
    except:
        pass


def _consume_input_until_lost(mut conn: AsyncConnection) raises -> PgError:
    """Read the socket until `consume_input` reports the connection gone.

    The loss is not visible on the first read: the kernel has to deliver the
    server's farewell and then the end of the stream, which takes a round
    trip or two.

    Args:
        conn: The connection whose backend has been terminated.

    Returns:
        The `PgError` `consume_input` finally raised.

    Raises:
        Error: If the connection never reported itself lost.
    """
    for _ in range(50):
        try:
            conn.consume_input()
        except e:
            return e^
        _pause_until_readable(conn, 100)
    raise Error("the connection never reported itself lost")


def _cancel_error(mut conn: AsyncConnection) raises -> PgError:
    """Return the `PgError` raised by a `cancel` that must fail.

    Args:
        conn: The connection under test.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the cancel succeeded instead of failing.
    """
    try:
        conn.cancel()
    except e:
        return e^
    raise Error("expected a PgError from cancel")


def _notifications_error(mut conn: AsyncConnection) raises -> PgError:
    """Return the `PgError` raised by a `notifications` that must be refused.

    Args:
        conn: The connection under test.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the call succeeded instead of failing.
    """
    try:
        var found = conn.notifications()
        _ = found^
    except e:
        return e^
    raise Error("expected a PgError from notifications")


def _set_single_row_mode_error(mut conn: AsyncConnection) raises -> PgError:
    """Return the `PgError` raised by a `set_single_row_mode` out of its window.

    Args:
        conn: The connection under test.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the call succeeded instead of failing.
    """
    try:
        conn.set_single_row_mode()
    except e:
        return e^
    raise Error("expected a PgError from set_single_row_mode")


def _poll_until_result(mut conn: AsyncConnection) raises -> Result:
    """Poll until one result of the command in flight is ready.

    Args:
        conn: The connection with a command in flight.

    Returns:
        The next `Result`.

    Raises:
        Error: If the command ended without producing one.
    """
    var got = _poll_result(conn)
    while not got:
        assert_true(
            conn.state() == AsyncState.BUSY,
            "the command ended without a result",
        )
        _wait_readable_allowing_timeout(conn, 2000)
        got = _poll_result(conn)
    return got.take()


def _backend_pid(mut conn: AsyncConnection) raises -> Int:
    """Return the process ID of the backend serving an idle `conn`.

    Args:
        conn: The idle connection.

    Returns:
        `pg_backend_pid()` as an `Int`.

    Raises:
        Error: If the query failed.
    """
    _send(conn, "SELECT pg_backend_pid()")
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 1)
    return Int(_int32_at(results[0], 0, 0))


def _terminate(pid: Int) raises:
    """Kill the backend with process ID `pid` from a second connection.

    A backend cannot be asked to terminate itself and still report the
    administrator's SQLSTATE on the connection under test, so the request
    comes over an ordinary synchronous connection.

    Args:
        pid: The process ID to terminate.

    Raises:
        Error: If the second connection or its statement failed.
    """
    try:
        var killer = Connection.open(_conninfo())
        var res = killer.execute(
            String("SELECT pg_terminate_backend(", pid, ")")
        )
        _ = res^
        _ = killer^
    except e:
        raise Error(String(e))


def _with_nul(prefix: String) -> String:
    """Return `prefix`, a NUL byte, then `NUL_MARKER`.

    Args:
        prefix: The part libpq would still see after truncation.

    Returns:
        A `String` whose `byte_length` counts the NUL, so the embedded byte
        really is part of the value rather than a terminator.
    """
    return prefix + chr(0) + NUL_MARKER


def _assert_nul_error(error: PgError, what: String) raises:
    """Check that `error` is the NUL rejection raised for argument `what`.

    Args:
        error: The error the rejected call raised.
        what: The argument name the message must blame.

    Raises:
        Error: If the kind, the message or the leak check does not hold.
    """
    assert_true(error.kind == PgErrorKind.TYPE_MISMATCH, String(error))
    assert_equal(error.message, "embedded NUL byte in " + what)
    assert_false(error.message.find(NUL_MARKER) >= 0)


def _wait_notification_error(
    mut conn: AsyncConnection, timeout_ms: Int
) raises -> PgError:
    """Return the `PgError` raised by a `wait_notification` that must fail.

    Args:
        conn: The connection to listen on.
        timeout_ms: Milliseconds to wait in total.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the call returned instead of raising.
    """
    try:
        var got = conn.wait_notification(timeout_ms)
        _ = got^
    except e:
        return e^
    raise Error("expected a PgError from wait_notification")


def _assert_timeout_too_large(error: PgError) raises:
    """Check that `error` is the refusal of a budget above the `c_int` bound.

    Args:
        error: The error the refused call raised.

    Raises:
        Error: If the kind or the message does not hold.
    """
    assert_true(error.kind == PgErrorKind.USAGE, String(error))
    assert_true(error.message.find("timeout_ms must be") >= 0, error.message)
    assert_true(error.message.find("2147483647") >= 0, error.message)


def _assert_connecting_usage(error: PgError, method: String) raises:
    """Check that `error` is the refusal of `method` during the handshake.

    Args:
        error: The error the refused call raised.
        method: The method name, without parentheses.

    Raises:
        Error: If the kind, the message or the SQLSTATE does not hold.
    """
    assert_true(error.kind == PgErrorKind.USAGE, String(error))
    assert_equal(error.message, method + "() called while Connecting")
    assert_equal(error.sqlstate, "")


def _repeat_x(size: Int) raises -> String:
    """Build a `String` of exactly `size` repetitions of `x`.

    Args:
        size: The length in bytes.

    Returns:
        The value, built by doubling a chunk rather than by appending bytes
        sixteen million times.
    """
    var chunk = String("x")
    while chunk.byte_length() < 4096:
        chunk += chunk.copy()
    var out = String()
    while out.byte_length() + chunk.byte_length() <= size:
        out += chunk
    while out.byte_length() < size:
        out += "x"
    return out^


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


# --- T4 ---


def test_cancel_stops_a_running_statement() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    _send(conn, "SELECT pg_sleep(10)")
    # One wait so the statement is really running on the server; it times out,
    # which is the point -- pg_sleep(10) answers nothing for ten seconds.
    _wait_readable_allowing_timeout(conn, 100)
    var started = monotonic()
    _cancel(conn)
    var error = _fetch_all_error(conn, 5000)
    var took = _elapsed_ms(started)
    assert_true(error.kind == PgErrorKind.SERVER, String(error))
    assert_equal(error.sqlstate, "57014")
    assert_true(error.message.find("canceling statement") >= 0, error.message)
    # The cancel travels on its own connection, so it does not queue behind
    # the ten-second sleep it is cancelling.
    assert_true(took < 1000, "cancel and collect took " + String(took) + " ms")
    assert_true(conn.state() == AsyncState.IDLE)
    # And the connection itself is untouched.
    _send(conn, "SELECT 42")
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 1)
    assert_equal(_int32_at(results[0], 0, 0), Int32(42))


def test_cancel_while_idle_is_a_no_op() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    # A result can arrive in the instant between deciding to cancel and
    # calling, so cancelling nothing is a race that has to be harmless.
    _cancel(conn)
    assert_true(conn.state() == AsyncState.IDLE)
    _send(conn, "SELECT 1")
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 1)
    assert_equal(_int32_at(results[0], 0, 0), Int32(1))


def test_single_row_mode_splits_the_rows() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    _send(conn, "SELECT generate_series(1,3)")
    _set_single_row_mode(conn)
    var results = _fetch_all(conn, 5000)
    # Three rows, three results, plus the empty one that ends the statement.
    assert_equal(len(results), 4)
    for i in range(3):
        assert_equal(results[i].row_count(), 1)
        assert_equal(_int32_at(results[i], 0, 0), Int32(i + 1))
    assert_equal(results[3].row_count(), 0)
    assert_true(conn.state() == AsyncState.IDLE)


def test_single_row_mode_error_after_a_row() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    # The first row divides by 1 and arrives; the second divides by 0.
    _send(conn, "SELECT 1/(2-generate_series(1,2))")
    _set_single_row_mode(conn)
    var error = _fetch_all_error(conn, 5000)
    assert_true(error.kind == PgErrorKind.SERVER, String(error))
    assert_equal(error.sqlstate, "22012")
    # fetch_all drained the rest before raising, so the connection is usable.
    assert_true(conn.state() == AsyncState.IDLE)
    _send(conn, "SELECT 1")
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 1)
    assert_equal(_int32_at(results[0], 0, 0), Int32(1))


# --- T5 ---
#
# The grid of states crossed with calls. Every refusal below is `pq`'s own
# client-side check, which is what keeps libpq's wording -- "another command
# is already in progress", "no connection to the server" -- out of a `USAGE`
# message: the call never reaches libpq at all.


def test_send_while_a_command_is_in_flight_is_usage() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    _send(conn, "SELECT pg_sleep(0.2)")
    var error = _send_error(conn, "SELECT 1")
    assert_true(error.kind == PgErrorKind.USAGE, String(error))
    # How much of the first statement the kernel accepted is not reproducible,
    # so the state named in the message is Sending or Busy.
    assert_true(
        error.message == "send() called while Busy"
        or error.message == "send() called while Sending",
        error.message,
    )
    assert_equal(error.sqlstate, "")
    assert_false(error.message.find("already in progress") >= 0)
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 1)


def test_send_between_two_results_is_usage() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    _send(conn, "SELECT 1; SELECT 2")
    # One result collected, the command not over: a two-statement send is
    # still in flight after the first answer.
    var first = _poll_until_result(conn)
    assert_equal(_int32_at(first, 0, 0), Int32(1))
    _ = first^
    assert_true(conn.state() == AsyncState.BUSY)
    var error = _send_error(conn, "SELECT 3")
    assert_true(error.kind == PgErrorKind.USAGE, String(error))
    assert_equal(error.message, "send() called while Busy")
    var rest = _fetch_all(conn, 5000)
    assert_equal(len(rest), 1)
    assert_equal(_int32_at(rest[0], 0, 0), Int32(2))


def test_single_row_mode_outside_its_window_is_usage() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    # Nothing has been sent, so there is no command to switch.
    var idle = _set_single_row_mode_error(conn)
    assert_true(idle.kind == PgErrorKind.USAGE, String(idle))
    assert_true(idle.message.find("must follow send") >= 0, idle.message)
    # A collected result closes the window: libpq would still answer 1 here,
    # which is why the window is tracked client-side instead.
    _send(conn, "SELECT generate_series(1,2)")
    var res = _poll_until_result(conn)
    assert_equal(res.row_count(), 2)
    _ = res^
    var late = _set_single_row_mode_error(conn)
    assert_true(late.kind == PgErrorKind.USAGE, String(late))
    assert_true(late.message.find("must follow send") >= 0, late.message)
    _poll_to_idle(conn)
    # So does merely reading the socket, even when no result came of it.
    _send(conn, "SELECT 1")
    _consume_input(conn)
    var consumed = _set_single_row_mode_error(conn)
    assert_true(consumed.kind == PgErrorKind.USAGE, String(consumed))
    assert_true(
        consumed.message.find("must follow send") >= 0, consumed.message
    )
    var rest = _fetch_all(conn, 5000)
    assert_equal(len(rest), 1)


def test_every_call_while_connecting_is_usage() raises:
    var conn = _start(_conninfo())
    assert_true(conn.state() == AsyncState.CONNECTING)
    _assert_connecting_usage(_cancel_error(conn), "cancel")
    _assert_connecting_usage(_consume_input_error(conn), "consume_input")
    _assert_connecting_usage(_poll_result_error(conn), "poll_result")
    _assert_connecting_usage(_notifications_error(conn), "notifications")
    _assert_connecting_usage(_fetch_all_error(conn, 100), "fetch_all")
    # None of them touched the handshake, which still completes.
    _poll_to_ready(conn)
    assert_true(conn.state() == AsyncState.IDLE)


def test_an_idle_connection_has_nothing_to_collect() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    # Nothing in flight is not an error on either collecting entry point:
    # None and an empty list are the answers.
    assert_false(Bool(_poll_result(conn)), "a result arrived unasked")
    var results = _fetch_all(conn, 100)
    assert_equal(len(results), 0)
    assert_true(conn.state() == AsyncState.IDLE)


def test_a_budget_below_minus_one_is_usage() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    var error = _wait_readable_error(conn, -2)
    assert_true(error.kind == PgErrorKind.USAGE, String(error))
    assert_true(error.message.find("timeout_ms must be") >= 0, error.message)


def test_a_budget_above_c_int_max_is_usage_at_every_entry() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    var t0 = monotonic()
    # Every entry point that takes a budget rejects one that would not
    # survive the trip through `poll`'s `c_int`: without the check
    # `wait_readable(2**32)` waits 0 ms and `fetch_all(Int.MAX)` reports an
    # immediate `TIMEOUT`, both of them silently.
    _assert_timeout_too_large(_wait_readable_error(conn, 4294967296))
    _send(conn, "SELECT 1")
    _assert_timeout_too_large(_fetch_all_error(conn, Int.MAX))
    # The refused `fetch_all` did not touch the command in flight, so the
    # connection is still `Busy` and the results are still collectable.
    assert_true(conn.state() == AsyncState.BUSY)
    _assert_timeout_too_large(_wait_notification_error(conn, 4294967296))
    _assert_timeout_too_large(_connect_blocking_error(_conninfo(), 4294967296))
    var took = _elapsed_ms(t0)
    assert_true(took < 1000, "the rejections took " + String(took) + " ms")
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 1)
    assert_true(conn.state() == AsyncState.IDLE)


def test_cancel_after_the_backend_is_gone_is_connection() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    var pid = _backend_pid(conn)
    _send(conn, "SELECT pg_sleep(5)")
    _terminate(pid)
    # `consume_input` is the one entry point that reports the loss and still
    # leaves the command in flight, which is how the connection ends up both
    # `Busy` -- so the cancel is not the documented idle no-op -- and known
    # to be gone, so the cancel has no connection to travel on.
    var lost = _consume_input_until_lost(conn)
    assert_true(lost.kind == PgErrorKind.CONNECTION, String(lost))
    assert_true(conn.state() == AsyncState.BUSY)
    # The fourth corner of the cancel grid: idle, connecting and busy with a
    # live connection are covered elsewhere.
    var cancelled = _cancel_error(conn)
    assert_true(cancelled.kind == PgErrorKind.CONNECTION, String(cancelled))


def test_cancel_inside_a_transaction_still_owes_a_rollback() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    _send(conn, "BEGIN")
    var begun = _fetch_all(conn, 5000)
    assert_equal(len(begun), 1)
    _send(conn, "SELECT pg_sleep(10)")
    _wait_readable_allowing_timeout(conn, 100)
    _cancel(conn)
    var error = _fetch_all_error(conn, 5000)
    assert_true(error.kind == PgErrorKind.SERVER, String(error))
    assert_equal(error.sqlstate, "57014")
    # A cancelled statement inside an explicit transaction aborts the block
    # like any other failure, so the server refuses everything until it ends.
    assert_equal(conn.transaction_status(), Int(PQTRANS_INERROR))
    _send(conn, "SELECT 1")
    var aborted = _fetch_all_error(conn, 5000)
    assert_true(aborted.kind == PgErrorKind.SERVER, String(aborted))
    assert_equal(aborted.sqlstate, "25P02")
    _send(conn, "ROLLBACK")
    var rolled = _fetch_all(conn, 5000)
    assert_equal(len(rolled), 1)
    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))


def test_a_terminated_backend_ends_the_command() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    var pid = _backend_pid(conn)
    _send(conn, "SELECT pg_sleep(5)")
    _terminate(pid)
    var error = _fetch_all_error(conn, 5000)
    # Whether the server's farewell arrives before the socket closes is a
    # race, so both shapes are accepted.
    assert_true(
        error.kind == PgErrorKind.SERVER
        or error.kind == PgErrorKind.CONNECTION,
        String(error),
    )
    if error.kind == PgErrorKind.SERVER:
        assert_equal(error.sqlstate, "57P01")
    # Whether the drain already saw the connection go bad is the same race,
    # so whatever is left of the command is settled here. A lost connection
    # can never deliver the NULL result that ends a command, so polling on
    # ends it instead of spinning forever -- which is the whole point.
    while conn.state() != AsyncState.IDLE:
        var lost = _poll_result_error(conn)
        assert_true(lost.kind == PgErrorKind.CONNECTION, String(lost))
        assert_equal(lost.sqlstate, "")
    assert_equal(conn.socket(), -1)
    assert_equal(conn.status(), Int(CONNECTION_BAD))
    assert_false(Bool(_poll_result(conn)), "a result arrived after the loss")
    # Nothing is in flight any more, so the client-side check finds nothing
    # wrong with the state and it is libpq that reports the loss.
    var gone = _send_error(conn, "SELECT 1")
    assert_true(gone.kind == PgErrorKind.CONNECTION, String(gone))
    assert_true(gone.message.find("no connection") >= 0, gone.message)


def test_a_large_statement_is_written_in_instalments() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    _send(conn, String("SELECT length('", _repeat_x(BIG_STATEMENT_BYTES), "')"))
    # Whether anything was left unwritten is up to the kernel's buffers, so
    # this loops on flush rather than asserting the state is Sending.
    while not _flush(conn):
        _wait_writable(conn, 2000)
    var results = _fetch_all(conn, 10000)
    assert_equal(len(results), 1)
    assert_equal(_int32_at(results[0], 0, 0), Int32(BIG_STATEMENT_BYTES))


def test_single_row_mode_across_statements_and_prepared() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    _send(conn, "SELECT 1; SELECT 2")
    _set_single_row_mode(conn)
    var results = _fetch_all(conn, 5000)
    # A row, the end of its statement, a row, the end of the next: the mode
    # is per statement, and its empty result is not the end of the command.
    assert_equal(len(results), 4)
    assert_equal(results[0].row_count(), 1)
    assert_equal(_int32_at(results[0], 0, 0), Int32(1))
    assert_equal(results[1].row_count(), 0)
    assert_equal(results[2].row_count(), 1)
    assert_equal(_int32_at(results[2], 0, 0), Int32(2))
    assert_equal(results[3].row_count(), 0)
    # A prepared statement splits the same way.
    _send_prepare(conn, "sr", "SELECT generate_series(1,$1::int4)")
    var prepared = _fetch_all(conn, 5000)
    assert_equal(len(prepared), 1)
    _send_prepared(conn, "sr", [Int32(2)])
    _set_single_row_mode(conn)
    var rows = _fetch_all(conn, 5000)
    assert_equal(len(rows), 3)
    assert_equal(_int32_at(rows[0], 0, 0), Int32(1))
    assert_equal(_int32_at(rows[1], 0, 0), Int32(2))
    assert_equal(rows[2].row_count(), 0)


def test_multi_host_conninfo_reaches_the_second_host() raises:
    var params = _params()
    # The first host refuses, so libpq walks on and replaces the socket --
    # which is why every wait reads `socket()` again instead of caching it.
    var conninfo = String(
        "host=",
        params["host"],
        ",",
        params["host"],
        " port=1,",
        params["port"],
        " user=",
        params["user"],
        " password=",
        params["password"],
        " dbname=",
        params["dbname"],
    )
    var conn = _connect_blocking(conninfo^, 5000)
    assert_true(conn.state() == AsyncState.IDLE)
    _send(conn, "SELECT 1")
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 1)
    assert_equal(_int32_at(results[0], 0, 0), Int32(1))


def test_connect_failures_name_their_cause() raises:
    # A host name that does not resolve is refused before any socket exists,
    # so `start` itself fails and there is nothing to poll.
    var unresolvable = _start_error(
        String("host=nonexistent.invalid port=1 user=pq dbname=pq_test")
    )
    assert_true(
        unresolvable.kind == PgErrorKind.CONNECTION, String(unresolvable)
    )
    assert_true(
        unresolvable.message.find("could not translate host name") >= 0,
        unresolvable.message,
    )
    # A refused port resolves, so `start` succeeds and the refusal only
    # surfaces while the handshake is being polled.
    var conn = _start(String("host=127.0.0.1 port=1 user=pq dbname=pq_test"))
    assert_true(conn.state() == AsyncState.CONNECTING)
    var refused = _poll_connect_to_failure(conn)
    assert_true(refused.kind == PgErrorKind.CONNECTION, String(refused))
    assert_true(
        refused.message.find("Connection refused") >= 0, refused.message
    )
    # A wrong password is the server's refusal, and the password it refused
    # must not travel back in the message.
    var bad = _connect_blocking_error(
        _conninfo() + " password=" + WRONG_PASSWORD, 5000
    )
    assert_true(bad.kind == PgErrorKind.CONNECTION, String(bad))
    assert_true(
        bad.message.find("password authentication failed") >= 0, bad.message
    )
    assert_false(bad.message.find(WRONG_PASSWORD) >= 0)


def test_dropping_a_connection_with_unread_results_is_safe() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    _send(conn, "SELECT 1; SELECT 2")
    _wait_readable(conn, 2000)
    _consume_input(conn)
    # PQfinish is the whole destructor: libpq discards the results still
    # queued, so nothing has to be drained before dropping the connection.
    _ = conn^


def test_parameter_values_are_copied_by_the_send() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    var value = String("hello-param")
    _send_params(conn, "SELECT $1::text", [value])
    # libpq copies the parameter values during the send itself, so the
    # caller's own String is free the moment `send` returns.
    value = String("XXXX")
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 1)
    assert_equal(_text_at(results[0], 0, 0), "hello-param")
    assert_equal(value, "XXXX")


def test_send_paths_reject_an_embedded_nul() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    # Truncated at the NUL, this would run `SELECT 1` and drop the rest.
    var in_sql = _send_error(conn, _with_nul("SELECT 1; DROP TABLE "))
    _assert_nul_error(in_sql, "sql")
    # `send_prepare` checks the name before the statement, so a NUL in both
    # is reported against the name.
    var in_both = _send_prepare_error(
        conn, _with_nul("p"), _with_nul("SELECT 1")
    )
    _assert_nul_error(in_both, "name")
    var in_prepare_sql = _send_prepare_error(
        conn, "p_nul", _with_nul("SELECT 1; DROP TABLE ")
    )
    _assert_nul_error(in_prepare_sql, "sql")
    var in_prepared_name = _send_prepared_error(
        conn, _with_nul("p"), List[Param]()
    )
    _assert_nul_error(in_prepared_name, "name")
    # Every one of them was refused before libpq saw it, so the connection
    # never left Idle and is still usable.
    assert_true(conn.state() == AsyncState.IDLE)
    _send(conn, "SELECT 1")
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 1)
    assert_equal(_int32_at(results[0], 0, 0), Int32(1))


# --- T5 (Phase 5) ---


def test_fetch_all_stops_draining_on_a_closed_socket() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    _send(conn, "SELECT pg_sleep(0.3), 1")
    # Closing the descriptor under libpq is the one way to make a read fail
    # while `PQstatus` still answers `OK`: the server is fine, so it never
    # sends the notice that would turn the status BAD. Draining has to stop on
    # the error itself. Nothing may open a descriptor between here and the
    # destructor, or `PQfinish` would close a file that belongs to someone
    # else.
    _ = external_call["close", c_int](c_int(conn.socket()))
    var t0 = monotonic()
    var error = _fetch_all_error(conn, 2000)
    assert_true(error.kind == PgErrorKind.CONNECTION, String(error))
    # Before the fix this spun on `poll_result` until the 2000 ms budget ran
    # out and reported TIMEOUT instead.
    var elapsed = _elapsed_ms(t0)
    assert_true(elapsed < 500, String("fetch_all took ", elapsed, " ms"))
    _ = conn^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
