"""Tests for binary-format results against a live server.

Covers the `result_format` keyword argument on `Connection.execute`,
`PreparedStatement.execute` and `Transaction.execute`, the
`Result.column_format` accessor, and the rule that a binary result decodes to
the *same* values the text result of the same SQL decodes to.

Three properties are asserted everywhere:

* The format is a property of the whole result, not of a single column: a
  binary result reports `ResultFormat.BINARY` for *every* column.
* `ResultFormat.TEXT` is the default, so `execute(sql, [])` and the
  parameterless `execute(sql)` both come back in text format.
* Binary decoding never falls back to raw bytes. An OID the binary decoder
  does not support is a `TYPE_MISMATCH` naming the OID and pointing at
  `ResultFormat.TEXT`, and only re-running in text format reads it.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI), falling back to the local container. An unreachable server
fails these tests; it never skips them.

Every test must pass against both PG14 and PG17 with the *same* expected
values -- there is no version-dependent branch here -- so nothing below
asserts a column *name* that the query did not alias: PG17 reports `?column?`
where PG14 reports `bool` for a bare `true`. Type OIDs and values are
identical across both versions, and those are what these tests assert.

Text containing an embedded NUL is out of scope here: the server cannot
produce such a value (`chr(0)` is SQLSTATE 54000), so the binary decoder's
handling of it is covered by the unit tests in `tests/test_decode_binary.mojo`.
"""

from std.math import isinf, isnan
from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pq.connection import Connection
from pq.errors import PgError, PgErrorKind
from pq.params import Param
from pq.prepared import PreparedStatement
from pq.result import Result, ResultFormat, Row
from pq.transaction import Transaction

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime SCALARS_SQL: StaticString = (
    "SELECT true, false, 1::int2, 2::int4, 3::int8, 1.5::float4, 2.5::float8,"
    " 'héllo'::text, ''::text, 'x'::varchar, 'ab'::char(5), 'n'::name,"
    " '\\x00ff00'::bytea, ''::bytea"
)
"""One row of all eight supported types, plus varchar, bpchar and name.

`'ab'::char(5)` is blank-padded by the server in *both* formats, so the
expected value is `"ab   "` either way. `'héllo'` is six bytes of UTF-8 behind
five characters, and both the empty text and the empty bytea are values rather
than NULLs.
"""

comptime BOUNDARIES_SQL: StaticString = (
    "SELECT 32767::int2, (-32768)::int2,"
    " 2147483647::int4, (-2147483648)::int4,"
    " 9223372036854775807::int8, (-9223372036854775808)::int8"
)
"""The extremes of `int2`, `int4` and `int8`.

The negative literals are parenthesized on purpose: `::` binds tighter than
unary minus, so `-2147483648::int4` casts the *positive* literal and the
server answers `ERROR: integer out of range` (measured on PG14 and PG17).
"""

comptime FLOATS_SQL: StaticString = (
    "SELECT 'NaN'::float8, 'Infinity'::float8, '-Infinity'::float8,"
    " '-0'::float8, 1e300::float8,"
    " 'NaN'::float4, 'Infinity'::float4, '-Infinity'::float4, '-0'::float4"
)
"""Every floating point value whose two wire formats need care.

The negative zero is written `'-0'::float8`, not `(-0.0)::float8`: the latter
parses as a `numeric` literal, and `numeric` has no signed zero, so the server
answers a plain `0` and the sign under test is gone before the wire format
matters (measured on PG14 and PG17).

`1e300::float8` prints as `1e+300` in text format, which is a different byte
string from anything the binary format sends while being the same `Float64`.
"""

comptime UNSUPPORTED_SQL: StaticString = (
    "SELECT ARRAY[1,2]::int4[], point(1,2), 1::oid, 'a'::\"char\","
    " int4range(1,5), 1.5::money, '08:00:2b:01:02:03'::macaddr"
)
"""Seven columns whose OIDs the binary decoder does not support.

In order: `int4[]` (1007), `point` (600), `oid` (26), `"char"` (18),
`int4range` (3904), `money` (790) and `macaddr` (829). None of them is in the
binary allow-list of any Mojo type, so every type requested from every one of
these columns must be rejected. Their *text* values are locale- or
version-sensitive (`money` renders as `$1.50` under the test locale), so the
text half of the grid asserts only that `String` decodes, never what it says.
"""

