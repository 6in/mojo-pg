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

## turn 5 — impl — T3 params（`Param` / `_ParamBuffers` / `execute(sql, params)` / test_params 31 本）

- やったこと: サブエージェント 3 本（A: `src/pq/params.mojo` / B: `Connection.execute(sql, params)` +
  `__init__.mojo` の再エクスポート / C: `tests/test_params.mojo` を仕様リストから独立に 31 本）を対象ファイル
  非重複で並行実装。親で統合 → 空 `bytea` の非 NULL 補強 1 箇所 → `fmt` 1 回 → `package` → docstring 診断 →
  `test`（両サーバー）→ `check`。完了基準 (a)〜(d) をすべて満たしてコミット（0a4d0fd）
- 想定外: **(1) 空 `bytea` パラメータが黙って SQL NULL になり得る経路**があった。libpq は `values[i]` が
  NULL なら `lengths[i]` が 0 でも SQL NULL と解釈するので、空 `List[UInt8]` の `unsafe_ptr()` が NULL を
  返す stdlib なら `[]` が NULL に化ける（今の stdlib では非 NULL が返るので**テストは緑のまま通ってしまう**
  = 発覚しない種類のバグ）。決めた事項 5 の末尾ダミーと同じ趣旨でバイナリ用バッファを `capacity=len+1`
  にして塞いだ（PLAN 補強に記載。送るバイト列と `lengths` は変えていない）。サブエージェント A が
  「契約外の提案」として報告してきたもので、契約の文面には無いが**決めた事項 5 の非 NULL 保証の意図の範囲内**
  と判断して親が適用した。
  (2) `String.as_bytes()` は `Span[UInt8, origin]` を返すので `List[UInt8]` を取るヘルパには渡せない
  （1 バイトずつコピーする `_text_bytes` が必要）。(3) `def main() raises PgError:` は通らない
  （`kgen.call` の pass manager エラー）。probe も既存テストと同じ `def main() raises:` にする。
  (4) `s += s` は aliasing エラー（`var more = s.copy(); s += more` で倍々にする）。
  (5) `StaticString` は `Param` に暗黙変換されない（契約は `String` / `StringLiteral` のみ）ので
  `comptime` のテキスト定数は `Param(String(X))` と書く必要がある
- やり直し: 0 回
- 次への注意: (1) **`Param` の `@implicit` 19 本で曖昧さは出なかった**（PLAN「未プローブ」の最大の懸念が解消。
  `Param.of[T]()` へのフォールバックは不要だった）。T4 / T5 で `List[Param]` を受ける新しい経路を足すときも
  同じ 19 本をそのまま使える。
  (2) `_ParamBuffers` は `count()` / `types_ptr()` / `values_ptr()` / `lengths_ptr()` / `formats_ptr()` で
  確定。`PreparedStatement.execute`（T4）は `types_ptr()` を使わない（`PQexecPrepared` に types 引数が無い）。
  **`_ = buffers^` を libpq 呼び出しの後に置くことを忘れない**（`connection.mojo:330-348` が雛形）。
  (3) `Param` の構築は **raises を要求しない**（`encode_*` が非 raising に推論される）。`_ParamBuffers(...)` だけが
  `raises PgError`。T4 / T5 のシグネチャ設計に関係する。
  (4) テストの所要が伸びている（test_params は PG17 117 s / PG14 142 s）。**ほぼ全部が `Connection.open` の
  ~3.6〜4.0 s/回**で、DB を触るテスト 1 本ごとに固定で乗る（Phase 1 から共通で、この回に増えた性質ではない）。
  T4 / T5 でテストを 18 ケース以上足すと `pixi run test` がさらに +4〜6 分になる見込み。
  **1 テスト 1 接続をやめて接続を共有する案は REQ に無いので勝手にやらない**が、T7 で所要を書くときに
  verify への申し送り候補として挙げる。
  (5) C が挙げた「仕様との食い違い」は**ゼロ**。PLAN (c) の期待値（OID 25 推論 / `08P01` / `42601` /
  `22003` / `Int(5)` 成功 / `25P02` / NUL の非対称 / -0.0 のビット保存）が PG14・PG17 とも全部そのまま通った

### T3 完了基準の実測

- (a) `src/pq/params.mojo`: `Param` の `@implicit` デコレータ **ちょうど 19 本**（非 Optional 10 +
  `Optional[T]` 9。`grep -c '@implicit' src/pq/params.mojo` → 19）。`Param.null()` / `Param.null(oid)`、
  公開アクセサは `oid()` / `is_null()` / `is_binary()` の 3 本だけ（値を返すアクセサ無し）。
  OID 定数は `from pq.decode_text import OID_BOOL, OID_BYTEA, OID_INT8, OID_INT2, OID_INT4, OID_FLOAT4, OID_FLOAT8`。
  `_ParamBuffers` は `lengths` / `formats` が `List[c_int]`、`values` は `bufs` を全部作り終えてから取得、
  types / values / lengths / formats の 4 本すべてに末尾ダミー 1 要素。
  String パラメータの NUL は `USAGE` / `embedded NUL byte in parameter $N`（N は 1 始まり、値は非表示）✓
  - A の probe 実測: リスト literal `[1, "a", 1.5, True, Param.null()]` → OID **20 / 0 / 701 / 16 / 0**；
    `Optional[T]` の None 側 9 本 → OID `16, 21, 23, 20, 20, 700, 701, 0, 17` が全部 `null=True`；
    空 `List[Param]()` → `count() = 0` で 4 本のポインタすべて非 NULL（末尾ダミーの効果）
- (b) `src/pq/connection.mojo`: `execute(self, var sql: String, params: List[Param]) raises PgError -> Result` を
  `connection.mojo:330` 以降に追加。本体は `_reject_nul` → `_ParamBuffers(params)` → `PQexecParams`
  （`resultFormat` は定数 `c_int(0)`）→ `_ = buffers^` → `_ = sql^` → `return self._take_result(res)`。
  **`git diff -U0 src/pq/connection.mojo | grep '^-'` が差分ヘッダ 1 行だけ = 既存 `execute(sql)` /
  `_take_result` / `escape_*` に削除行ゼロ**（挙動変更なし）。`tests/test_connection.mojo` は無変更で 28/28 PASS ✓
  docstring に単一文制約（`42601`）/ `$1`〜`$n` / 送信形式の表 9 行 / String の OID 0 推論 /
  `Int` の assignment cast と `22003` / 個数不一致 `08P01` / `result_format` テキスト固定を記載 ✓
- (c) `tests/test_params.mojo` **31 本**（`grep -c '^def test_' tests/test_params.mojo` → 31）。
  PLAN (c)-1〜12 の対応: 12 → 4 本（DB 不要）/ 1 → 1 / 2 → 1 / 3 → 8 / 4 → 6 / 5 → 3 / 6 → 1 / 7 → 1 /
  8 → 2 / 9 → 2 / 10 → 1 / 11 → 1。**両サーバーで 31/31 PASS**（PG17 117.7 s / PG14 142.3 s）✓
  - 仕様値どおりに実測一致した要所: 未指定 NULL と未指定テキストの OID 25 推論、`SELECT $1 + 1` に `"7"` → `8`、
    個数不一致 `08P01`（直後の `execute("SELECT 1")` が通り `status() == CONNECTION_OK`）、
    空 params でも `SELECT 1; SELECT 2` が `42601`・`SELECT 1;` は成功、`Int(3000000000)` → `22003`、
    `Int(5)` は assignment cast で**成功**、aborted tx 内で `25P02`、
    NUL の非対称（パラメータ値 → `USAGE` / `embedded NUL byte in parameter $N` / `sqlstate` 空 / 直後の
    `execute` が通る、`sql` → `TYPE_MISMATCH` / `embedded NUL byte in sql`）、
    `-0.0` の符号保存（`== 0.0` では区別できないので float32 は `0x80000000`、float64 は
    `0x8000000000000000` のビットで判定）、64 KiB の text と bytea を同じ文で（2 個目のバイナリ長がずれない）
- (d) 検証コマンド:
  - `/home/parallels/.pixi/bin/pixi run test` → **両サーバー全ファイル PASS（0 failed）**。内訳（各サーバー同数）:
    test_connection 28 / test_decode_text 49 / test_encode_binary 14 / test_errors 7 / test_ffi 7 /
    test_leak 8 / test_loader_fail 1 / **test_params 31** / test_result 15 / test_smoke 4。
    leak の RSS 系列は両サーバーとも平坦（PG17 `failed-open [4549 ×4]` / `failed-execute [4574 ×4]`、
    PG14 `[4463 ×4]` / `[4571 ×4]`）。所要は leak が支配的（PG17 48.7 s / PG14 45.4 s）
  - `/home/parallels/.pixi/bin/pixi run check` → **6/6 PASS**（`final_check: PASS`）。**作業木が未コミットのまま**成功。
    所要 **66 s**（01:16:30 → 01:17:36）。3/6 段 `missing doc strings outside _ffi: 0`、
    6/6 段 `matched lines in build/final_check.log: 0`（`warning:` / `WARNING:` 両方 0 件 = サーバー WARNING も無し）
  - `/home/parallels/.pixi/bin/pixi run package`（`mojo precompile src/pq`）→ 出力なし = **警告ゼロ** ✓
  - docstring 診断: `mojo precompile --diagnose-missing-doc-strings src/pq | grep -v '/_ffi/' | grep -vE "'(__init__|__deinit__|__copyinit__|__moveinit__)'" | grep -c 'doc string'` → **0** ✓
  - `/home/parallels/.pixi/bin/pixi run fmt` → `reformatted tests/test_params.mojo` / `1 file reformatted, 23 files left unchanged`
    （親が統合後に 1 回だけ実行。整形は `check` の 1/6 段より前に済ませたので作業木のまま 1/6 段が通る）

