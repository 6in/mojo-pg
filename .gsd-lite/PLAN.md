# PLAN — phase4-async-cancel-notify

- 作成: 2026-10-17 / gsd-lite-plan（turn 2）
- 入力: REQUIREMENTS.md / DECISIONS.md / RESEARCH.md / `.gsd-lite/reflect/20261017-0254-phase3-binary-all-types.md`（直近）/
  `.gsd-lite/reflect/20261016-0246-phase2-params-prepared-tx.md` / `archive/phase3-binary-all-types/PLAN.md`（書式の手本）/
  `src/pq/*.mojo` / `tests/*` / `examples/*` / `HANDOFF.md` §7・§9・§10
- 対象リポジトリ: `.`（in-repo 形）。`CLAUDE.md` / `AGENTS.md` は無い（`ls` で確認。Phase 3 PLAN と同じ）
- 無人シェルの注意（RESEARCH 冒頭と同じ）: `mojo` / `pixi` は PATH に無い → **`/home/parallels/.pixi/bin/pixi run ...`**。`rg` は無い（`grep`）。
  docker の DB は `tests-pg17-1`（127.0.0.1:54317）/ `tests-pg14-1`（127.0.0.1:54314）が healthy で起動中（plan 時点 `docker ps`、Up 41 hours）。
  **`blackhole`（54399）はまだ無い**（T1 で足す。`pixi run db-up` で compose 全体が上がる）。lean-ctx MCP は未接続（素の Read / Bash で可）
- research のプローブ（`.gsd-lite/logs/phase4-async-cancel-notify/scratch/turn-001-*`、gitignore 対象）は impl が**雛形として開いてよい**:
  `probe-poll.mojo`（`PollFd` struct と `external_call["poll"]` の形、pipe / socketpair / errno / 単調時計。`_platform/poll.mojo` と `test_poll.mojo` の原型）、
  `probe-async.mojo`（`PQconnectStartParams` の引数組み立て `cstr` / `field` / `errmsg` / `describe` / `drain`、cancel / NOTIFY / 切断の一連の呼び方）、
  `probe-async2.mojo`（接続中の誤呼び出し・single-row 境界・tx 内 cancel・multi-host）、`probe-async-pg17.log` / `-pg14.log` / `probe-async2-*.log`（期待値の原本）、
  `probe-lang.mojo`（`comptime if CompilationTarget.is_linux()` と `String(from_utf8=)` の形）、`blackhole-compose.yml`（compose にそのまま写す 5 行）
- **追従先チェックリストは実行可能スクリプト** `.gsd-lite/logs/phase4-async-cancel-notify/scratch/turn-002-checklist.sh`（REQ §9 plan 項目。plan ターンで 1 回実行し
  「現在値」を下表に転記済み）。impl は各タスクの完了基準の最後で実行し、自タスクの行が期待値に到達していることを PROGRESS に書く。T8 は再実行だけで総点検にする

## 検証コマンド

impl の各ターンがテストに使うコマンド（リポジトリルートで実行。`cd` 不要）:

```bash
/home/parallels/.pixi/bin/pixi run db-up        # 環境の初期化（--wait 付き。pg17 / pg14 / blackhole（T1 以降）。起動済みなら即終了）
/home/parallels/.pixi/bin/pixi run test         # tests/run_tests.sh: 54317 → 54314 の順に tests/test_*.mojo を 1 ファイル 1 プロセス（test_leak は build/test_leak）
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_poll.mojo      # 単一ファイル（サーバー不要）
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_async.mojo     # 単一ファイル（PQ_TEST_CONNINFO 未設定なら 54317）
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_notify.mojo    # 同上
/home/parallels/.pixi/bin/pixi run mojo build -I src tests/test_leak.mojo -o build/test_leak   # leak だけ手で回すとき（run_tests.sh と同じ）
/home/parallels/.pixi/bin/pixi run example-async                              # examples/async_query.mojo（T4 以降）
/home/parallels/.pixi/bin/pixi run example-notify                             # examples/listen_notify.mojo（T4 以降）
/home/parallels/.pixi/bin/pixi run package      # mojo precompile src/pq -o build/pq.mojoc（警告ゼロ確認）
/home/parallels/.pixi/bin/pixi run check        # 最終判定: bash tests/final_check.sh（6 段、exit 0 が合格）
bash .gsd-lite/logs/phase4-async-cancel-notify/scratch/turn-002-checklist.sh   # 追従先チェックリスト（現在値を出す）
```

- 環境の初期化（テストの前に毎回）: `/home/parallels/.pixi/bin/pixi run db-up`（`tests/docker-compose.yml` 全サービス。T1 で `blackhole` を足した後は 3 つ）
- 最終判定（クリーンな状態から全検査。verify と T8 が使う）: **`/home/parallels/.pixi/bin/pixi run check`**
  - 1/6 段はコピーに `mojo format` → `diff -r` なので作業木のまま回せる（`tests/final_check.sh:57-79`）
  - 4/6 段（`tests/final_check.sh:120-127`）に T4 で `examples/async_query.mojo` / `examples/listen_notify.mojo` の `run_logged` 行を足す
  - 5/6 段は `PQ_TEST_LEAK_SERVERS=1` で `test_leak` を PG17 だけ（`final_check.sh:131`）。`pixi run test` は両サーバーで回す
  - 6/6 段は `grep -cE 'warning:|WARNING:|implicit ROLLBACK failed'`（`final_check.sh:153`）。**見出し行と `say()` にこれらの文字列を含めない**。
    Phase 4 で新しく機械化する grep は無い（REQ §9 の「複数タスクが繰り返す `grep -c X = 0`」はチェックリストスクリプトに集約した）
- 所要の目安（REQ §9 の式: 前マイルストーン末の実測 + 新テスト 1 ファイルあたりの接続数 × 3〜7 s）: Phase 3 末の実測は `check` **112〜143 s**（T1〜F1 の 10 ターン）、
  `pixi run test` **189〜200 s**（21 ファイル × 2 サーバー + leak 74 s / サーバー）。Phase 4 で乗るもの: `test_poll`（サーバー不要、≈ 1 s）、`test_async`（接続 10〜12 本 + `pg_sleep(2)` + cancel +
  タイムアウト 0.5 s ≈ **40〜60 s / サーバー**。RESEARCH §6）、`test_notify`（接続 4〜6 本 ≈ 15 s / サーバー）、leak +4 ループ（≈ +15 s、1 サーバー）、examples 2 本（各 3〜5 s）。
  **`check` は 260〜300 s、`pixi run test` は 330〜360 s と見込む**（未確認。impl は所要を PROGRESS に単位付きで書く。`final_check.sh` にタイムアウトは無い）
- PG14 / PG17 の差はタイミングだけ（RESEARCH §2.7）。**サーバー版分岐のテストは Phase 4 に無い**。全テスト両サーバー同一期待値

## 追従先チェックリスト

スクリプト `turn-002-checklist.sh` の key で書く（左列）。「現在値」は plan ターンの実行結果（2026-10-17、コミット `647538d` の木）。
`absent(...)` はファイル未作成。期待値の「≥」は下限。

| key | 変更の種類 / 直す場所 | 現在値 | 期待値（到達タスク） |
|---|---|---|---|
| `params_libpq_takes_at_most` / `params_MaxAllocSize` | REQ §6-1: `src/pq/params.mojo:641-645` docstring Raises と `:670` のメッセージを「上限は PG 側（`MaxAllocSize` 1 GB）」の言い方に | 1 / 1 | **0 / ≥ 2**（T1） |
| `testconn_from_the_environment` / `testconn_PGCLIENTENCODING` | REQ §6-2: `tests/test_connection.mojo:949-955` の docstring | 1 / 0 | **0 / 1**（T1。T7 が同じ docstring の「without validation」も直す） |
| `timetz_time_of_day_is_not` / `timetz_out_of_range_sites` | REQ §6-3: `src/pq/decode_binary.mojo:565-596` `decode_timetz` に時刻部の範囲検査 + docstring `:573-574` | 1 / 0 | **0 / 1**（T1） |
| `datetime_is_utc_calls` / `datetime_asia_tokyo` | REQ §6-4: `tests/test_extended_datetime.mojo:764-797` の非 UTC `else` 分岐を専用接続のケースに | 2 / 0 | **2 / ≥ 1**（T1。`:568` の `_is_utc` は別テストで残る） |
| `compose_blackhole` / `compose_54399` | D10: `tests/docker-compose.yml` に `blackhole` サービス | 0 / 0 | **1 / 1**（T1） |
| `run_tests_SKIP` / `run_tests_pipefail` | §4.8: `tests/run_tests.sh` の SKIP 集計と終了コード保全 | 0 / 0 | **≥ 2 / ≥ 1**（T1） |
| `tests_print_SKIP` / `leak_old_SKIP_colon` | §4.8: `print("SKIP <name>: <reason>")` の形。`test_extended_datetime.mojo:840-879` の 2 件、`test_leak.mojo:573` の形式、T1 (d) の Tokyo 分岐、T3 のタイムアウトテスト。**`print("SKIP ` は 1 行に収める**（折り返すとパターンが当たらない） | absent / 1 | **≥ 5 / 0**（T1 で ≥ 3、T3 で +1、T5 以降 +α）。**注（T1 実装時）**: `tests_print_SKIP` は `test_async.mojo` / `test_notify.mojo` が無いあいだスクリプトが `absent(...)` を返すので、T3 までは `grep -c 'print("SKIP ' tests/test_extended_datetime.mojo tests/test_leak.mojo` で手で数える（T1 実測 3 + 1 = 4） |
| `string_payload_def` / `string_payload_calls` / `jsonb_version_checks` / `oid_varchar_checks` | §4.9: `decode_binary.mojo:706-726` と `result.mojo:746-765` の重複を `_string_payload` に | 0 / 0 / 4 / 2 | **1 / 2 / ≤ 2 / 1**（T1。`_JSONB_VERSION` は定義 + 使用 1 箇所、`oid != OID_VARCHAR` は 1 箇所） |
| `test_decode_binary_tests` | §4.9 の単体 1 件（T1）+ §4.10 の UTF-8 5 件 + 陽性対照 1 件（T7） | 78 | **≥ 79**（T1）→ **≥ 85**（T7） |
| `test_extended_datetime_tests` | REQ §6-3 の timetz テスト 1 件は `test_decode_binary.mojo` 側。ここは変化なし | 19 | **19**（T1。`test_timestamp_params_round_trip` は書き換えで件数不変） |
| `conn_def_take_result` / `conn_def_error_field` / `result_def_adopt_result` / `result_def_error_field` / `result_SINGLE_TUPLE` / `conn_adopt_result_calls` | D5: `adopt_result` と `_error_field` を `result.mojo` へ。`Connection._take_result` は 1 行委譲 | 1 / 1 / 0 / 0 / 0 / 0 | **1 / 0 / 1 / 1 / ≥ 1 / 1**（T2） |
| `errors_TIMEOUT` / `errors_six` / `init_exactly_six` / `init_TIMEOUT` | D11: `errors.mojo:3,13`「six」→ seven、`__init__.mojo:174`「exactly six」→ seven + 箇条書きに `TIMEOUT` | 0 / 2 / 1 / 0 | **≥ 2 / 0 / 0 / ≥ 1**（T2。`__init__.mojo:29,108` の「six string-shaped OIDs」は別物で残す） |
| `ffi_PQsetSingleRowMode` / `ffi_PQconnectStart_plain` / `testffi_*` / `testffi_symbol_count_53` / `_55` | §4.5: `_ffi/functions.mojo` に 2 バインド（宣言 + `_dl_sym`）、`tests/test_ffi.mojo:40-92` の名前表と `:102` の件数 53 → 55 | 0 / 0 / 0 / 0 / 1 / 0 | **3 / 1 / 1 / 1 / 0 / 1**（T2。**訂正（T2 実装時）**: `ffi_PQsetSingleRowMode` の期待 2 → **3**。`mojo format` が `_dl_sym[...](self._lib, "PQsetSingleRowMode")` を 3 行に割るため宣言 1 + 代入 1 + 名前文字列 1 で 3 行当たる） |
| `platform_init` / `platform_poll` / `poll_*` / `test_poll` / `test_poll_tests` | §4.1: `src/pq/_platform/__init__.mojo` + `poll.mojo`、`tests/test_poll.mojo` | absent | **exists / exists / `def poll_socket` 1 / `comptime if` ≥ 1 / `WSAPoll` ≥ 1 / `EINTR` ≥ 1 / `monotonic` ≥ 1 / `external_call["` ≤ 3 / exists / ≥ 7**（T2） |
| `async_conn` / `async_struct` / `async_state_struct` / `pollstate_struct` / `notification_struct` / `async_public_defs` | §4.2 / §4.3: `src/pq/async_conn.mojo` | absent | **exists / 1 / 1 / 1 / 1 / ≥ 20**（T3 で struct 4 つと接続〜`fetch_all`、T4 で cancel / notify / single-row が加わる） |
| `async_called_while` / `async_cancel_insecure` | USAGE 格子のメッセージ（決めた事項 8）、P31 の docstring | absent → **5 / 0**（T3 後の実測） | **≥ 6 / ≥ 1**（T3 / T4。T3 時点は 5 で、`_require_state` / `_reject_connecting` の 2 本に文言を集約したため。T4 の `cancel` / `notifications` の docstring で 6 を超える） |
| `init_async_import` / `conn_phase4_future` / `init_phase4` | `__init__.mojo` の再エクスポート + Layout 行に Phase 4、`connection.mojo:164`「Phase 4's asynchronous connect will send」を現在形（`AsyncConnection.poll_connect` sends the same SQL）に | 0 / 1 / 0 | **1 / 0 / 1**（T3） |
| `src_PQfinish_calls` / `src_PQfreemem_calls` / `src_PQfreeCancel_calls` / `src_PQexec_calls` | libpq の解放・直呼び経路の本数（REQ §5.2） | absent（connection 2 / 2 / — / 4） | **≥ 3 / 3 / 1 / 4**（T3 / T4。`async_conn.mojo` に `PQexec(` は書かない） |
| `test_async` / `test_async_tests` / `test_notify` / `test_notify_tests` | §4.7 | absent | **exists / ≥ 8（T3）→ ≥ 20（T5）/ exists / ≥ 3（T4）→ ≥ 8（T5）** |
| `example_async` / `example_notify` / `pixi_example_tasks` / `final_check_examples` / `final_check_run_logged_examples` | §4.6: examples 2 本、`pixi.toml:17-19` の並び、`final_check.sh:122-124` | absent / absent / 0 / 0 / 3 | **exists / exists / 2 / 2 / 5**（T4） |
| `leak_tests` / `leak_Fourteen` / `leak_async_import` | §5.2: `test_leak.mojo:33`「Fourteen tests」→ Eighteen + 箇条書きに Phase 4 の段、`:55-60` の所要 | 14 / 1 / 0 | **18 / 0 / ≥ 1**（T6） |
| `utf8_unsafe_span` / `result_unsafe_ptr` / `utf8_from_utf8` / `utf8_scanner_def` / `utf8_invalid_message` / `docs_not_validated` / `test_decode_binary_utf8_tests` | §4.10: `result.mojo:435,765`、`decode_binary.mojo:715,725`、docstring 4 箇所（`result.mojo:712`、`decode_binary.mojo:651`、`__init__.mojo:111`、`test_connection.mojo:952`） | 3 / 4 / 0 / 0 / 0 / 4 / 0 → **2 / 7**（T1・T2 後の実測） | **0 / 6 / ≥ 2 / 1 / ≥ 1 / 0 / ≥ 5**（T7。**訂正（T2 実装時）**: `result_unsafe_ptr` の現在値 4 → **7**、期待 3 → **6**。T2 が `_error_field` / `adopt_result` を `result.mojo` に移し、libpq のエラー文字列を読む `unsafe_from_utf8_ptr` が 3 行増えたため。残り 6 は `column_name` / `affected_rows` / `command_tag` + エラー文字列 3 で、いずれも列値ではないので UTF-8 検証の対象外。`utf8_unsafe_span` の現在値 3 → 2 は T1 の `_string_payload` 一元化による） |
| `src_def_ref_return` / `tests_files_count` / `test_file_count` | `ref` を返す公開 API を作らない（Phase 3 P19 の継続）/ テストファイル数 | 0 / 21 / 21 | **0 / 24 / 24**（T8 で確認。`test_poll` / `test_async` / `test_notify`） |

