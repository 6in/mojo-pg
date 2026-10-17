"""Binary-format decoding of PostgreSQL wire bytes into Mojo types.

Holds fourteen decoders -- the fixed-width `decode_bool`, `decode_int16`,
`decode_int32`, `decode_int64`, `decode_float32`, `decode_float64`,
`decode_uuid`, `decode_date`, `decode_timestamp`, `decode_timestamptz`,
`decode_time`, `decode_timetz` and `decode_interval`, plus the
variable-length `decode_numeric` -- and the
`comptime if` type switch `decode_binary[T]` that turns one libpq
binary-format cell into a Mojo value. Each decoder is the inverse of the
`encode_<pgtype>` function of the same suffix in `pq.encode_binary`, reading
network byte order (big-endian) by shifting bytes together rather than by
reinterpreting host storage, so the result does not depend on the host's
endianness.

Decoding is strict in three independent ways, because a binary cell carries
no self-description and a wrong guess would silently produce a plausible
number:

- The column OID must match `T` exactly. Neither widening (`int2` into
  `Int32`) nor narrowing is performed. Unlike the text path, `String` is not
  universal here: it accepts only the six string-shaped OIDs (`text`,
  `varchar`, `bpchar`, `name`, `json`, `jsonb`), since the binary form of a
  non-string type is not its printed form.
- A fixed-width type's cell must be exactly as wide as the type. One byte
  short, one byte long and zero bytes are all rejected rather than
  zero-padded. `numeric` is variable-length, so there the header's
  `ndigits` and the cell length must agree.
- Values outside the type's wire domain are rejected: a `bool` byte must be
  0 or 1, a `jsonb` cell must open with version byte 1, and a `numeric`
  header must carry one of the five defined signs, a `dscale` of at most
  16383 and digit groups in `0..9999`. A `time` must fall in
  `0..86400000000`, the upper bound included since `24:00:00` is a valid
  `time`, and a `timetz` zone must be narrower than 16 hours. `date`,
  `timestamp`, `timestamptz` and `interval` have no such check: every cell
  of the right width is a value those types can hold, the `infinity`
  sentinels included.

`String` copies exactly the `PQgetlength` bytes it is given and does not
treat them as a C string, so a `text` value containing NUL survives intact.
The bytes are checked to be well-formed UTF-8 first, and a cell that is not
raises `PgErrorKind.TYPE_MISMATCH` naming the byte offset and the column but
never quoting the cell. `pq` still does not set `client_encoding`, so it is
the server's `client_encoding` that decides whether cells arrive as UTF-8 at
all.

Every failure raises `PgError(PgErrorKind.TYPE_MISMATCH, ...)`; an OID
mismatch message points the caller at `ResultFormat.TEXT` as the fallback.
"""

from std.memory import bitcast

from pq.decode_text import (
    OID_BOOL,
    OID_BPCHAR,
    OID_BYTEA,
    OID_DATE,
    OID_FLOAT4,
    OID_FLOAT8,
    OID_INT2,
    OID_INT4,
    OID_INT8,
    OID_INTERVAL,
    OID_JSON,
    OID_JSONB,
    OID_NAME,
    OID_NUMERIC,
    OID_TEXT,
    OID_TIME,
    OID_TIMESTAMP,
    OID_TIMESTAMPTZ,
    OID_TIMETZ,
    OID_UUID,
    OID_VARCHAR,
)
from pq.errors import PgError, PgErrorKind
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

comptime _JSONB_VERSION = UInt8(1)

comptime _NUMERIC_HEADER = 8
"""Bytes of `numeric` header before the base-10000 digit groups."""

comptime _NUMERIC_POS = UInt16(0x0000)
comptime _NUMERIC_NEG = UInt16(0x4000)
comptime _NUMERIC_NAN = UInt16(0xC000)
comptime _NUMERIC_PINF = UInt16(0xD000)
comptime _NUMERIC_NINF = UInt16(0xF000)

comptime _NUMERIC_DSCALE_MAX = UInt16(0x3FFF)
comptime _NUMERIC_DIGIT_MAX = Int16(9999)

comptime _UUID_BYTES = 16

comptime _MAX_TIME_MICROS = Int64(86400000000)
"""Microseconds of `24:00:00`, the largest `time` PostgreSQL accepts."""

