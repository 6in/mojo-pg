"""Tests for `pq.copy` and the `copy_in` / `copy_out` factories.

Fixes the observable contract of the two bulk-transfer streams against a live
server: `Connection.copy_in` and `Transaction.copy_in` hand back a `CopyIn`
whose `write` feeds `PQputCopyData` and whose `finish` reports the server's
row count, while `copy_out` hands back a `CopyOut` driven with `while` and
`next()` until it answers `None`.

Six properties get their own tests because they are the ones that break
quietly.

First, a `write` that returns means libpq accepted the bytes -- not that the
server liked them. A malformed row surfaces from `finish()`, as
`PgErrorKind.SERVER` carrying the server's own SQLSTATE (`22P04` for a row
with a column missing), and the table is left exactly as it was.

Second, every path that ends a stream drains libpq until `PQgetResult`
answers NULL, so the connection is back to `PQTRANS_IDLE` and immediately
usable -- after a successful `finish`, after a failed one, after `abort`, and
after a destructor. `COPY t FROM STDIN; SELECT 42` is the case that proves
the drain: the `SELECT`'s result arrives behind the COPY's own.

Third, `abort` and a dropped `CopyIn` both cancel through `PQputCopyEnd` with
a reason, which the server answers with SQLSTATE `57014`. That is the
*expected* outcome of those two paths, so it is swallowed: `abort` returns
normally and a destructor leaves the connection's rollback-failure handler
uncalled. A handler that never fires is the only way a test can see that the
swallowing happened, which is why the drop test installs one.

Fourth, while a COPY is open the connection is locked: `execute`,
`execute` with parameters, `prepare`, `transaction`, `copy_in`, `copy_out`
and `PreparedStatement.execute` all raise `PgErrorKind.USAGE` and send
nothing, because libpq would otherwise end the COPY silently and discard
every row written so far. The COPY is unharmed by the refusals -- `finish()`
still counts exactly the rows that were written.

Fifth, the direction is checked client-side: a `COPY ... TO STDOUT` handed to
`copy_in`, a `COPY ... FROM STDIN` handed to `copy_out` and a plain `SELECT`
handed to either are `USAGE` errors naming the `PGRES_*` status that came
back, and the connection is idle again straight away. A `COPY` the *server*
rejects is not a `USAGE` error: a missing table is `PgErrorKind.SERVER` with
SQLSTATE `42P01`.

Sixth, destruction order matters, because a `Transaction` destroyed before
its own `CopyIn` sends a `ROLLBACK` that cancels the COPY underneath it. That
must not crash; the `CopyIn` destructor then finds no COPY in progress and
reports through the rollback-failure handler.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI), falling back to the local container. An unreachable
server fails these tests; it never skips them. Every test must pass against
both PG14 and PG17, so nothing here depends on version-specific wording: only
SQLSTATEs, transaction statuses, our own messages and values are asserted.

Each test opens its own connection and creates its own `CREATE TEMP TABLE`,
which keeps the table inside the session, so two test processes -- or the two
server versions -- never collide on a name. The table names are unique to
this file (`pq_p7_*`). The two tests that install a rollback-failure handler
each use their own connection, which keeps the handler out of the others, and
so do the two that close their own socket: nothing may open a descriptor
between the `close` and the `Connection` destructor, or `PQfinish` would
close a file that belongs to someone else.
"""

from std.ffi import c_int, external_call
from std.os import getenv, setenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pq._ffi.types import PQTRANS_IDLE
from pq.connection import Connection
from pq.copy import CopyIn, CopyOut
from pq.encode_binary import encode_int16, encode_int32
from pq.errors import PgError, PgErrorKind
from pq.params import Param
from pq.prepared import PreparedStatement
from pq.result import Result, Row
from pq.transaction import Transaction

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

# --- the wide table, used by the two 100,000 row transfers -------------------

comptime WIDE_ROWS: Int = 100000
"""How many rows the text COPY tests move in one stream."""

comptime WIDE_CHUNK: Int = 1000
"""How many rows go out per `write` call.

Each chunk is a little over eight kilobytes, which is what makes libpq flush
inside the `write` rather than only buffer: the closed-socket test depends on
a `write` being large enough to reach the socket.
"""

comptime WIDE_BYTES: Int = 4522225
"""Byte length of the whole generated payload, measured on PG14 and PG17.

Asserted rather than merely computed, so a change to the row generator shows
up here instead of silently changing what the round trip compares.
"""

comptime CREATE_WIDE: StaticString = (
    "CREATE TEMP TABLE pq_p7_wide(a int4, b int8, c float8, d text,"
    " e timestamp)"
)
"""The five column table whose text COPY output is byte-identical to input.

Every column was chosen so that the server's text output spells the value the
same way the input did: `1.5` stays `1.5`, and `2024-01-02 03:04:05` is
already the ISO form `timestamp` prints.
"""

comptime COPY_WIDE_IN: StaticString = "COPY pq_p7_wide FROM STDIN"
"""The statement `copy_in` accepts for the wide table."""

comptime COPY_WIDE_OUT: StaticString = "COPY pq_p7_wide TO STDOUT"
"""The statement `copy_out` accepts for the wide table."""

comptime COUNT_WIDE: StaticString = "SELECT count(*) FROM pq_p7_wide"
"""Counts what the wide table actually stored."""

# --- the CSV table -----------------------------------------------------------

comptime CREATE_CSV: StaticString = (
    "CREATE TEMP TABLE pq_p7_csv(id int4, name text, note text)"
)
"""Three text-ish columns, enough to carry a quoted field with a comma."""

comptime COPY_CSV_IN: StaticString = (
    "COPY pq_p7_csv FROM STDIN WITH (FORMAT csv)"
)
"""The CSV form of a COPY IN; `write` passes the bytes through untouched."""

comptime CSV_PAYLOAD: StaticString = '1,alice,plain\n2,"bob,jr","has, comma"\n'
"""Two CSV rows, the second with two quoted fields that contain commas.

No field is left empty: an unquoted empty CSV field is a NULL, which would
make the assertion about stored values a test of NULL handling instead.
"""

comptime SELECT_CSV: StaticString = (
    "SELECT id, name, note FROM pq_p7_csv ORDER BY id"
)
"""Reads the CSV rows back in a defined order."""

# --- the binary table --------------------------------------------------------

comptime CREATE_BIN: StaticString = (
    "CREATE TEMP TABLE pq_p7_bin(a int4, b int4)"
)
"""Two fixed-width columns, the smallest table worth a binary COPY."""

comptime COPY_BIN_IN: StaticString = (
    "COPY pq_p7_bin FROM STDIN WITH (FORMAT binary)"
)
"""The binary form of a COPY IN, which needs the PGCOPY header and trailer."""

comptime SELECT_BIN: StaticString = "SELECT a, b FROM pq_p7_bin ORDER BY a"
"""Reads the binary rows back in a defined order."""

comptime BIN_COLUMNS: Int = 2
"""How many columns each binary row declares in its int16 field count."""

comptime BIN_WIDTH: Int = 4
"""Byte length of an `int4` column, written before each value."""

comptime BIN_TRAILER: Int = -1
"""The int16 `ffff` that ends a binary COPY payload."""

comptime BIN_FIRST_A: Int = 7
"""First column of the first binary row."""

comptime BIN_FIRST_B: Int = 8
"""Second column of the first binary row."""

comptime BIN_SECOND_A: Int = -1
"""First column of the second binary row; negative, so the sign is tested."""

comptime BIN_SECOND_B: Int = 2147483647
"""Second column of the second binary row; `int4` max, so the width is too."""

# --- the pair table, used by everything that does not need bulk --------------

comptime CREATE_PAIR: StaticString = (
    "CREATE TEMP TABLE pq_p7_pair(x int4, y int4)"
)
"""The two column table most of the error-path tests write to."""

comptime COPY_PAIR_IN: StaticString = "COPY pq_p7_pair FROM STDIN"
"""The statement `copy_in` accepts for the pair table."""

comptime COPY_PAIR_OUT: StaticString = "COPY pq_p7_pair TO STDOUT"
"""The statement `copy_out` accepts for the pair table."""

comptime COUNT_PAIR: StaticString = "SELECT count(*) FROM pq_p7_pair"
"""Counts what the pair table actually stored."""

