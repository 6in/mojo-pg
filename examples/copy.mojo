"""Copy: stream 1000 rows in with `COPY`, then read the same rows back out.

Imports nothing but `Connection` and `PgError` from `pq`, which is the point:
both stream handles arrive as return values of `conn.copy_in()` and
`conn.copy_out()`, so neither `CopyIn` nor `CopyOut` is ever named. The write
side is one `write` per row of text-format COPY data; the read side is a
`while` loop over `next()`, because `CopyOut` is deliberately not an
`Iterator` and `for` is therefore unavailable.

The run copies `ROW_COUNT` rows into a temporary table and reads them back,
comparing the row count `finish()` reports, the number of rows that come back
out and the number of bytes that come back out with what was written. Any of
the three disagreeing is reported and exits non-zero.

Run it with `pixi run example-copy`. The server comes from
`PQ_TEST_CONNINFO` (a `key=value ...` string or a `postgresql://` URI, passed
to `PQconnectdb` as is), falling back to the local container. Any `PgError` is
printed and turned into a non-zero exit status.
"""

from std.os import getenv
from std.sys import exit

from pq import Connection, PgError

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime CREATE_TABLE = "CREATE TEMP TABLE pq_p7_copy(id int4, label text)"

comptime COPY_IN_SQL = "COPY pq_p7_copy (id, label) FROM STDIN"

comptime COPY_OUT_SQL = "COPY pq_p7_copy (id, label) TO STDOUT"

comptime ROW_COUNT = 1000


def _conninfo() -> String:
    """Return the conninfo of the server to connect to.

    Returns:
        `PQ_TEST_CONNINFO` when set and non-empty, else `DEFAULT_CONNINFO`.
    """
    var value = getenv("PQ_TEST_CONNINFO")
    return value if value != "" else String(DEFAULT_CONNINFO)


def _row_text(i: Int) -> String:
    """Build one row of text-format COPY data.

    The two columns are separated by a tab and the row ends in a newline,
    which is all the text format is. The label holds none of the three
    characters the format reserves -- tab, newline and backslash -- so no
    escaping is needed and the bytes written are the bytes the server stores.

    Args:
        i: The row's `id`, which its label repeats.

    Returns:
        `"<i>\\trow<i>\\n"`.
    """
    return String(i, "\trow", i, "\n")


def _written_bytes() -> Int:
    """Return how many bytes `ROW_COUNT` calls to `_row_text` produce.

    The COPY that reads the table back out re-renders the same two columns in
    the same text format, so this is also the number of bytes `copy_out` must
    hand back.

    Returns:
        The total length of every row of the stream that is written.
    """
    var total = 0
    for i in range(ROW_COUNT):
        total += _row_text(i).byte_length()
    return total


def main():
    try:
        var conn = Connection.open(_conninfo())
        var created = conn.execute(String(CREATE_TABLE))
        _ = created^

        var written = _written_bytes()

        var copy_in = conn.copy_in(String(COPY_IN_SQL))
        for i in range(ROW_COUNT):
            copy_in.write(_row_text(i))
        var inserted = copy_in.finish()
        print("copied in =", inserted.affected_rows())
        var in_rows = inserted.affected_rows()
        _ = inserted^

        var copy_out = conn.copy_out(String(COPY_OUT_SQL))
        var rows = 0
        var total_bytes = 0
        while True:
            var row = copy_out.next()
            if not row:
                break
            rows += 1
            ref payload = row.value()
            total_bytes += len(payload)
        print("copied out =", rows, "rows")
        print("copied out bytes =", total_bytes)
        _ = copy_out^
        _ = conn^

        if in_rows != ROW_COUNT:
            print("expected", ROW_COUNT, "rows copied in, got", in_rows)
            exit(1)
        if rows != ROW_COUNT:
            print("expected", ROW_COUNT, "rows copied out, got", rows)
            exit(1)
        if total_bytes != written:
            print("expected", written, "bytes back, got", total_bytes)
            exit(1)
    except e:
        print("failed:", e)
        exit(1)
