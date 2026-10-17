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

## turn 6 — impl — T4 cancel / NOTIFY / single-row / examples
- やったこと: (a)〜(g) を 1 人で実装（推奨 1 本 / 実 0 本。サブ作業 A は examples + pixi + final_check の 1 本だけなのでサブエージェントは使わず）。
  `async_conn.mojo` に `cancel` / `notifications` / `wait_notification` / `set_single_row_mode`（+ 私用 `_single_row_error`）、
  `__init__.mojo` の `## Asynchronous use` に cancel / single-row / LISTEN-NOTIFY の 3 項目と 5 行の例、
  `tests/test_async.mojo` に T4 節 4 件（計 13 件）、`tests/test_notify.mojo` 新設 3 件、
  `examples/async_query.mojo` / `examples/listen_notify.mojo` + `pixi.toml` 2 タスク + `final_check.sh` 4/6 段に 2 行
- 期待値の取り直し（REQ §9 常設。プローブ `scratch/turn-006-probe-expect.mojo`、同期 `Connection` のみ）: `pg_backend_pid()` は Int32 で取れる /
  自分を `pg_cancel_backend(pg_backend_pid())` した `pg_sleep` が `Server` `57014` `canceling statement due to user request`（PLAN の期待と一致）/
  `NOTIFY ch, 'payload-1'` と `NOTIFY ch` はどちらも command_tag `NOTIFY`。NOTIFY の payload（`"payload-1"` / `""`）と `backend_pid` の一致は
  `test_notify.mojo` ① が実測（送信側の `pg_backend_pid()` と同値、PG17 / PG14 両方 PASS）
- 既存テストの期待値変更: **ゼロ**（既存 9 件は無変更。追加は `test_async` 4 件 + `test_notify` 3 件、`__init__.mojo` は docstring のみ）
- 検証（所要つき）: `pixi run test` 両サーバー PASS（24 ファイル × 2 = **48 サマリ全部 0 failed**、exit 0、`-- 127.0.0.1:54317 skipped 1` /
  `-- 127.0.0.1:54314 skipped 1`、17:02:19 → 17:07:12 = **293 s**）、`pixi run check` **6/6 PASS**（17:07:17 → 17:10:06 = **169 s**。
  T3 の 221 s より短い。4/6 段に新 examples 2 本の出力あり）、`pixi run package` 警告ゼロ、`pixi run fmt` は 2 ファイル整形（コミット前に反映済み）。
  `pixi run example-async`（`n = 1` / 空ポーリング 14〜15 回）と `example-notify`（`channel = pq_example` / `payload = hello from pq` / `backend_pid`）は単体でも成功。
  `test_async` 単体は **2.9 s**（うち cancel 114〜132 ms）、`test_notify` 単体は **0.38 s**
- チェックリスト（T4 行）: `async_cancel_insecure=2`（≥1） / `src_PQfreemem_calls=3` / `src_PQfreeCancel_calls=1` / `test_notify=exists` /
  `test_notify_tests=3`（≥3） / `example_async=exists` / `example_notify=exists` / `pixi_example_tasks=2` / `final_check_examples=2` /
  `final_check_run_logged_examples=5` / `async_called_while=7`（≥6。T3 の 5 + cancel / notifications の docstring）— **全部期待値**。
  併せて `async_public_defs=27` / `test_async_tests=13`（T5 で ≥20）/ `tests_print_SKIP=5`（`test_notify.mojo` ができて `absent` が解消。手数えと一致）/
  `tests_files_count=24`・`test_file_count=24`（T8 の期待値に到達）
- 想定外: (1) `notifications()` で `self._pending^` とフィールドから move out はできない（部分的に未初期化になる）→ `copy()` + `clear()` にした。
  `PQconsumeInput` が 0 のときに `_pending` を失わないよう、**consume の後に** `_pending` を引き取る順序にしてある。
  (2) それ以外は PLAN どおり（cancel の errbuf・`PGnotify` の struct 読み・`PQfreemem` は research プローブの形がそのまま通った）
- やり直し: 0 回（`package` / `test_async` / `test_notify` / examples はいずれも初回で通った）
- 次への注意:
  - 確認済み: `cancel()` は `self`（非 mut）で呼べる＝`IDLE` no-op も状態を触らない。`fetch_all` が `57014` を投げたあと `state()` は `IDLE`（drain 済み）なので
    T5 ③ の tx 内 cancel は `fetch_all` の後に `transaction_status()` を読めばよい。`set_single_row_mode()` は `_single_row_allowed` が偽のとき
    **`set_single_row_mode() must follow send() before any result is read (state <State>)`**（`called while` の形ではない）ので T5 ① の部分文字列は
    `"must follow send"` を使う。`notifications()` は `CONNECTING` 以外どの状態でも呼べる（`BUSY` 中も可）。`wait_notification` の 2 件目は `_pending` から即返る（T5 ⑤ の陽性はこの経路）
  - 未確認: `PQcancel` が 0 を返す経路（errbuf の文言を message にする分岐）は未実測。切断済み接続で `PQgetCancel` が非 NULL を返すか 0 を返すかは
    research プローブ L 行の挙動次第で、**処分先は T5 ②「切断後 cancel → CONNECTION」**（既に PLAN にある）。`PQsetSingleRowMode` が 0 を返す分岐も未到達（契約上起こらない想定）
  - `check` は 169 s で 5 分に届かず。T5 で 16 MB クエリ + 切断テストが乗るので再計測する

