"""Tests for the zero-copy accessors `Row.get_text` / `Row.get_bytes`.

Both hand back a view of the `PGresult`'s own storage instead of a copy, so
what has to be asserted is not just "the right bytes" but "the right bytes,
read without copying, and still readable where the docstring promises they
are":

* `get_text(i)` agrees with `get[String](i)` -- the owning accessor -- on
  every column it accepts, in both wire formats. That is the whole contract
  for the happy path: same bytes, no allocation.
* `get_bytes(i)` is the one accessor that reads the region **as it is**,
  whatever the OID. A `bytea` therefore reads as the eight bytes of the text
  `\\x00ff00` in text format and as the three bytes `00 ff 00` in binary,
  and both are correct.
* A slice outlives `_ = result^`. That marker is a keep-alive, not a destroy,
  and the slice stays readable after it; the compile-time half of the same
  rule -- a slice used after `var moved = result^` failing to compile -- is
  measured by the negative controls under
  `.gsd-lite/logs/phase3-binary-all-types/scratch/`, because a test that does
  not compile cannot live in this suite.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI), falling back to the local container. An unreachable server
fails these tests; it never skips them. Every expected value is identical on
PG14 and PG17, so nothing here branches on `server_version`.
"""

from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_true

from pq.connection import Connection
from pq.errors import PgError, PgErrorKind
from pq.params import Param
from pq.result import Result, ResultFormat, Row

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime TEXT_SQL: StaticString = (
    "SELECT 42::int4, 'héllo'::text, 'ab'::char(5), 1.50::numeric"
)
"""Four columns whose text form `get_text` must hand back unchanged.

Only one of them is string-shaped: in text format `get_text` takes any OID,
exactly as `get[String]` does, so the `int4` and the `numeric` are as much
part of the contract as the `text` is. `'ab'::char(5)` is blank-padded by the
server, and `'héllo'` is six bytes of UTF-8 behind five characters.
"""

comptime BINARY_STRINGS_SQL: StaticString = (
    "SELECT 'héllo'::text, 'x'::varchar, 'ab'::char(5), 'n'::name,"
    " '{\"a\": 1}'::json, '{\"a\": 1}'::jsonb"
)
"""The six string-shaped OIDs, the only ones `get_text` accepts in binary.

The `jsonb` column is the one that is not simply its own bytes: the binary
form opens with a one byte format version, which `get_text` must drop, so
this column is what proves the slice starts at the JSON text.
"""

comptime BYTEA_SQL: StaticString = "SELECT '\\x00ff00'::bytea, ''::bytea"
"""A `bytea` holding a NUL, a high byte and a NUL, and an empty one.

The non-empty value is the reason `get_bytes` cannot use a NUL scan for its
length: the first byte of the binary form ends the string a C API would
return. The empty `bytea` is a value, not a NULL.
"""


# --- helpers -----------------------------------------------------------------
#
# A `TestSuite` test only declares `raises` (plain `Error`), and `PgError` does
# not implicitly convert to `Error`, so a `raises PgError` API cannot be called
# straight from a test. These wrappers translate in both directions: success
# paths re-raise as `Error`, failure paths hand the kind or the message back
# for inspection.
#
# The wrappers that return a view keep the `origin` parameter, so the borrow
# the caller holds is still tied to the result it came from and the compiler
# still rejects a use after the result is moved away.


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


def _row(result: Result, i: Int) raises -> Row[origin_of(result)]:
    """Return row `i` of `result`.

    Args:
        result: The result to index.
        i: Zero-based row index.

    Returns:
        The row at that index, as a view onto the result.

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
    """Read column `col` of `row` as an owned `T`.

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


def _get_text[
    origin: ImmOrigin, //
](row: Row[origin], col: Int) raises -> StringSlice[origin]:
    """Read column `col` of `row` as a borrowed slice.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.

    Args:
        row: The row to read.
        col: Zero-based column index.

    Returns:
        A slice over the cell's bytes, still bound to the result's origin.

    Raises:
        Error: If `Row.get_text` raised a `PgError`.
    """
    try:
        return row.get_text(col)
    except e:
        raise Error(String(e))


