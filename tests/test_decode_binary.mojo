"""Tests for `pq.decode_binary`: strict binary decoding, no database needed.

Every expected value is the wire form PostgreSQL 17 and 14 were observed to
send, written here as a hex string and turned into bytes by `_hex`.
"""

from std.math import isinf, isnan
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pq.decode_binary import decode_binary
from pq.decode_text import parse_bytea_hex
from pq.errors import PgErrorKind
from pq.types_datetime import Date, Timestamp, TimestampTz
from pq.types_numeric import Decimal
from pq.types_uuid import UUID


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


# --- numeric ------------------------------------------------------------------


def _assert_numeric(digits: String, expected: String) raises:
    """Assert a `numeric` cell decodes to the text PostgreSQL prints for it.

    Args:
        digits: The cell's binary-format bytes, as hex digits.
        expected: The `numeric_out` text of the same value.

    Raises:
        Error: If decoding failed or printed something else.
    """
    var value = _ok[Decimal](digits, 1700)
    assert_equal(String(value), expected, String("numeric ", digits))


def _assert_numeric_rejected(digits: String) raises:
    """Assert a malformed `numeric` cell is a `TYPE_MISMATCH` naming the type.

    Args:
        digits: A cell that is not a well-formed `numeric`, as hex digits.

    Raises:
        Error: If the call succeeded or reported the wrong kind or message.
    """
    assert_equal(_error_kind[Decimal](digits, 1700), PgErrorKind.TYPE_MISMATCH)
    var message = _error_message[Decimal](digits, 1700)
    assert_true(
        "cannot decode binary numeric" in message,
        String("numeric ", digits, ": ", message),
    )


def test_numeric_table_decodes_to_printed_text() raises:
    # Every row is the wire form PostgreSQL 17 and 14 send for the value in
    # the second column, taken from `encode(numeric_send(v), 'hex')`.
    _assert_numeric("000200000000000200011388", "1.50")
    _assert_numeric("0001ffff40000003000a", "-0.001")
    _assert_numeric("0000000000000000", "0")
    _assert_numeric("0000000000000002", "0.00")
    _assert_numeric("0001fffe000000060064", "0.000001")
    _assert_numeric("0001fffd0000000a0064", "0.0000000001")
    _assert_numeric("00010001000000000064", "1000000")
    _assert_numeric("00010001000000000001", "10000")
    _assert_numeric("0001000000000000270f", "9999")
    _assert_numeric("000300010000000104d2162e2328", "12345678.9")
    _assert_numeric(
        "000b000700000009000c0d801ed204d2162e23340d801ed204d2162e2328",
        "123456789012345678901234567890.123456789",
    )
    _assert_numeric("0002000000000004000c0d48", "12.3400")
    _assert_numeric("0001ffff000000040001", "0.0001")
    _assert_numeric("0001ffff000000011388", "0.5")
    _assert_numeric("0001ffff400000011388", "-0.5")
    _assert_numeric("00010000000000000001", "1")
    _assert_numeric("00000000c0000000", "NaN")
    _assert_numeric("00000000d0000020", "Infinity")
    _assert_numeric("00000000f0000020", "-Infinity")
    # `numeric(10,4)` and `numeric(10,0)`: the typmod shows up as dscale.
    _assert_numeric("000200000000000400011388", "1.5000")
    _assert_numeric("00010000000000000064", "100")


def test_numeric_infinity_drops_the_header_dscale() raises:
    # PostgreSQL sends +Infinity with a dscale of 32, an artefact of its
    # header packing; only the sign is meaningful.
    var value = _ok[Decimal]("00000000d0000020", 1700)
    assert_true(value.is_infinite())
    assert_false(value.is_nan())
    assert_equal(String(value), "Infinity")
    assert_equal(value.dscale(), 0)


def test_numeric_dscale_pads_and_truncates_the_fraction() raises:
    # The stored digits and dscale need not agree: the fraction is printed to
    # exactly dscale places, zero-padded or cut as needed.
    _assert_numeric("0001ffff000000050001", "0.00010")
    _assert_numeric("0001fffe0000000503e8", "0.00001")


def test_numeric_large_weight_stays_in_position_notation() raises:
    var want = String("1")
    for _ in range(130):
        want += "0"
    var value = _ok[Decimal]("00010020000000000064", 1700)
    var printed = String(value)
    assert_equal(printed.byte_length(), 131)
    assert_equal(printed, want)


def test_numeric_minimum_weight_decodes() raises:
    # weight 0x8000 is Int16.MIN; taking `-weight` anywhere would overflow.
    _assert_numeric("00018000000000000001", "0")


def test_numeric_rejects_short_header() raises:
    _assert_numeric_rejected("00000000000000")


def test_numeric_rejects_length_disagreeing_with_ndigits() raises:
    # ndigits 2 needs 12 bytes; this cell is 10.
    _assert_numeric_rejected("00020000000000020001")


def test_numeric_rejects_invalid_sign() raises:
    _assert_numeric_rejected("0000000012340000")


def test_numeric_rejects_digit_out_of_range() raises:
    # 0x2710 is 10000, one past the last base-10000 digit.
    _assert_numeric_rejected("00010000000000002710")


