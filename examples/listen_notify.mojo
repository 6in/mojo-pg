"""Listen/notify: subscribe on one connection, send on another, read it back.

`LISTEN` is an ordinary statement, so it goes through `send` / `fetch_all`
like any other; the notification itself is not a result and arrives whenever
the server gets round to it, which is what `wait_notification` waits for. The
sender is a synchronous `Connection` because `NOTIFY` needs nothing
asynchronous -- and because the `backend_pid` on the notification is the
sender's, which is only interesting when it is a different backend.

Nothing arriving within the budget is a normal outcome rather than an error,
so that case prints a line and still exits 0.

Run it with `pixi run example-notify`. The server comes from
`PQ_TEST_CONNINFO` (`key=value ...` form only, never a `postgres://` URI),
falling back to the local container. Any `PgError` is printed and turned into
a non-zero exit status.
"""

from std.os import getenv
from std.sys import exit

from pq import AsyncConnection, Connection, PgError

comptime DEFAULT_CONNINFO = (
    "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
)

comptime CHANNEL = "pq_example"


def _conninfo() -> String:
    """Return the conninfo of the server to connect to.

    Returns:
        `PQ_TEST_CONNINFO` when set and non-empty, else `DEFAULT_CONNINFO`.
    """
    var value = getenv("PQ_TEST_CONNINFO")
    return value if value != "" else String(DEFAULT_CONNINFO)


def main():
    try:
        var listener = AsyncConnection.connect_blocking(_conninfo(), 5000)
        listener.send(String("LISTEN ") + CHANNEL)
        _ = listener.fetch_all(5000)
        var sender = Connection.open(_conninfo())
        var sent = sender.execute(
            String("NOTIFY ") + CHANNEL + ", 'hello from pq'"
        )
        _ = sent^
        _ = sender^
        var note = listener.wait_notification(2000)
        if note:
            var value = note.take()
            print("channel =", value.channel)
            print("payload =", value.payload)
            print("backend_pid =", value.backend_pid)
        else:
            print("no notification within 2 s")
        _ = listener^
    except e:
        print("failed:", e)
        exit(1)
