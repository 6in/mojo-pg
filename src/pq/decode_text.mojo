"""Text-format decoding of PostgreSQL values into Mojo types.

Holds the PostgreSQL OID constants the package understands -- this module
is their only home, and `pq.decode_binary`, `pq.encode_binary` and
`pq.params` import them from here -- the `comptime if` type switch
`decode_text[T]` that turns a libpq text-format cell into a Mojo value,
and `parse_bytea_hex` for the `\\x`-prefixed hex output of `bytea`. Types
whose text form needs a parser of its own (`Decimal`, `UUID`, `Date`,
`Timestamp`, `TimestampTz`, `Time`, `TimeTz`, `Interval`) provide a
`parse` static method in
`pq.types_numeric` / `pq.types_uuid` / `pq.types_datetime`, which the
type switch calls. The requested type must match the column OID exactly:
neither widening (`int2` into `Int32`) nor narrowing is performed, so a
mismatch raises `PgError(PgErrorKind.TYPE_MISMATCH, ...)` before any
conversion is attempted. `String` is the single exception; it accepts any
OID and returns the text unchanged.

One-dimensional arrays decode into `List[T]` and `List[Optional[T]]` for
the same element types, against the 21 `OID_*_ARRAY` constants
(`pg_type.typarray`). `parse_array_literal` splits the literal and
`decode_text[T]` then decodes each element, so an array element accepts
exactly what the same value would in a scalar column. A column read as
`String` still returns the literal unchanged.

Every `TYPE_MISMATCH` message names the requested PostgreSQL type and
quotes the offending input text.
"""

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

comptime OID_DATE = UInt32(1082)
"""OID of `date`."""

comptime OID_TIME = UInt32(1083)
"""OID of `time` (without time zone)."""

comptime OID_TIMESTAMP = UInt32(1114)
"""OID of `timestamp` (without time zone)."""

comptime OID_TIMESTAMPTZ = UInt32(1184)
"""OID of `timestamptz` (`timestamp with time zone`)."""

comptime OID_INTERVAL = UInt32(1186)
"""OID of `interval`."""

comptime OID_TIMETZ = UInt32(1266)
"""OID of `timetz` (`time with time zone`)."""

comptime OID_NUMERIC = UInt32(1700)
"""OID of `numeric` (`decimal`)."""

comptime OID_UUID = UInt32(2950)
"""OID of `uuid`."""

comptime OID_JSONB = UInt32(3802)
"""OID of `jsonb`."""

comptime OID_BOOL_ARRAY = UInt32(1000)
"""OID of `bool[]` (`pg_type.typarray` of `bool`)."""

comptime OID_BYTEA_ARRAY = UInt32(1001)
"""OID of `bytea[]`."""

comptime OID_NAME_ARRAY = UInt32(1003)
"""OID of `name[]`."""

comptime OID_INT8_ARRAY = UInt32(1016)
"""OID of `int8[]` (`bigint[]`)."""

comptime OID_INT2_ARRAY = UInt32(1005)
"""OID of `int2[]` (`smallint[]`)."""

comptime OID_INT4_ARRAY = UInt32(1007)
"""OID of `int4[]` (`integer[]`)."""

comptime OID_TEXT_ARRAY = UInt32(1009)
"""OID of `text[]`."""

comptime OID_JSON_ARRAY = UInt32(199)
"""OID of `json[]`."""

comptime OID_FLOAT4_ARRAY = UInt32(1021)
"""OID of `float4[]` (`real[]`)."""

comptime OID_FLOAT8_ARRAY = UInt32(1022)
"""OID of `float8[]` (`double precision[]`)."""

comptime OID_BPCHAR_ARRAY = UInt32(1014)
"""OID of `bpchar[]` (`character(n)[]`)."""

comptime OID_VARCHAR_ARRAY = UInt32(1015)
"""OID of `varchar[]` (`character varying[]`)."""

comptime OID_DATE_ARRAY = UInt32(1182)
"""OID of `date[]`."""

comptime OID_TIME_ARRAY = UInt32(1183)
"""OID of `time[]` (without time zone)."""

comptime OID_TIMESTAMP_ARRAY = UInt32(1115)
"""OID of `timestamp[]` (without time zone)."""

