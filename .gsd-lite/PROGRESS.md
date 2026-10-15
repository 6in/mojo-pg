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

## turn 3 — impl — T1 `errors.mojo` + `_ffi`（50 本）+ テスト基盤
- やったこと: サブエージェント 3 本（A: errors / B: _ffi 4 ファイル / C: run_tests・final_check・pixi タスク）で並行実装し統合。
  `pixi run test` は両サーバーで 26 件 PASS（test_errors 3 / test_ffi 7 / test_smoke 3 ×2）、`pixi run package` は exit 0 で `build/pq.mojoc` 生成・警告ゼロ。
  `pixi run check` は **examples 段のみ FAIL**（`examples/basic.mojo` は T6 で揃う。PLAN どおりの意図した赤）で、fmt / precompile / docstring 診断 / テスト / 警告ゼロの 5 段は緑
- 想定外: (1) **docstring 診断が合成 dunder を数えて 0 にできない**。`--diagnose-missing-doc-strings` は
  コンパイラ合成の `__init__` / `__deinit__` / `__copyinit__` / `__moveinit__` を **struct 宣言行**に報告し、docstring を付ける場所が無い
  （`PgError` は docstring 付きの明示 `__init__` を持つのに合成コピー / ムーブ分で 2 件報告される）。除外して 0 になることを実測し、`final_check.sh` 3/6 段と PLAN を訂正。
  (2) 追従先チェックリストの `grep -c '"PQ' tests/test_ffi.mojo` は `PQ_MOJO_LIBPQ` / `PQ_TEST_CONNINFO` / エラー文も数えて 53 になる（実体は 50 で正しい）→ 精密な grep に訂正。
  (3) `final_check.sh` の fmt 段は `git diff`（worktree vs index）なので、ステージ後にファイルを編集すると**フォーマッタのせいでなくても**赤くなる。再ステージで解消。T8 は commit 済みの綺麗な木で走らせること。
  (4) プローブで事前確認した結果はすべて PLAN どおり: struct 内 `comptime X = Self(n)` は通る、`from std.sys import size_of`、`c_size_t` あり、`size_of[PGnotify]() == 32`、`ord()` は comptime 初期化子で使える、`libpq-fe.h` の 50 本の行番号も全一致
- やり直し: 1 回（docstring 診断の 12 件。うち 5 件は `PgErrorKind` の `comptime` 定数に docstring が無い**本物の漏れ**なので追加して修正、残り 7 件は上記の合成 dunder なので判定側を訂正）
- PLAN 訂正: (a) T8 完了基準と追従先チェックリストの docstring 診断コマンド → 合成 dunder を除外する形に（根拠: 上記実測。除外なしでは達成不可能）。
  (b) 追従先チェックリストのシンボル数一致コマンド → `grep -cE` の精密版 +`assert_equal(len(names), 50)` を機械判定とする（根拠: 素朴な grep が 53 を返す実測）
- 既存テストの期待値の変更: なし（`tests/test_smoke.mojo` は未編集。`run_tests.sh` は見出し形式と 2 サーバー化のみで、テストの期待値は変えていない）
- 次への注意: T2 は `_ffi/loader.mojo` と `tests/test_smoke.mojo` の書き換え。`test_smoke.mojo` の自前 `OwnedDLHandle` 探索を消して `libpq()` 経由にするので、
  **`test_ffi.mojo` も自前で `OwnedDLHandle` / `LibpqFFI(path)` を 4 箇所で作っている**（`_libpq_path()` と 50 名の `check_symbol` ループ）。
  T2 の契約には `test_ffi.mojo` の書き換えが入っていないので、そのまま残して良いか T2 で判断する（残すなら二重管理の指摘として verify に申し送る）。
  `final_check.sh` は「全段走らせてから集約 exit」方式。`build/final_check.log` に溜めたログで警告を数えるので、段を足すときは出力を必ず `$LOG` に流すこと
  （docstring 診断の生ログだけは `build/docstrings.log` に分けてある。`_ffi` の期待される警告を数えないため）

