"""Tests for `pq.params` and the parameterized `Connection.execute` overload.

Covers `Param` construction (OID, NULL and binary-format flags) without a
server, then the full round trip through `PQexecParams`: every supported Mojo
type, the boundary and non-finite values of each, SQL NULL in both the
untyped and the typed form, server-side type inference for untyped text
parameters, and each way a parameterized statement can be rejected.

`execute(sql, params)` always goes through `PQexecParams`, even for an empty
parameter list, so it accepts a *single* statement only. That asymmetry
against the one-argument overload is asserted here rather than assumed, as is
the second asymmetry around embedded NUL bytes: a NUL in `sql` is a
`TYPE_MISMATCH`, while a NUL in a `String` parameter value is a `USAGE`
error.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI), falling back to the local container. An unreachable
server fails these tests; it never skips them. Every test must pass against
both PG14 and PG17, so nothing here depends on version-specific wording:
only SQLSTATEs, type OIDs and values are asserted.

Every table is created as `CREATE TEMP TABLE pq_p2_<name>`, which keeps it
inside the session, so two test processes -- or the two server versions --
never collide on a name.
"""

from std.math import isinf, isnan
from std.memory import bitcast
from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pq._ffi.types import CONNECTION_OK
from pq.connection import Connection
from pq.errors import PgError, PgErrorKind
from pq.params import Param
from pq.result import Result, Row
from pq.types_datetime import Date, Timestamp, TimestampTz
from pq.types_numeric import Decimal
from pq.types_uuid import UUID

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime NUL_MARKER: StaticString = "AFTER_NUL_MARKER"
"""Text placed *after* an embedded NUL byte in a rejected argument.

libpq takes C strings and counted byte buffers; either way everything from
the NUL onwards is either invisible to it or silently reinterpreted. The
marker proves the truncated tail never reaches a `PgError.message`.
"""

comptime INJECTION: StaticString = "'; DROP TABLE pq_p2_inj; --"
"""A value that would end the statement if it were pasted into the SQL."""

comptime TYPES_DDL: StaticString = (
    "CREATE TEMP TABLE pq_p2_types(b bool, i2 int2, i4 int4, i8 int8,"
    " n int8, f4 float4, f8 float8, t text, by bytea, z int4)"
)
"""One column per Mojo type `Param` can send, plus a NULL target."""

comptime TYPES_INSERT: StaticString = (
    "INSERT INTO pq_p2_types VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)"
)

comptime MIXED_SQL: StaticString = (
    "SELECT $1,$2,$3,$4,$5,$6,$7,$8,$9::int4,$10,$11,$12"
)
"""Twelve parameters in one statement, binary and text formats interleaved.

Three of them are zero-length. A parameter array whose lengths or offsets
drift would still answer the first column correctly, so the point of this
query is the *later* columns.
"""

comptime BIG_SIZE = 65536
"""Payload size for the large text/bytea pair: 64 KiB."""

comptime NEG_ZERO_F32: UInt32 = 0x80000000
"""Bit pattern of `Float32` negative zero.

`-0.0 == 0.0` is true, so sign preservation can only be checked on the bits.
"""

comptime NEG_ZERO_F64: UInt64 = 0x8000000000000000
"""Bit pattern of `Float64` negative zero."""


# --- helpers -----------------------------------------------------------------
#
# A `TestSuite` test only declares `raises` (plain `Error`), and `PgError` does
# not implicitly convert to `Error`, so a `raises PgError` API cannot be called
# straight from a test. These wrappers translate in both directions: success
# paths re-raise as `Error`, failure paths hand the `PgError` back for
# inspection.
#
# The generic wrappers bind `T: Copyable & Deinitable`, not just `Copyable`:
# discarding a `get` result with `_ = ...` needs `Deinitable` to compile.


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
    """Run `sql` on `conn` without parameters.

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


def _execute_error(conn: Connection, var sql: String) raises -> PgError:
    """Return the `PgError` raised by `conn.execute(sql)`.

    Args:
        conn: An open connection.
        sql: A statement that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `execute` returned a result instead of raising.
    """
    try:
        var result = conn.execute(sql^)
        _ = result^
    except e:
        return e.copy()
    raise Error("expected a PgError from Connection.execute(sql)")


def _execute_params(
    conn: Connection, var sql: String, params: List[Param]
) raises -> Result:
    """Run `sql` on `conn` with bound parameters.

    Args:
        conn: An open connection.
        sql: The single statement to run.
        params: The values bound to `$1`, `$2`, ... in order.

    Returns:
        The result of the statement.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    try:
        return conn.execute(sql^, params)
    except e:
        raise Error(String(e))