comptime INSERT_PAIR: StaticString = "INSERT INTO pq_p7_pair VALUES ($1, $2)"
"""The parameterised write prepared *before* a COPY starts."""

comptime PAIR_ROW_ONE: StaticString = "1\t2\n"
"""One well-formed text row for the pair table."""

comptime PAIR_ROW_TWO: StaticString = "3\t4\n"
"""A second well-formed text row for the pair table."""

comptime PAIR_CHUNK: Int = 1000
"""Rows per `write` in the closed-socket COPY IN test.

Ten kilobytes or so per call, which is past libpq's output buffer, so the
call reaches the socket instead of only buffering.
"""

comptime COPY_PAIR_THEN_SELECT: StaticString = (
    "COPY pq_p7_pair FROM STDIN; SELECT 42"
)
"""A COPY with a second statement behind it, whose result must be drained."""

# --- the trio table, used by the malformed-row test --------------------------

comptime CREATE_TRIO: StaticString = (
    "CREATE TEMP TABLE pq_p7_trio(x int4, y int4, z int4)"
)
"""Three columns, so a two-column row is short by one."""

comptime COPY_TRIO_IN: StaticString = "COPY pq_p7_trio FROM STDIN"
"""The statement `copy_in` accepts for the trio table."""

comptime COUNT_TRIO: StaticString = "SELECT count(*) FROM pq_p7_trio"
"""Counts what the trio table stored; zero, when the stream was rejected."""

comptime TRIO_SHORT_ROW: StaticString = "1\t2\n"
"""A row with one column missing, which the server reports as 22P04."""

comptime TRIO_GOOD_ROWS: StaticString = "4\t5\t6\n7\t8\t9\n"
"""Two well-formed rows, written after the short one and lost with it."""

# --- statements that need no table of ours -----------------------------------

comptime COPY_MISSING_TABLE: StaticString = (
    "COPY pq_p7_no_such_table FROM STDIN"
)
"""A COPY the server rejects, which must be SERVER 42P01 and not USAGE."""

comptime COPY_SERIES_OUT: StaticString = (
    "COPY (SELECT i, i * 2 FROM generate_series(1, 300000) i) TO STDOUT"
)
"""A COPY OUT of roughly four megabytes, produced without a table.

The closed-socket COPY OUT test needs more data than libpq can possibly have
buffered, so that the stream ends in a transfer failure rather than at its
own end; a server-side `generate_series` is the cheapest way to get it.
"""

comptime SERIES_LIMIT: Int = 400000
"""Upper bound on `next()` calls in the closed-socket COPY OUT test.

The number of rows libpq had already buffered is a buffer size, not a
contract, so the test asserts only that the loop ends in a `CONNECTION` error
inside this many iterations.
"""

comptime SELECT_ONE: StaticString = "SELECT 1"
"""The smallest statement that proves a connection is usable again."""

comptime SELECT_PARAM: StaticString = "SELECT $1::int4"
"""The smallest parameterised statement, for the refusal grid."""

# --- messages ----------------------------------------------------------------

comptime ALREADY_FINISHED: StaticString = "COPY already finished"
"""The `USAGE` message every method raises once a stream has ended."""

comptime COPY_IN_PROGRESS: StaticString = (
    "a COPY is in progress on this connection"
)
"""The `USAGE` message every other command raises while a COPY is open."""

comptime COPY_IN_WANTS_STDIN_FROM_COPY_OUT: StaticString = (
    "copy_in() requires a COPY ... FROM STDIN statement (result status 3)"
)
"""What `copy_in` says about a `COPY ... TO STDOUT` (`PGRES_COPY_OUT`)."""

comptime COPY_IN_WANTS_STDIN_FROM_SELECT: StaticString = (
    "copy_in() requires a COPY ... FROM STDIN statement (result status 2)"
)
"""What `copy_in` says about a `SELECT` (`PGRES_TUPLES_OK`)."""

comptime COPY_OUT_WANTS_STDOUT: StaticString = (
    "copy_out() requires a COPY ... TO STDOUT statement (result status 4)"
)
"""What `copy_out` says about a `COPY ... FROM STDIN` (`PGRES_COPY_IN`)."""

comptime UNEXPECTED_COPY_IN: StaticString = "unexpected result status 4"
"""What `execute` still says about a `COPY ... FROM STDIN` handed to it."""

comptime UNEXPECTED_COPY_OUT: StaticString = "unexpected result status 3"
"""What `execute` still says about a `COPY ... TO STDOUT` handed to it."""

comptime MISSING_TABLE_SQLSTATE: StaticString = "42P01"
"""`undefined_table`, what the server answers for a COPY of nothing."""

comptime BAD_COPY_SQLSTATE: StaticString = "22P04"
"""`bad_copy_file_format`, what a row with a column missing answers."""

comptime HANDLER_CALLS_VAR: StaticString = "PQ_TEST_COPY_ROLLBACK_CALLS"
"""Environment variable the counting handler records its calls in.

A rollback-failure handler cannot raise and returns nothing, so it has no way
to hand an observation back to the test by value. Writing to the environment
is the smallest channel that survives the destructor it is called from, and
one character per call makes "never" and "at least once" both readable.
"""


# --- helpers -----------------------------------------------------------------
#
# A `TestSuite` test only declares `raises` (plain `Error`), and `PgError` does
# not implicitly convert to `Error`, so a `raises PgError` API cannot be called
# straight from a test. These wrappers translate in both directions: success
# paths re-raise as `Error`, failure paths hand the `PgError` back for
# inspection. Helpers are per file by convention; nothing here is shared with
# `test_transaction.mojo`.
#
# Every `CopyIn` / `CopyOut` wrapper takes `mut c`, which is what `write`,
# `finish`, `abort` and `next` all need.


def _conninfo() -> String:
    """Return the conninfo of the server under test.

    Returns:
        `PQ_TEST_CONNINFO` when set and non-empty, else `DEFAULT_CONNINFO`.
    """
    var value = getenv("PQ_TEST_CONNINFO")
    return value if value != "" else String(DEFAULT_CONNINFO)


def _connect(var conninfo: String) raises -> Connection:
    """Open a connection from a conninfo string.

    Args:
        conninfo: A libpq `key=value ...` conninfo string.

    Returns:
        The open connection.

    Raises:
        Error: If `Connection.open` raised a `PgError`.
    """
    try:
        return Connection.open(conninfo^)
    except e:
        raise Error(String(e))