## turn 7 — impl — T5 テスト格子（test_async 第 2 弾 / test_notify 完成）
- やったこと: 推奨 1 本 / 実 **1 本**（サブエージェントに `tests/test_notify.mojo` の 6 件、親が `tests/test_async.mojo` の 16 件 + 陽性対照 + 期待値取り直し + 検証）。
  `test_async.mojo` は 13 → **29 件**（USAGE 格子 6 件 / cancel 切断後 / tx 内 cancel / 切断 / 16 MB flush / single-row 多文・prepared / multi-host / 接続失敗 3 種 /
  未読結果ありの drop / パラメータのコピー / NUL 4 経路）、`test_notify.mojo` は 3 → **9 件**（実行中受信 / payload 7999 byte と UTF-8 / commit 配送 / 自己通知 / `_pending` 即返し / 切断）
- **`src/` の差分: バグ修正 1 件**（T5 の「テストが露わにしたバグ」枠。`src/pq/async_conn.mojo`、+20 / -3 行）:
  `poll_result` が `PQconsumeInput` の失敗時に常に `BUSY` を保っていたため、**接続を失うと終端 NULL が永遠に来ず `poll_result` ループが無限に回り**、
  以降の `send` がすべて `USAGE "called while Busy"` になっていた（プローブ `scratch/turn-007-probe-disconnect.mojo` で 5 回連続 `Connection` + `Busy` を実測）。
  修正は `poll_result` 専用の私用 `_consume_or_end_command`: `PQconsumeInput` が 0 かつ `PQstatus == CONNECTION_BAD` なら `_state = IDLE` にしてから `CONNECTION` を投げる。
  公開 `consume_input()` は P21 / P32 のとおり `BUSY` を保つまま（T5 ② の切断後 cancel がこの入口を使う）。`poll_result` の docstring に 1 文追記
- 陽性対照（P9。`scratch/turn-007-usage-positive.mojo` を 2 回）: `send(var sql)` の `_require_state("send", AsyncState.IDLE)` を外すと
  結果待ち中の 2 回目の `send` が **`Connection` / `"another command is already in progress"`**（libpq の文言）になる。検査を戻すと **`Usage` / `"send() called while Busy"`**。
  どちらの実行でも `state()` は `Busy` のまま。`src/` は `git checkout src/pq/async_conn.mojo` で戻し `git status` が clean を確認（コミット済みの修正は保持）
- 期待値の取り直し（REQ §9 常設。`scratch/turn-007-probe-expect.mojo`、同期 `Connection` のみ）: `25P02` = `current transaction is aborted, commands ignored until end of transaction block` /
  `26000` = `prepared statement "nope" does not exist` / `could not translate host name "nonexistent.invalid" to address: Name or service not known` /
  `Connection refused` / `password authentication failed for user "pq"` — すべてテストの期待と一致。
  **`57P01` は取り直しで値が違った**: 自分の backend を `pg_terminate_backend(pg_backend_pid())` で落とすと `Connection` / `server closed the connection unexpectedly` になり、
  `Server 57P01 terminating connection due to administrator command` は**別接続から落としたとき**だけ出る（`scratch/turn-007-probe-disconnect.mojo` で確認）。テストは別接続から落とす形なので期待どおり
- 既存テストの期待値変更: **ゼロ**（既存 13 + 3 件は無変更。`src/` の変更は上記バグ修正のみで、既存テストの期待値には触れていない）
- 検証（所要つき）: `pixi run test` 両サーバー PASS（24 ファイル × 2 = **48 サマリ全部 0 failed**、exit 0、`-- 127.0.0.1:54317 skipped 1` /
  `-- 127.0.0.1:54314 skipped 1`、17:22:28 → 17:26:16 = **228 s**）、`pixi run check` **6/6 PASS**（17:27:04 → 17:29:42 = **158 s**）、
  `pixi run package` 警告ゼロ、`pixi run fmt` は `test_async.mojo` を 1 回整形（コミット前に反映）。
  `test_async` 単体は **3.5〜3.6 s**（PG17。内訳は `pg_sleep(2)` 2,030 ms + connect タイムアウト 561 ms + busy send 269〜306 ms + 16 MB 88〜95 ms + tx cancel 109〜222 ms）、
  `test_notify` 単体は **1.0〜1.2 s**。`run_tests.sh` の計測では `test_async` が 15 s（PG17）/ 7 s（PG14）、`test_notify` が 6 s / 3 s（コンパイル込み）
- チェックリスト（T5 行）: `test_async_tests=29`（≥20） / `test_notify_tests=9`（≥8） / `src_PQexec_calls=4` — **期待値**。
  併せて `src_def_ref_return=0` / `tests_files_count=24`・`test_file_count=24` / `tests_print_SKIP=5` / `async_public_defs=27` / `async_called_while=7` /
  `src_PQfinish_calls=5` / `src_PQfreemem_calls=3` / `src_PQfreeCancel_calls=1`（T8 の期待値に到達済み）
