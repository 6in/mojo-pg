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
