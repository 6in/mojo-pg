"""Tests for `numeric`, `uuid`, `json` and `jsonb` against a live server.

Covers the four non-temporal extended types end to end: every value is read
back from a real PostgreSQL in *both* wire formats and the two readings must
agree, and every value is also sent back as a parameter and read again.

Four properties are asserted throughout:

* Binary and text decode to the same value. The same SQL is run twice, once
  with `ResultFormat.BINARY` and once with `ResultFormat.TEXT`, and the two
  `get[T]` results must be `==` *and* render to the same `String`.
* `Decimal.__eq__` ignores the display scale, so `1.0 == 1.00`, and it treats
  the special values the way `numeric` does rather than the way IEEE 754
  does: `NaN == NaN` and `Infinity == Infinity`. The three server-side
  comparisons are run alongside and must give the same answers.
* A binary `numeric` infinity arrives with a dscale of 32 in its header --
  a quirk of the short header encoding -- but the decoder reads only the
  sign, so the decoded value has `dscale() == 0`, renders as `Infinity` or
  `-Infinity` and reports `is_infinite()`. That is checked by comparing
  *values*, never by comparing wire bytes.
* `jsonb` is normalised by the server in both formats alike -- keys sorted,
  duplicate keys resolved last-one-wins, `": "` between key and value -- so
  `get[String]` returns the same normalised text either way. `json` keeps
  the raw input text instead.

Binary decoding never falls back to raw bytes: an OID the binary decoder
does not accept for the requested type is a `TYPE_MISMATCH` naming the OID
and pointing at `ResultFormat.TEXT`.

There is no test here that sends malformed binary to the server. `Decimal`
and `UUID` validate at construction time, so neither can be built into a
parameter the server would reject with `22P03` or `08P01`; the server-side
checks on hand-rolled bytes belong to the encoder unit tests.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI), falling back to the local container. An unreachable
server fails these tests; it never skips them.

Every expected value below was measured with `psql` on both PG14 and PG17
and is identical there, so nothing in this file branches on the server
version.
"""

from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_true

from pq.connection import Connection
from pq.errors import PgError, PgErrorKind
from pq.params import Param
from pq.result import Result, ResultFormat, Row
from pq.types_numeric import Decimal
from pq.types_uuid import UUID

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime OID_JSON = UInt32(114)
comptime OID_NUMERIC = UInt32(1700)
comptime OID_UUID = UInt32(2950)
comptime OID_JSONB = UInt32(3802)

comptime NUMERIC_SQL: StaticString = (
    "SELECT 1.50::numeric, (-0.001)::numeric, 0::numeric,"
    " 0.000001::numeric, 1e130::numeric, 1e-10::numeric, 0.00::numeric,"
    " 1000000::numeric, 12345678.9::numeric, 'NaN'::numeric,"
    " 'Infinity'::numeric, '-Infinity'::numeric, '-0'::numeric,"
    " 123456789012345678901234567890.123456789::numeric,"
    " 10000::numeric, 9999::numeric, 0.0001::numeric,"
    " 1.5::numeric(10,4), 100::numeric(10,0), 0.5::numeric,"
    " (-0.5)::numeric, 12.3400::numeric, (+1)::numeric"
)
"""Every `numeric` value the wire-format survey turned up, in one row.

The negative literals are parenthesized because `::` binds tighter than
unary minus. `1e130` and `1e-10` are written in exponent form on purpose:
the server accepts them and prints them positionally, which is the only
spelling `Decimal` itself reads. `'-0'` is quoted because `numeric` has no
signed zero and the server answers a plain `0`.
"""

comptime NUMERIC_1E130: StaticString = (
    "1"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "00"
)
"""`1e130` as the server prints it: a one and 130 zeroes, never `1e+130`."""

comptime NUMERIC_EQ_SQL: StaticString = (
    "SELECT 1.0::numeric = 1.00::numeric,"
    " 'NaN'::numeric = 'NaN'::numeric,"
    " 'Infinity'::numeric = 'Infinity'::numeric"
)
"""The three comparisons `Decimal.__eq__` is required to reproduce."""

