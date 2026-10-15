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

## turn 2 — plan — 8 タスク（T1 errors+_ffi 50 本+テスト基盤 / T2 loader / T3 decode_text / T4 Connection+Result 本体 / T5 Row+iter / T6 escape+status+examples / T7 leak / T8 品質仕上げ）
- やったこと: REQUIREMENTS / DECISIONS / RESEARCH / HANDOFF とコードベース・`libpq-fe.h` を読み、50 本の C プロトタイプ（ヘッダ行番号付き）、enum 値、`PG_DIAG_*` を実物から表にして PLAN.md を作成。
  最終判定コマンド `pixi run check`（`tests/final_check.sh`、T1 で作る）と 2 サーバー `run_tests.sh` を確定。RESEARCH §4 の盗める点 11 件を採否表に、§5 の落とし穴 21 件をタスクに対応づけた
- 想定外: (1) `mojo precompile --help` は `-o` に `.mojopkg` も可と書くが実際は `error: output path must have a '.mojoc' extension`（実測）→ REQ §5.1b は `.mojoc` に読み替え（D11 の目的は満たす。決めた事項 8）。
  (2) RESEARCH は PQfname / PQgetvalue を非 NULL 扱いにしていたが libpq は範囲外 index で NULL を返すので `OptCStr` に変更（決めた事項 2）。
  (3) D8 の trait 式は不可（research 確定済み）→ `comptime if` 型スイッチを PLAN に記録。(4) 存在しない列名 / 範囲外 index の kind は REQ 未指定 → `TYPE_MISMATCH` に決定（決めた事項 7）
- やり直し: 0 回
- 次への注意: impl は `/home/parallels/.pixi/bin/pixi run ...` のフルパスで呼ぶ。T1 は 3 サブ作業（errors / _ffi / テスト基盤）で 1 ターン想定、T1 時点では `pixi run check` が examples 段で落ちる（T6 で揃う）。
  `pg_terminate_backend` による切断テスト（T4）と `size_of` / macOS 判定の名前は未プローブなので、違えば実測を正に PLAN 訂正。struct 内 `comptime X = Self(n)`（PgErrorKind）も未検証でフォールバック先を決めた事項 4 に書いた
