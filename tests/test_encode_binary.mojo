"""Tests for `pq.encode_binary`: fixed widths and network byte order."""

from pq.decode_binary import (
    decode_date,
    decode_numeric,
    decode_timestamp,
    decode_timestamptz,
)
from pq.decode_text import parse_bytea_hex
from pq.encode_binary import (
    encode_bool,
    encode_date,
    encode_float32,
    encode_float64,
    encode_int16,
    encode_int32,
    encode_int64,
    encode_numeric,
    encode_timestamp,
    encode_timestamptz,
    encode_uuid,
)
from pq.types_datetime import Date, Timestamp, TimestampTz
from pq.types_numeric import Decimal
from pq.types_uuid import UUID
from std.testing import TestSuite, assert_equal, assert_true


def _assert_bytes(
    actual: List[UInt8], expected: List[UInt8], what: StaticString
) raises:
    """Assert `actual` equals `expected` byte for byte.

    Args:
        actual: The encoder output under test.
        expected: The bytes the encoder must produce.
        what: Label naming the case, used in failure messages.

    Raises:
        Error: When the lengths differ or any byte differs.
    """
    assert_equal(len(actual), len(expected), String(what, ": length"))
    for i in range(len(expected)):
        assert_equal(
            Int(actual[i]),
            Int(expected[i]),
            String(what, ": byte ", i),
        )


def test_bool_is_one_byte() raises:
    var t: List[UInt8] = [1]
    var f: List[UInt8] = [0]
    _assert_bytes(encode_bool(True), t, "bool True")
    _assert_bytes(encode_bool(False), f, "bool False")


def test_int16_endpoints() raises:
    var lo: List[UInt8] = [0x80, 0x00]
    var hi: List[UInt8] = [0x7F, 0xFF]
    _assert_bytes(encode_int16(-32768), lo, "int16 min")
    _assert_bytes(encode_int16(32767), hi, "int16 max")


