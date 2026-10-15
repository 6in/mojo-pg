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

## turn 3 — impl — T1 持ち越し整理 + リーク測定の mojo build 化 + final_check の fmt / WARNING 判定
- やったこと: サブエージェント 2 本（A: docstring 3 件 + `test_leak.mojo` の docstring / B: `run_tests.sh` の `mojo build` 分岐と
  `PQ_TEST_LEAK_SERVERS`、`final_check.sh` の 1/6・5/6・6/6 段）を並行で走らせて統合。親で `TOLERANCE_PAGES` の実測決定（16 系列）、
  リーク陽性対照 2 本、fmt 陽性対照、`pixi run test` ×2 と `pixi run check` を実行。T1 の完了基準 (a)〜(h) をすべて満たしてコミット（7ce578c）
- 想定外: **(1) 1/6 段の新方式が無言の no-op だった**。`mojo format` はディレクトリ走査時に `.gitignore` の除外を尊重するため、
  コピー先 `build/fmtcheck/`（`.gitignore:6` の `build/`）配下のファイルを 1 つも整形せず（`No Mojo files are present to be formatted`）、
  `diff -r` が常に一致して**段が永久に PASS する**状態だった。`find ... -print0` の明示ファイル列を渡す形に直した（明示指定は除外されない）。
  陽性対照を完了基準に入れていたから捕まった（reflect 提案 1 の効果。PLAN 訂正に記載）。
  (2) **+83 ページの一段は `mojo run` 固有ではなく built binary でも出る**。サブエージェント A が書いた「`mojo run` では偽陽性になり得る」は
  実測と食い違うので、親が「`mojo run` では最初の 1〜2 区間が平坦化され単調増加シグナルが効かなくなる」に書き換えた。
  (3) `TOLERANCE_PAGES` を 16 に下げられなかった（下記 (f)）
- やり直し: 1 回（fmt 陽性対照。`comptime SERVER = Self(2)` を崩しても `diff` が 0 のままで、最初は「`mojo format` が `comptime` 行を
  整形しないのか」と疑った。単一ファイル指定では整形される／ディレクトリ指定では `No Mojo files are present` と出る差から
  `.gitignore` 尊重が原因と特定し、`build/` 外（`fmtprobe-turn003/`）へのコピーで裏取りしてから 1/6 段を直した）
- 次への注意: (1) `check` は**作業木のままで回せる**ようになった（T1 (h) で実測、73 s）。T2 以降はコミット前に回してよい。
  (2) `pixi run test` は leak を両サーバーで回すので 4〜5 分、`check` は leak 1 サーバーで 73 s。T6 で Phase 2 の 4 ループが乗ると伸びる。
  (3) `tests/test_ffi.mojo` はまだ `test_all_fifty_symbols_present` / 50 本のまま（T2 の担当）。
  (4) サブエージェントは契約どおり動いたが、**実測に基づかない断定を docstring に書く**ことがある（上記 (2)）。
  親の実測と突き合わせる手順を省かないこと。
  (5) `.gitignore` 配下を触るツールは除外を尊重するものとして疑う（`mojo format` / 将来のリンタも同様）

### T1 完了基準の実測

- (b) REQ §6-2: `grep -n 'that one path only' src/pq/_ffi/loader.mojo` → `loader.mojo:10` の 1 件。コード変更なし ✓
- (c) REQ §6-4: `OID_*` 11 定数は `src/pq/decode_text.mojo:18-48` に健在。T1 では変更なし ✓
- (e) 追従先チェックリスト「テスト環境の環境変数を足す」: `grep -rn PQ_TEST_LEAK_SERVERS tests/run_tests.sh tests/final_check.sh` → 5 行（run_tests.sh:19,82,83,85 / final_check.sh:119）≥ 2 ✓。
  `git check-ignore -v build/test_leak` → `.gitignore:6:build/` ✓

#### (f) `TOLERANCE_PAGES` の決定 → **256 を維持**

`pixi run test` を 2 回（PG17 / PG14 × 4 ループ = 16 系列）。built binary、`mkdir -p build` → `mojo build` 済み:

| 回 | サーバー | 系列 | 増分 |
|---|---|---|---|
| 1 | PG17 | connect/query/close `[4084, 4086, 4086, 4086, 4086, 4086, 4086, 4086, 4086]` | 2 |
| 1 | PG17 | failed-open `[4549, 4549, 4549, 4549]` | 0 |
| 1 | PG17 | escape_literal `[4559, 4559, 4559, 4559]` | 0 |
| 1 | PG17 | failed-execute `[4559, 4559, 4559, 4559]` | 0 |
| 1 | PG14 | connect/query/close `[4085, 4087, 4087, 4087, 4087, 4087, 4087, 4087, 4087]` | 2 |
| 1 | PG14 | failed-open `[4550, 4550, 4550, 4550]` | 0 |
| 1 | PG14 | escape_literal `[4575, 4575, 4575, 4575]` | 0 |
| 1 | PG14 | failed-execute `[4575, 4575, 4575, 4575]` | 0 |
| 2 | PG17 | connect/query/close `[4085, 4087, 4087, **4170**, 4170, 4170, 4170, 4170, 4170]` | **85（+83 の一段、4 サンプル目）** |
| 2 | PG17 | failed-open `[4550, 4550, 4550, 4550]` | 0 |
| 2 | PG17 | escape_literal `[4575, 4575, 4575, 4575]` | 0 |
| 2 | PG17 | failed-execute `[4575, 4575, 4575, 4575]` | 0 |
| 2 | PG14 | connect/query/close `[4083, 4085, 4085, 4085, 4085, 4085, 4085, 4085, **4168**]` | **85（+83 の一段、9 サンプル目）** |
| 2 | PG14 | failed-open `[4548, 4548, 4548, 4548]` | 0 |
| 2 | PG14 | escape_literal `[4573, 4573, 4573, 4573]` | 0 |
| 2 | PG14 | failed-execute `[4573, 4573, 4573, 4573]` | 0 |

**+83 ページの一段が 2 回出た**（PLAN の分岐: 「一段が 1 回でも出たら 256 のまま維持」）→ `TOLERANCE_PAGES = 256` を維持。
増分 85 は 16 を超えるので、16 に下げていれば偽陽性で落ちていた。
一段は `mojo run` 固有ではなく **built binary でも出る**（RESEARCH 時の PG17 単発では出ていなかった）。
`check` の実行（T1 (h)）でも 3 回目の一段が出た（PG17 `[4085, 4087 ×6, 4170, 4170]`）。
`is_leaking` の単体テスト 4 件（tolerance 16 を引数で渡す）は PLAN どおり未変更。

#### (g) リーク陽性対照（PG17、built binary、`scratch/turn-003-leaksrc-*/`）

① `Result.__deinit__` の `PQclear` を `pass` に（`result.mojo:99`）:
```
FAIL [ 29402.729 ] test_connect_query_close_does_not_leak
  connect/query/close RSS pages: [37824, 54667, 71509, 88351, 105191] — grew 67367 pages
  past the first sample, over the 65536 allowed; aborting the loop (leaking)
```
→ 5 サンプル目で `ABORT_PAGES` 超過（RESEARCH 時と同じ）。他 3 ループは PASS（エラー経路の `PQclear` は `__deinit__` 経由ではないため）。

② `escape_literal` の `PQfreemem` を削除（`connection.mojo:354`）:
```
FAIL [ 204.337 ] test_escape_literal_does_not_leak
  AssertionError: escape_literal RSS pages: [10847, 14049, 17250, 20452]
```
→ 単調増加（+3,200 ページ/区間）で検出。`connect/query/close` は `[4085, 4087 ×8]` で PASS（この対照ではベースライン 4,085 ページを確認）。

2 経路（`PQclear` / `PQfreemem`）とも検出できることを実測した。

#### (d) fmt 陽性対照 + 発見した欠陥

`src/pq/errors.mojo` の `comptime SERVER = Self(2)` を `comptime   SERVER   =   Self( 2 )` に崩して実測:

| 手順 | 結果 |
|---|---|
| `mojo format --quiet build/fmtcheck/src ...`（**ディレクトリ指定**、B の初版） | `diff -r -q` が**一致**（`fmt_diff=0`）= 検出できない |
| `mojo format build/fmtcheck2/src`（単体で再現） | `No Mojo files are present to be formatted. Nothing to do` |
| `mojo format build/fmtcheck/src/pq/errors.mojo`（**単一ファイル指定**） | `reformatted` = 整形される |
| `cp -r src fmtprobe-turn003/src`（`build/` の外）+ ディレクトリ指定 | `1 file reformatted, 8 files left unchanged` = 整形される |
| `find build/fmtcheck -name '*.mojo' -print0 \| xargs -0 mojo format` | `1 file reformatted, 19 files left unchanged` = 整形される |

→ 原因は **`mojo format` がディレクトリ走査時に `.gitignore` の除外を尊重すること**。コピー先が `build/`（`.gitignore:6`）配下なので
1 ファイルも拾わず、段が常に PASS していた。**明示ファイル列**を渡す形に修正（`fmt_files` 配列、0 件なら `fail`）。