#### 追従先チェックリストの照合（T3 該当行）

| 行 | 確かめ方 | 結果 |
|---|---|---|
| 公開 struct を足す（`Param`） | `grep -nE 'Param\|PreparedStatement\|Transaction' src/pq/__init__.mojo` | `__init__.mojo:7`（モジュール docstring の再エクスポート列挙に `Param` を 1 行）と `:64`（`from .params import Param`）の 2 件 ✓（`PreparedStatement` / `Transaction` は T4 / T5） |
| 公開 struct を足す（docstring 診断） | `mojo precompile --diagnose-missing-doc-strings ...` の 'doc string' 件数 | **0** ✓ |
| 埋め込み NUL の経路を足す | `grep -rn '_reject_nul' src/pq` に `execute(sql, params)` が追加されている | `connection.mojo:330` が新しい `execute(sql, params)` の `_reject_nul(sql, "sql")`（既存は `:158` conninfo / `:191-192` params key・value / `:256` `execute(sql)` / `:452` `:494` escape 系）✓ |
| テストファイルを足す | `pixi run test` のログに新ファイル名が 2 回出る | `== 127.0.0.1:54317 tests/test_params.mojo` と `== 127.0.0.1:54314 tests/test_params.mojo` の 2 回 ✓ |
| libpq を呼ぶ新しい経路を足す | `grep -rn 'PQfreemem(' src/pq/*.mojo` = 2 行 | `connection.mojo:470, 512`（escape_literal / escape_identifier）の **2 行**のまま ✓。`PQexec(` も `connection.mojo:254` の **1 行**のまま（T3 が足したのは `PQexecParams` なので増えない。T7 時点で 4 行の見込みは T4 / T5 の担当） |
| libpq を呼ぶ新しい経路を足す（`get_function` 禁止） | `grep -rc get_function src/pq` 全 0 | 0 件（マッチするファイルなし）✓ |

- 未該当（後続タスクの担当）: `PreparedStatement` / `Transaction` の再エクスポート（T4 / T5）/
  `examples/` 追加（T7）/ leak 12 本（T6）/ `PgErrorKind` 追加（T2 で完了）

## turn 6 — impl — T4 prepared（`PreparedStatement[origin]` / `Connection.prepare` / test_prepared 13 本）

- やったこと: サブエージェント 2 本（A: `src/pq/prepared.mojo` + `Connection.prepare` / `_stmt_counter` /
  `_next_stmt_name` + `__init__.mojo` の再エクスポート / B: `tests/test_prepared.mojo` を仕様リスト 1〜12 から
  独立に 13 本）を対象ファイル非重複で並行実装。親で統合 → B が報告した PLAN との食い違いを自前のプローブで
  確認 → PLAN 訂正 → `fmt` 1 回 → `package` → docstring 診断 → `test`（両サーバー）→ `check`。
  完了基準 (a)〜(c) をすべて満たしてコミット（890e76e）
- 想定外: **(1) PLAN T4 (b)-1 の `execute([1, 2, "x"])` が通らない**（下の PLAN 訂正）。リスト literal の
  `1` は `Param(Int)` = OID 20 の 8 byte バイナリで、`PQexecPrepared` には `paramTypes` 引数が無く
  パラメータ型は `PQprepare` 時点で int4 に確定しているため、サーバーが 8 byte を int4 として読んで
  `22P03 incorrect binary data format in bind parameter 1` になる。**`execute(sql, params)`（`PQexecParams`）
  との非対称**で、あちらは OID 20 を同送するので assignment cast が効き `Int(5)` が int4 列に入る（T3 (c)-6）。
  サブエージェント B が「仕様が実物と合わない」として報告してきたので、鵜呑みにせず親が
  `scratch/turn-006-probe-int8-int4.mojo` で両形を実測して確認した（出力は下記）。
  (2) **T3 の申し送り (4) の所要の数値は誤り**（`Summary [ N ]` の N は**ミリ秒**で、秒ではない）。
  実測: `mojo run -I src tests/test_prepared.mojo` の `real` が **1.1 s**（13 テスト、内 100 回の
  prepare ループ込み。`Summary [ 109.666 ]` = 109 ms）。したがって「`Connection.open` が ~3.6〜4.0 s/回」
  「test_params が 117 s / 142 s」も ms の読み違いで、正しくは ~4 ms/回・~100 ms/ファイル。
  **テストの所要が伸びているという T3 の懸念は成立しない**（`pixi run test` の所要は `test_leak` の
  41 s × 2 サーバーとファイルごとの mojo コンパイル 1〜4 s が支配的で、DB 往復はほぼ無視できる）。
  T7 で所要を書くときも verify への「接続を共有する案」の申し送りは不要。
  (3) `self._conn[]._pq[].PQexec(...)` は `mojo format` が `._pq[]` を括弧で包む形に崩すので、
  A が `var pq = self._conn[]._pq` を挟んで format 安定にした（`prepared.mojo:112, 175`）
- やり直し: 0 回
- 次への注意: (1) **PLAN「未プローブ」の 3 項目が全部解消**: `param_types: List[UInt32] = List[UInt32]()`
  の既定引数は**通る**（2 オーバーロードへの分割は不要）、`-> PreparedStatement[origin_of(self)]` +
  `Pointer(to=self)` は `ref self` で**通る**、`connection.mojo` ↔ `prepared.mojo` の循環 import も
  **通る**（どちらも絶対形 `from pq.xxx import`）。T5 の `transaction.mojo` を同じ循環に足すのも同型。
  (2) **T5 の `Transaction.prepare` は `self._conn[].prepare(sql^, param_types)` に委譲して
  `PreparedStatement[Self.origin]` を返せる**見込み（どちらも同じ不変 `Connection` 借用由来で origin が一致。
  PLAN「未プローブ」の懸念はこれで小さいが、実際に通すのは T5）。
  (3) **T5 は `Connection` の `__init__` と フィールド宣言ブロックを触る**（`_rollback_failure_handler` の追加）。
  T4 が同じ場所に `_stmt_counter` を足したので、フィールド宣言は `connection.mojo:78-91`、
  `__init__` 本体は `:96-108` にマージすること。
  (4) `prepare` の **describe 失敗時の DEALLOCATE 経路（`connection.mojo:467-483`）は未実行のまま**。
  `PQprepare` 成功直後に `PQdescribePrepared` が失敗する状況（2 往復の間に接続が落ちる）を作れないため、
  仕様どおり書いてコンパイルは通っているがテストが通っていない。verify への申し送り。
  (5) T4 が足した生の `PQexec` は 2 箇所（`connection.mojo:476` の describe 失敗時 DEALLOCATE と
  `prepared.mojo:114` の `__deinit__`）。追従先チェックリストの `PQexec(` は現在 **3 行**で、
  T5 の `Transaction.__deinit__` が 4 行目になる見込み（PLAN の「4 行」と一致）

### T4 完了基準の実測

- (a) `src/pq/prepared.mojo`（245 行）: `struct PreparedStatement[origin: ImmOrigin](Movable)` で
  **`Copyable` にしていない**（`__deinit__` の DEALLOCATE 二重送信を型で防ぐ）。フィールドは
  `_conn: Pointer[Connection, Self.origin]` / `_name: String` / `_param_types: List[UInt32]` の 3 本だけ。
  `Connection.prepare(ref self, var sql: String, param_types: List[UInt32] = List[UInt32]()) raises PgError
  -> PreparedStatement[origin_of(self)]` が `connection.mojo:384`、`_next_stmt_name` が `:357`、
  `var _stmt_counter: List[Int]` が `:86`（`__init__` で `[0]`）。`src/pq/__init__.mojo:66` に
  `from .prepared import PreparedStatement`、docstring の再エクスポート列挙（`:7-9`）にも追加 ✓
  - 決めた事項 9 の手順どおり: `_reject_nul` → `_next_stmt_name` → `PQprepare`（hints は
    `capacity=len+1` の末尾ダミー付き `List[UInt32]`）→ `_take_result`（失敗はそのまま raise。
    この時点でサーバーに文は無い）→ `PQdescribePrepared` → `_take_result` が失敗したら
    **生の `PQexec` で `DEALLOCATE` を試み `PQclear` して結果を捨て、元のエラーを `raise e^`** →
    `PQnparams` / `PQparamtype` を `List[UInt32]` に読む → `desc` は `Result` なので自動 `PQclear`
  - `execute` は **個数検査（USAGE、サーバーに送らない）→ `_ParamBuffers`（NUL は USAGE）→
    `PQexecPrepared`（`types_ptr()` は渡さない）→ `_ = buffers^` → `_take_result`** の順 ✓
  - `__deinit__` は `DEALLOCATE <name>` を生の `PQexec` で送り、非 NULL なら `PQclear`。
    **結果も接続状態も見ず、raise もハンドラ呼び出しもしない** ✓