def _execute(conn: Connection, var sql: String) raises -> Result:
    """Run `sql` on `conn` without parameters.

    Args:
        conn: An open connection.
        sql: The statement to run.

    Returns:
        The result of the statement.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    try:
        return conn.execute(sql^)
    except e:
        raise Error(String(e))


def _execute_error(conn: Connection, var sql: String) raises -> PgError:
    """Return the `PgError` raised by `conn.execute(sql)`.

    Args:
        conn: An open connection.
        sql: A statement that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `execute` returned a result instead of raising.
    """
    try:
        var result = conn.execute(sql^)
        _ = result^
    except e:
        return e.copy()
    raise Error("expected a PgError from Connection.execute(sql)")


def _execute_params_error(
    conn: Connection, var sql: String, params: List[Param]
) raises -> PgError:
    """Return the `PgError` raised by `conn.execute(sql, params)`.

    Args:
        conn: An open connection.
        sql: A statement that must be rejected.
        params: The values bound to `$1`, `$2`, ... in order.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `execute` returned a result instead of raising.
    """
    try:
        var result = conn.execute(sql^, params)
        _ = result^
    except e:
        return e.copy()
    raise Error("expected a PgError from Connection.execute(sql, params)")


def _prepare(
    conn: Connection, var sql: String
) raises -> PreparedStatement[origin_of(conn)]:
    """Prepare `sql` on `conn`.

    Args:
        conn: An idle, open connection.
        sql: Exactly one statement, using `$1`..`$n` placeholders.

    Returns:
        The prepared statement, bound to the connection's origin.

    Raises:
        Error: If `prepare` raised a `PgError`.
    """
    try:
        return conn.prepare(sql^)
    except e:
        raise Error(String(e))


def _prepare_error(conn: Connection, var sql: String) raises -> PgError:
    """Return the `PgError` raised by `conn.prepare(sql)`.

    Args:
        conn: A connection that must refuse to prepare.
        sql: The statement whose preparation must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `prepare` returned a statement instead of raising.
    """
    try:
        var stmt = conn.prepare(sql^)
        _ = stmt^
    except e:
        return e.copy()
    raise Error("expected a PgError from Connection.prepare(sql)")


def _stmt_execute_error[
    origin: ImmOrigin, //
](stmt: PreparedStatement[origin], params: List[Param]) raises -> PgError:
    """Return the `PgError` raised by `stmt.execute(params)`.

    Parameters:
        origin: Origin of the `Connection` the statement views; inferred.

    Args:
        stmt: A prepared statement whose execution must be rejected.
        params: The values bound to `$1`, `$2`, ... in order.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `execute` returned a result instead of raising.
    """
    try:
        var result = stmt.execute(params)
        _ = result^
    except e:
        return e.copy()
    raise Error("expected a PgError from PreparedStatement.execute(params)")


def _transaction(conn: Connection) raises -> Transaction[origin_of(conn)]:
    """Begin a transaction block on `conn`.

    Args:
        conn: An idle, open connection.

    Returns:
        The open transaction block, with its `BEGIN` already sent.

    Raises:
        Error: If `transaction` raised a `PgError`.
    """
    try:
        return conn.transaction()
    except e:
        raise Error(String(e))


def _transaction_error(conn: Connection) raises -> PgError:
    """Return the `PgError` raised by `conn.transaction()`.

    Args:
        conn: A connection that must refuse to start a block.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `transaction` returned a block instead of raising.
    """
    try:
        var tx = conn.transaction()
        _ = tx^
    except e:
        return e.copy()
    raise Error("expected a PgError from Connection.transaction()")


def _tx_commit[origin: ImmOrigin, //](mut tx: Transaction[origin]) raises:
    """Commit `tx`.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The open transaction block.

    Raises:
        Error: If `commit` raised a `PgError`.
    """
    try:
        tx.commit()
    except e:
        raise Error(String(e))


def _tx_rollback[origin: ImmOrigin, //](mut tx: Transaction[origin]) raises:
    """Roll `tx` back.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The open transaction block.

    Raises:
        Error: If `rollback` raised a `PgError`.
    """
    try:
        tx.rollback()
    except e:
        raise Error(String(e))


def _tx_commit_error[
    origin: ImmOrigin, //
](mut tx: Transaction[origin]) raises -> PgError:
    """Commit `tx` expecting a refusal, and hand the error back.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The open transaction block.

    Returns:
        The `PgError` `commit` raised.

    Raises:
        Error: If `commit` succeeded.
    """
    try:
        tx.commit()
    except e:
        return e.copy()
    raise Error("expected a PgError from Transaction.commit()")


def _tx_rollback_error[
    origin: ImmOrigin, //
](mut tx: Transaction[origin]) raises -> PgError:
    """Roll `tx` back expecting a refusal, and hand the error back.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The open transaction block.

    Returns:
        The `PgError` `rollback` raised.

    Raises:
        Error: If `rollback` succeeded.
    """
    try:
        tx.rollback()
    except e:
        return e.copy()
    raise Error("expected a PgError from Transaction.rollback()")


def _copy_in(
    conn: Connection, var sql: String
) raises -> CopyIn[origin_of(conn)]:
    """Start `sql` as a COPY IN on `conn`.

    The returned stream is a view onto the connection: its `origin` parameter
    ties it to `conn`, so the compiler keeps the connection alive for as long
    as the stream is reachable.

    Args:
        conn: An idle, open connection.
        sql: A `COPY ... FROM STDIN` statement.

    Returns:
        The open input stream, with the `COPY` already accepted.

    Raises:
        Error: If `copy_in` raised a `PgError`.
    """
    try:
        return conn.copy_in(sql^)
    except e:
        raise Error(String(e))


def _copy_in_error(conn: Connection, var sql: String) raises -> PgError:
    """Return the `PgError` raised by `conn.copy_in(sql)`.

    Args:
        conn: A connection that must refuse to start the stream.
        sql: A statement `copy_in` must reject.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `copy_in` returned a stream instead of raising.
    """
    try:
        var stream = conn.copy_in(sql^)
        _ = stream^
    except e:
        return e.copy()
    raise Error("expected a PgError from Connection.copy_in(sql)")


def _copy_out(
    conn: Connection, var sql: String
) raises -> CopyOut[origin_of(conn)]:
    """Start `sql` as a COPY OUT on `conn`.

    Args:
        conn: An idle, open connection.
        sql: A `COPY ... TO STDOUT` statement.

    Returns:
        The open output stream, with the `COPY` already accepted.

    Raises:
        Error: If `copy_out` raised a `PgError`.
    """
    try:
        return conn.copy_out(sql^)
    except e:
        raise Error(String(e))


def _copy_out_error(conn: Connection, var sql: String) raises -> PgError:
    """Return the `PgError` raised by `conn.copy_out(sql)`.

    Args:
        conn: A connection that must refuse to start the stream.
        sql: A statement `copy_out` must reject.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `copy_out` returned a stream instead of raising.
    """
    try:
        var stream = conn.copy_out(sql^)
        _ = stream^
    except e:
        return e.copy()
    raise Error("expected a PgError from Connection.copy_out(sql)")


def _tx_copy_in[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var sql: String) raises -> CopyIn[origin]:
    """Start `sql` as a COPY IN inside `tx`.

    The stream borrows the same connection the block borrows, so it carries
    the block's own `origin` and may outlive the block itself -- which is
    exactly the hazard the destruction-order test covers.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The open transaction block.
        sql: A `COPY ... FROM STDIN` statement.

    Returns:
        The open input stream.

    Raises:
        Error: If `copy_in` raised a `PgError`.
    """
    try:
        return tx.copy_in(sql^)
    except e:
        raise Error(String(e))


def _tx_copy_out[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var sql: String) raises -> CopyOut[origin]:
    """Start `sql` as a COPY OUT inside `tx`.

    The mirror of `_tx_copy_in`, with the same origin and the same hazard:
    the stream may outlive the block it was started in.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The open transaction block.
        sql: A `COPY ... TO STDOUT` statement.

    Returns:
        The open output stream.

    Raises:
        Error: If `copy_out` raised a `PgError`.
    """
    try:
        return tx.copy_out(sql^)
    except e:
        raise Error(String(e))


def _copy_write[
    origin: ImmOrigin, //
](mut stream: CopyIn[origin], var s: String) raises:
    """Write the UTF-8 bytes of `s` to `stream`.

    Parameters:
        origin: Origin of the `Connection` the stream views; inferred.

    Args:
        stream: The open input stream.
        s: One or more complete rows in the COPY format of the command.

    Raises:
        Error: If `write` raised a `PgError`.
    """
    try:
        stream.write(s)
    except e:
        raise Error(String(e))


def _copy_write_bytes[
    origin: ImmOrigin, bytes_origin: ImmOrigin, //
](mut stream: CopyIn[origin], bytes: Span[UInt8, bytes_origin]) raises:
    """Write raw `bytes` to `stream`.

    Parameters:
        origin: Origin of the `Connection` the stream views; inferred.
        bytes_origin: Origin of the caller's byte span; inferred.

    Args:
        stream: The open input stream.
        bytes: The payload, already in the COPY format of the command.

    Raises:
        Error: If `write` raised a `PgError`.
    """
    try:
        stream.write(bytes)
    except e:
        raise Error(String(e))


def _copy_write_error[
    origin: ImmOrigin, //
](mut stream: CopyIn[origin], var s: String) raises -> PgError:
    """Return the `PgError` raised by `stream.write(s)`.

    Parameters:
        origin: Origin of the `Connection` the stream views; inferred.

    Args:
        stream: The stream the write must be refused on.
        s: The payload the write would have carried.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `write` succeeded instead of raising.
    """
    try:
        stream.write(s)
    except e:
        return e.copy()
    raise Error("expected a PgError from CopyIn.write(s)")


def _copy_write_until_connection_error[
    origin: ImmOrigin, //
](mut stream: CopyIn[origin], var s: String, limit: Int) raises -> PgError:
    """Write `s` repeatedly until a write fails, at most `limit` times.

    libpq buffers before it sends, so how many `write` calls fit between a
    closed socket and the failure is a buffer size rather than a contract.
    The caller gets the first error back and asserts its kind; the bound keeps
    a stream that never fails from looping forever.

    Parameters:
        origin: Origin of the `Connection` the stream views; inferred.

    Args:
        stream: The stream whose socket has been closed.
        s: The payload to write over and over.
        limit: Maximum number of attempts before giving up.

    Returns:
        The `PgError` the first failing write raised.

    Raises:
        Error: If `limit` writes all succeeded.
    """
    for _ in range(limit):
        try:
            stream.write(s)
        except e:
            return e.copy()
    raise Error("CopyIn.write kept succeeding on a closed socket")


def _copy_finish[
    origin: ImmOrigin, //
](mut stream: CopyIn[origin]) raises -> Result:
    """End `stream` normally and return the COPY's own result.

    Parameters:
        origin: Origin of the `Connection` the stream views; inferred.

    Args:
        stream: The open input stream.

    Returns:
        The result of the `COPY` command; `affected_rows()` is the row count.

    Raises:
        Error: If `finish` raised a `PgError`.
    """
    try:
        return stream.finish()
    except e:
        raise Error(String(e))


def _copy_finish_error[
    origin: ImmOrigin, //
](mut stream: CopyIn[origin]) raises -> PgError:
    """Return the `PgError` raised by `stream.finish()`.

    Parameters:
        origin: Origin of the `Connection` the stream views; inferred.

    Args:
        stream: The stream whose end must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `finish` returned a result instead of raising.
    """
    try:
        var result = stream.finish()
        _ = result^
    except e:
        return e.copy()
    raise Error("expected a PgError from CopyIn.finish()")


def _copy_abort[
    origin: ImmOrigin, //
](mut stream: CopyIn[origin], var message: String) raises:
    """Cancel `stream`, which must not raise.

    The server answers a cancel with SQLSTATE `57014`, and that is the
    expected outcome of this path, so it is swallowed rather than reported.

    Parameters:
        origin: Origin of the `Connection` the stream views; inferred.

    Args:
        stream: The open input stream.
        message: The reason handed to the server.

    Raises:
        Error: If `abort` raised a `PgError`.
    """
    try:
        stream.abort(message^)
    except e:
        raise Error(String(e))


def _copy_next[
    origin: ImmOrigin, //
](mut stream: CopyOut[origin]) raises -> Optional[List[UInt8]]:
    """Return the next row of `stream`, or `None` at its end.

    Parameters:
        origin: Origin of the `Connection` the stream views; inferred.

    Args:
        stream: The open output stream.

    Returns:
        The next row's bytes, or `None` once the server has sent everything.

    Raises:
        Error: If `next` raised a `PgError`.
    """
    try:
        return stream.next()
    except e:
        raise Error(String(e))


def _copy_next_until_connection_error[
    origin: ImmOrigin, //
](mut stream: CopyOut[origin], limit: Int) raises -> PgError:
    """Read from `stream` until it fails, at most `limit` rows.

    How many rows libpq had already buffered when the socket went away is a
    buffer size and not a contract, so the caller only gets the error back.
    Reaching the end of the stream is a failure of the test, not a result: the
    payload is chosen to be far larger than any buffer.

    Parameters:
        origin: Origin of the `Connection` the stream views; inferred.

    Args:
        stream: The stream whose socket has been closed.
        limit: Maximum number of rows to read before giving up.

    Returns:
        The `PgError` the failing `next()` raised.

    Raises:
        Error: If the stream ended cleanly, or `limit` rows came back.
    """
    for _ in range(limit):
        # The read is the only thing inside the `try`: that block raises
        # `PgError`, so an `Error` raised inside it would not convert to one.
        var row: Optional[List[UInt8]]
        try:
            row = stream.next()
        except e:
            return e.copy()
        if not row:
            raise Error("CopyOut ended cleanly on a closed socket")
        _ = row^
    raise Error("CopyOut kept answering rows on a closed socket")


def _row(result: Result, i: Int) raises -> Row[origin_of(result)]:
    """Return row `i` of `result`.

    Args:
        result: The result to index.
        i: Zero-based row index.

    Returns:
        The row at that index.

    Raises:
        Error: If `result[i]` raised a `PgError`.
    """
    try:
        return result[i]
    except e:
        raise Error(String(e))


def _get[
    origin: ImmOrigin, //, T: Copyable & Deinitable
](row: Row[origin], col: Int) raises -> T:
    """Read column `col` of `row` as `T`.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.
        T: The Mojo type requested from `Row.get`.

    Args:
        row: The row to read.
        col: Zero-based column index.

    Returns:
        The decoded value.

    Raises:
        Error: If `Row.get` raised a `PgError`.
    """
    try:
        return row.get[T](col)
    except e:
        raise Error(String(e))


def _create(conn: Connection, var sql: String) raises:
    """Run a `CREATE TEMP TABLE` on `conn` and discard its result.

    Args:
        conn: The connection whose session gets the table.
        sql: The `CREATE TEMP TABLE` statement.

    Raises:
        Error: If the `CREATE` raised a `PgError`.
    """
    var created = _execute(conn, sql^)
    _ = created^


def _count(conn: Connection, var sql: String) raises -> Int:
    """Run a one-column `count(*)` query and return its value.

    Args:
        conn: The connection whose session owns the table.
        sql: A `SELECT count(*) ...` statement.

    Returns:
        The counted number of rows.

    Raises:
        Error: If the query or the decoding raised a `PgError`.
    """
    var result = _execute(conn, sql^)
    var row = _row(result, 0)
    var count = _get[Int64](row, 0)
    _ = row^
    _ = result^
    return Int(count)


def _reset(conn: Connection) raises:
    """Reconnect `conn` with `Connection.reset()`.

    Args:
        conn: The connection to revive.

    Raises:
        Error: If `reset` raised a `PgError`.
    """
    try:
        conn.reset()
    except e:
        raise Error(String(e))


def _assert_usable(conn: Connection) raises:
    """Assert `conn` is idle and that the next `execute` on it works.

    This is the end state every COPY path must leave behind, so it is checked
    the same way everywhere: the libpq transaction status first -- a COPY that
    was not drained reports `PQTRANS_ACTIVE` -- and then a real round trip.

    Args:
        conn: The connection a COPY has just finished on.

    Raises:
        Error: If the connection is not idle or the statement failed.
    """
    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))
    var result = _execute(conn, String(SELECT_ONE))
    assert_equal(result.row_count(), 1)
    assert_equal(_get[Int32](_row(result, 0), 0), Int32(1))
    _ = result^


def _assert_same_bytes[
    got_origin: ImmOrigin, expected_origin: ImmOrigin, //
](
    got: Span[UInt8, got_origin],
    expected: Span[UInt8, expected_origin],
    what: StaticString,
) raises:
    """Assert two byte views have the same length and the same elements.

    The comparison is a plain loop that records the first differing index and
    asserts once, rather than asserting per byte: these views are megabytes
    long, and one assertion per byte would dominate the test's runtime.

    Parameters:
        got_origin: Origin of the bytes under test; inferred.
        expected_origin: Origin of the expected bytes; inferred.

    Args:
        got: The bytes read back.
        expected: The bytes they must equal.
        what: Label naming the case, used in failure messages.

    Raises:
        Error: If the two views differ in length or in any byte.
    """
    assert_equal(len(got), len(expected), String(what, ": length"))
    var first_difference = -1
    for i in range(len(expected)):
        if got[i] != expected[i]:
            first_difference = i
            break
    assert_equal(
        first_difference, -1, String(what, ": first differing byte index")
    )


def _wide_rows(start: Int, count: Int) -> String:
    """Return `count` text COPY rows of the wide table, starting at `start`.

    The row is `<i>\\t<i*2>\\t1.5\\trow<i>\\t2024-01-02 03:04:05\\n`, which the
    server stores and prints back byte for byte -- that is what makes the
    COPY OUT comparison exact.

    Args:
        start: Value of `a` in the first row.
        count: How many consecutive rows to generate.

    Returns:
        The rows concatenated, each newline terminated.
    """
    var out = String()
    for i in range(start, start + count):
        # `write` appends in place; `out += String(...)` would build and then
        # throw away one temporary `String` per row, and there are a hundred
        # thousand of them.
        out.write(i, "\t", i * 2, "\t1.5\trow", i, "\t2024-01-02 03:04:05\n")
    return out^


def _wide_payload() -> String:
    """Return every generated wide-table row as one text COPY payload.

    Returns:
        All `WIDE_ROWS` rows, which is `WIDE_BYTES` bytes.
    """
    return _wide_rows(0, WIDE_ROWS)


def _fill_wide(conn: Connection) raises -> Int:
    """COPY the whole generated payload into the wide table on `conn`.

    The rows go out `WIDE_CHUNK` at a time, so the stream exercises many
    `write` calls rather than one, and the chunks are large enough that libpq
    flushes inside each call.

    Args:
        conn: A connection whose session already has the wide table.

    Returns:
        The row count the server reported from `finish()`.

    Raises:
        Error: If any part of the stream raised a `PgError`.
    """
    var stream = _copy_in(conn, String(COPY_WIDE_IN))
    for start in range(0, WIDE_ROWS, WIDE_CHUNK):
        _copy_write(stream, _wide_rows(start, WIDE_CHUNK))
    var result = _copy_finish(stream)
    var taken = result.affected_rows()
    _ = result^
    _ = stream^
    return taken


def _pair_rows(start: Int, count: Int) -> String:
    """Return `count` text COPY rows of the pair table, starting at `start`.

    Args:
        start: Value of `x` in the first row.
        count: How many consecutive rows to generate.

    Returns:
        The rows concatenated, each newline terminated.
    """
    var out = String()
    for i in range(start, start + count):
        out.write(i, "\t", i * 2, "\n")
    return out^


def _binary_pair_payload() -> List[UInt8]:
    """Return a complete binary COPY payload for two `int4` rows.

    The layout is the one `COPY ... WITH (FORMAT binary)` reads: the eleven
    byte `PGCOPY\\n\\377\\r\\n\\0` signature, an int32 flags word of 0 and an
    int32 header-extension length of 0, then per row an int16 column count
    followed by an int32 byte length and that many bytes for each column, and
    finally the int16 `-1` trailer.

    Returns:
        The bytes of the two rows, header and trailer included.
    """
    var out = List[UInt8](capacity=64)
    var signature: List[UInt8] = [
        0x50,
        0x47,
        0x43,
        0x4F,
        0x50,
        0x59,
        0x0A,
        0xFF,
        0x0D,
        0x0A,
        0x00,
    ]
    for i in range(len(signature)):
        out.append(signature[i])
    # The flags word and the header-extension length are both zero: no OIDs
    # travel with the data and there is no extension area to skip.
    out.extend(encode_int32(Int32(0)))
    out.extend(encode_int32(Int32(0)))

    out.extend(encode_int16(Int16(BIN_COLUMNS)))
    out.extend(encode_int32(Int32(BIN_WIDTH)))
    out.extend(encode_int32(Int32(BIN_FIRST_A)))
    out.extend(encode_int32(Int32(BIN_WIDTH)))
    out.extend(encode_int32(Int32(BIN_FIRST_B)))

    out.extend(encode_int16(Int16(BIN_COLUMNS)))
    out.extend(encode_int32(Int32(BIN_WIDTH)))
    out.extend(encode_int32(Int32(BIN_SECOND_A)))
    out.extend(encode_int32(Int32(BIN_WIDTH)))
    out.extend(encode_int32(Int32(BIN_SECOND_B)))

    out.extend(encode_int16(Int16(BIN_TRAILER)))
    return out^


# --- rollback-failure handler ------------------------------------------------
#
# A non-capturing top-level function, which is what the `thin` handler type
# asks for. The handler has no way to report anything by raising, so it appends
# one character per call to an environment variable instead: an empty value
# means "never called", and any length means "called at least that often". The
# character records the kind, so a surprising kind is visible in a failure.


def _count_rollback_failure(error: PgError):
    """Append one character per failed implicit rollback or cancel.

    Args:
        error: The `PgError` the destructor produced.
    """
    var mark = "c" if error.kind == PgErrorKind.CONNECTION else "o"
    _ = setenv(
        String(HANDLER_CALLS_VAR),
        getenv(String(HANDLER_CALLS_VAR)) + mark,
        True,
    )


# --- text COPY IN of 100,000 rows -- (1) -------------------------------------


def test_text_copy_in_takes_every_row() raises:
    """A hundred thousand rows go in over a hundred `write` calls."""
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_WIDE))

    assert_equal(_fill_wide(conn), WIDE_ROWS)

    # The server's own count agrees with the one `finish()` reported.
    assert_equal(_count(conn, String(COUNT_WIDE)), WIDE_ROWS)
    _assert_usable(conn)

    _ = conn^


# --- CSV COPY IN -- (2) ------------------------------------------------------


def test_csv_copy_in_stores_quoted_fields() raises:
    """CSV bytes pass through untouched, quoting and all.

    `write` does no escaping of its own, so the quoting in the payload is the
    CSV format's and the server is the only thing that interprets it: the
    field `"bob,jr"` arrives as the three characters `bob`, a comma and `jr`,
    not as two columns.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_CSV))

    var stream = _copy_in(conn, String(COPY_CSV_IN))
    _copy_write(stream, String(CSV_PAYLOAD))
    var result = _copy_finish(stream)
    assert_equal(result.affected_rows(), 2)
    _ = result^
    _ = stream^

    var rows = _execute(conn, String(SELECT_CSV))
    assert_equal(rows.row_count(), 2)

    var first = _row(rows, 0)
    assert_equal(_get[Int32](first, 0), Int32(1))
    assert_equal(_get[String](first, 1), "alice")
    assert_equal(_get[String](first, 2), "plain")
    _ = first^

    var second = _row(rows, 1)
    assert_equal(_get[Int32](second, 0), Int32(2))
    assert_equal(_get[String](second, 1), "bob,jr")
    assert_equal(_get[String](second, 2), "has, comma")
    _ = second^

    _ = rows^
    _assert_usable(conn)
    _ = conn^


