"""Explicit transaction block, rolled back on destruction unless ended.

`Connection.transaction` sends `BEGIN` and returns a `Transaction` holding a
borrowed pointer to the connection, a flag saying whether the block was
already ended, and a copy of the connection's rollback-failure handler.
`commit` and `rollback` end the block explicitly; destroying a `Transaction`
that was never ended sends `ROLLBACK`, so an error path that simply returns
cannot leave the block open.

The transaction is a *borrowed view* of its `Connection`, exactly as
`PreparedStatement` is: it carries a `Pointer[Connection, origin]` rather
than a copy. A `Transaction` is bound to the `Connection`'s origin, so using
it after the connection has been **moved away** (`var c2 = conn^`, or passing
`conn^` to a function) is a compile error (`use of uninitialized value`).
`_ = conn^` is **not** a destroy: it is a keep-alive marker, and `PQfinish`
runs after the last use of any transaction borrowed from the connection. It
is `Movable` but deliberately **not** `Copyable`: a copy
would hand the same open block to two destructors, and the second `ROLLBACK`
would be sent for a block the first one already closed.

## `BEGIN` is only sent from an idle connection

`Connection.transaction` refuses a connection whose `PQtransactionStatus` is
not `PQTRANS_IDLE` with `PgErrorKind.USAGE` and sends nothing, so a nested
`conn.transaction()` is a caller error rather than a `WARNING: there is
already a transaction in progress` the caller never sees. A connection that
is already *dead* is reported as `PgErrorKind.CONNECTION` instead: losing the
server is not an API misuse. The dead-connection test comes first, because
`PQtransactionStatus` answers `PQTRANS_UNKNOWN` for a bad connection and that
would otherwise be reported as the caller's mistake.

## Destruction time is where the implicit `ROLLBACK` happens

Mojo destroys a value right after the **last line that uses it**, not at the
end of the enclosing scope, and that is when the implicit `ROLLBACK` is sent.
A `Transaction` therefore ends much earlier than a `with` block in Python
would, which is why the `Transaction` docstring asks for `commit()`,
`rollback()` or `_ = tx^` on the last line that mentions it.

## The connection stays usable inside the block

The borrow is immutable, so `conn.execute(...)` keeps compiling while a
`Transaction` is alive, and the statement runs inside the open block because
the block belongs to the connection, not to the value. That is useful --
`Connection.prepare` and `Connection.execute` need no transaction-aware
overload -- but it is also the one way to be surprised by ASAP destruction;
the negative example in the `Transaction` docstring spells it out.

## `__deinit__` reports instead of raising

A destructor cannot raise, so a failed implicit `ROLLBACK` is handed to the
handler the `Transaction` copied when `transaction()` was called rather than
propagated. The default handler is `_default_rollback_failure_handler`, which
writes one line to stderr; `Connection.set_rollback_failure_handler` replaces
it for transactions started afterwards. The `ROLLBACK` goes through the raw
`PQexec` for the same reason, and its result is classified the same way
`Connection._take_result` classifies one.
"""

from std.sys import stderr

from pq._ffi.types import (
    CONNECTION_BAD,
    CStr,
    PG_DIAG_CONTEXT,
    PG_DIAG_MESSAGE_DETAIL,
    PG_DIAG_MESSAGE_HINT,
    PG_DIAG_MESSAGE_PRIMARY,
    PG_DIAG_SEVERITY,
    PG_DIAG_SEVERITY_NONLOCALIZED,
    PG_DIAG_SQLSTATE,
    PG_DIAG_STATEMENT_POSITION,
    PGRES_COMMAND_OK,
)
from pq.connection import Connection, _error_field
from pq.errors import PgError, PgErrorKind, _reject_nul
from pq.params import Param
from pq.prepared import PreparedStatement
from pq.result import Result


def _default_rollback_failure_handler(e: PgError):
    """Report a failed implicit `ROLLBACK` on stderr and continue.

    This is what a `Connection` starts with, and what a `Transaction`
    destructor calls unless `Connection.set_rollback_failure_handler`
    installed something else before `transaction()` was called. It writes a
    single line and never raises, because it runs from a destructor.

    Args:
        e: The error the implicit `ROLLBACK` produced.
    """
    print("pq: implicit ROLLBACK failed: ", e.message, sep="", file=stderr)


