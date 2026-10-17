"""Tests for the six date/time types against a live server.

Covers `Date`, `Timestamp`, `TimestampTz`, `Time`, `TimeTz` and `Interval`
decoded from a real result, in both `ResultFormat.TEXT` and
`ResultFormat.BINARY`, plus the parameter direction through `Param`.

Four properties are asserted throughout:

* A binary result decodes to the *same* value the text result of the same
  SQL decodes to, and `String(value)` is the very text PostgreSQL printed.
* Binary decoding does not depend on a GUC. `SET DateStyle TO 'German'`
  changes what the text format says -- and makes the text decoder refuse
  the column -- while the binary column still decodes to the same `Date`.
* `TimeTz.offset_secs` keeps PostgreSQL's sign convention, where *west* of
  UTC is positive, so `'12:34:56+09'` carries `-32400`.
* The `interval` wire format is `micros, days, months` in that order, which
  is also the field order of `Interval.__init__`.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI), falling back to the local container. An unreachable
server fails these tests; it never skips them.

Only one behaviour differs between the supported server versions, and it is
branched on `Connection.server_version()`: `interval` grew the `infinity` and
`-infinity` sentinels in PostgreSQL 17. Before 17 the input `'infinity'` for
an `interval` is SQLSTATE 22007 and the binary sentinel is 22008, and that is
what the pre-17 branch asserts rather than skipping. Everything else expects
identical values on PG14 and PG17.

Every expected value below was measured on both containers with
`date_send` / `timestamp_send` / `timestamptz_send` / `time_send` /
`timetz_send` / `interval_send`, never derived by hand.

`timestamptz` is printed by the server in its own `TimeZone`, so the text
comparison for that type runs only when `SHOW TimeZone` says UTC. The value
comparison always runs: a `timestamptz` is an instant, and the instant does
not depend on the session zone.
"""

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
    Timestamp,
    TimestampTz,
    TimeTz,
)

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime PG17 = 170000
"""First `server_version()` that has `interval` infinity."""


# --- helpers -----------------------------------------------------------------
#
# A `TestSuite` test only declares `raises` (plain `Error`), and `PgError` does
# not implicitly convert to `Error`, so a `raises PgError` API cannot be called
# straight from a test. These wrappers translate in both directions: success
# paths re-raise as `Error`, failure paths hand the `PgError` back.
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

    Args:
        conn: An open connection.
        sql: The statement to run.

    Returns:
        The result of the statement, always in text format.

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
    """Run `sql` on `conn` with bound parameters, asking for `fmt` results.

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


def _execute_params_error(
    conn: Connection, var sql: String, params: List[Param]
) raises -> PgError:
    """Return the `PgError` raised by `conn.execute(sql, params)`.

    Args:
        conn: A connection whose statement must be rejected.
        sql: The statement to attempt.
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
    `Result` it came from, so the compiler keeps that result alive for as
    long as the row is reachable.

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


def _show(conn: Connection, var name: String) raises -> String:
    """Return the session value of the GUC `name`.

    Args:
        conn: An open connection.
        name: The GUC to read, as a bare identifier.

    Returns:
        The one-column, one-row answer of `SHOW name`.

    Raises:
        Error: If the statement or the read raised a `PgError`.
    """
    var result = _execute(conn, String("SHOW ", name))
    var row = _row(result, 0)
    var value = _get[String](row, 0)
    _ = row^
    _ = result^
    return value^


def _is_utc(conn: Connection) raises -> Bool:
    """Report whether the session prints `timestamptz` in UTC.

    The container sets `TimeZone` to `Etc/UTC`, but a developer running
    these tests against another server may not have, and the text form of a
    `timestamptz` is rendered in the session zone. Only the text comparison
    depends on this; the decoded instant never does.

    Args:
        conn: An open connection.

    Returns:
        True if `SHOW TimeZone` names UTC.

    Raises:
        Error: If reading the GUC raised a `PgError`.
    """
    var zone = _show(conn, "TimeZone")
    return zone == "UTC" or zone == "Etc/UTC"


