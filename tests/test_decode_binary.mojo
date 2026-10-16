"""Tests for `pq.decode_binary`: strict binary decoding, no database needed.

Every expected value is the wire form PostgreSQL 17 and 14 were observed to
send, written here as a hex string and turned into bytes by `_hex`.
"""

from std.math import isinf, isnan
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pq.decode_binary import decode_binary
from pq.decode_text import parse_bytea_hex
from pq.errors import PgErrorKind


def _hex(digits: String) raises -> List[UInt8]:
    """Turn a hex string into the bytes it spells.

    Reuses `parse_bytea_hex` by prefixing the `\\x` marker it expects, so an
    empty `digits` yields an empty list.

    Args:
        digits: An even number of hex digits, in either case.

    Returns:
        One byte per pair of digits.

    Raises:
        Error: If `digits` is not valid hex.
    """
    try:
        return parse_bytea_hex(String("\\x", digits))
    except e:
        raise Error(String(e))


def _ok[T: Copyable & Deinitable](digits: String, oid: UInt32) raises -> T:
    """Decode `digits` as `T`, turning a `PgError` into a plain `Error`.

    A `TestSuite` test only declares `raises` (plain `Error`), so it cannot
    call a `raises PgError` function directly.

    Parameters:
        T: The Mojo type requested from `decode_binary`.

    Args:
        digits: The cell's binary-format bytes, as hex digits.
        oid: Column type OID reported by the server.

    Returns:
        The decoded value.

    Raises:
        Error: If `decode_binary` raised a `PgError`.
    """
    var bytes = _hex(digits)
    try:
        return decode_binary[T](Span[UInt8](bytes), oid)
    except e:
        raise Error(String(e))


def _error_kind[
    T: Copyable & Deinitable
](digits: String, oid: UInt32) raises -> PgErrorKind:
    """Return the kind of the `PgError` raised by `decode_binary[T]`.

    Parameters:
        T: The Mojo type requested from `decode_binary`.

    Args:
        digits: The cell's binary-format bytes, as hex digits.
        oid: Column type OID reported by the server.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If `decode_binary` returned a value instead of raising.
    """
    var bytes = _hex(digits)
    try:
        _ = decode_binary[T](Span[UInt8](bytes), oid)
    except e:
        return e.kind
    raise Error(String("expected PgError for oid ", oid, " and ", digits))


def _error_message[
    T: Copyable & Deinitable
](digits: String, oid: UInt32) raises -> String:
    """Return the message of the `PgError` raised by `decode_binary[T]`.

    Parameters:
        T: The Mojo type requested from `decode_binary`.

    Args:
        digits: The cell's binary-format bytes, as hex digits.
        oid: Column type OID reported by the server.

    Returns:
        The `message` field of the raised `PgError`.

    Raises:
        Error: If `decode_binary` returned a value instead of raising.
    """
    var bytes = _hex(digits)
    try:
        _ = decode_binary[T](Span[UInt8](bytes), oid)
    except e:
        return e.message
    raise Error(String("expected PgError for oid ", oid, " and ", digits))


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


def _assert_length_rejected[
    T: Copyable & Deinitable
](digits: String, oid: UInt32, expected: Int) raises:
    """Assert a wrong-width cell is a `TYPE_MISMATCH` naming the width.

    Parameters:
        T: The Mojo type requested from `decode_binary`.

    Args:
        digits: A cell that is not `expected` bytes wide, as hex digits.
        oid: The OID matching `T`, so only the length can fail.
        expected: The width `T` requires.

    Raises:
        Error: If the call succeeded or reported the wrong kind or message.
    """
    assert_equal(_error_kind[T](digits, oid), PgErrorKind.TYPE_MISMATCH)
    var message = _error_message[T](digits, oid)
    assert_true(String("bytes, expected ", expected) in message)