- PLAN 訂正 2 件（どちらも上記バグ修正の帰結。PLAN.md の T5 (a) ②④ に追記済み）:
  - ④: 修正後は `fetch_all` の drain がそのまま `IDLE` まで進む。`fetch_all` 直後の状態は `PQstatus` が BAD になるタイミング次第の競合なので断定せず、
    `while state != IDLE: poll_result`（各回 `CONNECTION` sqlstate 空）で片付けてから `poll_result() == None` / `socket() == -1` / `status() == CONNECTION_BAD` /
    `send` が `CONNECTION "no connection to the server"` を見る形にした
  - ②: `fetch_all` 後は `IDLE` なので `cancel()` は契約どおりの no-op になり `CONNECTION` が出ない。切断を **`consume_input()` で観測する**（`BUSY` を保つ唯一の入口）と
    「`BUSY` かつ接続が死んでいる」状態が作れる。`consume_input()` は 1 回目では失敗しない（実測 2〜3 回必要。サブエージェント側の `notifications()` も同じ 2〜3 回）のでリトライループにした
- 想定外: (1) 上記のバグ（切断時に状態機械が `BUSY` で固まる）。T3 の「次への注意」で `fetch_all` の drain 打ち切りは確認済みと書いたが、**手書きの `poll_result` ループ側が無限に回る**のは見落としていた。
  (2) `prefix^ + chr(0)` が `prefix ^ (+chr(0))` と解釈されて `'String' does not implement the '__pos__' method`（`var` 引数にしたのが原因。`tests/test_connection.mojo` と同じ借用引数に直した）。
  (3) `pg_terminate_backend(pg_backend_pid())` の自己終了は `57P01` ではなく `CONNECTION`（上記「期待値の取り直し」）
- やり直し: 3 回（(2) のコンパイルエラー 1 回、切断テストが落ちてバグ修正 1 回、修正で `fetch_all` の終状態が変わって T5 ②④ のテストを書き直し 1 回。いずれも 1 回で直った）
- 次への注意:
  - 確認済み: `single_row_mode` は多文 `send` では**文ごと**に働く（`SELECT 1; SELECT 2` + `set_single_row_mode` = 4 件: 1 行 / 0 行 / 1 行 / 0 行）。
    16 MB の文は `flush()` ループで書き切れる（`state()` が `SENDING` だったかは断定しない）。multi-host（`port=1,<port>`）は `connect_blocking` で成功する。
    接続拒否ポートは `start` が成功して `poll_connect` 側で `Connection refused`（`wait_writable` は writable を先に見るので POLLERR 文言にならない）。
    切断後の `notifications()` も `CONNECTION` が出るまで 2〜3 回かかる（サブエージェント実測）
  - 未確認: `PQcancel` が 0 を返す経路（errbuf の文言を message にする分岐）は**依然未到達**。T5 ② の切断後 cancel は `PQgetCancel` が NULL を返す側（`_connection_error`）に当たった。
    「誤った値が黙って返る経路」でも「状態機械が壊れる経路」でもない（cancel の失敗は必ず `CONNECTION` になる）ので、**処分先は T8 (d) の「契約外」**（libpq に `PQcancel` を 0 で返させる条件を作れない）。
    `PQsetSingleRowMode` が 0 を返す分岐も同様に未到達・契約外
  - `_after_send` で `PQflush` が **-1** を返したときに状態を `IDLE` のままにしている件（turn 6 の未確認）は T5 ④ でも再現できなかった（送信は一瞬で終わる）。
    **T8 (d) で「契約外（libpq が -1 を返す条件を作れない）」に分類する**
  - サブエージェントからの契約外の提案（実装せず、記録のみ）: `AsyncConnection.wait_notifications(n, timeout_ms)` の追加、`notifications()` 側での `PQstatus == CONNECTION_BAD` 先行チェック、
    テスト追加候補（`UNLISTEN` 後に来ないこと / LISTEN していないチャンネルの無視 / `LISTEN "Mixed Case"`）。いずれも Phase 5 以降の判断
  - `test_notify.mojo` ⑥ は libpq の notice `FATAL: terminating connection due to administrator command` を stderr に出すが、`final_check.sh` 6/6 段の grep
    （`warning:|WARNING:|implicit ROLLBACK failed`）には当たらないので 6/6 は PASS のまま（実測済み）
  - `check` は 158 s（T4 の 169 s とほぼ同じ。16 MB と切断が乗っても増えなかった）。T6 の leak 4 ループで +15 s 程度を見込む

## turn 8 — impl — T6 test_leak に Phase 4 ループ 4 本 + 陽性対照
- やったこと: `tests/test_leak.mojo` を 14 → **18 テスト**に（サブエージェントなし。PLAN 推奨 0 本）。
  `test_async_execute_does_not_leak`（1 接続で `send`/`fetch_all` を 10,000 回）/ `test_async_cancel_does_not_leak`（`send`→`cancel`→収集 1,000 回）/
  `test_notify_receive_does_not_leak`（同期側が 7,000 byte payload の `NOTIFY` を 1,000 回、async が `wait_notification(2000)` で 1 件ずつ受ける）/
  `test_async_drop_with_pending_results_does_not_leak`（2 文送って `consume_input()` だけして drop を 1,000 回）。
  モジュール docstring の「Fourteen tests」→ Eighteen、Phase 4 の段（担う 3 解放経路）、所要の実測値を更新