def _assert_both_formats[
    T: Copyable & Deinitable & Equatable & Writable
](
    conn: Connection,
    var expr: String,
    expected: T,
    compare_text: Bool = True,
) raises:
    """Assert `SELECT expr` decodes to `expected` in both wire formats.

    The same SQL is run twice, once per `ResultFormat`. Both results must
    decode to `expected` and to each other, and -- unless `compare_text`
    says otherwise -- `String(expected)` must be the exact byte string the
    server printed for the text result.

    Parameters:
        T: The Mojo type requested from `Row.get`.

    Args:
        conn: An open connection.
        expr: A single select-list expression, without the `SELECT`.
        expected: The value both formats must decode to.
        compare_text: Whether `String(expected)` must equal the server's
            text rendering. False only where the rendering depends on a
            session setting the test cannot pin.

    Raises:
        Error: If either format failed to decode, or disagreed.
    """
    var sql = String("SELECT ", expr)
    var in_text = _execute_fmt(conn, sql.copy(), ResultFormat.TEXT)
    var in_binary = _execute_fmt(conn, sql^, ResultFormat.BINARY)

    var t_row = _row(in_text, 0)
    var b_row = _row(in_binary, 0)
    var t_value = _get[T](t_row, 0)
    var b_value = _get[T](b_row, 0)

    assert_true(t_value == expected)
    assert_true(b_value == expected)
    assert_true(t_value == b_value)

    if compare_text:
        var printed = _get[String](t_row, 0)
        assert_equal(String(expected), printed)
        assert_equal(String(b_value), printed)

    _ = t_row^
    _ = b_row^
    _ = in_text^
    _ = in_binary^


def _assert_param_roundtrip[
    T: Copyable & Deinitable & Equatable & Writable
](
    conn: Connection,
    var sql: String,
    params: List[Param],
    expected: T,
    var expected_text: String,
) raises:
    """Assert a bound parameter comes back unchanged in both wire formats.

    Parameters:
        T: The Mojo type requested from `Row.get`.

    Args:
        conn: An open connection.
        sql: The statement, normally `SELECT $1::<type>`.
        params: The single value bound to `$1`.
        expected: The value both result formats must decode to.
        expected_text: The exact text the server must print for it.

    Raises:
        Error: If the statement failed, or either format disagreed.
    """
    var in_text = _execute_params_fmt(
        conn, sql.copy(), params, ResultFormat.TEXT
    )
    var in_binary = _execute_params_fmt(conn, sql^, params, ResultFormat.BINARY)

    var t_row = _row(in_text, 0)
    var b_row = _row(in_binary, 0)

    assert_equal(_get[String](t_row, 0), expected_text)
    assert_true(_get[T](t_row, 0) == expected)
    assert_true(_get[T](b_row, 0) == expected)

    _ = t_row^
    _ = b_row^
    _ = in_text^
    _ = in_binary^


# --- date --------------------------------------------------------------------


def test_date_values_match_in_both_formats() raises:
    var conn = _connect(_conninfo())

    # The PostgreSQL epoch is 2000-01-01, so day zero is not the Unix epoch
    # and the day before it is -1 rather than a large positive number.
    _assert_both_formats(conn, "'2000-01-01'::date", Date(0))
    _assert_both_formats(conn, "'1999-12-31'::date", Date(-1))
    _assert_both_formats(conn, "'2024-01-02'::date", Date(8767))
    _assert_both_formats(conn, "'2024-02-29'::date", Date(8825))

    # Year 1 and 1 BC are adjacent: there is no year zero in the text form,
    # which is why the two day counts differ by 366 and not by 365.
    _assert_both_formats(conn, "'0001-01-01'::date", Date(-730119))
    _assert_both_formats(conn, "'0001-01-01 BC'::date", Date(-730485))

    # Five-digit years are printed unpadded, four-digit ones zero-padded.
    _assert_both_formats(conn, "'10000-01-01'::date", Date(2921940))

    _ = conn^


