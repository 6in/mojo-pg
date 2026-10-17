# PROGRESS — phase4-async-cancel-notify

## turn 1 — research — libpq 非同期 API・poll・NOTIFY・タイムアウトリスナーを実測し RESEARCH.md を産出
- やったこと: プローブ 5 本（poll / lang / async / async2 / 名前確認 ×14）を PG17・PG14 で実行し、REQ §4・§5.1 の「要実測」8 件を全部確認（矛盾なし）。
  サブエージェント 1 本（OSS / 公式 docs / macOS・Windows 定数、推奨 1 本 / 実 1 本）。`alpine/socat` の黒穴リスナーを compose で起動して 501 ms タイムアウトを実測。
  RESEARCH.md（§0 結論 9 件、§0.5 落とし穴 ★☆、§1 OSS、§2 実測表、§3 盗める設計 15 件、§4 落とし穴 34 件、§5 REQ 訂正 3 + 提案 10、§6 plan 申し送り）。REQ 本文 3 箇所訂正
- 想定外: (1) **NOTIFY 2 件が 1 回の `PQconsumeInput` で揃わない**ことが PG14 で出た（タイミング差。REQ §4.7 を訂正）。(2) **Mojo 1.1.0 に Windows の OS 判定が無い**（`is_windows` /
  `platform_map(windows=)` とも不在。REQ §4.1 を `else` 分岐に訂正）。(3) **`external_call` は同名シンボルを 1 つのシグネチャでしか呼べず、stdlib が使う `write` と衝突**した
  （§0.5 ☆）。(4) `PQsetSingleRowMode` が最初の `PQgetResult` 後も 1 を返す（docs より緩い。クライアント側ガード必須）。(5) `PQflush` = 1 は 16 MB でも PG14 では出ず非決定的。
  (6) サブエージェント報告の `std.ffi.get_errno` / `std.time.monotonic` は実測で確認して採用（`Int(ErrNo)` は不可、`.value`）
- やり直し: 5 回（poll プローブ: `external_call` 未 import + `List[T](a, b)` ctor → 1 回 / `sizeof` → `size_of` → 1 回 / `poll` の 2 シグネチャ衝突 → 1 回 / `write` の stdlib 衝突 →
  `FileDescriptor` に → 1 回。async プローブ: `.strip()` が `StringSpan`・`mut` 引数に一時値 → 1 回。lang プローブは `os_is_*` / `@parameter if` で 2 回落ちたが名前探索の一部として数えない）
- 次への注意: plan は RESEARCH §3-5（`state()` の遷移）と §4 P9 / P13 / P18 / P21 を完了基準に写す。`tests/docker-compose.yml` に `blackhole`（§2.5 の 5 行）を足すのは最初の 1 コミット
  （REQ §6 持ち越し整理）と同時でよい。Phase 3 reflect の「期待値表は `...` で省略しない」は守った（sqlstate / メッセージ / 戻り値列は全桁）。
  `check` は 260〜300 s になる見込み（§6 所要）。Mojo の名前違いは §0.5 ☆ に 8 件追記したので impl はプローブ前に読む

## turn 2 — plan — 8 タスク（T1 持ち越し整理 + blackhole + SKIP + §4.9 / T2 土台 adopt_result・TIMEOUT・_ffi・_platform/poll / T3 AsyncConnection 前半 + test_async / T4 cancel・NOTIFY・single-row + examples / T5 テスト格子（実験: 1 本）/ T6 leak / T7 UTF-8 / T8 最終整備）
- やったこと: REQ / DECISIONS / RESEARCH / 直近 2 件の reflect と `src/` `tests/` `examples/` を読み、PLAN.md（検証コマンド・追従先チェックリスト 24 行・Tasks 8・決めた事項 17・採否表 18 行・落とし穴 34 件の対応）を作成。
  追従先チェックリストは REQ §9 どおり**実行可能スクリプト** `.gsd-lite/logs/phase4-async-cancel-notify/scratch/turn-002-checklist.sh` にして現在の木で 1 回実行し、現在値を表に転記（`absent` はファイル未作成）。
  REQ §4.5「他は既存」から 1 件逸れて `PQconnectStart` のバインドを足す判断（決めた事項 5。`test_ffi` の件数 53 → 55）、D13 の SET 失敗 kind は「同期側と同じ分類」= `adopt_result` の分類に揃える判断（決めた事項 7）を記録