- **陽性対照（T6 (b)）**: `cancel()` の `PQfreeCancel` と `notifications()` の `PQfreemem` を**同時に**外した `src/` で 1 回計測（`build/test_leak_positive`、計測後に削除）:
  - `notify-receive` は **FAIL**: RSS `[5285, 5629, 5974, 6318]`（単調増加、600 iteration で +1,033 pages ≈ 1.7 pages/iteration = payload ちょうど）。`PQfreemem` の欠落は検出できる
  - `async-cancel` は **PASS のまま**: RSS `[4714, 4714, 4714, 4714]`（完全に平坦）。PLAN (b) が予期した側で、`PGcancel` は数百 byte（`fe-cancel.c`: struct + `raddr`）なので
    1,000 iteration = 数百 KB では `TOLERANCE_PAGES` 256 にも届かない。**処分: 契約外**（`PGcancel` を膨らませる手段が無く RSS では原理的に見えない）。
    `PQfreeCancel` は `src/pq/async_conn.mojo:1297` にあり `src_PQfreeCancel_calls=1`（チェックリスト）＋ `:1290-1291` のコメント（errbuf を読んでから free）でコードレビュー担保。
    この経緯はループ本体のコメントにも実測値つきで書いた（`tests/test_leak.mojo` の `test_async_cancel_does_not_leak`）
  - 計測後 `git checkout src/pq/async_conn.mojo` → `git status` が `tests/test_leak.mojo` のみ M（`PQfreeCancel` / `PQfreemem` が戻っていることを grep で確認）
- 既存テストの期待値変更: **ゼロ**（既存 14 テストは無変更。`src/` の差分なし）
- 検証（所要つき）: `pixi run test` 両サーバー PASS（**48 サマリ全部 0 failed**、`grep 'tests run' | grep -vc ' 0 failed'` = 0、
  `-- 127.0.0.1:54317 skipped 1` / `-- 127.0.0.1:54314 skipped 1`、17:40:15 → 17:44:10 = **235 s**）、
  `pixi run check` **6/6 PASS**（17:48:33 → 17:51:22 = **169 s**。5/6 段の leak は PG17 のみ）、`pixi run package` 警告ゼロ、`pixi run fmt` は `test_leak.mojo` を 1 回整形（コミット前に反映）
- **leak の所要（P29）**: `test_leak` 全 18 テストで **74.2 s（PG17）/ 75.0 s（PG14）**。Phase 3 末の実測 74 s から **+0〜1 s** で、+15 s の枠内。
  Phase 4 の 4 ループ自身は合計 **7.4 s**（単体実行の内訳: async-execute 2,793 ms / async-cancel 905 ms / notify-receive 154 ms / async-drop 3,588 ms）。
  単体実行の合計は 72.2 s で、run_tests.sh の 74 s との差は計測の揺れ。RSS は 4 ループすべて両サーバーで平坦（例: PG17 `async-execute [4735 ×9]` / `notify-receive [4736 ×4]`）
- チェックリスト（T6 行）: `leak_tests=18`（期待 18） / `leak_Fourteen=0`（期待 0） / `leak_async_import=13`（期待 ≥1）— **期待値**
- 想定外: (1) `Optional[Notification]()` を先に作って `try` 内で代入する形が `warning: assignment to 'found' was never used` を出した。
  `final_check.sh` 6/6 段の `grep 'warning:'` に当たるので、ラッパーは `Optional` を返して判定をテスト側に出す形（`test_notify.mojo` と同じ）に直した。
  (2) `_payload(7000)` は既存 docstring どおり**次の 2 冪に切り上げる**ので 8,192 byte を返し、PG の payload 上限 7,999 byte を超える。
  1 byte ずつ伸ばす `_notify_payload()` を別に足した。(3) `notify-receive` は 1,000 往復で 154 ms しかかからない（1 iteration 0.15 ms）。速すぎて疑ったが、
  陽性対照で payload ぶんきっちり RSS が伸びたので PGnotify は 1,000 回確かに確保・解放されている
- やり直し: 1 回（上記 (1) の warning。`Optional` を返す形に直して再ビルドで解消）
- 次への注意:
  - T7 は `src/pq/decode_binary.mojo` / `result.mojo` を触るので、**`pixi run bench` の「前」計測を着手直後（この木の状態）に 2 回走らせる**こと（PLAN T7 (d)。切替後と比較する）
  - 確認済み: `cancel()` を 1,000 回連続で呼んでも接続は壊れない（`SELECT 1` 相手だと cancel が間に合わず結果が返る回も多く、`_collect_cancelled` が 57014 と成功の両方を受ける形にしてある）。
    `consume_input()` だけして drop を 1,000 回繰り返しても落ちない（P22 の `PQfinish` 任せが成立）
  - 未確認/契約外の積み残し（T8 (d) の表に入れる 4 件）: ① `PQcancel` が 0 を返す経路（契約外・turn 7） ② `PQsetSingleRowMode` が 0 を返す経路（契約外・turn 7）
    ③ `_after_send` で `PQflush` が -1（契約外・turn 7） ④ **`PQfreeCancel` の欠落（契約外・このターン。RSS では原理的に不可視、コードレビュー担保）**
  - `check` は 169 s（T4 169 s / T5 158 s と同水準）。T7 は bench 4 回ぶんが別途かかる