## Tasks

- [x] T1: 持ち越し整理（REQ §6 の 4 件）+ `blackhole` compose + TestSuite の SKIP 集計（§4.8）+ jsonb / 文字列系 OID 判定の一元化（§4.9）
  - 完了基準:
    - (a) REQ §6-1: `src/pq/params.mojo:641-645`（`_ParamBuffers.__init__` docstring Raises）の「longer than libpq's `paramLengths` can carry (1073741823 bytes)」と `:670` の
      `" bytes; libpq takes at most 1073741823)"` を「PostgreSQL の `MaxAllocSize`（1 GB = 1073741823 bytes）を超える値はサーバーが受け取れない」の言い方に
      （例: `" bytes; PostgreSQL accepts at most 1073741823, its MaxAllocSize)"`）。`:656-661` のコメントは既にこの趣旨なので揃えるだけ。`is too large` の部分文字列は残す
    - (b) REQ §6-2: `tests/test_connection.mojo:949-955`（`test_client_encoding_is_utf8` docstring）の「libpq takes `client_encoding` from the environment」→
      「libpq defaults `client_encoding` to the database's `server_encoding` unless `PGCLIENTENCODING` says otherwise, and the test containers are UTF-8」
      （`result.mojo:712-718` の既存文言と揃える）
    - (c) REQ §6-3: `src/pq/decode_binary.mojo:589-596` `decode_timetz` に `decode_time`（`:558-562`）と同じ `micros < 0 or micros > _MAX_TIME_MICROS` → `_binary_value_error("timetz", String(micros, " is out of range"))`
      を zone 検査の前に足し、docstring `:573-574`「the time of day is not, since the server pairs a `24:00:00` with a zone and both are valid」→「the time of day is range checked too, `0..86400000000` inclusive, since `24:00:00` with a zone is valid」に。
      `tests/test_decode_binary.mojo` に 2 件: `000000141dd76001 00000000`（86400000001）→ `TYPE_MISMATCH` でメッセージに `"is out of range"`、`000000141dd76000 ffff8170`（`24:00:00+09`）→ `TimeTz(86400000000, -32400)`
      （期待 hex は `test_extended_datetime.mojo:671` と Phase 3 PLAN T5 (d) の `000000141dd76000` = 86400000000 から）
    - (d) REQ §6-4: `tests/test_extended_datetime.mojo:775-795` の非 UTC `else` 分岐（binary だけ読む）を消し、代わりに**専用接続**
      `_connect(_conninfo() + " options='-c TimeZone=Asia/Tokyo'")` で `_assert_param_roundtrip(conn_tokyo, "SELECT $1::timestamptz", [TimestampTz(762525296789000)], TimestampTz(762525296789000), "2024-02-29 21:34:56.789+09")`
      を**無条件に** 1 ケース回す（UTC 12:34:56.789 の +09 は 21:34:56.789。impl は `psql` 相当（同期 `Connection`）で `SELECT '2024-02-29 12:34:56.789+00'::timestamptz` を同じ `options` 接続で取り直して期待文字列を確かめる）。
      `_is_utc(conn)` が偽のときの主接続のケースは `print("SKIP test_timestamp_params_round_trip: TimeZone is not UTC")` を出して飛ばす（§4.8 の形。
      **訂正（T1 実装時）**: 元の文言「main connection TimeZone is not UTC」は 80 桁を超えて `mojo format` が `print(` と文字列を別行に割るため、
      チェックリストのパターン `print("SKIP ` が当たらなくなる。文言を縮めて 1 行に収めた）
    - (e) D10 / RESEARCH §2.5 / P30: `tests/docker-compose.yml` に `blackhole`（`image: alpine/socat`、`command: -u TCP-LISTEN:5432,fork,reuseaddr OPEN:/dev/null`、`ports: "127.0.0.1:54399:5432"`。
      `scratch/turn-001-blackhole-compose.yml` の 5 行そのまま。healthcheck 不要）。`pixi run db-up` 後に `docker compose -f tests/docker-compose.yml ps` で `blackhole` が `Up`（running）。
      陽性対照: `python3 -c` は使わず、T3 のタイムアウトテストで実測する（ここでは `Up` の確認だけ）
    - (f) §4.8 / P28: `tests/run_tests.sh:94-99` の `mojo run -I src "$f" || status=1` を「出力を `build/last_test.log` に `tee` しつつ終了コードは `${PIPESTATUS[0]}` で拾う」形にし、
      `skipped=$((skipped + $(grep -c '^SKIP ' build/last_test.log || true)))` を加算、サーバーループの末尾（`:101` の前）で `echo "-- $label skipped $skipped"`（約 10 行）。
      `test_leak`（`:90` の `"$leak_bin"`）も同じ `tee` + 集計に通す。FAIL にはしない（`final_check.sh` は変更しない）。
      **陽性対照**: `PQ_TEST_CONNINFO='host=127.0.0.1 port=1 user=pq password=pq dbname=pq_test' bash tests/run_tests.sh` の終了コードが**非 0**（`tee` が終了コードを飲んでいない）。
      実行時間は接続拒否が即時なので数十秒。結果（exit code）を PROGRESS に書く
    - (g) §4.8: `tests/test_extended_datetime.mojo:842-844` / `:877-879` の早期 `return` の直前に `print("SKIP test_interval_infinity_on_pg17_and_later: server < 17")` /
      `print("SKIP test_interval_infinity_rejected_before_pg17: server 17+")`（**訂正（T1 実装時）**: 元の文言「server is older than 17」/「server is 17 or later」は
      80 桁を超えて `mojo format` が割るため縮めた。上記 (d) と同じ理由）。`tests/test_leak.mojo:566-575` `_skip_on_macos` に `name: StaticString` 引数を足して
      `print("SKIP ", name, ": RSS sampling is Linux-only", sep="")` にし、**10** 箇所の呼び出し（`grep -c '_skip_on_macos()' tests/test_leak.mojo` = 10。
      **訂正（T1 実装時）**: PLAN の 11 は数え違い。実測 10）に自関数名を渡す。
      `pixi run test` のログに `-- 127.0.0.1:54317 skipped 1`（PG17: `rejected_before_pg17` が SKIP）と `-- 127.0.0.1:54314 skipped 1`（PG14: `on_pg17_and_later`）が出る（Linux では leak の SKIP は出ない）
    - (h) §4.9 / RESEARCH §3-10: `src/pq/decode_binary.mojo` に `def _string_payload[origin: ImmOrigin, //](bytes: Span[UInt8, origin], oid: UInt32) raises PgError -> Span[UInt8, origin]`
      （jsonb 3802: `len < 1` → `_binary_length_error("jsonb", len, 1)`、`bytes[0] != _JSONB_VERSION` → `_binary_value_error("jsonb", "version byte is N, expected 1")`、`bytes[1:]` を返す。
      25 / 1043 / 1042 / 19 / 114 はそのまま返す。他は `_binary_oid_error(oid, "String")`）。`decode_binary[String]`（`:706-726`）と `Row.get_text`（`result.mojo:746-765`）の両方がこれを呼ぶ形に書き換え、
      メッセージは一字も変えない（`tests/test_decode_binary.mojo` / `tests/test_zero_copy.mojo` / `tests/test_binary.mojo` が無変更で PASS）。`tests/test_decode_binary.mojo` に `_string_payload` を直接呼ぶ 1 件
      （jsonb `01 7b7d` → `7b7d`、oid 25 はそのまま、oid 23 → `TYPE_MISMATCH` + `"oid 23"`）
    - (i) `pixi run test` 両サーバー PASS（既存テストの期待値変更**ゼロ**: 変えてよいのは (b)(d) の docstring / 分岐と、追加分だけ）、`pixi run check` 6/6 PASS。
      チェックリストスクリプトを実行し T1 の行（`params_*` / `testconn_*` / `timetz_*` / `datetime_*` / `compose_*` / `run_tests_*` / `tests_print_SKIP` ≥ 3 / `leak_old_SKIP_colon` 0 / `string_payload_*` / `jsonb_version_checks` / `oid_varchar_checks` / `test_decode_binary_tests`）が期待値。所要を PROGRESS に単位付きで
  - 対象: `src/pq/params.mojo`, `src/pq/decode_binary.mojo`, `src/pq/result.mojo`, `tests/test_connection.mojo`, `tests/test_decode_binary.mojo`, `tests/test_extended_datetime.mojo`, `tests/test_leak.mojo`, `tests/docker-compose.yml`, `tests/run_tests.sh`
  - 依存: なし
  - 並列サブ作業（推奨本数: **1**。(h) は 2 ファイル完結で他と重ならない）:
    - A: (h) §4.9 の `_string_payload` + `decode_binary[String]` の書き換え + `tests/test_decode_binary.mojo` の 1 件（対象: `src/pq/decode_binary.mojo`, `tests/test_decode_binary.mojo`。**`result.mojo` は触らない**。(c) の timetz もこの 2 ファイルなので A に渡す）
    - 親: (a)(b)(d)(e)(f)(g) + `result.mojo` の `get_text` を `_string_payload` に差し替え + (i)

