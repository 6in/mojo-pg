"""Hello: load libpq through the shared loader and print `PQlibVersion()`.

The candidate search (env `PQ_MOJO_LIBPQ` first, otherwise the OS default
sonames) and the libpq >= 14 floor both live in `pq._ffi.loader`.

Run it with `pixi run hello-libpq`. No database is needed -- only a libpq the
loader can find. Any `PgError` is printed and turned into a non-zero exit
status.
"""

from std.sys import exit

from pq._ffi.loader import libpq


def main():
    try:
        ref pq = libpq()
        var v = Int(pq.PQlibVersion())
        print(t"PQlibVersion = {v} (PostgreSQL {v // 10000}.{v % 10000})")
    except e:
        print("failed:", e)
        exit(1)
