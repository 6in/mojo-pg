"""Date, time and interval value types for PostgreSQL's temporal columns.

Holds `Date`, `Timestamp` and `TimestampTz`, each wrapping exactly the
integer PostgreSQL keeps on the wire: a day count for `date` and a
microsecond count for `timestamp` and `timestamptz`, both counted from the
PostgreSQL epoch 2000-01-01. The two sentinels a temporal column can carry,
`infinity` and `-infinity`, are the extreme values of that integer, so every
accessor that takes a value apart refuses them instead of reporting a
nonsensical calendar date.

Holds `Time`, `TimeTz` and `Interval` as well. The first two count
microseconds from midnight instead, `TimeTz` pairing that count with a UTC
offset the way the server does rather than folding it away, and neither has
an `infinity` to refuse. `Interval` keeps its months, days and microseconds
apart, since none of the three converts into another at a fixed rate, and
spells its sentinels with all three fields at once.

Years are astronomical, as PostgreSQL's own internals are: 1 BC is year 0
and 2 BC is year -1, the ` BC` suffix appears only in text, and the calendar
is proleptic Gregorian all the way back.

This module is a leaf: it imports only `pq.errors`, so both the text and the
binary decoder can depend on it.
"""

from pq.errors import PgError, PgErrorKind

comptime _PG_EPOCH_UNIX_DAYS = 10957
"""Days from the Unix epoch 1970-01-01 to the PostgreSQL epoch 2000-01-01."""

comptime _USECS_PER_DAY = 86400000000
"""Microseconds in a day. No PostgreSQL timestamp counts leap seconds."""

comptime _USECS_PER_HOUR = 3600000000
"""Microseconds in an hour."""

comptime _USECS_PER_MINUTE = 60000000
"""Microseconds in a minute."""

comptime _USECS_PER_SECOND = 1000000
"""Microseconds in a second."""

comptime _MIN_DATE_DAYS = -2451545
"""Day count of 4714-11-24 BC, the earliest `date` PostgreSQL stores."""

comptime _MAX_DATE_DAYS = 2145031948
"""Day count of 5874897-12-31, the latest `date` PostgreSQL stores."""

comptime _MIN_TS_DAYS = -2451545
"""Day count of 4714-11-24 BC, the earliest timestamp day."""

comptime _MAX_TS_DAYS = 106751982
"""Day count of 294276-12-31, the latest timestamp day."""

comptime _MIN_TS_MICROS = -211813488000000000
"""Microseconds of 4714-11-24 00:00:00 BC, the earliest timestamp."""

comptime _MAX_TS_MICROS = 9223371331199999999
"""Microseconds of 294276-12-31 23:59:59.999999, the latest timestamp."""

comptime _MAX_OFFSET_SECONDS = 57600
"""The first time zone offset too wide to accept: 16 hours, in seconds."""

comptime _MAX_YEAR_DIGITS = 9
"""Digits a parsed year may carry, which keeps day counts well in range."""

comptime _YEAR_GUARD = 6000000
"""Years further from zero than this are refused before any arithmetic."""

comptime _BAD = Int.MIN
"""Sentinel returned by `_parse_ymd` for text it will not accept."""

comptime _CH_ZERO = UInt8(ord("0"))
comptime _CH_NINE = UInt8(ord("9"))
comptime _CH_DOT = UInt8(ord("."))
comptime _CH_DASH = UInt8(ord("-"))
comptime _CH_PLUS = UInt8(ord("+"))
comptime _CH_COLON = UInt8(ord(":"))
comptime _CH_SPACE = UInt8(ord(" "))
comptime _CH_UPPER_B = UInt8(ord("B"))
comptime _CH_UPPER_C = UInt8(ord("C"))


def _usage_error(pg_type: String, detail: String) -> PgError:
    """Build the `USAGE` error a checked constructor raises."""
    return PgError(
        PgErrorKind.USAGE,
        String("invalid ", pg_type, ": ", detail),
    )


def _decode_error(pg_type: String, text: String) -> PgError:
    """Build the `TYPE_MISMATCH` error for text that does not parse."""
    return PgError(
        PgErrorKind.TYPE_MISMATCH,
        String('cannot decode "', text, '" as ', pg_type),
    )


def _infinite_error(pg_type: String, accessor: String) -> PgError:
    """Build the `USAGE` error an accessor raises on a sentinel value."""
    return PgError(
        PgErrorKind.USAGE,
        String(pg_type, " is infinite; ", accessor, "() is undefined"),
    )


def _is_digit(byte: UInt8) -> Bool:
    """Return True when `byte` is one of the ASCII digits `0` to `9`."""
    return byte >= _CH_ZERO and byte <= _CH_NINE


def _days_from_civil(y: Int, m: Int, d: Int) -> Int:
    """Return the day count of `y-m-d` from the PostgreSQL epoch.

    Howard Hinnant's `days_from_civil`, written with Mojo's flooring `//`
    rather than the C version's explicit `y < 0` branch: `//` already floors,
    so branching as well would floor twice and shift every date before
    0000-03-01 by a day. `y` is astronomical and `m` and `d` are assumed
    valid, which every caller checks first.
    """
    var yy = y - 1 if m <= 2 else y
    var era = yy // 400
    var yoe = yy - era * 400
    var mp = m - 3 if m > 2 else m + 9
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468 - _PG_EPOCH_UNIX_DAYS


def _civil_from_days(days: Int) -> Tuple[Int, Int, Int]:
    """Return the astronomical year, month and day of a PostgreSQL day count.

    The exact inverse of `_days_from_civil`, and flooring for the same
    reason.
    """
    var z = days + _PG_EPOCH_UNIX_DAYS + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return (y, m, d)


def _is_leap(y: Int) -> Bool:
    """Report whether astronomical year `y` is a proleptic Gregorian leap."""
    if y % 4 != 0:
        return False
    if y % 100 != 0:
        return True
    return y % 400 == 0


def _days_in_month(y: Int, m: Int) -> Int:
    """Return the length of month `m` of year `y`, or 0 if `m` is not 1-12."""
    if m == 1 or m == 3 or m == 5 or m == 7 or m == 8 or m == 10 or m == 12:
        return 31
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    if m == 2:
        return 29 if _is_leap(y) else 28
    return 0


