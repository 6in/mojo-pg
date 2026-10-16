"""PostgreSQL client for Mojo built on libpq via C FFI.

Layout follows HANDOFF.md §4. Phase 1 adds `_ffi`, `connection`, `result`.
Phase 2 adds `params`, `prepared`, `transaction`.

Everything needed to open a connection, run a statement and read the rows
back is re-exported here, so `from pq import Connection, PgError` is enough:
`Connection`, `Result`, `Row`, `PgError`, `PgErrorKind`, `Param` for
`execute(sql, params)`, `PreparedStatement`, `Transaction`, the
`CONNECTION_OK` / `CONNECTION_BAD` status constants and the five `PQTRANS_*`
transaction status constants.

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

## Parameters

`Connection.execute(sql, params)` and `PreparedStatement.execute(params)`
bind values to the `$1`..`$n` placeholders instead of pasting them into the
SQL, so nothing a caller passes can change the statement. `Param` converts
implicitly from every supported Mojo type, which makes a plain list literal
enough: `conn.execute(sql, [1, "a", Param.null()])`.

Each value is encoded when the `Param` is built, and that fixes both the
wire format and the OID sent in `paramTypes`:

| Mojo type | wire format | OID | notes |
|---|---|---|---|
| `Bool` | binary, 1 byte | 16 | |
| `Int16` | binary, 2 byte BE | 21 | |
| `Int32` | binary, 4 byte BE | 23 | |
| `Int64` / `Int` | binary, 8 byte BE | 20 | `Int` is `int8` |
| `Float32` | IEEE 754, 4 byte BE | 700 | `NaN` / `±Inf` as-is |
| `Float64` | IEEE 754, 8 byte BE | 701 | same |
| `String`, `StringLiteral` | text, NUL-terminated | 0 | server infers |
| `List[UInt8]` | binary, with length | 17 | empty / NUL-containing ok |
| NULL | NULL | 0, or the given OID | see below |

A SQL NULL is `Param.null()` when the statement determines the type, and
`Param.null(oid)` when it cannot -- `SELECT $1::int4` wants `null(23)`.
`Optional[T]` of any row of the table converts implicitly as well, but a
bare `None` literal does not, so write the type out:
`Optional[Int](None)`, or `var x: Optional[Int] = None` and pass `x`.

`PreparedStatement.execute(params)` is stricter about width than
`Connection.execute(sql, params)`: the types were fixed when the server
prepared the statement, so a value has to be the **same width** that
`param_type_oid(i)` reports -- `$1::int4` wants `Int32`, and passing `Int`
(`int8`) is SQLSTATE `22P03`.

## Transactions

`Connection.transaction()` issues `BEGIN` and returns a
`Transaction[origin]`; `Connection.prepare(sql)` returns a
`PreparedStatement[origin]`. Both borrow the connection, and Mojo destroys
them right after the **last line that uses them** -- not at the end of the
enclosing scope -- which is where the implicit `ROLLBACK` or the
`DEALLOCATE` is sent. So put the last use last: end the block with
`commit()` or `rollback()`, or write `_ = tx^` / `_ = stmt^`, and only
*after* that line inspect the outcome with `conn.execute`. `_ = x^` is a
"keep it alive until here" marker, not an eager free.

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

The two embedded-NUL cases are deliberately **not** the same kind: a NUL
byte in the `sql` text is `TYPE_MISMATCH`, like every other argument libpq
cannot be handed at all, while a NUL byte in the value of a `String`
parameter is `USAGE` -- the statement is fine and only the data offered
with it is not.
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
from .params import Param
from .prepared import PreparedStatement
from .result import Result, Row
from .transaction import Transaction
