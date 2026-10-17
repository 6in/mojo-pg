"""Tests for `pq._platform.poll`: readiness, hangup, timeout and misuse.

No PostgreSQL server is involved. Every case drives `poll_socket` with a
`pipe(2)` or a `socketpair(2)` whose state the test controls exactly, so the
expectations are the kernel's and not a server's timing.

`write` and `read` are deliberately not called through `external_call`: the
stdlib already binds both names with its own signatures, and Mojo resolves an
`external_call` symbol once per name. Writing a byte goes through
`std.io.FileDescriptor` instead; `pipe`, `socketpair` and `close` do not
collide.
"""

from std.ffi import c_int, external_call
from std.io import FileDescriptor
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import monotonic

from pq._platform.poll import TIMEOUT_MS_MAX, PollEvents, poll_socket
from pq.errors import PgError, PgErrorKind


def _pipe() raises -> Tuple[Int, Int]:
    """Create a pipe.

    Returns:
        The read end and the write end.
    """
    var fds: List[Int32] = [Int32(-1), Int32(-1)]
    var ret = external_call["pipe", c_int](fds.unsafe_ptr())
    assert_equal(Int(ret), 0, "pipe() failed")
    return (Int(fds[0]), Int(fds[1]))


def _socketpair() raises -> Tuple[Int, Int]:
    """Create a connected pair of AF_UNIX stream sockets.

    Returns:
        The two ends, which are interchangeable.
    """
    var fds: List[Int32] = [Int32(-1), Int32(-1)]
    var ret = external_call["socketpair", c_int](
        c_int(1), c_int(1), c_int(0), fds.unsafe_ptr()
    )
    assert_equal(Int(ret), 0, "socketpair() failed")
    return (Int(fds[0]), Int(fds[1]))


def _close(fd: Int):
    """Close one descriptor, ignoring the result.

    Args:
        fd: The descriptor to close.
    """
    _ = external_call["close", c_int](c_int(fd))


def _write_byte(fd: Int):
    """Write one byte so the peer becomes readable.

    Args:
        fd: The descriptor to write to.
    """
    var out = FileDescriptor(fd)
    out.write("A")


def _elapsed_ms(since: Int) -> Int:
    """Milliseconds elapsed since a `monotonic()` reading.

    Args:
        since: The earlier `monotonic()` value, in nanoseconds.

    Returns:
        The elapsed time in whole milliseconds.
    """
    return (monotonic() - since) // 1_000_000


def test_empty_pipe_read_end_times_out() raises:
    var ends = _pipe()
    var t0 = monotonic()
    var ev = poll_socket(ends[0], True, False, 50)
    var took = _elapsed_ms(t0)
    _close(ends[0])
    _close(ends[1])
    assert_true(ev.timeout, "expected a timeout")
    assert_false(ev.readable)
    assert_false(ev.hangup)
    assert_true(took >= 45, "returned too early: " + String(took) + " ms")
    assert_true(took < 2000, "returned too late: " + String(took) + " ms")


def test_pipe_write_end_is_writable() raises:
    var ends = _pipe()
    var ev = poll_socket(ends[1], False, True, 0)
    _close(ends[0])
    _close(ends[1])
    assert_true(ev.writable)
    assert_false(ev.timeout)
    assert_false(ev.hangup)


def test_written_byte_makes_read_end_readable() raises:
    var ends = _pipe()
    _write_byte(ends[1])
    var ev = poll_socket(ends[0], True, False, 0)
    # -1 means "wait forever", which still returns at once once data is in.
    var ev_blocking = poll_socket(ends[0], True, False, -1)
    _close(ends[0])
    _close(ends[1])
    assert_true(ev.readable)
    assert_false(ev.timeout)
    assert_true(ev_blocking.readable)
    assert_false(ev_blocking.timeout)


