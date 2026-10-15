"""Phase 0 hello: load libpq at runtime and print PQlibVersion().

Search order (mirrors HANDOFF §5.1):
  1. env PQ_MOJO_LIBPQ (full path)
  2. OS default soname
"""

from std.ffi import OwnedDLHandle, c_int
from std.os import getenv
from std.sys.info import platform_map

comptime LIBPQ_DEFAULT = platform_map[
    "libpq", linux="libpq.so.5", macos="libpq.5.dylib"
]()


def main() raises:
    var path = getenv("PQ_MOJO_LIBPQ")
    if path == "":
        path = String(LIBPQ_DEFAULT)

    var lib = OwnedDLHandle(path)
    var PQlibVersion = lib.get_function[c_int]("PQlibVersion")
    var v = Int(PQlibVersion())
    if v < 140000:
        raise Error(t"libpq too old: {v} (need >= 14)")

    print(t"loaded: {path}")
    print(t"PQlibVersion = {v} (PostgreSQL {v // 10000}.{v % 10000})")
