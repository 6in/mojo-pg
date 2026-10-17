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