- (b) `tests/test_prepared.mojo` **13 本**（`grep -c '^def test_' tests/test_prepared.mojo` → 13）。
  PLAN (b)-1〜12 の対応: 1 → 2 本（`test_prepare_describes_and_executes` /
  `test_statement_numbering_is_per_connection`）/ 2 → 1 / 3 → 1 / 4 → 1 / 5 → 1 / 6 → 1 / 7 → 1 /
  8 → 1 / 9 → 1 / 10 → 1 / 11 → 1 / 12 → 1。**両サーバーで 13/13 PASS** ✓
  - 仕様どおり実測一致した要所: `pq_stmt_1` → `pq_stmt_2` の連番と**別接続で `pq_stmt_1` に戻る**、
    `param_type_oid(0..2) == 23 / 23 / 25`、範囲外が `TYPE_MISMATCH`
    `parameter index 3 out of range (0..2)`、個数不一致が `USAGE` / `sqlstate` 空で
    **`BEGIN` 中でも `PQTRANS_INTRANS` のまま**（08P01 が届いていない証拠）、
    `pg_prepared_statements` の count が生存中 1 → `_ = stmt^` の後 0、手動 `DEALLOCATE` 後の
    `execute` が `SERVER` / `26000` で破棄は静か、**`BEGIN` → `prepare` → `ROLLBACK` → `execute` が成功**
    （PLAN 14-1 の PREPARE 非トランザクショナル）、aborted tx 内の破棄では DEALLOCATE が 25P02 で
    無視され**文がサーバーに残る（count 1。決めた事項 22）**、`prepare("SELEC 1")` / `prepare("SELECT 1; SELECT 2")`
    が `42601`、`param_types=[20]` の明示と `[23]` + `Param.null()`、`prepare("SELECT $1")` の text 推論、
    NUL が `USAGE`、100 回ループ後に count 0、接続断後の `execute` が `CONNECTION`
  - B が仕様から解釈を選んだ点（親が確認して妥当と判断）: `param_type_oid(-1)` は `TYPE_MISMATCH` と
    `"out of range"` の部分一致だけを固定（文言は index 3 の分だけ PLAN が決めている）；
    (b)-7 の「失敗した prepare が番号を消費するか」は PLAN に無いので assert していない
    （実装は消費する。A のプローブで `pq_stmt_4` を確認済み）；(b)-12 の `pg_terminate_backend` 自体の
    kind / sqlstate は固定せず raise することだけを固定
- (c) 検証コマンド:
  - `/home/parallels/.pixi/bin/pixi run test` → **両サーバー全ファイル PASS（0 failed、exit 0）**。内訳（各サーバー同数）:
    test_connection 28 / test_decode_text 49 / test_encode_binary 14 / test_errors 7 / test_ffi 7 /
    test_leak 8 / test_loader_fail 1 / test_params 31 / **test_prepared 13** / test_result 15 / test_smoke 4。
    leak の RSS 系列は両サーバーとも完全に平坦（PG14 `failed-open [4467 ×4]` / `failed-execute [4576 ×4]`）。
    ログに `warning:` / `WARNING:` は **0 件**
  - `/home/parallels/.pixi/bin/pixi run check` → **6/6 PASS**（`final_check: PASS`）。**作業木が未コミットのまま**成功。
    所要 **61 s**（01:35:06 → 01:36:07）。3/6 段 `missing doc strings outside _ffi: 0`、
    5/6 段で `-- 127.0.0.1:54314 tests/test_leak.mojo skipped (PQ_TEST_LEAK_SERVERS=1)`、
    6/6 段 `matched lines in build/final_check.log: 0`
  - `/home/parallels/.pixi/bin/pixi run package` → 出力はタスク見出し行のみ = **警告ゼロ** ✓
  - docstring 診断 → **0** ✓
  - `/home/parallels/.pixi/bin/pixi run fmt` → `reformatted tests/test_prepared.mojo` /
    `1 file reformatted, 25 files left unchanged`（親が統合後に 1 回だけ。`check` の 1/6 段より前に実施）

### PLAN 訂正の実測（`scratch/turn-006-probe-int8-int4.mojo`）

```
name: pq_stmt_1 param_count: 3
oids: 23 23 25
Int form oids: 20 20
Int form: kind = Server  sqlstate = 22P03
Int form: message = incorrect binary data format in bind parameter 1
Int32 form: OK sum = 3
```

`prepare("SELECT $1::int4 + $2::int4, $3")` に対し `[1, 2, "x"]`（`Param(Int)` = OID 20 / 8 byte）は
`22P03` で失敗し、`[Int32(1), Int32(2), "x"]`（OID 23 / 4 byte）は成功して 3 を返す。
PLAN T4 (b)-1 の期待値を後者に訂正した（要件・決定に反しない: 決めた事項 9 は
「`execute` は個数だけ検査し型強制はしない」と定めており、型の整合は呼び出し側の責任）。

#### 追従先チェックリストの照合（T4 該当行）

| 行 | 確かめ方 | 結果 |
|---|---|---|
| 公開 struct を足す（`PreparedStatement`） | `grep -nE 'Param\|PreparedStatement\|Transaction' src/pq/__init__.mojo` | `:7-8`（docstring の再エクスポート列挙に `Param` と `PreparedStatement`）/ `:65` `from .params import Param` / `:66` `from .prepared import PreparedStatement` の 4 件 ✓（`Transaction` は T5） |
| 公開 struct を足す（docstring 診断） | `mojo precompile --diagnose-missing-doc-strings ...` の 'doc string' 件数 | **0** ✓ |
| libpq を呼ぶ新しい経路を足す | `grep -rn 'PQexec(' src/pq/*.mojo` | **3 行**（`connection.mojo:268` `execute(sql)` / `connection.mojo:476` describe 失敗時の DEALLOCATE / `prepared.mojo:114` `__deinit__`）。PLAN の「4 行（connection ×2 / transaction / prepared）」と整合し、残り 1 行は T5 の `Transaction.__deinit__` ✓ |
| libpq を呼ぶ新しい経路を足す（`PQfreemem`） | `grep -rn 'PQfreemem(' src/pq/*.mojo` = 2 行 | `connection.mojo:617, 659`（escape_literal / escape_identifier）の **2 行**のまま ✓ |
| libpq を呼ぶ新しい経路を足す（`get_function` 禁止） | `grep -rc get_function src/pq` 全 0 | 0 件 ✓ |
| テストファイルを足す | `pixi run test` のログに新ファイル名が 2 回出る | `grep -c '== 127.0.0.1:5431[47] tests/test_prepared.mojo'` → **2** ✓ |
| `__del__` を書かない（決めた事項 14-4） | `grep -rn '__del__' src/pq tests examples` | 0 件 ✓ |
| `fn` を使わない | `grep -rnE '^[[:space:]]*fn ' src tests examples hello.mojo` | 0 件 ✓ |

- 未該当（後続タスクの担当）: `Transaction` の再エクスポート（T5）/ `examples/` 追加（T7）/ leak 12 本（T6）

## turn 7 — impl — T5 transaction（`Transaction[origin]` / `Connection.transaction` / test_transaction 13 + test_savepoint 7）

- やったこと: サブエージェント 3 本（A: `src/pq/transaction.mojo` + `Connection.transaction` /
  `set_rollback_failure_handler` + `__init__.mojo` / B: `tests/test_transaction.mojo` を (b) 1〜12 から
  独立に 13 本 / C: `tests/test_savepoint.mojo` を (c) 1〜6 から独立に 7 本）を対象ファイル非重複で並行実装。
  親で統合 → `fmt` 1 回 → `package` → docstring 診断 → `test`（両サーバー）→ `check` 6/6 →
  追従先チェックリスト照合 → コミット（8546642）。完了基準 (a)〜(d) をすべて満たした
