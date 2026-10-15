# PROGRESS — phase1-sync-text-basic

## turn 1 — research — Mojo 1.1.0 FFI/言語制約をプローブで確定、類似 OSS（postgres.mojo）は非ブロッカーと判定
- やったこと: similar_oss / official_docs / local_projects を調査し RESEARCH.md に集約。9 本のプローブ（scratch/turn-001-probe-*.mojo）で
  get_function / get_symbol+thin 関数ポインタ / _Global / 型スイッチ get[T] / Iterable / atol・atof / 接続ループ RSS を PG17・PG14 で実測
- 想定外: (1) D8 の trait 式は `extension` 構文が無く不可 → `comptime if` 型スイッチで代替（型別 getter は不要）。
  (2) `mojo package` は `.mojoc` 必須で `.mojopkg` 不可（REQ §5.1b に影響、提案として記載）。
  (3) `mojo` / `pixi` が無人シェルの PATH に無い（`/home/parallels/.pixi/bin/pixi run` のフルパスで解決）。
  (4) `ExternalFunction` / `comptime match` / モジュール `var` / `OpaquePointer`（origin 無し）/ `OptionalPointer` のフィールド化は 1.1.0 では使えない。
  (5) lean-ctx MCP ツールは未接続（通常ツールで実施）
- やり直し: 7 回（プローブのコンパイルエラー修正: 不存在シンボル名 `ImmAnyOrigin`→`ImmutAnyOrigin`→`ImmUntrackedOrigin`、`OpaquePointer`、
  `ExternalFunction`、`extension`、グローバル `var`、`comptime match`、`rebind` の暗黙コピー、`Pointer(unsafe_from_address=0)`、`as_c_string_span` の `mut self`）
- 次への注意: plan は RESEARCH §2.1/§2.2 の採用設計（Int newtype opaque、thin 関数ポインタ表、`_Global`+`LoadState`）と §5 の落とし穴表を
  タスク完了基準に写すこと。`pixi` は `/home/parallels/.pixi/bin/pixi` のフルパスで呼ぶ。`.mojopkg` ではなく `.mojoc`。
  現行 `src/pq/__init__.mojo` の docstring は lint 警告を出す（先頭を大文字に）。10,000 回ループは約 35 s/サーバー
