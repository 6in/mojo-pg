"""Tests for `pq.decode_text`: strict-OID text decoding, no database needed."""

from std.math import isinf, isnan
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pq.decode_text import decode_text, parse_bytea_hex
from pq.errors import PgErrorKind


def _ok[T: Copyable & Deinitable](text: String, oid: UInt32) raises -> T:
    """Decode `text` as `T`, turning a `PgError` into a plain `Error`.

    A `TestSuite` test only declares `raises` (plain `Error`), so it cannot
    call a `raises PgError` function directly.

    Parameters:
        T: The Mojo type requested from `decode_text`.

    Args:
        text: Value in PostgreSQL text format.
        oid: Column type OID reported by the server.

    Returns:
        The decoded value.

    Raises:
        Error: If `decode_text` raised a `PgError`.
    """
    try:
        return decode_text[T](text, oid)
    except e:
        raise Error(String(e))


def _error_kind[
    T: Copyable & Deinitable
](text: String, oid: UInt32) raises -> PgErrorKind:
    """Return the kind of the `PgError` raised by `decode_text[T]`.

    Parameters:
        T: The Mojo type requested from `decode_text`.

    Args:
        text: Value in PostgreSQL text format.
        oid: Column type OID reported by the server.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If `decode_text` returned a value instead of raising.
    """
    try:
        _ = decode_text[T](text, oid)
    except e:
        return e.kind
    raise Error(String("expected PgError for oid ", oid, " and ", text))


def _error_message[
    T: Copyable & Deinitable
](text: String, oid: UInt32) raises -> String:
    """Return the message of the `PgError` raised by `decode_text[T]`.

    Parameters:
        T: The Mojo type requested from `decode_text`.

    Args:
        text: Value in PostgreSQL text format.
        oid: Column type OID reported by the server.

    Returns:
        The `message` field of the raised `PgError`.

    Raises:
        Error: If `decode_text` returned a value instead of raising.
    """
    try:
        _ = decode_text[T](text, oid)
    except e:
        return e.message
    raise Error(String("expected PgError for oid ", oid, " and ", text))


def _parse_hex(text: String) raises -> List[UInt8]:
    """Call `parse_bytea_hex`, turning a `PgError` into a plain `Error`.

    Args:
        text: A `bytea` value in hex format.

    Returns:
        The decoded bytes.

    Raises:
        Error: If `parse_bytea_hex` raised a `PgError`.
    """
    try:
        return parse_bytea_hex(text)
    except e:
        raise Error(String(e))


def _parse_hex_kind(text: String) raises -> PgErrorKind:
    """Return the kind of the `PgError` raised by `parse_bytea_hex`.

    Args:
        text: A `bytea` value that `parse_bytea_hex` must reject.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If `parse_bytea_hex` returned a value instead of raising.
    """
    try:
        _ = parse_bytea_hex(text)
    except e:
        return e.kind
    raise Error(String("expected PgError for ", text))


def _assert_bytes(got: List[UInt8], expected: List[UInt8]) raises:
    """Assert that two byte lists have the same length and elements.

    Args:
        got: The decoded bytes.
        expected: The expected bytes.

    Raises:
        Error: If the lists differ.
    """
    assert_equal(len(got), len(expected))
    for i in range(len(expected)):
        assert_equal(got[i], expected[i])


# --- bool (OID 16) -----------------------------------------------------------


def test_bool_true() raises:
    assert_true(_ok[Bool]("t", 16))


def test_bool_false() raises:
    assert_false(_ok[Bool]("f", 16))


def test_bool_rejects_spelled_out_true() raises:
    assert_true(_error_kind[Bool]("true", 16) == PgErrorKind.TYPE_MISMATCH)


def test_bool_rejects_int4_oid() raises:
    assert_true(_error_kind[Bool]("t", 23) == PgErrorKind.TYPE_MISMATCH)


# --- int2 (OID 21) -----------------------------------------------------------


def test_int16_max() raises:
    assert_equal(_ok[Int16]("32767", 21), Int16(32767))


def test_int16_min() raises:
    assert_equal(_ok[Int16]("-32768", 21), Int16(-32768))


def test_int16_rejects_out_of_range() raises:
    assert_true(_error_kind[Int16]("32768", 21) == PgErrorKind.TYPE_MISMATCH)


# --- int4 (OID 23) -----------------------------------------------------------


def test_int32_max() raises:
    assert_equal(_ok[Int32]("2147483647", 23), Int32(2147483647))


def test_int32_min() raises:
    assert_equal(_ok[Int32]("-2147483648", 23), Int32(-2147483648))


def test_int32_rejects_out_of_range() raises:
    assert_true(
        _error_kind[Int32]("2147483648", 23) == PgErrorKind.TYPE_MISMATCH
    )


def test_int32_rejects_int2_oid() raises:
    # OIDs match exactly: an int2 column never widens into `Int32`.
    assert_true(_error_kind[Int32]("1", 21) == PgErrorKind.TYPE_MISMATCH)


def test_int32_rejects_non_numeric_text() raises:
    assert_true(_error_kind[Int32]("abc", 23) == PgErrorKind.TYPE_MISMATCH)


def test_int32_rejects_empty_text() raises:
    assert_true(_error_kind[Int32]("", 23) == PgErrorKind.TYPE_MISMATCH)


def test_int32_rejects_decimal_text() raises:
    assert_true(_error_kind[Int32]("1.5", 23) == PgErrorKind.TYPE_MISMATCH)


# --- int8 (OID 20) -----------------------------------------------------------


def test_int64_max() raises:
    assert_equal(_ok[Int64]("9223372036854775807", 20), Int64.MAX)


