# PLAN — phase5-polish-bench-readme

- 作成: 2026-10-17 / gsd-lite-plan（turn 2）
- 入力: REQUIREMENTS.md / DECISIONS.md / RESEARCH.md / `.gsd-lite/reflect/20261017-1925-phase4-async-cancel-notify.md`（直近）/
  `.gsd-lite/reflect/20261017-0254-phase3-binary-all-types.md` / `archive/phase4-async-cancel-notify/PLAN.md`（書式の手本）/
  `src/pq/*.mojo` / `tests/*` / `examples/*` / `pixi.toml` / `HANDOFF.md` §5.1・§8・§10
- 対象リポジトリ: `.`（in-repo 形）。`CLAUDE.md` / `AGENTS.md` は無い（`git ls-files` で確認。Phase 4 PLAN と同じ）
- 無人シェルの注意（RESEARCH 冒頭と同じ）: `mojo` / `pixi` は PATH に無い → **`/home/parallels/.pixi/bin/pixi run ...`**。`rg` は無い（`grep`）。`curl` / `md5sum` は allowlist に無い
  （`.claude/settings.json`。`WebFetch` と `pixi run python` は可）。docker は `tests-pg17-1` / `tests-pg14-1`（healthy）/ `tests-blackhole-1` が起動中（plan 時点 `docker ps`）。
  lean-ctx MCP は未接続（素の Read / Bash で可）
- research のプローブ（`.gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-001-*`、gitignore 対象）は impl が**雛形として開いてよい**:
  `probe-closefd.mojo`（`close(PQsocket)` → `fetch_all` の形。T1 のテストの原型）、`probe-notify-bad.mojo` + `.log`（BAD 後の `notifications()` の文言が伸びる陽性対照。T2）、
  `probe-lang.mojo`（`comptime if` 連鎖で `StaticString` を返す関数。T4 の `_default_candidates` の原型）、`turn-001-pixi/`（`pixi.toml` の feature 形 + `examples/bench_psycopg.py` そのもの。T5）、
  `examples-robust.sh` + `.log`（examples 堅牢性の格子 15 本。T1 / T7）、`zerocopy-time.log`（T1 の TRACE 転記元）、`bench.log`（README 表の形の手本。数値は T5 で取り直す）
- **追従先チェックリストは実行可能スクリプト** `.gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-002-checklist.sh`（REQ §9 plan 項目）。plan ターンで 1 回実行し、
  現在値は `scratch/turn-002-checklist.log`（コミット `34c2e35` の木）にある。下表は key / 直す場所 / 期待値の 3 列だけ。impl は各タスクの完了基準の最後で実行し、
  自タスクの行が期待値に到達していることを PROGRESS に 1 行で書く（生の値は `.gsd-lite/TRACE.md` へ）。**PLAN の訂正は表のセルに書かず `TRACE.md` の「PLAN 訂正（turn N）」節に 1 件 1 行**

## 検証コマンド

impl の各ターンがテストに使うコマンド（リポジトリルートで実行。`cd` 不要）:

```bash
/home/parallels/.pixi/bin/pixi run db-up          # 環境の初期化（--wait 付き。pg17 / pg14 / blackhole。起動済みなら即終了）
/home/parallels/.pixi/bin/pixi run db-reset       # T1 以降: db-down（-v）→ db-up。フィクスチャ再適用。pq_test_ascii も消える
/home/parallels/.pixi/bin/pixi run test           # tests/run_tests.sh: 54317 → 54314 の順に tests/test_*.mojo を 1 ファイル 1 プロセス
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_async.mojo          # 単一ファイル（PQ_TEST_CONNINFO 未設定なら 54317）
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_notify.mojo         # 同上
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_decode_binary.mojo  # サーバー不要
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_errors.mojo         # サーバー不要
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_poll.mojo           # サーバー不要
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_loader_fail.mojo    # サーバー不要（T4 の loader 回帰）
/home/parallels/.pixi/bin/pixi run hello-libpq                                     # T1 / T4
/home/parallels/.pixi/bin/pixi run bench                                           # Mojo text vs binary（check 外。T5 / T7）
/home/parallels/.pixi/bin/pixi run bench-psycopg                                   # T5 以降（初回は bench 環境の作成で 1 分前後）
/home/parallels/.pixi/bin/pixi run package        # mojo precompile src/pq -o build/pq.mojoc（警告ゼロ確認）
/home/parallels/.pixi/bin/pixi run check          # 最終判定: bash tests/final_check.sh（6 段、exit 0 が合格）
bash .gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-002-checklist.sh   # 追従先チェックリスト（現在値を出す）
docker exec tests-pg17-1 psql -U pq -d pq_test -tAc "SELECT datname FROM pg_database WHERE datname LIKE 'pq_test_%'"   # 後始末の確認（pg14 は tests-pg14-1）
```

- 環境の初期化（テストの前に毎回）: `/home/parallels/.pixi/bin/pixi run db-up`（起動済みなら即終了）
- 最終判定（クリーンな状態から全検査。verify と T7 が使う）: **`/home/parallels/.pixi/bin/pixi run check`**
  - 1/6 段はコピーに `mojo format` → `diff -r`（`tests/final_check.sh:57-79`）。`examples/bench_psycopg.py` もコピーされるが `.mojo` でないので整形対象外
  - 4/6 段（`final_check.sh:120-129`）は 5 本の examples。**Phase 5 で増減なし**（`hello_libpq` は `pixi run hello-libpq` で別途、bench 2 本は `check` 外のまま）
  - 6/6 段は `grep -cE 'warning:|WARNING:|implicit ROLLBACK failed'`（`final_check.sh:155`）。`DROP DATABASE IF EXISTS` の NOTICE（`NOTICE:` 行）はこのパターンに当たらない（RESEARCH P7）。
    **見出し行・`print` にこれらの文字列を含めない**
- 所要見積もり（REQ §9 の式）: `check` = Phase 4 末実測 **167〜187 s** + 新テストファイル 0 本 × 5 s + 新テストの明示的な待ち（T1 `pg_sleep(0.3)` + `fetch_all` 上限 0.5 s、
  T3 の予算切れ 300 ms × 3 + 200 ms × 1 + UNLISTEN / 未 LISTEN の 300 ms × 2、DROP + CREATE 2 回 ≈ 0.3 s × 2、接続 1 本 0.3 s × 約 15 本）≈ **+ 10 s / サーバー** →
  **`check` 180〜210 s** と見込む。閾値は 187 + 60 = **247 s**（超えたら PROGRESS に理由）。`pixi run test` は両サーバーで + 74 s（leak PG14 分）。
  bench は `check` 外（Mojo 2 本 ≈ 10 s、psycopg ≈ 10 s + 初回の環境作成 ≈ 60 s）。examples 堅牢性の格子（T7）≈ 17 本 × 4 s ≈ 70 s
- **時間は単位を明記する**（TestSuite の `PASS [ n ]` / `Summary [ n ]` はミリ秒。RESEARCH §0.5 ◇、P20）
- PG14 / PG17 の差: **Phase 5 の新テストはすべて両サーバー同一期待値**（`DROP DATABASE ... WITH (FORCE)` は PG13+。RESEARCH §2.6）

## 追従先チェックリスト

スクリプト `turn-002-checklist.sh` の key で書く（左列）。現在値は `scratch/turn-002-checklist.log`（2026-10-17、コミット `34c2e35` の木）。`absent(...)` はファイル未作成。
期待値の「≥」「≤」は下限 / 上限。

