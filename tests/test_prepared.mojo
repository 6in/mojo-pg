"""Tests for `pq.prepared` and the `Connection.prepare` factory.

Fixes the observable contract of a named prepared statement: the per
connection `pq_stmt_N` naming, the metadata `PQdescribePrepared` hands back
(`param_count`, `param_type_oid` and its out-of-range rejection), the
parameter-count check that happens *before* anything is written to the
socket, and the `DEALLOCATE` that `__deinit__` sends when the statement dies.

Two properties of the lifetime get their own tests because they are easy to
break by accident. First, destruction is ASAP: a statement dies right after
the last line that uses it, which is why every test here puts the "still
prepared" observation *before* the final use and the "gone" observation
*after* the `_ = stmt^` marker -- that marker keeps the statement alive up to
that point, it does not destroy it early. Second, the `DEALLOCATE` in
`__deinit__` must stay silent: a destructor cannot raise, so a statement
dropped inside an aborted transaction (25P02), one whose name the user
already deallocated (26000) and one whose connection is gone all have to
unwind without a traceback.

`PREPARE` is not transactional. A statement prepared inside a transaction
survives a `ROLLBACK`, so the rolled-back cases assert that the statement is
*still there* rather than cleaned up.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI), falling back to the local container. An unreachable
server fails these tests; it never skips them. Every test must pass against
both PG14 and PG17, so nothing here depends on version-specific wording:
only SQLSTATEs, type OIDs and values are asserted.

Every table is created as `CREATE TEMP TABLE pq_p2_<name>`, which keeps it
inside the session, so two test processes -- or the two server versions --
never collide on a name.
"""

from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_true

from pq._ffi.types import PQTRANS_INTRANS
from pq.connection import Connection
from pq.decode_text import OID_INT4, OID_INT8, OID_TEXT
from pq.errors import PgError, PgErrorKind
from pq.params import Param
from pq.prepared import PreparedStatement
from pq.result import Result, Row

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime THREE_PARAM_SQL: StaticString = "SELECT $1::int4 + $2::int4, $3"
"""Three parameters of two different inferred types.

`$1` and `$2` are cast to `int4`, so the server resolves them as `int4`;
`$3` is used bare in the select list, which leaves it as `text`. The mix is
what makes `param_type_oid` worth asking about.
"""

comptime ONE_INT_SQL: StaticString = "SELECT $1::int4"
"""One `int4` parameter: the smallest statement that still takes a value."""

comptime ONE_UNTYPED_SQL: StaticString = "SELECT $1"
"""One parameter with nothing to infer from, so the server picks `text`."""

comptime NO_PARAM_SQL: StaticString = "SELECT 1"
"""A statement with no placeholders, so `param_type_oid` has no valid index."""

comptime COUNT_BY_NAME: StaticString = (
    "SELECT count(*) FROM pg_prepared_statements WHERE name = $1"
)
"""Server-side existence check for one statement name.

`pg_prepared_statements` is session local, so this counts only the
statements prepared by the connection that runs the query.
"""

comptime COUNT_ALL: StaticString = "SELECT count(*) FROM pg_prepared_statements"
"""Server-side count of every statement still prepared on this session."""

comptime NUL_MARKER: StaticString = "AFTER_NUL_MARKER"
"""Text placed *after* an embedded NUL byte in a rejected parameter."""

comptime LOOP_ROUNDS = 100
"""How many prepare/execute/destroy cycles the leak test runs."""


# --- helpers -----------------------------------------------------------------
#
# A `TestSuite` test only declares `raises` (plain `Error`), and `PgError` does
# not implicitly convert to `Error`, so a `raises PgError` API cannot be called
# straight from a test. These wrappers translate in both directions: success
# paths re-raise as `Error`, failure paths hand the `PgError` back for
# inspection. Helpers are per file by convention; nothing here is shared with
# `test_params.mojo`.
#
# The generic wrappers bind `T: Copyable & Deinitable`, not just `Copyable`:
# discarding a `get` result with `_ = ...` needs `Deinitable` to compile.


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


