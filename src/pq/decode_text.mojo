"""Text-format decoding of PostgreSQL values into Mojo types.

Holds the PostgreSQL OID constants the package understands -- this module
is their only home, and `pq.decode_binary`, `pq.encode_binary` and
`pq.params` import them from here -- the `comptime if` type switch
`decode_text[T]` that turns a libpq text-format cell into a Mojo value,
and `parse_bytea_hex` for the `\\x`-prefixed hex output of `bytea`. Types
whose text form needs a parser of its own (`Decimal`, `UUID`) provide a
`parse` static method in `pq.types_numeric` / `pq.types_uuid`, which the
type switch calls. The requested type must match the column OID exactly:
neither widening (`int2` into `Int32`) nor narrowing is performed, so a
mismatch raises `PgError(PgErrorKind.TYPE_MISMATCH, ...)` before any
conversion is attempted. `String` is the single exception; it accepts any
OID and returns the text unchanged.

Every `TYPE_MISMATCH` message names the requested PostgreSQL type and
quotes the offending input text.
"""

from pq.errors import PgError, PgErrorKind
from pq.types_numeric import Decimal
from pq.types_uuid import UUID

comptime OID_BOOL = UInt32(16)
"""OID of `bool`."""

comptime OID_BYTEA = UInt32(17)
"""OID of `bytea`."""

comptime OID_NAME = UInt32(19)
"""OID of `name`."""

comptime OID_INT8 = UInt32(20)
"""OID of `int8` (`bigint`)."""

comptime OID_INT2 = UInt32(21)
"""OID of `int2` (`smallint`)."""

comptime OID_INT4 = UInt32(23)
"""OID of `int4` (`integer`)."""

comptime OID_TEXT = UInt32(25)
"""OID of `text`."""

comptime OID_JSON = UInt32(114)
"""OID of `json`."""

comptime OID_FLOAT4 = UInt32(700)
"""OID of `float4` (`real`)."""

comptime OID_FLOAT8 = UInt32(701)
"""OID of `float8` (`double precision`)."""

comptime OID_BPCHAR = UInt32(1042)
"""OID of `bpchar` (`character(n)`)."""

comptime OID_VARCHAR = UInt32(1043)
"""OID of `varchar` (`character varying`)."""

comptime OID_NUMERIC = UInt32(1700)
"""OID of `numeric` (`decimal`)."""

comptime OID_UUID = UInt32(2950)
"""OID of `uuid`."""

comptime OID_JSONB = UInt32(3802)
"""OID of `jsonb`."""

comptime _INT2_MIN = -32768
comptime _INT2_MAX = 32767
comptime _INT4_MIN = -2147483648
comptime _INT4_MAX = 2147483647

comptime _BACKSLASH = UInt8(ord("\\"))
comptime _LOWER_X = UInt8(ord("x"))


def _oid_error(oid: UInt32, pg_type: String, text: String) -> PgError:
    """Build the `TYPE_MISMATCH` error for a column of the wrong OID."""
    return PgError(
        PgErrorKind.TYPE_MISMATCH,
        String(
            "column is oid ",
            oid,
            " but ",
            pg_type,
            ' was requested (text: "',
            text,
            '")',
        ),
    )


def _decode_error(pg_type: String, text: String) -> PgError:
    """Build the `TYPE_MISMATCH` error for text that does not parse."""
    return PgError(
        PgErrorKind.TYPE_MISMATCH,
        String('cannot decode "', text, '" as ', pg_type),
    )


def _hex_digit(byte: UInt8) -> Int:
    """Return the value of one hex digit, or -1 when `byte` is not hex."""
    if byte >= UInt8(ord("0")) and byte <= UInt8(ord("9")):
        return Int(byte) - ord("0")
    if byte >= UInt8(ord("a")) and byte <= UInt8(ord("f")):
        return Int(byte) - ord("a") + 10
    if byte >= UInt8(ord("A")) and byte <= UInt8(ord("F")):
        return Int(byte) - ord("A") + 10
    return -1