def test_infinite_dates_match_in_both_formats() raises:
    var conn = _connect(_conninfo())

    _assert_both_formats(conn, "'infinity'::date", Date.infinity())
    _assert_both_formats(conn, "'-infinity'::date", Date.negative_infinity())

    # The sentinels are the Int32 extremes, and both formats must agree that
    # they are sentinels rather than very distant real dates. This is asked
    # of the values that came off the wire, not only of the constructors
    # they compare equal to.
    for fmt in [ResultFormat.TEXT, ResultFormat.BINARY]:
        var result = _execute_fmt(
            conn, "SELECT 'infinity'::date, '-infinity'::date", fmt
        )
        var row = _row(result, 0)
        assert_true(_get[Date](row, 0).is_infinite())
        assert_false(_get[Date](row, 0).is_finite())
        assert_true(_get[Date](row, 1).is_infinite())
        assert_false(_get[Date](row, 1).is_finite())
        _ = row^
        _ = result^

    assert_equal(String(Date.infinity()), "infinity")
    assert_equal(String(Date.negative_infinity()), "-infinity")

    _ = conn^


# --- timestamp ---------------------------------------------------------------


def test_timestamp_values_match_in_both_formats() raises:
    var conn = _connect(_conninfo())

    _assert_both_formats(conn, "'2000-01-01 00:00:00'::timestamp", Timestamp(0))
    _assert_both_formats(
        conn,
        "'2024-01-02 03:04:05.678901'::timestamp",
        Timestamp(757479845678901),
    )

    # One microsecond before the Unix epoch, which is a negative count in
    # the PostgreSQL epoch and keeps all six fractional digits.
    _assert_both_formats(
        conn,
        "'1969-12-31 23:59:59.999999'::timestamp",
        Timestamp(-946684800000001),
    )

    _assert_both_formats(
        conn,
        "'0001-01-01 00:00:00 BC'::timestamp",
        Timestamp(-63113904000000000),
    )
    _assert_both_formats(
        conn, "'10000-01-01'::timestamp", Timestamp(252455616000000000)
    )

    _ = conn^


def test_infinite_timestamps_match_in_both_formats() raises:
    var conn = _connect(_conninfo())

    _assert_both_formats(conn, "'infinity'::timestamp", Timestamp.infinity())
    _assert_both_formats(
        conn, "'-infinity'::timestamp", Timestamp.negative_infinity()
    )

    for fmt in [ResultFormat.TEXT, ResultFormat.BINARY]:
        var result = _execute_fmt(
            conn, "SELECT 'infinity'::timestamp, '-infinity'::timestamp", fmt
        )
        var row = _row(result, 0)
        assert_true(_get[Timestamp](row, 0).is_infinite())
        assert_false(_get[Timestamp](row, 0).is_finite())
        assert_true(_get[Timestamp](row, 1).is_infinite())
        assert_false(_get[Timestamp](row, 1).is_finite())
        _ = row^
        _ = result^

    assert_equal(String(Timestamp.infinity()), "infinity")
    assert_equal(String(Timestamp.negative_infinity()), "-infinity")

    _ = conn^


# --- timestamptz -------------------------------------------------------------


def test_timestamptz_same_instant_from_two_offsets() raises:
    var conn = _connect(_conninfo())
    var utc = _is_utc(conn)

    # The two literals name the same instant written in two zones, so both
    # must decode to one and the same microsecond count. The text form is
    # rendered in the session zone, so it is only compared under UTC.
    _assert_both_formats(
        conn,
        "'2024-01-02 03:04:05.678901+00'::timestamptz",
        TimestampTz(757479845678901),
        compare_text=utc,
    )
    _assert_both_formats(
        conn,
        "'2024-01-02 12:04:05.678901+09'::timestamptz",
        TimestampTz(757479845678901),
        compare_text=utc,
    )

    if utc:
        assert_equal(
            String(TimestampTz(757479845678901)),
            "2024-01-02 03:04:05.678901+00",
        )

    _ = conn^