def _execute_params(
    conn: Connection, var sql: String, params: List[Param]
) raises -> Result:
    """Run `sql` on `conn` with bound parameters.

    Args:
        conn: An open connection.
        sql: The single statement to run.
        params: The values bound to `$1`, `$2`, ... in order.

    Returns:
        The result of the statement.

    Raises:
        Error: If `execute` raised a `PgError`.
    """
    try:
        return conn.execute(sql^, params)
    except e:
        raise Error(String(e))


def _prepare(
    conn: Connection,
    var sql: String,
    param_types: List[UInt32] = List[UInt32](),
) raises -> PreparedStatement[origin_of(conn)]:
    """Prepare `sql` on `conn`.

    The returned statement is a view onto the connection: its `origin`
    parameter ties it to `conn`, so the compiler keeps the connection alive
    for as long as the statement is reachable.

    Args:
        conn: An open connection.
        sql: The single statement to prepare.
        param_types: Type OIDs for `$1`, `$2`, ...; empty means "infer".

    Returns:
        The prepared statement.

    Raises:
        Error: If `prepare` raised a `PgError`.
    """
    try:
        return conn.prepare(sql^, param_types)
    except e:
        raise Error(String(e))


def _prepare_error(
    conn: Connection,
    var sql: String,
    param_types: List[UInt32] = List[UInt32](),
) raises -> PgError:
    """Return the `PgError` raised by `conn.prepare(sql, param_types)`.

    Args:
        conn: An open connection.
        sql: A statement that must be rejected.
        param_types: Type OIDs for `$1`, `$2`, ...; empty means "infer".

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `prepare` returned a statement instead of raising.
    """
    try:
        var stmt = conn.prepare(sql^, param_types)
        _ = stmt^
    except e:
        return e.copy()
    raise Error("expected a PgError from Connection.prepare(sql)")


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