def parse_bytea_hex(text: String) raises PgError -> List[UInt8]:
    """Decode libpq's `\\x` hex output for `bytea` into raw bytes.

    `text` must start with a backslash followed by `x`; the remaining
    characters must form an even number of hex digits, in either case.
    `"\\x"` alone decodes to an empty list. The older `escape` output
    format (`\\000`) is rejected.

    Args:
        text: The text-format `bytea` value as libpq returned it.

    Returns:
        The decoded bytes, one per pair of hex digits.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when the `\\x` prefix is
            missing, an odd number of digits follows it, or any digit is
            not hexadecimal.
    """
    var bytes = text.as_bytes()
    var size = len(bytes)
    if size < 2 or bytes[0] != _BACKSLASH or bytes[1] != _LOWER_X:
        raise _decode_error("bytea", text)
    if (size - 2) % 2 != 0:
        raise _decode_error("bytea", text)
    var out = List[UInt8](capacity=(size - 2) // 2)
    var i = 2
    while i < size:
        var hi = _hex_digit(bytes[i])
        var lo = _hex_digit(bytes[i + 1])
        if hi < 0 or lo < 0:
            raise _decode_error("bytea", text)
        out.append(UInt8(hi * 16 + lo))
        i += 2
    return out^


def decode_text[T: Copyable](text: String, oid: UInt32) raises PgError -> T:
    """Decode one text-format PostgreSQL value into `T`.

    The column OID must match `T` exactly; no widening or narrowing
    conversion is performed. `Bool` requires oid 16, `Int16` oid 21,
    `Int32` oid 23, `Int64` and `Int` oid 20, `Float32` oid 700,
    `Float64` oid 701, `List[UInt8]` oid 17, `Decimal` oid 1700
    (`numeric`) and `UUID` oid 2950. `String` accepts any OID and never
    fails. Any other `T` is a compile-time error.

    Parameters:
        T: The Mojo type to decode into.

    Args:
        text: The cell contents as libpq returned them.
        oid: The column type OID reported by `PQftype`.

    Returns:
        The decoded value.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `oid` does not match
            `T`, when `text` does not parse as `T`, or when the parsed
            value falls outside the range of `T`.
    """
    comptime if T == Bool:
        if oid != OID_BOOL:
            raise _oid_error(oid, "bool", text)
        var value: Bool
        if text == "t":
            value = True
        elif text == "f":
            value = False
        else:
            raise _decode_error("bool", text)
        return rebind[T](value).copy()
    elif T == Int16:
        if oid != OID_INT2:
            raise _oid_error(oid, "int2", text)
        var wide: Int
        try:
            wide = atol(text)
        except e:
            raise _decode_error("int2", text)
        if wide < _INT2_MIN or wide > _INT2_MAX:
            raise _decode_error("int2", text)
        var value = Int16(wide)
        return rebind[T](value).copy()
    elif T == Int32:
        if oid != OID_INT4:
            raise _oid_error(oid, "int4", text)
        var wide: Int
        try:
            wide = atol(text)
        except e:
            raise _decode_error("int4", text)
        if wide < _INT4_MIN or wide > _INT4_MAX:
            raise _decode_error("int4", text)
        var value = Int32(wide)
        return rebind[T](value).copy()
    elif T == Int64:
        if oid != OID_INT8:
            raise _oid_error(oid, "int8", text)
        var wide: Int
        try:
            wide = atol(text)
        except e:
            raise _decode_error("int8", text)
        var value = Int64(wide)
        return rebind[T](value).copy()
    elif T == Int:
        if oid != OID_INT8:
            raise _oid_error(oid, "int8", text)
        var value: Int
        try:
            value = atol(text)
        except e:
            raise _decode_error("int8", text)
        return rebind[T](value).copy()
    elif T == Float32:
        if oid != OID_FLOAT4:
            raise _oid_error(oid, "float4", text)
        var value: Float32
        try:
            value = Float32(atof(text))
        except e:
            raise _decode_error("float4", text)
        return rebind[T](value).copy()
    elif T == Float64:
        if oid != OID_FLOAT8:
            raise _oid_error(oid, "float8", text)
        var value: Float64
        try:
            value = atof(text)
        except e:
            raise _decode_error("float8", text)
        return rebind[T](value).copy()
    elif T == String:
        return rebind[T](text).copy()
    elif T == List[UInt8]:
        if oid != OID_BYTEA:
            raise _oid_error(oid, "bytea", text)
        var value = parse_bytea_hex(text)
        return rebind[T](value).copy()
    elif T == Decimal:
        if oid != OID_NUMERIC:
            raise _oid_error(oid, "numeric", text)
        var value = Decimal.parse(text)
        return rebind[T](value).copy()
    elif T == UUID:
        if oid != OID_UUID:
            raise _oid_error(oid, "uuid", text)
        var value = UUID.parse(text)
        return rebind[T](value).copy()
    else:
        comptime assert False, "unsupported type for Row.get"
