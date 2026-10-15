"""Smoke test: the toolchain works and the shared libpq handle loads.

All library search logic lives in `pq._ffi.loader`; this file must not
rediscover it with its own `OwnedDLHandle`.
"""

from std.testing import TestSuite, assert_equal, assert_true

from pq._ffi.loader import libpq


def _lib_version() raises -> Int:
    """Return `PQlibVersion()` from the shared handle.

    `libpq()` raises `PgError`, which a `TestSuite` test (plain `raises`)
    cannot propagate directly, so it is converted to `Error` here.

    Returns:
        The `PQlibVersion()` value of the loaded libpq.

    Raises:
        Error: If libpq could not be loaded.
    """
    try:
        ref pq = libpq()
        return Int(pq.PQlibVersion())
    except e:
        raise Error(String(e))


def test_toolchain() raises:
    assert_equal(1 + 1, 2)


def test_libpq_loads() raises:
    assert_true(_lib_version() > 0)


def test_libpq_version_at_least_14() raises:
    assert_true(_lib_version() >= 140000)


def test_libpq_is_a_single_handle() raises:
    # Two `libpq()` calls must hit the same `_Global` entry (no reload).
    var first = _lib_version()
    var second = _lib_version()
    assert_equal(first, second)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
