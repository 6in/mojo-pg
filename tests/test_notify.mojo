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
from pq.errors import PgError, PgErrorKind
from pq.result import Result

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)


# --- helpers -----------------------------------------------------------------
#
# A `TestSuite` test only declares `raises` (plain `Error`), and `PgError` does
# not implicitly convert to `Error`, so a `raises PgError` API cannot be called
# straight from a test. These wrappers translate in both directions: success
# paths re-raise as `Error`, and the one failure path here -- `notifications`
# on a connection the server has dropped -- hands the `PgError` back for
# inspection.


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


def _notifications_error(mut conn: AsyncConnection) -> Optional[PgError]:
    """Report whether `notifications` refused the connection this time.

    Unlike the other failure-path wrappers in this suite, one call is not
    expected to fail: a backend that has just been terminated is not visible
    to `PQconsumeInput` until the kernel has seen the end of the stream, so
    the caller loops on this.

    Args:
        conn: The connection whose backend may already be gone.

    Returns:
        The raised `PgError`, or None when the call succeeded.
    """
    try:
        var found = conn.notifications()
        _ = found^
    except e:
        return e.copy()
    return None


def _pause_until_readable(mut conn: AsyncConnection, timeout_ms: Int):
    """Wait a little for the socket, swallowing whatever the wait says.

    Used only to pace a retry loop: a timeout means nothing has arrived yet,
    and a lost connection is exactly what the loop is waiting to observe
    through a real API call, so neither is an error here.

    Args:
        conn: The connection to wait on.
        timeout_ms: Milliseconds to wait at most.
    """
    try:
        conn.wait_readable(timeout_ms)
    except:
        pass


def _collect_notifications(
    mut conn: AsyncConnection, want: Int, timeout_ms: Int
) raises -> List[Notification]:
    """Call `notifications` until `want` have arrived or the budget runs out.

    One `notifications` call is not a promise of every notification the
    server has sent -- they arrive when they arrive -- so a test that needs a
    fixed number of them loops, as the API's own docstring prescribes.

    Args:
        conn: The listening connection.
        want: How many notifications to wait for.
        timeout_ms: Milliseconds allowed for the whole collection.

    Returns:
        Everything collected, oldest first; fewer than `want` when the budget
        ran out.

    Raises:
        Error: If `notifications` raised a `PgError`.
    """
    var found = List[Notification]()
    var deadline = monotonic() + timeout_ms * 1_000_000
    while len(found) < want:
        var batch = _notifications(conn)
        for i in range(len(batch)):
            found.append(batch[i].copy())
        if len(found) >= want or monotonic() >= deadline:
            break
        _pause_until_readable(conn, 50)
    return found^


def _async_backend_pid(mut conn: AsyncConnection) raises -> Int:
    """Return the process ID of the backend serving the async connection.

    Args:
        conn: The idle asynchronous connection.

    Returns:
        `pg_backend_pid()` as an `Int`.

    Raises:
        Error: If the query failed.
    """
    _send(conn, "SELECT pg_backend_pid()")
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 1)
    try:
        return Int(results[0][0].get[Int32](0))
    except e:
        raise Error(String(e))


def _wait_until_active(mut conn: Connection, pid: Int, timeout_ms: Int) raises:
    """Wait until `pg_stat_activity` reports backend `pid` as active.

    Args:
        conn: A synchronous connection to ask with, not the one being waited
            on.
        pid: The backend process ID to watch.
        timeout_ms: Milliseconds allowed for the whole wait.

    Raises:
        Error: If the query failed, or if the backend was still not active
            when the budget ran out.
    """
    var sql = String(
        "SELECT count(*) FROM pg_stat_activity WHERE pid = ",
        pid,
        " AND state = 'active'",
    )
    var deadline = monotonic() + timeout_ms * 1_000_000
    while True:
        var res = _execute(conn, sql.copy())
        var active: Int
        try:
            active = Int(res[0].get[Int64](0))
        except e:
            raise Error(String(e))
        if active > 0:
            return
        if monotonic() >= deadline:
            raise Error(String("backend ", pid, " never became active in time"))


def _wait_notification_error(
    mut conn: AsyncConnection, timeout_ms: Int
) raises -> PgError:
    """Return the `PgError` raised by a wait that must not succeed.

    Args:
        conn: The listening connection.
        timeout_ms: Milliseconds to wait in total.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the wait returned instead of raising.
    """
    try:
        var got = conn.wait_notification(timeout_ms)
        _ = got^
    except e:
        return e^
    raise Error("expected a PgError from wait_notification")


