"""Owned libpq result handle and its metadata accessors.

`Result` owns one `PGresultPtr` and calls `PQclear` exactly once in
`__deinit__`. It is `Movable` but deliberately **not** `Copyable`: a copy
would hand the same pointer to two destructors. Row and column counts are
read once in `__init__` and cached, so `row_count` / `column_count` /
`__len__` never cross the FFI boundary.

Every index-taking accessor validates against the cached counts *before*
calling libpq. That matters beyond tidiness: libpq's own `PQfname` /
`PQgetvalue` print `out of range` diagnostics to stderr for a bad index and
then return NULL, so checking first is what keeps stderr clean.

Row-level access (`Row`, `RowIter`, `__getitem__`, `__iter__`) is not part of
this module yet; the internal `_check_cell` / `_is_null` / `_text` helpers are
the surface it will build on.
"""

from std.ffi import c_int

from pq.errors import PgError, PgErrorKind

from ._ffi.functions import LibpqFFI
from ._ffi.types import CStr, PGresultPtr


def _row_range_error(row: Int, nrows: Int) -> PgError:
    """Build the `TYPE_MISMATCH` error for a row index outside the result."""
    return PgError(
        PgErrorKind.TYPE_MISMATCH,
        String("row index ", row, " out of range (0..", nrows - 1, ")"),
    )


def _column_range_error(col: Int, ncols: Int) -> PgError:
    """Build the `TYPE_MISMATCH` error for a column index outside the result."""
    return PgError(
        PgErrorKind.TYPE_MISMATCH,
        String("column index ", col, " out of range (0..", ncols - 1, ")"),
    )


