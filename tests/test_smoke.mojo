"""Phase 0 smoke test: toolchain works and libpq is loadable."""

from std.ffi import OwnedDLHandle, c_int
from std.os import getenv
from std.sys.info import platform_map
from std.testing import TestSuite, assert_equal, assert_true

comptime LIBPQ_DEFAULT = platform_map[
    "libpq", linux="libpq.so.5", macos="libpq.5.dylib"
]()


def _libpq_path() -> String:
    var path = getenv("PQ_MOJO_LIBPQ")
    return path if path != "" else String(LIBPQ_DEFAULT)


def test_toolchain() raises:
    assert_equal(1 + 1, 2)


def test_libpq_loads() raises:
    var lib = OwnedDLHandle(_libpq_path())
    assert_true(lib.check_symbol("PQlibVersion"))
    assert_true(lib.check_symbol("PQconnectdb"))


def test_libpq_version_at_least_14() raises:
    var lib = OwnedDLHandle(_libpq_path())
    var PQlibVersion = lib.get_function[c_int]("PQlibVersion")
    assert_true(Int(PQlibVersion()) >= 140000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
