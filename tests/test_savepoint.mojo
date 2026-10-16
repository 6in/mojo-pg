"""Tests for the savepoint half of `pq.transaction`.

Fixes the observable contract of `Transaction.savepoint`,
`Transaction.rollback_to` and `Transaction.release`: names go through
`Connection.escape_identifier` before they are spliced into `SAVEPOINT`,
`ROLLBACK TO SAVEPOINT` and `RELEASE SAVEPOINT`, so a name containing a
double quote is usable and a name containing upper case keeps its case; an
empty name is refused locally, *before* anything is written to the socket;
and a name the server does not know is left to the server, which answers
3B001.

Two behaviours are worth stating because they are easy to break by
accident. First, the subtransaction a savepoint opens is what makes an
aborted block recoverable: after a failed statement the block is in
`PQTRANS_INERROR` and refuses everything with 25P02, and `rollback_to`
brings it back to `PQTRANS_INTRANS` so the transaction can still commit.
Second, destruction is ASAP: a `Transaction` dies right after the last line
that uses it and sends `ROLLBACK` unless it was already finished, which is
why every test here observes `transaction_status` *before* the `_ = tx^`
marker. That marker keeps the transaction alive up to that point; it does
not end it early.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI), falling back to the local container. An unreachable
server fails these tests; it never skips them. Every test must pass against
both PG14 and PG17, so nothing here depends on version-specific wording:
only SQLSTATEs, the locally produced message and values are asserted.

Every table is created as `CREATE TEMP TABLE pq_p2_<name>`, which keeps it
inside the session, so two test processes -- or the two server versions --
never collide on a name.
"""

from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_true

from pq._ffi.types import PQTRANS_IDLE, PQTRANS_INERROR, PQTRANS_INTRANS
from pq.connection import Connection
from pq.errors import PgError, PgErrorKind
from pq.result import Result, Row
from pq.transaction import Transaction

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime EMPTY_NAME_MESSAGE: StaticString = "savepoint name must not be empty"
"""The message of the local rejection of an empty savepoint name.

This one string is asserted verbatim because it is produced here rather
than by the server, so it is the same under PG14 and PG17.
"""

comptime NUL_NAME_MESSAGE: StaticString = "embedded NUL byte in name"
"""The message of the local rejection of a savepoint name holding a NUL byte.

The argument is named `name`, not the parameter of the quoting helper the
name would otherwise reach first.
"""

comptime NUL_MARKER: StaticString = "AFTER_NUL_MARKER"
"""Text placed *after* an embedded NUL byte in a rejected savepoint name.

libpq takes C strings, so everything from the NUL onwards would be invisible
to it; the marker shows the truncated tail never reaches the message either.
"""

comptime NO_SUCH_SAVEPOINT: StaticString = "3B001"
"""`invalid_savepoint_specification`: the name is not an open savepoint."""

comptime IN_FAILED_TRANSACTION: StaticString = "25P02"
"""`in_failed_sql_transaction`: the block is aborted and refuses commands."""

comptime DIVISION_BY_ZERO: StaticString = "22012"
"""`division_by_zero`: the cheapest way to abort an open block."""

comptime QUOTED_NAME: StaticString = 'sp "1"'
"""A savepoint name holding a double quote.

Only `PQescapeIdentifier` makes this usable: it wraps the name in double
quotes and doubles the inner one.
"""

comptime MIXED_CASE_NAME: StaticString = "Sp"
"""A savepoint name holding upper case.

An unquoted identifier would be folded to `sp` by the server, so the fact
that this name can be referenced again as written is what shows the
identifier was quoted.
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
# The `Transaction` wrappers take `mut tx` because `commit` and `rollback` are
# `mut self`; the read-only calls are happy with a mutable binding too.


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


def _transaction(conn: Connection) raises -> Transaction[origin_of(conn)]:
    """Begin a transaction on `conn`.

    The returned transaction is a view onto the connection: its `origin`
    parameter ties it to `conn`, so the compiler keeps the connection alive
    for as long as the transaction is reachable.

    Args:
        conn: An open connection.

    Returns:
        The open transaction, with `BEGIN` already sent.

    Raises:
        Error: If `transaction` raised a `PgError`.
    """
    try:
        return conn.transaction()
    except e:
        raise Error(String(e))


def _tx_execute[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var sql: String) raises -> Result:
    """Run `sql` inside `tx`.

    Parameters:
        origin: Origin of the `Connection` the transaction views; inferred.

    Args:
        tx: The open transaction.
        sql: The statement to run.

    Returns:
        The result of the statement.

    Raises:
        Error: If `Transaction.execute` raised a `PgError`.
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
        origin: Origin of the `Connection` the transaction views; inferred.

    Args:
        tx: The open transaction.
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


