"""Tests for `pq.types_uuid`: canonical UUID text and bytes, no database.

Checks that the 36-character `8-4-4-4-12` form round-trips, that uppercase
input is normalised to lowercase, and that every near-miss spelling is
refused with `USAGE` from the constructor and `TYPE_MISMATCH` from
`UUID.parse`.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pq.errors import PgErrorKind
from pq.types_uuid import UUID

comptime _SAMPLE = "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
"""The canonical lowercase form used by most of the positive tests."""


def _ok(text: String) raises -> UUID:
    """Build a `UUID` from `text`, turning a `PgError` into a plain `Error`.

    A `TestSuite` test only declares `raises` (plain `Error`), so it cannot
    call a `raises PgError` function directly.

    Args:
        text: The canonical text to construct from.

    Returns:
        The constructed `UUID`.

    Raises:
        Error: If the constructor raised a `PgError`.
    """
    try:
        return UUID(text)
    except e:
        raise Error(String(e))


def _parsed(text: String) raises -> UUID:
    """Decode `text` with `UUID.parse`, turning a `PgError` into an `Error`.

    Args:
        text: The canonical text to decode.

    Returns:
        The decoded `UUID`.

    Raises:
        Error: If `UUID.parse` raised a `PgError`.
    """
    try:
        return UUID.parse(text)
    except e:
        raise Error(String(e))


def _init_error_kind(text: String) raises -> PgErrorKind:
    """Return the kind of the `PgError` the constructor raises for `text`.

    Args:
        text: Text the constructor is expected to reject.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If the constructor returned a value instead of raising.
    """
    try:
        _ = UUID(text)
    except e:
        return e.kind
    raise Error(String('expected PgError for "', text, '"'))


def _init_error_message(text: String) raises -> String:
    """Return the message of the `PgError` the constructor raises.

    Args:
        text: Text the constructor is expected to reject.

    Returns:
        The `message` field of the raised `PgError`.

    Raises:
        Error: If the constructor returned a value instead of raising.
    """
    try:
        _ = UUID(text)
    except e:
        return e.message
    raise Error(String('expected PgError for "', text, '"'))


def _parse_error_kind(text: String) raises -> PgErrorKind:
    """Return the kind of the `PgError` `UUID.parse` raises for `text`.

    Args:
        text: Text `UUID.parse` is expected to reject.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If `UUID.parse` returned a value instead of raising.
    """
    try:
        _ = UUID.parse(text)
    except e:
        return e.kind
    raise Error(String('expected PgError for "', text, '"'))


def _parse_error_message(text: String) raises -> String:
    """Return the message of the `PgError` `UUID.parse` raises.

    Args:
        text: Text `UUID.parse` is expected to reject.

    Returns:
        The `message` field of the raised `PgError`.

    Raises:
        Error: If `UUID.parse` returned a value instead of raising.
    """
    try:
        _ = UUID.parse(text)
    except e:
        return e.message
    raise Error(String('expected PgError for "', text, '"'))


def _assert_rejected(text: String) raises:
    """Assert both entry points refuse `text`, each with its own kind.

    Args:
        text: Text neither the constructor nor `UUID.parse` may accept.

    Raises:
        Error: If either entry point accepted `text` or reported the wrong
            kind or message.
    """
    assert_equal(_init_error_kind(text), PgErrorKind.USAGE)
    assert_true("invalid uuid literal" in _init_error_message(text))
    assert_equal(_parse_error_kind(text), PgErrorKind.TYPE_MISMATCH)
    assert_true("cannot decode" in _parse_error_message(text))


def _round_trip(text: String) raises:
    """Assert `text` survives both entry points unchanged.

    Args:
        text: Canonical lowercase text.

    Raises:
        Error: If either entry point rejected or altered `text`.
    """
    assert_equal(String(_ok(text)), text)
    assert_equal(String(_parsed(text)), text)


def test_lowercase_round_trip() raises:
    _round_trip(_SAMPLE)


def test_uppercase_is_written_lowercase() raises:
    comptime upper = "A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11"
    assert_equal(String(_ok(upper)), _SAMPLE)
    assert_equal(String(_parsed(upper)), _SAMPLE)
    assert_true(_ok(upper) == _ok(_SAMPLE))
    assert_false(_ok(upper) != _ok(_SAMPLE))


def test_all_zero_round_trip() raises:
    _round_trip("00000000-0000-0000-0000-000000000000")


def test_all_f_round_trip() raises:
    _round_trip("ffffffff-ffff-ffff-ffff-ffffffffffff")


def test_bytes_constructor_matches_text() raises:
    var bytes = Array[UInt8, 16](fill=0)
    for i in range(16):
        bytes[i] = UInt8(i)
    var value = UUID(bytes)
    assert_equal(String(value), "00010203-0405-0607-0809-0a0b0c0d0e0f")
    assert_equal(value.bytes[0], UInt8(0))
    assert_equal(value.bytes[15], UInt8(15))
    assert_equal(len(value.bytes), 16)


def test_bytes_round_trip_through_text() raises:
    var value = _ok(_SAMPLE)
    assert_equal(value.bytes[0], UInt8(0xA0))
    assert_equal(value.bytes[15], UInt8(0x11))
    assert_true(UUID(value.bytes) == value)


def test_ne_on_single_byte_difference() raises:
    var left = Array[UInt8, 16](fill=0)
    var right = Array[UInt8, 16](fill=0)
    right[15] = UInt8(1)
    assert_true(UUID(left) != UUID(right))
    assert_false(UUID(left) == UUID(right))


def test_rejects_too_short() raises:
    _assert_rejected("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a1")


def test_rejects_too_long() raises:
    _assert_rejected("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a119")


def test_rejects_non_hex_digit() raises:
    _assert_rejected("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380g11")


def test_rejects_misplaced_hyphen() raises:
    _assert_rejected("a0eebc999-c0b-4ef8-bb6d-6bb9bd380a11")


def test_rejects_braced_form() raises:
    _assert_rejected("{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11}")


def test_rejects_unhyphenated_form() raises:
    _assert_rejected("a0eebc999c0b4ef8bb6d6bb9bd380a11")


def test_rejects_empty_text() raises:
    _assert_rejected("")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
