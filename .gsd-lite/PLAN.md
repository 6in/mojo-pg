# PLAN — phase7-pool-copy-array

- 作成: 2026-10-20 / gsd-lite-plan（turn 2）
- 入力: REQUIREMENTS.md / DECISIONS.md（D1〜D20）/ RESEARCH.md（§0〜§6、落とし穴 P1〜P29、提案 1〜11）/
  `.gsd-lite/reflect/20261018-1252-phase6-packaging-ci.md`（直近）/ `.gsd-lite/reflect/20261018-0103-phase5-polish-bench-readme.md` /
  `archive/phase6-packaging-ci/PLAN.md`（書式の手本）/ `src/pq/{connection,transaction,prepared,result,params,decode_text,decode_binary,encode_binary,errors}.mojo` /
  `src/pq/_ffi/{functions,types}.mojo` / `tests/{final_check.sh,run_tests.sh,test_leak.mojo,test_decode_text.mojo}` / `README.md` / `CHANGELOG.md` / `pixi.toml` /
  research のプローブ `scratch/turn-001-probe-{copy,pool,array,lang}.mojo`
- 対象リポジトリ: `.`（in-repo 形）。`CLAUDE.md` / `AGENTS.md` は無い（`ls` で確認）。base `main`、ブランチ `gsd-lite/phase7-pool-copy-array`
- 無人シェルの注意（RESEARCH §0.5 と同じ）: `mojo` / `pixi` は PATH に無い → **`/home/parallels/.pixi/bin/pixi run ...`**。先頭の変数代入は不可（`env VAR=… cmd`）。
  `bash <任意パス>` / `awk` / `sed` / `tee` / `curl` は allowlist（`.claude/settings.json`）に無い → **`/home/parallels/.pixi/bin/pixi run bash <file>`** で実行する
  （`bash tests/...` / `python3` / `grep` / `docker` / `git` / `gh api|pr|run` は直接可）。docker は `tests-pg17-1` / `tests-pg14-1`（healthy）/ `tests-blackhole-1` が起動中
  （plan 時点 `docker compose ps`）。lean-ctx MCP は未接続（素の Read / Bash で可）。`> >(exit 0)` などプロセス置換は Bash ツール直書き不可 → スクリプトファイルにする
- research のプローブ（`.gsd-lite/logs/phase7-pool-copy-array/scratch/turn-001-*`、gitignore 対象）は impl が**雛形として開いてよい**:
  `turn-001-probe-copy.mojo`（`CopyFFI` の 3 シグネチャ `:56-75`、`get_row` の `char **` 受け取り `:97-123`、`describe` / `start`）、
  `turn-001-probe-pool.mojo`（`PoolProto` の `_mut_idle` 型の escape hatch `:72-80`、`_release` の判定順 `:99-126`、`Pooled._conn_ptr` の rebind `:155-161`、`transaction` / `prepare` の転送 `:163-174`）、
  `turn-001-probe-array.mojo`（`array_recv` 形式の手組み payload 24 ケース = T3 / T4 の期待値）、`turn-001-probe-lang.mojo`（`comptime if T == List[...]` の `rebind` 形 A、`@implicit` 4 本 + literal B、`Iterator` の制約 D、ガード E）
- **追従先チェックリストは実行可能スクリプト** `.gsd-lite/logs/phase7-pool-copy-array/scratch/turn-002-checklist.sh`（`.md` 以外はコメント行を母数から除外。Phase 6 reflect 提案 3）。
  plan ターンで 1 回実行し、現在値は `scratch/turn-002-checklist.log`（コミット `e7fdf6c` の木、**全 77 key**）にある。下表は key / 直す場所 / 期待値の 3 列だけ。
  impl は各タスクの完了基準の最後で実行し、自タスクの行が期待値に到達していることを PROGRESS に 1 行で書く（生の値は `.gsd-lite/TRACE.md` の「チェックリスト（turn N）」節へ。総数 77 を同じ節に書く）。
  **PLAN の訂正は表のセルに書かず `TRACE.md` の「PLAN 訂正（turn N）」節に 1 件 1 行**。コメントを書いたらコミット前にチェックリストを 1 回回す（key の語がコメントに当たる事故の防止）

## 検証コマンド

impl の各ターンがテストに使うコマンド（リポジトリルートで実行。`cd` 不要）:

```bash
/home/parallels/.pixi/bin/pixi run db-up          # 環境の初期化（起動済みなら即終了）
/home/parallels/.pixi/bin/pixi run db-reset       # db-down（-v）→ db-up。フィクスチャ再適用。T9 の最終判定の前に 1 回
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_decode_array.mojo   # T2 / T3（サーバー不要）
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_encode_binary.mojo  # T4
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_params.mojo         # T4（既存 33 件 不変 + 追加）
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_array.mojo          # T5（PQ_TEST_CONNINFO 未設定なら 54317。PG14 は `env PQ_TEST_CONNINFO="host=127.0.0.1 port=54314 user=pq password=pq dbname=pq_test" ...`）
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_copy.mojo           # T6
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_pool.mojo           # T7
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_connection.mojo     # T1（reset の 2 件）
/home/parallels/.pixi/bin/pixi run mojo build -I src tests/test_leak.mojo -o build/test_leak   # T7: leak は built binary で（run_tests.sh:71 と同じ）
/home/parallels/.pixi/bin/pixi run test           # tests/run_tests.sh: 54317 → 54314 の順に tests/test_*.mojo を 1 ファイル 1 プロセス
/home/parallels/.pixi/bin/pixi run package        # mojo precompile src/pq -o build/pq.mojoc（警告ゼロ確認）
/home/parallels/.pixi/bin/pixi run fmt            # mojo format（1/6 段と同じ対象）
/home/parallels/.pixi/bin/pixi run check          # 最終判定: bash tests/final_check.sh（6 段、exit 0 が合格）
/home/parallels/.pixi/bin/pixi run bash .gsd-lite/logs/phase7-pool-copy-array/scratch/turn-002-checklist.sh   # 追従先チェックリスト（現在値を出す）
/home/parallels/.pixi/bin/pixi run bash .gsd-lite/logs/phase7-pool-copy-array/scratch/turn-003-robust-grid.sh  # 堅牢性格子（T1 が作り T9 が全セル回す）
python3 .gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-008-readme-excerpts.py   # README のコード片が examples と逐語一致（T8。Phase 5 の照合器をそのまま）
python3 -c "t=open('.gsd-lite/PROGRESS.md').read().split('\n## turn');print(len(t[-1].splitlines()))"   # T9: 最新ターン節の行数（≤ 40）
docker exec tests-pg17-1 psql -U pq -d pq_test -At -c "<sql>"   # サーバー側の実測（typarray / 配列リテラル / pg_stat_activity）
```

- 環境の初期化（テストの前に毎回）: `/home/parallels/.pixi/bin/pixi run db-up`（起動済みなら即終了）
- 最終判定（クリーンな状態から全検査。verify と T9 が使う）: **`/home/parallels/.pixi/bin/pixi run db-reset` → `/home/parallels/.pixi/bin/pixi run check`**（exit 0、`final_check: PASS`）
  - 4/6 段（`final_check.sh:120-129`）は現在 5 本の examples。**T8 で `examples/copy.mojo` / `examples/pool.mojo` の 2 行を足して 7 本**。6/6 段は `grep -cE 'warning:|WARNING:|implicit ROLLBACK failed'`（`final_check.sh:155`）。
    **見出し行・`print`・テストの出力にこれらの文字列を含めない**。サーバーの `NOTICE:` は数えられない（P28）
  - 所要見積もり（Phase 4 reflect の式: 前回末実測 + 新規分）: `check` = **turn 3（T1）実測 263 s** + 新テストファイル 4 本 × 2 サーバー（コンパイル各 3〜5 s + 実行: `test_decode_array` < 1 s / `test_array` ≈ 3 s / `test_copy` ≈ 2 s（10 万行 IN+OUT 0.1 s、close(fd) 待ちなし）/
    `test_pool` ≈ 3 s（`pg_sleep(1.1)` + `pg_sleep(0.05)` ×3））+ `test_leak` の 2 ループ ≈ 10 s（1 サーバーのみ）+ examples 2 本 ≈ 4 s → **+60〜85 s = 323〜348 s**。
    閾値 **380 s**（超えたら PROGRESS に理由。母数は T1 で取り直した: 訂正の根拠は `TRACE.md`「PLAN 訂正（turn 3）」）
- **CI は PR 作成後に初めて走る**: `ci.yml` の `on:` は `pull_request`（base main）と `push`（main）だけ → T9 の branch push では走らない。PR を作るのは verify（REQ §6）。PR 作成後は state コミットの push ごとに 3 OS の run が起動し `concurrency` が古いものを cancel する（Phase 6 reflect Minus 5）
- PG14 / PG17 の差: 無し（RESEARCH §2.1 / §2.4 両サーバー同一）。`server_version()` 分岐は書かない

## 追従先チェックリスト

スクリプト `turn-002-checklist.sh` の key で書く（左列）。現在値は `scratch/turn-002-checklist.log`（2026-10-20、コミット `e7fdf6c` の木、全 77 key）。`absent(...)` はファイル未作成。
期待値の「≥」は下限（増える方向の key は `≥ 現在値 + 最小増分`）。`= N` は「0 になる」「不変」「件数が確定している」性質だけ。

