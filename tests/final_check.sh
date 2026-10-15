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
# Formats a throwaway *copy* and diffs it against the real tree, so the verdict
# depends only on the files themselves -- not on what git has staged. (The old
# `mojo format` + `git diff` form reformatted the working tree in place and
# flagged every unrelated uncommitted edit, which forced `check` to be run on a
# clean tree only.) `mojo format` has no --check flag in Mojo 1.1.0.
#
# The formatter is handed an explicit list of *files*, never the copied
# directories: `mojo format` skips anything .gitignore excludes when it walks a
# directory, and the copy lives under the ignored `build/`. Passing the
# directories made the stage a silent no-op -- the formatter reported "No Mojo
# files are present", so the diff always matched and the stage could never fail
# (measured on Mojo 1.1.0; explicitly named files are formatted regardless).
stage "1/6 fmt (no diff)"
rm -rf build/fmtcheck
mkdir -p build/fmtcheck
run_logged cp -r src tests examples hello.mojo build/fmtcheck/ \
    || fail "1/6 fmt (copy error)"
fmt_files=()
while IFS= read -r -d '' f; do
    fmt_files+=("$f")
done < <(find build/fmtcheck -name '*.mojo' -type f -print0)
if [ "${#fmt_files[@]}" -eq 0 ]; then
    fail "1/6 fmt (no .mojo files found in the copy)"
else
    run_logged mojo format --quiet "${fmt_files[@]}" \
        || fail "1/6 fmt (formatter error)"
fi
fmt_diff=0
for t in src tests examples hello.mojo; do
    run_logged diff -r -q "$t" "build/fmtcheck/$t" || fmt_diff=1
done
if [ "$fmt_diff" -ne 0 ]; then
    say "formatter would change the files listed above"
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
# Both examples run; either one failing fails the stage. They are judged
# together because the stage name is what the summary reports, and the two are
# the same promise: the package's re-exported surface is enough on its own.
stage "4/6 examples"
examples_failed=0
run_logged mojo run -I src examples/basic.mojo || examples_failed=1
run_logged mojo run -I src examples/params.mojo || examples_failed=1
if [ "$examples_failed" -ne 0 ]; then
    fail "4/6 examples"
fi

# -------------------------------------------------------------- 5. tests
stage "5/6 tests (both servers, test_leak on the first server only)"
run_logged env PQ_TEST_LEAK_SERVERS=1 bash tests/run_tests.sh || fail "5/6 tests"

# ------------------------------------------------------ 6. zero warnings
# Must be last: it measures everything the stages above appended to $LOG.
# (the heading must not itself contain the literal pattern being counted)
#
# Both the lower-case compiler form and the upper-case server form are counted:
# libpq's default notice processor prints server-side WARNING: / NOTICE: lines
# to stderr, and run_logged folds stderr into $LOG. Requiring zero of those is
# the mechanical proof that the transaction code never sends a redundant BEGIN
# or COMMIT (the server answers those with "there is already a transaction in
# progress" / "there is no transaction in progress").
#
# Nothing below may emit the counted literals through say(); they would land in
# $LOG and count themselves. printf without tee stays out of $LOG, so the
# report lines are safe -- they are worded without the literals anyway.
stage "6/6 zero compiler and server warnings in log"
warnings=$(grep -cE 'warning:|WARNING:' "$LOG" || true)
printf 'matched lines in %s: %s\n' "$LOG" "$warnings"
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
