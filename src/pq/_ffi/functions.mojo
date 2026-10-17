"""Thin libpq function-pointer table resolved from a single dlopen'd handle.

`LibpqFFI` is `Movable` only: the owned `OwnedDLHandle` must not be duplicated.
Every symbol is resolved eagerly in `__init__` via `_dl_sym`, so a missing
symbol surfaces as `Error("missing symbol <name>")` at load time rather than
as a crash at first call. This layer stays free of `PgError` on purpose.
"""

from std.ffi import OwnedDLHandle, RTLD, c_int, c_size_t

from .types import (
    CStr,
    CStrArray,
    IntPtr,
    MutCStr,
    MutRawPtr,
    OidPtr,
    OptCStr,
    PGcancelPtr,
    PGconnPtr,
    PGnotifyPtr,
    PGresultPtr,
)


def _dl_sym[
    FT: TrivialRegisterPassable
](lib: OwnedDLHandle, name: String) raises -> FT:
    var opt = lib.get_symbol[FT](name)
    if not opt:
        raise Error("missing symbol " + name)
    var addr: Int = Int(opt.value())
    return Pointer(to=addr).unsafe_bitcast[FT]()[]


struct LibpqFFI(Movable):
    var _lib: OwnedDLHandle

    # --- connection lifecycle -------------------------------------------
    var PQconnectdb: def(CStr) thin abi("C") -> PGconnPtr  # libpq-fe.h:331
    var PQconnectdbParams: def(CStrArray, CStrArray, c_int) thin abi(
        "C"
    ) -> PGconnPtr  # libpq-fe.h:332
    var PQfinish: def(PGconnPtr) thin abi("C") -> None  # libpq-fe.h:343
    var PQreset: def(PGconnPtr) thin abi("C") -> None  # libpq-fe.h:366

    # --- connection introspection ---------------------------------------
    var PQstatus: def(PGconnPtr) thin abi("C") -> c_int  # libpq-fe.h:407
    var PQerrorMessage: def(PGconnPtr) thin abi("C") -> CStr  # libpq-fe.h:414
    var PQserverVersion: def(PGconnPtr) thin abi("C") -> c_int  # libpq-fe.h:413
    var PQparameterStatus: def(PGconnPtr, CStr) thin abi(
        "C"
    ) -> OptCStr  # libpq-fe.h:409
    var PQtransactionStatus: def(PGconnPtr) thin abi(
        "C"
    ) -> c_int  # libpq-fe.h:408
    var PQlibVersion: def() thin abi("C") -> c_int  # libpq-fe.h:709

    # --- synchronous command execution ----------------------------------
    var PQexec: def(PGconnPtr, CStr) thin abi(
        "C"
    ) -> PGresultPtr  # libpq-fe.h:486
    var PQexecParams: def(
        PGconnPtr, CStr, c_int, OidPtr, CStrArray, IntPtr, IntPtr, c_int
    ) thin abi(
        "C"
    ) -> PGresultPtr  # libpq-fe.h:487
    var PQprepare: def(PGconnPtr, CStr, CStr, c_int, OidPtr) thin abi(
        "C"
    ) -> PGresultPtr  # libpq-fe.h:495
    var PQexecPrepared: def(
        PGconnPtr, CStr, c_int, CStrArray, IntPtr, IntPtr, c_int
    ) thin abi(
        "C"
    ) -> PGresultPtr  # libpq-fe.h:498
    var PQdescribePrepared: def(PGconnPtr, CStr) thin abi(
        "C"
    ) -> PGresultPtr  # libpq-fe.h:611

    # --- result inspection ----------------------------------------------
    var PQresultStatus: def(PGresultPtr) thin abi(
        "C"
    ) -> c_int  # libpq-fe.h:582
    var PQresultErrorMessage: def(PGresultPtr) thin abi(
        "C"
    ) -> CStr  # libpq-fe.h:584
    var PQresultErrorField: def(PGresultPtr, c_int) thin abi(
        "C"
    ) -> OptCStr  # libpq-fe.h:588
    var PQntuples: def(PGresultPtr) thin abi("C") -> c_int  # libpq-fe.h:589
    var PQnfields: def(PGresultPtr) thin abi("C") -> c_int  # libpq-fe.h:590
    var PQfname: def(PGresultPtr, c_int) thin abi(
        "C"
    ) -> OptCStr  # libpq-fe.h:592
    var PQfnumber: def(PGresultPtr, CStr) thin abi(
        "C"
    ) -> c_int  # libpq-fe.h:593
    var PQftype: def(PGresultPtr, c_int) thin abi(
        "C"
    ) -> UInt32  # libpq-fe.h:597
    var PQfformat: def(PGresultPtr, c_int) thin abi(
        "C"
    ) -> c_int  # libpq-fe.h:596
    var PQfmod: def(PGresultPtr, c_int) thin abi("C") -> c_int  # libpq-fe.h:599
    var PQgetvalue: def(PGresultPtr, c_int, c_int) thin abi(
        "C"
    ) -> OptCStr  # libpq-fe.h:604
    var PQgetlength: def(PGresultPtr, c_int, c_int) thin abi(
        "C"
    ) -> c_int  # libpq-fe.h:605
    var PQgetisnull: def(PGresultPtr, c_int, c_int) thin abi(
        "C"
    ) -> c_int  # libpq-fe.h:606
    var PQcmdTuples: def(PGresultPtr) thin abi("C") -> CStr  # libpq-fe.h:603
    var PQclear: def(PGresultPtr) thin abi("C") -> None  # libpq-fe.h:623
    var PQcmdStatus: def(PGresultPtr) thin abi("C") -> CStr  # libpq-fe.h:600
    var PQnparams: def(PGresultPtr) thin abi("C") -> c_int  # libpq-fe.h:607
    var PQparamtype: def(PGresultPtr, c_int) thin abi(
        "C"
    ) -> UInt32  # libpq-fe.h:608

    # --- quoting and libpq-allocated memory -----------------------------
    var PQescapeLiteral: def(PGconnPtr, CStr, c_size_t) thin abi(
        "C"
    ) -> OptCStr  # libpq-fe.h:647
    var PQescapeIdentifier: def(PGconnPtr, CStr, c_size_t) thin abi(
        "C"
    ) -> OptCStr  # libpq-fe.h:648
    var PQfreemem: def(MutRawPtr) thin abi("C") -> None  # libpq-fe.h:626

    # --- asynchronous connection and socket -----------------------------
    var PQconnectStart: def(CStr) thin abi("C") -> PGconnPtr  # libpq-fe.h:327
    var PQconnectStartParams: def(CStrArray, CStrArray, c_int) thin abi(
        "C"
    ) -> PGconnPtr  # libpq-fe.h:326
    var PQconnectPoll: def(PGconnPtr) thin abi("C") -> c_int  # libpq-fe.h:328
    var PQsocket: def(PGconnPtr) thin abi("C") -> c_int  # libpq-fe.h:415
    var PQsetnonblocking: def(PGconnPtr, c_int) thin abi(
        "C"
    ) -> c_int  # libpq-fe.h:559
    var PQisnonblocking: def(PGconnPtr) thin abi("C") -> c_int  # libpq-fe.h:560

    # --- asynchronous command execution ---------------------------------
    var PQsendQuery: def(PGconnPtr, CStr) thin abi(
        "C"
    ) -> c_int  # libpq-fe.h:509
    var PQsendQueryParams: def(
        PGconnPtr, CStr, c_int, OidPtr, CStrArray, IntPtr, IntPtr, c_int
    ) thin abi(
        "C"
    ) -> c_int  # libpq-fe.h:510
    var PQsendPrepare: def(PGconnPtr, CStr, CStr, c_int, OidPtr) thin abi(
        "C"
    ) -> c_int  # libpq-fe.h:518
    var PQsendQueryPrepared: def(
        PGconnPtr, CStr, c_int, CStrArray, IntPtr, IntPtr, c_int
    ) thin abi(
        "C"
    ) -> c_int  # libpq-fe.h:521
    var PQflush: def(PGconnPtr) thin abi("C") -> c_int  # libpq-fe.h:567
    var PQconsumeInput: def(PGconnPtr) thin abi("C") -> c_int  # libpq-fe.h:534
    var PQisBusy: def(PGconnPtr) thin abi("C") -> c_int  # libpq-fe.h:533
    var PQgetResult: def(PGconnPtr) thin abi(
        "C"
    ) -> PGresultPtr  # libpq-fe.h:530
    var PQsetSingleRowMode: def(PGconnPtr) thin abi(
        "C"
    ) -> c_int  # libpq-fe.h:528

    # --- cancellation and notifications ---------------------------------
    var PQgetCancel: def(PGconnPtr) thin abi(
        "C"
    ) -> PGcancelPtr  # libpq-fe.h:387
    var PQcancel: def(PGcancelPtr, MutCStr, c_int) thin abi(
        "C"
    ) -> c_int  # libpq-fe.h:393
    var PQfreeCancel: def(PGcancelPtr) thin abi("C") -> None  # libpq-fe.h:390
    var PQnotifies: def(PGconnPtr) thin abi(
        "C"
    ) -> PGnotifyPtr  # libpq-fe.h:544

    def __init__(out self, path: String) raises:
        comptime FLAGS = RTLD.NOW | RTLD.GLOBAL | RTLD.NODELETE
        self._lib = OwnedDLHandle(path, FLAGS)

        self.PQconnectdb = _dl_sym[def(CStr) thin abi("C") -> PGconnPtr](
            self._lib, "PQconnectdb"
        )
        self.PQconnectdbParams = _dl_sym[
            def(CStrArray, CStrArray, c_int) thin abi("C") -> PGconnPtr
        ](self._lib, "PQconnectdbParams")
        self.PQfinish = _dl_sym[def(PGconnPtr) thin abi("C") -> None](
            self._lib, "PQfinish"
        )
        self.PQreset = _dl_sym[def(PGconnPtr) thin abi("C") -> None](
            self._lib, "PQreset"
        )

        self.PQstatus = _dl_sym[def(PGconnPtr) thin abi("C") -> c_int](
            self._lib, "PQstatus"
        )
        self.PQerrorMessage = _dl_sym[def(PGconnPtr) thin abi("C") -> CStr](
            self._lib, "PQerrorMessage"
        )
        self.PQserverVersion = _dl_sym[def(PGconnPtr) thin abi("C") -> c_int](
            self._lib, "PQserverVersion"
        )
        self.PQparameterStatus = _dl_sym[
            def(PGconnPtr, CStr) thin abi("C") -> OptCStr
        ](self._lib, "PQparameterStatus")
        self.PQtransactionStatus = _dl_sym[
            def(PGconnPtr) thin abi("C") -> c_int
        ](self._lib, "PQtransactionStatus")
        self.PQlibVersion = _dl_sym[def() thin abi("C") -> c_int](
            self._lib, "PQlibVersion"
        )

        self.PQexec = _dl_sym[
            def(PGconnPtr, CStr) thin abi("C") -> PGresultPtr
        ](self._lib, "PQexec")
        self.PQexecParams = _dl_sym[
            def(
                PGconnPtr, CStr, c_int, OidPtr, CStrArray, IntPtr, IntPtr, c_int
            ) thin abi("C") -> PGresultPtr
        ](self._lib, "PQexecParams")
        self.PQprepare = _dl_sym[
            def(
                PGconnPtr, CStr, CStr, c_int, OidPtr
            ) thin abi("C") -> PGresultPtr
        ](self._lib, "PQprepare")
        self.PQexecPrepared = _dl_sym[
            def(
                PGconnPtr, CStr, c_int, CStrArray, IntPtr, IntPtr, c_int
            ) thin abi("C") -> PGresultPtr
        ](self._lib, "PQexecPrepared")
        self.PQdescribePrepared = _dl_sym[
            def(PGconnPtr, CStr) thin abi("C") -> PGresultPtr
        ](self._lib, "PQdescribePrepared")

        self.PQresultStatus = _dl_sym[def(PGresultPtr) thin abi("C") -> c_int](
            self._lib, "PQresultStatus"
        )
        self.PQresultErrorMessage = _dl_sym[
            def(PGresultPtr) thin abi("C") -> CStr
        ](self._lib, "PQresultErrorMessage")
        self.PQresultErrorField = _dl_sym[
            def(PGresultPtr, c_int) thin abi("C") -> OptCStr
        ](self._lib, "PQresultErrorField")
        self.PQntuples = _dl_sym[def(PGresultPtr) thin abi("C") -> c_int](
            self._lib, "PQntuples"
        )
        self.PQnfields = _dl_sym[def(PGresultPtr) thin abi("C") -> c_int](
            self._lib, "PQnfields"
        )
        self.PQfname = _dl_sym[
            def(PGresultPtr, c_int) thin abi("C") -> OptCStr
        ](self._lib, "PQfname")
        self.PQfnumber = _dl_sym[def(PGresultPtr, CStr) thin abi("C") -> c_int](
            self._lib, "PQfnumber"
        )
        self.PQftype = _dl_sym[def(PGresultPtr, c_int) thin abi("C") -> UInt32](
            self._lib, "PQftype"
        )
        self.PQfformat = _dl_sym[
            def(PGresultPtr, c_int) thin abi("C") -> c_int
        ](self._lib, "PQfformat")
        self.PQfmod = _dl_sym[def(PGresultPtr, c_int) thin abi("C") -> c_int](
            self._lib, "PQfmod"
        )
        self.PQgetvalue = _dl_sym[
            def(PGresultPtr, c_int, c_int) thin abi("C") -> OptCStr
        ](self._lib, "PQgetvalue")
        self.PQgetlength = _dl_sym[
            def(PGresultPtr, c_int, c_int) thin abi("C") -> c_int
        ](self._lib, "PQgetlength")
        self.PQgetisnull = _dl_sym[
            def(PGresultPtr, c_int, c_int) thin abi("C") -> c_int
        ](self._lib, "PQgetisnull")
        self.PQcmdTuples = _dl_sym[def(PGresultPtr) thin abi("C") -> CStr](
            self._lib, "PQcmdTuples"
        )
        self.PQclear = _dl_sym[def(PGresultPtr) thin abi("C") -> None](
            self._lib, "PQclear"
        )
        self.PQcmdStatus = _dl_sym[def(PGresultPtr) thin abi("C") -> CStr](
            self._lib, "PQcmdStatus"
        )
        self.PQnparams = _dl_sym[def(PGresultPtr) thin abi("C") -> c_int](
            self._lib, "PQnparams"
        )
        self.PQparamtype = _dl_sym[
            def(PGresultPtr, c_int) thin abi("C") -> UInt32
        ](self._lib, "PQparamtype")

        self.PQescapeLiteral = _dl_sym[
            def(PGconnPtr, CStr, c_size_t) thin abi("C") -> OptCStr
        ](self._lib, "PQescapeLiteral")
        self.PQescapeIdentifier = _dl_sym[
            def(PGconnPtr, CStr, c_size_t) thin abi("C") -> OptCStr
        ](self._lib, "PQescapeIdentifier")
        self.PQfreemem = _dl_sym[def(MutRawPtr) thin abi("C") -> None](
            self._lib, "PQfreemem"
        )

        self.PQconnectStart = _dl_sym[def(CStr) thin abi("C") -> PGconnPtr](
            self._lib, "PQconnectStart"
        )
        self.PQconnectStartParams = _dl_sym[
            def(CStrArray, CStrArray, c_int) thin abi("C") -> PGconnPtr
        ](self._lib, "PQconnectStartParams")
        self.PQconnectPoll = _dl_sym[def(PGconnPtr) thin abi("C") -> c_int](
            self._lib, "PQconnectPoll"
        )
        self.PQsocket = _dl_sym[def(PGconnPtr) thin abi("C") -> c_int](
            self._lib, "PQsocket"
        )
        self.PQsetnonblocking = _dl_sym[
            def(PGconnPtr, c_int) thin abi("C") -> c_int
        ](self._lib, "PQsetnonblocking")
        self.PQisnonblocking = _dl_sym[def(PGconnPtr) thin abi("C") -> c_int](
            self._lib, "PQisnonblocking"
        )

        self.PQsendQuery = _dl_sym[def(PGconnPtr, CStr) thin abi("C") -> c_int](
            self._lib, "PQsendQuery"
        )
        self.PQsendQueryParams = _dl_sym[
            def(
                PGconnPtr, CStr, c_int, OidPtr, CStrArray, IntPtr, IntPtr, c_int
            ) thin abi("C") -> c_int
        ](self._lib, "PQsendQueryParams")
        self.PQsendPrepare = _dl_sym[
            def(PGconnPtr, CStr, CStr, c_int, OidPtr) thin abi("C") -> c_int
        ](self._lib, "PQsendPrepare")
        self.PQsendQueryPrepared = _dl_sym[
            def(
                PGconnPtr, CStr, c_int, CStrArray, IntPtr, IntPtr, c_int
            ) thin abi("C") -> c_int
        ](self._lib, "PQsendQueryPrepared")
        self.PQflush = _dl_sym[def(PGconnPtr) thin abi("C") -> c_int](
            self._lib, "PQflush"
        )
        self.PQconsumeInput = _dl_sym[def(PGconnPtr) thin abi("C") -> c_int](
            self._lib, "PQconsumeInput"
        )
        self.PQisBusy = _dl_sym[def(PGconnPtr) thin abi("C") -> c_int](
            self._lib, "PQisBusy"
        )
        self.PQgetResult = _dl_sym[def(PGconnPtr) thin abi("C") -> PGresultPtr](
            self._lib, "PQgetResult"
        )
        self.PQsetSingleRowMode = _dl_sym[
            def(PGconnPtr) thin abi("C") -> c_int
        ](self._lib, "PQsetSingleRowMode")

        self.PQgetCancel = _dl_sym[def(PGconnPtr) thin abi("C") -> PGcancelPtr](
            self._lib, "PQgetCancel"
        )
        self.PQcancel = _dl_sym[
            def(PGcancelPtr, MutCStr, c_int) thin abi("C") -> c_int
        ](self._lib, "PQcancel")
        self.PQfreeCancel = _dl_sym[def(PGcancelPtr) thin abi("C") -> None](
            self._lib, "PQfreeCancel"
        )
        self.PQnotifies = _dl_sym[def(PGconnPtr) thin abi("C") -> PGnotifyPtr](
            self._lib, "PQnotifies"
        )
