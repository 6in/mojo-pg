"""Bench: text vs binary results over 100,000 rows x 5 columns.

Prints timings and nothing else -- there is no pass or fail here. The point is
the shape of the two costs: `exec` is the round trip plus whatever the server
spends formatting the columns, `decode` is this client turning all 500,000
cells into Mojo values through `Row.get[T]`. A format that wins the first can
lose the second.

One warm-up run is discarded, then three measured runs per format, so a cold
first round trip and a cold `generate_series` plan do not land in the numbers.
Every cell is read: the `Int32` is summed, the `String`'s byte length is
summed, and the `Timestamp` is summed as micros, so nothing can be optimized
away unread.

Run it with `pixi run bench`. The server comes from `PQ_TEST_CONNINFO`
(a `key=value ...` string or a `postgresql://` URI, passed to `PQconnectdb` as
is), falling back to the local container; it is read-only, so any database will
do.
"""

from std.os import getenv
from std.sys import exit
from std.time import perf_counter_ns

from pq import Connection, PgError, ResultFormat, Timestamp

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime ROWS = 100000

comptime SQL = (
    "SELECT i::int4, i::int8, i::float8 / 3, 'row ' || i::text,"
    " timestamp '2000-01-01' + i * interval '1 second'"
    " FROM generate_series(1, "
    + String(ROWS)
    + ") AS g(i)"
)

comptime RUNS = 3
"""Measured runs per format, after one discarded warm-up."""


def _conninfo() -> String:
    """Return the conninfo of the server to connect to.

    Returns:
        `PQ_TEST_CONNINFO` when set and non-empty, else `DEFAULT_CONNINFO`.
    """
    var value = getenv("PQ_TEST_CONNINFO")
    return value if value != "" else String(DEFAULT_CONNINFO)


def _run(
    conn: Connection, format: ResultFormat, label: String, report: Bool
) raises PgError:
    """Fetch `SQL` in one format, reading every cell, and print the timings.

    Args:
        conn: An open connection.
        format: The result format to ask the server for.
        label: Name of the format, for the report line.
        report: False for the warm-up run, which prints nothing.

    Raises:
        PgError: Whatever the query or the decoding raised.
    """
    var t0 = perf_counter_ns()
    var result = conn.execute(String(SQL), [], result_format=format)
    var t1 = perf_counter_ns()

    var rows = result.row_count()
    var ints = 0
    var longs = Int64(0)
    var floats = Float64(0)
    var text_bytes = 0
    var micros = Int64(0)
    for i in range(rows):
        var row = result[i]
        ints += Int(row.get[Int32](0))
        longs += row.get[Int64](1)
        floats += row.get[Float64](2)
        text_bytes += row.get[String](3).byte_length()
        micros += row.get[Timestamp](4).micros
    var t2 = perf_counter_ns()
    _ = result^

    if report:
        print(
            label,
            ": exec",
            (t1 - t0) // 1000000,
            "ms, decode",
            (t2 - t1) // 1000000,
            "ms, total",
            (t2 - t0) // 1000000,
            "ms",
        )
    # Keep every sum observable so no read can be optimized away.
    if rows != ROWS or ints == 0 or longs == 0 or floats == 0:
        print("unexpected result:", rows, ints, longs, floats)
        exit(1)
    if text_bytes == 0 or micros == 0:
        print("unexpected result:", text_bytes, micros)
        exit(1)


def main():
    try:
        var conn = Connection.open(_conninfo())
        print("rows:", ROWS, "x 5 columns, ", RUNS, "runs per format")
        _run(conn, ResultFormat.TEXT, "warmup", False)
        _run(conn, ResultFormat.BINARY, "warmup", False)
        for _ in range(RUNS):
            _run(conn, ResultFormat.TEXT, "text  ", True)
            _run(conn, ResultFormat.BINARY, "binary", True)
        _ = conn^
    except e:
        print("failed:", e)
        exit(1)
