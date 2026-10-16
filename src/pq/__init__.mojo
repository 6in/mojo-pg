"""PostgreSQL client for Mojo built on libpq via C FFI.

Layout follows HANDOFF.md §4. Phase 1 adds `_ffi`, `connection`, `result`.
Phase 2 adds `params`, `prepared`, `transaction`. Phase 3 adds
`decode_binary` and the `types_*` modules holding the value types for
PostgreSQL types Mojo has no built-in for.

Everything needed to open a connection, run a statement and read the rows
back is re-exported here, so `from pq import Connection, PgError` is enough:
`Connection`, `Result`, `Row`, `ResultFormat` for the `result_format`
argument, `PgError`, `PgErrorKind`, `Param` for `execute(sql, params)`,
`PreparedStatement`, `Transaction`, the `Decimal`, `UUID`, `Date`,
`Timestamp`, `TimestampTz`, `Time`, `TimeTz` and `Interval` value types
for the PostgreSQL types that
have no Mojo equivalent, the `CONNECTION_OK`
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
| numeric | 1700 | `Decimal` | position notation, `NaN` / `±Infinity` |
| uuid | 2950 | `UUID` | lowercase `8-4-4-4-12` |
| date | 1082 | `Date` | `YYYY-MM-DD`, ` BC` suffix, `±infinity` |
| timestamp | 1114 | `Timestamp` | `YYYY-MM-DD HH:MM:SS[.f]`, same |
| timestamptz | 1184 | `TimestampTz` | same plus the UTC offset |
| time | 1083 | `Time` | `HH:MM:SS[.f]`, `24:00:00` included |
| timetz | 1266 | `TimeTz` | same plus `±HH[:MM[:SS]]` |
| interval | 1186 | `Interval` | `IntervalStyle` `postgres` only |
| text, varchar, bpchar, name | 25, 1043, 1042, 19 | `String` | as-is |
| json, jsonb | 114, 3802 | `String` | as-is; jsonb drops its version byte |
| bytea | 17 | `List[UInt8]` | `\\x` hex form only |
| anything else | -- | `String` in the text format only; a binary result raises `TYPE_MISMATCH` | as-is |

`pq.decode_text.decode_text` implements the table and is the one place to
change when a type is added.

## Result format

`Connection.execute(sql, params)`, `PreparedStatement.execute(params)` and
`Transaction.execute(sql, params)` take a `result_format` keyword argument,
`ResultFormat.TEXT` by default. `ResultFormat.BINARY` asks the server for the
binary form instead:

```mojo
var res = conn.execute(
    "SELECT $1::int8", [Int(7)], result_format=ResultFormat.BINARY
)
```

Three things to know about it:

- It applies to the **whole result**, never to a single column: libpq takes
  one `resultFormat` per request, so `BINARY` means every column comes back
  binary. `Result.column_format(i)` reports what actually arrived, and gives
  the same answer for every `i` of a given result.
- Reading the rows back is unchanged. `Row.get[T]` / `Row.get_optional[T]`
  read `PQfformat` and pick the decoder themselves, so the same
  `row.get[Int64](0)` works in either format. The one difference is `String`:
  it is the text format's wildcard and accepts **any** OID, while in binary it
  only accepts the string-like OIDs 25 (text), 1043 (varchar), 1042 (bpchar),
  19 (name), 114 (json) and 3802 (jsonb).
- `Connection.execute(sql)` -- the single-argument overload -- is always
  text, because `PQexec` has no `resultFormat` argument. For a statement that
  binds nothing, `execute(sql, [], result_format=ResultFormat.BINARY)` goes
  through `PQexecParams` with an empty parameter list and does get binary.

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
| `Decimal` | binary, 8 byte header + digits | 1700 | `numeric` |
| `UUID` | binary, 16 byte | 2950 | |
| `Date` | binary, 4 byte BE | 1082 | days from 2000-01-01 |
| `Timestamp` | binary, 8 byte BE | 1114 | µs from 2000-01-01 |
| `TimestampTz` | binary, 8 byte BE | 1184 | same, read as UTC |
| `Time` | binary, 8 byte BE | 1083 | µs into the day |
| `TimeTz` | binary, 8 + 4 byte BE | 1266 | zone is positive west |
| `Interval` | binary, 8 + 4 + 4 byte BE | 1186 | µs, days, months |
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
from .result import Result, ResultFormat, Row
from .transaction import Transaction
from .types_datetime import (
    Date,
    Interval,
    Time,
    TimeTz,
    Timestamp,
    TimestampTz,
)
from .types_numeric import Decimal
from .types_uuid import UUID