- [x] T2: Phase 4 の土台 — `adopt_result` の抜き出し（D5）+ `PgErrorKind.TIMEOUT`（D11）+ `_ffi` 2 バインド（§4.5）+ `_platform/poll`（§4.1 / D7）+ `tests/test_poll.mojo`
  - 完了基準:
    - (a) D5 / RESEARCH §3-3 / P27: `src/pq/connection.mojo:64-82` の `_error_field` と `:613-691` の `_take_result` 本文を `src/pq/result.mojo` のモジュール関数
      `def adopt_result(pq: Pointer[LibpqFFI, MutUntrackedOrigin], conn: PGconnPtr, res: PGresultPtr) raises PgError -> Result`（**決めた事項 4**）に移す。
      `Connection._take_result(self, res)` は `return adopt_result(self._pq, self._conn, res)` の 1 行 + docstring 1 文（「`adopt_result` に委譲。分類はそちらの docstring」）。
      成功判定に `PGRES_SINGLE_TUPLE` を足す（`status == PGRES_TUPLES_OK or status == PGRES_COMMAND_OK or status == PGRES_SINGLE_TUPLE`。同期側では到達しない）。
      `_ffi.types` の import を `result.mojo` に足す（`PG_DIAG_*` / `PGRES_*` / `CONNECTION_BAD` / `PGconnPtr`）。`connection.mojo` から不要になった import を消す（`mojo precompile` の警告ゼロ）
    - (b) D11: `src/pq/errors.mojo:39-44` の後に `comptime TIMEOUT = Self(6)` + docstring（「`timeout_ms` 以内に待っている状態変化が来なかった。接続は使える」）、`write_to`（`:68-85`）に `Timeout`、
      `:3`「six failure categories」/ `:13`「exactly six constants」→ seven + `TIMEOUT` を列挙。`src/pq/__init__.mojo:172-194`（`## PgErrorKind` 節）の「exactly six」→ seven、箇条書きに `TIMEOUT` (`Timeout`) を 1 行。
      `tests/test_errors.mojo` に `PgErrorKind.TIMEOUT.value == 6` と `String(PgErrorKind.TIMEOUT) == "Timeout"` の 1 件（既存の形に倣う）
    - (c) §4.5: `src/pq/_ffi/functions.mojo` に `PQsetSingleRowMode: def(PGconnPtr) thin abi("C") -> c_int  # libpq-fe.h:528` と `PQconnectStart: def(CStr) thin abi("C") -> PGconnPtr  # libpq-fe.h:327`
      （宣言 + `__init__` の `_dl_sym`。**決めた事項 5** の理由）。`tests/test_ffi.mojo:40-92` の名前表に 2 名、`:102` の `assert_equal(len(names), 53)` → 55
    - (d) §4.1 / D7 / RESEARCH §2.3・§3-15: `src/pq/_platform/__init__.mojo`（モジュール docstring 1 行だけ）と `src/pq/_platform/poll.mojo`（**決めた事項 1**）。
      `comptime if CompilationTarget.is_linux(): ... elif CompilationTarget.is_macos(): ... else: ...`（RESEARCH §0.5 ☆。`is_windows` は無い）。`else` が Windows（`WSAPoll` / `WSAPOLLFD` 16 byte / 別の定数値。**未検証**とモジュール docstring に明記。P8）。
      `external_call` は `poll`（Linux / macOS）と `WSAPoll`（else）だけ（P7。errno は `std.ffi.get_errno`）。`EINTR` は `std.time.monotonic()` の締め切りから残り ms を再計算して再試行（`timeout_ms == -1` なら再計算なしで再試行。P4）。
      `POLLNVAL` → `USAGE`（P5）。`timeout_ms < -1` → `USAGE`（P6）。`ret == -1` で `EINTR` 以外: `EBADF` / `EINVAL` → `USAGE`、他 → `CONNECTION`（errno の文言を message に。`ErrNo` は `Writable`）。
      戻りの判定順は RESEARCH §3-14（`POLLNVAL` → `USAGE`；`POLLIN` / `POLLOUT` が立っていれば `readable` / `writable`（`hangup` / `error` も同時に True になり得る）；ret 0 → `timeout` だけ True）
    - (e) `tests/test_poll.mojo`（サーバー不要。`external_call["pipe", c_int]` / `external_call["socketpair", c_int]` と `external_call["close", c_int](c_int(fd))`、書き込みは `std.io.FileDescriptor(fd).write("A")`。RESEARCH §0.5 ☆ の衝突を踏まない。
      雛形は `scratch/turn-001-probe-poll.mojo`）。RESEARCH §2.3 の実測表をそのまま 7 件以上:
      ① 空の pipe 読み側 `want_read`、`timeout_ms=50` → `timeout == True`、経過 45〜200 ms（`monotonic()`）；② pipe 書き側 `want_write`、0 → `writable`；③ 1 byte 書いた後の読み側、0 と -1 → `readable`（-1 でも即返る）；
      ④ 書き側 close 後の読み側（未読 1 byte）→ `readable == True` かつ `hangup == True`（17）；⑤ 両端 close 済み fd → `USAGE` でメッセージに `"not open"`（P5。ret 1 + `POLLNVAL`）；
      ⑥ `timeout_ms = -2` → `USAGE` でメッセージに `"timeout_ms must be"`（P6）；⑦ socketpair の片側で相手 close 後 `want_read` → `readable` + `hangup`（17）、`want_write` → `writable` + `hangup`（20）；
      ⑧ `want_read = want_write = False`、`timeout_ms = 10` → `timeout`、経過 ≥ 10 ms（純粋な sleep）。
      `EINTR` はテストしない（P4 はコードレビュー: `get_errno() == ErrNo.EINTR` の分岐と `monotonic()` の再計算が `poll.mojo` にある。PROGRESS に該当行番号を書く）
    - (f) `pixi run test` 両サーバー PASS（**既存テストの期待値変更ゼロ**。`test_errors` / `test_ffi` / `test_poll` の追加分だけ）、`pixi run package` 警告ゼロ、`pixi run check` 6/6。
      チェックリストの T2 行（`conn_*` / `result_*` / `errors_*` / `init_exactly_six` / `init_TIMEOUT` / `ffi_*` / `testffi_*` / `platform_*` / `poll_*` / `test_poll*`）が期待値
  - 対象: `src/pq/connection.mojo`, `src/pq/result.mojo`, `src/pq/errors.mojo`, `src/pq/__init__.mojo`, `src/pq/_ffi/functions.mojo`, `src/pq/_platform/__init__.mojo`, `src/pq/_platform/poll.mojo`, `tests/test_errors.mojo`, `tests/test_ffi.mojo`, `tests/test_poll.mojo`
    （**追加（T2 実装時）**: `src/pq/transaction.mojo` — `from pq.connection import Connection, _error_field`（`:75`）があり、移動先の `pq.result` から取るよう 1 行直す。PLAN の対象一覧に漏れていた。`src/pq/_ffi/__init__.mojo` の「50 libpq entry points」も 55 に）
  - 依存: T1
  - 並列サブ作業（推奨本数: **1**。`_platform/poll` + `test_poll` は 2 ファイル完結で他と重ならない）:
    - A: (d)(e) `src/pq/_platform/__init__.mojo` + `src/pq/_platform/poll.mojo` + `tests/test_poll.mojo`（契約は決めた事項 1。**最初に `poll_socket` 1 本 + テスト①をコンパイルしてから**残りを書く）
    - 親: (a)(b)(c)(f)

- [x] T3: `AsyncConnection` 接続・送信・受信・状態機械・ブロッキング補助（`src/pq/async_conn.mojo` 前半）+ `__init__.mojo` 再エクスポート + `tests/test_async.mojo` 第 1 弾（受け入れ §5.1 の 1・4 件目）
  - 完了基準:
    - (a) `src/pq/async_conn.mojo`（新設）: **決めた事項 2**（`AsyncState` / `PollState`）、**決めた事項 3**（`Notification` は struct 定義だけ先に置く。T4 が使う）、**決めた事項 6**（`AsyncConnection` のフィールドと接続・送信・受信 API）、
      **決めた事項 7**（`state()` 遷移）、**決めた事項 8**（`USAGE` 格子の文言）、**決めた事項 9**（ブロッキング補助）。この時点で実装するメソッド:
      `start(var conninfo: String)` / `start(params: Dict[String, String])` / `poll_connect()` / `socket()` / `state()` / `status()` / `transaction_status()` /
      `send(var sql)` / `send(var sql, params, result_format)` / `send_prepare(var name, var sql, param_types)` / `send_prepared(var name, params, result_format)` / `flush()` /
      `consume_input()` / `is_busy()` / `poll_result()` / `wait_readable(timeout_ms)` / `wait_writable(timeout_ms)` / `connect_blocking(var conninfo, timeout_ms)` / `connect_blocking(params, timeout_ms)` / `fetch_all(timeout_ms)` / `__deinit__`。
      `cancel` / `notifications` / `wait_notification` / `set_single_row_mode` は T4（`_single_row_allowed` フラグの上げ下げは T3 で入れておく）。
      `start` は `PQstatus == CONNECTION_BAD` なら message を取ってから `PQfinish` し `CONNECTION`（P1。`PQsetnonblocking` を呼ばない）。`PQsetnonblocking(1)` が -1 → `PQfinish` + `CONNECTION`。
      `poll_connect` は D13 の SET を組み込む（RESEARCH §3-4: 結果 **2 件 + NULL** を `adopt_result` で取り切る。P10）。`PGRES_POLLING_FAILED` / `ACTIVE` / 他 → `CONNECTION`（P33）。
      `send*` は `_reject_nul` → 状態検査（`IDLE` 以外は `USAGE`。libpq に届かせない。P9 / P34）→ `PQsend*`（0 → `CONNECTION` with `PQerrorMessage`）→ `PQflush`（0 → `BUSY`、1 → `SENDING`、-1 → `CONNECTION`）→ `_single_row_allowed = True`。
      `PQsendQueryParams` 後の `_ParamBuffers` は `_ = buffers^` で呼び出しの後に解放（RESEARCH §2.1 I: libpq は呼び出し中にコピー済み）。
      `poll_result` は raise の前に状態を変えない（P11）。`consume_input` が 0 → `CONNECTION`、状態は `BUSY` のまま（P21 / P32）。`is_busy()` は「結果が揃ったか」だけで切断検出に使わない（P32。docstring に明記）。
      `wait_*` は毎回 `PQsocket` を読み直す（P3）。`-1` なら `CONNECTION`（`"no socket"`）。`wait_readable` の docstring に「`SENDING` のときは先に `flush()`。readable だけ待つとデッドロックし得る（libpq-async）」（RESEARCH §3-13）。
      `fetch_all` は `SENDING` なら `wait_writable` + `flush()` を先に（ruby-pg :2578）、エラー結果は `first_error` に保存して NULL まで取り切ってから投げる（D16 / P14）、締め切りは全体（RESEARCH §3-8）。
      `__deinit__` は `PQfinish` だけ（D16 / P22）。`cancel()` の docstring は T4
    - (b) `src/pq/__init__.mojo`: `from .async_conn import AsyncConnection, AsyncState, Notification, PollState`、`:3-7` の Layout 行に「Phase 4 adds `_platform/poll` and `async_conn`」、
      新節 `## Asynchronous use`（15〜25 行: 状態機械の図 `Connecting → Idle → (send) → Sending | Busy → (poll_result が None で state Idle) → Idle`、`wait_*` と `connect_blocking` / `fetch_all` / `wait_notification`、`TIMEOUT` の意味、`cancel` と NOTIFY は T4 で追記）。
      `src/pq/connection.mojo:164-165` の「Phase 4's asynchronous connect will send the same SQL as its first query step」→「`AsyncConnection.poll_connect` sends the same SQL as its first query step」
    - (c) `tests/test_async.mojo`（新設。雛形は `tests/test_connection.mojo:54-120` のラッパー群。`raises PgError` → `Error` 変換のヘルパ `_start` / `_connect_blocking` / `_send` / `_fetch_all` / `_poll_result` / `_wait_readable` / `_error_of(...)`。
      **訂正（T3 実装時）**: `_error_of(...)` は Mojo にクロージャ引数の形が無いので入口ごとに分けた —
      `_connect_blocking_error` / `_send_error` / `_fetch_all_error` / `_poll_result_error` / `_wait_readable_error`。
      成功側は `_connect_blocking_params` / `_send_params` / `_send_prepare` / `_send_prepared` / `_poll_connect` / `_wait_writable`、
      読み出しは `_text_at` / `_int32_at` / `_int64_at` / `_column_format`、待ちは `_wait_readable_allowing_timeout` / `_poll_to_idle`、経過は `_elapsed_ms`。T5 はこの名前に追記する）。
      両サーバー同一期待値。第 1 弾は次の 8 件以上:
      ① `connect_blocking(_conninfo(), 5000)` が成功し `state() == AsyncState.IDLE`、`status() == CONNECTION_OK`、`transaction_status() == PQTRANS_IDLE`、`socket() >= 0`；`send("SHOW DateStyle")` → `fetch_all(5000)` が 1 件で `get[String](0) == "ISO, YMD"`、`SHOW IntervalStyle` → `"postgres"`（D13 / P10）；
      ② `connect_blocking(_params(), 5000)`（Dict 版）でも ①の `DateStyle`；
      ③ **手動ポーリング**: `start` → `state() == CONNECTING`、`poll_connect()` の最初の戻りが `NEED_READ` または `NEED_WRITE`（断定しない。P2）→ 戻り値に応じて `wait_readable(2000)` / `wait_writable(2000)` → `READY` まで。`READY` 後 `state() == IDLE`。`READY` 後にもう 1 回 `poll_connect()` を呼んでも `READY`；
      ④ **受け入れ §5.1-1（pg_sleep カウンタ）**: `send("SELECT pg_sleep(2), 1")` → ループ `poll_result()`: `None` かつ `state() == BUSY` ならカウンタ +1 して `wait_readable(100)`（`TIMEOUT` は捕まえて続行）→ `Some` が来たら `get[Int32](1) == 1`、次の `poll_result()` が `None` で `state() == IDLE`。
      判定は「カウンタ ≥ 1 **かつ** 経過 ≥ 2,000 ms（`monotonic()`）」（REQ §4.7。実測は 20 回 / 2,006 ms）。終端は ⑥ と同じ `_poll_to_idle`；
      ⑤ 多文 `send("SELECT 1; SELECT 2; SELECT 3")` → `fetch_all(5000)` が 3 件、各 `get[Int32](0)` が 1 / 2 / 3（RESEARCH F3）；`send("")` → `fetch_all` が `SERVER` で message `"empty query"`（F4。`adopt_result` 流用の確認）；
      ⑥ エラー後の復帰（P11）: `send("SELECT 1/0")` → `poll_result()` をループ（`None` + `BUSY` なら `wait_readable(2000)`）→ `SERVER 22012` が raise → raise 直後は `state() == BUSY`、
      **`poll_result()` を `IDLE` になるまでループ**して終端（**訂正（T3 実装時）**: 元の「もう 1 回 `poll_result()` が `None` で `state() == IDLE`」は不成立。
      終端 NULL は別ラウンドトリップで届くので 1 回目は `None` + `BUSY` になり得る——実測で約 1/5 の頻度で失敗した。`None` の意味は契約どおり
      「`BUSY` ならまだ、`IDLE` なら終了」なので、テスト側はループが正。ヘルパ `_poll_to_idle` に集約し ④ でも使う）→ `send("SELECT 1")` が成功し値 1；
      ⑦ **受け入れ §5.1-4（タイムアウト）**: `connect_blocking("host=127.0.0.1 port=54399 user=pq password=pq dbname=pq_test", 500)` が `TIMEOUT` でメッセージに `"timed out after"`、経過 500 ms 以上 1,500 ms 未満（P23。`connect_timeout` は conninfo に入れない）。
      54399 が接続拒否（`CONNECTION` で message に `"Connection refused"`）なら `print("SKIP test_connect_blocking_times_out: port 54399 refused (blackhole not running)")` して return（P30）。
      `wait_readable(50)`（アイドル接続）→ `TIMEOUT`、`wait_writable(0)`（アイドル接続）→ 例外なし（書ける）（P24）；
      ⑧ パラメータ送信: `send("SELECT $1::int4 + 1, $2::text", [Int32(41), "hello-param"], result_format=ResultFormat.BINARY)` → `fetch_all` 1 件、`column_format(0) == BINARY`、値 42 / `"hello-param"`（RESEARCH I）；
      `send_prepare("p1", "SELECT $1::int8 * 2")` → `fetch_all` 1 件（`command_tag() == ""`。async2 B）→ `send_prepared("p1", [Int64(21)])` → 42；`send_prepared("nope", [])` → `fetch_all` が `SERVER 26000`；
      ⑨ 未接続 send（`USAGE` 格子の 1 列目）: `start` 直後の `send("SELECT 1")` が `USAGE` でメッセージに `"called while Connecting"`（決めた事項 8）。残りの格子は T5
    - (d) 期待値の取り直し（REQ §9 常設）: 親が同期 `Connection` で `SHOW DateStyle` / `SELECT 1/0` の sqlstate `22012` / `"empty query"` を取り直して期待と一致することを PROGRESS に 1 行
    - (e) `pixi run test` 両サーバー PASS、`pixi run package` 警告ゼロ、`pixi run check` 6/6。チェックリストの T3 行（`async_conn` / `async_struct` / `async_state_struct` / `pollstate_struct` / `notification_struct` / `async_public_defs` ≥ 20 / `async_called_while` ≥ 6 /
      `init_async_import` / `conn_phase4_future` / `init_phase4` / `test_async` / `test_async_tests` ≥ 8 / `tests_print_SKIP` +1 / `src_PQexec_calls` = 4）が期待値。`test_async` の所要（`took Ns`）を PROGRESS に
  - 対象: `src/pq/async_conn.mojo`, `src/pq/__init__.mojo`, `src/pq/connection.mojo`（docstring 1 文）, `tests/test_async.mojo`
  - 依存: T2
  - 並列サブ作業（推奨本数: **1**。`async_conn.mojo` は 1 ファイルで分けられない。テストは契約から並行して書ける）:
    - A: `tests/test_async.mojo`（対象: その 1 ファイル。決めた事項 2・6〜9 の契約どおりに書き、親が統合後にコンパイルを通す。**ヘルパ名は上記 (c) のとおり**。T5 が同じファイルに追記するので `# --- 第 2 弾は T5 ---` の区切りコメントを末尾に）
    - 親: `async_conn.mojo`（**最初に `AsyncState` / `PollState` / `start` / `poll_connect` / `connect_blocking` + テスト①をコンパイルして通してから**残りを書く。Phase 2 reflect Minus 3）+ (b)(d)(e)