# --- binary COPY IN -- (3) ---------------------------------------------------


def test_binary_copy_in_stores_both_rows() raises:
    """A hand-built PGCOPY payload lands as two `int4` rows.

    The whole payload goes out in a single `write`, through the `Span`
    overload: a binary COPY has no row separator, so there is nothing to be
    gained from splitting it.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_BIN))

    var payload = _binary_pair_payload()
    var stream = _copy_in(conn, String(COPY_BIN_IN))
    _copy_write_bytes(stream, Span[UInt8](payload))
    var result = _copy_finish(stream)
    assert_equal(result.affected_rows(), 2)
    _ = result^
    _ = stream^

    # `ORDER BY a` puts the negative row first.
    var rows = _execute(conn, String(SELECT_BIN))
    assert_equal(rows.row_count(), 2)

    var negative = _row(rows, 0)
    assert_equal(_get[Int32](negative, 0), Int32(BIN_SECOND_A))
    assert_equal(_get[Int32](negative, 1), Int32(BIN_SECOND_B))
    _ = negative^

    var positive = _row(rows, 1)
    assert_equal(_get[Int32](positive, 0), Int32(BIN_FIRST_A))
    assert_equal(_get[Int32](positive, 1), Int32(BIN_FIRST_B))
    _ = positive^

    _ = rows^
    _ = payload^
    _assert_usable(conn)
    _ = conn^


# --- COPY OUT of the same 100,000 rows -- (4) --------------------------------


def test_copy_out_returns_every_row_then_none() raises:
    """`next()` answers each row once and then `None`, byte for byte.

    The concatenation of the rows that come back is compared against the very
    payload that went in, which only holds because every column of the wide
    table prints the way it was written. The stream is read with `while` and
    `next()` because a `CopyOut` is deliberately not an `Iterator`: the end of
    the stream is a value, not a `StopIteration`.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_WIDE))
    assert_equal(_fill_wide(conn), WIDE_ROWS)

    var expected = _wide_payload()
    assert_equal(Int(expected.byte_length()), WIDE_BYTES)

    var stream = _copy_out(conn, String(COPY_WIDE_OUT))
    var seen = List[UInt8](capacity=WIDE_BYTES)
    var rows = 0
    var newline_terminated = 0
    while rows < WIDE_ROWS:
        var row = _copy_next(stream)
        if not row:
            break
        ref bytes = row.value()
        var length = len(bytes)
        if length > 0 and bytes[length - 1] == UInt8(10):
            newline_terminated += 1
        for i in range(length):
            seen.append(bytes[i])
        rows += 1

    assert_equal(rows, WIDE_ROWS)
    assert_equal(newline_terminated, WIDE_ROWS)

    # The 100,001st call is the end of the stream, and it is a value.
    assert_false(Bool(_copy_next(stream)))
    _ = stream^

    _assert_same_bytes(
        Span[UInt8](seen), expected.as_bytes(), "COPY OUT round trip"
    )
    _ = seen^
    _ = expected^

    _assert_usable(conn)
    _ = conn^


