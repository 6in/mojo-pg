"""Tests for `pq.transaction` and the `Connection.transaction` factory.

Fixes the observable contract of an RAII transaction block: `transaction()`
sends the `BEGIN` while it builds the `Transaction`, `commit()` and
`rollback()` end it exactly once, every other method delegates to the
connection it views, and destruction of a block that was never ended sends a
`ROLLBACK`.

Three properties get their own tests because they are the easy ones to break.
First, the entry condition is checked on the connection itself: a dead
connection is a `CONNECTION` error (not a `USAGE` one), while a live
connection that is already inside a block -- or inside an aborted block --
is a `USAGE` error naming the libpq transaction status it saw. Second,
destruction is ASAP: a `Transaction` dies right after the last line that
uses it, not at the end of the enclosing scope, so the implicit `ROLLBACK`
can land earlier than a reader expects; `_ = tx^` is the marker that keeps
the block alive up to that line, it does not destroy it early. Third, the
implicit `ROLLBACK` cannot raise from a destructor, so its failure is routed
to the handler installed with `Connection.set_rollback_failure_handler`, and
that handler is copied when the `Transaction` is created -- replacing it
afterwards cannot change where an already-open block reports to.

`COMMIT` on an aborted block is the one case where the server answers a
`COMMIT` with a `ROLLBACK` command tag instead of an error. That is reported
as a `SERVER` error with an empty `sqlstate`, because there is no server
diagnostic behind it: nothing failed, the transaction had simply already
been undone.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI), falling back to the local container. An unreachable
server fails these tests; it never skips them. Every test must pass against
both PG14 and PG17, so nothing here depends on version-specific wording:
only SQLSTATEs, transaction statuses, our own messages and values are
asserted.

Every test creates its own `CREATE TEMP TABLE pq_p2_tx`, which keeps the
table inside the session, so two test processes -- or the two server
versions -- never collide on the name. The tests that kill their own backend
each use their own connection, and so does every test that installs a
rollback-failure handler, which keeps the handler out of the other tests.
"""

from std.os import getenv, setenv
from std.testing import TestSuite, assert_equal, assert_true

from pq._ffi.types import PQTRANS_IDLE, PQTRANS_INERROR, PQTRANS_INTRANS
from pq.connection import Connection
from pq.errors import PgError, PgErrorKind
from pq.params import Param
from pq.prepared import PreparedStatement
from pq.result import Result, Row
from pq.transaction import Transaction

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime CREATE_TABLE: StaticString = "CREATE TEMP TABLE pq_p2_tx(x int)"
"""The one-column table every test writes to.

`TEMP` keeps it in the session that created it, so the name is free to be
reused by a concurrent test process and by the other server version.
"""

comptime INSERT_ONE: StaticString = "INSERT INTO pq_p2_tx VALUES (1)"
"""An unparameterised write, used to give a block something to undo."""

comptime INSERT_PARAM: StaticString = "INSERT INTO pq_p2_tx VALUES ($1)"
"""The same write with its value bound, for the parameterised delegation."""

comptime COUNT_SQL: StaticString = "SELECT count(*) FROM pq_p2_tx"
"""Counts what survived: 1 after a commit, 0 after any kind of rollback."""

comptime ONE_INT_SQL: StaticString = "SELECT $1::int4"
"""The smallest statement worth preparing through a `Transaction`."""

comptime DIVIDE_BY_ZERO_SQL: StaticString = "SELECT 1 / 0"
"""Aborts the block it runs in with 22012, without closing it."""

comptime TERMINATE_SQL: StaticString = (
    "SELECT pg_terminate_backend(pg_backend_pid())"
)
"""Kills the backend of the connection that runs it.

The command itself is reported as a `CONNECTION` error, and every later use
of the connection -- including the `ROLLBACK` sent from a destructor -- has
no socket left to travel on.
"""

comptime ALREADY_ENDED: StaticString = "transaction already ended"
"""The message of the `USAGE` error every method raises after the end."""

comptime IDLE_REQUIRED_PREFIX: StaticString = (
    "transaction() requires an idle connection (transaction status "
)
"""Everything before the status number in the nesting-rejection message."""

