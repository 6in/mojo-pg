"""Binary-format encoding of Mojo values into PostgreSQL wire bytes.

Holds fifteen encoders -- `encode_bool`, `encode_int16`, `encode_int32`,
`encode_int64`, `encode_float32`, `encode_float64`, `encode_numeric`,
`encode_date`, `encode_timestamp`, `encode_timestamptz`, `encode_time`,
`encode_timetz`, `encode_interval`,
`encode_uuid` and `encode_array` -- each returning the value's PostgreSQL
binary representation as a `List[UInt8]` in network byte order
(big-endian).
Lengths are fixed for all but two: 1 byte for `bool`, 2 for `int2`, 4 for
`int4`, `float4` and `date`, 8 for `int8`, `float8`, `timestamp`,
`timestamptz` and `time`, 12 for `timetz`, 16 for `interval` and `uuid`.
`numeric` is variable: an 8 byte
header plus two bytes per base-10000 digit group. So is `encode_array`,
which takes the elements already encoded -- it is the one encoder that
does not look at a Mojo value at all, so it serves every element type
without being generic.

There is no `Int` encoder on purpose: callers widen with `Int64(v)` and use
`encode_int64`, so the wire width is always chosen explicitly.

Bytes are produced by shifting the value's bit pattern, never by reading the
value's storage through a pointer, so the output does not depend on the
host's endianness.

Phase 3's `decode_binary` is the inverse of this module: names are paired as
`encode_<pgtype>` / `decode_<pgtype>`, so every encoder added here gets a
decoder of the same suffix there.
"""

from std.memory import bitcast

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


def _be_bytes(bits: UInt64, size: Int) -> List[UInt8]:
    """Return the low `size` bytes of `bits`, most significant byte first.

    Args:
        bits: The bit pattern to serialise, right-aligned in a `UInt64`.
        size: How many of the low bytes to emit.

    Returns:
        Exactly `size` bytes in network byte order.
    """
    var out = List[UInt8](capacity=size)
    for i in range(size):
        out.append(UInt8((bits >> UInt64(8 * (size - 1 - i))) & 0xFF))
    return out^


def _append_be16(mut out: List[UInt8], v: UInt16):
    """Append `v` to `out` as two bytes, most significant byte first.

    Args:
        out: The byte list to extend in place.
        v: The bit pattern to serialise.
    """
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8(v & 0xFF))


def encode_bool(v: Bool) -> List[UInt8]:
    """Encode `v` as the one byte PostgreSQL `bool` binary format.

    Args:
        v: The value to encode.

    Returns:
        `[1]` for `True`, `[0]` for `False`.
    """
    return _be_bytes(UInt64(1) if v else UInt64(0), 1)


def encode_int16(v: Int16) -> List[UInt8]:
    """Encode `v` as the two byte PostgreSQL `int2` binary format.

    Args:
        v: The value to encode.

    Returns:
        Two bytes, big-endian two's complement.
    """
    return _be_bytes(UInt64(bitcast[DType.uint16, 1](v)), 2)


def encode_int32(v: Int32) -> List[UInt8]:
    """Encode `v` as the four byte PostgreSQL `int4` binary format.

    Args:
        v: The value to encode.

    Returns:
        Four bytes, big-endian two's complement.
    """
    return _be_bytes(UInt64(bitcast[DType.uint32, 1](v)), 4)


def encode_int64(v: Int64) -> List[UInt8]:
    """Encode `v` as the eight byte PostgreSQL `int8` binary format.

    Args:
        v: The value to encode.

    Returns:
        Eight bytes, big-endian two's complement.
    """
    return _be_bytes(bitcast[DType.uint64, 1](v), 8)


def encode_float32(v: Float32) -> List[UInt8]:
    """Encode `v` as the four byte PostgreSQL `float4` binary format.

    The IEEE 754 single-precision bit pattern is emitted as-is, so NaN and
    the infinities round-trip unchanged.

    Args:
        v: The value to encode.

    Returns:
        Four bytes, big-endian IEEE 754 binary32.
    """
    return _be_bytes(UInt64(bitcast[DType.uint32, 1](v)), 4)


def encode_float64(v: Float64) -> List[UInt8]:
    """Encode `v` as the eight byte PostgreSQL `float8` binary format.

    The IEEE 754 double-precision bit pattern is emitted as-is, so NaN and
    the infinities round-trip unchanged.

    Args:
        v: The value to encode.

    Returns:
        Eight bytes, big-endian IEEE 754 binary64.
    """
    return _be_bytes(bitcast[DType.uint64, 1](v), 8)


def encode_numeric(d: Decimal) -> List[UInt8]:
    """Encode `d` as the PostgreSQL `numeric` binary format.

    The output is the `ndigits`, `weight`, `sign` and `dscale` header
    followed by `ndigits` base-10000 digit groups, every field two bytes
    big-endian. `Decimal` keeps its digits normalised, so this is a plain
    transcription of its fields and needs no special case: `NaN` and the
    infinities hold no digits and a zeroed weight and dscale, which is
    exactly the `0000 0000 <sign> 0000` the server expects for them.

    Args:
        d: The value to encode.

    Returns:
        `8 + 2 * ndigits` bytes, big-endian throughout.
    """
    var ndigits = len(d._digits)
    var out = List[UInt8](capacity=8 + 2 * ndigits)
    _append_be16(out, UInt16(ndigits))
    _append_be16(out, bitcast[DType.uint16, 1](d._weight))
    _append_be16(out, d._sign)
    _append_be16(out, d._dscale)
    for i in range(ndigits):
        _append_be16(out, bitcast[DType.uint16, 1](d._digits[i]))
    return out^