def test_read_end_reports_hangup_with_data_still_pending() raises:
    var ends = _pipe()
    _write_byte(ends[1])
    _close(ends[1])
    var ev = poll_socket(ends[0], True, False, 0)
    _close(ends[0])
    # Both flags at once: the unread byte must be readable *and* the writer
    # is gone. Reacting to the hangup alone would drop the byte.
    assert_true(ev.readable)
    assert_true(ev.hangup)
    assert_false(ev.timeout)


def test_closed_descriptor_is_a_usage_error() raises:
    var ends = _pipe()
    _close(ends[0])
    _close(ends[1])
    var raised = False
    try:
        _ = poll_socket(ends[0], True, False, 0)
    except e:
        raised = True
        assert_equal(e.kind, PgErrorKind.USAGE)
        assert_true(
            "not open" in e.message,
            "message was: " + e.message,
        )
    assert_true(raised, "polling a closed fd did not raise")


def test_timeout_below_minus_one_is_rejected() raises:
    var ends = _pipe()
    var raised = False
    try:
        _ = poll_socket(ends[0], True, False, -2)
    except e:
        raised = True
        assert_equal(e.kind, PgErrorKind.USAGE)
        assert_true(
            "timeout_ms must be" in e.message,
            "message was: " + e.message,
        )
    _close(ends[0])
    _close(ends[1])
    assert_true(raised, "timeout_ms = -2 did not raise")


def test_timeout_above_c_int_max_is_rejected() raises:
    var ends = _pipe()
    var raised = False
    var t0 = monotonic()
    try:
        # One past `TIMEOUT_MS_MAX`: as a `c_int` this wraps to -2147483648,
        # which `poll` reads as "wait forever", so the call must be refused
        # before libpq or the kernel ever sees it.
        _ = poll_socket(ends[0], True, False, TIMEOUT_MS_MAX + 1)
    except e:
        raised = True
        assert_equal(e.kind, PgErrorKind.USAGE)
        assert_true(
            "timeout_ms must be" in e.message,
            "message was: " + e.message,
        )
        assert_true(
            "2147483647" in e.message,
            "message was: " + e.message,
        )
    var took = _elapsed_ms(t0)
    _close(ends[0])
    _close(ends[1])
    assert_true(raised, "timeout_ms = 2147483648 did not raise")
    assert_true(took < 100, "it waited " + String(took) + " ms")


def test_timeout_at_c_int_max_is_accepted() raises:
    var ends = _pipe()
    _write_byte(ends[1])
    var t0 = monotonic()
    # The bound itself is a legal budget: with a byte already waiting the
    # call returns at once rather than sitting on the 24-day timeout.
    var ev = poll_socket(ends[0], True, False, TIMEOUT_MS_MAX)
    var took = _elapsed_ms(t0)
    _close(ends[0])
    _close(ends[1])
    assert_true(ev.readable)
    assert_false(ev.timeout)
    assert_true(took < 100, "it waited " + String(took) + " ms")


def test_socketpair_peer_close_sets_hangup_both_ways() raises:
    var ends = _socketpair()
    _close(ends[1])
    var readable = poll_socket(ends[0], True, False, 0)
    var writable = poll_socket(ends[0], False, True, 0)
    _close(ends[0])
    assert_true(readable.readable)
    assert_true(readable.hangup)
    assert_true(writable.writable)
    assert_true(writable.hangup)


def test_waiting_for_nothing_is_a_sleep() raises:
    var ends = _pipe()
    _write_byte(ends[1])
    var t0 = monotonic()
    # Readable data is ignored because no direction was requested.
    var ev = poll_socket(ends[0], False, False, 10)
    var took = _elapsed_ms(t0)
    _close(ends[0])
    _close(ends[1])
    assert_true(ev.timeout)
    assert_false(ev.readable)
    assert_true(took >= 10, "slept only " + String(took) + " ms")


def test_poll_events_writes_its_flags() raises:
    var ev = PollEvents(True, False, False, False, False)
    assert_equal(
        String(ev),
        (
            "PollEvents(readable=True, writable=False, hangup=False,"
            " error=False, timeout=False)"
        ),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