| key | 変更の種類 / 直す場所 | 期待値（到達タスク） |
|---|---|---|
| `ffi_putcopydata` / `ffi_putcopyend` / `ffi_getcopydata` | T1: `src/pq/_ffi/functions.mojo` にフィールド + `_dl_sym`（`libpq-fe.h:547-549`） | **≥ 2 ×3**（T1。var 行 + `_dl_sym` の名前文字列） |
| `conn_reset_def` / `conn_reset_session_setup` | T1: `Connection.reset()`（`PQreset` → `PQstatus` → `_SESSION_SETUP_SQL` 再送。P19） | **1 / ≥ 4**（T1。現在 3 = 定義 + `_adopt` の 2 箇所） |
| `conn_transaction_parts_def` / `conn_transaction_parts_sites` | T1: `transaction()` の検査 + `BEGIN` を `_transaction_parts` に分離。T7 で `pool.mojo` からも呼ぶ | **1 / ≥ 2**（T1 で 2、T7 で ≥ 3。`absent(pool.mojo)` は T7 まで許容） |
| `test_connection_tests` | T1: `reset()` のテスト 2 件（terminate → reset → DateStyle / 健全な接続の pid 変化） | **≥ 33**（T1。現在 31） |
| `trace_exists` / `trace_checklist_section` / `grid_script` | T1: `.gsd-lite/TRACE.md` 新設 + `scratch/turn-003-robust-grid.sh`（3 軸） | **exists / ≥ 1 / exists**（T1） |
| `oid_array_consts` / `array_elem_oid_def` / `array_oid_of_def` | T2: `decode_text.mojo` に `OID_*_ARRAY` 21 個（RESEARCH §2.1）+ 2 関数 | **21 / 1 / 1**（T2） |
| `parse_array_literal_def` / `decode_text_array_def` | T2: tokenizer + 要素デコーダ呼び出し | **1 / 1**（T2） |
| `decode_text_list_branches` / `decode_text_optional_branches` | T2: `comptime if` に `List[T]` 17 + `List[Optional[T]]` 17（既存 `List[UInt8]` 1 を含む） | **35 / 17**（T2。turn 4 訂正） |
| `decode_binary_array_def` / `decode_binary_list_branches` / `decode_binary_optional_branches` | T3: `decode_binary.mojo` 同型 | **1 / 35 / 17**（T3。turn 4 訂正） |
| `test_decode_array_tests` | T2 でテキスト側（≥ 18）、T3 でバイナリ側（+ ≥ 14） | **≥ 18（T2）/ ≥ 32（T3）** |
| `encode_array_def` / `params_list_implicit` / `params_optional_list_implicit` / `params_text_array_oid` | T4: `encode_binary.mojo` の `encode_array` + `params.mojo` の `@implicit` 34 本（既存 `List[UInt8]` 1 + `Optional[List[UInt8]]` は `var v: Optional[` なので母数外） | **1 / 35 / 17 / ≥ 1**（T4。turn 4 訂正） |
| `test_encode_binary_tests` / `test_params_tests` | T4: 単体 3 件以上 + サーバー 4 件以上（既存 26 / 33 件の期待値変更 0） | **≥ 29 / ≥ 37**（T4） |
| `test_array_tests` | T5: `tests/test_array.mojo` 新設 | **≥ 14**（T5） |
| `copy_mojo` / `copyin_struct` / `copyout_struct` / `copy_drain_def` | T6: `src/pq/copy.mojo` | **exists / 1 / 1 / 1**（T6） |
| `copy_in_defs` / `copy_out_defs` | T6: `Connection.copy_in` + `Transaction.copy_in`（T7 で `PooledConnection.copy_in`） | **2 / 2**（T6）→ **3 / 3**（T7。`absent(pool.mojo)` は T7 まで許容） |
| `conn_copy_parts_defs` / `conn_check_not_copying_def` / `check_not_copying_sites` | T6: `_copy_in_parts` / `_copy_out_parts` / `_check_not_copying` + 呼び出し 7 箇所（`execute` ×2 / `prepare` / `_transaction_parts` / `_copy_in_parts` / `_copy_out_parts` / `PreparedStatement.execute`） | **2 / 1 / ≥ 7**（T6。P13） |
| `conn_docstring_copy_unsupported` | T6: `connection.mojo:266-269` の「not supported」を `copy_in` / `copy_out` への案内に（REQ §4.4） | **0**（T6） |
| `init_export_copy` / `init_export_pool` | T6 / T7: `__init__.mojo` の re-export | **1（T6）/ 1（T7）** |
| `test_copy_tests` | T6: `tests/test_copy.mojo` 新設 | **≥ 18**（T6） |
| `pool_mojo` / `pool_struct` / `pooled_struct` / `pool_release_def` / `pool_consume_input` / `pool_rollback` / `pool_monotonic` | T7: `src/pq/pool.mojo` | **exists / 1 / 1 / 1 / ≥ 1 / ≥ 1 / ≥ 1**（T7） |
| `test_pool_tests` / `test_leak_tests` / `test_leak_pool` | T7: `tests/test_pool.mojo` 新設 + `test_leak.mojo` に 2 ループ | **≥ 14 / ≥ 22 / ≥ 2**（T7。leak 現在 20） |
| `readme_array_optional_row` / `readme_array_word` / `readme_copy_example` / `readme_pool_example` / `readme_thread_unsafe` / `readme_en_arrays` | T8: 型表の配列行、クイックスタート 2 節、既知の制限、英語要約 | **≥ 2 / ≥ 8 / ≥ 2 / ≥ 2 / ≥ 2 / ≥ 1**（T8。現在 0 / 1 / 0 / 0 / 0 / 0） |
| `readme_out_of_scope_line` | T8: 「配列型・`COPY`・コネクションプールは対象外です」を外す | **0**（T8。現在 1） |
| `readme_19_types` / `readme_h2` | README の「19 の型」（スカラの型数。真のまま）と `##` 節数は不変（新節は `###`） | **1 / 11**（不変） |
| `changelog_phase7` / `changelog_phase_lines` | T8: `[Unreleased]` に `- Phase 7:` 1 行 | **≥ 1 / 7**（T8。現在 6） |
| `init_docstring_phase7` / `init_docstring_copy_in` | T8: `__init__.mojo` 冒頭の Phase 列挙 + `## COPY` / `## Connection pool` 節 | **≥ 1 / ≥ 2**（T8） |
| `examples_copy` / `examples_pool` / `examples_params_any` / `examples_copy_next` | T8: 新 examples 2 本 + `params.mojo` に `= ANY($1)` | **exists / exists / ≥ 1 / ≥ 1**（T8） |
| `pixi_example_tasks` / `final_check_examples` | T8: `pixi.toml` の `example-copy` / `example-pool`、`final_check.sh` 4/6 に 2 行 | **7 / 7**（T8。現在 5 / 5。P26） |
| `examples_mojo_count` / `test_file_count` / `src_mojo_count` | 件数: examples 7 → 9、tests 24 → 28、src 20 → 22 | **9 / 28 / 22**（T8 / T7 / T7） |
| `src_def_ref_return` / `src_iterator_in_copy` / `tests_sh_bash4_only` | 不変: `ref` を返さない（REQ §2.3）/ `CopyOut` は `Iterator` にしない（決めた事項 7）/ sh は bash 3.2 互換 | **0 / 0 / 0**（不変） |

## Tasks

順序は 配列（T2〜T5）→ COPY（T6）→ Pool（T7）→ 文書・examples（T8）→ 最終判定（T9）。T1 は全部の土台（FFI / `reset` / `_transaction_parts` / TRACE / 格子）。
各タスクの完了基準は「`pixi run check` 6/6 PASS（既存テストの期待値変更 0 件）+ 自タスクのチェックリスト行が期待値 + PROGRESS の最新ターン節 40 行以内」を共通に含む（以下では省略）。
陽性対照は「実装前に走らせて赤を見る」か「検査を外したコピー（scratch）で赤を見る」のどちらかで、**判別しなかった対照はそう書いて差し替える**（Phase 5 reflect）。

- [x] T1: 土台 — FFI 3 関数 + `Connection.reset()` + `_transaction_parts` 分離 + TRACE.md + 堅牢性格子スクリプト
  - 完了基準:
    - (a) `src/pq/_ffi/functions.mojo` に `PQputCopyData: def(PGconnPtr, CStr, c_int) thin abi("C") -> c_int  # libpq-fe.h:547`、
      `PQputCopyEnd: def(PGconnPtr, Int) thin abi("C") -> c_int  # libpq-fe.h:548（errormsg は 0 = NULL。決めた事項 2）`、
      `PQgetCopyData: def(PGconnPtr, Pointer[Int, MutUntrackedOrigin], c_int) thin abi("C") -> c_int  # libpq-fe.h:549` の 3 フィールド + `_dl_sym`（`functions.mojo:186-366` の形。
      雛形 `turn-001-probe-copy.mojo:56-75`）。`tests/test_ffi.mojo` に「3 シンボルが解決され非 0」の 1 件（既存の形に倣う）
    - (b) `Connection.reset(self) raises PgError`（決めた事項 3。P19）: `PQreset` → `PQstatus != CONNECTION_OK` なら `CONNECTION`（`PQerrorMessage`）→ `self.execute(_SESSION_SETUP_SQL)`。docstring に
      「健全な接続に呼んでも接続し直す（`backend_pid` が変わる）」「サーバー側の prepared statement は消える（手元の `PreparedStatement` の `DEALLOCATE` は失敗して黙殺される）」。
      テスト 2 件（`tests/test_connection.mojo`、雛形 `:141` `_connect` / `:177` `_open_error` の `raises PgError` → `Error` 変換）:
      ① 第 2 接続から `pg_terminate_backend(pid)` → `execute` が `CONNECTION` → `reset()` → `SHOW DateStyle` が `ISO, YMD`、`backend_pid` が変わる、`row.get[Date]`（text）が通る、`status() == CONNECTION_OK`;
      ② 健全な接続に `reset()` → `backend_pid` が変わり `execute` が通る。**陽性対照**: ① で `_SESSION_SETUP_SQL` の再送を外したコピーは `SHOW DateStyle` = `ISO, MDY`（RESEARCH §2.5 実測）
    - (c) `Connection._transaction_parts(self) raises PgError`（`connection.mojo:758-776` の検査 2 つ + `execute("BEGIN")`）に切り出し、`transaction()` は parts + 構築だけ（`_prepare_parts` と同型、`:496-511` の理由をそのまま docstring に）。
      `tests/test_transaction.mojo` 13 件の期待値変更 0
    - (d) `.gsd-lite/TRACE.md` 新設（節: 「チェックリスト（turn 3）」= 全 77 key の生値、「`check` の所要」、「PLAN 訂正（turn N）」は必要時）
    - (e) 堅牢性格子スクリプト `scratch/turn-003-robust-grid.sh`（雛形: `.gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-012-robust-regress.sh` の `run_pipe` / `run_epipe` / `report()` を写す。REQ §2.4 / D2）。
      3 軸を**コメントでなく配列変数で**列挙: 入力（conninfo 空 / `postgresql://` URI / 100 KB / 存在しない DB / 不正 conninfo）× 出力（`/dev/full` / 閉じた fd 1 / `> >(exit 0)` の EPIPE）× 依存（`PQ_MOJO_LIBPQ=libc.so.6` / サーバー無し port 54398 / blackhole 54399 / badpw）。
      対象は examples 全本（`copy.mojo` / `pool.mojo` は T8 で足す行を **今から列挙して `absent` 扱い**）。T1 では既存 5 本で 1 回回して `unhandled_markers=0`（rc 141 は Phase 5 の既知）をログ `turn-003-robust-grid.log` に残す。
      今回の「入力」軸の追加分（配列リテラルの不正形 / バイナリヘッダ不正 / COPY 途中切断 / プール枯渇・死んだ接続）は**単体・サーバーテスト側**（T2 / T3 / T6 / T7）が担う旨をスクリプト冒頭に書く
    - (f) `check` を 1 回回し基線の所要を TRACE に（見積もり節の母数）
  - 対象: `src/pq/_ffi/functions.mojo`, `src/pq/connection.mojo`, `tests/test_ffi.mojo`, `tests/test_connection.mojo`, `.gsd-lite/TRACE.md`, `scratch/turn-003-robust-grid.sh`
  - 依存: なし
  - 並列サブ作業: なし（推奨 0 本）