comptime _MAX_OFFSET_SECONDS = Int32(57600)
"""The first `timetz` zone too wide to accept: 16 hours, in seconds."""


def _hex4(v: UInt16) -> String:
    """Render `v` as exactly four lowercase hex digits with an `0x` prefix."""
    comptime DIGITS = "0123456789abcdef"
    var out = String("0x")
    for i in range(4):
        var nibble = Int((v >> UInt16(4 * (3 - i))) & 0xF)
        out += DIGITS[byte = nibble : nibble + 1]
    return out^


def _binary_oid_error(oid: UInt32, type_name: String) -> PgError:
    """Build the `TYPE_MISMATCH` error for a column of the wrong OID."""
    return PgError(
        PgErrorKind.TYPE_MISMATCH,
        String(
            "column is oid ",
            oid,
            " but ",
            type_name,
            (
                " was requested in binary format; request a matching type or"
                " re-run with ResultFormat.TEXT"
            ),
        ),
    )


def _binary_length_error(
    pg_type: String, actual: Int, expected: Int
) -> PgError:
    """Build the `TYPE_MISMATCH` error for a wrong-width fixed-length cell."""
    return PgError(
        PgErrorKind.TYPE_MISMATCH,
        String(
            "binary ",
            pg_type,
            " value has ",
            actual,
            " bytes, expected ",
            expected,
        ),
    )


def _binary_value_error(pg_type: String, reason: String) -> PgError:
    """Build the `TYPE_MISMATCH` error for an out-of-domain wire value."""
    return PgError(
        PgErrorKind.TYPE_MISMATCH,
        String("cannot decode binary ", pg_type, ": ", reason),
    )


def _be_bits[origin: ImmOrigin, //](bytes: Span[UInt8, origin]) -> UInt64:
    """Fold `bytes` into a `UInt64`, reading most significant byte first."""
    var bits = UInt64(0)
    for i in range(len(bytes)):
        bits = (bits << 8) | UInt64(bytes[i])
    return bits


def _check_length[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin], pg_type: String, expected: Int) raises PgError:
    """Raise unless `bytes` is exactly `expected` bytes wide."""
    if len(bytes) != expected:
        raise _binary_length_error(pg_type, len(bytes), expected)


def _string_payload[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin], oid: UInt32) raises PgError -> Span[
    UInt8, origin
]:
    """Return the text bytes of a binary-format string-shaped cell.

    The one place that decides which binary OIDs carry UTF-8 text and where
    that text starts: the six string-shaped OIDs 25 (`text`), 1043
    (`varchar`), 1042 (`bpchar`), 19 (`name`), 114 (`json`) and 3802
    (`jsonb`). A `jsonb` cell opens with a one byte format version, which
    must be 1 and is not part of the payload; the other five are their own
    payload. Both `decode_binary[String]` and `Row.get_text` read the cell
    through here, so they raise the same errors with the same messages.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The cell's binary-format bytes.
        oid: The column type OID reported by `PQftype`.

    Returns:
        A slice of `bytes` holding the text, borrowed from the same storage.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `oid` is not one of the
            six, or when a `jsonb` cell is empty or carries a version byte
            other than 1.
    """
    if oid == OID_JSONB:
        if len(bytes) < 1:
            raise _binary_length_error("jsonb", len(bytes), 1)
        if bytes[0] != _JSONB_VERSION:
            raise _binary_value_error(
                "jsonb",
                String("version byte is ", bytes[0], ", expected 1"),
            )
        return bytes[1:]
    if (
        oid != OID_TEXT
        and oid != OID_VARCHAR
        and oid != OID_BPCHAR
        and oid != OID_NAME
        and oid != OID_JSON
    ):
        raise _binary_oid_error(oid, "String")
    return bytes