## turn 9 — impl — T7 UTF-8 検証 + bench 記録 + docstring の「検証しない」文言の更新
- やったこと: 推奨 1 本 / 実 **1 本**（サブエージェントが `decode_binary.mojo` のスキャナ + `test_decode_binary.mojo` の 8 件、
  親が `result.mojo` / `__init__.mojo` / `test_connection.mojo` / `test_zero_copy.mojo` + bench 前後計測 + 統合検証）。
  `_utf8_first_invalid`（RFC 3629 表 3-7 の直書き、最初の不正シーケンスの offset。正しければ -1）と `_validated_utf8`（速い経路は stdlib の
  `StringSlice(from_utf8=)`、失敗時だけスキャナで位置を出して `invalid UTF-8 at byte N of column M`。セル本文は message に入れない）を
  `decode_binary.mojo` に置き、`String` になる **3 経路**を通した: `decode_binary[String]`（`column: Int = -1` キーワード引数を足し `Row.get` / `get_optional` が列番号を渡す）/
  `Result._text`（`PQgetvalue` + `PQgetlength` の `Span` を検証してから `String` 化）/ `Row.get_text`（戻りをそのまま返す）
- **bench（D12。受け入れ条件ではない記録）**: 切替前 2 回 → 後 2 回（`scratch/turn-009-bench-{before,after}-{1,2}.log`。100,000 行 × 5 列 × 3 run）:
  - text: decode **32〜33 ms → 41〜42 ms**（+9 ms、+28 %）、total **71〜76 ms → 83〜85 ms**
  - binary: decode **7〜9 ms → 11〜13 ms**（+4 ms）、total **45〜47 ms → 49〜51 ms**
  - 500,000 セルで +9 ms = **1 セルあたり約 18 ns**。stdlib の 1 回走査ぶんで、自前スキャナは正常系では走らない
- **副産物（P25）**: `_text` が `PQgetlength` 基準になったので、NUL を含む text 値が NUL で切れなくなった（以前は C 文字列として読んでいた）
- 既存テストの期待値変更: **ゼロ**。既存テストへの変更は 1 件だけで、期待値ではなく手順:
  `tests/test_notify.mojo:385` `test_notification_waits_for_the_running_command` に `_wait_until_active`（`pg_stat_activity` が listener の backend を
  `active` と報告するまで最大 2,000 ms 待つヘルパ）を挟んだ。理由: `send` は libpq にバイトを渡すだけで、listener の backend がまだクエリを読んでいなければ
  **idle なので通知が即届く**。NOTIFY が先に commit するとこのテストの前提（「sleep 中は届かない」）が崩れる。T7 とは無関係の既存の競合で、
  通しの 1 回目で実際に落ちた（`early` が 1 件、テスト全体が 9 ms で中断 = sleep が始まる前）。単体では 3 回連続 PASS だったので flake と確認してから直した。
  P20 の主張（コマンド実行中は届かない）を弱めずに競合だけ消す形
- 検証（所要つき）: `pixi run test` 両サーバー PASS（**48 サマリ全部 0 failed**、exit 0、`-- 127.0.0.1:54317 skipped 1` / `-- 127.0.0.1:54314 skipped 1`、
  18:11:58 → 18:16:02 = **244 s**）、`pixi run check` **6/6 PASS**（18:16:11 → 18:19:18 = **187 s**。T6 の 169 s + 18 s）、`pixi run package` 警告ゼロ、
  `pixi run fmt` は `test_notify.mojo` を 1 回整形（コミット前に反映）。`test_decode_binary` 単体は 88 件 **0.10 s**（サーバー不要）、`test_zero_copy` は 12 件 46 s
- チェックリスト（T7 行）: `utf8_unsafe_span=0`（期待 0） / `result_unsafe_ptr=6`（6） / `utf8_from_utf8=2`（≥2） / `utf8_scanner_def=1`（1） /
  `utf8_invalid_message=3`（≥1） / `docs_not_validated=0`（0） / `test_decode_binary_utf8_tests=8`（≥5） / `test_decode_binary_tests=88`（≥85）— **全行期待値**
- 陽性対照（P26。サブエージェントが実測、親が差分で確認）: `_utf8_first_invalid` を直接呼び、stdlib が弾く 4 入力すべてで offset ≥ 0
  （`6162c32863`→2 / `61e282`→1 / `c080`→0 / `eda080`→0）、正しい 2 入力（`68c3a9` と空）で -1。
  併せて message にセル本文（`"ab"` と `0x28` の `"("`）が出ないことを 1 件で確かめている
- PLAN 訂正 2 件（PLAN.md に追記済み）: ① T7 の対象一覧に `tests/test_notify.mojo` を追加（上記の競合修正）
  ② チェックリスト T7 行に実測値と、`utf8_from_utf8=2` の内訳（実呼び出し `decode_binary.mojo:334` + docstring の引用 `:304`。実装箇所は 1 つ）を注記
- 想定外: (1) 上記 `test_notify` の競合。T7 の変更とは無関係だが通しの 1 回目を落としたので、原因（libpq の送信と backend の実行開始のずれ）まで特定して直した。
  (2) `test_zero_copy` が 1 テスト 3.4〜3.9 s かかる。T7 のせいかを疑い `git stash` で HEAD と A/B した（HEAD 41.4 s / 11 件、T7 後 46.3 s / 12 件 = 1 件ぶんの増分のみ）。
  **接続あたりの固定費で、Phase 4 以前からの既存の性質**（他のファイルは 1 テスト 0.1 s 台なので、この 1 ファイルだけ `_connect` の作りが重い。原因未調査）