- [x] T2: 配列 OID 表 + テキスト配列リテラルの tokenizer + `decode_text` の 34 分岐 + 単体テスト（テキスト側）
  - 完了基準:
    - (a) `src/pq/decode_text.mojo` に `OID_*_ARRAY` 21 個（`decode_text.mojo:34-94` の `OID_*` の直後。値は RESEARCH §2.1: bool 1000 / bytea 1001 / name 1003 / int8 1016 / int2 1005 / int4 1007 / text 1009 / json 199 / float4 1021 / float8 1022 /
      bpchar 1014 / varchar 1015 / date 1182 / time 1183 / timestamp 1115 / timestamptz 1185 / interval 1187 / timetz 1270 / numeric 1231 / uuid 2951 / jsonb 3807）、
      `_array_elem_oid(array_oid: UInt32) -> UInt32`（未知は 0）、`_array_oid_of(elem_oid: UInt32) -> UInt32`（未知は 0）。両方向を 21 行ずつ単体テスト（表の転記ミス防止）
    - (b) `parse_array_literal(text: String) raises PgError -> List[Optional[String]]`（決めた事項 5。RESEARCH §3-1 の tokenizer）: 先頭が `[` なら `=` まで捨てる → `{` → 要素（`"…"` は `\x` → `x` の unescape、裸は前後空白 trim、裸の `NULL`（大小無視）は None、`{` のネスト = `TYPE_MISMATCH`（メッセージに `multidimensional`））→ `,` / `}` → `}` の後に空白以外が残れば `TYPE_MISMATCH`。
      `{}` は空 `List`。P7 の 9 件（`{1,2` / `{"abc}` / `{1,,2}` / `{1,2}}` / `1,2` / `` / `{` / `}` / `{"a`）が全部 `TYPE_MISMATCH` で raise し無限ループしない（各ケースに `_error_kind` の単体テスト）。`'{ 1 , 2 }'` は `["1","2"]`
    - (c) `_decode_text_array[E: Copyable](text: String, oid: UInt32, expect_oid: UInt32, elem_oid: UInt32, type_name: StaticString) raises PgError -> List[Optional[E]]`:
      `oid != expect_oid` → `TYPE_MISMATCH`（メッセージに両 OID と `type_name`。P5）→ `parse_array_literal` → 要素ごとに `decode_text[E](elem, elem_oid)`、失敗は `array element N: <元メッセージ>`（N は 0 始まり。決めた事項 6。P8）。
      `_require_no_nulls[E](var elems: List[Optional[E]]) raises PgError -> List[E]`（None があれば `NULL_VALUE` `array element N is NULL`）
    - (d) `decode_text[T]`（`:211-`）に `List[E]` 17 + `List[Optional[E]]` 17 の分岐を **1 行ずつ**（`elif T == List[Int32]: return rebind[T](_require_no_nulls(_decode_text_array[Int32](text, oid, OID_INT4_ARRAY, OID_INT4, "int4[]"))).copy()` の形。probe-lang A）。
      `List[String]` / `List[Optional[String]]` は 6 配列 OID（1009 / 1015 / 1014 / 1003 / 199 / 3807）を受け、要素 OID は `_array_elem_oid(oid)` を渡す（スカラ `String` の wildcard と同じ）。
      既存 `List[UInt8]`（`:285`）の分岐は不変。**`String` の wildcard（`:283`）は不変**: 配列列を `get[String]` するとリテラルがそのまま返る（REQ §4.1）
    - (e) `tests/test_decode_array.mojo` 新設（サーバー不要。雛形 `test_decode_text.mojo:10-80` の `_ok` / `_error_kind` / `_error_message`）。RESEARCH §2.2 の実測文字列を期待値に: text[] 9 要素 `{a,"b,c","d\"e","f\\g","","NULL","null"," x ","{y}"}` → 9 要素（P6）、
      `{a,NULL,b}` → `List[Optional[String]]` で `[a, None, b]` / `List[String]` で `NULL_VALUE`、`{"\\x00ff","\\x"}` → `List[List[UInt8]]` で `[[0,255],[]]`、`{"ab   ",cde}`（1014）で padding 保持、`{NaN,Infinity,-Infinity,1.50}`（1231）、`{NaN,Infinity,-Infinity,0,1e+300}`（1022）、
      `{"2024-01-02 03:04:05",infinity,-infinity}`（1115）、`{t,f}`（1000）、`{2024-02-29,"0001-01-01 BC"}`（1182）、`{{1,2},{3,4}}` → `TYPE_MISMATCH`、`[0:1]={7,8}` → `[7,8]`（P4）、`{}` / `{{}}`（サーバー出力は `{}`）→ 空、
      `{1,2}` を 1005 で `List[Int32]` → `TYPE_MISMATCH`（P5）、`{1,a,3}` のメッセージに `array element 1`（P8）、`Int` と `Int64` の両方で 1016 を読める。**≥ 18 件**
  - 対象: `src/pq/decode_text.mojo`, `tests/test_decode_array.mojo`
  - 依存: T1
  - 並列サブ作業: なし（推奨 0 本。tokenizer と分岐は同じファイル）

- [x] T3: バイナリ配列デコーダ + `decode_binary` の 34 分岐 + 単体テスト（バイナリ側）
  - 完了基準:
    - (a) `src/pq/decode_binary.mojo` に `_decode_binary_array[origin: ImmOrigin, //, E: Copyable](bytes: Span[UInt8, origin], oid: UInt32, expect_oid: UInt32, elem_oid: UInt32, type_name: StaticString, column: Int) raises PgError -> List[Optional[E]]`
      （RESEARCH §3-2 の検査を**この順で**）: `oid != expect_oid` → `TYPE_MISMATCH`; `len < 12` → `TYPE_MISMATCH`; `ndim` / `flags` / `elemtype` を読む; `flags ∉ {0,1}` → `TYPE_MISMATCH`（P1）; `elemtype != elem_oid` → `TYPE_MISMATCH`（メッセージに両 OID。P5 / P2）;
      `ndim == 0` → 空（**dims を読まない**。P2）; `ndim < 0 or ndim >= 2` → `TYPE_MISMATCH`（`multidimensional`）; `dim` / `lbound` を読む（lbound は捨てる。P4）; `dim < 0` → `TYPE_MISMATCH`; 要素ごとに `int32 len`: `-1` → None、`len > 残り` → `TYPE_MISMATCH`（P3）、
      それ以外 `decode_binary[E](bytes[p:p+len], elem_oid, column)`（jsonb の version byte / 固定長検査は既存が行う）、失敗は `array element N: <元>`; 全要素の後に残りバイト → `TYPE_MISMATCH`（P3）。`List[String]` は 6 配列 OID
    - (b) `decode_binary[T]`（`:865-`）に 34 分岐（T2 (d) と同型。`column` を渡す）。既存 `List[UInt8]`（`:904`）/ `String`（`:900`）不変
    - (c) `tests/test_decode_array.mojo` にバイナリ側 **≥ 14 件**。RESEARCH §2.3 の hex を期待値に（`test_decode_binary.mojo` の hex → `List[UInt8]` 変換ヘルパを流用）: `ARRAY[1,2,3]::int4[]` の 11 ワード、`'{}'::int4[]` の 12 byte（P2）、`ARRAY[1,NULL,3]` の `ffffffff`（flags 1）と **flags 0 + `ffffffff`**（P1。`List[Optional[Int32]]` で `[1,None,3]`、`List[Int32]` で `NULL_VALUE`）、
      flags 2 → `TYPE_MISMATCH`、elemtype 25 を 1007 で → `TYPE_MISMATCH`（P2）、11 byte → `TYPE_MISMATCH`、dim 3 で要素 2 個 / 要素 len 5 の int4 / 末尾 +1 byte → `TYPE_MISMATCH`（P3）、ndim 2 → `TYPE_MISMATCH`、lbound 0 → `[7,8]`（P4）、
      text[] 9 要素（空文字は len 0）、`ARRAY['tab\there','é',NULL]`、numeric 12 byte 要素、bpchar padding 5 byte、**jsonb 要素の version byte `01`**（`decode_binary[String](…, 3802)` で剥がれる）、interval 16 byte、bool / bytea。`{1,2}`（1005 の payload、elemtype 21）を `List[Int32]` → `TYPE_MISMATCH`
  - 対象: `src/pq/decode_binary.mojo`, `tests/test_decode_array.mojo`
  - 依存: T2
  - 並列サブ作業: なし（推奨 0 本）