## turn 4 — impl — T2 `_ffi/loader.mojo` + smoke / hello をローダー経由に
- やったこと: サブエージェント 2 本（A: `loader.mojo` + `test_smoke.mojo` 書き換え + `hello_libpq.mojo` + `pixi.toml` / B: `test_loader_fail.mojo` を契約から独立に）で並行実装し統合。
  `pixi run test` は両サーバーで 30 件 PASS（errors 3 / ffi 7 / loader_fail 1 / smoke 4 ×2、`FAIL` と `warning:` は grep 0 件）、`pixi run package` exit 0 で警告ゼロ、`pixi run fmt` 差分なし、`pixi run hello-libpq` が `PQlibVersion = 180006` を表示
- 想定外: (1) **`platform_map` は `List` を返せない**ので OS 既定候補はカンマ区切りの `StringLiteral`（`linux="libpq.so.5,libpq.so"`）にして実行時 `split(",")` で分解した。
  結果として RESEARCH が「未プローブ」と警告していた macOS 判定（`CompilationTarget.is_macos()` / `os_is_macos()`）は一切使わずに済んだ（PLAN の候補リストの中身は変更なし）。
  (2) `var reason = String()` が `warning: assignment to 'reason' was never used` を出す → 宣言のみ `var reason: String` にして try 末尾と except の両方で代入（1.1.0 の確定初期化解析が通る）。
  (3) **`PgError` は `Error` に暗黙変換されない**ので、`raises`（素の `Error`）である TestSuite のテスト関数から `libpq()` を直接呼べない。`test_smoke.mojo` / `hello_libpq.mojo` は `try/except` で `Error(String(e))` に変換するヘルパー経由にした（`test_errors.mojo` と同じ既存パターン）。
  (4) バージョンゲート（`PQlibVersion() < 140000`）の分岐は**実行されていない**: pixi 環境の libpq は 18.6 で、140000 未満の libpq がこのマシンに無い。文字列生成は仕様どおりだが runtime 未到達
- やり直し: 0 回（統合時の修正なし。A が spec 7 の `try/except` 省略時のコンパイルエラー、B が `ref _ = f()` の警告回避形をそれぞれ事前に実測して確定させていた）
- 既存テストの期待値の変更: `tests/test_smoke.mojo` の 3 テストを書き換えた。(a) `test_libpq_loads` は「`OwnedDLHandle.check_symbol("PQlibVersion"/"PQconnectdb")` が True」→「`libpq()` 経由の `PQlibVersion() > 0`」。
  (b) `test_libpq_version_at_least_14` は `get_function` 直呼び → `libpq()` 経由。(c) `test_toolchain` は変更なし。理由: T2 の完了基準が「自前の探索ロジックを消して `libpq()` を使う」ことそのもの（シンボル存在の網羅確認は `test_ffi.mojo` の 50 名 `check_symbol` が担当なので smoke 側の 2 シンボル確認は重複）。`test_libpq_is_a_single_handle` を新規追加
- T2 の判断（turn 3 の申し送りへの回答）: **`tests/test_ffi.mojo` は書き換えず、自前の `OwnedDLHandle` / `LibpqFFI(path)` 構築をそのまま残した**。
  理由: `test_ffi.mojo` は `_ffi` 生層の単体テストで、ローダーのキャッシュから独立に 50 シンボルの解決を確かめるのが役目。ローダー経由にすると「`_Global` が一度成功したこと」しか言えなくなる。
  ただし `_libpq_path()` 相当のパス決定ロジックが `test_ffi.mojo` と `loader.mojo` の 2 箇所にある**二重管理**なので、verify への指摘として残す
