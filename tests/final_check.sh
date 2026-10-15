#!/usr/bin/env bash
# Final acceptance gate for phase1 (`pixi run check`).
#
# POLICY: every stage runs even if an earlier one fails (no early exit). The
# aggregated exit code is returned at the end. Rationale: the stage-6
# "zero warning:" check counts over the whole build/final_check.log, so the log
# must always contain every stage's output; bailing out early would silently
# shrink the thing we are measuring.
#
# `set -u` is on; `set -e` is deliberately NOT used because each stage is
# judged individually.
set -u
cd "$(dirname "$0")/.."

LOG=build/final_check.log
DOCLOG=build/docstrings.log
mkdir -p build
: >"$LOG"          # truncate: never count leftovers from a previous run
: >"$DOCLOG"

status=0
failed_stages=()

say() { printf '%s\n' "$*" | tee -a "$LOG"; }

stage() {
    say ""
    say "=== [$1] $(date '+%Y-%m-%dT%H:%M:%S%z')"
}

fail() {
    failed_stages+=("$1")
    status=1
    say "--- FAIL: $1"
}

# Run a command, mirroring stdout+stderr to the terminal and to $LOG.
# Returns the command's own exit code (not tee's).
run_logged() {
    "$@" 2>&1 | tee -a "$LOG"
    return "${PIPESTATUS[0]}"
}

# ---------------------------------------------------------------- 1. fmt
stage "1/6 fmt (no diff)"
run_logged mojo format src/ tests/ examples/ hello.mojo || fail "1/6 fmt (formatter error)"
if ! git diff --quiet -- src tests examples hello.mojo; then
    say "formatter changed these files:"
    run_logged git diff --stat -- src tests examples hello.mojo
    fail "1/6 fmt (diff not empty)"
fi

# ---------------------------------------------------------- 2. precompile
stage "2/6 precompile src/pq"
# NOTE: output is .mojoc, not .mojopkg -- Mojo 1.1.0 rejects .mojopkg here.
run_logged mojo precompile src/pq -o build/pq.mojoc || fail "2/6 precompile"

# ------------------------------------------------- 3. docstring diagnostics
stage "3/6 docstring diagnostics"
# Raw diagnostics go to $DOCLOG, NOT $LOG: the `_ffi` modules only need a
# module-level docstring, so their diagnostics are expected and must not be
# counted by the stage-6 `warning:` sweep over $LOG.
#
# Compiler-synthesized lifecycle methods (__init__ / __deinit__ / __copyinit__ /
# __moveinit__) are also excluded. They are reported against the *struct
# declaration* line, not any line we wrote, and there is nowhere to attach a doc
# string: `PgError` has an explicit documented `__init__` and is still reported
# twice for the synthesized copy/move overloads. Measured on Mojo 1.1.0.
# Known blind spot: a hand-written but undocumented `__init__` is reported at its
# own line and would be filtered out here too; the struct docstring covers it by
# convention.
mojo precompile --diagnose-missing-doc-strings src/pq -o build/pq.mojoc \
    >"$DOCLOG" 2>&1
doc_missing=$(grep -v '/_ffi/' "$DOCLOG" \
    | grep -vE "'(__init__|__deinit__|__copyinit__|__moveinit__)'" \
    | grep -c 'doc string' || true)
say "missing doc strings outside _ffi: $doc_missing (raw: $DOCLOG)"
if [ "$doc_missing" -ne 0 ]; then
    grep -v '/_ffi/' "$DOCLOG" \
        | grep -vE "'(__init__|__deinit__|__copyinit__|__moveinit__)'" \
        | grep 'doc string' | tee -a "$LOG"
    fail "3/6 docstring diagnostics"
fi

# ------------------------------------------------------- 4. examples run
stage "4/6 examples/basic.mojo"
# INTENTIONAL: if examples/basic.mojo does not exist yet this stage FAILS
# rather than skipping. It is delivered by task T6; until then `check` is
# supposed to be red.
if [ ! -f examples/basic.mojo ]; then
    say "examples/basic.mojo is missing (delivered by T6) -- failing on purpose"
    fail "4/6 examples (missing examples/basic.mojo)"
else
    run_logged mojo run -I src examples/basic.mojo || fail "4/6 examples"
fi

# -------------------------------------------------------------- 5. tests
stage "5/6 tests (both servers)"
run_logged bash tests/run_tests.sh || fail "5/6 tests"

# ------------------------------------------------------ 6. zero warnings
# Must be last: it measures everything the stages above appended to $LOG.
# (the heading must not itself contain the literal pattern being counted)
stage "6/6 zero compiler warnings in log"
warnings=$(grep -c 'warning:' "$LOG" || true)
printf 'warning: lines in %s: %s\n' "$LOG" "$warnings"
if [ "$warnings" -ne 0 ]; then
    failed_stages+=("6/6 warnings ($warnings)")
    status=1
    printf -- '--- FAIL: 6/6 warnings (%s)\n' "$warnings"
fi

printf '\n=== summary %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
if [ "$status" -eq 0 ]; then
    printf 'final_check: PASS\n'
else
    printf 'final_check: FAIL\n'
    for s in "${failed_stages[@]}"; do
        printf '  - %s\n' "$s"
    done
fi
exit $status