- [x] T4: 配列エンコーダ + `Param` の `@implicit` 34 本 + 単体テスト + `List[String]` → `varchar[]` のサーバー確認
  - 完了基準:
    - (a) `src/pq/encode_binary.mojo` に `encode_array(elems: List[Optional[List[UInt8]]], elem_oid: UInt32) -> List[UInt8]`（決めた事項 8。RESEARCH §3-3）: 空なら `ndim 0, flags 0, elemtype`（12 byte）、それ以外 `ndim 1, flags = (None があれば 1), elemtype, dim = len, lbound 1`、要素は `int32 len + bytes`、None は `ffffffff`。
      単体テスト（`tests/test_encode_binary.mojo`、≥ 3 件）: `[1,2,3]` int4 が RESEARCH §2.3 の hex と一致、空が 12 byte、`[1,None,3]` が flags 1 + `ffffffff`
    - (b) `src/pq/params.mojo` に `@implicit def __init__(out self, var v: List[E])` 17 本 + `List[Optional[E]]` 17 本（`:354-365` の `List[UInt8]` の次。probe-lang B の形）。OID は `_array_oid_of` 系の定数（`List[Int]` / `List[Int64]` → 1016 / 要素 20、`List[String]` → **1009 / 要素 25**（決めた事項 9。P9）、`List[List[UInt8]]` → 1001 / 17）、
      `_binary = True`、要素は既存 `encode_*`（`encode_binary.mojo:68-274`）/ `String` は `_text_bytes`（`params.mojo:97`）/ `List[UInt8]` は生バイト。docstring に「`text[]` として送る。`varchar[]` / `jsonb[]` 列へはサーバーの配列キャスト」
    - (c) `tests/test_params.mojo` に ≥ 4 件（既存 33 件の期待値変更 0。P10）: `test_param_oids_of_the_extended_types`（`:534`）と同型に配列 OID / `is_binary()` の表 34 行、`[ids^, "a", Param.null()]` の literal が通る（P10。`^` 必須）、
      `SELECT $1::varchar[]` / `INSERT INTO <temp>(v varchar[]) VALUES ($1)` / `SELECT $1::jsonb[]` が通る（**P9 の未実測。impl の最初に 1 回**。通らなければ TRACE に記録し `List[String]` を `Param` の `oid` 引数付き ctor で送る案に切り替え、PLAN 訂正として 1 行）、
      `List[String]` に NUL を含む要素 → サーバーが `SERVER`（sqlstate を実測して TRACE に。決めた事項 10 の確認）
    - (d) 陽性対照: (c) の OID 表で 1 本の OID を故意に変えた scratch コピーが FAIL する（表の転記が検査されていることの証明）
  - 対象: `src/pq/encode_binary.mojo`, `src/pq/params.mojo`, `tests/test_encode_binary.mojo`, `tests/test_params.mojo`
  - 依存: T2
  - 並列サブ作業（推奨 1 本）:
    - A（親）: `encode_binary.mojo` + `params.mojo` + P9 のサーバー確認
    - B: `tests/test_encode_binary.mojo` の 3 件 + `tests/test_params.mojo` の 4 件（PLAN の (a)(b) のシグネチャと OID 表を依頼文に写す。親の待ち合わせファイル名は書かない）

