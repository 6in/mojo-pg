"""Tests for array columns and array parameters against a live server.

`tests/test_decode_array.mojo` checks the two array decoders against hand-built
literals and hand-built `array_send` payloads. This file checks the same
decoders against what the server actually puts on the wire, in both formats, for
all seventeen element types -- and checks the send direction, which has no
offline test at all because a `Param` payload only means something once the
server has parsed it.

The property asserted everywhere is the one from `tests/test_binary.mojo`,
raised to arrays: a binary array result decodes to the *same* `List` the text
result of the same `SELECT` decodes to. Where a value has no format-independent
spelling -- `timestamptz` is printed in the server's own `TimeZone` -- the two
formats are compared against each other rather than against a literal, which
keeps the assertion true whatever the server's zone is.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI), falling back to the local container. An unreachable server
fails these tests; it never skips them.

Every expected literal below was observed identically on PG14 and PG17
(`DateStyle = ISO, YMD`, `IntervalStyle = postgres`, both pinned by
`Connection.open`), so nothing here branches on `server_version`.
"""

from std.math import isinf, isnan
from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pq.connection import Connection
from pq.errors import PgError, PgErrorKind
from pq.params import Param
from pq.result import Result, ResultFormat, Row
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

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime TEXT9_SQL: StaticString = (
    "SELECT ARRAY['a','b,c','d\"e','f\\g','','NULL','null',' x ','{y}']::text[]"
)
"""The nine text elements whose array literal needs every quoting rule.

Observed output (PG14 and PG17):
`{a,"b,c","d\\"e","f\\\\g","","NULL","null"," x ","{y}"}`. Three of them are
traps: the quoted `NULL` is the four-character string, not a SQL NULL; the
empty string is a value; and `{y}` is text that looks like a nested array.
"""

comptime FLOAT8_SQL: StaticString = (
    "SELECT ARRAY['NaN'::float8,'Infinity','-Infinity','-0',1e300]::float8[]"
)
"""The `float8` values whose two wire formats need care, in an array.

`'-0'` is written as a string literal rather than `(-0.0)`: the latter parses as
`numeric`, which has no signed zero, so the sign under test would be gone before
the array is built (same reason as in `tests/test_binary.mojo`).
"""

comptime FLOAT4_SQL: StaticString = (
    "SELECT ARRAY['NaN'::float4,'Infinity','-Infinity','-0']::float4[]"
)

comptime NUMERIC_SQL: StaticString = (
    "SELECT ARRAY['NaN'::numeric,'Infinity','-Infinity',"
    "123456789012345678901234567890.1234567890,0,-1.50]::numeric[]"
)
"""`numeric` specials plus a value wider than any fixed-width integer.

The infinities are PG14-and-later spellings; both test servers accept them, and
`numeric` carries no digits for either, which is what the binary decoder has to
notice.
"""

comptime INT2_SQL: StaticString = (
    "SELECT ARRAY[32767::int2,(-32768)::int2,0]::int2[]"
)

comptime INT4_SQL: StaticString = (
    "SELECT ARRAY[2147483647::int4,(-2147483648)::int4,0]::int4[]"
)

comptime INT8_SQL: StaticString = (
    "SELECT ARRAY[9223372036854775807::int8,(-9223372036854775808)::int8,0]"
    "::int8[]"
)
"""The extremes of `int8`, parenthesized so `::` does not bind to the sign."""

comptime DATE_SQL: StaticString = (
    "SELECT ARRAY['infinity'::date,'-infinity','2024-02-29','0001-01-01 BC']"
    "::date[]"
)

comptime TIMESTAMP_SQL: StaticString = (
    "SELECT ARRAY['infinity'::timestamp,'-infinity','2024-01-02 03:04:05']"
    "::timestamp[]"
)

comptime TIMESTAMPTZ_SQL: StaticString = (
    "SELECT ARRAY['2024-01-01 18:04:05+00'::timestamptz,'infinity',"
    "'-infinity']::timestamptz[]"
)

comptime INTERVAL_SQL: StaticString = (
    "SELECT ARRAY['1 year 2 mons 3 days 04:05:06'::interval,'-1 days']"
    "::interval[]"
)

comptime UUID_TEXT = "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"

comptime SIX_OIDS_SQL: StaticString = (
    "SELECT ARRAY['x'::text]::text[], ARRAY['x'::varchar]::varchar[],"
    " ARRAY['ab'::char(5)]::bpchar[], ARRAY['n'::name]::name[],"
    " ARRAY['{\"a\": 1}'::json]::json[], ARRAY['{\"a\": 1}'::jsonb]::jsonb[]"
)
"""One array per text-shaped element OID: text, varchar, bpchar, name, json,
jsonb.

All six decode to `List[String]`, the same rule the scalar `String` decoder
follows. The `jsonb` element is the interesting one in binary format: each
element payload starts with jsonb's version byte, which the element decoder has
to strip.
"""


# --- helpers -----------------------------------------------------------------
#
# A `TestSuite` test only declares `raises` (plain `Error`), and `PgError` does
# not implicitly convert to `Error`, so a `raises PgError` API cannot be called
# straight from a test. These wrappers translate, exactly as the ones in
# `tests/test_binary.mojo` do.
#
# The generic wrappers bind `T: Copyable & Deinitable`, not just `Copyable`:
# discarding a `get` result with `_ = ...` needs `Deinitable` to compile, and
# `List[Optional[E]]` needs it to be destroyed at all.


def _conninfo() -> String:
    """Return the conninfo of the server under test.

    Returns:
        `PQ_TEST_CONNINFO` when set and non-empty, else `DEFAULT_CONNINFO`.
    """
    var value = getenv("PQ_TEST_CONNINFO")
    return value if value != "" else String(DEFAULT_CONNINFO)


