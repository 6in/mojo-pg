# PLAN — phase1-sync-text-basic

- 作成: 2026-10-15 / gsd-lite-plan（turn 2）
- 入力: REQUIREMENTS.md / DECISIONS.md / RESEARCH.md / HANDOFF.md §5.2 / `.pixi/envs/default/include/libpq-fe.h`
- 対象リポジトリ: `.`（in-repo 形）。`CLAUDE.md` / `AGENTS.md` は無い
- 無人シェルの注意（RESEARCH 冒頭）: `mojo` / `pixi` は PATH に無い。**`/home/parallels/.pixi/bin/pixi run ...`** のフルパスで呼ぶ。
  docker の DB は `tests-pg17-1`(54317) / `tests-pg14-1`(54314) が healthy で起動中（plan 時点、`docker compose ps` で確認）

## 検証コマンド

impl の各ターンがテストに使うコマンド（リポジトリルートで実行）:

```bash
/home/parallels/.pixi/bin/pixi run db-up      # 環境の初期化（docker が落ちていたら。起動済みなら即終了）
/home/parallels/.pixi/bin/pixi run test       # tests/run_tests.sh: PQ_TEST_CONNINFO 未設定なら 54317 と 54314 の両方で tests/test_*.mojo を 1 ファイル 1 プロセスで実行
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_decode_text.mojo   # 単一ファイルだけ回すとき（DB 不要のテスト）
```

- 環境の初期化（テストの前に毎回）: `/home/parallels/.pixi/bin/pixi run db-up`（`--wait` 付きなので healthy まで待つ）
- 最終判定（クリーンな状態から全検査。verify と T8 が使う）: **`/home/parallels/.pixi/bin/pixi run check`** → `bash tests/final_check.sh`
  （T1 で作る。内容: fmt → `git diff --quiet` / `mojo precompile` → `build/pq.mojoc` 生成 / docstring 診断 / `examples/basic.mojo` 実行 /
  `run_tests.sh` 両サーバー / ログ全体で `warning:` が 0 件。exit 0 が合格）
- T1 完了までは最終判定コマンドが無いので、T1 自身の検証は `pixi run test` と `pixi run package` で行う

## 追従先チェックリスト

| 変更の種類 | 直す場所 | 確かめ方 |
|---|---|---|
| libpq 関数のバインディングを足す / 減らす | `src/pq/_ffi/functions.mojo` のフィールド + `__init__` の `_dl_sym` 行（ヘッダ行番号コメント付き）、`tests/test_ffi.mojo` のシンボル名リスト、本 PLAN「決めた事項」の **50 本** | `grep -c '^    var PQ' src/pq/_ffi/functions.mojo` と `grep -cE '^\s+(String\()?"PQ[A-Za-z]+"\),?$\|^\s+"PQ[A-Za-z]+",$' tests/test_ffi.mojo` が同数（素朴な `grep -c '"PQ'` は `PQ_MOJO_LIBPQ` / `PQ_TEST_CONNINFO` / エラー文の `PQconnectdb failed` も数えて 53 になる — T1 で実測）、`tests/test_ffi.mojo` 内の `assert_equal(len(names), 50)` が機械判定、`rg -n '50 本' .gsd-lite/PLAN.md` の値を更新 |
| `Row.get[T]` の対応型を足す | `src/pq/decode_text.mojo` の OID 定数 + `comptime if` 分岐、`Row.get` の docstring の型表、`tests/test_decode_text.mojo` の境界値、`src/pq/__init__.mojo` モジュール docstring の型一覧 | `rg -n 'Int16' src/pq/decode_text.mojo src/pq/result.mojo src/pq/__init__.mojo tests/test_decode_text.mojo` で 4 ファイル全部に出る（新型でも同様） |
| `PgErrorKind` を足す | `src/pq/errors.mojo` の定数 + `PgErrorKind.write_to` の名前表 + `PgError` docstring の一覧。REQUIREMENTS §4.4 の kind 集合は固定なので**足さない**（足すなら BLOCKED） | `rg -c 'TYPE_MISMATCH' src/pq/errors.mojo` ≥ 2（定数と write_to） |
| テストファイルを足す | 無し（`run_tests.sh` は glob）。DB 不要のテストも両サーバー分回る（高速なので許容） | `pixi run test` のログに新ファイル名が 2 回出る |
| `examples/` を足す | `pixi.toml` の `[tasks]` に `example-<name>` を追加、`tests/final_check.sh` の examples 実行行 | `rg -n 'examples/' pixi.toml tests/final_check.sh` |
| 公開 struct / メソッドを足す | docstring 必須（T8 の診断で機械検出） | `mojo precompile --diagnose-missing-doc-strings src/pq -o build/pq.mojoc 2>&1 \| grep -v '/_ffi/' \| grep -vE "'(__init__\|__deinit__\|__copyinit__\|__moveinit__)'" \| grep -c 'doc string'` = 0（合成 dunder の除外理由は T8 完了基準） |
| libpq を呼ぶ新しい経路を足す | `char*` は即 `String` にコピー、`PQfreemem` は 1 箇所、`get_function` は使わない | `grep -c get_function src/pq` = 0、`rg -n 'PQfreemem' src/pq/connection.mojo` が escape 2 メソッドの各 1 回のみ |

## Tasks

