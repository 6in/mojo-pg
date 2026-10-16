"""Tests for `pq.types_numeric`: `Decimal` literals, no database needed.

Every round-trip case asserts that printing what was parsed gives the input
back byte for byte, which is the property that makes `Decimal` able to carry
a PostgreSQL `numeric` without losing its trailing zeroes.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pq.errors import PgErrorKind
from pq.types_numeric import Decimal


def _ok(text: String) raises -> Decimal:
    """Construct a `Decimal`, turning a `PgError` into a plain `Error`.

    A `TestSuite` test only declares `raises` (plain `Error`), so it cannot
    call a `raises PgError` function directly.

    Args:
        text: The literal to read.

    Returns:
        The constructed value.

    Raises:
        Error: If the constructor raised a `PgError`.
    """
    try:
        return Decimal(text)
    except e:
        raise Error(String(e))


def _parsed(text: String) raises -> Decimal:
    """Read a `Decimal` with `Decimal.parse`, raising a plain `Error`.

    Args:
        text: The literal to read.

    Returns:
        The parsed value.

    Raises:
        Error: If `Decimal.parse` raised a `PgError`.
    """
    try:
        return Decimal.parse(text)
    except e:
        raise Error(String(e))


def _error_kind(text: String) raises -> PgErrorKind:
    """Return the kind of the `PgError` the constructor raises.

    Args:
        text: A literal the constructor should reject.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If the constructor returned a value instead of raising.
    """
    try:
        _ = Decimal(text)
    except e:
        return e.kind
    raise Error(String('expected PgError for "', text, '"'))


def _error_message(text: String) raises -> String:
    """Return the message of the `PgError` the constructor raises.

    Args:
        text: A literal the constructor should reject.

    Returns:
        The `message` field of the raised `PgError`.

    Raises:
        Error: If the constructor returned a value instead of raising.
    """
    try:
        _ = Decimal(text)
    except e:
        return e.message
    raise Error(String('expected PgError for "', text, '"'))


def _parse_error_kind(text: String) raises -> PgErrorKind:
    """Return the kind of the `PgError` `Decimal.parse` raises.

    Args:
        text: A literal `Decimal.parse` should reject.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If `Decimal.parse` returned a value instead of raising.
    """
    try:
        _ = Decimal.parse(text)
    except e:
        return e.kind
    raise Error(String('expected PgError for "', text, '"'))


def _parse_error_message(text: String) raises -> String:
    """Return the message of the `PgError` `Decimal.parse` raises.

    Args:
        text: A literal `Decimal.parse` should reject.

    Returns:
        The `message` field of the raised `PgError`.

    Raises:
        Error: If `Decimal.parse` returned a value instead of raising.
    """
    try:
        _ = Decimal.parse(text)
    except e:
        return e.message
    raise Error(String('expected PgError for "', text, '"'))


def _assert_round_trip(text: String) raises:
    """Assert `text` survives a parse and print unchanged, both ways in.

    Args:
        text: A valid literal already in canonical form.

    Raises:
        Error: If either entry point rejected `text` or printed it back
            differently.
    """
    assert_equal(String(_ok(text)), text)
    assert_equal(String(_parsed(text)), text)


def _assert_rejected(text: String) raises:
    """Assert both entry points reject `text`, each with its own error.

    Args:
        text: A literal outside the accepted grammar.

    Raises:
        Error: If either call succeeded or reported the wrong kind or
            message.
    """
    assert_equal(_error_kind(text), PgErrorKind.USAGE)
    assert_true("invalid numeric literal" in _error_message(text))
    assert_equal(_parse_error_kind(text), PgErrorKind.TYPE_MISMATCH)
    assert_true("cannot decode" in _parse_error_message(text))


# --- round trips -------------------------------------------------------------


def test_round_trip_one_and_a_half() raises:
    _assert_round_trip("1.50")
    assert_equal(_ok("1.50").dscale(), 2)


def test_round_trip_small_negative() raises:
    _assert_round_trip("-0.001")


def test_round_trip_zero() raises:
    _assert_round_trip("0")


def test_round_trip_zero_with_scale() raises:
    _assert_round_trip("0.00")
    assert_equal(_ok("0.00").dscale(), 2)


def test_round_trip_one_millionth() raises:
    _assert_round_trip("0.000001")


def test_round_trip_crossing_groups() raises:
    _assert_round_trip("12345678.9")


def test_round_trip_trailing_zero_group() raises:
    _assert_round_trip("1000000")


def test_round_trip_thirty_digits() raises:
    _assert_round_trip("123456789012345678901234567890.123456789")


def test_round_trip_trailing_zeroes_kept() raises:
    _assert_round_trip("12.3400")
    assert_equal(_ok("12.3400").dscale(), 4)


def test_round_trip_fourth_decimal() raises:
    _assert_round_trip("0.0001")


def test_round_trip_half() raises:
    _assert_round_trip("0.5")


def test_round_trip_negative_half() raises:
    _assert_round_trip("-0.5")


def test_round_trip_131_digit_integer() raises:
    var text = String("1")
    for _ in range(130):
        text += "0"
    assert_equal(text.byte_length(), 131)
    _assert_round_trip(text)


# --- canonical forms ---------------------------------------------------------


def test_leading_plus_is_dropped() raises:
    assert_equal(String(_ok("+1")), "1")


def test_trailing_point_has_no_scale() raises:
    assert_equal(String(_ok("1.")), "1")
    assert_equal(_ok("1.").dscale(), 0)


def test_leading_point_gains_a_zero() raises:
    assert_equal(String(_ok(".5")), "0.5")
    assert_equal(_ok(".5").dscale(), 1)


# --- equality ----------------------------------------------------------------


def test_scale_does_not_affect_equality() raises:
    assert_true(_ok("1.0") == _ok("1.00"))


def test_zero_scales_are_equal() raises:
    assert_true(_ok("0") == _ok("0.00"))


def test_nan_equals_nan() raises:
    assert_true(_ok("NaN") == _ok("NaN"))


def test_sign_affects_equality() raises:
    assert_true(_ok("1") != _ok("-1"))


def test_infinity_equals_infinity() raises:
    assert_true(_ok("Infinity") == _ok("Infinity"))


def test_infinities_differ_by_sign() raises:
    assert_true(_ok("Infinity") != _ok("-Infinity"))


def test_nan_differs_from_infinity() raises:
    assert_true(_ok("NaN") != _ok("Infinity"))


# --- special values ----------------------------------------------------------


def test_nan_prints_nan() raises:
    assert_equal(String(Decimal.nan()), "NaN")
    _assert_round_trip("NaN")


def test_infinity_prints_infinity() raises:
    assert_equal(String(Decimal.infinity()), "Infinity")
    _assert_round_trip("Infinity")


def test_negative_infinity_prints_signed_infinity() raises:
    assert_equal(String(Decimal.negative_infinity()), "-Infinity")
    _assert_round_trip("-Infinity")


def test_leading_plus_infinity_is_accepted() raises:
    assert_equal(String(_ok("+Infinity")), "Infinity")


def test_nan_predicates() raises:
    var value = Decimal.nan()
    assert_true(value.is_nan())
    assert_false(value.is_infinite())
    assert_false(value.is_finite())


def test_infinity_predicates() raises:
    var value = Decimal.infinity()
    assert_false(value.is_nan())
    assert_true(value.is_infinite())
    assert_false(value.is_finite())


def test_negative_infinity_predicates() raises:
    var value = Decimal.negative_infinity()
    assert_false(value.is_nan())
    assert_true(value.is_infinite())
    assert_false(value.is_finite())


def test_finite_predicates() raises:
    var value = _ok("-0.001")
    assert_false(value.is_nan())
    assert_false(value.is_infinite())
    assert_true(value.is_finite())


def test_specials_have_no_scale() raises:
    assert_equal(Decimal.nan().dscale(), 0)
    assert_equal(Decimal.infinity().dscale(), 0)
    assert_equal(Decimal.negative_infinity().dscale(), 0)


# --- rejected literals -------------------------------------------------------


def test_rejects_exponent() raises:
    _assert_rejected("1e5")


def test_rejects_hex() raises:
    _assert_rejected("0x10")


def test_rejects_empty() raises:
    _assert_rejected("")


def test_rejects_bare_point() raises:
    _assert_rejected(".")


def test_rejects_bare_minus() raises:
    _assert_rejected("-")


def test_rejects_bare_plus() raises:
    _assert_rejected("+")


def test_rejects_leading_space() raises:
    _assert_rejected(" 1")


def test_rejects_trailing_space() raises:
    _assert_rejected("1 ")


def test_rejects_two_points() raises:
    _assert_rejected("1.2.3")


def test_rejects_lowercase_inf() raises:
    _assert_rejected("inf")


def test_rejects_lowercase_nan() raises:
    _assert_rejected("nan")


def test_rejects_digit_separator() raises:
    _assert_rejected("1_000")


def test_rejects_scale_over_limit() raises:
    var text = String("0.")
    for _ in range(16384):
        text += "1"
    assert_equal(_error_kind(text), PgErrorKind.USAGE)
    assert_true("invalid numeric literal" in _error_message(text))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