| key | 変更の種類 / 直す場所 | 期待値（到達タスク） |
|---|---|---|
| `async_fetch_all_kind_connection` | §4.5: `src/pq/async_conn.mojo:1518-1526` の `except e:` に `e.kind == PgErrorKind.CONNECTION` で break | **≥ 1**（T1） |
| `async_after_send_left_at_idle` / `async_after_send_PGASYNC_BUSY` | §4.5: `async_conn.mojo:914-917` の `else`（-1）で `BUSY` に置き、コメント「left at IDLE」を消し libpq の `PGASYNC_BUSY` を根拠に書く | **0 / ≥ 1**（T1） |
| `test_async_tests` / `test_async_close_call` | §4.5 のテスト 1 件（`close(PQsocket)` 方式） | **31 / 1**（T1） |
| `notify_drop_ascii_calls` / `notify_with_force` / `notify_42P04` | §4.7: `tests/test_notify.mojo:378-410` `_ascii_conninfo` の先頭 DROP + 2 テストの末尾 DROP（ヘルパ `_drop_ascii_database`）。`42P04` 容認は消す | **≥ 4 / ≥ 1 / 0**（T1） |
| `pixi_db_reset` | §4.7: `pixi.toml` の `db-reset` | **1**（T1） |
| `hello_raise_error` / `examples_raise_error` / `hello_def_main_plain` / `hello_pixi_run` | §4.3 / RESEARCH §2.9 P17: `examples/hello_libpq.mojo:10-16` を他 6 本と同じ `def main():` + `try / except / exit(1)` に。docstring に `pixi run hello-libpq` | **0 / 0 / 1 / 1**（T1） |
| `trace_exists` / `trace_zero_copy` | §4.5: `.gsd-lite/TRACE.md` 新設 + `test_zero_copy` の所要表 | **exists / ≥ 1**（T1） |
| `errors_ENCODING` / `errors_seven` / `errors_eight` / `errors_write_Encoding` | §4.6.2: `src/pq/errors.mojo:3,13-14,46-52,94-95` | **≥ 2 / 0 / ≥ 1 / 1**（T2） |
| `init_exactly_seven` / `init_ENCODING` | `src/pq/__init__.mojo:296`「exactly seven」、`## PgErrorKind` 節の箇条書き、`:35,122,254,285,286` の UTF-8 文 | **0 / ≥ 5**（T2） |
| `src_TYPE_MISMATCH` / `tests_TYPE_MISMATCH` / `src_ENCODING` / `tests_ENCODING` | P8 の陽性対照: raise 4 箇所 + docstring 16 行（決めた事項 3）/ テスト期待値 7 行 + `test_errors` の `!= TYPE_MISMATCH` 1 行 | **≤ 106 / 91 / ≥ 15 / ≥ 8**（T2。`src` は 125 − 4 − 16 = 105 が目安） |
| `src_utf8_and_type_mismatch_same_line` | P8: `__init__.mojo:35,122,285`、`async_conn.mojo:281,1373`（同一行に両方）。複数行 docstring は impl が `grep -n -B2 -A2 'UTF-8' src/pq/*.mojo` で目視 | **0**（T2） |
| `src_invalid_utf8_raise_sites` | 文言は変えない（D9） | **4**（T2。不変） |
| `test_errors_tests` | `tests/test_errors.mojo` に `ENCODING` の 1 件 | **9**（T2） |
| `async_reject_lost_def` / `async_reject_lost_calls` / `async_lost_connection_text` | §4.6: `_reject_lost(method)` ヘルパ（決めた事項 4）。def 1 + `notifications` 直接 1 + `_collect_notifications`（両公開待ちの共通入口。T3 (a)）1 | **1 / ≥ 3（T2）→ 3（T3。不変。TRACE の PLAN 訂正 turn 5）/ ≥ 1** |
| `test_decode_binary_f4908080` / `_f5808080` / `_f48fbfbf` / `test_decode_binary_tests` | §4.6 テスト: `tests/test_decode_binary.mojo:510-523` の格子に 3 行（def は増やさない） | **1 / 1 / 1 / 88**（T2） |
| `test_notify_tests` / `test_notify_lost_message_fixed` | §4.6: BAD 後の文言固定テスト 1 件（T2）、`wait_notifications` 8 件 + 契約外 3 件（T3） | **≥ 12（T2）→ ≥ 21（T3）/ ≥ 1（T2）** |
| `async_wait_notifications_def` / `async_n_must_be` / `init_wait_notifications` | §4.6.1: `async_conn.mojo` の新 API + `__init__.mojo` の API 表 + `## Asynchronous use` | **1 / 1 / ≥ 2**（T3） |
| `test_notify_wait_notifications_calls` / `test_async_wait_notifications` / `test_notify_mixed_case` / `test_notify_unlisten` / `test_notify_n_must_be` | §4.6.1 テスト（決めた事項 6 の格子）+ `test_async.mojo:1373-1380` の Connecting 格子と `:1403-1417` の予算格子に各 1 行 | **≥ 8 / ≥ 3 / ≥ 2 / ≥ 1 / ≥ 1**（T3） |
| `loader_libpq_dll` / `loader_platform_map` / `loader_homebrew` / `loader_default_candidates_def` / `loader_CompilationTarget` | §4.4 / RESEARCH §2.4: `src/pq/_ffi/loader.mojo:16,24-28` | **≥ 2 / 0 / 1 / 1 / ≥ 3**（T4。`loader_libpq_dll` は turn 6 訂正） |
| `poll_WSAGetLastError` / `poll_external_call_symbols` / `poll_get_errno` / `poll_10022` / `poll_only_two_symbols` / `poll_win10_2004` / `poll_WSAStartup` | §4.4 / RESEARCH §2.3 #6・#8・#11: `src/pq/_platform/poll.mojo:24-27,183-232,271-285` | **≥ 2 / 3 / ≥ 1 / ≥ 1 / 0 / ≥ 1 / ≥ 1**（T4） |
| `trace_wsapoll_table` / `test_poll_tests` | 照合表 12 行を TRACE に / `tests/test_poll.mojo` は不変 | **≥ 1 / 11**（T4） |
| `pixi_feature_bench` / `pixi_bench_psycopg` / `pixi_environments` / `lock_psycopg_c` | §4.1 / RESEARCH §2.1: `pixi.toml` + `pixi.lock`（3 プラットフォーム） | **2 / 1 / 1 / ≥ 3**（T5） |
| `bench_py` / `bench_py_binary` / `bench_py_psycopg_error` | §4.1: `examples/bench_psycopg.py` | **exists / ≥ 1 / ≥ 1**（T5） |
| `readme` / `readme_h2` / `readme_copyright` / `readme_unverified_windows` / `readme_ENCODING` / `readme_wait_notifications` / `readme_db_reset` / `readme_bench_psycopg` / `readme_PQ_MOJO_LIBPQ` / `readme_type_oids` / `readme_examples_links` | §4.2: `README.md`（決めた事項 11 の節立て） | **exists / ≥ 10 / 1 / ≥ 1 / ≥ 1 / ≥ 1 / ≥ 1 / ≥ 1 / ≥ 1 / ≥ 17 / ≥ 7**（T6） |
| `license` / `license_apache` / `license_appendix` / `license_lines` | §4.2: `LICENSE`（Apache-2.0 全文、APPENDIX 含む） | **exists / ≥ 1 / 1 / 200〜205**（T6。公式は 202 行） |
| `examples_pixi_run` | §4.3: 7 本の docstring に `pixi run <task>`（現状 bench の 1 本だけ） | **2（T1）→ 7（T6）** |
| `src_def_ref_return` / `tests_files_count` / `test_file_count` | `ref` を返す公開 API を作らない（Phase 3 P19 の継続）/ テストファイル数（Phase 5 は新ファイル無し） | **0 / 24 / 24**（T7 で確認） |

## Tasks

