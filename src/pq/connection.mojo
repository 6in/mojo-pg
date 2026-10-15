"""Synchronous PostgreSQL connection built on `PQconnectdb` and `PQexec`.

`Connection` owns one `PGconn*` and the process-wide `LibpqFFI` table it was
opened with. It is `Movable` but deliberately not `Copyable`: a libpq
connection is not thread-safe and must be handed to `PQfinish` exactly once,
so `var b = a` is a compile error and ownership transfers with `a^` instead.

`pq` never adds the caller's conninfo or parameter dictionary to a raised
message: the text is always libpq's own `PQerrorMessage`. libpq does not echo
the password when authentication fails, but it *does* echo the offending
fragment of a malformed conninfo string -- `missing "=" after "<token>"` or
`invalid percent-encoded token` -- so a password mistyped as `password=sec ret`
reaches the error as `missing "=" after "ret"`. Pass credentials your program
holds through `open(Dict)`, where each value is taken literally and never
parsed.
"""

from std.ffi import c_int, c_size_t

from pq._ffi.functions import LibpqFFI
from pq._ffi.loader import libpq_ptr
from pq._ffi.types import (
    CONNECTION_BAD,
    CONNECTION_OK,
    CStr,
    CStrArray,
    IntPtr,
    MutRawPtr,
    OidPtr,
    PG_DIAG_CONTEXT,
    PG_DIAG_MESSAGE_DETAIL,
    PG_DIAG_MESSAGE_HINT,
    PG_DIAG_MESSAGE_PRIMARY,
    PG_DIAG_SEVERITY,
    PG_DIAG_SEVERITY_NONLOCALIZED,
    PG_DIAG_SQLSTATE,
    PG_DIAG_STATEMENT_POSITION,
    PGRES_COMMAND_OK,
    PGRES_EMPTY_QUERY,
    PGRES_TUPLES_OK,
    PGconnPtr,
    PGresultPtr,
    PQTRANS_IDLE,
)
from pq.errors import PgError, PgErrorKind, _reject_nul
from pq.params import Param, _ParamBuffers
from pq.prepared import PreparedStatement
from pq.result import Result
from pq.transaction import Transaction, _default_rollback_failure_handler


def _error_field(
    pq: Pointer[LibpqFFI, MutUntrackedOrigin],
    res: PGresultPtr,
    code: c_int,
) -> String:
    """Copy one `PQresultErrorField` into an owned `String`.

    Args:
        pq: The libpq function table to call through.
        res: The result carrying the diagnostic.
        code: A `PG_DIAG_*` field code.

    Returns:
        The field text, or an empty string when libpq reports NULL.
    """
    var p = pq[].PQresultErrorField(res, code)
    if p:
        return String(unsafe_from_utf8_ptr=p.value())
    return String()


