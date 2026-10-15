"""Hello: load libpq through the shared loader and print `PQlibVersion()`.

The candidate search (env `PQ_MOJO_LIBPQ` first, otherwise the OS default
sonames) and the libpq >= 14 floor both live in `pq._ffi.loader`.
"""

from pq._ffi.loader import libpq


def main() raises:
    try:
        ref pq = libpq()
        var v = Int(pq.PQlibVersion())
        print(t"PQlibVersion = {v} (PostgreSQL {v // 10000}.{v % 10000})")
    except e:
        raise Error(String(e))