- [x] T1: 持ち越し整理（§4.5 / §4.7）+ `hello_libpq` の堅牢性（§4.3）+ `TRACE.md` 新設（1 コミット。REQ §9）
  - 完了基準:
    - (a) §4.5 / RESEARCH §2.7 P1: `src/pq/async_conn.mojo:1518-1526` の `except e:` を「`first_error` に保存 → **`e.kind == PgErrorKind.CONNECTION` または `PQstatus == CONNECTION_BAD` なら break**、
      それ以外は continue」に。docstring `:1465-1466`「draining stops as soon as libpq reports the connection lost」→「draining stops at the first `CONNECTION` error, whether or not `PQstatus`
      has turned `CONNECTION_BAD` (a `close(2)`d socket is reported by libpq as a read failure with the status still `OK`)」の趣旨に。raise される値は変わらない（`first_error` 経由）
    - (b) (a) のテスト（`tests/test_async.mojo`、T4 節の後に `# --- T5 (Phase 5) ---` 節）: `test_fetch_all_stops_draining_on_a_closed_socket` —
      `_connect_blocking(_conninfo(), 5000)` → `_send(conn, "SELECT pg_sleep(0.3), 1")` → `_ = external_call["close", c_int](c_int(conn.socket()))`（`tests/test_poll.mojo:55` と同じ 1 シグネチャ。
      `from std.ffi import c_int, external_call` を足す）→ `var t0 = monotonic()` → `_fetch_all_error(conn, 2000)` が `kind == PgErrorKind.CONNECTION` かつ `_elapsed_ms(t0) < 500`。
      **close から `__del__` までに fd を開かない**（P2: 接続・ファイル open・`_open` を挟まない。テスト末尾は `_ = conn^` だけ）。両サーバー同一。
      **陽性対照**: 修正前は 2000 ms 後に `TIMEOUT`（`scratch/turn-001-probe-closefd.log` A）。impl は (a) を入れる前にこのテストだけ 1 回走らせて `TIMEOUT` で落ちることを見て PROGRESS に 1 行
    - (c) §4.5 / RESEARCH §2.7 P3: `async_conn.mojo:914-917` の `else`（`flushed == -1`）で **`self._state = AsyncState.BUSY` を置いてから** `raise self._connection_error()`。
      コメント「left at IDLE because there are no results to drain」を消し、「libpq は `PQsendQuery` 成功時点で `PGASYNC_BUSY`。pq も `BUSY` に揃えておけば次の `send` は pq の `USAGE` が先に出る。
      PG18 の `PQflush` は `status == CONNECTION_BAD` のときだけ -1 を返し、送信失敗は `write_failed` + 成功扱いなので `PQsendQuery` 直後に -1 になる経路は同一スレッドに無い（到達不能。fe-exec.c / fe-secure.c）」を
      docstring に。**陽性対照はコードレビュー**（REQ §4.5）: `TRACE.md` に「`_after_send` -1 のコードレビュー」節を作り、RESEARCH §2.7 の libpq 根拠 3 行（`PQflush` 先頭 / `pqSendSome` の return 0 /
      `pqsecure_raw_write` の `n = len`）と `probe-closefd.log` B（`send` 成功・`PQflush` 0）を写す
    - (d) §4.7 / D10 / RESEARCH §2.6 P5・P6: `tests/test_notify.mojo` にヘルパ `_drop_ascii_database()`（`_open(_conninfo())`（= `pq_test` に接続。対象 DB からは発行しない）で
      `DROP DATABASE IF EXISTS pq_test_ascii WITH (FORCE)` を `execute`。**`conn.transaction()` の中では発行しない**。失敗は握って元の結果を隠さない: 戻り値 `Bool` で成否を返し raise しない）。
      `_ascii_conninfo()`（`:378-410`）の先頭で呼び、`42P04` の容認（`:406-408`）は消す（DROP 直後の CREATE は成功しなければならない）。
      `test_a_payload_that_is_not_utf8_is_rejected_and_dropped`（`:481-508`）と `test_a_channel_that_is_not_utf8_is_rejected_and_dropped`（`:511-540`）の末尾、`_ = sender^` の後に
      `_ = listener^` を置いてから `_drop_ascii_database()`（listener を閉じてから DROP。FORCE は保険）。docstring `:379-385`「left behind, so a second run reuses it」を「dropped at the end of
      each test and, in case an assertion skipped that, at the start of the next」に
    - (e) (d) の検証: `pixi run mojo run -I src tests/test_notify.mojo` を 54317 / 54314（`PQ_TEST_CONNINFO` を環境で渡す）で回した後、検証コマンドの `docker exec ... psql` が**両サーバーで 0 行**。
      **陽性対照**: 末尾の `_drop_ascii_database()` 呼び出しを 2 つともコメントアウトした scratch コピー（`.gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-NNN-notify-nodrop.mojo`）を
      54317 で 1 回走らせて `pq_test_ascii` が 1 行残ること → 本物の `test_notify` を走らせて 0 行に戻ることを見る（P6: 先頭の `IF EXISTS` が回収する）。結果を PROGRESS に 1 行
    - (f) §4.7: `pixi.toml` の `db-down` の次に `db-reset = { depends-on = ["db-down", "db-up"] }`（コメント「フィクスチャ再適用。`check` は呼ばない」）。`pixi run db-reset` が exit 0 で 3 コンテナが
      `Up`（`docker compose -f tests/docker-compose.yml ps`）、直後の `pixi run db-up` が即終了。**所要（秒）を PROGRESS に**（`check` の前に毎回走らせる必要は無い）
    - (g) §4.3 / RESEARCH §2.9 P17: `examples/hello_libpq.mojo:10-16` を `def main():` + `try: ... except e: print("failed:", e); exit(1)`（`from std.sys import exit`。`examples/basic.mojo:33-48` と同じ形）に。
      docstring に `Run it with \`pixi run hello-libpq\`. No database is needed.` の 1〜2 行。検証: `pixi run hello-libpq` が `PQlibVersion = 180006 ...` を出す（正常）、
      `PQ_MOJO_LIBPQ=/nonexistent/libpq.so` を環境で渡した `pixi run hello-libpq` が **`failed: PgError(kind=LibpqLoad, ...)` の 1 行 + 終了コード 1**、出力に `Unhandled` / `stack trace` が無い
    - (h) §4.5 / D12 / RESEARCH §2.5: `.gsd-lite/TRACE.md` を新設（決めた事項 13 の節立て）。「`test_zero_copy` の所要」節に `scratch/turn-001-zerocopy-time.log` の表 5 行（単位 **ms** を明記）と
      結論「TestSuite の `[ n ]` はミリ秒。1 テスト 3.4〜3.9 ms は接続 1 本の固定費で `test_result` と同じ。直すものは無い」を写す。「PLAN 訂正（turn N）」節は空の見出しで置く
    - (i) `pixi run test` 両サーバー PASS（既存テストの期待値変更**ゼロ**。変えてよいのは (d) の docstring と追加分）、`pixi run package` 警告ゼロ、`pixi run check` 6/6 PASS。
      チェックリストの T1 行（`async_fetch_all_kind_connection` / `async_after_send_*` / `test_async_*` / `notify_*` / `pixi_db_reset` / `hello_*` / `examples_raise_error` / `trace_*` / `examples_pixi_run` = 2）が期待値。
      所要（`check` と `test_notify` の `took Ns`）を PROGRESS に単位付きで
  - 対象: `src/pq/async_conn.mojo`, `tests/test_async.mojo`, `tests/test_notify.mojo`, `pixi.toml`, `examples/hello_libpq.mojo`, `.gsd-lite/TRACE.md`
  - 依存: なし
  - 並列サブ作業（サブエージェント **1 本**（親を除く）。(d)(e) は `test_notify.mojo` 1 ファイル完結で他と重ならない）:
    - A: (d) `tests/test_notify.mojo` の `_drop_ascii_database` + `_ascii_conninfo` の書き換え + 2 テスト末尾の DROP + docstring（対象: `tests/test_notify.mojo` のみ。(e) の陽性対照 scratch も A が作って 54317 で 1 回回す）
    - 親: (a)(b)(c)(f)(g)(h)(i)

