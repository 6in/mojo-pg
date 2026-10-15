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

## turn 7 — impl — T5 `Row` / `RowIter`（`Iterable` + `get[T]` / `get_optional[T]`）+ 受け入れクエリと型取得テスト
- やったこと: サブエージェント 2 本（A: `src/pq/result.mojo` に Row 系を追記 / B: `tests/test_result.mojo` を PLAN の仕様表から独立に）で並行実装し統合。
  `pixi run test` は両サーバーで **182 PASS / 0 FAIL**（test_result 13 ×2 が純増。connection 14 / decode_text 49 / errors 3 / ffi 7 / loader_fail 1 / result 13 / smoke 4 ×2）、
  ログ全体で `FAIL` `warning:` `error:` `out of range` `NOTICE` が grep 0 件、`pixi run package` exit 0、docstring 診断（`_ffi` と合成 dunder 除外）0 件、`pixi run fmt` 差分なし（18 ファイル）
- 負のコンパイル確認（P5 / REQ §5.2）: `.gsd-lite/logs/phase1-sync-text-basic/scratch/turn-007-neg-row-escape.mojo`。
  `var moved = result^` で `Result` を移動した後に `row.get[Int32](0)` を使うと `error: use of uninitialized value 'result'`（`note: 'result' declared here`）でコンパイル失敗。
  **エラーが出るのは `row.get` の行で、そこに `result` という名前は出てこない** — origin が借用を通じて `result` を初期化済みに保っていることの証拠。期待どおり
- 想定外: (1) **`_ = x^` は寿命を終わらせない**（PLAN 訂正 (b) の原因）。`_ = result^` の直後に `result.row_count()` を書いてもコンパイルも実行もできる（scratch `turn-007-neg-row-escape3.mojo` で単独確認）。
  4,000 バイトの text を持つ結果で `_ = result^` 後に 2,000 回の `String` 確保を挟んで読み直しても値は無傷だった（`turn-007-neg-row-escape2.mojo`）。
  つまり `tests/test_*.mojo` に散っている `_ = conn^` / `_ = result^` は **ASAP 破棄を防ぐ生存マーカー**として機能しているのであって、デストラクタの明示呼び出しではない。**この解釈は既存テスト全体の読み方に関わる**
  (2) **B の統合は 1 箇所だけ合わなかった**（PLAN どおりの想定内の食い違い）: B は契約文の `Row` という表記から「origin パラメータ無し」と仮定してヘルパーを書いたが、実装は `Row[origin: ImmOrigin]`。
  `'Row[_]' is not concrete, use '[]' to bind missing parameters` で 1 行目から落ちた。親が 6 ヘルパーの署名を修正（`-> Row[origin_of(result)]` と、推論パラメータ `[origin: ImmOrigin, //, T: ...]` + `row: Row[origin]`）。両形は先に scratch プローブで確定させてから適用
  (3) `len(String)` と `s[0:8]` は 1.1.0 で**エラー**（UTF-8 の曖昧さを理由に明示を要求）→ `s.byte_length()` / `s[byte=0:8]`
  (4) A の報告より: `comptime IteratorType` のような**パラメータを持つ comptime 値は docstring に `Parameters:` 節が必要**で、無いと `warning: comptime value has parameters, but has no 'Parameters' in doc string`。
  この警告文には `doc string` が含まれるので **`final_check.sh` 3/6 段の `grep -c 'doc string'` に数えられて gate が落ちる**（`pixi run package` は無言のまま）。推論パラメータ（`iterable_mut`）も列挙が必要
- やり直し: 1 回（上記 想定外 (2) のヘルパー署名修正。テスト本体のアサーションは 1 つも変えていない）
- PLAN 訂正: 2 件（どちらも実測反映で、要件・決定には触れない）。
  (a) T5 テスト案件 7 の SQL を `-2147483648::int4` / `-32768::int2` → **`(-2147483648)::int4` / `(-32768)::int2`**。
  `::` が単項マイナスより強く束縛するため、括弧なしでは正の `2147483648` を先に int4 にキャストして `ERROR: integer out of range`（int2 側は `smallint out of range`）になり、クエリ自体が通らない。**B が psql で PG14 / PG17 両方で実測して発見**
  (b) T5 の負のコンパイル確認の形を `_ = res^` → **`var moved = res^`**（根拠: 上記 想定外 (1)）
- 既存テストの期待値の変更: **なし**。既存のテストファイルは 1 つも編集していない（新規 `tests/test_result.mojo` のみ。`src/pq/result.mojo` は追記）。
  親が手を入れたのは**このターンで新規作成された** `tests/test_result.mojo` のヘルパー署名 6 箇所（想定外 (2)）だけで、期待値は未変更
- 追従先チェックリスト: 該当行を実行。
  「`Row.get[T]` の対応型を足す」→ 検査 `rg 'Int16' src/pq/decode_text.mojo src/pq/result.mojo src/pq/__init__.mojo tests/test_decode_text.mojo` は **4 ファイル中 3 ファイル**で一致（`src/pq/__init__.mojo` の型一覧は T6 の完了基準なので未作成 = 想定どおりの残り）。
  A は当初 `Row.get` の docstring に表を置かず `decode_text` を参照する形にしていたが、チェックリストが `Row.get` の docstring の型表を同期先に挙げており、
  公開 API の利用者が最初に読むのは `Row.get` 側なので**親が型表（T ↔ 要求 OID の 8 行 + 拡幅なしの明記）を追記**し、実装の単一の出所は `decode_text` であると併記した。
  「テストファイルを足す」→ `pixi run test` のログに `tests/test_result.mojo` が両サーバー分出る ✓。「公開 struct / メソッドを足す」→ docstring 診断 0 件 ✓。
  「libpq を呼ぶ新しい経路を足す」→ **非該当**（T5 は `_text` / `_is_null` / `column_type_oid` という T4 の既存経路しか使わず、新しい libpq 呼び出しを足していない）。`grep -c get_function src/pq` = 0 ✓、`rg '^\s*fn ' src tests examples hello.mojo` = 0 件 ✓。
  非該当: 「libpq 関数のバインディング」（`functions.mojo` 未編集）/「`PgErrorKind` を足す」（追加なし）/「`examples/` を足す」（T6）
- verify への申し送り（サブエージェントの「契約外の提案」から、実装せず記録したもの）:
  (1) **`is_null` に `String` 版が無い**（`get` / `get_optional` は両方ある）。列名で書く利用者は `row.is_null(res.column_index("n"))` と書くことになる。非対称
  (2) **`Row.__init__` が公開**なので、モジュール外から範囲外 index の `Row` を作れる。全アクセサが `_check_cell` で再検査するので安全だが、不変条件を構造で守るなら内部化が要る
  (3) `src/pq/__init__.mojo` が `Result` / `Row` を再エクスポートしていないので今は `from pq.result import Result, Row` と書く必要がある（T6 の完了基準に入っているので T6 で解消する見込み。`examples/basic.mojo` が `from pq import ...` だけを使う前提と整合させること）
  (4) `Row` から列メタデータ（`column_count` / `column_name`）に届かないので、`for row in res:` の中でメタデータを見るには `Result` を別に抱える必要がある
  (5) 契約にあるが必須ケースに無く**テストが無い**組み合わせ: `get[T]` に存在しない列名（→ TYPE_MISMATCH）/ `get_optional` の `String` 版 / `is_null` の範囲外 index。T5 の完了基準を満たす範囲では穴
