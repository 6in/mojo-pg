"""Bench: the same SQL as examples/bench_formats.mojo, through psycopg 3.

Same shape as the Mojo bench: 100,000 rows x 5 columns, one discarded warm-up
and then three measured runs per format. `exec` is `cursor.execute()` -- the
round trip plus the server's formatting, with the whole result landed in the
client-side PGresult -- and `decode` is `fetchall()` plus a loop that reads
every cell, so nothing can be skipped unread. Text is the default cursor,
binary is `cursor(binary=True)`.

Run it with `pixi run bench-psycopg`. The server comes from `PQ_TEST_CONNINFO`
(`key=value ...` form), falling back to the local container. A psycopg error, a
conninfo that is not UTF-8 and a stdout that cannot be written are each printed
as one `failed: <type> <message>` record and turned into exit status 1.
"""

import os
import sys
import time
from datetime import datetime

import psycopg

DEFAULT_CONNINFO = "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
ROWS = 100000
SQL = (
    "SELECT i::int4, i::int8, i::float8 / 3, 'row ' || i::text,"
    " timestamp '2000-01-01' + i * interval '1 second'"
    f" FROM generate_series(1, {ROWS}) AS g(i)"
)
RUNS = 3
EPOCH = datetime(2000, 1, 1)


def _conninfo() -> str:
    return os.environ.get("PQ_TEST_CONNINFO") or DEFAULT_CONNINFO


def _run(conn: psycopg.Connection, binary: bool, label: str, report: bool) -> None:
    t0 = time.perf_counter_ns()
    with conn.cursor(binary=binary) as cur:
        cur.execute(SQL)
        t1 = time.perf_counter_ns()
        rows = cur.fetchall()
        ints = 0
        longs = 0
        floats = 0.0
        text_chars = 0
        micros = 0
        for i4, i8, f8, s, ts in rows:
            ints += i4
            longs += i8
            floats += f8
            text_chars += len(s)
            delta = ts - EPOCH
            micros += (delta.days * 86400 + delta.seconds) * 1_000_000 + delta.microseconds
        t2 = time.perf_counter_ns()
    if report:
        print(
            f"{label}: exec {(t1 - t0) // 1_000_000} ms,"
            f" decode {(t2 - t1) // 1_000_000} ms,"
            f" total {(t2 - t0) // 1_000_000} ms"
        )
    if len(rows) != ROWS or ints == 0 or longs == 0 or floats == 0 or text_chars == 0 or micros == 0:
        print("unexpected result:", len(rows), ints, longs, floats, text_chars, micros)
        sys.exit(1)


def _discard_stdout() -> None:
    """Point fd 1 at /dev/null so the interpreter's exit-time flush cannot fail.

    This is the recipe the `signal` module documents under "Note on SIGPIPE".
    Without it, a stdout that cannot be written (a full device, a closed pipe)
    fails a second time on the way out and Python prints `Exception ignored
    while flushing sys.stdout` and exits with status 120.
    """
    os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())


def main() -> None:
    status = 0
    try:
        try:
            with psycopg.connect(_conninfo(), autocommit=True) as conn:
                print(
                    f"psycopg {psycopg.__version__} impl={psycopg.pq.__impl__}"
                    f" libpq={psycopg.pq.version()} server={conn.info.server_version}"
                    f" python={sys.version.split()[0]}"
                )
                print(f"rows: {ROWS} x 5 columns, {RUNS} runs per format")
                _run(conn, False, "warmup", False)
                _run(conn, True, "warmup", False)
                for _ in range(RUNS):
                    _run(conn, False, "text  ", True)
                    _run(conn, True, "binary", True)
        except psycopg.Error as e:
            print("failed:", type(e).__name__, str(e).strip())
            status = 1
        except ValueError as e:
            # UnicodeEncodeError is a ValueError: psycopg encodes the conninfo
            # itself, so bytes that are not UTF-8 never reach libpq.
            print("failed:", type(e).__name__, str(e).strip())
            status = 1
        if sys.stdout is not None:  # None when fd 1 is closed; print() is a no-op then
            sys.stdout.flush()
    except OSError as e:
        _discard_stdout()
        print("failed:", type(e).__name__, str(e).strip(), file=sys.stderr)
        status = 1
    sys.exit(status)


if __name__ == "__main__":
    main()