- やり直し: 1 回（`pixi run test` の 1 回目が `test_notify` の競合で exit 1。原因特定 → ヘルパ追加 → 2 回目で green）
- 次への注意:
  - 確認済み: UTF-8 検証のコストは text decode に +28 %（1 セル 18 ns）で、`String` になる 3 経路すべてが `_validated_utf8` を通る。
    サーバーからは不正 UTF-8 を作れない（`E'\xC3\x28'::bytea::text` は PG が拒否）ので、不正系は `test_decode_binary.mojo` の単体 8 件が唯一の担保。
    `test_zero_copy.mojo` の追加 1 件はその旨を docstring に書いてある
  - 未確認: `_validated_utf8` の「スキャナが -1 を返した（stdlib と食い違った）」分岐（`decode_binary.mojo:339-345`）は到達不能で未到達。
    **誤った値が黙って返る経路ではない**（どちらに転んでも `TYPE_MISMATCH` を投げる。位置が出ないだけ）ので、**処分先は T8 (d) の「契約外」**
  - T8 (d) の表に入れる未確認/契約外は **5 件**: ① `PQcancel` が 0 を返す経路（契約外・turn 7） ② `PQsetSingleRowMode` が 0 を返す経路（契約外・turn 7）
    ③ `_after_send` で `PQflush` が -1（契約外・turn 7） ④ `PQfreeCancel` の欠落（契約外・turn 8。RSS では原理的に不可視、コードレビュー担保）
    ⑤ **`_validated_utf8` のスキャナ不一致分岐（契約外・このターン）**
  - サブエージェントからの契約外の提案（実装せず、記録のみ）: `f4 90 80 80` / `f5 80 80 80` の 4 バイト境界をスキャナの単体に足す案、
    検証失敗に専用の `PgErrorKind.ENCODING` を作る案。どちらも Phase 5 以降の判断（契約は `TYPE_MISMATCH`）
  - Mojo 1.1.0 のメモ（サブエージェント実測）: `len(StringSlice)` は不可（`byte_length()`）、`__origin_of` は廃止で `origin_of`、
    `var x: Int`（初期値なし）＋全分岐代入は通る（`var x = 0` だと `never used` 警告が出る形があった）
  - `check` は 187 s。T8 は `check` + `fmt` + `package` + examples 単体で 5 分前後を見込む（PLAN の「5 分を超えたら書く」の境目）

## turn 10 — impl — T8 文書の最終整備 + 受け入れ基準の総点検 + 最終判定
- やったこと: 推奨 0 本 / 実 **0 本**。`src/pq/__init__.mojo` の `## Asynchronous use` 節に**公開 API の全表**
  （16 行、`AsyncConnection` の全メソッド × 返り値 × raise する `PgErrorKind`）を足し、`.gsd-lite/TRACE.md` を新設して
  §1 チェックリスト最終実行 / §2 受け入れ基準の対応表 / §3「未確認」行の処分表（10 件）を置いた
- (a) 名前の一致: HANDOFF §7.2 の 8 名（`start` / `poll_connect` / `socket` / `send` / `poll_result` / `notifications` / `cancel` / `wait_*`）は
  すべて実装済み・表に記載。`PgErrorKind` 節の 7 件と `TIMEOUT` の説明は既存のまま一致。docstring は `check` 3/6 段が機械判定（**0 missing**）
- (b) チェックリスト再実行: **全 85 行が期待値**（`absent` 0 件）。`test_file_count=24`、`src_def_ref_return=0`、
  `tests_files_count=24`。生出力は `TRACE.md` §1（85 行）
- (c)(d) TRACE.md §2 / §3 に表。REQ §5.1 の 4 件・§5.2 の 4 項目・§5.3 の 3 項目・§5.4 の 5 項目・§4.8〜§4.10 を
  「担うテスト関数 / コマンド」と「turn N で PASS」で対応づけた。§3 は 10 件を **テスト追加 1 / 契約外 7 / verify 申し送り 2** に振り分け。
  「誤った値が黙って返る経路」「状態機械が壊れる経路」を述べた行は**残っていない**（各ターンで判定済み。このターンで追加したテストは 0 件）
- 既存テストの期待値変更: **ゼロ**（このターンはテストを 1 行も触っていない。変更は `__init__.mojo` の docstring と `.gsd-lite/` のみ）
- 検証（所要つき）: `pixi run fmt` → `52 files left unchanged`（差分なし）、`pixi run package` 警告ゼロ、
  `pixi run test` 両サーバー **48 サマリ全部 0 failed**・exit 0（18:26:15 → 18:31:29 = **314 s**）、SKIP 集計行が各サーバーに 1 本ずつ、
  `pixi run check` **6/6 PASS**（18:31:40 → 18:34:40 = **180 s**。`final_check: PASS`、6/6 段の一致行 0）、
  `pixi run example-async`（`n = 1` / `empty polls while waiting = 19`）と `pixi run example-notify`（`channel = pq_example` / `payload = hello from pq` / `backend_pid = 1541121`）が単体実行で成功
- PLAN 訂正 1 件（PLAN.md に追記済み）: T8 (c) の「`grep -c 'Copyable' src/pq/async_conn.mojo` が `Notification` の 1 行だけ」→ **2**。
  `AsyncConnection` の docstring が「`Movable` and not `Copyable`」と述べる `:43` を数え落としていた。`struct AsyncConnection(Movable)`（`:277`）に `Copyable` は無いので要件自体は満たす