- [x] T1: `errors.mojo` + `_ffi`（types / functions 50 本）+ テスト基盤（run_tests 2 サーバー・final_check・pixi タスク）
  - 完了基準:
    - `src/pq/errors.mojo`: `PgErrorKind`（Int newtype、`Equatable`、`Writable` で名前を出力）の 5 定数と `PgError`（`Copyable, Writable`、
      フィールド `kind / message / sqlstate / severity / detail / hint / position / context`、`__init__(out self, kind, message, sqlstate="", severity="", detail="", hint="", position="", context="")`）。
      `tests/test_errors.mojo`: `def f() raises PgError` を `except e` で受けて `e.kind == PgErrorKind.CONNECTION`、`String(e)` に kind 名と message を含む、
      既定引数で作った `PgError` の 6 フィールドが空文字
    - `src/pq/_ffi/types.mojo`: opaque 4 種（`PGconnPtr` / `PGresultPtr` / `PGcancelPtr` / `PGnotifyPtr`、`@fieldwise_init ... (TrivialRegisterPassable)`、`var _addr: Int`、`is_null()`）、
      `PGnotify` struct、enum 定数（下記「決めた事項」3 の全値、名前は `libpq-fe.h` と同じ）、`PG_DIAG_*` 18 定数、ポインタ型エイリアス（`CStr` / `OptCStr` / `MutCStr` / `MutRawPtr` / `CStrArray` / `OidPtr` / `IntPtr`）
    - `src/pq/_ffi/functions.mojo`: `LibpqFFI(Movable)` に **50 本**の thin 関数ポインタフィールド（「決めた事項」2 の表どおり。各行末に `# libpq-fe.h:<行>` コメント）、
      `__init__(out self, path: String) raises`（`OwnedDLHandle(path, RTLD.NOW | RTLD.GLOBAL | RTLD.NODELETE)` → 各シンボルを `_dl_sym[FT]`。欠損は `Error("missing symbol <name>")`）。
      `grep -c get_function src/pq/_ffi` = 0（P1）
    - `src/pq/_ffi/__init__.mojo`: モジュール docstring のみ（+ 再エクスポートは任意）。`src/pq/__init__.mojo` の docstring 先頭を大文字に直し `mojo precompile src/pq -o build/pq.mojoc` が**警告ゼロ**（P15）
    - `tests/test_ffi.mojo`（DB 不要。パスは `PQ_MOJO_LIBPQ` → `libpq.so.5`、現 `tests/test_smoke.mojo:8-15` と同じ決め方）: `LibpqFFI(path)` が構築できる、
      `OwnedDLHandle.check_symbol` で 50 名すべて True（名前リストを `List[String]` で持つ）、`PQlibVersion() >= 140000`、`size_of[PGnotify]() == 32`、
      enum 定数の代表値（`CONNECTION_OK==0`、`CONNECTION_BAD==1`、`PGRES_TUPLES_OK==2`、`PGRES_FATAL_ERROR==7`、`PQTRANS_INTRANS==2`、`PGRES_POLLING_OK==3`、`PGRES_TUPLES_CHUNK==12`）、
      `PGconnPtr(0).is_null()` が True。低レベル往復 1 本: `PQconnectdb(PQ_TEST_CONNINFO)` → `PQstatus==CONNECTION_OK` → `PQexec("SELECT 1")` → `PQresultStatus==PGRES_TUPLES_OK` → `PQclear` → `PQfinish`
      （これだけ DB 必須。到達不能なら失敗させる）
    - `tests/run_tests.sh`: `PQ_TEST_CONNINFO` が設定済みならその 1 本、未設定なら `host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test` と `port=54314` 版の 2 本を順に `export` して全 `tests/test_*.mojo` を回す（P20）。
      ファイルごとに `== <conninfo の host/port だけ> <file>` を出力し、失敗ファイルがあっても他を続行、最後に集約 exit（P19）。コメントに「`PQ_TEST_CONNINFO` は key=value 形式のみ（テストが ` password=...` を末尾に足す）」と書く
    - `tests/final_check.sh` + `pixi.toml` タスク `check = "bash tests/final_check.sh"`, `package = "mkdir -p build && mojo precompile src/pq -o build/pq.mojoc"`（P16。`.mojopkg` は 1.1.0 が拒否する — 「決めた事項」8）。
      final_check の手順と判定は「検証コマンド」節のとおり。各段のログを `build/final_check.log` に溜め、最後に `grep -c 'warning:'` が 0 でなければ exit 1。
      `examples/basic.mojo` が無い段階（T1〜T5）では examples 段をスキップせず**存在チェックで fail** させてよい（T6 で揃う）。T1 時点では `pixi run check` が examples 段で落ちることを PROGRESS に書く
    - `pixi run package` が exit 0 で `build/pq.mojoc` 生成、`pixi run test` で `test_errors` / `test_ffi` / 既存 `test_smoke` が両サーバーで PASS
  - 対象: `src/pq/errors.mojo`, `src/pq/_ffi/__init__.mojo`, `src/pq/_ffi/types.mojo`, `src/pq/_ffi/functions.mojo`, `src/pq/__init__.mojo`, `tests/test_errors.mojo`, `tests/test_ffi.mojo`, `tests/run_tests.sh`, `tests/final_check.sh`, `pixi.toml`
  - 依存: なし
  - 並列サブ作業:
    - A: `errors.mojo` + `tests/test_errors.mojo`（対象: `src/pq/errors.mojo`, `tests/test_errors.mojo`）
    - B: `_ffi/types.mojo` + `_ffi/functions.mojo` + `_ffi/__init__.mojo` + `tests/test_ffi.mojo`（対象: `src/pq/_ffi/*`, `tests/test_ffi.mojo`）
    - C: `run_tests.sh` 2 サーバー化 + `final_check.sh` + `pixi.toml` タスク + `src/pq/__init__.mojo` docstring 修正（対象: `tests/run_tests.sh`, `tests/final_check.sh`, `pixi.toml`, `src/pq/__init__.mojo`）

- [x] T2: `_ffi/loader.mojo`（`_Global` + `LoadState` + `libpq()`）、smoke / hello をローダー経由に書き換え、ロード失敗テスト
  - 完了基準:
    - `src/pq/_ffi/loader.mojo`: `_candidates() -> List[String]`（`PQ_MOJO_LIBPQ` があればそれ 1 本、無ければ Linux `libpq.so.5`, `libpq.so` / macOS `libpq.5.dylib`, `libpq.dylib`, `/opt/homebrew/opt/libpq/lib/libpq.5.dylib`, `/usr/local/opt/libpq/lib/libpq.5.dylib`）、
      `_open() -> LoadState`（非 raising。候補を順に `LibpqFFI(path)` → 成功したら `PQlibVersion() < 140000` なら失敗扱いにして次へ。全失敗で `error` に「`libpq not found. tried: <path>: <原因>; ...`」）、
      `comptime _STATE = _Global["pq_libpq", _open]`、`libpq_ptr() raises PgError -> Pointer[LibpqFFI, MutUntrackedOrigin]`、`libpq() raises PgError -> ref[MutUntrackedOrigin] LibpqFFI`（`PgError(kind=LIBPQ_LOAD, message=error)`。`get_or_create_ptr` の `Error` も LIBPQ_LOAD に変換）（P1 / P2）
    - `tests/test_smoke.mojo`: 自前の探索ロジックを消し `from pq._ffi.loader import libpq` を使う。`libpq()` を 2 回呼んで同じ `PQlibVersion` が返る（1 ハンドル）。`check_symbol` の自前 `OwnedDLHandle` 生成は削除
    - `examples/hello_libpq.mojo`: `libpq()` 経由で `PQlibVersion` を表示（`pixi.toml` の `hello-libpq` / `build` タスクに `-I src` を付ける）
    - `tests/test_loader_fail.mojo`（専用ファイル。P2 / P19）: `main` の最初で `setenv("PQ_MOJO_LIBPQ", "/nonexistent/dir/libpq.so.5", True)` → `libpq()` が `PgError` で `kind == LIBPQ_LOAD` かつ `message` に `/nonexistent/dir/libpq.so.5` を含む。
      2 回目の `libpq()` も同じ kind（失敗結果がキャッシュされて再ロードしない）。トレースバック無しで PASS
    - `pixi run test` が両サーバーで PASS（`test_loader_fail` は DB 不要）。`pixi run package` 警告ゼロ
  - 対象: `src/pq/_ffi/loader.mojo`, `src/pq/_ffi/__init__.mojo`, `tests/test_smoke.mojo`, `tests/test_loader_fail.mojo`, `examples/hello_libpq.mojo`, `pixi.toml`
  - 依存: T1
  - 並列サブ作業:
    - A: `loader.mojo` + `test_smoke.mojo` 書き換え + `hello_libpq.mojo` + `pixi.toml`（対象: `src/pq/_ffi/loader.mojo`, `src/pq/_ffi/__init__.mojo`, `tests/test_smoke.mojo`, `examples/hello_libpq.mojo`, `pixi.toml`）
    - B: `tests/test_loader_fail.mojo`（契約: `from pq._ffi.loader import libpq`、`from pq.errors import PgError, PgErrorKind`、失敗は `kind == PgErrorKind.LIBPQ_LOAD`）（対象: `tests/test_loader_fail.mojo`）

