"""Private libpq FFI binding layer: thin function pointers and C types.

`types` holds the Int-backed opaque handles, pointer aliases and the
`libpq-fe.h` / `postgres_ext.h` enum constants. `functions` holds `LibpqFFI`,
a `Movable`-only table of 55 libpq entry points resolved from one dlopen'd
handle. `loader` owns the process-wide handle: it searches the candidate paths,
enforces the libpq >= 14 floor and exposes `libpq()` / `libpq_ptr()`.

`types` and `functions` do not depend on `pq.errors`: a missing symbol raises a
plain `Error("missing symbol <name>")`. `loader` is the one module here that
translates load failures into `PgError(PgErrorKind.LIBPQ_LOAD, ...)`.
"""