- 想定外: なし
- やり直し: 0 回
- 次への注意:
  - 確認済み: Phase 4 の全 8 タスク完了。`pixi run test` 314 s / `pixi run check` 180 s（PLAN の見込み 330〜360 s / 260〜300 s より速い。
    実測が見込みを下回ったのは leak が `check` では 1 サーバーのみのため）。テストファイル 24 本、`test_async` 29 件 / `test_notify` 9 件 / `test_poll` 9 件
  - verify への申し送り（TRACE.md §3 の「verify 申し送り」2 件）: ① `poll.mojo` の Windows 分岐は未コンパイル・未検証
    （モジュール docstring に **unverified** 明記。Phase 5 の「Windows 用コードパスのレビュー」が引き取る）
    ② `test_zero_copy` が 1 テスト 3.4〜3.9 s（Phase 4 以前からの既存の性質。A/B 済み。Phase 5 のベンチマークが引き取る）
  - verify が照合すべき一覧: 既存テストの期待値変更は Phase 4 全体で **ゼロ**（turn 9 の `test_notify.mojo:385` への
    `_wait_until_active` 挿入だけが既存テストへの変更で、期待値ではなく手順。理由は turn 9 に記載）
  - 未確認: なし（TRACE.md §3 で 10 件すべてを処分済み）

## turn 11 — verify — round 1: 指摘あり（差し戻し F1 = 誤動作 1 + D12 整合 1 + 文書・例 5）/ マージなし
- やったこと: サブエージェント 2 本（コードレビュー / セキュリティ、読み取り専用、並行 約 10 分）+ 親が `async_conn.mojo` / `poll.mojo` 通読、クリーンな `pixi run check`（**6/6 PASS、179 s**、47 サマリ全部 `0 failed`）、
  追従先チェックリスト再実行（全行期待値。TRACE §1 との差は `init_TIMEOUT` 3 → 6 の字句のみ）、堅牢性プローブ 5 本（`scratch/turn-011-probe-grid.mojo`）。VERIFICATION.md を作成し PLAN に F1 を追記
- 判定の根拠: 受け入れ基準 §5.1 の 4 件・§5.2・§5.4 は全部満たす。差し戻しは **`timeout_ms ≥ 2^31` の `c_int` 切り捨て**（`2^32+50` → 50 ms で timeout、`fetch_all(Int.MAX)` → 0 ms で `TIMEOUT`。親とセキュリティが独立に再現）が
  「黙って誤動作」に当たるため。ついでに `notifications()` の UTF-8 無検証（`SQL_ASCII` DB で再現。D12 の趣旨と不整合）と文書・例 5 件を F1 に同梱。既存テストの期待値変更ゼロはコードレビュー側が全 hunk 分類で確認
- 想定外: (1) サブエージェントの出力ファイルの更新時刻で完了を待つ `until` ループが即終了した（出力は完了時にまとめて書かれる）→ `sleep 300` の再試行で待った。
  (2) セキュリティ側が検証のために PG17 に `pq_sec_ascii` DB を作って削除した（作業木は無変更）。(3) P3（`Sending` 中の切断）は 3 回中 1 回しか `Sending` を観測できなかったが、その 1 回で状態機械が `Idle` に戻ることを確認
- やり直し: 1 回（上記 (1) の待ち方）
- 次への注意: impl は F1 の**期待結果の表**だけを見て実装する（文言は表に 1 回だけ書いた）。`pq` は両サーバーで superuser なので `CREATE DATABASE pq_test_ascii` はテストが自分で作れる（`42P04` は無視）。
  F1 (b) の `LISTEN "ch\xC3\x28"`（channel 側）が PG に拒否されたら payload 側だけにしてよい。round 2 の verify は PLAN F1 末尾「修正後にプローブで期待される変化」の数だけ照合する
  （P1 → `USAGE`、sec-timeout 4 行 → `USAGE`、sec-ascii-notify → `TYPE_MISMATCH`、`test_poll` 11 / `test_async` 30 / `test_notify` 10〜11）。セキュリティ側プローブは DB 名 `pq_sec_ascii` を使っているので round 2 で `pq_test_ascii` に直して回す

## turn 12 — impl — F1 verify round 1 の差し戻し（timeout 上限 / 通知の UTF-8 / 文書・例 5 件）
- やったこと: 推奨 0 本 / 実 **0 本**。`_platform/poll.mojo` に `TIMEOUT_MS_MAX = 2147483647` と
  `_reject_bad_timeout` を置き、`poll_socket` と `async_conn` の両方がこの 1 定義を使う形にした（決めた事項 17 の
  import 向き `poll → errors` は維持。async_conn 側の同名関数は削除して import に置き換え）。`notifications()` は
  channel / payload を UTF-8 検査するようになり、文書 5 件と `examples/async_query.mojo` のループを直した
- 期待結果の表 7 件: 全部テストに落ちて PASS（対応表は TRACE.md §4）。`test_poll` +2 / `test_async` +1 /
  `test_notify` +2 ＝ 11 / 30 / 11 件
- (b) の実装: `PQfreemem` は検査の**前**に呼ぶ（`async_conn.mojo:1399`）。raise 経路でも必ず通るのでこれで
  `src_PQfreemem_calls=3` のまま。raise の直前に `self._pending = found^`（`:1408`）で正常分を戻す
- (b) の陽性対照: `_reject_bad_notification_text` の先頭に `if True: return` を入れたコピーで
  `scratch/turn-012-ascii-notify.mojo` を 1 回実測 → `notification payload bytes: 0x61 0x62 0xc3 0x28  byte_length 4`。
  すぐ戻し、同じプローブが `invalid UTF-8 at byte 2 of notification payload` になることを確認（TRACE §4 に記載）