comptime UUID_SQL: StaticString = (
    "SELECT 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid,"
    " '00000000-0000-0000-0000-000000000000'::uuid,"
    " 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid,"
    " upper('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11')::uuid"
)
"""An ordinary UUID, the all-zero and all-one extremes, and an upper-case
input the server stores and prints in lower case."""

comptime JSON_SQL: StaticString = (
    "SELECT '{\"a\":1}'::json,"
    ' \'{"b":2,"a":1,"a":3}\'::jsonb,'
    " 'null'::jsonb, '[]'::jsonb, '\"é\"'::jsonb,"
    ' \'{"a":{"b":[1,{"c":null}]}}\'::jsonb'
)
"""One `json` column followed by five `jsonb` columns.

The `json` column keeps its input bytes verbatim. The `jsonb` columns are
re-rendered by the server: the duplicate `a` key resolves to the last one,
the keys come out sorted, and `": "` separates key from value. `'null'` and
`'[]'` are scalars rather than objects, and `'"é"'` is a two-byte UTF-8
character the normalisation leaves alone.
"""

comptime REFUSAL_SQL: StaticString = "SELECT '1.5'::numeric, '{\"a\":1}'::jsonb"
"""A `numeric` and a `jsonb` column to request the wrong Mojo type from."""

comptime UUID_TABLE_SQL: StaticString = (
    "CREATE TEMP TABLE pq_t6_uuid AS SELECT gen_random_uuid() AS u"
)
"""Freeze one server-generated UUID so both formats read the same row.

`gen_random_uuid()` answers differently on every call, so it cannot be
selected twice and compared; TEMP keeps the table inside this session so a
parallel test process or a second server version never collides on the name.
"""


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