def _utf8_first_invalid[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin]) -> Int:
    """Return the offset of the first ill-formed UTF-8 sequence in `bytes`.

    A direct walk of RFC 3629 table 3-7, so it rejects exactly what that
    table rejects: an overlong encoding (`c0`/`c1`, `e0 80..9f`,
    `f0 80..8f`), a UTF-16 surrogate (`ed a0..bf`), a code point above
    U+10FFFF (`f4 90..` and `f5..ff`), a continuation byte outside
    `80..bf`, a sequence cut short by the end of `bytes`, and a
    continuation byte where a lead byte belongs. Used only to locate a
    failure `StringSlice`'s own validation already found, so it trades
    speed for being easy to check against the table.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The bytes to scan.

    Returns:
        -1 when every byte of `bytes` is part of a well-formed sequence,
        otherwise the zero-based offset of the *start* of the first
        ill-formed sequence.
    """
    var i = 0
    var n = len(bytes)
    while i < n:
        var lead = bytes[i]
        if lead < 0x80:
            i += 1
            continue
        var trail: Int
        var low = UInt8(0x80)
        var high = UInt8(0xBF)
        if lead >= 0xC2 and lead <= 0xDF:
            trail = 1
        elif lead == 0xE0:
            trail = 2
            low = 0xA0
        elif lead == 0xED:
            trail = 2
            high = 0x9F
        elif (lead >= 0xE1 and lead <= 0xEC) or lead == 0xEE or lead == 0xEF:
            trail = 2
        elif lead == 0xF0:
            trail = 3
            low = 0x90
        elif lead >= 0xF1 and lead <= 0xF3:
            trail = 3
        elif lead == 0xF4:
            trail = 3
            high = 0x8F
        else:
            # `80..bf` is a stray continuation byte; `c0`/`c1` would be an
            # overlong two-byte form; `f5..ff` is above U+10FFFF.
            return i
        if i + trail >= n:
            return i
        if bytes[i + 1] < low or bytes[i + 1] > high:
            return i
        for k in range(2, trail + 1):
            if bytes[i + k] < 0x80 or bytes[i + k] > 0xBF:
                return i
        i += trail + 1
    return -1


def _validated_utf8[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin], column: Int) raises PgError -> StringSlice[
    origin
]:
    """View `bytes` as UTF-8 text, raising when they are not UTF-8.

    The fast path is the stdlib's own validator,
    `StringSlice(from_utf8=...)`, which walks the bytes once and raises a
    plain `Error` carrying no position. Only on that failure does
    `_utf8_first_invalid` run, to turn the rejection into a byte offset
    for the message, so a well-formed cell pays for one validation and
    nothing else.

    The message names the offset and the column but never quotes the
    cell: a cell that is not UTF-8 cannot be put in an error message
    without either corrupting the message or leaking the row's contents
    into a log.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The text bytes of the cell, as `_string_payload` delimits
            them -- for `jsonb` the version byte is already gone, so the
            offset is relative to the JSON text.
        column: Zero-based column index for the message, or -1 when the
            caller does not know it, which prints `of column ?`.

    Returns:
        A `StringSlice` over `bytes`, borrowed from the same storage.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` with the message
            `invalid UTF-8 at byte N of column M` when `bytes` are not
            well-formed UTF-8.
    """
    try:
        return StringSlice[origin](from_utf8=bytes)
    except:
        pass
    var label = String("?") if column < 0 else String(column)
    var offset = _utf8_first_invalid(bytes)
    if offset < 0:
        # Unreachable unless the scanner and the stdlib disagree; still a
        # rejection, just without a position to name.
        raise PgError(
            PgErrorKind.TYPE_MISMATCH,
            String("invalid UTF-8 of column ", label),
        )
    raise PgError(
        PgErrorKind.TYPE_MISMATCH,
        String("invalid UTF-8 at byte ", offset, " of column ", label),
    )


def decode_bool[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin]) raises PgError -> Bool:
    """Decode the one byte PostgreSQL `bool` binary format.

    The wire byte must be 0 or 1. PostgreSQL itself accepts any non-zero
    byte as true, but a cell holding anything else did not come from a
    `bool` column, so it is rejected instead of coerced.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The cell's binary-format bytes.

    Returns:
        False for byte 0, True for byte 1.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `bytes` is not exactly
            one byte, or when that byte is neither 0 nor 1.
    """
    _check_length(bytes, "bool", 1)
    var byte = bytes[0]
    if byte == 0:
        return False
    if byte == 1:
        return True
    raise _binary_value_error(
        "bool", String("byte is ", byte, ", expected 0 or 1")
    )