- [x] T3: `decode_text.mojo`（型スイッチ `decode_text[T]` + bytea hex + 範囲チェック）と DB 不要の境界値テスト
  - 完了基準:
    - `src/pq/decode_text.mojo`: OID 定数（`OID_BOOL=16, OID_BYTEA=17, OID_NAME=19, OID_INT8=20, OID_INT2=21, OID_INT4=23, OID_TEXT=25, OID_FLOAT4=700, OID_FLOAT8=701, OID_BPCHAR=1042, OID_VARCHAR=1043`）、
      `decode_text[T: Copyable](text: String, oid: UInt32) raises PgError -> T`（「決めた事項」5 の表。非対応 T は `comptime assert False`）、`parse_bytea_hex(text) raises PgError -> List[UInt8]`
    - `tests/test_decode_text.mojo`（DB 不要）に少なくとも: Bool `t`/`f`/`true`(→TypeMismatch)/OID 23 で Bool(→TypeMismatch)；Int16 `32767`/`-32768`/`32768`(→TypeMismatch)；Int32 `2147483647`/`-2147483648`/`2147483648`(→TypeMismatch)/OID 21 で Int32(→TypeMismatch、拡幅不可)；
      Int64 と Int の `9223372036854775807`/`-9223372036854775808`；`abc`/``/`1.5` を Int32(→TypeMismatch)；Float32/Float64 `1.5`/`NaN`(isnan)/`Infinity`/`-Infinity`(isinf)/`abc`(→TypeMismatch)/OID 700 で Float64(→TypeMismatch)；
      String を OID 25/1043/1042/19/1700/16 で（任意 OID でそのまま）；bytea `\x`→[]/`\x0102`→[1,2]/`\xDEADbeef`→[0xDE,0xAD,0xBE,0xEF]/`\x012`(奇数)→TypeMismatch/`\xzz`→TypeMismatch/`abc`(先頭 `\x` 無し)→TypeMismatch/`\\000`(escape 形式)→TypeMismatch/OID 25 で List[UInt8](→TypeMismatch)（P10 / P11 / P12）
    - 全 TypeMismatch の message に期待型名（`int4` 等）と入力テキストを含む（デバッグ用）。`pixi run package` 警告ゼロ
  - 対象: `src/pq/decode_text.mojo`, `tests/test_decode_text.mojo`
  - 依存: T1（`PgError`）
  - 並列サブ作業:
    - A: `decode_text.mojo`（対象: `src/pq/decode_text.mojo`）
    - B: `tests/test_decode_text.mojo` を「決めた事項」5 の表から独立に書く（契約: `from pq.decode_text import decode_text, parse_bytea_hex`、OID 不一致・パース失敗は `kind == TYPE_MISMATCH`）（対象: `tests/test_decode_text.mojo`）

- [x] T4: `Connection`（open ×2 / execute / deinit）+ `Result` 本体（所有・メタデータ）+ 接続・実行の異常系テスト
  - 完了基準:
    - `src/pq/connection.mojo` `struct Connection(Movable)`: `_conn: PGconnPtr`, `_pq: Pointer[LibpqFFI, MutUntrackedOrigin]`。
      `@staticmethod open(var conninfo: String) raises PgError -> Connection`（`PQconnectdb`）、`@staticmethod open(params: Dict[String, String]) raises PgError -> Connection`（`PQconnectdbParams`, `expand_dbname=0`。P6: 値は `var` の所有コピーで `as_c_string_span()` し、呼び出し後まで生存）。
      どちらも `PGconnPtr.is_null()` → `PgError(CONNECTION, "PQconnectdb returned NULL (out of memory)")`、`PQstatus != CONNECTION_OK` → `PQerrorMessage` を `String` にコピー → `PQfinish` → `PgError(CONNECTION, msg)`（P3 / P21。conninfo / params をメッセージに入れない）。
      `execute(self, var sql: String) raises PgError -> Result`（「決めた事項」6 の状態→エラー表。P4 / P5）、`__deinit__(deinit self)` で `_conn` 非 NULL なら `PQfinish`
    - `src/pq/result.mojo` `struct Result(Movable, Sized)`（Iterable は T5）: `_res: PGresultPtr`, `_pq`, `_nrows`, `_ncols` をキャッシュ。`__init__(out self, res: PGresultPtr, pq: Pointer[...])`、`__deinit__` で `PQclear`、
      `row_count()`, `column_count()`, `__len__()`（= row_count）、`column_name(i) raises PgError -> String`、`column_index(name) raises PgError -> Int`（`PQfnumber`、-1 なら `PgError(TYPE_MISMATCH, 'column "<name>" does not exist')`。docstring に小文字化規則 P7）、
      `column_type_oid(i) raises PgError -> UInt32`、`affected_rows() -> Int`（`PQcmdTuples` が空なら 0）、内部 `_check_cell(row, col) raises PgError`（範囲外は `PgError(TYPE_MISMATCH, "row index N out of range (0..M)")` / 列も同様。P8）、
      `_is_null(row, col) -> Bool`、`_text(row, col) -> String`（`PQgetvalue` を即コピー。NULL ポインタなら TYPE_MISMATCH）
    - `tests/test_connection.mojo`（PQ_TEST_CONNINFO 必須）に少なくとも: 正常 open → `execute("SELECT 1")` の `row_count()==1` / `column_count()==1`；誤パスワード（conninfo 末尾に ` password=WRONG_pw_123` を足す）→ `kind==CONNECTION` かつ message に `WRONG_pw_123` を含まない（P21。Dict 版でも同じ）；
      到達不能 Dict `{host:127.0.0.1, port:1, connect_timeout:1}` → CONNECTION；Dict 版正常（conninfo を空白と `=` で分解した Dict）に `application_name` = **63 バイト**を足して `SELECT current_setting('application_name')` が一致（P6、SSO 超え。
      **PLAN 訂正（turn 6 実測）**: 元は「100 文字」だったが PostgreSQL は `application_name` を NAMEDATALEN-1 = 63 バイトに切り詰め `NOTICE: identifier ... will be truncated` を吐くので 100 文字での一致は原理的に成立しない。
      63 バイトなら切り詰めが起きず完全一致で検査でき、NOTICE もログに出ない。SSO 境界（23 バイト）は 63 でも十分超える）；
      構文エラー `SELEC 1` → `kind==SERVER`, `sqlstate=="42601"`, `severity=="ERROR"`, `position=="1"`, message に `syntax error`；空文字 / `"   "` → `kind==SERVER`, `message=="empty query"`；複数文 `CREATE TEMP TABLE t(x int); INSERT INTO t VALUES (1),(2)` → `affected_rows()==2`；
      複数文の途中失敗 `SELECT 1; SELEC 2; SELECT 3` → SERVER 42601；`SELECT pg_terminate_backend(pg_backend_pid())` → 1 回目の execute は `PgError` で **`kind==SERVER` かつ `sqlstate==""` かつ message に `server closed the connection unexpectedly`**、
      **2 回目の execute は `kind==CONNECTION`** かつ message 非空、クラッシュしない（P4 の「サーバー停止後」代替）。
      **PLAN 訂正（turn 6 実測、PG14 / PG17 同一）**: 元は「SERVER なら sqlstate `57P01`、CONNECTION でも可」という未検証の期待だったが、libpq は FATAL 57P01 を**一度も届けない**（ソケットが先に閉じる）。
      `PQexec` はクライアント側生成の `PGRES_FATAL_ERROR`（sqlstate 空）を返すので、決めた事項 6 の表どおり SERVER に分類される。2 回目が CONNECTION になるので P4 の設計自体は成立。
      **verify への申し送り**: 「結果に sqlstate が無く `PQstatus` が `CONNECTION_BAD` なら CONNECTION に寄せる」という分類規則の追加は決めた事項 6 に触るので本ターンでは実装していない（kind の意味としては CONNECTION の方が正しいという指摘）；
      `var r = conn.execute(...)` の後 `conn` を使わず `_ = conn^` で先に破棄しても `r.row_count()` が読める（P18）；0 行の `SELECT 1 WHERE false` で `row_count()==0`、`column_index("nope")` → TYPE_MISMATCH、`column_name(5)` → TYPE_MISMATCH、`column_name(-1)` → TYPE_MISMATCH、stderr に libpq の `out of range` が出ない（目視ではなくテストが先に弾くので出ない）
    - 負のコンパイル確認（run_tests 外）: `.gsd-lite/logs/phase1-sync-text-basic/scratch/turn-NNN-neg-copy.mojo` で `var c2 = c1`（Connection のコピー）がコンパイルエラーになることを `mojo run` で確かめ、結果を PROGRESS に書く（P3）。`tests/test_connection.mojo` にコメントで同じことを記録
    - `pixi run test` 両サーバー PASS、`pixi run package` 警告ゼロ
  - 対象: `src/pq/connection.mojo`, `src/pq/result.mojo`, `tests/test_connection.mojo`
  - 依存: T2, T3
  - 並列サブ作業:
    - A: `connection.mojo`（対象: `src/pq/connection.mojo`。契約: 「決めた事項」6 のエラー表を必ず満たす。conninfo / params をメッセージに**一切**入れない）
    - B: `result.mojo` 本体（対象: `src/pq/result.mojo`。契約: 範囲外は libpq を呼ぶ前に `PgError(TYPE_MISMATCH)`。`PQgetvalue` の戻りは即 `String` にコピー）
    - C: `tests/test_connection.mojo` を上の箇条書きから独立に書く（対象: `tests/test_connection.mojo`）