def _assert_oid_rejected[
    T: Copyable & Deinitable
](digits: String, oid: UInt32) raises:
    """Assert a wrong OID is a `TYPE_MISMATCH` that points at the text path.

    Parameters:
        T: The Mojo type requested from `decode_binary`.

    Args:
        digits: Any cell bytes, as hex digits; never reached.
        oid: An OID that does not match `T`.

    Raises:
        Error: If the call succeeded or reported the wrong kind or message.
    """
    assert_equal(_error_kind[T](digits, oid), PgErrorKind.TYPE_MISMATCH)
    var message = _error_message[T](digits, oid)
    assert_true(String("oid ", oid) in message)
    assert_true("ResultFormat.TEXT" in message)


# --- bool (OID 16) -----------------------------------------------------------


def test_bool_true() raises:
    assert_true(_ok[Bool]("01", 16))


def test_bool_false() raises:
    assert_false(_ok[Bool]("00", 16))


def test_bool_rejects_byte_two() raises:
    assert_equal(_error_kind[Bool]("02", 16), PgErrorKind.TYPE_MISMATCH)
    var message = _error_message[Bool]("02", 16)
    assert_true("expected 0 or 1" in message)
    assert_true("byte is 2" in message)


# --- int2 / int4 / int8 ------------------------------------------------------


def test_int16_min() raises:
    assert_equal(_ok[Int16]("8000", 21), Int16(-32768))


def test_int16_max() raises:
    assert_equal(_ok[Int16]("7fff", 21), Int16(32767))


def test_int32_min() raises:
    assert_equal(_ok[Int32]("80000000", 23), Int32(-2147483648))


def test_int32_max() raises:
    assert_equal(_ok[Int32]("7fffffff", 23), Int32(2147483647))


def test_int64_min() raises:
    assert_equal(_ok[Int64]("8000000000000000", 20), Int64.MIN)


def test_int64_max() raises:
    assert_equal(_ok[Int64]("7fffffffffffffff", 20), Int64.MAX)


def test_int_min() raises:
    assert_equal(_ok[Int]("8000000000000000", 20), Int.MIN)


def test_int_max() raises:
    assert_equal(_ok[Int]("7fffffffffffffff", 20), Int.MAX)


# --- float4 (OID 700) --------------------------------------------------------


def test_float32_nan() raises:
    assert_true(isnan(_ok[Float32]("7fc00000", 700)))


def test_float32_positive_infinity() raises:
    var value = _ok[Float32]("7f800000", 700)
    assert_true(isinf(value))
    assert_true(value > 0)


def test_float32_negative_infinity() raises:
    var value = _ok[Float32]("ff800000", 700)
    assert_true(isinf(value))
    assert_true(value < 0)


def test_float32_negative_zero() raises:
    var value = _ok[Float32]("80000000", 700)
    assert_equal(value, Float32(0))
    var reciprocal = Float32(1) / value
    assert_true(isinf(reciprocal))
    assert_true(reciprocal < 0)


def test_float32_one_and_a_half() raises:
    assert_equal(_ok[Float32]("3fc00000", 700), Float32(1.5))


# --- float8 (OID 701) --------------------------------------------------------


def test_float64_nan() raises:
    assert_true(isnan(_ok[Float64]("7ff8000000000000", 701)))


def test_float64_negative_zero() raises:
    var value = _ok[Float64]("8000000000000000", 701)
    assert_equal(value, Float64(0))
    var reciprocal = Float64(1) / value
    assert_true(isinf(reciprocal))
    assert_true(reciprocal < 0)


def test_float64_one_tenth() raises:
    assert_equal(_ok[Float64]("3fb999999999999a", 701), Float64(0.1))


def test_float64_1e300() raises:
    assert_equal(_ok[Float64]("7e37e43c8800759c", 701), Float64(1e300))


# --- text and friends (OIDs 25 / 1043 / 1042 / 19 / 114) ---------------------


def test_text_multibyte() raises:
    assert_equal(_ok[String]("68c3a96c6c6f", 25), "héllo")


def test_text_empty() raises:
    assert_equal(_ok[String]("", 25), "")


