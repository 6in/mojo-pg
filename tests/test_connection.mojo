"""Tests for `pq.connection` and `pq.result` against a live PostgreSQL server.

`Connection` is `Movable` but deliberately **not** `Copyable`: `var c2 = c1` is a
compile error, so one `PGconn` can never be handed to two owners and `PQfinish`
can never run twice. That is a *negative* compilation check, so it cannot live
in this file (every test here must compile for the suite to run at all); the
parent task verifies it outside `tests/run_tests.sh`.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI: these tests append ` password=...` to it). Every test must
pass against both PG14 and PG17, so nothing here depends on version-specific
wording.
"""

from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pq._ffi.types import (
    CONNECTION_OK,
    PQTRANS_IDLE,
    PQTRANS_INERROR,
    PQTRANS_INTRANS,
)
from pq.connection import Connection
from pq.errors import PgError, PgErrorKind
from pq.result import Result

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime WRONG_PASSWORD: StaticString = "WRONG_pw_123"
"""A password that must never reach a `PgError.message`."""

comptime NUL_MARKER: StaticString = "AFTER_NUL_MARKER"
"""Text placed *after* an embedded NUL byte in a rejected argument.

libpq takes C strings, so everything from the NUL onwards is invisible to it.
These tests use the marker twice over: it proves the truncated tail never
reaches a `PgError.message`, and -- because it is appended where a password
value would go -- that the rejection does not echo caller credentials either.
"""

comptime APP_NAME_LENGTH = 63
"""Length of the `application_name` round-tripped by `open(Dict)`.

NAMEDATALEN-1: PostgreSQL silently truncates a longer `application_name` and
emits a `NOTICE` about it, so a longer value could only be checked as a
prefix. 63 bytes is still far past the small-string-optimization boundary,
which is what this round trip is really probing (P6).
"""


# --- helpers -----------------------------------------------------------------
#
# A `TestSuite` test only declares `raises` (plain `Error`), and `PgError` does
# not implicitly convert to `Error`, so a `raises PgError` API cannot be called
# straight from a test. These wrappers translate in both directions: success
# paths re-raise as `Error`, failure paths hand the `PgError` back for
# inspection.


def _conninfo() -> String:
    """Return the conninfo of the server under test.

    Returns:
        `PQ_TEST_CONNINFO` when set and non-empty, else `DEFAULT_CONNINFO`.
    """
    var value = getenv("PQ_TEST_CONNINFO")
    return value if value != "" else String(DEFAULT_CONNINFO)


def _params() raises -> Dict[String, String]:
    """Split the conninfo of the server under test into keyword/value pairs.

    Tokens are separated by spaces and each token is cut at its *first* `=`, so
    a value containing `=` survives the round trip.

    Returns:
        The conninfo as a `Dict`, suitable for `Connection.open(Dict)`.
    """
    var conninfo = _conninfo()
    var params = Dict[String, String]()
    var tokens = conninfo.split(" ")
    for token in tokens:
        var pair = String(token).split("=")
        if len(pair) < 2:
            continue
        var value = String(pair[1])
        for i in range(2, len(pair)):
            value += "="
            value += String(pair[i])
        params[String(pair[0])] = value
    return params^


def _long_application_name() -> String:
    """Build an `application_name` of exactly `APP_NAME_LENGTH` bytes.

    Returns:
        A 63-byte ASCII string.
    """
    var name = String("")
    for _ in range(APP_NAME_LENGTH):
        name += "a"
    return name^


def _with_nul(prefix: String) -> String:
    """Return `prefix`, a NUL byte, then `NUL_MARKER`.

    Args:
        prefix: The part libpq would still see after truncation.

    Returns:
        A `String` whose `byte_length` counts the NUL, so the embedded byte
        really is part of the value rather than a terminator.
    """
    return prefix + chr(0) + NUL_MARKER


