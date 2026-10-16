"""Query parameters and the libpq argument arrays built from them.

`Param` is the single value type accepted by the parameterised execute
APIs. Twenty-nine `@implicit` constructors make a plain list literal --
`[1, "a", 1.5, True, Param.null()]` -- convert to `List[Param]`, so the
caller never names the type. Each constructor **encodes at construction
time**: the Mojo value is turned into its PostgreSQL wire bytes right
there and only those bytes are kept. That keeps `Param` free of a type
tag the executor would have to re-dispatch on, and it means the value's
lifetime ends at the constructor rather than being pinned until the
statement runs.

For the same reason `Param` exposes **no value-reading accessor**. The
only public accessors are `oid`, `is_null` and `is_binary` -- metadata,
never payload. A parameter can hold a password or another credential, so
there is deliberately no way to read it back out of a `Param`, and no
`Writable`/`Stringable` conformance that could put it in a log line.

Two NUL-byte rules meet here and they are **not** symmetric:

* A **text parameter** (`String` / `StringLiteral`) containing a 0 byte
  raises `PgErrorKind.USAGE`. libpq receives text parameters as C
  strings, so the value could only arrive truncated -- but this is the
  caller passing bad *data*, which is a usage error, and the offending
  value is never put in the message.
* The **`sql` text** of a statement containing a 0 byte raises
  `PgErrorKind.TYPE_MISMATCH` (see `pq.errors._reject_nul`), matching the
  rest of the "argument libpq cannot be handed at all" family.

Binary parameters (`List[UInt8]`, and every numeric/`Bool` encoding) may
contain 0 bytes freely: they are passed with an explicit length, so there
is nothing to truncate. SQL NULLs are not inspected at all.

`_ParamBuffers` is the second half of the module. It turns a
`List[Param]` into the five parallel arrays `PQexecParams` /
`PQexecPrepared` want, and its whole job is to **keep those buffers alive
across the libpq call**. libpq only reads the pointers during the call, so
the struct must outlive it and not a moment less -- callers therefore put

    var buffers = _ParamBuffers(params)
    var res = ffi.PQexecParams(..., buffers.values_ptr(), ...)
    _ = buffers^

with the `_ = buffers^` **after** the call, never before. Dropping it
early would free the buffers while libpq still holds their addresses.
"""

from std.ffi import c_int

from pq._ffi.types import CStrArray, IntPtr, OidPtr
from pq.decode_text import (
    OID_BOOL,
    OID_BYTEA,
    OID_DATE,
    OID_FLOAT4,
    OID_FLOAT8,
    OID_INT2,
    OID_INT4,
    OID_INT8,
    OID_NUMERIC,
    OID_TIMESTAMP,
    OID_TIMESTAMPTZ,
    OID_UUID,
)
from pq.encode_binary import (
    encode_bool,
    encode_date,
    encode_float32,
    encode_float64,
    encode_int16,
    encode_int32,
    encode_int64,
    encode_numeric,
    encode_timestamp,
    encode_timestamptz,
    encode_uuid,
)
from pq.errors import PgError, PgErrorKind
from pq.types_datetime import Date, Timestamp, TimestampTz
from pq.types_numeric import Decimal
from pq.types_uuid import UUID


def _text_bytes(s: String) -> List[UInt8]:
    """Copy the UTF-8 bytes of `s` into an owned list, without a NUL.

    Args:
        s: The text to copy.

    Returns:
        The bytes of `s`, with no terminator appended.
    """
    var bytes = s.as_bytes()
    var out = List[UInt8](capacity=len(bytes))
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^