- [x] T5: `Row` / `RowIter`（`__getitem__` / `for row in result` / `get[T]` / `get_optional[T]`、index と列名）+ 受け入れクエリと型取得テスト
  - 完了基準:
    - `src/pq/result.mojo`: `Result` に `Iterable` を足し `comptime IteratorType[...]` / `__getitem__(ref self, i: Int) raises PgError -> Row[origin_of(self)]` / `__iter__(ref self)`（RESEARCH §2.3 のコード片どおり）。
      `struct Row[origin: ImmOrigin](Copyable)`: `get[T: Copyable](self, col: Int) raises PgError -> T`、`get[T: Copyable](self, col: String) raises PgError -> T`（`column_index` 経由）、`get_optional[T: Copyable](self, col: Int|String) raises PgError -> Optional[T]`、`is_null(col: Int) raises PgError -> Bool`。
      `get`: `_check_cell` → `_is_null` なら `PgError(NULL_VALUE, "column <i> is NULL")` → `decode_text[T](_text(...), column_type_oid(col))`（P9）。`struct RowIter[origin: ImmOrigin](Iterator)` の `__next__ raises StopIteration`
    - `tests/test_result.mojo` に少なくとも: 受け入れクエリ `SELECT 1::int4, 'a'::text, NULL::int4, true, 1.5::float8, '\x0102'::bytea` → `get[Int32](0)==1`, `get[String](1)=="a"`, `get[Int32](2)` → NULL_VALUE, `get_optional[Int32](2)` が None, `get[Bool](3)==True`, `get[Float64](4)==1.5`, `get[List[UInt8]](5)==[1,2]`、`column_type_oid` が 23/25/23/16/701/17；
      `SELECT NULL::text, ''::text` → `get_optional[String]` が None / Some("")（P9）；`SELECT 1 AS FOO, 2 AS "BAR"` → `column_index("FOO")==0`, `("foo")==0`, `("BAR")` → TYPE_MISMATCH, `("\"BAR\"")==1`, `get[Int32]("foo")==1`（P7）；
      `SELECT 1::int2, 1::int8, 1.5::float4, 'x'::varchar, 'ab'::char(5), 'n'::name, 12.5::numeric` → Int16 / Int64 と Int / Float32 / String ×3（OID 1043/1042/19）/ `get[String]` で `"12.5"`、`get[Float64](6)`（numeric）→ TYPE_MISMATCH、`get[Int32](0)`（int2 を Int32）→ TYPE_MISMATCH；
      `SELECT 'NaN'::float8, 'Infinity'::float4, '-Infinity'::float8`（P11）；`SET bytea_output = 'escape'` 後に `SELECT '\x00'::bytea` → TYPE_MISMATCH（P12）；`SELECT 2147483647::int4, (-2147483648)::int4, 32767::int2, (-32768)::int2`（P10。
      **PLAN 訂正（turn 7 実測）**: 元は括弧なしの `-2147483648::int4` / `-32768::int2` だったが、`::` は単項マイナスより強く束縛するので
      正の `2147483648` を先に int4 にキャストして `ERROR: integer out of range`（int2 側は `smallint out of range`）になり、クエリ自体が通らない。括弧が必須）；
      `SELECT generate_series(1, 5)` を `for row in res` で合計 15、`len(res)==5`、`res[4].get[Int32](0)==5`、`res[5]` → TYPE_MISMATCH、`res[-1]` → TYPE_MISMATCH、`res[0].get[Int32](1)` → TYPE_MISMATCH；0 行の結果で `for` が 0 回
    - 負のコンパイル確認（run_tests 外、scratch）: `Result` を **`var moved = res^`** で移動した後に `row.get[...]` を使う → origin エラーでコンパイル失敗を確認し PROGRESS に書く（P5 / REQ §5.2 の「長生きする参照を返さない」）。
      **PLAN 訂正（turn 7 実測）**: 元は `_ = res^` で破棄する形だったが、Mojo 1.1.0 の `_ = x^` は**寿命を終わらせない**（`_ = result^` の後でも `result.row_count()` がコンパイルも実行もできる）。
      ASAP 破棄を防ぐ「生存マーカー」であってデストラクタ呼び出しではない（`tests/test_*.mojo` の `_ = conn^` / `_ = result^` がこの用途）。
      借用の検査を踏ませるには名前付きの移動が必要で、その形なら `row.get` の行に `error: use of uninitialized value 'result'` が出る
    - `pixi run test` 両サーバー PASS、`pixi run package` 警告ゼロ
  - 対象: `src/pq/result.mojo`, `tests/test_result.mojo`
  - 依存: T4
  - 並列サブ作業:
    - A: `result.mojo` の Row / RowIter / Iterable（対象: `src/pq/result.mojo`）
    - B: `tests/test_result.mojo` を上の箇条書きから独立に書く（契約: NULL は `NULL_VALUE`、OID 不一致・範囲外・列名無しは `TYPE_MISMATCH`）（対象: `tests/test_result.mojo`）