- [x] T5: `tests/test_array.mojo` — サーバー格子（受信 17 型 × text / binary × `List` / `List[Optional]`、境界値、送信往復、`= ANY($1)`）
  - 完了基準（REQ §4.1 + RESEARCH §5-8。**≥ 14 件**。雛形 `tests/test_binary.mojo:699` `test_binary_scalars_match_text` の「text と binary で同じ値」の形）:
    - (a) 17 要素型（`Bool` / `Int16` / `Int32` / `Int64` / `Int` / `Float32` / `Float64` / `String` ×6 OID / `List[UInt8]` / `Decimal` / `UUID` / `Date` / `Time` / `TimeTz` / `Timestamp` / `TimestampTz` / `Interval`）それぞれ `SELECT ARRAY[...]::<type>[]` を `execute(sql)`（text）と `execute(sql, [], result_format=BINARY)` で取得し `List[T]` が一致。
      要素に Phase 3 の境界値（`test_binary.mojo:776,807` の最小 / 最大 / 0 / 負数 / NaN / ±Infinity / `infinity` 日時 / numeric の大きな桁）
    - (b) `'{}'::int4[]` → 空（両形式）、`ARRAY[1,NULL,3]` → `List[Optional[Int32]]` で None / `List[Int32]` で `NULL_VALUE`（両形式）、`get_optional[List[Optional[Int32]]]` で列 NULL と要素 NULL の両立
    - (c) `'{1,2}'::int2[]` を `List[Int32]` → `TYPE_MISMATCH`（両形式。P5）、`int8[]` を `List[Int]` と `List[Int64]` の両方で、`varchar[]` / `name[]` / `bpchar[]` / `json[]` / `jsonb[]` を `List[String]` で（6 OID）
    - (d) `ARRAY[[1,2],[3,4]]` → `TYPE_MISMATCH`（両形式、メッセージに `multidimensional`）、`'[0:1]={7,8}'::int4[]` → `[7,8]`（両形式。P4）、配列列を `get[String]`（text）→ リテラルそのまま `{1,NULL,3}` / `[0:1]={7,8}`（REQ §4.1）、binary の `get[String]` → `TYPE_MISMATCH`（現行どおり）
    - (e) 送信往復 17 型: `SELECT $1::<type>[]` に `List[T]` を渡して `List[T]` で読み戻し一致（`List[Optional[T]]` で None 混じりも）、空 `List[Int32]` → `{}`、`SELECT 2 = ANY($1)`（`List[Int32]`）→ `t`、`'b,c' = ANY($1)`（`List[String]`、要素に `,` / `"` / `\` / 空 / `NULL` 文字列）→ `t`（RESEARCH §2.3 p）
    - (f) 既存 `test_binary` 14 件 / `test_params` の期待値変更 0。両サーバー（54317 / 54314）で PASS
  - 対象: `tests/test_array.mojo`
  - 依存: T3, T4
  - 並列サブ作業: なし（推奨 0 本。テスト 1 ファイルのみ、親が直接書く）

- [x] T6: `src/pq/copy.mojo`（`CopyIn` / `CopyOut`）+ `Connection` / `Transaction` / `PreparedStatement` の結線 + `_check_not_copying` + `tests/test_copy.mojo`
  - 完了基準:
    - (a) `src/pq/copy.mojo` 新設（決めた事項 11〜13）: `struct CopyIn[origin: ImmOrigin](Movable)`（`_conn: Pointer[Connection, origin]`, `_done: Bool`, `_handler: def(PgError) thin`）に
      `write(mut self, bytes: Span[UInt8]) raises PgError` / `write(mut self, s: String) raises PgError`（`s.as_bytes()` で前者へ）/ `finish(mut self) raises PgError -> Result` / `abort(mut self, var message: String) raises PgError` / `__deinit__`。
      `struct CopyOut[origin: ImmOrigin](Movable)`（同 3 フィールド）に `next(mut self) raises PgError -> Optional[List[UInt8]]` / `__deinit__`。**`Iterator` / `Iterable` は付けない**（決めた事項 7）。
      モジュール関数 `_drain_results(pq, conn)`（`PQgetResult` が NULL まで `PQclear`）と `_copy_final_result(pq, conn) raises PgError -> Result`（`PQgetResult` → `adopt_result`、`SERVER` かつ `sqlstate == ""` は `CONNECTION` に倒す（RESEARCH §2.4 (d)。P11）→ `_drain_results`（P15））
    - (b) 動作: `write` は `PQputCopyData` が `1` 以外（`-1`、同期では `0` は来ない）→ `CONNECTION`（`PQerrorMessage` 1 回だけ）+ `_done = True`（以後の `write` / `finish` / `abort` は `USAGE` `COPY already finished`、`__deinit__` は何もしない。P11）。
      `finish` = `PQputCopyEnd(0)`（`-1` → `CONNECTION` + `_done`）→ `_copy_final_result` → `_done = True`（`affected_rows()` = `cmdTuples`）。`abort(msg)` = `PQputCopyEnd(msg)` → `_copy_final_result` を try: sqlstate `57014` は飲む、それ以外は上げる（RESEARCH §3-6）→ `_done`。
      `CopyIn.__deinit__`: `_done` でなければ `PQputCopyEnd("aborted by pq")` → 結果を読み `57014` 以外の失敗は `_handler` へ（`Transaction.__deinit__` `transaction.mojo:159-223` と同じ分類）→ drain。
      `CopyOut.next`: `PQgetCopyData(async=0)`: `> 0` → `List[UInt8]`（雛形 `probe-copy.mojo:97-123`。`PQfreemem` 必須）、`-1` → `_copy_final_result`（結果は捨てる）+ `_done` → None、`-2` → `CONNECTION` + `_done`、`0` → `CONNECTION`（同期では来ない。防御）。
      `CopyOut.__deinit__`: `_done` でなければ `PQgetCopyData` を `≤ 0` まで読み捨て → `-1` なら `_copy_final_result` の失敗を `_handler` へ、`-2` なら `PQerrorMessage` を `CONNECTION` で `_handler` へ（P17）
    - (c) `Connection`（`connection.mojo`）: `_check_not_copying(self) raises PgError`（`PQtransactionStatus == PQTRANS_ACTIVE` → `USAGE` `a COPY is in progress on this connection`。決めた事項 14。P13）を `execute`（`:258` / `:307`）/ `prepare`（`:428`）/ `_transaction_parts` / `_copy_in_parts` / `_copy_out_parts` の先頭に、
      `PreparedStatement.execute`（`prepared.mojo:131`）の先頭に `self._conn[]._check_not_copying()`。`_copy_in_parts(self, var sql: String) raises PgError`: `_reject_nul` → `_check_not_copying` → `PQexec` → status が `PGRES_COPY_IN` なら `PQclear` して return；`PGRES_COPY_OUT` なら**その場で drain**（`PQgetCopyData` を `≤ 0` まで + `_drain_results`）して `USAGE` `copy_in() requires a COPY ... FROM STDIN statement (result status 3)`（P14）；
      `TUPLES_OK` / `COMMAND_OK` なら `PQclear` + drain して `USAGE`（status N）；それ以外は `_take_result` に渡して `SERVER` / `CONNECTION`（`42P01` 等は `USAGE` でなく `SERVER`）。`_copy_out_parts` は鏡像（`COPY_IN` を受けたら `PQputCopyEnd("wrong direction")` + drain → `USAGE`）。
      `copy_in(ref self, var sql) raises PgError -> CopyIn[origin_of(self)]` = parts + `CopyIn[origin_of(self)](Pointer(to=self), self._rollback_failure_handler)`。`copy_out` 同型。
      `Transaction.copy_in(self, var sql) raises PgError -> CopyIn[Self.origin]` / `copy_out`（`_check_open` → parts → `CopyIn[Self.origin](self._conn, self._handler)`。`transaction.mojo:449-481` `prepare` と同型。P16）。
      `connection.mojo:266-269` の docstring を「`COPY ... FROM STDIN` / `TO STDOUT` は `copy_in` / `copy_out` で。`execute` に渡すと `USAGE`（方向違いの検出と同じ経路で drain される）」に書き換え（REQ §4.4。`execute(sql)` が COPY 文を受けた場合の挙動は変えない: libpq の `PGRES_COPY_IN` 結果は `adopt_result` が `SERVER` `unexpected result status 4` にする現行のまま。ただし接続が COPY 状態で残るので、**`execute(sql)` でも status 3 / 4 を見たら drain してから raise する**（P14 の派生。`_take_result` の前に 1 分岐））。
      `src/pq/__init__.mojo` に `from .copy import CopyIn, CopyOut`
    - (d) `tests/test_copy.mojo` 新設（**≥ 18 件**。REQ §4.2 の全項目 + RESEARCH §4）: ① text 10 万行（`int4, int8, float8, text, timestamp` の 5 列、`probe-copy` と同じ生成式、1,000 行ずつ `write`）→ `finish().affected_rows() == 100000`、`SELECT count(*)` 一致、所要を PROGRESS に；
      ② CSV（`WITH (FORMAT csv)`）1 件往復；③ binary（PGCOPY ヘッダ `PGCOPY\n\377\r\n\0` + int32 flags 0 + int32 ext 0 + 行（int16 列数 + 各 int32 len + bytes。既存 `encode_int32` 等を使う）+ `ffff` トレーラ）1 件往復；
      ④ `copy_out` で ① のテーブルを取り出し、行数 100000・末尾 `\n` 込みの各行バイト列が `copy_in` に渡した連結と一致（RESEARCH §2.4 case 2: 4,522,225 byte）；
      ⑤ `abort("test")` → 行 0、`transaction_status() == IDLE`、次の `execute` が通る；⑥ `finish` なしで drop → 行 0、次の `execute` が通る（`__deinit__` 経路。handler が呼ばれない = 57014 を飲んだ証明）；⑦ `copy_out` を 1 行で drop → 次の `execute` が通る（10 万行で所要を記録。P17）；
      ⑧ USAGE 格子（P13。陽性対照つき）: COPY IN で 2 行書いた後 `conn.execute("SELECT 1")` / `execute("SELECT 1", [])` / `prepare` / `transaction()` / `copy_in` / `copy_out` / 事前に作った `PreparedStatement.execute` の 7 件が `USAGE`（`a COPY is in progress`）で、その後 `finish()` が **2 行**を数える。
      **陽性対照**: `_check_not_copying` を no-op にした scratch コピーで `finish()` の行数が 0（probe-copy case 5 の再現）；
      ⑨ 不正行 `1\t2\n` + 正常行 → `finish()` が `SERVER` / sqlstate `22P04`、`count(*)` 不変、`transaction_status() == IDLE`、次の `execute` が通る（P12）；
      ⑩ 途中切断（`external_call["close"]` で `PQsocket` を閉じる。`test_leak.mojo` / Phase 5 `probe-closefd.mojo` の形）: COPY IN で `write` が `CONNECTION`、2 回目の `write` / `finish` が `USAGE`、トレースバック無し；COPY OUT で 1 行読んでから閉じる → `next()` がバッファ分の後 `CONNECTION`（P11。RESEARCH §2.4 6a / 6b）；
      ⑪ `copy_in("COPY t FROM STDIN; SELECT 42")` → `finish().affected_rows() == 1`（1 行書いた場合）、次の `execute` が通る（P15）；⑫ 方向違い: `copy_in("COPY t TO STDOUT")` → `USAGE`、直後の `execute` が通る；`copy_out("COPY t FROM STDIN")` → `USAGE`、同じ；`copy_in("SELECT 1")` → `USAGE`；`copy_in("COPY nonexistent FROM STDIN")` → `SERVER` `42P01`（P14）；
      ⑬ `Transaction` 内: `var tx = conn.transaction(); var c = tx.copy_in(...); c.write(...); _ = c.finish(); tx.commit()` で行が残る / `tx.rollback()` で残らない（REQ §4.2）；⑭ 順序違い（`tx` の最後の使用が `c` より先 → `ROLLBACK` が COPY を中止）でもトレースバック無し・handler ≥ 1・その後の `execute` が通る（P16。`set_rollback_failure_handler` で数える。雛形 `test_transaction.mojo:700,1047`）；
      ⑮ `execute("COPY t FROM STDIN")` / `execute("COPY t TO STDOUT")` → `SERVER` `unexpected result status 4` / `3` のあと次の `execute` が通る（(c) の drain）；⑯ 既存 `test_transaction` 13 / `test_prepared` 14 / `test_connection` の期待値変更 0。6/6 段に `WARNING:` 0（`abort` の `57014` はエラーであって WARNING ではない: RESEARCH §2.4 case 3）
  - 対象: `src/pq/copy.mojo`, `src/pq/connection.mojo`, `src/pq/transaction.mojo`, `src/pq/prepared.mojo`, `src/pq/__init__.mojo`, `tests/test_copy.mojo`
  - 依存: T1（T5 とは独立だが順序どおり T5 の後）
  - 並列サブ作業（推奨 1 本）:
    - A（親）: `copy.mojo` + `connection.mojo` / `transaction.mojo` / `prepared.mojo` / `__init__.mojo`
    - B: `tests/test_copy.mojo` の ①〜⑮（(a)(b) のシグネチャと USAGE 文言を依頼文に写す。親のファイル名・待ち合わせ条件は書かない。`fmt` は親が統合後）

- [ ] T7: `src/pq/pool.mojo`（`Pool` / `PooledConnection` / `_Slot`）+ `tests/test_pool.mojo` + `test_leak.mojo` の 2 ループ
  - 完了基準:
    - (a) `src/pq/pool.mojo` 新設（決めた事項 15〜19。雛形 `probe-pool.mojo:53-174`）: `struct _Slot(Movable)`（`conn: Connection`, `opened_at: Int`）、
      `struct Pool(Movable)`: フィールド `_pq`, `_conninfo: String`, `_params: Dict[String, String]`, `_use_params: Bool`, `_max_size: Int`, `_max_lifetime_s: Int`, `_idle: List[_Slot]`, `_borrowed: List[Int]`（1 要素セル）, `_closed: List[Int]`（1 要素セル）, `_handler: def(PgError) thin`。
      `@staticmethod open(var conninfo: String, max_size: Int, *, min_size: Int = 0, max_lifetime_s: Int = 0) raises PgError -> Pool` と `open(params: Dict[String, String], max_size: Int, *, min_size: Int = 0, max_lifetime_s: Int = 0)`（`Connection.open` `connection.mojo:168,201` の 2 オーバーロードに揃える）。
      検査（`USAGE`、サーバーに接続しない）: `max_size <= 0` `max_size must be positive (got N)` / `min_size < 0 or min_size > max_size` `min_size must be between 0 and max_size (got N)` / `max_lifetime_s < 0` `max_lifetime_s must not be negative (got N)`。`min_size` 本を**局所の `List[_Slot]` に**開いてから `Pool` に入れる（失敗は raise、deinit が `PQfinish`。P24）。
      `acquire(ref self) raises PgError -> PooledConnection[origin_of(self)]`: `_closed` → `USAGE` `pool is closed`；idle があれば pop → `_is_alive` でなければ `conn.reset()`、それも失敗なら捨てて新規；idle が無ければ `size() < max_size` なら `_open_one()`、達していれば `USAGE` `pool exhausted: all N connections are borrowed`（D13）；`_borrowed[0] += 1`。
      `_is_alive(conn: Connection) -> Bool` = `PQstatus == CONNECTION_OK` かつ `PQconsumeInput` を **2 回**呼んで両方 `1`（RESEARCH §2.5: 1 回目は FATAL を消費して 1、2 回目で 0。往復なし・非ブロッキング。決めた事項 17）。
      `_release(self, var conn: Connection, opened_at: Int)`（判定順 = RESEARCH §3-8 + 決めた事項 18）: `_borrowed[0] -= 1` → `_closed` なら捨てる → `PQtransactionStatus` が `INTRANS` / `INERROR` なら `conn.execute("ROLLBACK")`（失敗は `conn._rollback_failure_handler(e)` へ + 捨てる。P25）→
      `PQstatus != OK` or `PQtransactionStatus != IDLE`（`ACTIVE` / `UNKNOWN`）→ 捨てる → `max_lifetime_s > 0` かつ `(monotonic() - opened_at) // 1_000_000_000 >= max_lifetime_s` → 捨てる（P23）→ `_is_alive` でなければ捨てる → `_idle.append(_Slot(conn^, opened_at))`。
      「捨てる」= `_ = conn^`（`Connection.__deinit__` が `PQfinish`）。内部状態の書き換えは `ref self` のまま `Pointer[List[_Slot], MutUntrackedOrigin](unsafe_from_address=Int(Pointer(to=self._idle)))` 型（`probe-pool.mojo:72-80` / `_next_stmt_name` `connection.mojo:422-424`。P21）。
      `close(mut self)`: idle を全部捨て `_closed[0] = 1`。`__deinit__` は書かない（`List[_Slot]` の deinit が各 `Connection` を `PQfinish`。RESEARCH §0 発見 5）。`size()` = `len(_idle) + _borrowed[0]` / `idle()` / `borrowed()`。
      `set_rollback_failure_handler(mut self, handler: def(PgError) thin)`: 以後 `_open_one` する接続と**今 idle の接続**に `Connection.set_rollback_failure_handler` を適用（貸し出し中は対象外と docstring）。
      struct docstring の冒頭に「**単一スレッド前提、ロックなし、スレッド安全ではない**」（D12。README にも）
    - (b) `struct PooledConnection[origin: ImmOrigin](Movable)`（`_pool: Pointer[Pool, origin]`, `_conn: Connection`, `_opened_at: Int`）: `__deinit__(deinit self)` → `self._pool[]._release(self._conn^, self._opened_at)`。
      転送（REQ §2.3 の 11 本、`Connection` と同じシグネチャ・docstring は「`Connection.X` に委譲」1 行 + 違いだけ）: `execute(sql)` / `execute(sql, params, result_format)` / `escape_literal` / `escape_identifier` / `server_version` / `status` / `transaction_status` は直接転送。
      origin 付きの 4 本は `_conn_ptr(ref self) -> Pointer[Connection, origin_of(self)]`（`probe-pool.mojo:155-161` の rebind。RESEARCH §0 発見 6）で組む: `transaction(ref self) -> Transaction[origin_of(self)]` = `self._conn._transaction_parts()` + `Transaction[origin_of(self)](self._conn_ptr(), self._conn._rollback_failure_handler)`、
      `prepare(ref self, var sql, param_types = List[UInt32]()) -> PreparedStatement[origin_of(self)]` = `_prepare_parts` + 構築、`copy_in(ref self, var sql) -> CopyIn[origin_of(self)]` = `_copy_in_parts` + 構築、`copy_out` 同型。`ref` / `Connection` そのものは返さない。
      `src/pq/__init__.mojo` に `from .pool import Pool, PooledConnection`
    - (c) `tests/test_pool.mojo` 新設（**≥ 14 件**。REQ §4.3 の 9 項目 + P20 (a)(b) + P22 + P25 + 白箱 1 件。D18: `backend_pid` と `pg_stat_activity`。conninfo に **`application_name=pq_test_pool`** を足し、
      本数は `SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND application_name = 'pq_test_pool'` を**別の接続**（application_name 無し）で数える。`pg_sleep(0.05)` を 1 回挟んでから数える（切断の反映待ち））:
      ① `max_size=2`: `acquire` ×2 成功（pid が異なる）、3 回目 `USAGE`（`pool exhausted`）、`pg_stat_activity` = 2、`size() == 2 / idle() == 0 / borrowed() == 2`；1 本 drop → `idle() == 1` → `acquire` の pid が drop した方と一致（再利用）；
      ② `min_size=2`: `open` 直後 `idle() == 2`、`size() == 2`、`pg_stat_activity` = 2、`borrowed() == 0`；③ `transaction()` を commit せず drop（`Transaction` が先に ROLLBACK）→ 次の利用者 `transaction_status() == IDLE`、`CREATE TEMP TABLE` が消えている（`42P01`）；
      ④ 生 `execute("BEGIN")` + `CREATE TEMP TABLE` → guard drop → **プールの `ROLLBACK` 経路**（`_release` の `INTRANS`）→ 次の利用者 IDLE、temp table 無し、`size()` 不変、pid 同じ（probe-pool C）；
      ⑤ `copy_in` を未完了のまま guard drop → `CopyIn.__deinit__` が先に中止（RAII の順序）→ 行 0、次の `acquire` は**同じ pid**（再利用）で `execute` が通る、`size()` 不変（決めた事項 20。REQ §4.3 の文言との差を docstring / README に）；
      ⑥ 白箱: `guard._conn._pq[].PQexec(guard._conn._conn, "COPY t FROM STDIN")` で COPY 状態を作って drop → `_release` の `ACTIVE` 分岐で捨てられ `size()` が 1 減り、次の `acquire` は新 pid（D15 の `ACTIVE` 分岐の証明）；
      ⑦ 貸し出し中に第 2 接続から `pg_terminate_backend` → `execute` が `CONNECTION` → drop → `size()` −1 → 次の `acquire` は新 pid で `execute` が通る（P20 (a)）；
      ⑧ terminate → `pg_sleep(0.05)` → **使わずに** drop → `_is_alive` が偽 → 捨てられ `size()` −1（P20 (b) は `PQconsumeInput` ×2 で (a) と同じ結果になる。待ちなしの変種は「再利用され最初の `execute` が `CONNECTION`、その drop で捨てられる」で、こちらも 1 件）；
      ⑨ idle 中に terminate（`min_size=1` で開いてから pid を取り terminate、`pg_sleep(0.05)`）→ `acquire` で `_is_alive` 偽 → `reset()` → 新 pid で `execute` が通り `SHOW DateStyle` = `ISO, YMD`（P19 の経路）；
      ⑩ `max_lifetime_s=1`: 貸し出し中に `SELECT pg_sleep(1.1)` → drop → `idle() == 0` → 次の `acquire` の pid が変わる；`max_lifetime_s=0` で `pg_sleep(1.1)` 後も同じ pid（P23）；
      ⑪ `close()` 後の `acquire` が `USAGE`（`pool is closed`）、`close()` で `pg_stat_activity` が減る、貸し出し中の guard が `close()` 後に drop → 捨てられる；⑫ `max_size=0` / `max_size=-1` / `min_size=3,max_size=2` / `max_lifetime_s=-1` が `USAGE` で `pg_stat_activity` 不変（P24）；
      ⑬ P22（probe-pool D/E）: `execute("BEGIN")` → `prepare`（`pq_stmt_1`）→ `SELECT 1/0`（`22012`）→ stmt drop → guard drop → 再 `acquire` → `prepare` が **`pq_stmt_2`** で成功。**陽性対照**: `_release` で `conn._stmt_counter[0] = 0` にする scratch コピーで `42P05`；
      ⑭ P25: `execute("BEGIN")` 後に terminate → 使わずに drop → `ROLLBACK` が `CONNECTION` → `set_rollback_failure_handler` で数えた handler が 1 回 → `size()` −1。6/6 段の `implicit ROLLBACK failed` が 0（既定 handler を使わない）；
      ⑮ 転送 11 本が通る（`transaction` / `prepare` / `copy_in` / `copy_out` を guard から使い、`tx.execute` / `st.execute` / `finish().affected_rows()` / `next()`）；⑯ `Dict` オーバーロードで `open` → `acquire` → `execute`；
      ⑰ 陽性対照 P21: `var a = pool.acquire(); var p2 = pool^; _ = a.execute("SELECT 1")` が `use of uninitialized value` でコンパイルエラー（scratch の mojo で確認し TRACE に）
    - (d) `tests/test_leak.mojo` に 2 ループ（P24。雛形 `:1106-1145` の `MAIN_ITERATIONS` / `_sample` / `_assert_stable`）: `Pool.open(min_size=2, max_size=2)` → drop を `ERROR_ITERATIONS`（1,000）回、`acquire` → `execute` → drop を `MAIN_ITERATIONS` 回（1 プール、再利用）。
      `_skip_on_macos` を付ける。**陽性対照**: `_release` が捨てる経路で `conn._conn = PGconnPtr(0)` してから `_ = conn^` する scratch コピー（`PQfinish` が走らない）で `is_leaking` が FAIL（RESEARCH §6）。built binary で実行（`run_tests.sh:71`）
    - (e) 両サーバーで PASS、`test_leak` の所要増分を TRACE に（見込み +10 s）
  - 対象: `src/pq/pool.mojo`, `src/pq/__init__.mojo`, `tests/test_pool.mojo`, `tests/test_leak.mojo`
  - 依存: T6
  - 並列サブ作業（推奨 1 本）:
    - A（親）: `pool.mojo` + `__init__.mojo`
    - B: `tests/test_pool.mojo` ①〜⑯ + `tests/test_leak.mojo` の 2 ループ（(a)(b) のシグネチャ・USAGE 文言・`application_name` 規則を依頼文に写す）

