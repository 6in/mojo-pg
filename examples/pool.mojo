"""Pool: borrow two connections, hit the limit, then get a backend back.

Imports `Pool` and its `PooledConnection` guard, plus `PgError`, from `pq`:
the guard is named only because `_backend_pid` takes one as an argument, and
everything else goes through the pool itself. A guard forwards the
`Connection` API, so `guard.execute(sql)` is the same call a connection takes.

The run opens a pool of two, borrows both, and shows that a third `acquire()`
raises `PgErrorKind.USAGE` rather than opening a connection past the limit.
Dropping one guard with `_ = first^` gives that connection back, and the next
`acquire()` comes out on the same backend, which `pg_backend_pid()` proves. A
third `acquire()` that succeeds, or a backend that is not the one that went
back, is reported and exits non-zero.

Run it with `pixi run example-pool`. The server comes from
`PQ_TEST_CONNINFO` (a `key=value ...` string or a `postgresql://` URI, passed
to `PQconnectdb` as is), falling back to the local container. Any `PgError` is
printed and turned into a non-zero exit status.
"""

from std.os import getenv
from std.sys import exit

from pq import PgError, Pool, PooledConnection

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime BACKEND_PID = "SELECT pg_backend_pid()"

comptime POOL_SIZE = 2


def _conninfo() -> String:
    """Return the conninfo of the server to connect to.

    Returns:
        `PQ_TEST_CONNINFO` when set and non-empty, else `DEFAULT_CONNINFO`.
    """
    var value = getenv("PQ_TEST_CONNINFO")
    return value if value != "" else String(DEFAULT_CONNINFO)


def _backend_pid[
    origin: ImmOrigin, //
](guard: PooledConnection[origin]) raises PgError -> Int:
    """Return the PID of the backend the guard is holding.

    Two guards on different backends and one guard on a reused backend are
    only distinguishable by this number, so the reuse this example claims is
    shown with it.

    Parameters:
        origin: Immutable origin of the `Pool` the guard borrows; inferred.

    Args:
        guard: The borrowed connection to ask.

    Returns:
        The server's `pg_backend_pid()` for that connection.

    Raises:
        PgError: Whatever the `SELECT` or the decoding raised.
    """
    var result = guard.execute(String(BACKEND_PID))
    var pid = result[0].get[Int32](0)
    _ = result^
    return Int(pid)


def main():
    try:
        var pool = Pool.open(_conninfo(), 2)
        var first = pool.acquire()
        var second = pool.acquire()
        print("size =", pool.size())
        print("idle =", pool.idle())
        print("borrowed =", pool.borrowed())
        var exhausted = False
        try:
            var third = pool.acquire()
            _ = third^
        except e:
            print("pool exhausted:", e)
            exhausted = True

        var pid = _backend_pid(first)
        _ = first^
        var again = pool.acquire()
        print("reused backend =", _backend_pid(again) == pid)
        var reused = _backend_pid(again)
        _ = again^
        _ = second^
        _ = pool^

        if not exhausted:
            print("expected acquire() past", POOL_SIZE, "to raise, it did not")
            exit(1)
        if reused != pid:
            print("expected backend", pid, "again, got", reused)
            exit(1)
    except e:
        print("failed:", e)
        exit(1)