- 次への注意: T6 は `escape_literal` / `escape_identifier`（**`PQfreemem` の初登場**。追従先チェックリストの「`PQfreemem` は 1 箇所」= 各メソッド 1 回を必ず確かめる）/ `server_version` / `status` / `transaction_status` + `examples/basic.mojo` + `__init__.mojo` 再エクスポート。
  `__init__.mojo` には **REQ §4.5 の型マッピング表**を書くので、`decode_text.mojo`（決めた事項 5）と `Row.get` の docstring の表（今回追記）と**3 箇所を 1 対 1 で突き合わせる**こと。
  T6 で初めて `pixi run check` の全段がそろう（`examples/basic.mojo` が埋まるため）。それまで `check` は examples 段で落ちる。
  サブエージェントに渡す契約文では、**`Row` を必ず `Row[origin]` と書く**（今回の唯一のやり直しの原因。型パラメータを省くと「パラメータ無し」と読まれる）。
  `fmt` は親が統合後にだけ走らせる方針は今回も維持して衝突ゼロだった（turn 6 の想定外 (7) への対処が有効）

## turn 8 — impl — T6 escape / status 5 メソッド + `examples/basic.mojo` + 公開 API 再エクスポート
- やったこと: サブエージェント 2 本（A: `connection.mojo` の 5 メソッド + `tests/test_connection.mojo` 追記 / B: `examples/basic.mojo` + `src/pq/__init__.mojo` 再エクスポート + `pixi.toml` + `final_check.sh` 4/6 段）で並行実装し統合。
  **`pixi run check` が初めて全段 PASS**（1/6 fmt 差分なし・2/6 precompile・3/6 docstring 診断 0 件・4/6 `examples/basic.mojo` 実行（`n = 1` / `s = hello` / `z = NULL`）・5/6 両サーバー **194 PASS / 0 FAIL**（97 ×2。test_connection が 14 → 20 で +6 ×2 = +12）・6/6 `warning:` 0 件）。所要は 5/6 段が約 95 s（PG17 ≈ 74 s + PG14 ≈ 54 s を直列）、全体 99 s
- 想定外: (1) **`pixi run check` の 1/6 段は未コミットの作業ツリーでは原理的に落ちる**。この段は `mojo format` 実行後に `git diff --quiet -- src tests examples hello.mojo` を見るので、
  「整形で差分が出た」と「そのターンの実装がまだ未コミット」を区別できない。実際 1 回目の `check` は `All done! ✨ 19 files left unchanged`（= 整形は何も変えていない）なのに 1/6 だけ FAIL した。
  PLAN「検証コマンド」節が最終判定を**「クリーンな状態から全検査」**と定義しているとおり、**コミット後に `check` を回すのが設計どおりの使い方**なので、ゲート側は直していない（T8 の完了基準も同じ HEAD 相対の形を指定している）。手順は「fmt → 実装コミット → `check`」
  (2) A の報告より: `PQescapeLiteral` は `OptCStr` を返すが `PQfreemem` は `MutRawPtr` を取るので、`p = quoted.value()` から `MutRawPtr(unsafe_from_address=Int(p))` を作り直して渡している。コピーが先なので「各メソッド `PQfreemem` 1 回」は保たれる
  (3) B の報告より: サブエージェントへの依頼文で「`src/pq/decode_text.mojo` の型マッピング**表**を読め」と書いたが、`decode_text.mojo` の型対応は**表ではなく散文**（モジュール docstring と `decode_text` の docstring の 2 箇所、`grep -c '^|'` = 0）。依頼文の誤りで、PLAN の追従先チェックリストは `decode_text.mojo` について「OID 定数 + `comptime if` 分岐」しか求めていないので **PLAN 訂正には当たらない**
- やり直し: 0 回（統合時のコード修正なし。親が直したファイルは無く、`fmt` も 19 ファイル無変更）
- PLAN 訂正: なし
- 既存テストの期待値の変更: **なし**。`tests/test_connection.mojo` は 6 本を**追記**しただけで既存 14 本は未編集。`tests/final_check.sh` の 4/6 段は「`examples/basic.mojo` が無ければ意図的に fail」という**T6 で解消する前提で書かれていた暫定分岐**を外して実行に切り替えた（T1 完了基準に明記されていた予定どおりの変更で、期待値の変更ではない）
- 追従先チェックリスト: 該当 3 行を実行。
  「`examples/` を足す」→ `rg 'examples/' pixi.toml tests/final_check.sh`: `pixi.toml:17 example-basic` と `final_check.sh:87 run_logged mojo run -I src examples/basic.mojo` の両方 ✓。
  「公開 struct / メソッドを足す」→ 3/6 段の docstring 診断 0 件 ✓。`escape_literal` の docstring に ` E'a\b'` の例あり ✓（T8 の `rg` 検査対象）。
  「libpq を呼ぶ新しい経路を足す」→ `PQfreemem` は `connection.mojo:317`（escape_literal）と `:356`（escape_identifier）の**各 1 回だけ** ✓、`char*` 戻りは両方 `String(unsafe_from_utf8_ptr=p)` で即コピーしてから free ✓、`grep -rc get_function src/pq` = 0 ✓。
  横断検査: `rg '^\s*fn ' src tests examples hello.mojo` = 0 件 ✓。
  非該当: 「libpq 関数のバインディング」（`functions.mojo` 未編集。50 本のまま）/「`Row.get[T]` の対応型」（追加なし）/「`PgErrorKind` を足す」（追加なし）/「テストファイルを足す」（新規ファイルなし・追記のみ）
- 型マッピング表の 3 箇所突き合わせ（前ターンの申し送り）: `src/pq/__init__.mojo`（新規・4 列表）/ `Row.get` docstring（表）/ `decode_text.mojo`（散文）の 3 つで **OID は全て一致**（bool 16 / int2 21 / int4 23 / int8 20（`Int64` と `Int`）/ float4 700 / float8 701 / bytea 17 hex のみ / `String` は任意 OID）、拡幅なしも 3 箇所すべて明記。差は表現だけで矛盾なし
- verify への申し送り（サブエージェントの「契約外の提案」から、実装せず記録したもの）:
  (1) **`OID_TEXT`(25) / `OID_VARCHAR`(1043) / `OID_BPCHAR`(1042) / `OID_NAME`(19) は宣言されているが 1 箇所も使われていない**（B の実測: `src` と `tests` 全体で定義行のみ一致）。`decode_text` の `String` 分岐は OID を検査しないので、型マッピング表の「25, 1043, 1042, 19」列は**文書だけで強制されていない**（`jsonb` 列も `String` で読める）。表の「上記以外 → `String` としてのみ取得可」行は事実と整合しているので変更なし。定数を使うか消すかの判断は verify へ
  (2) **`status()` / `transaction_status()` の戻り `Int` を比較する定数の置き場所**: A の新テストは `pq._ffi.types` から `CONNECTION_OK` / `PQTRANS_*` を import している（`tests/test_ffi.mojo` と同じ形）。T6 で `pq` 直下に再エクスポートしたので、**公開 API だけを使うなら `from pq import ...` に寄せられる**（A と B は並行で、A は B の成果物を前提にできなかった）。利用者向けの `is_ok()` / `in_transaction()` のような述語メソッドの提案は却下して記録のみ
  (3) **`examples/basic.mojo` の `PgError` import はコンパイル上は不要**（B の実測: `from pq import Connection` だけでも `except e` は callee の `raises PgError` から型推論されて exit 0）。完了基準が 2 名の import を指定しており、再エクスポートの証明にもなるので指定どおり残した
  (4) **テストが無い escape のケース**: マルチバイト UTF-8（byte 長 vs 文字数の区別は docstring で主張しているだけで未実測）/ 空文字列 / 埋め込み NUL / NULL 戻り → `PgError(SERVER)` 分岐（libpq の確保失敗を起こせないので到達不能）
  (5) T5 からの持ち越し（未解決のまま）: `is_null` に `String` 版が無い / `Row.__init__` が公開 / `Row` から列メタデータに届かない / `execute` のエラー分類（sqlstate 無し + `CONNECTION_BAD` を `CONNECTION` に寄せるか）
