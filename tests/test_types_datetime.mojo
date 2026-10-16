"""Tests for `pq.types_datetime`: dates, times, timestamps, intervals.

No database is involved. Every expectation is a value measured on a live
PostgreSQL 17 / 14 server and written here as a literal, so these tests pin
the PostgreSQL epoch (2000-01-01), the astronomical year numbering used by
the checked constructors (1 BC is year 0), the exact text PostgreSQL prints
and the input spellings it refuses.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pq.errors import PgErrorKind
from pq.types_datetime import (
    Date,
    Interval,
    Time,
    Timestamp,
    TimestampTz,
    TimeTz,
)


# --- Date helpers ------------------------------------------------------------


def _date_ymd(y: Int, m: Int, d: Int) raises -> Date:
    """Build a `Date` from a calendar date, raising a plain `Error`.

    A `TestSuite` test only declares `raises` (plain `Error`), so it cannot
    call a `raises PgError` function directly.

    Args:
        y: Astronomical year, where 1 BC is 0.
        m: Month, 1 to 12.
        d: Day of month.

    Returns:
        The constructed `Date`.

    Raises:
        Error: If `Date.from_ymd` raised a `PgError`.
    """
    try:
        return Date.from_ymd(y, m, d)
    except e:
        raise Error(String(e))


def _date_parsed(text: String) raises -> Date:
    """Decode `text` with `Date.parse`, raising a plain `Error`.

    Args:
        text: The text to decode.

    Returns:
        The decoded `Date`.

    Raises:
        Error: If `Date.parse` raised a `PgError`.
    """
    try:
        return Date.parse(text)
    except e:
        raise Error(String(e))


def _date_parts(value: Date) raises -> List[Int]:
    """Return `[year, month, day]` of `value`, raising a plain `Error`.

    Args:
        value: A finite `Date`.

    Returns:
        The three decomposed fields, in that order.

    Raises:
        Error: If any accessor raised a `PgError`.
    """
    try:
        return [value.year(), value.month(), value.day()]
    except e:
        raise Error(String(e))


def _assert_date(y: Int, m: Int, d: Int, days: Int32) raises:
    """Assert `from_ymd` yields `days` and decomposes back to the input.

    Args:
        y: Astronomical year passed to `Date.from_ymd`.
        m: Month passed to `Date.from_ymd`.
        d: Day passed to `Date.from_ymd`.
        days: Day count relative to 2000-01-01 the server reports.

    Raises:
        Error: If the day count or any decomposed field differs.
    """
    var value = _date_ymd(y, m, d)
    assert_equal(value.days, days)
    var parts = _date_parts(value)
    assert_equal(parts[0], y)
    assert_equal(parts[1], m)
    assert_equal(parts[2], d)


def _assert_date_text(days: Int32, text: String) raises:
    """Assert `Date(days)` prints as `text` and `text` parses back to it.

    Args:
        days: Raw day count relative to 2000-01-01.
        text: The text PostgreSQL prints for that day count.

    Raises:
        Error: If printing or parsing disagreed.
    """
    assert_equal(String(Date(days)), text)
    assert_true(_date_parsed(text) == Date(days))
    assert_false(_date_parsed(text) != Date(days))


def _assert_date_rejected(y: Int, m: Int, d: Int) raises:
    """Assert `Date.from_ymd` refuses `y`/`m`/`d` with `USAGE`.

    Args:
        y: Astronomical year that must be refused.
        m: Month that must be refused.
        d: Day that must be refused.

    Raises:
        Error: If the call succeeded or reported the wrong kind or
            message.
    """
    try:
        _ = Date.from_ymd(y, m, d)
    except e:
        assert_equal(e.kind, PgErrorKind.USAGE)
        assert_true("invalid date" in e.message)
        return
    raise Error("expected PgError from Date.from_ymd")


def _assert_date_parse_rejected(text: String) raises:
    """Assert `Date.parse` refuses `text` with `TYPE_MISMATCH`.

    Args:
        text: Text outside the accepted `YYYY-MM-DD( BC)?` grammar.

    Raises:
        Error: If the call succeeded or reported the wrong kind or
            message.
    """
    try:
        _ = Date.parse(text)
    except e:
        assert_equal(e.kind, PgErrorKind.TYPE_MISMATCH)
        assert_true("cannot decode" in e.message)
        return
    raise Error(String('expected PgError for "', text, '"'))


def _assert_date_year_infinite(value: Date) raises:
    """Assert `value.year()` refuses an infinite `Date` with `USAGE`.

    Args:
        value: An infinite `Date`.

    Raises:
        Error: If the accessor returned a value or reported the wrong
            kind or message.
    """
    try:
        _ = value.year()
    except e:
        assert_equal(e.kind, PgErrorKind.USAGE)
        assert_true("is infinite" in e.message)
        return
    raise Error("expected PgError from Date.year()")


def _assert_date_month_infinite(value: Date) raises:
    """Assert `value.month()` refuses an infinite `Date` with `USAGE`.

    Args:
        value: An infinite `Date`.

    Raises:
        Error: If the accessor returned a value or reported the wrong
            kind or message.
    """
    try:
        _ = value.month()
    except e:
        assert_equal(e.kind, PgErrorKind.USAGE)
        assert_true("is infinite" in e.message)
        return
    raise Error("expected PgError from Date.month()")


def _assert_date_day_infinite(value: Date) raises:
    """Assert `value.day()` refuses an infinite `Date` with `USAGE`.

    Args:
        value: An infinite `Date`.

    Raises:
        Error: If the accessor returned a value or reported the wrong
            kind or message.
    """
    try:
        _ = value.day()
    except e:
        assert_equal(e.kind, PgErrorKind.USAGE)
        assert_true("is infinite" in e.message)
        return
    raise Error("expected PgError from Date.day()")


# --- Timestamp helpers -------------------------------------------------------


def _ts_hms(
    y: Int, m: Int, d: Int, h: Int, mi: Int, s: Int, us: Int
) raises -> Timestamp:
    """Build a `Timestamp` from its components, raising a plain `Error`.

    Args:
        y: Astronomical year, where 1 BC is 0.
        m: Month, 1 to 12.
        d: Day of month.
        h: Hour, 0 to 23.
        mi: Minute, 0 to 59.
        s: Second, 0 to 59.
        us: Microsecond, 0 to 999999.

    Returns:
        The constructed `Timestamp`.

    Raises:
        Error: If `Timestamp.from_ymd_hms` raised a `PgError`.
    """
    try:
        return Timestamp.from_ymd_hms(y, m, d, h, mi, s, us)
    except e:
        raise Error(String(e))


def _ts_hms_default_us(
    y: Int, m: Int, d: Int, h: Int, mi: Int, s: Int
) raises -> Timestamp:
    """Build a `Timestamp` leaving the microsecond argument defaulted.

    Args:
        y: Astronomical year, where 1 BC is 0.
        m: Month, 1 to 12.
        d: Day of month.
        h: Hour, 0 to 23.
        mi: Minute, 0 to 59.
        s: Second, 0 to 59.

    Returns:
        The constructed `Timestamp`.

    Raises:
        Error: If `Timestamp.from_ymd_hms` raised a `PgError`.
    """
    try:
        return Timestamp.from_ymd_hms(y, m, d, h, mi, s)
    except e:
        raise Error(String(e))


def _ts_parsed(text: String) raises -> Timestamp:
    """Decode `text` with `Timestamp.parse`, raising a plain `Error`.

    Args:
        text: The text to decode.

    Returns:
        The decoded `Timestamp`.

    Raises:
        Error: If `Timestamp.parse` raised a `PgError`.
    """
    try:
        return Timestamp.parse(text)
    except e:
        raise Error(String(e))


def _ts_parts(value: Timestamp) raises -> List[Int]:
    """Return the seven decomposed fields of `value`, in order.

    Args:
        value: A finite `Timestamp`.

    Returns:
        `[year, month, day, hour, minute, second, microsecond]`.

    Raises:
        Error: If any accessor raised a `PgError`.
    """
    try:
        return [
            value.year(),
            value.month(),
            value.day(),
            value.hour(),
            value.minute(),
            value.second(),
            value.microsecond(),
        ]
    except e:
        raise Error(String(e))


def _assert_timestamp_parts(
    value: Timestamp, y: Int, m: Int, d: Int, h: Int, mi: Int, s: Int, us: Int
) raises:
    """Assert the seven accessors of `value` give back the components.

    Args:
        value: The `Timestamp` to decompose.
        y: Expected astronomical year.
        m: Expected month.
        d: Expected day of month.
        h: Expected hour.
        mi: Expected minute.
        s: Expected second.
        us: Expected microsecond.

    Raises:
        Error: If any decomposed field differs.
    """
    var parts = _ts_parts(value)
    assert_equal(parts[0], y)
    assert_equal(parts[1], m)
    assert_equal(parts[2], d)
    assert_equal(parts[3], h)
    assert_equal(parts[4], mi)
    assert_equal(parts[5], s)
    assert_equal(parts[6], us)


def _assert_timestamp(
    y: Int,
    m: Int,
    d: Int,
    h: Int,
    mi: Int,
    s: Int,
    us: Int,
    micros: Int64,
) raises:
    """Assert `from_ymd_hms` yields `micros` and decomposes back.

    Args:
        y: Astronomical year passed to `Timestamp.from_ymd_hms`.
        m: Month passed to `Timestamp.from_ymd_hms`.
        d: Day passed to `Timestamp.from_ymd_hms`.
        h: Hour passed to `Timestamp.from_ymd_hms`.
        mi: Minute passed to `Timestamp.from_ymd_hms`.
        s: Second passed to `Timestamp.from_ymd_hms`.
        us: Microsecond passed to `Timestamp.from_ymd_hms`.
        micros: Microseconds since 2000-01-01 the server reports.

    Raises:
        Error: If the microsecond count or any decomposed field differs.
    """
    var value = _ts_hms(y, m, d, h, mi, s, us)
    assert_equal(value.micros, micros)
    _assert_timestamp_parts(value, y, m, d, h, mi, s, us)


def _assert_timestamp_text(micros: Int64, text: String) raises:
    """Assert `Timestamp(micros)` prints as `text` and parses back.

    Args:
        micros: Raw microseconds relative to 2000-01-01.
        text: The text PostgreSQL prints for that count.

    Raises:
        Error: If printing or parsing disagreed.
    """
    assert_equal(String(Timestamp(micros)), text)
    assert_true(_ts_parsed(text) == Timestamp(micros))
    assert_false(_ts_parsed(text) != Timestamp(micros))


def _assert_timestamp_rejected(
    y: Int, m: Int, d: Int, h: Int, mi: Int, s: Int, us: Int
) raises:
    """Assert `Timestamp.from_ymd_hms` refuses the components.

    Args:
        y: Astronomical year that must be refused.
        m: Month that must be refused.
        d: Day that must be refused.
        h: Hour that must be refused.
        mi: Minute that must be refused.
        s: Second that must be refused.
        us: Microsecond that must be refused.

    Raises:
        Error: If the call succeeded or reported the wrong kind or
            message.
    """
    try:
        _ = Timestamp.from_ymd_hms(y, m, d, h, mi, s, us)
    except e:
        assert_equal(e.kind, PgErrorKind.USAGE)
        assert_true("invalid timestamp" in e.message)
        return
    raise Error("expected PgError from Timestamp.from_ymd_hms")


def _assert_timestamp_parse_rejected(text: String) raises:
    """Assert `Timestamp.parse` refuses `text` with `TYPE_MISMATCH`.

    Args:
        text: Text outside the accepted timestamp grammar.

    Raises:
        Error: If the call succeeded or reported the wrong kind or
            message.
    """
    try:
        _ = Timestamp.parse(text)
    except e:
        assert_equal(e.kind, PgErrorKind.TYPE_MISMATCH)
        assert_true("cannot decode" in e.message)
        return
    raise Error(String('expected PgError for "', text, '"'))


# --- TimestampTz helpers -----------------------------------------------------


def _tstz_utc(
    y: Int, m: Int, d: Int, h: Int, mi: Int, s: Int, us: Int
) raises -> TimestampTz:
    """Build a `TimestampTz` from UTC components, raising plain `Error`.

    Args:
        y: Astronomical UTC year, where 1 BC is 0.
        m: UTC month, 1 to 12.
        d: UTC day of month.
        h: UTC hour, 0 to 23.
        mi: UTC minute, 0 to 59.
        s: UTC second, 0 to 59.
        us: UTC microsecond, 0 to 999999.

    Returns:
        The constructed `TimestampTz`.

    Raises:
        Error: If `TimestampTz.from_utc` raised a `PgError`.
    """
    try:
        return TimestampTz.from_utc(y, m, d, h, mi, s, us)
    except e:
        raise Error(String(e))


def _tstz_parsed(text: String) raises -> TimestampTz:
    """Decode `text` with `TimestampTz.parse`, raising plain `Error`.

    Args:
        text: The text to decode, offset included.

    Returns:
        The decoded `TimestampTz`.

    Raises:
        Error: If `TimestampTz.parse` raised a `PgError`.
    """
    try:
        return TimestampTz.parse(text)
    except e:
        raise Error(String(e))


def _assert_tstz_parse_rejected(text: String) raises:
    """Assert `TimestampTz.parse` refuses `text` with `TYPE_MISMATCH`.

    Args:
        text: Text outside the accepted timestamptz grammar.

    Raises:
        Error: If the call succeeded or reported the wrong kind or
            message.
    """
    try:
        _ = TimestampTz.parse(text)
    except e:
        assert_equal(e.kind, PgErrorKind.TYPE_MISMATCH)
        assert_true("cannot decode" in e.message)
        return
    raise Error(String('expected PgError for "', text, '"'))


# --- Date.from_ymd day counts ------------------------------------------------


def test_date_from_ymd_epoch() raises:
    _assert_date(2000, 1, 1, 0)


def test_date_from_ymd_unix_epoch() raises:
    _assert_date(1970, 1, 1, -10957)


def test_date_from_ymd_leap_day() raises:
    _assert_date(2024, 2, 29, 8825)


def test_date_from_ymd_day_before_epoch() raises:
    _assert_date(1999, 12, 31, -1)


def test_date_from_ymd_year_one() raises:
    _assert_date(1, 1, 1, -730119)


def test_date_from_ymd_year_zero_is_one_bc() raises:
    _assert_date(0, 1, 1, -730485)


def test_date_from_ymd_julian_day_origin() raises:
    _assert_date(-4713, 11, 24, -2451545)


def test_date_from_ymd_five_digit_year() raises:
    _assert_date(10000, 1, 1, 2921940)


def test_date_from_ymd_highest_date() raises:
    _assert_date(5874897, 12, 31, 2145031948)


# --- Date text and parse -----------------------------------------------------


def test_date_text_epoch() raises:
    _assert_date_text(0, "2000-01-01")


def test_date_text_one_bc() raises:
    _assert_date_text(-730485, "0001-01-01 BC")


def test_date_text_julian_day_origin() raises:
    _assert_date_text(-2451545, "4714-11-24 BC")


def test_date_text_five_digit_year() raises:
    _assert_date_text(2921940, "10000-01-01")


def test_date_text_highest_date() raises:
    _assert_date_text(2145031948, "5874897-12-31")


def test_date_text_year_one_ad() raises:
    _assert_date_text(-730119, "0001-01-01")


def test_date_text_infinity() raises:
    assert_equal(String(Date.infinity()), "infinity")
    assert_true(_date_parsed("infinity") == Date.infinity())


def test_date_text_negative_infinity() raises:
    assert_equal(String(Date.negative_infinity()), "-infinity")
    assert_true(_date_parsed("-infinity") == Date.negative_infinity())


# --- Date.from_ymd rejections ------------------------------------------------


def test_date_rejects_february_30_in_leap_year() raises:
    _assert_date_rejected(2024, 2, 30)


def test_date_rejects_february_29_in_common_year() raises:
    _assert_date_rejected(2023, 2, 29)


def test_date_rejects_month_thirteen() raises:
    _assert_date_rejected(2024, 13, 1)


def test_date_rejects_month_zero() raises:
    _assert_date_rejected(2024, 0, 1)


def test_date_rejects_day_zero() raises:
    _assert_date_rejected(2024, 1, 0)


def test_date_rejects_year_above_maximum() raises:
    _assert_date_rejected(5874898, 1, 1)


def test_date_rejects_year_below_minimum() raises:
    _assert_date_rejected(-4714, 1, 1)


def test_date_accepts_leap_day_and_year_zero() raises:
    assert_equal(_date_ymd(2024, 2, 29).days, Int32(8825))
    assert_equal(_date_ymd(0, 1, 1).days, Int32(-730485))


# --- Date infinities ---------------------------------------------------------


def test_date_infinity_accessors_raise() raises:
    var value = Date.infinity()
    _assert_date_year_infinite(value)
    _assert_date_month_infinite(value)
    _assert_date_day_infinite(value)


def test_date_negative_infinity_accessors_raise() raises:
    var value = Date.negative_infinity()
    _assert_date_year_infinite(value)
    _assert_date_month_infinite(value)
    _assert_date_day_infinite(value)


def test_date_infinity_predicates() raises:
    var value = Date.infinity()
    assert_equal(value.days, Int32.MAX)
    assert_true(value.is_infinite())
    assert_false(value.is_finite())


def test_date_negative_infinity_predicates() raises:
    var value = Date.negative_infinity()
    assert_equal(value.days, Int32.MIN)
    assert_true(value.is_infinite())
    assert_false(value.is_finite())


def test_date_finite_predicates() raises:
    var value = Date(0)
    assert_false(value.is_infinite())
    assert_true(value.is_finite())


# --- Date.parse rejections ---------------------------------------------------


def test_date_parse_rejects_leading_space() raises:
    _assert_date_parse_rejected(" 2024-01-02")


def test_date_parse_rejects_leading_plus() raises:
    _assert_date_parse_rejected("+2024-01-02")


def test_date_parse_rejects_unpadded_fields() raises:
    _assert_date_parse_rejected("2024-1-2")


def test_date_parse_rejects_slash_form() raises:
    _assert_date_parse_rejected("01/02/2024")


def test_date_parse_rejects_dotted_form() raises:
    _assert_date_parse_rejected("02.01.2024")


def test_date_parse_rejects_trailing_space() raises:
    _assert_date_parse_rejected("2024-01-02 ")


def test_date_parse_rejects_iso_t_separator() raises:
    _assert_date_parse_rejected("2024-01-02T00:00:00")


def test_date_parse_rejects_empty_text() raises:
    _assert_date_parse_rejected("")


def test_date_parse_rejects_capitalised_infinity() raises:
    _assert_date_parse_rejected("Infinity")


# --- Timestamp.from_ymd_hms microsecond counts -------------------------------


def test_timestamp_from_ymd_hms_epoch() raises:
    var value = _ts_hms_default_us(2000, 1, 1, 0, 0, 0)
    assert_equal(value.micros, Int64(0))
    _assert_timestamp_parts(value, 2000, 1, 1, 0, 0, 0, 0)


def test_timestamp_from_ymd_hms_with_microseconds() raises:
    _assert_timestamp(2024, 1, 2, 3, 4, 5, 678901, 0x0002B0EC85204F35)


def test_timestamp_from_ymd_hms_last_microsecond_before_1970() raises:
    _assert_timestamp(1969, 12, 31, 23, 59, 59, 999999, -946684800000001)


def test_timestamp_from_ymd_hms_year_zero_is_one_bc() raises:
    _assert_timestamp(0, 1, 1, 0, 0, 0, 0, -0xE039C2E44EE000)


def test_timestamp_from_ymd_hms_julian_year() raises:
    _assert_timestamp(-4712, 1, 1, 0, 0, 0, 0, -0x2F0804250E82000)


def test_timestamp_from_ymd_hms_highest_value() raises:
    _assert_timestamp(294276, 12, 31, 23, 59, 59, 999999, 0x7FFFFF5BB3B29FFF)


def test_timestamp_from_ymd_hms_five_digit_year() raises:
    _assert_timestamp(10000, 1, 1, 0, 0, 0, 0, 0x0380E70B913B8000)


# --- Timestamp text and parse ------------------------------------------------


def test_timestamp_text_epoch() raises:
    _assert_timestamp_text(0, "2000-01-01 00:00:00")


def test_timestamp_text_with_microseconds() raises:
    _assert_timestamp_text(0x0002B0EC85204F35, "2024-01-02 03:04:05.678901")


def test_timestamp_text_last_microsecond_before_1970() raises:
    _assert_timestamp_text(-946684800000001, "1969-12-31 23:59:59.999999")


def test_timestamp_text_one_bc() raises:
    _assert_timestamp_text(-0xE039C2E44EE000, "0001-01-01 00:00:00 BC")


def test_timestamp_text_highest_value() raises:
    _assert_timestamp_text(0x7FFFFF5BB3B29FFF, "294276-12-31 23:59:59.999999")


def test_timestamp_text_trims_trailing_fraction_zeroes() raises:
    _assert_timestamp_text(5500000, "2000-01-01 00:00:05.5")


def test_timestamp_text_single_microsecond() raises:
    _assert_timestamp_text(1, "2000-01-01 00:00:00.000001")


def test_timestamp_text_infinity() raises:
    assert_equal(String(Timestamp.infinity()), "infinity")
    assert_true(_ts_parsed("infinity") == Timestamp.infinity())


def test_timestamp_text_negative_infinity() raises:
    assert_equal(String(Timestamp.negative_infinity()), "-infinity")
    assert_true(_ts_parsed("-infinity") == Timestamp.negative_infinity())


def test_timestamp_parse_fraction_digit_counts() raises:
    var half = _ts_parsed("2000-01-01 00:00:05.5")
    assert_equal(_ts_parts(half)[6], 500000)
    var tiny = _ts_parsed("2000-01-01 00:00:00.000001")
    assert_equal(_ts_parts(tiny)[6], 1)
    var full = _ts_parsed("2024-01-02 03:04:05.123456")
    assert_equal(_ts_parts(full)[6], 123456)


# --- Timestamp.from_ymd_hms rejections ---------------------------------------


def test_timestamp_rejects_hour_24() raises:
    _assert_timestamp_rejected(2024, 1, 1, 24, 0, 0, 0)


def test_timestamp_rejects_minute_60() raises:
    _assert_timestamp_rejected(2024, 1, 1, 0, 60, 0, 0)


def test_timestamp_rejects_second_60() raises:
    _assert_timestamp_rejected(2024, 1, 1, 0, 0, 60, 0)


def test_timestamp_rejects_microsecond_overflow() raises:
    _assert_timestamp_rejected(2024, 1, 1, 0, 0, 0, 1000000)


def test_timestamp_rejects_year_above_maximum() raises:
    _assert_timestamp_rejected(294277, 1, 1, 0, 0, 0, 0)


# --- Timestamp.parse rejections ----------------------------------------------


def test_timestamp_parse_rejects_seven_fraction_digits() raises:
    _assert_timestamp_parse_rejected("2024-01-02 03:04:05.1234567")


def test_timestamp_parse_rejects_date_without_time() raises:
    _assert_timestamp_parse_rejected("2024-01-02")


def test_timestamp_parse_rejects_hour_25() raises:
    _assert_timestamp_parse_rejected("2024-01-02 25:00:00")


# --- TimestampTz parse -------------------------------------------------------


def test_timestamptz_parse_utc_offset() raises:
    var value = _tstz_parsed("2024-01-02 03:04:05.678901+00")
    assert_equal(value.micros, Int64(0x0002B0EC85204F35))


def test_timestamptz_parse_offsets_agree() raises:
    var utc = _tstz_parsed("2024-01-02 03:04:05.678901+00")
    assert_true(_tstz_parsed("2024-01-02 12:04:05.678901+09") == utc)
    assert_true(_tstz_parsed("2024-01-02 08:34:05.678901+05:30") == utc)
    assert_true(_tstz_parsed("2024-01-01 23:34:05.678901-03:30") == utc)
    assert_true(_tstz_parsed("2024-01-02 08:57:33.678901+05:53:28") == utc)


def test_timestamptz_parse_one_bc() raises:
    var value = _tstz_parsed("0001-01-01 00:00:00+00 BC")
    assert_equal(value.micros, Int64(-0xE039C2E44EE000))


def test_timestamptz_parse_offset_with_seconds() raises:
    var left = _tstz_parsed("2024-01-02 06:04:35+00")
    var right = _tstz_parsed("2024-01-02 03:04:05-03:00:30")
    assert_true(left == right)
    assert_false(left != right)


# --- TimestampTz text --------------------------------------------------------


def test_timestamptz_text_with_microseconds() raises:
    assert_equal(
        String(TimestampTz(0x0002B0EC85204F35)),
        "2024-01-02 03:04:05.678901+00",
    )


def test_timestamptz_text_one_bc() raises:
    assert_equal(
        String(TimestampTz(-0xE039C2E44EE000)),
        "0001-01-01 00:00:00+00 BC",
    )


def test_timestamptz_text_infinity() raises:
    assert_equal(String(TimestampTz.infinity()), "infinity")
    assert_true(_tstz_parsed("infinity") == TimestampTz.infinity())


def test_timestamptz_text_negative_infinity() raises:
    assert_equal(String(TimestampTz.negative_infinity()), "-infinity")
    assert_true(_tstz_parsed("-infinity") == TimestampTz.negative_infinity())


def test_timestamptz_from_utc_matches_parse() raises:
    var value = _tstz_utc(2024, 1, 2, 3, 4, 5, 678901)
    assert_equal(value.micros, Int64(0x0002B0EC85204F35))
    assert_true(value == _tstz_parsed("2024-01-02 03:04:05.678901+00"))


# --- TimestampTz.parse rejections --------------------------------------------


def test_timestamptz_parse_rejects_missing_offset() raises:
    _assert_tstz_parse_rejected("2024-01-02 03:04:05")


def test_timestamptz_parse_rejects_offset_out_of_range() raises:
    _assert_tstz_parse_rejected("2024-01-02 03:04:05+16")


# --- Time helpers ------------------------------------------------------------


def _time_hms(h: Int, mi: Int, s: Int, us: Int) raises -> Time:
    """Build a `Time` from its components, raising a plain `Error`.

    Args:
        h: Hour, 0 to 24.
        mi: Minute, 0 to 59.
        s: Second, 0 to 59.
        us: Microsecond, 0 to 999999.

    Returns:
        The constructed `Time`.

    Raises:
        Error: If `Time.from_hms` raised a `PgError`.
    """
    try:
        return Time.from_hms(h, mi, s, us)
    except e:
        raise Error(String(e))


def _time_hms_default_us(h: Int, mi: Int, s: Int) raises -> Time:
    """Build a `Time` leaving the microsecond argument defaulted.

    Args:
        h: Hour, 0 to 24.
        mi: Minute, 0 to 59.
        s: Second, 0 to 59.

    Returns:
        The constructed `Time`.

    Raises:
        Error: If `Time.from_hms` raised a `PgError`.
    """
    try:
        return Time.from_hms(h, mi, s)
    except e:
        raise Error(String(e))


def _time_parsed(text: String) raises -> Time:
    """Decode `text` with `Time.parse`, raising a plain `Error`.

    Args:
        text: The text to decode.

    Returns:
        The decoded `Time`.

    Raises:
        Error: If `Time.parse` raised a `PgError`.
    """
    try:
        return Time.parse(text)
    except e:
        raise Error(String(e))


def _assert_time_text(micros: Int64, text: String) raises:
    """Assert `Time(micros)` prints as `text` and `text` parses back.

    Args:
        micros: Raw microseconds since midnight, 0 to 86400000000.
        text: The text PostgreSQL prints for that count.

    Raises:
        Error: If printing or parsing disagreed.
    """
    var value = Time(micros)
    assert_equal(String(value), text)
    var decoded = _time_parsed(text)
    assert_equal(decoded.micros, micros)
    assert_true(decoded == value)
    assert_false(decoded != value)


def _assert_time_rejected(h: Int, mi: Int, s: Int, us: Int) raises:
    """Assert `Time.from_hms` refuses the components with `USAGE`.

    Args:
        h: Hour that must be refused.
        mi: Minute that must be refused.
        s: Second that must be refused.
        us: Microsecond that must be refused.

    Raises:
        Error: If the call succeeded or reported the wrong kind or
            message.
    """
    try:
        _ = Time.from_hms(h, mi, s, us)
    except e:
        assert_equal(e.kind, PgErrorKind.USAGE)
        assert_true("invalid time" in e.message)
        return
    raise Error("expected PgError from Time.from_hms")


def _assert_time_parse_rejected(text: String) raises:
    """Assert `Time.parse` refuses `text` with `TYPE_MISMATCH`.

    Args:
        text: Text outside the accepted time grammar.

    Raises:
        Error: If the call succeeded or reported the wrong kind or
            message.
    """
    try:
        _ = Time.parse(text)
    except e:
        assert_equal(e.kind, PgErrorKind.TYPE_MISMATCH)
        assert_true("cannot decode" in e.message)
        return
    raise Error(String('expected PgError for "', text, '"'))


# --- TimeTz helpers ----------------------------------------------------------


def _timetz_parsed(text: String) raises -> TimeTz:
    """Decode `text` with `TimeTz.parse`, raising a plain `Error`.

    Args:
        text: The text to decode, offset included.

    Returns:
        The decoded `TimeTz`.

    Raises:
        Error: If `TimeTz.parse` raised a `PgError`.
    """
    try:
        return TimeTz.parse(text)
    except e:
        raise Error(String(e))


def _assert_timetz_text(micros: Int64, offset_secs: Int32, text: String) raises:
    """Assert `TimeTz` prints as `text` and `text` parses back to it.

    Args:
        micros: Raw microseconds since midnight in the printed zone.
        offset_secs: Zone offset in seconds, positive west of UTC.
        text: The text PostgreSQL prints for that pair.

    Raises:
        Error: If printing or parsing disagreed.
    """
    var value = TimeTz(micros, offset_secs)
    assert_equal(String(value), text)
    var decoded = _timetz_parsed(text)
    assert_equal(decoded.micros, micros)
    assert_equal(decoded.offset_secs, offset_secs)
    assert_true(decoded == value)
    assert_false(decoded != value)


def _assert_timetz_rejected(
    h: Int, mi: Int, s: Int, us: Int, offset_secs: Int
) raises:
    """Assert `TimeTz.from_hms` refuses the components with `USAGE`.

    Args:
        h: Hour that must be refused.
        mi: Minute that must be refused.
        s: Second that must be refused.
        us: Microsecond that must be refused.
        offset_secs: Zone offset in seconds that must be refused.

    Raises:
        Error: If the call succeeded or reported the wrong kind or
            message.
    """
    try:
        _ = TimeTz.from_hms(h, mi, s, us, offset_secs)
    except e:
        assert_equal(e.kind, PgErrorKind.USAGE)
        assert_true("invalid timetz" in e.message)
        return
    raise Error("expected PgError from TimeTz.from_hms")


def _assert_timetz_parse_rejected(text: String) raises:
    """Assert `TimeTz.parse` refuses `text` with `TYPE_MISMATCH`.

    Args:
        text: Text outside the accepted timetz grammar.

    Raises:
        Error: If the call succeeded or reported the wrong kind or
            message.
    """
    try:
        _ = TimeTz.parse(text)
    except e:
        assert_equal(e.kind, PgErrorKind.TYPE_MISMATCH)
        assert_true("cannot decode" in e.message)
        return
    raise Error(String('expected PgError for "', text, '"'))


# --- Interval helpers --------------------------------------------------------


def _interval_parsed(text: String) raises -> Interval:
    """Decode `text` with `Interval.parse`, raising a plain `Error`.

    Args:
        text: The text to decode.

    Returns:
        The decoded `Interval`.

    Raises:
        Error: If `Interval.parse` raised a `PgError`.
    """
    try:
        return Interval.parse(text)
    except e:
        raise Error(String(e))


def _assert_interval_text(
    micros: Int64, days: Int32, months: Int32, text: String
) raises:
    """Assert the `Interval` prints as `text` and `text` parses back.

    Args:
        micros: Microsecond field of the interval.
        days: Day field of the interval, kept separate from `micros`.
        months: Month field of the interval.
        text: The text PostgreSQL prints for that triple.

    Raises:
        Error: If printing or parsing disagreed.
    """
    var value = Interval(micros, days, months)
    assert_equal(String(value), text)
    var decoded = _interval_parsed(text)
    assert_equal(decoded.micros, micros)
    assert_equal(decoded.days, days)
    assert_equal(decoded.months, months)
    assert_true(decoded == value)
    assert_false(decoded != value)


def _assert_interval_parse_rejected(text: String) raises:
    """Assert `Interval.parse` refuses `text` with `TYPE_MISMATCH`.

    Args:
        text: Text outside the accepted interval grammar.

    Raises:
        Error: If the call succeeded or reported the wrong kind or
            message.
    """
    try:
        _ = Interval.parse(text)
    except e:
        assert_equal(e.kind, PgErrorKind.TYPE_MISMATCH)
        assert_true("cannot decode" in e.message)
        return
    raise Error(String('expected PgError for "', text, '"'))


# --- Time text and parse -----------------------------------------------------


def test_time_text_midnight() raises:
    _assert_time_text(0, "00:00:00")


def test_time_text_end_of_day() raises:
    _assert_time_text(86400000000, "24:00:00")


def test_time_text_last_microsecond_of_day() raises:
    _assert_time_text(86399999999, "23:59:59.999999")


def test_time_text_trims_trailing_fraction_zeroes() raises:
    _assert_time_text(0x0000000A8BE1BD20, "12:34:56.5")


# --- Time.from_hms microsecond counts ----------------------------------------


def test_time_from_hms_with_microseconds() raises:
    assert_equal(_time_hms(12, 34, 56, 500000).micros, Int64(45296500000))


def test_time_from_hms_accepts_hour_24() raises:
    assert_equal(_time_hms_default_us(24, 0, 0).micros, Int64(86400000000))


# --- Time.from_hms rejections ------------------------------------------------


def test_time_rejects_past_end_of_day() raises:
    _assert_time_rejected(24, 0, 1, 0)


def test_time_rejects_minute_60() raises:
    _assert_time_rejected(23, 60, 0, 0)


def test_time_rejects_second_60() raises:
    _assert_time_rejected(0, 0, 60, 0)


def test_time_rejects_microsecond_overflow() raises:
    _assert_time_rejected(0, 0, 0, 1000000)


def test_time_rejects_negative_hour() raises:
    _assert_time_rejected(-1, 0, 0, 0)


# --- Time.parse rejections ---------------------------------------------------


def test_time_parse_rejects_past_end_of_day() raises:
    _assert_time_parse_rejected("24:00:01")


def test_time_parse_rejects_unpadded_hour() raises:
    _assert_time_parse_rejected("1:00:00")


def test_time_parse_rejects_missing_seconds() raises:
    _assert_time_parse_rejected("12:34")


def test_time_parse_rejects_seven_fraction_digits() raises:
    _assert_time_parse_rejected("12:34:56.1234567")


# --- Time accessors ----------------------------------------------------------


def test_time_accessors() raises:
    var value = Time(45296500000)
    assert_equal(value.hour(), 12)
    assert_equal(value.minute(), 34)
    assert_equal(value.second(), 56)
    assert_equal(value.microsecond(), 500000)


# --- TimeTz text and parse ---------------------------------------------------


def test_timetz_text_whole_hour_offset() raises:
    _assert_timetz_text(45296000000, -32400, "12:34:56+09")


def test_timetz_text_offset_with_seconds() raises:
    _assert_timetz_text(43200000000, -21208, "12:00:00+05:53:28")


def test_timetz_text_negative_offset() raises:
    _assert_timetz_text(43200000000, 12600, "12:00:00-03:30")


def test_timetz_text_one_second_offset() raises:
    _assert_timetz_text(0, -1, "00:00:00+00:00:01")


def test_timetz_text_lowest_offset() raises:
    _assert_timetz_text(43200000000, 57540, "12:00:00-15:59")


def test_timetz_text_highest_offset() raises:
    _assert_timetz_text(43200000000, -57599, "12:00:00+15:59:59")


def test_timetz_text_zero_offset() raises:
    assert_equal(String(TimeTz(0, 0)), "00:00:00+00")


def test_timetz_parse_accepts_end_of_day() raises:
    assert_true(_timetz_parsed("24:00:00+09") == TimeTz(86400000000, -32400))


# --- TimeTz rejections -------------------------------------------------------


def test_timetz_rejects_offset_above_maximum() raises:
    _assert_timetz_rejected(12, 0, 0, 0, 57600)


def test_timetz_rejects_offset_below_minimum() raises:
    _assert_timetz_rejected(12, 0, 0, 0, -57600)


def test_timetz_parse_rejects_offset_out_of_range() raises:
    _assert_timetz_parse_rejected("12:00:00+16")


# --- Interval text and parse -------------------------------------------------


def test_interval_text_zero() raises:
    _assert_interval_text(0, 0, 0, "00:00:00")


def test_interval_text_one_day() raises:
    _assert_interval_text(0, 1, 0, "1 day")


def test_interval_text_minus_one_day() raises:
    _assert_interval_text(0, -1, 0, "-1 days")


def test_interval_text_one_month() raises:
    _assert_interval_text(0, 0, 1, "1 mon")


def test_interval_text_minus_eleven_months() raises:
    _assert_interval_text(0, 0, -11, "-11 mons")


def test_interval_text_one_year() raises:
    _assert_interval_text(0, 0, 12, "1 year")


def test_interval_text_two_years_one_month() raises:
    _assert_interval_text(0, 0, 25, "2 years 1 mon")


def test_interval_text_minus_one_second() raises:
    _assert_interval_text(-1000000, 0, 0, "-00:00:01")


def test_interval_text_minus_half_second() raises:
    _assert_interval_text(-500000, 0, 0, "-00:00:00.5")


def test_interval_text_hours_beyond_one_day() raises:
    _assert_interval_text(360000000000, 0, 0, "100:00:00")


def test_interval_text_largest_micros() raises:
    _assert_interval_text(9223372036854775807, 0, 0, "2562047788:00:54.775807")


def test_interval_text_day_and_time() raises:
    _assert_interval_text(43200000000, 1, 0, "1 day 12:00:00")


def test_interval_text_minus_day_plus_time() raises:
    _assert_interval_text(7200000000, -1, 0, "-1 days +02:00:00")


def test_interval_text_minus_day_plus_second() raises:
    _assert_interval_text(1000000, -1, 0, "-1 days +00:00:01")


def test_interval_text_minus_year_plus_day() raises:
    _assert_interval_text(0, 1, -12, "-1 years +1 day")


def test_interval_text_month_minus_day() raises:
    _assert_interval_text(0, -1, 1, "1 mon -1 days")


def test_interval_text_all_fields() raises:
    _assert_interval_text(
        14706789000, 3, 14, "1 year 2 mons 3 days 04:05:06.789"
    )


def test_interval_text_all_fields_negative() raises:
    _assert_interval_text(
        -14706789000, -3, -14, "-1 years -2 mons -3 days -04:05:06.789"
    )


# --- Interval infinities -----------------------------------------------------


def test_interval_text_infinity() raises:
    assert_equal(String(Interval.infinity()), "infinity")
    assert_true(_interval_parsed("infinity") == Interval.infinity())


def test_interval_text_negative_infinity() raises:
    assert_equal(String(Interval.negative_infinity()), "-infinity")
    assert_true(_interval_parsed("-infinity") == Interval.negative_infinity())


def test_interval_infinity_predicates() raises:
    var value = Interval.infinity()
    assert_equal(value.micros, Int64.MAX)
    assert_equal(value.days, Int32.MAX)
    assert_equal(value.months, Int32.MAX)
    assert_true(value.is_infinite())
    assert_false(value.is_finite())


def test_interval_negative_infinity_predicates() raises:
    var value = Interval.negative_infinity()
    assert_equal(value.micros, Int64.MIN)
    assert_equal(value.days, Int32.MIN)
    assert_equal(value.months, Int32.MIN)
    assert_true(value.is_infinite())
    assert_false(value.is_finite())


def test_interval_largest_micros_is_finite() raises:
    var value = Interval(Int64.MAX, 0, 0)
    assert_false(value.is_infinite())
    assert_true(value.is_finite())


# --- Interval.parse rejections -----------------------------------------------


def test_interval_parse_rejects_empty_text() raises:
    _assert_interval_parse_rejected("")


def test_interval_parse_rejects_week_unit() raises:
    _assert_interval_parse_rejected("1 week")


def test_interval_parse_rejects_repeated_unit() raises:
    _assert_interval_parse_rejected("1 day 1 day")


def test_interval_parse_rejects_iso8601_form() raises:
    _assert_interval_parse_rejected("P1D")


def test_interval_parse_rejects_time_without_seconds() raises:
    _assert_interval_parse_rejected("1 days 02:00")


def test_interval_parse_rejects_leading_plus() raises:
    _assert_interval_parse_rejected("+1 day")


def test_interval_parse_rejects_trailing_space() raises:
    _assert_interval_parse_rejected("1 year ")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