def test_int64_min() raises:
    assert_equal(_ok[Int64]("-9223372036854775808", 20), Int64.MIN)


def test_int_max() raises:
    assert_equal(_ok[Int]("9223372036854775807", 20), Int.MAX)


def test_int_min() raises:
    assert_equal(_ok[Int]("-9223372036854775808", 20), Int.MIN)


# --- float4 (OID 700) / float8 (OID 701) ------------------------------------


def test_float32_value() raises:
    assert_equal(_ok[Float32]("1.5", 700), Float32(1.5))


def test_float32_nan() raises:
    assert_true(isnan(_ok[Float32]("NaN", 700)))


def test_float32_infinities() raises:
    var positive = _ok[Float32]("Infinity", 700)
    var negative = _ok[Float32]("-Infinity", 700)
    assert_true(isinf(positive))
    assert_true(positive > 0)
    assert_true(isinf(negative))
    assert_true(negative < 0)


def test_float32_rejects_non_numeric_text() raises:
    assert_true(_error_kind[Float32]("abc", 700) == PgErrorKind.TYPE_MISMATCH)


def test_float64_value() raises:
    assert_equal(_ok[Float64]("1.5", 701), Float64(1.5))


def test_float64_nan() raises:
    assert_true(isnan(_ok[Float64]("NaN", 701)))


def test_float64_infinities() raises:
    var positive = _ok[Float64]("Infinity", 701)
    var negative = _ok[Float64]("-Infinity", 701)
    assert_true(isinf(positive))
    assert_true(positive > 0)
    assert_true(isinf(negative))
    assert_true(negative < 0)


def test_float64_rejects_non_numeric_text() raises:
    assert_true(_error_kind[Float64]("abc", 701) == PgErrorKind.TYPE_MISMATCH)


def test_float64_rejects_float4_oid() raises:
    assert_true(_error_kind[Float64]("1.5", 700) == PgErrorKind.TYPE_MISMATCH)


# --- text: any OID ----------------------------------------------------------


def test_string_accepts_text_oid() raises:
    assert_equal(_ok[String]("hello", 25), "hello")


def test_string_accepts_varchar_oid() raises:
    assert_equal(_ok[String]("hello", 1043), "hello")


def test_string_accepts_bpchar_oid() raises:
    assert_equal(_ok[String]("hello", 1042), "hello")


def test_string_accepts_name_oid() raises:
    assert_equal(_ok[String]("hello", 19), "hello")


def test_string_accepts_numeric_oid() raises:
    assert_equal(_ok[String]("12.34", 1700), "12.34")


def test_string_accepts_bool_oid() raises:
    assert_equal(_ok[String]("t", 16), "t")


# --- bytea (OID 17) ---------------------------------------------------------


def test_bytea_empty() raises:
    var expected = List[UInt8]()
    _assert_bytes(_ok[List[UInt8]]("\\x", 17), expected)


def test_bytea_two_bytes() raises:
    var expected: List[UInt8] = [1, 2]
    _assert_bytes(_ok[List[UInt8]]("\\x0102", 17), expected)


def test_bytea_mixed_case_digits() raises:
    var expected: List[UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
    _assert_bytes(_ok[List[UInt8]]("\\xDEADbeef", 17), expected)


def test_bytea_rejects_odd_length() raises:
    assert_true(
        _error_kind[List[UInt8]]("\\x012", 17) == PgErrorKind.TYPE_MISMATCH
    )


def test_bytea_rejects_non_hex_digits() raises:
    assert_true(
        _error_kind[List[UInt8]]("\\xzz", 17) == PgErrorKind.TYPE_MISMATCH
    )


def test_bytea_rejects_missing_hex_prefix() raises:
    assert_true(
        _error_kind[List[UInt8]]("abc", 17) == PgErrorKind.TYPE_MISMATCH
    )


def test_bytea_rejects_escape_format() raises:
    assert_true(
        _error_kind[List[UInt8]]("\\\\000", 17) == PgErrorKind.TYPE_MISMATCH
    )


def test_bytea_rejects_text_oid() raises:
    assert_true(
        _error_kind[List[UInt8]]("\\x0102", 25) == PgErrorKind.TYPE_MISMATCH
    )


# --- parse_bytea_hex, called directly ---------------------------------------


def test_parse_bytea_hex_decodes_bytes() raises:
    var expected: List[UInt8] = [0x41, 0x42, 0x43]
    _assert_bytes(_parse_hex("\\x414243"), expected)


def test_parse_bytea_hex_rejects_missing_prefix() raises:
    assert_true(_parse_hex_kind("414243") == PgErrorKind.TYPE_MISMATCH)


# --- messages name the requested type and echo the input --------------------


def test_message_names_int4_and_echoes_text() raises:
    var message = _error_message[Int32]("abc", 23)
    assert_true("int4" in message)
    assert_true("abc" in message)


def test_message_names_int2_on_range_error() raises:
    var message = _error_message[Int16]("32768", 21)
    assert_true("int2" in message)
    assert_true("32768" in message)


def test_message_names_bool_on_oid_mismatch() raises:
    var message = _error_message[Bool]("t", 23)
    assert_true("bool" in message)
    assert_true("t" in message)


def test_message_names_float8_on_oid_mismatch() raises:
    var message = _error_message[Float64]("1.5", 700)
    assert_true("float8" in message)
    assert_true("1.5" in message)


def test_message_names_int8_on_parse_error() raises:
    var message = _error_message[Int64]("x9", 20)
    assert_true("int8" in message)
    assert_true("x9" in message)


def test_message_names_bytea_on_odd_length() raises:
    var message = _error_message[List[UInt8]]("\\x012", 17)
    assert_true("bytea" in message)
    assert_true("\\x012" in message)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
