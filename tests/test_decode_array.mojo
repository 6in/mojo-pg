"""Tests for array decoding in `pq.decode_text`, no database needed.

Every expected value is a literal PostgreSQL 17 and 14 were observed to
send for the matching `SELECT` (`DateStyle = ISO, YMD`,
`IntervalStyle = postgres`), so the parser is checked against the server's
real output rather than against the documented grammar alone. The
malformed literals the tokenizer must reject are inputs the server never
produces -- it always prints the normal form -- but a caller can hand them
to `decode_text` directly, and they are the ones a hand-written parser
loops or crashes on.
"""

from std.math import isinf, isnan
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pq.decode_text import (
    OID_BOOL,
    OID_BOOL_ARRAY,
    OID_BPCHAR,
    OID_BPCHAR_ARRAY,
    OID_BYTEA,
    OID_BYTEA_ARRAY,
    OID_DATE,
    OID_DATE_ARRAY,
    OID_FLOAT4,
    OID_FLOAT4_ARRAY,
    OID_FLOAT8,
    OID_FLOAT8_ARRAY,
    OID_INT2,
    OID_INT2_ARRAY,
    OID_INT4,
    OID_INT4_ARRAY,
    OID_INT8,
    OID_INT8_ARRAY,
    OID_INTERVAL,
    OID_INTERVAL_ARRAY,
    OID_JSON,
    OID_JSON_ARRAY,
    OID_JSONB,
    OID_JSONB_ARRAY,
    OID_NAME,
    OID_NAME_ARRAY,
    OID_NUMERIC,
    OID_NUMERIC_ARRAY,
    OID_TEXT,
    OID_TEXT_ARRAY,
    OID_TIME,
    OID_TIME_ARRAY,
    OID_TIMESTAMP,
    OID_TIMESTAMP_ARRAY,
    OID_TIMESTAMPTZ,
    OID_TIMESTAMPTZ_ARRAY,
    OID_TIMETZ,
    OID_TIMETZ_ARRAY,
    OID_UUID,
    OID_UUID_ARRAY,
    OID_VARCHAR,
    OID_VARCHAR_ARRAY,
    _array_elem_oid,
    _array_oid_of,
    decode_text,
    parse_array_literal,
    parse_bytea_hex,
)
from pq.decode_binary import decode_binary
from pq.errors import PgErrorKind
from pq.types_datetime import (
    Date,
    Interval,
    Time,
    TimeTz,
    Timestamp,
    TimestampTz,
)
from pq.types_numeric import Decimal
from pq.types_uuid import UUID

# `array_send` payloads, byte for byte as PostgreSQL 17 sent them for
# the matching `SELECT` (RESEARCH 2.3), plus the malformed headers the
# server's own `array_recv` rejects.
comptime _P_INT4_123 = "0000000100000000000000170000000300000001000000040000000100000004000000020000000400000003"
comptime _P_INT4_EMPTY = "000000000000000000000017"
comptime _P_INT4_NULL_FLAGS1 = "00000001000000010000001700000003000000010000000400000001ffffffff0000000400000003"
comptime _P_INT4_NULL_FLAGS0 = "00000001000000000000001700000003000000010000000400000001ffffffff0000000400000003"
comptime _P_INT4_FLAGS2 = (
    "00000001000000020000001700000003000000010000000400000001"
)
comptime _P_INT4_WRONG_ELEMTYPE = (
    "00000001000000000000001900000001000000010000000400000001"
)
comptime _P_SHORT_HEADER = "0000000000000000000000"
comptime _P_DIM_BEYOND_DATA = (
    "000000010000000000000017000000030000000100000004000000010000000400000002"
)
comptime _P_ELEM_TOO_LONG = (
    "0000000100000000000000170000000100000001000000050000000100"
)
comptime _P_TRAILING_BYTE = "000000010000000000000017000000030000000100000004000000010000000400000002000000040000000300"
comptime _P_NDIM2 = "000000020000000000000017000000020000000100000002000000010000000400000001000000040000000200000004000000030000000400000004"
comptime _P_LBOUND_ZERO = (
    "000000010000000000000017000000020000000000000004000000070000000400000008"
)
comptime _P_TEXT9 = "0000000100000000000000190000000900000001000000016100000003622c630000000364226500000003665c6700000000000000044e554c4c000000046e756c6c00000003207820000000037b797d"
comptime _P_TEXT_NULL_MULTIBYTE = "0000000100000001000000190000000300000001000000097461625c746865726500000002c3a9ffffffff"
comptime _P_NUMERIC = (
    "0000000100000000000006a400000001000000010000000c000200000000000100011388"
)
comptime _P_BPCHAR = (
    "0000000100000000000004120000000100000001000000056162202020"
)
comptime _P_JSONB = (
    "000000010000000000000eda000000010000000100000009017b2261223a20317d"
)
comptime _P_INTERVAL = "0000000100000000000004a200000001000000010000001000000000000000000000000100000000"
comptime _P_BOOL = (
    "000000010000000000000010000000020000000100000001010000000100"
)
comptime _P_BYTEA = (
    "00000001000000000000001100000002000000010000000200ff00000000"
)
comptime _P_INT2_12 = (
    "0000000100000000000000150000000200000001000000020001000000020002"
)
comptime _P_INT8 = (
    "0000000100000000000000140000000100000001000000087fffffffffffffff"
)
comptime _P_FLOAT4 = "0000000100000000000002bc0000000100000001000000043fc00000"
comptime _P_FLOAT8 = (
    "0000000100000000000002bd0000000100000001000000083fb999999999999a"
)
comptime _P_DATE = "00000001000000000000043a00000001000000010000000400002279"
comptime _P_TS = (
    "00000001000000000000045a0000000100000001000000080002b0ec85204f35"
)
comptime _P_TSTZ = (
    "0000000100000000000004a00000000100000001000000080002b0ec85204f35"
)
comptime _P_TIME = (
    "00000001000000000000043b0000000100000001000000080000000a8bda1c00"
)
comptime _P_TIMETZ = (
    "0000000100000000000004f200000001000000010000000c0000000a8bda1c00ffff8170"
)
comptime _P_UUID = "000000010000000000000b86000000010000000100000010a0eebc999c0b4ef8bb6d6bb9bd380a11"
comptime _P_INT2_ELEM = "0000000100000000000000150000000100000001000000020001"