def test_infinite_timestamptz_match_in_both_formats() raises:
    var conn = _connect(_conninfo())

    # The sentinels print as bare words with no offset at all, so these two
    # are compared as text in every session zone.
    _assert_both_formats(
        conn, "'infinity'::timestamptz", TimestampTz.infinity()
    )
    _assert_both_formats(
        conn, "'-infinity'::timestamptz", TimestampTz.negative_infinity()
    )

    for fmt in [ResultFormat.TEXT, ResultFormat.BINARY]:
        var sql = String(
            "SELECT 'infinity'::timestamptz, '-infinity'::timestamptz"
        )
        var result = _execute_fmt(conn, sql^, fmt)
        var row = _row(result, 0)
        assert_true(_get[TimestampTz](row, 0).is_infinite())
        assert_false(_get[TimestampTz](row, 0).is_finite())
        assert_true(_get[TimestampTz](row, 1).is_infinite())
        assert_false(_get[TimestampTz](row, 1).is_finite())
        _ = row^
        _ = result^

    assert_equal(String(TimestampTz.infinity()), "infinity")
    assert_equal(String(TimestampTz.negative_infinity()), "-infinity")

    _ = conn^


# --- time --------------------------------------------------------------------


def test_time_values_match_in_both_formats() raises:
    var conn = _connect(_conninfo())

    _assert_both_formats(conn, "'00:00:00'::time", Time(0))

    # `24:00:00` is a real `time` value in PostgreSQL, one microsecond past
    # the largest value `23:59:59.999999` can express.
    _assert_both_formats(conn, "'24:00:00'::time", Time(86400000000))
    _assert_both_formats(conn, "'23:59:59.999999'::time", Time(86399999999))

    # A single fractional digit on input is printed back as one digit, not
    # padded to six.
    _assert_both_formats(conn, "'12:34:56.5'::time", Time(45296500000))

    _ = conn^


# --- timetz ------------------------------------------------------------------


def test_timetz_zone_sign_follows_postgres() raises:
    var conn = _connect(_conninfo())

    # PostgreSQL stores the zone as seconds *west* of UTC, so `+09` is
    # -32400 and `-03:30` is +12600. The sign is the opposite of the one in
    # the printed text, and that is the whole point of these four cases.
    _assert_both_formats(
        conn, "'12:34:56+09'::timetz", TimeTz(45296000000, -32400)
    )
    _assert_both_formats(
        conn, "'12:00:00-03:30'::timetz", TimeTz(43200000000, 12600)
    )

    # Offsets are not whole minutes in general: both a historic
    # seconds-bearing zone and the smallest possible one round-trip.
    _assert_both_formats(
        conn, "'12:00:00+05:53:28'::timetz", TimeTz(43200000000, -21208)
    )
    _assert_both_formats(conn, "'00:00:00+00:00:01'::timetz", TimeTz(0, -1))

    # The `24:00:00` time of day carries a zone like any other.
    _assert_both_formats(
        conn, "'24:00:00+09'::timetz", TimeTz(86400000000, -32400)
    )

    _ = conn^


# --- interval ----------------------------------------------------------------