修正後、崩した作業木で**実際の `pixi run check`** を実行:
```
=== [1/6 fmt (no diff)] 2026-10-16T00:41:31+0900
ファイル src/pq/errors.mojo と build/fmtcheck/src/pq/errors.mojo は異なります
--- FAIL: 1/6 fmt (diff not empty)
final_check: FAIL
  - 1/6 fmt (diff not empty)
```
→ 1/6 段だけが FAIL（他 5 段は PASS）。`errors.mojo` を戻すと `fmt_diff=0` に復帰し、`git status` から消えた（コミット前に確認）。

#### (h) 最終検証（作業木が未コミットの状態で実行）

- `pixi run test`: 両サーバー PASS。ログに `== mojo build tests/test_leak.mojo` 行あり、`build/test_leak` が生成され leak は 54314 でも回った。
  test_leak の所要: PG17 54〜57 s / PG14 52 s（うち connect/query/close が 47〜51 s）
- `pixi run check`: **6/6 PASS**（作業木未コミットのまま = 1/6 段の新方式の効果）。所要 **73 s**（1/6 〜 6/6 の timestamp 差。Phase 1 末は 96 s）。
  5/6 段が 70 s でほぼ全部。54314 側に `-- 127.0.0.1:54314 tests/test_leak.mojo skipped (PQ_TEST_LEAK_SERVERS=1)` が出た ✓
  6/6 段 `matched lines in build/final_check.log: 0`（`warning:` と `WARNING:` の両方を計数して 0 件）✓

## turn 4 — impl — T2 基盤（_ffi 53 本 / USAGE / command_tag / _take_result / encode_binary）
- やったこと: サブエージェント 4 本（A: `_ffi` 3 本 + `test_ffi` / B: `PgErrorKind.USAGE` + docstring five→six + `test_errors` /
  C: `encode_binary.mojo` + `test_encode_binary` / D: `Result.command_tag()` + `test_result` 追記 + `Connection._take_result` 抽出）を
  対象ファイル非重複で並行実装。親で統合 → `fmt` 1 回 → `package` → docstring 診断 → `check`。完了基準 (a)〜(g) をすべて満たしてコミット（a658b55）
- 想定外: **符号付き整数のシフトが PLAN どおりには書けなかった**。`SIMD.__rshift__` の rhs は `Self` 固定で `v >> Int` が通らず、
  さらに符号付き右シフトは符号拡張するので `encode_int16(-1)` の上位バイトが `0xFF` で埋まる。`bitcast` でゼロ拡張してから
  `UInt64` に広げる形に変えた（PLAN 訂正に記載。シフトで組む / エンディアン非依存という PLAN の意図は維持）。
  もう 1 点、`List[UInt8]` のローカルを `return out` で返すと `ImplicitlyCopyable` 非準拠エラーになり `return out^` が必要だった
- やり直し: 0 回
- 次への注意: (1) `Connection._take_result` が入ったので T3 の `execute(sql, params)` は結果採用を自分で書かず
  `return self._take_result(res)` を呼ぶだけでよい。(2) `encode_binary` は `from pq.encode_binary import ...` のみ
  （`__init__.mojo` への再エクスポートは PLAN どおり未実施。T3 以降で `Param` 側が内部利用する）。
  (3) **`write_to` の `elif` 連鎖は `else` が無い**ので、将来 `PgErrorKind` を足して `write_to` への追記を忘れると
  `String(kind)` が**空文字になって黙って通る**（テストが無い）。T3〜T5 で USAGE を投げるテストは `kind=Usage` の
  文字列一致で見ているので今回は捕まるが、定数追加時は `write_to` も必ず確認すること。
  (4) サブエージェントは今回 4 本とも契約どおりで、前ターンのような未実測の断定は出なかった（契約の抜き書きと
  「契約外は報告だけ」の固定文言が効いている）

### T2 完了基準の実測

- (a) `_ffi` 3 本: `grep -c '^    var PQ' src/pq/_ffi/functions.mojo` → **53**、
  `grep -cE '^        (String\()?"PQ[A-Za-z]+"\)?,$' tests/test_ffi.mojo` → **53**、`grep -c fifty tests/test_ffi.mojo` → **0**（exit 1）✓
  ヘッダ行を再確認: `grep -n 'PQcmdStatus\|PQnparams\|PQparamtype' .pixi/envs/default/include/libpq-fe.h` → 600 / 607 / 608（PLAN の表と一致）✓
- (b) `USAGE`: `grep -rnE 'exactly five|the five failure|five failure' src/pq` → **0 件**（exit 1）、
  `grep -c 'USAGE' src/pq/errors.mojo` → **3**、`grep -n 'five' src/pq/__init__.mojo` → `__init__.mojo:8` の `PQTRANS_*` の 1 件だけ残る（別物。触っていない）✓
