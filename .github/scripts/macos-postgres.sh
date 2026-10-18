#!/usr/bin/env bash
# macos-postgres.sh — macOS ランナー（arm64 / Homebrew）に PostgreSQL 17 を
# 用意し、ロール pq / DB pq_test / schema を作ってから scram-sha-256 に切り替える。
#
#   bash .github/scripts/macos-postgres.sh
#
# 順序が重要: ロール・DB・schema は **まだ trust のまま TCP 経由で** 作る。
# （ソケットパスに依存せず、かつパスワード設定前でも接続できる）
# その後で pg_hba.conf の host 行を scram-sha-256 に書き換えて reload する。
#
# bash 3.2 互換（配列・mapfile・declare -A・${x,,} は使わない）。
# BSD sed なので in-place は `sed -i '' -E`（GNU 形の `sed -i -E` は失敗する）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

TMPDIR_OUT="${RUNNER_TEMP:-/tmp}"

echo "== install postgresql@17 (retry 3 x 30s; 数分かかる)"
bash "$SCRIPT_DIR/retry.sh" 3 30 brew install postgresql@17

echo "== resolve paths"
PGBIN="$(brew --prefix postgresql@17)/bin"
PGDATA="$(brew --prefix)/var/postgresql@17"
echo "PGBIN=$PGBIN"
echo "PGDATA=$PGDATA"

echo "== initdb (formula の post_install が済んでいればスキップ)"
if [ -f "$PGDATA/PG_VERSION" ]; then
  echo "already initialized: $PGDATA/PG_VERSION"
else
  "$PGBIN/initdb" -D "$PGDATA"
fi

echo "== start server on port 5432"
"$PGBIN/pg_ctl" -D "$PGDATA" -l "$TMPDIR_OUT/pg.log" -o "-p 5432" -w -t 60 start

echo "== create role pq / database pq_test (auth はまだ trust / TCP 経由)"
"$PGBIN/psql" -h 127.0.0.1 -p 5432 -d postgres \
  -c "CREATE ROLE pq SUPERUSER LOGIN PASSWORD 'pq'" \
  -c "CREATE DATABASE pq_test OWNER pq"

echo "== apply tests/fixtures/schema.sql"
"$PGBIN/psql" "host=127.0.0.1 port=5432 user=pq password=pq dbname=pq_test" \
  -f tests/fixtures/schema.sql

echo "== switch host auth trust -> scram-sha-256 (local 行は触らない)"
sed -i '' -E 's/^(host.*[[:space:]])trust[[:space:]]*$/\1scram-sha-256/' "$PGDATA/pg_hba.conf"
grep -E '^(host|local)' "$PGDATA/pg_hba.conf"

echo "== reload"
"$PGBIN/pg_ctl" -D "$PGDATA" reload

echo "== positive control 1: 正しいパスワードで接続できること"
if "$PGBIN/psql" "host=127.0.0.1 port=5432 user=pq password=pq dbname=pq_test" -c 'select 1'; then
  echo "ok: correct password accepted"
else
  echo "FAIL: correct password was rejected" >&2
  exit 1
fi

echo "== positive control 2: 間違ったパスワードが拒否されること"
WRONG_ERR="$TMPDIR_OUT/pg-wrong-password.err"
set +e
"$PGBIN/psql" "host=127.0.0.1 port=5432 user=pq password=WRONG dbname=pq_test" \
  -c 'select 1' >/dev/null 2>"$WRONG_ERR"
wrong_rc=$?
set -e
if [ "$wrong_rc" -eq 0 ]; then
  echo "FAIL: wrong password was accepted — auth is still trust" >&2
  cat "$PGDATA/pg_hba.conf" >&2
  exit 1
fi
if grep -q 'password authentication failed' "$WRONG_ERR"; then
  echo "ok: wrong password rejected with rc=$wrong_rc and 'password authentication failed'"
else
  echo "FAIL: wrong password failed with rc=$wrong_rc but stderr lacks 'password authentication failed'" >&2
  cat "$WRONG_ERR" >&2
  exit 1
fi

echo "== done: PGBIN=$PGBIN PGDATA=$PGDATA"