- [ ] T8: README / CHANGELOG / `__init__` docstring / examples 2 本 + `params.mojo` 配列 / `pixi.toml` / `final_check.sh`
  - 完了基準:
    - (a) `examples/copy.mojo` 新設（docstring は `examples/params.mojo:1-16` の形。`_conninfo` / `DEFAULT_CONNINFO` 同じ）: `CREATE TEMP TABLE` → `copy_in` で 1,000 行 text を `write` → `finish().affected_rows()` → `copy_out` を `while True: var row = out.next(); if not row: break`（P18）で行数とバイト数を数え、
      往復が一致しなければ `exit(1)`。`examples/pool.mojo` 新設: `Pool.open(conninfo, 2)` → `acquire` ×2 → 3 本目の `USAGE` を捕まえて `pool exhausted` を印字 → 1 本 drop → 再 `acquire` の `backend_pid` が同じことを確認、`size()/idle()/borrowed()` を印字、不一致は `exit(1)`。
      `examples/params.mojo` に `SELECT id, label FROM pq_p2_example WHERE id = ANY($1)` を `List[Int32]` で + `SELECT array_agg(label ORDER BY id)` を `List[String]` で読む節（`EXPECTED_ROWS` のロジックは不変）。
      `pixi.toml:20-24` に `example-copy` / `example-pool`、`final_check.sh:122-126` に 2 行（P26）。全 examples が単体で `exit 0`
    - (b) README（日本語本文、英語要約 `:7-14` に `arrays, COPY and a single-threaded connection pool` を 1 句）: 型マッピング表（`:343-363`）に行 `T[]（上の 19 型の 1 次元配列）| 要素の typarray（int4[] = 1007 など）| List[T] / List[Optional[T]] | 配列リテラル {1,2}（引用・\ エスケープ）| array_send 形式（ndim / flags / elemtype / dim / lbound + 要素）`、
      パラメータ表（`:141-159`）に `List[T]` / `List[Optional[T]]`（binary、typarray。`List[String]` は 1009）と「名前付きの `List` は `[ids^]` か `.copy()`」の注意（P10）；クイックスタートに `### COPY — examples/copy.mojo` と `### コネクションプール — examples/pool.mojo`（`:164-315` の形。コード片は examples から逐語抜粋、`pixi run example-copy` / `example-pool`）、
      `### パラメータバインド` の抜粋に `= ANY($1)` を足す（**抜粋照合器 `turn-008-readme-excerpts.py` が通ること**）；「既知の制限」（`:567-590`）から `:576-578` の 1 項目を外し、代わりに: 多次元配列（`TYPE_MISMATCH`）/ `box` 等 `,` 以外の区切り / `AsyncConnection` の COPY 無し / COPY の不正データは `finish()` まで分からない（P12）/
      `CopyOut` は `Iterator` ではない（`next()` + `while`）/ プールはスレッド安全でない（D12。Mojo 1.1.0 に stdlib のスレッド無し）/ 返却時に `SET` した GUC・prepared statement・一時テーブル・`LISTEN`・advisory lock は残る（D15。deadpool の Clean の列挙）/
      切られた直後の接続は `PQconsumeInput` で検出するが FATAL がまだ届いていなければ次の利用者の最初の `execute` が `CONNECTION`（P20 (b)）/ 未完了の `CopyIn` を持つ guard の drop は COPY を中止してから返却する（接続は再利用される）。「エラー」表は不変
    - (c) `CHANGELOG.md` `[Unreleased]` に `- Phase 7: ...`（配列型 19 型 × text / binary × `List` / `List[Optional]` + 送信、`copy_in` / `copy_out`、`Pool` / `PooledConnection`、`Connection.reset()`。タグは人間）
    - (d) `src/pq/__init__.mojo` docstring: `:3-8` に「Phase 7 adds `copy` and `pool`」、`:10-19` の列挙に `CopyIn` / `CopyOut` / `Pool` / `PooledConnection`、型表（`:42-62`）に配列行、`## Parameters` 表に配列行、新節 `## COPY` と `## Connection pool`（各 10 行以内: API 名・RAII・`USAGE` 検査・スレッド非安全）。
      `Connection.execute` / `prepare` / `transaction` の `Raises:` に `USAGE`（COPY 中）を 1 句（T6 で書いていなければ）
    - (e) 3/6 段（docstring 診断）0 件、6/6 段 0 件、`pixi run check` で 4/6 段に 7 本
  - 対象: `README.md`, `CHANGELOG.md`, `src/pq/__init__.mojo`, `examples/copy.mojo`, `examples/pool.mojo`, `examples/params.mojo`, `pixi.toml`, `tests/final_check.sh`
  - 依存: T7
  - 並列サブ作業（推奨 2 本）:
    - A: examples 3 本 + `pixi.toml` + `tests/final_check.sh`（対象: `examples/*.mojo`, `pixi.toml`, `tests/final_check.sh`）
    - B: `README.md` + `CHANGELOG.md`（対象: `README.md`, `CHANGELOG.md`。README のコード片は A の examples から逐語で写すので、A の完成後に親が照合器を回す）
    - 親: `src/pq/__init__.mojo` + 照合器 + `check`