- 想定外: **(1) `Transaction.prepare` を委譲で書けない**（PLAN 訂正に詳述）。`self._conn[].prepare(...)` の戻りは
  `PreparedStatement[origin_of(origin)]` の入れ子 origin になり、署名側の `PreparedStatement[Self.origin]` /
  `[origin_of(self._conn[])]` はどちらも `[origin]` に畳まれる。struct の origin パラメータは不変なので変換不能で、
  PLAN「未プローブ」が用意していた代替（`rebind`）も `expression does not designate a value with an origin` で不可、
  `__disable_del` は Mojo 1.1.0 に存在しない。A は FFI を複製せず `Connection._prepare_parts`（不変 `self` で
  2 往復を行い名前を返す）に切り出し、2 つの `prepare` が各自の借用で `PreparedStatement` を構築する形にした。
  前ターン申し送り (2) の「委譲で返せる見込み」は**外れ**（同じ `Connection` 借用由来でも deref を挟むと origin が入れ子になる）。
  (2) **`std.os.setenv` は Mojo 1.1.0 で raise しない**（`Bool` を返す）。B が依頼文どおり `try/except` で包んだら
  `try body doesn't raise an exception` 警告が 3 件出たため `try` を外した（警告ゼロ要件と両立しない）。
  PLAN 決めた事項 12 の「`setenv` 等を `try/except` で包む」は不要。
  (3) B / C はどちらも「`Connection.transaction()` がまだ無い」状態で終わったが、C は `src/pq` のコピーに
  スタブを当てて自力で型検査まで済ませており（7 本 0 警告）、統合後の修正は**ゼロ**だった
- やり直し: 0 回
- 次への注意: (1) **T6 が参照する `__deinit__` の ROLLBACK 経路は `transaction.mojo:150-214`**（生 `PQexec` +
  `PQclear`）。陽性対照 ③（ROLLBACK 結果の `PQclear` を消す）は `:182` と `:199` の 2 箇所のうち
  **`:199`（失敗時）ではなく `:182`（COMMAND_OK 時）**を消すのが正しい（正常系の 10,000 回ループで効く）。
  (2) `_prepare_parts` の切り出しで `prepare` の FFI は 1 箇所に集約されたので、T6 の prepared ループが
  `PQclear` 漏れを見る対象も 1 箇所（`connection.mojo:_prepare_parts` の describe 結果は `Result` が解放）。
  (3) **T7 (c) の docstring 照合は T5 の時点で済んでいる**: `grep -c 'conn.execute(b)' src/pq/transaction.mojo` → 1、
  `copied when` + `transaction()` が `set_rollback_failure_handler` の docstring に、`commit()` に
  `ROLLBACK` command tag の説明あり。残りは `PreparedStatement` の「tx 内 DDL 巻き戻し後」の 1 項目。
  (4) `grep -c 'implicit ROLLBACK failed' build/final_check.log` は**この turn の check で既に 0**（T5 (b)-12 の
  機械的な裏付け。T7 で再掲するだけでよい）。
  (5) B / C の「契約外の提案」で verify が拾ってよいもの: `savepoint("Sp")` のあと `rollback_to("sp")` が
  `3B001` になる（クォート済み識別子と畳まれた名前は別物）という**エスケープの本質を突く 1 件**は未テスト。
  savepoint のネスト（`a` → `b` → `rollback_to("a")` が `b` を捨てる）と同名の二重 `savepoint`（PostgreSQL は
  シャドウする）も未テスト。いずれも PLAN の 6 項目外なので入れていない

### T5 完了基準の実測

- (a) `src/pq/transaction.mojo`（457 行、`fmt` 後）: `struct Transaction[origin: ImmOrigin](Movable)` で
  `Copyable` にしていない。フィールドは `_conn: Pointer[Connection, Self.origin]` / `_done: Bool` /
  `_handler: def(PgError) thin` の 3 本だけ ✓。`Connection` 側は `var _rollback_failure_handler: def(PgError) thin`
  が `connection.mojo:95`（`__init__` で `_default_rollback_failure_handler` を代入）、
  `transaction(ref self) raises PgError -> Transaction[origin_of(self)]` が `:742`、
  `set_rollback_failure_handler(mut self, handler: def(PgError) thin)` が `:802`、
  `_prepare_parts` が `:457`。`src/pq/__init__.mojo:68` に `from .transaction import Transaction` ✓
  - 決めた事項 10 の順序どおり: `transaction()` は ① `PQstatus == CONNECTION_BAD` → `CONNECTION`
    （`PQerrorMessage`）→ ② `PQtransactionStatus != PQTRANS_IDLE` → `USAGE`
    `transaction() requires an idle connection (transaction status N)` → ③ `BEGIN` → 構築（ハンドラをコピー）✓
  - `commit()` は `_check_open()` → **`_done = True` を送信前** → `COMMIT` → `command_tag() == "ROLLBACK"` なら
    `SERVER` / `sqlstate=""` / `COMMIT resulted in ROLLBACK: the transaction was aborted` ✓
  - savepoint 3 本は `_check_open()` → 空文字 `USAGE` `savepoint name must not be empty` →
    `escape_identifier` → `SAVEPOINT` / `ROLLBACK TO SAVEPOINT` / `RELEASE SAVEPOINT`。command tag は見ない ✓
  - `__deinit__` は `_done` なら無動作、そうでなければ生 `PQexec("ROLLBACK")` → NULL なら `CONNECTION`、
    非 `PGRES_COMMAND_OK` なら診断 7 項目を `_error_field` でコピー → `PQclear` → sqlstate 空 かつ
    `CONNECTION_BAD` なら `CONNECTION`、それ以外 `SERVER` → `self._handler(err)`。**raise しない** ✓
    （`_take_result` との差は `message` が空のときの `unexpected result status N` フォールバックが無い点だけ）
- (b) `tests/test_transaction.mojo` **13 本**（PLAN (b) 1〜12 → 1:1、項目 2 だけ 2 本に分割）。**両サーバー 13/13 PASS** ✓
  - 仕様どおり実測一致した要所: `commit` 後の count 1 と二重 `commit` の `USAGE`、`rollback` の count 0、
    `_ = tx^` での暗黙 ROLLBACK と `PQTRANS_IDLE`、**ASAP 破棄（次の行の `conn.execute` が既に tx 外）**、
    `tx.execute(sql, params)` / `tx.prepare` の委譲（prepared は `Int32` で束縛）、ネスト禁止が
    `transaction status 2` / `3` の USAGE、終了後の 6 メソッド全部 USAGE、aborted からの `commit()` が
    `SERVER` / sqlstate 空 / message に `ROLLBACK`、**接続断中の破棄でハンドラが `Connection|...` を記録**、
    **ハンドラは生成時コピー（`first|Connection|...`。2 本目は呼ばれない）**、接続断後の `transaction()` が `CONNECTION`
  - B が仕様から解釈を選んだ点（親が妥当と判断）: USAGE 系は `sqlstate == ""` も assert（Phase 1 からの慣習）；
    ネストのメッセージは `PQTRANS_*` 定数から組み立てて「どの状態を断ったか」を示す；
    項目 4 は `_tx_execute(tx, ...).affected_rows()` の連鎖で INSERT 行を tx の最終使用にしている
- (c) `tests/test_savepoint.mojo` **7 本**（PLAN (c) 1〜6 → 項目 4 のみ 2 本）。**両サーバー 7/7 PASS** ✓
  部分取り消しで count 1、`sp "1"` と `Sp` の往復、`22012` → `rollback_to` → `INTRANS` → `commit`、
  存在しない名前が `3B001` → `25P02` → `rollback()` で `IDLE`、空文字 3 本が `USAGE` で `INTRANS` のまま、
  `release` 後の `rollback_to` が `3B001`
- (d) 検証コマンド:
  - `/home/parallels/.pixi/bin/pixi run test` → **両サーバー全ファイル PASS（0 failed）**。内訳（各サーバー同数）:
    test_connection 28 / test_decode_text 49 / test_encode_binary 14 / test_errors 7 / test_ffi 7 /
    test_leak 8 / test_loader_fail 1 / test_params 31 / test_prepared 13 / test_result 15 /
    **test_savepoint 7** / test_smoke 4 / **test_transaction 13**。leak の RSS 系列は PG17
    `connect/query/close [4085, 4086, 4086, 4086, 4086, 4169, 4169, 4169, 4169]`（+84 の一段 1 回、
    tolerance 256 内）/ 他 3 系列は完全に平坦、PG14 は 4 系列すべて平坦。所要 **約 5 分**
  - `/home/parallels/.pixi/bin/pixi run check` → **6/6 PASS**（`final_check: PASS`）。作業木が未コミットのまま成功。
    所要 **65 s**（01:58:35 → 01:59:40）。3/6 段 `missing doc strings outside _ffi: 0`、
    5/6 段で `-- 127.0.0.1:54314 tests/test_leak.mojo skipped (PQ_TEST_LEAK_SERVERS=1)`、
    6/6 段 `matched lines in build/final_check.log: 0`（= `warning:` も libpq の `WARNING:` も 0 件 =
    ネスト BEGIN / 二重 COMMIT がサーバーに届いていない証拠）。test_leak は 1 サーバー 40 s
  - `/home/parallels/.pixi/bin/pixi run package` → 出力はタスク見出し行のみ = **警告ゼロ** ✓
  - docstring 診断 → `_ffi` と dunder を除いて **0 件** ✓
  - `/home/parallels/.pixi/bin/pixi run fmt` → `4 files reformatted, 25 files left unchanged`
    （`transaction.mojo` / `connection.mojo` / `test_transaction.mojo` / `test_savepoint.mojo`。親が統合後に 1 回だけ）

#### 追従先チェックリストの照合（T5 該当行）