- [x] T6: `escape_literal` / `escape_identifier` / `server_version` / `status` / `transaction_status` + `examples/basic.mojo` + 公開 API の再エクスポート
  - 完了基準:
    - `src/pq/connection.mojo`: `escape_literal(self, var s: String) raises PgError -> String` / `escape_identifier(...)`（`PQescapeLiteral(conn, ptr, c_size_t(byte_length))`。NULL 戻り → `PgError(SERVER, PQerrorMessage(conn))`。非 NULL → `String` にコピー → `PQfreemem` の順、各メソッド 1 箇所。P13 / P14）、
      `server_version(self) -> Int`、`status(self) -> Int`（`CONNECTION_*` と比較）、`transaction_status(self) -> Int`（`PQTRANS_*` と比較）
    - `tests/test_connection.mojo` に追記: `escape_literal("O'Reilly") == "'O''Reilly'"`、`escape_literal("a\\b")` が ` E'` で始まる（先頭空白 + E。P13）、`escape_identifier("x\"y") == "\"x\"\"y\""`、`server_version() >= 140000`、`status() == CONNECTION_OK`、
      `transaction_status()`: 直後 `PQTRANS_IDLE` → `BEGIN` 後 `PQTRANS_INTRANS` → `SELEC 1` 失敗後 `PQTRANS_INERROR` → `ROLLBACK` 後 `PQTRANS_IDLE`
    - `src/pq/__init__.mojo`: `Connection`, `Result`, `Row`, `PgError`, `PgErrorKind`, `CONNECTION_OK`, `CONNECTION_BAD`, `PQTRANS_IDLE`, `PQTRANS_ACTIVE`, `PQTRANS_INTRANS`, `PQTRANS_INERROR`, `PQTRANS_UNKNOWN` を再エクスポート。docstring に型マッピング表（REQ §4.5）と `PgErrorKind` 一覧
    - `examples/basic.mojo`: `from pq import Connection, PgError` のみ使用。`PQ_TEST_CONNINFO`（無ければ 54317 既定）で接続 → `SELECT 1::int4 AS n, 'hello'::text AS s, NULL::text AS z` → `for row in res` で `get[Int32]("n")` / `get[String]("s")` / `get_optional[String]("z")` を表示。`PgError` を `except e` で捕捉して `print` し非 0 で終了。
      `pixi.toml` に `example-basic = "mojo run -I src examples/basic.mojo"`。`tests/final_check.sh` の examples 段がこれを実行
    - `pixi run example-basic` exit 0、`pixi run test` 両サーバー PASS、`pixi run package` 警告ゼロ、`pixi run check` が通る（ここで初めて全段そろう）
  - 対象: `src/pq/connection.mojo`, `src/pq/__init__.mojo`, `tests/test_connection.mojo`, `examples/basic.mojo`, `pixi.toml`, `tests/final_check.sh`
  - 依存: T5
  - 並列サブ作業:
    - A: `connection.mojo` の 5 メソッド + `tests/test_connection.mojo` 追記（対象: `src/pq/connection.mojo`, `tests/test_connection.mojo`）
    - B: `examples/basic.mojo` + `pixi.toml` + `src/pq/__init__.mojo` 再エクスポート（対象: `examples/basic.mojo`, `pixi.toml`, `src/pq/__init__.mojo`, `tests/final_check.sh`）

- [x] T7: リークテスト `tests/test_leak.mojo`（10,000 回 connect/query/close + 異常系ループ + 判定ロジック単体テスト、macOS skip）
  - 完了基準:
    - `rss_pages() raises -> Int`（`/proc/self/statm` の 2 番目。RESEARCH probe-leak `rss_pages()` と同じ）
    - 判定関数 `is_leaking(samples: List[Int], tolerance_pages: Int) -> Bool` = 「全隣接差分が > 0（単調増加）」**または**「`samples[-1] - samples[0] > tolerance_pages`」。単体テスト: `[100,101,102,103]` → True、`[100,100,101,100]` → False、`[100,100,100,120]`（tolerance 16）→ True、`[100,100,100,100]` → False
    - 本体（Linux のみ。macOS は `print("SKIP: RSS sampling is Linux-only")` して PASS）: `Connection.open(conninfo)` → `execute("SELECT 1")` → 破棄 を **10,000 回**。最初の 1,000 回はウォームアップ、以降 1,000 回ごとに `rss_pages()` を記録（9 サンプル）→ `is_leaking(samples, 16)` が False（P17。所要 ≈ 35 s/サーバー）。
      異常系: 誤パスワード `open` 失敗 ×1,000（200 回ウォームアップ後 4 サンプル、tolerance 16）→ False（P3）；`escape_literal("O'Reilly")` ×1,000（同様）→ False（P14）；`execute("SELEC 1")` 失敗 ×1,000 → False（失敗経路の `PQclear`）
    - `pixi run test` 両サーバー PASS。`run_tests.sh` のログに所要時間が分かる出力（開始・終了の `date` 等）があると verify が助かる（任意）
  - 対象: `tests/test_leak.mojo`
  - 依存: T6
  - 並列サブ作業: なし

- [ ] T8: 品質仕上げ: docstring 診断ゼロ / `mojo format` 差分ゼロ / 警告ゼロ / `pixi run check` 両サーバー緑 / 追従先チェックリスト照合
  - 完了基準:
    - `mojo precompile --diagnose-missing-doc-strings src/pq -o build/pq.mojoc 2>&1 | grep -v '/_ffi/' | grep -vE "'(__init__|__deinit__|__copyinit__|__moveinit__)'" | grep -c 'doc string'` = 0（`pq` 直下の公開 struct / メソッド / 関数すべて。`_ffi` はモジュール docstring のみでよい）
      **合成 dunder を除外する理由**（T1 で実測。元の PLAN は除外なしで「= 0」だったが達成不可能だった）: `--diagnose-missing-doc-strings` は
      コンパイラが合成する `__init__` / `__deinit__` / `__copyinit__` / `__moveinit__` を **struct 宣言行**に対して報告する。docstring を付ける場所が無く、
      実際に `PgError` は明示 `__init__`（docstring 付き）を持つのに合成のコピー / ムーブ分で 2 件報告される。判定は `tests/final_check.sh` 3/6 段に同じ除外で実装済み。
      既知の盲点: 手書きで docstring の無い `__init__` もこの除外に引っかかる（struct docstring で代替する規約とする）
    - `pixi run fmt` 実行後 `git diff --quiet -- src tests examples hello.mojo` が exit 0
    - `rg -n '^\s*fn ' src tests examples hello.mojo` が 0 件（REQ §5.1「`fn` を使わない。`def` + 明示 `raises`」）
    - `pixi run check` が exit 0（両サーバー、`build/final_check.log` に `warning:` 0 件）。ログの要約（各段の結果と所要時間）を PROGRESS に書く
    - 追従先チェックリストの全行を実行して結果を PROGRESS に書く（特に 50 本の一致、`get_function` 0 件、`PQfreemem` 2 箇所）
    - `Connection.execute` の docstring に「複数文は最後の文の結果を返し、途中の失敗はそのエラー」（D9）、`Result.column_index` / `Row.get(name)` の docstring に `PQfnumber` の小文字化規則（P7）、`escape_literal` の docstring に ` E'...'` 形式の例（P13）があることを `rg` で確認
    - 既存の `HANDOFF.md` は触らない（README 整備は Phase 5 / 対象外）
  - 対象: `src/pq/*.mojo`, `tests/*.mojo`, `examples/*.mojo`（docstring・整形のみ。挙動変更なし）
  - 依存: T7
  - 並列サブ作業: なし（整形は全ファイルに当たるので分けない）

## 決めた事項

1. **ファイル構成**（HANDOFF §4 の案から Phase 1 分だけ。`value.mojo` / `params.mojo` / `_platform` は作らない）:
   `src/pq/{__init__,errors,decode_text,connection,result}.mojo`、`src/pq/_ffi/{__init__,types,functions,loader}.mojo`、
   `tests/{run_tests.sh,final_check.sh,test_errors,test_ffi,test_smoke,test_loader_fail,test_decode_text,test_connection,test_result,test_leak}`、`examples/{hello_libpq,basic}.mojo`
   （根拠: REQ §2、HANDOFF.md:84-112）
