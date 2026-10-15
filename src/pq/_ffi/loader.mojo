"""Process-wide libpq handle: candidate search, version gate and accessors.

The library is dlopen'd at most once per process. `_Global["pq_libpq", _open]`
holds a `LoadState`, which is either a resolved `LibpqFFI` or the collected
reason why every candidate failed; `_open` is non-raising and never aborts, so
a missing or too-old libpq surfaces as `PgError(PgErrorKind.LIBPQ_LOAD, ...)`
from `libpq()` / `libpq_ptr()` instead of killing the process. A cached failure
is never retried: later calls raise the same error.

Candidates come from `PQ_MOJO_LIBPQ` when it is set (that one path only),
otherwise from the OS default sonames.
"""

from std.ffi import _Global
from std.os import getenv
from std.sys.info import platform_map

from pq.errors import PgError, PgErrorKind

from .functions import LibpqFFI

comptime _MIN_LIBPQ_VERSION = 140000

comptime _DEFAULT_CANDIDATES = platform_map[
    "libpq_candidates",
    linux="libpq.so.5,libpq.so",
    macos="libpq.5.dylib,libpq.dylib,/opt/homebrew/opt/libpq/lib/libpq.5.dylib,/usr/local/opt/libpq/lib/libpq.5.dylib",
]()


def _candidates() -> List[String]:
    var override = getenv("PQ_MOJO_LIBPQ")
    if override != "":
        return [override]
    var defaults = String(_DEFAULT_CANDIDATES)
    var out = List[String]()
    for part in defaults.split(","):
        out.append(String(part))
    return out^


@fieldwise_init
struct LoadState(Movable):
    var ffi: Optional[LibpqFFI]
    var error: String


def _open() -> LoadState:
    var tried = String()
    for path in _candidates():
        var reason: String
        try:
            var ffi = LibpqFFI(path)
            var version = Int(ffi.PQlibVersion())
            if version >= _MIN_LIBPQ_VERSION:
                return LoadState(Optional[LibpqFFI](ffi^), String())
            reason = String(
                "libpq too old: ",
                version,
                " (need >= ",
                _MIN_LIBPQ_VERSION,
                ")",
            )
        except e:
            reason = String(e)
        if tried != "":
            tried += "; "
        tried += String(path, ": ", reason)
    return LoadState(
        Optional[LibpqFFI](), String("libpq not found. tried: ", tried)
    )


comptime _STATE = _Global["pq_libpq", _open]


def _state_ptr() raises PgError -> Pointer[LoadState, MutUntrackedOrigin]:
    try:
        return _STATE.get_or_create_ptr()
    except e:
        raise PgError(PgErrorKind.LIBPQ_LOAD, String(e))


def libpq_ptr() raises PgError -> Pointer[LibpqFFI, MutUntrackedOrigin]:
    var state = _state_ptr()
    if not state[].ffi:
        raise PgError(PgErrorKind.LIBPQ_LOAD, state[].error.copy())
    var p = Pointer(to=state[].ffi.value())
    return Pointer[LibpqFFI, MutUntrackedOrigin](unsafe_from_address=Int(p))


def libpq() raises PgError -> ref[MutUntrackedOrigin] LibpqFFI:
    return libpq_ptr()[]
