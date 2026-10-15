"""PostgreSQL client for Mojo built on libpq via C FFI.

Layout follows HANDOFF.md §4. Phase 1 adds `_ffi`, `connection`, `result`.

Everything needed to open a connection, run a statement and read the rows
back is re-exported here, so `from pq import Connection, PgError` is enough:
`Connection`, `Result`, `Row`, `PgError`, `PgErrorKind`, the `CONNECTION_OK`
/ `CONNECTION_BAD` status constants and the five `PQTRANS_*` transaction
status constants.

## Type mapping

`Row.get[T]` and `Row.get_optional[T]` decode a column's text form into `T`.
The column OID must match `T` exactly: **there is no widening**, so reading
an `int2` column as `Int32` is a `TYPE_MISMATCH`, and so is reading an `int4`
column as `Int64`. `String` is the single exception -- it accepts any OID and
returns the text unchanged.

| PostgreSQL | OID | Mojo type | text form |
|---|---|---|---|
| bool | 16 | `Bool` | `t` / `f` |
| int2 | 21 | `Int16` | decimal |
| int4 | 23 | `Int32` | decimal |
| int8 | 20 | `Int64` (also readable as `Int`) | decimal |
| float4 | 700 | `Float32` | decimal, `NaN` / `Infinity` / `-Infinity` |
| float8 | 701 | `Float64` | same |
| text, varchar, bpchar, name | 25, 1043, 1042, 19 | `String` | as-is |
| bytea | 17 | `List[UInt8]` | `\\x` hex form only |
| anything else | -- | only obtainable as `String` | as-is |

`pq.decode_text.decode_text` implements the table and is the one place to
change when a type is added.

## `PgErrorKind`

Every `pq` API raises `PgError`, and its `kind` is one of exactly six
values. The name in parentheses is what `PgErrorKind.write_to` prints:

- `LIBPQ_LOAD` (`LibpqLoad`) -- libpq itself could not be loaded.
- `CONNECTION` (`Connection`) -- connecting failed, or the connection is no
  longer usable.
- `SERVER` (`Server`) -- the server rejected a statement and reported a
  diagnostic.
- `NULL_VALUE` (`NullValue`) -- a non-optional value was requested from a
  SQL NULL.
- `TYPE_MISMATCH` (`TypeMismatch`) -- the requested shape does not match the
  result (type, index or name).
- `USAGE` (`Usage`) -- the caller misused the `pq` API. Detected
  client-side; nothing was sent to the server, so `sqlstate` and the other
  diagnostics are empty.
"""

from ._ffi.types import (
    CONNECTION_BAD,
    CONNECTION_OK,
    PQTRANS_ACTIVE,
    PQTRANS_IDLE,
    PQTRANS_INERROR,
    PQTRANS_INTRANS,
    PQTRANS_UNKNOWN,
)
from .connection import Connection
from .errors import PgError, PgErrorKind
from .result import Result, Row