comptime TERMINATE_SQL: StaticString = (
    "SELECT pg_terminate_backend(pg_backend_pid())"
)
"""Kill this session's own backend, leaving the connection unusable."""


# --- helpers -----------------------------------------------------------------
#
# A `TestSuite` test only declares `raises` (plain `Error`), and `PgError` does
# not implicitly convert to `Error`, so a `raises PgError` API cannot be called
# straight from a test. These wrappers translate in both directions: success
# paths re-raise as `Error`, failure paths hand the `PgError` -- or just its
# kind or message -- back for inspection.
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
    """Run `sql` on `conn` through the parameterless overload.

    That overload takes no `result_format`, so its result is always in text
    format.

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


def _execute_params(
    conn: Connection, var sql: String, params: List[Param]
) raises -> Result:
    """Run `sql` on `conn` with bound parameters and the default format.

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


def _execute_fmt(
    conn: Connection, var sql: String, fmt: ResultFormat
) raises -> Result:
    """Run `sql` on `conn` asking for results in `fmt`.

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


def _execute_error_either_kind(
    conn: Connection, var sql: String
) raises -> PgError:
    """Return the `PgError` raised by `conn.execute(sql)`.

    Only used for the statement that kills the backend, where either kind is
    a correct answer; everywhere else a single kind is asserted.

    Args:
        conn: An open connection.
        sql: A statement that must be rejected.

    Returns:
        The raised `PgError`, whose kind may be CONNECTION or SERVER.

    Raises:
        Error: If `execute` returned a result instead of raising, or raised
            with a kind that is neither CONNECTION nor SERVER.
    """
    try:
        var result = conn.execute(sql^)
        _ = result^
    except e:
        if e.kind != PgErrorKind.CONNECTION and e.kind != PgErrorKind.SERVER:
            raise Error(String("unexpected PgError kind: ", e))
        return e.copy()
    raise Error("expected a PgError from Connection.execute(sql)")


def _execute_fmt_error(
    conn: Connection, var sql: String, fmt: ResultFormat
) raises -> PgError:
    """Return the `PgError` raised by a `fmt`-format `execute` of `sql`.

    Args:
        conn: A connection whose statement must be rejected.
        sql: The statement to attempt.
        fmt: The wire format the server should send columns in.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `execute` returned a result instead of raising.
    """
    try:
        var result = conn.execute(sql^, List[Param](), result_format=fmt)
        _ = result^
    except e:
        return e.copy()
    raise Error("expected a PgError from Connection.execute(sql, params, fmt)")


def _prepare(
    conn: Connection,
    var sql: String,
    param_types: List[UInt32] = List[UInt32](),
) raises -> PreparedStatement[origin_of(conn)]:
    """Prepare `sql` on `conn`.

    The returned statement is a view onto the connection: its `origin`
    parameter ties it to `conn`, so the compiler keeps the connection alive
    for as long as the statement is reachable.

    Args:
        conn: An open connection.
        sql: The single statement to prepare.
        param_types: Type OIDs for `$1`, `$2`, ...; empty means "infer".

    Returns:
        The prepared statement.

    Raises:
        Error: If `prepare` raised a `PgError`.
    """
    try:
        return conn.prepare(sql^, param_types)
    except e:
        raise Error(String(e))


def _stmt_execute_fmt[
    origin: ImmOrigin, //
](
    stmt: PreparedStatement[origin], params: List[Param], fmt: ResultFormat
) raises -> Result:
    """Execute `stmt` with bound parameters, asking for results in `fmt`.

    Parameters:
        origin: Origin of the `Connection` the statement views; inferred.

    Args:
        stmt: The prepared statement to run.
        params: The values bound to `$1`, `$2`, ... in order.
        fmt: The wire format the server should send columns in.

    Returns:
        The result of the statement.

    Raises:
        Error: If `PreparedStatement.execute` raised a `PgError`.
    """
    try:
        return stmt.execute(params, result_format=fmt)
    except e:
        raise Error(String(e))


def _transaction(conn: Connection) raises -> Transaction[origin_of(conn)]:
    """Begin a transaction block on `conn`.

    The returned block is a view onto the connection: its `origin` parameter
    ties it to `conn`, so the compiler keeps the connection alive for as long
    as the block is reachable.

    Args:
        conn: An idle, open connection.

    Returns:
        The open transaction block, with its `BEGIN` already sent.

    Raises:
        Error: If `transaction` raised a `PgError`.
    """
    try:
        return conn.transaction()
    except e:
        raise Error(String(e))


def _tx_execute_fmt[
    origin: ImmOrigin, //
](
    mut tx: Transaction[origin], var sql: String, fmt: ResultFormat
) raises -> Result:
    """Run `sql` inside `tx`, asking for results in `fmt`.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The open transaction block.
        sql: The single statement to run.
        fmt: The wire format the server should send columns in.

    Returns:
        The result of the statement.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    try:
        return tx.execute(sql^, List[Param](), result_format=fmt)
    except e:
        raise Error(String(e))