def _get_bytes[
    origin: ImmOrigin, //
](row: Row[origin], col: Int) raises -> Span[UInt8, origin]:
    """Read column `col` of `row` as a borrowed span of bytes.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.

    Args:
        row: The row to read.
        col: Zero-based column index.

    Returns:
        A span over the cell's bytes, still bound to the result's origin.

    Raises:
        Error: If `Row.get_bytes` raised a `PgError`.
    """
    try:
        return row.get_bytes(col)
    except e:
        raise Error(String(e))


def _get_text_error[
    origin: ImmOrigin, //
](row: Row[origin], col: Int) raises -> PgError:
    """Return the `PgError` raised by `row.get_text(col)`.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.

    Args:
        row: The row to read.
        col: A column index that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `Row.get_text` returned a slice instead of raising.
    """
    try:
        _ = row.get_text(col)
    except e:
        return e.copy()
    raise Error(String("expected a PgError from get_text(", col, ")"))


def _get_bytes_error[
    origin: ImmOrigin, //
](row: Row[origin], col: Int) raises -> PgError:
    """Return the `PgError` raised by `row.get_bytes(col)`.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.

    Args:
        row: The row to read.
        col: A column index that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `Row.get_bytes` returned a span instead of raising.
    """
    try:
        _ = row.get_bytes(col)
    except e:
        return e.copy()
    raise Error(String("expected a PgError from get_bytes(", col, ")"))


def _assert_same_bytes[
    got_origin: ImmOrigin, expected_origin: ImmOrigin, //
](got: Span[UInt8, got_origin], expected: Span[UInt8, expected_origin]) raises:
    """Assert that two byte views have the same length and elements.

    Parameters:
        got_origin: Origin of the bytes under test; inferred.
        expected_origin: Origin of the expected bytes; inferred.

    Args:
        got: The bytes read back.
        expected: The bytes they must equal.

    Raises:
        Error: If the two views differ.
    """
    assert_equal(len(got), len(expected))
    for i in range(len(expected)):
        assert_equal(got[i], expected[i])


# --- get_text agrees with get[String] ----------------------------------------


def test_get_text_matches_get_string_in_text_format() raises:
    var conn = _connect(_conninfo())
    var result = _execute_fmt(conn, String(TEXT_SQL), ResultFormat.TEXT)
    var row = _row(result, 0)

    # In text format the cell *is* its text, so every OID is readable --
    # the int4 and the numeric as much as the text and the bpchar.
    for col in range(result.column_count()):
        assert_equal(String(_get_text(row, col)), _get[String](row, col))

    assert_equal(String(_get_text(row, 0)), "42")
    assert_equal(String(_get_text(row, 1)), "héllo")
    assert_equal(String(_get_text(row, 2)), "ab   ")
    assert_equal(String(_get_text(row, 3)), "1.50")

    _ = row^
    _ = result^
    _ = conn^


def test_get_text_matches_get_string_in_binary_format() raises:
    var conn = _connect(_conninfo())
    var result = _execute_fmt(
        conn, String(BINARY_STRINGS_SQL), ResultFormat.BINARY
    )
    var row = _row(result, 0)

    assert_equal(result.column_count(), 6)
    for col in range(result.column_count()):
        assert_equal(String(_get_text(row, col)), _get[String](row, col))

    assert_equal(String(_get_text(row, 0)), "héllo")
    assert_equal(String(_get_text(row, 1)), "x")
    assert_equal(String(_get_text(row, 2)), "ab   ")
    assert_equal(String(_get_text(row, 3)), "n")
    assert_equal(String(_get_text(row, 4)), '{"a": 1}')

    # The jsonb column is the one whose binary form is not simply its text:
    # dropping the leading format version byte is what makes the slice start
    # at the `{`.
    assert_equal(String(_get_text(row, 5)), '{"a": 1}')

    _ = row^
    _ = result^
    _ = conn^


