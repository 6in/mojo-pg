"""PostgreSQL client for Mojo built on libpq via C FFI.

Layout follows HANDOFF.md §4. Phase 1 adds `_ffi`, `connection`, `result`.
Phase 2 adds `params`, `prepared`, `transaction`. Phase 3 adds
`decode_binary`, `types_numeric`, `types_datetime` and `types_uuid` -- the
binary decoders and the value types for PostgreSQL types Mojo has no
built-in for. Phase 4 adds `_platform/poll` and `async_conn` -- the
non-blocking connection and the one `poll(2)` call it waits on.

Everything needed to open a connection, run a statement and read the rows
back is re-exported here, so `from pq import Connection, PgError` is enough:
`Connection`, `Result`, `Row`, `ResultFormat` for the `result_format`
argument, `PgError`, `PgErrorKind`, `Param` for `execute(sql, params)`,
`PreparedStatement`, `Transaction`, `AsyncConnection` with its `AsyncState`,
`PollState` and `Notification`, the `Decimal`, `UUID`, `Date`, `Timestamp`,
`TimestampTz`, `Time`, `TimeTz` and `Interval` value types for the
PostgreSQL types that have no Mojo equivalent, the `CONNECTION_OK` /
`CONNECTION_BAD` status constants and the five `PQTRANS_*` transaction
status constants.

## Type mapping

`Row.get[T]` and `Row.get_optional[T]` decode a column into `T`, reading
whichever wire format the column actually arrived in -- see `## Result
format` below. The column OID must match `T` exactly: **there is no
widening**, so reading an `int2` column as `Int32` is a `TYPE_MISMATCH`, and
so is reading an `int4` column as `Int64`.

`String` is the one type whose accepted OIDs depend on the format. In text
it is a wildcard that accepts **any** OID and returns the text unchanged; in
binary it accepts only the six string-shaped OIDs in the table, because
there is nothing sensible to hand back for the others.

Every cell that becomes a `String`, a `StringSlice` or text handed to a
decoder is checked as UTF-8 first: an invalid sequence is an `ENCODING` error
reading `invalid UTF-8 at byte N of column M`, with the cell's own bytes left
out of the message. An embedded NUL is **not** invalid -- the length comes
from `PQgetlength`, never from a NUL scan, so a `text` value holding a NUL
arrives whole. What `pq` still does not do is set `client_encoding`; see
`## Zero-copy access` for what that means for a non-UTF-8 database.

| PostgreSQL | OID | Mojo type | text form | binary form |
|---|---|---|---|---|
| bool | 16 | `Bool` | `t` / `f` | 1 byte, 0 or 1 |
| int2 | 21 | `Int16` | decimal | 2 byte BE |
| int4 | 23 | `Int32` | decimal | 4 byte BE |
| int8 | 20 | `Int64` (also readable as `Int`) | decimal | 8 byte BE |
| float4 | 700 | `Float32` | decimal, `NaN` / `Infinity` / `-Infinity` | IEEE 754, 4 byte BE |
| float8 | 701 | `Float64` | same | IEEE 754, 8 byte BE |
| numeric | 1700 | `Decimal` | position notation, `NaN` / `±Infinity` | ndigits, weight, sign, dscale, then base-10000 digits |
| uuid | 2950 | `UUID` | lowercase `8-4-4-4-12` | 16 byte |
| date | 1082 | `Date` | `YYYY-MM-DD`, ` BC` suffix, `±infinity` | int32 days from 2000-01-01 |
| timestamp | 1114 | `Timestamp` | `YYYY-MM-DD HH:MM:SS[.f]`, same | int64 µs from 2000-01-01 |
| timestamptz | 1184 | `TimestampTz` | same plus the UTC offset | same, always UTC |
| time | 1083 | `Time` | `HH:MM:SS[.f]`, `24:00:00` included | int64 µs into the day |
| timetz | 1266 | `TimeTz` | same plus `±HH[:MM[:SS]]` | int64 µs + int32 zone |
| interval | 1186 | `Interval` | `IntervalStyle` `postgres` only | int64 µs + int32 days + int32 months |
| text, varchar, bpchar, name | 25, 1043, 1042, 19 | `String` | as-is, UTF-8 checked | same, `PQgetlength` bytes |
| json | 114 | `String` | as-is, UTF-8 checked | same |
| jsonb | 3802 | `String` | as-is, UTF-8 checked | same, leading version byte (1) stripped before the check |
| bytea | 17 | `List[UInt8]` | `\\x` hex form only | the raw bytes |
| anything else | -- | `String` in text, nothing in binary | as-is | `TYPE_MISMATCH`, pointing at `ResultFormat.TEXT` |

`pq.decode_text.decode_text` and `pq.decode_binary.decode_binary` implement
one column of the table each, and are the two places to change when a type
is added. `Row.get_bytes` is outside the table on purpose: it hands back the
column's bytes as they arrived without consulting the OID at all, so a
`bytea` read with it is the eight bytes of `\\x00ff00` in text format and the
three bytes `00 ff 00` in binary -- see `## Zero-copy access`.

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

## Zero-copy access

`Row.get_text(i)` returns a `StringSlice` and `Row.get_bytes(i)` a
`Span[UInt8]`, both pointing straight into the `PGresult`'s own storage
instead of allocating a copy:

```mojo
var total = 0
for row in res:
    total += row.get_text(0).byte_length()
```

- The view is valid until `PQclear` runs, which is after the **last use** of
  any `Row` or slice borrowed from the result. Using one after the result has
  been moved away (`var r2 = res^`, or passing `res^` to a function) is a
  compile error, not a dangling read; `_ = res^` is a keep-alive marker, so
  `var s = res[0].get_text(0); _ = res^; print(s)` is correct.
- `get_text` accepts any OID in text format and only the six string-shaped
  OIDs in binary; `get_bytes` accepts every column in either format and hands
  back the region as it is, so a `bytea` is the eight bytes of `\\x00ff00` in
  text format and the three bytes `00 ff 00` in binary. `get_text` checks the
  region as UTF-8 and raises `ENCODING` with the byte offset when it is
  not; `get_bytes` has no encoding to check. `pq` still never sets
  `client_encoding`: libpq defaults it to the database's `server_encoding`
  (or `PGCLIENTENCODING`), and the tests only check that this is `UTF8` on
  the test containers -- against a non-UTF-8 database the check is what
  fails, in place of a malformed slice.
- Nothing in `pq` returns a `ref`; the origin travels with the slice.

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

## Asynchronous use

`AsyncConnection` is the non-blocking connection. It never waits unless
asked: each round trip is a step the caller drives, and `state()` says where
the connection is between the steps.

```
Connecting --(poll_connect returns Ready)--> Idle
Idle --(send*)--> Sending or Busy
Sending --(flush returns True)--> Busy
Busy --(poll_result returns None, state Idle)--> Idle
```

```mojo
var conn = AsyncConnection.connect_blocking(conninfo, 5000)
conn.send("SELECT pg_sleep(2), 1")
var results = conn.fetch_all(5000)
print(results[0][0].get[Int32](1))
```

- **Stepping it yourself.** `start` then `poll_connect` until it answers
  `PollState.READY`, waiting for whichever direction it asks for; then
  `send*`, `flush` while `SENDING`, and `poll_result` until it answers None
  with `state() == AsyncState.IDLE`. A None while `BUSY` means "nothing yet",
  so wait for readability and call again.
- **Letting it block.** `connect_blocking` is that handshake loop and
  `fetch_all` is that result loop, each with a millisecond budget for the
  **whole** operation. `wait_readable` / `wait_writable` are the single waits
  underneath, in case only part of the loop should be written by hand.
- **Timeouts.** Running out of budget is `PgErrorKind.TIMEOUT` and nothing
  else: the connection is untouched and still usable, and the command it was
  waiting for is still in flight. `timeout_ms` is `-1` for no limit and `0`
  to test the current state without waiting. Its largest accepted value is
  `2147483647` ms (about 24 days), the maximum of the `c_int` that `poll(2)`
  takes; anything above it is `USAGE` rather than a budget that silently
  wraps, so "effectively forever" is spelled `-1`. On the loops that own a
  whole operation -- `connect_blocking`, `fetch_all` -- `0` is a budget of
  nothing and therefore an immediate `TIMEOUT`, not a single look.
- **One command at a time.** `send*` is accepted only in `IDLE`, and a
  command is over when `poll_result` has seen the None, which is later than
  `is_busy` turning False -- `SELECT 1; SELECT 2` answers with two results
  and then the None. Calling a method in the wrong state is
  `PgErrorKind.USAGE` with `<method>() called while <State>`, detected
  before libpq sees it.
- **Failures are recoverable.** A statement that fails leaves the rest of
  the command collectable: `fetch_all` drains to the end before raising, and
  a hand-written loop just keeps calling `poll_result` until `IDLE`. The
  connection is usable for the next `send` either way.

- **Cancelling.** `cancel` asks the server to drop the command in flight
  over a second, short-lived connection, so it answers in a millisecond or
  two. The command itself still has to be collected: it comes back as
  `PgErrorKind.SERVER` with SQLSTATE `57014`. Inside an explicit
  transaction that leaves `transaction_status()` at `PQTRANS_INERROR`, where
  every further statement is `25P02` until a `ROLLBACK` is sent. A `cancel`
  with nothing in flight does nothing rather than raising.
- **One row at a time.** `set_single_row_mode` right after a `send*` turns
  each row of each statement into a result of its own, followed by one
  carrying no rows: `SELECT generate_series(1,3)` becomes four results. The
  window closes as soon as anything reads from the connection, and calling
  it outside the window is `USAGE`.
- **`LISTEN` / `NOTIFY`.** `send("LISTEN channel")` like any other command,
  then collect with `notifications` (everything that has arrived, possibly
  nothing) or `wait_notification` (one, with a budget). Neither promises
  that one call sees every notification already sent, so a reader that needs
  *n* of them keeps calling. `wait_notification` answers None when its
  budget runs out -- nothing arriving is a normal outcome, not a `TIMEOUT`.
  Channel and payload are checked as UTF-8 like any text value, so a
  notification carrying other bytes (which a `SQL_ASCII` database allows) is
  dropped with an `ENCODING` error instead of arriving mangled; the
  connection stays usable and the next call delivers the rest.

```mojo
conn.send("LISTEN jobs")
_ = conn.fetch_all(5000)
var note = conn.wait_notification(2000)
if note:
    print(note.value().channel, note.value().payload)
```

The whole surface, with the `PgErrorKind` each method can raise. Every
method that takes a `timeout_ms` also raises `USAGE` for a budget outside
`-1 .. 2147483647`, and every one that talks to libpq raises `USAGE` when
called in a state the step does not belong to:

| Method | Answers | Raises |
|---|---|---|
| `start(conninfo)`, `start(params)` | an `AsyncConnection` in `CONNECTING` | `TYPE_MISMATCH`, `LIBPQ_LOAD`, `CONNECTION` |
| `connect_blocking(conninfo, timeout_ms)`, `connect_blocking(params, timeout_ms)` | an `AsyncConnection` in `IDLE` | those, plus `TIMEOUT`, `USAGE` and `SERVER` (rejected session settings) |
| `poll_connect()` | `PollState` | `CONNECTION`, `SERVER` |
| `socket()`, `state()`, `status()`, `transaction_status()` | `Int`, `AsyncState`, `Int`, `Int` | nothing |
| `send(sql)`, `send(sql, params, result_format)` | nothing | `TYPE_MISMATCH`, `USAGE`, `CONNECTION` |
| `send_prepare(name, sql, param_types)`, `send_prepared(name, params, result_format)` | nothing | `TYPE_MISMATCH`, `USAGE`, `CONNECTION` |
| `flush()` | True once the command is fully written | `USAGE`, `CONNECTION` |
| `set_single_row_mode()` | nothing | `USAGE` |
| `consume_input()` | nothing | `USAGE`, `CONNECTION` |
| `is_busy()` | True while no complete result has arrived | nothing |
| `poll_result()` | `Optional[Result]` | `USAGE`, `CONNECTION`, `SERVER` |
| `fetch_all(timeout_ms)` | `List[Result]` | `TIMEOUT`, `USAGE`, `SERVER`, `CONNECTION` |
| `cancel()` | nothing | `USAGE`, `CONNECTION` |
| `notifications()` | `List[Notification]` | `USAGE`, `CONNECTION`, `ENCODING` (channel or payload is not UTF-8) |
| `wait_notification(timeout_ms)` | `Optional[Notification]`, None on an expired budget | `USAGE`, `CONNECTION`, `ENCODING` |
| `wait_readable(timeout_ms)`, `wait_writable(timeout_ms)` | nothing | `TIMEOUT`, `CONNECTION`, `USAGE` |

`AsyncState` is `CONNECTING` / `IDLE` / `SENDING` / `BUSY` and `PollState`
is `NEED_READ` / `NEED_WRITE` / `READY`; a failed handshake is the raised
`CONNECTION` rather than a fourth `PollState`. `Notification` carries
`channel`, `payload` and `backend_pid`.

## `PgErrorKind`

Every `pq` API raises `PgError`, and its `kind` is one of exactly eight
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
- `TIMEOUT` (`Timeout`) -- an asynchronous wait ran out of time. The
  connection is untouched and still usable.
- `ENCODING` (`Encoding`) -- text that reached the client is not UTF-8: a
  `String` cell or a notification's channel / payload. The connection and
  the result are untouched.

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
from .async_conn import AsyncConnection, AsyncState, Notification, PollState
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