# --- abort -- (5) ------------------------------------------------------------


def test_abort_discards_the_rows_without_raising() raises:
    """`abort` cancels the COPY and swallows the server's 57014.

    The cancel *is* an error on the wire -- `COPY from stdin failed: test`
    with SQLSTATE `57014` -- but it is the outcome the caller asked for, so
    `abort` returns normally and only an unexpected failure is raised.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_PAIR))

    var stream = _copy_in(conn, String(COPY_PAIR_IN))
    _copy_write(stream, String(PAIR_ROW_ONE))
    _copy_write(stream, String(PAIR_ROW_TWO))
    _copy_abort(stream, "test")
    _ = stream^

    assert_equal(_count(conn, String(COUNT_PAIR)), 0)
    _assert_usable(conn)
    _ = conn^


# --- dropping a CopyIn -- (6) ------------------------------------------------


def test_dropping_an_unfinished_copy_in_cancels_it_quietly() raises:
    """A dropped `CopyIn` cancels, and the handler never hears about it.

    The destructor's cancel draws the same `57014` `abort` does, and swallows
    it the same way. The handler is the only place a destructor could report
    anything, so a handler that was never called is the proof that the
    swallowing happened -- and that the default handler would not have printed
    anything either.
    """
    _ = setenv(String(HANDLER_CALLS_VAR), "", True)

    var conn = _connect(_conninfo())
    conn.set_rollback_failure_handler(_count_rollback_failure)
    _create(conn, String(CREATE_PAIR))

    var stream = _copy_in(conn, String(COPY_PAIR_IN))
    _copy_write(stream, String(PAIR_ROW_ONE))

    # The marker keeps the stream alive to here; past it the destructor has
    # run, so the cancel has already been sent and drained.
    _ = stream^

    assert_equal(_count(conn, String(COUNT_PAIR)), 0)
    assert_equal(getenv(String(HANDLER_CALLS_VAR)), "")
    _assert_usable(conn)
    _ = conn^


# --- dropping a CopyOut -- (7) -----------------------------------------------


def test_dropping_a_copy_out_mid_stream_leaves_the_connection_usable() raises:
    """A `CopyOut` dropped after one row reads the rest away itself.

    Nothing else can: until the server has sent its last row the connection is
    not idle, so the destructor has to drain the remaining 99,999 rows rather
    than leave them for the next command to trip over.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_WIDE))
    assert_equal(_fill_wide(conn), WIDE_ROWS)

    var stream = _copy_out(conn, String(COPY_WIDE_OUT))
    var first = _copy_next(stream)
    assert_true(Bool(first))
    _ = first^
    _ = stream^

    _assert_usable(conn)
    _ = conn^