def test_interval_p8_values_match_in_both_formats() raises:
    var conn = _connect(_conninfo())

    # `Interval(micros, days, months)` is the field order of the wire
    # format, not the order the text form prints them in. The months are
    # never normalised into days and the days are never normalised into
    # microseconds, so a mixed-sign interval such as the first one keeps
    # both signs and prints as `-1 days +02:00:00`.
    _assert_both_formats(
        conn, "'-1 day 2 hours'::interval", Interval(7200000000, -1, 0)
    )
    _assert_both_formats(
        conn, "'-1 second'::interval", Interval(-1000000, 0, 0)
    )
    _assert_both_formats(conn, "'-1 day'::interval", Interval(0, -1, 0))
    _assert_both_formats(conn, "'1 day'::interval", Interval(0, 1, 0))
    _assert_both_formats(
        conn,
        "'1 year 2 mons 3 days 04:05:06.789'::interval",
        Interval(14706789000, 3, 14),
    )
    _assert_both_formats(conn, "'-11 mons'::interval", Interval(0, 0, -11))
    _assert_both_formats(conn, "'25 mons'::interval", Interval(0, 0, 25))
    _assert_both_formats(conn, "'0'::interval", Interval(0, 0, 0))
    _assert_both_formats(
        conn, "'100:00:00'::interval", Interval(360000000000, 0, 0)
    )
    _assert_both_formats(conn, "'-0.5 secs'::interval", Interval(-500000, 0, 0))
    _assert_both_formats(
        conn, "'-1 years +1 day'::interval", Interval(0, 1, -12)
    )

    _ = conn^


def test_interval_literals_match_in_both_formats() raises:
    var conn = _connect(_conninfo())

    # A month is a month and a year is twelve of them; neither becomes days.
    _assert_both_formats(conn, "'1 mon'::interval", Interval(0, 0, 1))
    _assert_both_formats(conn, "'1 year'::interval", Interval(0, 0, 12))

    # Hours beyond a day stay in the microsecond field, so `36 hours` is not
    # `1 day 12:00:00`, while a fractional day *is* split into both fields.
    _assert_both_formats(
        conn, "'36 hours'::interval", Interval(129600000000, 0, 0)
    )
    _assert_both_formats(
        conn, "'1.5 days'::interval", Interval(43200000000, 1, 0)
    )

    _ = conn^


# --- parameters round-trip through the server --------------------------------


def test_date_and_time_params_round_trip() raises:
    var conn = _connect(_conninfo())

    _assert_param_roundtrip(
        conn, "SELECT $1::date", [Date(8825)], Date(8825), "2024-02-29"
    )
    _assert_param_roundtrip(
        conn,
        "SELECT $1::time",
        [Time(45296789000)],
        Time(45296789000),
        "12:34:56.789",
    )

    # The parameter carries seconds west of UTC, and the server prints the
    # zone back with the opposite sign.
    _assert_param_roundtrip(
        conn,
        "SELECT $1::timetz",
        [TimeTz(45296000000, -32400)],
        TimeTz(45296000000, -32400),
        "12:34:56+09",
    )

    _ = conn^


def test_timestamp_params_round_trip() raises:
    var conn = _connect(_conninfo())

    _assert_param_roundtrip(
        conn,
        "SELECT $1::timestamp",
        [Timestamp(762525296789000)],
        Timestamp(762525296789000),
        "2024-02-29 12:34:56.789",
    )

    # A `timestamptz` parameter is the same microsecond count, but the text
    # it prints as carries the session zone, so the text of the main
    # connection's case is only pinned when that zone is UTC.
    if _is_utc(conn):
        _assert_param_roundtrip(
            conn,
            "SELECT $1::timestamptz",
            [TimestampTz(762525296789000)],
            TimestampTz(762525296789000),
            "2024-02-29 12:34:56.789+00",
        )
    else:
        # `(main)` because the function goes on to run its `Asia/Tokyo` case:
        # only the main connection's UTC assertion is skipped.
        print("SKIP test_timestamp_params_round_trip(main): TimeZone not UTC")

    # The zone dependence itself is pinned on a connection that asks for one,
    # whatever the server's default is: the same instant prints as 21:34:56.789
    # with a +09 zone under `Asia/Tokyo`.
    var conn_tokyo = _connect(_conninfo() + " options='-c TimeZone=Asia/Tokyo'")
    _assert_param_roundtrip(
        conn_tokyo,
        "SELECT $1::timestamptz",
        [TimestampTz(762525296789000)],
        TimestampTz(762525296789000),
        "2024-02-29 21:34:56.789+09",
    )

    _ = conn_tokyo^
    _ = conn^