def _drop_ascii_database() -> Bool:
    """Drop `pq_test_ascii` if it is there, reporting instead of raising.

    `DROP DATABASE` cannot be issued from the database it drops, nor from
    inside a transaction block, so this opens its own synchronous connection
    to `pq_test` and runs the one statement on it directly. `WITH (FORCE)`
    terminates whatever is still attached.

    Returns:
        True when the statement ran, False when anything went wrong.

    Notes:
        Callers discard the result with `_ = `: a drop that failed must never
        hide the test result that has already been established.
    """
    try:
        var admin = _open(_conninfo())
        _ = _execute(
            admin, "DROP DATABASE IF EXISTS pq_test_ascii WITH (FORCE)"
        )
        _ = admin^
    except:
        return False
    return True


def _ascii_conninfo() raises -> String:
    """Return the conninfo of the `SQL_ASCII` database, creating it fresh.

    `pq_test_ascii` is the only way to get bytes that are not UTF-8 out of a
    server: every other database under test is UTF-8 and rejects them on the
    way in. It is created on demand -- `pq` is superuser on both servers --
    and dropped at the end of each test and, in case an assertion skipped
    that, at the start of the next.

    The `dbname` is appended rather than substituted: libpq takes the last
    occurrence of a repeated keyword, so this redirects `PQ_TEST_CONNINFO`
    whatever database it names (verified against both servers).

    Returns:
        The conninfo of the server under test with `dbname=pq_test_ascii`.

    Raises:
        Error: If the database could not be created. The `CREATE` follows a
            `DROP DATABASE IF EXISTS`, so it has nothing left to collide
            with and has to succeed.
    """
    _ = _drop_ascii_database()
    var admin = _open(_conninfo())
    try:
        _ = admin.execute(
            String(
                "CREATE DATABASE pq_test_ascii ENCODING 'SQL_ASCII'"
                " TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C'"
            )
        )
    except e:
        raise Error(String(e))
    _ = admin^
    return _conninfo() + " dbname=pq_test_ascii"


def _assert_sql_ascii(mut conn: AsyncConnection) raises:
    """Check that `conn` really is attached to the `SQL_ASCII` database.

    The guard that keeps the two non-UTF-8 cases honest: on a UTF-8 database
    the server would reject the bytes itself and the test would pass for the
    wrong reason.

    Args:
        conn: The connection to interrogate.

    Raises:
        Error: If the query failed or the encoding is not `SQL_ASCII`.
    """
    _send(conn, "SHOW server_encoding")
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 1)
    var encoding: String
    try:
        encoding = String(results[0][0].get_text(0))
    except e:
        raise Error(String(e))
    assert_equal(encoding, "SQL_ASCII")


def _payload_at_the_limit() -> String:
    """Build the longest payload `NOTIFY` accepts.

    PostgreSQL keeps the payload in 8000 bytes including its NUL terminator,
    on PG14 and PG17 alike, so 7999 bytes is the limit rather than 8000.

    Returns:
        7999 `x` bytes.
    """
    var out = String()
    while out.byte_length() < 7999:
        out += "x"
    return out^


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


def test_a_payload_that_is_not_utf8_is_rejected_and_dropped() raises:
    var ascii_conninfo = _ascii_conninfo()
    var listener = _connect_blocking(ascii_conninfo.copy(), 5000)
    _assert_sql_ascii(listener)
    _listen(listener, "pq_f1")
    var sender = _open(ascii_conninfo.copy())
    # `ab` then a lead byte with no continuation: ill-formed at offset 2, and
    # a SQL_ASCII database hands it over unchanged. `get_text` rejects the
    # same bytes, so a notification must not quietly carry them.
    _ = _execute(sender, "NOTIFY pq_f1, E'ab\\xC3\\x28'")
    var error = _wait_notification_error(listener, 2000)
    assert_true(error.kind == PgErrorKind.TYPE_MISMATCH, String(error))
    assert_true(
        error.message.find("invalid UTF-8 at byte 2") >= 0, error.message
    )
    assert_true(error.message.find("notification payload") >= 0, error.message)
    # The payload is named, never quoted: it cannot be put in a message
    # without corrupting the message or spilling the payload into a log.
    assert_false(error.message.find("ab") >= 0, error.message)
    # Only that one notification is lost. The connection never left `Idle`
    # and the next notification arrives on the same listener.
    assert_true(listener.state() == AsyncState.IDLE)
    _ = _execute(sender, "NOTIFY pq_f1, 'ok'")
    var got = _wait_notification(listener, 2000)
    assert_true(Bool(got), "nothing arrived after the rejected notification")
    assert_equal(got.value().channel, "pq_f1")
    assert_equal(got.value().payload, "ok")
    _ = sender^
    _ = listener^
    _ = _drop_ascii_database()