- [ ] T9: 最終判定 — 堅牢性格子の全セル + クリーン状態からの `check` + 受け入れ基準対応表 + branch push
  - 完了基準:
    - (a) `scratch/turn-003-robust-grid.sh` を `turn-011-robust-grid.sh` に写し、`copy.mojo` / `pool.mojo` / `params.mojo` の行を有効化して全セル実行 → `unhandled_markers=0`（`traceback|unhandled|abort|segfault` 0 件。rc 141 は EPIPE の既知挙動で許容）。ログ `turn-011-robust-grid.log`。
      入力軸の追加分の所在を TRACE の表に: 配列リテラル不正 9 件 → `test_decode_array`、バイナリ不正 6 件 → 同、COPY 途中切断 → `test_copy` ⑩、プール枯渇 / 死んだ接続 → `test_pool` ① ⑦ ⑧ ⑨
    - (b) `pixi run db-reset` → `pixi run check` が `final_check: PASS`（所要を TRACE。閾値 300 s）。`pixi run package` 警告ゼロ。`pixi run fmt` 差分ゼロ
    - (c) チェックリスト全 77 key が期待値（`absent` 0 件）。`python3 -c ...` で PROGRESS 最新節 ≤ 40 行
    - (d) TRACE に「受け入れ基準対応表」（REQ §4.1〜§4.4 の各行 → テスト名 / 完了基準番号）と「verify への申し送り」（P1〜P29 → 検証した場所の表、grep パターン / 件数 / ファイルの 3 列）
    - (e) `git push -u origin gsd-lite/phase7-pool-copy-array`（REQ §6 の許可範囲。PR は verify が作る。CI はこの push では走らない）
  - 対象: `.gsd-lite/TRACE.md`, `scratch/turn-011-robust-grid.sh`
  - 依存: T8
  - 並列サブ作業: なし（推奨 0 本）

## 決めた事項

1. **モジュール配置**（RESEARCH §6 の案を採用）: FFI は `src/pq/_ffi/functions.mojo`、配列 OID 表 + テキスト配列は `decode_text.mojo`、バイナリ配列は `decode_binary.mojo`、エンコーダは `encode_binary.mojo`、`Param` は `params.mojo`、COPY は新規 `copy.mojo`、プールは新規 `pool.mojo`。src は 20 → 22 ファイル（根拠: `find src/pq -name '*.mojo' | wc -l` = 20）
2. **`PQputCopyEnd` の `errormsg` は `Int` で束縛し 0 = NULL**（RESEARCH §5-11。`OptCStr` を作る手段が無い）。`PQgetCopyData` の `char **` は `Pointer[Int, MutUntrackedOrigin]`（`probe-copy.mojo:59-61` で動作確認済み）
3. **`Connection.reset()` を公開メソッドとして足す**（REQ §2.3「plan が決める」→ RESEARCH §5-3）。`self`（`mut` でない。`PGconn*` は同じアドレスのまま）
4. **COPY 中の検出は `PQtransactionStatus == PQTRANS_ACTIVE`**（`_ffi/types.mojo:101`）。同期 `Connection` が `ACTIVE` になるのは COPY 中だけ（RESEARCH §2.4 (c)）。状態フィールドは足さない
5. **テキスト配列の tokenizer は psycopg `_load_text` の 3 分岐**（RESEARCH §3-1）。`[..]=` 接頭辞は `=` まで捨てる。`NULL` 判定は「引用符なし・大小無視」のみ
6. **要素エラーのメッセージは `array element N: <元メッセージ>`、N は 0 始まり**（既存の `column N is NULL` `result.mojo:729` が 0 始まりなので揃える）。NULL 要素の `NULL_VALUE` は `array element N is NULL`
7. **`CopyOut` は `Iterator` / `Iterable` にしない**。主 API は `next() -> Optional[List[UInt8]]` + `while`（REQ §2.2「`Iterator` としても使える」からの**意図的な逸脱**。根拠: Mojo 1.1.0 の `Iterator.__next__` は `raises StopIteration` ちょうどでないと適合せず `PgError` を `for` の中で出せない。
   RESEARCH §0 発見 1 / §2.7 D / `probe-lang.log`。error-stash 方式はエラーを隠すので D2 の堅牢性に反する）。README「既知の制限」に明記（T8）。verify はこの項を差し戻し対象にしない
8. **`encode_array(elems: List[Optional[List[UInt8]]], elem_oid: UInt32) -> List[UInt8]`** の非ジェネリック 1 本（RESEARCH §6 の「前者」。ジェネリック無しで単体テストしやすい）。`Param` の 34 本が既存 `encode_*` の戻りを並べて呼ぶ
9. **`List[String]` / `List[Optional[String]]` は OID 1009（`text[]`）/ 要素 25 で送る**（RESEARCH §2.3 p: 1015 に 25 を入れると `42804`）。`List[Int]` は `List[Int64]` と同じ 1016 / 20。要素型は `Int` を含めて **17**（turn 4 訂正）、`Param` は 34 本、`decode_*` は各 34 分岐
10. **`List[String]` の NUL 入り要素はサーバーに送り `SERVER`（22021 想定、T4 で実測）**。`USAGE` にするには `Param` に失敗フラグ用のフィールドを足す必要があり（`@implicit __init__` は raise しない）、最小実装を優先（RESEARCH P9 の「`USAGE`」は不採用）
11. **`CopyIn` / `CopyOut` の構造 = `Transaction[origin]`**（`transaction.mojo:96-157`）: `_conn: Pointer[Connection, origin]` / `_done: Bool` / `_handler: def(PgError) thin`。`__deinit__` は `PQexec` を呼ばない（COPY API だけ。P16）
12. **COPY の USAGE 文言**: `a COPY is in progress on this connection` / `COPY already finished` / `copy_in() requires a COPY ... FROM STDIN statement (result status N)` / `copy_out() requires a COPY ... TO STDOUT statement (result status N)`。プール: `pool is closed` / `pool exhausted: all N connections are borrowed` / `max_size must be positive (got N)` / `min_size must be between 0 and max_size (got N)` / `max_lifetime_s must not be negative (got N)`
13. **`write` の `-1` と「sqlstate 無しの FATAL」は `CONNECTION`**（`PQstatus` は当てにならない: RESEARCH §2.4 6a）。`-1` の後は libpq を呼ばない（`PQerrorMessage` の追記肥大。P11）。`abort()` は 57014 だけ飲む（psycopg `finish(exc)`）。`finish` / `abort` / `__deinit__` は `PQgetResult` が NULL になるまで回す（P15）
14. **`_check_not_copying` の呼び出し 7 箇所**: `Connection.execute` ×2 / `prepare` / `_transaction_parts` / `_copy_in_parts` / `_copy_out_parts` / `PreparedStatement.execute`。`escape_*` は client-side なので対象外。`Transaction` の各コマンドは `Connection.execute` 経由なので自動的に対象
15. **`Pool` は `Connection` を `List[_Slot]` で丸ごと保持**（`_stmt_counter` を引き継ぐ。RESEARCH §0 発見 5 / P22）。`__deinit__` は書かない（List の deinit が各 `Connection` の `PQfinish` を走らせる）
16. **`Pool.open` のシグネチャ**: `open(var conninfo: String, max_size: Int, *, min_size: Int = 0, max_lifetime_s: Int = 0)` + `Dict` 版。`max_size` は位置引数（`Connection.open(conninfo)` の次に自然）、オプション 2 つは keyword-only（D17）。`max_lifetime_s` の時計は `std.time.monotonic()`（ns）
17. **健全性の確認 = `PQstatus` + `PQconsumeInput` ×2**（貸し出し前と返却時）。往復なし・非ブロッキング（REQ §2.3「往復しない」の範囲内。RESEARCH §2.5 H2: 1 回目は FATAL を消費して 1、2 回目で 0 / BAD）。健全な接続では両方 1（実測）。これにより REQ §4.3「使わずに返した terminate 済み接続が捨てられる」が `pg_sleep(0.05)` 付きで成立する
18. **返却時の判定順**: `_closed` → `INTRANS` / `INERROR` なら `ROLLBACK`（失敗は handler + 捨てる）→ `PQstatus != OK` or `txstatus != IDLE` → 捨てる → 寿命 → 捨てる → `_is_alive` 偽 → 捨てる → idle へ
19. **`PooledConnection` の origin 付き 4 本は `_X_parts` + `_conn_ptr()` rebind**（RESEARCH §3-10 / §0 発見 6）。`Connection` 側に `_transaction_parts` / `_copy_in_parts` / `_copy_out_parts` を分け、`Transaction` と `PooledConnection` が同じ parts を使う（`_prepare_parts` の前例 `connection.mojo:496-511`）
20. **未完了の `CopyIn` を持つ guard の drop は「COPY 中止 → 返却 → 再利用」**。REQ §4.3「その接続は捨てられ `size()` が 1 減り」は、origin で `CopyIn` が guard より先に死ぬ Mojo の順序では観測できない（`CopyIn.__deinit__` が先に `PQputCopyEnd` で中止し接続は IDLE に戻る）。
   D11（drop で中止して接続を戻す）と D15（返却時に `ACTIVE` なら捨てる）の両方を満たす解として、`ACTIVE` 分岐は白箱テスト（T7 ⑥）で、利用者視点は「再利用される」で検証する。中止に失敗した（接続が死んだ）場合は `PQstatus` / `txstatus` で捨てられる。README「既知の制限」に 1 行