struct Result(Movable, Sized):
    """A libpq query result, owned and cleared on destruction.

    Constructed by `Connection.execute` from a `PGresultPtr` that has already
    been checked for a successful `PQresultStatus`. Holds the row and column
    counts read at construction time.
    """

    var _res: PGresultPtr
    var _pq: Pointer[LibpqFFI, MutUntrackedOrigin]
    var _nrows: Int
    var _ncols: Int

    def __init__(
        out self,
        res: PGresultPtr,
        pq: Pointer[LibpqFFI, MutUntrackedOrigin],
    ):
        """Take ownership of `res` and cache its shape.

        Calls `PQntuples` and `PQnfields` once each. Does not inspect
        `PQresultStatus`: the caller is responsible for only passing results
        that represent success.

        Args:
            res: The result handle to take ownership of.
            pq: The resolved libpq function table, used for every later call
                including `PQclear` in `__deinit__`.
        """
        self._res = res
        self._pq = pq
        self._nrows = Int(pq[].PQntuples(res))
        self._ncols = Int(pq[].PQnfields(res))

    def __deinit__(deinit self):
        """Release the result with `PQclear`.

        Goes through the stored `_pq` table rather than `libpq()` because a
        destructor cannot raise and `libpq()` is `raises PgError`.
        """
        if not self._res.is_null():
            self._pq[].PQclear(self._res)

    def row_count(self) -> Int:
        """Return the number of rows in the result.

        Returns:
            The cached `PQntuples` value; 0 for a command that returns no rows.
        """
        return self._nrows

    def column_count(self) -> Int:
        """Return the number of columns in the result.

        Returns:
            The cached `PQnfields` value.
        """
        return self._ncols

    def __len__(self) -> Int:
        """Return the number of rows, so `len(result)` works.

        Returns:
            The same value as `row_count`.
        """
        return self._nrows

    def column_name(self, i: Int) raises PgError -> String:
        """Return the name of column `i`.

        Args:
            i: Zero-based column index.

        Returns:
            An owned copy of the column name. The result's own storage is not
            referenced after this returns.

        Raises:
            PgError: `TYPE_MISMATCH` when `i` is outside
                `0..column_count() - 1`. The index is rejected before libpq is
                called.
        """
        if i < 0 or i >= self._ncols:
            raise _column_range_error(i, self._ncols)
        var p = self._pq[].PQfname(self._res, c_int(i))
        if p:
            return String(unsafe_from_utf8_ptr=p.value())
        raise _column_range_error(i, self._ncols)

    def column_index(self, name: String) raises PgError -> Int:
        """Return the index of the column called `name`.

        Matching follows `PQfnumber`, which folds an unquoted name to lower
        case before comparing. For `SELECT 1 AS FOO, 2 AS "BAR"`:

        - `"FOO"` and `"foo"` both return 0, because `FOO` in the query was
          itself folded to `foo`.
        - `"BAR"` returns -1 here and therefore raises: the column was created
          with a quoted, case-preserved name, so the unquoted lookup folds to
          `bar` and finds nothing.
        - To reach that column the double quotes must be part of the argument:
          `"\\"BAR\\""` returns 1.

        Args:
            name: Column name, optionally wrapped in double quotes to defeat
                case folding.

        Returns:
            Zero-based index of the matching column.

        Raises:
            PgError: `TYPE_MISMATCH` when no column matches.
        """
        # as_c_string_span() is `mut self` and may reallocate, so it needs an
        # owned String; `name` arrives read-only. The copy stays alive until
        # after PQfnumber has read through the pointer.
        var owned = name.copy()
        var index = Int(
            self._pq[].PQfnumber(
                self._res,
                CStr(unsafe_from_address=Int(owned.as_c_string_span().ptr())),
            )
        )
        _ = owned^
        if index < 0:
            raise PgError(
                PgErrorKind.TYPE_MISMATCH,
                String('column "', name, '" does not exist'),
            )
        return index

    def column_type_oid(self, i: Int) raises PgError -> UInt32:
        """Return the PostgreSQL type OID of column `i`.

        Args:
            i: Zero-based column index.

        Returns:
            The `PQftype` OID, matching the `OID_*` constants in
            `pq.decode_text`.

        Raises:
            PgError: `TYPE_MISMATCH` when `i` is outside
                `0..column_count() - 1`. The index is rejected before libpq is
                called.
        """
        if i < 0 or i >= self._ncols:
            raise _column_range_error(i, self._ncols)
        return self._pq[].PQftype(self._res, c_int(i))

    def affected_rows(self) -> Int:
        """Return the row count reported by the command tag.

        `PQcmdTuples` is the number of rows a `SELECT`, `INSERT`, `UPDATE`,
        `DELETE` or similar statement touched, as a string. It is empty for
        statements that carry no such count, such as a bare DDL command.

        Returns:
            The parsed count, or 0 when the command tag carries no number.
        """
        var text = String(
            unsafe_from_utf8_ptr=self._pq[].PQcmdTuples(self._res)
        )
        if text == "":
            return 0
        try:
            return atol(text)
        except e:
            return 0

    def _check_cell(self, row: Int, col: Int) raises PgError:
        """Reject a cell coordinate outside the result, before libpq sees it.

        Args:
            row: Zero-based row index.
            col: Zero-based column index.

        Raises:
            PgError: `TYPE_MISMATCH` when `row` or `col` is out of range. The
                row is checked first.
        """
        if row < 0 or row >= self._nrows:
            raise _row_range_error(row, self._nrows)
        if col < 0 or col >= self._ncols:
            raise _column_range_error(col, self._ncols)

    def _is_null(self, row: Int, col: Int) -> Bool:
        """Report whether a cell holds SQL NULL.

        Assumes the coordinate has already passed `_check_cell`.

        Args:
            row: Zero-based row index.
            col: Zero-based column index.

        Returns:
            True when `PQgetisnull` is non-zero.
        """
        return (
            Int(self._pq[].PQgetisnull(self._res, c_int(row), c_int(col))) != 0
        )

    def _text(self, row: Int, col: Int) raises PgError -> String:
        """Return a cell's text-format value as an owned `String`.

        A SQL NULL reads back as an empty string here; use `_is_null` to tell
        the two apart.

        Args:
            row: Zero-based row index.
            col: Zero-based column index.

        Returns:
            An owned copy of the cell text. Nothing borrows the result's
            storage after this returns.

        Raises:
            PgError: `TYPE_MISMATCH` when `PQgetvalue` returns NULL, which
                only happens for an out-of-range coordinate that skipped
                `_check_cell`.
        """
        var p = self._pq[].PQgetvalue(self._res, c_int(row), c_int(col))
        if p:
            return String(unsafe_from_utf8_ptr=p.value())
        raise PgError(
            PgErrorKind.TYPE_MISMATCH,
            String("cell (", row, ", ", col, ") is out of range"),
        )