- 想定外: (1) `_ffi` に `PQconnectStart`（文字列版）が無く、`start(var conninfo: String)` を `PQconnectStartParams` だけで書くには `expand_dbname=1` の変換が要る → バインド追加を決めた。
  (2) REQ §4.2 の「SET が失敗したら `CONNECTION`（同期側と同じ kind）」は同期側 `_adopt` の実際の kind（`SERVER` with sqlstate。`connection.mojo:182-184`）と食い違う → 「同期側と同じ」を優先し決めた事項 7 に明記（REQ 本文は触っていない。verify はこちらを正とする）。
  (3) `wait_notification` が 1 件しか返さないのに `notifications()` は複数件返し得る → 内部キュー `_pending` が必要（決めた事項 11。REQ に無い内部状態。T5 (b) ⑤ で陽性確認）。
  (4) `grep -c 'from_utf8='` が `unsafe_from_utf8=` も数える → スクリプトのパターンを `(from_utf8=` に直して再実行（現在値 0）
- やり直し: 1 回（チェックリストスクリプトの UTF-8 パターン。上記 (4)）
- 次への注意: impl は T1 から。`pixi run db-up` で `blackhole` が上がるのは T1 (e) を書いた後。T1 (f) の陽性対照（port=1 で `run_tests.sh` の exit code ≠ 0）は数十秒で終わる。
  T3 の `async_conn.mojo` は決めた事項 6〜9 を契約にして `start` / `poll_connect` / `connect_blocking` から書き始める（最初の 1 本をコンパイルしてから）。
  未確認: `"x" * 16000000` の形の文字列反復が Mojo 1.1.0 にあるか（T5 ⑤。無ければ `List[UInt8]` から作る）／`PGcancel` の確保サイズが leak の陽性対照に出るか（T6 (b)。見えなければ「契約外」と書く）／`check` の所要 260〜300 s（見込み）

## turn 3 — impl — T1 持ち越し整理 + blackhole + SKIP 集計 + 文字列 OID 判定の一元化
- やったこと: (a)〜(i) を 1 人で実装（並列サブ作業は 1 本なのでサブエージェントは使わず）。REQ §6 の 4 件（params の上限文言 / client_encoding の docstring /
  `decode_timetz` の時刻範囲検査 + テスト 2 ケース / 非 UTC `else` を `options='-c TimeZone=Asia/Tokyo'` の専用接続ケースに）、`tests/docker-compose.yml` に `blackhole`（socat・54399、`db-up` で `Up`）、
  `run_tests.sh` の `tee` + `${PIPESTATUS[0]}` + SKIP 集計（`run_test_cmd` 関数 1 本に集約。leak バイナリも同じ経路）、`print("SKIP <name>: <reason>")` 3 箇所、
  `decode_binary._string_payload` に文字列系 OID 判定 + jsonb バージョンバイトを一元化して `decode_binary[String]` と `Row.get_text` の両方を通した（`result.mojo` の import 6 名が不要になり削除）
- 期待値の取り直し（REQ §9 常設）: 同期 `Connection` + `options='-c TimeZone=Asia/Tokyo'` で `SELECT '2024-02-29 12:34:56.789+00'::timestamptz` = `2024-02-29 21:34:56.789+09`（`SHOW TimeZone` = `Asia/Tokyo`）。
  (d) の期待文字列と一致（プローブ `scratch/turn-003-probe-tokyo.mojo`）
- 既存テストの期待値変更: **ゼロ**（変えたのは (b) の docstring と (d) の分岐、追加した 2 ファイル 3 テスト分だけ。`test_extended_datetime` は 19 件のまま、`test_decode_binary` は 78 → 80 件）
- 検証（所要つき）: `pixi run test` 両サーバー PASS（21 ファイル × 2 = 42 サマリ全部 0 failed、`-- 127.0.0.1:54317 skipped 1` / `-- 127.0.0.1:54314 skipped 1`、per-file 合計 **243 s**）、
  `pixi run check` **6/6 PASS**（15:52:13 → 15:54:45 = **152 s**。PLAN の見込み 260〜300 s より速い。Phase 4 のテストがまだ 0 本なので当然で、T3 以降で増える）、`pixi run package` 警告ゼロ。
  (f) の陽性対照: `PQ_TEST_CONNINFO='... port=1 ...' bash tests/run_tests.sh` の **exit code = 1**（`tee` が終了コードを飲んでいない）、集計行も出た（`-- 127.0.0.1:1 skipped 0`）