- 次への注意: 残りは T7（`tests/test_leak.mojo`）と T8（品質仕上げ）。
  **T7 は実行時間が長い**: 本体 10,000 回 ≈ 35 s/サーバー + 異常系 3 ループ ×1,000 回。`test_connection.mojo` が既に ≈ 74 s/サーバー（PG17 実測）あるので、T7 投入後の `pixi run test` は 1 回 4〜5 分を見込むこと（`check` も同じだけ伸びる）。
  T7 の `is_leaking` 単体テスト 4 ケースは DB 不要なので、本体ループの前に置けば失敗が早く分かる。macOS 判定（`CompilationTarget.is_macos()` / `os_is_macos()`）と `size_of` の import 元は未プローブ（PLAN「impl への申し送り」）—— コンパイルエラーになったら scratch で名前を確かめてから PLAN 訂正する。
  **実装 → コミット → `pixi run check`** の順を守る（上記 想定外 (1)）。`fmt` は親が統合後に 1 回だけ走らせる方針を継続（3 ターン連続で衝突ゼロ）

## turn 9 — impl — T7 `tests/test_leak.mojo`（10,000 回ループ + 異常系 3 本 + `is_leaking` 単体 4 ケース）
- やったこと: `rss_pages()`（`/proc/self/statm` の 2 番目）/ `is_leaking(samples, tolerance_pages)`（単調増加 **or** 最終−初回 > tolerance）/ DB 不要の単体テスト 4 ケース（本体ループより先に宣言）/
  本体 10,000 回（ウォームアップ 1,000・9 サンプル）/ 異常系 3 本（誤パスワード `open` 失敗・`escape_literal`・`execute("SELEC 1")` 失敗、各 1,000 回・ウォームアップ 200・4 サンプル）。
  並列サブ作業なしの単独タスクなのでサブエージェントは使わず自分で実装。**`pixi run check` 6/6 PASS**（1/6 fmt 差分なし・2/6 precompile・3/6 docstring 診断 0 件・4/6 `examples/basic.mojo`・5/6 両サーバー **210 PASS / 0 FAIL**（105 ×2。+8 ×2 = +16）・6/6 `warning:` 0 件）、全体 92 s。`test_leak.mojo` 単体は 38〜43 s/サーバー（PLAN 見積り ≈35 s とほぼ一致）
- 想定外: (1) **tolerance 16 ページだと 4 回に 1 回ほど偽陽性**になる（下記 PLAN 訂正）。リークしていないループは ±2 ページで安定するのに、
  **1 回だけ 83 ページ（≈332 KiB）の一段**が任意のループ・任意の位置で入る。1 回目の `check`（本体ループ・PG17）と、その後 3 回連続で回した 3 回目（異常系 `failed-open`・PG17）で再現し、
  訂正後の `check` では PG17 の本体ループのサンプル 3 でまた同じ **+83**（37731 → 37814）が出て今度は PASS。4 ループ・PG14 / PG17 で常に同値なので libpq 配下の遅延初期化（1 回だけの確保）と判断
  (2) `with open(...) as f:` の中で `var` 宣言した値は **with ブロックの外から見えない**（`error: use of unknown declaration 'text'`）。`read()` → `split` → `atol` を with の中に収め、`return` も中で行う形にした（scratch プローブで確定）
  (3) **リスト literal `[100, 101, 102, 103]` は `Array[Int, 4]`** で `List[Int]` 引数に渡せない（`cannot be converted from 'Array[Int, Int(4)]'`）。`var samples: List[Int] = [...]` と**型注釈を付ける**と List になる（`tests/test_decode_text.mojo` の既存流儀と同じ）
  (4) `CompilationTarget.is_macos()`（`std.sys.info`）と `/proc/self/statm` 読みは**どちらもプローブ一発で動いた**（PLAN「未プローブ」項目の解消）。macOS 判定は実行時 `if` で十分（`/proc` 読みは macOS でもコンパイルは通る）
- やり直し: 1 回（上記 想定外 (1) の tolerance。コンパイルエラー 2 件（(2)(3)）は scratch プローブと 1 行修正で、立て直しには数えていない）
- PLAN 訂正: 1 件（実測反映。`tolerance_pages` は DECISIONS D6 が固定していない PLAN 側の数値なので要件・決定には触れない）。
  T7 完了基準と決めた事項 12 の `tolerance` を **16 → 256 ページ（1 MiB = 観測された一段 2 回分）**。
  **検出力は落ちない**根拠: 定常リークは `is_leaking` の「全隣接差分 > 0」側が拾う（100 B/回でも本体 1,000 回区間 = 24 ページ、異常系 200 回区間 = 5 ページで**全区間が増える**ので単調増加が成立する）。
  tolerance はバースト型リーク専用の保険であり、1 段だけの確保は単調増加にはならない（4 サンプル中 1 区間しか正にならない）。`is_leaking` の**単体テスト 4 ケースは tolerance を引数で渡すので 16 のまま**（完了基準どおり）
- 既存テストの期待値の変更: **なし**。既存テストファイルは 1 つも編集していない（新規 `tests/test_leak.mojo` のみ）。`tests/run_tests.sh` には**ファイルごとの所要秒を出力する 3 行を追加**しただけ（T7 完了基準の「所要時間が分かる出力（任意）」。判定ロジックは未変更）
- 追従先チェックリスト: 該当 1 行のみ。
  「テストファイルを足す」→ 追従先は無し（`run_tests.sh` は glob）。`pixi run test` のログに `tests/test_leak.mojo` が両サーバー分出る ✓。
  横断検査: `rg '^\s*fn ' src tests examples hello.mojo` = 0 件 ✓、3/6 段の docstring 診断 0 件 ✓（`src/pq` 対象なので本タスクは非該当だが素通し確認）。
  非該当: 「libpq 関数のバインディング」/「`Row.get[T]` の対応型」/「`PgErrorKind` を足す」/「`examples/` を足す」/「公開 struct / メソッドを足す」（`src/pq` は 1 行も変更していない）/「libpq を呼ぶ新しい経路を足す」（既存の `open` / `execute` / `escape_literal` だけを回している）