def _tx_commit[origin: ImmOrigin, //](mut tx: Transaction[origin]) raises:
    """Commit `tx`.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The open transaction block.

    Raises:
        Error: If `commit` raised a `PgError`.
    """
    try:
        tx.commit()
    except e:
        raise Error(String(e))


def _column_format(result: Result, i: Int) raises -> ResultFormat:
    """Return the wire format column `i` of `result` arrived in.

    Args:
        result: The result to inspect.
        i: Zero-based column index.

    Returns:
        The column's wire format.

    Raises:
        Error: If `column_format` raised a `PgError`.
    """
    try:
        return result.column_format(i)
    except e:
        raise Error(String(e))


def _column_format_kind(result: Result, i: Int) raises -> PgErrorKind:
    """Return the kind of the `PgError` raised by `column_format(i)`.

    Args:
        result: The result to inspect.
        i: A column index that must be rejected.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If `column_format` returned a format instead of raising.
    """
    try:
        _ = result.column_format(i)
    except e:
        return e.kind
    raise Error(String("expected a PgError from column_format(", i, ")"))


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


def _get_kind[
    origin: ImmOrigin, //, T: Copyable & Deinitable
](row: Row[origin], col: Int) raises -> PgErrorKind:
    """Return the kind of the `PgError` raised by `row.get[T](col)`.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.
        T: The Mojo type requested from `Row.get`.

    Args:
        row: The row to read.
        col: A column index that must be rejected.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If `Row.get` returned a value instead of raising.
    """
    try:
        _ = row.get[T](col)
    except e:
        return e.kind
    raise Error(String("expected a PgError from get(", col, ")"))


def _get_message[
    origin: ImmOrigin, //, T: Copyable & Deinitable
](row: Row[origin], col: Int) raises -> String:
    """Return the message of the `PgError` raised by `row.get[T](col)`.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.
        T: The Mojo type requested from `Row.get`.

    Args:
        row: The row to read.
        col: A column index that must be rejected.

    Returns:
        The `message` field of the raised `PgError`.

    Raises:
        Error: If `Row.get` returned a value instead of raising.
    """
    try:
        _ = row.get[T](col)
    except e:
        return e.message
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


def _assert_binary_refusal[
    origin: ImmOrigin, //, T: Copyable & Deinitable
](row: Row[origin], col: Int) raises:
    """Assert that `row.get[T](col)` refuses a binary column it cannot decode.

    The refusal must be a `TYPE_MISMATCH` whose message names the offending
    OID and points the caller at the text format. Both halves are checked with
    multi-word substrings so that a message which merely happens to contain
    the letter sequence cannot pass.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.
        T: The Mojo type requested from `Row.get`.

    Args:
        row: A row from a binary-format result.
        col: The column index that must be rejected.

    Raises:
        Error: If the call succeeded, or failed with the wrong kind or text.
    """
    assert_true(_get_kind[T](row, col) == PgErrorKind.TYPE_MISMATCH)
    var message = _get_message[T](row, col)
    assert_true("oid " in message)
    assert_true("ResultFormat.TEXT" in message)


# --- the ResultFormat type itself --------------------------------------------


def test_result_format_constants_and_equality() raises:
    assert_equal(ResultFormat.TEXT.value, 0)
    assert_equal(ResultFormat.BINARY.value, 1)
    assert_equal(String(ResultFormat.TEXT), "Text")
    assert_equal(String(ResultFormat.BINARY), "Binary")
    assert_true(ResultFormat.TEXT != ResultFormat.BINARY)
    assert_false(ResultFormat.TEXT == ResultFormat.BINARY)
    assert_true(ResultFormat.TEXT == ResultFormat.TEXT)
    assert_true(ResultFormat.BINARY == ResultFormat.BINARY)


# --- column_format reports the format of the whole result --------------------


def test_column_format_defaults_to_text() raises:
    var conn = _connect(_conninfo())

    # The parameterless overload has no `result_format` argument at all.
    var unary = _execute(conn, "SELECT 1::int4, 'a'::text")
    assert_equal(unary.column_count(), 2)
    assert_true(_column_format(unary, 0) == ResultFormat.TEXT)
    assert_true(_column_format(unary, 1) == ResultFormat.TEXT)
    _ = unary^

    # The parameterized overload defaults to text when the caller says
    # nothing, so binary is never reached by accident.
    var defaulted = _execute_params(
        conn, "SELECT 1::int4, 'a'::text", List[Param]()
    )
    assert_equal(defaulted.column_count(), 2)
    assert_true(_column_format(defaulted, 0) == ResultFormat.TEXT)
    assert_true(_column_format(defaulted, 1) == ResultFormat.TEXT)
    _ = defaulted^

    _ = conn^


def test_column_format_is_binary_for_every_column() raises:
    var conn = _connect(_conninfo())
    var result = _execute_fmt(conn, String(SCALARS_SQL), ResultFormat.BINARY)

    # The format is requested for the result as a whole, so there is no
    # mixed-format result to describe: all fourteen columns are binary.
    var ncols = result.column_count()
    assert_equal(ncols, 14)
    for i in range(ncols):
        assert_true(_column_format(result, i) == ResultFormat.BINARY)

    # Asking about a column that does not exist is a type mismatch, the same
    # rejection every other out-of-range column lookup gives.
    assert_true(_column_format_kind(result, ncols) == PgErrorKind.TYPE_MISMATCH)

    _ = result^
    _ = conn^


# --- binary values equal text values -----------------------------------------


def test_binary_scalars_match_text() raises:
    var conn = _connect(_conninfo())
    var in_text = _execute(conn, String(SCALARS_SQL))
    var in_binary = _execute_fmt(conn, String(SCALARS_SQL), ResultFormat.BINARY)

    # The two results describe the same columns; only the wire format differs.
    assert_equal(in_text.column_count(), in_binary.column_count())
    assert_equal(_column_type_oid(in_binary, 0), UInt32(16))
    assert_equal(_column_type_oid(in_binary, 2), UInt32(21))
    assert_equal(_column_type_oid(in_binary, 3), UInt32(23))
    assert_equal(_column_type_oid(in_binary, 4), UInt32(20))
    assert_equal(_column_type_oid(in_binary, 5), UInt32(700))
    assert_equal(_column_type_oid(in_binary, 6), UInt32(701))
    assert_equal(_column_type_oid(in_binary, 7), UInt32(25))
    assert_equal(_column_type_oid(in_binary, 9), UInt32(1043))
    assert_equal(_column_type_oid(in_binary, 10), UInt32(1042))
    assert_equal(_column_type_oid(in_binary, 11), UInt32(19))
    assert_equal(_column_type_oid(in_binary, 12), UInt32(17))

    var t = _row(in_text, 0)
    var b = _row(in_binary, 0)

    assert_equal(_get[Bool](b, 0), _get[Bool](t, 0))
    assert_true(_get[Bool](b, 0))
    assert_equal(_get[Bool](b, 1), _get[Bool](t, 1))
    assert_false(_get[Bool](b, 1))

    assert_equal(_get[Int16](b, 2), _get[Int16](t, 2))
    assert_equal(_get[Int16](b, 2), Int16(1))
    assert_equal(_get[Int32](b, 3), _get[Int32](t, 3))
    assert_equal(_get[Int32](b, 3), Int32(2))
    assert_equal(_get[Int64](b, 4), _get[Int64](t, 4))
    assert_equal(_get[Int64](b, 4), Int64(3))
    assert_equal(_get[Int](b, 4), _get[Int](t, 4))
    assert_equal(_get[Int](b, 4), 3)

    assert_equal(_get[Float32](b, 5), _get[Float32](t, 5))
    assert_equal(_get[Float32](b, 5), Float32(1.5))
    assert_equal(_get[Float64](b, 6), _get[Float64](t, 6))
    assert_equal(_get[Float64](b, 6), Float64(2.5))

    # `héllo` is five characters in six bytes, so a byte-for-byte equal
    # decode is the only way both formats can agree here.
    var hello = _get[String](b, 7)
    assert_equal(hello, _get[String](t, 7))
    assert_equal(hello, "héllo")
    assert_equal(hello.byte_length(), 6)

    # The empty string is a value, not a NULL, in either format.
    assert_equal(_get[String](b, 8), _get[String](t, 8))
    assert_equal(_get[String](b, 8), "")
    assert_false(_is_null(b, 8))

    assert_equal(_get[String](b, 9), _get[String](t, 9))
    assert_equal(_get[String](b, 9), "x")

    # `char(5)` is blank-padded by the server, binary format included.
    assert_equal(_get[String](b, 10), _get[String](t, 10))
    assert_equal(_get[String](b, 10), "ab   ")

    assert_equal(_get[String](b, 11), _get[String](t, 11))
    assert_equal(_get[String](b, 11), "n")

    var expected_bytes: List[UInt8] = [0, 255, 0]
    _assert_bytes(_get[List[UInt8]](b, 12), expected_bytes)
    _assert_bytes(_get[List[UInt8]](b, 12), _get[List[UInt8]](t, 12))
    var no_bytes = List[UInt8]()
    _assert_bytes(_get[List[UInt8]](b, 13), no_bytes)
    _assert_bytes(_get[List[UInt8]](b, 13), _get[List[UInt8]](t, 13))

    _ = b^
    _ = t^
    _ = in_binary^
    _ = in_text^
    _ = conn^


def test_binary_integer_boundaries_match_text() raises:
    var conn = _connect(_conninfo())
    var in_text = _execute(conn, String(BOUNDARIES_SQL))
    var in_binary = _execute_fmt(
        conn, String(BOUNDARIES_SQL), ResultFormat.BINARY
    )
    var t = _row(in_text, 0)
    var b = _row(in_binary, 0)

    assert_equal(_get[Int16](b, 0), _get[Int16](t, 0))
    assert_equal(_get[Int16](b, 0), Int16(32767))
    assert_equal(_get[Int16](b, 1), _get[Int16](t, 1))
    assert_equal(_get[Int16](b, 1), Int16(-32768))

    assert_equal(_get[Int32](b, 2), _get[Int32](t, 2))
    assert_equal(_get[Int32](b, 2), Int32(2147483647))
    assert_equal(_get[Int32](b, 3), _get[Int32](t, 3))
    assert_equal(_get[Int32](b, 3), Int32(-2147483648))

    assert_equal(_get[Int64](b, 4), _get[Int64](t, 4))
    assert_equal(_get[Int64](b, 4), Int64(9223372036854775807))
    assert_equal(_get[Int64](b, 5), _get[Int64](t, 5))
    assert_equal(_get[Int64](b, 5), Int64(-9223372036854775808))

    _ = b^
    _ = t^
    _ = in_binary^
    _ = in_text^
    _ = conn^


def test_binary_float_special_values_match_text() raises:
    var conn = _connect(_conninfo())
    var in_text = _execute(conn, String(FLOATS_SQL))
    var in_binary = _execute_fmt(conn, String(FLOATS_SQL), ResultFormat.BINARY)
    var t = _row(in_text, 0)
    var b = _row(in_binary, 0)

    # `NaN == NaN` is False, so agreement between the formats is checked with
    # `isnan` on both sides rather than by comparing the two values.
    assert_true(isnan(_get[Float64](t, 0)))
    assert_true(isnan(_get[Float64](b, 0)))
    assert_true(isnan(_get[Float32](t, 5)))
    assert_true(isnan(_get[Float32](b, 5)))

    # Infinities must agree in magnitude *and* sign.
    var t_pos = _get[Float64](t, 1)
    var b_pos = _get[Float64](b, 1)
    assert_true(isinf(t_pos))
    assert_true(isinf(b_pos))
    assert_true(t_pos > 0)
    assert_true(b_pos > 0)

    var t_neg = _get[Float64](t, 2)
    var b_neg = _get[Float64](b, 2)
    assert_true(isinf(t_neg))
    assert_true(isinf(b_neg))
    assert_true(t_neg < 0)
    assert_true(b_neg < 0)

    var t_pos32 = _get[Float32](t, 6)
    var b_pos32 = _get[Float32](b, 6)
    assert_true(isinf(t_pos32))
    assert_true(isinf(b_pos32))
    assert_true(t_pos32 > 0)
    assert_true(b_pos32 > 0)

    var t_neg32 = _get[Float32](t, 7)
    var b_neg32 = _get[Float32](b, 7)
    assert_true(isinf(t_neg32))
    assert_true(isinf(b_neg32))
    assert_true(t_neg32 < 0)
    assert_true(b_neg32 < 0)

    # `-0.0 == 0.0` is True, so the sign bit is read off `1.0 / x`, which is
    # `-inf` for a negative zero and `+inf` for a positive one.
    var t_zero = _get[Float64](t, 3)
    var b_zero = _get[Float64](b, 3)
    assert_equal(b_zero, t_zero)
    assert_true(isinf(1.0 / t_zero))
    assert_true(isinf(1.0 / b_zero))
    assert_true(1.0 / t_zero < 0)
    assert_true(1.0 / b_zero < 0)

    var t_zero32 = _get[Float32](t, 8)
    var b_zero32 = _get[Float32](b, 8)
    assert_equal(b_zero32, t_zero32)
    assert_true(isinf(Float32(1.0) / t_zero32))
    assert_true(isinf(Float32(1.0) / b_zero32))
    assert_true(Float32(1.0) / t_zero32 < 0)
    assert_true(Float32(1.0) / b_zero32 < 0)

    # The text spelling is `1e+300`, which no binary payload resembles, yet
    # both decode to the same `Float64`.
    assert_equal(_get[Float64](b, 4), _get[Float64](t, 4))
    assert_equal(_get[Float64](b, 4), Float64(1e300))

    _ = b^
    _ = t^
    _ = in_binary^
    _ = in_text^
    _ = conn^


# --- the other two execute entry points --------------------------------------


def test_prepared_statement_executes_in_binary() raises:
    var conn = _connect(_conninfo())
    var stmt = _prepare(conn, "SELECT $1::int4")
    var params: List[Param] = [Int32(7)]

    var result = _stmt_execute_fmt(stmt, params, ResultFormat.BINARY)
    assert_true(_column_format(result, 0) == ResultFormat.BINARY)
    var row = _row(result, 0)
    assert_equal(_get[Int32](row, 0), Int32(7))
    _ = row^
    _ = result^

    # The statement is deallocated right after its last use, so keep it alive
    # until here.
    _ = stmt^
    _ = conn^


def test_transaction_executes_in_binary() raises:
    var conn = _connect(_conninfo())
    var tx = _transaction(conn)

    var result = _tx_execute_fmt(tx, "SELECT 42::int4", ResultFormat.BINARY)
    assert_true(_column_format(result, 0) == ResultFormat.BINARY)
    var row = _row(result, 0)
    assert_equal(_get[Int32](row, 0), Int32(42))
    _ = row^
    _ = result^

    # The block is ended explicitly so the implicit ROLLBACK at its last use
    # is not what this test depends on.
    _tx_commit(tx)
    _ = tx^
    _ = conn^


# --- OIDs the binary decoder does not support --------------------------------


def test_binary_unsupported_oids_are_type_mismatch() raises:
    var conn = _connect(_conninfo())
    var result = _execute_fmt(
        conn, String(UNSUPPORTED_SQL), ResultFormat.BINARY
    )
    assert_equal(result.column_count(), 7)
    var row = _row(result, 0)

    # Seven columns times three requested types: not one of the twenty-one
    # cells may hand back raw bytes or a reinterpreted value.
    for i in range(7):
        _assert_binary_refusal[String](row, i)
        _assert_binary_refusal[List[UInt8]](row, i)
        _assert_binary_refusal[Int32](row, i)

    _ = row^
    _ = result^
    _ = conn^


def test_text_reads_every_unsupported_oid_as_string() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, String(UNSUPPORTED_SQL))
    assert_equal(result.column_count(), 7)
    var row = _row(result, 0)

    # In text format `String` accepts any OID, so re-running the same SQL in
    # text is the documented way out of the refusals above. The rendered text
    # is locale- and version-sensitive, so only its presence is asserted.
    for i in range(7):
        assert_true(_get[String](row, i) != "")

    _ = row^
    _ = result^
    _ = conn^