comptime OID_TIMESTAMPTZ_ARRAY = UInt32(1185)
"""OID of `timestamptz[]` (`timestamp with time zone[]`)."""

comptime OID_INTERVAL_ARRAY = UInt32(1187)
"""OID of `interval[]`."""

comptime OID_TIMETZ_ARRAY = UInt32(1270)
"""OID of `timetz[]` (`time with time zone[]`)."""

comptime OID_NUMERIC_ARRAY = UInt32(1231)
"""OID of `numeric[]` (`decimal[]`)."""

comptime OID_UUID_ARRAY = UInt32(2951)
"""OID of `uuid[]`."""

comptime OID_JSONB_ARRAY = UInt32(3807)
"""OID of `jsonb[]`."""

comptime _INT2_MIN = -32768
comptime _INT2_MAX = 32767
comptime _INT4_MIN = -2147483648
comptime _INT4_MAX = 2147483647

comptime _BACKSLASH = UInt8(ord("\\"))
comptime _LOWER_X = UInt8(ord("x"))
comptime _LBRACE = UInt8(ord("{"))
comptime _RBRACE = UInt8(ord("}"))
comptime _LBRACKET = UInt8(ord("["))
comptime _EQUALS = UInt8(ord("="))
comptime _COMMA = UInt8(ord(","))
comptime _DQUOTE = UInt8(ord('"'))

comptime _MULTIDIM = "multidimensional arrays are not supported"
comptime _UNEXPECTED_END = "unexpected end of input"


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


def _array_oid_error(
    oid: UInt32, expect_oid: UInt32, type_name: StaticString, text: String
) -> PgError:
    """Build the `TYPE_MISMATCH` error for an array column of the wrong OID.

    Unlike `_oid_error` the message carries both OIDs: the array OIDs are
    far enough from the element OIDs (`int4` 23 vs `int4[]` 1007) that
    naming only the column's own OID leaves the reader guessing what was
    expected.
    """
    return PgError(
        PgErrorKind.TYPE_MISMATCH,
        String(
            "column is oid ",
            oid,
            " but ",
            type_name,
            " (oid ",
            expect_oid,
            ') was requested (text: "',
            text,
            '")',
        ),
    )


def _array_literal_error(text: String, reason: String) -> PgError:
    """Build the `TYPE_MISMATCH` error for text that is not an array literal."""
    return PgError(
        PgErrorKind.TYPE_MISMATCH,
        String('cannot decode "', text, '" as an array literal: ', reason),
    )


def _array_elem_oid(array_oid: UInt32) -> UInt32:
    """Return the element OID of `array_oid`, or 0 when it is not an array."""
    if array_oid == OID_BOOL_ARRAY:
        return OID_BOOL
    if array_oid == OID_BYTEA_ARRAY:
        return OID_BYTEA
    if array_oid == OID_NAME_ARRAY:
        return OID_NAME
    if array_oid == OID_INT8_ARRAY:
        return OID_INT8
    if array_oid == OID_INT2_ARRAY:
        return OID_INT2
    if array_oid == OID_INT4_ARRAY:
        return OID_INT4
    if array_oid == OID_TEXT_ARRAY:
        return OID_TEXT
    if array_oid == OID_JSON_ARRAY:
        return OID_JSON
    if array_oid == OID_FLOAT4_ARRAY:
        return OID_FLOAT4
    if array_oid == OID_FLOAT8_ARRAY:
        return OID_FLOAT8
    if array_oid == OID_BPCHAR_ARRAY:
        return OID_BPCHAR
    if array_oid == OID_VARCHAR_ARRAY:
        return OID_VARCHAR
    if array_oid == OID_DATE_ARRAY:
        return OID_DATE
    if array_oid == OID_TIME_ARRAY:
        return OID_TIME
    if array_oid == OID_TIMESTAMP_ARRAY:
        return OID_TIMESTAMP
    if array_oid == OID_TIMESTAMPTZ_ARRAY:
        return OID_TIMESTAMPTZ
    if array_oid == OID_INTERVAL_ARRAY:
        return OID_INTERVAL
    if array_oid == OID_TIMETZ_ARRAY:
        return OID_TIMETZ
    if array_oid == OID_NUMERIC_ARRAY:
        return OID_NUMERIC
    if array_oid == OID_UUID_ARRAY:
        return OID_UUID
    if array_oid == OID_JSONB_ARRAY:
        return OID_JSONB
    return UInt32(0)