def test_a_channel_that_is_not_utf8_is_rejected_and_dropped() raises:
    var ascii_conninfo = _ascii_conninfo()
    var listener = _connect_blocking(ascii_conninfo.copy(), 5000)
    _assert_sql_ascii(listener)
    # The channel name itself carries the ill-formed bytes. `LISTEN` takes an
    # identifier rather than an expression, so the bytes are smuggled in
    # through `format('%I', ...)` inside a `DO` block -- the SQL text sent
    # over the wire stays ASCII.
    _send(
        listener,
        "DO $$ BEGIN EXECUTE format('LISTEN %I', E'ch\\xC3\\x28'); END $$",
    )
    var listened = _fetch_all(listener, 5000)
    assert_equal(len(listened), 1)
    var sender = _open(ascii_conninfo.copy())
    _ = _execute(
        sender,
        (
            "DO $$ BEGIN EXECUTE format('NOTIFY %I, ''x''',"
            " E'ch\\xC3\\x28'); END $$"
        ),
    )
    var error = _wait_notification_error(listener, 2000)
    assert_true(error.kind == PgErrorKind.TYPE_MISMATCH, String(error))
    assert_true(
        error.message.find("invalid UTF-8 at byte 2") >= 0, error.message
    )
    assert_true(error.message.find("notification channel") >= 0, error.message)
    assert_true(listener.state() == AsyncState.IDLE)
    _ = sender^
    _ = listener^
    _ = _drop_ascii_database()


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


def test_notification_waits_for_the_running_command() raises:
    var listener = _connect_blocking(_conninfo(), 5000)
    _listen(listener, "pq_t5_during")
    var sender = _open(_conninfo())
    var sender_pid = _backend_pid(sender)
    var listener_pid = _async_backend_pid(listener)
    _send(listener, "SELECT pg_sleep(0.3)")
    # `send` only hands the bytes to libpq: the listening backend may not have
    # read them yet, and while it has not it is still idle and delivers a
    # notification immediately. So wait until the server itself reports the
    # sleep as running before sending anything -- without this the assertion
    # below fails whenever the NOTIFY commits first (measured: it does, under
    # load).
    _wait_until_active(sender, listener_pid, 2000)
    _ = _execute(sender, "NOTIFY pq_t5_during, 'during'")
    # The listening backend only delivers notifications between commands, so
    # nothing can have arrived while the sleep is still running.
    var early = _notifications(listener)
    assert_equal(len(early), 0)
    var results = _fetch_all(listener, 5000)
    assert_equal(len(results), 1)
    var found = _collect_notifications(listener, 1, 2000)
    assert_equal(len(found), 1)
    assert_equal(found[0].channel, "pq_t5_during")
    assert_equal(found[0].payload, "during")
    assert_equal(found[0].backend_pid, sender_pid)
    _ = sender^


def test_payload_survives_the_byte_limit_and_utf8() raises:
    var listener = _connect_blocking(_conninfo(), 5000)
    _listen(listener, "pq_t5_payload")
    var sender = _open(_conninfo())
    var sender_pid = _backend_pid(sender)
    var biggest = _payload_at_the_limit()
    assert_equal(biggest.byte_length(), 7999)
    _ = _execute(sender, "NOTIFY pq_t5_payload, '" + biggest + "'")
    # `héllo` is five characters in six bytes: the payload is carried as
    # bytes, so the length that matters is the byte length.
    _ = _execute(sender, "NOTIFY pq_t5_payload, 'héllo'")
    var found = _collect_notifications(listener, 2, 5000)
    assert_equal(len(found), 2)
    assert_equal(found[0].payload.byte_length(), 7999)
    assert_equal(found[0].payload, biggest)
    assert_equal(found[0].backend_pid, sender_pid)
    assert_equal(found[1].payload.byte_length(), 6)
    assert_equal(found[1].payload, "héllo")
    assert_equal(found[1].backend_pid, sender_pid)
    _ = sender^


