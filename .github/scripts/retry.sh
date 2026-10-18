#!/usr/bin/env bash
# retry.sh — コマンドを最大 <tries> 回まで再試行する。
#
#   bash .github/scripts/retry.sh <tries> <sleep_sec> <cmd...>
#
# 成功したら即 rc 0 で戻る。全回失敗したら最後のコマンドの rc をそのまま返し、
# stderr に "retry: giving up after N tries" を出す。
#
# bash 3.2 互換（macOS ランナーの bash は 3.2.57）。配列・mapfile・declare -A・
# ${x,,} は使わない。再試行を壊すので set -e は使わない。
set -u

if [ "$#" -lt 3 ]; then
  echo "usage: retry.sh <tries> <sleep_sec> <cmd...>" >&2
  exit 2
fi

tries="$1"
sleep_sec="$2"
shift 2

i=1
rc=0
while [ "$i" -le "$tries" ]; do
  echo "retry: attempt $i/$tries: $*" >&2
  "$@"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    exit 0
  fi
  echo "retry: attempt $i/$tries failed (rc=$rc)" >&2
  if [ "$i" -lt "$tries" ]; then
    sleep "$sleep_sec"
  fi
  i=$((i + 1))
done

echo "retry: giving up after $tries tries" >&2
exit "$rc"
