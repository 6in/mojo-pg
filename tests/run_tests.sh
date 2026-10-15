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
        echo "== $label $f"
        mojo run -I src "$f" || status=1
    done
done
exit $status