2. **`LibpqFFI` の 50 本**（HANDOFF.md:135-143 の表 = `libpq-fe.h` の `grep` で 50 行。型は `.pixi/envs/default/include/libpq-fe.h` の行番号を併記）。
   エイリアス: `CStr = Pointer[c_char, ImmUntrackedOrigin]`, `OptCStr = OptionalPointer[c_char, ImmUntrackedOrigin]`, `MutCStr = Pointer[c_char, MutUntrackedOrigin]`,
   `MutRawPtr = Pointer[NoneType, MutUntrackedOrigin]`, `CStrArray = Pointer[Int, ImmUntrackedOrigin]`（`const char* const*`: 要素は C 文字列のアドレス、末尾 0）, `OidPtr = Pointer[UInt32, ImmUntrackedOrigin]`, `IntPtr = Pointer[c_int, ImmUntrackedOrigin]`。
   すべて `def(...) thin abi("C") -> R` 型のフィールド（RESEARCH §2.1 probe-global / probe-loader で検証済みの形）:

   | 関数 | Mojo シグネチャ（引数 → 戻り） | libpq-fe.h |
   |---|---|---|
   | PQconnectdb | `(CStr) -> PGconnPtr` | 331 |
   | PQconnectdbParams | `(CStrArray, CStrArray, c_int) -> PGconnPtr` | 332 |
   | PQfinish | `(PGconnPtr) -> None` | 343 |
   | PQreset | `(PGconnPtr) -> None` | 366 |
   | PQstatus | `(PGconnPtr) -> c_int` | 407 |
   | PQerrorMessage | `(PGconnPtr) -> CStr` | 414 |
   | PQserverVersion | `(PGconnPtr) -> c_int` | 413 |
   | PQparameterStatus | `(PGconnPtr, CStr) -> OptCStr` | 409 |
   | PQtransactionStatus | `(PGconnPtr) -> c_int` | 408 |
   | PQlibVersion | `() -> c_int` | 709 |
   | PQexec | `(PGconnPtr, CStr) -> PGresultPtr` | 486 |
   | PQexecParams | `(PGconnPtr, CStr, c_int, OidPtr, CStrArray, IntPtr, IntPtr, c_int) -> PGresultPtr` | 487-494 |
   | PQprepare | `(PGconnPtr, CStr, CStr, c_int, OidPtr) -> PGresultPtr` | 495-497 |
   | PQexecPrepared | `(PGconnPtr, CStr, c_int, CStrArray, IntPtr, IntPtr, c_int) -> PGresultPtr` | 498-504 |
   | PQdescribePrepared | `(PGconnPtr, CStr) -> PGresultPtr` | 611 |
   | PQresultStatus | `(PGresultPtr) -> c_int` | 582 |
   | PQresultErrorMessage | `(PGresultPtr) -> CStr` | 584 |
   | PQresultErrorField | `(PGresultPtr, c_int) -> OptCStr` | 588 |
   | PQntuples / PQnfields | `(PGresultPtr) -> c_int` | 589 / 590 |
   | PQfname | `(PGresultPtr, c_int) -> OptCStr`（範囲外で NULL） | 592 |
   | PQfnumber | `(PGresultPtr, CStr) -> c_int` | 593 |
   | PQftype | `(PGresultPtr, c_int) -> UInt32` | 597 |
   | PQfformat / PQfmod | `(PGresultPtr, c_int) -> c_int` | 596 / 599 |
   | PQgetvalue | `(PGresultPtr, c_int, c_int) -> OptCStr`（範囲外で NULL。値 NULL は `""`） | 604 |
   | PQgetlength / PQgetisnull | `(PGresultPtr, c_int, c_int) -> c_int` | 605 / 606 |
   | PQcmdTuples | `(PGresultPtr) -> CStr` | 603 |
   | PQclear | `(PGresultPtr) -> None` | 623 |
   | PQescapeLiteral / PQescapeIdentifier | `(PGconnPtr, CStr, c_size_t) -> OptCStr` | 647 / 648 |
   | PQfreemem | `(MutRawPtr) -> None` | 626 |
   | PQconnectStartParams | `(CStrArray, CStrArray, c_int) -> PGconnPtr` | 326-327 |
   | PQconnectPoll | `(PGconnPtr) -> c_int` | 328 |
   | PQsocket | `(PGconnPtr) -> c_int` | 415 |
   | PQsetnonblocking | `(PGconnPtr, c_int) -> c_int` | 559 |
   | PQisnonblocking | `(PGconnPtr) -> c_int` | 560 |
   | PQsendQuery | `(PGconnPtr, CStr) -> c_int` | 509 |
   | PQsendQueryParams | `(PGconnPtr, CStr, c_int, OidPtr, CStrArray, IntPtr, IntPtr, c_int) -> c_int` | 510-517 |
   | PQsendPrepare | `(PGconnPtr, CStr, CStr, c_int, OidPtr) -> c_int` | 518-520 |
   | PQsendQueryPrepared | `(PGconnPtr, CStr, c_int, CStrArray, IntPtr, IntPtr, c_int) -> c_int` | 521-527 |
   | PQflush / PQconsumeInput / PQisBusy | `(PGconnPtr) -> c_int` | 567 / 534 / 533 |
   | PQgetResult | `(PGconnPtr) -> PGresultPtr` | 530 |
   | PQgetCancel | `(PGconnPtr) -> PGcancelPtr` | 387 |
   | PQcancel | `(PGcancelPtr, MutCStr, c_int) -> c_int` | 393 |
   | PQfreeCancel | `(PGcancelPtr) -> None` | 390 |
   | PQnotifies | `(PGconnPtr) -> PGnotifyPtr` | 544 |

   NULL になり得る `char*` 戻り（`OptCStr`）: PQresultErrorField / PQescapeLiteral / PQescapeIdentifier / PQparameterStatus / PQfname / PQgetvalue。
   ならないもの（`CStr`）: PQerrorMessage / PQresultErrorMessage / PQcmdTuples（libpq は `res` が無くても `""` を返す）。
   RESEARCH §2.1 は PQfname / PQgetvalue を非 NULL 扱いにしていたが、libpq は範囲外 index で NULL を返すので `OptCStr` に変更（高レベル層は先に範囲検査するので実際には NULL を見ない。保険として `TYPE_MISMATCH` にする）