def decode_int16[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin]) raises PgError -> Int16:
    """Decode the two byte PostgreSQL `int2` binary format.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The cell's binary-format bytes.

    Returns:
        The value, read as big-endian two's complement.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `bytes` is not exactly
            two bytes.
    """
    _check_length(bytes, "int2", 2)
    return bitcast[DType.int16, 1](UInt16(_be_bits(bytes)))


def decode_int32[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin]) raises PgError -> Int32:
    """Decode the four byte PostgreSQL `int4` binary format.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The cell's binary-format bytes.

    Returns:
        The value, read as big-endian two's complement.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `bytes` is not exactly
            four bytes.
    """
    _check_length(bytes, "int4", 4)
    return bitcast[DType.int32, 1](UInt32(_be_bits(bytes)))


def decode_int64[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin]) raises PgError -> Int64:
    """Decode the eight byte PostgreSQL `int8` binary format.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The cell's binary-format bytes.

    Returns:
        The value, read as big-endian two's complement.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `bytes` is not exactly
            eight bytes.
    """
    _check_length(bytes, "int8", 8)
    return bitcast[DType.int64, 1](_be_bits(bytes))


def decode_float32[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin]) raises PgError -> Float32:
    """Decode the four byte PostgreSQL `float4` binary format.

    The IEEE 754 bit pattern is taken as-is, so NaN, the infinities and
    negative zero round-trip unchanged.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The cell's binary-format bytes.

    Returns:
        The value, read as big-endian IEEE 754 binary32.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `bytes` is not exactly
            four bytes.
    """
    _check_length(bytes, "float4", 4)
    return bitcast[DType.float32, 1](UInt32(_be_bits(bytes)))


def decode_float64[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin]) raises PgError -> Float64:
    """Decode the eight byte PostgreSQL `float8` binary format.

    The IEEE 754 bit pattern is taken as-is, so NaN, the infinities and
    negative zero round-trip unchanged.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The cell's binary-format bytes.

    Returns:
        The value, read as big-endian IEEE 754 binary64.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `bytes` is not exactly
            eight bytes.
    """
    _check_length(bytes, "float8", 8)
    return bitcast[DType.float64, 1](_be_bits(bytes))


def decode_numeric[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin]) raises PgError -> Decimal:
    """Decode the variable-length PostgreSQL `numeric` binary format.

    The wire form is the four `int16`/`uint16` header fields `ndigits`,
    `weight`, `sign` and `dscale`, followed by `ndigits` base-10000 digit
    groups, all big-endian. The cell must be exactly `8 + 2 * ndigits`
    bytes, which is what rules out a truncated or over-long cell; `sign`
    must be one of the five values PostgreSQL defines, and every digit
    group must be in `0..9999`.

    `NaN` and the infinities carry no digits, and PostgreSQL sends them
    with a `dscale` of 32 that is an artefact of its header packing, so
    for those only the sign is read and `weight` / `dscale` are dropped.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The cell's binary-format bytes.

    Returns:
        The value, normalised the way `Decimal` keeps it.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when the cell is shorter than
            the header, when its length disagrees with `ndigits`, or when
            `sign`, `dscale` or a digit group is out of range; also when
            dropping the leading zero groups would take the weight below
            `Int16.MIN`.
    """
    if len(bytes) < _NUMERIC_HEADER:
        raise _binary_value_error(
            "numeric",
            String("has ", len(bytes), " bytes, expected at least 8"),
        )
    var ndigits = Int(bitcast[DType.int16, 1](UInt16(_be_bits(bytes[0:2]))))
    var expected = _NUMERIC_HEADER + 2 * ndigits
    if len(bytes) != expected:
        raise _binary_value_error(
            "numeric",
            String(
                "has ",
                len(bytes),
                " bytes, expected 8 + 2*ndigits = ",
                expected,
            ),
        )
    var weight = bitcast[DType.int16, 1](UInt16(_be_bits(bytes[2:4])))
    var sign = UInt16(_be_bits(bytes[4:6]))
    var dscale = UInt16(_be_bits(bytes[6:8]))
    if (
        sign != _NUMERIC_POS
        and sign != _NUMERIC_NEG
        and sign != _NUMERIC_NAN
        and sign != _NUMERIC_PINF
        and sign != _NUMERIC_NINF
    ):
        raise _binary_value_error(
            "numeric", String("invalid sign ", _hex4(sign))
        )
    if sign != _NUMERIC_POS and sign != _NUMERIC_NEG:
        return Decimal._from_parts(sign, 0, 0, List[Int16]())
    if dscale > _NUMERIC_DSCALE_MAX:
        raise _binary_value_error(
            "numeric", String("dscale ", dscale, " out of range")
        )
    var digits = List[Int16](capacity=ndigits)
    for i in range(ndigits):
        var at = _NUMERIC_HEADER + 2 * i
        var digit = bitcast[DType.int16, 1](
            UInt16(_be_bits(bytes[at : at + 2]))
        )
        if digit < 0 or digit > _NUMERIC_DIGIT_MAX:
            raise _binary_value_error(
                "numeric", String("digit ", digit, " out of range")
            )
        digits.append(digit)
    # `Decimal` normalizes by dropping leading zero groups and lowering the
    # weight once per group, and keeps the weight in an `Int16`. A wire form
    # whose weight is already near `Int16.MIN` would wrap there into a huge
    # positive exponent, so the stripped weight is checked before handing the
    # parts over. PostgreSQL's own `make_result` rejects the same cells with
    # `value overflows numeric format`.
    var lead = 0
    while lead < len(digits) and digits[lead] == 0:
        lead += 1
    var stripped = Int(weight) - lead
    if stripped < Int(Int16.MIN):
        raise _binary_value_error(
            "numeric",
            String(
                "weight ",
                stripped,
                " out of range after stripping ",
                lead,
                " leading zero groups",
            ),
        )
    return Decimal._from_parts(sign, weight, dscale, digits^)


