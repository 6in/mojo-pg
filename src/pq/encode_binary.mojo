"""Binary-format encoding of Mojo values into PostgreSQL wire bytes.

Holds exactly six encoders -- `encode_bool`, `encode_int16`, `encode_int32`,
`encode_int64`, `encode_float32` and `encode_float64` -- each returning the
value's PostgreSQL binary representation as a `List[UInt8]` in network byte
order (big-endian). Lengths are fixed: 1 byte for `bool`, 2 for `int2`, 4
for `int4` and `float4`, 8 for `int8` and `float8`.

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