3. **enum 定数**（`libpq-fe.h:82-152` から抽出。名前は libpq と同一、型は `c_int`、`_ffi/types.mojo` のモジュールレベル `comptime`）:
   `CONNECTION_OK=0, CONNECTION_BAD=1, CONNECTION_STARTED=2, CONNECTION_MADE=3, CONNECTION_AWAITING_RESPONSE=4, CONNECTION_AUTH_OK=5, CONNECTION_SETENV=6, CONNECTION_SSL_STARTUP=7, CONNECTION_NEEDED=8, CONNECTION_CHECK_WRITABLE=9, CONNECTION_CONSUME=10, CONNECTION_GSS_STARTUP=11, CONNECTION_CHECK_TARGET=12, CONNECTION_CHECK_STANDBY=13, CONNECTION_ALLOCATED=14, CONNECTION_AUTHENTICATING=15`；
   `PGRES_POLLING_FAILED=0, PGRES_POLLING_READING=1, PGRES_POLLING_WRITING=2, PGRES_POLLING_OK=3, PGRES_POLLING_ACTIVE=4`；
   `PGRES_EMPTY_QUERY=0, PGRES_COMMAND_OK=1, PGRES_TUPLES_OK=2, PGRES_COPY_OUT=3, PGRES_COPY_IN=4, PGRES_BAD_RESPONSE=5, PGRES_NONFATAL_ERROR=6, PGRES_FATAL_ERROR=7, PGRES_COPY_BOTH=8, PGRES_SINGLE_TUPLE=9, PGRES_PIPELINE_SYNC=10, PGRES_PIPELINE_ABORTED=11, PGRES_TUPLES_CHUNK=12`；
   `PQTRANS_IDLE=0, PQTRANS_ACTIVE=1, PQTRANS_INTRANS=2, PQTRANS_INERROR=3, PQTRANS_UNKNOWN=4`。
   `PG_DIAG_*`（`postgres_ext.h:55-72`、値は `c_int(ord(ch))`）: SEVERITY 'S', SEVERITY_NONLOCALIZED 'V', SQLSTATE 'C', MESSAGE_PRIMARY 'M', MESSAGE_DETAIL 'D', MESSAGE_HINT 'H', STATEMENT_POSITION 'P', INTERNAL_POSITION 'p', INTERNAL_QUERY 'q', CONTEXT 'W', SCHEMA_NAME 's', TABLE_NAME 't', COLUMN_NAME 'c', DATATYPE_NAME 'd', CONSTRAINT_NAME 'n', SOURCE_FILE 'F', SOURCE_LINE 'L', SOURCE_FUNCTION 'R'。
   `PGnotify`（`libpq-fe.h:228-235`）: `@fieldwise_init struct PGnotify(TrivialRegisterPassable): var relname: Int; var be_pid: c_int; var extra: Int; var next: Int`、`size_of[PGnotify]() == 32` をテスト
4. **`PgErrorKind`**: `@fieldwise_init struct PgErrorKind(TrivialRegisterPassable, Equatable, Writable): var value: Int` と struct 内 `comptime LIBPQ_LOAD = Self(0)`, `CONNECTION = Self(1)`, `SERVER = Self(2)`, `NULL_VALUE = Self(3)`, `TYPE_MISMATCH = Self(4)`。
   `write_to` は名前（`LibpqLoad` / `Connection` / `Server` / `NullValue` / `TypeMismatch`）を書く。struct 内 `comptime X = Self(n)` が 1.1.0 で通らなければ `errors.mojo` のモジュールレベル `comptime` 定数（`KIND_LIBPQ_LOAD` 等）にフォールバックし PROGRESS に書く。
   `PgError(Copyable, Writable)` の `write_to` は `PgError(kind=Server, sqlstate=42601, message=...)` 形式（sqlstate が空なら省略）。（根拠: REQ §4.4、D3、probe-lang / probe-iter の `PgError(Copyable, Writable)`）
5. **`Row.get[T]` は trait 式ではなく `comptime if` 型スイッチ**（D8 のフォールバック判断。理由: Mojo 1.1.0 に `extension` 構文が無く組み込み型に `FromPgText` を後付けできない — RESEARCH §2.3 probe-lang。型パラメータ式 API 自体は保てるので型別 getter にはしない）。
   `decode_text[T: Copyable](text: String, oid: UInt32) raises PgError -> T` の表:

   | T | 受け付ける OID | 変換 | TypeMismatch 条件 |
   |---|---|---|---|
   | `Bool` | 16 | `"t"`→True / `"f"`→False | それ以外の文字列 |
   | `Int16` | 21 | `atol` → 範囲 -32768..32767 | `atol` 失敗 / 範囲外 |
   | `Int32` | 23 | `atol` → 範囲 -2147483648..2147483647 | 同上 |
   | `Int64`, `Int` | 20 | `atol` | `atol` 失敗 |
   | `Float32` | 700 | `Float32(atof(text))` | `atof` 失敗 |
   | `Float64` | 701 | `atof` | `atof` 失敗 |
   | `String` | **任意** | そのまま | なし |
   | `List[UInt8]` | 17 | `parse_bytea_hex`: 先頭 `\x`、残り偶数長、各桁 hex | 先頭が `\x` でない / 奇数長 / 非 hex |
   | その他 | — | `comptime assert False, "unsupported type for Row.get"` | — |

   OID 不一致は変換前に `PgError(TYPE_MISMATCH, "column is <oid> but <T の PG 名> was requested")`。`rebind[T](v).copy()` で返す（probe-lang）。拡幅不可（D10）
6. **`Connection.execute` の状態→エラー表**（REQ §4.3、D9、RESEARCH §3）:

   | `PQexec` の結果 | 処理 |
   |---|---|
   | `PGresultPtr.is_null()` | `PgError(CONNECTION, PQerrorMessage(conn) をコピー)`。`PQclear` は呼ばない |
   | `PGRES_TUPLES_OK` / `PGRES_COMMAND_OK` | `Result` を返す（所有権移動） |
   | `PGRES_EMPTY_QUERY` | `PQclear` → `PgError(SERVER, "empty query")`（他フィールド空） |
   | それ以外（FATAL_ERROR / NONFATAL_ERROR / BAD_RESPONSE / COPY_* / …） | `PQresultErrorField` で `severity`('V' があれば 'V'、無ければ 'S') / `sqlstate`('C') / `message`('M'、NULL なら `PQresultErrorMessage`、それも空なら `"unexpected result status <n>"`) / `detail`('D') / `hint`('H') / `position`('P') / `context`('W') を**全部 `String` にコピーしてから** `PQclear` → `PgError(SERVER, ...)` |

   複数文は libpq どおり最後の文の結果（docstring に明記）。
7. **存在しない列名 / 範囲外 index の kind は `TYPE_MISMATCH`**（REQ §4.4 の kind 集合は固定で 6 つ目を足せない。サーバーは関与しないので `SERVER` は誤解を招く。
   「要求した形が結果と合わない」クラスとして TypeMismatch に寄せる。message: `column "<name>" does not exist` / `column index <i> out of range (0..<n-1>)` / `row index <i> out of range (0..<n-1>)`。RESEARCH §6-5 の「plan で決める」項目）
8. **`pixi run package` = `mojo precompile src/pq -o build/pq.mojoc`**（REQ §5.1b の `mojo package ... -o build/pq.mojopkg` は 1.1.0 で不可能: `mojo package` は非推奨、`precompile -o x.mojopkg` は `error: output path must have a '.mojoc' extension` — plan 時に実測。
   D11 の目的「パッケージビルドが通ることを機械判定」は `.mojoc` で満たす。`.gitignore` は `build/` 済みで変更不要）
9. **ハンドルの共有**: `Connection` / `Result` は `_pq: Pointer[LibpqFFI, MutUntrackedOrigin]` を構築時に `libpq_ptr()` から受け取り、`__deinit__`（raise 不可）ではそれ経由で `PQfinish` / `PQclear` を呼ぶ
   （`libpq()` は `raises PgError` なので deinit から呼べない）。`libpq_ptr()` が `Pointer(to=libpq())` で書けない場合は `loader.mojo` に非 raising の `_libpq_or_abort()` を置く（到達不能経路: Result が存在する時点でロードは成功済み）
10. **`open(Dict)` は `expand_dbname=0`**（Dict の値は字義どおり。URI 展開が要るなら `open(String)` を使う — docstring に書く）
11. **テストの接続先**: 各テストファイルが `getenv("PQ_TEST_CONNINFO")` を読み、空なら `host=127.0.0.1 port=54317 user=pq password=pq dbname=pq_test`。到達不能は失敗（D4）。
    誤パスワードは conninfo 末尾に ` password=WRONG_pw_123` を連結（libpq は同じキーの後勝ち。key=value 形式のみ対応と `run_tests.sh` に明記）。Dict 版は conninfo を空白 → `=` で分解して作る
