"""Binary-format decoding of PostgreSQL wire bytes into Mojo types.

Holds eleven decoders -- the fixed-width `decode_bool`, `decode_int16`,
`decode_int32`, `decode_int64`, `decode_float32`, `decode_float64`,
`decode_uuid`, `decode_date`, `decode_timestamp` and
`decode_timestamptz`, plus the variable-length `decode_numeric` -- and the
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
  16383 and digit groups in `0..9999`. `date`, `timestamp` and
  `timestamptz` have no such check: every cell of the right width is a
  value those types can hold, the `infinity` sentinels included.

`String` copies exactly the `PQgetlength` bytes it is given and does not
treat them as a C string, so a `text` value containing NUL survives intact.
UTF-8 is not validated, matching the text path's `Result._text`.

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
    OID_JSON,
    OID_JSONB,
    OID_NAME,
    OID_NUMERIC,
    OID_TEXT,
    OID_TIMESTAMP,
    OID_TIMESTAMPTZ,
    OID_UUID,
    OID_VARCHAR,
)
from pq.errors import PgError, PgErrorKind
from pq.types_datetime import Date, Timestamp, TimestampTz
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
            `sign`, `dscale` or a digit group is out of range.
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


def decode_binary[
    origin: ImmOrigin, //, T: Copyable
](bytes: Span[UInt8, origin], oid: UInt32) raises PgError -> T:
    """Decode one binary-format PostgreSQL value into `T`.

    The column OID must match `T` exactly; no widening or narrowing
    conversion is performed. `Bool` requires oid 16, `Int16` oid 21,
    `Int32` oid 23, `Int64` and `Int` oid 20, `Float32` oid 700,
    `Float64` oid 701, `List[UInt8]` oid 17, `Decimal` oid 1700
    (`numeric`), `UUID` oid 2950, `Date` oid 1082, `Timestamp` oid 1114
    and `TimestampTz` oid 1184. `String` requires one of
    the six string-shaped OIDs -- 25 (`text`), 1043 (`varchar`), 1042
    (`bpchar`), 19 (`name`), 114 (`json`) and 3802 (`jsonb`) -- and is
    therefore not the catch-all it is on the text path. Any other `T` is a
    compile-time error.

    A `jsonb` cell opens with a one byte format version, which must be 1;
    the remaining bytes are the JSON text. `String` copies the bytes it is
    handed verbatim, so an embedded NUL is preserved and UTF-8 is not
    validated.

    Parameters:
        origin: Origin of the viewed bytes; inferred from `bytes`.
        T: The Mojo type to decode into.

    Args:
        bytes: The cell's binary-format bytes, as `PQgetvalue` and
            `PQgetlength` delimit them.
        oid: The column type OID reported by `PQftype`.

    Returns:
        The decoded value.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `oid` does not match
            `T`, when a fixed-width cell has the wrong number of bytes, or
            when the wire value is outside the type's domain.
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
        if oid == OID_JSONB:
            if len(bytes) < 1:
                raise _binary_length_error("jsonb", len(bytes), 1)
            if bytes[0] != _JSONB_VERSION:
                raise _binary_value_error(
                    "jsonb",
                    String("version byte is ", bytes[0], ", expected 1"),
                )
            var value = String(unsafe_from_utf8=bytes[1:])
            return rebind[T](value).copy()
        if (
            oid != OID_TEXT
            and oid != OID_VARCHAR
            and oid != OID_BPCHAR
            and oid != OID_NAME
            and oid != OID_JSON
        ):
            raise _binary_oid_error(oid, "String")
        var value = String(unsafe_from_utf8=bytes)
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
    else:
        comptime assert False, "unsupported type for Row.get"