- verify への申し送り:
  (1) **リーク検出の「陽性側」は未実証**。`is_leaking` の判定ロジックは単体テスト 4 ケースで検査しているが、「実際に `PQclear` を消したら本体ループが FAIL する」ことは確かめていない（`src/pq` を壊す変更が必要なので実装せず）。
  やるなら `__deinit__` の `PQclear` を一時的にコメントアウトして 1 回回す（期待: 9 サンプルが単調増加して FAIL）
  (2) 83 ページの一段の**出所は特定していない**（libpq / OpenSSL / glibc arena のいずれか）。tolerance で吸収しているだけなので、将来この値が変われば再調整が要る。サンプル列を常に print しているので `check` のログで追跡できる
  (3) 本体ループは `conn` / `result` の破棄を**スコープ終端（ループ 1 周ごと）に任せている**。turn 7 で判明したとおり `_ = x^` は生存マーカーで破棄命令ではないので、10,000 回がサーバーの接続上限に当たらず RSS も平坦という実測が、1 周ごとに `PQfinish` が走っている間接的な証拠になっている
- 次への注意: 残りは **T8（品質仕上げ）だけ**で、これが最後のタスク。完了基準はほぼ「機械判定を並べて結果を PROGRESS に書く」なので実装は少ないが、
  **`pixi run check` が 1 回 92 s、`test` が 85 s** かかるので回す回数を計画すること（T8 は `check` 1 回で足りる）。
  T8 の `rg` 検査（`execute` の docstring の D9 文言 / `column_index` と `Row.get(name)` の `PQfnumber` 小文字化 / `escape_literal` の ` E'...'` 例）は turn 8 で ✓ を確認済みだが、**T8 で改めて実行して結果を書く**こと。
  追従先チェックリストは**全行**を実行する（50 本の一致・`get_function` 0 件・`PQfreemem` 2 箇所を特に）。`fmt` → コミット → `check` の順は維持（turn 8 想定外 (1)）

## turn 10 — impl — T8 品質仕上げ（機械判定の全実行・最終タスク）
- やったこと: T8 の完了基準 7 項目と追従先チェックリスト**全 7 行**を実行し、**すべて基準どおり**だった（`src` / `tests` / `examples` のコード変更は 0 行。
  `pixi run fmt` は 20 ファイル無変更）。**`pixi run check` 6/6 PASS**（21:47:53 → 21:49:17、**全体 84 s**）。
  唯一の変更は PLAN.md の検査コマンドを `rg` → `grep` に直したこと（下記 PLAN 訂正）。T8 の完了基準どおり `HANDOFF.md` は触っていない
- T8 完了基準の実測:
  (1) docstring 診断（`_ffi` と合成 dunder を除外）= **0 件** ✓（`check` 3/6 段も `missing doc strings outside _ffi: 0`）
  (2) `pixi run fmt` 後 `git diff --quiet -- src tests examples hello.mojo` = **exit 0** ✓
  (3) `grep -rnE '^[[:space:]]*fn ' src tests examples hello.mojo` = **0 件（exit 1）** ✓
  (4) `pixi run check` = **exit 0 / `final_check: PASS`**、`build/final_check.log` の `warning:` 行 = **0** ✓
  (5) docstring 文言 3 件 ✓: `Connection.execute`（`connection.mojo:204-210`）に「複数文は最後の文の結果・途中の失敗はそのエラー」（D9）/
      `PQfnumber` の小文字化規則は `result.mojo:180`（`column_index`）・`:402`・`:462`（`Row.get(name)` の 2 オーバーロード）の 3 箇所（P7）/
      `escape_literal` に `` yields ` E'a\\b'` ``（`connection.mojo:287`、P13）
  (6) `check` 各段の所要と結果: 1/6 fmt 0 s（20 files unchanged）・2/6 precompile 1 s・3/6 docstring 診断 0 件 0 s・4/6 `examples/basic.mojo` 1 s（`n = 1` / `s = hello` / `z = NULL`）・
      **5/6 両サーバー 82 s（PG17 41 s + PG14 41 s を直列）で 210 PASS / 0 FAIL**（105 ×2。turn 9 から増減なし）・6/6 `warning:` 0 件。最長は `test_leak.mojo` 37 s / 36 s、次が `test_connection.mojo`
- 追従先チェックリスト（**全 7 行**を実行。T8 は該当・非該当を問わず全行）:
  (1) libpq バインディング 50 本 → `grep -c '^    var PQ' src/pq/_ffi/functions.mojo` = **50**、`tests/test_ffi.mojo` の名前リスト（PLAN の ERE 版）= **50**、`assert_equal(len(names), 50)`（`test_ffi.mojo:99`）が機械判定、PLAN 本文の「50 本」と一致 ✓（3 つとも 50）
  (2) `Row.get[T]` 対応型 → `grep -c 'Int16'` が `decode_text.mojo` 3 / `result.mojo` 1 / `__init__.mojo` 1 / `test_decode_text.mojo` 4 で**4 ファイル全部に出る** ✓
  (3) `PgErrorKind` → `grep -c 'TYPE_MISMATCH' src/pq/errors.mojo` = **3**（≥ 2。定数・`write_to`・docstring 一覧）✓
  (4) テストファイル → 新規なし。`check` 5/6 のログに 8 ファイル × 2 サーバー ✓
  (5) `examples/` → `pixi.toml:17 example-basic` と `tests/final_check.sh:87`（4/6 段）の両方 ✓
  (6) 公開 struct / メソッドの docstring → (1) の診断 0 件 ✓
  (7) libpq を呼ぶ経路 → `grep -rc get_function src/pq` が **9 ファイルすべて 0**、`PQfreemem` は `connection.mojo:317`（escape_literal）と `:356`（escape_identifier）の**各 1 回だけ** ✓
- 想定外: (1) **`rg`（ripgrep）がこの環境に無い**（`command -v rg` 空、`~/.cargo/bin` にも無い。`/bin/bash: rg: コマンドが見つかりません`）。
  turn 8 / turn 9 の PROGRESS は `rg ...` で ✓ と書いているが、実際には MCP 側の検索ツール経由だったと思われる（素のシェルでは実行不能）。`grep` の等価コマンドに置き換えて同じ結論を得た（下記 PLAN 訂正）
  (2) `grep -c` / `grep -r` は**ヒット 0 件で exit 1** を返す（`get_function` 0 件・`fn` 0 件・docstring 診断 0 件はいずれも「exit 1 が合格」）。`rg` 前提の判定文を機械化するときは注意
  (3) T8 は**コード変更ゼロで全基準を満たした**（turn 1〜9 が各ターンで `check` を通していたため）。整形・docstring・警告の負債が最終タスクに溜まらなかった
  (4) リークサンプル列に turn 9 の **+83 ページの一段が今回は PG14 側で再現**（`connect/query/close`: 37752 → 37754 → **37837** 以降平坦）。PG17 側は 37775 → 37777 で完全に平坦。
    turn 9 の訂正（tolerance 256）で吸収され PASS。「任意のサーバー・任意のループ・任意の位置で 1 回だけ」という turn 9 の見立てを支持する追加の実測