- チェックリスト（T1 行）: `params_libpq_takes_at_most=0` / `params_MaxAllocSize=3`（期待 ≥2） / `testconn_from_the_environment=0` / `testconn_PGCLIENTENCODING=1` / `timetz_time_of_day_is_not=0` /
  `timetz_out_of_range_sites=1` / `datetime_is_utc_calls=2` / `datetime_asia_tokyo=2` / `compose_blackhole=1` / `compose_54399=1` / `run_tests_SKIP=2` / `run_tests_pipefail=2` /
  `leak_old_SKIP_colon=0` / `string_payload_def=1` / `string_payload_calls=2` / `jsonb_version_checks=2` / `oid_varchar_checks=1` / `test_decode_binary_tests=80` / `test_extended_datetime_tests=19` — **全部期待値**。
  `tests_print_SKIP` だけはスクリプトが `absent(tests/test_async.mojo)` を返す（T3 まで対象ファイルが無い）ので手で数えた: **4**（期待 ≥3）
- PLAN 訂正 3 件:
  - `(g)` の `_skip_on_macos()` 呼び出し **11 → 10**（実測 `grep -c` = 10。PLAN の数え違い）
  - `(d)(g)` の SKIP 文言を短縮: `main connection TimeZone is not UTC` → `TimeZone is not UTC`、`server is older than 17` → `server < 17`、`server is 17 or later` → `server 17+`
    （根拠: 元の文言は 80 桁を超え `mojo format` が `print(` と文字列を別行に割る。割れるとチェックリストのパターン `print("SKIP ` が当たらない。形式 `SKIP <name>: <reason>` と `run_tests.sh` の `^SKIP ` は不変）
  - 追従先チェックリストの `tests_print_SKIP` 行に「T3 まではスクリプトが `absent` を返すので手で数える」注記（スクリプト自体は変更していない）
- 想定外: (1) `except e: return e` が `PgError` は `ImplicitlyCopyable` でないとして弾かれた → `return e^`（テストのヘルパ `_payload_error`）。
  (2) `print("SKIP ...")` の 1 行制約（上の PLAN 訂正）。`mojo format` は文字列を割れないので `print(` ごと改行する。
  (3) `check` が 152 s で見込みより速かった（Phase 4 のテストがまだ無いだけ）
- やり直し: 1 回（上記 (1) の `return e^`。コンパイルエラー 1 回で直った）
- 次への注意: T2 から。`print("SKIP ` と、同じく grep で数える行は **1 行に収まる文言**にする（80 桁。`mojo format` が割ると機械チェックが当たらない）。
  `_string_payload` は `decode_binary.mojo` の private だが `result.mojo` / `tests/test_decode_binary.mojo` から名前で import している（T7 の UTF-8 検証もこの 1 箇所に足せる）。
  `run_test_cmd` は `build/last_test.log` を毎ファイル上書きするので、T3 以降で新しいテストを足しても集計はそのまま効く。`blackhole` は compose に入ったので `db-up` 済みの環境では 54399 が常に `Up`（T3 (c) ⑦ の SKIP 分岐は実際には通らない見込み）。
  `PgError` を値として返す場面では `^` が必要（想定外 (1)）

## turn 4 — impl — T2 Phase 4 の土台（adopt_result / TIMEOUT / _ffi 2 本 / _platform/poll + test_poll）
- やったこと: (a)〜(f) を 1 人で実装（並列サブ作業は推奨 1 本なのでサブエージェントは使わず。推奨 1 本 / 実 0 本）。
  `_take_result` 本文 + `_error_field` を `result.mojo` の `adopt_result` へ移して `_take_result` は 1 行委譲（成功判定に `PGRES_SINGLE_TUPLE` 追加）、
  `PgErrorKind.TIMEOUT`（値 6 / `Timeout`）、`_ffi` に `PQconnectStart` と `PQsetSingleRowMode`（名前表 53 → 55）、
  `src/pq/_platform/{__init__,poll}.mojo`（`poll_socket` + `PollEvents`、POSIX と WSAPoll を `comptime if` で分岐）、`tests/test_poll.mojo` 9 件
- 既存テストの期待値変更: **ゼロ**（`test_ffi.mojo:103` の `len(names)` 53 → 55 は追加した 2 バインドの件数そのもの。
  他は `test_errors` に 1 件、`test_poll` に 9 件の追加だけ。同期側 `_take_result` の分類・文言は 1 字も変えていない）