- [x] T2: `PgErrorKind.ENCODING`（§4.6.2 / D9）+ `notifications()` の先行チェック（§4.6）+ UTF-8 スキャナの 4 バイト境界 2 件（§4.6）+ 既存テストの期待値変更
  - 完了基準:
    - (a) D9 / 決めた事項 2: `src/pq/errors.mojo:46-52` の後に `comptime ENCODING = Self(7)` + docstring（「Text that reached the client is not valid UTF-8: a column decoded as `String` /
      `StringSlice`, or a notification's channel / payload. The offending bytes are never quoted in the message. Distinct from `TYPE_MISMATCH`, which is about OIDs, widths and indices」）、
      `write_to`（`:94-95` の後）に `elif self == Self.ENCODING: writer.write("Encoding")`、`:3`「seven failure categories」/ `:13-14`「exactly seven constants: ... and `TIMEOUT`」→ eight + `ENCODING` を列挙。
      `tests/test_errors.mojo` に `test_encoding_kind_discriminant_and_name`（`PgErrorKind.ENCODING.value == 7`、`String(PgErrorKind.ENCODING) == "Encoding"`、`ENCODING != TYPE_MISMATCH`。`:62-65` の形）
    - (b) D9 / RESEARCH §2.10 / P8: raise 4 箇所を `ENCODING` に — `src/pq/decode_binary.mojo:343,347`（`_validated_utf8`）、`src/pq/async_conn.mojo:295,299`（`_reject_bad_notification_text`）。
      **メッセージ文言は一字も変えない**（`"invalid UTF-8 at byte N of column M"` / `"... of notification <what>"`）。docstring を全部直す（決めた事項 3 の 16 行: `decode_binary.mojo:41,46,329,859`、
      `async_conn.mojo:267,281,1362,1373,1562`、`result.mojo:543,848,854`、`__init__.mojo:35,122,254,285,286`）。`__init__.mojo:294-312` の `## PgErrorKind` 節: 「exactly seven」→ eight、
      `TIMEOUT` の次に `ENCODING` (`Encoding`) の 1 行（「text that reached the client is not UTF-8: a `String` cell or a notification's channel / payload. The connection and the result are untouched」）。
      impl は `grep -n -B2 -A2 'UTF-8' src/pq/*.mojo` で**複数行にまたがる docstring**も拾う（同一行 grep だけでは `decode_binary.mojo:41` のような行が漏れる）。
      `decode_binary.mojo:46`「Every failure raises `PgError(PgErrorKind.TYPE_MISMATCH, ...)`」は「... except the UTF-8 check, which raises `ENCODING`」に
    - (c) 既存テストの期待値: `tests/test_notify.mojo:492,534` と `tests/test_decode_binary.mojo:470,481,489,497,538` の `TYPE_MISMATCH` → `ENCODING`（**7 行**。OID 不一致・長さ不一致・jsonb 版数の
      `TYPE_MISMATCH` は残す。`tests/test_zero_copy.mojo:469,474,551,552` は OID 不一致なので残す）。**陽性対照（REQ §9）**: チェックリストの `tests_TYPE_MISMATCH` が 97 → **91**（−7 + `test_errors` の 1 行）、
      `src_TYPE_MISMATCH` が 125 → **≤ 106**、`src_utf8_and_type_mismatch_same_line` が 5 → **0**、`grep -rn 'invalid UTF-8' tests/` の全件が `ENCODING` を断定（REQ §5）
    - (d) §4.6 / RESEARCH §2.8 P4 / 決めた事項 4: `async_conn.mojo` に `_reject_lost(self, method: StaticString) raises PgError`（`_reject_connecting`（`:580-594`）の隣。`PQstatus == CONNECTION_BAD` なら
      `PgError(CONNECTION, String(method, "() called on a lost connection"))`）。`notifications()`（`:1378`）と `wait_notification`（`:1567`）で `_reject_connecting` の直後に呼ぶ（T3 の `wait_notifications` も）。
      docstring の `Raises:` に 1 行。`__init__.mojo` の API 表（`:285-286`）は `CONNECTION` が既にあるので文言のみ。
      テスト（`tests/test_notify.mojo`）`test_a_lost_connection_is_reported_with_a_fixed_message`: `test_notifications_reports_a_lost_connection`（`:676-702`）と同じ手順で最初の `CONNECTION` を得た後、
      `_notifications_error(listener)` を **3 回**呼び、3 回とも `kind == CONNECTION` かつ **message が `"notifications() called on a lost connection"` に等しい**（伸びない）。さらに
      `_wait_notification_error(listener, 100)` が `CONNECTION` で message `"wait_notification() called on a lost connection"`。**陽性対照**: 先行チェック無しだと 3 回目の message が 2 回目より長い
      （`scratch/turn-001-probe-notify-bad.log`）。既存 `test_notifications_reports_a_lost_connection` は不変で PASS（最初の検出は `PQconsumeInput` 経路のまま）
    - (e) §4.6 テスト / RESEARCH §2.10: `tests/test_decode_binary.mojo:510-523` の格子に 3 行 — `_first_invalid("f4908080") == 0`（U+110000、範囲外）、`_first_invalid("f5808080") == 0`（不正先頭バイト）、
      `_first_invalid("f48fbfbf") == -1`（U+10FFFF、正常側の対照）。**def は増やさない**（`test_decode_binary_tests` = 88 のまま）。impl は同期 `Connection` で `SELECT E'\\xf4\\x8f\\xbf\\xbf'::text` を
      UTF-8 DB に投げて受理されることを 1 回確かめ、期待値の根拠を PROGRESS に 1 行（`\\xf4\\x90\\x80\\x80` は UTF-8 DB が `22021` で拒否するので対照にならない。単体格子だけ）
    - (f) `pixi run test` 両サーバー PASS（期待値変更は (c) の 7 行だけ）、`pixi run package` 警告ゼロ、`pixi run check` 6/6。チェックリストの T2 行（`errors_*` / `init_exactly_seven` / `init_ENCODING` /
      `src_TYPE_MISMATCH` / `tests_TYPE_MISMATCH` / `src_ENCODING` / `tests_ENCODING` / `src_utf8_and_type_mismatch_same_line` / `src_invalid_utf8_raise_sites` / `test_errors_tests` / `async_reject_lost_*` /
      `async_lost_connection_text` / `test_decode_binary_*` / `test_notify_tests` ≥ 12 / `test_notify_lost_message_fixed`）が期待値
  - 対象: `src/pq/errors.mojo`, `src/pq/decode_binary.mojo`, `src/pq/async_conn.mojo`, `src/pq/result.mojo`（docstring のみ）, `src/pq/__init__.mojo`, `tests/test_errors.mojo`, `tests/test_decode_binary.mojo`, `tests/test_notify.mojo`
  - 依存: T1
  - 並列サブ作業（サブエージェント **1 本**（親を除く）。テスト側は契約（決めた事項 2・4）から並行して書ける）:
    - A: (c) の期待値変更 7 行 + (e) の格子 3 行 + (a) の `test_errors` 1 件 + (d) のテスト 1 件（対象: `tests/test_errors.mojo`, `tests/test_decode_binary.mojo`, `tests/test_notify.mojo`。**src は触らない**。
      親が src を入れるまでコンパイルは通らないので、A は書くだけで親が統合後に回す）
    - 親: (a)(b)(d) の src 側 + `__init__.mojo` + (f)

- [x] T3: `AsyncConnection.wait_notifications(n, timeout_ms)`（§4.6.1 / D8）+ 契約外テスト 3 件（UNLISTEN / 未 LISTEN / `"Mixed Case"`）+ 境界格子
  - 完了基準:
    - (a) 決めた事項 5: `async_conn.mojo` に private `_collect_notifications(mut self, method: StaticString, n: Int, timeout_ms: Int) raises PgError -> List[Notification]`
      （`wait_notification`（`:1537-1588`）の本体を「`n` 件集まるまで」に一般化。`notifications()` が返した `found` のうち `out` に入り切らない分を **`_pending` に先頭から append**（現状 `:1572-1573` と同じ順序。P10）。
      `len(out) >= n` で返す。予算切れ（`remaining <= 0` / `wait_readable` の `TIMEOUT`）は**集まった分（0〜n−1 件）を返す**（D8）。`notifications()` が raise したら **`out` を `_pending` の先頭に戻してから**
      `raise e^`（1 往復目で集めた良い通知を失わない。`self._pending = out + self._pending` の形: `out` の要素を順に `insert` するか、新しい `List` を作って `_pending` を付け足す）。
      入口検査の順: `_reject_bad_timeout(timeout_ms)` → `self._reject_connecting(method)` → `self._reject_lost(method)`）。
      公開 `wait_notifications(mut self, n: Int, timeout_ms: Int) raises PgError -> List[Notification]`: `n < 1` なら `USAGE` `String("wait_notifications: n must be at least 1 (got ", n, ")")`
      （**`_reject_bad_timeout` の後、`_reject_connecting` の前**）→ `_collect_notifications("wait_notifications", n, timeout_ms)`。
      `wait_notification(timeout_ms)` は `_collect_notifications("wait_notification", 1, timeout_ms)` の先頭要素を `Optional` で返す薄いラッパに（既存 11 件 + T2 の分が回帰。文言 `wait_notification() called while Connecting` は `method` 経由で不変）。
      `n` は C に渡さない（縮小変換なし。RESEARCH §0.5.1）。`n = Int.MAX` は「予算切れまで集める」として受け入れる。docstring（`Args` / `Returns` / `Raises`: `USAGE`（`n < 1`、Connecting、予算範囲外）/ `CONNECTION` / `ENCODING`）
    - (b) `src/pq/__init__.mojo`: API 表（`:270-287`）に `| \`wait_notifications(n, timeout_ms)\` | \`List[Notification]\`, 0 to n−1 of them on an expired budget | \`USAGE\`, \`CONNECTION\`, \`ENCODING\` |` の行を
      `wait_notification` の次に。`## Asynchronous use` の LISTEN / NOTIFY 箇条書き（`:246-255`）に「`wait_notifications(n, timeout_ms)` collects up to *n* with one budget and answers what it has when the budget ends」を 1 文。
      `:1-19` の冒頭説明は変えない（`AsyncConnection` の列挙で足りる）
    - (c) テスト（`tests/test_notify.mojo`。ヘルパ `_wait_notifications(mut conn, n, timeout_ms) raises -> List[Notification]` と `_wait_notifications_error(mut conn, n, timeout_ms) raises -> PgError`、
      `_assert_timeout_too_large` 相当（`tests/test_async.mojo:1005-1017` を写す））。決めた事項 6 の格子を 8 件以上:
      ① `test_wait_notifications_collects_exactly_n`: 1 トランザクションで 2 件 NOTIFY（`:656-659` の形）→ `wait_notifications(2, 5000)` が 2 件、payload 順に `first` / `second`；
      ② `test_wait_notifications_returns_what_it_has_on_an_expired_budget`: 1 件 NOTIFY → `wait_notifications(3, 300)` が **1 件**、経過 **≥ 290 ms かつ < 2000 ms**（`monotonic()`）、例外なし（D8）；
      ③ `test_wait_notifications_of_one_matches_wait_notification`: 1 件 NOTIFY → `wait_notifications(1, 2000)` が 1 件で `channel` / `payload` / `backend_pid` が送信側と一致；
      ④ `test_wait_notifications_rejects_n_below_one`: `n ∈ {0, -1}` → `USAGE` で message に `"n must be at least 1"` と `"got 0"` / `"got -1"`（`timeout_ms = 100`）；
      ⑤ `test_wait_notifications_budget_grid`: `timeout_ms ∈ {-2, TIMEOUT_MS_MAX + 1, 4294967296, Int.MAX}` → `USAGE` で `"timeout_ms must be"`（`n = 1`）、`timeout_ms = 0` で通知なし → 空リスト即時（経過 < 50 ms）、
      `timeout_ms = -1` で 1 件保留あり（直前の `wait_notifications(1, …)` が 2 件届いた往復の余り）→ 待たずに 1 件（経過 < 50 ms）；
      ⑥ `test_wait_notifications_with_int_max_n_stops_at_the_budget`: `wait_notifications(Int.MAX, 200)` が通知なしで空リスト、経過 ≥ 190 ms かつ < 1000 ms；
      ⑦ `test_wait_notifications_surplus_feeds_the_next_wait`（P10）: 1 トランザクションで 3 件 → `wait_notifications(2, 5000)` が 2 件 → `wait_notification(5000)` が 3 件目を **< 50 ms** で返す；
      ⑧ `test_wait_notifications_keeps_collected_ones_when_a_later_one_is_rejected`（`out` の保全）: `SQL_ASCII` DB（T1 の `_ascii_conninfo` + `_assert_sql_ascii`）で LISTEN → sender が `NOTIFY ch, 'ok'`
      （単独 tx）→ `_pause_until_readable(listener, 500)` で `ok` が socket に届くのを待つ → sender が `NOTIFY ch, E'ab\\xC3\\x28'`（別 tx）→ `_wait_notifications_error(listener, 2, 1500)` が `ENCODING`
      → 直後の `_notifications(listener)` が `ok` の 1 件を返す（失われていない）。末尾で `_drop_ascii_database()`。
      **注**: ⑧ は「1 往復目で `ok` が `out` に入り、2 往復目で raise」の形でないと `out` の保全を検証できない（同一 tx で 2 件送ると `notifications()` 1 回の中で処理され `out` は空のまま）。
      2 往復に分かれないマシンでは `ok` が `notifications()` 内の `found` → `_pending` 経由で保全されるので、どちらの経路でも断定は同じ「`ok` が残る」。
      **turn 5 の訂正（格子 8 件 → 9 件）**: 陽性対照で ⑧ は restore なしでも PASS（= `out` 保全を判別しない）と分かったため、
      ⑨ `test_wait_notifications_keeps_collected_ones_across_two_round_trips` を追加した（第 3 の接続から `pg_sleep` 付きで
      不正 UTF-8 を遅延 commit させ 1 往復目を `ok` だけにする。restore なしで FAIL）。詳細は `TRACE.md` の「PLAN 訂正（turn 5）」
    - (d) 契約外テスト 3 件（`tests/test_notify.mojo`）: `test_unlisten_stops_delivery`（LISTEN `pq_t5_un` → NOTIFY → `wait_notification(2000)` が届く → `_send(listener, "UNLISTEN pq_t5_un")` + `_fetch_all` →
      NOTIFY → `wait_notification(300)` が **None**）；`test_a_channel_not_listened_to_is_not_delivered`（LISTEN `pq_t5_a` → NOTIFY `pq_t5_b` → `wait_notification(300)` が None → NOTIFY `pq_t5_a` → 届く（対照））；
      `test_mixed_case_channel_keeps_its_case`（`_listen(listener, "\"Mixed Case\"")`（`_listen` は `"LISTEN " + channel` なので引用符つきで渡す。`:164-176`）→ sender `NOTIFY "Mixed Case", 'x'` →
      `wait_notification(2000)` の `channel == "Mixed Case"`）
    - (e) `tests/test_async.mojo`: ヘルパ `_wait_notifications_error(mut conn, n, timeout_ms) raises -> PgError` を足し、`test_every_call_while_connecting_is_usage`（`:1373-1380`）に
      `_assert_connecting_usage(_wait_notifications_error(conn, 1, 100), "wait_notifications")` を 1 行、`test_a_budget_above_c_int_max_is_usage_at_every_entry`（`:1403-1417`）に
      `_assert_timeout_too_large(_wait_notifications_error(conn, 1, 4294967296))` を 1 行（def は増やさない。`test_async_tests` = 31 のまま）
    - (f) `pixi run test` 両サーバー PASS（既存テストの期待値変更ゼロ）、`pixi run package` 警告ゼロ、`pixi run check` 6/6。チェックリストの T3 行（`async_wait_notifications_def` / `async_n_must_be` /
      `async_reject_lost_calls` = 3（訂正済み） / `init_wait_notifications` / `test_notify_wait_notifications_calls` / `test_async_wait_notifications` / `test_notify_mixed_case` / `test_notify_unlisten` / `test_notify_n_must_be` /
      `test_notify_tests` ≥ 21）が期待値。`test_notify` の `took Ns` を PROGRESS に（見込み +5 s / サーバー）
  - 対象: `src/pq/async_conn.mojo`, `src/pq/__init__.mojo`, `tests/test_notify.mojo`, `tests/test_async.mojo`
  - 依存: T2
  - 並列サブ作業（サブエージェント **1 本**（親を除く）。テストは契約（決めた事項 5・6）から並行して書ける）:
    - A: (c)(d) `tests/test_notify.mojo` の 11 件 + ヘルパ（対象: `tests/test_notify.mojo` のみ。**ヘルパ名は上記 (c) のとおり**。親が src を入れるまでコンパイルは通らないので書くだけ）
    - 親: (a)(b)(e)(f)