def test_interval_param_round_trips() raises:
    var conn = _connect(_conninfo())

    # One month, two days and three hours, each in its own field, printed
    # back in the `postgres` style the connection pinned at open time.
    _assert_param_roundtrip(
        conn,
        "SELECT $1::interval",
        [Interval(10800000000, 2, 1)],
        Interval(10800000000, 2, 1),
        "1 mon 2 days 03:00:00",
    )

    _ = conn^


def test_infinite_params_round_trip() raises:
    var conn = _connect(_conninfo())

    _assert_param_roundtrip(
        conn,
        "SELECT $1::date",
        [Date.infinity()],
        Date.infinity(),
        "infinity",
    )
    _assert_param_roundtrip(
        conn,
        "SELECT $1::timestamp",
        [Timestamp.negative_infinity()],
        Timestamp.negative_infinity(),
        "-infinity",
    )

    _ = conn^


# --- interval infinity is PostgreSQL 17 and later ----------------------------


def test_interval_infinity_on_pg17_and_later() raises:
    var conn = _connect(_conninfo())
    if conn.server_version() < PG17:
        print("SKIP test_interval_infinity_on_pg17_and_later: server < 17")
        _ = conn^
        return

    _assert_both_formats(conn, "'infinity'::interval", Interval.infinity())
    _assert_both_formats(
        conn, "'-infinity'::interval", Interval.negative_infinity()
    )

    # The sentinel is every field at its extreme, which is why it has to be
    # recognised as a whole rather than field by field.
    for fmt in [ResultFormat.TEXT, ResultFormat.BINARY]:
        var sql = String("SELECT 'infinity'::interval, '-infinity'::interval")
        var result = _execute_fmt(conn, sql^, fmt)
        var row = _row(result, 0)
        assert_true(_get[Interval](row, 0).is_infinite())
        assert_false(_get[Interval](row, 0).is_finite())
        assert_true(_get[Interval](row, 1).is_infinite())
        assert_false(_get[Interval](row, 1).is_finite())
        _ = row^
        _ = result^

    _assert_param_roundtrip(
        conn,
        "SELECT $1::interval",
        [Interval.infinity()],
        Interval.infinity(),
        "infinity",
    )

    _ = conn^


def test_interval_infinity_rejected_before_pg17() raises:
    var conn = _connect(_conninfo())
    if conn.server_version() >= PG17:
        print("SKIP test_interval_infinity_rejected_before_pg17: server 17+")
        _ = conn^
        return

    # Before 17 the word is simply not `interval` input syntax, and the
    # server says so with 22007 (invalid_datetime_format).
    var parsed = _execute_fmt_error(
        conn, "SELECT 'infinity'::interval", ResultFormat.BINARY
    )
    assert_true(parsed.kind == PgErrorKind.SERVER)
    assert_equal(parsed.sqlstate, "22007")
    assert_true("type interval" in parsed.message)

    # The binary sentinel is a different failure: the bytes are well formed,
    # but the field values overflow, which is 22008 (datetime_field_overflow).
    var sent = _execute_params_error(
        conn, "SELECT $1::interval", [Interval.negative_infinity()]
    )
    assert_true(sent.kind == PgErrorKind.SERVER)
    assert_equal(sent.sqlstate, "22008")
    assert_true(sent.message != "")

    _ = conn^


# --- binary is independent of the output-formatting GUCs ---------------------


