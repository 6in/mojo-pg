"""Basic: connect, run one `SELECT`, read a typed row and a NULL back.

Imports nothing but `Connection` and `PgError` from `pq`, which is the point:
the whole round trip is reachable through the package's re-exported surface.

Run it with `pixi run example-basic`. The server comes from
`PQ_TEST_CONNINFO` (`key=value ...` form only, never a `postgres://` URI),
falling back to the local container. Any `PgError` is printed and turned into
a non-zero exit status.
"""

from std.os import getenv
from std.sys import exit

from pq import Connection, PgError

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime SQL = "SELECT 1::int4 AS n, 'hello'::text AS s, NULL::text AS z"


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
        var res = conn.execute(String(SQL))
        for row in res:
            var n = row.get[Int32]("n")
            var s = row.get[String]("s")
            var z = row.get_optional[String]("z")
            print("n =", n)
            print("s =", s)
            print("z =", z.value() if z else String("NULL"))
        _ = res^
        _ = conn^
    except e:
        print("failed:", e)
        exit(1)
