"""Tests for `LISTEN` / `NOTIFY` on `pq.async_conn` against a live server.

The listener is an `AsyncConnection` -- notifications are only readable
through `PQconsumeInput`, which is the asynchronous half of the API -- and the
sender is an ordinary synchronous `Connection`, because `NOTIFY` is just a
statement. Using two connections is what makes `backend_pid` meaningful: it is
the sender's, and the test checks it against the sender's own
`pg_backend_pid()`.

Both PG14 and PG17 behave identically here; nothing below asserts a timing
narrow enough for a loaded machine to miss. The helpers are deliberately
duplicated from `tests/test_async.mojo` rather than imported: a test file is
run as its own program, and one `TestSuite` per file is the house shape.
"""

from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import monotonic

from pq.async_conn import AsyncConnection, AsyncState, Notification
from pq.connection import Connection
from pq.errors import PgError
from pq.result import Result

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)


# --- helpers -----------------------------------------------------------------
#
# A `TestSuite` test only declares `raises` (plain `Error`), and `PgError` does
# not implicitly convert to `Error`, so a `raises PgError` API cannot be called
# straight from a test. These wrappers translate the success paths; no test
# here inspects a `PgError`, so there are no failure-path wrappers.


def _conninfo() -> String:
    """Return the conninfo of the server under test.

    Returns:
        `PQ_TEST_CONNINFO` when set and non-empty, else `DEFAULT_CONNINFO`.
    """
    var value = getenv("PQ_TEST_CONNINFO")
    return value if value != "" else String(DEFAULT_CONNINFO)


def _connect_blocking(
    var conninfo: String, timeout_ms: Int
) raises -> AsyncConnection:
    """Connect asynchronously and wait for the handshake.

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


def _open(var conninfo: String) raises -> Connection:
    """Open the synchronous connection that sends the notifications.

    Args:
        conninfo: A libpq `key=value ...` conninfo string.

    Returns:
        An open `Connection`.

    Raises:
        Error: If `Connection.open` raised a `PgError`.
    """
    try:
        return Connection.open(conninfo^)
    except e:
        raise Error(String(e))


def _execute(mut conn: Connection, var sql: String) raises -> Result:
    """Run one statement on the synchronous connection.

    Args:
        conn: The open synchronous connection.
        sql: Exactly one SQL statement.

    Returns:
        Its `Result`.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    try:
        return conn.execute(sql^)
    except e:
        raise Error(String(e))


def _backend_pid(mut conn: Connection) raises -> Int:
    """Return the process ID of the backend serving `conn`.

    Args:
        conn: The open synchronous connection.

    Returns:
        `pg_backend_pid()` as an `Int`.

    Raises:
        Error: If the query failed.
    """
    var res = _execute(conn, "SELECT pg_backend_pid()")
    try:
        return Int(res[0].get[Int32](0))
    except e:
        raise Error(String(e))


def _send(mut conn: AsyncConnection, var sql: String) raises:
    """Queue `sql` on the asynchronous connection.

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


def _listen(mut conn: AsyncConnection, var channel: String) raises:
    """Subscribe the asynchronous connection to `channel`.

    Args:
        conn: The idle connection.
        channel: An unquoted channel name.

    Raises:
        Error: If the `LISTEN` failed.
    """
    _send(conn, "LISTEN " + channel)
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 1)


def _notifications(mut conn: AsyncConnection) raises -> List[Notification]:
    """Collect whatever notifications have arrived.

    Args:
        conn: The listening connection.

    Returns:
        The notifications, oldest first.

    Raises:
        Error: If `notifications` raised a `PgError`.
    """
    try:
        return conn.notifications()
    except e:
        raise Error(String(e))


def _wait_notification(
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


def _elapsed_ms(since: Int) raises -> Int:
    """Return the milliseconds elapsed since a `monotonic()` reading.

    Args:
        since: An earlier `std.time.monotonic()` value, in nanoseconds.

    Returns:
        Whole milliseconds elapsed.
    """
    return (monotonic() - since) // 1_000_000


# --- tests -------------------------------------------------------------------


def test_wait_notification_receives_both_payloads() raises:
    var listener = _connect_blocking(_conninfo(), 5000)
    _listen(listener, "pq_t4")
    var sender = _open(_conninfo())
    var sender_pid = _backend_pid(sender)
    # Two separate statements, so two separate transactions: PostgreSQL
    # delivers at commit, and a payload-less NOTIFY arrives as an empty one.
    _ = _execute(sender, "NOTIFY pq_t4, 'payload-1'")
    _ = _execute(sender, "NOTIFY pq_t4")
    var first = _wait_notification(listener, 2000)
    assert_true(Bool(first), "no notification within 2 s")
    assert_equal(first.value().channel, "pq_t4")
    assert_equal(first.value().payload, "payload-1")
    assert_equal(first.value().backend_pid, sender_pid)
    var second = _wait_notification(listener, 2000)
    assert_true(Bool(second), "only one of the two notifications arrived")
    assert_equal(second.value().channel, "pq_t4")
    assert_equal(second.value().payload, "")
    assert_equal(second.value().backend_pid, sender_pid)
    # Nothing more was sent, so the third wait spends its budget and answers
    # None rather than raising: nothing arriving is a normal outcome.
    var third = _wait_notification(listener, 200)
    assert_false(Bool(third), "a third notification arrived")
    _ = sender^


def test_notifications_is_empty_before_anything_is_sent() raises:
    var listener = _connect_blocking(_conninfo(), 5000)
    _listen(listener, "pq_t4_quiet")
    var found = _notifications(listener)
    assert_equal(len(found), 0)
    assert_true(listener.state() == AsyncState.IDLE)


def test_wait_notification_times_out_to_none() raises:
    var listener = _connect_blocking(_conninfo(), 5000)
    _listen(listener, "pq_t4_silent")
    var started = monotonic()
    var got = _wait_notification(listener, 50)
    var took = _elapsed_ms(started)
    assert_false(Bool(got), "a notification arrived on a silent channel")
    assert_true(took >= 50, "gave up after only " + String(took) + " ms")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
