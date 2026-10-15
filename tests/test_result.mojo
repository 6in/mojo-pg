"""Tests for row-level access to a `pq.result.Result` against a live server.

Covers `Result` iteration and indexing plus `Row.get`, `Row.get_optional` and
`Row.is_null`: the exact-OID decoding rules seen through a real result, a SQL
NULL versus the empty string, and every index or name that must be rejected.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI), falling back to the local container. An unreachable server
fails these tests; it never skips them.

Every test must pass against both PG14 and PG17, so nothing here asserts a
column *name* that the query did not alias: PG17 reports `?column?` where PG14
reports `bool` for a bare `true`. Type OIDs and values are identical across
both versions, and those are what these tests assert.
"""

from std.math import isinf, isnan
from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pq.connection import Connection
from pq.errors import PgErrorKind
from pq.result import Result, Row

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime ACCEPTANCE_SQL: StaticString = (
    "SELECT 1::int4, 'a'::text, NULL::int4, true, 1.5::float8, '\\x0102'::bytea"
)
"""One row touching every Mojo type `Row.get` supports."""

comptime SCALARS_SQL: StaticString = (
    "SELECT 1::int2, 1::int8, 1.5::float4, 'x'::varchar,"
    " 'ab'::char(5), 'n'::name, 12.5::numeric"
)
"""One row of the remaining numeric and string-like PostgreSQL types."""

comptime FLOATS_SQL: StaticString = (
    "SELECT 'NaN'::float8, 'Infinity'::float4, '-Infinity'::float8"
)
"""The three non-finite floating point values PostgreSQL can return."""

comptime BOUNDARIES_SQL: StaticString = (
    "SELECT 2147483647::int4, (-2147483648)::int4, 32767::int2, (-32768)::int2"
)
"""The extremes of `int4` and `int2`.

The negative literals are parenthesized on purpose: `::` binds tighter than
unary minus, so `-2147483648::int4` casts the *positive* literal and the
server answers `ERROR: integer out of range` (measured on PG14 and PG17).
"""