12. **リーク判定**（D6 / P17）: ウォームアップ 1,000 回、以降 1,000 回ごとに RSS ページ数を記録（9 点）、`is_leaking` = 全隣接差分 > 0 **or** 最終 − 初回 > 16 ページ。異常系ループは 1,000 回（200 回ウォームアップ、4 点）
13. **`String` → `const char*`**: 引数は `var` で受け取り（所有コピー）、`as_c_string_span()` を 1 回だけ呼び、`CStr(unsafe_from_address=Int(span.ptr()))` で渡す。呼び出しが終わるまで元 `String` を生存させる（`_ = s^` を呼び出しの後に置く。probe-loader `connect_params`）。
    `char*` → `String` は `String(unsafe_from_utf8_ptr=p)`（`OptCStr` は `p.value()`）で**即コピー**
14. **ロード候補の失敗文言**: `libpq not found. tried: <path>: <OwnedDLHandle のエラー文>; <path2>: ...`。バージョン不足は `<path>: libpq too old: <v> (need >= 140000)` を同じ一覧に入れる
15. **public API の docstring 規約**: 要約行は大文字で始める（lint P15）。`raises PgError` を持つものは `Raises:` 節に kind を書く。`_ffi` はモジュール docstring のみ必須（REQ §5.1b）

## メモ

### reflect の反映
- `.gsd-lite/reflect/` は空（初回マイルストーン）。反映した提案は無い

### RESEARCH §4「盗める点」の採否

| # | 項目 | 採否 | 理由 |
|---|---|---|---|
| 1 | FFI 表 struct `LibpqFFI`（`OwnedDLHandle` + 全関数ポインタ、`check_symbol` → `_dl_sym`） | 採用 | T1。`_dl_sym` が欠損で `Error` を投げるので `check_symbol` の事前ループは省略可（欠損名はエラー文に入る） |
| 2 | `_Global` + `LoadState`（結果保持、abort しない） | 採用 | T2。REQ §4.1 の `PgError(LibpqLoad)` に必須 |
| 3 | `RTLD.NOW \| RTLD.GLOBAL \| RTLD.NODELETE` | 採用 | T1。NOW で欠損を起動時検出、NODELETE で関数ポインタ無効化を防ぐ |
| 4 | Int アドレスの newtype opaque 型（取り違え防止） | 採用 | T1。`Pointer(unsafe_from_address=0)` が不可なので Int 必須 |
| 5 | `Result(Iterable, Movable, Sized)` + `RowIter[origin]`、`Row` はスナップショットでなくビュー | 採用（ビュー版） | T5。REQ の `__getitem__ -> Row` と origin による寿命保証（P5） |
| 6 | エラーフィールド取得順（'V' 優先、無ければ 'S'） | 採用 | T4 決めた事項 6 |
| 7 | psycopg `_pq_ctypes.py` の argtypes/restype 表 | 採用（照合元） | T1 のシグネチャレビュー。PQgetvalue / PQescapeLiteral の `POINTER(c_char)`（NULL 可）を `OptCStr` に反映 |
| 8 | psycopg `pq_ctypes.py`: NULL 戻りの扱い、`finish` が「ポインタを無効化してから PQfinish」 | 採用 | T4。`__deinit__` は `_conn` 非 NULL のときだけ `PQfinish`（Movable のみなので二重呼び出しは型で防がれるが保険） |
| 9 | `PGnotify` レイアウト（offset 0/8/16/24、size 32） | 採用 | T1 で `size_of == 32` をテスト |
| 10 | enum 値一覧 | 採用 | T1（ヘッダから再抽出して一致を確認済み） |
| 11 | C プロトタイプ抽出 | 採用 | 決めた事項 2 の表（ヘッダ行番号付き） |
| — | postgres.mojo の `row.int64("id")` 型別 accessor | 却下 | D8 / D10: 型パラメータ式 + OID 完全一致が要件 |
| — | postgres.mojo の `abort()` on load failure | 却下 | REQ §4.1 |
| — | mojo-http の `ExternalFunction` | 却下 | 1.1.0 に存在しない |

### 落とし穴 → タスク対応（RESEARCH §5）
P1→T1/T2, P2→T2, P3→T4/T7, P4→T4, P5→T4/T5, P6→T4, P7→T5, P8→T4/T5, P9→T5, P10→T3/T5, P11→T3/T5, P12→T3/T5, P13→T6, P14→T6/T7, P15→T1/T8, P16→T1, P17→T7, P18→T4, P19→T1/T2, P20→T1, P21→T4。
並行性: libpq 接続はスレッド非安全で `Connection` は `Movable` のみ（T4 の負のコンパイル確認）。Phase 1 にマルチスレッドの要件は無い。
境界値: T3（数値・bytea・float 特殊値）/ T5（DB 経由の同じ値 + index 境界）。異常系: T4（接続・実行）/ T7（失敗経路のリーク）。

### impl への申し送り
- **1 ターン 1 タスク**。T1 と T4 が最大。サブ作業に分けて並行させる場合、親は統合後に `pixi run test` と `pixi run package` を必ず回す
- 無人シェル: `/home/parallels/.pixi/bin/pixi run ...` フルパス。`cd` や `&&` を使わない（pixi.toml のタスクは内部で `&&` を使ってよい）
- `mojo run -I src tests/test_x.mojo` 単体実行時も `PQ_TEST_CONNINFO` 未設定なら既定 54317 に行く（テスト内の既定値）
- Mojo 1.1.0 の既知の罠（RESEARCH §2）: `T: Copyable & Movable` は冗長警告 → `T: Copyable`；`Copyable, Movable` の両方を struct に書くと警告が出ることがある → probe が通った `(Copyable, Writable)` / `(Movable)` / `(Iterable, Movable, Sized)` の形を使う；`UnsafePointer` は非推奨（`Pointer`）；`CStringSlice` は非推奨（`CStringSpan`）；
  `as_c_string_span()` は `mut self`；`MutAnyOrigin` を含む型はフィールドに置けない；`comptime match` は無い；モジュール `var` は無い；デストラクタは `__deinit__(deinit self)`
- `get_or_create_ptr()` は `raises Error`。`raises PgError` 関数の中では `try/except` で包む（そのままだとコンパイルエラー）
- 警告ゼロは `tests/` と `examples/` も対象（`mojo run` のコンパイル時警告が `final_check.log` に出る）。未使用変数は `_ = x` で消す
- 数値の `atol` は前後空白を許容する（PG の出力に空白は無いので実害なし。テストに「空白を拒否」を入れない）
- `pg_terminate_backend(pg_backend_pid())` による切断シミュレーション（T4）は research 未検証。1 回目の execute の結果が期待表と違えば実測を正として PLAN を訂正（2 回目が `CONNECTION` にならない場合は P4 の設計を見直して PROGRESS に書く）
- `size_of` のインポート元（`std.sys`）と macOS 判定（`CompilationTarget.is_macos()` または `os_is_macos()`）は RESEARCH が名前を挙げているだけで未プローブ。コンパイルエラーなら `mojo` の std ドキュメントで名前を確かめて PLAN 訂正
- タスク数 8（目安 8〜15 の下限）。T1 / T4 は並列サブ作業前提で 1 ターン想定。サブエージェントが使えない場合は T1 を「A+B」「C」、T4 を「A+B」「C」の順に同一ターン内で直列に進める（それでも 1 ターンに収める）
