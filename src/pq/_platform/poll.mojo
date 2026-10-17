"""Wait for readiness on one socket with `poll(2)`, or `WSAPoll` on Windows.

`poll_socket` is the whole module: it takes a file descriptor, the directions
the caller cares about and a millisecond budget, and reports what happened as
a `PollEvents`. A timeout is **not** an error -- it comes back as
`PollEvents.timeout`, and it is the caller (`AsyncConnection.wait_readable`
and friends) that turns it into `PgErrorKind.TIMEOUT` with its own wording.

`EINTR` is retried here rather than surfaced: the deadline is recomputed from
`std.time.monotonic()` so a signal cannot stretch the caller's budget, and an
infinite wait (`timeout_ms == -1`) simply polls again.

Three platform notes:

- The POSIX branch covers Linux and macOS, which agree on the `pollfd` layout
  (8 bytes) and on all six `POLL*` values this module reads.
- The `else` branch is Windows. It is written from the `WSAPoll`
  documentation and is **unverified**: no Windows machine has ever run it.
  `WSAPOLLFD` is 16 bytes, the flag values differ, and `WSAPoll` rejects
  `POLLERR` / `POLLHUP` / `POLLNVAL` in `events` with `WSAEINVAL`, so only the
  two input flags are ever requested. Its `revents` are translated to the
  POSIX values before they leave `_poll_once`, which keeps the decoding in
  `poll_socket` single-branched. Winsock reports failures through
  `WSAGetLastError` rather than `errno`, so `_poll_once` returns the error
  code alongside the flags and `_is_interrupted` / `_is_usage_error` classify
  it with per-platform constants. Two Windows-only caveats no code here can
  paper over: before Windows 10 version 2004 a failed TCP connect is not
  reported to `WSAPoll` at all (`POLLHUP | POLLERR | POLLWRNORM` on a failed
  connect arrived in 2004), so an asynchronous connection waiting in
  `wait_writable` only learns of the failure when its budget expires and it
  reports `TIMEOUT`; and Winsock needs `WSAStartup` before any socket call or
  every call fails with `WSANOTINITIALISED` (10093) -- libpq calls it itself
  when it opens a connection, so a `PQsocket` is safe, but using this module
  on a descriptor libpq did not create is not.
- Only three symbols are called by name, `poll`, `WSAPoll` and
  `WSAGetLastError`, and each in one signature. Mojo resolves an
  `external_call` symbol once per name, so a second signature for the same
  name -- or re-declaring something the stdlib already calls, such as `write`
  -- is a compile error.

The Windows branch was written against these, and `.gsd-lite/TRACE.md` holds
the line-by-line comparison:

- https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsapoll
- https://learn.microsoft.com/en-us/windows/win32/api/winsock2/ns-winsock2-wsapollfd
- https://learn.microsoft.com/en-us/windows/win32/winsock/windows-sockets-error-codes-2
"""

from std.ffi import ErrNo, c_int, external_call, get_errno
from std.sys.info import CompilationTarget
from std.time import monotonic

from pq.errors import PgError, PgErrorKind

comptime _POLLIN = Int16(0x0001)
"""Normalized "readable" bit; the POSIX value, also used for `WSAPoll` output.
"""

comptime _POLLOUT = Int16(0x0004)
"""Normalized "writable" bit."""

comptime _POLLERR = Int16(0x0008)
"""Normalized "error condition" bit."""

comptime _POLLHUP = Int16(0x0010)
"""Normalized "peer hung up" bit."""

comptime _POLLNVAL = Int16(0x0020)
"""Normalized "descriptor is not open" bit."""

comptime _WSA_POLLIN = Int16(0x0300)
"""Windows `POLLRDNORM | POLLRDBAND`, what `POLLIN` means to `WSAPoll`."""

comptime _WSA_POLLOUT = Int16(0x0010)
"""Windows `POLLWRNORM`, what `POLLOUT` means to `WSAPoll`."""

comptime _WSA_POLLERR = Int16(0x0001)
"""Windows `POLLERR`."""

comptime _WSA_POLLHUP = Int16(0x0002)
"""Windows `POLLHUP`."""

comptime _WSA_POLLNVAL = Int16(0x0004)
"""Windows `POLLNVAL`."""

comptime TIMEOUT_MS_MAX = 2_147_483_647
"""The largest `timeout_ms` any waiting entry point accepts: `c_int`'s own
maximum.

The budget ends up as the `c_int` third argument of `poll`, where anything
wider wraps instead of saturating: `2**32 + 50` would wait 50 ms and report a
timeout, and `2**31` would turn into a negative value and wait forever. Both
are a silent misreading of what the caller asked for, so the value is rejected
instead. The bound doubles as the guarantee that `timeout_ms * 1_000_000` --
every deadline in this package -- stays inside `Int`.
"""