- 既存テストの期待値変更: **ゼロ**。既存の 2 件（`test_timeout_below_minus_one_is_rejected` /
  `test_a_budget_below_minus_one_is_usage`）は部分文字列 `"timeout_ms must be"` しか見ていないので文言変更後も無変更で通る。
  `test_extended_datetime.mojo:787` の SKIP は**文言だけ**（判定ロジック不変）
- 検証（所要つき）: `pixi run fmt` 差分なし（52 files unchanged）、`pixi run package` 警告ゼロ、
  `pixi run test` 両サーバー **48 サマリ全部 0 failed**・exit 0、SKIP 集計行が各サーバーに 1 本、
  `pixi run check` **6/6 PASS**（19:09:55 → 19:12:50 = **175 s**）。チェックリスト再実行は全 83 行が期待値
  （`poll_external_call_symbols=2` / `src_PQfreemem_calls=3` / `src_PQexec_calls=4` 不変）
- round 2 用プローブの実測: `turn-011-probe-grid` の P1 → `Usage`（P2 / P5 は不変）、`turn-011-sec-timeout` の
  4 行（`wait_readable(2**32)` / `fetch_all(Int.MAX)` / `fetch_all(1e13)` / `wait_notification(2**32)`）が全部 `Usage`、
  `wait_readable(300)` は `Timeout` のまま
- 想定外: (1) PLAN (b) は `strlen` 長の `Span` を指定していたが、`strlen` を `external_call` で引くと
  stdlib が同名シンボルを別シグネチャで束縛している risk があるため（`poll.mojo` モジュール docstring の注）、
  `String(unsafe_from_utf8_ptr=)` で作った owned コピーの `as_bytes()` を検査する形にした。不正な `String` は
  ローカルに留まり呼び出し側へは出ない。スキャナ `_utf8_first_invalid` は `decode_binary` から import（実装 1 つ）。
  (2) F1 (b) ② の `LISTEN "ch\xC3\x28"` は **PG が受ける**（PG17 で実測。識別子 4 byte）。ただし `LISTEN` は
  識別子しか取らないので、`DO $$ ... format('LISTEN %I', E'ch\xC3\x28') ... $$` 経由で送った（送る SQL 自体は ASCII）
- PLAN 訂正 1 件: F1 (b) の「`strlen` 長の `Span`」→ 「owned `String` の `as_bytes()`」（上記 (1)。
  PLAN は「`_validated_utf8` 相当で検査する」が本題で、長さの取り方は要件・決定に触れない）
- やり直し: 2 回（`_assert_sql_ascii` のコンパイル: `raises PgError` の `try` 本体から `assert_equal` を呼べない →
  値だけ取り出して外で assert / `get_text` の `StringSpan` を `String()` で包む）
- 次への注意:
  - round 2 の verify は PLAN F1 末尾「修正後にプローブで期待される変化」の数と TRACE §4 を照合すれば足りる。
    `turn-011-sec-ascii-notify.mojo`（DB 名 `pq_sec_ascii`）は `scratch/turn-012-ascii-notify.mojo` が
    `pq_test_ascii` 版として置き換わっているのでそちらを使う
  - テストが作る `pq_test_ascii` DB は**消さずに残る**（両サーバー）。`42P04` を無視するので再実行は安全
  - `empty polls while waiting` は例の形を変えたので値が動く（今回 17。`n = 1` の行は不変）
  - 未確認: なし（F1 で足したコードはすべてテストが通る。`_reject_bad_notification_text` の
    `offset < 0` 分岐だけは TRACE §3 #9 と同じ到達不能分岐で、どちらでも `TYPE_MISMATCH`）

## turn 13 — verify — round 2: 合格 / 指摘 0 / `main` へ `--no-ff` ローカルマージ成功
- やったこと: サブエージェントなし（F1 差分 +296 / -45 を親が通読）。PLAN F1 末尾「修正後にプローブで期待される変化」を `turn-011-probe-grid` / `turn-011-sec-timeout` / `turn-012-ascii-notify` の再実行で全項目一致を確認
  （P1 と timeout 4 入口が `Usage`、SQL_ASCII 通知が `TypeMismatch`、P2〜P5 不変）。クリーンな `pixi run check` **6/6 PASS**（19:18:02 → 19:20:49 = **167 s**、47 サマリ `0 failed`、`skipped 1` ×2）、
  追従先チェックリスト再実行は turn 12 と diff なし。VERIFICATION.md §8 に round 2 を追記して合格に更新 → `git checkout main` → `git merge --no-ff gsd-lite/phase4-async-cancel-notify`（衝突なし、42 ファイル）。ブランチは残す
- 想定外: なし（P3 は 3 回とも `Busy` で `Sending` を 1 回も観測しなかったが、round 1 の「3 回中 1 回」と同じ非決定の範囲）
- やり直し: 0 回
- 次への注意: reflect は REQ §9 の実験（T5「テスト 2 ファイル型を 1 本」の USD を Phase 3 T6 の 2 本・USD 10.77 と比べる）を生ログから。verify 側の学び: round 1 の「修正後にプローブで期待される変化」を数で書いておいたので round 2 は 10 分で終わった（プローブ 3 本 + check 1 回 + 通読）。
  テストが両サーバーに `pq_test_ascii` DB を残す（Phase 5 の環境整備で `db-reset` 相当を考える余地）。`PQcancel` の deprecated 注記と Windows 分岐の未検証は Phase 5 への申し送りのまま
