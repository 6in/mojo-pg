"""Opaque handles, pointer aliases and libpq enum constants.

Mirrors `libpq-fe.h` and `postgres_ext.h`. Opaque handles are Int-backed
newtypes because `Pointer(unsafe_from_address=0)` is rejected on Mojo 1.1.0.
This module never raises `PgError`; it holds no behaviour beyond `is_null`.
"""

from std.ffi import c_char, c_int

comptime CStr = Pointer[c_char, ImmUntrackedOrigin]
comptime OptCStr = OptionalPointer[c_char, ImmUntrackedOrigin]
comptime MutCStr = Pointer[c_char, MutUntrackedOrigin]
comptime MutRawPtr = Pointer[NoneType, MutUntrackedOrigin]
comptime CStrArray = Pointer[Int, ImmUntrackedOrigin]
comptime OidPtr = Pointer[UInt32, ImmUntrackedOrigin]
comptime IntPtr = Pointer[c_int, ImmUntrackedOrigin]


@fieldwise_init
struct PGconnPtr(TrivialRegisterPassable):
    var _addr: Int

    def is_null(self) -> Bool:
        return self._addr == 0


@fieldwise_init
struct PGresultPtr(TrivialRegisterPassable):
    var _addr: Int

    def is_null(self) -> Bool:
        return self._addr == 0


@fieldwise_init
struct PGcancelPtr(TrivialRegisterPassable):
    var _addr: Int

    def is_null(self) -> Bool:
        return self._addr == 0


@fieldwise_init
struct PGnotifyPtr(TrivialRegisterPassable):
    var _addr: Int

    def is_null(self) -> Bool:
        return self._addr == 0


@fieldwise_init
struct PGnotify(TrivialRegisterPassable):
    var relname: Int  # char* notification channel name
    var be_pid: c_int  # process ID of notifying server process
    var extra: Int  # char* notification parameter
    var next: Int  # struct pgNotify* internal libpq list link


# ConnStatusType -- libpq-fe.h:82-101
comptime CONNECTION_OK = c_int(0)
comptime CONNECTION_BAD = c_int(1)
comptime CONNECTION_STARTED = c_int(2)
comptime CONNECTION_MADE = c_int(3)
comptime CONNECTION_AWAITING_RESPONSE = c_int(4)
comptime CONNECTION_AUTH_OK = c_int(5)
comptime CONNECTION_SETENV = c_int(6)
comptime CONNECTION_SSL_STARTUP = c_int(7)
comptime CONNECTION_NEEDED = c_int(8)
comptime CONNECTION_CHECK_WRITABLE = c_int(9)
comptime CONNECTION_CONSUME = c_int(10)
comptime CONNECTION_GSS_STARTUP = c_int(11)
comptime CONNECTION_CHECK_TARGET = c_int(12)
comptime CONNECTION_CHECK_STANDBY = c_int(13)
comptime CONNECTION_ALLOCATED = c_int(14)
comptime CONNECTION_AUTHENTICATING = c_int(15)

# PostgresPollingStatusType -- libpq-fe.h:103-111
comptime PGRES_POLLING_FAILED = c_int(0)
comptime PGRES_POLLING_READING = c_int(1)
comptime PGRES_POLLING_WRITING = c_int(2)
comptime PGRES_POLLING_OK = c_int(3)
comptime PGRES_POLLING_ACTIVE = c_int(4)

# ExecStatusType -- libpq-fe.h:113-135
comptime PGRES_EMPTY_QUERY = c_int(0)
comptime PGRES_COMMAND_OK = c_int(1)
comptime PGRES_TUPLES_OK = c_int(2)
comptime PGRES_COPY_OUT = c_int(3)
comptime PGRES_COPY_IN = c_int(4)
comptime PGRES_BAD_RESPONSE = c_int(5)
comptime PGRES_NONFATAL_ERROR = c_int(6)
comptime PGRES_FATAL_ERROR = c_int(7)
comptime PGRES_COPY_BOTH = c_int(8)
comptime PGRES_SINGLE_TUPLE = c_int(9)
comptime PGRES_PIPELINE_SYNC = c_int(10)
comptime PGRES_PIPELINE_ABORTED = c_int(11)
comptime PGRES_TUPLES_CHUNK = c_int(12)

# PGTransactionStatusType -- libpq-fe.h:137-144
comptime PQTRANS_IDLE = c_int(0)
comptime PQTRANS_ACTIVE = c_int(1)
comptime PQTRANS_INTRANS = c_int(2)
comptime PQTRANS_INERROR = c_int(3)
comptime PQTRANS_UNKNOWN = c_int(4)

# PQresultErrorField() field codes -- postgres_ext.h:55-72
comptime PG_DIAG_SEVERITY = c_int(ord("S"))
comptime PG_DIAG_SEVERITY_NONLOCALIZED = c_int(ord("V"))
comptime PG_DIAG_SQLSTATE = c_int(ord("C"))
comptime PG_DIAG_MESSAGE_PRIMARY = c_int(ord("M"))
comptime PG_DIAG_MESSAGE_DETAIL = c_int(ord("D"))
comptime PG_DIAG_MESSAGE_HINT = c_int(ord("H"))
comptime PG_DIAG_STATEMENT_POSITION = c_int(ord("P"))
comptime PG_DIAG_INTERNAL_POSITION = c_int(ord("p"))
comptime PG_DIAG_INTERNAL_QUERY = c_int(ord("q"))
comptime PG_DIAG_CONTEXT = c_int(ord("W"))
comptime PG_DIAG_SCHEMA_NAME = c_int(ord("s"))
comptime PG_DIAG_TABLE_NAME = c_int(ord("t"))
comptime PG_DIAG_COLUMN_NAME = c_int(ord("c"))
comptime PG_DIAG_DATATYPE_NAME = c_int(ord("d"))
comptime PG_DIAG_CONSTRAINT_NAME = c_int(ord("n"))
comptime PG_DIAG_SOURCE_FILE = c_int(ord("F"))
comptime PG_DIAG_SOURCE_LINE = c_int(ord("L"))
comptime PG_DIAG_SOURCE_FUNCTION = c_int(ord("R"))
