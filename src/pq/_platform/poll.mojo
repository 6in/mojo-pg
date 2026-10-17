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
  `poll_socket` single-branched.
- Only two symbols are called by name, `poll` and `WSAPoll`, and each in one
  signature. Mojo resolves an `external_call` symbol once per name, so a
  second signature for the same name -- or re-declaring something the stdlib
  already calls, such as `write` -- is a compile error.
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


def _poll_once(
    fd: Int, want_read: Bool, want_write: Bool, timeout_ms: Int
) -> Tuple[Int, Int]:
    """Call the platform's poll exactly once.

    Args:
        fd: The descriptor to poll.
        want_read: Whether to wait for readability.
        want_write: Whether to wait for writability.
        timeout_ms: Milliseconds to wait, `0` for a probe, `-1` for forever.

    Returns:
        The poll return value and the resulting flags, the latter always
        expressed with the POSIX `POLL*` values.
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
        return (Int(ret), Int(pfd.revents))
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
        return (Int(ret), Int(flags))


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
        timeout_ms: Milliseconds to wait. `0` returns immediately with the
            current state; `-1` waits forever.

    Returns:
        The conditions observed, or a `PollEvents` with only `timeout` set.

    Raises:
        PgError: `PgErrorKind.USAGE` when `timeout_ms` is below `-1`, when the
            descriptor is not open (`POLLNVAL`), or when the kernel rejects
            the call with `EBADF` / `EINVAL`; `PgErrorKind.CONNECTION` for any
            other `poll` failure, carrying the `errno` text.
    """
    if timeout_ms < -1:
        raise PgError(
            PgErrorKind.USAGE,
            String(
                "timeout_ms must be -1, 0 or positive (got ", timeout_ms, ")"
            ),
        )
    # A finite budget is anchored to a deadline so an EINTR retry resumes
    # with what is left rather than restarting the full wait.
    var deadline = monotonic() + timeout_ms * 1_000_000 if timeout_ms > 0 else 0
    var remaining = timeout_ms
    while True:
        var polled = _poll_once(fd, want_read, want_write, remaining)
        var ret = polled[0]
        var flags = Int16(polled[1])
        if ret < 0:
            var err = get_errno()
            if err == ErrNo.EINTR:
                if timeout_ms > 0:
                    var left = deadline - monotonic()
                    if left <= 0:
                        return PollEvents(False, False, False, False, True)
                    # Round up: a sub-millisecond remainder is still time the
                    # caller allowed, and 0 would turn the wait into a probe.
                    remaining = (left + 999_999) // 1_000_000
                continue
            var kind = PgErrorKind.CONNECTION
            if err == ErrNo.EBADF or err == ErrNo.EINVAL:
                kind = PgErrorKind.USAGE
            raise PgError(kind, String("poll failed: ", err))
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