- [x] T4: `cancel()` / `notifications()` / `wait_notification()` / `set_single_row_mode()`（`async_conn.mojo` 後半）+ `tests/test_async.mojo` 追記（受け入れ §5.1-2）+ `tests/test_notify.mojo` 最小（受け入れ §5.1-3）+ examples 2 本 + `pixi.toml` / `final_check.sh`
  - 完了基準:
    - (a) `src/pq/async_conn.mojo` に **決めた事項 10**（`cancel`）、**決めた事項 11**（`notifications` / `wait_notification` と `_pending` キュー）、**決めた事項 12**（`set_single_row_mode` のクライアント側ガード）。
      `cancel()`: `BUSY` / `SENDING` のときだけ `PQgetCancel`（NULL → `CONNECTION` with `PQerrorMessage`）→ `PQcancel(c, errbuf, 256)`（errbuf は `List[UInt8](capacity=256)` を 256 個の 0 で埋めた `unsafe_ptr()`）→ **errbuf を `String` に読んでから** `PQfreeCancel`（P17）→ 0 なら `CONNECTION`（message は errbuf の文言）。
      `IDLE` は no-op（D11 / P16）、`CONNECTING` は `USAGE`（RESEARCH §5-6 採用）。docstring に P31（「cancel 要求は TLS で保護されない（PG18 docs は `PQcancel` を deprecated / insecure と記す）。`PQcancelBlocking`（17+）への切替は Phase 5 以降の判断」）。
      `notifications()`: `CONNECTING` → `USAGE`；`PQconsumeInput`（0 → `CONNECTION`）→ `_pending` を先頭に、`PQnotifies` を NULL まで（`Pointer[PGnotify, MutUntrackedOrigin](unsafe_from_address=n._addr)[]` で読み、`relname` / `extra` を `String(unsafe_from_utf8_ptr=CStr(unsafe_from_address=...))` に複製してから `PQfreemem(MutRawPtr(unsafe_from_address=n._addr))`。P19）。
      `wait_notification(timeout_ms)`: 締め切りループ（`notifications()` が空なら `wait_readable(残り)`；`TIMEOUT` は `None` に写す。D8）。1 件目を返し残りは `_pending`。
      `set_single_row_mode()`: `_single_row_allowed` が偽なら `USAGE`（libpq の戻り値は信用しない。P13）、真なら `PQsetSingleRowMode`（0 → `USAGE`、起こらない想定）
    - (b) `tests/test_async.mojo` に追記（T3 の区切りの前に `# --- T4 ---` 節）:
      ① **受け入れ §5.1-2（cancel）**: `send("SELECT pg_sleep(10)")` → `wait_readable(100)` を 1 回（`TIMEOUT` を捕まえる）→ `t0 = monotonic()` → `cancel()` → `fetch_all(5000)` が `SERVER` で `sqlstate == "57014"`、message に `"canceling statement"`、`monotonic() - t0 < 1,000 ms`（実測 1〜4 ms。P15）→ `state() == IDLE`、`send("SELECT 42")` → 42（接続は使える）；
      ② アイドル cancel: `cancel()` が例外なし、直後の `send("SELECT 1")` → 1（D11 / RESEARCH E）；
      ③ single-row 正例（P13 / P14）: `send("SELECT generate_series(1,3)")` → `set_single_row_mode()` → `fetch_all(5000)` が **4 件**（`row_count()` 1 / 1 / 1 / 0、値 1 / 2 / 3）、`state() == IDLE`；
      ④ single-row の途中エラー: `send("SELECT 1/(2-generate_series(1,2))")` → `set_single_row_mode()` → `fetch_all(5000)` が `SERVER 22012`、その後 `state() == IDLE`、`send("SELECT 1")` 成功（P14。残りを取り切ってから投げる）
    - (c) `tests/test_notify.mojo`（新設。ヘルパは `test_async.mojo` と同形で自前に持つ（import しない）。同期 `Connection` を通知側に使う）。最小 3 件:
      ① **受け入れ §5.1-3**: async `send("LISTEN pq_t4")` → `fetch_all` → 同期 `Connection.open(_conninfo())` で `execute("NOTIFY pq_t4, 'payload-1'")` と `execute("NOTIFY pq_t4")`（2 文を別 `execute` で）→ `wait_notification(2000)` を 2 回で 2 件、`channel == "pq_t4"`、payload が順に `"payload-1"` / `""`、
      `backend_pid` が通知側の `SELECT pg_backend_pid()` と一致（親が同期 `Connection` で取り直す。P18）→ 3 回目 `wait_notification(200)` が `None`（P24）；
      ② `notifications()` を `PQconsumeInput` 前（NOTIFY 送信前）に呼ぶと空 `List`、例外なし；
      ③ `wait_notification(50)`（通知なし）が `None` で経過 ≥ 50 ms
    - (d) §4.6 / D16: `examples/async_query.mojo`（`connect_blocking(_conninfo(), 5000)` → `send("SELECT pg_sleep(2), 1")` → `poll_result()` が `None` のあいだカウンタ +1 と `wait_readable(100)`（`TIMEOUT` は無視）→ 結果の値と最終カウンタを `print`）、
      `examples/listen_notify.mojo`（async `LISTEN pq_example` → 同期 `Connection` で `NOTIFY pq_example, 'hello from pq'` → `wait_notification(2000)` → `channel` / `payload` / `backend_pid` を `print`。`None` なら `no notification within 2 s` を出して終了コード 0。RESEARCH §5-10）。
      どちらも `examples/basic.mojo` の形（`from pq import ...` だけ、`PQ_TEST_CONNINFO`、`PgError` は `print` + `exit(1)`）。
      `pixi.toml:17-19` の並びに `example-async = "mojo run -I src examples/async_query.mojo"` / `example-notify = "mojo run -I src examples/listen_notify.mojo"`、`tests/final_check.sh:122-124` の後に `run_logged mojo run -I src examples/async_query.mojo || examples_failed=1` と `listen_notify` の 2 行
    - (e) `src/pq/__init__.mojo` の `## Asynchronous use` 節に `cancel`（`57014`、tx 内は `INERROR` → `ROLLBACK`）と `LISTEN` / `NOTIFY`（`wait_notification`、1 回で全件揃わないこと）を追記
    - (f) 期待値の取り直し: 親が同期 `Connection` で `pg_backend_pid()` / `57014` の message（`canceling statement due to user request`）/ NOTIFY の payload を取り直して PROGRESS に 1 行
    - (g) `pixi run test` 両サーバー PASS、`pixi run example-async` / `example-notify` 単体で成功、`pixi run check` 6/6（4/6 段に新 2 本）。チェックリストの T4 行（`async_cancel_insecure` / `src_PQfreemem_calls` 3 / `src_PQfreeCancel_calls` 1 / `test_notify*` / `example_*` / `pixi_example_tasks` / `final_check_*`）が期待値
  - 対象: `src/pq/async_conn.mojo`, `src/pq/__init__.mojo`, `tests/test_async.mojo`, `tests/test_notify.mojo`, `examples/async_query.mojo`, `examples/listen_notify.mojo`, `pixi.toml`, `tests/final_check.sh`
  - 依存: T3
  - 並列サブ作業（推奨本数: **1**。examples + pixi + final_check は契約から書けて他と重ならない）:
    - A: (d) `examples/async_query.mojo` + `examples/listen_notify.mojo` + `pixi.toml` + `tests/final_check.sh`（対象: その 4 ファイル）
    - 親: (a)(b)(c)(e)(f)(g)