def _execute_params_error(
    conn: Connection, var sql: String, params: List[Param]
) raises -> PgError:
    """Return the `PgError` raised by `conn.execute(sql, params)`.

    Args:
        conn: An open connection.
        sql: A statement that must be rejected.
        params: The values bound to `$1`, `$2`, ... in order.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `execute` returned a result instead of raising.
    """
    try:
        var result = conn.execute(sql^, params)
        _ = result^
    except e:
        return e.copy()
    raise Error("expected a PgError from Connection.execute(sql, params)")


def _row(result: Result, i: Int) raises -> Row[origin_of(result)]:
    """Return row `i` of `result`.

    A `Row` is a view, not a snapshot: its `origin` parameter ties it to the
    `Result` it came from, so the compiler keeps that result alive for as long
    as the row is reachable.

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


def _assert_oids(result: Result, expected: List[UInt32]) raises:
    """Assert that `result`'s column type OIDs are exactly `expected`.

    Args:
        result: The result to inspect.
        expected: One OID per column, in order.

    Raises:
        Error: If the column count or any OID differs.
    """
    assert_equal(result.column_count(), len(expected))
    for i in range(len(expected)):
        assert_equal(_column_type_oid(result, i), expected[i])


def _assert_param_nul_error(error: PgError, position: Int) raises:
    """Check that `error` is the NUL rejection for parameter `$position`.

    Args:
        error: The error raised by `execute(sql, params)`.
        position: The one-based parameter number the message must name.

    Raises:
        Error: If the kind, message or diagnostics do not match, or if the
            message echoes the text that followed the NUL.
    """
    assert_true(error.kind == PgErrorKind.USAGE)
    assert_equal(
        error.message,
        String("embedded NUL byte in parameter $", position),
    )
    assert_false(error.message.find(NUL_MARKER) >= 0)
    # Nothing reached the server, so there is no diagnostic to carry.
    assert_equal(error.sqlstate, "")
    assert_equal(error.severity, "")


def _with_nul(prefix: String) -> String:
    """Return `prefix`, a NUL byte, then `NUL_MARKER`.

    Args:
        prefix: The part libpq would still see after truncation.

    Returns:
        A `String` whose `byte_length` counts the NUL, so the embedded byte
        really is part of the value rather than a terminator.
    """
    return prefix + chr(0) + NUL_MARKER


def _select_float32(conn: Connection, v: Float32) raises -> Float32:
    """Round-trip `v` through `SELECT $1::float4`.

    Args:
        conn: An open connection.
        v: The value to send.

    Returns:
        The value the server sent back.

    Raises:
        Error: If `execute` or decoding raised a `PgError`.
    """
    var params: List[Param] = [Param(v)]
    var result = _execute_params(conn, "SELECT $1::float4", params)
    var row = _row(result, 0)
    var got = _get[Float32](row, 0)
    _ = row^
    _ = result^
    return got


def _select_float64(conn: Connection, v: Float64) raises -> Float64:
    """Round-trip `v` through `SELECT $1::float8`.

    Args:
        conn: An open connection.
        v: The value to send.

    Returns:
        The value the server sent back.

    Raises:
        Error: If `execute` or decoding raised a `PgError`.
    """
    var params: List[Param] = [Param(v)]
    var result = _execute_params(conn, "SELECT $1::float8", params)
    var row = _row(result, 0)
    var got = _get[Float64](row, 0)
    _ = row^
    _ = result^
    return got


def _select_bytes(conn: Connection, bytes: List[UInt8]) raises -> List[UInt8]:
    """Round-trip `bytes` through `SELECT $1::bytea`.

    Args:
        conn: An open connection.
        bytes: The value to send.

    Returns:
        The bytes the server sent back.

    Raises:
        Error: If `execute` or decoding raised a `PgError`.
    """
    var params: List[Param] = [Param(bytes.copy())]
    var result = _execute_params(conn, "SELECT $1::bytea", params)
    var row = _row(result, 0)
    var got = _get[List[UInt8]](row, 0)
    _ = row^
    _ = result^
    return got^


def _select_text(conn: Connection, text: String) raises -> String:
    """Round-trip `text` through `SELECT $1::text`.

    Args:
        conn: An open connection.
        text: The value to send.

    Returns:
        The text the server sent back.

    Raises:
        Error: If `execute` or decoding raised a `PgError`.
    """
    var params: List[Param] = [Param(text.copy())]
    var result = _execute_params(conn, "SELECT $1::text", params)
    var row = _row(result, 0)
    var got = _get[String](row, 0)
    _ = row^
    _ = result^
    return got^


def _big_text() -> String:
    """Build a text payload of exactly `BIG_SIZE` bytes.

    Returns:
        A 64 KiB ASCII string, grown by doubling a 16-byte seed.
    """
    var text = String("0123456789abcdef")
    while text.byte_length() < BIG_SIZE:
        var more = text.copy()
        text += more
    return text^


def _big_bytes() -> List[UInt8]:
    """Build a bytea payload of exactly `BIG_SIZE` bytes.

    The byte at index `i` is `i % 251`, so the content is position dependent:
    a buffer that is off by any amount other than a multiple of 251 shows up
    as a value mismatch rather than only as a length mismatch.

    Returns:
        A 64 KiB byte list.
    """
    var bytes = List[UInt8]()
    for i in range(BIG_SIZE):
        bytes.append(UInt8(i % 251))
    return bytes^


# --- Param construction, no server needed -- (c)-12 --------------------------


def test_param_null_and_typed_null() raises:
    var untyped = Param.null()
    assert_equal(untyped.oid(), UInt32(0))
    assert_true(untyped.is_null())

    var typed = Param.null(23)
    assert_equal(typed.oid(), UInt32(23))
    assert_true(typed.is_null())


def test_param_oids_and_formats() raises:
    # Integers and floats go out in binary with their exact OID.
    var as_int = Param(Int(1))
    assert_equal(as_int.oid(), UInt32(20))
    assert_true(as_int.is_binary())
    assert_false(as_int.is_null())

    assert_equal(Param(Int16(1)).oid(), UInt32(21))
    assert_equal(Param(Int32(1)).oid(), UInt32(23))
    assert_equal(Param(Int64(1)).oid(), UInt32(20))
    assert_equal(Param(Float32(1)).oid(), UInt32(700))
    assert_equal(Param(Float64(1)).oid(), UInt32(701))
    assert_equal(Param(True).oid(), UInt32(16))
    assert_true(Param(True).is_binary())

    # Text goes out as an untyped text parameter, for the server to infer.
    var as_text = Param("a")
    assert_equal(as_text.oid(), UInt32(0))
    assert_false(as_text.is_binary())
    assert_false(as_text.is_null())

    var blob: List[UInt8] = [1, 2, 3]
    var as_bytes = Param(blob.copy())
    assert_equal(as_bytes.oid(), UInt32(17))
    assert_true(as_bytes.is_binary())
    assert_false(as_bytes.is_null())


def test_param_oids_of_the_extended_types() raises:
    # `Decimal` and `UUID` go out in binary with the OID of the PostgreSQL
    # type they stand for, unlike `String`, which leaves the OID unspecified.
    var as_numeric = Param(Decimal(String("1")))
    assert_equal(as_numeric.oid(), UInt32(1700))
    assert_true(as_numeric.is_binary())
    assert_false(as_numeric.is_null())

    var as_uuid = Param(UUID(String("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")))
    assert_equal(as_uuid.oid(), UInt32(2950))
    assert_true(as_uuid.is_binary())
    assert_false(as_uuid.is_null())

    var as_date = Param(Date(8825))
    assert_equal(as_date.oid(), UInt32(1082))
    assert_true(as_date.is_binary())
    assert_false(as_date.is_null())

    var as_timestamp = Param(Timestamp(762525296789000))
    assert_equal(as_timestamp.oid(), UInt32(1114))
    assert_true(as_timestamp.is_binary())
    assert_false(as_timestamp.is_null())

    var as_timestamptz = Param(TimestampTz(762525296789000))
    assert_equal(as_timestamptz.oid(), UInt32(1184))
    assert_true(as_timestamptz.is_binary())
    assert_false(as_timestamptz.is_null())


def test_param_from_empty_optional_of_an_extended_type() raises:
    var no_numeric = Param(Optional[Decimal](None))
    assert_equal(no_numeric.oid(), UInt32(1700))
    assert_true(no_numeric.is_null())

    var no_uuid = Param(Optional[UUID](None))
    assert_equal(no_uuid.oid(), UInt32(2950))
    assert_true(no_uuid.is_null())

    var no_date = Param(Optional[Date](None))
    assert_equal(no_date.oid(), UInt32(1082))
    assert_true(no_date.is_null())

    var no_timestamp = Param(Optional[Timestamp](None))
    assert_equal(no_timestamp.oid(), UInt32(1114))
    assert_true(no_timestamp.is_null())

    var no_timestamptz = Param(Optional[TimestampTz](None))
    assert_equal(no_timestamptz.oid(), UInt32(1184))
    assert_true(no_timestamptz.is_null())


def test_param_from_empty_optional_keeps_the_oid() raises:
    # An empty `Optional` is a NULL that still carries its element's type, so
    # the server never has to infer one.
    var no_int = Param(Optional[Int32](None))
    assert_equal(no_int.oid(), UInt32(23))
    assert_true(no_int.is_null())

    # Except for text, which has no OID to carry in the first place.
    var no_text = Param(Optional[String](None))
    assert_equal(no_text.oid(), UInt32(0))
    assert_true(no_text.is_null())


def test_param_list_literal_converts_each_element() raises:
    var ps: List[Param] = [1, "a", 1.5, True, Param.null()]
    assert_equal(len(ps), 5)
    assert_equal(ps[0].oid(), UInt32(20))
    assert_equal(ps[1].oid(), UInt32(0))
    assert_equal(ps[2].oid(), UInt32(701))
    assert_equal(ps[3].oid(), UInt32(16))
    assert_equal(ps[4].oid(), UInt32(0))
    assert_true(ps[4].is_null())


# --- every type in one round trip -- (c)-1 -----------------------------------


def test_all_types_round_trip() raises:
    var conn = _connect(_conninfo())
    var created = _execute(conn, String(TYPES_DDL))
    _ = created^

    var blob: List[UInt8] = [0, 1, 0, 255]
    var params: List[Param] = [
        True,
        Int16(-32768),
        Int32(2147483647),
        Int64.MIN,
        Int(42),
        Float32(1.5),
        Float64(-2.5),
        "héllo",
        blob.copy(),
        Param.null(),
    ]
    var inserted = _execute_params(conn, String(TYPES_INSERT), params)
    assert_equal(inserted.affected_rows(), 1)
    assert_equal(inserted.command_tag(), "INSERT 0 1")
    _ = inserted^

    var result = _execute(conn, "SELECT * FROM pq_p2_types")
    assert_equal(result.row_count(), 1)

    var expected_oids: List[UInt32] = [
        16,
        21,
        23,
        20,
        20,
        700,
        701,
        25,
        17,
        23,
    ]
    _assert_oids(result, expected_oids)

    var row = _row(result, 0)
    assert_true(_get[Bool](row, 0))
    assert_equal(_get[Int16](row, 1), Int16(-32768))
    assert_equal(_get[Int32](row, 2), Int32(2147483647))
    assert_equal(_get[Int64](row, 3), Int64.MIN)
    assert_equal(_get[Int](row, 4), 42)
    assert_equal(_get[Float32](row, 5), Float32(1.5))
    assert_equal(_get[Float64](row, 6), Float64(-2.5))
    assert_equal(_get[String](row, 7), "héllo")
    _assert_bytes(_get[List[UInt8]](row, 8), blob)
    assert_true(_is_null(row, 9))

    _ = row^
    _ = result^
    _ = conn^


# --- a text parameter is never SQL -- (c)-2 ----------------------------------


def test_text_parameter_is_never_sql() raises:
    var conn = _connect(_conninfo())
    var created = _execute(conn, "CREATE TEMP TABLE pq_p2_inj(t text)")
    _ = created^

    var params: List[Param] = [Param(String(INJECTION))]
    var inserted = _execute_params(
        conn, "INSERT INTO pq_p2_inj VALUES ($1)", params
    )
    assert_equal(inserted.affected_rows(), 1)
    _ = inserted^

    # The table is still there -- had the value been pasted into the SQL, the
    # DROP would have run and this statement would fail with 42P01.
    var counted = _execute(conn, "SELECT count(*) FROM pq_p2_inj")
    var count_row = _row(counted, 0)
    assert_equal(_get[Int64](count_row, 0), Int64(1))
    _ = count_row^
    _ = counted^

    # And the value was stored verbatim, quotes, semicolon and comment alike.
    var stored = _execute(conn, "SELECT t FROM pq_p2_inj")
    var row = _row(stored, 0)
    assert_equal(_get[String](row, 0), String(INJECTION))
    _ = row^
    _ = stored^
    _ = conn^


# --- boundary values -- (c)-3 ------------------------------------------------


def test_int16_parameter_boundaries() raises:
    var conn = _connect(_conninfo())
    var values: List[Int16] = [-32768, 32767, 0, -1]
    for v in values:
        var params: List[Param] = [Param(v)]
        var result = _execute_params(conn, "SELECT $1::int2", params)
        assert_equal(_column_type_oid(result, 0), UInt32(21))
        var row = _row(result, 0)
        assert_equal(_get[Int16](row, 0), v)
        _ = row^
        _ = result^
    _ = conn^


def test_int32_parameter_boundaries() raises:
    var conn = _connect(_conninfo())
    var values: List[Int32] = [Int32(-2147483648), Int32(2147483647)]
    for v in values:
        var params: List[Param] = [Param(v)]
        var result = _execute_params(conn, "SELECT $1::int4", params)
        assert_equal(_column_type_oid(result, 0), UInt32(23))
        var row = _row(result, 0)
        assert_equal(_get[Int32](row, 0), v)
        _ = row^
        _ = result^
    _ = conn^


def test_int64_parameter_boundaries() raises:
    var conn = _connect(_conninfo())
    var values: List[Int64] = [Int64.MIN, Int64.MAX]
    for v in values:
        var params: List[Param] = [Param(v)]
        var result = _execute_params(conn, "SELECT $1::int8", params)
        assert_equal(_column_type_oid(result, 0), UInt32(20))
        var row = _row(result, 0)
        assert_equal(_get[Int64](row, 0), v)
        _ = row^
        _ = result^
    _ = conn^


def test_int_parameter_boundaries() raises:
    var conn = _connect(_conninfo())
    var values: List[Int] = [Int.MIN, Int.MAX]
    for v in values:
        var params: List[Param] = [Param(v)]
        var result = _execute_params(conn, "SELECT $1::int8", params)
        assert_equal(_column_type_oid(result, 0), UInt32(20))
        var row = _row(result, 0)
        assert_equal(_get[Int](row, 0), v)
        _ = row^
        _ = result^
    _ = conn^


def test_float32_parameter_specials() raises:
    var conn = _connect(_conninfo())

    assert_equal(_select_float32(conn, Float32(1.5)), Float32(1.5))

    assert_true(isnan(_select_float32(conn, Float32(0.0) / Float32(0.0))))

    var positive = _select_float32(conn, Float32(1.0) / Float32(0.0))
    assert_true(isinf(positive))
    assert_true(positive > 0)

    var negative = _select_float32(conn, (-Float32(1.0)) / Float32(0.0))
    assert_true(isinf(negative))
    assert_true(negative < 0)

    # `-0.0 == 0.0`, so the sign only shows up in the bits.
    var sent = -Float32(0.0)
    assert_equal(bitcast[DType.uint32, 1](sent), NEG_ZERO_F32)
    assert_equal(
        bitcast[DType.uint32, 1](_select_float32(conn, sent)), NEG_ZERO_F32
    )

    _ = conn^


def test_float64_parameter_specials() raises:
    var conn = _connect(_conninfo())

    assert_equal(_select_float64(conn, Float64(-2.5)), Float64(-2.5))

    assert_true(isnan(_select_float64(conn, Float64(0.0) / Float64(0.0))))

    var positive = _select_float64(conn, Float64(1.0) / Float64(0.0))
    assert_true(isinf(positive))
    assert_true(positive > 0)

    var negative = _select_float64(conn, (-Float64(1.0)) / Float64(0.0))
    assert_true(isinf(negative))
    assert_true(negative < 0)

    var sent = -Float64(0.0)
    assert_equal(bitcast[DType.uint64, 1](sent), NEG_ZERO_F64)
    assert_equal(
        bitcast[DType.uint64, 1](_select_float64(conn, sent)), NEG_ZERO_F64
    )

    _ = conn^


def test_empty_and_nul_bearing_payloads() raises:
    var conn = _connect(_conninfo())

    # A zero-length bytea is a value, not a NULL.
    var empty_bytes = List[UInt8]()
    var got_empty = _select_bytes(conn, empty_bytes)
    assert_equal(len(got_empty), 0)

    # bytea travels in binary with an explicit length, so a NUL in the middle
    # is just a byte -- unlike a NUL in a `String` parameter, which is
    # rejected outright.
    var with_nul: List[UInt8] = [0x61, 0x00, 0x62]
    _assert_bytes(_select_bytes(conn, with_nul), with_nul)

    # The empty string likewise round-trips as a value.
    assert_equal(_select_text(conn, ""), "")

    _ = conn^


def test_large_text_and_bytea_in_one_statement() raises:
    var conn = _connect(_conninfo())

    var text = _big_text()
    var bytes = _big_bytes()
    assert_equal(text.byte_length(), BIG_SIZE)
    assert_equal(len(bytes), BIG_SIZE)

    # Two large payloads of different formats in one statement: if the second
    # parameter's length were taken from the first, the sizes would not match.
    var params: List[Param] = [Param(text.copy()), Param(bytes.copy())]
    var result = _execute_params(conn, "SELECT $1::text, $2::bytea", params)
    var row = _row(result, 0)

    var got_text = _get[String](row, 0)
    assert_equal(got_text.byte_length(), BIG_SIZE)
    assert_equal(got_text, text)
    _assert_bytes(_get[List[UInt8]](row, 1), bytes)

    _ = row^
    _ = result^
    _ = conn^


# --- NULL parameters -- (c)-4 ------------------------------------------------


def test_untyped_null_in_a_cast_position() raises:
    var conn = _connect(_conninfo())
    var params: List[Param] = [Param.null()]
    var result = _execute_params(conn, "SELECT $1::int4", params)
    var row = _row(result, 0)
    assert_true(_is_null(row, 0))
    _ = row^
    _ = result^
    _ = conn^


def test_typed_null_pins_the_column_type() raises:
    var conn = _connect(_conninfo())
    var params: List[Param] = [Param.null(23)]
    var result = _execute_params(conn, "SELECT $1", params)
    assert_equal(_column_type_oid(result, 0), UInt32(23))
    var row = _row(result, 0)
    assert_true(_is_null(row, 0))
    _ = row^
    _ = result^
    _ = conn^


def test_untyped_null_is_inferred_as_text() raises:
    var conn = _connect(_conninfo())

    # OID 0 in a bare select-list position resolves to text on PG14 and
    # PG17 alike; it is never the "could not determine data type" 42P18.
    var params: List[Param] = [Param.null()]
    var result = _execute_params(conn, "SELECT $1", params)
    assert_equal(_column_type_oid(result, 0), UInt32(25))
    var row = _row(result, 0)
    assert_true(_is_null(row, 0))
    _ = row^
    _ = result^
    _ = conn^


def test_optional_int_parameter_both_ways() raises:
    var conn = _connect(_conninfo())

    var none: Optional[Int] = None
    var absent_params: List[Param] = [Param(none)]
    var absent = _execute_params(conn, "SELECT $1", absent_params)
    assert_equal(_column_type_oid(absent, 0), UInt32(20))
    var absent_row = _row(absent, 0)
    assert_true(_is_null(absent_row, 0))
    _ = absent_row^
    _ = absent^

    var present_params: List[Param] = [Param(Optional[Int](7))]
    var present = _execute_params(conn, "SELECT $1", present_params)
    assert_equal(_column_type_oid(present, 0), UInt32(20))
    var present_row = _row(present, 0)
    assert_false(_is_null(present_row, 0))
    assert_equal(_get[Int](present_row, 0), 7)
    _ = present_row^
    _ = present^

    _ = conn^


def test_optional_string_parameter_both_ways() raises:
    var conn = _connect(_conninfo())

    var absent_params: List[Param] = [Param(Optional[String](None))]
    var absent = _execute_params(conn, "SELECT $1", absent_params)
    assert_equal(_column_type_oid(absent, 0), UInt32(25))
    var absent_row = _row(absent, 0)
    assert_true(_is_null(absent_row, 0))
    _ = absent_row^
    _ = absent^

    var present_params: List[Param] = [Param(Optional[String]("s"))]
    var present = _execute_params(conn, "SELECT $1", present_params)
    assert_equal(_column_type_oid(present, 0), UInt32(25))
    var present_row = _row(present, 0)
    assert_equal(_get[String](present_row, 0), "s")
    _ = present_row^
    _ = present^

    _ = conn^


def test_optional_bool_none_keeps_the_bool_oid() raises:
    var conn = _connect(_conninfo())
    var params: List[Param] = [Param(Optional[Bool](None))]
    var result = _execute_params(conn, "SELECT $1", params)
    assert_equal(_column_type_oid(result, 0), UInt32(16))
    var row = _row(result, 0)
    assert_true(_is_null(row, 0))
    _ = row^
    _ = result^
    _ = conn^


# --- server-side type inference -- (c)-5 -------------------------------------


def test_text_parameter_is_inferred_as_text() raises:
    var conn = _connect(_conninfo())
    var params: List[Param] = ["hello"]
    var result = _execute_params(conn, "SELECT $1", params)
    assert_equal(_column_type_oid(result, 0), UInt32(25))
    var row = _row(result, 0)
    assert_equal(_get[String](row, 0), "hello")
    _ = row^
    _ = result^
    _ = conn^


def test_text_parameter_is_inferred_as_int4_in_arithmetic() raises:
    var conn = _connect(_conninfo())

    # A `String` parameter is sent with OID 0, so the context decides: here
    # `$1 + 1` resolves to int4 and the server parses "7" as a number.
    var params: List[Param] = ["7"]
    var result = _execute_params(conn, "SELECT $1 + 1", params)
    assert_equal(_column_type_oid(result, 0), UInt32(23))
    var row = _row(result, 0)
    assert_equal(_get[Int32](row, 0), Int32(8))
    _ = row^
    _ = result^
    _ = conn^


def test_int_parameter_pins_int8() raises:
    var conn = _connect(_conninfo())
    var params: List[Param] = [Int(1)]
    var result = _execute_params(conn, "SELECT $1", params)
    assert_equal(_column_type_oid(result, 0), UInt32(20))
    var row = _row(result, 0)
    assert_equal(_get[Int64](row, 0), Int64(1))
    _ = row^
    _ = result^
    _ = conn^


# --- type mismatches are the server's call -- (c)-6 --------------------------


def test_type_mismatch_is_a_server_error() raises:
    var conn = _connect(_conninfo())
    var created = _execute(conn, "CREATE TEMP TABLE pq_p2_i4(x int4)")
    _ = created^

    # bool (OID 16) into int4 has no cast at all.
    var bool_params: List[Param] = [True]
    var bad_type = _execute_params_error(
        conn, "INSERT INTO pq_p2_i4 VALUES ($1)", bool_params
    )
    assert_true(bad_type.kind == PgErrorKind.SERVER)
    assert_true(bad_type.sqlstate != "")

    # int8 into int4 has an assignment cast, so the range is what decides.
    var big_params: List[Param] = [Int(3000000000)]
    var overflow = _execute_params_error(
        conn, "INSERT INTO pq_p2_i4 VALUES ($1)", big_params
    )
    assert_true(overflow.kind == PgErrorKind.SERVER)
    assert_equal(overflow.sqlstate, "22003")

    # And an in-range `Int` goes in, even though it was sent as int8.
    var ok_params: List[Param] = [Int(5)]
    var inserted = _execute_params(
        conn, "INSERT INTO pq_p2_i4 VALUES ($1)", ok_params
    )
    assert_equal(inserted.affected_rows(), 1)
    _ = inserted^

    _ = conn^


# --- the parameter count is the server's call -- (c)-7 -----------------------


def test_parameter_count_mismatch_is_a_protocol_error() raises:
    var conn = _connect(_conninfo())

    # `execute` does not scan the SQL for placeholders, so a short parameter
    # list reaches the server and comes back as a protocol violation.
    var params: List[Param] = [1]
    var error = _execute_params_error(conn, "SELECT $1::int4, $2::int4", params)
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.sqlstate, "08P01")

    # 08P01 here is a rejected statement, not a broken connection.
    assert_equal(conn.status(), Int(CONNECTION_OK))
    var ok = _execute(conn, "SELECT 1")
    assert_equal(ok.row_count(), 1)
    _ = ok^

    _ = conn^


# --- one statement only -- (c)-8 ---------------------------------------------


def test_empty_sql_is_a_server_error() raises:
    var conn = _connect(_conninfo())
    var empty = List[Param]()
    var error = _execute_params_error(conn, "", empty)
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.message, "empty query")
    _ = conn^


def test_multi_statement_is_rejected_even_without_params() raises:
    var conn = _connect(_conninfo())
    var empty = List[Param]()

    # An empty parameter list still goes through `PQexecParams`, which speaks
    # the extended protocol and therefore accepts a single statement only.
    var error = _execute_params_error(conn, "SELECT 1; SELECT 2", empty)
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.sqlstate, "42601")

    # A lone trailing semicolon is still one statement, so it is fine.
    var ok = _execute_params(conn, "SELECT 1;", empty)
    assert_equal(ok.row_count(), 1)
    _ = ok^

    _ = conn^


# --- embedded NUL bytes -- (c)-9 ---------------------------------------------
#
# The two rejections are deliberately different. A NUL in `sql` is a
# TYPE_MISMATCH, matching the one-argument overload. A NUL in a `String`
# parameter value is a USAGE error, because the value *could* have been sent
# as a bytea instead: the caller picked the wrong type, rather than handing
# over a malformed statement.


def test_nul_in_a_string_parameter_is_a_usage_error() raises:
    var conn = _connect(_conninfo())

    var first: List[Param] = [Param(_with_nul("ab"))]
    _assert_param_nul_error(_execute_params_error(conn, "SELECT $1", first), 1)

    # The position in the message is one-based, so it is only pinned down by a
    # parameter other than the first.
    var second: List[Param] = ["ok", Param(_with_nul("ab"))]
    _assert_param_nul_error(
        _execute_params_error(conn, "SELECT $1, $2", second), 2
    )

    # Nothing was sent, so the connection is untouched and still usable.
    assert_equal(conn.status(), Int(CONNECTION_OK))
    var ok = _execute(conn, "SELECT 1")
    assert_equal(ok.row_count(), 1)
    _ = ok^

    _ = conn^


def test_nul_in_sql_is_a_type_mismatch() raises:
    var conn = _connect(_conninfo())
    var empty = List[Param]()

    var error = _execute_params_error(conn, _with_nul("SELECT 1"), empty)
    assert_true(error.kind == PgErrorKind.TYPE_MISMATCH)
    assert_equal(error.message, "embedded NUL byte in sql")
    # Everything past the NUL is invisible to libpq; it must be invisible in
    # the error text too.
    assert_false(error.message.find(NUL_MARKER) >= 0)
    assert_equal(error.sqlstate, "")
    assert_equal(error.severity, "")

    assert_equal(conn.status(), Int(CONNECTION_OK))
    _ = conn^


# --- twelve parameters at once -- (c)-10 -------------------------------------


def test_twelve_mixed_parameters() raises:
    var conn = _connect(_conninfo())

    var blob: List[UInt8] = [0, 1, 0, 255]
    var empty_blob = List[UInt8]()
    var params: List[Param] = [
        True,
        Int16(-32768),
        Int32(2147483647),
        Int64.MIN,
        Float32(0.0) / Float32(0.0),
        -Float64(0.0),
        Param(String(INJECTION)),
        blob.copy(),
        Param.null(),
        empty_blob.copy(),
        "",
        Float64(1.0) / Float64(0.0),
    ]
    var result = _execute_params(conn, String(MIXED_SQL), params)

    var expected_oids: List[UInt32] = [
        16,
        21,
        23,
        20,
        700,
        701,
        25,
        17,
        23,
        17,
        25,
        701,
    ]
    _assert_oids(result, expected_oids)

    var row = _row(result, 0)
    assert_true(_get[Bool](row, 0))
    assert_equal(_get[Int16](row, 1), Int16(-32768))
    assert_equal(_get[Int32](row, 2), Int32(2147483647))
    assert_equal(_get[Int64](row, 3), Int64.MIN)
    assert_true(isnan(_get[Float32](row, 4)))
    assert_equal(bitcast[DType.uint64, 1](_get[Float64](row, 5)), NEG_ZERO_F64)
    assert_equal(_get[String](row, 6), String(INJECTION))
    _assert_bytes(_get[List[UInt8]](row, 7), blob)
    assert_true(_is_null(row, 8))
    assert_equal(len(_get[List[UInt8]](row, 9)), 0)
    assert_equal(_get[String](row, 10), "")
    var last = _get[Float64](row, 11)
    assert_true(isinf(last))
    assert_true(last > 0)

    _ = row^
    _ = result^
    _ = conn^


# --- inside an aborted transaction -- (c)-11 ---------------------------------


def test_params_inside_an_aborted_transaction() raises:
    var conn = _connect(_conninfo())

    var begun = _execute(conn, "BEGIN")
    _ = begun^

    var broken = _execute_error(conn, "SELEC")
    assert_true(broken.kind == PgErrorKind.SERVER)

    # The transaction is aborted, so a parameterized statement is refused for
    # that reason alone -- 25P02, not whatever the statement itself would say.
    var params: List[Param] = [1]
    var error = _execute_params_error(conn, "SELECT $1", params)
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.sqlstate, "25P02")

    # And the block can still be unwound.
    var rolled_back = _execute(conn, "ROLLBACK")
    _ = rolled_back^
    assert_equal(conn.status(), Int(CONNECTION_OK))

    var ok = _execute(conn, "SELECT 1")
    assert_equal(ok.row_count(), 1)
    _ = ok^

    _ = conn^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
