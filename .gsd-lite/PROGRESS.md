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
