"""Private libpq FFI binding layer: thin function pointers and C types.

`types` holds the Int-backed opaque handles, pointer aliases and the
`libpq-fe.h` / `postgres_ext.h` enum constants. `functions` holds `LibpqFFI`,
a `Movable`-only table of 50 libpq entry points resolved from one dlopen'd
handle. Nothing here depends on `pq.errors`: a missing symbol raises a plain
`Error("missing symbol <name>")`, and translation to `PgError` belongs to the
layers above.
"""
