"""Tests for the lazy `pq._ffi.loader` global when libpq cannot be loaded.

`PQ_MOJO_LIBPQ` is pointed at a path that cannot exist before the very first
`libpq()` call, so the process-global load attempt fails. The failure is then
observed twice: the loader attempts the load only once and caches the failed
result, so the second call reports the same `PgErrorKind.LIBPQ_LOAD` without
re-opening libpq.

This file owns its process (`tests/run_tests.sh` runs every `tests/test_*.mojo`
separately), so poisoning the environment here cannot affect the other test
files. No database is needed.
"""

from std.os import setenv
from std.testing import TestSuite, assert_true

from pq._ffi.loader import libpq
from pq.errors import PgError, PgErrorKind

comptime MISSING_LIBPQ = "/nonexistent/dir/libpq.so.5"
"""Unloadable library path, installed into `PQ_MOJO_LIBPQ` by `main`."""


def test_missing_library_fails_once_and_stays_failed() raises:
    # First call: triggers the one and only load attempt.
    var first_kind = PgErrorKind.TYPE_MISMATCH
    var first_message = String("")
    try:
        ref _ = libpq()
    except e:
        first_kind = e.kind
        first_message = e.message

    # Second call: must report the cached failure, not a fresh load attempt.
    var second_kind = PgErrorKind.TYPE_MISMATCH
    try:
        ref _ = libpq()
    except e:
        second_kind = e.kind

    assert_true(
        first_kind == PgErrorKind.LIBPQ_LOAD,
        "first libpq() must raise PgErrorKind.LIBPQ_LOAD",
    )
    assert_true(
        MISSING_LIBPQ in first_message,
        "message must list the tried path, got: " + first_message,
    )
    assert_true(
        second_kind == PgErrorKind.LIBPQ_LOAD,
        "second libpq() must report the cached LIBPQ_LOAD failure",
    )


def main() raises:
    # Must precede every libpq() call: the load is attempted once, lazily, on
    # the first call, so the environment has to be poisoned before the runner
    # starts.
    _ = setenv("PQ_MOJO_LIBPQ", MISSING_LIBPQ, True)
    TestSuite.discover_tests[__functions_in_module()]().run()