def _commit[origin: ImmOrigin, //](mut tx: Transaction[origin]) raises:
    """Commit `tx`.

    Parameters:
        origin: Origin of the `Connection` the transaction views; inferred.

    Args:
        tx: The open transaction.

    Raises:
        Error: If `Transaction.commit` raised a `PgError`.
    """
    try:
        tx.commit()
    except e:
        raise Error(String(e))


def _rollback[origin: ImmOrigin, //](mut tx: Transaction[origin]) raises:
    """Roll `tx` back.

    Parameters:
        origin: Origin of the `Connection` the transaction views; inferred.

    Args:
        tx: The open transaction.

    Raises:
        Error: If `Transaction.rollback` raised a `PgError`.
    """
    try:
        tx.rollback()
    except e:
        raise Error(String(e))


def _savepoint[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var name: String) raises:
    """Open savepoint `name` inside `tx`.

    Parameters:
        origin: Origin of the `Connection` the transaction views; inferred.

    Args:
        tx: The open transaction.
        name: The savepoint name, used unquoted by the caller.

    Raises:
        Error: If `Transaction.savepoint` raised a `PgError`.
    """
    try:
        tx.savepoint(name^)
    except e:
        raise Error(String(e))


def _savepoint_error[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var name: String) raises -> PgError:
    """Return the `PgError` raised by `tx.savepoint(name)`.

    Parameters:
        origin: Origin of the `Connection` the transaction views; inferred.

    Args:
        tx: The open transaction.
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


def _rollback_to[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var name: String) raises:
    """Roll `tx` back to savepoint `name`.

    Parameters:
        origin: Origin of the `Connection` the transaction views; inferred.

    Args:
        tx: The open transaction.
        name: The savepoint name, used unquoted by the caller.

    Raises:
        Error: If `Transaction.rollback_to` raised a `PgError`.
    """
    try:
        tx.rollback_to(name^)
    except e:
        raise Error(String(e))


def _rollback_to_error[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var name: String) raises -> PgError:
    """Return the `PgError` raised by `tx.rollback_to(name)`.

    Parameters:
        origin: Origin of the `Connection` the transaction views; inferred.

    Args:
        tx: The open transaction.
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


def _release[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var name: String) raises:
    """Release savepoint `name` in `tx`.

    Parameters:
        origin: Origin of the `Connection` the transaction views; inferred.

    Args:
        tx: The open transaction.
        name: The savepoint name, used unquoted by the caller.

    Raises:
        Error: If `Transaction.release` raised a `PgError`.
    """
    try:
        tx.release(name^)
    except e:
        raise Error(String(e))


def _release_error[
    origin: ImmOrigin, //
](mut tx: Transaction[origin], var name: String) raises -> PgError:
    """Return the `PgError` raised by `tx.release(name)`.

    Parameters:
        origin: Origin of the `Connection` the transaction views; inferred.

    Args:
        tx: The open transaction.
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


def _count(conn: Connection, var table: String) raises -> Int:
    """Count the rows currently visible in `table`.

    Args:
        conn: An open connection, outside any transaction of its own.
        table: The table name, spliced into the query as written.

    Returns:
        The number of rows in the table.

    Raises:
        Error: If the query or the decoding raised a `PgError`.
    """
    var result = _execute(conn, "SELECT count(*) FROM " + table^)
    var row = _row(result, 0)
    var count = _get[Int64](row, 0)
    _ = row^
    _ = result^
    return Int(count)


# --- a savepoint undoes only what came after it -- (c)-1 ---------------------


def test_rollback_to_savepoint_keeps_the_earlier_insert() raises:
    """Rolling back to a savepoint drops the later row and commits the first.

    The whole point of the partial undo: the work before the savepoint is
    still committed by the outer transaction.
    """
    var conn = _connect(_conninfo())
    var created = _execute(conn, "CREATE TEMP TABLE pq_p2_sp(x int)")
    _ = created^

    var tx = _transaction(conn)

    var first = _tx_execute(tx, "INSERT INTO pq_p2_sp VALUES (1)")
    _ = first^

    _savepoint(tx, "a")

    var second = _tx_execute(tx, "INSERT INTO pq_p2_sp VALUES (2)")
    _ = second^

    # Undo the second insert, but not the first and not the block itself.
    _rollback_to(tx, "a")
    _commit(tx)
    _ = tx^

    assert_equal(_count(conn, "pq_p2_sp"), 1)

    var remaining = _execute(conn, "SELECT x FROM pq_p2_sp")
    var row = _row(remaining, 0)
    assert_equal(_get[Int32](row, 0), Int32(1))
    _ = row^
    _ = remaining^

    _ = conn^


# --- names are escaped identifiers -- (c)-2 ----------------------------------


def test_savepoint_names_are_escaped_identifiers() raises:
    """A quote-bearing name and a mixed-case name both round trip.

    `escape_identifier` quotes the name, so the double quote inside it is
    not a syntax error and the upper case is not folded away: the same
    spelling can be handed back to `rollback_to` and `release`.
    """
    var conn = _connect(_conninfo())
    var tx = _transaction(conn)

    # A double quote inside the name: only correct quoting survives this.
    _savepoint(tx, String(QUOTED_NAME))
    _rollback_to(tx, String(QUOTED_NAME))
    _release(tx, String(QUOTED_NAME))

    # Upper case is preserved, so the name is still found as written.
    _savepoint(tx, String(MIXED_CASE_NAME))
    _rollback_to(tx, String(MIXED_CASE_NAME))
    _release(tx, String(MIXED_CASE_NAME))

    # None of the above aborted the block.
    assert_equal(conn.transaction_status(), Int(PQTRANS_INTRANS))

    _commit(tx)
    _ = tx^
    _ = conn^


# --- a savepoint makes an aborted block recoverable -- (c)-3 -----------------


def test_rollback_to_savepoint_recovers_an_aborted_block() raises:
    """A failed statement aborts the block; `rollback_to` revives it.

    Without the savepoint the only way out of `PQTRANS_INERROR` is
    `ROLLBACK`; with one the transaction still reaches `COMMIT`.
    """
    var conn = _connect(_conninfo())
    var tx = _transaction(conn)

    _savepoint(tx, "s1")

    var failed = _tx_execute_error(tx, "SELECT 1/0")
    assert_true(failed.kind == PgErrorKind.SERVER)
    assert_equal(failed.sqlstate, String(DIVISION_BY_ZERO))
    assert_equal(conn.transaction_status(), Int(PQTRANS_INERROR))

    # Back to the subtransaction's start, which clears the aborted state.
    _rollback_to(tx, "s1")
    assert_equal(conn.transaction_status(), Int(PQTRANS_INTRANS))

    var ok = _tx_execute(tx, "SELECT 1")
    assert_equal(ok.row_count(), 1)
    _ = ok^

    _commit(tx)
    _ = tx^
    _ = conn^


# --- an unknown savepoint is the server's call -- (c)-4 ----------------------


def test_rollback_to_unknown_savepoint_is_3b001() raises:
    """`rollback_to` on a name that was never opened is 3B001 from the server.

    The check is not done locally, so the statement reaches the backend and
    aborts the block: everything after it is 25P02 until `ROLLBACK`.
    """
    var conn = _connect(_conninfo())
    var tx = _transaction(conn)

    var error = _rollback_to_error(tx, "nope")
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.sqlstate, String(NO_SUCH_SAVEPOINT))
    assert_equal(conn.transaction_status(), Int(PQTRANS_INERROR))

    var refused = _tx_execute_error(tx, "SELECT 1")
    assert_true(refused.kind == PgErrorKind.SERVER)
    assert_equal(refused.sqlstate, String(IN_FAILED_TRANSACTION))

    # `ROLLBACK` is still accepted in an aborted block.
    _rollback(tx)
    _ = tx^

    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))

    _ = conn^


def test_release_unknown_savepoint_is_3b001() raises:
    """`release` on a name that was never opened is 3B001 from the server."""
    var conn = _connect(_conninfo())
    var tx = _transaction(conn)

    var error = _release_error(tx, "nope")
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.sqlstate, String(NO_SUCH_SAVEPOINT))
    assert_equal(conn.transaction_status(), Int(PQTRANS_INERROR))

    _rollback(tx)
    _ = tx^

    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))

    _ = conn^


# --- an empty name never reaches the server -- (c)-5 -------------------------


def test_empty_savepoint_name_is_a_usage_error() raises:
    """All three savepoint calls refuse `""` locally, leaving the block intact.

    The rejection happens before anything is written out, which is what the
    unchanged `PQTRANS_INTRANS` shows: had the empty name been spliced into
    the SQL, the syntax error would have dropped the block into
    `PQTRANS_INERROR`.
    """
    var conn = _connect(_conninfo())
    var tx = _transaction(conn)

    var on_savepoint = _savepoint_error(tx, "")
    assert_true(on_savepoint.kind == PgErrorKind.USAGE)
    assert_equal(on_savepoint.message, String(EMPTY_NAME_MESSAGE))
    assert_equal(on_savepoint.sqlstate, "")

    var on_rollback_to = _rollback_to_error(tx, "")
    assert_true(on_rollback_to.kind == PgErrorKind.USAGE)
    assert_equal(on_rollback_to.message, String(EMPTY_NAME_MESSAGE))
    assert_equal(on_rollback_to.sqlstate, "")

    var on_release = _release_error(tx, "")
    assert_true(on_release.kind == PgErrorKind.USAGE)
    assert_equal(on_release.message, String(EMPTY_NAME_MESSAGE))
    assert_equal(on_release.sqlstate, "")

    # Nothing was sent, so the block is still open and still usable.
    assert_equal(conn.transaction_status(), Int(PQTRANS_INTRANS))

    var ok = _tx_execute(tx, "SELECT 1")
    assert_equal(ok.row_count(), 1)
    _ = ok^

    _commit(tx)
    _ = tx^
    _ = conn^


# --- a NUL byte in the name never reaches the server -- (c)-7 ----------------


def test_savepoint_name_with_a_nul_byte_is_rejected() raises:
    """All three calls refuse a name holding a NUL byte, naming `name`.

    libpq takes C strings, so a name with an embedded NUL would be silently
    cut there. The rejection happens before `escape_identifier` sees the
    name, which is what makes the message name `name` rather than the
    quoting helper's own parameter -- and what leaves the block intact,
    shown by the unchanged `PQTRANS_INTRANS`.
    """
    var conn = _connect(_conninfo())
    var tx = _transaction(conn)

    var name = String("sp") + chr(0) + NUL_MARKER

    var on_savepoint = _savepoint_error(tx, name)
    assert_true(on_savepoint.kind == PgErrorKind.TYPE_MISMATCH)
    assert_equal(on_savepoint.message, String(NUL_NAME_MESSAGE))
    # The truncated tail is never echoed back.
    assert_true(on_savepoint.message.find(NUL_MARKER) < 0)
    assert_equal(on_savepoint.sqlstate, "")

    var on_rollback_to = _rollback_to_error(tx, name)
    assert_true(on_rollback_to.kind == PgErrorKind.TYPE_MISMATCH)
    assert_equal(on_rollback_to.message, String(NUL_NAME_MESSAGE))

    var on_release = _release_error(tx, name)
    assert_true(on_release.kind == PgErrorKind.TYPE_MISMATCH)
    assert_equal(on_release.message, String(NUL_NAME_MESSAGE))

    # Nothing was sent, so the block is still open and still usable.
    assert_equal(conn.transaction_status(), Int(PQTRANS_INTRANS))

    var ok = _tx_execute(tx, "SELECT 1")
    assert_equal(ok.row_count(), 1)
    _ = ok^

    _commit(tx)
    _ = tx^
    _ = conn^


# --- RELEASE forgets the name -- (c)-6 ---------------------------------------


def test_rollback_to_a_released_savepoint_is_3b001() raises:
    """After `release` the name is gone, so `rollback_to` it is 3B001.

    `RELEASE SAVEPOINT` destroys the savepoint rather than just closing the
    subtransaction, so the name cannot be used as a target afterwards.
    """
    var conn = _connect(_conninfo())
    var tx = _transaction(conn)

    _savepoint(tx, "gone")
    _release(tx, "gone")

    var error = _rollback_to_error(tx, "gone")
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.sqlstate, String(NO_SUCH_SAVEPOINT))

    _rollback(tx)
    _ = tx^
    _ = conn^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