- やり直し: 0 回
- PLAN 訂正: 1 件（ツール可用性のみ。要件・決定・期待値には触れない）。
  PLAN 冒頭の無人シェル注意に「`rg` はこの環境に無い」を追記し、**追従先チェックリスト 5 行**（Int16 / TYPE_MISMATCH / examples/ / PQfreemem / 50 本）と **T8 完了基準 2 行**（`fn` 検査 / docstring 文言検査）の `rg ...` を
  `grep ...` の等価コマンドに書き換えた（`\s` は BRE/ERE に無いので `[[:space:]]`、複数ファイル横断は `-r`）。判定内容と期待値は同一
- 既存テストの期待値の変更: **なし**（`tests/` を 1 行も編集していない）
- verify への申し送り:
  (1) **PLAN 全 8 タスクが完了**。`pixi run check` が唯一の最終判定（exit 0 / `final_check: PASS` / 210 PASS 0 FAIL / `warning:` 0 件）。1 回 84 s なので verify は 1 回で足りる
  (2) 未解決として積み上がった「契約外の提案」は turn 5 / 7 / 8 / 9 の PROGRESS に列挙済み。T8 では**一切実装していない**（挙動変更なしの基準どおり）。主なもの:
    `OID_TEXT` / `OID_VARCHAR` / `OID_BPCHAR` / `OID_NAME` が宣言のみで未使用（turn 8 (1)）/ `status()` 定数の import 元を公開 API に寄せるか（turn 8 (2)）/
    `execute` のエラー分類（sqlstate 無し + `CONNECTION_BAD` を `CONNECTION` に寄せるか。turn 6 と turn 8 (5)）/ `is_null` の `String` 版が無い / `Row.__init__` が公開 /
    escape の未テストケース（マルチバイト UTF-8・空文字列・埋め込み NUL。turn 8 (4)）/ リーク検出の陽性側が未実証（turn 9 (1)）/ 83 ページの一段の出所未特定（turn 9 (2)）
  (3) docstring 診断の既知の盲点（T8 完了基準に明記）: 手書きで docstring の無い `__init__` も合成 dunder の除外に引っかかる。現状は struct docstring で代替する規約
- 次への注意: 実装フェーズは完了。次は `/gsd-lite-verify`（`phase: "verify"`）。verify は `pixi run db-up` → `pixi run check` の順で回すこと（`check` はテスト前に DB を起こさない）

## turn 11 — verify — round 1: 差し戻し（指摘 3 件 = F1 リークテストの偽陰性 / F2 接続断の分類 + NUL 拒否 / F3 文書・テスト・compose）。マージなし
- やったこと: `pixi run db-up` → `pixi run check`（6/6 PASS、210 PASS / 0 FAIL、警告 0、docstring 診断 0、fmt 差分なし、90 s）。追従先チェックリスト 7 行を再実行して全一致。
  コードレビューとセキュリティを読み取り専用サブエージェント 2 本に並行させ（FFI 50 本のシグネチャをヘッダと全照合、全 `raise PgError` の文言追跡、FFI 境界の生存確認: いずれもバグなし）、
  親は堅牢性の格子（conninfo / Dict / SQL / 列名 / escape / `PQ_MOJO_LIBPQ` × 空・NUL・巨大・不正）を scratch プローブ 2 本で一括実施（トレースバック 0、秘密情報の漏れ 0）。
  リークテストの陽性側を `src/pq` のコピー（`-I scratch`）から `PQclear` を消して実測 → **PASS してしまう**（偽陰性）。VERIFICATION.md round 1 を作成、PLAN.md に F1〜F3 と期待結果表 E1〜E16 を追記
- 想定外: (1) **リークテストが `PQclear` 全削除を検出できない**。1 回目（cold compile、baseline 88,406 ページ）だけでなく 2 回目（warm、baseline 37,765 = 実運用と同じ）でも 9 サンプル `[37765, 37767 ×8]` で完全に平坦。
  `mojo run` のプロセス内コンパイラが残す解放済み常駐ヒープが数 KB × 10,000 のリークを吸収する。`test_leak.mojo:45-48` の「100 バイト/回でも全区間で増える」は成立しない。impl の turn 9 申し送り「陽性側は未実証」が的中
  (2) `-I <dir>` で `src/pq` のコピーに差し替える方法は素直に効く（`row_count + 424242` のマーカーで確認）。`src` を触らずに positive control ができるので F1 の完了基準にこの方法を指定した
  (3) scratch プローブで `String(m[byte=0:200], "...")` は「aliasing values passed immutably」でコンパイルエラー → 一時変数に逃がす。probe の docstring 先頭小文字で lint 警告（scratch なので放置）
  (4) `COPY ... TO STDOUT` / `FROM STDIN` は `SERVER` `unexpected result status 3/4` になり次の `execute` で libpq が回復させる（要件外だが docstring に書く → F3d）。複数文 `CREATE TEMP TABLE; COPY FROM STDIN` の失敗は暗黙トランザクションごと巻き戻る（PG の仕様）
  (5) security review の実測: conninfo の**構文エラー**では libpq がトークンを echo する（`password=sec ret` → `missing "=" after "ret"`）。認証失敗では出ない。docstring の「conninfo を echo しない」は過大 → F3a
  (6) `tests/docker-compose.yml`（Phase 0 の既存ファイル、差分外）が `0.0.0.0` で superuser を公開 → F3f
- やり直し: 1 回（badlib プローブのコンパイルエラー 1 件。上記 (3)）
- 次への注意: impl は **F1 → F2 → F3 の順に 1 ターン 1 タスク**。期待結果は PLAN の表 E1〜E16 だけを見る（本文に exit / kind を重複して書いていない）。
  F1 の positive control は `cp -r src/pq <scratch>/pq` → 該当の free を消す → `mojo run -I <scratch> tests/test_leak.mojo` で、`src` 本体は変更しない。リーク状態での実行はメモリを食うので E6 の早期 fail を先に入れてから E1〜E4 を回すこと。
  F2 の NUL 拒否は kind を `TYPE_MISMATCH` に固定（判断を impl に迫らない）。F3f は compose 変更後 `pixi run db-up` で作り直し `docker ps` で E15 を確認。
  verify round 2 は「round 1 の格子の再確認 + F1〜F3 の回帰」だけを行う（新しいクラスの探索はしない）。`pixi run check` は 1 回 90 s、F1 で payload を大きくすると `test_leak` が伸びる見込み

## turn 12 — impl — F1 リークテストの検出力（偽陰性の修正）
- やったこと: 4 ループが 1 反復あたり「コンパイラの解放済みプールに収まらない量」を確保・解放する形に変え、サンプル取得時の早期 fail（`ABORT_PAGES = 65536` ページ = 256 MiB）を入れた。
  positive control E1〜E4 を `src/pq` のコピー（`-I <scratch>`）で実測して**全部 FAIL することを確認**（`src` は 1 行も変更していない）。無改変で `pixi run test` 両サーバー **3 回連続 8/8 PASS**、`pixi run check` **6/6 PASS**（210 PASS / 0 FAIL / 警告 0 / docstring 診断 0 / fmt 差分なし、97 s）
