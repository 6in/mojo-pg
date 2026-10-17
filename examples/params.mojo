"""Params: bind `$1`/`$2` values, then subdivide a block with a savepoint.

Imports nothing but `Connection`, `Param` and `PgError` from `pq`, which is the
point: parameter binding, the transaction block and the savepoint round trip are
all reachable through the package's re-exported surface. `Transaction` itself is
never named -- it arrives as the return value of `conn.transaction()`.

The run inserts one row through the connection and one through the block, with a
second insert inside the block undone by `rollback_to("sp")`. Two rows therefore
survive the `commit()`, and a different count is reported and exits non-zero.

Run it with `pixi run example-params`. The server comes from
`PQ_TEST_CONNINFO` (a `key=value ...` string or a `postgresql://` URI, passed
to `PQconnectdb` as is), falling back to the local container. Any `PgError` is
printed and turned into a non-zero exit status.
"""

from std.os import getenv
from std.sys import exit

from pq import Connection, Param, PgError

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime CREATE_TABLE = "CREATE TEMP TABLE pq_p2_example(id int4, label text)"

comptime INSERT_SQL = "INSERT INTO pq_p2_example (id, label) VALUES ($1, $2)"

comptime SELECT_SQL = "SELECT id, label FROM pq_p2_example WHERE id = $1"

comptime COUNT_SQL = "SELECT count(*) FROM pq_p2_example"

comptime EXPECTED_ROWS = 2


def _conninfo() -> String:
    """Return the conninfo of the server to connect to.

    Returns:
        `PQ_TEST_CONNINFO` when set and non-empty, else `DEFAULT_CONNINFO`.
    """
    var value = getenv("PQ_TEST_CONNINFO")
    return value if value != "" else String(DEFAULT_CONNINFO)


def _count(conn: Connection) raises PgError -> Int:
    """Count the rows currently visible in `pq_p2_example`.

    Args:
        conn: The connection whose session owns the temporary table.

    Returns:
        The number of rows the session can see.

    Raises:
        PgError: Whatever the `SELECT count(*)` or the decoding raised.
    """
    var result = conn.execute(String(COUNT_SQL))
    var total = result[0].get[Int64](0)
    _ = result^
    return Int(total)


def main():
    try:
        var conn = Connection.open(_conninfo())
        var created = conn.execute(String(CREATE_TABLE))
        _ = created^

        # One row through the connection itself, bound as $1 and $2.
        var inserted = conn.execute(String(INSERT_SQL), [Int32(1), "one"])
        _ = inserted^

        var res = conn.execute(String(SELECT_SQL), [Int32(1)])
        for row in res:
            print("id =", row.get[Int32]("id"))
            print("label =", row.get[String]("label"))
        _ = res^

        # One row through the block, plus one the savepoint takes back.
        var kept: List[Param] = [Int32(2), "two"]
        var undone: List[Param] = [Int32(3), "three"]
        var tx = conn.transaction()
        var first = tx.execute(String(INSERT_SQL), kept)
        _ = first^
        tx.savepoint("sp")
        var second = tx.execute(String(INSERT_SQL), undone)
        _ = second^
        tx.rollback_to("sp")
        tx.commit()

        var total = _count(conn)
        print("rows =", total)
        _ = conn^
        if total != EXPECTED_ROWS:
            print("expected", EXPECTED_ROWS, "rows, got", total)
            exit(1)
    except e:
        print("failed:", e)
        exit(1)
