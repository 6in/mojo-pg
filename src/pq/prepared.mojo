"""Server-side prepared statement, owned and `DEALLOCATE`d on destruction.

`Connection.prepare` sends `PQprepare`, then immediately `PQdescribePrepared`
to learn how many parameters the server resolved and what types it gave them,
and returns a `PreparedStatement` holding the statement name and that type
list. `PreparedStatement.execute` runs it with `PQexecPrepared`.

The statement is a *borrowed view* of its `Connection`: it carries a
`Pointer[Connection, origin]` rather than a copy. A `PreparedStatement` is
bound to the `Connection`'s origin, so using it after the connection has been
**moved away** (`var c2 = conn^`, or passing `conn^` to a function) is a
compile error (`use of uninitialized value`) instead of a call through a
closed `PGconn*`. `_ = conn^` is **not** a destroy: it is a keep-alive
marker, and `PQfinish` runs after the last use of any statement borrowed from
the connection. It is `Movable` but deliberately **not**
`Copyable`: a copy would hand the same statement name to two destructors and
the second `DEALLOCATE` would be sent for a name that no longer exists.

## Parameter count is checked client-side

`execute` compares `len(params)` against the count the server reported and
raises `PgErrorKind.USAGE` on a mismatch **without sending anything**. That is
deliberate rather than an optimisation: `PQexecPrepared` with the wrong number
of parameters is protocol error `08P01`, which aborts an open transaction, so
a caller typo inside a `Transaction` would cost the whole transaction instead
of one statement.

## Destruction time is where `DEALLOCATE` happens (ASAP destruction)

Mojo destroys a value right after the **last line that uses it**, not at the
end of the enclosing scope, and that is when `DEALLOCATE <name>` is sent. So
to observe the statement's own effects, keep it alive explicitly and check
afterwards:

    var stmt = conn.prepare("SELECT $1::int4")
    var r = stmt.execute([Param(Int32(1))])
    _ = stmt^  # last use: DEALLOCATE is sent here
    var gone = conn.execute("SELECT count(*) FROM pg_prepared_statements")

`_ = stmt^` is a "keep it alive until here" marker, not an eager free.

## `PREPARE` is not transactional

A statement prepared inside a transaction survives `ROLLBACK`: PostgreSQL does
not roll back the prepared-statement namespace, so `execute` still succeeds
afterwards. What a rollback *can* undo is everything the statement refers to --
a table created in the rolled-back transaction is gone, so the next `execute`
fails with a server error even though the statement itself is still there.

`__deinit__` ignores every failure. It sends `DEALLOCATE` through a raw
`PQexec` and never looks at the result or the connection state, because a
destructor cannot raise: a statement already dropped by hand (`26000`), an
aborted transaction (`25P02`) and a lost connection all pass silently, and no
hook is called for them.
"""

from std.ffi import c_int

from pq._ffi.types import CStr
from pq.connection import Connection
from pq.errors import PgError, PgErrorKind
from pq.params import Param, _ParamBuffers
from pq.result import Result