struct Connection(Movable):
    """An open synchronous connection to a PostgreSQL server.

    Construct one with `Connection.open`. The connection is closed by
    `PQfinish` when the value is destroyed, so it must not be copied; move it
    with `^` to transfer ownership.
    """

    var _conn: PGconnPtr
    """The owned `PGconn*`, closed exactly once on destruction."""

    var _pq: Pointer[LibpqFFI, MutUntrackedOrigin]
    """Borrowed process-wide libpq table, retained so `__deinit__` cannot raise.
    """

    var _stmt_counter: List[Int]
    """One-element cell holding the last prepared-statement number issued.

    A `List` rather than a plain `Int` because `prepare` only borrows the
    connection immutably; see `_next_stmt_name`.
    """

    var _rollback_failure_handler: def(PgError) thin
    """Handler every new `Transaction` copies for a failed implicit `ROLLBACK`.

    Replaceable with `set_rollback_failure_handler`; a `Transaction` takes its
    own copy when `transaction()` runs, so a later replacement never changes
    an existing one.
    """

    def __init__(
        out self,
        conn: PGconnPtr,
        pq: Pointer[LibpqFFI, MutUntrackedOrigin],
    ):
        """Take ownership of an already-connected `PGconn*`.

        Args:
            conn: A `PGconn*` whose status is `CONNECTION_OK`.
            pq: The libpq table `conn` was opened with.
        """
        self._conn = conn
        self._pq = pq
        # `_stmt_counter` starts at 0, so the first `prepare` issues
        # `pq_stmt_1`. Numbering is per connection.
        self._stmt_counter = [0]
        self._rollback_failure_handler = _default_rollback_failure_handler

    def __deinit__(deinit self):
        """Close the connection with `PQfinish` unless it is already NULL."""
        if not self._conn.is_null():
            self._pq[].PQfinish(self._conn)

    @staticmethod
    def _adopt(
        pq: Pointer[LibpqFFI, MutUntrackedOrigin], conn: PGconnPtr
    ) raises PgError -> Connection:
        """Validate a freshly returned `PGconn*` and wrap it.

        A non-NULL connection whose status is not `CONNECTION_OK` is closed
        before raising, so no handle leaks on a failed connect.

        Args:
            pq: The libpq table `conn` was opened with.
            conn: The `PGconn*` returned by libpq.

        Returns:
            A `Connection` owning `conn`.

        Raises:
            PgError: `PgErrorKind.CONNECTION` when libpq returned NULL or the
                connection attempt failed. The message is libpq's own text and
                never includes the caller's connection parameters.
        """
        if conn.is_null():
            raise PgError(
                PgErrorKind.CONNECTION,
                "libpq returned NULL (out of memory)",
            )
        if pq[].PQstatus(conn) != CONNECTION_OK:
            var message = String(unsafe_from_utf8_ptr=pq[].PQerrorMessage(conn))
            pq[].PQfinish(conn)
            raise PgError(PgErrorKind.CONNECTION, message)
        return Connection(conn, pq)

    @staticmethod
    def open(var conninfo: String) raises PgError -> Connection:
        """Connect using a libpq conninfo string or URI.

        Accepts either keyword form (`"host=127.0.0.1 dbname=pq_test"`) or a
        `postgresql://` URI, exactly as `PQconnectdb` does.

        Args:
            conninfo: The conninfo string or connection URI.

        Returns:
            An open `Connection`.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` if `conninfo` contains a NUL
                byte, `PgErrorKind.LIBPQ_LOAD` if libpq cannot be loaded, or
                `PgErrorKind.CONNECTION` if connecting fails. `pq` never adds
                `conninfo` to the message, but libpq echoes the offending
                fragment of a *malformed* conninfo string, so a password that
                contains a space or a stray `%` can reach the error text. Use
                `open(Dict)` for credentials the program supplies.
        """
        _reject_nul(conninfo, "conninfo")
        var pq = libpq_ptr()
        var conn = pq[].PQconnectdb(
            CStr(unsafe_from_address=Int(conninfo.as_c_string_span().ptr()))
        )
        _ = conninfo^
        return Connection._adopt(pq, conn)

    @staticmethod
    def open(params: Dict[String, String]) raises PgError -> Connection:
        """Connect using discrete keyword/value parameters.

        Calls `PQconnectdbParams` with `expand_dbname` set to 0, so every value
        is taken literally. A `postgresql://` URI placed in `dbname` is treated
        as a database *name* rather than expanded; pass the URI to
        `open(String)` instead.

        Args:
            params: Connection keywords mapped to their values, for example
                `"host"`, `"port"`, `"user"`, `"password"`, `"dbname"`.

        Returns:
            An open `Connection`.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` if any key or value contains a
                NUL byte, `PgErrorKind.LIBPQ_LOAD` if libpq cannot be loaded,
                or `PgErrorKind.CONNECTION` if connecting fails. Each value is
                taken literally rather than parsed, so -- unlike
                `open(String)` -- no value can be echoed back as a conninfo
                syntax error, and a password cannot leak through the message.
        """
        for ref item in params.items():
            _reject_nul(item.key, "params key")
            _reject_nul(item.value, "params value")
        var pq = libpq_ptr()
        # as_c_string_span() is `mut self` and may reallocate to append the NUL
        # terminator, so the keys and values must be owned copies that outlive
        # the call rather than borrowed views into `params`.
        var keys = List[String]()
        var values = List[String]()
        for ref item in params.items():
            keys.append(item.key.copy())
            values.append(item.value.copy())
        var key_ptrs = List[Int]()
        var value_ptrs = List[Int]()
        for ref k in keys:
            key_ptrs.append(Int(k.as_c_string_span().ptr()))
        for ref v in values:
            value_ptrs.append(Int(v.as_c_string_span().ptr()))
        key_ptrs.append(0)
        value_ptrs.append(0)
        var conn = pq[].PQconnectdbParams(
            CStrArray(unsafe_from_address=Int(key_ptrs.unsafe_ptr())),
            CStrArray(unsafe_from_address=Int(value_ptrs.unsafe_ptr())),
            c_int(0),
        )
        _ = key_ptrs^
        _ = value_ptrs^
        _ = keys^
        _ = values^
        return Connection._adopt(pq, conn)

    def execute(self, var sql: String) raises PgError -> Result:
        """Run `sql` to completion with `PQexec` and return its result.

        `sql` may contain several statements separated by semicolons. As in
        libpq, the returned `Result` is the result of the *last* statement; if
        an earlier statement fails, that statement's error is raised and no
        result is returned.

        `COPY ... TO STDOUT` and `COPY ... FROM STDIN` are not supported: they
        raise `PgErrorKind.SERVER` with `unexpected result status 3` or `4`,
        and libpq brings the connection back to a usable state on the next
        `execute`.

        The result is adopted by `_take_result`, which `execute(sql, params)`,
        `PreparedStatement.execute` and each `Transaction` command also go
        through, so they all classify failures identically.

        Args:
            sql: One or more SQL statements.

        Returns:
            The `Result` of the last statement, owning the `PGresult*`.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `sql` contains a NUL
                byte, `PgErrorKind.CONNECTION` when libpq returns no result at
                all, or when the connection was lost while running `sql` and
                libpq reported it without an SQLSTATE, or
                `PgErrorKind.SERVER` when the server reports a diagnostic. (A
                disconnect the server announced as a FATAL *with* an SQLSTATE
                is therefore still `SERVER` for that statement, and the next
                `execute` is the one that raises `CONNECTION`.) Server errors
                carry `sqlstate`, `severity`, `detail`, `hint`, `position` and
                `context` when libpq supplies them.
        """
        _reject_nul(sql, "sql")
        var res = self._pq[].PQexec(
            self._conn,
            CStr(unsafe_from_address=Int(sql.as_c_string_span().ptr())),
        )
        _ = sql^
        return self._take_result(res)

    def execute(
        self, var sql: String, params: List[Param]
    ) raises PgError -> Result:
        """Run one parameterised statement with `PQexecParams`.

        Placeholders are `$1` through `$n`, numbered from 1 rather than
        written as `?`, so `params[0]` binds `$1`. The call always goes
        through `PQexecParams`, including when `params` is empty: it never
        falls back to `PQexec`.

        Only a single statement is allowed, because `PQexecParams` builds an
        unnamed prepared statement: `SELECT 1; SELECT 2` is rejected with
        SQLSTATE `42601` (`cannot insert multiple commands into a prepared
        statement`). A single trailing semicolon -- `SELECT 1;` -- succeeds.

        Each `Param` carries its own type OID and wire format:

        | Mojo type | type OID | format |
        |---|---|---|
        | `Bool` | 16 | binary, 1 byte |
        | `Int16` | 21 | binary, 2 byte big-endian |
        | `Int32` | 23 | binary, 4 byte big-endian |
        | `Int64` / `Int` | 20 | binary, 8 byte big-endian |
        | `Float32` | 700 | binary, 4 byte IEEE 754 |
        | `Float64` | 701 | binary, 8 byte IEEE 754 |
        | `String` / `StringLiteral` | **0 (unspecified)** | text |
        | `List[UInt8]` | 17 | binary, the bytes as-is |
        | `Param.null()` / `Param.null(oid)` | 0 / the given OID | NULL |

        A `String` goes out with OID 0 -- type unspecified -- so the server
        infers it from context: in `SELECT $1` it becomes `text` (OID 25),
        while `SELECT $1 + 1` infers `int4`, so `"7"` arrives as 8. An `Int`
        is sent as `int8` (OID 20), yet PostgreSQL's assignment cast still
        lets `Int(5)` reach an `int4` column on `INSERT`; a value outside
        that column's range, such as `Int(3000000000)`, is `22003`.

        The number of parameters is left to the server rather than counted
        client-side, so passing fewer than the placeholders need is SQLSTATE
        `08P01`, and the connection remains usable afterwards.

        Results always come back in text form; a binary `result_format` is
        Phase 3.

        The result is adopted by `_take_result`, the same path `execute(sql)`
        takes, so both classify failures identically.

        Args:
            sql: Exactly one SQL statement, using `$1`..`$n` placeholders.
            params: The values to bind, `params[0]` binding `$1`.

        Returns:
            The `Result` of the statement, owning the `PGresult*`.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `sql` contains a NUL
                byte, `PgErrorKind.USAGE` when the value of a `String`
                parameter contains a NUL byte (`embedded NUL byte in
                parameter $N`; nothing is sent to the server), and
                `PgErrorKind.CONNECTION` or `PgErrorKind.SERVER` under
                exactly the classification `_take_result` applies --
                `CONNECTION` when libpq returns no result at all or the
                connection was lost and libpq reported it without an
                SQLSTATE, `SERVER` when the server reports a diagnostic,
                carrying `sqlstate`, `severity`, `detail`, `hint`,
                `position` and `context` when libpq supplies them.
        """
        _reject_nul(sql, "sql")
        var buffers = _ParamBuffers(params)
        var res = self._pq[].PQexecParams(
            self._conn,
            CStr(unsafe_from_address=Int(sql.as_c_string_span().ptr())),
            c_int(buffers.count()),
            buffers.types_ptr(),
            buffers.values_ptr(),
            buffers.lengths_ptr(),
            buffers.formats_ptr(),
            c_int(0),
        )
        _ = buffers^
        _ = sql^
        return self._take_result(res)

    def _next_stmt_name(self) -> String:
        """Consume the next prepared-statement number and build its name.

        Names are `pq_stmt_1`, `pq_stmt_2`, ... per connection. A number is
        consumed even when the `prepare` that asked for it then fails: reusing
        it would risk `42P05` (`prepared statement already exists`) against a
        statement the failure left behind, and a gap in the sequence costs
        nothing.

        `prepare` borrows the connection immutably -- that is what lets a
        `PreparedStatement` coexist with further `Connection.execute` calls --
        so the counter cannot be a plain `var` field. It lives in a
        one-element `List` instead, and the write goes through a pointer
        rebound to `MutUntrackedOrigin`, the same escape hatch
        `_ffi.loader.libpq_ptr` uses to hand out a mutable view of a
        process-global. The heap cell is reached through `unsafe_ptr()`, so no
        part of `self` is mutated and nothing else aliases that address.

        Returns:
            The name for the statement about to be prepared.
        """
        var cell = Pointer[Int, MutUntrackedOrigin](
            unsafe_from_address=Int(self._stmt_counter.unsafe_ptr())
        )
        cell[] += 1
        return String("pq_stmt_", cell[])

    def prepare(
        ref self,
        var sql: String,
        param_types: List[UInt32] = List[UInt32](),
    ) raises PgError -> PreparedStatement[origin_of(self)]:
        """Prepare `sql` on the server and return a handle to it.

        Exactly one statement is allowed, with `$1`..`$n` placeholders, as for
        `execute(sql, params)`. The statement is given a generated name --
        `pq_stmt_1`, `pq_stmt_2`, ... per connection, readable through
        `PreparedStatement.name()` -- so no caller-supplied identifier is ever
        interpolated into SQL.

        Two round trips happen here: `PQprepare`, then `PQdescribePrepared` to
        read back the parameter count and the type OIDs the server resolved.
        That is what makes `PreparedStatement.param_count()` and
        `param_type_oid()` answerable without a further round trip, and what
        lets `PreparedStatement.execute` reject a wrong parameter count
        client-side.

        `param_types` is a *hint* for types the server cannot infer, exactly
        like the `paramTypes` argument of `PQprepare`: an entry of 0 leaves
        that parameter to inference, and a shorter list than the statement has
        placeholders leaves the rest to inference too. The authoritative types
        are always the ones `PQdescribePrepared` reports, so
        `param_type_oid()` can differ from what was passed in.

        The returned statement borrows the connection immutably, so
        `Connection.execute` stays callable while it is alive, but the
        statement cannot outlive the connection -- that is a compile error.
        Destroying it sends `DEALLOCATE`; see the `pq.prepared` module
        docstring for when Mojo destroys it and why `PREPARE` surviving a
        `ROLLBACK` is expected.

        Nothing is left on the server when this raises: a failed `PQprepare`
        created no statement, and a failed `PQdescribePrepared` is followed by
        a best-effort `DEALLOCATE` whose own outcome is discarded before the
        describe error is re-raised.

        Args:
            sql: Exactly one SQL statement, using `$1`..`$n` placeholders.
            param_types: Optional type OID hints, `param_types[0]` for `$1`.
                An entry of 0 asks the server to infer that parameter.

        Returns:
            A `PreparedStatement` bound to this connection's origin.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `sql` contains a NUL
                byte, or `PgErrorKind.CONNECTION` / `PgErrorKind.SERVER` under
                exactly the classification `_take_result` applies, for either
                the prepare or the describe -- `42601` for a syntax error,
                `42P18` when a parameter type cannot be determined, `42P05`
                for a name collision. Server errors carry `sqlstate`,
                `severity`, `detail`, `hint`, `position` and `context` when
                libpq supplies them.
        """
        var types = List[UInt32]()
        var name = self._prepare_parts(sql^, param_types, types)
        return PreparedStatement[origin_of(self)](
            Pointer(to=self), name^, types^
        )

    def _prepare_parts(
        self,
        var sql: String,
        param_types: List[UInt32],
        mut types: List[UInt32],
    ) raises PgError -> String:
        """Run the two round trips `prepare` needs and return its parts.

        This is the whole of `prepare` except the final construction. It is
        split out because the origin a `PreparedStatement` is parameterised on
        has to be written by whoever holds the borrow: `Transaction.prepare`
        has to hand out a statement on the transaction's own borrow of the
        connection, and on Mojo 1.1.0 a `PreparedStatement` returned from
        `prepare` called through `Pointer.__getitem__` comes back with a
        nested origin that no signature can spell, so it cannot be converted.
        Both callers therefore build the value themselves from these parts.

        `self` is borrowed immutably -- the generated name comes from
        `_next_stmt_name`'s heap cell, not from a mutable field -- so it is
        callable through the immutable borrow a `Transaction` holds.

        Args:
            sql: Exactly one SQL statement, using `$1`..`$n` placeholders.
            param_types: Optional type OID hints, `param_types[0]` for `$1`.
                An entry of 0 asks the server to infer that parameter.
            types: Cleared, then filled with the type OID `PQdescribePrepared`
                reported for each parameter, in `$1`..`$n` order.

        Returns:
            The generated name of the statement the server now holds.

        Raises:
            PgError: Exactly what `prepare` documents, for either round trip.
        """
        _reject_nul(sql, "sql")
        var name = self._next_stmt_name()
        # One dummy element past the hints, so `unsafe_ptr()` is a valid
        # non-NULL address even for an empty list -- the same rule
        # `_ParamBuffers` follows.
        var hints = List[UInt32](capacity=len(param_types) + 1)
        for i in range(len(param_types)):
            hints.append(param_types[i])
        hints.append(UInt32(0))
        var res = self._pq[].PQprepare(
            self._conn,
            CStr(unsafe_from_address=Int(name.as_c_string_span().ptr())),
            CStr(unsafe_from_address=Int(sql.as_c_string_span().ptr())),
            c_int(len(param_types)),
            OidPtr(unsafe_from_address=Int(hints.unsafe_ptr())),
        )
        _ = hints^
        _ = sql^
        # A failing prepare left no statement on the server, so there is
        # nothing to clean up before this propagates.
        _ = self._take_result(res)
        var res2 = self._pq[].PQdescribePrepared(
            self._conn,
            CStr(unsafe_from_address=Int(name.as_c_string_span().ptr())),
        )
        var desc: Result
        try:
            desc = self._take_result(res2)
        except e:
            # The statement exists but the caller gets no handle for it, so
            # nothing would ever DEALLOCATE it. Try once through the raw
            # PQexec and discard the outcome entirely: the describe failure is
            # what the caller needs to see, and a failed cleanup must not
            # replace it with a less informative error.
            var drop = String("DEALLOCATE ", name)
            var dropped = self._pq[].PQexec(
                self._conn,
                CStr(unsafe_from_address=Int(drop.as_c_string_span().ptr())),
            )
            _ = drop^
            if not dropped.is_null():
                self._pq[].PQclear(dropped)
            raise e^
        var count = Int(self._pq[].PQnparams(desc._res))
        types.clear()
        types.reserve(count)
        for i in range(count):
            types.append(self._pq[].PQparamtype(desc._res, c_int(i)))
        # `desc` is a `Result`, so its PQclear happens on destruction here.
        return name^

    def _take_result(self, res: PGresultPtr) raises PgError -> Result:
        """Adopt a finished `PGresult` or raise the error it reports.

        A successful result is handed to `Result`, which takes over the
        `PQclear`. Every failing path clears `res` itself before raising, apart
        from a NULL `res`, where libpq allocated nothing to clear.

        Args:
            res: The result libpq returned for the command that just ran, as-is
                including NULL.

        Returns:
            The `Result` of the command, owning the `PGresult*`.

        Raises:
            PgError: `PgErrorKind.CONNECTION` when libpq returns no result at
                all, or when the connection was lost while running the command
                and libpq reported it without an SQLSTATE, or
                `PgErrorKind.SERVER` when the server reports a diagnostic. (A
                disconnect the server announced as a FATAL *with* an SQLSTATE
                is therefore still `SERVER` for that statement, and the next
                command is the one that raises `CONNECTION`.) Server errors
                carry `sqlstate`, `severity`, `detail`, `hint`, `position` and
                `context` when libpq supplies them.
        """
        if res.is_null():
            # No PGresult was allocated, so there is nothing to PQclear.
            raise PgError(
                PgErrorKind.CONNECTION,
                String(
                    unsafe_from_utf8_ptr=self._pq[].PQerrorMessage(self._conn)
                ),
            )
        var status = self._pq[].PQresultStatus(res)
        if status == PGRES_TUPLES_OK or status == PGRES_COMMAND_OK:
            return Result(res, self._pq)
        if status == PGRES_EMPTY_QUERY:
            self._pq[].PQclear(res)
            raise PgError(PgErrorKind.SERVER, "empty query")
        # Every diagnostic is copied into owned Strings before PQclear frees
        # the PGresult the field pointers point into.
        var severity = _error_field(
            self._pq, res, PG_DIAG_SEVERITY_NONLOCALIZED
        )
        if severity == "":
            severity = _error_field(self._pq, res, PG_DIAG_SEVERITY)
        var sqlstate = _error_field(self._pq, res, PG_DIAG_SQLSTATE)
        var message = _error_field(self._pq, res, PG_DIAG_MESSAGE_PRIMARY)
        if message == "":
            message = String(
                unsafe_from_utf8_ptr=self._pq[].PQresultErrorMessage(res)
            )
        if message == "":
            message = String("unexpected result status ", Int(status))
        var detail = _error_field(self._pq, res, PG_DIAG_MESSAGE_DETAIL)
        var hint = _error_field(self._pq, res, PG_DIAG_MESSAGE_HINT)
        var position = _error_field(self._pq, res, PG_DIAG_STATEMENT_POSITION)
        var context = _error_field(self._pq, res, PG_DIAG_CONTEXT)
        self._pq[].PQclear(res)
        # A diagnostic that carries no SQLSTATE did not come from the server:
        # libpq generated it client-side. When the connection is also gone,
        # that is a lost connection rather than a rejected statement, so it is
        # reported as CONNECTION -- `PgErrorKind.CONNECTION` is what tells the
        # caller the connection is no longer usable. Both halves of the test
        # matter: a syntax error has an SQLSTATE, and `COPY ... TO STDOUT`
        # has none but leaves the connection perfectly usable.
        var kind = PgErrorKind.SERVER
        if sqlstate == "" and self._pq[].PQstatus(self._conn) == CONNECTION_BAD:
            kind = PgErrorKind.CONNECTION
        raise PgError(
            kind,
            message,
            sqlstate=sqlstate,
            severity=severity,
            detail=detail,
            hint=hint,
            position=position,
            context=context,
        )

    def escape_literal(self, var s: String) raises PgError -> String:
        """Quote `s` as a SQL string literal with `PQescapeLiteral`.

        The returned text already carries its surrounding quotes, so it is
        substituted into SQL directly rather than wrapped again. Quoting is
        connection-aware: it follows the connection's client encoding, and `s`
        is measured in *bytes*, so a multi-byte value is escaped whole.

        So `escape_literal("O'Reilly")` yields `'O''Reilly'`, while a value
        containing a backslash always comes back in libpq's E-string form --
        `standard_conforming_strings` is not consulted -- which carries a
        deliberate leading space: `escape_literal("a\\b")` yields ` E'a\\b'`.

        Args:
            s: The value to quote. Any byte sequence except one containing a
                NUL byte is accepted.

        Returns:
            An owned copy of libpq's quoted text; the libpq buffer is released
            before returning.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `s` contains a NUL byte,
                or `PgErrorKind.SERVER` when `PQescapeLiteral` returns NULL,
                carrying libpq's own `PQerrorMessage` text.
        """
        _reject_nul(s, "s")
        var byte_length = s.byte_length()
        var quoted = self._pq[].PQescapeLiteral(
            self._conn,
            CStr(unsafe_from_address=Int(s.as_c_string_span().ptr())),
            c_size_t(byte_length),
        )
        _ = s^
        if not quoted:
            raise PgError(
                PgErrorKind.SERVER,
                String(
                    unsafe_from_utf8_ptr=self._pq[].PQerrorMessage(self._conn)
                ),
            )
        # Copy first, then free: `owned` must not outlive the libpq buffer.
        var p = quoted.value()
        var owned = String(unsafe_from_utf8_ptr=p)
        self._pq[].PQfreemem(MutRawPtr(unsafe_from_address=Int(p)))
        return owned^

    def escape_identifier(self, var s: String) raises PgError -> String:
        """Quote `s` as a SQL identifier with `PQescapeIdentifier`.

        The returned text is double-quoted and ready to use as a table or
        column name, so `escape_identifier("x")` yields `"x"` and an embedded
        double quote is doubled. As with `escape_literal`, `s` is measured in
        bytes and quoting follows the connection's client encoding.

        Args:
            s: The identifier to quote. Any byte sequence except one containing
                a NUL byte is accepted.

        Returns:
            An owned copy of libpq's quoted identifier; the libpq buffer is
            released before returning.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `s` contains a NUL byte,
                or `PgErrorKind.SERVER` when `PQescapeIdentifier` returns
                NULL, carrying libpq's own `PQerrorMessage` text.
        """
        _reject_nul(s, "s")
        var byte_length = s.byte_length()
        var quoted = self._pq[].PQescapeIdentifier(
            self._conn,
            CStr(unsafe_from_address=Int(s.as_c_string_span().ptr())),
            c_size_t(byte_length),
        )
        _ = s^
        if not quoted:
            raise PgError(
                PgErrorKind.SERVER,
                String(
                    unsafe_from_utf8_ptr=self._pq[].PQerrorMessage(self._conn)
                ),
            )
        # Copy first, then free: `owned` must not outlive the libpq buffer.
        var p = quoted.value()
        var owned = String(unsafe_from_utf8_ptr=p)
        self._pq[].PQfreemem(MutRawPtr(unsafe_from_address=Int(p)))
        return owned^

    def server_version(self) -> Int:
        """Return the server version as reported by `PQserverVersion`.

        Returns:
            The version as a single integer, for example 140012 for 14.12 and
            170002 for 17.2; 0 when the version is unknown.
        """
        return Int(self._pq[].PQserverVersion(self._conn))

    def status(self) -> Int:
        """Return the connection status as reported by `PQstatus`.

        Returns:
            `CONNECTION_OK` while the connection is usable, `CONNECTION_BAD`
            once it has failed, as an `Int` for comparison against those
            constants.
        """
        return Int(self._pq[].PQstatus(self._conn))

    def transaction_status(self) -> Int:
        """Return the transaction status as reported by `PQtransactionStatus`.

        Returns:
            One of the `PQTRANS_*` constants as an `Int`: `PQTRANS_IDLE` when
            no transaction is open, `PQTRANS_ACTIVE` while a command is in
            flight, `PQTRANS_INTRANS` inside a transaction block,
            `PQTRANS_INERROR` inside a failed one, and `PQTRANS_UNKNOWN` when
            the connection is bad.
        """
        return Int(self._pq[].PQtransactionStatus(self._conn))

    def transaction(ref self) raises PgError -> Transaction[origin_of(self)]:
        """Send `BEGIN` and return the transaction block it opened.

        The connection must be idle: a second `transaction()` while one is
        already open is rejected client-side with `PgErrorKind.USAGE` and
        nothing is sent, so the server never sees the `WARNING: there is
        already a transaction in progress` that a bare second `BEGIN` would
        produce. Savepoints, not nesting, are how a block subdivides -- see
        `Transaction.savepoint`.

        A connection that has already failed is reported as
        `PgErrorKind.CONNECTION` rather than `USAGE`, and that test runs
        first: `PQtransactionStatus` answers `PQTRANS_UNKNOWN` on a dead
        connection, which is not idle either, and losing the server is not an
        API misuse.

        The returned value borrows the connection immutably, so
        `Connection.execute` stays callable -- and runs inside the block --
        while it is alive, but the transaction cannot outlive the connection:
        that is a compile error. Destroying it without `commit()` or
        `rollback()` sends `ROLLBACK`, and because Mojo destroys it right
        after its last use, the `pq.transaction` module docstring is worth
        reading before mixing `tx.execute` and `conn.execute`.

        Returns:
            A `Transaction` bound to this connection's origin, holding a copy
            of the current rollback-failure handler.

        Raises:
            PgError: `PgErrorKind.CONNECTION` when `PQstatus` is already
                `CONNECTION_BAD`, carrying libpq's own `PQerrorMessage` text;
                `PgErrorKind.USAGE` when the connection is not idle
                (`transaction() requires an idle connection (transaction
                status N)`, `N` being the `PQTRANS_*` value); otherwise
                whatever `execute("BEGIN")` raises.
        """
        if self._pq[].PQstatus(self._conn) == CONNECTION_BAD:
            raise PgError(
                PgErrorKind.CONNECTION,
                String(
                    unsafe_from_utf8_ptr=self._pq[].PQerrorMessage(self._conn)
                ),
            )
        var status = self._pq[].PQtransactionStatus(self._conn)
        if status != PQTRANS_IDLE:
            raise PgError(
                PgErrorKind.USAGE,
                String(
                    "transaction() requires an idle connection ",
                    "(transaction status ",
                    Int(status),
                    ")",
                ),
            )
        _ = self.execute("BEGIN")
        return Transaction[origin_of(self)](
            Pointer(to=self), self._rollback_failure_handler
        )

    def set_rollback_failure_handler(mut self, handler: def(PgError) thin):
        """Install the handler for a `Transaction`'s failed implicit rollback.

        A `Transaction` destructor cannot raise, so when the `ROLLBACK` it
        sends fails it calls this handler instead.

        The handler is **copied when `transaction()`** is called, so replacing
        it later does not affect existing `Transaction` values -- install it
        before opening the block it should cover.

        The default handler writes one line to stderr. A replacement must not
        raise, which is what the `thin` function type enforces.

        Args:
            handler: The function to call with the error a failed implicit
                `ROLLBACK` produced.
        """
        self._rollback_failure_handler = handler
