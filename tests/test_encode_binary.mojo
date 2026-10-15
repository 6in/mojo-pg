"""Tests for `pq.encode_binary`: fixed widths and network byte order."""

from pq.encode_binary import (
    encode_bool,
    encode_float32,
    encode_float64,
    encode_int16,
    encode_int32,
    encode_int64,
)
from std.testing import TestSuite, assert_equal


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