comptime ROLLBACK_OF_ABORTED: StaticString = (
    "COMMIT resulted in ROLLBACK: the transaction was aborted"
)
"""What `commit()` reports when the server answers with a ROLLBACK tag."""

comptime ROLLBACK_FAILURE_VAR: StaticString = "PQ_TEST_ROLLBACK_FAILURE"
"""Environment variable the test handlers record their call in.

A rollback-failure handler cannot raise and returns nothing, so it has no
way to hand an observation back to the test by value. Writing to the
environment is the smallest channel that survives the destructor it is
called from.
"""

comptime CONNECTION_PREFIX: StaticString = "Connection|"
"""What `_record_rollback_failure` writes for a `CONNECTION` error.

The kind is spelled out by the handler rather than taken from a `PgError`
conversion, so the assertion does not depend on how a kind prints.
"""

comptime FIRST_CONNECTION_PREFIX: StaticString = "first|Connection|"
"""What the first of the two numbered handlers writes."""


# --- helpers -----------------------------------------------------------------
#
# A `TestSuite` test only declares `raises` (plain `Error`), and `PgError` does
# not implicitly convert to `Error`, so a `raises PgError` API cannot be called
# straight from a test. These wrappers translate in both directions: success
# paths re-raise as `Error`, failure paths hand the `PgError` back for
# inspection. Helpers are per file by convention; nothing here is shared with
# `test_savepoint.mojo` or `test_prepared.mojo`.
#
# Every `Transaction` wrapper takes `mut tx`, which is what `commit` and
# `rollback` need; the delegating methods are happy with less.


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


def _transaction(conn: Connection) raises -> Transaction[origin_of(conn)]:
    """Begin a transaction block on `conn`.

    The returned block is a view onto the connection: its `origin` parameter
    ties it to `conn`, so the compiler keeps the connection alive for as long
    as the block is reachable.

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


def _tx_commit_error[
    origin: ImmOrigin, //
](mut tx: Transaction[origin]) raises -> PgError:
    """Return the `PgError` raised by `tx.commit()`.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: A block whose commit must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `commit` succeeded instead of raising.
    """
    try:
        tx.commit()
    except e:
        return e.copy()
    raise Error("expected a PgError from Transaction.commit()")


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


def _tx_rollback_error[
    origin: ImmOrigin, //
](mut tx: Transaction[origin]) raises -> PgError:
    """Return the `PgError` raised by `tx.rollback()`.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: A block whose rollback must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `rollback` succeeded instead of raising.
    """
    try:
        tx.rollback()
    except e:
        return e.copy()
    raise Error("expected a PgError from Transaction.rollback()")


def _tx_execute[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var sql: String) raises -> Result:
    """Run `sql` inside `tx` without parameters.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The open transaction block.
        sql: The statement to run.

    Returns:
        The result of the statement.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    try:
        return tx.execute(sql^)
    except e:
        raise Error(String(e))


def _tx_execute_error[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var sql: String) raises -> PgError:
    """Return the `PgError` raised by `tx.execute(sql)`.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The transaction block to run on.
        sql: A statement that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `execute` returned a result instead of raising.
    """
    try:
        var result = tx.execute(sql^)
        _ = result^
    except e:
        return e.copy()
    raise Error("expected a PgError from Transaction.execute(sql)")