def test_get_text_agrees_across_the_two_formats() raises:
    var conn = _connect(_conninfo())

    var text_result = _execute_fmt(
        conn, String(BINARY_STRINGS_SQL), ResultFormat.TEXT
    )
    var text_row = _row(text_result, 0)
    var expected = List[String]()
    for col in range(text_result.column_count()):
        expected.append(String(_get_text(text_row, col)))
    _ = text_row^
    _ = text_result^

    var binary_result = _execute_fmt(
        conn, String(BINARY_STRINGS_SQL), ResultFormat.BINARY
    )
    var binary_row = _row(binary_result, 0)
    for col in range(binary_result.column_count()):
        assert_equal(String(_get_text(binary_row, col)), expected[col])

    _ = binary_row^
    _ = binary_result^
    _ = conn^


def test_byte_length_counts_bytes_not_characters() raises:
    var conn = _connect(_conninfo())
    var result = _execute_fmt(conn, String(TEXT_SQL), ResultFormat.TEXT)
    var row = _row(result, 0)

    # `PQgetlength` is the only length involved: five characters of
    # `'héllo'`, six bytes of UTF-8, and the span agrees with the slice.
    assert_equal(_get_text(row, 1).byte_length(), 6)
    assert_equal(len(_get_bytes(row, 1)), 6)
    assert_equal(_get_text(row, 2).byte_length(), 5)

    _ = row^
    _ = result^
    _ = conn^


# --- get_bytes reads the region as it is -------------------------------------


def test_get_bytes_matches_get_list_in_binary_format() raises:
    var conn = _connect(_conninfo())
    var result = _execute_fmt(conn, String(BYTEA_SQL), ResultFormat.BINARY)
    var row = _row(result, 0)

    var owned = _get[List[UInt8]](row, 0)
    _assert_same_bytes(_get_bytes(row, 0), Span[UInt8](owned))

    var expected: List[UInt8] = [0, 255, 0]
    _assert_same_bytes(_get_bytes(row, 0), Span[UInt8](expected))

    var owned_empty = _get[List[UInt8]](row, 1)
    _assert_same_bytes(_get_bytes(row, 1), Span[UInt8](owned_empty))
    assert_equal(len(_get_bytes(row, 1)), 0)

    _ = row^
    _ = result^
    _ = conn^


def test_get_bytes_reads_text_format_bytes_verbatim() raises:
    var conn = _connect(_conninfo())
    var result = _execute_fmt(conn, String(BYTEA_SQL), ResultFormat.TEXT)
    var row = _row(result, 0)

    # In text format a `bytea` arrives as its `\x` hex rendering, and
    # `get_bytes` hands those eight bytes back rather than the three bytes
    # they denote. That is the documented difference from
    # `get[List[UInt8]]`, which decodes the hex.
    var hex_text = String("\\x00ff00")
    _assert_same_bytes(_get_bytes(row, 0), hex_text.as_bytes())
    assert_equal(len(_get_bytes(row, 0)), 8)

    var decoded = _get[List[UInt8]](row, 0)
    var expected: List[UInt8] = [0, 255, 0]
    _assert_same_bytes(Span[UInt8](decoded), Span[UInt8](expected))

    var empty_hex = String("\\x")
    _assert_same_bytes(_get_bytes(row, 1), empty_hex.as_bytes())
    assert_equal(len(_get_bytes(row, 1)), 2)

    _ = row^
    _ = result^
    _ = conn^


