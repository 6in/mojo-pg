# PROGRESS — phase2-params-prepared-tx

## turn 1 — research — libpq / Mojo 1.1.0 の実測 + リーク測定方式の裏取り（RESEARCH.md）
- やったこと: REQUIREMENTS / DECISIONS / 前回 RESEARCH・reflect を読み、プローブ 6 本（variant / implicit / tx / encode / negzero / libpq）を
  Mojo 1.1.0 で実行。libpq プローブは PG17 / PG14 両方で回し出力が同一であることを `diff` で確認。`mojo build` したバイナリで `test_leak` を
  PG17 で実測（平坦 ±2 ページ、ベースライン 4,084 ページ）し、`PQclear` を消した陽性対照が FAIL することも実測。rust-postgres / psycopg 3 /
  PG 公式・ML を調査して RESEARCH.md に集約（結論サマリ 6 件、落とし穴 24 件、要件への提案 8 件）
- 想定外: (1) **REQ の受け入れ基準 2 件が実測と矛盾**: prepared statement は ROLLBACK で消えない（E4）／ int8 パラメータを int4 列に INSERT しても
  42804 にならず成功する（B1）。BLOCKED にはせず RESEARCH §5 に読み替え案を提案した（作る/使うの判断には影響しない）。
  (2) `Transaction` が最後の使用直後に ASAP 破棄され ROLLBACK が走る（probe-tx）。API 設計そのものは変えずテスト・docstring の規約で吸収する前提で記録。
  (3) pixi env に Mojo stdlib のソースが無い（`std.mojoc` のみ）。REQ §9 の「stdlib ソースの場所を特定」は「docs サイト + コンパイルエラーの候補シグネチャ」に置き換えた。
  (4) `mojo format` に `--check` が無い。(5) lean-ctx の MCP ツールは未接続（素のツールで進めた）
- やり直し: 5 回（probe 初回コンパイル: `List[UInt8](1,2,3)` 位置引数ctorが無い ×3 ファイル / `String` の `s[i]` 不可 / `UnsafePointer` deprecated + origin 必須 /
  `len()` の Int を `c_size_t` に / `Variant` と `Param` への素の `None` 変換不可 ×2。いずれも Mojo 1.1.0 のシグネチャを記憶で書いたのが原因。
  §0.5 に落とし穴として追記済み）
- 次への注意: (1) plan は RESEARCH §5 の提案 1・2（prepared × ROLLBACK、型不一致の題材）を PLAN の「決めた事項」で確定し、REQ の該当テストを読み替える
  （REQ 本文は research では触っていない）。(2) P1 / P2（ASAP 破棄）をテスト・example の完了基準に最初から書く。(3) `run_tests.sh` の `mojo build` 化と
  `TOLERANCE_PAGES` は PG14 側の実測が未了なので impl 初回タスクで PG14 / PG17 × 2 回回してから決める。(4) `PQcmdStatus` / `PQnparams` / `PQparamtype` の
  thin 型は RESEARCH §7 の表のとおり（ヘッダ行 600 / 607 / 608）。(5) プローブを書くときは `List[T]` 位置引数ctor・`s[i]`・`UnsafePointer` を使わない