- 次への注意: T3（`decode_text.mojo`）は DB 不要で `PgError` にしか依存しないので T2 の成果物に触らない。
  T4 以降で `Connection` / `Result` が使うのは `libpq_ptr()`（`Pointer[LibpqFFI, MutUntrackedOrigin]` を返す。`__deinit__` から `PQfinish` / `PQclear` を呼ぶ用）で、**T2 では `libpq()` 側しか runtime で通っていない**（origin キャストは `libpq()` が内部で `libpq_ptr()` を呼ぶので実行はされている）。
  テストから `libpq()` を呼ぶときは `PgError` → `Error` の変換ヘルパーが必要（上記 想定外 (3)）。`PQ_MOJO_LIBPQ` を設定すると**それ 1 本だけ**が候補になり OS 既定へのフォールバックは無い（契約どおりの仕様。typo で分かりにくい失敗になりうる点は verify に申し送る）


## turn 5 — impl — T3 `decode_text.mojo`（OID 完全一致の型スイッチ）+ 境界値テスト
- やったこと: サブエージェント 2 本（A: `src/pq/decode_text.mojo` / B: `tests/test_decode_text.mojo` を契約表から独立に）で並行実装し統合。
  `pixi run test` は両サーバーで 64 件 PASS（decode_text 49 / errors 3 / ffi 7 / loader_fail 1 / smoke 4、`FAIL` と `warning:` は grep 0 件）、`pixi run package` exit 0、`pixi run fmt` 差分なし（14 ファイル）
- 想定外: (1) **ジェネリックなヘルパーの中で `_ = decode_text[T](...)` と書くと `T: Copyable` では通らない**
  （`abandoned without being explicitly destroyed: unhandled explicitly destroyed type 'AnyType'`）。テスト側のヘルパーは境界を `T: Copyable & Deinitable` にして解決。
  具体型での `_ = decode_text[Int32](...)` は問題なし。`decode_text` 自身の境界は契約どおり `T: Copyable` のまま（**T5 の `Row.get[T]` も `T: Copyable` で宣言できるが、テストからジェネリックに捨てるときだけ `Deinitable` が要る**）。
  (2) `from math import isnan` は不可（`unable to locate module 'math'`）→ **`from std.math import isnan, isinf`**。
  (3) `atol("-9223372036854775808")` は成功する（RESEARCH は `"9223372036854775808"` の失敗だけを記録していた）ので int8 の両境界が通る。`atol` は Int 幅なので int8 に自前の範囲チェックは不要。
  (4) `except e:` で `e` を使わなくても未使用警告は出ない（`_ = e` は不要）
- やり直し: 0 回（統合時の修正なし。B は実装を読まずに契約表だけで書いて初回から 49 件 PASS = 仕様と実装が独立に一致）
- PLAN 訂正: なし。契約の補足として、決めた事項 5 の「OID 不一致は `column is <oid> but <T の PG 名> was requested`」に加え、
  T3 完了基準の「全 TypeMismatch の message に期待型名と入力テキストを含む」を満たすため実装の文言を
  `column is oid 23 but int2 was requested (text: "1")` / `cannot decode "abc" as int4` に確定（どちらも型名 + 入力テキストを含む。テストは部分文字列包含だけを見る）
- 既存テストの期待値の変更: なし（新規 2 ファイルのみ。既存ファイルは未編集）
- 追従先チェックリスト: 「`Row.get[T]` の対応型を足す」行は**今回は未適用**。`src/pq/result.mojo`（T4/T5）と `src/pq/__init__.mojo` の型一覧（T6）がまだ無く、
  今回は対応型の追加ではなく初回作成だから。**T5 / T6 で型マッピング表を書くときに `decode_text.mojo` の表（決めた事項 5）と 1 対 1 で突き合わせること**