def _execute_params_fmt(
    conn: Connection, var sql: String, params: List[Param], fmt: ResultFormat
) raises -> Result:
    """Run `sql` with bound parameters, asking for results in `fmt`.

    The template file has no wrapper that takes parameters *and* a format,
    and every round trip below needs both.

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


def _decimal(text: String) raises -> Decimal:
    """Build a `Decimal` from a caller-written literal.

    Args:
        text: The decimal literal to read.

    Returns:
        The value `text` spells.

    Raises:
        Error: If the `Decimal` constructor raised a `PgError`.
    """
    try:
        return Decimal(text)
    except e:
        raise Error(String(e))


def _uuid(text: String) raises -> UUID:
    """Build a `UUID` from a caller-written literal.

    Args:
        text: The 36-character `8-4-4-4-12` form.

    Returns:
        The parsed `UUID`.

    Raises:
        Error: If the `UUID` constructor raised a `PgError`.
    """
    try:
        return UUID(text)
    except e:
        raise Error(String(e))


def _numeric_text() -> List[StaticString]:
    """Return the text PostgreSQL prints for each column of `NUMERIC_SQL`.

    Measured with `psql -At` on PG14 and PG17; the two agree value for
    value, including the trailing zeroes typmods and literals carry.

    Returns:
        Twenty-three spellings, in the column order of `NUMERIC_SQL`.
    """
    return [
        "1.50",
        "-0.001",
        "0",
        "0.000001",
        NUMERIC_1E130,
        "0.0000000001",
        "0.00",
        "1000000",
        "12345678.9",
        "NaN",
        "Infinity",
        "-Infinity",
        "0",
        "123456789012345678901234567890.123456789",
        "10000",
        "9999",
        "0.0001",
        "1.5000",
        "100",
        "0.5",
        "-0.5",
        "12.3400",
        "1",
    ]


def _assert_numeric_echo(
    conn: Connection, sent: Decimal, expected: String
) raises:
    """Send `sent` to `SELECT $1::numeric` and read it back in both formats.

    The parameter always goes out in binary, since that is the only encoding
    `Param(Decimal)` has; what varies is the format the *result* comes back
    in, and the two must agree with each other and with `sent`.

    Args:
        conn: An open connection.
        sent: The value bound to `$1`.
        expected: The text PostgreSQL prints for the echoed value.

    Raises:
        Error: If the round trip failed or the two formats disagreed.
    """
    var params: List[Param] = [Param(sent)]
    var in_text = _execute_params_fmt(
        conn, "SELECT $1::numeric", params, ResultFormat.TEXT
    )
    var in_binary = _execute_params_fmt(
        conn, "SELECT $1::numeric", params, ResultFormat.BINARY
    )
    var t = _row(in_text, 0)
    var b = _row(in_binary, 0)

    var from_text = _get[Decimal](t, 0)
    var from_binary = _get[Decimal](b, 0)
    assert_true(from_text == sent)
    assert_true(from_binary == sent)
    assert_true(from_binary == from_text)
    assert_equal(String(from_text), expected)
    assert_equal(String(from_binary), expected)

    # The text column renders through `numeric_out` on the server and
    # through `Decimal.write_to` here, and the two must spell it the same.
    assert_equal(_get[String](t, 0), expected)

    # The server echoes an infinity with 32 in the header's dscale field.
    # The decoder reads only the sign, so the value carries dscale 0 and
    # still compares equal to the one that was sent.
    if from_binary.is_infinite():
        assert_equal(from_binary.dscale(), 0)
        assert_equal(from_text.dscale(), 0)

    _ = b^
    _ = t^
    _ = in_binary^
    _ = in_text^


def _assert_uuid_echo(conn: Connection, sent: UUID, expected: String) raises:
    """Send `sent` to `SELECT $1::uuid` and read it back in both formats.

    Args:
        conn: An open connection.
        sent: The value bound to `$1`.
        expected: The lower-case canonical text PostgreSQL prints.

    Raises:
        Error: If the round trip failed or the two formats disagreed.
    """
    var params: List[Param] = [Param(sent)]
    var in_text = _execute_params_fmt(
        conn, "SELECT $1::uuid", params, ResultFormat.TEXT
    )
    var in_binary = _execute_params_fmt(
        conn, "SELECT $1::uuid", params, ResultFormat.BINARY
    )
    var t = _row(in_text, 0)
    var b = _row(in_binary, 0)

    var from_text = _get[UUID](t, 0)
    var from_binary = _get[UUID](b, 0)
    assert_true(from_text == sent)
    assert_true(from_binary == sent)
    assert_true(from_binary == from_text)
    assert_equal(String(from_text), expected)
    assert_equal(String(from_binary), expected)
    assert_equal(_get[String](t, 0), expected)

    _ = b^
    _ = t^
    _ = in_binary^
    _ = in_text^


def _assert_text_echo(
    conn: Connection, var sql: String, sent: String, expected: String
) raises:
    """Send `sent` as a text parameter to `sql` and read it back both ways.

    Used for `json` and `jsonb`, which travel as `String` in both
    directions, so the only thing the two result formats differ in is the
    one-byte `jsonb` version prefix the decoder strips.

    Args:
        conn: An open connection.
        sql: A one-placeholder statement such as `SELECT $1::jsonb`.
        sent: The text bound to `$1`.
        expected: The text PostgreSQL sends back.

    Raises:
        Error: If the round trip failed or the two formats disagreed.
    """
    var params: List[Param] = [Param(sent.copy())]
    var in_text = _execute_params_fmt(
        conn, sql.copy(), params, ResultFormat.TEXT
    )
    var in_binary = _execute_params_fmt(conn, sql^, params, ResultFormat.BINARY)
    var t = _row(in_text, 0)
    var b = _row(in_binary, 0)

    assert_equal(_get[String](t, 0), expected)
    assert_equal(_get[String](b, 0), expected)

    _ = b^
    _ = t^
    _ = in_binary^
    _ = in_text^


def _assert_binary_refusal[
    origin: ImmOrigin, //, T: Copyable & Deinitable
](row: Row[origin], col: Int, oid_text: String) raises:
    """Assert that `row.get[T](col)` refuses a binary column it cannot decode.

    The refusal must be a `TYPE_MISMATCH` whose message names the offending
    OID and points the caller at the text format. Both halves are checked
    with multi-word substrings so that a message which merely happens to
    contain the letter sequence cannot pass.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.
        T: The Mojo type requested from `Row.get`.

    Args:
        row: A row from a binary-format result.
        col: The column index that must be rejected.
        oid_text: The `oid <n>` substring the message must carry.

    Raises:
        Error: If the call succeeded, or failed with the wrong kind or text.
    """
    assert_true(_get_kind[T](row, col) == PgErrorKind.TYPE_MISMATCH)
    var message = _get_message[T](row, col)
    assert_true(oid_text in message)
    assert_true("ResultFormat.TEXT" in message)


# --- numeric read in both formats --------------------------------------------


def test_numeric_binary_matches_text() raises:
    var conn = _connect(_conninfo())
    var in_text = _execute(conn, String(NUMERIC_SQL))
    var in_binary = _execute_fmt(conn, String(NUMERIC_SQL), ResultFormat.BINARY)

    var expected = _numeric_text()
    assert_equal(in_text.column_count(), len(expected))
    assert_equal(in_binary.column_count(), len(expected))

    var t = _row(in_text, 0)
    var b = _row(in_binary, 0)

    for i in range(len(expected)):
        assert_equal(_column_type_oid(in_binary, i), OID_NUMERIC)
        var from_text = _get[Decimal](t, i)
        var from_binary = _get[Decimal](b, i)

        # The decoded values agree, they render the same, and they render
        # what the server itself prints for the column.
        assert_true(from_binary == from_text)
        assert_equal(String(from_binary), String(from_text))
        assert_equal(String(from_binary), String(expected[i]))
        assert_equal(_get[String](t, i), String(from_binary))

        # `dscale` is display-only and so is excluded from `==`; the two
        # formats must still carry the same one.
        assert_equal(from_binary.dscale(), from_text.dscale())

    _ = b^
    _ = t^
    _ = in_binary^
    _ = in_text^
    _ = conn^


def test_numeric_special_values_in_both_formats() raises:
    var conn = _connect(_conninfo())
    var in_text = _execute(conn, String(NUMERIC_SQL))
    var in_binary = _execute_fmt(conn, String(NUMERIC_SQL), ResultFormat.BINARY)
    var t = _row(in_text, 0)
    var b = _row(in_binary, 0)

    # Unlike `float8`, a `numeric` NaN equals itself, so the two formats are
    # compared directly rather than through a predicate.
    var nan_text = _get[Decimal](t, 9)
    var nan_binary = _get[Decimal](b, 9)
    assert_true(nan_text.is_nan())
    assert_true(nan_binary.is_nan())
    assert_true(nan_binary == nan_text)
    assert_equal(String(nan_binary), "NaN")
    assert_equal(nan_binary.dscale(), 0)

    # The binary header of an infinity carries dscale 32, a side effect of
    # the short header encoding. Only the sign is read, so the value that
    # comes out is indistinguishable from the text one.
    var pos_text = _get[Decimal](t, 10)
    var pos_binary = _get[Decimal](b, 10)
    assert_true(pos_text.is_infinite())
    assert_true(pos_binary.is_infinite())
    assert_true(pos_binary == pos_text)
    assert_equal(String(pos_binary), "Infinity")
    assert_equal(pos_binary.dscale(), 0)

    var neg_text = _get[Decimal](t, 11)
    var neg_binary = _get[Decimal](b, 11)
    assert_true(neg_text.is_infinite())
    assert_true(neg_binary.is_infinite())
    assert_true(neg_binary == neg_text)
    assert_equal(String(neg_binary), "-Infinity")
    assert_equal(neg_binary.dscale(), 0)

    # The two infinities are distinct values, and neither is NaN.
    assert_true(pos_binary != neg_binary)
    assert_true(pos_binary != nan_binary)

    # `numeric` has no signed zero, so `'-0'` comes back as a finite zero.
    var zero = _get[Decimal](b, 12)
    assert_true(zero.is_finite())
    assert_equal(String(zero), "0")
    assert_true(zero == _get[Decimal](t, 12))

    _ = b^
    _ = t^
    _ = in_binary^
    _ = in_text^
    _ = conn^


# --- numeric sent back as a parameter ----------------------------------------


def test_numeric_param_roundtrip_in_both_formats() raises:
    var conn = _connect(_conninfo())
    var expected = _numeric_text()

    # Every value the read test covers goes back out as a binary `numeric`
    # parameter and is read again in both formats.
    for i in range(len(expected)):
        var text = String(expected[i])
        _assert_numeric_echo(conn, _decimal(text), text)

    # The three factory values have no literal to parse, so they are sent
    # straight from the constructors.
    _assert_numeric_echo(conn, Decimal.nan(), "NaN")
    _assert_numeric_echo(conn, Decimal.infinity(), "Infinity")
    _assert_numeric_echo(conn, Decimal.negative_infinity(), "-Infinity")

    _ = conn^


# --- Decimal equality against the server's own numeric comparison ------------


def test_numeric_equality_matches_the_server() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, String(NUMERIC_EQ_SQL))
    var row = _row(result, 0)

    var server_scale = _get[Bool](row, 0)
    var server_nan = _get[Bool](row, 1)
    var server_infinite = _get[Bool](row, 2)
    assert_true(server_scale)
    assert_true(server_nan)
    assert_true(server_infinite)

    # `__eq__` must give the same three answers the server gives.
    assert_equal(_decimal("1.0") == _decimal("1.00"), server_scale)
    assert_equal(Decimal.nan() == Decimal.nan(), server_nan)
    assert_equal(Decimal.infinity() == Decimal.infinity(), server_infinite)

    # The display scale really is the only difference between the two equal
    # values, which is what makes the first comparison meaningful.
    assert_equal(_decimal("1.0").dscale(), 1)
    assert_equal(_decimal("1.00").dscale(), 2)

    _ = row^
    _ = result^
    _ = conn^


# --- uuid --------------------------------------------------------------------


def test_uuid_binary_matches_text() raises:
    var conn = _connect(_conninfo())
    var in_text = _execute(conn, String(UUID_SQL))
    var in_binary = _execute_fmt(conn, String(UUID_SQL), ResultFormat.BINARY)

    # The fourth column is the first one written in upper case: the server
    # stores the same sixteen bytes and prints them in lower case.
    var expected: List[StaticString] = [
        "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
        "00000000-0000-0000-0000-000000000000",
        "ffffffff-ffff-ffff-ffff-ffffffffffff",
        "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
    ]
    assert_equal(in_text.column_count(), len(expected))
    assert_equal(in_binary.column_count(), len(expected))

    var t = _row(in_text, 0)
    var b = _row(in_binary, 0)

    for i in range(len(expected)):
        assert_equal(_column_type_oid(in_binary, i), OID_UUID)
        var from_text = _get[UUID](t, i)
        var from_binary = _get[UUID](b, i)
        assert_true(from_binary == from_text)
        assert_equal(String(from_binary), String(from_text))
        assert_equal(String(from_binary), String(expected[i]))
        assert_equal(_get[String](t, i), String(from_binary))

    # The upper-case input decodes to the very same value as column 0.
    assert_true(_get[UUID](b, 3) == _get[UUID](b, 0))

    _ = b^
    _ = t^
    _ = in_binary^
    _ = in_text^
    _ = conn^


def test_uuid_param_roundtrip_in_both_formats() raises:
    var conn = _connect(_conninfo())

    _assert_uuid_echo(
        conn,
        _uuid("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"),
        "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
    )
    _assert_uuid_echo(
        conn,
        _uuid("00000000-0000-0000-0000-000000000000"),
        "00000000-0000-0000-0000-000000000000",
    )
    _assert_uuid_echo(
        conn,
        _uuid("ffffffff-ffff-ffff-ffff-ffffffffffff"),
        "ffffffff-ffff-ffff-ffff-ffffffffffff",
    )

    # An upper-case literal is accepted by the constructor and sent as the
    # same sixteen bytes, so it echoes back in lower case too.
    _assert_uuid_echo(
        conn,
        _uuid("A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11"),
        "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
    )

    _ = conn^


def test_generated_uuid_reads_the_same_in_both_formats() raises:
    var conn = _connect(_conninfo())
    var created = _execute(conn, String(UUID_TABLE_SQL))
    _ = created^

    var in_text = _execute(conn, "SELECT u FROM pq_t6_uuid")
    var in_binary = _execute_fmt(
        conn, "SELECT u FROM pq_t6_uuid", ResultFormat.BINARY
    )
    assert_equal(in_text.row_count(), 1)
    assert_equal(in_binary.row_count(), 1)

    var t = _row(in_text, 0)
    var b = _row(in_binary, 0)

    # A value the server invented, not one this file spelled out: the text
    # decode has to succeed and has to agree with the binary one.
    var from_text = _get[UUID](t, 0)
    var from_binary = _get[UUID](b, 0)
    assert_true(from_binary == from_text)
    assert_equal(String(from_binary), String(from_text))
    assert_equal(String(from_text).byte_length(), 36)
    assert_equal(_get[String](t, 0), String(from_text))

    _ = b^
    _ = t^
    _ = in_binary^
    _ = in_text^
    _ = conn^


# --- json and jsonb ----------------------------------------------------------


def test_json_and_jsonb_binary_match_text() raises:
    var conn = _connect(_conninfo())
    var in_text = _execute(conn, String(JSON_SQL))
    var in_binary = _execute_fmt(conn, String(JSON_SQL), ResultFormat.BINARY)

    # Column 0 is `json` and keeps its input bytes; the rest are `jsonb` and
    # come back normalised in both formats alike.
    var expected: List[StaticString] = [
        '{"a":1}',
        '{"a": 3, "b": 2}',
        "null",
        "[]",
        '"é"',
        '{"a": {"b": [1, {"c": null}]}}',
    ]
    assert_equal(in_text.column_count(), len(expected))
    assert_equal(in_binary.column_count(), len(expected))
    assert_equal(_column_type_oid(in_binary, 0), OID_JSON)
    for i in range(1, len(expected)):
        assert_equal(_column_type_oid(in_binary, i), OID_JSONB)

    var t = _row(in_text, 0)
    var b = _row(in_binary, 0)

    for i in range(len(expected)):
        var from_text = _get[String](t, i)
        var from_binary = _get[String](b, i)

        # The binary `jsonb` payload opens with a version byte the decoder
        # strips, so the two strings are byte-for-byte identical.
        assert_equal(from_binary, from_text)
        assert_equal(from_binary, String(expected[i]))

    # The accented character is two UTF-8 bytes inside the two quotes.
    assert_equal(_get[String](b, 4).byte_length(), 4)

    _ = b^
    _ = t^
    _ = in_binary^
    _ = in_text^
    _ = conn^


def test_json_and_jsonb_param_roundtrip_in_both_formats() raises:
    var conn = _connect(_conninfo())

    # `json` hands the text straight back.
    _assert_text_echo(conn, "SELECT $1::json", '{"a":1}', '{"a":1}')

    # `jsonb` normalises whatever it is given, parameter or literal alike.
    _assert_text_echo(
        conn,
        "SELECT $1::jsonb",
        '{"b":2,"a":1,"a":3}',
        '{"a": 3, "b": 2}',
    )
    _assert_text_echo(conn, "SELECT $1::jsonb", "null", "null")
    _assert_text_echo(conn, "SELECT $1::jsonb", "[]", "[]")
    _assert_text_echo(conn, "SELECT $1::jsonb", '"é"', '"é"')
    _assert_text_echo(
        conn,
        "SELECT $1::jsonb",
        '{"a":{"b":[1,{"c":null}]}}',
        '{"a": {"b": [1, {"c": null}]}}',
    )

    _ = conn^


# --- types the binary decoder refuses for these OIDs -------------------------


def test_binary_refuses_mismatched_numeric_and_jsonb() raises:
    var conn = _connect(_conninfo())
    var result = _execute_fmt(conn, String(REFUSAL_SQL), ResultFormat.BINARY)
    assert_equal(result.column_count(), 2)
    var row = _row(result, 0)

    # A `numeric` is not an `Int32` and a `jsonb` is not a byte array; the
    # binary decoder names the OID instead of reinterpreting the payload.
    _assert_binary_refusal[Int32](row, 0, "oid 1700")
    _assert_binary_refusal[List[UInt8]](row, 1, "oid 3802")

    # The matching types still read, so the refusals above are about the
    # requested type and not about the columns being undecodable.
    assert_equal(String(_get[Decimal](row, 0)), "1.5")
    assert_equal(_get[String](row, 1), '{"a": 1}')

    _ = row^
    _ = result^
    _ = conn^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