def test_get_bytes_takes_any_oid_in_either_format() raises:
    var conn = _connect(_conninfo())

    var text_result = _execute_fmt(conn, String(TEXT_SQL), ResultFormat.TEXT)
    var text_row = _row(text_result, 0)
    var digits = String("42")
    _assert_same_bytes(_get_bytes(text_row, 0), digits.as_bytes())
    _ = text_row^
    _ = text_result^

    # The same int4 column in binary format: four big-endian bytes, and
    # `get_bytes` reads them where `get_text` refuses the OID.
    var binary_result = _execute_fmt(
        conn, String(TEXT_SQL), ResultFormat.BINARY
    )
    var binary_row = _row(binary_result, 0)
    var wire: List[UInt8] = [0, 0, 0, 42]
    _assert_same_bytes(_get_bytes(binary_row, 0), Span[UInt8](wire))
    _ = binary_row^
    _ = binary_result^
    _ = conn^


# --- the rejections ----------------------------------------------------------


def test_binary_non_string_oid_get_text_is_type_mismatch() raises:
    var conn = _connect(_conninfo())
    var result = _execute_fmt(conn, String(TEXT_SQL), ResultFormat.BINARY)
    var row = _row(result, 0)

    var int4 = _get_text_error(row, 0)
    assert_equal(int4.kind, PgErrorKind.TYPE_MISMATCH)
    assert_true(int4.message.find("oid 23") >= 0)
    assert_true(int4.message.find("ResultFormat.TEXT") >= 0)

    var numeric = _get_text_error(row, 3)
    assert_equal(numeric.kind, PgErrorKind.TYPE_MISMATCH)
    assert_true(numeric.message.find("oid 1700") >= 0)
    assert_true(numeric.message.find("ResultFormat.TEXT") >= 0)

    # The same columns are readable the moment the format is text: the
    # message names the fallback that works.
    assert_equal(String(_get_text(row, 1)), "héllo")

    _ = row^
    _ = result^
    _ = conn^


def test_null_cell_raises_null_value() raises:
    var conn = _connect(_conninfo())
    var result = _execute_fmt(conn, "SELECT NULL::text", ResultFormat.TEXT)
    var row = _row(result, 0)

    # libpq reports both a SQL NULL and an empty value as zero bytes, so a
    # zero-length slice would be ambiguous; both accessors raise instead.
    var text_error = _get_text_error(row, 0)
    assert_equal(text_error.kind, PgErrorKind.NULL_VALUE)
    assert_true(text_error.message.find("is NULL") >= 0)

    var bytes_error = _get_bytes_error(row, 0)
    assert_equal(bytes_error.kind, PgErrorKind.NULL_VALUE)
    assert_true(bytes_error.message.find("is NULL") >= 0)

    _ = row^
    _ = result^
    _ = conn^


def test_out_of_range_column_is_type_mismatch() raises:
    var conn = _connect(_conninfo())
    var result = _execute_fmt(conn, String(TEXT_SQL), ResultFormat.TEXT)
    var row = _row(result, 0)
    var ncols = result.column_count()

    for col in [-1, ncols, ncols + 7]:
        assert_equal(_get_text_error(row, col).kind, PgErrorKind.TYPE_MISMATCH)
        assert_equal(_get_bytes_error(row, col).kind, PgErrorKind.TYPE_MISMATCH)

    _ = row^
    _ = result^
    _ = conn^


# --- the lifetime the docstring promises -------------------------------------


def test_slice_survives_a_keep_alive_marker() raises:
    var conn = _connect(_conninfo())
    var result = _execute_fmt(conn, String(TEXT_SQL), ResultFormat.TEXT)
    var row = _row(result, 0)

    var slice = _get_text(row, 1)
    var span = _get_bytes(row, 1)

    # `_ = result^` is a keep-alive marker, not a destroy: `PQclear` runs
    # after the last use of anything borrowed from the result, which is the
    # assertions below. The consuming form -- `var moved = result^` -- is a
    # compile error here instead, measured by the negative controls in
    # `.gsd-lite/logs/phase3-binary-all-types/scratch/`.
    _ = row^
    _ = result^

    assert_equal(String(slice), "héllo")
    assert_equal(slice.byte_length(), 6)
    assert_equal(len(span), 6)
    assert_equal(span[0], UInt8(ord("h")))

    _ = conn^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