- [x] T4: Windows コードパスのレビュー（§4.4 / D6）— `poll.mojo` の `WSAGetLastError`、`loader.mojo` の `libpq.dll`、照合表を TRACE に、`else` 分岐の複製ビルド
  - 完了基準:
    - (a) RESEARCH §2.3 #6 / P11 / 決めた事項 7: `src/pq/_platform/poll.mojo` の `_poll_once`（`:183-232`）を **`Tuple[Int, Int, Int]`（ret, flags, err）** に。POSIX 分岐は `ret < 0` のとき
      `Int(get_errno().value)`（それ以外 0）、Windows 分岐は `ret < 0` のとき `Int(external_call["WSAGetLastError", c_int]())`。`poll_socket`（`:271-285`）は `err` を 2 つのヘルパで分類:
      `_is_interrupted(err: Int) -> Bool`（POSIX: `err == Int(ErrNo.EINTR.value)`、Windows: 常に False — `WSAEINTR` 10004 は `WSACancelBlockingCall` 時のみで再試行対象にしない）と
      `_is_usage_error(err: Int) -> Bool`（POSIX: `EBADF` / `EINVAL`、Windows: **10009 `WSAEBADF` / 10022 `WSAEINVAL` / 10038 `WSAENOTSOCK`**）。どちらも `comptime if CompilationTarget.is_linux() or
      CompilationTarget.is_macos(): ... else: ...` で定数を切り替える。message は `String("poll failed: errno ", err)`（`ErrNo` の `Writable` は使わない。`tests/test_poll.mojo` に `poll failed` の文言断定は無い —
      `grep -n 'poll failed' tests/test_poll.mojo` が 0 件）。`ErrNo` / `get_errno` の import は POSIX 側でだけ使う形でも、両方で import していても可（Windows では使われないだけ）
    - (b) `poll.mojo` の docstring: `:24-27`「Only two symbols are called by name, `poll` and `WSAPoll`」→ three（`WSAGetLastError` を足す）；Windows 注記に **#8**「Windows 10 version 2004 より前は
      TCP 接続失敗が `WSAPoll` に通知されない（`POLLHUP | POLLERR | POLLWRNORM` は 2004 以降）ので、`wait_writable` で待つ非同期接続の失敗は予算切れ（`TIMEOUT`）まで分からない」と
      **#11**「libpq の socket 以外に使うなら `WSAStartup` が先（`WSANOTINITIALISED` 10093）。libpq は接続時に自分で呼ぶ」を各 1〜2 行。RESEARCH §2.3 の一次資料 URL（[F] [S] [E]）を docstring に 3 行
    - (c) RESEARCH §2.4 / P13 / 決めた事項 8: `src/pq/_ffi/loader.mojo:14-28` の `platform_map` を `def _default_candidates() -> StaticString` の `comptime if CompilationTarget.is_linux(): return "libpq.so.5,libpq.so"`
      `elif CompilationTarget.is_macos(): return "libpq.5.dylib,libpq.dylib,/opt/homebrew/opt/libpq/lib/libpq.5.dylib,/usr/local/opt/libpq/lib/libpq.5.dylib"` `else: return "libpq.dll"` に置き換え
      （`scratch/turn-001-probe-lang.mojo` でコンパイル済みの形）。`from std.sys.info import CompilationTarget` を足し、`platform_map` の import を消す。`_candidates()`（`:31-39`）は `String(_default_candidates())` を `split(",")`。
      モジュール docstring `:10-11`「otherwise from the OS default sonames」に「(`libpq.so.5` / `libpq.so` on Linux, the dylibs and Homebrew paths on macOS, `libpq.dll` on Windows -- the last **unverified**,
      see `_platform/poll`)」を足す。検証: `pixi run hello-libpq` が `PQlibVersion = 180006` のまま、`pixi run mojo run -I src tests/test_loader_fail.mojo` PASS（候補が全部失敗する経路）、
      `loader_homebrew` = 1 のまま（macOS 候補を落とさない）
    - (d) P12 / 決めた事項 9: `else` 分岐（Windows）は Linux ではコンパイルされないので、**`_poll_once` の `else` 側と `_is_interrupted` / `_is_usage_error` の Windows 側を `if True:` 側に複製した scratch**
      `.gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-NNN-win-typecheck.mojo` を作り `pixi run mojo build -I src <scratch> -o build/win-typecheck` を試す。**期待は型検査が通ること**（`external_call` は
      実行時解決なのでリンクは通る見込み。実行はしない）。通っても通らなくても結果（コマンドと最初のエラー 3 行）を `TRACE.md`「Windows 照合表」節の末尾に 1〜3 行で書く。通らない原因が複製手順
      （シンボル）側なら「未検証のまま」と明記して進む（REQ §3: Windows でのコンパイルは対象外）
    - (e) `TRACE.md` に「Windows 照合表（`_platform/poll.mojo` の `else` 分岐）」節: RESEARCH §2.3 の表 **12 行をそのまま**（# / 項目 / poll.mojo の現状 / 根拠 / 判定）+ 一次資料 URL 4 本 + 「#6 を直した。#8 / #11 は docstring と README」の結び。
      verify が URL と行番号を突き合わせる
    - (f) `pixi run test` 両サーバー PASS（`test_poll` 11 件不変。Linux / macOS の挙動は変わらない）、`pixi run package` 警告ゼロ、`pixi run check` 6/6。チェックリストの T4 行（`loader_*` / `poll_*` / `trace_wsapoll_table` / `test_poll_tests`）が期待値
  - 対象: `src/pq/_platform/poll.mojo`, `src/pq/_ffi/loader.mojo`, `.gsd-lite/TRACE.md`
  - 依存: T1（TRACE.md の存在）
  - 並列サブ作業: サブエージェント **0 本（親が全部）**。src 2 ファイルとも小さく、(d) は (a) が決まってから