- 次への注意: T4（`Connection` + `Result` 本体）は 3 サブ作業（A: connection / B: result / C: test_connection）。T3 の成果物は読み取り専用で使う（`decode_text` を呼ぶのは T5 の `Row.get`）。
  `Connection` / `Result` が持つのは `libpq_ptr()`（`Pointer[LibpqFFI, MutUntrackedOrigin]`）。テストから `raises PgError` の API を呼ぶには
  `PgError` → `Error` 変換ヘルパーが必要（`tests/test_decode_text.mojo` の `_ok` / `_error_kind` / `_error_message` がそのまま参考になる形）。
  `pg_terminate_backend` の切断シミュレーション（T4 完了基準）は research 未検証なので、実測が期待表と違えば実測を正に PLAN 訂正する

## turn 6 — impl — T4 `Connection` + `Result` 本体 + 接続・実行の異常系テスト
- やったこと: サブエージェント 3 本（A: `src/pq/connection.mojo` / B: `src/pq/result.mojo` / C: `tests/test_connection.mojo` を契約から独立に）で並行実装し統合。
  `pixi run test` は両サーバーで 156 件 PASS / 0 FAIL（connection 14 / decode_text 49 / errors 3 / ffi 7 / loader_fail 1 / smoke 4 ×2）、`FAIL` `warning:` `out of range` `NOTICE` はログ全体で grep 0 件、
  `pixi run package` exit 0、`pixi run fmt` 差分なし（17 ファイル）、docstring 診断（合成 dunder 除外）0 件
- 負のコンパイル確認（P3）: `.gsd-lite/logs/phase1-sync-text-basic/scratch/turn-006-neg-copy.mojo` の `var c2 = c1` は
  `error: value of type 'Connection' cannot be implicitly copied, it does not conform to 'ImplicitlyCopyable'` + `note: consider transferring the value with '^'` でコンパイル失敗。**期待どおり**（`Connection` は `Movable` のみ）
- 想定外: (1) **`pg_terminate_backend` の実測が期待表と違った**（PLAN 訂正へ）。libpq は FATAL `57P01` を**一度も届けない**（ソケットが先に閉じる）。
  1 回目の execute は `kind=SERVER` / `sqlstate=""` / message `server closed the connection unexpectedly`、2 回目以降は `kind=CONNECTION` / `no connection to the server`。PG14 / PG17 同一。
  決めた事項 6 の表（FATAL_ERROR → SERVER）に実装は忠実なので**実装は変えず PLAN の期待値を実測に合わせた**
  (2) **PostgreSQL は `application_name` を NAMEDATALEN-1 = 63 バイトに切り詰め** `NOTICE: identifier ... will be truncated` を stderr に吐く。
  → 完了基準の「100 文字で一致」は原理的に成立しない。**63 バイトに変更**して完全一致で検査できるようにした（NOTICE もログから消えた。SSO 境界 23 バイトは 63 でも超える）
  (3) `PQerrorMessage(NULL conn)` は `"connection pointer is NULL\n"` を返しクラッシュしない（A 実測）。`execute` の NULL 結果経路のメッセージは degenerate な場合でも壊れない
  (4) `expand_dbname=0` の字義性を A が実測: `dbname` に `postgresql://...` URI を入れると**データベース名として扱われ** URI の host は無視されて unix socket にフォールバックする（docstring の「URI は `open(String)` を使え」の裏付け）
  (5) 複数文の失敗の `position` は**文字列全体での位置**（`SELECT 1; SELEC 2; SELECT 3` で `11`、`1` ではない）
  (6) **列名はサーバー版で違う**: 別名なしの `true` の `column_name` は PG17 が `?column?`、PG14 が `bool`。OID と値は全バージョン同一。**T5 で列名を assert しないこと**
  (7) `pixi run fmt` はリポジトリ全体（`src/ tests/ examples/ hello.mojo`）を対象にするので、並行実装中にサブエージェントが走らせると**他のサブエージェントの編集中ファイルを書き換える**。
  実際に A の fmt が B の `result.mojo` を reformat した（B は `precompile` 警告ゼロを再確認済みで被害なし）。**次回は fmt を親だけが統合後に走らせる**とサブエージェントに明記する