- [x] T5: テスト格子（**`src/` は原則触らない**。テストが露わにしたバグの修正だけ許す）— `tests/test_async.mojo` 第 2 弾 + `tests/test_notify.mojo` 完成 【REQ §9 の実験: 「src を触らずテスト 2 ファイル」型を **1 本** で】
  - 完了基準:
    - (a) `tests/test_async.mojo` 第 2 弾（RESEARCH §4 の検証欄をそのまま。12 件以上）:
      ① **USAGE 格子**（P9 / P34。メッセージは決めた事項 8 の自前文言で、libpq の `another command is already in progress` / `no connection to the server` を**含まない**）: 結果待ち中 send（`send("SELECT pg_sleep(0.2)")` 直後の `send("SELECT 1")` → `USAGE` `"called while Busy"`（`SENDING` の可能性もあるので `"called while"` + kind で断定し、状態名は `Busy` か `Sending` のどちらか）；
      最初の結果取得後・NULL 前の send（`send("SELECT 1; SELECT 2")` → `poll_result` で 1 件取った直後 `state() == BUSY` かつ `send` が `USAGE`。RESEARCH G4）；送信前 `set_single_row_mode()`（アイドル）→ `USAGE` `"must follow send()"`；
      `poll_result` 1 回呼んだ後の `set_single_row_mode()` → `USAGE`（P13）；`consume_input()` 後の `set_single_row_mode()` → `USAGE`；接続中（`start` 直後）の `cancel()` / `consume_input()` / `poll_result()` / `notifications()` / `fetch_all(100)` → 全部 `USAGE` `"called while Connecting"`；
      `IDLE` の `poll_result()` → `None`、`fetch_all(100)` → 空 `List`（例外なし）；`wait_readable(-2)` → `USAGE` `"timeout_ms must be"`。
      **陽性対照**（P9）: `send` の状態検査を一時的に外したコピーで「結果待ち中 send」が `CONNECTION` + libpq 文言になることを 1 回実測し PROGRESS に貼る（コピーは `scratch/turn-NNN-usage-positive.mojo`、`src/` は戻す）；
      ② **cancel 4 格子**（P16）: idle（T4 ②で済）/ connecting（①で済）/ busy（T4 ①で済）/ **切断後**: `pg_terminate_backend` で切ってから `cancel()` → `CONNECTION`
      （**訂正（T5 実装時）**: `fetch_all` で結果を取り切ると下記 ④ の修正により状態が `IDLE` になり、`cancel()` は契約どおりの no-op になって `CONNECTION` が出ない。
      切断を**`consume_input()` で観測する**——これが P21 / P32 のとおり状態を `BUSY` のまま残す唯一の入口——と `BUSY` かつ接続が死んだ状態が作れるので、そこで `cancel()` を呼ぶ。
      `consume_input()` は 1 回目では失敗しない（カーネルが farewell と EOF を届けるのに 1〜2 往復かかる。実測 2〜3 回）のでリトライループにする）；
      ③ **tx 内 cancel**（P15 / async2 D）: `send("BEGIN")` → `fetch_all` → `send("SELECT pg_sleep(10)")` → `wait_readable(100)` → `cancel()` → `fetch_all` が `57014` → `transaction_status() == PQTRANS_INERROR` → `send("SELECT 1")` → `fetch_all` が `SERVER 25P02` → `send("ROLLBACK")` → `fetch_all` → `PQTRANS_IDLE`；
      ④ **切断**（P21 / P32）: 別の同期 `Connection` から `SELECT pg_terminate_backend(<async の pg_backend_pid>)`（pid は async で `SELECT pg_backend_pid()` を先に取る）→ async `send("SELECT pg_sleep(5)")` の `fetch_all(5000)` が `SERVER 57P01` **または** `CONNECTION`（競合。両方許容）→ その後 `send("SELECT 1")` が `USAGE`（`BUSY` のまま）または `CONNECTION`、`poll_result()` を `None` まで呼ぶと途中で `CONNECTION`（sqlstate 空）が出て最終的に `state() == IDLE`、`socket() == -1`、`status() == CONNECTION_BAD`、`send` が `CONNECTION` `"no connection"`（libpq 文言を含んでよい: 自前検査は状態だけで接続生死は libpq に任せる。決めた事項 8）
      （**訂正（T5 実装時）**: このテストが `src/pq/async_conn.mojo` のバグを露わにした。`poll_result` は `PQconsumeInput` が 0 のとき常に `BUSY` を保っていたため、
      接続が死ぬと終端 NULL が永遠に来ず `poll_result` ループが**無限に回り**、以降の `send` がすべて `USAGE "called while Busy"` になっていた（実測: 5 回連続で `Connection` + `Busy`）。
      修正は `poll_result` 専用の私用 `_consume_or_end_command`: `PQconsumeInput` が 0 かつ `PQstatus == CONNECTION_BAD` なら `_state = IDLE` にしてから `CONNECTION` を投げる。
      公開 `consume_input()` は P21 / P32 のとおり `BUSY` を保つまま（上記 ② がこれを使う）。
      修正後は `fetch_all` の drain がそのまま `IDLE` まで進むので、テストは `while state != IDLE: poll_result` で残りを片付けてから `poll_result() == None`・`socket() == -1`・
      `status() == CONNECTION_BAD`・`send` が `CONNECTION "no connection to the server"` を見る形にした。`fetch_all` 直後の状態は競合（`PQstatus` が BAD になるタイミング）なので断定しない）；
      ⑤ **16 MB flush**（P12）: `send(String("SELECT length('", "x" * 16000000, "')"))` → `flush()` を `True` までループ（0 回以上。`False` なら `wait_writable(2000)`）→ `fetch_all(10000)` の `get[Int32](0) == 16000000`。`state()` が `SENDING` だったかは**断定しない**；
      ⑥ **single-row 多文 / prepared**（P13）: `send("SELECT 1; SELECT 2")` + `set_single_row_mode()` → `fetch_all` が **4 件**（1 行, 0 行, 1 行, 0 行）；`send_prepare("sr", "SELECT generate_series(1,$1::int4)")` → `send_prepared("sr", [Int32(2)])` + `set_single_row_mode()` → 3 件；
      ⑦ **multi-host**（P3）: `connect_blocking("host=127.0.0.1,127.0.0.1 port=1,<port> user=pq password=pq dbname=pq_test", 5000)` が成功（`<port>` は `_conninfo()` から取る）；
      ⑧ **接続失敗 2 種**（P1）: `start("host=nonexistent.invalid port=1 user=pq dbname=pq_test")` が `start` 時点で `CONNECTION`（message に `"could not translate host name"`）；`start("host=127.0.0.1 port=1 ...")` は成功し `poll_connect`（必要なら `wait_*` を挟む）が `CONNECTION`（`"Connection refused"`）；
      悪いパスワード（`_conninfo() + " password=WRONG"`）は `connect_blocking(..., 5000)` が `CONNECTION`、message に `"password authentication failed"`、`"WRONG"` を含まない；
      ⑨ **未読結果ありの drop**（P22）: `send("SELECT 1; SELECT 2")` → `wait_readable(2000)` → `consume_input()` → `_ = conn^`（クラッシュ無し。leak は T6）；
      ⑩ **`PQsendQueryParams` 後のバッファ**（RESEARCH I。仕様上の非対称）: `send("SELECT $1::text", [String("hello-param")])` の直後にパラメータを作った `String` を上書き（`var p = String("hello-param"); send(..., [p]); p = "XXXX"`）→ `fetch_all` の値が `"hello-param"`；
      ⑪ NUL を含む sql / name → `TYPE_MISMATCH` `"embedded NUL byte in sql"`（`send` / `send_prepare` / `send_prepared` の 3 経路。
      **注（T3 実装時）**: `name` 引数の方は `_reject_nul(name, "name")` なので `"embedded NUL byte in name"`。`transaction.mojo` の savepoint 名と同じ `what` を使った。
      `send_prepare` は `name` → `sql` の順に検査するので、両方 NUL のときのメッセージは `name` 側）
    - (b) `tests/test_notify.mojo` 完成（5 件以上追加。RESEARCH §2.2 の表の各行）:
      ① クエリ実行中の NOTIFY（P20）: async `send("SELECT pg_sleep(0.3)")` 直後に同期側が `NOTIFY` → async `fetch_all` 後の `notifications()` が 1 件；② payload 7999 byte と UTF-8 `héllo`（`byte_length() == 6`）が一致；③ 通知側 `BEGIN; NOTIFY` では `wait_notification(300)` が `None`、`COMMIT` 後に届く（async2 E2）；
      ④ 自分への NOTIFY（同じ async 接続で `send("NOTIFY pq_self")` → `fetch_all` → `notifications()` が 1 件。async2 E3）；⑤ `wait_notification` が 2 件来たとき 2 回目の呼び出しが `_pending` から即返る（経過 < 50 ms。決めた事項 11 の陽性）；
      ⑥ 切断後の `notifications()` → `CONNECTION`（`PQconsumeInput` 0）
    - (c) 期待値の取り直し: 親が同期 `Connection` で `57P01` / `25P02` / `26000` の message と `could not translate host name` を取り直し PROGRESS に 1 行
    - (d) `pixi run test` 両サーバー PASS、`pixi run check` 6/6。チェックリストの `test_async_tests` ≥ 20 / `test_notify_tests` ≥ 8 / `src_PQexec_calls` 4。**`src/` の差分を PROGRESS に列挙**（バグ修正があれば何を直したか。無ければ「src 差分なし」）。
      PROGRESS「やったこと」に「推奨 1 本 / 実 M 本」
  - 対象: `tests/test_async.mojo`, `tests/test_notify.mojo`（+ バグ修正時のみ `src/pq/async_conn.mojo`）
  - 依存: T4
  - 並列サブ作業（推奨本数: **1**。REQ §9 の実験条件: 親がもう 1 ファイルを書く）:
    - A: (b) `tests/test_notify.mojo` の追記（対象: その 1 ファイル）
    - 親: (a) `tests/test_async.mojo` の追記 + 陽性対照 + (c)(d)

- [ ] T6: `test_leak` に Phase 4 ループ 4 本 + 陽性対照 2 件（REQ §5.2 / §5.3）
  - 完了基準:
    - (a) `tests/test_leak.mojo` に 4 テスト（既存の `_assert_stable` / `_sample` / `MAIN_ITERATIONS` の流儀。1 接続を使い回す。P29）:
      `test_async_execute_does_not_leak`（`AsyncConnection.connect_blocking` 1 本で `send(SELECT repeat('x', PAYLOAD_BYTES))` → `fetch_all(5000)` を **10,000 回**。`pg_sleep` 無し）、
      `test_async_cancel_does_not_leak`（`send("SELECT 1")` → `cancel()` → `fetch_all`（57014 か成功のどちらでも）を **1,000 回**。`PGcancel` の `PQfreeCancel` 経路）、
      `test_notify_receive_does_not_leak`（同期 `Connection` が `NOTIFY ch, '<PAYLOAD_BYTES の 1/8 = 8 KiB 未満 → 7000 byte>'` を 1 回ずつ送り async が `wait_notification(2000)` で受ける × **1,000 回**。`PGnotify` の `PQfreemem` 経路）、
      `test_async_drop_with_pending_results_does_not_leak`（`send("SELECT repeat('x', PAYLOAD_BYTES); SELECT 2")` → `wait_readable` → `consume_input()` → drop（`PQfinish` が未読結果を片付ける。P22）× **1,000 回**（接続ループなので連続 open と同じコスト））。
      `:33`「Fourteen tests」→ Eighteen、箇条書きに Phase 4 の段（4 本と担う解放経路）、`:55-60` の所要に Phase 4 分
    - (b) **陽性対照**（§5.3 / P17 / P19。同じターンで実測し、サンプル列を PROGRESS に貼る）: `cancel()` から `PQfreeCancel` を消したコピー、`notifications()` から `PQfreemem` を消したコピー、の 2 つで
      それぞれ該当ループが FAIL する（`is_leaking` または `_sample` の abort）。コピーは `src/` を直接編集 → 計測 → `git checkout src/pq/async_conn.mojo` で戻す（差分が残っていないことを `git status` で確認）。
      `PGcancel` は数百 byte なので 1,000 回で見えない可能性がある → 見えなければ `cancel` ループの陽性対照は「`ABORT_PAGES` / `TOLERANCE_PAGES` に届かない」と正直に書き、`PQgetCancel` の確保サイズ（`fe-cancel.c`: `PGcancel` ≈ 数百 byte + `raddr`）を根拠に**コードレビュー**で代替（PROGRESS の「未確認」ではなく「契約外」に分類）
    - (c) `pixi run test`（leak は両サーバー）PASS、`pixi run check` 6/6。`-- took Ns` が Phase 3 末（74 s / サーバー）+ 15 s 以内（P29）。チェックリストの `leak_tests` 18 / `leak_Fourteen` 0 / `leak_async_import` ≥ 1
  - 対象: `tests/test_leak.mojo`
  - 依存: T5
  - 並列サブ作業: なし（推奨本数: **0**。1 ファイル完結で実行待ちが支配）