| 行 | 確かめ方 | 結果 |
|---|---|---|
| 公開 struct を足す（`Transaction`） | `grep -nE 'Param\|PreparedStatement\|Transaction' src/pq/__init__.mojo` | `:7-8`（docstring の列挙に 3 型）/ `:65` `Param` / `:66` `PreparedStatement` / `:68` `from .transaction import Transaction` の 5 件 ✓ **3 型すべて揃った** |
| 公開 struct を足す（docstring 診断） | `mojo precompile --diagnose-missing-doc-strings ...` の 'doc string' 件数 | **0** ✓ |
| libpq を呼ぶ新しい経路を足す | `grep -rn 'PQexec(' src/pq/*.mojo` | **4 行**（`connection.mojo:279` `execute(sql)` / `connection.mojo:527` describe 失敗時 DEALLOCATE / `prepared.mojo:114` `__deinit__` / `transaction.mojo:167` `__deinit__`）= PLAN の「4 行（connection ×2 / transaction / prepared）」と一致 ✓ |
| libpq を呼ぶ新しい経路を足す（`PQfreemem`） | `grep -rn 'PQfreemem(' src/pq/*.mojo` = 2 行 | `connection.mojo:667, 709`（escape_literal / escape_identifier）の **2 行**のまま ✓（savepoint は `escape_identifier` 経由） |
| テストファイルを足す | `pixi run test` のログに新ファイル名が 2 回出る | `test_transaction.mojo` / `test_savepoint.mojo` とも `== 127.0.0.1:54317` と `== 127.0.0.1:54314` の **2 回** ✓ |
| `__del__` を書かない（決めた事項 14-4） | `grep -rn '__del__' src tests examples` | 0 件 ✓ |
| 既定ハンドラが黙っている（T5 (b)-12 / T7 (d)） | `grep -c 'implicit ROLLBACK failed' build/final_check.log` | **0** ✓ |

## turn 8 — impl — T6 `tests/test_leak.mojo` に Phase 2 の 4 ループ + 陽性対照 3 本

- やったこと: `tests/test_leak.mojo` に Phase 2 の 4 ループ（計 12 テスト）と Phase 2 API 用の
  ラッパ 6 本（`_execute_params` / `_prepare` / `_stmt_execute` / `_transaction` / `_tx_execute` /
  `_tx_commit`）と `_payload_bytes` を追加し、陽性対照 3 本を scratch の `src` コピー + `mojo build`
  で実測して 3 経路すべての検出力を示した。両サーバー PASS / `check` 6/6 / `package` 警告ゼロ。
- 想定外: PLAN の所要見積もり（`check` 2〜3 分）が過大だった（実測 82 s）。Phase 2 の 4 ループは
  接続を 1 本使い回すので 10,000 回でも計 18 s にしかならない。PLAN を訂正した（下記）。
- やり直し: 0 回
- 次への注意: 下記「次への注意」節

### (a) 4 ループ（各 10,000 回 / `MAIN_WARMUP` 1,000 / 9 サンプル / `TOLERANCE_PAGES` 256 / 接続 1 本）

| テスト | ラベル | 回す経路 | 1 回あたりの `PGresult` |
|---|---|---|---|
| `test_execute_params_does_not_leak` | `execute(sql, params)` | `conn.execute("SELECT $1::bytea, $2::text", [<64 KiB bytea>, <64 KiB text>])` | `_ParamBuffers`（送信側）+ `PGresult` 1 個。結果はテキスト形式なので bytea が hex で返り、往路より復路が太い |
| `test_prepared_does_not_leak` | `prepare/execute/drop` | `prepare("SELECT repeat('x', 65536) WHERE $1 = 1")` → `execute([Int32(1)])` → 結果と stmt を破棄 | 4 個（PQprepare / PQdescribePrepared / PQexecPrepared / `__deinit__` の DEALLOCATE）。4 個目だけが `Result` 経由でなく手で `PQclear` |
| `test_transaction_commit_does_not_leak` | `transaction/commit` | `conn.transaction()` → `tx.execute("SELECT repeat('x', 65536)")` → `tx.commit()` | 3 個（BEGIN / SELECT / COMMIT）。すべて `Connection.execute` 経由 = `Result` が所有 |
| `test_transaction_drop_does_not_leak` | `transaction/drop` | `conn.transaction()` → `tx.execute(...)` → `_ = tx^` | 3 個。3 個目（`__deinit__` の ROLLBACK）は raise できないので生 `PQexec` + 手動 `PQclear` |

- 接続を 1 本使い回すのは PLAN (a) どおり（connect ループは Phase 1 が持つ）。
  `_ = conn^` を各ループの最後に置いて `_assert_stable` より後まで生かしている
- `params` は `Param` リストをループ外で 1 回作って読み取り参照で渡す（`Connection.execute` の
  `params` は immutable 引数）。`_ParamBuffers` は `execute` の中で毎回作り直されるので
  測りたい経路は変わらない。Mojo 側の割り当てノイズだけがループから落ちる
- ASAP 破棄の規約（決めた事項 13）どおり、`tx` の最後の行を `_tx_commit(tx)` / `_ = tx^`、
  `stmt` の最後の行を `_ = stmt^` にしてコメントで理由を書いた

### (b) サンプル列（成功時も `print`。`_assert_stable` は Phase 1 と同じものを使用）

`pixi run test`（`PQ_TEST_LEAK_SERVERS` 未設定 = 両サーバー）の 8 系列:

```
== 127.0.0.1:54317
connect/query/close  [4092, 4093, 4093, 4093, 4093, 4093, 4093, 4093, 4093]
failed-open          [4556, 4556, 4556, 4556]
escape_literal       [4581, 4581, 4581, 4581]
failed-execute       [4581, 4581, 4581, 4581]
execute(sql, params) [4675, 4675, 4676, 4676, 4676, 4676, 4676, 4676, 4676]
prepare/execute/drop [4679, 4679, 4679, 4679, 4679, 4679, 4679, 4679, 4679]
transaction/commit   [4679, 4679, 4679, 4679, 4679, 4679, 4679, 4679, 4679]
transaction/drop     [4679, 4679, 4679, 4679, 4679, 4679, 4679, 4679, 4679]

== 127.0.0.1:54314
connect/query/close  [4092, 4093, 4093, 4176, 4176, 4176, 4176, 4176, 4176]   ← +83 の一段 1 回
failed-open          [4556, 4556, 4556, 4556]
escape_literal       [4581, 4581, 4581, 4581]
failed-execute       [4581, 4581, 4581, 4581]
execute(sql, params) [4679, 4679, 4679, 4679, 4679, 4679, 4679, 4679, 4695]   ← 末尾 +16
prepare/execute/drop [4695, 4695, 4695, 4695, 4695, 4695, 4695, 4695, 4695]
transaction/commit   [4695, 4695, 4695, 4695, 4695, 4695, 4695, 4695, 4695]
transaction/drop     [4695, 4695, 4695, 4695, 4695, 4695, 4695, 4695, 4695]
```

- Phase 2 の 4 系列の総増分は PG17 で 0〜1 ページ、PG14 で 0〜16 ページ。tolerance 256 に十分収まる。
  PG14 の params 系列の末尾 +16 と、connect 系列の +83 の一段（T1 で 256 を維持した理由そのもの）が
  この回も再現した。T1 の判断（16 に下げない）は正しかった
- `check`（`PQ_TEST_LEAK_SERVERS=1`、PG17 のみ）でも 4 系列とも 0〜16 ページで平坦
- モジュール docstring に 12 テストの一覧（4 unit + Phase 1 の 4 + Phase 2 の 4）と所要を書いた

### (c) 陽性対照 3 本（PG17。`scratch/turn-008-leaksrc-<name>/` に `src` をコピー → 1 行だけ壊して `mojo build -I <copy>`）

① `src/pq/result.mojo:99` の `self._pq[].PQclear(self._res)` を `pass` に
（`scratch/turn-008-leaksrc-result`、バイナリ `scratch/turn-008-test_leak_result`）:

```
FAIL test_execute_params_does_not_leak
  execute(sql, params) RSS pages: [203313, 252141, 300969]
  — grew 97656 pages past the first sample, over the 65536 allowed; aborting the loop (leaking)
FAIL test_connect_query_close_does_not_leak  [37747, 54589, 71431, 88273, 105113]  (+67366)
FAIL test_prepared_does_not_leak             [335744, 353178, 370612, 388045, 405479]  (+69735)
FAIL test_transaction_commit_does_not_leak   [439323, 456253, 473183, 490112, 507042]  (+67719)
FAIL test_transaction_drop_does_not_leak     [540792, 557667, 574542, 591417, 608292]  (+67500)
→ 12 tests run: 7 passed, 5 failed
```
`Result` は 4 ループすべての共通経路なので全部 FAIL する（PLAN が「connect ループも FAIL するが
問わない」とした範囲）。params ループは 3 サンプル目で `ABORT_PAGES` を超えて打ち切り = 約 1.2 GB で
止まる。1 サンプル間隔（1,000 回）あたり約 48,800 ページ ≈ 190 MB で、1 回の往復が
64 KiB の bytea（hex で約 128 KiB）+ 64 KiB の text を運ぶ計算と合う。

