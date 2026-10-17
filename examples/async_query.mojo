"""Async: drive a slow query by hand and count the empty polls.

The whole point of `AsyncConnection` in one loop: `send` queues the statement
and returns, then each `poll_result` either hands over a result or says
"nothing yet", which is where a real program would service its event loop
instead of waiting. Here the waiting is a 100 ms `wait_readable` whose timeout
is ignored, and the counter is the proof that control came back. The loop runs
until `poll_result` answers None with the connection back in `IDLE`, which is
what ends a command -- a result is not the end of one.

The server comes from `PQ_TEST_CONNINFO` (`key=value ...` form only, never a
`postgres://` URI), falling back to the local container. Any `PgError` is
printed and turned into a non-zero exit status.
"""

from std.os import getenv
from std.sys import exit

from pq import AsyncConnection, AsyncState, PgError, PgErrorKind

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime SQL = "SELECT pg_sleep(2), 1::int4 AS n"


def _conninfo() -> String:
    """Return the conninfo of the server to connect to.

    Returns:
        `PQ_TEST_CONNINFO` when set and non-empty, else `DEFAULT_CONNINFO`.
    """
    var value = getenv("PQ_TEST_CONNINFO")
    return value if value != "" else String(DEFAULT_CONNINFO)


def main():
    try:
        var conn = AsyncConnection.connect_blocking(_conninfo(), 5000)
        conn.send(String(SQL))
        var polls = 0
        var results = 0
        # The command is over when `poll_result` answers None *and* the state
        # is back to `IDLE`: breaking at the first result would leave the
        # connection `BUSY` with the terminating None unread.
        while True:
            var got = conn.poll_result()
            if got:
                var res = got.take()
                print("n =", res[0].get[Int32]("n"))
                _ = res^
                results += 1
                continue
            if conn.state() == AsyncState.IDLE:
                break
            polls += 1
            try:
                conn.wait_readable(100)
            except e:
                # Out of budget for this iteration only: the statement is
                # still running, so poll again.
                if e.kind != PgErrorKind.TIMEOUT:
                    raise e^
        if results == 0:
            print("the command ended without a result")
        print("empty polls while waiting =", polls)
        _ = conn^
    except e:
        print("failed:", e)
        exit(1)
