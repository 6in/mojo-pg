#!/usr/bin/env bash
# Run every tests/test_*.mojo with the Mojo TestSuite runner (there is no
# `mojo test` subcommand in Mojo 1.x; each test file has its own main()).
#
# Conninfo selection:
#   - If PQ_TEST_CONNINFO is set and non-empty, that single value is used.
#   - Otherwise the full test suite is run twice, once per local server
#     (ports 54317 and 54314 from tests/docker-compose.yml).
#
# NOTE: PQ_TEST_CONNINFO only supports the `key=value ...` form (NOT a
# postgres:// URI). Tests append ` password=...` to the end of the conninfo to
# build a deliberately-wrong-password string; appending that to a URI would
# produce a malformed conninfo instead of a bad-password one.
#
# NOTE: DB-independent tests (pure FFI / error mapping) are re-run for both
# servers too. They are fast, so paying for the duplicate run is cheaper than
# maintaining a per-file "needs a server" classification.
#
# PQ_TEST_LEAK_SERVERS:
#   How many servers tests/test_leak.mojo is run against. Unset (the default)
#   means "no limit": leak runs on every server, as it always has.
#   tests/final_check.sh passes 1, so the leak test runs on the first server
#   only there -- it is the slowest file in the suite and a second run adds
#   coverage of the libpq client side only, which is identical per server.
#
# NOTE: tests/test_leak.mojo is run from a *built* binary (build/test_leak),
# not via `mojo run`. `mojo run` hosts the Mojo compiler inside the very
# process whose RSS the leak test measures: the ~100 MiB the compiler
# allocates and frees before main() stays in this process' heap, so the RSS
# growth thresholds get drowned in compiler noise and can report a leak that
# is not there (or hide a real one). `mojo build` moves that allocation into a
# separate process, leaving the measured RSS to the test itself. Every other
# test file is unaffected and keeps using `mojo run`.
set -u
cd "$(dirname "$0")/.."

if [ -n "${PQ_TEST_CONNINFO:-}" ]; then
    conninfos=("$PQ_TEST_CONNINFO")
else
    conninfos=(
        "host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test"
        "host=127.0.0.1 port=54314 user=pq password=pq dbname=pq_test"
    )
fi

status=0
shopt -s nullglob

# Build the leak test once, up front (see the NOTE above for why it must not
# run under `mojo run`). A build failure is a suite failure, but the remaining
# test files are still worth running, so leak is skipped instead of aborting.
leak_bin=build/test_leak
leak_built=1
mkdir -p build
echo "== mojo build tests/test_leak.mojo"
if ! mojo build -I src tests/test_leak.mojo -o "$leak_bin"; then
    leak_built=0
    status=1
    echo "-- mojo build tests/test_leak.mojo FAILED (leak test will be skipped)"
fi

server_index=0
for conninfo in "${conninfos[@]}"; do
    # Headings show only host/port: the conninfo carries a password.
    host=""
    port=""
    for kv in $conninfo; do
        case "$kv" in
            host=*) host="${kv#host=}" ;;
            port=*) port="${kv#port=}" ;;
        esac
    done
    label="${host:-?}:${port:-?}"

    export PQ_TEST_CONNINFO="$conninfo"
    for f in tests/test_*.mojo; do
        if [ "$f" = tests/test_leak.mojo ]; then
            if [ "$leak_built" -eq 0 ]; then
                echo "-- $label tests/test_leak.mojo skipped (build failed)"
                continue
            fi
            if [ -n "${PQ_TEST_LEAK_SERVERS:-}" ] \
                && [ "$server_index" -ge "$PQ_TEST_LEAK_SERVERS" ]; then
                echo "-- $label tests/test_leak.mojo skipped" \
                    "(PQ_TEST_LEAK_SERVERS=$PQ_TEST_LEAK_SERVERS)"
                continue
            fi
            echo "== $label $f"
            started=$SECONDS
            "$leak_bin" || status=1
            echo "-- $label $f took $((SECONDS - started))s"
            continue
        fi
        echo "== $label $f"
        # Per-file wall clock: tests/test_leak.mojo alone runs for ~57 s, so
        # the timings are what tells a slow suite apart from a hung one.
        started=$SECONDS
        mojo run -I src "$f" || status=1
        echo "-- $label $f took $((SECONDS - started))s"
    done
    server_index=$((server_index + 1))
done
exit $status