② `src/pq/prepared.mojo:120`（`__deinit__` の DEALLOCATE 結果の `PQclear`）を `pass` に
（`scratch/turn-008-leaksrc-prepared`、バイナリ `scratch/turn-008-test_leak_prepared`）:

```
FAIL test_prepared_does_not_leak
  AssertionError: prepare/execute/drop RSS pages:
  [4690, 4721, 4776, 4831, 4886, 4940, 4995, 5050, 5104]
他 11 テストは PASS（execute(sql, params) / transaction の 3 系列はすべて完全に平坦）
→ 12 tests run: 11 passed, 1 failed
```
総増分 414 ページ（約 1.7 MB、10,000 回で 1 個あたり約 170 B）。tolerance 256 を超え、かつ
9 サンプルすべてが単調増加なので `is_leaking` の 2 信号の両方が立つ。PLAN が懸念した
「数 MB では RSS に出ないかもしれない」は起きず、**ループだけを狙い撃ちできた**（他 3 系列が平坦な
ことが、この対照が prepared 経路だけを壊したことの裏付け）。payload を増やす必要はなかった。

③ `src/pq/transaction.mojo:182`（`__deinit__` の `PGRES_COMMAND_OK` 時の `PQclear`）を削除
（`scratch/turn-008-leaksrc-tx`、バイナリ `scratch/turn-008-test_leak_tx`）:

```
FAIL test_transaction_drop_does_not_leak
  AssertionError: transaction/drop RSS pages:
  [4642, 4674, 4728, 4783, 4838, 4892, 4947, 5002, 5056]
他 11 テストは PASS（transaction/commit は完全に平坦 = COMMIT 経路は別物）
→ 12 tests run: 11 passed, 1 failed
```
総増分 414 ページ（②と同じ規模）。**壊した 1 行は turn 7 の申し送り (1) どおり `:182`（COMMAND_OK 時）**で、
`:199`（失敗時）ではない。正常系の 10,000 回ループが通るのは COMMAND_OK 側だけなので、
この選択でなければ対照は FAIL しなかった。`transaction/commit` が平坦なまま残るのも想定どおり
（COMMIT の `PGresult` は `Connection.execute` 経由で `Result` が所有する）。

### (d) 検証コマンド

- `/home/parallels/.pixi/bin/pixi run db-up` → `tests-pg17-1` / `tests-pg14-1` とも Healthy
- `/home/parallels/.pixi/bin/pixi run test` → **両サーバー全ファイル PASS（exit 0）**。
  `Summary ... 0 failed` が 26 件（13 ファイル × 2 サーバー）、`N failed`（N ≥ 1）が 0 件。
  **test_leak は 12 tests run: 12 passed を両サーバーで記録**（`grep -c 'test_leak.mojo'` = 7 行 =
  `mojo build` 1 + 各サーバーの `==` / `--` 2 組 + 旧 skip 行なし）。
  **test_leak の所要: PG17 57 s / PG14 58 s**（T1 時点の 40 s から +17 s = Phase 2 の 4 ループ分）。
  内訳（PG17、TestSuite の表示）: connect 35.6 s / failed-open 3.5 s / escape_literal 0.18 s /
  failed-execute 0.51 s / **params 3.9 s / prepared 5.5 s / tx commit 4.4 s / tx drop 4.4 s**
- `/home/parallels/.pixi/bin/pixi run check` → **6/6 PASS**（`final_check: PASS`）。
  **所要 82 s**（02:15:36 → 02:16:58）。1/6 fmt 差分なし、3/6 `missing doc strings outside _ffi: 0`、
  5/6 で `-- 127.0.0.1:54314 tests/test_leak.mojo skipped (PQ_TEST_LEAK_SERVERS=1)`、
  6/6 `matched lines in build/final_check.log: 0`（`warning:` も libpq の `WARNING:` も 0 件）
- `/home/parallels/.pixi/bin/pixi run package` → 出力はタスク見出し行のみ = **警告ゼロ**
- `/home/parallels/.pixi/bin/pixi run fmt` → `1 file reformatted`（`test_leak.mojo`。親が統合後に 1 回だけ）。
  整形後に `check` を回して 1/6 段が PASS

### 追従先チェックリストの照合（T6 該当行）

| 行 | 確かめ方 | 結果 |
|---|---|---|
| リークループを足す（T6） | `grep -c '^def test_' tests/test_leak.mojo` = 12 | **12** ✓（4 unit + Phase 1 の 4 + Phase 2 の 4） |
| テストファイルを足す | 新規ファイルなし（既存ファイルへの追記のみ） | 該当なし。`run_tests.sh` の `test_leak` 特別扱いは変更していない ✓ |
| 既定ハンドラが黙っている | `grep -c 'implicit ROLLBACK failed' build/final_check.log` | **0** ✓（`transaction/drop` を 10,000 回回しても既定ハンドラが鳴らない = ROLLBACK がすべて成功している） |
| `fn` を書かない | `grep -rnE '^[[:space:]]*fn ' src tests examples hello.mojo \| wc -l` | **0** ✓ |

### PLAN 訂正

- `PLAN 訂正: 「所要の目安」の `check` 2〜3 分 → 82 s（test_leak 1 サーバー 57〜58 s）`
  （根拠: Phase 2 の 4 ループは接続を 1 本使い回すので 10,000 回でも計 18 s。
  `Connection.open` の ~3.5 ms/回が乗る Phase 1 の connect ループ 35 s がこの 1 ファイルの大半を
  占め続ける。T6 本文と「検証コマンド」節の両方を直した）

### 契約外の変更 1 件（報告）

- `tests/run_tests.sh:95` のコメント「`tests/test_leak.mojo` alone runs for ~40 s」を `~57 s` に更新した。
  追従先チェックリストに無い行だが、T6 がまさにこの数字を陳腐化させた変更なので直した。
  コメント 1 行のみで挙動は変えていない

### 次への注意

1. **T7 (d) の `grep -c 'implicit ROLLBACK failed' build/final_check.log` = 0 はこの turn の
   `check` で既に満たしている**（turn 7 の申し送り (4) の再掲 + `transaction/drop` 10,000 回という
   より強い裏付けが付いた）。T7 では再掲するだけでよい。
2. **T7 (a) の `examples/params.mojo` は `tx.commit()` を tx の最後の行に置く**（P1 の規約）。
   T6 の `transaction/commit` ループがまさにこの形で、`_assert_stable` より後に `_ = conn^` を
   置いている。`tx.rollback_to("sp")` → `tx.commit()` の順で書けば ASAP 破棄に引っかからない。
3. **T7 (c) で残っている docstring 照合は 1 項目だけ**: `PreparedStatement` docstring の
   「ROLLBACK しても文は残るが、tx 内 DDL の巻き戻し後の `execute` はサーバーエラーになり得る」
   （RESEARCH §3-8）。他の 5 項目は T5 までに済んでいる（turn 7 の申し送り (3)）。
4. **`check` は 82 s / `pixi run test` は 5〜6 分**。T7 は `check` を複数回回す可能性があるので、
   1 回 82 s + `examples/params.mojo` の追加で 4/6 段が 1 本増える分（`mojo run` で ~5 s）を見込む。
5. **陽性対照のバイナリと src コピーは `scratch/turn-008-*` に残してある**（`.gsd-lite/logs/` は
   gitignore 済み）。verify が検出力を再確認したいときはビルドし直さずそのまま実行できる。
   ただし①のバイナリは 5 テストが FAIL して約 2.4 GB まで RSS を伸ばすので、実行には注意。
6. **`pixi run test` の全体 wall clock はこの turn では計測していない**（ログへのリダイレクトで
   回したため）。計測した数字は `check` の 82 s と test_leak の 57 s / 58 s。T7 で全段の所要を
   書くときは `date -Iseconds` を前後で挟むこと。

## turn 9 — impl — T7 仕上げ（examples/params.mojo / `__init__` 文書 / 品質照合）

- やったこと: サブエージェント 2 本で A（`examples/params.mojo` + `pixi.toml` + `final_check.sh` 4/6）と
  B（`src/pq/__init__.mojo` の文書 + (c) の docstring 照合）を並行実装し、親が統合して `fmt` 1 回 →
  `check` 6/6 PASS（111 s）→ (d)/(e) の機械判定を全部回した。PLAN の全 7 タスクが完了。
- 想定外: (1) 前ターンの申し送り「(c) で残っているのは 4 番だけ」が**不正確で、2 番（`execute(sql, params)`
  の「single statement」）も欠けていた**（docstring が "Exactly one statement" で D13 の文言と一致せず）。
  依頼文に「鵜呑みにせず 6 項目すべて自分で grep して確かめる」と書いておいたので B が検出した。
  (2) `check` が 82 s → 111 s。example 2 本分（+4 s）と test_leak の +2 s では説明できない差で、
  同一コードでの実行ごとのばらつきと見る（PLAN 訂正に範囲で書いた）。
  (3) `fmt` が **30 files unchanged**（差分ゼロ）。両サブエージェントに「行幅を手で 80 桁に合わせる」と
  指示したのが効いて、統合時の整形差分が 1 件も出なかった。