def test_numeric_rejects_dscale_out_of_range() raises:
    # 0x4000 is 16384, one past the 14 bit dscale field.
    _assert_numeric_rejected("0000000000004000")


def test_numeric_rejects_int4_column() raises:
    _assert_oid_rejected[Decimal]("00000001", 23)


# --- uuid ---------------------------------------------------------------------


def test_uuid_decodes_sixteen_bytes() raises:
    var value = _ok[UUID]("a0eebc999c0b4ef8bb6d6bb9bd380a11", 2950)
    assert_equal(String(value), "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")


def test_uuid_rejects_wrong_length() raises:
    _assert_length_rejected[UUID]("a0eebc999c0b4ef8bb6d6bb9bd380a", 2950, 16)
    _assert_length_rejected[UUID](
        "a0eebc999c0b4ef8bb6d6bb9bd380a1122", 2950, 16
    )
    _assert_length_rejected[UUID]("", 2950, 16)


def test_uuid_rejects_text_column() raises:
    _assert_oid_rejected[UUID]("a0eebc999c0b4ef8bb6d6bb9bd380a11", 25)


# --- date / timestamp / timestamptz -------------------------------------------


def _assert_date(digits: String, expected: Int) raises:
    """Assert a `date` cell decodes to the day count the server sent.

    Args:
        digits: The cell's binary-format bytes, as hex digits.
        expected: The day count from 2000-01-01.

    Raises:
        Error: If decoding failed or produced another day count.
    """
    var value = _ok[Date](digits, 1082)
    assert_equal(Int(value.days), expected, String("date ", digits))


def _assert_timestamp(digits: String, expected: String) raises:
    """Assert a `timestamp` cell decodes to the text PostgreSQL prints.

    Args:
        digits: The cell's binary-format bytes, as hex digits.
        expected: The `timestamp_out` text of the same value.

    Raises:
        Error: If decoding failed or printed something else.
    """
    var value = _ok[Timestamp](digits, 1114)
    assert_equal(String(value), expected, String("timestamp ", digits))


def test_date_decodes_the_measured_day_counts() raises:
    _assert_date("00000000", 0)
    _assert_date("ffffd533", -10957)
    _assert_date("00002279", 8825)
    _assert_date("fff4da8b", -730485)
    _assert_date("ffda97a7", -2451545)
    _assert_date("7fda970c", 2145031948)
    _assert_date("002c95d4", 2921940)


def test_date_sentinels_decode_as_infinite() raises:
    var pos = _ok[Date]("7fffffff", 1082)
    assert_true(pos.is_infinite())
    assert_false(pos.is_finite())
    assert_equal(String(pos), "infinity")
    var neg = _ok[Date]("80000000", 1082)
    assert_true(neg.is_infinite())
    assert_equal(String(neg), "-infinity")


def test_date_rejects_wrong_length() raises:
    _assert_length_rejected[Date]("000022", 1082, 4)
    _assert_length_rejected[Date]("0000227900", 1082, 4)
    _assert_length_rejected[Date]("", 1082, 4)


def test_date_rejects_timestamp_column() raises:
    _assert_oid_rejected[Date]("00002279", 1114)


def test_timestamp_decodes_the_measured_values() raises:
    _assert_timestamp("0000000000000000", "2000-01-01 00:00:00")
    _assert_timestamp("0002b0ec85204f35", "2024-01-02 03:04:05.678901")
    _assert_timestamp("fffca2fec4c81fff", "1969-12-31 23:59:59.999999")
    _assert_timestamp("ff1fc63d1bb12000", "0001-01-01 00:00:00 BC")
    _assert_timestamp("fd0f7fbdaf17e000", "4713-01-01 00:00:00 BC")
    _assert_timestamp("7fffff5bb3b29fff", "294276-12-31 23:59:59.999999")


def test_timestamp_sentinels_decode_as_infinite() raises:
    var neg = _ok[Timestamp]("8000000000000000", 1114)
    assert_true(neg.is_infinite())
    assert_equal(String(neg), "-infinity")
    var pos = _ok[Timestamp]("7fffffffffffffff", 1114)
    assert_true(pos.is_infinite())
    assert_equal(String(pos), "infinity")


def test_timestamp_rejects_wrong_length() raises:
    _assert_length_rejected[Timestamp]("0002b0ec85204f", 1114, 8)
    _assert_length_rejected[Timestamp]("0002b0ec85204f3501", 1114, 8)
    _assert_length_rejected[Timestamp]("", 1114, 8)


def test_timestamp_rejects_timestamptz_column() raises:
    _assert_oid_rejected[Timestamp]("0002b0ec85204f35", 1184)


def test_timestamptz_decodes_as_utc() raises:
    var value = _ok[TimestampTz]("0002b0ec85204f35", 1184)
    assert_equal(value.micros, Int64(0x0002B0EC85204F35))
    assert_equal(String(value), "2024-01-02 03:04:05.678901+00")


def test_timestamptz_rejects_wrong_length_and_oid() raises:
    _assert_length_rejected[TimestampTz]("0002b0ec85204f", 1184, 8)
    _assert_length_rejected[TimestampTz]("0002b0ec85204f3501", 1184, 8)
    _assert_oid_rejected[TimestampTz]("0002b0ec85204f35", 1114)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