struct PreparedStatement[origin: ImmOrigin](Movable):
    """A named prepared statement on a live `Connection`.

    Built by `Connection.prepare`, which has already run `PQprepare` and
    `PQdescribePrepared`, so the parameter types are known and need no further
    round trip. Destroying the value sends `DEALLOCATE` for the statement; see
    the module docstring for when that happens and why every failure of it is
    ignored.

    `PREPARE` is not transactional, so a statement prepared inside a
    transaction still exists after `ROLLBACK` -- but anything it refers to may
    not: once a rollback undoes DDL from inside the transaction, a later
    `execute` of the surviving statement can come back as a server error.

    Parameters:
        origin: Immutable origin of the borrowed `Connection`.
    """

    var _conn: Pointer[Connection, Self.origin]
    """Borrowed connection the statement lives on."""

    var _name: String
    """Server-side statement name, always of the form `pq_stmt_<n>`."""

    var _param_types: List[UInt32]
    """Type OID the server resolved for each parameter, in `$1`..`$n` order."""

    def __init__(
        out self,
        conn: Pointer[Connection, Self.origin],
        var name: String,
        var param_types: List[UInt32],
    ):
        """Adopt an already-prepared statement name.

        Args:
            conn: Pointer to the connection the statement was prepared on.
            name: The name `PQprepare` was called with. Taken by value because
                this value becomes responsible for `DEALLOCATE`ing it.
            param_types: Type OIDs as reported by `PQdescribePrepared`.
        """
        self._conn = conn
        self._name = name^
        self._param_types = param_types^

    def __deinit__(deinit self):
        """Send `DEALLOCATE` for the statement, ignoring every outcome.

        The name is generated by `Connection._next_stmt_name` and therefore
        matches `[a-z0-9_]+`, so it is interpolated into the SQL without
        quoting; no caller text reaches this statement. The call goes through
        the raw `PQexec` rather than `Connection.execute` because a destructor
        cannot raise, and neither the result status nor the connection status
        is inspected -- see the module docstring.
        """
        var pq = self._conn[]._pq
        var sql = String("DEALLOCATE ", self._name)
        var res = pq[].PQexec(
            self._conn[]._conn,
            CStr(unsafe_from_address=Int(sql.as_c_string_span().ptr())),
        )
        _ = sql^
        if not res.is_null():
            pq[].PQclear(res)

    def execute(self, params: List[Param]) raises PgError -> Result:
        """Run the statement with `params` via `PQexecPrepared`.

        Placeholders are `$1` through `$n`, so `params[0]` binds `$1`, and the
        value types follow the same table as `Connection.execute(sql, params)`.

        The parameter count is checked against `param_count()` first and a
        mismatch is rejected client-side, so nothing is sent to the server and
        an open transaction is left usable. Embedded NUL bytes in text
        parameters are rejected next, also before anything is sent.

        A prepared statement binds values of the **same width** the server
        resolved at `PQprepare` time: `$1::int4` wants `Int32`, and passing
        `Int` (`int8`) is SQLSTATE `22P03`. `param_type_oid(i)` is what the
        server resolved, so it is the authority on which width to send.

        Results always come back in text form; a binary `result_format` is
        Phase 3.

        The result is adopted by `Connection._take_result`, the same path
        `Connection.execute` takes, so failures are classified identically.

        Args:
            params: The values to bind, `params[0]` binding `$1`.

        Returns:
            The `Result` of the statement, owning the `PGresult*`.

        Raises:
            PgError: `PgErrorKind.USAGE` when `len(params)` differs from
                `param_count()` (`prepared statement "<name>" takes K
                parameters, got M`) or when a `String` parameter contains a
                NUL byte (`embedded NUL byte in parameter $N`); nothing is
                sent to the server in either case. Otherwise
                `PgErrorKind.CONNECTION` when libpq returns no result at all
                or the connection was lost and libpq reported it without an
                SQLSTATE, or `PgErrorKind.SERVER` when the server reports a
                diagnostic -- including `26000` for a statement that has since
                been dropped by hand -- carrying `sqlstate`, `severity`,
                `detail`, `hint`, `position` and `context` when libpq supplies
                them.
        """
        if len(params) != len(self._param_types):
            raise PgError(
                PgErrorKind.USAGE,
                String(
                    'prepared statement "',
                    self._name,
                    '" takes ',
                    len(self._param_types),
                    " parameters, got ",
                    len(params),
                ),
            )
        var buffers = _ParamBuffers(params)
        # `as_c_string_span()` is `mut self`, so the name needs an owned copy;
        # `self` is immutable here. It stays alive until after the call.
        var name = self._name.copy()
        var pq = self._conn[]._pq
        var res = pq[].PQexecPrepared(
            self._conn[]._conn,
            CStr(unsafe_from_address=Int(name.as_c_string_span().ptr())),
            c_int(buffers.count()),
            buffers.values_ptr(),
            buffers.lengths_ptr(),
            buffers.formats_ptr(),
            c_int(0),
        )
        # After the call: libpq reads through the buffer addresses for the
        # duration of PQexecPrepared, so dropping them earlier is a use after
        # free. `PQexecPrepared` has no `paramTypes` argument -- the types were
        # fixed by `PQprepare` -- so `buffers.types_ptr()` is never passed.
        _ = buffers^
        _ = name^
        return self._conn[]._take_result(res)

    def param_count(self) -> Int:
        """Return the number of parameters the statement takes.

        This is the count `PQdescribePrepared` reported, which is what the
        server resolved from the SQL rather than what the caller guessed: a
        statement whose text uses no placeholders takes 0 parameters even when
        `prepare` was given a `param_types` list.

        Returns:
            The parameter count, 0 for a statement with no placeholders.
        """
        return len(self._param_types)

    def param_type_oid(self, i: Int) raises PgError -> UInt32:
        """Return the PostgreSQL type OID of parameter `i`.

        Indices are zero-based, so `$1` is index 0.

        Args:
            i: Zero-based parameter index.

        Returns:
            The `PQparamtype` OID the server resolved for that parameter,
            matching the `OID_*` constants in `pq.decode_text`.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `i` is outside
                `0..param_count() - 1`, which includes every negative index. A
                statement that takes no parameters has no valid index at all,
                and says so (`statement takes no parameters`) rather than
                naming the empty range `0..-1`.
        """
        if len(self._param_types) == 0:
            raise PgError(
                PgErrorKind.TYPE_MISMATCH,
                String(
                    "parameter index ",
                    i,
                    " out of range (statement takes no parameters)",
                ),
            )
        if i < 0 or i >= len(self._param_types):
            raise PgError(
                PgErrorKind.TYPE_MISMATCH,
                String(
                    "parameter index ",
                    i,
                    " out of range (0..",
                    len(self._param_types) - 1,
                    ")",
                ),
            )
        return self._param_types[i]

    def name(self) -> String:
        """Return the server-side name of the statement.

        The name is generated by `pq`, of the form `pq_stmt_<n>` numbered from
        1 per connection, and is what appears in `pg_prepared_statements`. It
        is useful for `DEALLOCATE` or `EXECUTE` sent as plain SQL.

        Returns:
            An owned copy of the statement name.
        """
        return self._name.copy()