- やり直し: 0 回
- 次への注意: 下記「次への注意」節

### (a) `examples/params.mojo`（101 行・新規）

- import は `from pq import Connection, Param, PgError` の **3 本だけ**。`Transaction` も
  `PreparedStatement` も名前として書いていない（`tx` は `conn.transaction()` の戻りのまま使う）。
  `Param` は `var kept: List[Param] = [Int32(2), "two"]` で型名として実際に使われているので未使用 import ではない
- 流れ: `_conninfo()`（`PQ_TEST_CONNINFO`、無ければ 54317）→ `CREATE TEMP TABLE pq_p2_example(id int4, label text)`
  → `conn.execute(INSERT, [Int32(1), "one"])` → `conn.execute("SELECT id, label ... WHERE id = $1", [Int32(1)])` を
  `for row in res` で表示 → `var tx = conn.transaction()` → `tx.execute(INSERT, kept)` → `tx.savepoint("sp")` →
  `tx.execute(INSERT, undone)` → `tx.rollback_to("sp")` → **`tx.commit()`（91 行目 = `tx` を使う最後の行）** →
  `_count(conn)`（93 行目、commit より後の `conn.execute`）で件数表示
- **P1 の ASAP 破棄の規約どおり**: `tx.commit()` が最後の `tx` 使用で、状態確認はその後。件数が
  `EXPECTED_ROWS`（2）と違えば `print` して `exit(1)`。`PgError` は `except e` で `print` + `exit(1)`
- 実行出力（`pixi run example-params`、exit 0・警告 0 行）:

```
id = 1
label = one
rows = 2
```

- `rows = 2` が savepoint の効果そのもの: conn 経由 1 行 + tx 経由 1 行で、`rollback_to("sp")` が
  2 本目の tx 内 insert（id=3）を巻き戻している
- **陽性対照**（A が実施）: `EXPECTED_ROWS` を一時的に 3 にして実行 → `expected 3 rows, got 2` を出して
  **exit 1**。件数判定が飾りでないことを実測で確認してから 2 に戻した
- **PG14 でも同一出力・exit 0**（`env PQ_TEST_CONNINFO="...port=54314..." pixi run mojo run -I src examples/params.mojo`）
- `pixi.toml:18` に `example-params = "mojo run -I src examples/params.mojo"`（`example-basic` の直下）
- `tests/final_check.sh` の 4/6 段（見出し `4/6 examples`）は basic と params を**別々の `run_logged` で**回し、
  `examples_failed` に畳んでから 1 回 `fail` する:

```sh
stage "4/6 examples"
examples_failed=0
run_logged mojo run -I src examples/basic.mojo || examples_failed=1
run_logged mojo run -I src examples/params.mojo || examples_failed=1
if [ "$examples_failed" -ne 0 ]; then
    fail "4/6 examples"
fi
```

  `|| fail` に直結しないのは、スクリプト冒頭の POLICY（`final_check.sh:4-11`「どの段も早期 exit しない —
  6/6 段が `$LOG` 全体を数えるので、途中で抜けると測る対象が黙って縮む」）に合わせたため。`set -e` は
  意図的に使われていないのでこの書き方で動く

### (b) `src/pq/__init__.mojo` の文書（+48 行、モジュール docstring のみ）

- 4 行目に「Phase 2 adds `params`, `prepared`, `transaction`.」
- 新 `## Parameters` 節: REQ §4.1 の送信形式表（列は **Mojo 型 / 送信形式 / OID / 備考**）と
  `conn.execute(sql, [1, "a", Param.null()])` の例。表は `src/pq/params.mojo` の 19 本の
  `@implicit __init__` に突き合わせて書いた（**REQ §4.1 と実装の食い違いなし**):
  `Bool` 16 / `Int16` 21 / `Int32` 23 / `Int64`・`Int` 20 / `Float32` 700 / `Float64` 701 はバイナリ、
  `String`・`StringLiteral` は **OID 0 のテキスト**（サーバーが推論）、`List[UInt8]` は **17 のバイナリ**
- NULL の段落は決めた事項 4 / 14-5 どおり: `Param.null()` と `Param.null(oid)`、`SELECT $1::int4` は `null(23)`、
  **素の `None` リテラルは変換されない**ので `Optional[Int](None)` / `var x: Optional[Int] = None` と書く
- 新 `## Transactions` 節: P1 の規約 1 段落（`Transaction[origin]` / `PreparedStatement[origin]` は
  **最後に使う行**の直後に破棄される → `commit()` / `rollback()` / `_ = tx^` / `_ = stmt^` を最後に置き、
  状態確認は**その後**の `conn.execute`。`_ = x^` は破棄ではなく「ここまで生かす」マーカー）
- `## PgErrorKind` に決めた事項 20 の非対称を追記: **`sql` の NUL は `TYPE_MISMATCH`、`String`
  パラメータ値の NUL は `USAGE`**。既存の `USAGE` 項目と「exactly six values」は T2 で入っていたので触っていない

### (c) docstring 照合（6 項目。実行した `grep` と出力）

| # | 項目 | コマンドと結果 |
|---|---|---|
| 1 | `Transaction` に「last use」/「ASAP」+ 負の例 | `grep -nE 'last use\|ASAP' src/pq/transaction.mojo` → 4 行（`:42` ASAP / `:101` ASAP / `:108` `tx.commit()  # last use` / `:114` `_ = tx.execute(a)  # last use of tx`）。`grep -c 'conn.execute(b)' src/pq/transaction.mojo` → **1** ✓ |
| 2 | `execute(sql, params)` に「single statement」（D13） | `grep -n 'single statement' src/pq/connection.mojo` → `296: Only a single statement is allowed, because ...` ✓ **（turn 9 で追記。それまで 0 件 — 下記「申し送りの訂正」）** |
| 3 | `set_rollback_failure_handler` に「copied when `transaction()`」（D9） | ``grep -n 'copied when `transaction()`' src/pq/connection.mojo`` → `808: The handler is **copied when \`transaction()\`** is called, ...` ✓ |
| 4 | `PreparedStatement` に ROLLBACK / DDL 巻き戻しの注意（RESEARCH §3-8） | `grep -n 'survives `ROLLBACK`\|rollback undoes DDL\|rolled-back transaction' src/pq/prepared.mojo` → `:40` / `:43`（既存・モジュール docstring）+ **`:73`（turn 9 で追記・struct docstring）** ✓ |
| 5 | `commit()` に「`ROLLBACK` command tag → `PgError`」（D10） | ``grep -n 'command tag `ROLLBACK`' src/pq/transaction.mojo`` → `238:` ✓（`:246-247` にも `COMMIT resulted in ROLLBACK: the transaction was aborted` の文言）|
| 6 | `__deinit__` と書き `__del__` と書かない | `grep -rn '__del__' src/pq` → **0 matches in 13 files** ✓。``grep -rn '`__deinit__`' src/pq`` → 8 hits（result 2 / transaction 4 / prepared 1 / connection 1）|

**申し送りの訂正**: turn 8 の申し送り (3) は「(c) で残っているのは 4 番だけ」としていたが、**2 番も
欠けていた**（`connection.mojo:296` が "Exactly one statement is allowed" で、D13 の `single statement`
という文言と一致していなかった）。4 番は `prepared.mojo` のモジュール docstring（`:40`/`:43`）には既にあり、
PLAN T7 (c) が名指しする `PreparedStatement` **struct** の docstring にはなかったので `:73` に足した。
どちらも挙動は変えていない（`git diff src/pq/connection.mojo src/pq/prepared.mojo` が docstring 行のみ）。

### (d) 品質（各段の所要つき）

| 判定 | コマンド | 結果 |
|---|---|---|
| docstring 診断 0 | `check` 3/6 段（追従先チェックリスト 3 行目のコマンド） | **`missing doc strings outside _ffi: 0`** ✓ |
| fmt 差分 0 | `pixi run fmt`（親が統合後に 1 回だけ）→ `check` 1/6 段 | **`All done! 30 files left unchanged.`** = 差分ゼロ。1/6 段も PASS ✓ |
| `fn` 0 件 | `grep -rnE '^[[:space:]]*fn ' src tests examples hello.mojo` | **0 件**（exit 1、出力なし）✓ |
| 既定ハンドラが黙る | `grep -c 'implicit ROLLBACK failed' build/final_check.log` | **0** ✓ |
| `check` 6/6 | `/home/parallels/.pixi/bin/pixi run check` | **`final_check: PASS`** ✓ |
| `package` 警告ゼロ | `/home/parallels/.pixi/bin/pixi run package` | 出力はタスク見出し行のみ ✓ |

所要（`date -Iseconds` と `check` のステージ見出しの時刻から）: 全体 **02:27:05 → 02:29:04**。
`fmt` 8 s（02:27:05 → 02:27:13）、`check` **111 s**（02:27:13 → 02:29:04）。`check` の内訳:
1/6 fmt 1 s / 2/6 precompile 1 s / 3/6 docstring 0 s / **4/6 examples 4 s（basic + params の 2 本）** /
5/6 tests 105 s / 6/6 warnings 0 s。5/6 の中で **test_leak が 59 s**（12/12 PASS、PG17 のみ）。