- P4（`EINTR` はコードレビュー）: `src/pq/_platform/poll.mojo:236` が `err == ErrNo.EINTR`、`:238` が `deadline - monotonic()` の残り再計算、
  `:243` が `remaining = (left + 999_999) // 1_000_000`（切り上げ。0 に落として probe 化させない）、`:228` が `deadline`。`timeout_ms == -1` は再計算せず `continue`
- 検証（所要つき）: `pixi run test` 両サーバー PASS（22 ファイル × 2、全サマリ `0 failed`、`-- 127.0.0.1:54317 skipped 1` / `-- 127.0.0.1:54314 skipped 1`、16:04:58 → 16:09:45 = **287 s**）、
  `pixi run check` **6/6 PASS**（16:15:57 → 16:18:10 = **133 s**。T1 の 152 s より短いのは leak が 1 サーバーのみの分の揺らぎ）、`pixi run package` 警告ゼロ。
  `test_poll` 単体は 9 件 PASS / **0.13 s**（サーバー不要）
- チェックリスト（T2 行）: `conn_def_take_result=1` / `conn_def_error_field=0` / `result_def_adopt_result=1` / `result_def_error_field=1` / `result_SINGLE_TUPLE=3`（期待 ≥1） /
  `conn_adopt_result_calls=1` / `errors_TIMEOUT=3`（≥2） / `errors_six=0` / `init_exactly_six=0` / `init_TIMEOUT=1`（≥1） / `ffi_PQsetSingleRowMode=3`（PLAN 訂正、下記） /
  `ffi_PQconnectStart_plain=1` / `testffi_PQsetSingleRowMode=1` / `testffi_PQconnectStart_plain=1` / `testffi_symbol_count_53=0` / `_55=1` /
  `platform_init=exists` / `platform_poll=exists` / `poll_def_poll_socket=1` / `poll_comptime_if=1` / `poll_WSAPoll=10`（≥1） / `poll_EINTR=3`（≥1） / `poll_monotonic=4`（≥1） /
  `poll_external_call_symbols=2`（≤3） / `test_poll=exists` / `test_poll_tests=9`（≥7） — **全部期待値**。全体行は `tests_files_count=22` / `test_file_count=22`（T8 で 24）
- PLAN 訂正 3 件:
  - `ffi_PQsetSingleRowMode` の期待 **2 → 3**（`mojo format` が `_dl_sym[...](self._lib, "PQsetSingleRowMode")` を 3 行に割るので、宣言 1 + 代入 1 + 名前文字列 1 で 3 行当たる）
  - T7 行の `result_unsafe_ptr` 現在値 **4 → 7**、期待 **3 → 6**（`_error_field` / `adopt_result` が `result.mojo` に移り、libpq のエラー文字列を読む `unsafe_from_utf8_ptr` が 3 行増えた。
    いずれも列値ではないので UTF-8 検証の対象外）。同じ行の `utf8_unsafe_span` は 3 → 2（T1 の `_string_payload` 一元化による。T7 の期待 0 は変えない）
  - T2 の対象ファイルに `src/pq/transaction.mojo`（`_error_field` の import 元）と `src/pq/_ffi/__init__.mojo`（「50 libpq entry points」→ 55）を追記
- 想定外: (1) `transaction.mojo:75` が `from pq.connection import Connection, _error_field` で移動先を参照していた（PLAN の対象一覧漏れ。`pq.result` から取るよう 1 行修正）。
  (2) `FileDescriptor(fd).write("A")` は一時値への mutating 呼び出しで弾かれる → `var out = FileDescriptor(fd); out.write("A")`（probe と同じ形に戻した）。
  (3) `comptime if` の非選択側に置いた `external_call["WSAPoll"]` は Linux でリンクエラーにならない（分岐ごと codegen されない。`package` も `test` も通った）