- やり直し: 0 回（統合時のコード修正なし。親が直したのは C のテスト 2 本の期待値のみ = 上記 想定外 (1)(2)）
- PLAN 訂正: 2 件（どちらも要件・決定に触れない実測反映）。
  (a) T4 完了基準の `application_name` を「100 文字」→「**63 バイト**」（NAMEDATALEN-1。根拠: 切り詰め + NOTICE の実測）
  (b) T4 完了基準の `pg_terminate_backend` の 1 回目を「SERVER なら sqlstate 57P01、CONNECTION でも可」→「**SERVER かつ sqlstate 空かつ message に `server closed the connection unexpectedly`**」（根拠: PG14 / PG17 での実測）
- 既存テストの期待値の変更: なし（新規 3 ファイルのみ。既存ファイルは未編集）。親が変更したのは**このターンで新規作成された** `tests/test_connection.mojo` の 2 本（上記 PLAN 訂正に対応）
- 追従先チェックリスト: 該当 3 行を実行。
  「テストファイルを足す」→ `pixi run test` のログに `tests/test_connection.mojo` が 2 回（両サーバー）出る ✓。
  「公開 struct / メソッドを足す」→ docstring 診断（`_ffi` と合成 dunder を除外）0 件 ✓。
  「libpq を呼ぶ新しい経路を足す」→ `grep -c get_function src/pq` = 0 ✓、`char*` は全箇所で即 `String` コピー（`connection.mojo` / `result.mojo` の struct フィールドは `PGconnPtr` / `PGresultPtr` / `Pointer[LibpqFFI,...]` / `Int` のみで生ポインタを保持しない）✓、`PQfreemem` はまだ 0 箇所（escape 2 メソッドは T6）。
  非該当: 「libpq 関数のバインディング」（`functions.mojo` 未編集）/「`Row.get[T]` の対応型」（T5）/「`PgErrorKind` を足す」（追加なし）/「`examples/` を足す」（追加なし）
- verify への申し送り: **`execute` のエラー分類**。「結果に sqlstate が無く `PQstatus` が `CONNECTION_BAD`」のケース（= 接続が死んだ）を `SERVER` ではなく `CONNECTION` に寄せる規則の追加は、
  決めた事項 6 の表に触るので本ターンでは実装していない。kind の意味（`CONNECTION` = 接続がもう使えない）としては CONNECTION の方が正しいという C の独立指摘なので、判断を verify に委ねる。
  併せて: 接続失敗の message には host / port / user が平文で入る（password は入らない）。P21 を「conninfo の文字列が一切入らない」と文字どおり取ると不整合なので「秘密情報を含まない」への文言修正を提案
- 次への注意: T5（`Row` / `RowIter` / `Iterable`）は `src/pq/result.mojo` に**追記**する（`Result` 本体は完成済み。`_check_cell` / `_is_null` / `_text` が `Row.get` 用の内部 API）。
  `Row.get` は必ず `_is_null` → `_text` の順で呼ぶこと（`_text` は SQL NULL と空文字の両方で `""` を返すので区別できない）。
  `Result.__init__` は `raises` 無しなので NULL 結果を弾けない（`execute` が `PQresultStatus` を先に見て守っている。T5 で別経路から `Result` を作らないこと）。
  `column_index(name: String)` は `as_c_string_span()` が `mut self` なので毎回 `name.copy()` している。`var name: String` に変えれば 1 コピー省けるが T5 の呼び出し側に影響するので T5 で判断（B の契約外の提案）。
  **T5 のテストで列名を assert しない**（上記 想定外 (6)）。`application_name` の値一致を T5 で見るなら 63 バイト前提。
  `tests/test_connection.mojo` は 1 サーバーあたり ≈ 50 s かかる（`connect_timeout=1` の到達不能テストと切断テストが主因）。T7 のリークテスト（≈ 35 s/サーバー）と合わせると `pixi run test` が 1 回 3 分前後になる見込み