# --- helpers -----------------------------------------------------------------
#
# A `TestSuite` test only declares `raises` (plain `Error`), and `PgError` does
# not implicitly convert to `Error`, so a `raises PgError` API cannot be called
# straight from a test. These wrappers translate in both directions: success
# paths re-raise as `Error`, failure paths hand the `PgError`'s kind back for
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
    """Run `sql` on `conn`.

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


def _row_kind(result: Result, i: Int) raises -> PgErrorKind:
    """Return the kind of the `PgError` raised by `result[i]`.

    Args:
        result: The result to index.
        i: A row index that must be rejected.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If `result[i]` returned a row instead of raising.
    """
    try:
        _ = result[i]
    except e:
        return e.kind
    raise Error(String("expected a PgError from result[", i, "]"))


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


def _get_by_name[
    origin: ImmOrigin, //, T: Copyable & Deinitable
](row: Row[origin], name: String) raises -> T:
    """Read the column called `name` of `row` as `T`.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.
        T: The Mojo type requested from `Row.get`.

    Args:
        row: The row to read.
        name: The column name to look up.

    Returns:
        The decoded value.

    Raises:
        Error: If `Row.get` raised a `PgError`.
    """
    try:
        return row.get[T](name)
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


def _get_by_name_kind[
    origin: ImmOrigin, //, T: Copyable & Deinitable
](row: Row[origin], name: String) raises -> PgErrorKind:
    """Return the kind of the `PgError` raised by `row.get[T](name)`.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.
        T: The Mojo type requested from `Row.get`.

    Args:
        row: The row to read.
        name: A column name that must be rejected.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If `Row.get` returned a value instead of raising.
    """
    try:
        _ = row.get[T](name)
    except e:
        return e.kind
    raise Error(String("expected a PgError from get(", name, ")"))


def _get_optional_by_name_kind[
    origin: ImmOrigin, //, T: Copyable & Deinitable
](row: Row[origin], name: String) raises -> PgErrorKind:
    """Return the kind of the `PgError` raised by `get_optional[T](name)`.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.
        T: The Mojo type requested from `Row.get_optional`.

    Args:
        row: The row to read.
        name: A column name that must be rejected.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If `Row.get_optional` returned a value instead of raising.
    """
    try:
        _ = row.get_optional[T](name)
    except e:
        return e.kind
    raise Error(String("expected a PgError from get_optional(", name, ")"))


def _get_optional_by_name[
    origin: ImmOrigin, //, T: Copyable & Deinitable
](row: Row[origin], name: String) raises -> Optional[T]:
    """Read the column called `name` of `row` as an optional `T`.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.
        T: The Mojo type requested from `Row.get_optional`.

    Args:
        row: The row to read.
        name: The column name to look up.

    Returns:
        The decoded value, or `None` for a SQL NULL.

    Raises:
        Error: If `Row.get_optional` raised a `PgError`.
    """
    try:
        return row.get_optional[T](name)
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


def _column_index(result: Result, name: String) raises -> Int:
    """Return the index of the column called `name`.

    Args:
        result: The result to inspect.
        name: The column name to look up.

    Returns:
        The zero-based column index.

    Raises:
        Error: If `column_index` raised a `PgError`.
    """
    try:
        return result.column_index(name)
    except e:
        raise Error(String(e))


def _column_index_kind(result: Result, name: String) raises -> PgErrorKind:
    """Return the kind of the `PgError` raised by `column_index(name)`.

    Args:
        result: The result to inspect.
        name: A column name that must be rejected.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If `column_index` returned an index instead of raising.
    """
    try:
        _ = result.column_index(name)
    except e:
        return e.kind
    raise Error(String("expected a PgError from column_index(", name, ")"))


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


# --- the acceptance query ----------------------------------------------------


def test_acceptance_query_values() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, String(ACCEPTANCE_SQL))
    assert_equal(result.row_count(), 1)
    assert_equal(result.column_count(), 6)

    var row = _row(result, 0)
    assert_equal(_get[Int32](row, 0), Int32(1))
    assert_equal(_get[String](row, 1), "a")

    # Column 2 is a SQL NULL: `get` refuses it, `get_optional` reports it.
    assert_true(_get_kind[Int32](row, 2) == PgErrorKind.NULL_VALUE)
    assert_false(Bool(_get_optional[Int32](row, 2)))
    assert_true(_is_null(row, 2))
    assert_false(_is_null(row, 0))

    assert_true(_get[Bool](row, 3))
    assert_equal(_get[Float64](row, 4), Float64(1.5))
    var expected: List[UInt8] = [1, 2]
    _assert_bytes(_get[List[UInt8]](row, 5), expected)

    _ = row^
    _ = result^
    _ = conn^


def test_acceptance_query_column_type_oids() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, String(ACCEPTANCE_SQL))
    assert_equal(_column_type_oid(result, 0), UInt32(23))
    assert_equal(_column_type_oid(result, 1), UInt32(25))
    assert_equal(_column_type_oid(result, 2), UInt32(23))
    assert_equal(_column_type_oid(result, 3), UInt32(16))
    assert_equal(_column_type_oid(result, 4), UInt32(701))
    assert_equal(_column_type_oid(result, 5), UInt32(17))
    _ = result^
    _ = conn^


# --- NULL versus the empty string --------------------------------------------


def test_null_text_differs_from_empty_text() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, "SELECT NULL::text, ''::text")
    var row = _row(result, 0)

    assert_false(Bool(_get_optional[String](row, 0)))

    # The empty string is a value, not a NULL.
    var present = _get_optional[String](row, 1)
    assert_true(Bool(present))
    assert_equal(present.value(), "")

    _ = row^
    _ = result^
    _ = conn^


# --- column names ------------------------------------------------------------


def test_column_index_folds_unquoted_names() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, 'SELECT 1 AS FOO, 2 AS "BAR"')

    # `FOO` was unquoted, so the server folded it to `foo` and the lookup
    # folds too: both spellings find column 0.
    assert_equal(_column_index(result, "FOO"), 0)
    assert_equal(_column_index(result, "foo"), 0)

    # `"BAR"` kept its case in the query, so it is only found when quoted
    # here as well.
    assert_true(_column_index_kind(result, "BAR") == PgErrorKind.TYPE_MISMATCH)
    assert_equal(_column_index(result, '"BAR"'), 1)

    var row = _row(result, 0)
    assert_equal(_get_by_name[Int32](row, "foo"), Int32(1))

    _ = row^
    _ = result^
    _ = conn^


def test_name_lookup_in_get_and_get_optional() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, "SELECT 's'::text AS s, NULL::text AS n")
    var row = _row(result, 0)

    # Both name overloads go through `column_index`, so an unknown name is a
    # TYPE_MISMATCH rather than an out-of-range index error.
    assert_true(
        _get_by_name_kind[Int32](row, "nope") == PgErrorKind.TYPE_MISMATCH
    )
    assert_true(
        _get_optional_by_name_kind[Int32](row, "nope")
        == PgErrorKind.TYPE_MISMATCH
    )

    # A name that does resolve reads the same value the index overload does,
    # including the NULL case.
    var present = _get_optional_by_name[String](row, "s")
    assert_true(Bool(present))
    assert_equal(present.value(), "s")
    assert_false(Bool(_get_optional_by_name[String](row, "n")))

    _ = row^
    _ = result^
    _ = conn^


# --- the remaining scalar types ----------------------------------------------


def test_more_scalar_types_decode() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, String(SCALARS_SQL))
    var row = _row(result, 0)

    assert_equal(_get[Int16](row, 0), Int16(1))
    assert_equal(_get[Int64](row, 1), Int64(1))
    assert_equal(_get[Int](row, 1), 1)
    assert_equal(_get[Float32](row, 2), Float32(1.5))

    # `String` accepts any OID: varchar, bpchar, name and numeric alike.
    assert_equal(_get[String](row, 3), "x")
    # `char(5)` is blank-padded by PostgreSQL, text format included.
    assert_equal(_get[String](row, 4), "ab   ")
    assert_equal(_get[String](row, 5), "n")
    assert_equal(_get[String](row, 6), "12.5")

    _ = row^
    _ = result^
    _ = conn^


def test_oid_match_is_exact_with_no_widening() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, String(SCALARS_SQL))
    assert_equal(_column_type_oid(result, 3), UInt32(1043))
    assert_equal(_column_type_oid(result, 4), UInt32(1042))
    assert_equal(_column_type_oid(result, 5), UInt32(19))
    assert_equal(_column_type_oid(result, 6), UInt32(1700))

    var row = _row(result, 0)
    # numeric is OID 1700, never float8's 701.
    assert_true(_get_kind[Float64](row, 6) == PgErrorKind.TYPE_MISMATCH)
    # An int2 column never widens into `Int32`.
    assert_true(_get_kind[Int32](row, 0) == PgErrorKind.TYPE_MISMATCH)

    _ = row^
    _ = result^
    _ = conn^


# --- non-finite floats and integer extremes ----------------------------------


def test_float_special_values() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, String(FLOATS_SQL))
    var row = _row(result, 0)

    assert_true(isnan(_get[Float64](row, 0)))

    var positive = _get[Float32](row, 1)
    assert_true(isinf(positive))
    assert_true(positive > 0)

    var negative = _get[Float64](row, 2)
    assert_true(isinf(negative))
    assert_true(negative < 0)

    _ = row^
    _ = result^
    _ = conn^


def test_integer_boundaries_decode_exactly() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, String(BOUNDARIES_SQL))
    var row = _row(result, 0)

    assert_equal(_get[Int32](row, 0), Int32(2147483647))
    assert_equal(_get[Int32](row, 1), Int32(-2147483648))
    assert_equal(_get[Int16](row, 2), Int16(32767))
    assert_equal(_get[Int16](row, 3), Int16(-32768))

    _ = row^
    _ = result^
    _ = conn^


# --- bytea in escape format --------------------------------------------------


def test_bytea_escape_output_is_rejected() raises:
    var conn = _connect(_conninfo())

    # Only the hex format `\x...` is accepted, so a server configured to send
    # the escape format is a type mismatch rather than a silent misread.
    var command = _execute(conn, "SET bytea_output = 'escape'")
    _ = command^

    var result = _execute(conn, "SELECT '\\x00'::bytea")
    assert_equal(_column_type_oid(result, 0), UInt32(17))
    var row = _row(result, 0)
    assert_true(_get_kind[List[UInt8]](row, 0) == PgErrorKind.TYPE_MISMATCH)

    _ = row^
    _ = result^
    _ = conn^


# --- iteration and indexing --------------------------------------------------


def test_iteration_yields_every_row() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, "SELECT generate_series(1, 5)")
    assert_equal(len(result), 5)

    var total = Int32(0)
    for row in result:
        total += _get[Int32](row, 0)
    assert_equal(total, Int32(15))

    var last = _row(result, 4)
    assert_equal(_get[Int32](last, 0), Int32(5))

    _ = last^
    _ = result^
    _ = conn^


def test_row_index_out_of_range_is_rejected() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, "SELECT generate_series(1, 5)")
    assert_true(_row_kind(result, 5) == PgErrorKind.TYPE_MISMATCH)
    assert_true(_row_kind(result, -1) == PgErrorKind.TYPE_MISMATCH)
    _ = result^
    _ = conn^


def test_column_index_out_of_range_is_rejected() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, "SELECT generate_series(1, 5)")
    var row = _row(result, 0)
    assert_true(_get_kind[Int32](row, 1) == PgErrorKind.TYPE_MISMATCH)
    _ = row^
    _ = result^
    _ = conn^


def test_zero_row_result_iterates_zero_times() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, "SELECT 1 WHERE false")
    var seen = 0
    for _ in result:
        seen += 1
    assert_equal(seen, 0)
    _ = result^
    _ = conn^


# --- the command tag ---------------------------------------------------------


def test_command_tag_reports_the_server_tag() raises:
    var conn = _connect(_conninfo())

    var selected = _execute(conn, "SELECT 1")
    assert_equal(selected.command_tag(), "SELECT 1")
    _ = selected^

    # TEMP keeps the table inside this session, so a parallel test process or
    # a second server version never collides on the name.
    var created = _execute(conn, "CREATE TEMP TABLE pq_p2_tag(x int)")
    assert_equal(created.command_tag(), "CREATE TABLE")
    _ = created^

    var inserted = _execute(conn, "INSERT INTO pq_p2_tag VALUES (1),(2)")
    assert_equal(inserted.command_tag(), "INSERT 0 2")
    _ = inserted^

    var updated = _execute(conn, "UPDATE pq_p2_tag SET x = 0 WHERE false")
    assert_equal(updated.command_tag(), "UPDATE 0")
    _ = updated^

    _ = conn^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