def test_varchar_accepted() raises:
    assert_equal(_ok[String]("68c3a96c6c6f", 1043), "héllo")


def test_bpchar_accepted() raises:
    assert_equal(_ok[String]("68c3a96c6c6f", 1042), "héllo")


def test_name_accepted() raises:
    assert_equal(_ok[String]("68c3a96c6c6f", 19), "héllo")


def test_json_accepted() raises:
    assert_equal(_ok[String]("68c3a96c6c6f", 114), "héllo")


def test_text_keeps_embedded_nul() raises:
    var value = _ok[String]("006800", 25)
    assert_equal(value.byte_length(), 3)


# --- jsonb (OID 3802) --------------------------------------------------------


def test_jsonb_strips_version_byte() raises:
    assert_equal(_ok[String]("017b7d", 3802), "{}")


def test_jsonb_rejects_version_two() raises:
    assert_equal(_error_kind[String]("027b7d", 3802), PgErrorKind.TYPE_MISMATCH)
    var message = _error_message[String]("027b7d", 3802)
    assert_true("version byte is 2" in message)
    assert_true("expected 1" in message)


def test_jsonb_rejects_empty() raises:
    assert_equal(_error_kind[String]("", 3802), PgErrorKind.TYPE_MISMATCH)


# --- bytea (OID 17) ----------------------------------------------------------


def test_bytea_three_bytes() raises:
    var expected = List[UInt8]()
    expected.append(0)
    expected.append(255)
    expected.append(0)
    _assert_bytes(_ok[List[UInt8]]("00ff00", 17), expected)


def test_bytea_empty() raises:
    _assert_bytes(_ok[List[UInt8]]("", 17), List[UInt8]())


# --- wrong cell width --------------------------------------------------------


def test_bool_rejects_wrong_length() raises:
    # One byte short of `bool` is zero bytes, so there are only two cases.
    _assert_length_rejected[Bool]("", 16, 1)
    _assert_length_rejected[Bool]("0101", 16, 1)


def test_int16_rejects_wrong_length() raises:
    _assert_length_rejected[Int16]("00", 21, 2)
    _assert_length_rejected[Int16]("000000", 21, 2)
    _assert_length_rejected[Int16]("", 21, 2)


def test_int32_rejects_wrong_length() raises:
    _assert_length_rejected[Int32]("000000", 23, 4)
    _assert_length_rejected[Int32]("0000000000", 23, 4)
    _assert_length_rejected[Int32]("", 23, 4)


def test_int64_rejects_wrong_length() raises:
    _assert_length_rejected[Int64]("00000000000000", 20, 8)
    _assert_length_rejected[Int64]("000000000000000000", 20, 8)
    _assert_length_rejected[Int64]("", 20, 8)


def test_float32_rejects_wrong_length() raises:
    _assert_length_rejected[Float32]("000000", 700, 4)
    _assert_length_rejected[Float32]("0000000000", 700, 4)
    _assert_length_rejected[Float32]("", 700, 4)


def test_float64_rejects_wrong_length() raises:
    _assert_length_rejected[Float64]("00000000000000", 701, 8)
    _assert_length_rejected[Float64]("000000000000000000", 701, 8)
    _assert_length_rejected[Float64]("", 701, 8)


# --- wrong OID ---------------------------------------------------------------


def test_int32_rejects_int8_column() raises:
    _assert_oid_rejected[Int32]("0000000000000001", 20)


def test_string_rejects_int4_column() raises:
    _assert_oid_rejected[String]("00000001", 23)


def test_string_rejects_point_column() raises:
    _assert_oid_rejected[String]("00000001", 600)


def test_string_rejects_int4_array_column() raises:
    _assert_oid_rejected[String]("00000001", 1007)


def test_bytea_rejects_text_column() raises:
    _assert_oid_rejected[List[UInt8]]("0068", 25)


def test_bytea_rejects_point_column() raises:
    _assert_oid_rejected[List[UInt8]]("0068", 600)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