- [ ] T7: UTF-8 検証（§4.10 / D12 / RESEARCH §3-9）+ bench 記録 + docstring の「検証しない」文言の更新
  - 完了基準:
    - (a) `src/pq/decode_binary.mojo` に `def _utf8_first_invalid[origin: ImmOrigin, //](bytes: Span[UInt8, origin]) -> Int`（RFC 3629 表 3-7 の約 30 行。overlong / サロゲート / 末尾切れ / 不正継続バイトを弾き、最初の不正位置を返す。全部正しければ -1）と
      `def _validated_utf8[origin: ImmOrigin, //](bytes: Span[UInt8, origin], column: Int) raises PgError -> StringSlice[origin]`（**決めた事項 13**: 速い経路 `StringSlice[origin](from_utf8=bytes)`（stdlib、位置なし）→ raise したら `_utf8_first_invalid` で N を求め
      `TYPE_MISMATCH` `"invalid UTF-8 at byte N of column M"`。**セル全文を message に入れない**）。`_string_payload`（T1）の呼び出し側 2 箇所と `_text` の 3 経路が使う
    - (b) `src/pq/result.mojo:414-439` `_text` を「`PQgetvalue` + `PQgetlength` で `Span` → `_validated_utf8(span, col)` → `String(slice)`」に（P25。NUL 入り text が切れない。`unsafe_from_utf8_ptr` を使わない）；`:765` `get_text` を `return _validated_utf8(bytes, col)`（origin は `Self.origin`）に；
      `decode_binary.mojo:715,725` を `String(_validated_utf8(payload, column))` に（`decode_binary[String]` は列番号を持たないので `column` 引数を `decode_binary` に足す**か**、`-1` を渡して message を `"of column ?"` にする → **決めた事項 13 で「`decode_binary` に `column: Int = -1` のキーワード引数を足し、`Row.get` が渡す」**）。
      `__init__.mojo` 型マッピング表の text / jsonb 行と `## Zero-copy access` 節 `:111-114`「Neither validates UTF-8」、`result.mojo:712-718`（3.）、`decode_binary.mojo:650-652`、`tests/test_connection.mojo:952`「Text cells are handed to `String` without validation」を
      「UTF-8 を検証し、不正なら `TYPE_MISMATCH`（位置付き、セル本文は含まない）。`client_encoding` は依然 `pq` が設定しない」に書き換え（チェックリスト `docs_not_validated` = 0）
    - (c) `tests/test_decode_binary.mojo` に 6 件以上: RESEARCH §2.6 / §3-9 の 5 バイト列を `decode_binary[String]`（oid 25）に渡し `c3 28`（`61 62 c3 28 63`）→ `TYPE_MISMATCH` message に `"invalid UTF-8 at byte 2"`、`61 e2 82`（末尾切れ）→ `"at byte 1"`、`c0 80`（overlong）→ `"at byte 0"`、`ed a0 80`（サロゲート）→ `"at byte 0"`、`68 c3 a9`（`hé`）→ OK `"hé"`；
      **陽性対照**（P26）: `_utf8_first_invalid` を直接呼び、stdlib が raise する 4 入力で `-1` を返さない（4 件とも位置 ≥ 0）こと + 正しい 2 入力（`68 c3 a9`、空）で `-1`；
      message にセル本文（`abc(` 等）が含まれない（`"\x28"` / `"ab"` が message に無い）；jsonb `01 61 c3 28` → `"at byte 1"`（version byte を剥がした後の位置。決めた事項 13）。
      `tests/test_zero_copy.mojo` に `get_text` の 1 件: サーバーからは不正 UTF-8 を作れない（`E'\xC3\x28'::bytea::text` は PG が拒否。REQ §4.10）ので、`get_text` は正常系の往復（`'héllo'::text` の `byte_length() == 6`）だけ確かめ、不正系は (c) の単体で担保する旨を docstring に
    - (d) `pixi run bench`（`examples/bench_formats.mojo`）を切替**前**（T6 完了時点の木。`git stash` ではなく T7 着手前に 1 回走らせる）と切替**後**で各 2 回走らせ、text 列の decode 時間（Phase 3 実測: text total 75〜80 ms）を PROGRESS に単位付きで記録（受け入れ条件にしない。D12）
    - (e) `pixi run test` 両サーバー PASS（**既存テストの期待値変更ゼロ**。(c) の追加だけ）、`pixi run check` 6/6。チェックリストの T7 行が期待値
  - 対象: `src/pq/decode_binary.mojo`, `src/pq/result.mojo`, `src/pq/__init__.mojo`, `tests/test_decode_binary.mojo`, `tests/test_zero_copy.mojo`, `tests/test_connection.mojo`（docstring）
  - 依存: T6
  - 並列サブ作業（推奨本数: **1**。スキャナ + 単体は 2 ファイル完結）:
    - A: (a) の `_utf8_first_invalid` + `_validated_utf8` + `decode_binary[String]` の差し替え + (c) の `test_decode_binary.mojo`（対象: `src/pq/decode_binary.mojo`, `tests/test_decode_binary.mojo`）
    - 親: (d) の「前」計測を**最初に** → (b) `result.mojo` / `__init__.mojo` / `test_connection.mojo` / `test_zero_copy.mojo` → 統合 → (d) の「後」計測 → (e)

- [ ] T8: 文書の最終整備 + 受け入れ基準の総点検 + 最終判定
  - 完了基準:
    - (a) `src/pq/__init__.mojo` の `## Asynchronous use` 節を公開 API 一覧（`AsyncConnection` の全メソッドと raise する kind）で完成させ、`## PgErrorKind` 節の 7 件・`TIMEOUT` の説明と `HANDOFF.md §7.2` の名前（`start` / `poll_connect` / `socket` / `send` / `poll_result` / `notifications` / `cancel` / `wait_*`）が一致。
      `src/pq/async_conn.mojo` の全公開 struct / メソッドに docstring（3/6 段 = 0）、`_platform/poll.mojo` はモジュール docstring に Windows 未検証
    - (b) 追従先チェックリストスクリプトを**再実行**し、全行が期待値（`absent` が残っていない、`test_file_count` 24、`src_def_ref_return` 0）。出力を `.gsd-lite/TRACE.md` に貼る（REQ §9: 30 行超の表は TRACE.md）
    - (c) `.gsd-lite/TRACE.md` に受け入れ基準対応表: REQ §5.1 の 4 件（§5.1-1 → T3 ④、§5.1-2 → T4 (b) ①、§5.1-3 → T4 (c) ①、§5.1-4 → T3 ⑦）、§5.2 の 4 項目（状態 9 種 × 入力 → T3 / T5 の格子、解放経路 → T6、`Movable` のみ → `grep -c 'Copyable' src/pq/async_conn.mojo` が `Notification` の 1 行だけ、10,000 / 1,000 回 → T6）、§5.3、§5.4 の 5 項目、§4.8〜§4.10 → 各 T。
      それぞれ「担うテスト関数名 / コマンド」と「turn N で PASS」を書く
    - (d) **PROGRESS の全『未確認』行を列挙し、各行を テスト追加 / 契約外と明記 / verify 申し送り のいずれか 1 つに振り分けた表**（REQ §9 impl 項目）を TRACE.md に。「誤った値が黙って返る経路」「状態機械が壊れる経路」を述べた行が残っていればこのターンでテストにする
    - (e) `pixi run fmt` → 差分なし、`pixi run package` 警告ゼロ、**`pixi run check` 6/6 PASS**（所要を書く）、`pixi run test` 両サーバー全 PASS（`grep 'tests run' <log> | grep -vc ' 0 failed'` = 0、SKIP 集計行が各サーバーに出る）。
      `examples/async_query.mojo` / `listen_notify.mojo` を `pixi run example-*` で単体実行（§5.4）
  - 対象: `src/pq/__init__.mojo`, `src/pq/async_conn.mojo`（docstring）, `.gsd-lite/TRACE.md`, `.gsd-lite/PROGRESS.md`
  - 依存: T7
  - 並列サブ作業: なし（推奨本数: **0**。実行待ちと文書）

## 決めた事項

1. **`_platform/poll` の形**（REQ §4.1 / D7 / RESEARCH §2.3・§3-14・§3-15。mojothon/libc と同型）: `src/pq/_platform/poll.mojo` に
   `@fieldwise_init struct PollEvents(Copyable, Movable, TrivialRegisterPassable, Writable)` — `var readable: Bool` / `var writable: Bool` / `var hangup: Bool` / `var error: Bool` / `var timeout: Bool`（`write_to` は `PollEvents(readable=..., ...)`）、
   `def poll_socket(fd: Int, want_read: Bool, want_write: Bool, timeout_ms: Int) raises PgError -> PollEvents`。
   Linux / macOS 分岐: `@fieldwise_init struct _PollFd(TrivialRegisterPassable)`（`fd: Int32` / `events: Int16` / `revents: Int16`。8 byte、`scratch/turn-001-probe-poll.mojo:14-18`）、
   `external_call["poll", c_int](Pointer(to=pfd), Int(1), c_int(timeout_ms))`（`probe-poll.mojo:38-40`。`nfds` は `Int(1)`、glibc 8 byte / macOS 4 byte どちらもレジスタ渡しで可）、
   定数 `POLLIN 0x0001` / `POLLOUT 0x0004` / `POLLERR 0x0008` / `POLLHUP 0x0010` / `POLLNVAL 0x0020`（両 OS 同一。RESEARCH §2.3）。
   `else`（Windows、未検証）: `_WsaPollFd(fd: Int, events: Int16, revents: Int16)`（16 byte）、`external_call["WSAPoll", c_int](Pointer(to=pfd), Int(1), c_int(timeout_ms))`、定数 `POLLIN 0x0300` / `POLLOUT 0x0010` / `POLLERR 0x0001` / `POLLHUP 0x0002` / `POLLNVAL 0x0004`、
   `events` に `POLLERR` / `POLLHUP` / `POLLNVAL` を**入れない**（`WSAEINVAL`。RESEARCH §2.3）。errno は `from std.ffi import get_errno, ErrNo`（`.value` で Int、`== ErrNo.EINTR`。`Int(ErrNo)` は不可）、単調時計は `from std.time import monotonic`（ns）。
   判定順: `timeout_ms < -1` → `USAGE` `"timeout_ms must be -1, 0 or positive (got N)"`；`ret == -1`: `EINTR` → 残り ms を再計算して再試行、`EBADF` / `EINVAL` → `USAGE` `"poll failed: <errno 文言>"`、他 → `CONNECTION` 同文；`ret == 0` → `timeout=True`；
   `revents & POLLNVAL` → `USAGE` `"poll: fd N is not open (POLLNVAL)"`；それ以外は `readable = revents & POLLIN`、`writable = revents & POLLOUT`、`hangup = revents & POLLHUP`、`error = revents & POLLERR`（併存可）。
   `_platform` は private パッケージ（`pq` 直下で再エクスポートしない。`__init__.mojo` にも書かない）
2. **`AsyncState` / `PollState`**（REQ §4.2 / §4.3 / D15。`ResultFormat`（`src/pq/result.mojo:56-107`）と同形）: `src/pq/async_conn.mojo` に
   `@fieldwise_init struct AsyncState(Equatable, TrivialRegisterPassable, Writable)` — `var value: Int`、`comptime CONNECTING = Self(0)` / `IDLE = Self(1)` / `SENDING = Self(2)` / `BUSY = Self(3)`、`write_to` は `Connecting` / `Idle` / `Sending` / `Busy`；
   `@fieldwise_init struct PollState(Equatable, TrivialRegisterPassable, Writable)` — `comptime NEED_READ = Self(0)` / `NEED_WRITE = Self(1)` / `READY = Self(2)`、`write_to` は `NeedRead` / `NeedWrite` / `Ready`（`Failed` は定数にしない。REQ §4.3）。
   `pq` 直下で再エクスポート
3. **`Notification`**（REQ §4.2 / D16）: `@fieldwise_init struct Notification(Copyable, Movable, Equatable, Writable)` — `var channel: String` / `var payload: String` / `var backend_pid: Int`、`__eq__` は 3 フィールド一致、`write_to` は `Notification(channel=..., payload=..., backend_pid=...)`。
   `PGnotify` の読み出しは `_ffi/types.mojo:51-56` の struct を `Pointer[PGnotify, MutUntrackedOrigin](unsafe_from_address=n._addr)[]` で（offset 0 / 8 / 16 / 24 は RESEARCH §2.2 J で照合済み、`tests/test_ffi.mojo:114-115` が 32 byte を確認済み）
4. **`adopt_result`**（D5 / RESEARCH §3-3）: `src/pq/result.mojo` のモジュール関数 `def adopt_result(pq: Pointer[LibpqFFI, MutUntrackedOrigin], conn: PGconnPtr, res: PGresultPtr) raises PgError -> Result`。本文は `connection.mojo:638-691` を**そのまま**移し、
   `:647` の成功判定に `or status == PGRES_SINGLE_TUPLE` を足すだけ。`_error_field`（`connection.mojo:64-82`）も `result.mojo` へ。docstring は `_take_result` の現行（`:614-636`）を移して「`Connection._take_result` と `AsyncConnection.poll_result` / `poll_connect` / `fetch_all` の全部がここを通る」を足す。
   既存テストの期待値は一切変えない（verify が照合。P27）。置き場を `result.mojo` にする理由: `Result` を作る側で、`connection.mojo` → `result.mojo` の import 向きが既にあり循環しない