def decode_uuid[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin]) raises PgError -> UUID:
    """Decode the sixteen byte PostgreSQL `uuid` binary format.

    The bytes are the UUID itself, in the order its canonical text form
    spells them out, so nothing is byte-swapped here.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The cell's binary-format bytes.

    Returns:
        The value, holding the sixteen bytes as given.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `bytes` is not exactly
            sixteen bytes.
    """
    _check_length(bytes, "uuid", _UUID_BYTES)
    var raw = Array[UInt8, _UUID_BYTES](fill=0)
    for i in range(_UUID_BYTES):
        raw[i] = bytes[i]
    return UUID(raw)


def decode_date[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin]) raises PgError -> Date:
    """Decode the four byte PostgreSQL `date` binary format.

    The wire value is the day count from 2000-01-01, which is exactly what
    `Date` holds, so it is kept as-is. The `infinity` / `-infinity`
    sentinels are ordinary values here and are not singled out; no range
    check is applied, because every four byte cell a `date` column can
    send is one `Date` can hold.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The cell's binary-format bytes.

    Returns:
        The value, holding the server's day count.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `bytes` is not exactly
            four bytes.
    """
    _check_length(bytes, "date", 4)
    return Date(bitcast[DType.int32, 1](UInt32(_be_bits(bytes))))


def decode_timestamp[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin]) raises PgError -> Timestamp:
    """Decode the eight byte PostgreSQL `timestamp` binary format.

    The wire value is the microsecond count from 2000-01-01 00:00:00,
    which is what `Timestamp` holds, sentinels included, so only the
    length is checked.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The cell's binary-format bytes.

    Returns:
        The value, holding the server's microsecond count.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `bytes` is not exactly
            eight bytes.
    """
    _check_length(bytes, "timestamp", 8)
    return Timestamp(bitcast[DType.int64, 1](_be_bits(bytes)))


def decode_timestamptz[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin]) raises PgError -> TimestampTz:
    """Decode the eight byte PostgreSQL `timestamptz` binary format.

    The wire value is the same microsecond count as `timestamp`, read as
    UTC -- the server's session `TimeZone` changes the text form only, so
    this decoder is independent of it.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The cell's binary-format bytes.

    Returns:
        The value, holding the server's microsecond count in UTC.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `bytes` is not exactly
            eight bytes.
    """
    _check_length(bytes, "timestamptz", 8)
    return TimestampTz(bitcast[DType.int64, 1](_be_bits(bytes)))