def _tx_execute_params[
    origin: ImmOrigin, //
](
    mut tx: Transaction[origin], var sql: String, params: List[Param]
) raises -> Result:
    """Run `sql` inside `tx` with bound parameters.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The open transaction block.
        sql: The single statement to run.
        params: The values bound to `$1`, `$2`, ... in order.

    Returns:
        The result of the statement.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    try:
        return tx.execute(sql^, params)
    except e:
        raise Error(String(e))


def _tx_execute_params_error[
    origin: ImmOrigin, //
](
    mut tx: Transaction[origin], var sql: String, params: List[Param]
) raises -> PgError:
    """Return the `PgError` raised by `tx.execute(sql, params)`.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The transaction block to run on.
        sql: A statement that must be rejected.
        params: The values bound to `$1`, `$2`, ... in order.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `execute` returned a result instead of raising.
    """
    try:
        var result = tx.execute(sql^, params)
        _ = result^
    except e:
        return e.copy()
    raise Error("expected a PgError from Transaction.execute(sql, params)")


def _tx_prepare[
    origin: ImmOrigin, //
](
    mut tx: Transaction[origin],
    var sql: String,
    param_types: List[UInt32] = List[UInt32](),
) raises -> PreparedStatement[origin]:
    """Prepare `sql` through `tx`.

    The statement belongs to the connection, not to the block: its `origin`
    is the one the block itself views, which is what lets it outlive the
    block the way a server-side `PREPARE` does.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The open transaction block.
        sql: The single statement to prepare.
        param_types: Type OIDs for `$1`, `$2`, ...; empty means "infer".

    Returns:
        The prepared statement.

    Raises:
        Error: If `prepare` raised a `PgError`.
    """
    try:
        return tx.prepare(sql^, param_types)
    except e:
        raise Error(String(e))


def _tx_prepare_error[
    origin: ImmOrigin, //
](
    mut tx: Transaction[origin],
    var sql: String,
    param_types: List[UInt32] = List[UInt32](),
) raises -> PgError:
    """Return the `PgError` raised by `tx.prepare(sql, param_types)`.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The transaction block to prepare on.
        sql: A statement whose preparation must be rejected.
        param_types: Type OIDs for `$1`, `$2`, ...; empty means "infer".

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `prepare` returned a statement instead of raising.
    """
    try:
        var stmt = tx.prepare(sql^, param_types)
        _ = stmt^
    except e:
        return e.copy()
    raise Error("expected a PgError from Transaction.prepare(sql)")


def _tx_savepoint_error[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var name: String) raises -> PgError:
    """Return the `PgError` raised by `tx.savepoint(name)`.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The transaction block to mark.
        name: A savepoint name that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `savepoint` succeeded instead of raising.
    """
    try:
        tx.savepoint(name^)
    except e:
        return e.copy()
    raise Error("expected a PgError from Transaction.savepoint(name)")


def _tx_rollback_to_error[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var name: String) raises -> PgError:
    """Return the `PgError` raised by `tx.rollback_to(name)`.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The transaction block to rewind.
        name: A savepoint name that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `rollback_to` succeeded instead of raising.
    """
    try:
        tx.rollback_to(name^)
    except e:
        return e.copy()
    raise Error("expected a PgError from Transaction.rollback_to(name)")


def _tx_release_error[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var name: String) raises -> PgError:
    """Return the `PgError` raised by `tx.release(name)`.

    Parameters:
        origin: Origin of the `Connection` the block views; inferred.

    Args:
        tx: The transaction block to release a mark on.
        name: A savepoint name that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `release` succeeded instead of raising.
    """
    try:
        tx.release(name^)
    except e:
        return e.copy()
    raise Error("expected a PgError from Transaction.release(name)")


def _stmt_execute[
    origin: ImmOrigin, //
](stmt: PreparedStatement[origin], params: List[Param]) raises -> Result:
    """Execute `stmt` with bound parameters.

    Parameters:
        origin: Origin of the `Connection` the statement views; inferred.

    Args:
        stmt: The prepared statement to run.
        params: The values bound to `$1`, `$2`, ... in order.

    Returns:
        The result of the statement.

    Raises:
        Error: If `PreparedStatement.execute` raised a `PgError`.
    """
    try:
        return stmt.execute(params)
    except e:
        raise Error(String(e))


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


def _create_table(conn: Connection) raises:
    """Create this file's `TEMP` table on `conn`.

    Args:
        conn: The connection whose session gets the table.

    Raises:
        Error: If the `CREATE` raised a `PgError`.
    """
    var created = _execute(conn, String(CREATE_TABLE))
    _ = created^


def _count(conn: Connection) raises -> Int:
    """Count the rows currently visible in `pq_p2_tx`.

    Args:
        conn: The connection whose session owns the table.

    Returns:
        The number of rows that survived.

    Raises:
        Error: If the query or the decoding raised a `PgError`.
    """
    var result = _execute(conn, String(COUNT_SQL))
    var row = _row(result, 0)
    var count = _get[Int64](row, 0)
    _ = row^
    _ = result^
    return Int(count)


def _idle_required_message(status: Int) -> String:
    """Return the nesting-rejection message for a transaction `status`.

    Building the message from the libpq constant rather than from a literal
    keeps the expectation honest about *which* status was refused.

    Args:
        status: The libpq transaction status the connection was in.

    Returns:
        The full expected `USAGE` message.
    """
    return String(IDLE_REQUIRED_PREFIX) + String(status) + ")"


# --- rollback-failure handlers -----------------------------------------------
#
# These are non-capturing top-level functions, which is what the `thin`
# handler type asks for. A handler has no way to report anything by raising,
# which is why each one writes what it saw into the environment instead. The
# kind is spelled out here rather than taken from a `PgError` conversion, so
# the assertions do not depend on how a kind prints.


def _record_rollback_failure(error: PgError):
    """Record a rollback failure, tagged with its kind.

    Args:
        error: The `PgError` the implicit `ROLLBACK` produced.
    """
    var kind = (
        "Connection|" if error.kind == PgErrorKind.CONNECTION else "Other|"
    )
    _ = setenv(String(ROLLBACK_FAILURE_VAR), kind + error.message, True)


def _record_as_first(error: PgError):
    """Record a rollback failure behind a `first|` tag.

    Args:
        error: The `PgError` the implicit `ROLLBACK` produced.
    """
    var kind = (
        "Connection|" if error.kind == PgErrorKind.CONNECTION else "Other|"
    )
    _ = setenv(
        String(ROLLBACK_FAILURE_VAR), "first|" + kind + error.message, True
    )


def _record_as_second(error: PgError):
    """Record a rollback failure behind a `second|` tag.

    Args:
        error: The `PgError` the implicit `ROLLBACK` produced.
    """
    var kind = (
        "Connection|" if error.kind == PgErrorKind.CONNECTION else "Other|"
    )
    _ = setenv(
        String(ROLLBACK_FAILURE_VAR), "second|" + kind + error.message, True
    )


# --- commit -- (b)-1 ---------------------------------------------------------


def test_commit_persists_and_only_happens_once() raises:
    """`commit()` opens in INTRANS, keeps the write, and ends the block."""
    var conn = _connect(_conninfo())
    _create_table(conn)

    var tx = _transaction(conn)
    # The BEGIN went out while the block was being built.
    assert_equal(conn.transaction_status(), Int(PQTRANS_INTRANS))

    var inserted = _tx_execute(tx, String(INSERT_ONE))
    assert_equal(inserted.affected_rows(), 1)
    _ = inserted^

    _tx_commit(tx)
    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))
    assert_equal(_count(conn), 1)

    # The ended flag is set before the COMMIT is sent, so a second attempt is
    # refused locally rather than reaching a connection that is now idle.
    var again = _tx_commit_error(tx)
    assert_true(again.kind == PgErrorKind.USAGE)
    assert_equal(again.message, String(ALREADY_ENDED))
    assert_equal(again.sqlstate, "")

    _ = tx^
    _ = conn^


# --- rollback -- (b)-2 -------------------------------------------------------


def test_rollback_discards_and_only_happens_once() raises:
    """`rollback()` undoes the write and refuses to run twice."""
    var conn = _connect(_conninfo())
    _create_table(conn)

    var tx = _transaction(conn)
    var inserted = _tx_execute(tx, String(INSERT_ONE))
    assert_equal(inserted.affected_rows(), 1)
    _ = inserted^

    _tx_rollback(tx)
    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))
    assert_equal(_count(conn), 0)

    var again = _tx_rollback_error(tx)
    assert_true(again.kind == PgErrorKind.USAGE)
    assert_equal(again.message, String(ALREADY_ENDED))

    _ = tx^
    _ = conn^


def test_rollback_after_commit_is_usage() raises:
    """The ended flag is shared: a committed block cannot be rolled back."""
    var conn = _connect(_conninfo())
    _create_table(conn)

    var tx = _transaction(conn)
    var inserted = _tx_execute(tx, String(INSERT_ONE))
    _ = inserted^
    _tx_commit(tx)

    var error = _tx_rollback_error(tx)
    assert_true(error.kind == PgErrorKind.USAGE)
    assert_equal(error.message, String(ALREADY_ENDED))

    # The commit still stands; the refused rollback changed nothing.
    assert_equal(_count(conn), 1)

    _ = tx^
    _ = conn^


# --- destruction without an end sends ROLLBACK -- (b)-3 ----------------------


def test_drop_without_commit_rolls_back() raises:
    """A block that is never ended undoes its work when it dies."""
    var conn = _connect(_conninfo())
    _create_table(conn)

    var tx = _transaction(conn)
    var inserted = _tx_execute(tx, String(INSERT_ONE))
    assert_equal(inserted.affected_rows(), 1)
    _ = inserted^

    # The marker keeps the block alive to here; past it the destructor has
    # run, so the ROLLBACK has already been sent.
    _ = tx^

    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))
    assert_equal(_count(conn), 0)

    _ = conn^


# --- destruction is ASAP, not end of scope -- (b)-4 --------------------------


def test_destruction_is_asap_not_end_of_scope() raises:
    """The implicit ROLLBACK lands right after the block's last use.

    This is Mojo's ASAP destruction, and it is the negative example from the
    `Transaction` docstring: without a `_ = tx^` marker the block below is
    already gone one line after its last use, so the row is undone before the
    scope ends. The chained call is deliberate -- it leaves no later mention
    of `tx` to extend its life.
    """
    var conn = _connect(_conninfo())
    _create_table(conn)

    var tx = _transaction(conn)
    assert_equal(_tx_execute(tx, String(INSERT_ONE)).affected_rows(), 1)

    # `tx` died on the line above, so this sees an idle connection and an
    # empty table even though the enclosing scope has not ended.
    assert_equal(_count(conn), 0)
    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))

    _ = conn^


# --- delegation to the connection -- (b)-5 -----------------------------------


def test_execute_and_prepare_delegate_to_the_connection() raises:
    """Parameterised execute and prepare both run through the block.

    The connection stays usable directly while the block is open, and stays
    in INTRANS throughout: a `Transaction` adds a guard, not a second
    channel.
    """
    var conn = _connect(_conninfo())
    _create_table(conn)

    var tx = _transaction(conn)

    # `conn.execute(sql, params)` sends the type OIDs alongside the values,
    # so an `Int` parameter would be accepted here too.
    var params: List[Param] = [Int32(2)]
    var inserted = _tx_execute_params(tx, String(INSERT_PARAM), params)
    assert_equal(inserted.affected_rows(), 1)
    _ = inserted^

    # `PQexecPrepared` carries no type OIDs, so the value has to match the
    # declared int4: `Param(Int)` would go out as int8 and fail with 22P03.
    var stmt = _tx_prepare(tx, String(ONE_INT_SQL))
    assert_equal(stmt.param_count(), 1)
    var bound: List[Param] = [Int32(3)]
    var result = _stmt_execute(stmt, bound)
    assert_equal(result.row_count(), 1)
    var row = _row(result, 0)
    assert_equal(_get[Int32](row, 0), Int32(3))
    _ = row^
    _ = result^
    _ = stmt^

    # The connection underneath is not locked out by the open block.
    var direct = _execute(conn, "SELECT 1")
    assert_equal(direct.row_count(), 1)
    _ = direct^
    assert_equal(conn.transaction_status(), Int(PQTRANS_INTRANS))

    _tx_commit(tx)
    assert_equal(_count(conn), 1)

    _ = tx^
    _ = conn^


# --- no nesting -- (b)-6 -----------------------------------------------------


def test_nested_transaction_is_rejected() raises:
    """A second block is refused, in INTRANS and in INERROR alike.

    The check reads the libpq transaction status, so it also catches a block
    that was opened by hand with `conn.execute("BEGIN")` rather than through
    `transaction()`.
    """
    var conn = _connect(_conninfo())

    var tx = _transaction(conn)
    assert_equal(conn.transaction_status(), Int(PQTRANS_INTRANS))

    var nested = _transaction_error(conn)
    assert_true(nested.kind == PgErrorKind.USAGE)
    assert_equal(nested.message, _idle_required_message(Int(PQTRANS_INTRANS)))
    assert_equal(nested.sqlstate, "")

    # Keeps the first block alive across the rejection above; past this the
    # implicit ROLLBACK has run and the connection is idle again.
    _ = tx^
    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))

    # Same refusal for a hand-opened block that has been aborted.
    var begun = _execute(conn, "BEGIN")
    _ = begun^
    var broken = _execute_error(conn, "SELEC")
    assert_true(broken.kind == PgErrorKind.SERVER)
    assert_equal(conn.transaction_status(), Int(PQTRANS_INERROR))

    var in_error = _transaction_error(conn)
    assert_true(in_error.kind == PgErrorKind.USAGE)
    assert_equal(in_error.message, _idle_required_message(Int(PQTRANS_INERROR)))

    var rolled_back = _execute(conn, "ROLLBACK")
    _ = rolled_back^
    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))

    _ = conn^


# --- every method refuses after the end -- (b)-7 -----------------------------


def test_every_method_after_the_end_is_usage() raises:
    """All six delegating methods report `transaction already ended`."""
    var conn = _connect(_conninfo())
    _create_table(conn)

    var tx = _transaction(conn)
    _tx_commit(tx)

    var executed = _tx_execute_error(tx, String(INSERT_ONE))
    assert_true(executed.kind == PgErrorKind.USAGE)
    assert_equal(executed.message, String(ALREADY_ENDED))

    var params: List[Param] = [Int32(2)]
    var bound = _tx_execute_params_error(tx, String(INSERT_PARAM), params)
    assert_true(bound.kind == PgErrorKind.USAGE)
    assert_equal(bound.message, String(ALREADY_ENDED))

    var prepared = _tx_prepare_error(tx, String(ONE_INT_SQL))
    assert_true(prepared.kind == PgErrorKind.USAGE)
    assert_equal(prepared.message, String(ALREADY_ENDED))

    var marked = _tx_savepoint_error(tx, "a")
    assert_true(marked.kind == PgErrorKind.USAGE)
    assert_equal(marked.message, String(ALREADY_ENDED))

    var rewound = _tx_rollback_to_error(tx, "a")
    assert_true(rewound.kind == PgErrorKind.USAGE)
    assert_equal(rewound.message, String(ALREADY_ENDED))

    var released = _tx_release_error(tx, "a")
    assert_true(released.kind == PgErrorKind.USAGE)
    assert_equal(released.message, String(ALREADY_ENDED))

    # None of the six reached the server: the table is still empty and the
    # connection is still idle.
    assert_equal(_count(conn), 0)
    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))

    _ = tx^
    _ = conn^


# --- committing an aborted block -- (b)-8 ------------------------------------


def test_commit_of_an_aborted_block_reports_the_rollback() raises:
    """A COMMIT the server answers with a ROLLBACK tag is a SERVER error.

    Nothing failed at commit time -- the block had already been undone -- so
    there is no diagnostic behind the error and `sqlstate` stays empty. The
    block still counts as ended afterwards.
    """
    var conn = _connect(_conninfo())
    _create_table(conn)

    var tx = _transaction(conn)
    var inserted = _tx_execute(tx, String(INSERT_ONE))
    assert_equal(inserted.affected_rows(), 1)
    _ = inserted^

    var divided = _tx_execute_error(tx, String(DIVIDE_BY_ZERO_SQL))
    assert_true(divided.kind == PgErrorKind.SERVER)
    assert_equal(divided.sqlstate, "22012")
    assert_equal(conn.transaction_status(), Int(PQTRANS_INERROR))

    var failed = _tx_commit_error(tx)
    assert_true(failed.kind == PgErrorKind.SERVER)
    assert_equal(failed.sqlstate, "")
    assert_equal(failed.message, String(ROLLBACK_OF_ABORTED))

    # The block is closed either way, and the write is gone with it.
    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))
    assert_equal(_count(conn), 0)

    # The ended flag was set before the COMMIT went out, so the failure does
    # not leave the block open for a retry.
    var after = _tx_rollback_error(tx)
    assert_true(after.kind == PgErrorKind.USAGE)
    assert_equal(after.message, String(ALREADY_ENDED))

    _ = tx^
    _ = conn^


# --- the handler sees a failed implicit ROLLBACK -- (b)-9 --------------------


def test_rollback_failure_handler_runs_on_a_dead_connection() raises:
    """A destructor's ROLLBACK that cannot be sent reaches the handler."""
    _ = setenv(String(ROLLBACK_FAILURE_VAR), "", True)

    var conn = _connect(_conninfo())
    conn.set_rollback_failure_handler(_record_rollback_failure)

    var tx = _transaction(conn)

    # Killing our own backend is reported, not swallowed.
    var terminated = _execute_error(conn, String(TERMINATE_SQL))
    assert_true(terminated.kind == PgErrorKind.CONNECTION)
    _ = terminated^

    # There is no socket left for the implicit ROLLBACK, and a destructor
    # cannot raise, so the failure can only come out through the handler.
    _ = tx^

    var recorded = getenv(String(ROLLBACK_FAILURE_VAR))
    assert_true(recorded.startswith(CONNECTION_PREFIX))
    # libpq has something to say about it ("no connection to the server"),
    # whatever the exact wording on this version.
    assert_true(
        recorded.byte_length() > String(CONNECTION_PREFIX).byte_length()
    )

    _ = conn^