struct Param(Copyable, Movable):
    """One already-encoded query parameter.

    Holds the PostgreSQL type OID, the wire format flag and the encoded
    bytes: big-endian binary for `Bool`, the integers, the floats,
    `Decimal` (`numeric`), `UUID`, `Date`, `Timestamp` and `TimestampTz`,
    raw bytes for `bytea`, and NUL-free text bytes for `String`. A SQL
    NULL carries no bytes at all.

    Construction is implicit from any of the supported Mojo types and
    from `Optional` of each of them, so `List[Param]` accepts a plain
    list literal. There is no accessor returning the encoded value; see
    the module docstring for why.
    """

    var _oid: UInt32
    """PostgreSQL type OID, or 0 to let the server infer the type."""

    var _binary: Bool
    """True when `_data` is the binary wire format, False for text."""

    var _null: Bool
    """True when this parameter is a SQL NULL; `_data` is then empty."""

    var _data: List[UInt8]
    """Encoded bytes: big-endian binary, NUL-free text, or empty."""

    def __init__(
        out self,
        oid: UInt32,
        binary: Bool,
        null: Bool,
        var data: List[UInt8],
    ):
        """Store an already-encoded parameter.

        Args:
            oid: PostgreSQL type OID, or 0 for server-inferred.
            binary: True when `data` is the binary wire format.
            null: True when the parameter is a SQL NULL.
            data: The encoded bytes, empty for a NULL.
        """
        self._oid = oid
        self._binary = binary
        self._null = null
        self._data = data^

    @staticmethod
    def null() -> Param:
        """Build an untyped SQL NULL parameter.

        The OID is 0, so the server infers the type from the statement.

        Returns:
            A NULL parameter of unspecified type.
        """
        return Param(UInt32(0), False, True, List[UInt8]())

    @staticmethod
    def null(oid: UInt32) -> Param:
        """Build a SQL NULL parameter of a known type.

        Args:
            oid: The PostgreSQL type OID to send the NULL as.

        Returns:
            A NULL parameter carrying `oid`.
        """
        return Param(oid, False, True, List[UInt8]())

    @implicit
    def __init__(out self, v: Bool):
        """Encode `v` as a binary `bool` parameter.

        Args:
            v: The value to send.
        """
        self = Param(OID_BOOL, True, False, encode_bool(v))

    @implicit
    def __init__(out self, v: Int16):
        """Encode `v` as a binary `int2` parameter.

        Args:
            v: The value to send.
        """
        self = Param(OID_INT2, True, False, encode_int16(v))

    @implicit
    def __init__(out self, v: Int32):
        """Encode `v` as a binary `int4` parameter.

        Args:
            v: The value to send.
        """
        self = Param(OID_INT4, True, False, encode_int32(v))

    @implicit
    def __init__(out self, v: Int64):
        """Encode `v` as a binary `int8` parameter.

        Args:
            v: The value to send.
        """
        self = Param(OID_INT8, True, False, encode_int64(v))

    @implicit
    def __init__(out self, v: Int):
        """Encode `v` as a binary `int8` parameter.

        `Int` is widened to `Int64`, so the wire width is always 8 bytes.

        Args:
            v: The value to send.
        """
        self = Param(OID_INT8, True, False, encode_int64(Int64(v)))

    @implicit
    def __init__(out self, v: Float32):
        """Encode `v` as a binary `float4` parameter.

        Args:
            v: The value to send.
        """
        self = Param(OID_FLOAT4, True, False, encode_float32(v))

    @implicit
    def __init__(out self, v: Float64):
        """Encode `v` as a binary `float8` parameter.

        Args:
            v: The value to send.
        """
        self = Param(OID_FLOAT8, True, False, encode_float64(v))

    @implicit
    def __init__(out self, var v: String):
        """Send `v` as a text parameter of server-inferred type.

        The OID stays 0 so PostgreSQL resolves the type from the
        statement, which is what makes `"42"` usable for an `int4`
        placeholder. The bytes are stored without a terminator; the NUL
        libpq needs is added by `_ParamBuffers`, which is also where an
        embedded NUL byte is rejected.

        Args:
            v: The text to send.
        """
        self = Param(UInt32(0), False, False, _text_bytes(v))

    @implicit
    def __init__(out self, v: StringLiteral):
        """Send `v` as a text parameter of server-inferred type.

        Behaves exactly like the `String` constructor.

        Args:
            v: The text to send.
        """
        self = Param(UInt32(0), False, False, _text_bytes(String(v)))

    @implicit
    def __init__(out self, v: Decimal):
        """Encode `v` as a binary `numeric` parameter.

        Args:
            v: The value to send.
        """
        self = Param(OID_NUMERIC, True, False, encode_numeric(v))

    @implicit
    def __init__(out self, v: UUID):
        """Encode `v` as a binary `uuid` parameter.

        Args:
            v: The value to send.
        """
        self = Param(OID_UUID, True, False, encode_uuid(v))

    @implicit
    def __init__(out self, v: Date):
        """Encode `v` as a binary `date` parameter.

        Args:
            v: The value to send.
        """
        self = Param(OID_DATE, True, False, encode_date(v))

    @implicit
    def __init__(out self, v: Timestamp):
        """Encode `v` as a binary `timestamp` parameter.

        Args:
            v: The value to send.
        """
        self = Param(OID_TIMESTAMP, True, False, encode_timestamp(v))

    @implicit
    def __init__(out self, v: TimestampTz):
        """Encode `v` as a binary `timestamptz` parameter.

        The value travels as the UTC microsecond count it holds, so the
        server's session `TimeZone` affects only how it prints the result
        back.

        Args:
            v: The value to send.
        """
        self = Param(OID_TIMESTAMPTZ, True, False, encode_timestamptz(v))

    @implicit
    def __init__(out self, var v: List[UInt8]):
        """Send `v` as a binary `bytea` parameter.

        The bytes are taken as they are: an empty list and embedded 0
        bytes are both valid `bytea` values, because binary parameters
        travel with an explicit length.

        Args:
            v: The bytes to send.
        """
        self = Param(OID_BYTEA, True, False, v^)

    @implicit
    def __init__(out self, v: Optional[Bool]):
        """Encode `v` as a binary `bool` parameter, or a typed NULL.

        Args:
            v: The value to send, or None for a SQL NULL of type `bool`.
        """
        if v:
            self = Param(v.value())
        else:
            self = Param.null(OID_BOOL)

    @implicit
    def __init__(out self, v: Optional[Int16]):
        """Encode `v` as a binary `int2` parameter, or a typed NULL.

        Args:
            v: The value to send, or None for a SQL NULL of type `int2`.
        """
        if v:
            self = Param(v.value())
        else:
            self = Param.null(OID_INT2)

    @implicit
    def __init__(out self, v: Optional[Int32]):
        """Encode `v` as a binary `int4` parameter, or a typed NULL.

        Args:
            v: The value to send, or None for a SQL NULL of type `int4`.
        """
        if v:
            self = Param(v.value())
        else:
            self = Param.null(OID_INT4)

    @implicit
    def __init__(out self, v: Optional[Int64]):
        """Encode `v` as a binary `int8` parameter, or a typed NULL.

        Args:
            v: The value to send, or None for a SQL NULL of type `int8`.
        """
        if v:
            self = Param(v.value())
        else:
            self = Param.null(OID_INT8)

    @implicit
    def __init__(out self, v: Optional[Int]):
        """Encode `v` as a binary `int8` parameter, or a typed NULL.

        Args:
            v: The value to send, or None for a SQL NULL of type `int8`.
        """
        if v:
            self = Param(v.value())
        else:
            self = Param.null(OID_INT8)

    @implicit
    def __init__(out self, v: Optional[Float32]):
        """Encode `v` as a binary `float4` parameter, or a typed NULL.

        Args:
            v: The value to send, or None for a SQL NULL of `float4`.
        """
        if v:
            self = Param(v.value())
        else:
            self = Param.null(OID_FLOAT4)

    @implicit
    def __init__(out self, v: Optional[Float64]):
        """Encode `v` as a binary `float8` parameter, or a typed NULL.

        Args:
            v: The value to send, or None for a SQL NULL of `float8`.
        """
        if v:
            self = Param(v.value())
        else:
            self = Param.null(OID_FLOAT8)

    @implicit
    def __init__(out self, var v: Optional[String]):
        """Send `v` as a text parameter, or an untyped NULL.

        Args:
            v: The text to send, or None for an untyped SQL NULL.
        """
        if v:
            self = Param(v.take())
        else:
            self = Param.null()

    @implicit
    def __init__(out self, var v: Optional[List[UInt8]]):
        """Send `v` as a binary `bytea` parameter, or a typed NULL.

        Args:
            v: The bytes to send, or None for a SQL NULL of `bytea`.
        """
        if v:
            self = Param(v.take())
        else:
            self = Param.null(OID_BYTEA)

    @implicit
    def __init__(out self, var v: Optional[Decimal]):
        """Encode `v` as a binary `numeric` parameter, or a typed NULL.

        Args:
            v: The value to send, or None for a SQL NULL of `numeric`.
        """
        if v:
            self = Param(v.take())
        else:
            self = Param.null(OID_NUMERIC)

    @implicit
    def __init__(out self, v: Optional[UUID]):
        """Encode `v` as a binary `uuid` parameter, or a typed NULL.

        Args:
            v: The value to send, or None for a SQL NULL of `uuid`.
        """
        if v:
            self = Param(v.value())
        else:
            self = Param.null(OID_UUID)

    @implicit
    def __init__(out self, v: Optional[Date]):
        """Encode `v` as a binary `date` parameter, or a typed NULL.

        Args:
            v: The value to send, or None for a SQL NULL of `date`.
        """
        if v:
            self = Param(v.value())
        else:
            self = Param.null(OID_DATE)

    @implicit
    def __init__(out self, v: Optional[Timestamp]):
        """Encode `v` as a binary `timestamp` parameter, or a typed NULL.

        Args:
            v: The value to send, or None for a SQL NULL of `timestamp`.
        """
        if v:
            self = Param(v.value())
        else:
            self = Param.null(OID_TIMESTAMP)

    @implicit
    def __init__(out self, v: Optional[TimestampTz]):
        """Encode `v` as a binary `timestamptz` parameter, or a typed NULL.

        Args:
            v: The value to send, or None for a SQL NULL of
                `timestamptz`.
        """
        if v:
            self = Param(v.value())
        else:
            self = Param.null(OID_TIMESTAMPTZ)

    def oid(self) -> UInt32:
        """Return the PostgreSQL type OID this parameter is sent as.

        Returns:
            The type OID, or 0 when the server infers the type.
        """
        return self._oid

    def is_null(self) -> Bool:
        """Report whether this parameter is a SQL NULL.

        Returns:
            True for a SQL NULL.
        """
        return self._null

    def is_binary(self) -> Bool:
        """Report whether this parameter uses the binary wire format.

        Returns:
            True for binary format, False for text. A SQL NULL reports
            False, since it carries no bytes in either format.
        """
        return self._binary