def _array_oid_of(elem_oid: UInt32) -> UInt32:
    """Return the array OID of `elem_oid`, or 0 when there is none here."""
    if elem_oid == OID_BOOL:
        return OID_BOOL_ARRAY
    if elem_oid == OID_BYTEA:
        return OID_BYTEA_ARRAY
    if elem_oid == OID_NAME:
        return OID_NAME_ARRAY
    if elem_oid == OID_INT8:
        return OID_INT8_ARRAY
    if elem_oid == OID_INT2:
        return OID_INT2_ARRAY
    if elem_oid == OID_INT4:
        return OID_INT4_ARRAY
    if elem_oid == OID_TEXT:
        return OID_TEXT_ARRAY
    if elem_oid == OID_JSON:
        return OID_JSON_ARRAY
    if elem_oid == OID_FLOAT4:
        return OID_FLOAT4_ARRAY
    if elem_oid == OID_FLOAT8:
        return OID_FLOAT8_ARRAY
    if elem_oid == OID_BPCHAR:
        return OID_BPCHAR_ARRAY
    if elem_oid == OID_VARCHAR:
        return OID_VARCHAR_ARRAY
    if elem_oid == OID_DATE:
        return OID_DATE_ARRAY
    if elem_oid == OID_TIME:
        return OID_TIME_ARRAY
    if elem_oid == OID_TIMESTAMP:
        return OID_TIMESTAMP_ARRAY
    if elem_oid == OID_TIMESTAMPTZ:
        return OID_TIMESTAMPTZ_ARRAY
    if elem_oid == OID_INTERVAL:
        return OID_INTERVAL_ARRAY
    if elem_oid == OID_TIMETZ:
        return OID_TIMETZ_ARRAY
    if elem_oid == OID_NUMERIC:
        return OID_NUMERIC_ARRAY
    if elem_oid == OID_UUID:
        return OID_UUID_ARRAY
    if elem_oid == OID_JSONB:
        return OID_JSONB_ARRAY
    return UInt32(0)


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


def _is_array_space(byte: UInt8) -> Bool:
    """Tell whether `byte` is whitespace `array_in` would skip."""
    return (
        byte == UInt8(ord(" "))
        or byte == UInt8(ord("\t"))
        or byte == UInt8(ord("\n"))
        or byte == UInt8(ord("\r"))
        or byte == UInt8(11)
        or byte == UInt8(12)
    )


def _is_null_word(text: String) -> Bool:
    """Tell whether `text` is the word `NULL` in any case variant."""
    var bytes = text.as_bytes()
    if len(bytes) != 4:
        return False
    return (
        (bytes[0] | 0x20) == UInt8(ord("n"))
        and (bytes[1] | 0x20) == UInt8(ord("u"))
        and (bytes[2] | 0x20) == UInt8(ord("l"))
        and (bytes[3] | 0x20) == UInt8(ord("l"))
    )