`check` の 6/6 段は `warning:`（コンパイラ）も `WARNING:`（libpq の notice processor 経由のサーバー警告）も
**0 件**（`matched lines in build/final_check.log: 0`）。5/6 段で両サーバーの全ファイルが PASS
（`test_leak` は `PQ_TEST_LEAK_SERVERS=1` で `-- 127.0.0.1:54314 tests/test_leak.mojo skipped` の 1 行）。

**`pixi run test`（両サーバーで test_leak も 2 回）は turn 9 では回していない**。理由: T7 の変更は
docstring と新規 example だけで `src/pq` の挙動も `tests/test_leak.mojo` も 1 行も変えていないため、
turn 8 で取った両サーバー 12/12 の測定が有効なまま。`check` の 5/6 段が両サーバーの他 12 ファイルを
すべて回しているので、T7 (d) の完了基準（`check` 6/6）は満たしている。REQ §5.3 の「両サーバーで leak」は
turn 8 の実測が根拠（verify が再確認するなら `pixi run test` を 1 回。5〜6 分）。

リーク系列（`check` の 5/6 段、PG17）— Phase 2 の 4 系列は完全に平坦:

```
connect/query/close  [4092, 4176, 4176, 4176, 4176, 4176, 4176, 4176, 4176]
failed-open          [4556, 4556, 4556, 4556]
escape_literal       [4581, 4581, 4581, 4581]
failed-execute       [4581, 4581, 4581, 4581]
execute(sql, params) [4679, 4679, 4679, 4679, 4679, 4679, 4679, 4679, 4679]
prepare/execute/drop [4679, 4679, 4679, 4679, 4679, 4679, 4679, 4679, 4679]
transaction/commit   [4680, 4680, 4680, 4680, 4680, 4680, 4680, 4680, 4680]
transaction/drop     [4680, 4680, 4680, 4680, 4680, 4680, 4680, 4680, 4680]
```

### (e) 追従先チェックリスト全行の照合（素のシェル。コマンドと出力）

| 行 | コマンド | 結果 |
|---|---|---|
| libpq 53 本 | `grep -c '^    var PQ' src/pq/_ffi/functions.mojo` | **53** ✓ |
| 〃 | `grep -cE '^        (String\()?"PQ[A-Za-z]+"\)?,$' tests/test_ffi.mojo` | **53** ✓ |
| 〃 | `grep -c fifty tests/test_ffi.mojo` | **0**（exit 1）✓ |
| 〃 | `grep -n '50 本' .gsd-lite/PLAN.md .gsd-lite/PROGRESS.md` | **2 件**（PLAN:41 = チェックリスト自身の「50 → **53 本**」の行、PROGRESS:52 = turn 3 の履歴記述）。どちらも**現在のコードについての陳腐化した主張ではない**ので ✓ と判定（PLAN 訂正に明記）|
| `PgErrorKind` の「five」 | `grep -rnE 'exactly five\|the five failure\|five failure' src/pq` | **0 件**（exit 1）✓。`__init__.mojo:10` の「the five `PQTRANS_*`」は別物なので残っている |
| 〃 | `grep -c 'USAGE' src/pq/errors.mojo` | **3**（≥ 3）✓ |
| 公開 struct 3 型の再エクスポート | `grep -nE 'Param\|PreparedStatement\|Transaction' src/pq/__init__.mojo` | 3 型とも出る: docstring の再エクスポート一覧 `:8-9`、import `:113` `Param` / `:114` `PreparedStatement` / `:116` `Transaction` ✓ |
| 〃 docstring 診断 | `check` 3/6 段 | `missing doc strings outside _ffi: 0` ✓ |
| `examples/` を足す | `grep -rn 'examples/' pixi.toml tests/final_check.sh` | `pixi.toml:18 example-params = "mojo run -I src examples/params.mojo"` と `tests/final_check.sh:120 run_logged mojo run -I src examples/params.mojo` で**両方に出る** ✓ |
| テストファイルを足す | 新規テストファイルなし（T7 は example のみ） | 該当なし。`run_tests.sh` の `test_leak` 特別扱いは未変更 ✓ |
| libpq を呼ぶ新経路 | `grep -rn 'PQfreemem(' src/pq/*.mojo` | **2 行**（`connection.mojo:667` `escape_literal` / `:709` `escape_identifier`）✓ |
| 〃 | `grep -rn 'PQexec(' src/pq/*.mojo` | **4 行**（`connection.mojo:279` `execute(sql)` / `:527` describe 失敗時の DEALLOCATE / `prepared.mojo:114` `__deinit__` / `transaction.mojo:167` `__deinit__`）✓ |
| 〃 | `grep -rc get_function src/pq` | 13 ファイル**全 0** ✓ |
| 埋め込み NUL の経路 | `grep -rn '_reject_nul' src/pq` | `connection.mojo:352` が `execute(sql, params)`（`:286` 開始）の中にある ✓。他に `:180` conninfo / `:213-214` params key・value / `:278` `execute(sql)` / `:492` `prepare` / `:649`・`:691` escape 系 / `result.mojo:203` / 定義 `errors.mojo:165` |
| テスト環境の環境変数 | `grep -rn PQ_TEST_LEAK_SERVERS tests/run_tests.sh tests/final_check.sh` | **5 行**（≥ 2）✓（`run_tests.sh:19` コメント / `:82-85` 判定 / `final_check.sh:119` 5/6 段）|
| リークループ（T6） | `grep -c '^def test_' tests/test_leak.mojo` | **12** ✓ |
| `PQ_MOJO_LIBPQ`（T1 (b)） | `grep -n 'that one path only' src/pq/_ffi/loader.mojo` | **1 件**（`loader.mojo:10`）✓ |
| savepoint が `escape_identifier` 経由 | `grep -rn 'escape_identifier' src/pq/transaction.mojo` | `:309` `savepoint` / `:339` `rollback_to` / `:365` `release` の 3 箇所とも ✓ |
| `fn` を書かない | `grep -rnE '^[[:space:]]*fn ' src tests examples hello.mojo` | **0 件** ✓ |

### サブエージェント運用（2 本並行。報告のうち親が判断した点）

- A / B の対象ファイルは重ならず、統合時の衝突は 0 件。`fmt` は親が 1 回だけ回し、差分ゼロ
- **依頼文に「申し送りを鵜呑みにせず 6 項目すべて自分で grep して確かめる」と書いたことが効いた**
  （(c) 2 番の欠落を検出）。仕様を「必ず満たす 1 行の断言」として抜き書きする構成も、A が
  `tx.commit()` を最後の行に置く規約と件数の期待値 2 を取り違えずに実装できた理由
- 固定文言（契約外の挙動は実装せず報告だけ）どおり、A は『契約外の提案』3 件（savepoint の効果を
  行の中身でも表示 / `final_check.sh` の examples 段を配列ループ化 / `pixi.toml` に集約タスク）を
  実装せず報告のみで返した。**親もいずれも採らなかった**（完了基準は「件数表示」で、2 本では YAGNI）。
  B は『契約外の提案』なし

### 契約外の変更 0 件

T7 では完了基準の範囲外の変更をしていない（turn 8 の `run_tests.sh` コメント更新のような例はなし）。

### 次への注意

1. **PLAN の全 7 タスクが完了した**ので次は `/gsd-lite-verify`。`phase: "verify"` に遷移済み。
2. **verify が `pixi run check` を回すときの目安は 80〜115 s**（turn 8 で 82 s、turn 9 で 111 s。
   同一コード・同一マシンでこの幅があるので、1 回の数字で遅くなったと判断しないこと）。
   `pixi run test`（両サーバー・test_leak 2 回）は 5〜6 分。
3. **`pixi run test` を turn 9 では回していない**（理由は (d) 節末尾）。verify が REQ §5.3 の
   「両サーバーで leak」を自分で確かめたいなら `pixi run test` を 1 回回す。turn 8 の実測が根拠として残っている。
4. **陽性対照のバイナリと src コピーは `.gsd-lite/logs/.../scratch/turn-008-*` に残っている**（gitignore 済み）。
   リーク検出力を再確認したいならビルドし直さず実行できる。ただし①のバイナリは 5 テストが FAIL して
   RSS が約 2.4 GB まで伸びるので注意（turn 8 の申し送り (5) の再掲）。
5. **(e) の `grep -n '50 本'` が 0 件にならない**のは仕様（チェックリスト自身の行と履歴記述の 2 件）。
   verify はこれを差し戻さないこと。PLAN T7 の「PLAN 訂正（turn 9 実測）」に理由を書いた。
6. **turn 8 の申し送りが 1 項目外していた実例がある**（(c) の残りが「4 番だけ」ではなく 2 番もあった）。
   verify は PROGRESS の申し送りを前提にせず、完了基準そのものを `grep` で確かめ直すこと。