def test_int32_negative_one_is_all_ones() raises:
    var expected: List[UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
    _assert_bytes(encode_int32(-1), expected, "int32 -1")


def test_int32_max() raises:
    var expected: List[UInt8] = [0x7F, 0xFF, 0xFF, 0xFF]
    _assert_bytes(encode_int32(2147483647), expected, "int32 max")


def test_int64_min() raises:
    var expected: List[UInt8] = [0x80, 0, 0, 0, 0, 0, 0, 0]
    _assert_bytes(encode_int64(Int64.MIN), expected, "int64 min")


def test_int64_negative_one_is_all_ones() raises:
    var expected: List[UInt8] = [
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
    ]
    _assert_bytes(encode_int64(-1), expected, "int64 -1")


def test_int64_small_positive_is_big_endian() raises:
    var expected: List[UInt8] = [0, 0, 0, 0, 0, 0, 0, 0x2A]
    _assert_bytes(encode_int64(42), expected, "int64 42")


def test_float32_finite() raises:
    var expected: List[UInt8] = [0x3F, 0xC0, 0, 0]
    _assert_bytes(encode_float32(1.5), expected, "float32 1.5")


def test_float32_nan() raises:
    var nan = Float32(0.0) / Float32(0.0)
    var expected: List[UInt8] = [0x7F, 0xC0, 0, 0]
    _assert_bytes(encode_float32(nan), expected, "float32 NaN")


def test_float32_infinities() raises:
    var pos = Float32(1.0) / Float32(0.0)
    var pos_expected: List[UInt8] = [0x7F, 0x80, 0, 0]
    var neg_expected: List[UInt8] = [0xFF, 0x80, 0, 0]
    _assert_bytes(encode_float32(pos), pos_expected, "float32 +inf")
    _assert_bytes(encode_float32(-pos), neg_expected, "float32 -inf")


def test_float64_negative_zero() raises:
    var expected: List[UInt8] = [0x80, 0, 0, 0, 0, 0, 0, 0]
    _assert_bytes(encode_float64(-Float64(0.0)), expected, "float64 -0.0")


def test_float64_nan() raises:
    var nan = Float64(0.0) / Float64(0.0)
    var expected: List[UInt8] = [0x7F, 0xF8, 0, 0, 0, 0, 0, 0]
    _assert_bytes(encode_float64(nan), expected, "float64 NaN")


def test_float64_finite() raises:
    var expected: List[UInt8] = [0x3F, 0xF8, 0, 0, 0, 0, 0, 0]
    _assert_bytes(encode_float64(1.5), expected, "float64 1.5")


def test_encoded_widths_are_fixed() raises:
    assert_equal(len(encode_bool(True)), 1)
    assert_equal(len(encode_int16(0)), 2)
    assert_equal(len(encode_int32(0)), 4)
    assert_equal(len(encode_int64(0)), 8)
    assert_equal(len(encode_float32(0.0)), 4)
    assert_equal(len(encode_float64(0.0)), 8)
    assert_equal(len(encode_uuid(_uuid())), 16)
    assert_equal(len(encode_date(Date(0))), 4)
    assert_equal(len(encode_timestamp(Timestamp(0))), 8)
    assert_equal(len(encode_timestamptz(TimestampTz(0))), 8)


def _hex(digits: String) raises -> List[UInt8]:
    """Turn a hex string into the bytes it spells.

    Reuses `parse_bytea_hex` by prefixing the `\\x` marker it expects.

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


def _uuid() raises -> UUID:
    """Return the sample UUID used by the encoder tests.

    Returns:
        The value spelled `a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11`.

    Raises:
        Error: Never; the literal is well-formed.
    """
    try:
        return UUID(String("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"))
    except e:
        raise Error(String(e))


def _decimal(text: String) raises -> Decimal:
    """Build a `Decimal` from `text`, turning a `PgError` into an `Error`.

    Args:
        text: A numeric literal `Decimal` accepts.

    Returns:
        The parsed value.

    Raises:
        Error: If `text` is not a valid numeric literal.
    """
    try:
        return Decimal(text)
    except e:
        raise Error(String(e))


def _assert_numeric_wire(text: String, digits: String) raises:
    """Assert `Decimal(text)` encodes to the bytes PostgreSQL sends for it.

    Args:
        text: A numeric literal.
        digits: The `numeric_send` output for the same value, as hex.

    Raises:
        Error: If the encoder produced different bytes.
    """
    _assert_bytes(encode_numeric(_decimal(text)), _hex(digits), "numeric")


def _assert_numeric_round_trip(text: String) raises:
    """Assert encoding then decoding `Decimal(text)` returns the same value.

    Args:
        text: A numeric literal.

    Raises:
        Error: If the round trip changed the value or its printed form.
    """
    var value = _decimal(text)
    var bytes = encode_numeric(value)
    var back: Decimal
    try:
        back = decode_numeric(Span[UInt8](bytes))
    except e:
        raise Error(String(e))
    assert_true(back == value, String("numeric round trip ", text))
    assert_equal(String(back), String(value), String("numeric text ", text))


def test_numeric_wire_matches_the_server() raises:
    _assert_numeric_wire("1.50", "000200000000000200011388")
    _assert_numeric_wire("-0.001", "0001ffff40000003000a")
    _assert_numeric_wire("0.00", "0000000000000002")
    _assert_numeric_wire("0", "0000000000000000")
    _assert_numeric_wire("12345678.9", "000300010000000104d2162e2328")
    _assert_numeric_wire(
        "123456789012345678901234567890.123456789",
        "000b000700000009000c0d801ed204d2162e23340d801ed204d2162e2328",
    )


def test_numeric_specials_encode_without_a_dscale() raises:
    _assert_bytes(
        encode_numeric(Decimal.nan()), _hex("00000000c0000000"), "numeric NaN"
    )
    _assert_bytes(
        encode_numeric(Decimal.infinity()),
        _hex("00000000d0000000"),
        "numeric Infinity",
    )
    _assert_bytes(
        encode_numeric(Decimal.negative_infinity()),
        _hex("00000000f0000000"),
        "numeric -Infinity",
    )


def test_numeric_round_trips_every_table_row() raises:
    _assert_numeric_round_trip("1.50")
    _assert_numeric_round_trip("-0.001")
    _assert_numeric_round_trip("0")
    _assert_numeric_round_trip("0.00")
    _assert_numeric_round_trip("0.000001")
    _assert_numeric_round_trip("0.0000000001")
    _assert_numeric_round_trip("1000000")
    _assert_numeric_round_trip("10000")
    _assert_numeric_round_trip("9999")
    _assert_numeric_round_trip("12345678.9")
    _assert_numeric_round_trip("123456789012345678901234567890.123456789")
    _assert_numeric_round_trip("12.3400")
    _assert_numeric_round_trip("0.0001")
    _assert_numeric_round_trip("0.5")
    _assert_numeric_round_trip("-0.5")
    _assert_numeric_round_trip("1")
    _assert_numeric_round_trip("1.5000")
    _assert_numeric_round_trip("100")
    _assert_numeric_round_trip("NaN")
    _assert_numeric_round_trip("Infinity")
    _assert_numeric_round_trip("-Infinity")


def test_uuid_wire_matches_the_server() raises:
    _assert_bytes(
        encode_uuid(_uuid()),
        _hex("a0eebc999c0b4ef8bb6d6bb9bd380a11"),
        "uuid",
    )


def test_date_wire_matches_the_server() raises:
    _assert_bytes(encode_date(Date(8825)), _hex("00002279"), "date 8825")
    _assert_bytes(encode_date(Date(-10957)), _hex("ffffd533"), "date -10957")
    _assert_bytes(encode_date(Date(0)), _hex("00000000"), "date 0")


def test_timestamp_wire_matches_the_server() raises:
    _assert_bytes(
        encode_timestamp(Timestamp(0x0002B0EC85204F35)),
        _hex("0002b0ec85204f35"),
        "timestamp 2024-01-02 03:04:05.678901",
    )
    _assert_bytes(
        encode_timestamp(Timestamp(-946684800000001)),
        _hex("fffca2fec4c81fff"),
        "timestamp 1969-12-31 23:59:59.999999",
    )
    _assert_bytes(
        encode_timestamptz(TimestampTz(0x0002B0EC85204F35)),
        _hex("0002b0ec85204f35"),
        "timestamptz 2024-01-02 03:04:05.678901+00",
    )


def test_datetime_sentinels_encode_to_the_wire_sentinels() raises:
    _assert_bytes(encode_date(Date.infinity()), _hex("7fffffff"), "date inf")
    _assert_bytes(
        encode_date(Date.negative_infinity()), _hex("80000000"), "date -inf"
    )
    _assert_bytes(
        encode_timestamp(Timestamp.infinity()),
        _hex("7fffffffffffffff"),
        "timestamp inf",
    )
    _assert_bytes(
        encode_timestamp(Timestamp.negative_infinity()),
        _hex("8000000000000000"),
        "timestamp -inf",
    )
    _assert_bytes(
        encode_timestamptz(TimestampTz.negative_infinity()),
        _hex("8000000000000000"),
        "timestamptz -inf",
    )


def test_datetime_round_trips_through_the_decoders() raises:
    var days: List[Int32] = [0, 8825, -10957, -730485, -2451545, 2145031948]
    for i in range(len(days)):
        var value = Date(days[i])
        var back: Date
        try:
            back = decode_date(Span[UInt8](encode_date(value)))
        except e:
            raise Error(String(e))
        assert_true(back == value, String("date round trip ", days[i]))

    var micros: List[Int64] = [
        0,
        1,
        0x0002B0EC85204F35,
        -946684800000001,
        0x7FFFFF5BB3B29FFF,
    ]
    for i in range(len(micros)):
        var value = Timestamp(micros[i])
        var back: Timestamp
        var back_tz: TimestampTz
        try:
            back = decode_timestamp(Span[UInt8](encode_timestamp(value)))
            back_tz = decode_timestamptz(
                Span[UInt8](encode_timestamptz(TimestampTz(micros[i])))
            )
        except e:
            raise Error(String(e))
        assert_true(back == value, String("timestamp round trip ", micros[i]))
        assert_true(
            back_tz == TimestampTz(micros[i]),
            String("timestamptz round trip ", micros[i]),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