def _reject_bad_timeout(timeout_ms: Int) raises PgError:
    """Reject a `timeout_ms` outside `-1 .. TIMEOUT_MS_MAX`.

    The one definition of what a millisecond budget may be, and of the wording
    used to refuse one. `poll_socket` calls it on the way in; the callers that
    compute a deadline before any waiting happens (`AsyncConnection`'s
    blocking helpers) call it themselves so they reject the budget just as
    early, with the identical text.

    Args:
        timeout_ms: The budget to validate.

    Raises:
        PgError: `PgErrorKind.USAGE` when `timeout_ms` is below `-1` or above
            `TIMEOUT_MS_MAX`.
    """
    if timeout_ms < -1 or timeout_ms > TIMEOUT_MS_MAX:
        raise PgError(
            PgErrorKind.USAGE,
            String(
                "timeout_ms must be -1, 0 or at most ",
                TIMEOUT_MS_MAX,
                " (got ",
                timeout_ms,
                ")",
            ),
        )


@fieldwise_init
struct _PollFd(TrivialRegisterPassable):
    """The POSIX `struct pollfd`, 8 bytes on Linux and macOS alike."""

    var fd: Int32
    """The descriptor being polled."""

    var events: Int16
    """Bitmask of the conditions to wait for."""

    var revents: Int16
    """Bitmask the kernel fills in with what actually happened."""


@fieldwise_init
struct _WsaPollFd(TrivialRegisterPassable):
    """The Windows `WSAPOLLFD`, 16 bytes: `SOCKET` is pointer-sized."""

    var fd: Int
    """The socket being polled."""

    var events: Int16
    """Bitmask of the conditions to wait for."""

    var revents: Int16
    """Bitmask `WSAPoll` fills in with what actually happened."""


@fieldwise_init
struct PollEvents(Copyable, Movable, TrivialRegisterPassable, Writable):
    """What one `poll_socket` call observed on the descriptor.

    The flags are not exclusive: a socket whose peer closed after sending
    data comes back `readable` *and* `hangup`, and the caller is expected to
    read the pending bytes before reacting to the hangup. `timeout` is the one
    flag that stands alone -- when it is set, nothing else is.
    """

    var readable: Bool
    """A read would not block (`POLLIN`)."""

    var writable: Bool
    """A write would not block (`POLLOUT`)."""

    var hangup: Bool
    """The peer closed its end (`POLLHUP`)."""

    var error: Bool
    """The descriptor reported an error condition (`POLLERR`)."""

    var timeout: Bool
    """The budget ran out before anything happened."""

    def write_to(self, mut writer: Some[Writer]):
        """Write the five flags in constructor form.

        Args:
            writer: The writer receiving the text.
        """
        writer.write(
            "PollEvents(readable=",
            self.readable,
            ", writable=",
            self.writable,
            ", hangup=",
            self.hangup,
            ", error=",
            self.error,
            ", timeout=",
            self.timeout,
            ")",
        )


def _is_interrupted(err: Int) -> Bool:
    """Whether a poll failure code means "a signal arrived, try again".

    Args:
        err: The code `_poll_once` reported.

    Returns:
        True only for POSIX `EINTR`. Windows has no equivalent worth
        retrying: `WSAEINTR` (10004) is raised when another thread calls
        `WSACancelBlockingCall`, which this package never does, and polling
        again would undo a deliberate cancellation.
    """
    comptime if CompilationTarget.is_linux() or CompilationTarget.is_macos():
        return err == Int(ErrNo.EINTR.value)
    else:
        return False


def _is_usage_error(err: Int) -> Bool:
    """Whether a poll failure code blames the caller rather than the network.

    Args:
        err: The code `_poll_once` reported.

    Returns:
        True when the descriptor or the arguments were wrong, which
        `poll_socket` turns into `PgErrorKind.USAGE` instead of
        `PgErrorKind.CONNECTION`. POSIX: `EBADF`, `EINVAL`. Windows:
        `WSAEBADF` 10009, `WSAEINVAL` 10022, `WSAENOTSOCK` 10038 -- the
        numbers are spelled out because Winsock codes are not in `ErrNo`.
    """
    comptime if CompilationTarget.is_linux() or CompilationTarget.is_macos():
        return err == Int(ErrNo.EBADF.value) or err == Int(ErrNo.EINVAL.value)
    else:
        return err == 10009 or err == 10022 or err == 10038