- [x] T5: ベンチマーク（§4.1 / D2）— pixi feature `bench` + `examples/bench_psycopg.py` + `pixi.lock` + 実測ログ
  - 完了基準:
    - (a) RESEARCH §2.1 / 決めた事項 10: `pixi.toml` に `[feature.bench.dependencies] python = ">=3.10"` / `psycopg = ">=3.2"`、`[feature.bench.tasks] bench-psycopg = "python examples/bench_psycopg.py"`、
      `[environments] bench = { features = ["bench"], solve-group = "default" }`（`scratch/turn-001-pixi/pixi.toml` の 3 ブロックとコメントをそのまま。`[dependencies]` は触らない → default 環境の python 3.15 は不変）。
      `pixi.lock` が bench 環境ぶん更新される（**コミット対象**。`lock_psycopg_c` 0 → ≥ 3）。`git diff --stat pixi.lock` を PROGRESS に 1 行（P16）
    - (b) `examples/bench_psycopg.py` = `scratch/turn-001-pixi/examples/bench_psycopg.py` をそのまま（`SQL` / `ROWS` / `RUNS` は `examples/bench_formats.mojo:30-40` と同値、`autocommit=True`、warm-up 1 + 3 回 text / binary 交互、
      全セルを読む、`rows != ROWS` や合計 0 で exit 1、`psycopg.Error` → `failed: <型名> <message>` + exit 1）。先頭 docstring に「Run it with `pixi run bench-psycopg`」があることを確認（RESEARCH 版にある）
    - (c) 堅牢性（§4.1 / §5）: `PQ_TEST_CONNINFO="host=127.0.0.1 port=54317 user=pq password=wrong dbname=pq_test"` と `"... port=54390 ... connect_timeout=3"` を環境で渡した `pixi run bench-psycopg` が
      **`failed: OperationalError ...` で始まる 1 レコード + 終了コード 1**、`Traceback` が出ない。結果を PROGRESS に 1 行
      （PLAN 訂正: 「1 行」→「1 レコード」。libpq の message 自体が `Is the server running on that host ...` のヒント行を含むため、
      接続拒否のケースは物理 2 行になる。`^failed: OperationalError` の行数が 1 で `Traceback` が 0 なら合格）
    - (d) 実測（P14 / REQ §9「`check` 直後に測らない」）: `check` を回した直後ではなく、**アイドル時に** `pixi run bench` → `pixi run bench-psycopg` → `pixi run bench` → `pixi run bench-psycopg` の順で 2 回ずつ
      回し、全出力を `.gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-NNN-bench.log` に残す（`tee`）。先頭に `date -Iseconds` と `lsb_release -ds` / `nproc` / `pixi run mojo --version` /
      `docker exec tests-pg17-1 psql -U pq -d pq_test -tAc "SHOW server_version"` の出力を書く（README の計測環境欄の原本）。**受け入れ（REQ §4.1）**: Mojo の `decode` 列で **binary < text** が 2 回とも成立
      （RESEARCH 実測 12 vs 44 ms）。合計の勝敗は記録のみ。psycopg の `impl=c` を確認（`python` 実装なら桁が変わる）
    - (e) `pixi run check` 6/6 PASS（default 環境が変わっていないことの担保。1/6 段に `.py` は無関係）。チェックリストの T5 行（`pixi_feature_bench` / `pixi_bench_psycopg` / `pixi_environments` / `lock_psycopg_c` / `bench_py*`）が期待値。
      bench 2 本の所要と初回環境作成の所要を PROGRESS に単位付きで
  - 対象: `pixi.toml`, `pixi.lock`, `examples/bench_psycopg.py`
  - 依存: T1（`pixi.toml` の `db-reset` と同じファイル。順序のため）
  - 並列サブ作業: サブエージェント **0 本（親が全部）**。3 ファイルとも雛形があり、実測は親が順に回す

- [ ] T6: `README.md`（§4.2 / D7 日本語）+ `LICENSE`（D11）+ examples 5 本の docstring（§4.3）
  - 完了基準:
    - (a) RESEARCH §2.11 / 決めた事項 12: `LICENSE` = https://www.apache.org/licenses/LICENSE-2.0.txt の全文（APPENDIX 含む。改変しない）。取得は scratch の 5 行スクリプト
      `.gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-NNN-fetch-license.py`（`urllib.request.urlretrieve(URL, "LICENSE")`）を `pixi run python <scratch>` で（`curl` は allowlist 外）。
      ダメなら `WebFetch` で本文を取って `Write`。検証: `head -3 LICENSE` が `Apache License` / `Version 2.0, January 2004` / `http://www.apache.org/licenses/`（前後の空白は可）、
      `grep -c APPENDIX LICENSE` = 1、`wc -l LICENSE` が 200〜205（公式 202 行）、`wc -c` を TRACE に（公式 11,358 bytes の見込み）
    - (b) `README.md`（日本語。決めた事項 11 の節立て 11 節、`## ` 見出し ≥ 10）。**コード片は `examples/` から抜粋し、各コード片の直前に抜粋元ファイル名を書く**（P18。verify が照合）:
      概要と対応環境（Mojo 1.1.0 / libpq 14+ / Linux・macOS、Windows は未検証）／インストール（pixi、libpq の探索順 = `loader.mojo` の `_default_candidates` の 3 OS と `PQ_MOJO_LIBPQ`）／
      クイックスタート（同期 `examples/basic.mojo`、パラメータ `examples/params.mojo`、トランザクション（`params.mojo` か `basic.mojo` の該当部。無ければ `__init__.mojo:173-183` の説明を日本語で）、
      バイナリ `examples/binary.mojo`、非同期 `examples/async_query.mojo`、LISTEN/NOTIFY `examples/listen_notify.mojo`。各 5〜15 行の抜粋 + `pixi run example-*` の実行行）／
      型マッピング表（**`src/pq/__init__.mojo:42-62` の 19 行を日本語見出しで転記**。OID と Mojo 型を変えない）／エラー（`PgErrorKind` **8 値**の一覧 = `errors.mojo` の順、`Encoding` を含む。`__init__.mojo` の `## PgErrorKind` 節を日本語で）／
      ベンチマーク結果（T5 の `scratch/turn-NNN-bench.log` から転記。**3 回の値を `a / b / c` で並べる**（決めた事項 14）、形式 × exec / decode / 合計の表、psycopg は text / binary 各行、
      計測環境（Ubuntu 24.04.5 LTS / kernel / aarch64 4 コア VM / RAM / Mojo 1.1.0 / libpq 18.6 conda-forge / PostgreSQL 17.11 docker / psycopg 3.3.4 + psycopg-c 3.3.4 impl=c python 3.14.8）、日付、
      1 行要約「バイナリ形式はテキスト形式より decode で N 倍速い（…）。合計でも …。psycopg 3（C 実装）は …」、「同じ SQL・同じ形式・同じ測り方（warm-up 1 + 3 回、全セルを読む）」、
      再現手順 `pixi run db-up` → `pixi run bench` → `pixi run bench-psycopg`（初回は環境作成で 1 分前後））／テストの回し方（`db-up` / `test` / `check` / **`db-reset`**、両サーバー 54317 / 54314、blackhole 54399）／
      Windows の状態（「`WSAPoll` と `libpq.dll` のコードは存在するが**未検証**（Mojo の Windows ツールチェーン待ち）」、Windows 10 2004 より前は非同期接続の失敗がタイムアウトまで分からない（RESEARCH §2.3 #8）、
      `OwnedDLHandle` の Windows 実装も未検証）／既知の制限（`client_encoding` を設定しない、`cancel` は `PQcancel`（TLS 保護なし）、配列型・COPY・プールは対象外）／ライセンス
      （「Apache License 2.0。`LICENSE` 参照」+ 末尾に `Copyright 2026 0hya6in`）。README のクイックスタートは `failed: PgError(kind=Connection, ...)` の形だけを約束し libpq 文言は約束しない（RESEARCH §2.9）
    - (c) §4.3 / RESEARCH §2.9: `examples/basic.mojo` / `params.mojo` / `binary.mojo` / `async_query.mojo` / `listen_notify.mojo` の先頭 docstring に `Run it with \`pixi run example-<name>\`.` の 1 行
      （`bench_formats.mojo:15` の形。`hello_libpq` は T1 済み、`bench_formats` は既にある → `examples_pixi_run` = 7）。「何を見せるか」「前提（`PQ_TEST_CONNINFO` / 既定の接続先）」「`PgError` は印字して非 0」は
      7 本とも既にある（RESEARCH §2.9）ので、無い本があれば足す。README のクイックスタートと矛盾しない（抜粋した行がそのまま存在する）
    - (d) 検証: `pixi run check` 6/6（4/6 段で 5 本の examples が docstring 変更後も走る）、`pixi run hello-libpq`。README の型表 19 行と `__init__.mojo:42-62` を impl 自身が目視で突き合わせ PROGRESS に 1 行、
      `PgErrorKind` 8 値を `errors.mojo` と突き合わせ 1 行。README の数値が `scratch/turn-NNN-bench.log` と一致（ログのパスを PROGRESS に）。チェックリストの T6 行（`readme*` / `license*` / `examples_pixi_run` = 7）が期待値
  - 対象: `README.md`, `LICENSE`, `examples/basic.mojo`, `examples/params.mojo`, `examples/binary.mojo`, `examples/async_query.mojo`, `examples/listen_notify.mojo`
  - 依存: T3（API 一覧に `wait_notifications` / `ENCODING`）, T4（Windows 節の内容）, T5（ベンチの数値）
  - 並列サブ作業（サブエージェント **1 本**（親を除く）。README は転記元を把握している親が書く（RESEARCH §6））:
    - A: (a) `LICENSE` の取得と検証 + (c) examples 5 本の docstring 1 行（対象: `LICENSE`, `examples/basic.mojo`, `examples/params.mojo`, `examples/binary.mojo`, `examples/async_query.mojo`, `examples/listen_notify.mojo`）
    - 親: (b) `README.md` + (d)

