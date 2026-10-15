"""Synchronous PostgreSQL connection built on `PQconnectdb` and `PQexec`.

`Connection` owns one `PGconn*` and the process-wide `LibpqFFI` table it was
opened with. It is `Movable` but deliberately not `Copyable`: a libpq
connection is not thread-safe and must be handed to `PQfinish` exactly once,
so `var b = a` is a compile error and ownership transfers with `a^` instead.

Connecting never echoes the caller's credentials. Neither the conninfo string
nor the parameter dictionary appears in any raised message; only libpq's own
`PQerrorMessage` text is reported, which names host, port and user but not the
password.
"""

from std.ffi import c_int, c_size_t

from pq._ffi.functions import LibpqFFI
from pq._ffi.loader import libpq_ptr
from pq._ffi.types import (
    CONNECTION_BAD,
    CONNECTION_OK,
    CStr,
    CStrArray,
    MutRawPtr,
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
)
from pq.errors import PgError, PgErrorKind, _reject_nul
from pq.result import Result


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
                "PQconnectdb returned NULL (out of memory)",
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
                `PgErrorKind.CONNECTION` if connecting fails. `conninfo` is
                never included in the message, so an embedded password cannot
                leak through the error.
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
                or `PgErrorKind.CONNECTION` if connecting fails. `params` is
                never included in the message, so a password value cannot leak
                through the error.
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

        Args:
            sql: One or more SQL statements.

        Returns:
            The `Result` of the last statement, owning the `PGresult*`.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `sql` contains a NUL
                byte, `PgErrorKind.CONNECTION` when libpq returns no result at
                all or the connection was lost while running `sql`, or
                `PgErrorKind.SERVER` when the server reports a diagnostic.
                Server errors carry `sqlstate`, `severity`, `detail`, `hint`,
                `position` and `context` when libpq supplies them.
        """
        _reject_nul(sql, "sql")
        var res = self._pq[].PQexec(
            self._conn,
            CStr(unsafe_from_address=Int(sql.as_c_string_span().ptr())),
        )
        _ = sql^
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
        connection-aware: it follows the server's `standard_conforming_strings`
        setting and the client encoding, and `s` is measured in *bytes*, so a
        multi-byte value is escaped whole.

        So `escape_literal("O'Reilly")` yields `'O''Reilly'`, while a value
        that needs a backslash escape comes back in libpq's E-string form,
        which carries a deliberate leading space: `escape_literal("a\\b")`
        yields ` E'a\\b'`.

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