- 完了基準（表 E1〜E6）の実測:
  - **E1**（`Result.__deinit__` の `PQclear` 削除）= FAIL ✓。`connect/query/close RSS pages: [116554, 132564, 148655, 164663, 180670, 197310]` → 6 サンプル目で早期 fail（9 回のうち 6 回で打ち切り）。他 3 ループは PASS
  - **E2**（`Connection._adopt` の `PQfinish` 削除）= FAIL ✓。`failed-open RSS pages: [113795, 128685, 145082, 161476]`（全隣接差分 > 0 で判定）。他 3 ループは PASS
  - **E3**（`escape_literal` の `PQfreemem` 削除）= FAIL ✓。`escape_literal RSS pages: [89691, 92578, 95779, 98981]`（最終 − 初回 = 9,290 > 256）。他 3 ループは PASS
  - **E4**（`execute` 非成功経路の `PQclear` 削除）= FAIL ✓。`failed-execute RSS pages: [96186, 102593, 108999, 115405]`（最終 − 初回 = 19,219 > 256）。他 3 ループは PASS
  - **E5** = ✓。`pixi run test` 3 回 × 2 サーバー = 6 回すべて `test_leak.mojo` 8/8 PASS（exit 0 ×3）。turn 9 以来の「83 ページの一段」は 6 回中 3 回に出たが tolerance 256 が吸収（`[90189, 90191, 90191, 90274, ...]` など）
  - **E6** = ✓（E1 と、下記の 256 KiB password 版 E2 の 2 回で発火を実測）。**E3 / E4 では発火しない**: この 2 ループのリーク総量は 64 MiB（1,000 × 64 KiB）で 256 MiB に届かないので打ち切る対象が無く、1,000 回を回し切って tolerance 側で FAIL する。機構は `_sample` に 1 本だけ置いてあり 4 ループ共通
  - positive control の再現手段は `.gsd-lite/logs/phase1-sync-text-basic/scratch/turn-012-positive-control.sh E1|E2|E3|E4` に置いた（verify round 2 の回帰用。`src` は触らない）
- 想定外: (1) **PLAN の推奨手段のうち failed-open だけ外れた**。`PGconn` ≈40 KiB × 1,000 = 40 MiB は解放済みプール（≈100 MiB）に丸ごと収まり、`PQfinish` を消しても 9 サンプル完全に平坦で PASS（`[90556, 90557, 90557, 90557]`）。
  payload を password 側に入れる案（256 KiB）は E2 を FAIL させられたが、**libpq が SCRAM の 4,096 反復ごとに password を鍵に HMAC を張り直す**ため 1 回の open が 3.2 ms → **424 ms**、ループが 3.2 s → **424 s** に膨れたので捨てた。
  採ったのは「`=` を含まない 256 KiB のトークンを conninfo の末尾に足した 2 本目の失敗 open」（libpq が `missing "=" after "xxx..."` として `PGconn` の errorMessage に echo する = ラウンドトリップ 0、3.2 s のまま）。誤パスワードの open も同じループに残したので認証失敗経路の網羅は落ちていない
  (2) 判定の主役が入れ替わった。turn 9 までの「定常リークは全隣接差分 > 0 が拾う（100 B/回でも増える）」は**成立しない**（プールが吸収する）。実測では本体と failed-open が単調増加側、escape と failed-execute が tolerance 側で立つ。docstring の該当段落を実測に書き換えた
  (3) `len(String)` は Mojo 1.1.0 でエラー（UTF-8 のため曖昧）。`byte_length()` に直した
  (4) `pixi run check` の 1/6 段は `mojo format` 後の **`git diff`** を見るので、**未コミットの変更があるだけで FAIL する**（フォーマッタ自体は「20 files left unchanged」）。コミット前は FAIL、コミット後に 6/6 PASS。turn 12 で 2 回回した理由
  (5) `test_leak.mojo` の所要が 37 s → **43〜47 s/サーバー**、`check` 全体が 84 s → **97 s** に伸びた（payload 分）
- やり直し: 2 回（(a) `len(String)` のコンパイルエラー 1 件 = 想定外 (3) / (b) failed-open の payload 設計 2 案の破棄 = 想定外 (1)。どちらも `src/pq` には触れていない）
- PLAN 訂正: 3 件（要件・決定には触れない。実物と実測を正とした）。
  (1) 決めた事項 12 に turn 12 追記（payload 64 KiB / failed-open 256 KiB / `ABORT_PAGES` 65536 ページ / 判定の役割分担）
  (2) T7 完了基準の「`SELECT 1`」「`escape_literal("O'Reilly")`」「`SELEC 1`」「所要 ≈ 35 s」を実装どおりの payload 付きクエリと 43〜47 s に、turn 9 の「100 B/回でも全区間で増える」に取り消し線相当の PLAN 訂正を追記
  (3) F1 の推奨手段に turn 12 実測（failed-open の 3 案の結果）を追記
- 既存テストの期待値の変更: `tests/test_leak.mojo` の 4 ループが**使う入力**を変えた（下記）。**assert の期待値（`is_leaking` が False）と `is_leaking` の単体テスト 4 ケースは変更していない**。
  (1) 本体ループのクエリ `SELECT 1` → `SELECT repeat('x', 65536)`（理由: 数 KB の `PGresult` では RSS が動かず E1 が検出できない）
  (2) failed-open ループに「巨大な不正トークンの conninfo」の open を 1 本追加（誤パスワードの open は残置。理由: 想定外 (1)）
  (3) escape ループの値 `"O'Reilly"` → `"O'Reilly " + 64 KiB`（アポストロフィは残置。理由: `PQfreemem` の対象を大きくする）
  (4) failed-execute ループの SQL `SELEC 1` → `DO $$ ... RAISE EXCEPTION '%', repeat('x', 65536) ... $$`（理由: 構文エラーの `PGresult` は数百バイトで RSS に出ない。`SELEC 1` = sqlstate 42601 の経路自体は `tests/test_connection.mojo` が担保しており、F2 の E8 でも使う）
- 次への注意: 次は **F2**（`execute` の接続断を `CONNECTION` に分類 + 埋め込み NUL の事前拒否）。期待結果は PLAN の表 **E7〜E11** だけを見る。
  F2 で `src/pq/connection.mojo` を編集すると `turn-012-positive-control.sh` の行番号（`result.mojo:99` / `connection.mojo:124` / `:317` / `:263`）がずれるので、F2 以降に positive control を回すときは `grep -n 'PQclear\|PQfinish\|PQfreemem' src/pq/*.mojo` で取り直すこと（スクリプト冒頭にも注記あり）。
  `pixi run check` は 1 回 **97 s** で、1/6 段が未コミットの差分で落ちるので「実装 → コミット → `check`」の順で回すのが速い。`pixi` / `mojo` は PATH に無いのでフルパス `/home/parallels/.pixi/bin/pixi` を使う