21. **`test_pool` の接続本数は `application_name=pq_test_pool` で絞って `pg_stat_activity` を数える**（他テストの接続・docker の healthcheck が混ざらない。RESEARCH §6）
22. **`check` の閾値は 300 s**（新テストファイル 4 本 × 2 サーバーのコンパイルが支配的。見積もり 230〜275 s）
23. **`execute(sql)` が COPY 文を受けたときの挙動は現行（`SERVER` `unexpected result status 3/4`）のまま、ただし raise の前に drain して接続を IDLE に戻す**（T6 (c)。現行は次の `execute` で libpq が黙って片付けていた: `connection.mojo:266-269` の記述）
24. **チェックリストの `.md` はコメント行を除外しない**（`#` が見出し。plan で `readme_h2=0` を踏んで修正済み）

## メモ

### 前回・前々回の reflect「次回への提案」の反映

| 提案（reflect） | 反映 |
|---|---|
| Phase 6-1 research: 第三者アクションのソースを読む | 対象外（今回アクションを足さない）。代わりに REQ §6 のプローブ 4 件を research が実測済み |
| Phase 6-2 plan: 複数 OS CI のマイルストーンは `verify_round_max` 4、OS 固有の赤は契約と照合 | `verify_round_max: 4`（state、D1）。OS 固有の経路は `close(PQsocket)`（T6 ⑩）と `pg_stat_activity`（T7）: P29 として verify に申し送り |
| Phase 6-3 plan: チェックリストはコメント行を除外、impl は「コメントを書いたらチェックリストを回す」 | `turn-002-checklist.sh` の `body()`（`.md` 以外）。冒頭の運用文に明記 |
| Phase 6-4 ツール側（複数 `result` の合算） | ユーザー側。未反映のまま（plan の範囲外） |
| Phase 6-5 impl: サブエージェントに親の待ち合わせファイル名を書かない | T4 / T6 / T7 / T8 の並列サブ作業欄に明記 |
| Phase 6-6 verify/impl: 自分が起動していない run は `gh run view --json` で確定 / state push で CI が走る事実 | 検証コマンド節に「PR 作成後は state コミットの push ごとに run が起動」を書いた。T9 は branch push だけ（CI 無し） |
| Phase 6-7 plan: key 総数を PLAN に書き TRACE も同じ総数 / `= N` 行は現在値を打つ | 「全 77 key」を冒頭と T1 (d) / T9 (c) に。`= N` 行（41 / 20 / 21 / 7 / 9 / 28 / 22 / 11 / 1）は現在値 + 確定増分で計算し、現在値は `turn-002-checklist.log` で確認済み |
| Phase 6-8 discuss (a)〜(f) | discuss で処理済み（D1 / D19 / D20）。(c)(d) の CI 観察は verify の PR 作成時に `gh run list` で 1 回見る（REQ §6） |
| Phase 5-2 plan: 堅牢性格子 3 軸を PLAN に常設 | T1 (e) + T9 (a)。入力軸の追加分はテスト側に割り当てて表で対応づけ |
| Phase 5-3 impl: TRACE「チェックリスト（turn N）」節 + PROGRESS 40 行 | T1 (d) + 各タスク共通 + T9 (c) |
| Phase 5-4 settings: Monitor を deny | 未反映（Phase 6 で使用 0 回。待ちは `run_in_background` Bash か前景 `sleep`。REQ §6） |
| Phase 5-5 plan: 増える方向は `≥` | チェックリスト表の `≥` |
| Phase 5-6 verify: F 項目の見込み行数は `+/-` 単位 | verify への申し送り（T9 (d)） |
| Phase 5-8 discuss: 「再現不能」は方式を列挙 / `close(PQsocket)` 常設 | T6 ⑩ が `close(PQsocket)` 方式 |

### RESEARCH §3「盗める設計」の採否

| # | 内容 | 採否 |
|---|---|---|
| 1 | psycopg の tokenizer 3 分岐 + `[..]=` 捨て + NULL 規則 | **採用**（T2 (b)） |
| 2 | psycopg `_load_binary` + `array_recv` の検査 10 種をクライアントで | **採用**（T3 (a)。hasnull を見ない = P1） |
| 3 | psycopg `ListBinaryDumper` + `array_send`（空は ndim 0） | **採用**（T4 (a)） |
| 4 | `pg_type.typarray` の定数表 + 2 関数 | **採用**（T2 (a)） |
| 5 | `comptime if` 分岐は 1 行ずつ 34 本 | **採用**（T2 (d) / T3 (b)。probe-lang A で `rebind` 形が通ることを確認済み） |
| 6 | psycopg `finish(exc)`: abort は 57014 だけ飲む | **採用**（T6 (b)） |
| 7 | `PQTRANS_ACTIVE` で COPY 中を検出 | **採用**（決めた事項 4） |
| 8 | psycopg `_reset_connection` の判定順 + `List[Connection]` 丸ごと | **採用**（決めた事項 15 / 18） |
| 9 | deadpool Fast + `PQreset`（+ 任意で `PQconsumeInput`） | **採用、`PQconsumeInput` は ×2 で必須に**（決めた事項 17。1 回では FATAL を消費して終わる） |
| 10 | ガード = origin パターン + `_conn_ptr()` rebind + `_X_parts` | **採用**（決めた事項 19） |
| 11 | `PQgetCopyData` の `char **` 受け取り | **採用**（`probe-copy.mojo:97-123` そのまま） |
| 12 | 堅牢性格子の雛形 = `turn-012-robust-regress.sh` | **採用**（T1 (e)。RESEARCH は `turn-010` を挙げるが Phase 5 reflect 提案 2 の `turn-012`（`run_pipe` 修正済み）を使う） |

### RESEARCH §5「要件への影響」の採否

| # | 提案 | 採否 |
|---|---|---|
| 1 | `CopyOut` の `Iterator` を外す | **採用**（決めた事項 7。REQ からの逸脱を明記） |
| 2 | terminate ケースを (a)(b) の 2 件に | **採用 + 改良**: `PQconsumeInput` ×2 で (b) も捨てられる（T7 ⑦ ⑧。待ちなし変種も 1 件） |
| 3 | `Connection.reset()` 公開 | **採用**（T1 (b)） |
| 4 | 方向違い / 非 COPY 文の `USAGE` はその場で drain | **採用**（T6 (c) ⑫。`execute(sql)` の COPY 文も drain: 決めた事項 23） |
| 5 | USAGE 検査の根拠 = データ消失、陽性対照 | **採用**（T6 ⑧） |
| 6 | `finish()` は多文の残りを捨てる、`abort` は 57014 だけ、`-1` は `CONNECTION` | **採用**（決めた事項 13） |
| 7 | `List[String]` = 1009 / 25、`List[Int]` を含め 17 型 | **採用**（決めた事項 9）。NUL 要素の `USAGE` は**却下**（決めた事項 10） |
| 8 | §4.1 の境界値追加 | **採用**（T2 (e) / T3 (c) / T5） |
| 9 | `max_lifetime_s=1` は `pg_sleep(1.1)` で | **採用**（T7 ⑩） |
| 10 | `test_leak` に 2 ループ | **採用**（T7 (d)） |
| 11 | `PQputCopyEnd` の errormsg は `Int` | **採用**（決めた事項 2） |

### 落とし穴 P1〜P29 → 完了基準の対応

P1 / P2 / P3 → T3 (c)；P4 → T2 (e) / T3 (c) / T5 (d)；P5 → T2 (e) / T3 (c) / T5 (c)；P6 / P7 / P8 → T2 (b)(e)；P9 → T4 (c)；P10 → T4 (c) + T8 (b)；P11 → T6 (b) ⑩；P12 → T6 ⑨；P13 → T6 ⑧（陽性対照）；P14 → T6 ⑫；P15 → T6 ⑪；P16 → T6 ⑬ ⑭；P17 → T6 ⑦；P18 → T8 (a) + 決めた事項 7；
P19 → T1 (b) + T7 ⑨；P20 → T7 ⑦ ⑧ + T8 (b)；P21 → T7 ⑰；P22 → T7 ⑬（陽性対照）；P23 → T7 ⑩；P24 → T7 ⑫ (d)；P25 → T7 ⑭；P26 → T8 (a)；P27 → T1 (e) + T9 (a)；P28 → 共通（6/6 段）；P29 → verify への申し送り（T9 (d)。CI 3 OS は PR 作成後）

### 並行性・境界値・異常系の担当

- 並行性（単一スレッド前提で「同時に生きる値」の並行）: ガード 2 本同時（T7 ①）、`PreparedStatement` と COPY の共存（T6 ⑧）、`Transaction` と `CopyIn` の破棄順序（T6 ⑬ ⑭）、プールの `List` を `ref self` で書く escape hatch（T7 (a)、P21）
- 境界値: 配列（空 / 1 要素 / NULL のみ / 10 万要素は T5 (a) に 1 件足す（`generate_series(1,100000)` を `List[Int32]` で、両形式））、COPY 10 万行 / 空の COPY（0 行で `finish` → 0）/ 1 行の `copy_out`、プール `max_size=1` / `min_size=max_size` / `max_lifetime_s=0`
- 異常系: 不正リテラル 9 件 / バイナリ不正 6 件 / 22P04 / 42P01 / 57014 / 途中切断 2 方向 / terminate 3 通り / ROLLBACK 失敗 / 方向違い 3 件 / `close()` 後 / 引数検査 4 件

### impl への注意

- **サブエージェント推奨本数**は各タスクの欄のとおり（T4 1 / T6 1 / T7 1 / T8 2 / 他 0）。依頼文の規則: 親の待ち合わせファイル名・解除条件を書かない、出力は `scratch/turn-NNN-<name>.log`、`fmt` は親が統合後、サブ側は PLAN の該当タスク本文（シグネチャ・文言）を**そのまま渡す**
- Mojo 1.1.0 の字句（RESEARCH §0.5 ☆）: 名前付き `List` を literal に並べるときは `^`；`Iterator.__next__` は `raises StopIteration`；フィールド経由の origin は `origin_of(self)` に rebind；`@implicit __init__(var v: String)` と `__init__(var tag: String)` は衝突；`Atomic[Int]`；未使用変数は `_ =`
- `PQerrorMessage` は失敗ごとに追記される → `-1` を見たら 1 回だけ読む（P11）
- `pixi` は絶対パス。`check` の前後は `date -Iseconds` で挟んで所要を TRACE に
- 既存テストの期待値変更は **0 件**を目標（変えるなら PROGRESS に 1 行ずつ列挙し、verify が diff で照合する）
- T2 / T3 の 34 分岐はコピペ事故（OID の取り違え）が最も起きやすい → T2 (a) の両方向テストと T4 (d) の陽性対照で表を機械検査する
- `examples/params.mojo` を変えると README の抜粋（`README.md:189-211`）が逐語一致しなくなる → T8 で必ず照合器を回す