# --- the lock on the connection -- (8) ---------------------------------------


def test_every_other_command_during_a_copy_is_usage() raises:
    """All seven commands are refused, and the COPY survives all seven.

    libpq would not refuse any of them: a `PQexec` issued during a COPY ends
    the COPY first and discards every row written so far, then runs the new
    command successfully. The refusal is what turns that silent data loss into
    an error, so the test asserts both halves -- the `USAGE` message, and that
    `finish()` still counts the two rows that were written.

    The prepared statement is created *before* the stream on purpose: its
    `execute` has to be refused like any other command, which is a check on
    the statement rather than on the connection the caller holds.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_PAIR))
    var stmt = _prepare(conn, String(INSERT_PAIR))

    var stream = _copy_in(conn, String(COPY_PAIR_IN))
    _copy_write(stream, String(PAIR_ROW_ONE))
    _copy_write(stream, String(PAIR_ROW_TWO))

    var executed = _execute_error(conn, String(SELECT_ONE))
    assert_true(executed.kind == PgErrorKind.USAGE)
    assert_equal(executed.message, String(COPY_IN_PROGRESS))
    assert_equal(executed.sqlstate, "")

    var params: List[Param] = [Int32(1)]
    var bound = _execute_params_error(conn, String(SELECT_PARAM), params)
    assert_true(bound.kind == PgErrorKind.USAGE)
    assert_equal(bound.message, String(COPY_IN_PROGRESS))

    var prepared = _prepare_error(conn, String(SELECT_ONE))
    assert_true(prepared.kind == PgErrorKind.USAGE)
    assert_equal(prepared.message, String(COPY_IN_PROGRESS))

    var begun = _transaction_error(conn)
    assert_true(begun.kind == PgErrorKind.USAGE)
    assert_equal(begun.message, String(COPY_IN_PROGRESS))

    var nested_in = _copy_in_error(conn, String(COPY_PAIR_IN))
    assert_true(nested_in.kind == PgErrorKind.USAGE)
    assert_equal(nested_in.message, String(COPY_IN_PROGRESS))

    var nested_out = _copy_out_error(conn, String(COPY_PAIR_OUT))
    assert_true(nested_out.kind == PgErrorKind.USAGE)
    assert_equal(nested_out.message, String(COPY_IN_PROGRESS))

    var values: List[Param] = [Int32(5), Int32(6)]
    var reused = _stmt_execute_error(stmt, values)
    assert_true(reused.kind == PgErrorKind.USAGE)
    assert_equal(reused.message, String(COPY_IN_PROGRESS))

    # Nothing of the seven reached the server, so the stream is intact.
    var result = _copy_finish(stream)
    assert_equal(result.affected_rows(), 2)
    _ = result^
    _ = stream^

    assert_equal(_count(conn, String(COUNT_PAIR)), 2)

    # The statement is kept alive until here: its destructor sends a raw
    # `DEALLOCATE`, which is not guarded, so it must not run during the COPY.
    _ = stmt^

    _assert_usable(conn)
    _ = conn^


# --- a malformed row surfaces from finish -- (9) -----------------------------


def test_malformed_row_surfaces_from_finish() raises:
    """A short row is the server's complaint, reported by `finish()`.

    The `write` that carried it had no way to know: libpq accepted the bytes,
    and the server only parses them when the stream ends. So the error arrives
    from `finish()`, as `SERVER` with the server's own `22P04`, and the whole
    stream is lost -- including the two well-formed rows written after it.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_TRIO))

    var stream = _copy_in(conn, String(COPY_TRIO_IN))
    _copy_write(stream, String(TRIO_SHORT_ROW))
    _copy_write(stream, String(TRIO_GOOD_ROWS))

    var failed = _copy_finish_error(stream)
    assert_true(failed.kind == PgErrorKind.SERVER)
    assert_equal(failed.sqlstate, String(BAD_COPY_SQLSTATE))
    _ = stream^

    # COPY is all-or-nothing, and the queue was drained before the raise.
    assert_equal(_count(conn, String(COUNT_TRIO)), 0)
    _assert_usable(conn)
    _ = conn^


# --- mid-stream disconnect -- (10) -------------------------------------------