def decode_time[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin]) raises PgError -> Time:
    """Decode the eight byte PostgreSQL `time` binary format.

    The wire value is the microsecond offset into the day, which is what
    `Time` holds. Unlike the timestamp types, `time` has no sentinels and a
    bounded domain, so the value is range checked: `0..86400000000`, the
    upper bound included because `24:00:00` is a `time` PostgreSQL both
    stores and prints.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The cell's binary-format bytes.

    Returns:
        The value, holding the server's microsecond offset.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `bytes` is not exactly
            eight bytes, or when the offset is outside a day.
    """
    _check_length(bytes, "time", 8)
    var micros = bitcast[DType.int64, 1](_be_bits(bytes))
    if micros < 0 or micros > _MAX_TIME_MICROS:
        raise _binary_value_error("time", String(micros, " is out of range"))
    return Time(micros)


def decode_timetz[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin]) raises PgError -> TimeTz:
    """Decode the twelve byte PostgreSQL `timetz` binary format.

    The cell is an eight byte microsecond offset into the day followed by a
    four byte zone offset in seconds, counted **positive west** of UTC the
    way PostgreSQL counts it, so `+09` arrives as -32400. The zone is range
    checked against the 16 hours PostgreSQL allows; the time of day is range
    checked too, `0..86400000000` inclusive, since `24:00:00` with a zone is
    valid.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The cell's binary-format bytes.

    Returns:
        The value, holding the microsecond offset and the zone.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `bytes` is not exactly
            twelve bytes, when the offset is outside a day, or when the
            zone is 16 hours or wider.
    """
    _check_length(bytes, "timetz", 12)
    var micros = bitcast[DType.int64, 1](_be_bits(bytes[0:8]))
    var zone = bitcast[DType.int32, 1](UInt32(_be_bits(bytes[8:12])))
    if micros < 0 or micros > _MAX_TIME_MICROS:
        raise _binary_value_error("timetz", String(micros, " is out of range"))
    if zone <= -_MAX_OFFSET_SECONDS or zone >= _MAX_OFFSET_SECONDS:
        raise _binary_value_error(
            "timetz", String("zone ", zone, " is out of range")
        )
    return TimeTz(micros, zone)


def decode_interval[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin]) raises PgError -> Interval:
    """Decode the sixteen byte PostgreSQL `interval` binary format.

    The cell is an eight byte microsecond count, then a four byte day count,
    then a four byte month count -- that order, not the order the text form
    prints them in. All three are kept as they arrive: months are never
    folded into days nor days into microseconds, since a month is not a
    fixed number of days. PostgreSQL 17's `infinity` sentinels, all three
    fields at their extreme, are ordinary values here, so no range check
    applies.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.

    Args:
        bytes: The cell's binary-format bytes.

    Returns:
        The value, holding the server's three counts.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `bytes` is not exactly
            sixteen bytes.
    """
    _check_length(bytes, "interval", 16)
    var micros = bitcast[DType.int64, 1](_be_bits(bytes[0:8]))
    var days = bitcast[DType.int32, 1](UInt32(_be_bits(bytes[8:12])))
    var months = bitcast[DType.int32, 1](UInt32(_be_bits(bytes[12:16])))
    return Interval(micros, days, months)