# --- results that carry no column data ---------------------------------------


def test_binary_zero_row_result() raises:
    var conn = _connect(_conninfo())
    var result = _execute_fmt(conn, "SELECT 1 WHERE false", ResultFormat.BINARY)
    assert_equal(result.row_count(), 0)
    _ = result^
    _ = conn^


def test_binary_format_is_accepted_by_ddl_and_insert() raises:
    var conn = _connect(_conninfo())

    # A binary request on a statement that returns no columns is not an
    # error: the server simply has nothing to format.
    #
    # TEMP keeps the table inside this session, so a parallel test process or
    # a second server version never collides on the name.
    var created = _execute_fmt(
        conn, "CREATE TEMP TABLE pq_p3_bin(x int)", ResultFormat.BINARY
    )
    assert_equal(created.command_tag(), "CREATE TABLE")
    _ = created^

    var inserted = _execute_fmt(
        conn, "INSERT INTO pq_p3_bin VALUES (1)", ResultFormat.BINARY
    )
    assert_equal(inserted.command_tag(), "INSERT 0 1")
    _ = inserted^

    _ = conn^


# --- NULL in binary format ---------------------------------------------------


def test_binary_null_column() raises:
    var conn = _connect(_conninfo())
    var result = _execute_fmt(conn, "SELECT NULL::int4", ResultFormat.BINARY)
    var row = _row(result, 0)

    # A NULL has no payload in either format, so the three NULL accessors
    # behave exactly as they do for a text result.
    assert_true(_get_kind[Int32](row, 0) == PgErrorKind.NULL_VALUE)
    assert_false(Bool(_get_optional[Int32](row, 0)))
    assert_true(_is_null(row, 0))

    _ = row^
    _ = result^
    _ = conn^


# --- a binary execute on a connection that is already gone -------------------


def test_terminated_backend_then_binary_connection_error() raises:
    var conn = _connect(_conninfo())

    # Measured on PG14 and PG17: libpq never delivers the server's FATAL
    # 57P01 here. The socket closes first, so `PQexecParams` yields a
    # client-side PGRES_FATAL_ERROR carrying no SQLSTATE.
    #
    # Which kind that first failure is reported as is the one place this
    # test tolerates two answers -- CONNECTION once libpq has marked the
    # connection bad, SERVER if the diagnostic arrives before it does. What
    # must never happen is a traceback instead of a `PgError`, and the
    # wrapper returning at all is what proves that.
    var terminated = _execute_error_either_kind(conn, String(TERMINATE_SQL))
    assert_true(terminated.message != "")

    # The binary request is the statement under test: asking for a binary
    # format on a dead connection must fail the same way a text one does,
    # not reach any decoding code.
    var after = _execute_fmt_error(conn, "SELECT 1", ResultFormat.BINARY)
    assert_true(
        after.kind == PgErrorKind.CONNECTION or after.kind == PgErrorKind.SERVER
    )
    assert_true(after.message != "")

    _ = conn^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
