"""Binary: ask for binary results and read all seventeen supported types.

Imports nothing but the package's re-exported surface -- `Connection`,
`PgError`, `ResultFormat` and the seven value types Phase 3 adds -- which is
the point: a binary round trip needs no module path and no `_ffi` detail.

`result_format=ResultFormat.BINARY` applies to **every** column of the result,
and the caller's `get[T]` calls do not change: `Row.get` reads `PQfformat` and
picks the decoder. The run proves that by asserting `column_format(0)` is
`BINARY` and exiting non-zero if it is not.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI), falling back to the local container. Any `PgError` is
printed and turned into a non-zero exit status.
"""

from std.os import getenv
from std.sys import exit

from pq import (
    Connection,
    Date,
    Decimal,
    Interval,
    PgError,
    ResultFormat,
    Time,
    TimeTz,
    Timestamp,
    TimestampTz,
    UUID,
)

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime SQL = (
    "SELECT true AS b,"
    " 32767::int2 AS i2,"
    " 2147483647::int4 AS i4,"
    " 9223372036854775807::int8 AS i8,"
    " 1.5::float4 AS f4,"
    " 0.1::float8 AS f8,"
    " 'héllo'::text AS t,"
    " '\\x00ff00'::bytea AS by,"
    " 1.50::numeric AS num,"
    " '2024-02-29'::date AS d,"
    " '2024-01-02 03:04:05.678901'::timestamp AS ts,"
    " '2024-01-02 03:04:05.678901+00'::timestamptz AS tstz,"
    " '12:34:56.5'::time AS tm,"
    " '12:34:56+09'::timetz AS tmtz,"
    " '1 year 2 mons 3 days 04:05:06.789'::interval AS iv,"
    " 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid AS u,"
    " '{\"a\": 1}'::jsonb AS j"
)


def _conninfo() -> String:
    """Return the conninfo of the server to connect to.

    Returns:
        `PQ_TEST_CONNINFO` when set and non-empty, else `DEFAULT_CONNINFO`.
    """
    var value = getenv("PQ_TEST_CONNINFO")
    return value if value != "" else String(DEFAULT_CONNINFO)


def main():
    try:
        var conn = Connection.open(_conninfo())
        var res = conn.execute(
            String(SQL), [], result_format=ResultFormat.BINARY
        )

        # Every column arrived in binary; `get[T]` is unchanged either way.
        var format = res.column_format(0)
        print("column_format(0) =", format)

        var row = res[0]
        print("b    =", row.get[Bool]("b"))
        print("i2   =", row.get[Int16]("i2"))
        print("i4   =", row.get[Int32]("i4"))
        print("i8   =", row.get[Int64]("i8"))
        print("f4   =", row.get[Float32]("f4"))
        print("f8   =", row.get[Float64]("f8"))
        print("t    =", row.get[String]("t"))
        # bytea is the three raw bytes in binary, not the eight of `\x00ff00`.
        var raw = row.get[List[UInt8]]("by")
        print("by   =", len(raw), "bytes, first", raw[0], "last", raw[2])
        print("num  =", row.get[Decimal]("num"))
        print("d    =", row.get[Date]("d"))
        print("ts   =", row.get[Timestamp]("ts"))
        print("tstz =", row.get[TimestampTz]("tstz"))
        print("tm   =", row.get[Time]("tm"))
        print("tmtz =", row.get[TimeTz]("tmtz"))
        print("iv   =", row.get[Interval]("iv"))
        print("u    =", row.get[UUID]("u"))
        print("j    =", row.get[String]("j"))

        _ = res^
        _ = conn^
        if format != ResultFormat.BINARY:
            print("expected binary columns, got", format)
            exit(1)
    except e:
        print("failed:", e)
        exit(1)