def _stmt_execute_error[
    origin: ImmOrigin, //
](stmt: PreparedStatement[origin], params: List[Param]) raises -> PgError:
    """Return the `PgError` raised by `stmt.execute(params)`.

    Parameters:
        origin: Origin of the `Connection` the statement views; inferred.

    Args:
        stmt: The prepared statement to run.
        params: A parameter list that must be rejected.

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


def _param_type_oid[
    origin: ImmOrigin, //
](stmt: PreparedStatement[origin], i: Int) raises -> UInt32:
    """Return the type OID the server assigned to parameter `i`.

    Parameters:
        origin: Origin of the `Connection` the statement views; inferred.

    Args:
        stmt: The prepared statement to inspect.
        i: Zero-based parameter index.

    Returns:
        The parameter's type OID.

    Raises:
        Error: If `param_type_oid` raised a `PgError`.
    """
    try:
        return stmt.param_type_oid(i)
    except e:
        raise Error(String(e))


def _param_type_oid_error[
    origin: ImmOrigin, //
](stmt: PreparedStatement[origin], i: Int) raises -> PgError:
    """Return the `PgError` raised by `stmt.param_type_oid(i)`.

    Parameters:
        origin: Origin of the `Connection` the statement views; inferred.

    Args:
        stmt: The prepared statement to inspect.
        i: A parameter index that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `param_type_oid` returned an OID instead of raising.
    """
    try:
        var oid = stmt.param_type_oid(i)
        _ = oid
    except e:
        return e.copy()
    raise Error("expected a PgError from PreparedStatement.param_type_oid(i)")


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


def _is_null[origin: ImmOrigin, //](row: Row[origin], col: Int) raises -> Bool:
    """Report whether column `col` of `row` is a SQL NULL.

    Parameters:
        origin: Origin of the `Result` the row views; inferred from `row`.

    Args:
        row: The row to inspect.
        col: Zero-based column index.

    Returns:
        True if the column holds a SQL NULL.

    Raises:
        Error: If `Row.is_null` raised a `PgError`.
    """
    try:
        return row.is_null(col)
    except e:
        raise Error(String(e))


def _prepared_count(conn: Connection, name: String) raises -> Int:
    """Count the statements on `conn` currently prepared under `name`.

    Args:
        conn: The connection whose session is inspected.
        name: The statement name to look for.

    Returns:
        1 while the statement exists on the server, 0 once it is gone.

    Raises:
        Error: If the query or the decoding raised a `PgError`.
    """
    var params: List[Param] = [Param(name.copy())]
    var result = _execute_params(conn, String(COUNT_BY_NAME), params)
    var row = _row(result, 0)
    var count = _get[Int64](row, 0)
    _ = row^
    _ = result^
    return Int(count)


def _prepared_count_all(conn: Connection) raises -> Int:
    """Count every statement still prepared on `conn`.

    Args:
        conn: The connection whose session is inspected.

    Returns:
        The number of rows in `pg_prepared_statements`.

    Raises:
        Error: If the query or the decoding raised a `PgError`.
    """
    var result = _execute(conn, String(COUNT_ALL))
    var row = _row(result, 0)
    var count = _get[Int64](row, 0)
    _ = row^
    _ = result^
    return Int(count)


def _with_nul(prefix: String) -> String:
    """Return `prefix`, a NUL byte, then `NUL_MARKER`.

    Args:
        prefix: The part libpq would still see after truncation.

    Returns:
        A `String` whose `byte_length` counts the NUL, so the embedded byte
        really is part of the value rather than a terminator.
    """
    return prefix + chr(0) + NUL_MARKER


# --- naming, description and round trip -- (b)-1 -----------------------------


def test_prepare_describes_and_executes() raises:
    """Describe, execute and name a three-parameter statement twice over."""
    var conn = _connect(_conninfo())
    var stmt = _prepare(conn, String(THREE_PARAM_SQL))

    # First statement on a fresh connection, so the counter starts at one.
    assert_equal(stmt.name(), "pq_stmt_1")
    assert_equal(stmt.param_count(), 3)

    # Both casts resolve to int4; the bare `$3` is left as text.
    assert_equal(_param_type_oid(stmt, 0), OID_INT4)
    assert_equal(_param_type_oid(stmt, 1), OID_INT4)
    assert_equal(_param_type_oid(stmt, 2), OID_TEXT)

    # Out of range in both directions: a local check, with the valid span
    # spelled out in the message.
    var too_high = _param_type_oid_error(stmt, 3)
    assert_true(too_high.kind == PgErrorKind.TYPE_MISMATCH)
    assert_equal(too_high.message, "parameter index 3 out of range (0..2)")
    var negative = _param_type_oid_error(stmt, -1)
    assert_true(negative.kind == PgErrorKind.TYPE_MISMATCH)
    assert_true(negative.message.find("out of range") >= 0)

    # The declared types are int4, and `PQexecPrepared` carries no type OIDs
    # of its own, so the values have to be sent as int4 to match.
    var params: List[Param] = [Int32(1), Int32(2), "x"]
    var result = _stmt_execute(stmt, params)
    assert_equal(result.row_count(), 1)
    var row = _row(result, 0)
    assert_equal(_get[Int32](row, 0), Int32(3))
    assert_equal(_get[String](row, 1), "x")
    _ = row^
    _ = result^

    # Same connection, so the counter keeps going rather than restarting.
    var second = _prepare(conn, String(ONE_INT_SQL))
    assert_equal(second.name(), "pq_stmt_2")

    _ = second^
    _ = stmt^
    _ = conn^


def test_param_type_oid_on_a_statement_with_no_parameters() raises:
    """A statement with no placeholders says so instead of naming `0..-1`.

    The generic message builds its upper bound from `param_count() - 1`, which
    reads as an empty range the caller cannot act on. The count being zero is
    the fact that explains the rejection, so it is what the message carries.
    """
    var conn = _connect(_conninfo())
    var stmt = _prepare(conn, String(NO_PARAM_SQL))

    assert_equal(stmt.param_count(), 0)

    var error = _param_type_oid_error(stmt, 0)
    assert_true(error.kind == PgErrorKind.TYPE_MISMATCH)
    assert_true(error.message.find("takes no parameters") >= 0)
    assert_true(error.message.find("0..-1") < 0)

    # Nothing was sent, so there is no server diagnostic to carry.
    assert_equal(error.sqlstate, "")

    _ = stmt^
    _ = conn^


def test_statement_numbering_is_per_connection() raises:
    """A second connection starts its own counter at `pq_stmt_1`."""
    var first_conn = _connect(_conninfo())
    var first = _prepare(first_conn, String(ONE_INT_SQL))
    assert_equal(first.name(), "pq_stmt_1")
    var also_first = _prepare(first_conn, String(ONE_INT_SQL))
    assert_equal(also_first.name(), "pq_stmt_2")

    # A different `Connection` has a different counter, not a shared global.
    var second_conn = _connect(_conninfo())
    var second = _prepare(second_conn, String(ONE_INT_SQL))
    assert_equal(second.name(), "pq_stmt_1")

    _ = second^
    _ = second_conn^
    _ = also_first^
    _ = first^
    _ = first_conn^


# --- the parameter count check is local -- (b)-2 -----------------------------


def test_param_count_mismatch_never_reaches_the_server() raises:
    """A wrong parameter count is caught before anything is written out.

    It is therefore a local `USAGE` error, and it cannot abort an open
    transaction the way the protocol error (08P01) of a bad bind would.
    """
    var conn = _connect(_conninfo())
    var stmt = _prepare(conn, String(THREE_PARAM_SQL))

    var one: List[Param] = [Int32(1)]
    var error = _stmt_execute_error(stmt, one)
    assert_true(error.kind == PgErrorKind.USAGE)
    # Both numbers are named: what the statement wants and what it got.
    assert_true(error.message.find("takes 3 parameters, got 1") >= 0)
    # Nothing reached the server, so there is no diagnostic to carry.
    assert_equal(error.sqlstate, "")

    var begun = _execute(conn, "BEGIN")
    _ = begun^

    var in_tx_error = _stmt_execute_error(stmt, one)
    assert_true(in_tx_error.kind == PgErrorKind.USAGE)

    # Had the mismatched bind gone out on the wire, libpq would have reported
    # 08P01 and the backend would have dropped the block into INERROR.
    assert_equal(conn.transaction_status(), Int(PQTRANS_INTRANS))

    var rolled_back = _execute(conn, "ROLLBACK")
    _ = rolled_back^

    _ = stmt^
    _ = conn^


# --- destruction sends DEALLOCATE -- (b)-3 -----------------------------------


def test_deinit_deallocates_on_last_use() raises:
    """`DEALLOCATE` runs when the statement dies, which is at its last use."""
    var conn = _connect(_conninfo())
    var stmt = _prepare(conn, String(ONE_INT_SQL))
    var name = stmt.name()

    # This observation has to come *before* the final use of `stmt`: ASAP
    # destruction would otherwise have deallocated it already.
    assert_equal(_prepared_count(conn, name), 1)

    # One more use, which is what keeps the statement alive above.
    assert_equal(stmt.param_count(), 1)
    _ = stmt^

    # Past the marker the statement is destroyed, so DEALLOCATE has run.
    assert_equal(_prepared_count(conn, name), 0)

    _ = conn^


# --- executing a statement the user deallocated -- (b)-4 ---------------------


def test_execute_after_manual_deallocate_is_26000() raises:
    """Executing a hand-deallocated statement is 26000, destruction is quiet."""
    var conn = _connect(_conninfo())
    var stmt = _prepare(conn, String(ONE_INT_SQL))
    var name = stmt.name()

    var deallocated = _execute(conn, "DEALLOCATE " + name)
    _ = deallocated^

    var params: List[Param] = [Int32(1)]
    var error = _stmt_execute_error(stmt, params)
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.sqlstate, "26000")

    # Destroying the statement sends a second DEALLOCATE for a name that is
    # already gone. That failure is swallowed: no raise, no traceback.
    _ = stmt^

    var ok = _execute(conn, "SELECT 1")
    assert_equal(ok.row_count(), 1)
    _ = ok^

    _ = conn^


# --- PREPARE is not transactional -- (b)-5 -----------------------------------


def test_prepare_survives_rollback() raises:
    """A statement prepared inside a transaction still runs after ROLLBACK."""
    var conn = _connect(_conninfo())

    var begun = _execute(conn, "BEGIN")
    _ = begun^

    var stmt = _prepare(conn, String(ONE_INT_SQL))

    var rolled_back = _execute(conn, "ROLLBACK")
    _ = rolled_back^

    var params: List[Param] = [Int32(7)]
    var result = _stmt_execute(stmt, params)
    assert_equal(result.row_count(), 1)
    var row = _row(result, 0)
    assert_equal(_get[Int32](row, 0), Int32(7))
    _ = row^
    _ = result^

    _ = stmt^
    _ = conn^


# --- destruction inside an aborted transaction -- (b)-6 ----------------------


def test_deinit_inside_an_aborted_transaction_is_silent() raises:
    """Destruction in an aborted block swallows the 25P02 it gets back.

    The statement is left on the server, so this test cleans it up by hand.
    """
    var conn = _connect(_conninfo())

    var begun = _execute(conn, "BEGIN")
    _ = begun^

    var stmt = _prepare(conn, String(ONE_INT_SQL))
    var name = stmt.name()

    # Abort the block, so every further command in it is refused with 25P02.
    var broken = _execute_error(conn, "SELEC")
    assert_true(broken.kind == PgErrorKind.SERVER)

    # The DEALLOCATE this sends is rejected, and that rejection is dropped.
    _ = stmt^

    var rolled_back = _execute(conn, "ROLLBACK")
    _ = rolled_back^

    # The statement was never deallocated, and PREPARE is not transactional,
    # so it outlived the block it was created in.
    assert_equal(_prepared_count(conn, name), 1)

    var cleaned = _execute(conn, "DEALLOCATE " + name)
    _ = cleaned^
    assert_equal(_prepared_count(conn, name), 0)

    _ = conn^


# --- prepare-time rejections -- (b)-7 ----------------------------------------


def test_prepare_rejects_bad_sql_and_multiple_statements() raises:
    """Bad SQL and multi-statement SQL are both 42601 at prepare time."""
    var conn = _connect(_conninfo())

    var syntax = _prepare_error(conn, "SELEC 1")
    assert_true(syntax.kind == PgErrorKind.SERVER)
    assert_equal(syntax.sqlstate, "42601")

    # A prepared statement holds exactly one command.
    var multiple = _prepare_error(conn, "SELECT 1; SELECT 2")
    assert_true(multiple.kind == PgErrorKind.SERVER)
    assert_equal(multiple.sqlstate, "42601")

    var stmt = _prepare(conn, "SELECT 1")
    assert_equal(stmt.param_count(), 0)

    _ = stmt^
    _ = conn^


# --- explicitly requested parameter types -- (b)-8 ---------------------------


def test_explicit_param_types() raises:
    """`param_types` overrides inference, for an INSERT and for a SELECT."""
    var conn = _connect(_conninfo())
    var created = _execute(conn, "CREATE TEMP TABLE pq_p2_prep(x int4)")
    _ = created^

    # int8 asked for against an int4 column: the assignment cast is the
    # server's business, the parameter still goes out as int8.
    var int8_types: List[UInt32] = [OID_INT8]
    var insert = _prepare(
        conn, "INSERT INTO pq_p2_prep VALUES ($1)", int8_types
    )
    assert_equal(insert.param_count(), 1)

    var values: List[Param] = [Int(5)]
    var inserted = _stmt_execute(insert, values)
    assert_equal(inserted.affected_rows(), 1)
    assert_equal(inserted.column_count(), 0)
    _ = inserted^
    _ = insert^

    # A bare `$1` would have been inferred as text; int4 was requested.
    var int4_types: List[UInt32] = [OID_INT4]
    var select = _prepare(conn, String(ONE_UNTYPED_SQL), int4_types)
    assert_equal(_param_type_oid(select, 0), OID_INT4)

    var nulls: List[Param] = [Param.null()]
    var result = _stmt_execute(select, nulls)
    assert_equal(result.row_count(), 1)
    var row = _row(result, 0)
    assert_true(_is_null(row, 0))
    _ = row^
    _ = result^

    _ = select^
    _ = conn^


# --- inference for an untyped placeholder -- (b)-9 ---------------------------


def test_inferred_param_type_is_text() raises:
    """With nothing to infer from, the server types `$1` as text."""
    var conn = _connect(_conninfo())
    var stmt = _prepare(conn, String(ONE_UNTYPED_SQL))

    assert_equal(stmt.param_count(), 1)
    assert_equal(_param_type_oid(stmt, 0), OID_TEXT)

    var params: List[Param] = ["x"]
    var result = _stmt_execute(stmt, params)
    var row = _row(result, 0)
    assert_equal(_get[String](row, 0), "x")
    _ = row^
    _ = result^

    _ = stmt^
    _ = conn^


# --- embedded NUL in a parameter value -- (b)-10 -----------------------------


def test_nul_byte_in_parameter_is_a_usage_error() raises:
    """A NUL inside a `String` parameter is rejected locally.

    The count is right here, which is the point: the count check runs first,
    so only a well-counted list ever reaches the NUL check.
    """
    var conn = _connect(_conninfo())
    var stmt = _prepare(conn, String(ONE_UNTYPED_SQL))

    var params: List[Param] = [Param(_with_nul("a"))]
    var error = _stmt_execute_error(stmt, params)
    assert_true(error.kind == PgErrorKind.USAGE)
    # Nothing reached the server, so there is no diagnostic to carry.
    assert_equal(error.sqlstate, "")

    _ = stmt^
    _ = conn^


# --- no statement is left behind -- (b)-11 -----------------------------------


def test_many_statements_leave_nothing_prepared() raises:
    """A hundred prepare/execute/destroy cycles leave nothing prepared."""
    var conn = _connect(_conninfo())

    for i in range(LOOP_ROUNDS):
        var stmt = _prepare(conn, String(ONE_INT_SQL))
        var params: List[Param] = [Int32(i)]
        var result = _stmt_execute(stmt, params)
        var row = _row(result, 0)
        assert_equal(_get[Int32](row, 0), Int32(i))
        _ = row^
        _ = result^
        _ = stmt^

    # Every DEALLOCATE landed, including the ones sent from a destructor.
    assert_equal(_prepared_count_all(conn), 0)

    _ = conn^


# --- the connection dies under the statement -- (b)-12 -----------------------


def test_execute_after_backend_termination_is_a_connection_error() raises:
    """Executing over a dead connection is a `CONNECTION` error.

    The `DEALLOCATE` that destruction then sends over the same dead socket
    has nowhere to go, and is dropped without a word.
    """
    var conn = _connect(_conninfo())
    var stmt = _prepare(conn, String(ONE_INT_SQL))

    # Killing our own backend has to be reported, not swallowed.
    var terminated = _execute_error(
        conn, "SELECT pg_terminate_backend(pg_backend_pid())"
    )
    _ = terminated^

    var params: List[Param] = [Int32(1)]
    var error = _stmt_execute_error(stmt, params)
    assert_true(error.kind == PgErrorKind.CONNECTION)

    # There is no socket left to send DEALLOCATE on; destruction is quiet.
    _ = stmt^
    _ = conn^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