# --- the handler is copied when the block begins -- (b)-10 -------------------


def test_handler_is_copied_when_the_block_begins() raises:
    """Replacing the handler cannot redirect an already-open block."""
    _ = setenv(String(ROLLBACK_FAILURE_VAR), "", True)

    var conn = _connect(_conninfo())
    conn.set_rollback_failure_handler(_record_as_first)

    var tx = _transaction(conn)

    # The block took its own copy above, so this only affects blocks opened
    # from here on -- of which there are none.
    conn.set_rollback_failure_handler(_record_as_second)

    var terminated = _execute_error(conn, String(TERMINATE_SQL))
    assert_true(terminated.kind == PgErrorKind.CONNECTION)
    _ = terminated^

    _ = tx^

    var recorded = getenv(String(ROLLBACK_FAILURE_VAR))
    assert_true(recorded.startswith(FIRST_CONNECTION_PREFIX))
    assert_true(recorded.find("second|") < 0)

    _ = conn^


# --- the entry check reads the connection first -- (b)-11 --------------------


def test_transaction_on_a_dead_connection_is_a_connection_error() raises:
    """A dead connection is a CONNECTION error, not a USAGE one.

    `PQstatus` is consulted before the transaction status, so the caller
    hears about the real problem instead of being told the connection is not
    idle.
    """
    var conn = _connect(_conninfo())

    var terminated = _execute_error(conn, String(TERMINATE_SQL))
    assert_true(terminated.kind == PgErrorKind.CONNECTION)
    _ = terminated^

    var error = _transaction_error(conn)
    assert_true(error.kind == PgErrorKind.CONNECTION)

    _ = conn^