struct _ParamBuffers(Movable):
    """The five parallel libpq arrays for one list of parameters.

    Owns the per-parameter byte buffers and the `types` / `values` /
    `lengths` / `formats` arrays whose addresses are handed to
    `PQexecParams` and `PQexecPrepared`. libpq reads through those
    addresses for the duration of the call only, so this struct must stay
    alive until the call returns -- see the module docstring for the
    `_ = buffers^` placement rule.

    Each array carries one extra dummy element past the real parameters,
    so `unsafe_ptr()` is a valid non-NULL pointer even for an empty
    parameter list. `count` reports the real parameter count and never
    counts the dummy.
    """

    var types: List[UInt32]
    """Per-parameter type OID, plus a trailing dummy `0`."""

    var bufs: List[List[UInt8]]
    """Owned byte buffers: NUL-terminated text, raw binary, or empty."""

    var lengths: List[c_int]
    """Byte length for binary parameters, 0 otherwise, plus a dummy."""

    var formats: List[c_int]
    """1 for binary parameters, 0 otherwise, plus a trailing dummy."""

    var values: List[Int]
    """Address of each buffer, 0 for a SQL NULL, plus a trailing dummy."""

    def __init__(out self, params: List[Param]) raises PgError:
        """Build the libpq arrays for `params`.

        Text parameters are copied with a trailing NUL byte, because
        libpq reads them as C strings; binary parameters are copied as
        they are and travel with their length. SQL NULLs get an empty
        buffer and a 0 address.

        Args:
            params: The already-encoded parameters, in `$1`..`$N` order.

        Raises:
            PgError: `PgErrorKind.USAGE` when a text parameter contains
                an embedded NUL byte, or when any parameter is longer
                than libpq's `paramLengths` can carry (1073741823
                bytes). Both name the one-based position as `$N`; the
                value itself is never put in the message.
        """
        var size = len(params)
        self.types = List[UInt32](capacity=size + 1)
        self.bufs = List[List[UInt8]](capacity=size + 1)
        self.lengths = List[c_int](capacity=size + 1)
        self.formats = List[c_int](capacity=size + 1)
        self.values = List[Int](capacity=size + 1)

        for i in range(size):
            self.types.append(params[i]._oid)
            # libpq's `paramLengths` is a C `int`, so a longer buffer would
            # reach the server with a wrapped -- possibly negative -- length.
            # Refused here instead, for the binary and the text branch alike.
            if len(params[i]._data) > 0x3FFFFFFF:
                raise PgError(
                    PgErrorKind.USAGE,
                    String(
                        "parameter $",
                        i + 1,
                        " is too large (",
                        len(params[i]._data),
                        " bytes; libpq takes at most 1073741823)",
                    ),
                )
            if params[i]._null:
                self.bufs.append(List[UInt8]())
                self.lengths.append(c_int(0))
                self.formats.append(c_int(0))
            elif params[i]._binary:
                self.lengths.append(c_int(len(params[i]._data)))
                self.formats.append(c_int(1))
                # The capacity is one byte past the data so `unsafe_ptr()` is
                # a valid non-NULL address even for an empty `bytea`: libpq
                # reads a NULL `values[i]` as SQL NULL whatever `lengths[i]`
                # says, which would turn `[]` into NULL. The extra byte is
                # never written, so the bytes sent are still `_data` as-is.
                var buf = List[UInt8](capacity=len(params[i]._data) + 1)
                for j in range(len(params[i]._data)):
                    buf.append(params[i]._data[j])
                self.bufs.append(buf^)
            else:
                for j in range(len(params[i]._data)):
                    if params[i]._data[j] == 0:
                        raise PgError(
                            PgErrorKind.USAGE,
                            String("embedded NUL byte in parameter $", i + 1),
                        )
                self.lengths.append(c_int(0))
                self.formats.append(c_int(0))
                var buf = params[i]._data.copy()
                buf.append(0)
                self.bufs.append(buf^)

        self.types.append(UInt32(0))
        self.lengths.append(c_int(0))
        self.formats.append(c_int(0))

        # Addresses are taken only now: appending to `bufs` can move the
        # outer list, which would invalidate an address taken earlier.
        for i in range(size):
            if params[i]._null:
                self.values.append(0)
            else:
                self.values.append(Int(self.bufs[i].unsafe_ptr()))
        self.values.append(0)

    def count(self) -> Int:
        """Return the number of real parameters, excluding the dummies.

        Returns:
            The length of the `params` list this was built from.
        """
        return len(self.types) - 1

    def types_ptr(self) -> OidPtr:
        """Return the address of the type OID array.

        Returns:
            A non-NULL pointer for `PQexecParams`' `paramTypes`.
        """
        return OidPtr(unsafe_from_address=Int(self.types.unsafe_ptr()))

    def values_ptr(self) -> CStrArray:
        """Return the address of the parameter value pointer array.

        Returns:
            A non-NULL pointer for `PQexecParams`' `paramValues`.
        """
        return CStrArray(unsafe_from_address=Int(self.values.unsafe_ptr()))

    def lengths_ptr(self) -> IntPtr:
        """Return the address of the parameter length array.

        Returns:
            A non-NULL pointer for `PQexecParams`' `paramLengths`.
        """
        return IntPtr(unsafe_from_address=Int(self.lengths.unsafe_ptr()))

    def formats_ptr(self) -> IntPtr:
        """Return the address of the parameter format array.

        Returns:
            A non-NULL pointer for `PQexecParams`' `paramFormats`.
        """
        return IntPtr(unsafe_from_address=Int(self.formats.unsafe_ptr()))