def _assert_nul_error(error: PgError, what: String) raises:
    """Check that `error` is the NUL rejection raised for argument `what`.

    Args:
        error: The error raised by the entry point under test.
        what: The argument name the message must name.

    Raises:
        Error: If the kind, message or diagnostics do not match, or if the
            message echoes the text that followed the NUL.
    """
    assert_true(error.kind == PgErrorKind.TYPE_MISMATCH)
    assert_equal(error.message, "embedded NUL byte in " + what)
    assert_false(error.message.find(NUL_MARKER) >= 0)
    # Nothing reached the server, so there is no diagnostic to carry.
    assert_equal(error.sqlstate, "")
    assert_equal(error.severity, "")


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


def _connect_params(params: Dict[String, String]) raises -> Connection:
    """Open a connection from keyword/value parameters.

    Args:
        params: Connection parameters, taken literally (no URI expansion).

    Returns:
        The open connection.

    Raises:
        Error: If `Connection.open` raised a `PgError`.
    """
    try:
        return Connection.open(params)
    except e:
        raise Error(String(e))


def _open_error(var conninfo: String) raises -> PgError:
    """Return the `PgError` raised by `Connection.open(conninfo)`.

    Args:
        conninfo: A conninfo string that must fail to connect.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the connection succeeded instead of failing.
    """
    try:
        var conn = Connection.open(conninfo^)
        _ = conn^
    except e:
        return e.copy()
    raise Error("expected a PgError from Connection.open(conninfo)")


def _open_params_error(params: Dict[String, String]) raises -> PgError:
    """Return the `PgError` raised by `Connection.open(params)`.

    Args:
        params: Connection parameters that must fail to connect.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If the connection succeeded instead of failing.
    """
    try:
        var conn = Connection.open(params)
        _ = conn^
    except e:
        return e.copy()
    raise Error("expected a PgError from Connection.open(params)")