- やり直し: 2 回（上記 (1)(2)。どちらもコンパイルエラー 1 回ずつで直った）
- 次への注意:
  - 確認済み: `adopt_result(pq, conn, res)` はモジュール関数で、`async_conn` からは `from pq.result import Result, ResultFormat, adopt_result` で取れる（`connection.mojo` と同じ形）。
    `poll_socket(fd, want_read, want_write, timeout_ms)` は `timeout` を例外にせず `PollEvents.timeout` で返すので、`TIMEOUT` の文言を作るのは T3 の `wait_readable` / `wait_writable` 側。
    `want_read = want_write = False` は純粋な sleep として使える（`test_poll.mojo:176-188` が陽性）。`_platform` は `pq` 直下に再エクスポートしていない。
    `PGRES_SINGLE_TUPLE` は既に `adopt_result` の成功判定に入っているので T4 の single-row は `set_single_row_mode` のガードだけ足せばよい
  - 未確認: `poll.mojo` の Windows 分岐（`WSAPoll` / `_WsaPollFd` 16 byte / 別の定数値）は**コンパイルすらされていない**（`comptime if` の非選択側）。
    誤った値が黙って返る経路ではなく「Windows では動かない可能性」なので、処分先は T8 (d) の「未確認の処分」= モジュール docstring の **unverified** 表記を残すことで足りる（P8）。
    `EINTR` の実挙動（シグナル下での再試行）は未確認のまま（RESEARCH §2.3 どおりテストしない。コードレビューで代替、上の P4 行）
  - `check` は 133 s。T3 で `test_async`（pg_sleep 2 s ×2 サーバー）が乗ると PLAN の見込み 260〜300 s に近づく見込み

## turn 5 — impl — T3 AsyncConnection 前半（接続 / 送信 / 受信 / 状態機械 / ブロッキング補助）
- やったこと: (a)〜(e) を 1 人で実装（推奨 1 本 / 実 0 本。サブ作業は `tests/test_async.mojo` の 1 本だけなのでサブエージェントは使わず）。
  `src/pq/async_conn.mojo`（新設 1,233 行）に `AsyncState` / `PollState` / `Notification` と `AsyncConnection` の 21 メソッド
  （`start` 2 形 / `poll_connect` / `connect_blocking` 2 形 / `socket` / `state` / `status` / `transaction_status` / `send` 2 形 /
  `send_prepare` / `send_prepared` / `flush` / `consume_input` / `is_busy` / `poll_result` / `fetch_all` / `wait_readable` / `wait_writable` / `__deinit__`）、
  `__init__.mojo` に 4 型の再エクスポート + Layout 行 + `## Asynchronous use` 節（43 行）、`connection.mojo:164` を現在形に、`tests/test_async.mojo` 9 件
- 期待値の取り直し（REQ §9 常設。プローブ `scratch/turn-005-probe-expect.mojo`、同期 `Connection` のみ）: `SHOW DateStyle` = `ISO, YMD` /
  `SHOW IntervalStyle` = `postgres` / `SELECT 1/0` は `Server` `22012` `division by zero` / 空クエリは `Server` `empty query` / 未知の prepared は `26000` —
  すべて (c) の期待値と一致。`send_prepare` + `fetch_all` の `command_tag() == ""`（async2 B）もテストで実測一致（SQL の `PREPARE` は `PREPARE` タグを返すが別経路）
- 既存テストの期待値変更: **ゼロ**（`connection.mojo` と `__init__.mojo` は docstring のみ。追加は `test_async.mojo` 9 件だけ）
- 検証（所要つき）: `pixi run test` 両サーバー PASS（23 ファイル × 2 = **46 サマリ全部 0 failed**、exit 0、`-- 127.0.0.1:54317 skipped 1` /
  `-- 127.0.0.1:54314 skipped 1`、16:42:35 → 16:46:11 = **216 s**）、`pixi run check` **6/6 PASS**（16:49:34 → 16:53:15 = **221 s**。PLAN の見込み 260〜300 s 内）、
  `pixi run package` 警告ゼロ、`pixi run fmt` 差分なし。`test_async` 単体は **2.6〜2.9 s**（PG17 を 3 回 + PG14 を 1 回、すべて 9/9 PASS。
  内訳は `pg_sleep(2)` 2,023〜2,075 ms + connect タイムアウト 575〜596 ms + 残り 7 件で 60 ms 前後。PLAN の見込み 40〜60 s/サーバーより大幅に短い）
- チェックリスト（T3 行）: `async_conn=exists` / `async_struct=1` / `async_state_struct=1` / `pollstate_struct=1` / `notification_struct=1` /
  `async_public_defs=23`（≥20） / `init_async_import=1` / `conn_phase4_future=0` / `init_phase4=1` / `test_async=exists` / `test_async_tests=9`（≥8） /
  `src_PQexec_calls=4`（`async_conn.mojo` に `PQexec(` は無し） / `src_PQfinish_calls=5`（≥3） / `src_def_ref_return=0` / `tests_files_count=23`・`test_file_count=23`（T8 で 24）— **期待値**。
  例外 2 件: `async_called_while=5`（期待 ≥6 は T3+T4 の合算。下記 PLAN 訂正）、`tests_print_SKIP` はスクリプトが `absent(tests/test_notify.mojo)` を返すので手で数えて **5**（datetime 3 + leak 1 + async 1。T3 で +1 の予定どおり）