- [ ] T7: 統合 — `check` / examples 堅牢性の格子 / `pg_database` の後始末確認 / チェックリスト全行 / PROGRESS「未確認」行の処分表 / 所要
  - 完了基準:
    - (a) `pixi run db-reset` → `pixi run check` が **6/6 PASS**、所要（秒）が **247 s 以下**（超えたら PROGRESS に理由）。`pixi run test`（両サーバー、leak 両方）も PASS
    - (b) REQ §5 堅牢性（D4）/ P17: `scratch/turn-001-examples-robust.sh` を `turn-NNN-examples-robust.sh` にコピーし、`bench_psycopg`（`pixi run bench-psycopg` を `PQ_TEST_CONNINFO` 付きで。badpw / badport の 2 本）と
      `hello_libpq nolib` を含めて **17 本以上**回し、全行 `rc=1` かつ `unhandled_markers=0`（`Traceback` / `Unhandled` / `stack trace` が無い）。ログを `scratch/turn-NNN-examples-robust.log` に。
      PROGRESS に「17/17」の 1 行、生ログのパス
    - (c) §4.7 / P5: (a) の `pixi run test` の後、検証コマンドの `docker exec ... psql` を **pg17 / pg14 の両方**で実行し **0 行**（`pq_test_ascii` が残らない）。結果を PROGRESS に 1 行
    - (d) 受け入れ §5 の対応表を `TRACE.md`「受け入れ基準対応表」節に（HANDOFF §10 Phase 5 の 3 項目 + REQ §5 の各行 → どのタスク・どのテスト・どのログで担保したか。1 行 1 項目）
    - (e) REQ §9 impl 項目: PROGRESS の turn 3〜 の全「未確認」行を列挙し、各行を **テスト追加 / 契約外と明記 / verify 申し送り** のいずれか 1 つに振り分けた表を `TRACE.md`「未確認行の処分表」節に
      （「誤った値が黙って返る経路」「状態機械が壊れる経路」を述べる行はテスト 1 件にするか、この表で処分先を 1 つだけ書く）
    - (f) チェックリストスクリプトを実行し**全行が期待値**（`src_def_ref_return` 0 / `tests_files_count` 24 / `test_file_count` 24 を含む）。例外があれば `TRACE.md`「PLAN 訂正」に 1 行ずつ。
      ログを `scratch/turn-NNN-checklist.log` に
    - (g) `git status` がクリーン（`pixi.lock` / `README.md` / `LICENSE` / `examples/bench_psycopg.py` がすべてコミット済み）。`phase: "verify"` / `next_command: "/gsd-lite-verify"` へ
  - 対象: `.gsd-lite/TRACE.md`, `.gsd-lite/PROGRESS.md`（コードは原則変えない。格子や `check` で見つかった不具合は同ターンで直し、その旨を PROGRESS に）
  - 依存: T6
  - 並列サブ作業: サブエージェント **0 本（親が全部）**（実行と転記だけ）

## 決めた事項

1. **タスク分割は RESEARCH §6 の T1〜T6 を 7 つに**（T2 を「`ENCODING` + 先行チェック + 格子」と「`wait_notifications` + 契約外テスト」に分けた）。T2 単体でも src 5 + tests 3 ファイルあり、
   `wait_notifications` の 11 件を同じターンに乗せると 1 ターンを超える見込み（Phase 4 T4 と同規模）。持ち越し整理は T1 に 1 コミット（REQ §9）
2. **`PgErrorKind.ENCODING = Self(7)`、`write_to` は `"Encoding"`**（根拠: `src/pq/errors.mojo:20-52` で 0〜6 が埋まっている。`test_errors.mojo:62-65` の形で検証）
3. **`ENCODING` に変える docstring 16 行**（`grep -rn 'invalid UTF-8\|TYPE_MISMATCH' src/pq` の結果から UTF-8 に関わる行だけ）: `decode_binary.mojo:41,46,329,859`、`async_conn.mojo:267,281,1362,1373,1562`、
   `result.mojo:543,848,854`、`__init__.mojo:35,122,254,285,286`。raise 4 箇所: `decode_binary.mojo:343,347`、`async_conn.mojo:295,299`。テスト 7 行: `test_notify.mojo:492,534`、`test_decode_binary.mojo:470,481,489,497,538`。
   OID / 幅 / 添字 / jsonb 版数の `TYPE_MISMATCH` は残す（`test_zero_copy.mojo:469,474,551,552` を含む）
4. **`notifications()` 先行チェックは `_reject_lost(self, method: StaticString)` ヘルパ**（`_reject_connecting`（`async_conn.mojo:580-594`）と同形）。文言 `<method>() called on a lost connection`、kind `CONNECTION`、
   `sqlstate` 空。呼び出し順は `_reject_connecting` → `_reject_lost` → `PQconsumeInput`。`notifications` / `wait_notification` / `wait_notifications` の 3 入口が自分の名前で呼ぶ（利用者が呼んだメソッド名が出る）。
   テストが断定するのは「3 回とも同一 message」（RESEARCH §2.8: 先行チェックの唯一の観測可能な効果）
5. **`wait_notifications` は private `_collect_notifications(method, n, timeout_ms)` に一般化し、`wait_notification` を薄いラッパにする**（RESEARCH §3-7 推奨。`_pending` の扱いが 1 箇所になる）。
   シグネチャ `def wait_notifications(mut self, n: Int, timeout_ms: Int) raises PgError -> List[Notification]`（REQ §4.6.1）。`n < 1` は `USAGE` `wait_notifications: n must be at least 1 (got N)`。
   検査順 `_reject_bad_timeout` → `n < 1` → `_reject_connecting` → `_reject_lost`。予算切れは集まった分を返す（D8）。`notifications()` の raise 時は `out` を `_pending` の先頭に戻す（既存データを失わない。REQ §5）。
   余りは `_pending` に先頭から append（現状 `:1572-1573` の順序）
6. **`wait_notifications` の境界格子**（REQ §9「縮小変換の行を常設」。`n` は C に渡さないが同じ格子で扱う）: `n ∈ {0, -1, 1, 2, Int.MAX}` × `timeout_ms ∈ {-2, -1, 0, 200, 300, TIMEOUT_MS_MAX + 1, 4294967296, Int.MAX}`
   のうち T3 (c) ①〜⑧ + (e) の 2 行で覆う（`timeout_ms` の範囲外は `_reject_bad_timeout` 1 箇所なので代表 4 値、`TIMEOUT_MS_MAX` ちょうどは `test_poll.mojo:192` が既に通している）
7. **Windows のエラー分類**（RESEARCH §2.3 #6 / §3-2）: `_poll_once` が `(ret, flags, err)` の 3 要素を返し、`poll_socket` は `_is_interrupted(err)` / `_is_usage_error(err)` の 2 ヘルパで分類する。
   Windows は 10009 / 10022 / 10038 → `USAGE`、他 → `CONNECTION`、再試行なし。POSIX は現状どおり（`EINTR` 再試行、`EBADF` / `EINVAL` → `USAGE`）。message は `poll failed: errno <数値>`
   （`tests/test_poll.mojo` に文言断定なし。`grep -n 'poll failed' tests/test_poll.mojo` = 0 件）