def _execute(conn: Connection, var sql: String) raises -> Result:
    """Run `sql` on `conn`.

    Args:
        conn: An open connection.
        sql: The statement (or statements) to run.

    Returns:
        The result of the last statement.

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
    raise Error("expected a PgError from Connection.execute")


def _escape_literal(conn: Connection, var s: String) raises -> String:
    """Quote `s` as a SQL literal on `conn`.

    Args:
        conn: An open connection.
        s: The value to quote.

    Returns:
        libpq's quoted literal, surrounding quotes included.

    Raises:
        Error: If `escape_literal` raised a `PgError`.
    """
    try:
        return conn.escape_literal(s^)
    except e:
        raise Error(String(e))


def _escape_identifier(conn: Connection, var s: String) raises -> String:
    """Quote `s` as a SQL identifier on `conn`.

    Args:
        conn: An open connection.
        s: The identifier to quote.

    Returns:
        libpq's quoted identifier, surrounding double quotes included.

    Raises:
        Error: If `escape_identifier` raised a `PgError`.
    """
    try:
        return conn.escape_identifier(s^)
    except e:
        raise Error(String(e))


def _escape_literal_error(conn: Connection, var s: String) raises -> PgError:
    """Return the `PgError` raised by `conn.escape_literal(s)`.

    Args:
        conn: An open connection.
        s: A value that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `escape_literal` returned a quoted value instead of raising.
    """
    try:
        _ = conn.escape_literal(s^)
    except e:
        return e.copy()
    raise Error("expected a PgError from Connection.escape_literal")


def _escape_identifier_error(conn: Connection, var s: String) raises -> PgError:
    """Return the `PgError` raised by `conn.escape_identifier(s)`.

    Args:
        conn: An open connection.
        s: An identifier that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `escape_identifier` returned a quoted name instead of
            raising.
    """
    try:
        _ = conn.escape_identifier(s^)
    except e:
        return e.copy()
    raise Error("expected a PgError from Connection.escape_identifier")


def _column_name(result: Result, i: Int) raises -> String:
    """Return the name of column `i`.

    Args:
        result: The result to inspect.
        i: Zero-based column index.

    Returns:
        The column name.

    Raises:
        Error: If `column_name` raised a `PgError`.
    """
    try:
        return result.column_name(i)
    except e:
        raise Error(String(e))


def _column_name_kind(result: Result, i: Int) raises -> PgErrorKind:
    """Return the kind of the `PgError` raised by `column_name(i)`.

    Args:
        result: The result to inspect.
        i: A column index that must be rejected.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If `column_name` returned a name instead of raising.
    """
    try:
        _ = result.column_name(i)
    except e:
        return e.kind
    raise Error(String("expected a PgError from column_name(", i, ")"))


def _column_index(result: Result, name: String) raises -> Int:
    """Return the index of the column called `name`.

    Args:
        result: The result to inspect.
        name: The column name to look up.

    Returns:
        The zero-based column index.

    Raises:
        Error: If `column_index` raised a `PgError`.
    """
    try:
        return result.column_index(name)
    except e:
        raise Error(String(e))


def _column_index_kind(result: Result, name: String) raises -> PgErrorKind:
    """Return the kind of the `PgError` raised by `column_index(name)`.

    Args:
        result: The result to inspect.
        name: A column name that must be rejected.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If `column_index` returned an index instead of raising.
    """
    try:
        _ = result.column_index(name)
    except e:
        return e.kind
    raise Error(String("expected a PgError from column_index(", name, ")"))


def _column_index_error(result: Result, name: String) raises -> PgError:
    """Return the `PgError` raised by `column_index(name)`.

    Args:
        result: The result to inspect.
        name: A column name that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `column_index` returned an index instead of raising.
    """
    try:
        _ = result.column_index(name)
    except e:
        return e.copy()
    raise Error("expected a PgError from column_index")


def _row_get_error(result: Result, name: String) raises -> PgError:
    """Return the `PgError` raised by `result[0].get[Int32](name)`.

    Args:
        result: A result with at least one row.
        name: A column name that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `Row.get` returned a value instead of raising.
    """
    try:
        _ = result[0].get[Int32](name)
    except e:
        return e.copy()
    raise Error("expected a PgError from Row.get(name)")


def _row_get_optional_error(result: Result, name: String) raises -> PgError:
    """Return the `PgError` raised by `result[0].get_optional[Int32](name)`.

    Args:
        result: A result with at least one row.
        name: A column name that must be rejected.

    Returns:
        The raised `PgError`.

    Raises:
        Error: If `Row.get_optional` returned a value instead of raising.
    """
    try:
        _ = result[0].get_optional[Int32](name)
    except e:
        return e.copy()
    raise Error("expected a PgError from Row.get_optional(name)")


def _column_type_oid(result: Result, i: Int) raises -> UInt32:
    """Return the type OID of column `i`.

    Args:
        result: The result to inspect.
        i: Zero-based column index.

    Returns:
        The column's type OID.

    Raises:
        Error: If `column_type_oid` raised a `PgError`.
    """
    try:
        return result.column_type_oid(i)
    except e:
        raise Error(String(e))


def _column_type_oid_kind(result: Result, i: Int) raises -> PgErrorKind:
    """Return the kind of the `PgError` raised by `column_type_oid(i)`.

    Args:
        result: The result to inspect.
        i: A column index that must be rejected.

    Returns:
        The `kind` field of the raised `PgError`.

    Raises:
        Error: If `column_type_oid` returned an OID instead of raising.
    """
    try:
        _ = result.column_type_oid(i)
    except e:
        return e.kind
    raise Error(String("expected a PgError from column_type_oid(", i, ")"))


# --- open(conninfo) ----------------------------------------------------------


def test_open_conninfo_select_one() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, "SELECT 1")
    assert_equal(result.row_count(), 1)
    assert_equal(result.column_count(), 1)
    assert_equal(len(result), 1)
    _ = result^
    _ = conn^


def test_open_conninfo_wrong_password_does_not_leak_it() raises:
    # libpq takes the last value given for a repeated key, so appending
    # `password=...` overrides the real one.
    var conninfo = _conninfo() + " password=" + WRONG_PASSWORD
    var error = _open_error(conninfo)
    assert_true(error.kind == PgErrorKind.CONNECTION)
    assert_true(error.message != "")
    assert_false(error.message.find(WRONG_PASSWORD) >= 0)


# --- open(Dict) --------------------------------------------------------------


def test_open_params_wrong_password_does_not_leak_it() raises:
    var params = _params()
    params["password"] = String(WRONG_PASSWORD)
    var error = _open_params_error(params)
    assert_true(error.kind == PgErrorKind.CONNECTION)
    assert_true(error.message != "")
    assert_false(error.message.find(WRONG_PASSWORD) >= 0)


def test_open_params_unreachable_port() raises:
    var params = Dict[String, String]()
    params["host"] = "127.0.0.1"
    params["port"] = "1"
    params["connect_timeout"] = "1"
    var error = _open_params_error(params)
    assert_true(error.kind == PgErrorKind.CONNECTION)
    assert_true(error.message != "")


def test_open_params_round_trips_application_name() raises:
    var app_name = _long_application_name()
    assert_equal(app_name.byte_length(), APP_NAME_LENGTH)

    var params = _params()
    params["application_name"] = app_name
    var conn = _connect_params(params)
    var result = _execute(conn, "SELECT current_setting('application_name')")
    assert_equal(result.row_count(), 1)
    assert_equal(result.column_count(), 1)
    _ = result^

    # The value is checked server-side with a predicate, which needs nothing
    # but `row_count`. `app_name` is exactly NAMEDATALEN-1 bytes, so
    # the server stores it untruncated and equality holds on PG14 and PG17.
    var predicate = (
        String("SELECT 1 WHERE current_setting('application_name') = '")
        + app_name
        + "'"
    )
    var echoed = _execute(conn, predicate)
    assert_equal(echoed.row_count(), 1)
    _ = echoed^
    _ = conn^


# --- server errors -----------------------------------------------------------


def test_syntax_error_fills_diagnostics() raises:
    var conn = _connect(_conninfo())
    var error = _execute_error(conn, "SELEC 1")
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.sqlstate, "42601")
    assert_equal(error.severity, "ERROR")
    assert_equal(error.position, "1")
    assert_true(error.message.find("syntax error") >= 0)
    _ = conn^


def test_raise_exception_fills_detail_hint_and_context() raises:
    var conn = _connect(_conninfo())

    # A syntax error carries no DETAIL, HINT or CONTEXT, so the only way to
    # check those three fields is to make the server emit them. `RAISE
    # EXCEPTION` inside an anonymous block does: PL/pgSQL reports the block as
    # `inline_code_block` in PG_DIAG_CONTEXT.
    var error = _execute_error(
        conn,
        (
            "DO $$ BEGIN RAISE EXCEPTION 'boom'"
            " USING DETAIL = 'd', HINT = 'h'; END $$"
        ),
    )
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.sqlstate, "P0001")
    assert_equal(error.message, "boom")
    assert_equal(error.detail, "d")
    assert_equal(error.hint, "h")
    assert_true(error.context.find("inline_code_block") >= 0)

    _ = conn^


def test_empty_query_is_server_error() raises:
    var conn = _connect(_conninfo())

    var empty = _execute_error(conn, "")
    assert_true(empty.kind == PgErrorKind.SERVER)
    assert_equal(empty.message, "empty query")

    var blank = _execute_error(conn, "   ")
    assert_true(blank.kind == PgErrorKind.SERVER)
    assert_equal(blank.message, "empty query")

    _ = conn^


# --- multiple statements -----------------------------------------------------


def test_multi_statement_returns_last_result() raises:
    var conn = _connect(_conninfo())
    var result = _execute(
        conn, "CREATE TEMP TABLE t(x int); INSERT INTO t VALUES (1),(2)"
    )
    assert_equal(result.affected_rows(), 2)
    _ = result^
    _ = conn^


def test_multi_statement_reports_failing_statement() raises:
    var conn = _connect(_conninfo())
    var error = _execute_error(conn, "SELECT 1; SELEC 2; SELECT 3")
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.sqlstate, "42601")
    _ = conn^


# --- a connection that dies under us -----------------------------------------


def test_terminated_backend_then_connection_error() raises:
    var conn = _connect(_conninfo())

    # Measured on PG14 and PG17: libpq never delivers the server's FATAL
    # 57P01 here. The socket closes first, so `PQexec` yields a client-side
    # PGRES_FATAL_ERROR carrying no SQLSTATE and the message "server closed
    # the connection unexpectedly".
    #
    # An empty SQLSTATE on a connection libpq has marked CONNECTION_BAD means
    # the connection is gone, not that the statement was rejected, so
    # `execute` reports CONNECTION -- matching what `PgErrorKind.CONNECTION`
    # promises ("no longer usable"). The error text is still libpq's own.
    var first = _execute_error(
        conn, "SELECT pg_terminate_backend(pg_backend_pid())"
    )
    assert_true(first.kind == PgErrorKind.CONNECTION)
    assert_equal(first.sqlstate, "")
    assert_true(
        first.message.find("server closed the connection unexpectedly") >= 0
    )

    # Once the backend is gone the connection is unusable, with no ambiguity.
    var second = _execute_error(conn, "SELECT 1")
    assert_true(second.kind == PgErrorKind.CONNECTION)
    assert_true(second.message != "")

    _ = conn^


def test_copy_out_stays_a_server_error() raises:
    var conn = _connect(_conninfo())

    # COPY is out of scope for `execute`: PQexec returns PGRES_COPY_OUT (3),
    # which carries no diagnostic at all, so the status text is the message
    # and the SQLSTATE is empty. The connection is still fine, which is the
    # other half of the rule the terminated-backend test exercises -- an empty
    # SQLSTATE alone must not turn a SERVER error into a CONNECTION one.
    var error = _execute_error(conn, "COPY (SELECT 1) TO STDOUT")
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(error.sqlstate, "")
    assert_equal(error.message, "unexpected result status 3")
    assert_equal(conn.status(), Int(CONNECTION_OK))

    _ = conn^


# --- embedded NUL bytes ------------------------------------------------------
#
# Every entry point that hands caller text to libpq refuses an embedded NUL
# before calling it. Without that check libpq would see the value cut at the
# NUL and act on the truncated prefix: a conninfo would connect somewhere
# else, a statement would run in part, a column lookup would match the wrong
# column. Each test therefore asserts the *message* too, since that is what
# proves the truncated tail was never used or echoed.


def test_open_conninfo_rejects_embedded_nul() raises:
    # The NUL lands inside a password value, so this also covers the "no
    # credentials in the message" rule for the conninfo form.
    var error = _open_error(_with_nul(_conninfo() + " password="))
    _assert_nul_error(error, "conninfo")


def test_open_params_rejects_embedded_nul_in_value() raises:
    var params = _params()
    params["password"] = _with_nul(String(WRONG_PASSWORD))
    var error = _open_params_error(params)
    _assert_nul_error(error, "params value")
    assert_false(error.message.find(WRONG_PASSWORD) >= 0)


def test_open_params_rejects_embedded_nul_in_key() raises:
    var params = _params()
    params[_with_nul("application_name")] = "x"
    var error = _open_params_error(params)
    _assert_nul_error(error, "params key")


def test_execute_rejects_embedded_nul() raises:
    var conn = _connect(_conninfo())

    # Truncated, this would run `SELECT 1` and silently drop the DROP.
    var error = _execute_error(conn, _with_nul("SELECT 1; DROP TABLE "))
    _assert_nul_error(error, "sql")

    # Nothing was sent, so the connection is untouched and still usable.
    assert_equal(conn.status(), Int(CONNECTION_OK))
    var ok = _execute(conn, "SELECT 1")
    assert_equal(ok.row_count(), 1)
    _ = ok^
    _ = conn^


def test_escape_rejects_embedded_nul() raises:
    var conn = _connect(_conninfo())

    _assert_nul_error(_escape_literal_error(conn, _with_nul("a")), "s")
    _assert_nul_error(_escape_identifier_error(conn, _with_nul("a")), "s")

    # Quoting is a client-side call, so the connection cannot have changed;
    # check anyway, because a rejected argument must leave no trace.
    assert_equal(conn.status(), Int(CONNECTION_OK))
    assert_equal(_escape_literal(conn, "a"), "'a'")
    _ = conn^


def test_column_lookup_rejects_embedded_nul() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, "SELECT 1 AS a")

    # Truncated to "a", every one of these would have found column 0.
    var name = _with_nul("a")
    _assert_nul_error(_column_index_error(result, name), "name")
    _assert_nul_error(_row_get_error(result, name), "name")
    _assert_nul_error(_row_get_optional_error(result, name), "name")

    # The result is read-only here, so the rejection cannot disturb it.
    assert_equal(_column_index(result, "a"), 0)
    assert_equal(result.row_count(), 1)

    _ = result^
    _ = conn^


# --- Result ------------------------------------------------------------------


def test_result_outlives_connection() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, "SELECT 1")
    _ = conn^
    assert_equal(result.row_count(), 1)
    assert_equal(result.column_count(), 1)
    _ = result^


def test_zero_rows_keeps_columns() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, "SELECT 1 WHERE false")
    assert_equal(result.row_count(), 0)
    assert_equal(len(result), 0)
    assert_equal(result.column_count(), 1)
    _ = result^
    _ = conn^


def test_column_lookup_rejects_bad_index_and_name() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, "SELECT 1 AS a")

    assert_equal(_column_name(result, 0), "a")
    assert_equal(_column_index(result, "a"), 0)

    # Rejected before libpq is asked, so nothing is written to stderr.
    assert_true(_column_index_kind(result, "nope") == PgErrorKind.TYPE_MISMATCH)
    assert_true(_column_name_kind(result, 5) == PgErrorKind.TYPE_MISMATCH)
    assert_true(_column_name_kind(result, -1) == PgErrorKind.TYPE_MISMATCH)

    _ = result^
    _ = conn^


def test_column_type_oid_reports_int4() raises:
    var conn = _connect(_conninfo())
    var result = _execute(conn, "SELECT 1::int4")
    assert_equal(_column_type_oid(result, 0), UInt32(23))
    assert_true(_column_type_oid_kind(result, 5) == PgErrorKind.TYPE_MISMATCH)
    _ = result^
    _ = conn^


# --- quoting -----------------------------------------------------------------


def test_escape_literal_doubles_quotes() raises:
    var conn = _connect(_conninfo())
    assert_equal(_escape_literal(conn, "O'Reilly"), "'O''Reilly'")
    _ = conn^


def test_escape_literal_uses_e_string_for_backslash() raises:
    var conn = _connect(_conninfo())
    # A backslash forces libpq's E-string form, whose leading space is
    # intentional so the result can be pasted straight after a keyword.
    var quoted = _escape_literal(conn, "a\\b")
    assert_equal(quoted[byte=0:3], " E'")
    _ = conn^


def test_escape_identifier_doubles_double_quotes() raises:
    var conn = _connect(_conninfo())
    assert_equal(_escape_identifier(conn, 'x"y'), '"x""y"')
    _ = conn^


# --- connection introspection ------------------------------------------------


def test_server_version_is_at_least_14() raises:
    var conn = _connect(_conninfo())
    assert_true(conn.server_version() >= 140000)
    _ = conn^


def test_status_is_connection_ok() raises:
    var conn = _connect(_conninfo())
    assert_equal(conn.status(), Int(CONNECTION_OK))
    _ = conn^


def test_transaction_status_follows_the_transaction() raises:
    var conn = _connect(_conninfo())
    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))

    var begun = _execute(conn, "BEGIN")
    _ = begun^
    assert_equal(conn.transaction_status(), Int(PQTRANS_INTRANS))

    var error = _execute_error(conn, "SELEC 1")
    assert_true(error.kind == PgErrorKind.SERVER)
    assert_equal(conn.transaction_status(), Int(PQTRANS_INERROR))

    var rolled_back = _execute(conn, "ROLLBACK")
    _ = rolled_back^
    assert_equal(conn.transaction_status(), Int(PQTRANS_IDLE))

    _ = conn^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
