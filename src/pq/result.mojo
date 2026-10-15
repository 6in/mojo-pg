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

Row-level access is `__getitem__` and `__iter__`, both of which hand out `Row`
values. A `Row` is a borrowed view -- a `Pointer[Result, origin]` plus a row
index, never a snapshot of the row data -- so the `origin` parameter makes a
`Row` that outlives its `Result` a compile error instead of a dangling read.
`Row.get` / `Row.get_optional` build on `_check_cell` / `_is_null` / `_text`
and finish in `pq.decode_text.decode_text`.
"""

from std.ffi import c_int

from pq.decode_text import decode_text
from pq.errors import PgError, PgErrorKind, _reject_nul

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


struct Result(Iterable, Movable, Sized):
    """A libpq query result, owned and cleared on destruction.

    Constructed by `Connection.execute` from a `PGresultPtr` that has already
    been checked for a successful `PQresultStatus`. Holds the row and column
    counts read at construction time.
    """

    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = RowIter[origin=iterable_origin]
    """The iterator `__iter__` returns, bound to the borrow's origin.

    Parameters:
        iterable_mut: Mutability of the borrow being iterated, inferred from
            `iterable_origin`.
        iterable_origin: Origin of the `Result` borrow the rows will view.
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

    def __getitem__(ref self, i: Int) raises PgError -> Row[origin_of(self)]:
        """Return a borrowed view of row `i`, so `result[i]` works.

        Nothing is copied: the `Row` carries a pointer to this result plus
        the row index, and reads cells on demand.

        Args:
            i: Zero-based row index.

        Returns:
            A `Row` bound to this result's origin.

        Raises:
            PgError: `TYPE_MISMATCH` when `i` is outside
                `0..row_count() - 1`, which includes every negative index.
        """
        if i < 0 or i >= self._nrows:
            raise _row_range_error(i, self._nrows)
        return Row[origin_of(self)](Pointer(to=self), i)

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        """Return an iterator over the rows, so `for row in result:` works.

        Returns:
            A `RowIter` positioned at row 0. It yields exactly `row_count()`
            rows in index order, and nothing at all when the result has no
            rows.
        """
        return RowIter[origin_of(self)](Pointer(to=self), 0)

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
            PgError: `TYPE_MISMATCH` when no column matches, or when `name`
                contains a NUL byte, which `PQfnumber` could only see
                truncated.
        """
        _reject_nul(name, "name")
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


struct Row[origin: ImmOrigin](Copyable):
    """One row of a `Result`, as a borrowed view.

    Holds a pointer to the result and a row index; no cell data is copied at
    construction, and every accessor reads through the pointer. `origin` ties
    the view to the borrow it came from, so a `Row` outliving its `Result` is
    a compile error rather than a dangling read -- there is no runtime guard
    for it.

    Parameters:
        origin: Immutable origin of the borrowed `Result`.
    """

    var _res: Pointer[Result, Self.origin]
    var _index: Int

    def __init__(out self, res: Pointer[Result, Self.origin], index: Int):
        """Bind a row index to a result.

        Args:
            res: Pointer to the result this row belongs to.
            index: Zero-based row index. Not validated here; `Result` only
                ever builds in-range rows, and each accessor re-checks the
                full cell coordinate anyway.
        """
        self._res = res
        self._index = index

    def get[T: Copyable](self, col: Int) raises PgError -> T:
        """Decode column `col` of this row as `T`.

        Validates the coordinate, then rejects SQL NULL, then decodes. The
        NULL check must precede the read: libpq reports both SQL NULL and a
        genuinely empty value as an empty string, so the order is the only
        thing that distinguishes them. Use `get_optional` for a nullable
        column.

        The column's OID must match `T` exactly -- there is no widening, so
        reading an `int2` column as `Int32` is a `TYPE_MISMATCH`:

        | `T`            | Required column OID                          |
        |----------------|----------------------------------------------|
        | `Bool`         | 16 (bool)                                    |
        | `Int16`        | 21 (int2)                                    |
        | `Int32`        | 23 (int4)                                    |
        | `Int64`, `Int` | 20 (int8)                                    |
        | `Float32`      | 700 (float4)                                 |
        | `Float64`      | 701 (float8)                                 |
        | `List[UInt8]`  | 17 (bytea), hex format only                  |
        | `String`       | any                                          |

        `pq.decode_text.decode_text` implements the table and is the one place
        to change when a type is added.

        Parameters:
            T: The Mojo type to decode into, from the table above. Any other
                type fails to compile.

        Args:
            col: Zero-based column index.

        Returns:
            The decoded value.

        Raises:
            PgError: `NULL_VALUE` when the cell is SQL NULL;
                `TYPE_MISMATCH` when `col` is outside
                `0..Result.column_count() - 1`, or when the column OID or
                the cell text does not match `T`.
        """
        self._res[]._check_cell(self._index, col)
        if self._res[]._is_null(self._index, col):
            raise PgError(
                PgErrorKind.NULL_VALUE, String("column ", col, " is NULL")
            )
        return decode_text[T](
            self._res[]._text(self._index, col),
            self._res[].column_type_oid(col),
        )

    def get[T: Copyable](self, col: String) raises PgError -> T:
        """Decode the column named `col` of this row as `T`.

        The name is resolved by `Result.column_index`, which follows
        `PQfnumber`: an unquoted name is folded to lower case before
        comparing, so for `SELECT 1 AS FOO, 2 AS "BAR"` both `"FOO"` and
        `"foo"` reach column 0. A quoted, case-preserved column is only
        reachable when the double quotes are part of the argument, so `"BAR"`
        raises while `"\\"BAR\\""` reaches column 1.

        Parameters:
            T: The Mojo type to decode into.

        Args:
            col: Column name, optionally wrapped in double quotes to defeat
                case folding.

        Returns:
            The decoded value.

        Raises:
            PgError: `NULL_VALUE` when the cell is SQL NULL;
                `TYPE_MISMATCH` when no column matches `col`, when `col`
                contains a NUL byte -- the message names `name`, the argument
                of `Result.column_index`, which this resolves through
                (`embedded NUL byte in name`) -- or when the column OID or the
                cell text does not match `T`.
        """
        return self.get[T](self._res[].column_index(col))

    def get_optional[T: Copyable](self, col: Int) raises PgError -> Optional[T]:
        """Decode column `col` of this row as an optional `T`.

        The nullable counterpart of `get`: SQL NULL yields an empty
        `Optional` instead of raising. A non-NULL empty string is still a
        value, so a `text` column holding `''` comes back as `Optional("")`,
        not as `None`.

        Parameters:
            T: The Mojo type to decode into.

        Args:
            col: Zero-based column index.

        Returns:
            An empty `Optional` when the cell is SQL NULL, otherwise the
            decoded value.

        Raises:
            PgError: `TYPE_MISMATCH` when `col` is outside
                `0..Result.column_count() - 1`, or when the column OID or
                the cell text does not match `T`.
        """
        self._res[]._check_cell(self._index, col)
        if self._res[]._is_null(self._index, col):
            return None
        return decode_text[T](
            self._res[]._text(self._index, col),
            self._res[].column_type_oid(col),
        )

    def get_optional[
        T: Copyable
    ](self, col: String) raises PgError -> Optional[T]:
        """Decode the column named `col` of this row as an optional `T`.

        The name is resolved by `Result.column_index`, which follows
        `PQfnumber`: an unquoted name is folded to lower case before
        comparing, so for `SELECT 1 AS FOO, 2 AS "BAR"` both `"FOO"` and
        `"foo"` reach column 0. A quoted, case-preserved column is only
        reachable when the double quotes are part of the argument, so `"BAR"`
        raises while `"\\"BAR\\""` reaches column 1.

        Parameters:
            T: The Mojo type to decode into.

        Args:
            col: Column name, optionally wrapped in double quotes to defeat
                case folding.

        Returns:
            An empty `Optional` when the cell is SQL NULL, otherwise the
            decoded value.

        Raises:
            PgError: `TYPE_MISMATCH` when no column matches `col`, when `col`
                contains a NUL byte -- the message names `name`, the argument
                of `Result.column_index`, which this resolves through
                (`embedded NUL byte in name`) -- or when the column OID or the
                cell text does not match `T`.
        """
        return self.get_optional[T](self._res[].column_index(col))

    def is_null(self, col: Int) raises PgError -> Bool:
        """Report whether column `col` of this row holds SQL NULL.

        Args:
            col: Zero-based column index.

        Returns:
            True for SQL NULL. A non-NULL empty string returns False.

        Raises:
            PgError: `TYPE_MISMATCH` when `col` is outside
                `0..Result.column_count() - 1`.
        """
        self._res[]._check_cell(self._index, col)
        return self._res[]._is_null(self._index, col)


struct RowIter[origin: ImmOrigin](Iterator):
    """Iterator over the rows of a `Result`.

    Hands out `Row` views in index order and raises `StopIteration` once the
    last row has been yielded, so a result with no rows yields nothing.

    Parameters:
        origin: Immutable origin of the borrowed `Result`.
    """

    comptime Element = Row[Self.origin]
    """The item type `__next__` produces."""

    var _res: Pointer[Result, Self.origin]
    var _index: Int

    def __init__(out self, res: Pointer[Result, Self.origin], index: Int):
        """Start iteration at `index`.

        Args:
            res: Pointer to the result being iterated.
            index: Zero-based index of the row to yield first.
        """
        self._res = res
        self._index = index

    def __next__(mut self) raises StopIteration -> Self.Element:
        """Return a view of the current row and advance past it.

        Returns:
            A `Row` for the current index.

        Raises:
            StopIteration: Once every row has been yielded, which is
                immediately for a result with no rows.
        """
        if self._index >= self._res[]._nrows:
            raise StopIteration()
        self._index += 1
        return Row[Self.origin](self._res, self._index - 1)