5. **`_ffi` の追加は 2 本**: `PQsetSingleRowMode`（`libpq-fe.h:528`、REQ §4.5）と **`PQconnectStart`（`libpq-fe.h:327`。REQ §4.5 の「他は既存」からの追加）**。理由: `start(var conninfo: String)` を `PQconnectStartParams` で書くには `dbname=<conninfo>, expand_dbname=1` の変換に頼ることになり、
   同期側 `open(String)` = `PQconnectdb`（`connection.mojo:226`）との対称性が崩れる。`PQconnectStart(const char*)` は `PQconnectdb` の非同期版そのもので、バインドは 2 行。`tests/test_ffi.mojo:102` の件数は 53 → 55
6. **`AsyncConnection` の骨格**（REQ §4.2 / D5 / D16）: `struct AsyncConnection(Movable)`、フィールド `_conn: PGconnPtr` / `_pq: Pointer[LibpqFFI, MutUntrackedOrigin]` / `_state: AsyncState` / `_setup_pending: Bool`（D13 の SET を取り切るまで True）/
   `_single_row_allowed: Bool` / `_pending: List[Notification]`（決めた事項 11）。`__init__(out self, conn, pq)` は `CONNECTING` で始める（`Connection.__init__`（`connection.mojo:115-144`）と同形。`_stmt_counter` / `_rollback_failure_handler` は持たない）。
   `__deinit__(deinit self)` は `if not self._conn.is_null(): PQfinish`（結果が残っていても drain しない）。
   シグネチャ（REQ §4.2 どおり）: `@staticmethod start(var conninfo: String) raises PgError -> AsyncConnection` / `start(params: Dict[String, String])`（`open(Dict)`（`connection.mojo:259-283`）の配列組み立てを**複製**する。4 つの `List` のポインタが互いを指すので関数に抽出しにくい。lean-ctx: 重複 20 行、Phase 5 で見直し）/
   `poll_connect(mut self) raises PgError -> PollState` / `socket(self) -> Int` / `state(self) -> AsyncState` / `status(self) -> Int` / `transaction_status(self) -> Int` /
   `send(mut self, var sql: String) raises PgError` / `send(mut self, var sql: String, params: List[Param], result_format: ResultFormat = ResultFormat.TEXT) raises PgError` /
   `send_prepare(mut self, var name: String, var sql: String, param_types: List[UInt32] = List[UInt32]()) raises PgError`（hints の `capacity=len+1` ダミーは `connection.mojo:564-570` と同じ）/
   `send_prepared(mut self, var name: String, params: List[Param], result_format: ResultFormat = ResultFormat.TEXT) raises PgError` / `flush(mut self) raises PgError -> Bool` / `set_single_row_mode(mut self) raises PgError` /
   `consume_input(mut self) raises PgError` / `is_busy(mut self) -> Bool` / `poll_result(mut self) raises PgError -> Optional[Result]` / `cancel(self) raises PgError` / `notifications(mut self) raises PgError -> List[Notification]` /
   `wait_readable(self, timeout_ms: Int) raises PgError` / `wait_writable(self, timeout_ms: Int) raises PgError` / `@staticmethod connect_blocking(var conninfo: String, timeout_ms: Int) raises PgError -> AsyncConnection`（Dict 版も）/
   `fetch_all(mut self, timeout_ms: Int) raises PgError -> List[Result]` / `wait_notification(mut self, timeout_ms: Int) raises PgError -> Optional[Notification]`。
   `transaction()` / `prepare()` / `execute()` は作らない（REQ §3）。`async_conn.mojo` に `PQexec(` は書かない
7. **`state()` の遷移規則**（D14 / D15 / RESEARCH §3-5、§2.1 G4）: `CONNECTING`（`start` 〜 `poll_connect` が `READY` を返すまで。D13 の SET 取り切り中も `CONNECTING`）→ `IDLE` →（`send*` 成功）→ `PQflush` 1 なら `SENDING`、0 なら `BUSY` →（`flush()` が 0 を得る）→ `BUSY` →（`poll_result` が NULL を見る）→ `IDLE`。
   **`PQisBusy` が 0 でも NULL を見るまで `BUSY`**。`adopt_result` の raise では状態を変えない（`BUSY` のまま。P11）。`consume_input` 0 → `CONNECTION` を投げ `BUSY` のまま（次の `poll_result` が sqlstate 空の FATAL → `adopt_result` が `CONNECTION`、その次が NULL → `IDLE`。RESEARCH §2.1 切断行）。
   `poll_result` の手順: `CONNECTING` → `USAGE`；`IDLE` → `None`（例外にしない）；`SENDING` → まず `flush()`（まだ 1 なら `PQconsumeInput` → `None`）；`PQconsumeInput`（0 → `CONNECTION`）→ `_single_row_allowed = False` → `PQisBusy` 真 → `None`（状態そのまま）→ `PQgetResult` NULL → `IDLE`・`None`；非 NULL → `adopt_result` → `Some(Result)`。
   `poll_connect` は `CONNECTING` 以外では `READY` を返す（冪等。`PQconnectPoll` を呼ばない）。`poll_connect` の手順: `_setup_pending` なら `PQflush`（1 → `NEED_WRITE`）→ `PQconsumeInput`（0 → `CONNECTION`）→ `PQisBusy` 真 → `NEED_READ` → `PQgetResult` を NULL まで（非 NULL は `adopt_result` に通して捨てる。失敗は同期側と同じ分類（`SERVER` with sqlstate か `CONNECTION`。`connection.mojo:182-184`。
   REQ §4.2 の「SET が失敗したら `CONNECTION`」は「同期側と同じ kind」の意味で、同期側は `_take_result` の分類 = `SERVER` なのでそれに合わせる）。途中で `PQisBusy` が真に戻ったら `NEED_READ`）→ NULL で `_setup_pending = False`・`IDLE`・`READY`；
   `_setup_pending` でなければ `PQconnectPoll`: 1 → `NEED_READ`、2 → `NEED_WRITE`、3 → `PQsendQuery(_SESSION_SETUP_SQL)`（`connection.mojo:51-53` の定数を import。0 → `CONNECTION`）→ `_setup_pending = True` → `PQflush` が 1 なら `NEED_WRITE`、0 なら `NEED_READ`；0 / 4 / 他 → `CONNECTION`（`PQerrorMessage`。P33）
8. **`USAGE` 格子のメッセージ**（D11 / P9 / P34。テストは 2 語以上の部分文字列）: 状態誤りは **`<method>() called while <State>`**（例 `send() called while Busy` / `cancel() called while Connecting` / `poll_result() called while Connecting`）。
   `CONNECTING` で `USAGE` にするもの: `send*` / `flush` / `set_single_row_mode` / `consume_input` / `poll_result` / `cancel` / `notifications` / `fetch_all` / `wait_notification`。`IDLE` で `USAGE` にするもの: `send*` 以外は無し（`poll_result` → `None`、`fetch_all` → 空、`cancel` → no-op、`set_single_row_mode` → `USAGE` だが文言は下）。
   `SENDING` / `BUSY` で `USAGE`: `send*`。`set_single_row_mode` の文言は **`set_single_row_mode() must follow send() before any result is read (state <State>)`**。`wait_*` / `connect_blocking` / `fetch_all` の `timeout_ms` 不正は決めた事項 1 の文言をそのまま。
   自前検査はすべて libpq に届く**前**（libpq の `another command is already in progress` / `no connection to the server` が `USAGE` の message に混ざらない。`PQerrorMessage` は追記式で前のエラーが残るため）。
   接続の生死（切断後の `send` 等）は自前検査しない: libpq が 0 を返し `CONNECTION` + `PQerrorMessage`（`no connection to the server` を含んでよい。Phase 1 方針）
9. **ブロッキング補助**（D8 / D16 / RESEARCH §3-8・§3-13）: `wait_readable(timeout_ms)` = `PQsocket`（-1 → `CONNECTION` `"no socket: connection is closed"`）→ `poll_socket(fd, True, False, timeout_ms)` → `timeout` → `TIMEOUT` **`wait_readable timed out after N ms`**；`readable` → return（`hangup` 併存でも return。libpq に読ませて本当の文言を得る）；
   `hangup` / `error` だけ → `CONNECTION` `"connection socket closed (POLLHUP/POLLERR)"`。`wait_writable` は対称。
   `connect_blocking(conninfo, timeout_ms)` = 締め切り `deadline = monotonic() + timeout_ms * 1_000_000`（`-1` は無期限）→ `start` → `poll_connect` → `NEED_READ` / `NEED_WRITE` なら残り ms で `wait_*`（残り ≤ 0 → `TIMEOUT` **`connect_blocking timed out after N ms`**。`wait_*` の `TIMEOUT` も同文に包み直す）→ `READY` で返す。失敗時は値が破棄され `__deinit__` が `PQfinish`。
   `fetch_all(timeout_ms)` = `CONNECTING` → `USAGE`；`IDLE` → 空 `List`；`SENDING` → `wait_writable(残り)` + `flush()` を 0 まで；ループ `poll_result()`（raise したら `first_error` に保存（最初だけ）して続行）→ `Some` → append、`None` かつ `IDLE` → 終了、`None` かつ `BUSY` → `wait_readable(残り)`。終了後 `first_error` があれば投げる（`TIMEOUT` **`fetch_all timed out after N ms`**）。
   `wait_notification(timeout_ms)` = `_pending` が非空ならその先頭；`notifications()` が非空なら先頭を返し残りを `_pending` に；空なら `wait_readable(残り)`（`TIMEOUT` → `None`）→ 再試行。`-1` 無期限、`0` は 1 回だけ見る
10. **`cancel()`**（D6 / D16 / P16 / P17 / P31）: `state()` が `BUSY` / `SENDING` のときだけ実行。`PQgetCancel` NULL → `CONNECTION`（`PQerrorMessage`）。`errbuf` は `List[UInt8]`（256 個の 0）の `unsafe_ptr()` を `MutCStr(unsafe_from_address=)` で渡す。
   `PQcancel` の戻りを読み、**errbuf を `String(unsafe_from_utf8_ptr=)` で複製してから** `PQfreeCancel`。0 → `CONNECTION`（message = errbuf。空なら `"PQcancel failed"`）。`IDLE` → no-op、`CONNECTING` → `USAGE`。
   `PGcancel` はキャッシュしない。docstring に P31 の注記（`not encrypted` と `PQcancelBlocking` の両語を含める。チェックリスト `async_cancel_insecure`）
11. **`notifications()` と `_pending`**（D1 / P18 / P19 / P20）: `notifications()` は `_pending` を先頭に、`PQconsumeInput`（0 → `CONNECTION`）後の `PQnotifies` を NULL まで足した `List[Notification]` を返し `_pending` を空にする。いつ呼んでもよい（`CONNECTING` 以外）。
   `wait_notification` は 1 件しか返さないので、`notifications()` が 2 件以上返したとき残りを `_pending` に置く（置かないと 2 件目が消える。T5 (b) ⑤ が陽性）
12. **`set_single_row_mode()` のガード**（D9 / P13 / RESEARCH §3-6）: `_single_row_allowed` を `send*` 成功時に True、`poll_result` / `consume_input` / `is_busy` のいずれかで False。False なら `USAGE`（決めた事項 8 の文言）。True なら `PQsetSingleRowMode`（戻り 0 は起こらない想定だが `USAGE` 同文）。
   `PGRES_SINGLE_TUPLE` は `adopt_result` で成功扱い（決めた事項 4）。0 行の `TUPLES_OK` 終端も `Result` として返す（P14）
13. **UTF-8 検証の形**（D12 / RESEARCH §2.6・§3-9 / P25 / P26）: `decode_binary.mojo` に `_utf8_first_invalid(bytes) -> Int`（-1 = 全部正しい）と `_validated_utf8(bytes, column) raises PgError -> StringSlice[origin]`。
   速い経路は `StringSlice[origin](from_utf8=bytes)`（stdlib が raise するのは素の `Error`。`try/except` で受けて位置計算に回す）。message は **`invalid UTF-8 at byte N of column M`**（N はセル先頭からの byte offset。jsonb は version byte を剥がした後の offset。セル本文は入れない）。
   `decode_binary[T]` に `column: Int = -1` のキーワード引数を足し、`Row.get` / `get_optional`（`result.mojo:598,663` の分岐）が `col` を渡す（`-1` のときは `"of column ?"`）。`_text` は `PQgetvalue` + `PQgetlength` の `Span` を `_validated_utf8` に通してから `String` 化（NUL 入り text が切れない）。
   `get_text` の戻り型は `StringSlice[Self.origin]` のまま（`_validated_utf8` の戻りをそのまま返す）。`client_encoding` は触らない