- PLAN 訂正 4 件:
  - (c) ⑥（と ④）の終端判定: 「エラー raise のあと**もう 1 回** `poll_result()` が `None` で `state() == IDLE`」は**不成立**。終端 NULL は別ラウンドトリップで届くので
    1 回目は `None` + `BUSY` になり得る（`pixi run test` 中に 1 回失敗、単体 4 回は通る頻度）。`None` の意味は契約どおり「`BUSY` ならまだ / `IDLE` なら終了」なので
    テスト側のループが正。ヘルパ `_poll_to_idle` に集約して ④⑥ の両方で使う（`src/` は無変更。契約どおりの挙動）
  - (c) のヘルパ `_error_of(...)` → 入口ごとに分割（Mojo にクロージャ引数の形が無い）: `_connect_blocking_error` / `_send_error` / `_fetch_all_error` /
    `_poll_result_error` / `_wait_readable_error`。成功側と読み出し側のヘルパ名も PLAN に列挙済み（T5 はこの名前に追記する）
  - チェックリスト `async_called_while` の T3 時点の実測は **5**（期待 ≥6 は T4 まで）。理由: 状態文言を `_require_state` / `_reject_connecting` の 2 本に集約したので
    メソッド数ぶんは増えない。T4 の `cancel` / `notifications` の docstring で 6 を超える
  - T5 ⑪ の NUL 文言: `name` 引数は `"embedded NUL byte in name"`（`transaction.mojo` の savepoint 名と同じ `what`）。`send_prepare` は `name` → `sql` の順に検査
- 想定外: (1) 上記の終端 NULL の 1 ラウンドトリップ遅れ（P11 の実地。PLAN の期待が楽観的だった）。
  (2) `try` 本体の例外型が `except` 側に引っぱられる: `except e: return e^`（`PgError` を返す）形の `try` の中では `Error` を投げる関数（`assert_*` / 他のヘルパ）を呼べない
  → PgError を出す呼び出しだけを `try` に入れ、判定は外に出す（`_poll_result_error` / `_column_format`）。
  (3) `var got: Optional[Result] = None` は「代入が使われない」警告になる（`except` が必ず脱出するので初期化子が死ぬ）→ `var got: Optional[Result]` と宣言だけにする（`package` の警告ゼロ条件）
- やり直し: 3 回（上記 (1) テスト修正 1 回、(2) コンパイルエラー 1 回、(3) 警告 1 回。いずれも 1 回で直った）
- 次への注意:
  - 確認済み: `fetch_all` は「書き切る → 取り切る」の順で、途中のエラーは `first_error` に保持して NULL まで取り切ってから投げる。
    切断時は無限ループ回避のため `PQstatus == CONNECTION_BAD` を見たら drain を打ち切る（T5 ④ の 2 値期待はこれで満たせる見込み）。
    `wait_*` の `TIMEOUT` は `fetch_all` / `connect_blocking` が自分の文言に包み直す（`_wait_for` / `_poll_to_ready`）ので、
    テストの部分文字列は `"timed out after"` で 3 経路に当たる。`_single_row_allowed` は `send*` 成功で True、`poll_result` / `consume_input` / `is_busy` で False（T4 はガードを足すだけ）。
    `_pending` フィールドは宣言済みで空のまま（T4 が使う）。`PQsetnonblocking(1)` は `start` 直後（RESEARCH §2.1 A どおり問題なし）
  - 未確認: `_after_send` で `PQflush` が **-1** を返したときの状態を `IDLE` のままにしている（結果が無いので drain 不要という判断）。
    実測していない経路で、「状態機械が壊れる経路」ではなく「送信直後に接続が死ぬ稀なケース」。処分先は **T5 ④ の切断テスト**に 1 行足せれば足りるが、
    `send` 中の切断は競合で再現できないので、再現しなければ「契約外（libpq が -1 を返す条件を作れない）」と T8 (d) に書く
  - `check` は 221 s（T2 の 133 s + 88 s。増分の大半は `test_async` の `pg_sleep(2)` × 2 サーバーと connect タイムアウト 0.5 s × 2）。T4 で NOTIFY と cancel が乗ると 5 分に近づく