def parse_array_literal(text: String) raises PgError -> List[Optional[String]]:
    """Split a one-dimensional array literal into its element texts.

    Implements the output format PostgreSQL documents in §8.15.6, which is
    the only form `PQgetvalue` ever hands back for an array column:

    - An optional dimension prefix (`[0:1]=`) is dropped up to its `=`;
      the lower bounds it carries are not represented in `List`, and
      dropping them loses no element.
    - A quoted element (`"..."`) ends at its unescaped `"`; inside it, a
      backslash is dropped and the byte after it taken literally, so
      `"d\\"e"` is `d"e` and a `bytea`'s `"\\\\x00ff"` becomes `\\x00ff`,
      exactly what `parse_bytea_hex` wants.
    - An unquoted element is trimmed of the whitespace around it, and is
      SQL NULL when it reads `NULL` in any case variant. A quote or a
      backslash anywhere in the element disables that reading, so the
      quoted `"NULL"` is the four-character string.
    - `{}` is the empty array.

    Whitespace is allowed before the braces and around every element.
    Anything else -- a nested `{` (a multidimensional array), a missing
    brace or quote, an empty element, or trailing junk -- raises rather
    than returning a partial list.

    Args:
        text: The text-format array value as libpq returned it.

    Returns:
        One entry per element, in order; `None` for a SQL NULL element.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `text` is not a
            one-dimensional array literal. The message quotes `text` and
            names the reason.
    """
    var bytes = text.as_bytes()
    var size = len(bytes)
    var i = 0
    while i < size and _is_array_space(bytes[i]):
        i += 1
    if i < size and bytes[i] == _LBRACKET:
        while i < size and bytes[i] != _EQUALS:
            i += 1
        if i == size:
            raise _array_literal_error(text, "dimension prefix has no '='")
        i += 1
        while i < size and _is_array_space(bytes[i]):
            i += 1
    if i == size or bytes[i] != _LBRACE:
        raise _array_literal_error(text, "expected '{'")
    i += 1
    while i < size and _is_array_space(bytes[i]):
        i += 1
    var out = List[Optional[String]]()
    if i < size and bytes[i] == _RBRACE:
        i += 1
    else:
        while True:
            if i == size:
                raise _array_literal_error(text, _UNEXPECTED_END)
            var elem: Optional[String]
            if bytes[i] == _DQUOTE:
                i += 1
                var buf = List[UInt8]()
                var closed = False
                while i < size:
                    if bytes[i] == _BACKSLASH:
                        if i + 1 == size:
                            break
                        buf.append(bytes[i + 1])
                        i += 2
                        continue
                    if bytes[i] == _DQUOTE:
                        i += 1
                        closed = True
                        break
                    buf.append(bytes[i])
                    i += 1
                if not closed:
                    raise _array_literal_error(
                        text, "unterminated double quote"
                    )
                elem = String(StringSlice(unsafe_from_utf8=Span(buf)))
            else:
                if bytes[i] == _LBRACE:
                    raise _array_literal_error(text, _MULTIDIM)
                if bytes[i] == _COMMA or bytes[i] == _RBRACE:
                    raise _array_literal_error(text, "empty element")
                var buf = List[UInt8]()
                var escaped = False
                while i < size:
                    if bytes[i] == _BACKSLASH:
                        if i + 1 == size:
                            break
                        buf.append(bytes[i + 1])
                        escaped = True
                        i += 2
                        continue
                    if bytes[i] == _COMMA or bytes[i] == _RBRACE:
                        break
                    if bytes[i] == _LBRACE:
                        raise _array_literal_error(text, _MULTIDIM)
                    if bytes[i] == _DQUOTE:
                        raise _array_literal_error(
                            text, "double quote inside an unquoted element"
                        )
                    buf.append(bytes[i])
                    i += 1
                if i == size:
                    raise _array_literal_error(text, _UNEXPECTED_END)
                while len(buf) > 0 and _is_array_space(buf[len(buf) - 1]):
                    _ = buf.pop()
                var raw = String(StringSlice(unsafe_from_utf8=Span(buf)))
                if not escaped and _is_null_word(raw):
                    elem = None
                else:
                    elem = raw^
            out.append(elem^)
            while i < size and _is_array_space(bytes[i]):
                i += 1
            if i == size:
                raise _array_literal_error(text, _UNEXPECTED_END)
            if bytes[i] == _COMMA:
                i += 1
                while i < size and _is_array_space(bytes[i]):
                    i += 1
                continue
            if bytes[i] == _RBRACE:
                i += 1
                break
            raise _array_literal_error(text, "expected ',' or '}'")
    while i < size and _is_array_space(bytes[i]):
        i += 1
    if i != size:
        raise _array_literal_error(text, "junk after the closing '}'")
    return out^


def _decode_text_array[
    E: Copyable & Deinitable
](
    text: String,
    oid: UInt32,
    expect_oid: UInt32,
    elem_oid: UInt32,
    type_name: StaticString,
) raises PgError -> List[Optional[E]]:
    """Decode a text-format array column into one `Optional[E]` per element.

    The column OID must be `expect_oid` exactly -- the array OIDs stand
    in the same strict relation to `E` that the element OIDs do in
    `decode_text` -- and every element goes through `decode_text[E]` with
    `elem_oid`, so an element behaves exactly as the same value would in a
    scalar column. A failing element is reported with its index, since the
    element's own message cannot say where in the array it sat.
    """
    if oid != expect_oid:
        raise _array_oid_error(oid, expect_oid, type_name, text)
    var raw = parse_array_literal(text)
    var out = List[Optional[E]](capacity=len(raw))
    for i in range(len(raw)):
        if not raw[i]:
            out.append(None)
            continue
        var value: E
        try:
            value = decode_text[E](raw[i].value(), elem_oid)
        except e:
            raise PgError(e.kind, String("array element ", i, ": ", e.message))
        out.append(value^)
    return out^