def decode_binary[
    origin: ImmOrigin, //, T: Copyable
](
    bytes: Span[UInt8, origin], oid: UInt32, column: Int = -1
) raises PgError -> T:
    """Decode one binary-format PostgreSQL value into `T`.

    The column OID must match `T` exactly; no widening or narrowing
    conversion is performed. `Bool` requires oid 16, `Int16` oid 21,
    `Int32` oid 23, `Int64` and `Int` oid 20, `Float32` oid 700,
    `Float64` oid 701, `List[UInt8]` oid 17, `Decimal` oid 1700
    (`numeric`), `UUID` oid 2950, `Date` oid 1082, `Timestamp` oid 1114,
    `TimestampTz` oid 1184, `Time` oid 1083, `TimeTz` oid 1266 and
    `Interval` oid 1186. `String` requires one of
    the six string-shaped OIDs -- 25 (`text`), 1043 (`varchar`), 1042
    (`bpchar`), 19 (`name`), 114 (`json`) and 3802 (`jsonb`) -- and is
    therefore not the catch-all it is on the text path. Any other `T` is a
    compile-time error.

    A `jsonb` cell opens with a one byte format version, which must be 1;
    the remaining bytes are the JSON text. `String` copies the payload
    bytes one for one, so an embedded NUL is preserved, but the payload
    must be well-formed UTF-8: it is checked before the copy, and the
    `jsonb` version byte is already gone by then, so a reported offset
    counts from the start of the JSON text.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.
        T: The Mojo type to decode into.

    Args:
        bytes: The cell's binary-format bytes, as `PQgetvalue` and
            `PQgetlength` delimit them.
        oid: The column type OID reported by `PQftype`.
        column: Zero-based column index, used only to name the column in
            the `String` UTF-8 error. Defaults to -1, which prints
            `of column ?`.

    Returns:
        The decoded value.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `oid` does not match
            `T`, when a fixed-width cell has the wrong number of bytes, or
            when the wire value is outside the type's domain.
        PgError: `PgErrorKind.TYPE_MISMATCH` with the message
            `invalid UTF-8 at byte N of column M` when `T` is `String` and
            the cell's payload is not well-formed UTF-8. The message names
            the position only; it never quotes the cell.
    """
    comptime if T == Bool:
        if oid != OID_BOOL:
            raise _binary_oid_error(oid, "Bool")
        var value = decode_bool(bytes)
        return rebind[T](value).copy()
    elif T == Int16:
        if oid != OID_INT2:
            raise _binary_oid_error(oid, "Int16")
        var value = decode_int16(bytes)
        return rebind[T](value).copy()
    elif T == Int32:
        if oid != OID_INT4:
            raise _binary_oid_error(oid, "Int32")
        var value = decode_int32(bytes)
        return rebind[T](value).copy()
    elif T == Int64:
        if oid != OID_INT8:
            raise _binary_oid_error(oid, "Int64")
        var value = decode_int64(bytes)
        return rebind[T](value).copy()
    elif T == Int:
        if oid != OID_INT8:
            raise _binary_oid_error(oid, "Int")
        var value = Int(decode_int64(bytes))
        return rebind[T](value).copy()
    elif T == Float32:
        if oid != OID_FLOAT4:
            raise _binary_oid_error(oid, "Float32")
        var value = decode_float32(bytes)
        return rebind[T](value).copy()
    elif T == Float64:
        if oid != OID_FLOAT8:
            raise _binary_oid_error(oid, "Float64")
        var value = decode_float64(bytes)
        return rebind[T](value).copy()
    elif T == String:
        var payload = _string_payload(bytes, oid)
        var value = String(_validated_utf8(payload, column))
        return rebind[T](value).copy()
    elif T == List[UInt8]:
        if oid != OID_BYTEA:
            raise _binary_oid_error(oid, "List[UInt8]")
        var value = List[UInt8](capacity=len(bytes))
        for i in range(len(bytes)):
            value.append(bytes[i])
        return rebind[T](value).copy()
    elif T == Decimal:
        if oid != OID_NUMERIC:
            raise _binary_oid_error(oid, "Decimal")
        var value = decode_numeric(bytes)
        return rebind[T](value).copy()
    elif T == UUID:
        if oid != OID_UUID:
            raise _binary_oid_error(oid, "UUID")
        var value = decode_uuid(bytes)
        return rebind[T](value).copy()
    elif T == Date:
        if oid != OID_DATE:
            raise _binary_oid_error(oid, "Date")
        var value = decode_date(bytes)
        return rebind[T](value).copy()
    elif T == Timestamp:
        if oid != OID_TIMESTAMP:
            raise _binary_oid_error(oid, "Timestamp")
        var value = decode_timestamp(bytes)
        return rebind[T](value).copy()
    elif T == TimestampTz:
        if oid != OID_TIMESTAMPTZ:
            raise _binary_oid_error(oid, "TimestampTz")
        var value = decode_timestamptz(bytes)
        return rebind[T](value).copy()
    elif T == Time:
        if oid != OID_TIME:
            raise _binary_oid_error(oid, "Time")
        var value = decode_time(bytes)
        return rebind[T](value).copy()
    elif T == TimeTz:
        if oid != OID_TIMETZ:
            raise _binary_oid_error(oid, "TimeTz")
        var value = decode_timetz(bytes)
        return rebind[T](value).copy()
    elif T == Interval:
        if oid != OID_INTERVAL:
            raise _binary_oid_error(oid, "Interval")
        var value = decode_interval(bytes)
        return rebind[T](value).copy()
    else:
        comptime assert False, "unsupported type for Row.get"
