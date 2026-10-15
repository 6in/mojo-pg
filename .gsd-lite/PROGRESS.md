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

## turn 2 — plan — 7 タスク（T1 持ち越し整理 + leak の mojo build 化 / T2 基盤 / T3 params / T4 prepared / T5 transaction / T6 leak ループ / T7 example + 仕上げ）
- やったこと: REQUIREMENTS / DECISIONS / RESEARCH / reflect / 前回 PLAN・VERIFICATION とコードベース（`src/pq` 全部、`tests/*.sh`、`test_ffi` / `test_leak` / `test_connection`）を読み、PLAN.md を作成。
  決めた事項 23 件（`Param` の構築時エンコード設計、`_ParamBuffers`、`_take_result` 抽出、`Result.command_tag()`、`pq_stmt_N` カウンタ、`Transaction` の `done` 先行、ハンドラの `setenv` 観測、
  REQ 読み替え 5 件、`PQ_TEST_LEAK_SERVERS`、`build/fmtcheck`、6/6 段の `WARNING:` 計数、USAGE 文言）。盗める点 11 件の採否表、reflect 提案 11 件の反映表、落とし穴 P1〜P24 → タスク対応、REQ §5.2 → 担当表。
  plan 時プローブ 1 本（`scratch/turn-002-cyc/`）で (1) パッケージ内の循環 import、(2) `print(file=stderr)`、(3) `setenv` 往復、(4) 不変 `self` からのカウンタ更新 を Mojo 1.1.0 で確認
- 想定外: (1) `Connection.transaction()` / `prepare()` は `connection.mojo` にしか置けず（`extension` 無し）、戻り型の `Transaction` / `PreparedStatement` は別ファイル → **循環 import が必須**になるのを設計中に発見。
  RESEARCH に無かったのでプローブで確認してから PLAN に書いた（通った）。(2) REQ の受け入れ基準 2 件が実測と矛盾する件（RESEARCH §5）は BLOCKED にせず、D16 の意図（その状況での堅牢性）を満たす読み替えを決めた事項 14 に固定した
  （REQ 本文は触っていない。verify はこの項を正とする）。(3) `PQexec` 直呼び箇所の数え上げを一度 3 と書いて 4 に訂正（describe 失敗時の DEALLOCATE を忘れた）。(4) lean-ctx MCP は未接続（素のツール）
- やり直し: 1 回（追従先チェックリストの `PQexec(` 行数 3 → 4。決めた事項 9 を書いたあとに自分の表と突き合わせて気づいた）
- 次への注意: (1) T1 は `check` を**コミット後**に回す（1/6 段を直すのが T1 自身）。T1 (h) は「作業木のまま `check` 6/6」が完了基準なので、直した後にもう 1 回回す。
  (2) T1 の `TOLERANCE_PAGES` は PG17 ×2 + PG14 ×2 の 16 系列を見てから決める（+83 段が 1 回でも出たら 256 維持）。陽性対照 2 本（PQclear / PQfreemem）は同じターンで実測し系列を貼る。
  (3) impl のサブエージェント依頼文に PLAN「impl への申し送り」の 3 行（型パラメータをフルに / fmt は親だけ / scratch 命名）を必ず入れる。
  (4) 「未プローブ」節の 4 項目（Optional 19 本の曖昧性、`Transaction.prepare` の origin、`List[UInt32]()` 既定引数、2 引数オーバーロードのリスト literal）は該当タスクの最初に小さなプローブで確認し、通らなければ PLAN 訂正で代替案へ。
  (5) 決めた事項 14（REQ 読み替え）はテストの期待値に直結する: prepared は ROLLBACK 後も**成功**、型不一致は `Bool` → int4 と `Int(3000000000)` → int4、接続断の `transaction()` は CONNECTION