def _decode_text_string_array(
    text: String, oid: UInt32
) raises PgError -> List[Optional[String]]:
    """Decode any of the six text-like array columns into `String` elements.

    `List[String]` accepts `text[]`, `varchar[]`, `bpchar[]`, `name[]`,
    `json[]` and `jsonb[]`, the array OIDs of the six element types the
    scalar `String` branch accepts. Elements are handed their own element
    OID, which the scalar branch ignores.
    """
    if (
        oid != OID_TEXT_ARRAY
        and oid != OID_VARCHAR_ARRAY
        and oid != OID_BPCHAR_ARRAY
        and oid != OID_NAME_ARRAY
        and oid != OID_JSON_ARRAY
        and oid != OID_JSONB_ARRAY
    ):
        raise _array_oid_error(oid, OID_TEXT_ARRAY, "text[]", text)
    return _decode_text_array[String](
        text, oid, oid, _array_elem_oid(oid), "text[]"
    )


def _require_no_nulls[
    E: Copyable & Deinitable
](var elems: List[Optional[E]]) raises PgError -> List[E]:
    """Strip the `Optional` from every element, rejecting a SQL NULL.

    `get[List[T]]` promises a `T` per element, so a NULL element is a
    `NULL_VALUE` naming its index -- the same split `get` and
    `get_optional` make for a NULL column, one axis down.
    """
    var out = List[E](capacity=len(elems))
    for i in range(len(elems)):
        if not elems[i]:
            raise PgError(
                PgErrorKind.NULL_VALUE, String("array element ", i, " is NULL")
            )
        out.append(elems[i].value().copy())
    return out^