## turn 13 — impl — F2 `execute` の接続断を CONNECTION に分類 + 埋め込み NUL の事前拒否
- やったこと: `execute` の非成功経路に「`sqlstate == ""` **かつ** `PQstatus == CONNECTION_BAD` なら `kind` を `CONNECTION`」の 1 条件を足し、`errors.mojo` に `_reject_nul(s, what)` を 1 本置いて libpq に渡す 6 箇所の入口で呼ぶようにした。`tests/test_connection.mojo` に 7 本追加（E7 の期待値を SERVER → CONNECTION に変更、E9、E10 の 8 経路）。`pixi run check` **6/6 PASS**（224 PASS / 0 FAIL / 警告 0 / docstring 診断 0 / fmt 差分なし、97 s）
- 完了基準（表 E7〜E11）の実測:
  - **E7** = ✓。`SELECT pg_terminate_backend(pg_backend_pid())` の 1 回目が `kind == CONNECTION` / `sqlstate == ""` / message に `server closed the connection unexpectedly`。2 回目も `CONNECTION`（PG14 / PG17 同一）
  - **E8** = ✓（既存 `test_syntax_error_fills_diagnostics` が無変更で PASS）。`SELEC 1` は sqlstate `42601` を持つので第 1 条件で落ちて `SERVER` のまま
  - **E9** = ✓。`COPY (SELECT 1) TO STDOUT` は `kind == SERVER` / `sqlstate == ""` / message `unexpected result status 3`。**同じテスト内で `conn.status() == CONNECTION_OK` も assert** したので、「sqlstate が空」だけでは CONNECTION に化けないことが機械判定される（E7 の規則の AND の両腕をテストが押さえている）
  - **E10** = ✓。8 経路すべて `TYPE_MISMATCH` / `message == "embedded NUL byte in <引数名>"`（`conninfo` / `params key` / `params value` / `sql` / `s` ×2 / `name` ×3）。`open` の 2 本は NUL を password の値の位置に置き、message に NUL 以降（`AFTER_NUL_MARKER`）も `WRONG_pw_123` も出ないことまで assert。拒否の直後に `execute("SELECT 1")` / `escape_literal("a")` / `column_index("a")` が通る（状態不変）
  - **E11** = ✓。既存 210 テストは 1 本も期待値を変えずに PASS（変更したのは E7 の 1 本のみ。下記）
- 想定外: (1) **`as_c_string_span()` は最初の NUL で切れる**ことを scratch プローブで実測（`"abc" + chr(0) + "MARKER"` は `byte_length() == 10` / `as_bytes()` に 0 が 1 個 / `len(span) == 3`）。つまり NUL 検査が無いと libpq は切り詰めた前半だけを見て「エラーにならずに違うことをする」（conninfo なら別のホストに繋がる、SQL なら前半だけ実行、列名なら別の列に当たる）。テストはこの性質を使って「切り詰めたら成功してしまう入力」を選んである（`SELECT 1; DROP TABLE ` + NUL、列名 `a` + NUL）
  (2) `Row.get[T](name)` / `get_optional[T](name)` は `column_index` に委譲しているので検査は `column_index` の 1 箇所で足りた（E10 の 8 経路に対して `_reject_nul` の呼び出しは 6 箇所）。契約は挙動で満たされているので重複呼び出しは入れていない
  (3) `open(Dict)` は検査専用のループを先頭に 1 本置いた（既存のコピーループ内に混ぜると `libpq_ptr()` の後になり、libpq 未ロード時に LIBPQ_LOAD が先に出て引数検査の順序が入口ごとに食い違う）。Dict は小さいので 2 パスの実害はない
  (4) turn 12 の想定外 (4) が再現: `pixi run check` の 1/6 段は `mojo format` 後の `git diff` を見るので、コミット前に回すと必ず FAIL する。先に `pixi run test`（両サーバー green）→ コミット → `check` の順で回した
- やり直し: 0 回
- 既存テストの期待値の変更: **1 箇所**。`tests/test_connection.mojo` の `test_terminated_backend_then_connection_error` の 1 回目の `execute` を `kind == SERVER` → **`kind == CONNECTION`** に変更（理由: F2 (a) そのもの = 表 E7。turn 6 と turn 11 で「kind の意味としては CONNECTION が正しい」と申し送られていた指摘の実装）。`sqlstate == ""` と message の assert は不変。turn 6 の「決めた事項 6 に触るので実装しない」というコメントも実装済みの説明に書き換えた
- PLAN 訂正: 0 件（実物と PLAN の食い違いは無かった）。決めた事項 6 への**追記**は F2 の完了基準どおり 2 件: 表に「sqlstate 空 + CONNECTION_BAD → CONNECTION」の行、節末に「埋め込み NUL の事前拒否」の段落
- 契約外の提案（実装していない。verify 判断用）:
  (1) `escape_literal` / `escape_identifier` は `PQescapeLiteral(conn, ptr, len)` に**長さを渡す**ので、libpq 自体は埋め込み NUL でも切り詰めずに扱える可能性がある（未確認）。契約（E10）が 8 経路すべて拒否と決めているので拒否で統一したが、「長さを渡す経路だけは通す」という設計もあり得る
  (2) `_reject_nul` は `errors.mojo` に置いた（`connection.mojo` と `result.mojo` の両方が既に import している唯一の葉モジュールだから）。エラー型の定義ファイルに引数検査が同居するのが気になるなら `_validate.mojo` 等に分ける案がある
  (3) E10 のメッセージの引数名が `escape_literal` / `escape_identifier` だけ `s`（実引数名そのまま）で説明的でない。`"the value to quote"` 等にする案はあるが、F2 の完了基準が「`<引数名>`」なので実引数名に揃えた
- 次への注意: 残りは **F3 だけ**（文書・テスト・compose の軽微な訂正、表 E12〜E16）。F3 の (e)「`tests/test_connection.mojo:424-425` の『Row.get は T5 で来る』コメント削除」は本ターンで**触っていない**ので行番号が動いている（`test_open_params_round_trips_application_name` 内。`grep -n 'T5' tests/test_connection.mojo` で引ける）。
  F3 (g) の E12（`detail` / `hint` / `context`）のテストは F3 の担当なので本ターンでは書いていない（一度書いたが F2 の範囲外なので外した）。
  `pixi run check` は 97 s で安定。コミット前に回すと 1/6 段が必ず FAIL するので、F3 でも「`pixi run test` → コミット → `check`」の順にすること

## turn 14 — impl — F3 文書・テスト・compose の軽微な訂正
- やったこと: F3 の (a)〜(g) をすべて実施。`connection.mojo` の 4 箇所の docstring 訂正（conninfo 構文エラーの echo / NULL メッセージ / `standard_conforming_strings` / COPY 未対応）、E12〜E14 のテスト 3 本追加、`docker-compose.yml` の 2 ポートを `127.0.0.1` バインドにして `pixi run db-up` で作り直し。`pixi run test` 両サーバー緑（**228 PASS / 0 FAIL**、114/サーバー）、`pixi run check` **6/6 PASS**（警告 0 / docstring 診断 0 / fmt 差分なし、101 s）
- 完了基準（表 E12〜E16）の実測:
  - **E12** = ✓。`test_raise_exception_fills_detail_hint_and_context`（`tests/test_connection.mojo`）。`DO $$ ... RAISE EXCEPTION 'boom' USING DETAIL = 'd', HINT = 'h' ... $$` が `kind == SERVER` / `sqlstate == "P0001"` / `message == "boom"` / `detail == "d"` / `hint == "h"` / `context` に `inline_code_block` を含む（PG14 / PG17 同一。REQ §4.4 の `detail` / `hint` / `context` を初めて assert した）
  - **E13** = ✓。`test_name_lookup_in_get_and_get_optional`（`tests/test_result.mojo`）。`SELECT 's'::text AS s, NULL::text AS n` に対し `get[Int32]("nope")` / `get_optional[Int32]("nope")` が `TYPE_MISMATCH`、`get_optional[String]("s") == Optional("s")`、`get_optional[String]("n") == None`。名前引きのヘルパー 3 本（`_get_by_name_kind` / `_get_optional_by_name_kind` / `_get_optional_by_name`）を既存の索引版と同じ形で追加
  - **E14** = ✓。`test_libpq_is_a_single_handle` を `PQlibVersion()` の一致から `Int(libpq_ptr())` の**アドレス一致**に変更（同じライブラリを 2 回ロードしても version は一致するので「1 ハンドル」の証明にならない）。ヘルパー `_table_address()` を追加
  - **E15** = ✓。`docker ps` が `tests-pg14-1 127.0.0.1:54314->5432/tcp` / `tests-pg17-1 127.0.0.1:54317->5432/tcp` のみ（`0.0.0.0` / `[::]` の行は出ない）
  - **E16** = ✓。`final_check: PASS`（1/6 fmt 差分なし「20 files left unchanged」/ 2/6 precompile / 3/6 docstring 診断 0 / 4/6 `examples/basic.mojo` 出力正常 / 5/6 両サーバー 228 PASS / 6/6 `warning:` 0 件）。所要 101 s（22:57:30→22:59:11）