8. **`loader.mojo` の候補は `_default_candidates() -> StaticString` の `comptime if` 連鎖**（RESEARCH §2.4。`probe-lang.mojo` でコンパイル済み）。Windows は `libpq.dll` の 1 候補（HANDOFF §5.1:123）。
   `PQ_MOJO_LIBPQ` の扱いは不変
9. **`else` 分岐の検証は複製ビルドまで**（RESEARCH §2.3 の検証方法 (a)）。通らなくても BLOCKED にせず TRACE に記録（REQ §3「Windows での実行・コンパイルは対象外」）
10. **pixi は feature `bench` + 環境 `bench`（`solve-group = "default"`）**（RESEARCH §2.1 実測。`[dependencies]` は触らない）。スクリプトは `examples/bench_psycopg.py`（REQ §4.1 既定）。`pixi.lock` はコミット
11. **README の節立て（この順）**: 1 概要と対応環境 / 2 インストール / 3 クイックスタート / 4 型マッピング / 5 エラー / 6 ベンチマーク結果 / 7 テストの回し方 / 8 Windows の状態 / 9 既知の制限 / 10 ライセンス
    （REQ §4.2 の最低限 + 既知の制限）。日本語、docstring は英語のまま（D7）。コード片は `examples/` から抜粋し抜粋元を明記（REQ §5）
12. **`LICENSE` は公式テキストをそのまま**（APPENDIX 含む）。取得は `pixi run python <scratch .py>`（`urllib`）。`curl` は allowlist 外（`.claude/settings.json`）
13. **`.gsd-lite/TRACE.md` の節立て**: 「PLAN 訂正（turn N）」/「`test_zero_copy` の所要」/「`_after_send` -1 のコードレビュー」/「Windows 照合表」/「examples 堅牢性の格子」/「受け入れ基準対応表」/「未確認行の処分表」。
    PROGRESS は 1 ターン 40 行上限、生の値は TRACE へ（REQ §9）
14. **README のベンチ表は 3 回の値を `a / b / c` で並べる**（RESEARCH §2.2 の表と同じ形。中央値は書かない — 揺れが見えるほうが「勝敗は条件にしない」（HANDOFF §8）に合う）
15. **`DROP DATABASE IF EXISTS pq_test_ascii WITH (FORCE)` を先頭と末尾の両方に**（RESEARCH §2.6 推奨形）。発行元は `pq_test` に繋いだ同期 `Connection`（`_open(_conninfo())`）、autocommit。末尾は結果を握る
16. **`fetch_all` の打ち切り条件は `e.kind == CONNECTION or PQstatus == BAD`**（既存条件を残して `or` で足す。RESEARCH P1）。テストは `close(PQsocket)` 方式（`pg_terminate_backend` では差分が出ない）
17. **`_after_send` の -1 分岐は `BUSY` に置いてから raise**。到達不能なので陽性対照はコードレビュー（REQ §4.5 / RESEARCH §2.7）
18. **examples の「実行方法」は docstring に `Run it with \`pixi run <task>\`.` の 1 行**（`bench_formats.mojo:15` の形。`hello_libpq` は T1、他 5 本は T6）
19. **テスト件数の期待値**: `test_async` 30 → 31、`test_notify` 11 → ≥ 12（T2）→ ≥ 21（T3）、`test_decode_binary` 88 → 88（格子に行を足すだけ）、`test_errors` 8 → 9、`test_poll` 11 → 11。新テストファイルは無い
20. **`check` の閾値 247 s**（Phase 4 末 187 s + 60 s）。超えたら PROGRESS に理由（REQ §5）

## メモ

- **reflect の提案の反映（直近 2 件: Phase 4 / Phase 3）**:
  - 反映: 縮小変換の行を常設（決めた事項 6。今回 C に渡す新規引数は無いので格子だけ）／所要見積もりを Phase 4 末実測 + 式で（検証コマンド節）／チェックリストは 3 列 + 現在値はログ（上表）／
    「サブエージェント N 本（親を除く）」「0 本（親が全部）」の書き方／陽性対照を完了基準に（T1 (b)(e)、T2 (c)(d)、T7 (b)）／持ち越し整理を T1 に 1 コミット／PROGRESS 40 行・TRACE 分離（決めた事項 13）／
    最終タスクに未確認行の処分表（T7 (e)）／テストのみ 2 ファイル型は 1 本（T2 / T3 の A）
  - 反映しない: Phase 3 の「期待値表の hex を RESEARCH のログからコピー」は今回 hex 期待値が無い（UTF-8 格子 3 行は RESEARCH §2.10 のとおり）。Phase 4 の「ツール側」提案は plan の対象外
- **RESEARCH §3「盗める点」の採否表**:

  | # | 盗める点 | 採否 | 理由 |
  |---|---|---|---|
  | 1 | psycopg bench の境界（`execute` = exec、`fetchall` + 全セル = decode、`autocommit=True`） | 採用 | T5 (b)。プローブ版をそのまま |
  | 2 | `WSAGetLastError` を 3 要素タプルで返す | 採用 | T4 (a)。POSIX 側も同じ位置に errno を入れ `poll_socket` は単一分岐のまま |
  | 3 | `comptime if` 連鎖の候補関数で `platform_map` を消す | 採用 | T4 (c) |
  | 4 | `DROP DATABASE IF EXISTS ... WITH (FORCE)` を先頭と末尾に、末尾は try | 採用 | T1 (d)。決めた事項 15 |
  | 5 | `fetch_all` の `kind == CONNECTION` で break | 採用 | T1 (a)。既存の `PQstatus` 条件も残す |
  | 6 | `notifications()` 先行チェックを `_reject_connecting` の直後に | 採用（ヘルパ化） | T2 (d)。決めた事項 4 |
  | 7 | `wait_notifications` に一般化 + 薄い `wait_notification` | 採用 | T3 (a)。決めた事項 5 |
  | 8 | README の節立てと型表の転記元 | 採用 | T6 (b)。決めた事項 11 |
  | 9 | examples 堅牢性スクリプトを `tests/` に入れない | 採用（入れない） | `check` +70 s を避ける。T7 (b) と verify の格子として scratch に残す |

- **落とし穴 P1〜P20 の対応先**: P1 → T1 (a)(b)、P2 → T1 (b)、P3 → T1 (c)、P4 → T2 (d)、P5 → T1 (d)(e) / T7 (c)、P6 → T1 (e)、P7 → T1 (i)（`check` 6/6）、P8 → T2 (c)、P9 → T3 (c)④⑤⑥ (e)、
  P10 → T3 (c)⑦、P11 → T4 (a)、P12 → T4 (d)、P13 → T4 (c)、P14 → T5 (d) / T6 (b)、P15 → T5 (a) / T6 (b)、P16 → T5 (a)、P17 → T1 (g) / T7 (b)、P18 → T6 (b)、P19 → 検証コマンド節 / T7 (a)、P20 → 検証コマンド節
- **並行性・境界値・異常系の担当**: 並行性 = T1 (b)（socket close 中の `fetch_all`）/ T3 (c)⑦⑧（1 往復に複数通知）/ T2 (d)（切断後の連続呼び出し）。境界値 = T3 (c)④⑤⑥ + (e)（`n` / `timeout_ms` の格子、決めた事項 6）/
  T2 (e)（UTF-8 4 バイト境界）。異常系 = T1 (g) / T5 (c) / T7 (b)（DB 未起動・認証失敗・libpq 不在で examples / bench がトレースバックを出さない）/ T1 (d)(e)（DROP が失敗しても結果を隠さない）
- **impl への申し送り（REQ §9）**: サブエージェント依頼文に (a) 型パラメータを持つ型はフルに書く（`Span[UInt8, origin]` は `[origin: ImmOrigin, //]`）、(b) `fmt` は親が統合後に 1 回、(c) scratch は
  `.gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-NNN-<name>` 固定、(d) `print("SKIP ...")` や長い文字列は 80 桁に収める（`mojo format` が割る）。PROGRESS「やったこと」に「推奨 N 本 / 実 M 本」。
  時間は単位付き。bench は `check` 直後に測らない。`PgError` を値で返すヘルパは `return e^`（RESEARCH §0.5 ☆）
- **verify への申し送り**: 照合表 12 行は URL と突き合わせ（T4 (e)）。`pg_database` は両サーバー（T7 (c)）。README の型表は `__init__.mojo:42-62`、`PgErrorKind` は `errors.mojo`、examples の実行手順は `pixi.toml:14-23` と照合。
  examples 格子は `scratch/turn-NNN-examples-robust.sh` を再実行できる（≈ 70 s）。bench は再実行して Mojo の decode 列で binary < text だけを断定（P14）。検証用 DB は `pq_verify_<turn>` で同ターンに消す