def test_copy_in_after_the_socket_is_closed() raises:
    """A failed `write` is `CONNECTION`, and it ends the stream.

    Closing the descriptor under libpq is the one way to make a send fail
    while the server itself is fine. How many `write` calls fit between the
    close and the failure is a buffer size rather than a contract -- libpq
    buffers before it sends -- so the test writes until one fails and asserts
    only the kind. What *is* a contract is what comes after: the stream is
    finished, so the next `write` and `finish()` are both `USAGE`.

    Nothing may open a descriptor between the `close` and this connection's
    destructor, or `PQfinish` would close a file that belongs to someone else.
    That is why this half has a connection of its own and never queries again.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_PAIR))

    var stream = _copy_in(conn, String(COPY_PAIR_IN))
    _copy_write(stream, _pair_rows(0, PAIR_CHUNK))
    _copy_write(stream, _pair_rows(PAIR_CHUNK, PAIR_CHUNK))

    _ = external_call["close", c_int](
        c_int(Int(conn._pq[].PQsocket(conn._conn)))
    )

    var lost = _copy_write_until_connection_error(
        stream, _pair_rows(2 * PAIR_CHUNK, PAIR_CHUNK), 64
    )
    assert_true(lost.kind == PgErrorKind.CONNECTION)
    assert_equal(lost.sqlstate, "")

    var after = _copy_write_error(stream, String(PAIR_ROW_ONE))
    assert_true(after.kind == PgErrorKind.USAGE)
    assert_equal(after.message, String(ALREADY_FINISHED))

    var ended = _copy_finish_error(stream)
    assert_true(ended.kind == PgErrorKind.USAGE)
    assert_equal(ended.message, String(ALREADY_FINISHED))

    # The destructor is disarmed by the failed write, so it sends nothing.
    _ = stream^
    _ = conn^


def test_copy_out_after_the_socket_is_closed() raises:
    """A broken COPY OUT serves its buffer and then reports `CONNECTION`.

    libpq hands over whatever it had already read before the descriptor went
    away, and how much that is depends on buffer sizes rather than on
    anything this library promises, so the only assertion is that the loop
    ends -- inside a generous bound -- with a `CONNECTION` error rather than
    at the stream's own end or not at all.
    """
    var conn = _connect(_conninfo())

    var stream = _copy_out(conn, String(COPY_SERIES_OUT))
    var first = _copy_next(stream)
    assert_true(Bool(first))
    _ = first^

    _ = external_call["close", c_int](
        c_int(Int(conn._pq[].PQsocket(conn._conn)))
    )

    var lost = _copy_next_until_connection_error(stream, SERIES_LIMIT)
    assert_true(lost.kind == PgErrorKind.CONNECTION)
    assert_equal(lost.sqlstate, "")

    # The failed read disarmed the destructor, so it reads nothing further.
    _ = stream^
    _ = conn^


# --- the drain reaches past the COPY's own result -- (11) --------------------


def test_copy_in_drains_the_statement_behind_it() raises:
    """`COPY ... FROM STDIN; SELECT 42` leaves nothing queued.

    `finish()` returns the COPY's own result -- the `SELECT`'s arrives behind
    it -- and both are drained before the connection is handed back, so the
    next command does not meet a result it did not ask for.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_PAIR))

    var stream = _copy_in(conn, String(COPY_PAIR_THEN_SELECT))
    _copy_write(stream, String(PAIR_ROW_ONE))
    var result = _copy_finish(stream)
    assert_equal(result.affected_rows(), 1)
    _ = result^
    _ = stream^

    assert_equal(_count(conn, String(COUNT_PAIR)), 1)
    _assert_usable(conn)
    _ = conn^


# --- wrong direction and non-COPY statements -- (12) -------------------------


def test_copy_in_rejects_a_copy_to_stdout() raises:
    """A `COPY ... TO STDOUT` handed to `copy_in` is `USAGE`.

    The server accepted the statement, so the rejection is ours and names the
    `PGRES_*` status that came back. The output stream libpq opened is read
    away before the raise, which is what leaves the connection idle.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_PAIR))

    var error = _copy_in_error(conn, String(COPY_PAIR_OUT))
    assert_true(error.kind == PgErrorKind.USAGE)
    assert_equal(error.message, String(COPY_IN_WANTS_STDIN_FROM_COPY_OUT))
    assert_equal(error.sqlstate, "")

    _assert_usable(conn)
    _ = conn^


def test_copy_out_rejects_a_copy_from_stdin() raises:
    """A `COPY ... FROM STDIN` handed to `copy_out` is `USAGE`.

    The mirror image, and the cleanup is the mirror image too: there is no
    data to read in that direction, so the input stream is cancelled rather
    than drained.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_PAIR))

    var error = _copy_out_error(conn, String(COPY_PAIR_IN))
    assert_true(error.kind == PgErrorKind.USAGE)
    assert_equal(error.message, String(COPY_OUT_WANTS_STDOUT))
    assert_equal(error.sqlstate, "")

    assert_equal(_count(conn, String(COUNT_PAIR)), 0)
    _assert_usable(conn)
    _ = conn^


def test_copy_in_rejects_a_plain_select() raises:
    """A statement that is no COPY at all is `USAGE`, naming its status.

    `SELECT 1` comes back as `PGRES_TUPLES_OK`, status 2, so the message says
    so: the caller learns what the statement actually was rather than just
    that it was wrong.
    """
    var conn = _connect(_conninfo())

    var error = _copy_in_error(conn, String(SELECT_ONE))
    assert_true(error.kind == PgErrorKind.USAGE)
    assert_equal(error.message, String(COPY_IN_WANTS_STDIN_FROM_SELECT))
    assert_equal(error.sqlstate, "")

    _assert_usable(conn)
    _ = conn^


def test_copy_in_on_a_missing_table_is_a_server_error() raises:
    """A COPY the *server* rejects is `SERVER`, not `USAGE`.

    The direction check never runs: there is no result status to report,
    because the statement never got as far as opening a stream. Reporting this
    as `USAGE` would tell the caller to fix their call when what needs fixing
    is their schema.
    """
    var conn = _connect(_conninfo())

    var error = _copy_in_error(conn, String(COPY_MISSING_TABLE))
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.sqlstate, String(MISSING_TABLE_SQLSTATE))

    _assert_usable(conn)
    _ = conn^


# --- COPY inside a transaction block -- (13) ---------------------------------


def test_transaction_copy_in_commit_keeps_the_rows() raises:
    """Rows written through a block survive its `commit()`.

    The order of the last three lines is the whole test: `finish()` has to
    come before `commit()`, because the `COMMIT` is a command on the
    connection and a command on a connection with an open COPY is refused.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_PAIR))

    var tx = _transaction(conn)
    var stream = _tx_copy_in(tx, String(COPY_PAIR_IN))
    _copy_write(stream, String(PAIR_ROW_ONE))
    _copy_write(stream, String(PAIR_ROW_TWO))
    var result = _copy_finish(stream)
    assert_equal(result.affected_rows(), 2)
    _ = result^
    _ = stream^

    _tx_commit(tx)
    _ = tx^

    assert_equal(_count(conn, String(COUNT_PAIR)), 2)
    _assert_usable(conn)
    _ = conn^


def test_transaction_copy_in_rollback_loses_the_rows() raises:
    """The same sequence ending in `rollback()` keeps nothing.

    A COPY is not special to the transaction: its rows are undone exactly as
    an `INSERT`'s would be, even though the server already reported taking
    them from `finish()`.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_PAIR))

    var tx = _transaction(conn)
    var stream = _tx_copy_in(tx, String(COPY_PAIR_IN))
    _copy_write(stream, String(PAIR_ROW_ONE))
    _copy_write(stream, String(PAIR_ROW_TWO))
    var result = _copy_finish(stream)
    assert_equal(result.affected_rows(), 2)
    _ = result^
    _ = stream^

    _tx_rollback(tx)
    _ = tx^

    assert_equal(_count(conn, String(COUNT_PAIR)), 0)
    _assert_usable(conn)
    _ = conn^


def test_commit_during_a_copy_is_refused_and_the_block_stays_open() raises:
    """A `commit()` refused for an open COPY leaves the block usable.

    The `COMMIT` is a command on the connection, so it is refused like every
    other one -- and the refusal has to come *before* the block marks itself
    ended, or the `COMMIT` would be lost: nothing reached the server, yet no
    later `commit()` and no implicit `ROLLBACK` would ever be sent again and
    the transaction would stay open on the server with no way to close it
    through this API.

    So the contract is that `finish()` followed by `commit()` still works, and
    the rows are kept.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_PAIR))

    var tx = _transaction(conn)
    var stream = _tx_copy_in(tx, String(COPY_PAIR_IN))
    _copy_write(stream, String(PAIR_ROW_ONE))

    var refused = _tx_commit_error(tx)
    assert_true(refused.kind == PgErrorKind.USAGE)
    assert_equal(refused.message, String(COPY_IN_PROGRESS))

    var result = _copy_finish(stream)
    assert_equal(result.affected_rows(), 1)
    _ = result^
    _ = stream^

    _tx_commit(tx)
    _ = tx^

    assert_equal(_count(conn, String(COUNT_PAIR)), 1)
    _assert_usable(conn)
    _ = conn^


def test_rollback_during_a_copy_is_refused_and_the_block_stays_open() raises:
    """The same refusal for `rollback()`, which is then still available.

    `rollback()` is the one way out of a block whose statements failed, so
    losing it to a refused call would be worse than losing `commit()`: the
    destructor's implicit `ROLLBACK` is disarmed by the same flag.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_PAIR))

    var tx = _transaction(conn)
    var stream = _tx_copy_in(tx, String(COPY_PAIR_IN))
    _copy_write(stream, String(PAIR_ROW_ONE))

    var refused = _tx_rollback_error(tx)
    assert_true(refused.kind == PgErrorKind.USAGE)
    assert_equal(refused.message, String(COPY_IN_PROGRESS))

    var result = _copy_finish(stream)
    assert_equal(result.affected_rows(), 1)
    _ = result^
    _ = stream^

    _tx_rollback(tx)
    _ = tx^

    assert_equal(_count(conn, String(COUNT_PAIR)), 0)
    _assert_usable(conn)
    _ = conn^