def _ok[T: Copyable & Deinitable](text: String, oid: UInt32) raises -> T:
    """Decode `text` as `T`, turning a `PgError` into a plain `Error`.

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


def _literal(text: String) raises -> List[Optional[String]]:
    """Split `text`, turning a `PgError` into a plain `Error`.

    Args:
        text: A text-format array value.

    Returns:
        One entry per element; `None` for a SQL NULL element.

    Raises:
        Error: If `parse_array_literal` raised a `PgError`.
    """
    try:
        return parse_array_literal(text)
    except e:
        raise Error(String(e))


def _literal_kind(text: String) raises -> PgErrorKind:
    """Return the kind of the `PgError` raised by `parse_array_literal`.

    Args:
        text: A literal `parse_array_literal` must reject.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If `parse_array_literal` returned a list instead of raising.
    """
    try:
        _ = parse_array_literal(text)
    except e:
        return e.kind
    raise Error(String("expected PgError for ", text))


def _assert_strings(got: List[String], expected: List[String]) raises:
    """Assert that two string lists have the same length and elements.

    Args:
        got: The decoded elements.
        expected: The expected elements.

    Raises:
        Error: If the lists differ.
    """
    assert_equal(len(got), len(expected))
    for i in range(len(expected)):
        assert_equal(got[i], expected[i])


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


# --- the OID table (pg_type.typarray), both directions ----------------------


def test_array_oid_constants_are_the_observed_typarray_values() raises:
    # Literal numbers on purpose: the two mapping tests below compare the
    # constants against each other and so would agree with a mistyped
    # value. These are `SELECT typarray FROM pg_type` on PG17 and PG14.
    assert_equal(OID_BOOL_ARRAY, UInt32(1000))
    assert_equal(OID_BYTEA_ARRAY, UInt32(1001))
    assert_equal(OID_NAME_ARRAY, UInt32(1003))
    assert_equal(OID_INT8_ARRAY, UInt32(1016))
    assert_equal(OID_INT2_ARRAY, UInt32(1005))
    assert_equal(OID_INT4_ARRAY, UInt32(1007))
    assert_equal(OID_TEXT_ARRAY, UInt32(1009))
    assert_equal(OID_JSON_ARRAY, UInt32(199))
    assert_equal(OID_FLOAT4_ARRAY, UInt32(1021))
    assert_equal(OID_FLOAT8_ARRAY, UInt32(1022))
    assert_equal(OID_BPCHAR_ARRAY, UInt32(1014))
    assert_equal(OID_VARCHAR_ARRAY, UInt32(1015))
    assert_equal(OID_DATE_ARRAY, UInt32(1182))
    assert_equal(OID_TIME_ARRAY, UInt32(1183))
    assert_equal(OID_TIMESTAMP_ARRAY, UInt32(1115))
    assert_equal(OID_TIMESTAMPTZ_ARRAY, UInt32(1185))
    assert_equal(OID_INTERVAL_ARRAY, UInt32(1187))
    assert_equal(OID_TIMETZ_ARRAY, UInt32(1270))
    assert_equal(OID_NUMERIC_ARRAY, UInt32(1231))
    assert_equal(OID_UUID_ARRAY, UInt32(2951))
    assert_equal(OID_JSONB_ARRAY, UInt32(3807))


def test_array_elem_oid_maps_all_21_arrays() raises:
    assert_equal(_array_elem_oid(OID_BOOL_ARRAY), OID_BOOL)
    assert_equal(_array_elem_oid(OID_BYTEA_ARRAY), OID_BYTEA)
    assert_equal(_array_elem_oid(OID_NAME_ARRAY), OID_NAME)
    assert_equal(_array_elem_oid(OID_INT8_ARRAY), OID_INT8)
    assert_equal(_array_elem_oid(OID_INT2_ARRAY), OID_INT2)
    assert_equal(_array_elem_oid(OID_INT4_ARRAY), OID_INT4)
    assert_equal(_array_elem_oid(OID_TEXT_ARRAY), OID_TEXT)
    assert_equal(_array_elem_oid(OID_JSON_ARRAY), OID_JSON)
    assert_equal(_array_elem_oid(OID_FLOAT4_ARRAY), OID_FLOAT4)
    assert_equal(_array_elem_oid(OID_FLOAT8_ARRAY), OID_FLOAT8)
    assert_equal(_array_elem_oid(OID_BPCHAR_ARRAY), OID_BPCHAR)
    assert_equal(_array_elem_oid(OID_VARCHAR_ARRAY), OID_VARCHAR)
    assert_equal(_array_elem_oid(OID_DATE_ARRAY), OID_DATE)
    assert_equal(_array_elem_oid(OID_TIME_ARRAY), OID_TIME)
    assert_equal(_array_elem_oid(OID_TIMESTAMP_ARRAY), OID_TIMESTAMP)
    assert_equal(_array_elem_oid(OID_TIMESTAMPTZ_ARRAY), OID_TIMESTAMPTZ)
    assert_equal(_array_elem_oid(OID_INTERVAL_ARRAY), OID_INTERVAL)
    assert_equal(_array_elem_oid(OID_TIMETZ_ARRAY), OID_TIMETZ)
    assert_equal(_array_elem_oid(OID_NUMERIC_ARRAY), OID_NUMERIC)
    assert_equal(_array_elem_oid(OID_UUID_ARRAY), OID_UUID)
    assert_equal(_array_elem_oid(OID_JSONB_ARRAY), OID_JSONB)


def test_array_oid_of_maps_all_21_elements() raises:
    assert_equal(_array_oid_of(OID_BOOL), OID_BOOL_ARRAY)
    assert_equal(_array_oid_of(OID_BYTEA), OID_BYTEA_ARRAY)
    assert_equal(_array_oid_of(OID_NAME), OID_NAME_ARRAY)
    assert_equal(_array_oid_of(OID_INT8), OID_INT8_ARRAY)
    assert_equal(_array_oid_of(OID_INT2), OID_INT2_ARRAY)
    assert_equal(_array_oid_of(OID_INT4), OID_INT4_ARRAY)
    assert_equal(_array_oid_of(OID_TEXT), OID_TEXT_ARRAY)
    assert_equal(_array_oid_of(OID_JSON), OID_JSON_ARRAY)
    assert_equal(_array_oid_of(OID_FLOAT4), OID_FLOAT4_ARRAY)
    assert_equal(_array_oid_of(OID_FLOAT8), OID_FLOAT8_ARRAY)
    assert_equal(_array_oid_of(OID_BPCHAR), OID_BPCHAR_ARRAY)
    assert_equal(_array_oid_of(OID_VARCHAR), OID_VARCHAR_ARRAY)
    assert_equal(_array_oid_of(OID_DATE), OID_DATE_ARRAY)
    assert_equal(_array_oid_of(OID_TIME), OID_TIME_ARRAY)
    assert_equal(_array_oid_of(OID_TIMESTAMP), OID_TIMESTAMP_ARRAY)
    assert_equal(_array_oid_of(OID_TIMESTAMPTZ), OID_TIMESTAMPTZ_ARRAY)
    assert_equal(_array_oid_of(OID_INTERVAL), OID_INTERVAL_ARRAY)
    assert_equal(_array_oid_of(OID_TIMETZ), OID_TIMETZ_ARRAY)
    assert_equal(_array_oid_of(OID_NUMERIC), OID_NUMERIC_ARRAY)
    assert_equal(_array_oid_of(OID_UUID), OID_UUID_ARRAY)
    assert_equal(_array_oid_of(OID_JSONB), OID_JSONB_ARRAY)


def test_array_oid_table_rejects_unknown_both_ways() raises:
    assert_equal(_array_elem_oid(OID_INT4), UInt32(0))
    assert_equal(_array_elem_oid(UInt32(0)), UInt32(0))
    assert_equal(_array_elem_oid(UInt32(600)), UInt32(0))
    assert_equal(_array_oid_of(OID_INT4_ARRAY), UInt32(0))
    assert_equal(_array_oid_of(UInt32(0)), UInt32(0))
    assert_equal(_array_oid_of(UInt32(600)), UInt32(0))


# --- text[]: quoting and escaping (RESEARCH 2.2) ----------------------------


def test_text_array_nine_elements_unescaped() raises:
    var literal = String(
        '{a,"b,c","d\\"e","f\\\\g","","NULL","null"," x ","{y}"}'
    )
    var expected: List[String] = [
        "a",
        "b,c",
        'd"e',
        "f\\g",
        "",
        "NULL",
        "null",
        " x ",
        "{y}",
    ]
    _assert_strings(_ok[List[String]](literal, OID_TEXT_ARRAY), expected)


def test_text_array_null_element_is_none_when_optional() raises:
    var got = _ok[List[Optional[String]]]("{a,NULL,b}", OID_TEXT_ARRAY)
    assert_equal(len(got), 3)
    assert_equal(got[0].value(), "a")
    assert_false(Bool(got[1]))
    assert_equal(got[2].value(), "b")


def test_text_array_null_element_rejected_when_not_optional() raises:
    assert_true(
        _error_kind[List[String]]("{a,NULL,b}", OID_TEXT_ARRAY)
        == PgErrorKind.NULL_VALUE
    )
    assert_true(
        "array element 1 is NULL"
        in _error_message[List[String]]("{a,NULL,b}", OID_TEXT_ARRAY)
    )


def test_text_array_lowercase_null_word_is_also_null() raises:
    var got = _ok[List[Optional[String]]]("{null,Null}", OID_TEXT_ARRAY)
    assert_equal(len(got), 2)
    assert_false(Bool(got[0]))
    assert_false(Bool(got[1]))


def test_text_array_accepts_all_six_text_oids() raises:
    var oids: List[UInt32] = [
        OID_TEXT_ARRAY,
        OID_VARCHAR_ARRAY,
        OID_BPCHAR_ARRAY,
        OID_NAME_ARRAY,
        OID_JSON_ARRAY,
        OID_JSONB_ARRAY,
    ]
    var expected: List[String] = ["a", "b"]
    for i in range(len(oids)):
        _assert_strings(_ok[List[String]]("{a,b}", oids[i]), expected)


def test_text_array_rejects_int4_array_oid_for_strings() raises:
    assert_true(
        _error_kind[List[String]]("{a,b}", OID_INT4_ARRAY)
        == PgErrorKind.TYPE_MISMATCH
    )


def test_text_array_bpchar_keeps_padding() raises:
    var expected: List[String] = ["ab   ", "cde"]
    _assert_strings(
        _ok[List[String]]('{"ab   ",cde}', OID_BPCHAR_ARRAY), expected
    )


def test_text_array_bytea_elements_decode_to_bytes() raises:
    var got = _ok[List[List[UInt8]]]('{"\\\\x00ff","\\\\x"}', OID_BYTEA_ARRAY)
    var first: List[UInt8] = [0, 255]
    var second = List[UInt8]()
    assert_equal(len(got), 2)
    _assert_bytes(got[0], first)
    _assert_bytes(got[1], second)


def test_text_array_bytea_optional_elements() raises:
    var got = _ok[List[Optional[List[UInt8]]]](
        '{"\\\\x00ff",NULL}', OID_BYTEA_ARRAY
    )
    var first: List[UInt8] = [0, 255]
    assert_equal(len(got), 2)
    _assert_bytes(got[0].value(), first)
    assert_false(Bool(got[1]))


# --- element types whose text form has specials -----------------------------


def test_text_array_numeric_specials() raises:
    var got = _ok[List[Decimal]](
        "{NaN,Infinity,-Infinity,1.50}", OID_NUMERIC_ARRAY
    )
    assert_equal(len(got), 4)
    assert_equal(String(got[0]), "NaN")
    assert_equal(String(got[1]), "Infinity")
    assert_equal(String(got[2]), "-Infinity")
    assert_equal(String(got[3]), "1.50")


def test_text_array_float8_specials() raises:
    var got = _ok[List[Float64]](
        "{NaN,Infinity,-Infinity,0,1e+300}", OID_FLOAT8_ARRAY
    )
    assert_equal(len(got), 5)
    assert_true(isnan(got[0]))
    assert_true(isinf(got[1]) and got[1] > 0)
    assert_true(isinf(got[2]) and got[2] < 0)
    assert_equal(got[3], Float64(0))
    assert_equal(got[4], Float64(1e300))


def test_text_array_timestamp_infinities() raises:
    var got = _ok[List[Timestamp]](
        '{"2024-01-02 03:04:05",infinity,-infinity}', OID_TIMESTAMP_ARRAY
    )
    assert_equal(len(got), 3)
    assert_equal(String(got[0]), "2024-01-02 03:04:05")
    assert_equal(String(got[1]), "infinity")
    assert_equal(String(got[2]), "-infinity")


def test_text_array_bool() raises:
    var got = _ok[List[Bool]]("{t,f}", OID_BOOL_ARRAY)
    assert_equal(len(got), 2)
    assert_true(got[0])
    assert_false(got[1])


def test_text_array_date_with_bc_era() raises:
    var got = _ok[List[Date]]('{2024-02-29,"0001-01-01 BC"}', OID_DATE_ARRAY)
    assert_equal(len(got), 2)
    assert_equal(String(got[0]), "2024-02-29")
    assert_equal(String(got[1]), "0001-01-01 BC")


def test_text_array_int8_as_int_and_int64() raises:
    var as_int = _ok[List[Int]]("{1,9223372036854775807}", OID_INT8_ARRAY)
    var as_int64 = _ok[List[Int64]]("{1,9223372036854775807}", OID_INT8_ARRAY)
    assert_equal(len(as_int), 2)
    assert_equal(as_int[1], Int.MAX)
    assert_equal(len(as_int64), 2)
    assert_equal(as_int64[1], Int64.MAX)


def test_text_array_remaining_element_types() raises:
    assert_equal(
        _ok[List[Int16]]("{1,-32768}", OID_INT2_ARRAY)[1], Int16(-32768)
    )
    assert_true(isnan(_ok[List[Float32]]("{1.5,NaN}", OID_FLOAT4_ARRAY)[1]))
    assert_equal(
        String(
            _ok[List[TimestampTz]](
                '{"2024-01-01 18:04:05+00"}', OID_TIMESTAMPTZ_ARRAY
            )[0]
        ),
        "2024-01-01 18:04:05+00",
    )
    assert_equal(
        String(_ok[List[Time]]("{24:00:00}", OID_TIME_ARRAY)[0]), "24:00:00"
    )
    assert_equal(
        String(_ok[List[TimeTz]]("{12:34:56+09}", OID_TIMETZ_ARRAY)[0]),
        "12:34:56+09",
    )
    assert_equal(
        String(
            _ok[List[Interval]](
                '{"1 year 2 mons 3 days 04:05:06"}', OID_INTERVAL_ARRAY
            )[0]
        ),
        "1 year 2 mons 3 days 04:05:06",
    )
    assert_equal(
        String(
            _ok[List[UUID]](
                "{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11}", OID_UUID_ARRAY
            )[0]
        ),
        "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
    )


def test_text_array_optional_branch_of_every_element_type() raises:
    assert_true(
        _ok[List[Optional[Bool]]]("{t,NULL}", OID_BOOL_ARRAY)[0].value()
    )
    assert_equal(len(_ok[List[Optional[Int16]]]("{1,NULL}", OID_INT2_ARRAY)), 2)
    assert_equal(len(_ok[List[Optional[Int32]]]("{1,NULL}", OID_INT4_ARRAY)), 2)
    assert_equal(len(_ok[List[Optional[Int64]]]("{1,NULL}", OID_INT8_ARRAY)), 2)
    assert_equal(len(_ok[List[Optional[Int]]]("{1,NULL}", OID_INT8_ARRAY)), 2)
    assert_equal(
        len(_ok[List[Optional[Float32]]]("{1.5,NULL}", OID_FLOAT4_ARRAY)), 2
    )
    assert_equal(
        len(_ok[List[Optional[Float64]]]("{1.5,NULL}", OID_FLOAT8_ARRAY)), 2
    )
    assert_equal(
        len(_ok[List[Optional[Decimal]]]("{1.50,NULL}", OID_NUMERIC_ARRAY)), 2
    )
    assert_equal(
        len(
            _ok[List[Optional[UUID]]](
                "{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11,NULL}", OID_UUID_ARRAY
            )
        ),
        2,
    )
    assert_equal(
        len(_ok[List[Optional[Date]]]("{2024-02-29,NULL}", OID_DATE_ARRAY)), 2
    )
    assert_equal(
        len(
            _ok[List[Optional[Timestamp]]](
                '{"2024-01-02 03:04:05",NULL}', OID_TIMESTAMP_ARRAY
            )
        ),
        2,
    )
    assert_equal(
        len(
            _ok[List[Optional[TimestampTz]]](
                '{"2024-01-01 18:04:05+00",NULL}', OID_TIMESTAMPTZ_ARRAY
            )
        ),
        2,
    )
    assert_equal(
        len(_ok[List[Optional[Time]]]("{24:00:00,NULL}", OID_TIME_ARRAY)), 2
    )
    assert_equal(
        len(
            _ok[List[Optional[TimeTz]]]("{12:34:56+09,NULL}", OID_TIMETZ_ARRAY)
        ),
        2,
    )
    assert_equal(
        len(
            _ok[List[Optional[Interval]]](
                '{"-1 days",NULL}', OID_INTERVAL_ARRAY
            )
        ),
        2,
    )


# --- shape: empty, dimensions, multidimensional -----------------------------


def test_text_array_empty_is_empty_list() raises:
    assert_equal(len(_ok[List[Int32]]("{}", OID_INT4_ARRAY)), 0)
    assert_equal(len(_ok[List[Optional[Int32]]]("{}", OID_INT4_ARRAY)), 0)
    assert_equal(len(_ok[List[String]]("{}", OID_TEXT_ARRAY)), 0)


def test_text_array_dimension_prefix_is_dropped() raises:
    var got = _ok[List[Int32]]("[0:1]={7,8}", OID_INT4_ARRAY)
    assert_equal(len(got), 2)
    assert_equal(got[0], Int32(7))
    assert_equal(got[1], Int32(8))


def test_text_array_rejects_multidimensional() raises:
    assert_true(
        _error_kind[List[Int32]]("{{1,2},{3,4}}", OID_INT4_ARRAY)
        == PgErrorKind.TYPE_MISMATCH
    )
    assert_true(
        "multidimensional"
        in _error_message[List[Int32]]("{{1,2},{3,4}}", OID_INT4_ARRAY)
    )


def test_text_array_rejects_empty_nested_literal() raises:
    # The server prints `{}` even for `'{{}}'::int4[]`, so a nested brace
    # here is the multidimensional case and not an empty array.
    assert_true(
        _error_kind[List[Int32]]("{{}}", OID_INT4_ARRAY)
        == PgErrorKind.TYPE_MISMATCH
    )
    assert_true(
        "multidimensional"
        in _error_message[List[Int32]]("{{}}", OID_INT4_ARRAY)
    )


def test_text_array_allows_whitespace_around_elements() raises:
    var got = _ok[List[Int32]]("{ 1 , 2 }", OID_INT4_ARRAY)
    assert_equal(len(got), 2)
    assert_equal(got[0], Int32(1))
    assert_equal(got[1], Int32(2))


# --- OID and element mismatches ---------------------------------------------


def test_text_array_rejects_int2_array_for_int32() raises:
    var message = _error_message[List[Int32]]("{1,2}", OID_INT2_ARRAY)
    assert_true(
        _error_kind[List[Int32]]("{1,2}", OID_INT2_ARRAY)
        == PgErrorKind.TYPE_MISMATCH
    )
    assert_true("1005" in message)
    assert_true("1007" in message)
    assert_true("int4[]" in message)


def test_text_array_element_error_names_its_index() raises:
    var message = _error_message[List[Int32]]("{1,a,3}", OID_INT4_ARRAY)
    assert_true(
        _error_kind[List[Int32]]("{1,a,3}", OID_INT4_ARRAY)
        == PgErrorKind.TYPE_MISMATCH
    )
    assert_true("array element 1" in message)
    assert_true("int4" in message)


def test_text_array_column_read_as_string_is_the_literal() raises:
    assert_equal(
        _ok[String]("{1,NULL,3}", OID_INT4_ARRAY), String("{1,NULL,3}")
    )
    assert_equal(
        _ok[String]("[0:1]={7,8}", OID_INT4_ARRAY), String("[0:1]={7,8}")
    )


# --- malformed literals (P7): every one raises, none loops ------------------


def test_malformed_unclosed_brace() raises:
    assert_true(_literal_kind("{1,2") == PgErrorKind.TYPE_MISMATCH)
    assert_true(
        _error_kind[List[Int32]]("{1,2", OID_INT4_ARRAY)
        == PgErrorKind.TYPE_MISMATCH
    )


def test_malformed_unterminated_quote() raises:
    assert_true(_literal_kind('{"abc}') == PgErrorKind.TYPE_MISMATCH)


def test_malformed_empty_element() raises:
    assert_true(_literal_kind("{1,,2}") == PgErrorKind.TYPE_MISMATCH)


def test_malformed_junk_after_closing_brace() raises:
    assert_true(_literal_kind("{1,2}}") == PgErrorKind.TYPE_MISMATCH)


def test_malformed_without_braces() raises:
    assert_true(_literal_kind("1,2") == PgErrorKind.TYPE_MISMATCH)


def test_malformed_empty_text() raises:
    assert_true(_literal_kind("") == PgErrorKind.TYPE_MISMATCH)


def test_malformed_open_brace_only() raises:
    assert_true(_literal_kind("{") == PgErrorKind.TYPE_MISMATCH)


def test_malformed_close_brace_only() raises:
    assert_true(_literal_kind("}") == PgErrorKind.TYPE_MISMATCH)


def test_malformed_quote_at_end_of_input() raises:
    assert_true(_literal_kind('{"a') == PgErrorKind.TYPE_MISMATCH)


def test_malformed_dimension_prefix_without_equals() raises:
    assert_true(_literal_kind("[0:1{7,8}") == PgErrorKind.TYPE_MISMATCH)


def test_parse_array_literal_returns_element_texts() raises:
    var got = _literal('{ 1 ,"a b", NULL }')
    assert_equal(len(got), 3)
    assert_equal(got[0].value(), "1")
    assert_equal(got[1].value(), "a b")
    assert_false(Bool(got[2]))


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


def _bin_ok[T: Copyable & Deinitable](digits: String, oid: UInt32) raises -> T:
    """Decode `digits` as `T`, turning a `PgError` into a plain `Error`.

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


