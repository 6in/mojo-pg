#!/usr/bin/env bash
# Run every tests/test_*.mojo with the Mojo TestSuite runner (there is no
# `mojo test` subcommand in Mojo 1.x; each test file has its own main()).
set -u
cd "$(dirname "$0")/.."
status=0
shopt -s nullglob
for f in tests/test_*.mojo; do
    echo "== $f"
    mojo run -I src "$f" || status=1
done
exit $status