- 文書訂正の実測根拠: (a) モジュール docstring と `open(String)` / `open(Dict)` の Raises を「`pq` はメッセージに conninfo / params を足さない。libpq は認証失敗ではパスワードを出さないが、**conninfo の構文エラーでは断片を echo する**（`password=sec ret` → `missing "=" after "ret"`）。プログラムが渡す資格情報は `open(Dict)`（値を解析しないので echo され得ない）」に書き換え。(b) `escape_literal` の「サーバーの `standard_conforming_strings` に従う」を削り「`standard_conforming_strings` は参照されない。バックスラッシュがあれば常に ` E'...'`」に。(c) `"PQconnectdb returned NULL (out of memory)"` → `"libpq returned NULL (out of memory)"`（`_adopt` は `open(Dict)` = `PQconnectdbParams` からも通るため）。(d) `execute` に COPY 未対応の段落。(e) `T5` コメント削除（`Row.get` は実装済みなので、直後の「サーバー側の述語で値を確かめる」コメントの「still」も落とした）
- 想定外: なし（F3 はすべて PLAN どおり。`pixi run check` が 97 s → 101 s、`test_connection` が 27 → 28 本 / `test_result` が 13 → 14 本に増えた分）
- やり直し: 0 回
- 既存テストの期待値の変更: **1 箇所**。`tests/test_smoke.mojo` の `test_libpq_is_a_single_handle` が見る値を `PQlibVersion()` の一致 → `libpq_ptr()` のアドレス一致に変更（理由: 表 E14 そのもの。version の一致は 2 回ロードでも成立するので、ロードが 1 回だったことを検出できていなかった = 偽陰性）。他のテストの期待値は 1 つも変えていない（E12 / E13 は新規追加、`test_open_params_round_trips_application_name` の変更はコメント 2 行のみで assert は不変）
- PLAN 訂正: 1 件。`.gsd-lite/PLAN.md:105`（T4 の実装メモ）の `PgError(CONNECTION, "PQconnectdb returned NULL (out of memory)")` を `"libpq returned NULL (out of memory)"` に更新（F3 (c) で message を変えたので、PLAN の記述が実物と食い違うのを解消。要件・決定には触れない）
- 契約外の提案（実装していない。verify 判断用）:
  (1) `test_open_params_round_trips_application_name` は `Row.get` が実装済みなので列値を直接 assert できる（今はサーバー側の述語で確認）。F3 の完了基準は「古いコメントの削除」だけなので assert は足していない
  (2) `tests/docker-compose.yml` の superuser `pq/pq` は 127.0.0.1 バインドで LAN からは届かなくなったが、同一ホストの他ユーザーからは届く。テスト専用なので変えていない
- 次への注意: **PLAN の未完了タスクはゼロ**。次は `/gsd-lite-verify`（verify round 2）。verify round 2 は「round 1 の格子の再確認 + F1〜F3 の回帰」だけで、新しいクラスの探索はしない（turn 11 の申し送り）。
  F1 の positive control を回すなら `.gsd-lite/logs/phase1-sync-text-basic/scratch/turn-012-positive-control.sh E1|E2|E3|E4` を使うが、**F2 / F3 で `src/pq/connection.mojo` の行番号が動いている**ので `grep -n 'PQclear\|PQfinish\|PQfreemem' src/pq/*.mojo` で取り直すこと。
  `pixi run check` は 1 回 **101 s**、`pixi run test` は 1 回 **約 100 s**（`test_leak` が 43〜45 s/サーバー）。1/6 段は未コミットの差分で必ず FAIL するので「実装 → コミット → `check`」の順で回す。`pixi` / `mojo` は PATH に無いのでフルパス `/home/parallels/.pixi/bin/pixi` を使う

## turn 15 — verify — round 2: 合格（指摘 0 件）。main へ `--no-ff` ローカルマージ（リモート無し）
- やったこと: `pixi run db-up` → `pixi run check`（6/6 PASS、228 PASS / 0 FAIL 両サーバー、警告 0、docstring 診断 0、fmt 差分なし、96 s）。追従先チェックリスト 7 行を再実行して全一致。
  F1 の陽性対照 E1〜E4 を行番号を取り直した `scratch/turn-015-positive-control.sh` で再実測（4 本とも自分のループだけ FAIL、E1 は E6 の早期 fail で打ち切り）。
  E7〜E16 を新テスト・`docker ps`・実装行で確認。round 1 の堅牢性プローブ 2 本を無改変で再実行（NUL 7 ケースが TypeMismatch に変わった以外は round 1 と同一、トレースバック 0）。
  F1〜F3 の差分は読み取り専用サブエージェント 1 本にも独立レビューさせ、バグ / リーク / 弱いテストは 0 件（docstring の精度 3 件は残留リスクに記録）。VERIFICATION.md に round 2 を追記してコミット → `git checkout main` → `git merge --no-ff`（衝突なし、30 ファイル）
- 想定外: なし（impl の申し送りどおり positive control の行番号は `result.mojo:99` / `connection.mojo:129` / `:350` / `:284` に動いていた。turn 12 のスクリプトは使わず turn 15 版を書いた）
- やり直し: 0 回
- 次への注意: 次は `/gsd-lite-reflect`（`reflect: true`）。振り返りの材料として: (1) round 1 の最重要指摘「リークテストの偽陰性」は impl の turn 9 申し送りに既にあった = **申し送りの「未実証」を impl が同じターンで陽性対照まで回していれば差し戻し 1 回が消えた**。
  (2) `_ = x^` が寿命を終わらせない（turn 7）と `mojo run` の常駐ヒープ（turn 11 / 12）の 2 つが Mojo 1.1.0 固有の落とし穴で、次のマイルストーンの RESEARCH に先回りで載せる価値がある。
  (3) `pixi run check` の 1/6 段が未コミット差分で落ちる仕様は 3 ターン連続で「想定外」に書かれた（turn 8 / 12 / 13）= PLAN の検証コマンド節に最初から「コミット後に回す」と書くべきだった。
  (4) 残留リスクの docstring 3 件（`execute` の CONNECTION の説明 / `Row.get(name)` の引数名 / `test_leak` の `PAYLOAD_BYTES` 説明）は次のマイルストーンの冒頭で 1 コミットで直せる
