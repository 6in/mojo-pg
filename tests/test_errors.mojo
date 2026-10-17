"""Tests for `pq.errors`: typed raises, formatting and default fields."""

from pq.errors import PgError, PgErrorKind
from std.testing import TestSuite, assert_equal, assert_true


def _raise_connection() raises PgError:
    """Raise a connection-kind `PgError` for the tests below.

    Raises:
        PgError: Always, with kind `PgErrorKind.CONNECTION`.
    """
    raise PgError(PgErrorKind.CONNECTION, "boom")


def test_typed_raise_preserves_kind() raises:
    var caught = PgErrorKind.TYPE_MISMATCH
    try:
        _raise_connection()
    except e:
        caught = e.kind
    assert_true(caught == PgErrorKind.CONNECTION)


def test_string_contains_kind_and_message() raises:
    var text = String("")
    try:
        _raise_connection()
    except e:
        text = String(e)
    assert_true("Connection" in text)
    assert_true("boom" in text)


def test_optional_fields_default_to_empty() raises:
    var e = PgError(PgErrorKind.SERVER, "msg")
    assert_equal(e.sqlstate, "")
    assert_equal(e.severity, "")
    assert_equal(e.detail, "")
    assert_equal(e.hint, "")
    assert_equal(e.position, "")
    assert_equal(e.context, "")


def test_usage_kind_discriminant() raises:
    assert_equal(PgErrorKind.USAGE.value, 5)


def test_usage_kind_writes_its_name() raises:
    assert_equal(String(PgErrorKind.USAGE), "Usage")


def test_usage_error_string_contains_kind() raises:
    var e = PgError(PgErrorKind.USAGE, "m")
    assert_true("kind=Usage" in String(e))


def test_usage_differs_from_type_mismatch() raises:
    assert_true(PgErrorKind.USAGE != PgErrorKind.TYPE_MISMATCH)


def test_timeout_kind_discriminant_and_name() raises:
    assert_equal(PgErrorKind.TIMEOUT.value, 6)
    assert_equal(String(PgErrorKind.TIMEOUT), "Timeout")
    assert_true(PgErrorKind.TIMEOUT != PgErrorKind.USAGE)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