def test_notify_is_delivered_at_commit() raises:
    var listener = _connect_blocking(_conninfo(), 5000)
    _listen(listener, "pq_t5_tx")
    var sender = _open(_conninfo())
    var sender_pid = _backend_pid(sender)
    _ = _execute(sender, "BEGIN")
    _ = _execute(sender, "NOTIFY pq_t5_tx, 'committed'")
    # PostgreSQL delivers at commit, so an uncommitted NOTIFY is invisible
    # and the wait spends its budget and answers None.
    var early = _wait_notification(listener, 300)
    assert_false(Bool(early), "an uncommitted notification was delivered")
    _ = _execute(sender, "COMMIT")
    var got = _wait_notification(listener, 2000)
    assert_true(Bool(got), "the committed notification never arrived")
    assert_equal(got.value().channel, "pq_t5_tx")
    assert_equal(got.value().payload, "committed")
    assert_equal(got.value().backend_pid, sender_pid)
    _ = sender^


def test_notify_reaches_its_own_connection() raises:
    var conn = _connect_blocking(_conninfo(), 5000)
    _listen(conn, "pq_t5_self")
    var own_pid = _async_backend_pid(conn)
    _send(conn, "NOTIFY pq_t5_self, 'self'")
    var results = _fetch_all(conn, 5000)
    assert_equal(len(results), 1)
    var found = _collect_notifications(conn, 1, 2000)
    assert_equal(len(found), 1)
    assert_equal(found[0].channel, "pq_t5_self")
    assert_equal(found[0].payload, "self")
    # Listening and notifying on one connection is allowed, and the sender's
    # backend PID is then the listener's own.
    assert_equal(found[0].backend_pid, own_pid)


def test_second_wait_notification_answers_without_waiting() raises:
    var listener = _connect_blocking(_conninfo(), 5000)
    _listen(listener, "pq_t5_queue")
    var sender = _open(_conninfo())
    var sender_pid = _backend_pid(sender)
    # One transaction, two distinct payloads: both are delivered together at
    # commit -- identical payloads on one channel would be collapsed into one
    # -- so a single round trip can carry the pair.
    _ = _execute(sender, "BEGIN")
    _ = _execute(sender, "NOTIFY pq_t5_queue, 'first'")
    _ = _execute(sender, "NOTIFY pq_t5_queue, 'second'")
    _ = _execute(sender, "COMMIT")
    var first = _wait_notification(listener, 5000)
    assert_true(Bool(first), "the first notification never arrived")
    assert_equal(first.value().payload, "first")
    assert_equal(first.value().backend_pid, sender_pid)
    # Whatever the first wait picked up beyond the one it returned is held,
    # so this call answers from that queue instead of waiting on the socket.
    var started = monotonic()
    var second = _wait_notification(listener, 5000)
    var took = _elapsed_ms(started)
    assert_true(Bool(second), "the second notification never arrived")
    assert_equal(second.value().payload, "second")
    assert_equal(second.value().backend_pid, sender_pid)
    assert_true(took < 50, "the queued notification took " + String(took))
    _ = sender^


def test_notifications_reports_a_lost_connection() raises:
    var listener = _connect_blocking(_conninfo(), 5000)
    _listen(listener, "pq_t5_gone")
    var listener_pid = _async_backend_pid(listener)
    var killer = _open(_conninfo())
    _ = _execute(
        killer, "SELECT pg_terminate_backend(" + String(listener_pid) + ")"
    )
    # The first call can still succeed: the backend is gone but the kernel
    # may not have seen the end of the stream yet, so retry rather than bet
    # on one round of timing.
    var error = Optional[PgError](None)
    var tries = 0
    while tries < 20:
        tries += 1
        error = _notifications_error(listener)
        if error:
            break
        _pause_until_readable(listener, 50)
    assert_true(
        Bool(error),
        "notifications() still succeeded after " + String(tries) + " tries",
    )
    assert_true(
        error.value().kind == PgErrorKind.CONNECTION, String(error.value())
    )
    _ = killer^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