def _poll_once(
    fd: Int, want_read: Bool, want_write: Bool, timeout_ms: Int
) -> Tuple[Int, Int, Int]:
    """Call the platform's poll exactly once.

    Args:
        fd: The descriptor to poll.
        want_read: Whether to wait for readability.
        want_write: Whether to wait for writability.
        timeout_ms: Milliseconds to wait, `0` for a probe, `-1` for forever.

    Returns:
        The poll return value, the resulting flags -- always expressed with
        the POSIX `POLL*` values -- and the failure code, which is `0` unless
        the return value is negative. The code is read here rather than by the
        caller because the two platforms keep it in different places
        (`errno` versus `WSAGetLastError`) and both are clobbered by the next
        call.
    """
    comptime if CompilationTarget.is_linux() or CompilationTarget.is_macos():
        var events = Int16(0)
        if want_read:
            events |= _POLLIN
        if want_write:
            events |= _POLLOUT
        var pfd = _PollFd(Int32(fd), events, Int16(0))
        var ret = external_call["poll", c_int](
            Pointer(to=pfd), Int(1), c_int(timeout_ms)
        )
        var err = Int(get_errno().value) if ret < 0 else 0
        return (Int(ret), Int(pfd.revents), err)
    else:
        # Windows: never ask for POLLERR / POLLHUP / POLLNVAL -- WSAPoll
        # fails the whole call with WSAEINVAL if they appear in `events`.
        var events = Int16(0)
        if want_read:
            events |= _WSA_POLLIN
        if want_write:
            events |= _WSA_POLLOUT
        var pfd = _WsaPollFd(fd, events, Int16(0))
        var ret = external_call["WSAPoll", c_int](
            Pointer(to=pfd), Int(1), c_int(timeout_ms)
        )
        var flags = Int16(0)
        if (pfd.revents & _WSA_POLLIN) != 0:
            flags |= _POLLIN
        if (pfd.revents & _WSA_POLLOUT) != 0:
            flags |= _POLLOUT
        if (pfd.revents & _WSA_POLLERR) != 0:
            flags |= _POLLERR
        if (pfd.revents & _WSA_POLLHUP) != 0:
            flags |= _POLLHUP
        if (pfd.revents & _WSA_POLLNVAL) != 0:
            flags |= _POLLNVAL
        # Winsock leaves `errno` alone; the code lives in WSAGetLastError and
        # only the call that just failed may read it.
        var err = (
            Int(external_call["WSAGetLastError", c_int]()) if ret < 0 else 0
        )
        return (Int(ret), Int(flags), err)


def poll_socket(
    fd: Int, want_read: Bool, want_write: Bool, timeout_ms: Int
) raises PgError -> PollEvents:
    """Wait until `fd` is ready in one of the requested directions.

    Waiting for neither direction is legal and degrades to a sleep of
    `timeout_ms`, which is what makes `poll_socket(fd, False, False, n)` a
    usable pure delay.

    Args:
        fd: The descriptor to poll, normally libpq's `PQsocket`.
        want_read: Whether to wait for readability.
        want_write: Whether to wait for writability.
        timeout_ms: Milliseconds to wait, at most `TIMEOUT_MS_MAX`. `0`
            returns immediately with the current state; `-1` waits forever.

    Returns:
        The conditions observed, or a `PollEvents` with only `timeout` set.

    Raises:
        PgError: `PgErrorKind.USAGE` when `timeout_ms` is below `-1` or above
            `TIMEOUT_MS_MAX`, when the descriptor is not open (`POLLNVAL`), or
            when the call is rejected for a reason `_is_usage_error` claims
            (`EBADF` / `EINVAL`, or their Winsock equivalents);
            `PgErrorKind.CONNECTION` for any other `poll` failure, carrying
            the numeric failure code.
    """
    _reject_bad_timeout(timeout_ms)
    # A finite budget is anchored to a deadline so an EINTR retry resumes
    # with what is left rather than restarting the full wait. The nanosecond
    # product cannot overflow: `timeout_ms` is at most `TIMEOUT_MS_MAX`.
    var deadline = monotonic() + timeout_ms * 1_000_000 if timeout_ms > 0 else 0
    var remaining = timeout_ms
    while True:
        var polled = _poll_once(fd, want_read, want_write, remaining)
        var ret = polled[0]
        var flags = Int16(polled[1])
        if ret < 0:
            var err = polled[2]
            if _is_interrupted(err):
                if timeout_ms > 0:
                    var left = deadline - monotonic()
                    if left <= 0:
                        return PollEvents(False, False, False, False, True)
                    # Round up: a sub-millisecond remainder is still time the
                    # caller allowed, and 0 would turn the wait into a probe.
                    remaining = (left + 999_999) // 1_000_000
                continue
            var kind = PgErrorKind.CONNECTION
            if _is_usage_error(err):
                kind = PgErrorKind.USAGE
            raise PgError(kind, String("poll failed: errno ", err))
        if ret == 0:
            return PollEvents(False, False, False, False, True)
        # POLLNVAL is a closed or never-opened descriptor, which is a bug in
        # the caller rather than a condition to report: poll returns 1, not
        # -1, so it would otherwise read as "nothing is ready".
        if (flags & _POLLNVAL) != 0:
            raise PgError(
                PgErrorKind.USAGE,
                String("poll: fd ", fd, " is not open (POLLNVAL)"),
            )
        return PollEvents(
            readable=(flags & _POLLIN) != 0,
            writable=(flags & _POLLOUT) != 0,
            hangup=(flags & _POLLHUP) != 0,
            error=(flags & _POLLERR) != 0,
            timeout=False,
        )
