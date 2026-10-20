"""Tests for the `pq._ffi` binding layer: symbol coverage, types, constants."""

from std.ffi import OwnedDLHandle
from std.os import getenv
from std.sys import size_of
from std.sys.info import platform_map
from std.testing import TestSuite, assert_equal, assert_true

from pq._ffi.functions import LibpqFFI
from pq._ffi.types import (
    CONNECTION_BAD,
    CONNECTION_OK,
    CStr,
    PGnotify,
    PGRES_FATAL_ERROR,
    PGRES_POLLING_OK,
    PGRES_TUPLES_CHUNK,
    PGRES_TUPLES_OK,
    PGconnPtr,
    PQTRANS_INTRANS,
)

comptime LIBPQ_DEFAULT = platform_map[
    "libpq", linux="libpq.so.5", macos="libpq.5.dylib"
]()

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)


def _libpq_path() -> String:
    var path = getenv("PQ_MOJO_LIBPQ")
    return path if path != "" else String(LIBPQ_DEFAULT)


def _symbol_names() -> List[String]:
    return [
        String("PQconnectdb"),
        "PQconnectdbParams",
        "PQfinish",
        "PQreset",
        "PQstatus",
        "PQerrorMessage",
        "PQserverVersion",
        "PQparameterStatus",
        "PQtransactionStatus",
        "PQlibVersion",
        "PQexec",
        "PQexecParams",
        "PQprepare",
        "PQexecPrepared",
        "PQdescribePrepared",
        "PQresultStatus",
        "PQresultErrorMessage",
        "PQresultErrorField",
        "PQntuples",
        "PQnfields",
        "PQfname",
        "PQfnumber",
        "PQftype",
        "PQfformat",
        "PQfmod",
        "PQgetvalue",
        "PQgetlength",
        "PQgetisnull",
        "PQcmdTuples",
        "PQclear",
        "PQcmdStatus",
        "PQnparams",
        "PQparamtype",
        "PQescapeLiteral",
        "PQescapeIdentifier",
        "PQfreemem",
        "PQconnectStart",
        "PQconnectStartParams",
        "PQconnectPoll",
        "PQsocket",
        "PQsetnonblocking",
        "PQisnonblocking",
        "PQsendQuery",
        "PQsendQueryParams",
        "PQsendPrepare",
        "PQsendQueryPrepared",
        "PQflush",
        "PQconsumeInput",
        "PQisBusy",
        "PQgetResult",
        "PQsetSingleRowMode",
        "PQgetCancel",
        "PQcancel",
        "PQfreeCancel",
        "PQnotifies",
    ]


def test_libpq_ffi_constructs() raises:
    var ffi = LibpqFFI(_libpq_path())
    _ = ffi^


def test_all_symbols_present() raises:
    var names = _symbol_names()
    assert_equal(len(names), 55)
    var lib = OwnedDLHandle(_libpq_path())
    for ref name in names:
        assert_true(lib.check_symbol(name), "missing symbol " + name)


def test_copy_symbols_resolve() raises:
    """The three COPY entry points resolve to non-NULL addresses.

    They are checked here rather than appended to `_symbol_names()` so the
    coverage list above keeps its own count; what this adds over
    `check_symbol` is that the resolved *function pointers* on a constructed
    `LibpqFFI` are non-zero, which is what `copy_in` / `copy_out` call
    through.
    """
    var ffi = LibpqFFI(_libpq_path())
    assert_true(Pointer(to=ffi.PQputCopyData).unsafe_bitcast[Int]()[] != 0)
    assert_true(Pointer(to=ffi.PQputCopyEnd).unsafe_bitcast[Int]()[] != 0)
    assert_true(Pointer(to=ffi.PQgetCopyData).unsafe_bitcast[Int]()[] != 0)
    _ = ffi^


def test_lib_version_at_least_14() raises:
    var ffi = LibpqFFI(_libpq_path())
    assert_true(Int(ffi.PQlibVersion()) >= 140000)
    _ = ffi^


def test_pgnotify_layout() raises:
    assert_equal(size_of[PGnotify](), 32)


def test_enum_constants() raises:
    assert_equal(Int(CONNECTION_OK), 0)
    assert_equal(Int(CONNECTION_BAD), 1)
    assert_equal(Int(PGRES_TUPLES_OK), 2)
    assert_equal(Int(PGRES_FATAL_ERROR), 7)
    assert_equal(Int(PQTRANS_INTRANS), 2)
    assert_equal(Int(PGRES_POLLING_OK), 3)
    assert_equal(Int(PGRES_TUPLES_CHUNK), 12)


def test_null_opaque_handle() raises:
    assert_true(PGconnPtr(0).is_null())


def test_low_level_round_trip() raises:
    var ffi = LibpqFFI(_libpq_path())

    var conninfo = getenv("PQ_TEST_CONNINFO")
    if conninfo == "":
        conninfo = String(DEFAULT_CONNINFO)
    var conn = ffi.PQconnectdb(
        CStr(unsafe_from_address=Int(conninfo.as_c_string_span().ptr()))
    )
    _ = conninfo^

    var status = Int(ffi.PQstatus(conn))
    if status != Int(CONNECTION_OK):
        var msg = String(unsafe_from_utf8_ptr=ffi.PQerrorMessage(conn))
        ffi.PQfinish(conn)
        raise Error("PQconnectdb failed (status=", status, "): ", msg)

    var sql = String("SELECT 1")
    var res = ffi.PQexec(
        conn, CStr(unsafe_from_address=Int(sql.as_c_string_span().ptr()))
    )
    _ = sql^

    var result_status = Int(ffi.PQresultStatus(res))
    ffi.PQclear(res)
    ffi.PQfinish(conn)
    _ = ffi^
    assert_equal(result_status, Int(PGRES_TUPLES_OK))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