def test_binary_date_is_independent_of_datestyle() raises:
    # A dedicated connection: `SET` is session state, and leaking a
    # non-ISO `DateStyle` into another test would break its text half.
    var conn = _connect(_conninfo())
    var set_german = _execute(conn, "SET DateStyle TO 'German'")
    _ = set_german^

    var sql = String("SELECT '2024-01-02'::date")
    var in_text = _execute_fmt(conn, sql.copy(), ResultFormat.TEXT)
    var in_binary = _execute_fmt(conn, sql^, ResultFormat.BINARY)
    var t_row = _row(in_text, 0)
    var b_row = _row(in_binary, 0)

    # The text decoder accepts `ISO, YMD` and nothing else, so the German
    # rendering is a `TYPE_MISMATCH` that quotes the text it could not read.
    assert_true(_get_kind[Date](t_row, 0) == PgErrorKind.TYPE_MISMATCH)
    var message = _get_message[Date](t_row, 0)
    assert_true('"02.01.2024" as date' in message)
    assert_equal(_get[String](t_row, 0), "02.01.2024")

    # The binary column is the same day count whatever `DateStyle` says:
    # the GUC only governs the text rendering.
    assert_true(_get[Date](b_row, 0) == Date(8767))

    _ = t_row^
    _ = b_row^
    _ = in_text^
    _ = in_binary^

    # Putting the GUC back is what makes the text half work again, and
    # checking that here is what proves the earlier failure was the GUC.
    var restore = _execute(conn, "SET DateStyle TO 'ISO, YMD'")
    _ = restore^
    var again = _execute_fmt(
        conn, "SELECT '2024-01-02'::date", ResultFormat.TEXT
    )
    var again_row = _row(again, 0)
    assert_true(_get[Date](again_row, 0) == Date(8767))
    _ = again_row^
    _ = again^

    _ = conn^


def test_binary_interval_is_independent_of_intervalstyle() raises:
    # Same reasoning as the `DateStyle` test: its own connection.
    var conn = _connect(_conninfo())
    var set_iso = _execute(conn, "SET IntervalStyle TO 'iso_8601'")
    _ = set_iso^

    var sql = String("SELECT '1 day'::interval")
    var in_text = _execute_fmt(conn, sql.copy(), ResultFormat.TEXT)
    var in_binary = _execute_fmt(conn, sql^, ResultFormat.BINARY)
    var t_row = _row(in_text, 0)
    var b_row = _row(in_binary, 0)

    assert_true(_get_kind[Interval](t_row, 0) == PgErrorKind.TYPE_MISMATCH)
    var message = _get_message[Interval](t_row, 0)
    assert_true('"P1D" as interval' in message)
    assert_equal(_get[String](t_row, 0), "P1D")

    assert_true(_get[Interval](b_row, 0) == Interval(0, 1, 0))

    _ = t_row^
    _ = b_row^
    _ = in_text^
    _ = in_binary^

    var restore = _execute(conn, "SET IntervalStyle TO 'postgres'")
    _ = restore^
    var again = _execute_fmt(
        conn, "SELECT '1 day'::interval", ResultFormat.TEXT
    )
    var again_row = _row(again, 0)
    assert_true(_get[Interval](again_row, 0) == Interval(0, 1, 0))
    _ = again_row^
    _ = again^

    _ = conn^


# --- the extremes of the date and timestamp ranges ---------------------------


def test_range_boundaries_match_in_both_formats() raises:
    var conn = _connect(_conninfo())

    # The first and last day a `date` can hold, and the first and last
    # microsecond a `timestamp` can hold, all four of them one step inside
    # the sentinels rather than equal to them.
    _assert_both_formats(conn, "'4714-11-24 BC'::date", Date(-2451545))
    _assert_both_formats(conn, "'5874897-12-31'::date", Date(2145031948))
    _assert_both_formats(
        conn,
        "'294276-12-31 23:59:59.999999'::timestamp",
        Timestamp(9223371331199999999),
    )
    _assert_both_formats(
        conn,
        "'4714-11-24 00:00:00 BC'::timestamp",
        Timestamp(-211813488000000000),
    )

    # These are real values, not sentinels, so neither end is "infinite".
    assert_true(Date(2145031948).is_finite())
    assert_true(Timestamp(9223371331199999999).is_finite())

    _ = conn^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
