"""Binary-format decoding of PostgreSQL wire bytes into Mojo types.

Holds six fixed-width decoders -- `decode_bool`, `decode_int16`,
`decode_int32`, `decode_int64`, `decode_float32` and `decode_float64` -- and
the `comptime if` type switch `decode_binary[T]` that turns one libpq
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
  zero-padded.
- Values outside the type's wire domain are rejected: a `bool` byte must be
  0 or 1, and a `jsonb` cell must open with version byte 1.

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
    OID_FLOAT4,
    OID_FLOAT8,
    OID_INT2,
    OID_INT4,
    OID_INT8,
    OID_NAME,
    OID_TEXT,
    OID_VARCHAR,
)
from pq.errors import PgError, PgErrorKind

# Replace these two with imports from `pq.decode_text` once T3 adds
# `OID_JSON` / `OID_JSONB` there; that module is the only home for OIDs.
comptime _OID_JSON = UInt32(114)
comptime _OID_JSONB = UInt32(3802)

comptime _JSONB_VERSION = UInt8(1)


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


def decode_binary[
    origin: ImmOrigin, //, T: Copyable
](bytes: Span[UInt8, origin], oid: UInt32) raises PgError -> T:
    """Decode one binary-format PostgreSQL value into `T`.

    The column OID must match `T` exactly; no widening or narrowing
    conversion is performed. `Bool` requires oid 16, `Int16` oid 21,
    `Int32` oid 23, `Int64` and `Int` oid 20, `Float32` oid 700,
    `Float64` oid 701 and `List[UInt8]` oid 17. `String` requires one of
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
        if oid == _OID_JSONB:
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
            and oid != _OID_JSON
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
    else:
        comptime assert False, "unsupported type for Row.get"