def decode_text[T: Copyable](text: String, oid: UInt32) raises PgError -> T:
    """Decode one text-format PostgreSQL value into `T`.

    The column OID must match `T` exactly; no widening or narrowing
    conversion is performed. `Bool` requires oid 16, `Int16` oid 21,
    `Int32` oid 23, `Int64` and `Int` oid 20, `Float32` oid 700,
    `Float64` oid 701, `List[UInt8]` oid 17, `Decimal` oid 1700
    (`numeric`), `UUID` oid 2950, `Date` oid 1082, `Timestamp` oid 1114,
    `TimestampTz` oid 1184, `Time` oid 1083, `TimeTz` oid 1266 and
    `Interval` oid 1186. `String` accepts any OID and never fails.
    Any other `T` is a compile-time error.

    `List[E]` and `List[Optional[E]]`, for every `E` above, decode a
    one-dimensional array column whose OID is the array OID of `E`
    (`List[Int32]` oid 1007, `List[String]` any of 1009, 1015, 1014,
    1003, 199 and 3807). A `NULL` element is `None` in
    `List[Optional[E]]` and a `PgErrorKind.NULL_VALUE` in `List[E]`; a
    multidimensional literal is a `TYPE_MISMATCH`. `List[UInt8]` keeps
    its scalar meaning of `bytea`, so `bytea[]` is `List[List[UInt8]]`.

    The three date and timestamp parsers accept only the `ISO, YMD`
    `DateStyle` and `Interval.parse` only the `postgres` `IntervalStyle`,
    which `Connection.open` pins on every connection; a session that
    changes either GUC afterwards makes the text form of those columns a
    `TYPE_MISMATCH` here, and the binary format stays unaffected.

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
    elif T == List[Bool]:
        var value = _require_no_nulls(
            _decode_text_array[Bool](
                text, oid, OID_BOOL_ARRAY, OID_BOOL, "bool[]"
            )
        )
        return rebind[T](value).copy()
    elif T == List[Optional[Bool]]:
        var value = _decode_text_array[Bool](
            text, oid, OID_BOOL_ARRAY, OID_BOOL, "bool[]"
        )
        return rebind[T](value).copy()
    elif T == List[Int16]:
        var value = _require_no_nulls(
            _decode_text_array[Int16](
                text, oid, OID_INT2_ARRAY, OID_INT2, "int2[]"
            )
        )
        return rebind[T](value).copy()
    elif T == List[Optional[Int16]]:
        var value = _decode_text_array[Int16](
            text, oid, OID_INT2_ARRAY, OID_INT2, "int2[]"
        )
        return rebind[T](value).copy()
    elif T == List[Int32]:
        var value = _require_no_nulls(
            _decode_text_array[Int32](
                text, oid, OID_INT4_ARRAY, OID_INT4, "int4[]"
            )
        )
        return rebind[T](value).copy()
    elif T == List[Optional[Int32]]:
        var value = _decode_text_array[Int32](
            text, oid, OID_INT4_ARRAY, OID_INT4, "int4[]"
        )
        return rebind[T](value).copy()
    elif T == List[Int64]:
        var value = _require_no_nulls(
            _decode_text_array[Int64](
                text, oid, OID_INT8_ARRAY, OID_INT8, "int8[]"
            )
        )
        return rebind[T](value).copy()
    elif T == List[Optional[Int64]]:
        var value = _decode_text_array[Int64](
            text, oid, OID_INT8_ARRAY, OID_INT8, "int8[]"
        )
        return rebind[T](value).copy()
    elif T == List[Int]:
        var value = _require_no_nulls(
            _decode_text_array[Int](
                text, oid, OID_INT8_ARRAY, OID_INT8, "int8[]"
            )
        )
        return rebind[T](value).copy()
    elif T == List[Optional[Int]]:
        var value = _decode_text_array[Int](
            text, oid, OID_INT8_ARRAY, OID_INT8, "int8[]"
        )
        return rebind[T](value).copy()
    elif T == List[Float32]:
        var value = _require_no_nulls(
            _decode_text_array[Float32](
                text, oid, OID_FLOAT4_ARRAY, OID_FLOAT4, "float4[]"
            )
        )
        return rebind[T](value).copy()
    elif T == List[Optional[Float32]]:
        var value = _decode_text_array[Float32](
            text, oid, OID_FLOAT4_ARRAY, OID_FLOAT4, "float4[]"
        )
        return rebind[T](value).copy()
    elif T == List[Float64]:
        var value = _require_no_nulls(
            _decode_text_array[Float64](
                text, oid, OID_FLOAT8_ARRAY, OID_FLOAT8, "float8[]"
            )
        )
        return rebind[T](value).copy()
    elif T == List[Optional[Float64]]:
        var value = _decode_text_array[Float64](
            text, oid, OID_FLOAT8_ARRAY, OID_FLOAT8, "float8[]"
        )
        return rebind[T](value).copy()
    elif T == List[String]:
        var value = _require_no_nulls(_decode_text_string_array(text, oid))
        return rebind[T](value).copy()
    elif T == List[Optional[String]]:
        var value = _decode_text_string_array(text, oid)
        return rebind[T](value).copy()
    elif T == List[List[UInt8]]:
        var value = _require_no_nulls(
            _decode_text_array[List[UInt8]](
                text, oid, OID_BYTEA_ARRAY, OID_BYTEA, "bytea[]"
            )
        )
        return rebind[T](value).copy()
    elif T == List[Optional[List[UInt8]]]:
        var value = _decode_text_array[List[UInt8]](
            text, oid, OID_BYTEA_ARRAY, OID_BYTEA, "bytea[]"
        )
        return rebind[T](value).copy()
    elif T == List[Decimal]:
        var value = _require_no_nulls(
            _decode_text_array[Decimal](
                text, oid, OID_NUMERIC_ARRAY, OID_NUMERIC, "numeric[]"
            )
        )
        return rebind[T](value).copy()
    elif T == List[Optional[Decimal]]:
        var value = _decode_text_array[Decimal](
            text, oid, OID_NUMERIC_ARRAY, OID_NUMERIC, "numeric[]"
        )
        return rebind[T](value).copy()
    elif T == List[UUID]:
        var value = _require_no_nulls(
            _decode_text_array[UUID](
                text, oid, OID_UUID_ARRAY, OID_UUID, "uuid[]"
            )
        )
        return rebind[T](value).copy()
    elif T == List[Optional[UUID]]:
        var value = _decode_text_array[UUID](
            text, oid, OID_UUID_ARRAY, OID_UUID, "uuid[]"
        )
        return rebind[T](value).copy()
    elif T == List[Date]:
        var value = _require_no_nulls(
            _decode_text_array[Date](
                text, oid, OID_DATE_ARRAY, OID_DATE, "date[]"
            )
        )
        return rebind[T](value).copy()
    elif T == List[Optional[Date]]:
        var value = _decode_text_array[Date](
            text, oid, OID_DATE_ARRAY, OID_DATE, "date[]"
        )
        return rebind[T](value).copy()
    elif T == List[Timestamp]:
        var value = _require_no_nulls(
            _decode_text_array[Timestamp](
                text, oid, OID_TIMESTAMP_ARRAY, OID_TIMESTAMP, "timestamp[]"
            )
        )
        return rebind[T](value).copy()
    elif T == List[Optional[Timestamp]]:
        var value = _decode_text_array[Timestamp](
            text, oid, OID_TIMESTAMP_ARRAY, OID_TIMESTAMP, "timestamp[]"
        )
        return rebind[T](value).copy()
    elif T == List[TimestampTz]:
        var value = _require_no_nulls(
            _decode_text_array[TimestampTz](
                text,
                oid,
                OID_TIMESTAMPTZ_ARRAY,
                OID_TIMESTAMPTZ,
                "timestamptz[]",
            )
        )
        return rebind[T](value).copy()
    elif T == List[Optional[TimestampTz]]:
        var value = _decode_text_array[TimestampTz](
            text, oid, OID_TIMESTAMPTZ_ARRAY, OID_TIMESTAMPTZ, "timestamptz[]"
        )
        return rebind[T](value).copy()
    elif T == List[Time]:
        var value = _require_no_nulls(
            _decode_text_array[Time](
                text, oid, OID_TIME_ARRAY, OID_TIME, "time[]"
            )
        )
        return rebind[T](value).copy()
    elif T == List[Optional[Time]]:
        var value = _decode_text_array[Time](
            text, oid, OID_TIME_ARRAY, OID_TIME, "time[]"
        )
        return rebind[T](value).copy()
    elif T == List[TimeTz]:
        var value = _require_no_nulls(
            _decode_text_array[TimeTz](
                text, oid, OID_TIMETZ_ARRAY, OID_TIMETZ, "timetz[]"
            )
        )
        return rebind[T](value).copy()
    elif T == List[Optional[TimeTz]]:
        var value = _decode_text_array[TimeTz](
            text, oid, OID_TIMETZ_ARRAY, OID_TIMETZ, "timetz[]"
        )
        return rebind[T](value).copy()
    elif T == List[Interval]:
        var value = _require_no_nulls(
            _decode_text_array[Interval](
                text, oid, OID_INTERVAL_ARRAY, OID_INTERVAL, "interval[]"
            )
        )
        return rebind[T](value).copy()
    elif T == List[Optional[Interval]]:
        var value = _decode_text_array[Interval](
            text, oid, OID_INTERVAL_ARRAY, OID_INTERVAL, "interval[]"
        )
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
    elif T == Date:
        if oid != OID_DATE:
            raise _oid_error(oid, "date", text)
        var value = Date.parse(text)
        return rebind[T](value).copy()
    elif T == Timestamp:
        if oid != OID_TIMESTAMP:
            raise _oid_error(oid, "timestamp", text)
        var value = Timestamp.parse(text)
        return rebind[T](value).copy()
    elif T == TimestampTz:
        if oid != OID_TIMESTAMPTZ:
            raise _oid_error(oid, "timestamptz", text)
        var value = TimestampTz.parse(text)
        return rebind[T](value).copy()
    elif T == Time:
        if oid != OID_TIME:
            raise _oid_error(oid, "time", text)
        var value = Time.parse(text)
        return rebind[T](value).copy()
    elif T == TimeTz:
        if oid != OID_TIMETZ:
            raise _oid_error(oid, "timetz", text)
        var value = TimeTz.parse(text)
        return rebind[T](value).copy()
    elif T == Interval:
        if oid != OID_INTERVAL:
            raise _oid_error(oid, "interval", text)
        var value = Interval.parse(text)
        return rebind[T](value).copy()
    else:
        comptime assert False, "unsupported type for Row.get"