# --- the default handler stays quiet -- (b)-12 -------------------------------


def test_default_handler_stays_quiet_on_the_good_paths() raises:
    """None of the three succeeding paths reaches the failure handler.

    The default handler prints `pq: implicit ROLLBACK failed: ...` to stderr,
    so a commit, a rollback and a clean implicit rollback must all leave it
    uncalled. The handler is left at its default here on purpose; stderr is
    not captured in-process -- the harness counts those lines.
    """
    var conn = _connect(_conninfo())
    _create_table(conn)

    # Path one: an explicit commit.
    var committed = _transaction(conn)
    var first_insert = _tx_execute(committed, String(INSERT_ONE))
    _ = first_insert^
    _tx_commit(committed)
    assert_equal(_count(conn), 1)
    _ = committed^

    # Path two: an explicit rollback.
    var rolled_back = _transaction(conn)
    var second_insert = _tx_execute(rolled_back, String(INSERT_ONE))
    _ = second_insert^
    _tx_rollback(rolled_back)
    assert_equal(_count(conn), 1)
    _ = rolled_back^

    # Path three: destruction over a live connection, where the implicit
    # ROLLBACK succeeds and so has nothing to report.
    var dropped = _transaction(conn)
    var third_insert = _tx_execute(dropped, String(INSERT_ONE))
    _ = third_insert^
    _ = dropped^
    assert_equal(_count(conn), 1)
    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))

    _ = conn^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