def _bin_error_kind[
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


def _bin_error_message[
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


def test_binary_array_int4_decodes_the_measured_payload() raises:
    var got = _bin_ok[List[Int32]](_P_INT4_123, OID_INT4_ARRAY)
    assert_equal(len(got), 3)
    assert_equal(got[0], Int32(1))
    assert_equal(got[1], Int32(2))
    assert_equal(got[2], Int32(3))


def test_binary_array_empty_is_the_twelve_byte_header() raises:
    # `'{}'::int4[]` stops after `ndim 0`; there are no dimension words to
    # read, and reading them anyway would walk past the cell.
    assert_equal(len(_bin_ok[List[Int32]](_P_INT4_EMPTY, OID_INT4_ARRAY)), 0)
    assert_equal(
        len(_bin_ok[List[Optional[Int32]]](_P_INT4_EMPTY, OID_INT4_ARRAY)), 0
    )


def test_binary_array_null_element_with_flags_one() raises:
    var got = _bin_ok[List[Optional[Int32]]](
        _P_INT4_NULL_FLAGS1, OID_INT4_ARRAY
    )
    assert_equal(len(got), 3)
    assert_equal(got[0].value(), Int32(1))
    assert_false(Bool(got[1]))
    assert_equal(got[2].value(), Int32(3))


def test_binary_array_null_element_with_flags_zero() raises:
    # The server accepts a `-1` element alongside `flags 0`, so NULL is
    # decided by the element length alone.
    var got = _bin_ok[List[Optional[Int32]]](
        _P_INT4_NULL_FLAGS0, OID_INT4_ARRAY
    )
    assert_equal(len(got), 3)
    assert_false(Bool(got[1]))
    assert_equal(
        _bin_error_kind[List[Int32]](_P_INT4_NULL_FLAGS0, OID_INT4_ARRAY),
        PgErrorKind.NULL_VALUE,
    )


def test_binary_array_null_element_rejected_for_non_optional() raises:
    assert_equal(
        _bin_error_kind[List[Int32]](_P_INT4_NULL_FLAGS1, OID_INT4_ARRAY),
        PgErrorKind.NULL_VALUE,
    )
    var message = _bin_error_message[List[Int32]](
        _P_INT4_NULL_FLAGS1, OID_INT4_ARRAY
    )
    assert_true("array element 1" in message, String("message was: ", message))


def test_binary_array_rejects_invalid_flags() raises:
    assert_equal(
        _bin_error_kind[List[Int32]](_P_INT4_FLAGS2, OID_INT4_ARRAY),
        PgErrorKind.TYPE_MISMATCH,
    )


def test_binary_array_rejects_a_foreign_element_type() raises:
    var message = _bin_error_message[List[Int32]](
        _P_INT4_WRONG_ELEMTYPE, OID_INT4_ARRAY
    )
    assert_true("oid 25" in message, String("message was: ", message))
    assert_true("oid 23" in message, String("message was: ", message))


def test_binary_array_rejects_a_header_shorter_than_twelve_bytes() raises:
    assert_equal(
        _bin_error_kind[List[Int32]](_P_SHORT_HEADER, OID_INT4_ARRAY),
        PgErrorKind.TYPE_MISMATCH,
    )


def test_binary_array_rejects_a_dimension_the_cell_cannot_fill() raises:
    assert_equal(
        _bin_error_kind[List[Int32]](_P_DIM_BEYOND_DATA, OID_INT4_ARRAY),
        PgErrorKind.TYPE_MISMATCH,
    )


def test_binary_array_rejects_an_element_of_the_wrong_width() raises:
    # An `int4` element with a five byte length: the element decoder is the
    # one that rejects it, so the message carries the element's index.
    var message = _bin_error_message[List[Int32]](
        _P_ELEM_TOO_LONG, OID_INT4_ARRAY
    )
    assert_true("array element 0" in message, String("message was: ", message))
    assert_equal(
        _bin_error_kind[List[Int32]](_P_ELEM_TOO_LONG, OID_INT4_ARRAY),
        PgErrorKind.TYPE_MISMATCH,
    )


def test_binary_array_rejects_bytes_after_the_last_element() raises:
    assert_equal(
        _bin_error_kind[List[Int32]](_P_TRAILING_BYTE, OID_INT4_ARRAY),
        PgErrorKind.TYPE_MISMATCH,
    )


def test_binary_array_rejects_multidimensional() raises:
    assert_equal(
        _bin_error_kind[List[Int32]](_P_NDIM2, OID_INT4_ARRAY),
        PgErrorKind.TYPE_MISMATCH,
    )


def test_binary_array_lower_bound_is_dropped() raises:
    var got = _bin_ok[List[Int32]](_P_LBOUND_ZERO, OID_INT4_ARRAY)
    assert_equal(len(got), 2)
    assert_equal(got[0], Int32(7))
    assert_equal(got[1], Int32(8))


def test_binary_array_text_elements_keep_their_bytes() raises:
    var got = _bin_ok[List[String]](_P_TEXT9, OID_TEXT_ARRAY)
    assert_equal(len(got), 9)
    assert_equal(got[0], "a")
    assert_equal(got[1], "b,c")
    assert_equal(got[2], 'd"e')
    assert_equal(got[3], "f\\g")
    assert_equal(got[4], "")
    assert_equal(got[5], "NULL")
    assert_equal(got[6], "null")
    assert_equal(got[7], " x ")
    assert_equal(got[8], "{y}")


def test_binary_array_text_with_null_and_multibyte() raises:
    var got = _bin_ok[List[Optional[String]]](
        _P_TEXT_NULL_MULTIBYTE, OID_TEXT_ARRAY
    )
    assert_equal(len(got), 3)
    assert_equal(got[0].value(), "tab\\there")
    assert_equal(got[1].value(), "é")
    assert_false(Bool(got[2]))


def test_binary_array_string_accepts_the_six_array_oids() raises:
    assert_equal(_bin_ok[List[String]](_P_BPCHAR, OID_BPCHAR_ARRAY)[0], "ab   ")
    assert_equal(
        _bin_ok[List[String]](_P_JSONB, OID_JSONB_ARRAY)[0], '{"a": 1}'
    )
    assert_equal(
        _bin_error_kind[List[String]](_P_TEXT9, OID_INT4_ARRAY),
        PgErrorKind.TYPE_MISMATCH,
    )


def test_binary_array_numeric_element() raises:
    assert_equal(
        String(_bin_ok[List[Decimal]](_P_NUMERIC, OID_NUMERIC_ARRAY)[0]), "1.5"
    )


def test_binary_array_interval_element() raises:
    assert_equal(
        String(_bin_ok[List[Interval]](_P_INTERVAL, OID_INTERVAL_ARRAY)[0]),
        "1 day",
    )


def test_binary_array_bool_and_bytea_elements() raises:
    var flags = _bin_ok[List[Bool]](_P_BOOL, OID_BOOL_ARRAY)
    assert_true(flags[0])
    assert_false(flags[1])
    var blobs = _bin_ok[List[List[UInt8]]](_P_BYTEA, OID_BYTEA_ARRAY)
    assert_equal(len(blobs[0]), 2)
    assert_equal(blobs[0][0], UInt8(0))
    assert_equal(blobs[0][1], UInt8(255))
    assert_equal(len(blobs[1]), 0)


def test_binary_array_remaining_element_types() raises:
    assert_equal(_bin_ok[List[Int16]](_P_INT2_12, OID_INT2_ARRAY)[1], Int16(2))
    assert_equal(_bin_ok[List[Int64]](_P_INT8, OID_INT8_ARRAY)[0], Int64.MAX)
    assert_equal(_bin_ok[List[Int]](_P_INT8, OID_INT8_ARRAY)[0], Int(Int64.MAX))
    assert_equal(
        _bin_ok[List[Float32]](_P_FLOAT4, OID_FLOAT4_ARRAY)[0], Float32(1.5)
    )
    assert_equal(
        _bin_ok[List[Float64]](_P_FLOAT8, OID_FLOAT8_ARRAY)[0], Float64(0.1)
    )
    assert_equal(
        Int(_bin_ok[List[Date]](_P_DATE, OID_DATE_ARRAY)[0].days), 8825
    )
    assert_equal(
        String(_bin_ok[List[Timestamp]](_P_TS, OID_TIMESTAMP_ARRAY)[0]),
        "2024-01-02 03:04:05.678901",
    )
    assert_equal(
        String(_bin_ok[List[TimestampTz]](_P_TSTZ, OID_TIMESTAMPTZ_ARRAY)[0]),
        "2024-01-02 03:04:05.678901+00",
    )
    assert_equal(
        String(_bin_ok[List[Time]](_P_TIME, OID_TIME_ARRAY)[0]), "12:34:56"
    )
    assert_equal(
        _bin_ok[List[TimeTz]](_P_TIMETZ, OID_TIMETZ_ARRAY)[0].offset_secs,
        Int32(-32400),
    )
    assert_equal(
        String(_bin_ok[List[UUID]](_P_UUID, OID_UUID_ARRAY)[0]),
        "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
    )


def test_binary_array_optional_branch_of_every_element_type() raises:
    assert_true(
        _bin_ok[List[Optional[Bool]]](_P_BOOL, OID_BOOL_ARRAY)[0].value()
    )
    assert_equal(
        _bin_ok[List[Optional[Int16]]](_P_INT2_12, OID_INT2_ARRAY)[0].value(),
        Int16(1),
    )
    assert_equal(
        _bin_ok[List[Optional[Int64]]](_P_INT8, OID_INT8_ARRAY)[0].value(),
        Int64.MAX,
    )
    assert_equal(
        _bin_ok[List[Optional[Int]]](_P_INT8, OID_INT8_ARRAY)[0].value(),
        Int(Int64.MAX),
    )
    assert_equal(
        _bin_ok[List[Optional[Float32]]](_P_FLOAT4, OID_FLOAT4_ARRAY)[
            0
        ].value(),
        Float32(1.5),
    )
    assert_equal(
        _bin_ok[List[Optional[Float64]]](_P_FLOAT8, OID_FLOAT8_ARRAY)[
            0
        ].value(),
        Float64(0.1),
    )
    assert_equal(
        len(
            _bin_ok[List[Optional[List[UInt8]]]](_P_BYTEA, OID_BYTEA_ARRAY)[
                0
            ].value()
        ),
        2,
    )
    assert_equal(
        String(
            _bin_ok[List[Optional[Decimal]]](_P_NUMERIC, OID_NUMERIC_ARRAY)[
                0
            ].value()
        ),
        "1.5",
    )
    assert_equal(
        Int(
            _bin_ok[List[Optional[Date]]](_P_DATE, OID_DATE_ARRAY)[0]
            .value()
            .days
        ),
        8825,
    )
    assert_equal(
        String(
            _bin_ok[List[Optional[Timestamp]]](_P_TS, OID_TIMESTAMP_ARRAY)[
                0
            ].value()
        ),
        "2024-01-02 03:04:05.678901",
    )
    assert_equal(
        String(
            _bin_ok[List[Optional[TimestampTz]]](
                _P_TSTZ, OID_TIMESTAMPTZ_ARRAY
            )[0].value()
        ),
        "2024-01-02 03:04:05.678901+00",
    )
    assert_equal(
        String(
            _bin_ok[List[Optional[Time]]](_P_TIME, OID_TIME_ARRAY)[0].value()
        ),
        "12:34:56",
    )
    assert_equal(
        _bin_ok[List[Optional[TimeTz]]](_P_TIMETZ, OID_TIMETZ_ARRAY)[0]
        .value()
        .offset_secs,
        Int32(-32400),
    )
    assert_equal(
        String(
            _bin_ok[List[Optional[Interval]]](_P_INTERVAL, OID_INTERVAL_ARRAY)[
                0
            ].value()
        ),
        "1 day",
    )
    assert_equal(
        String(
            _bin_ok[List[Optional[UUID]]](_P_UUID, OID_UUID_ARRAY)[0].value()
        ),
        "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
    )


def test_binary_array_rejects_the_int2_array_oid_for_int32() raises:
    # The payload is a well-formed `int2[]`; only the requested type is
    # wrong, and the OID check catches it before the element type does.
    assert_equal(
        _bin_error_kind[List[Int32]](_P_INT2_ELEM, OID_INT2_ARRAY),
        PgErrorKind.TYPE_MISMATCH,
    )
    var message = _bin_error_message[List[Int32]](_P_INT2_ELEM, OID_INT2_ARRAY)
    assert_true("oid 1005" in message, String("message was: ", message))
    assert_true("oid 1007" in message, String("message was: ", message))


def test_binary_array_column_read_as_string_is_still_rejected() raises:
    # Unlike the text path, binary `String` is not a wildcard: an array
    # column has no printed form to fall back on.
    assert_equal(
        _bin_error_kind[String](_P_INT4_123, OID_INT4_ARRAY),
        PgErrorKind.TYPE_MISMATCH,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