14. **SKIP の形**（§4.8 / D16 / P28）: テスト側は `print("SKIP <test関数名>: <理由>")` の直後に `return`。`run_tests.sh` は各ファイルの出力を `build/last_test.log` に `tee` し `grep -c '^SKIP '` を加算、サーバーごとに `-- <label> skipped N`。終了コードは `${PIPESTATUS[0]}`（`final_check.sh:39-42` と同じ）。
   `final_check.sh` は変えない。陽性対照は `PQ_TEST_CONNINFO` を port=1 にした実行の exit code ≠ 0
15. **テストファイル**: サーバー不要 — `tests/test_poll.mojo`（T2）、`tests/test_decode_binary.mojo` への追記（T1 / T7）、`tests/test_errors.mojo` / `tests/test_ffi.mojo` への追記（T2）；サーバー — `tests/test_async.mojo`（T3 → T4 → T5）、`tests/test_notify.mojo`（T4 → T5）、
   `tests/test_extended_datetime.mojo` / `tests/test_connection.mojo`（T1 docstring）、`tests/test_zero_copy.mojo`（T7）、`tests/test_leak.mojo`（T1 SKIP 形式 / T6）。期待値は RESEARCH §2.1 / §2.2 の sqlstate とメッセージをそのまま（PG17 / PG14 実測）。期待メッセージは 2 語以上の部分文字列
16. **examples / pixi タスク**（§4.6 / D16）: `examples/async_query.mojo` / `examples/listen_notify.mojo`、`pixi.toml` の `example-async` / `example-notify`、`final_check.sh` 4/6 段に 2 行。`bench_formats` は従来どおり 4/6 段に入れない
17. **モジュール配置と import の向き**: `_platform/poll` → `errors` のみ；`async_conn` → `_ffi` / `_platform/poll` / `errors` / `params`（`Param` / `_ParamBuffers`）/ `result`（`Result` / `ResultFormat` / `adopt_result`）/ `connection`（`_SESSION_SETUP_SQL` のみ）；`connection` → `result`（`adopt_result`）。循環なし
    （`connection` は `async_conn` を import しない）。`__init__.mojo` は `AsyncConnection` / `AsyncState` / `PollState` / `Notification` を再エクスポート。`PollEvents` は再エクスポートしない

## メモ

### RESEARCH §3「盗める点」の採否

| # | 内容 | 採否 | 理由 |
|---|---|---|---|
| 1 | psycopg 3 の 4 generator（connect / send / fetch / notifies）を 1 ステップ進めるメソッドに写す | 採用 | T3 / T4。yield の代わりに `PollState` / `Optional[Result]` で待ち方を返す |
| 2 | `PollState` / `AsyncState` は `ResultFormat` と同形の Int newtype | 採用 | 決めた事項 2 |
| 3 | `adopt_result` の抜き出し + `PGRES_SINGLE_TUPLE` | 採用 | T2 / 決めた事項 4 |
| 4 | `poll_connect` に D13 の SET を組み込む（2 件 + NULL） | 採用 | T3 / 決めた事項 7。失敗 kind は同期側と同じ分類に揃えた |
| 5 | `state()` は自前の状態変数、NULL を見るまで `Busy` | 採用 | 決めた事項 7 |
| 6 | `set_single_row_mode` のクライアント側ガード | 採用 | T4 / 決めた事項 12 |
| 7 | `cancel()` の状態分岐（Idle no-op / Connecting USAGE / 切断後 CONNECTION） | 採用 | T4 / 決めた事項 10 |
| 8 | `fetch_all` の `first_error` 保持 + 全体締め切り | 採用 | 決めた事項 9（最短実装で落とさない。D16） |
| 9 | UTF-8 の 2 段構え（stdlib → 自前スキャナで位置） | 採用 | T7 / 決めた事項 13 |
| 10 | `_string_payload` の一元化 | 採用 | T1 (h) |
| 11 | SKIP 集計 | 採用 | T1 (f)(g) / 決めた事項 14 |
| 12 | NOTIFY テストは揃うまで再試行 | 採用 | T4 (c) ①（`wait_notification` を 2 回） |
| 13 | `wait_readable` の前に送信を終わらせる（ruby-pg） | 採用 | 決めた事項 9（`fetch_all` / `wait_notification`） |
| 14 | `PollEvents` の判定順（psycopg `waiting.py`） | 採用 | 決めた事項 1 / 9 |
| 15 | `_platform/poll` の形（mojothon/libc） | 採用 | 決めた事項 1 |
| — | psycopg 3 の「`nonblocking = 1` は接続完了後」 | 却下 | REQ §4.2 は `start` 直後。実測で問題なし（RESEARCH §2.1 A） |
| — | psycopg2 の「結果列の最初のエラーを保持して後続は PQclear」 | 採用（同型） | `fetch_all` の `first_error`。後続の `Result` は返す（捨てない）点だけ違う |
| — | `PQcancelCreate`（17+）/ `PQsocketPoll` | 却下 | D6 / D7。docstring に P31 の注記だけ |

### RESEARCH §4「落とし穴」とタスクの対応（34 件）

P1 → T3 (a) + T5 ⑧／P2 → T3 ③／P3 → T3 (a) + T5 ⑦／P4 → T2 (d)(e)（コードレビュー）／P5・P6・P7 → T2 (e)／P8 → T2 (d)（`package` が通る）／P9 → T5 ① + 陽性対照／P10 → T3 ①／P11 → T3 ⑥／P12 → T5 ⑤／
P13 → T4 (b) ③ + T5 ①⑥／P14 → T4 (b) ④／P15 → T4 (b) ① + T5 ③／P16 → T4 (b) ②・T5 ①②／P17 → T6 (b)／P18 → T4 (c) ①／P19 → T6 (b)／P20 → T5 (b) ①／P21 → T5 ④／P22 → T5 ⑨ + T6 (a)／P23 → T3 ⑦／P24 → T3 ⑦ + T4 (c) ③／
P25 → T7 (b)／P26 → T7 (c)／P27 → T2 (a)(f)／P28 → T1 (f)／P29 → T6 (c)／P30 → T1 (e) + T3 ⑦／P31 → T4 (a)／P32 → T5 ④／P33 → T3 (a)／P34 → T5 ①。対応先の無い落とし穴は無い

### 観点の担当

- 並行性: 同一スレッドの状態機械なので「競合」は cancel と結果到着（T4 (b) ②: アイドル cancel が無害）、切断の検出順（T5 ④: `57P01` と `CONNECTION` のどちらが先か。2 値期待）、NOTIFY の到着分割（T4 (c) ①）、`PQflush` = 1 の非決定（T5 ⑤: 断定しない）
- 境界値: `timeout_ms` の -1 / 0 / 正 / -2（T2 ⑥、T5 ①）、16 MB クエリ（T5 ⑤）、payload 7999 byte（T5 (b) ②）、single-row の 0 行終端（T4 (b) ③）、空クエリ（T3 ⑤）、UTF-8 の 4 不正パターン（T7 (c)）、timetz 86400000001（T1 (c)）
- 異常系: 状態 9 種（未接続 / 接続ポーリング中 / 送信中 / 結果待ち / 結果取得後 / 切断 / cancel 後 / タイムアウト後 / 未読結果ありの drop）× 誤呼び出しの格子は T3 ⑨ / T5 ①②④⑨ / T4 (b)。接続失敗 3 種は T5 ⑧
- 陽性対照（必ず同じターンで実測して PROGRESS に貼る）: T1 (f)（run_tests.sh の exit code）、T5 ①（状態検査を外す）、T6 (b)（`PQfreeCancel` / `PQfreemem` 除去）、T7 (c)（スキャナが -1 を返さない）

### reflect 提案の反映（直近 2 件）

- Phase 3 reflect: 持ち越し整理 4 件を T1 に（反映）／**追従先チェックリストを実行可能スクリプトにして plan で現在値を記録**（反映: `turn-002-checklist.sh`、表の「現在値」列）／PROGRESS「未確認」行の処分（T8 (d) に反映。impl への申し送りにも）／
  verify の字句指摘のクラス名指し・集計値の書き方（REQ §9 に記載済み。plan は関与しない）／所要見積もりの式（反映: 検証コマンド節）／PROGRESS 40 行上限 + TRACE.md（T8 (b)(c)(d) に反映。impl への申し送りにも）／
  RESEARCH の期待値を省略しない（research が実施済み。plan は RESEARCH の値をそのまま写した）／RESEARCH §0.5 の転記（済）／SKIP 集計 (b)（D2 で採用 → T1）／**「テストのみ 2 ファイル」型を 1 本で試す**（反映: T5 を実験に指定。T3 / T4 は src を触るので対象外）／ツール側（ユーザー）
- Phase 2 reflect: 期待メッセージ 2 語以上（全タスクに反映）／`grep -c X = 0` の機械化（反映: `final_check.sh` ではなくチェックリストスクリプトに集約。Phase 4 で新しい `warning:` 系パターンは無いため）／
  PROGRESS「確認済み / 未確認」の分離（下の impl への申し送りに）／サブエージェント推奨本数（全タスクに明記。T6 / T8 は 0 本）／最初の 1 本をコンパイルしてから（T2 A / T3 親に明記）／非対称を突くプローブ（research 済み。T5 ⑩ にテスト化）

### impl への申し送り

- **書き始めの順序**: T3 は `AsyncState` / `PollState` / `start` / `poll_connect` / `connect_blocking` + テスト①を先にコンパイルして通し、それから `send*` / `poll_result` / `fetch_all` を書く。`PQconnectStart` の引数は `CStr(unsafe_from_address=Int(conninfo.as_c_string_span().ptr()))`（`connection.mojo:226-229` と同形。`_ = conninfo^` を呼び出しの後に）
- **Mojo 1.1.0 の落とし穴は RESEARCH §0.5 を最初に読む**（☆ 8 件が今回分）。特に: `external_call` は `from std.ffi import external_call`、同名シンボルは 1 シグネチャ、`poll` / `__errno_location` 以外を `_platform/poll` で呼ばない／`comptime if CompilationTarget.is_linux()`（`@parameter if` は不可）／
  `get_errno() == ErrNo.EINTR`（`.value` で Int）／`monotonic()` は ns／`"x" * 16000000` の形の文字列反復が無ければ `String` の `+=` ループでなく `List[UInt8]` から作る／`print(a, b)` の既定 `sep=" "`／`var x: List[Int32] = [Int32(0), Int32(0)]`
- **サブエージェント依頼文に必ず入れる 3 行**（REQ §9）: (a) 型パラメータを持つ型は `Span[UInt8, origin]` / `StringSlice[origin]` / `Pointer[LibpqFFI, MutUntrackedOrigin]` のようにフルに書く、(b) `fmt` は親が統合後に 1 回だけ、(c) scratch は `.gsd-lite/logs/phase4-async-cancel-notify/scratch/turn-NNN-<name>` 固定（`/tmp` は権限拒否）。
  加えて本 PLAN の該当「決めた事項」の番号を貼る（契約）
- **PROGRESS「次への注意」は「確認済み:」と「未確認:」を分ける**。所要の数値には単位。**「未確認」で「誤った値が黙って返る経路」「状態機械が壊れる経路」を述べる行は同ターンでテスト 1 件にするか、PLAN の該当タスクに「(x) この行を処分する」を追記**（処分先は 1 つ）。
  1 ターンの申し送りは 40 行まで。30 行超の表は `.gsd-lite/TRACE.md` に置いてパスと行数だけ書く。「やったこと」に「推奨 N 本 / 実 M 本」
- **期待値の取り直し**（REQ §9 常設）: sqlstate / message / `pg_backend_pid` / NOTIFY payload は親が同期 `Connection`（`pixi run mojo run -I src` の使い捨てスクリプトを scratch に）で取り直してから期待値に書く。RESEARCH の原本ログは `scratch/turn-001-probe-async*-pg17.log` / `-pg14.log`
- **状態機械のテストで `SENDING` を断定しない**（P12）。`send` 直後の `state()` は `SENDING` または `BUSY`
- **`_ = buffers^` の並び**: `PQsendQueryParams` / `PQsendQueryPrepared` の呼び出しの**後**に置く（`connection.mojo:429-430` と同じ）。libpq は呼び出し中にコピー済み（RESEARCH §2.1 I）なので早すぎる解放の心配は無いが、Mojo の ASAP 破棄で呼び出し**前**に消えないよう生存マーカーは必須
- **切断テスト（T5 ④）の競合**: `57P01` を `fetch_all` が投げるか `CONNECTION` を投げるかはタイミング次第。両方許容する期待にし、最終状態（`socket() == -1`、`status() == CONNECTION_BAD`）だけ断定する
- **T6 の cancel ループの陽性対照**が見えなければ「契約外（確保サイズが小さく RSS に出ない）」と書く。嘘の陽性を書かない
- **T7 の bench は「前」を先に**: T7 のコード変更を始める前に `pixi run bench` を 2 回回してログを scratch に残す（後から取り直せない）
- `check` の時間が 5 分を超えたら PROGRESS に書く（verify の計画に使う）。超える要因は `test_async`（pg_sleep 2 s + cancel + タイムアウト 0.5 s + 16 MB）× 2 サーバーと leak +15 s