- (c) `Result.command_tag()`: `test_command_tag_reports_the_server_tag` が両サーバーで PASS。
  実測タグ: `SELECT 1` → `"SELECT 1"` / `CREATE TEMP TABLE pq_p2_tag(x int)` → `"CREATE TABLE"` /
  `INSERT INTO pq_p2_tag VALUES (1),(2)` → `"INSERT 0 2"` / `UPDATE pq_p2_tag SET x = 0 WHERE false` → `"UPDATE 0"`（PLAN の期待値どおり）✓
- (d) `_take_result` 抽出: `git diff src/pq/connection.mojo` が**挿入のみ**（移した `:255-308` の範囲に `-` 行が無い）= 1 文字も挙動を変えていない。
  `execute(sql)` の本体は `_reject_nul` → `PQexec` → `_ = sql^` → `return self._take_result(res)` の 4 ステップ。
  **`tests/test_connection.mojo` は無変更で 28/28 PASS**（両サーバー）✓
- (e)(f) `encode_binary`: 6 関数ちょうど（`Int` 用は作らない）。`tests/test_encode_binary.mojo` **14/14 PASS**（DB 不要、両サーバーの枠で実行）。
  PLAN (f) の期待値 16 件すべて実測一致（int16 ±端 / int32 -1・MAX / int64 MIN・-1・42 / bool / float32 1.5・NaN・±inf / float64 -0.0・NaN・1.5 / 各長 1・2・4・8・4・8）✓
- (g) 検証コマンド:
  - `pixi run check` → **6/6 PASS**（`final_check: PASS`）。**作業木が未コミットのまま**成功（T1 の 1/6 段の効果）。所要 **59 s**（00:56:29 → 00:57:28）。
    3/6 段 `missing doc strings outside _ffi: 0`、6/6 段 `matched lines in build/final_check.log: 0`（`warning:` / `WARNING:` 両方 0 件）、
    54314 側に `tests/test_leak.mojo skipped (PQ_TEST_LEAK_SERVERS=1)` ✓
  - 全テストが両サーバーで PASS（0 failed）。`check` の 5/6 段が全 8 ファイル × 2 サーバー（leak は PG17 のみ）を網羅し、
    leak の PG14 側は別途回した `pixi run test` で **8/8 PASS**（`connect/query/close [4080, 4082 ×6, 4165, 4165]` = +85 の一段が出たが
    `TOLERANCE_PAGES = 256` 内。T1 (f) で 256 を維持した判断どおり）。内訳: test_connection 28 / test_decode_text 49 /
    test_encode_binary 14 / test_errors 7 / test_ffi 7 / test_leak 8 / test_loader_fail 1 / test_result 15 / test_smoke 4
  - `pixi run package`（`mojo precompile src/pq`）→ 出力なし = **警告ゼロ** ✓
  - docstring 診断: `mojo precompile --diagnose-missing-doc-strings src/pq | grep -v '/_ffi/' | grep -vE "'(__init__|__deinit__|__copyinit__|__moveinit__)'" | grep -c 'doc string'` → **0** ✓
- `pixi run fmt` → `22 files left unchanged`（新規 2 ファイルを含む 21 `.mojo` + `hello.mojo` = 22。サブエージェントの手整形で差分ゼロ）✓

#### 追従先チェックリストの照合（T2 該当行）

| 行 | 確かめ方 | 結果 |
|---|---|---|
| libpq 関数のバインディングを足す | 上記 (a) の 3 コマンド | 53 / 53 / 0 ✓ |
| `PgErrorKind` を足す | 上記 (b) の 3 コマンド | 0 件 / 3 / PQTRANS の 1 件だけ ✓ |
| テストファイルを足す | `pixi run test` のログに新ファイル名が 2 回出る | `== 127.0.0.1:54317 tests/test_encode_binary.mojo` と `== 127.0.0.1:54314 tests/test_encode_binary.mojo` の 2 回 ✓ |
| libpq を呼ぶ新しい経路を足す | `grep -rn 'PQfreemem(' src/pq/*.mojo` = 2 行 / `PQexec(` | `PQfreemem` → `connection.mojo:385, 427`（escape_literal / escape_identifier）の **2 行** ✓。`PQexec(` は `connection.mojo:254` の **1 行**（T7 時点で 4 行になる予定。T3〜T5 で +3） |

- 未該当（後続タスクの担当）: 公開 struct の再エクスポート（T3〜T5）/ `examples/` 追加（T7）/ `_reject_nul` の `execute(sql, params)` 追加（T3）/ leak 12 本（T6）