def _connect(var conninfo: String) raises -> Connection:
    """Open a connection from a conninfo string.

    Args:
        conninfo: A libpq `key=value ...` conninfo string.

    Returns:
        The open connection.

    Raises:
        Error: If `Connection.open` raised a `PgError`.
    """
    try:
        return Connection.open(conninfo^)
    except e:
        raise Error(String(e))


def _execute(conn: Connection, var sql: String) raises -> Result:
    """Run `sql` through the parameterless overload, so in text format.

    Args:
        conn: An open connection.
        sql: The statement to run.

    Returns:
        The result of the statement.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    try:
        return conn.execute(sql^)
    except e:
        raise Error(String(e))


def _execute_fmt(
    conn: Connection, var sql: String, fmt: ResultFormat
) raises -> Result:
    """Run `sql` with no parameters, asking for results in `fmt`.

    Args:
        conn: An open connection.
        sql: The single statement to run.
        fmt: The wire format the server should send columns in.

    Returns:
        The result of the statement.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    try:
        return conn.execute(sql^, List[Param](), result_format=fmt)
    except e:
        raise Error(String(e))


def _execute_params(
    conn: Connection,
    var sql: String,
    params: List[Param],
    fmt: ResultFormat = ResultFormat.TEXT,
) raises -> Result:
    """Run `sql` with bound parameters, asking for results in `fmt`.

    Args:
        conn: An open connection.
        sql: The single statement to run.
        params: The values bound to `$1`, `$2`, ... in order.
        fmt: The wire format the server should send columns in.

    Returns:
        The result of the statement.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    try:
        return conn.execute(sql^, params, result_format=fmt)
    except e:
        raise Error(String(e))


def _row(result: Result, i: Int) raises -> Row[origin_of(result)]:
    """Return row `i` of `result`.

    Args:
        result: The result to index.
        i: Zero-based row index.

    Returns:
        The row at that index.

    Raises:
        Error: If `result[i]` raised a `PgError`.
    """
    try:
        return result[i]
    except e:
        raise Error(String(e))


def _get[
    origin: ImmOrigin, //, T: Copyable & Deinitable
](row: Row[origin], col: Int) raises -> T:
    """Read column `col` of `row` as `T`.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.
        T: The Mojo type requested from `Row.get`.

    Args:
        row: The row to read.
        col: Zero-based column index.

    Returns:
        The decoded value.

    Raises:
        Error: If `Row.get` raised a `PgError`.
    """
    try:
        return row.get[T](col)
    except e:
        raise Error(String(e))


def _get_optional[
    origin: ImmOrigin, //, T: Copyable & Deinitable
](row: Row[origin], col: Int) raises -> Optional[T]:
    """Read column `col` of `row` as an optional `T`.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.
        T: The Mojo type requested from `Row.get_optional`.

    Args:
        row: The row to read.
        col: Zero-based column index.

    Returns:
        The decoded value, or `None` for a SQL NULL.

    Raises:
        Error: If `Row.get_optional` raised a `PgError`.
    """
    try:
        return row.get_optional[T](col)
    except e:
        raise Error(String(e))


def _get_error[
    origin: ImmOrigin, //, T: Copyable & Deinitable
](row: Row[origin], col: Int) raises -> PgError:
    """Return the `PgError` raised by `row.get[T](col)`.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.
        T: The Mojo type requested from `Row.get`.

    Args:
        row: The row to read.
        col: A column index that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `Row.get` returned a value instead of raising.
    """
    try:
        _ = row.get[T](col)
    except e:
        return e.copy()
    raise Error(String("expected a PgError from get(", col, ")"))


def _is_null[origin: ImmOrigin, //](row: Row[origin], col: Int) raises -> Bool:
    """Report whether column `col` of `row` is a SQL NULL.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.

    Args:
        row: The row to inspect.
        col: Zero-based column index.

    Returns:
        True if the column holds a SQL NULL.

    Raises:
        Error: If `Row.is_null` raised a `PgError`.
    """
    try:
        return row.is_null(col)
    except e:
        raise Error(String(e))


def _column_type_oid(result: Result, i: Int) raises -> UInt32:
    """Return the type OID of column `i`.

    Args:
        result: The result to inspect.
        i: Zero-based column index.

    Returns:
        The column's type OID.

    Raises:
        Error: If `column_type_oid` raised a `PgError`.
    """
    try:
        return result.column_type_oid(i)
    except e:
        raise Error(String(e))


def _column_oid_of(conn: Connection, var sql: String) raises -> UInt32:
    """Return the type OID the server reports for column 0 of `sql`.

    Args:
        conn: An open connection.
        sql: A statement with at least one column.

    Returns:
        The type OID of its first column.

    Raises:
        Error: If the statement or the accessor failed.
    """
    var result = _execute(conn, sql^)
    var oid = _column_type_oid(result, 0)
    _ = result^
    return oid


def _array_in[
    T: Copyable & Deinitable
](conn: Connection, var sql: String, fmt: ResultFormat) raises -> List[T]:
    """Read column 0 of the first row of `sql` as `List[T]`, in format `fmt`.

    Parameters:
        T: The element type requested from `Row.get`.

    Args:
        conn: An open connection.
        sql: A statement whose first column is an array.
        fmt: The wire format the server should send the column in.

    Returns:
        The decoded list.

    Raises:
        Error: If the statement or the decode failed.
    """
    var result = _execute_fmt(conn, sql^, fmt)
    var row = _row(result, 0)
    var value = _get[List[T]](row, 0)
    _ = row^
    _ = result^
    return value^


def _optional_array_in[
    T: Copyable & Deinitable
](conn: Connection, var sql: String, fmt: ResultFormat) raises -> List[
    Optional[T]
]:
    """Read column 0 of the first row of `sql` as `List[Optional[T]]`.

    Parameters:
        T: The element type requested from `Row.get`.

    Args:
        conn: An open connection.
        sql: A statement whose first column is an array.
        fmt: The wire format the server should send the column in.

    Returns:
        The decoded list, with `None` for every NULL element.

    Raises:
        Error: If the statement or the decode failed.
    """
    var result = _execute_fmt(conn, sql^, fmt)
    var row = _row(result, 0)
    var value = _get[List[Optional[T]]](row, 0)
    _ = row^
    _ = result^
    return value^


def _array_error[
    T: Copyable & Deinitable
](conn: Connection, var sql: String, fmt: ResultFormat) raises -> PgError:
    """Return the `PgError` raised by reading column 0 of `sql` as `List[T]`.

    Parameters:
        T: The element type requested from `Row.get`.

    Args:
        conn: An open connection.
        sql: A statement whose first column must be rejected.
        fmt: The wire format the server should send the column in.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the read succeeded, or the statement itself failed.
    """
    var result = _execute_fmt(conn, sql^, fmt)
    var row = _row(result, 0)
    var error = _get_error[List[T]](row, 0)
    _ = row^
    _ = result^
    return error^


def _assert_lists_equal[
    T: Copyable & Deinitable & Equatable & Writable
](got: List[T], expected: List[T]) raises:
    """Assert that two lists have the same length and equal elements.

    Parameters:
        T: The element type, compared with `==`.

    Args:
        got: The decoded list.
        expected: The expected list.

    Raises:
        Error: If the lists differ.
    """
    assert_equal(len(got), len(expected))
    for i in range(len(expected)):
        assert_equal(got[i], expected[i])


def _assert_writes_as[
    T: Copyable & Deinitable & Writable
](got: List[T], expected: List[String]) raises:
    """Assert that each element of `got` writes as the matching expected text.

    Used for the element types whose `==` is not the property under test --
    `Decimal`, the date/time types and `UUID` all round-trip through their text
    form, and a `NaN` is only comparable that way.

    Parameters:
        T: The element type, rendered with `String`.

    Args:
        got: The decoded list.
        expected: The expected rendering of each element.

    Raises:
        Error: If the lengths or any rendering differ.
    """
    assert_equal(len(got), len(expected))
    for i in range(len(expected)):
        assert_equal(String(got[i]), expected[i])


def _assert_writes_match[
    T: Copyable & Deinitable & Writable
](got: List[T], other: List[T]) raises:
    """Assert that two lists render element for element.

    Args:
        got: One decoded list.
        other: The other decoded list.

    Parameters:
        T: The element type, rendered with `String`.

    Raises:
        Error: If the lengths or any rendering differ.
    """
    assert_equal(len(got), len(other))
    for i in range(len(other)):
        assert_equal(String(got[i]), String(other[i]))


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


def _assert_array_in_both_formats[
    T: Copyable & Deinitable & Equatable & Writable
](
    conn: Connection, var sql: String, expected_oid: UInt32, expected: List[T]
) raises:
    """Assert `sql` has column OID `expected_oid` and decodes to `expected`.

    The decode is done twice, once per wire format, so a format that silently
    disagrees with the other cannot pass.

    Parameters:
        T: The element type requested from `Row.get`.

    Args:
        conn: An open connection.
        sql: A statement whose first column is an array.
        expected_oid: The array type OID the server must report.
        expected: The list both formats must decode to.

    Raises:
        Error: If the OID or either decode disagrees.
    """
    assert_equal(_column_oid_of(conn, sql.copy()), expected_oid)
    _assert_lists_equal(
        _array_in[T](conn, sql.copy(), ResultFormat.TEXT), expected
    )
    _assert_lists_equal(_array_in[T](conn, sql^, ResultFormat.BINARY), expected)


def _assert_array_writes_in_both_formats[
    T: Copyable & Deinitable & Writable
](
    conn: Connection,
    var sql: String,
    expected_oid: UInt32,
    expected: List[String],
) raises:
    """Assert `sql` decodes, in both formats, to elements rendering as
    `expected`.

    Parameters:
        T: The element type requested from `Row.get`.

    Args:
        conn: An open connection.
        sql: A statement whose first column is an array.
        expected_oid: The array type OID the server must report.
        expected: The expected rendering of each element.

    Raises:
        Error: If the OID or either decode disagrees.
    """
    assert_equal(_column_oid_of(conn, sql.copy()), expected_oid)
    _assert_writes_as(
        _array_in[T](conn, sql.copy(), ResultFormat.TEXT), expected
    )
    _assert_writes_as(_array_in[T](conn, sql^, ResultFormat.BINARY), expected)


# --- the seventeen element types, text against binary ------------------------


def test_array_bool_matches_text_and_binary() raises:
    var conn = _connect(_conninfo())
    var expected: List[Bool] = [True, False, True]
    _assert_array_in_both_formats[Bool](
        conn, "SELECT ARRAY[true,false,true]::bool[]", 1000, expected
    )
    _ = conn^


def test_array_integer_boundaries_match_text_and_binary() raises:
    var conn = _connect(_conninfo())

    var i16: List[Int16] = [32767, -32768, 0]
    _assert_array_in_both_formats[Int16](conn, String(INT2_SQL), 1005, i16)

    var i32: List[Int32] = [2147483647, -2147483648, 0]
    _assert_array_in_both_formats[Int32](conn, String(INT4_SQL), 1007, i32)

    var i64: List[Int64] = [
        Int64.MAX,
        Int64.MIN,
        0,
    ]
    _assert_array_in_both_formats[Int64](conn, String(INT8_SQL), 1016, i64)

    _ = conn^


def test_array_int8_reads_as_int_and_int64() raises:
    # `Int` and `Int64` share the 1016 branch, and both have to survive the
    # extremes: a 64-bit `int8` element is the widest value either can hold.
    var conn = _connect(_conninfo())

    var as_int: List[Int] = [Int.MAX, Int.MIN, 0]
    _assert_array_in_both_formats[Int](conn, String(INT8_SQL), 1016, as_int)

    var as_int64: List[Int64] = [Int64.MAX, Int64.MIN, 0]
    _assert_array_in_both_formats[Int64](conn, String(INT8_SQL), 1016, as_int64)

    _ = conn^


def test_array_float8_specials_match_text_and_binary() raises:
    var conn = _connect(_conninfo())
    var in_text = _array_in[Float64](
        conn, String(FLOAT8_SQL), ResultFormat.TEXT
    )
    var in_binary = _array_in[Float64](
        conn, String(FLOAT8_SQL), ResultFormat.BINARY
    )
    assert_equal(len(in_text), 5)
    assert_equal(len(in_binary), 5)

    # `NaN == NaN` is False, so agreement between the formats is checked with
    # `isnan` on both sides rather than by comparing the two values.
    assert_true(isnan(in_text[0]))
    assert_true(isnan(in_binary[0]))
    assert_true(isinf(in_text[1]) and in_text[1] > 0)
    assert_true(isinf(in_binary[1]) and in_binary[1] > 0)
    assert_true(isinf(in_text[2]) and in_text[2] < 0)
    assert_true(isinf(in_binary[2]) and in_binary[2] < 0)

    # A signed zero compares equal to a plain zero, so the sign is read back
    # through the reciprocal, which is -Infinity only for -0.
    assert_equal(in_text[3], Float64(0))
    assert_equal(in_binary[3], Float64(0))
    assert_true(Float64(1) / in_text[3] < 0)
    assert_true(Float64(1) / in_binary[3] < 0)

    assert_equal(in_text[4], Float64(1e300))
    assert_equal(in_binary[4], Float64(1e300))

    _ = conn^


def test_array_float4_specials_match_text_and_binary() raises:
    var conn = _connect(_conninfo())
    var in_text = _array_in[Float32](
        conn, String(FLOAT4_SQL), ResultFormat.TEXT
    )
    var in_binary = _array_in[Float32](
        conn, String(FLOAT4_SQL), ResultFormat.BINARY
    )
    assert_equal(len(in_text), 4)
    assert_equal(len(in_binary), 4)

    assert_true(isnan(in_text[0]))
    assert_true(isnan(in_binary[0]))
    assert_true(isinf(in_text[1]) and in_text[1] > 0)
    assert_true(isinf(in_binary[1]) and in_binary[1] > 0)
    assert_true(isinf(in_text[2]) and in_text[2] < 0)
    assert_true(isinf(in_binary[2]) and in_binary[2] < 0)
    assert_true(Float32(1) / in_text[3] < 0)
    assert_true(Float32(1) / in_binary[3] < 0)

    _ = conn^


def test_array_numeric_specials_match_text_and_binary() raises:
    var conn = _connect(_conninfo())

    # Thirty digits before the point and ten after: `numeric` is the only
    # element type whose binary payload is variable-length *and* whose text
    # form keeps its trailing zeroes (`-1.50`, not `-1.5`).
    var expected: List[String] = [
        "NaN",
        "Infinity",
        "-Infinity",
        "123456789012345678901234567890.1234567890",
        "0",
        "-1.50",
    ]
    _assert_array_writes_in_both_formats[Decimal](
        conn, String(NUMERIC_SQL), 1231, expected
    )

    _ = conn^


def test_array_text_nine_elements_match_text_and_binary() raises:
    var conn = _connect(_conninfo())

    # The quoting the text format needs here is invisible to the binary
    # format, which sends each element as a counted run of bytes. Both have
    # to produce the same nine strings.
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
    _assert_array_in_both_formats[String](
        conn, String(TEXT9_SQL), 1009, expected
    )

    _ = conn^


def test_array_six_text_oids_decode_as_string_list() raises:
    var conn = _connect(_conninfo())
    var in_text = _execute(conn, String(SIX_OIDS_SQL))
    var in_binary = _execute_fmt(
        conn, String(SIX_OIDS_SQL), ResultFormat.BINARY
    )

    var oids: List[UInt32] = [1009, 1015, 1014, 1003, 199, 3807]
    for i in range(6):
        assert_equal(_column_type_oid(in_text, i), oids[i])
        assert_equal(_column_type_oid(in_binary, i), oids[i])

    var t = _row(in_text, 0)
    var b = _row(in_binary, 0)

    # `char(5)` is blank-padded by the server in either format, and the
    # `jsonb` element arrives behind a version byte in binary only.
    var expected: List[String] = [
        "x",
        "x",
        "ab   ",
        "n",
        '{"a": 1}',
        '{"a": 1}',
    ]
    for i in range(6):
        var from_text = _get[List[String]](t, i)
        var from_binary = _get[List[String]](b, i)
        assert_equal(len(from_text), 1)
        assert_equal(len(from_binary), 1)
        assert_equal(from_text[0], expected[i])
        assert_equal(from_binary[0], expected[i])

    _ = b^
    _ = t^
    _ = in_binary^
    _ = in_text^
    _ = conn^


def test_array_bytea_matches_text_and_binary() raises:
    var conn = _connect(_conninfo())
    var sql = String("SELECT ARRAY['\\x00ff'::bytea,''::bytea]::bytea[]")
    assert_equal(_column_oid_of(conn, sql.copy()), UInt32(1001))

    var in_text = _array_in[List[UInt8]](conn, sql.copy(), ResultFormat.TEXT)
    var in_binary = _array_in[List[UInt8]](conn, sql^, ResultFormat.BINARY)

    # `List[UInt8]` is not `Equatable`, so the elements are compared byte by
    # byte. The empty element is a value, not a NULL, in either format.
    var first: List[UInt8] = [0, 255]
    var second = List[UInt8]()
    assert_equal(len(in_text), 2)
    assert_equal(len(in_binary), 2)
    _assert_bytes(in_text[0], first)
    _assert_bytes(in_binary[0], first)
    _assert_bytes(in_text[1], second)
    _assert_bytes(in_binary[1], second)

    _ = conn^


def test_array_uuid_matches_text_and_binary() raises:
    var conn = _connect(_conninfo())
    var expected: List[String] = [
        String(UUID_TEXT),
        "00000000-0000-0000-0000-000000000000",
    ]
    _assert_array_writes_in_both_formats[UUID](
        conn,
        String(
            "SELECT ARRAY['",
            UUID_TEXT,
            "'::uuid,'00000000-0000-0000-0000-000000000000']::uuid[]",
        ),
        2951,
        expected,
    )
    _ = conn^


def test_array_date_specials_match_text_and_binary() raises:
    var conn = _connect(_conninfo())

    # The two infinities are the extremes of the same `int32` a finite date
    # travels in, and the BC era is the one text spelling with a suffix.
    var expected: List[String] = [
        "infinity",
        "-infinity",
        "2024-02-29",
        "0001-01-01 BC",
    ]
    _assert_array_writes_in_both_formats[Date](
        conn, String(DATE_SQL), 1182, expected
    )

    _ = conn^


def test_array_time_and_timetz_match_text_and_binary() raises:
    var conn = _connect(_conninfo())

    # `24:00:00` is a valid `time` and the only value past the end of a day.
    var times: List[String] = ["24:00:00", "00:00:00"]
    _assert_array_writes_in_both_formats[Time](
        conn, "SELECT ARRAY['24:00:00'::time,'00:00:00']::time[]", 1183, times
    )

    var timetzs: List[String] = ["12:34:56+09", "00:00:00+00"]
    _assert_array_writes_in_both_formats[TimeTz](
        conn,
        "SELECT ARRAY['12:34:56+09'::timetz,'00:00:00+00']::timetz[]",
        1270,
        timetzs,
    )

    _ = conn^


def test_array_timestamp_specials_match_text_and_binary() raises:
    var conn = _connect(_conninfo())
    var expected: List[String] = [
        "infinity",
        "-infinity",
        "2024-01-02 03:04:05",
    ]
    _assert_array_writes_in_both_formats[Timestamp](
        conn, String(TIMESTAMP_SQL), 1115, expected
    )
    _ = conn^


def test_array_timestamptz_matches_text_in_the_servers_zone() raises:
    var conn = _connect(_conninfo())

    # A `timestamptz` is printed in the server's own `TimeZone`, which
    # `Connection.open` does not pin, so the finite element has no
    # format-independent spelling to assert. What *is* format-independent is
    # that both formats name the same instant, so the two decodes are
    # compared against each other; the infinities are spelled the same in
    # every zone and are asserted directly.
    assert_equal(_column_oid_of(conn, String(TIMESTAMPTZ_SQL)), UInt32(1185))
    var in_text = _array_in[TimestampTz](
        conn, String(TIMESTAMPTZ_SQL), ResultFormat.TEXT
    )
    var in_binary = _array_in[TimestampTz](
        conn, String(TIMESTAMPTZ_SQL), ResultFormat.BINARY
    )
    assert_equal(len(in_text), 3)
    _assert_writes_match(in_text, in_binary)
    assert_equal(String(in_text[1]), "infinity")
    assert_equal(String(in_text[2]), "-infinity")
    assert_equal(in_text[0], in_binary[0])

    _ = conn^


def test_array_interval_matches_text_and_binary() raises:
    var conn = _connect(_conninfo())

    # `IntervalStyle = postgres` is pinned by `Connection.open`; the negative
    # interval is the one that carries a sign in the day field alone.
    var expected: List[String] = ["1 year 2 mons 3 days 04:05:06", "-1 days"]
    _assert_array_writes_in_both_formats[Interval](
        conn, String(INTERVAL_SQL), 1187, expected
    )

    _ = conn^


# --- shape: empty, NULLs, dimensions -----------------------------------------


def test_array_empty_is_empty_list_in_both_formats() raises:
    var conn = _connect(_conninfo())
    var sql = String("SELECT '{}'::int4[]")

    # The empty array is the one payload whose binary header has no dimension
    # words at all, so it is the header the decoder must not over-read.
    assert_equal(len(_array_in[Int32](conn, sql.copy(), ResultFormat.TEXT)), 0)
    assert_equal(
        len(_array_in[Int32](conn, sql.copy(), ResultFormat.BINARY)), 0
    )
    assert_equal(
        len(_optional_array_in[Int32](conn, sql.copy(), ResultFormat.TEXT)), 0
    )
    assert_equal(
        len(_optional_array_in[Int32](conn, sql^, ResultFormat.BINARY)), 0
    )

    _ = conn^


def test_array_null_element_in_both_formats() raises:
    var conn = _connect(_conninfo())
    var sql = String("SELECT ARRAY[1,NULL,3]::int4[]")

    for i in range(2):
        var fmt = ResultFormat.TEXT if i == 0 else ResultFormat.BINARY

        var optional = _optional_array_in[Int32](conn, sql.copy(), fmt)
        assert_equal(len(optional), 3)
        assert_equal(optional[0].value(), Int32(1))
        assert_false(Bool(optional[1]))
        assert_equal(optional[2].value(), Int32(3))

        # The non-nullable element type refuses the same array rather than
        # substituting a zero.
        var error = _array_error[Int32](conn, sql.copy(), fmt)
        assert_true(error.kind == PgErrorKind.NULL_VALUE)
        assert_true("array element 1" in error.message)

    _ = conn^


def test_array_column_null_and_element_null_together() raises:
    var conn = _connect(_conninfo())

    # A NULL *column* and a NULL *element* are different things, and
    # `get_optional[List[Optional[Int32]]]` is the one call that distinguishes
    # them: the outer `Optional` is the column, the inner ones are elements.
    var null_column = _execute_fmt(
        conn, "SELECT NULL::int4[]", ResultFormat.BINARY
    )
    var nc_row = _row(null_column, 0)
    assert_false(Bool(_get_optional[List[Optional[Int32]]](nc_row, 0)))
    assert_true(_is_null(nc_row, 0))
    _ = nc_row^
    _ = null_column^

    var null_element = _execute_fmt(
        conn, "SELECT ARRAY[1,NULL]::int4[]", ResultFormat.BINARY
    )
    var ne_row = _row(null_element, 0)
    var value = _get_optional[List[Optional[Int32]]](ne_row, 0)
    assert_true(Bool(value))
    assert_false(_is_null(ne_row, 0))
    ref elements = value.value()
    assert_equal(len(elements), 2)
    assert_equal(elements[0].value(), Int32(1))
    assert_false(Bool(elements[1]))
    _ = ne_row^
    _ = null_element^

    _ = conn^


def test_array_element_oid_mismatch_in_both_formats() raises:
    var conn = _connect(_conninfo())
    var sql = String("SELECT '{1,2}'::int2[]")

    # An `int2[]` holds the same two numbers an `int4[]` would, so nothing but
    # the OID check can tell the request apart from a correct one. In binary
    # format the element width differs too, which would silently misread.
    for i in range(2):
        var fmt = ResultFormat.TEXT if i == 0 else ResultFormat.BINARY
        var error = _array_error[Int32](conn, sql.copy(), fmt)
        assert_true(error.kind == PgErrorKind.TYPE_MISMATCH)
        assert_true("1005" in error.message)
        assert_true("int4[]" in error.message)

    _ = conn^


def test_array_multidimensional_is_rejected_in_both_formats() raises:
    var conn = _connect(_conninfo())
    var sql = String("SELECT ARRAY[[1,2],[3,4]]::int4[]")

    # A `List` has one dimension, so a two-dimensional array has no correct
    # answer; both decoders say so instead of flattening it.
    for i in range(2):
        var fmt = ResultFormat.TEXT if i == 0 else ResultFormat.BINARY
        var error = _array_error[Int32](conn, sql.copy(), fmt)
        assert_true(error.kind == PgErrorKind.TYPE_MISMATCH)
        assert_true("multidimensional" in error.message)

    _ = conn^


def test_array_dimension_prefix_is_dropped_in_both_formats() raises:
    var conn = _connect(_conninfo())
    var sql = String("SELECT '[0:1]={7,8}'::int4[]")

    # A non-default lower bound changes the text literal and the binary
    # header, and neither changes the values: a `List` is always 0-based.
    var expected: List[Int32] = [7, 8]
    _assert_array_in_both_formats[Int32](conn, sql^, 1007, expected)

    _ = conn^


def test_array_column_as_string_is_the_literal_in_text_only() raises:
    var conn = _connect(_conninfo())
    var sql = String("SELECT ARRAY[1,NULL,3]::int4[]")

    # Asking for `String` from an array column is not an error in text
    # format: the wildcard branch hands back the literal the server sent,
    # which is the escape hatch for the array shapes `List` cannot hold.
    var in_text = _execute(conn, sql.copy())
    var t = _row(in_text, 0)
    assert_equal(_get[String](t, 0), "{1,NULL,3}")
    _ = t^
    _ = in_text^

    var prefixed = _execute(conn, "SELECT '[0:1]={7,8}'::int4[]")
    var p = _row(prefixed, 0)
    assert_equal(_get[String](p, 0), "[0:1]={7,8}")
    _ = p^
    _ = prefixed^

    # In binary format there is no literal to hand back, and the binary
    # `String` branch takes only the text-shaped OIDs, so this stays a
    # refusal that names the OID.
    var in_binary = _execute_fmt(conn, sql^, ResultFormat.BINARY)
    var b = _row(in_binary, 0)
    var error = _get_error[String](b, 0)
    assert_true(error.kind == PgErrorKind.TYPE_MISMATCH)
    assert_true("1007" in error.message)
    _ = b^
    _ = in_binary^

    _ = conn^


# --- the send direction ------------------------------------------------------


def test_array_params_round_trip_every_element_type() raises:
    var conn = _connect(_conninfo())

    # One `SELECT $1::<type>[]` per element type: the parameter is built by
    # the binary encoder and read back by the binary decoder, so a wrong
    # length word or a wrong element OID cannot survive the loop.
    var bools: List[Bool] = [True, False]
    var bool_params: List[Param] = [bools.copy()]
    var bool_back = _execute_params(
        conn, "SELECT $1::bool[]", bool_params, ResultFormat.BINARY
    )
    var bool_row = _row(bool_back, 0)
    _assert_lists_equal(_get[List[Bool]](bool_row, 0), bools)
    _ = bool_row^
    _ = bool_back^

    var i16: List[Int16] = [32767, -32768]
    var i16_params: List[Param] = [i16.copy()]
    var i16_back = _execute_params(
        conn, "SELECT $1::int2[]", i16_params, ResultFormat.BINARY
    )
    var i16_row = _row(i16_back, 0)
    _assert_lists_equal(_get[List[Int16]](i16_row, 0), i16)
    _ = i16_row^
    _ = i16_back^

    var i32: List[Int32] = [2147483647, -2147483648]
    var i32_params: List[Param] = [i32.copy()]
    var i32_back = _execute_params(
        conn, "SELECT $1::int4[]", i32_params, ResultFormat.BINARY
    )
    var i32_row = _row(i32_back, 0)
    _assert_lists_equal(_get[List[Int32]](i32_row, 0), i32)
    _ = i32_row^
    _ = i32_back^

    var i64: List[Int64] = [Int64.MAX, Int64.MIN]
    var i64_params: List[Param] = [i64.copy()]
    var i64_back = _execute_params(
        conn, "SELECT $1::int8[]", i64_params, ResultFormat.BINARY
    )
    var i64_row = _row(i64_back, 0)
    _assert_lists_equal(_get[List[Int64]](i64_row, 0), i64)
    _ = i64_row^
    _ = i64_back^

    var ints: List[Int] = [Int.MAX, Int.MIN]
    var int_params: List[Param] = [ints.copy()]
    var int_back = _execute_params(
        conn, "SELECT $1::int8[]", int_params, ResultFormat.BINARY
    )
    var int_row = _row(int_back, 0)
    _assert_lists_equal(_get[List[Int]](int_row, 0), ints)
    _ = int_row^
    _ = int_back^

    var f32: List[Float32] = [1.5, -2.5]
    var f32_params: List[Param] = [f32.copy()]
    var f32_back = _execute_params(
        conn, "SELECT $1::float4[]", f32_params, ResultFormat.BINARY
    )
    var f32_row = _row(f32_back, 0)
    _assert_lists_equal(_get[List[Float32]](f32_row, 0), f32)
    _ = f32_row^
    _ = f32_back^

    var f64: List[Float64] = [1e300, -2.5]
    var f64_params: List[Param] = [f64.copy()]
    var f64_back = _execute_params(
        conn, "SELECT $1::float8[]", f64_params, ResultFormat.BINARY
    )
    var f64_row = _row(f64_back, 0)
    _assert_lists_equal(_get[List[Float64]](f64_row, 0), f64)
    _ = f64_row^
    _ = f64_back^

    var texts: List[String] = ["a", "b,c", 'd"e', "f\\g", "", "NULL"]
    var text_params: List[Param] = [texts.copy()]
    var text_back = _execute_params(
        conn, "SELECT $1::text[]", text_params, ResultFormat.BINARY
    )
    var text_row = _row(text_back, 0)
    _assert_lists_equal(_get[List[String]](text_row, 0), texts)
    _ = text_row^
    _ = text_back^

    var blob: List[UInt8] = [0, 255]
    var blobs: List[List[UInt8]] = [blob.copy(), List[UInt8]()]
    var blob_params: List[Param] = [blobs.copy()]
    var blob_back = _execute_params(
        conn, "SELECT $1::bytea[]", blob_params, ResultFormat.BINARY
    )
    var blob_row = _row(blob_back, 0)
    var blobs_back = _get[List[List[UInt8]]](blob_row, 0)
    assert_equal(len(blobs_back), 2)
    _assert_bytes(blobs_back[0], blob)
    assert_equal(len(blobs_back[1]), 0)
    _ = blob_row^
    _ = blob_back^

    var decimals: List[Decimal] = [
        Decimal(String("1.50")),
        Decimal(String("-0.0001")),
    ]
    var decimal_params: List[Param] = [decimals.copy()]
    var decimal_back = _execute_params(
        conn, "SELECT $1::numeric[]", decimal_params, ResultFormat.BINARY
    )
    var decimal_row = _row(decimal_back, 0)
    var decimals_expected: List[String] = ["1.50", "-0.0001"]
    _assert_writes_as(_get[List[Decimal]](decimal_row, 0), decimals_expected)
    _ = decimal_row^
    _ = decimal_back^

    var uuids: List[UUID] = [UUID(String(UUID_TEXT))]
    var uuid_params: List[Param] = [uuids.copy()]
    var uuid_back = _execute_params(
        conn, "SELECT $1::uuid[]", uuid_params, ResultFormat.BINARY
    )
    var uuid_row = _row(uuid_back, 0)
    var uuids_expected: List[String] = [String(UUID_TEXT)]
    _assert_writes_as(_get[List[UUID]](uuid_row, 0), uuids_expected)
    _ = uuid_row^
    _ = uuid_back^

    var dates: List[Date] = [Date(8825), Date.infinity()]
    var date_params: List[Param] = [dates.copy()]
    var date_back = _execute_params(
        conn, "SELECT $1::date[]", date_params, ResultFormat.BINARY
    )
    var date_row = _row(date_back, 0)
    _assert_writes_match(_get[List[Date]](date_row, 0), dates)
    _ = date_row^
    _ = date_back^

    var times: List[Time] = [Time(45296789000)]
    var time_params: List[Param] = [times.copy()]
    var time_back = _execute_params(
        conn, "SELECT $1::time[]", time_params, ResultFormat.BINARY
    )
    var time_row = _row(time_back, 0)
    _assert_writes_match(_get[List[Time]](time_row, 0), times)
    _ = time_row^
    _ = time_back^

    var timetzs: List[TimeTz] = [TimeTz(45296000000, -32400)]
    var timetz_params: List[Param] = [timetzs.copy()]
    var timetz_back = _execute_params(
        conn, "SELECT $1::timetz[]", timetz_params, ResultFormat.BINARY
    )
    var timetz_row = _row(timetz_back, 0)
    _assert_writes_match(_get[List[TimeTz]](timetz_row, 0), timetzs)
    _ = timetz_row^
    _ = timetz_back^

    var timestamps: List[Timestamp] = [
        Timestamp(762525296789000),
        Timestamp.negative_infinity(),
    ]
    var ts_params: List[Param] = [timestamps.copy()]
    var ts_back = _execute_params(
        conn, "SELECT $1::timestamp[]", ts_params, ResultFormat.BINARY
    )
    var ts_row = _row(ts_back, 0)
    _assert_writes_match(_get[List[Timestamp]](ts_row, 0), timestamps)
    _ = ts_row^
    _ = ts_back^

    var timestamptzs: List[TimestampTz] = [TimestampTz(762525296789000)]
    var tstz_params: List[Param] = [timestamptzs.copy()]
    var tstz_back = _execute_params(
        conn, "SELECT $1::timestamptz[]", tstz_params, ResultFormat.BINARY
    )
    var tstz_row = _row(tstz_back, 0)
    _assert_lists_equal(_get[List[TimestampTz]](tstz_row, 0), timestamptzs)
    _ = tstz_row^
    _ = tstz_back^

    var intervals: List[Interval] = [Interval(10800000000, 2, 1)]
    var interval_params: List[Param] = [intervals.copy()]
    var interval_back = _execute_params(
        conn, "SELECT $1::interval[]", interval_params, ResultFormat.BINARY
    )
    var interval_row = _row(interval_back, 0)
    _assert_writes_match(_get[List[Interval]](interval_row, 0), intervals)
    _ = interval_row^
    _ = interval_back^

    _ = conn^


def test_array_params_round_trip_with_null_elements() raises:
    var conn = _connect(_conninfo())

    # The nullable element form sets the payload's NULL bit and writes -1 for
    # the missing element, and the server has to read that back as a NULL
    # rather than as a zero-length value.
    var numbers: List[Optional[Int32]] = [Int32(1), None, Int32(3)]
    var number_params: List[Param] = [numbers.copy()]
    var numbers_back = _execute_params(
        conn, "SELECT $1::int4[]", number_params, ResultFormat.BINARY
    )
    var n_row = _row(numbers_back, 0)
    var got = _get[List[Optional[Int32]]](n_row, 0)
    assert_equal(len(got), 3)
    assert_equal(got[0].value(), Int32(1))
    assert_false(Bool(got[1]))
    assert_equal(got[2].value(), Int32(3))
    _ = n_row^
    _ = numbers_back^

    # Read back through the non-nullable element type, the same round trip is
    # the refusal from the other half of this file.
    var again_params: List[Param] = [numbers.copy()]
    var again = _execute_params(
        conn, "SELECT $1::int4[]", again_params, ResultFormat.BINARY
    )
    var a_row = _row(again, 0)
    var error = _get_error[List[Int32]](a_row, 0)
    assert_true(error.kind == PgErrorKind.NULL_VALUE)
    _ = a_row^
    _ = again^

    # A text element array keeps the distinction between a NULL element and
    # the four-character string "NULL".
    var words: List[Optional[String]] = ["NULL", None, ""]
    var word_params: List[Param] = [words.copy()]
    var words_back = _execute_params(
        conn, "SELECT $1::text[]", word_params, ResultFormat.BINARY
    )
    var w_row = _row(words_back, 0)
    var words_got = _get[List[Optional[String]]](w_row, 0)
    assert_equal(len(words_got), 3)
    assert_equal(words_got[0].value(), "NULL")
    assert_false(Bool(words_got[1]))
    assert_equal(words_got[2].value(), "")
    _ = w_row^
    _ = words_back^

    _ = numbers^
    _ = words^
    _ = conn^


def test_array_param_empty_array_round_trips() raises:
    var conn = _connect(_conninfo())

    # An empty `List` is the 12-byte header with no dimension words, and the
    # server prints it as `{}` -- the one case where the encoder writes a
    # different shape from every other value.
    var empty = List[Int32]()
    var params: List[Param] = [empty.copy()]
    var result = _execute_params(
        conn, "SELECT ($1::int4[])::text, $1::int4[]", params^
    )
    var row = _row(result, 0)
    assert_equal(_get[String](row, 0), "{}")
    assert_equal(len(_get[List[Int32]](row, 1)), 0)
    _ = row^
    _ = result^

    _ = conn^


def test_array_param_works_with_the_any_operator() raises:
    var conn = _connect(_conninfo())

    # `= ANY($1)` is the reason an array parameter is worth having: it is the
    # portable way to send an IN-list of unknown length as one parameter.
    var ids: List[Int32] = [1, 2, 3]
    var id_params: List[Param] = [ids^]
    var int_hit = _execute_params(conn, "SELECT 2 = ANY($1)", id_params)
    var int_row = _row(int_hit, 0)
    assert_true(_get[Bool](int_row, 0))
    _ = int_row^
    _ = int_hit^

    # The text elements carry every character the array literal would have to
    # quote, which is exactly what the binary parameter does not have to.
    var words: List[String] = ["a", "b,c", 'd"e', "f\\g", "", "NULL"]
    var word_params: List[Param] = [words.copy()]
    var text_hit = _execute_params(conn, "SELECT 'b,c' = ANY($1)", word_params)
    var text_row = _row(text_hit, 0)
    assert_true(_get[Bool](text_row, 0))
    _ = text_row^
    _ = text_hit^

    var miss_params: List[Param] = [words.copy()]
    var text_miss = _execute_params(conn, "SELECT 'b' = ANY($1)", miss_params)
    var miss_row = _row(text_miss, 0)
    assert_false(_get[Bool](miss_row, 0))
    _ = miss_row^
    _ = text_miss^

    _ = words^
    _ = conn^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