struct Transaction[origin: ImmOrigin](Movable):
    """An open transaction block on a live `Connection`.

    Built by `Connection.transaction`, which has already sent `BEGIN`. End it
    with `commit()` or `rollback()`; a value destroyed without either sends
    `ROLLBACK`.

    ## Use the value on its last line, or the block ends early

    Destruction is ASAP: the implicit `ROLLBACK` is sent right after the last
    line that mentions the transaction, not at the end of the scope. So put
    `commit()`, `rollback()` or the `_ = tx^` marker on the last line of the
    block:

        var tx = conn.transaction()
        _ = tx.execute("INSERT INTO t VALUES (1)")
        tx.commit()  # last use: COMMIT is sent here

    Going through the connection instead moves the end of the block, because
    the connection is still usable while the transaction is alive:

        var tx = conn.transaction()
        _ = tx.execute(a)  # last use of tx: ROLLBACK is sent here
        conn.execute(b)  # b therefore runs OUTSIDE the transaction

    Both statements compile, and `a` is rolled back while `b` is not. Mixing
    `tx.execute` and `conn.execute` is fine as long as the transaction is the
    one used last; `_ = tx^` is a "keep it alive until here" marker for that.

    Sending `COMMIT` / `ROLLBACK` by hand through `conn.execute` ends the
    block on the server; the implicit `ROLLBACK` at destruction then draws a
    server `WARNING: there is no transaction in progress`, and the data stays
    as the manual command left it.

    Parameters:
        origin: Immutable origin of the borrowed `Connection`.
    """

    var _conn: Pointer[Connection, Self.origin]
    """Borrowed connection the transaction block is open on."""

    var _done: Bool
    """True once `commit` or `rollback` ran, which disarms `__deinit__`."""

    var _handler: def(PgError) thin
    """Handler for a failed implicit `ROLLBACK`, copied at construction."""

    def __init__(
        out self,
        conn: Pointer[Connection, Self.origin],
        handler: def(PgError) thin,
    ):
        """Adopt a transaction block whose `BEGIN` has already been sent.

        Args:
            conn: Pointer to the connection the `BEGIN` was sent on.
            handler: The connection's rollback-failure handler, copied here so
                that replacing it later does not change this value.
        """
        self._conn = conn
        self._done = False
        self._handler = handler

    def __deinit__(deinit self):
        """Send the implicit `ROLLBACK` unless the block was already ended.

        A destructor cannot raise, so the outcome is classified here and
        passed to the handler this value copied at construction time instead
        of propagating. The call goes through the raw `PQexec` rather than
        `Connection.execute` for the same reason. Classification matches
        `Connection._take_result`: no result at all is
        `PgErrorKind.CONNECTION`, a diagnostic without an SQLSTATE on a
        connection that is also gone is `PgErrorKind.CONNECTION`, and
        everything else the server reported is `PgErrorKind.SERVER`.
        """
        if self._done:
            return
        var pq = self._conn[]._pq
        var conn = self._conn[]._conn
        var sql = String("ROLLBACK")
        var res = pq[].PQexec(
            conn,
            CStr(unsafe_from_address=Int(sql.as_c_string_span().ptr())),
        )
        _ = sql^
        if res.is_null():
            # No PGresult was allocated, so there is nothing to PQclear.
            self._handler(
                PgError(
                    PgErrorKind.CONNECTION,
                    String(unsafe_from_utf8_ptr=pq[].PQerrorMessage(conn)),
                )
            )
            return
        if pq[].PQresultStatus(res) == PGRES_COMMAND_OK:
            pq[].PQclear(res)
            return
        # Every diagnostic is copied into owned Strings before PQclear frees
        # the PGresult the field pointers point into.
        var severity = _error_field(pq, res, PG_DIAG_SEVERITY_NONLOCALIZED)
        if severity == "":
            severity = _error_field(pq, res, PG_DIAG_SEVERITY)
        var sqlstate = _error_field(pq, res, PG_DIAG_SQLSTATE)
        var message = _error_field(pq, res, PG_DIAG_MESSAGE_PRIMARY)
        if message == "":
            message = String(
                unsafe_from_utf8_ptr=pq[].PQresultErrorMessage(res)
            )
        var detail = _error_field(pq, res, PG_DIAG_MESSAGE_DETAIL)
        var hint = _error_field(pq, res, PG_DIAG_MESSAGE_HINT)
        var position = _error_field(pq, res, PG_DIAG_STATEMENT_POSITION)
        var context = _error_field(pq, res, PG_DIAG_CONTEXT)
        pq[].PQclear(res)
        var kind = PgErrorKind.SERVER
        if sqlstate == "" and pq[].PQstatus(conn) == CONNECTION_BAD:
            kind = PgErrorKind.CONNECTION
        self._handler(
            PgError(
                kind,
                message,
                sqlstate=sqlstate,
                severity=severity,
                detail=detail,
                hint=hint,
                position=position,
                context=context,
            )
        )

    def _check_open(self) raises PgError:
        """Reject every command once the block has been ended.

        Called first by every method, so a `commit` after a `commit` and a
        `savepoint` after a `rollback` both fail client-side with nothing
        sent to the server.

        Raises:
            PgError: `PgErrorKind.USAGE` (`transaction already ended`) when
                `commit` or `rollback` already ran.
        """
        if self._done:
            raise PgError(PgErrorKind.USAGE, "transaction already ended")

    def commit(mut self) raises PgError:
        """End the block with `COMMIT`.

        The value is marked ended *before* the `COMMIT` goes out, so a failure
        here is not followed by a second attempt from `__deinit__`; the block
        is over either way, and PostgreSQL has already closed it.

        A `COMMIT` sent inside a transaction that the server aborted succeeds
        at the protocol level but reports the command tag `ROLLBACK`: nothing
        was committed. That tag is read back here and raised as
        `PgErrorKind.SERVER`, because a `commit()` that returns normally has
        to mean the work is durable.

        Raises:
            PgError: `PgErrorKind.USAGE` when the block was already ended,
                `PgErrorKind.SERVER` with an empty `sqlstate` when the server
                answered the `COMMIT` with a `ROLLBACK` command tag (`COMMIT
                resulted in ROLLBACK: the transaction was aborted`), or
                `PgErrorKind.CONNECTION` / `PgErrorKind.SERVER` under exactly
                the classification `Connection._take_result` applies.
        """
        self._check_open()
        # Marked ended before sending: a failed COMMIT must not be retried by
        # the destructor.
        self._done = True
        var res = self._conn[].execute("COMMIT")
        if res.command_tag() == "ROLLBACK":
            raise PgError(
                PgErrorKind.SERVER,
                "COMMIT resulted in ROLLBACK: the transaction was aborted",
                sqlstate="",
            )

    def rollback(mut self) raises PgError:
        """End the block with `ROLLBACK`.

        This is the same statement `__deinit__` would send, run explicitly so
        that its failure is raised instead of handed to the rollback-failure
        handler. As in `commit`, the value is marked ended before the
        statement goes out, so the destructor does not send a second one.

        A `ROLLBACK` succeeds on an aborted transaction, so this is the way
        out of a block whose statements failed.

        Raises:
            PgError: `PgErrorKind.USAGE` when the block was already ended, or
                `PgErrorKind.CONNECTION` / `PgErrorKind.SERVER` under exactly
                the classification `Connection._take_result` applies.
        """
        self._check_open()
        self._done = True
        _ = self._conn[].execute("ROLLBACK")

    def savepoint(self, var name: String) raises PgError:
        """Establish a savepoint called `name` inside the block.

        `name` is quoted with `Connection.escape_identifier` before it reaches
        the SQL, so any text is safe to pass and a savepoint called `select`
        or `a"b` works. Quoting makes the name case-sensitive: `savepoint("S")`
        has to be released as `"S"`, not as `s`.

        Re-establishing an existing name is allowed and is what PostgreSQL
        does with it -- the older savepoint of that name stays on the stack and
        becomes reachable again once the newer one is released.

        Args:
            name: The savepoint name, taken by value because it is handed to
                `escape_identifier`.

        Raises:
            PgError: `PgErrorKind.USAGE` when the block was already ended or
                `name` is empty (`savepoint name must not be empty`),
                `PgErrorKind.TYPE_MISMATCH` when `name` contains a NUL byte
                (`embedded NUL byte in name`), or `PgErrorKind.CONNECTION` /
                `PgErrorKind.SERVER` under exactly the classification
                `Connection._take_result` applies.
        """
        self._check_open()
        # Checked here rather than left to `escape_identifier`, whose own
        # `_reject_nul` would name its parameter instead of this one.
        _reject_nul(name, "name")
        if name == "":
            raise PgError(PgErrorKind.USAGE, "savepoint name must not be empty")
        var ident = self._conn[].escape_identifier(name^)
        _ = self._conn[].execute(String("SAVEPOINT ", ident))

    def rollback_to(self, var name: String) raises PgError:
        """Undo the block back to the savepoint called `name`.

        Sends `ROLLBACK TO SAVEPOINT`, which keeps the transaction open and
        keeps the savepoint itself, so the same name can be rolled back to
        again. It is also the way to make an aborted transaction usable again
        without losing the work before the savepoint.

        The name is quoted exactly as in `savepoint`, and a name that was
        never established -- or was already released -- is left to the server,
        which reports SQLSTATE `3B001`.

        Args:
            name: The savepoint name, taken by value because it is handed to
                `escape_identifier`.

        Raises:
            PgError: `PgErrorKind.USAGE` when the block was already ended or
                `name` is empty (`savepoint name must not be empty`),
                `PgErrorKind.TYPE_MISMATCH` when `name` contains a NUL byte
                (`embedded NUL byte in name`), or `PgErrorKind.CONNECTION` /
                `PgErrorKind.SERVER` under exactly the classification
                `Connection._take_result` applies, including `3B001` for a
                savepoint that does not exist.
        """
        self._check_open()
        # See `savepoint` for why the NUL check is not left to
        # `escape_identifier`.
        _reject_nul(name, "name")
        if name == "":
            raise PgError(PgErrorKind.USAGE, "savepoint name must not be empty")
        var ident = self._conn[].escape_identifier(name^)
        _ = self._conn[].execute(String("ROLLBACK TO SAVEPOINT ", ident))

    def release(self, var name: String) raises PgError:
        """Discard the savepoint called `name`, keeping its work.

        Sends `RELEASE SAVEPOINT`, which drops the savepoint and every
        savepoint established after it, without undoing anything. The name is
        quoted exactly as in `savepoint`, and a name that does not exist is
        left to the server, which reports SQLSTATE `3B001`.

        Args:
            name: The savepoint name, taken by value because it is handed to
                `escape_identifier`.

        Raises:
            PgError: `PgErrorKind.USAGE` when the block was already ended or
                `name` is empty (`savepoint name must not be empty`),
                `PgErrorKind.TYPE_MISMATCH` when `name` contains a NUL byte
                (`embedded NUL byte in name`), or `PgErrorKind.CONNECTION` /
                `PgErrorKind.SERVER` under exactly the classification
                `Connection._take_result` applies, including `3B001` for a
                savepoint that does not exist.
        """
        self._check_open()
        # See `savepoint` for why the NUL check is not left to
        # `escape_identifier`.
        _reject_nul(name, "name")
        if name == "":
            raise PgError(PgErrorKind.USAGE, "savepoint name must not be empty")
        var ident = self._conn[].escape_identifier(name^)
        _ = self._conn[].execute(String("RELEASE SAVEPOINT ", ident))

    def execute(self, var sql: String) raises PgError -> Result:
        """Run `sql` inside the block, delegating to `Connection.execute`.

        The only thing added to `Connection.execute` is the check that the
        block is still open, so semicolon-separated statements, the
        last-statement result and the error classification are all exactly as
        documented there. `conn.execute(sql)` on the borrowed connection runs
        inside the same block; what this method buys is that it counts as a
        use of the transaction and so keeps it alive.

        Args:
            sql: One or more SQL statements.

        Returns:
            The `Result` of the last statement, owning the `PGresult*`.

        Raises:
            PgError: `PgErrorKind.USAGE` when the block was already ended,
                otherwise whatever `Connection.execute` raises. A failing
                statement leaves the transaction aborted, so the next command
                needs `rollback()` or `rollback_to()`.
        """
        self._check_open()
        return self._conn[].execute(sql^)

    def execute(
        self, var sql: String, params: List[Param]
    ) raises PgError -> Result:
        """Run one parameterised statement inside the block.

        Delegates to `Connection.execute(sql, params)` once the block is known
        to be open, so this is a single statement with `$1`..`$n` placeholders
        and the same `Param` type table; `SELECT 1; SELECT 2` is rejected by
        the server with `42601` exactly as it is there.

        Args:
            sql: Exactly one SQL statement, using `$1`..`$n` placeholders.
            params: The values to bind, `params[0]` binding `$1`.

        Returns:
            The `Result` of the statement, owning the `PGresult*`.

        Raises:
            PgError: `PgErrorKind.USAGE` when the block was already ended,
                otherwise whatever `Connection.execute(sql, params)` raises. A
                failing statement leaves the transaction aborted, so the next
                command needs `rollback()` or `rollback_to()`.
        """
        self._check_open()
        return self._conn[].execute(sql^, params)

    def prepare(
        self,
        var sql: String,
        param_types: List[UInt32] = List[UInt32](),
    ) raises PgError -> PreparedStatement[Self.origin]:
        """Prepare `sql` while the block is open, as `Connection.prepare` does.

        Nothing about the statement is transactional: `PREPARE` is not rolled
        back, so the returned handle keeps working after the block ends -- see
        the `pq.prepared` module docstring. The statement borrows the same
        connection this transaction borrows, so it carries this transaction's
        `origin` and may outlive the transaction itself.

        The two round trips are `Connection._prepare_parts`, shared with
        `Connection.prepare`; only the final value is built here, on this
        transaction's own borrow rather than on a borrow derived from it.

        Args:
            sql: Exactly one SQL statement, using `$1`..`$n` placeholders.
            param_types: Optional type OID hints, `param_types[0]` for `$1`.
                An entry of 0 asks the server to infer that parameter.

        Returns:
            A `PreparedStatement` bound to the borrowed connection's origin.

        Raises:
            PgError: `PgErrorKind.USAGE` when the block was already ended,
                otherwise whatever `Connection.prepare` raises.
        """
        self._check_open()
        var types = List[UInt32]()
        var name = self._conn[]._prepare_parts(sql^, param_types, types)
        return PreparedStatement[Self.origin](self._conn, name^, types^)