def encode_date(d: Date) -> List[UInt8]:
    """Encode `d` as the four byte PostgreSQL `date` binary format.

    `Date` already holds the day count from 2000-01-01 the wire format
    wants, so this is `encode_int32` of that field; the `infinity`
    sentinels go out unchanged.

    Args:
        d: The value to encode.

    Returns:
        Four bytes, big-endian two's complement.
    """
    return encode_int32(d.days)


def encode_timestamp(t: Timestamp) -> List[UInt8]:
    """Encode `t` as the eight byte PostgreSQL `timestamp` binary format.

    `Timestamp` already holds the microsecond count from 2000-01-01
    00:00:00 the wire format wants, so this is `encode_int64` of that
    field; the `infinity` sentinels go out unchanged.

    Args:
        t: The value to encode.

    Returns:
        Eight bytes, big-endian two's complement.
    """
    return encode_int64(t.micros)


def encode_timestamptz(t: TimestampTz) -> List[UInt8]:
    """Encode `t` as the eight byte `timestamptz` binary format.

    The field is the same microsecond count as `timestamp`, and the server
    reads a binary `timestamptz` parameter as UTC, which is the time zone
    `TimestampTz` keeps its value in.

    Args:
        t: The value to encode.

    Returns:
        Eight bytes, big-endian two's complement.
    """
    return encode_int64(t.micros)


def encode_time(t: Time) -> List[UInt8]:
    """Encode `t` as the eight byte PostgreSQL `time` binary format.

    `Time` already holds the microsecond offset into the day the wire
    format wants, so this is `encode_int64` of that field.

    Args:
        t: The value to encode.

    Returns:
        Eight bytes, big-endian two's complement.
    """
    return encode_int64(t.micros)


def encode_timetz(t: TimeTz) -> List[UInt8]:
    """Encode `t` as the twelve byte PostgreSQL `timetz` binary format.

    The microsecond offset into the day goes out first, then the zone in
    seconds. `TimeTz` already counts the zone positive west of UTC, the way
    PostgreSQL does, so no sign is flipped here.

    Args:
        t: The value to encode.

    Returns:
        Twelve bytes: eight of time, then four of zone, both big-endian.
    """
    var out = encode_int64(t.micros)
    out.extend(encode_int32(t.offset_secs))
    return out^


def encode_interval(v: Interval) -> List[UInt8]:
    """Encode `v` as the sixteen byte PostgreSQL `interval` binary format.

    The three fields go out in the order the wire format wants -- eight
    bytes of microseconds, four of days, four of months -- which is not the
    order the text form prints them in. Nothing is normalised, so the
    months a caller set stay months.

    Args:
        v: The value to encode.

    Returns:
        Sixteen bytes: microseconds, days, then months, all big-endian.
    """
    var out = encode_int64(v.micros)
    out.extend(encode_int32(v.days))
    out.extend(encode_int32(v.months))
    return out^


def encode_array(
    elems: List[Optional[List[UInt8]]], elem_oid: UInt32
) -> List[UInt8]:
    """Encode already-encoded elements as a one-dimensional array.

    The layout is the one `array_recv` reads and `array_send` writes: a
    twelve byte header of `ndim`, `flags` and the element type OID,
    followed -- only when there is a dimension at all -- by the `dim` and
    `lbound` pair and then the elements, each a four byte length and that
    many bytes. A None element is the length `-1` and no bytes.

    An empty array is the header alone with `ndim` 0, which is what the
    server sends for `'{}'`: no dimension words follow, so a reader must
    not look for them. `flags` is 1 exactly when some element is None,
    matching the server's "has nulls" bit; readers here ignore it and
    trust the per-element length, but a server reading these bytes does
    use it.

    The lower bound is always 1, so a value built here round-trips as a
    plain one-based PostgreSQL array even if it came from a slice that
    had been printed as `[0:1]={...}`.

    Args:
        elems: The per-element encodings in order, None for a SQL NULL
            element.
        elem_oid: The PostgreSQL type OID of the elements.

    Returns:
        The array's binary wire bytes, twelve of them for an empty array.
    """
    var has_nulls = False
    for i in range(len(elems)):
        if not elems[i]:
            has_nulls = True
            break

    var out = List[UInt8](capacity=12 + 8 * len(elems))
    out.extend(encode_int32(Int32(0) if len(elems) == 0 else Int32(1)))
    out.extend(encode_int32(Int32(1) if has_nulls else Int32(0)))
    out.extend(encode_int32(bitcast[DType.int32, 1](elem_oid)))
    if len(elems) == 0:
        return out^

    out.extend(encode_int32(Int32(len(elems))))
    out.extend(encode_int32(Int32(1)))
    for i in range(len(elems)):
        if elems[i]:
            ref bytes = elems[i].value()
            out.extend(encode_int32(Int32(len(bytes))))
            for j in range(len(bytes)):
                out.append(bytes[j])
        else:
            out.extend(encode_int32(Int32(-1)))
    return out^


def encode_uuid(u: UUID) -> List[UInt8]:
    """Encode `u` as the sixteen byte PostgreSQL `uuid` binary format.

    The bytes go out in the order the canonical text form spells them, so
    nothing is byte-swapped.

    Args:
        u: The value to encode.

    Returns:
        Exactly sixteen bytes.
    """
    var out = List[UInt8](capacity=16)
    for i in range(16):
        out.append(u.bytes[i])
    return out^