# --- destruction order -- (14) -----------------------------------------------


def test_transaction_destroyed_before_its_copy_in() raises:
    """A block that dies first cancels the COPY underneath it, silently.

    A `CopyIn` from a `Transaction` carries the *connection's* origin, not the
    block's, so it is allowed to outlive the block -- and when it does, the
    block's implicit `ROLLBACK` goes out first. libpq ends the COPY to make
    room for it, so by the time the stream's own destructor runs there is no
    COPY in progress any more: it sees a connection that is no longer
    `PQTRANS_ACTIVE` and sends nothing. Cancelling anyway would draw libpq's
    `no COPY in progress`, which carries no SQLSTATE and would be reported to
    the handler -- a failure notice about a connection that is perfectly
    healthy.

    So the handler must stay untouched here, and the connection must be
    usable afterwards. It is a dedicated connection with a dedicated handler
    all the same, because the default handler prints to stderr and a
    regression here would be noise in every other test.
    """
    _ = setenv(String(HANDLER_CALLS_VAR), "", True)

    var conn = _connect(_conninfo())
    conn.set_rollback_failure_handler(_count_rollback_failure)
    _create(conn, String(CREATE_PAIR))

    var tx = _transaction(conn)
    var stream = _tx_copy_in(tx, String(COPY_PAIR_IN))
    _copy_write(stream, String(PAIR_ROW_ONE))

    # Last use of the block: the implicit ROLLBACK is sent here, and it ends
    # the COPY on its way through.
    _ = tx^

    # Last use of the stream, one line later: its destructor finds the COPY
    # already gone and leaves the connection alone.
    _ = stream^

    assert_equal(getenv(String(HANDLER_CALLS_VAR)), "")

    # Neither destructor left anything queued on the connection.
    assert_equal(_count(conn, String(COUNT_PAIR)), 0)
    _assert_usable(conn)
    _ = conn^


def test_transaction_destroyed_before_its_copy_out() raises:
    """The same order with a `CopyOut`, equally silent.

    The output stream's destructor would normally read the rest of the stream
    away, but the block's `ROLLBACK` has already ended the COPY, so there is
    nothing left to read and asking would report a failure on a healthy
    connection. The rows written earlier in the block go away with it.
    """
    _ = setenv(String(HANDLER_CALLS_VAR), "", True)

    var conn = _connect(_conninfo())
    conn.set_rollback_failure_handler(_count_rollback_failure)
    _create(conn, String(CREATE_PAIR))

    var tx = _transaction(conn)
    var fill = _tx_copy_in(tx, String(COPY_PAIR_IN))
    _copy_write(fill, String(PAIR_ROW_ONE))
    _copy_write(fill, String(PAIR_ROW_TWO))
    var written = _copy_finish(fill)
    assert_equal(written.affected_rows(), 2)
    _ = written^
    _ = fill^

    var stream = _tx_copy_out(tx, String(COPY_PAIR_OUT))
    var first = _copy_next(stream)
    assert_true(Bool(first))
    _ = first^

    # Last use of the block, then of the stream: the ROLLBACK ends the COPY
    # with one row still unread, and the stream's destructor leaves it alone.
    _ = tx^
    _ = stream^

    assert_equal(getenv(String(HANDLER_CALLS_VAR)), "")
    assert_equal(_count(conn, String(COUNT_PAIR)), 0)
    _assert_usable(conn)
    _ = conn^


# --- execute() still refuses a COPY statement -- (15) ------------------------


def test_execute_of_a_copy_from_stdin_is_a_server_error() raises:
    """`execute` keeps reporting `unexpected result status 4`.

    `COPY ... FROM STDIN` has no result rows to hand back and no stream to
    write to, so `execute` is the wrong door and says so. What changed is only
    the cleanup: the COPY libpq opened is ended before the raise, so the
    *next* `execute` succeeds instead of inheriting the mess.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_PAIR))

    var error = _execute_error(conn, String(COPY_PAIR_IN))
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.message, String(UNEXPECTED_COPY_IN))

    assert_equal(_count(conn, String(COUNT_PAIR)), 0)
    _assert_usable(conn)
    _ = conn^


def test_execute_of_a_copy_to_stdout_is_a_server_error() raises:
    """`execute` keeps reporting `unexpected result status 3`.

    The other direction, drained rather than cancelled, with the same promise
    about the next statement.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_PAIR))

    var stream = _copy_in(conn, String(COPY_PAIR_IN))
    _copy_write(stream, String(PAIR_ROW_ONE))
    var written = _copy_finish(stream)
    assert_equal(written.affected_rows(), 1)
    _ = written^
    _ = stream^

    var error = _execute_error(conn, String(COPY_PAIR_OUT))
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.message, String(UNEXPECTED_COPY_OUT))

    _assert_usable(conn)
    _ = conn^


# --- what a lost COPY leaves behind -- (16) ----------------------------------


def test_a_failed_write_leaves_a_connection_that_reports_connection() raises:
    """After a failed `write` the connection says `CONNECTION`, not `USAGE`.

    A `write` that fails ends the COPY on libpq's side as well, so the
    connection is idle again rather than stuck in `PQTRANS_ACTIVE` -- which is
    what the `USAGE` refusal reads as, and reporting `a COPY is in progress`
    for a connection whose socket is gone would send the caller looking for a
    stream to finish instead of for a connection to replace.

    `reset()` is the way back, and it works: the descriptor this test closed
    is free, so libpq reconnects into it.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_PAIR))

    var stream = _copy_in(conn, String(COPY_PAIR_IN))
    _copy_write(stream, _pair_rows(0, PAIR_CHUNK))

    _ = external_call["close", c_int](
        c_int(Int(conn._pq[].PQsocket(conn._conn)))
    )

    var lost = _copy_write_until_connection_error(
        stream, _pair_rows(PAIR_CHUNK, PAIR_CHUNK), 64
    )
    assert_true(lost.kind == PgErrorKind.CONNECTION)

    # The failed write disarmed the destructor, so it sends nothing.
    _ = stream^

    var after = _execute_error(conn, String(SELECT_ONE))
    assert_true(after.kind == PgErrorKind.CONNECTION)
    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))

    _reset(conn)
    _assert_usable(conn)
    _ = conn^


def test_finish_after_the_socket_is_closed_is_connection() raises:
    """A `finish()` on a closed socket reports `CONNECTION` and lets go.

    The writes before the `close` all succeeded -- libpq buffers them -- so
    this is the path where the failure surfaces from `finish()` rather than
    from a `write`, and it has to leave the same end state: the COPY ended,
    the connection idle, and the next command a `CONNECTION` error about the
    connection rather than a `USAGE` error about the stream.

    Nothing may open a descriptor between the `close` and this connection's
    destructor, so this half never reconnects.
    """
    var conn = _connect(_conninfo())
    _create(conn, String(CREATE_PAIR))

    var stream = _copy_in(conn, String(COPY_PAIR_IN))
    _copy_write(stream, _pair_rows(0, PAIR_CHUNK))
    _copy_write(stream, _pair_rows(PAIR_CHUNK, PAIR_CHUNK))

    _ = external_call["close", c_int](
        c_int(Int(conn._pq[].PQsocket(conn._conn)))
    )

    var lost = _copy_finish_error(stream)
    assert_true(lost.kind == PgErrorKind.CONNECTION)
    _ = stream^

    var after = _execute_error(conn, String(SELECT_ONE))
    assert_true(after.kind == PgErrorKind.CONNECTION)
    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))
    _ = conn^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