def _pad2(value: Int) -> String:
    """Return `value` as exactly two decimal digits, zero padded."""
    var out = String()
    out += String(value // 10)
    out += String(value % 10)
    return out^


def _format_date(y: Int, m: Int, d: Int, mut writer: Some[Writer]):
    """Write astronomical `y-m-d` as `YYYY-MM-DD`, without any ` BC`.

    The year is printed the way PostgreSQL prints it: year 0 reads `0001`,
    year -1 reads `0002`, and the caller is the one that appends ` BC`.
    Years of five digits or more are printed in full, so the field is zero
    padded to four digits but never truncated.
    """
    var display = 1 - y if y <= 0 else y
    var text = String(display)
    for _ in range(4 - text.byte_length()):
        writer.write("0")
    writer.write(text, "-", _pad2(m), "-", _pad2(d))


def _format_time_of_day(micros_in_day: Int, mut writer: Some[Writer]):
    """Write a non-negative microsecond offset as `HH:MM:SS[.f]`.

    The fractional part is omitted when it is zero and has its trailing
    zeroes stripped otherwise, matching PostgreSQL's output. An offset of a
    whole day is written `24:00:00` rather than wrapping to zero.
    """
    var hour = micros_in_day // _USECS_PER_HOUR
    var rest = micros_in_day % _USECS_PER_HOUR
    var minute = rest // _USECS_PER_MINUTE
    rest = rest % _USECS_PER_MINUTE
    var second = rest // _USECS_PER_SECOND
    var micros = rest % _USECS_PER_SECOND
    writer.write(_pad2(hour), ":", _pad2(minute), ":", _pad2(second))
    if micros == 0:
        return
    var digits = String()
    var value = micros
    var scale = 100000
    while scale > 0:
        digits += String(value // scale)
        value = value % scale
        scale //= 10
    var bytes = digits.as_bytes()
    var length = 6
    while length > 1 and bytes[length - 1] == _CH_ZERO:
        length -= 1
    writer.write(".", digits[byte=0:length])


def _parse_fraction(digits: String) -> Int:
    """Return the microseconds a fractional second's digits spell, or -1.

    `digits` is the run of digits after the decimal point, without the point
    itself. One to six digits are accepted and scaled by `10 ** (6 - n)`, so
    `"5"` is 500000 and `"000001"` is 1. Anything else, including an empty
    run, gives -1.
    """
    var n = digits.byte_length()
    if n == 0 or n > 6:
        return -1
    var bytes = digits.as_bytes()
    var value = 0
    for i in range(n):
        if not _is_digit(bytes[i]):
            return -1
        value = value * 10 + Int(bytes[i] - _CH_ZERO)
    for _ in range(6 - n):
        value *= 10
    return value


def _parse_hms(text: String, start: Int) -> Int:
    """Read exactly `HH:MM:SS` at byte `start`, as microseconds, or -1.

    Each field is read by digit position, so no sign, no padding variant and
    no single-digit field is tolerated. The hour may be 24, which is a valid
    `time` even though it is never a valid timestamp, and the caller is the
    one that narrows it. -1 covers every other shape, including text too
    short to hold the eight bytes.
    """
    if start < 0 or start + 8 > text.byte_length():
        return -1
    var b = text.as_bytes()
    if b[start + 2] != _CH_COLON or b[start + 5] != _CH_COLON:
        return -1
    for offset in [0, 1, 3, 4, 6, 7]:
        if not _is_digit(b[start + offset]):
            return -1
    var hour = Int(b[start] - _CH_ZERO) * 10 + Int(b[start + 1] - _CH_ZERO)
    var minute = Int(b[start + 3] - _CH_ZERO) * 10 + Int(
        b[start + 4] - _CH_ZERO
    )
    var second = Int(b[start + 6] - _CH_ZERO) * 10 + Int(
        b[start + 7] - _CH_ZERO
    )
    if hour > 24 or minute > 59 or second > 59:
        return -1
    return (
        hour * _USECS_PER_HOUR
        + minute * _USECS_PER_MINUTE
        + second * _USECS_PER_SECOND
    )


def _parse_ymd(text: String, end: Int, is_bc: Bool) -> Int:
    """Read `YYYY-MM-DD` from byte 0 up to `end`, as a day count, or `_BAD`.

    The year is four to nine digits, the month and day exactly two each, and
    `end` must fall right after the day, so a trailing space or a `T` is
    refused here rather than being skipped. `is_bc` turns the displayed year
    into an astronomical one. A displayed year of zero is refused, since
    PostgreSQL has no such year, and the resulting date must exist in the
    proleptic Gregorian calendar.
    """
    if end < 10:
        return _BAD
    var b = text.as_bytes()
    var p = 0
    while p < end and _is_digit(b[p]):
        p += 1
    var year_digits = p
    if year_digits < 4 or year_digits > _MAX_YEAR_DIGITS:
        return _BAD
    if end - p != 6:
        return _BAD
    if b[p] != _CH_DASH or b[p + 3] != _CH_DASH:
        return _BAD
    for offset in [1, 2, 4, 5]:
        if not _is_digit(b[p + offset]):
            return _BAD
    var display_year = 0
    for i in range(year_digits):
        display_year = display_year * 10 + Int(b[i] - _CH_ZERO)
    if display_year == 0:
        return _BAD
    var month = Int(b[p + 1] - _CH_ZERO) * 10 + Int(b[p + 2] - _CH_ZERO)
    var day = Int(b[p + 4] - _CH_ZERO) * 10 + Int(b[p + 5] - _CH_ZERO)
    var y = 1 - display_year if is_bc else display_year
    if month < 1 or month > 12:
        return _BAD
    if day < 1 or day > _days_in_month(y, month):
        return _BAD
    return _days_from_civil(y, month, day)


def _strip_bc(text: String) -> Int:
    """Return the byte length of `text` without a trailing ` BC`."""
    var n = text.byte_length()
    if n < 3:
        return n
    var b = text.as_bytes()
    if (
        b[n - 3] == _CH_SPACE
        and b[n - 2] == _CH_UPPER_B
        and b[n - 1] == _CH_UPPER_C
    ):
        return n - 3
    return n


@fieldwise_init
struct Date(Copyable, Equatable, Movable, Writable):
    """A PostgreSQL `date`, held as its day count from 2000-01-01.

    The raw field is public and the fieldwise constructor checks nothing, so
    a decoder can hand over whatever the server sent, including the two
    sentinels `Int32.MAX` and `Int32.MIN` that spell `infinity` and
    `-infinity`. Use `from_ymd` to build a checked value from a calendar
    date.
    """

    var days: Int32
    """Days from the PostgreSQL epoch 2000-01-01, or a sentinel."""

    @staticmethod
    def infinity() -> Self:
        """Return the `date` that compares later than every other.

        Returns:
            The `infinity` sentinel.
        """
        return Self(Int32.MAX)

    @staticmethod
    def negative_infinity() -> Self:
        """Return the `date` that compares earlier than every other.

        Returns:
            The `-infinity` sentinel.
        """
        return Self(Int32.MIN)

    @staticmethod
    def from_ymd(y: Int, m: Int, d: Int) raises PgError -> Self:
        """Build a `date` from an astronomical year, month and day.

        The year is astronomical: 1 BC is 0 and 2 BC is -1, matching what
        the accessors return.

        Args:
            y: Astronomical year.
            m: Month, 1 to 12.
            d: Day of month, 1 to the length of that month.

        Returns:
            The `Date` for that calendar date.

        Raises:
            PgError: `PgErrorKind.USAGE` when the three fields are not a
                real date, or when it falls outside 4714-11-24 BC to
                5874897-12-31.
        """
        if y < -_YEAR_GUARD or y > _YEAR_GUARD:
            raise _usage_error("date", String("year ", y))
        if m < 1 or m > 12:
            raise _usage_error("date", String("month ", m))
        if d < 1 or d > _days_in_month(y, m):
            raise _usage_error("date", String("day ", d))
        var days = _days_from_civil(y, m, d)
        if days < _MIN_DATE_DAYS or days > _MAX_DATE_DAYS:
            raise _usage_error("date", "value out of range")
        return Self(Int32(days))

    @staticmethod
    def parse(text: String) raises PgError -> Self:
        """Decode the text form of a `date`.

        Accepts `YYYY-MM-DD` with an optional trailing ` BC`, plus the two
        sentinel spellings `infinity` and `-infinity`. The grammar is exact:
        no leading sign, no surrounding space, no single-digit month or day,
        no time part and no alternative separator.

        Args:
            text: The text the server printed.

        Returns:
            The decoded `Date`.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `text` is not that
                form, is not a real date, or is out of range.
        """
        if text == "infinity":
            return Self.infinity()
        if text == "-infinity":
            return Self.negative_infinity()
        var end = _strip_bc(text)
        var is_bc = end != text.byte_length()
        var days = _parse_ymd(text, end, is_bc)
        if days == _BAD:
            raise _decode_error("date", text)
        if days < _MIN_DATE_DAYS or days > _MAX_DATE_DAYS:
            raise _decode_error("date", text)
        return Self(Int32(days))

    def is_infinite(self) -> Bool:
        """Report whether this is `infinity` or `-infinity`.

        Returns:
            True for either sentinel.
        """
        return self.days == Int32.MAX or self.days == Int32.MIN

    def is_finite(self) -> Bool:
        """Report whether this is a real calendar date.

        Returns:
            True for anything but the two sentinels.
        """
        return not self.is_infinite()

    def year(self) raises PgError -> Int:
        """Return the astronomical year, where 1 BC is 0.

        Returns:
            The year.

        Raises:
            PgError: `PgErrorKind.USAGE` when the date is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("date", "year")
        return _civil_from_days(Int(self.days))[0]

    def month(self) raises PgError -> Int:
        """Return the month, 1 to 12.

        Returns:
            The month.

        Raises:
            PgError: `PgErrorKind.USAGE` when the date is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("date", "month")
        return _civil_from_days(Int(self.days))[1]

    def day(self) raises PgError -> Int:
        """Return the day of month, 1 to 31.

        Returns:
            The day of month.

        Raises:
            PgError: `PgErrorKind.USAGE` when the date is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("date", "day")
        return _civil_from_days(Int(self.days))[2]

    def __eq__(self, other: Self) -> Bool:
        """Compare two dates for equality.

        Args:
            other: The date to compare against.

        Returns:
            True if both hold the same day count.
        """
        return self.days == other.days

    def __ne__(self, other: Self) -> Bool:
        """Compare two dates for inequality.

        Args:
            other: The date to compare against.

        Returns:
            True if the day counts differ.
        """
        return self.days != other.days

    def write_to(self, mut writer: Some[Writer]):
        """Write the date the way PostgreSQL prints it.

        Args:
            writer: The writer receiving `YYYY-MM-DD`, a trailing ` BC` for
                years at or before 1 BC, or a sentinel spelling.
        """
        if self.days == Int32.MAX:
            writer.write("infinity")
            return
        if self.days == Int32.MIN:
            writer.write("-infinity")
            return
        var ymd = _civil_from_days(Int(self.days))
        _format_date(ymd[0], ymd[1], ymd[2], writer)
        if ymd[0] <= 0:
            writer.write(" BC")


@fieldwise_init
struct Timestamp(Copyable, Equatable, Movable, Writable):
    """A PostgreSQL `timestamp`, held as microseconds from 2000-01-01.

    The value carries no time zone at all: it is the wall clock reading the
    server stored, and nothing here shifts it. The raw field is public and
    the fieldwise constructor checks nothing, so the sentinels `Int64.MAX`
    and `Int64.MIN` pass through as `infinity` and `-infinity`.
    """

    var micros: Int64
    """Microseconds from the PostgreSQL epoch, or a sentinel."""

    @staticmethod
    def infinity() -> Self:
        """Return the timestamp that compares later than every other.

        Returns:
            The `infinity` sentinel.
        """
        return Self(Int64.MAX)

    @staticmethod
    def negative_infinity() -> Self:
        """Return the timestamp that compares earlier than every other.

        Returns:
            The `-infinity` sentinel.
        """
        return Self(Int64.MIN)

    @staticmethod
    def from_ymd_hms(
        y: Int, m: Int, d: Int, h: Int, mi: Int, s: Int, us: Int = 0
    ) raises PgError -> Self:
        """Build a `timestamp` from a calendar date and a wall clock time.

        Args:
            y: Astronomical year, where 1 BC is 0.
            m: Month, 1 to 12.
            d: Day of month, 1 to the length of that month.
            h: Hour, 0 to 23.
            mi: Minute, 0 to 59.
            s: Second, 0 to 59.
            us: Microsecond within the second, 0 to 999999.

        Returns:
            The `Timestamp` for that reading.

        Raises:
            PgError: `PgErrorKind.USAGE` when a field is out of its range,
                the date is not real, or the result falls outside
                4714-11-24 BC to 294276-12-31.
        """
        if y < -_YEAR_GUARD or y > _YEAR_GUARD:
            raise _usage_error("timestamp", String("year ", y))
        if m < 1 or m > 12:
            raise _usage_error("timestamp", String("month ", m))
        if d < 1 or d > _days_in_month(y, m):
            raise _usage_error("timestamp", String("day ", d))
        if h < 0 or h > 23:
            raise _usage_error("timestamp", String("hour ", h))
        if mi < 0 or mi > 59:
            raise _usage_error("timestamp", String("minute ", mi))
        if s < 0 or s > 59:
            raise _usage_error("timestamp", String("second ", s))
        if us < 0 or us > 999999:
            raise _usage_error("timestamp", String("microsecond ", us))
        var days = _days_from_civil(y, m, d)
        if days < _MIN_TS_DAYS or days > _MAX_TS_DAYS:
            raise _usage_error("timestamp", "value out of range")
        var micros = (
            days * _USECS_PER_DAY
            + h * _USECS_PER_HOUR
            + mi * _USECS_PER_MINUTE
            + s * _USECS_PER_SECOND
            + us
        )
        if micros < _MIN_TS_MICROS or micros > _MAX_TS_MICROS:
            raise _usage_error("timestamp", "value out of range")
        return Self(Int64(micros))

    @staticmethod
    def parse(text: String) raises PgError -> Self:
        """Decode the text form of a `timestamp`.

        Accepts `YYYY-MM-DD HH:MM:SS` with an optional fractional second of
        one to six digits and an optional trailing ` BC`, plus the sentinel
        spellings `infinity` and `-infinity`. The date and the time are
        separated by exactly one space, so the ISO `T` is refused, the hour
        must be 0 to 23, and a bare date carries no time to read.

        Args:
            text: The text the server printed.

        Returns:
            The decoded `Timestamp`.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `text` is not that
                form, is not a real date, or is out of range.
        """
        if text == "infinity":
            return Self.infinity()
        if text == "-infinity":
            return Self.negative_infinity()
        var end = _strip_bc(text)
        var is_bc = end != text.byte_length()
        var b = text.as_bytes()
        var sep = -1
        for i in range(end):
            if b[i] == _CH_SPACE:
                sep = i
                break
        if sep < 0:
            raise _decode_error("timestamp", text)
        var days = _parse_ymd(text, sep, is_bc)
        if days == _BAD or days < _MIN_TS_DAYS or days > _MAX_TS_DAYS:
            raise _decode_error("timestamp", text)
        if sep + 9 > end:
            raise _decode_error("timestamp", text)
        var in_day = _parse_hms(text, sep + 1)
        if in_day < 0 or in_day >= _USECS_PER_DAY:
            raise _decode_error("timestamp", text)
        var fraction = 0
        var p = sep + 9
        if p != end:
            if b[p] != _CH_DOT:
                raise _decode_error("timestamp", text)
            fraction = _parse_fraction(String(text[byte = p + 1 : end]))
            if fraction < 0:
                raise _decode_error("timestamp", text)
        var micros = days * _USECS_PER_DAY + in_day + fraction
        if micros < _MIN_TS_MICROS or micros > _MAX_TS_MICROS:
            raise _decode_error("timestamp", text)
        return Self(Int64(micros))

    def is_infinite(self) -> Bool:
        """Report whether this is `infinity` or `-infinity`.

        Returns:
            True for either sentinel.
        """
        return self.micros == Int64.MAX or self.micros == Int64.MIN

    def is_finite(self) -> Bool:
        """Report whether this is a real reading.

        Returns:
            True for anything but the two sentinels.
        """
        return not self.is_infinite()

    def year(self) raises PgError -> Int:
        """Return the astronomical year, where 1 BC is 0.

        Returns:
            The year.

        Raises:
            PgError: `PgErrorKind.USAGE` when the timestamp is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("timestamp", "year")
        return _civil_from_days(Int(self.micros) // _USECS_PER_DAY)[0]

    def month(self) raises PgError -> Int:
        """Return the month, 1 to 12.

        Returns:
            The month.

        Raises:
            PgError: `PgErrorKind.USAGE` when the timestamp is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("timestamp", "month")
        return _civil_from_days(Int(self.micros) // _USECS_PER_DAY)[1]

    def day(self) raises PgError -> Int:
        """Return the day of month, 1 to 31.

        Returns:
            The day of month.

        Raises:
            PgError: `PgErrorKind.USAGE` when the timestamp is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("timestamp", "day")
        return _civil_from_days(Int(self.micros) // _USECS_PER_DAY)[2]

    def hour(self) raises PgError -> Int:
        """Return the hour of day, 0 to 23.

        Returns:
            The hour.

        Raises:
            PgError: `PgErrorKind.USAGE` when the timestamp is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("timestamp", "hour")
        var in_day = Int(self.micros) % _USECS_PER_DAY
        return in_day // _USECS_PER_HOUR

    def minute(self) raises PgError -> Int:
        """Return the minute of hour, 0 to 59.

        Returns:
            The minute.

        Raises:
            PgError: `PgErrorKind.USAGE` when the timestamp is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("timestamp", "minute")
        var in_day = Int(self.micros) % _USECS_PER_DAY
        return (in_day // _USECS_PER_MINUTE) % 60

    def second(self) raises PgError -> Int:
        """Return the second of minute, 0 to 59.

        Returns:
            The second.

        Raises:
            PgError: `PgErrorKind.USAGE` when the timestamp is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("timestamp", "second")
        var in_day = Int(self.micros) % _USECS_PER_DAY
        return (in_day // _USECS_PER_SECOND) % 60

    def microsecond(self) raises PgError -> Int:
        """Return the microsecond within the second, 0 to 999999.

        Returns:
            The microsecond.

        Raises:
            PgError: `PgErrorKind.USAGE` when the timestamp is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("timestamp", "microsecond")
        return Int(self.micros) % _USECS_PER_SECOND

    def __eq__(self, other: Self) -> Bool:
        """Compare two timestamps for equality.

        Args:
            other: The timestamp to compare against.

        Returns:
            True if both hold the same microsecond count.
        """
        return self.micros == other.micros

    def __ne__(self, other: Self) -> Bool:
        """Compare two timestamps for inequality.

        Args:
            other: The timestamp to compare against.

        Returns:
            True if the microsecond counts differ.
        """
        return self.micros != other.micros

    def write_to(self, mut writer: Some[Writer]):
        """Write the timestamp the way PostgreSQL prints it.

        Args:
            writer: The writer receiving `YYYY-MM-DD HH:MM:SS`, a fractional
                second when there is one, a trailing ` BC` for years at or
                before 1 BC, or a sentinel spelling.
        """
        if self.micros == Int64.MAX:
            writer.write("infinity")
            return
        if self.micros == Int64.MIN:
            writer.write("-infinity")
            return
        var total = Int(self.micros)
        var days = total // _USECS_PER_DAY
        var ymd = _civil_from_days(days)
        _format_date(ymd[0], ymd[1], ymd[2], writer)
        writer.write(" ")
        _format_time_of_day(total - days * _USECS_PER_DAY, writer)
        if ymd[0] <= 0:
            writer.write(" BC")


@fieldwise_init
struct TimestampTz(Copyable, Equatable, Movable, Writable):
    """A PostgreSQL `timestamptz`, held as UTC microseconds from 2000-01-01.

    PostgreSQL stores a `timestamptz` as an absolute instant in UTC and
    applies a time zone only when printing, so this type does the same: the
    offset in the text it reads is folded away into UTC, and the text it
    writes always carries `+00`. The raw field is public and the fieldwise
    constructor checks nothing, so the sentinels `Int64.MAX` and `Int64.MIN`
    pass through as `infinity` and `-infinity`.
    """

    var micros: Int64
    """Microseconds of UTC from the PostgreSQL epoch, or a sentinel."""

    @staticmethod
    def infinity() -> Self:
        """Return the instant that compares later than every other.

        Returns:
            The `infinity` sentinel.
        """
        return Self(Int64.MAX)

    @staticmethod
    def negative_infinity() -> Self:
        """Return the instant that compares earlier than every other.

        Returns:
            The `-infinity` sentinel.
        """
        return Self(Int64.MIN)

    @staticmethod
    def from_utc(
        y: Int, m: Int, d: Int, h: Int, mi: Int, s: Int, us: Int = 0
    ) raises PgError -> Self:
        """Build a `timestamptz` from a UTC calendar date and clock time.

        The seven fields are read as UTC, not as any local zone, so no
        offset is applied to them.

        Args:
            y: Astronomical year, where 1 BC is 0.
            m: Month, 1 to 12.
            d: Day of month, 1 to the length of that month.
            h: Hour, 0 to 23.
            mi: Minute, 0 to 59.
            s: Second, 0 to 59.
            us: Microsecond within the second, 0 to 999999.

        Returns:
            The `TimestampTz` for that UTC instant.

        Raises:
            PgError: `PgErrorKind.USAGE` when a field is out of its range,
                the date is not real, or the result falls outside
                4714-11-24 BC to 294276-12-31.
        """
        if y < -_YEAR_GUARD or y > _YEAR_GUARD:
            raise _usage_error("timestamptz", String("year ", y))
        if m < 1 or m > 12:
            raise _usage_error("timestamptz", String("month ", m))
        if d < 1 or d > _days_in_month(y, m):
            raise _usage_error("timestamptz", String("day ", d))
        if h < 0 or h > 23:
            raise _usage_error("timestamptz", String("hour ", h))
        if mi < 0 or mi > 59:
            raise _usage_error("timestamptz", String("minute ", mi))
        if s < 0 or s > 59:
            raise _usage_error("timestamptz", String("second ", s))
        if us < 0 or us > 999999:
            raise _usage_error("timestamptz", String("microsecond ", us))
        var days = _days_from_civil(y, m, d)
        if days < _MIN_TS_DAYS or days > _MAX_TS_DAYS:
            raise _usage_error("timestamptz", "value out of range")
        var micros = (
            days * _USECS_PER_DAY
            + h * _USECS_PER_HOUR
            + mi * _USECS_PER_MINUTE
            + s * _USECS_PER_SECOND
            + us
        )
        if micros < _MIN_TS_MICROS or micros > _MAX_TS_MICROS:
            raise _usage_error("timestamptz", "value out of range")
        return Self(Int64(micros))

    @staticmethod
    def parse(text: String) raises PgError -> Self:
        """Decode the text form of a `timestamptz`.

        Accepts `YYYY-MM-DD HH:MM:SS` with an optional fractional second of
        one to six digits, then a mandatory `[+-]HH`, `[+-]HH:MM` or
        `[+-]HH:MM:SS` offset, then an optional trailing ` BC`; the two
        sentinel spellings are accepted as well. The offset is subtracted to
        reach UTC, so `+09` reads nine hours earlier than its local clock
        shows, and an offset of 16 hours or more is refused. Text without an
        offset is refused rather than guessed at, since the instant it names
        would depend on the server's `TimeZone`.

        Args:
            text: The text the server printed.

        Returns:
            The decoded `TimestampTz`.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `text` is not that
                form, is not a real date, or is out of range.
        """
        if text == "infinity":
            return Self.infinity()
        if text == "-infinity":
            return Self.negative_infinity()
        var end = _strip_bc(text)
        var is_bc = end != text.byte_length()
        var b = text.as_bytes()
        var sep = -1
        for i in range(end):
            if b[i] == _CH_SPACE:
                sep = i
                break
        if sep < 0:
            raise _decode_error("timestamptz", text)
        var days = _parse_ymd(text, sep, is_bc)
        if days == _BAD or days < _MIN_TS_DAYS or days > _MAX_TS_DAYS:
            raise _decode_error("timestamptz", text)
        if sep + 9 > end:
            raise _decode_error("timestamptz", text)
        var in_day = _parse_hms(text, sep + 1)
        if in_day < 0 or in_day >= _USECS_PER_DAY:
            raise _decode_error("timestamptz", text)
        var p = sep + 9
        var fraction = 0
        if p < end and b[p] == _CH_DOT:
            var start = p + 1
            var stop = start
            while stop < end and _is_digit(b[stop]):
                stop += 1
            fraction = _parse_fraction(String(text[byte=start:stop]))
            if fraction < 0:
                raise _decode_error("timestamptz", text)
            p = stop
        if p >= end:
            raise _decode_error("timestamptz", text)
        var negative = b[p] == _CH_DASH
        if not negative and b[p] != _CH_PLUS:
            raise _decode_error("timestamptz", text)
        p += 1
        if p + 2 > end or not _is_digit(b[p]) or not _is_digit(b[p + 1]):
            raise _decode_error("timestamptz", text)
        var offset = (
            Int(b[p] - _CH_ZERO) * 10 + Int(b[p + 1] - _CH_ZERO)
        ) * 3600
        p += 2
        for unit in [60, 1]:
            if p >= end or b[p] != _CH_COLON:
                break
            if (
                p + 3 > end
                or not _is_digit(b[p + 1])
                or not _is_digit(b[p + 2])
            ):
                raise _decode_error("timestamptz", text)
            var field = Int(b[p + 1] - _CH_ZERO) * 10 + Int(b[p + 2] - _CH_ZERO)
            if field > 59:
                raise _decode_error("timestamptz", text)
            offset += field * unit
            p += 3
        if p != end:
            raise _decode_error("timestamptz", text)
        if offset >= _MAX_OFFSET_SECONDS:
            raise _decode_error("timestamptz", text)
        if negative:
            offset = -offset
        var local = days * _USECS_PER_DAY + in_day + fraction
        var micros = local - offset * _USECS_PER_SECOND
        if micros < _MIN_TS_MICROS or micros > _MAX_TS_MICROS:
            raise _decode_error("timestamptz", text)
        return Self(Int64(micros))

    def is_infinite(self) -> Bool:
        """Report whether this is `infinity` or `-infinity`.

        Returns:
            True for either sentinel.
        """
        return self.micros == Int64.MAX or self.micros == Int64.MIN

    def is_finite(self) -> Bool:
        """Report whether this is a real instant.

        Returns:
            True for anything but the two sentinels.
        """
        return not self.is_infinite()

    def year(self) raises PgError -> Int:
        """Return the astronomical UTC year, where 1 BC is 0.

        Returns:
            The year.

        Raises:
            PgError: `PgErrorKind.USAGE` when the instant is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("timestamptz", "year")
        return _civil_from_days(Int(self.micros) // _USECS_PER_DAY)[0]

    def month(self) raises PgError -> Int:
        """Return the UTC month, 1 to 12.

        Returns:
            The month.

        Raises:
            PgError: `PgErrorKind.USAGE` when the instant is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("timestamptz", "month")
        return _civil_from_days(Int(self.micros) // _USECS_PER_DAY)[1]

    def day(self) raises PgError -> Int:
        """Return the UTC day of month, 1 to 31.

        Returns:
            The day of month.

        Raises:
            PgError: `PgErrorKind.USAGE` when the instant is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("timestamptz", "day")
        return _civil_from_days(Int(self.micros) // _USECS_PER_DAY)[2]

    def hour(self) raises PgError -> Int:
        """Return the UTC hour of day, 0 to 23.

        Returns:
            The hour.

        Raises:
            PgError: `PgErrorKind.USAGE` when the instant is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("timestamptz", "hour")
        var in_day = Int(self.micros) % _USECS_PER_DAY
        return in_day // _USECS_PER_HOUR

    def minute(self) raises PgError -> Int:
        """Return the UTC minute of hour, 0 to 59.

        Returns:
            The minute.

        Raises:
            PgError: `PgErrorKind.USAGE` when the instant is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("timestamptz", "minute")
        var in_day = Int(self.micros) % _USECS_PER_DAY
        return (in_day // _USECS_PER_MINUTE) % 60

    def second(self) raises PgError -> Int:
        """Return the UTC second of minute, 0 to 59.

        Returns:
            The second.

        Raises:
            PgError: `PgErrorKind.USAGE` when the instant is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("timestamptz", "second")
        var in_day = Int(self.micros) % _USECS_PER_DAY
        return (in_day // _USECS_PER_SECOND) % 60

    def microsecond(self) raises PgError -> Int:
        """Return the microsecond within the UTC second, 0 to 999999.

        Returns:
            The microsecond.

        Raises:
            PgError: `PgErrorKind.USAGE` when the instant is infinite.
        """
        if self.is_infinite():
            raise _infinite_error("timestamptz", "microsecond")
        return Int(self.micros) % _USECS_PER_SECOND

    def __eq__(self, other: Self) -> Bool:
        """Compare two instants for equality.

        Args:
            other: The instant to compare against.

        Returns:
            True if both hold the same microsecond count.
        """
        return self.micros == other.micros

    def __ne__(self, other: Self) -> Bool:
        """Compare two instants for inequality.

        Args:
            other: The instant to compare against.

        Returns:
            True if the microsecond counts differ.
        """
        return self.micros != other.micros

    def write_to(self, mut writer: Some[Writer]):
        """Write the instant the way PostgreSQL prints it in UTC.

        The offset is always `+00`, and a ` BC` suffix comes after it, which
        is the order PostgreSQL itself uses.

        Args:
            writer: The writer receiving `YYYY-MM-DD HH:MM:SS+00`, a
                fractional second when there is one, a trailing ` BC` for
                years at or before 1 BC, or a sentinel spelling.
        """
        if self.micros == Int64.MAX:
            writer.write("infinity")
            return
        if self.micros == Int64.MIN:
            writer.write("-infinity")
            return
        var total = Int(self.micros)
        var days = total // _USECS_PER_DAY
        var ymd = _civil_from_days(days)
        _format_date(ymd[0], ymd[1], ymd[2], writer)
        writer.write(" ")
        _format_time_of_day(total - days * _USECS_PER_DAY, writer)
        writer.write("+00")
        if ymd[0] <= 0:
            writer.write(" BC")


def _write_fraction(micros: Int, mut writer: Some[Writer]):
    """Write a sub-second part as `.f`, or nothing at all when it is zero."""
    if micros == 0:
        return
    var digits = String()
    var value = micros
    var scale = 100000
    while scale > 0:
        digits += String(value // scale)
        value = value % scale
        scale //= 10
    var bytes = digits.as_bytes()
    var length = 6
    while length > 1 and bytes[length - 1] == _CH_ZERO:
        length -= 1
    writer.write(".", digits[byte=0:length])


def _format_interval_time(micros: Int64, mut writer: Some[Writer]):
    """Write the magnitude of `micros` as `HH:MM:SS[.f]`, hour unbounded.

    An interval's time part is not a time of day, so the hour field has no
    upper bound and `_format_time_of_day` cannot stand in for this: it is
    only padded to two digits and runs as far as 2562047788. The sign is the
    caller's to write, and the magnitude is taken in `UInt64` so that
    `Int64.MIN`, which a finite interval may really hold, does not wrap.
    """
    var magnitude: UInt64
    if micros < 0:
        magnitude = (-(micros + 1)).cast[DType.uint64]() + 1
    else:
        magnitude = micros.cast[DType.uint64]()
    var hour = Int(magnitude // UInt64(_USECS_PER_HOUR))
    var rest = magnitude % UInt64(_USECS_PER_HOUR)
    var minute = Int(rest // UInt64(_USECS_PER_MINUTE))
    rest = rest % UInt64(_USECS_PER_MINUTE)
    var second = Int(rest // UInt64(_USECS_PER_SECOND))
    var fraction = Int(rest % UInt64(_USECS_PER_SECOND))
    var hours = String(hour)
    if hours.byte_length() < 2:
        writer.write("0")
    writer.write(hours, ":", _pad2(minute), ":", _pad2(second))
    _write_fraction(fraction, writer)


def _write_interval_part(
    value: Int,
    unit: String,
    mut is_zero: Bool,
    mut is_before: Bool,
    mut writer: Some[Writer],
):
    """Write one `year`, `mon` or `day` field of an interval, if it is set.

    PostgreSQL's own `AddPostgresIntPart`: a zero field is not printed at
    all, a field after another is preceded by one space, and a positive
    field is preceded by a `+` when the field just printed was negative.
    `is_before` tracks only the sign of that last field, not whether any
    field so far was negative.
    """
    if value == 0:
        return
    if not is_zero:
        writer.write(" ")
    if is_before and value > 0:
        writer.write("+")
    writer.write(value, " ", unit)
    if value != 1:
        writer.write("s")
    is_zero = False
    is_before = value < 0


@fieldwise_init
struct Time(Copyable, Equatable, Movable, Writable):
    """A PostgreSQL `time`, held as microseconds from midnight.

    The value is a wall clock reading with no date and no time zone behind
    it, so nothing here shifts it. The raw field is public and the fieldwise
    constructor checks nothing, so a decoder can hand over whatever the
    server sent; `from_hms` is the checked way in. A `time` has no
    `infinity`, so every accessor answers for every value and none of them
    raise.
    """

    var micros: Int64
    """Microseconds from midnight, 0 to 86400000000 inclusive."""

    @staticmethod
    def from_hms(h: Int, mi: Int, s: Int, us: Int = 0) raises PgError -> Self:
        """Build a `time` from a wall clock reading.

        The hour may be 24, which PostgreSQL accepts as the end of the day,
        but only when every smaller field is zero.

        Args:
            h: Hour, 0 to 23, or 24 for the end of the day.
            mi: Minute, 0 to 59.
            s: Second, 0 to 59.
            us: Microsecond within the second, 0 to 999999.

        Returns:
            The `Time` for that reading.

        Raises:
            PgError: `PgErrorKind.USAGE` when a field is out of its range,
                or when the hour is 24 and another field is not zero.
        """
        if h < 0 or h > 24:
            raise _usage_error("time", String("hour ", h))
        if mi < 0 or mi > 59:
            raise _usage_error("time", String("minute ", mi))
        if s < 0 or s > 59:
            raise _usage_error("time", String("second ", s))
        if us < 0 or us > 999999:
            raise _usage_error("time", String("microsecond ", us))
        if h == 24 and (mi != 0 or s != 0 or us != 0):
            raise _usage_error("time", "value out of range")
        return Self(
            Int64(
                h * _USECS_PER_HOUR
                + mi * _USECS_PER_MINUTE
                + s * _USECS_PER_SECOND
                + us
            )
        )

    @staticmethod
    def parse(text: String) raises PgError -> Self:
        """Decode the text form of a `time`.

        Accepts `HH:MM:SS` with an optional fractional second of one to six
        digits, and nothing else: no sign, no surrounding space, no
        single-digit field and no trailing offset. `24:00:00` is accepted
        and anything past it is not.

        Args:
            text: The text the server printed.

        Returns:
            The decoded `Time`.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `text` is not that
                form or names a reading past the end of the day.
        """
        var in_day = _parse_hms(text, 0)
        if in_day < 0:
            raise _decode_error("time", text)
        var n = text.byte_length()
        var b = text.as_bytes()
        var fraction = 0
        if n != 8:
            if n < 9 or b[8] != _CH_DOT:
                raise _decode_error("time", text)
            fraction = _parse_fraction(String(text[byte=9:n]))
            if fraction < 0:
                raise _decode_error("time", text)
        var micros = in_day + fraction
        if micros > _USECS_PER_DAY:
            raise _decode_error("time", text)
        return Self(Int64(micros))

    def hour(self) -> Int:
        """Return the hour of day, 0 to 24.

        Returns:
            The hour.
        """
        return Int(self.micros) // _USECS_PER_HOUR

    def minute(self) -> Int:
        """Return the minute of hour, 0 to 59.

        Returns:
            The minute.
        """
        return (Int(self.micros) // _USECS_PER_MINUTE) % 60

    def second(self) -> Int:
        """Return the second of minute, 0 to 59.

        Returns:
            The second.
        """
        return (Int(self.micros) // _USECS_PER_SECOND) % 60

    def microsecond(self) -> Int:
        """Return the microsecond within the second, 0 to 999999.

        Returns:
            The microsecond.
        """
        return Int(self.micros) % _USECS_PER_SECOND

    def __eq__(self, other: Self) -> Bool:
        """Compare two times for equality.

        Args:
            other: The time to compare against.

        Returns:
            True if both hold the same microsecond count.
        """
        return self.micros == other.micros

    def __ne__(self, other: Self) -> Bool:
        """Compare two times for inequality.

        Args:
            other: The time to compare against.

        Returns:
            True if the microsecond counts differ.
        """
        return self.micros != other.micros

    def write_to(self, mut writer: Some[Writer]):
        """Write the time the way PostgreSQL prints it.

        Args:
            writer: The writer receiving `HH:MM:SS` and a fractional second
                when there is one.
        """
        _format_time_of_day(Int(self.micros), writer)


@fieldwise_init
struct TimeTz(Copyable, Equatable, Movable, Writable):
    """A PostgreSQL `timetz`, held as a time of day and a UTC offset.

    PostgreSQL keeps the two apart rather than folding the offset away, as
    there is no date to say which instant the pair names, so this type keeps
    them apart too. The offset carries PostgreSQL's own sign, which is the
    POSIX one and the opposite of the text's: `+09` is stored as -32400. The
    raw fields are public and the fieldwise constructor checks nothing;
    `from_hms` is the checked way in. A `timetz` has no `infinity`, so none
    of the accessors raise.
    """

    var micros: Int64
    """Microseconds from midnight, 0 to 86400000000 inclusive."""

    var offset_secs: Int32
    """Seconds west of UTC, so `+09` is -32400 and `-03:30` is 12600."""

    @staticmethod
    def from_hms(
        h: Int, mi: Int, s: Int, us: Int, offset_secs: Int
    ) raises PgError -> Self:
        """Build a `timetz` from a wall clock reading and a UTC offset.

        The offset is given the way it is stored, west of UTC positive, so
        the nine hour offset printed `+09` is passed as -32400.

        Args:
            h: Hour, 0 to 23, or 24 for the end of the day.
            mi: Minute, 0 to 59.
            s: Second, 0 to 59.
            us: Microsecond within the second, 0 to 999999.
            offset_secs: Seconds west of UTC, further from zero than
                neither -57600 nor 57600.

        Returns:
            The `TimeTz` for that reading.

        Raises:
            PgError: `PgErrorKind.USAGE` when a field is out of its range,
                when the hour is 24 and another field is not zero, or when
                the offset is 16 hours or wider.
        """
        if h < 0 or h > 24:
            raise _usage_error("timetz", String("hour ", h))
        if mi < 0 or mi > 59:
            raise _usage_error("timetz", String("minute ", mi))
        if s < 0 or s > 59:
            raise _usage_error("timetz", String("second ", s))
        if us < 0 or us > 999999:
            raise _usage_error("timetz", String("microsecond ", us))
        if h == 24 and (mi != 0 or s != 0 or us != 0):
            raise _usage_error("timetz", "value out of range")
        if (
            offset_secs <= -_MAX_OFFSET_SECONDS
            or offset_secs >= _MAX_OFFSET_SECONDS
        ):
            raise _usage_error("timetz", String("offset ", offset_secs))
        return Self(
            Int64(
                h * _USECS_PER_HOUR
                + mi * _USECS_PER_MINUTE
                + s * _USECS_PER_SECOND
                + us
            ),
            Int32(offset_secs),
        )

    @staticmethod
    def parse(text: String) raises PgError -> Self:
        """Decode the text form of a `timetz`.

        Accepts `HH:MM:SS` with an optional fractional second of one to six
        digits, then a mandatory `[+-]HH`, `[+-]HH:MM` or `[+-]HH:MM:SS`
        offset. The offset's sign is flipped on the way in, since the text
        counts east of UTC positive and the stored field counts west of UTC
        positive, and an offset of 16 hours or wider is refused. Text
        without an offset is refused rather than guessed at.

        Args:
            text: The text the server printed.

        Returns:
            The decoded `TimeTz`.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `text` is not that
                form, names a reading past the end of the day, or carries an
                offset too wide to accept.
        """
        var in_day = _parse_hms(text, 0)
        if in_day < 0:
            raise _decode_error("timetz", text)
        var n = text.byte_length()
        var b = text.as_bytes()
        var p = 8
        var fraction = 0
        if p < n and b[p] == _CH_DOT:
            var start = p + 1
            var stop = start
            while stop < n and _is_digit(b[stop]):
                stop += 1
            fraction = _parse_fraction(String(text[byte=start:stop]))
            if fraction < 0:
                raise _decode_error("timetz", text)
            p = stop
        var micros = in_day + fraction
        if micros > _USECS_PER_DAY:
            raise _decode_error("timetz", text)
        if p >= n:
            raise _decode_error("timetz", text)
        var negative = b[p] == _CH_DASH
        if not negative and b[p] != _CH_PLUS:
            raise _decode_error("timetz", text)
        p += 1
        if p + 2 > n or not _is_digit(b[p]) or not _is_digit(b[p + 1]):
            raise _decode_error("timetz", text)
        var offset = (
            Int(b[p] - _CH_ZERO) * 10 + Int(b[p + 1] - _CH_ZERO)
        ) * 3600
        p += 2
        for unit in [60, 1]:
            if p >= n or b[p] != _CH_COLON:
                break
            if p + 3 > n or not _is_digit(b[p + 1]) or not _is_digit(b[p + 2]):
                raise _decode_error("timetz", text)
            var field = Int(b[p + 1] - _CH_ZERO) * 10 + Int(b[p + 2] - _CH_ZERO)
            if field > 59:
                raise _decode_error("timetz", text)
            offset += field * unit
            p += 3
        if p != n:
            raise _decode_error("timetz", text)
        if offset >= _MAX_OFFSET_SECONDS:
            raise _decode_error("timetz", text)
        return Self(Int64(micros), Int32(offset if negative else -offset))

    def hour(self) -> Int:
        """Return the hour of day, 0 to 24.

        Returns:
            The hour.
        """
        return Int(self.micros) // _USECS_PER_HOUR

    def minute(self) -> Int:
        """Return the minute of hour, 0 to 59.

        Returns:
            The minute.
        """
        return (Int(self.micros) // _USECS_PER_MINUTE) % 60

    def second(self) -> Int:
        """Return the second of minute, 0 to 59.

        Returns:
            The second.
        """
        return (Int(self.micros) // _USECS_PER_SECOND) % 60

    def microsecond(self) -> Int:
        """Return the microsecond within the second, 0 to 999999.

        Returns:
            The microsecond.
        """
        return Int(self.micros) % _USECS_PER_SECOND

    def __eq__(self, other: Self) -> Bool:
        """Compare two zoned times for equality.

        Args:
            other: The zoned time to compare against.

        Returns:
            True if both the reading and the offset match.
        """
        return (
            self.micros == other.micros
            and self.offset_secs == other.offset_secs
        )

    def __ne__(self, other: Self) -> Bool:
        """Compare two zoned times for inequality.

        Args:
            other: The zoned time to compare against.

        Returns:
            True if the reading or the offset differs.
        """
        return (
            self.micros != other.micros or self.offset_secs != other.offset_secs
        )

    def write_to(self, mut writer: Some[Writer]):
        """Write the zoned time the way PostgreSQL prints it.

        The offset is printed by PostgreSQL's `EncodeTimezone` rules: the
        sign is flipped back to the text's own convention, and the minute
        and second fields appear only when they carry something.

        Args:
            writer: The writer receiving `HH:MM:SS`, a fractional second
                when there is one, and `[+-]HH`, `[+-]HH:MM` or
                `[+-]HH:MM:SS`.
        """
        _format_time_of_day(Int(self.micros), writer)
        var tz = Int(self.offset_secs)
        var magnitude = -tz if tz < 0 else tz
        var sec = magnitude % 60
        var minute = (magnitude // 60) % 60
        var hour = magnitude // 3600
        if tz <= 0:
            writer.write("+")
        else:
            writer.write("-")
        writer.write(_pad2(hour))
        if sec != 0:
            writer.write(":", _pad2(minute), ":", _pad2(sec))
        elif minute != 0:
            writer.write(":", _pad2(minute))


@fieldwise_init
struct Interval(Copyable, Equatable, Movable, Writable):
    """A PostgreSQL `interval`, held as the three counts the server keeps.

    The three fields are independent on purpose, exactly as they are on the
    wire: a month is not a fixed number of days and a day is not a fixed
    number of microseconds once a daylight saving boundary is crossed, so
    nothing here folds one into another and `1 mon` never becomes `30 days`.
    The raw fields are public and the fieldwise constructor checks nothing.

    The sentinels `infinity` and `-infinity` are all three fields at their
    extreme at once, so a single field at its extreme is an ordinary finite
    interval and `is_infinite` says so.
    """

    var micros: Int64
    """Microseconds of the time part, counted apart from days and months."""

    var days: Int32
    """Whole days, which are not always 24 hours."""

    var months: Int32
    """Whole months, which are never folded into days."""

    @staticmethod
    def infinity() -> Self:
        """Return the interval that compares longer than every other.

        Returns:
            The `infinity` sentinel.
        """
        return Self(Int64.MAX, Int32.MAX, Int32.MAX)

    @staticmethod
    def negative_infinity() -> Self:
        """Return the interval that compares shorter than every other.

        Returns:
            The `-infinity` sentinel.
        """
        return Self(Int64.MIN, Int32.MIN, Int32.MIN)

    @staticmethod
    def parse(text: String) raises PgError -> Self:
        """Decode the text form of an `interval` in `postgres` style.

        Accepts exactly what `write_to` prints: the sentinel spellings
        `infinity` and `-infinity`, or a `year`, `mon` and `day` field in
        that order with each at most once, followed by an optional time part
        `[+-]H+:MM:SS` with an optional fractional second of one to six
        digits. Fields are separated by exactly one space, a leading `+` is
        refused on the first field only, and the whole string must be
        consumed, so a trailing space is refused as well. Other input styles,
        `1 week` and ISO 8601 among them, are not accepted.

        Args:
            text: The text the server printed.

        Returns:
            The decoded `Interval`.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `text` is not that
                form or holds a count too large for its field.
        """
        if text == "infinity":
            return Self.infinity()
        if text == "-infinity":
            return Self.negative_infinity()
        var n = text.byte_length()
        var b = text.as_bytes()
        var p = 0
        var first = True
        var next_slot = 0
        var months = 0
        var days = 0
        var micros = Int64(0)
        while True:
            if p >= n:
                raise _decode_error("interval", text)
            var negative = False
            if b[p] == _CH_PLUS:
                if first:
                    raise _decode_error("interval", text)
                p += 1
            elif b[p] == _CH_DASH:
                negative = True
                p += 1
            var digit_start = p
            while p < n and _is_digit(b[p]):
                p += 1
            var digit_count = p - digit_start
            if digit_count == 0 or digit_count > 10:
                raise _decode_error("interval", text)
            var value = 0
            for i in range(digit_start, p):
                value = value * 10 + Int(b[i] - _CH_ZERO)
            if p < n and b[p] == _CH_COLON:
                if value > 2562047788:
                    raise _decode_error("interval", text)
                if (
                    p + 6 > n
                    or not _is_digit(b[p + 1])
                    or not _is_digit(b[p + 2])
                    or b[p + 3] != _CH_COLON
                    or not _is_digit(b[p + 4])
                    or not _is_digit(b[p + 5])
                ):
                    raise _decode_error("interval", text)
                var minute = Int(b[p + 1] - _CH_ZERO) * 10 + Int(
                    b[p + 2] - _CH_ZERO
                )
                var second = Int(b[p + 4] - _CH_ZERO) * 10 + Int(
                    b[p + 5] - _CH_ZERO
                )
                if minute > 59 or second > 59:
                    raise _decode_error("interval", text)
                p += 6
                var fraction = 0
                if p < n and b[p] == _CH_DOT:
                    var start = p + 1
                    var stop = start
                    while stop < n and _is_digit(b[stop]):
                        stop += 1
                    fraction = _parse_fraction(String(text[byte=start:stop]))
                    if fraction < 0:
                        raise _decode_error("interval", text)
                    p = stop
                if p != n:
                    raise _decode_error("interval", text)
                var magnitude = (
                    UInt64(value) * UInt64(_USECS_PER_HOUR)
                    + UInt64(minute) * UInt64(_USECS_PER_MINUTE)
                    + UInt64(second) * UInt64(_USECS_PER_SECOND)
                    + UInt64(fraction)
                )
                var limit = Int64.MAX.cast[DType.uint64]()
                if negative:
                    if magnitude > limit + 1:
                        raise _decode_error("interval", text)
                    if magnitude == limit + 1:
                        micros = Int64.MIN
                    else:
                        micros = -(magnitude.cast[DType.int64]())
                else:
                    if magnitude > limit:
                        raise _decode_error("interval", text)
                    micros = magnitude.cast[DType.int64]()
                break
            if p >= n or b[p] != _CH_SPACE:
                raise _decode_error("interval", text)
            var unit_start = p + 1
            var unit_stop = unit_start
            while unit_stop < n and b[unit_stop] != _CH_SPACE:
                unit_stop += 1
            var unit = String(text[byte=unit_start:unit_stop])
            var slot = -1
            if unit == "year" or unit == "years":
                slot = 0
            elif unit == "mon" or unit == "mons":
                slot = 1
            elif unit == "day" or unit == "days":
                slot = 2
            if slot < 0 or slot < next_slot:
                raise _decode_error("interval", text)
            next_slot = slot + 1
            var signed = -value if negative else value
            if slot == 0:
                months += signed * 12
            elif slot == 1:
                months += signed
            else:
                days += signed
            p = unit_stop
            first = False
            if p == n:
                break
            p += 1
            if p >= n:
                raise _decode_error("interval", text)
        if months < Int(Int32.MIN) or months > Int(Int32.MAX):
            raise _decode_error("interval", text)
        if days < Int(Int32.MIN) or days > Int(Int32.MAX):
            raise _decode_error("interval", text)
        return Self(micros, Int32(days), Int32(months))

    def is_infinite(self) -> Bool:
        """Report whether this is `infinity` or `-infinity`.

        Returns:
            True only when all three fields sit at the same extreme.
        """
        if (
            self.micros == Int64.MAX
            and self.days == Int32.MAX
            and self.months == Int32.MAX
        ):
            return True
        return (
            self.micros == Int64.MIN
            and self.days == Int32.MIN
            and self.months == Int32.MIN
        )

    def is_finite(self) -> Bool:
        """Report whether this is a real span of time.

        Returns:
            True for anything but the two sentinels.
        """
        return not self.is_infinite()

    def __eq__(self, other: Self) -> Bool:
        """Compare two intervals field by field.

        Two intervals that name the same span through different fields, such
        as `1 mon` and `30 days`, are not equal, which is what the server's
        own binary representation says.

        Args:
            other: The interval to compare against.

        Returns:
            True if all three fields match.
        """
        return (
            self.micros == other.micros
            and self.days == other.days
            and self.months == other.months
        )

    def __ne__(self, other: Self) -> Bool:
        """Compare two intervals field by field for inequality.

        Args:
            other: The interval to compare against.

        Returns:
            True if any of the three fields differs.
        """
        return (
            self.micros != other.micros
            or self.days != other.days
            or self.months != other.months
        )

    def write_to(self, mut writer: Some[Writer]):
        """Write the interval in PostgreSQL's default `postgres` style.

        This follows `EncodeInterval`: the months split into a year and a
        month field by truncating toward zero, a field that is zero is left
        out entirely, and the time part appears when it is non-zero or when
        nothing else was printed, so a zero interval reads `00:00:00`. The
        time part's hour field has no upper bound.

        Args:
            writer: The writer receiving the fields, or a sentinel spelling.
        """
        if self.is_infinite():
            if self.months == Int32.MAX:
                writer.write("infinity")
            else:
                writer.write("-infinity")
            return
        var months = Int(self.months)
        var year = -((-months) // 12) if months < 0 else months // 12
        var mon = months - year * 12
        var is_zero = True
        var is_before = False
        _write_interval_part(year, "year", is_zero, is_before, writer)
        _write_interval_part(mon, "mon", is_zero, is_before, writer)
        _write_interval_part(Int(self.days), "day", is_zero, is_before, writer)
        if is_zero or self.micros != 0:
            if not is_zero:
                writer.write(" ")
            if self.micros < 0:
                writer.write("-")
            elif is_before:
                writer.write("+")
            _format_interval_time(self.micros, writer)
