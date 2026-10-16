"""Binary-format encoding of Mojo values into PostgreSQL wire bytes.

Holds eight encoders -- `encode_bool`, `encode_int16`, `encode_int32`,
`encode_int64`, `encode_float32`, `encode_float64`, `encode_numeric` and
`encode_uuid` -- each returning the value's PostgreSQL binary
representation as a `List[UInt8]` in network byte order (big-endian).
Lengths are fixed for all but one: 1 byte for `bool`, 2 for `int2`, 4 for
`int4` and `float4`, 8 for `int8` and `float8`, 16 for `uuid`. Only
`numeric` is variable: an 8 byte header plus two bytes per base-10000
digit group.

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
