# RESEARCH — phase1-sync-text-basic

- 作成: 2026-10-15 / gsd-lite-research（turn 1）
- 入力: REQUIREMENTS.md / DECISIONS.md / HANDOFF.md、`state.json.research.targets` = similar_oss / official_docs / local_projects
- 検証環境: Mojo 1.1.0 (8189361e)、libpq 18.6（pixi env、`libpq.so.5.18`）、docker `postgres:17`(54317) / `postgres:14`(54314)
- **プローブ**: `.gsd-lite/logs/phase1-sync-text-basic/scratch/turn-001-probe-*.mojo`（gitignore 対象。消えても困らないよう
  結論は本書に転記した。plan/impl は本書の「検証済み」を事実として使ってよい。未検証の項目は明示している）
- 無人シェルの注意: `mojo` / `pixi` は PATH に無い。**`/home/parallels/.pixi/bin/pixi run mojo ...`** のフルパスで呼ぶ
  （`pixi run test` / `pixi run db-up` も同様にフルパス）

## 0. 結論サマリ

1. **作る（BLOCKED にしない）**。要件をほぼ満たす既存 OSS は無い。最も近い `magmalake/postgres.mojo` は Mojo 1.1.0 対応の
   libpq クライアントだが、本マイルストーンの中核要件（`PgError` 構造体 + `kind`、OID 完全一致の型照合、`_ffi` の 1:1 全関数公開、
   `Result` から派生する `Row` ビュー）を満たさず、エラーは文字列、ロード失敗は `abort`。ただし **FFI 層の設計は盗める**（§1.1, §4）
2. **D8 の「trait 式 `get[T: FromPgText]`」は Mojo 1.1.0 では不可**（組み込み型に後付けで trait 準拠を足す `extension` 構文が無い）。
   代替として **`get[T: Copyable](col)` + `comptime if T == Bool: ... elif T == Int32: ...`（型スイッチ）** が動作することを確認した。
   型パラメータ式 API は維持でき、型別 getter フォールバックは不要（§2.3 / §6）
3. **関数ポインタの保持方法**: `OwnedDLHandle.get_function` は動くが戻り値がハンドルの origin に縛られ struct に保持できない。
   `get_symbol[FT]` → `def(...) thin abi("C") -> R` 型の **thin 関数ポインタをフィールドに格納**する方式が正解（§2.1）
4. **プロセス内 1 ハンドル**: モジュールレベル `var` は不可。`std.ffi._Global["name", init_fn]` を使う。init_fn は raise できないので
   「ロード結果（`Optional[LibpqFFI]` + エラー文字列）」をグローバルに置き、アクセサ `libpq() raises PgError` で変換する（§2.2）
5. **要件に影響する発見**: `mojo package` は非推奨で出力は **`.mojoc` 必須**（`.mojopkg` は拒否される）。REQUIREMENTS §5.1b の
   `build/pq.mojopkg` は `build/pq.mojoc` に読み替える提案（§6）

## 1. 類似 OSS（similar_oss）

### 1.1 magmalake/postgres.mojo — https://github.com/magmalake/postgres.mojo
- Apache-2.0。dvirarad/mojo-postgres の fork を Mojo 1.x（stable 1.1.0 + nightly）向けに書き直したもの。1 star / 24 commits / リリース無し
- 機能: conninfo 接続、パラメータ付き実行、typed row accessor、Transaction（savepoint）、COPY、pool。async / LISTEN/NOTIFY / バイナリは対象外
- **要件との差**（BLOCKED にしなかった根拠）:
  - エラーは Mojo の文字列 `Error` に SQLSTATE を埋め込む（REQ §4.4 の `PgError` 構造体 + `kind` ではない）
  - `row.int64("id")` 等の型別 accessor で、**列 OID を照合しない**（REQ §4.3 / D10 と不一致）
  - ロード失敗は `abort()`（REQ §4.1 は `PgError(kind=LibpqLoad)`）
  - `Row` は行を `List[String]` にスナップショットする（REQ の「`Result.__getitem__ -> Row` ビュー」とは別設計）
  - `_ffi` は使う関数だけ。`PGnotify` / キャンセル / 非同期は無い（D5 と不一致）
- **盗める設計**（`src/postgres/_ffi.mojo`、本書 §2 で 1.1.0 上の動作を再確認済み）:
  - `comptime _FFI = _Global["postgres_mojo_libpq", _open_ffi]` + `def libpq() raises -> ref[MutUntrackedOrigin] LibpqFFI: return _FFI.get_or_create_ptr()[]`
  - `_dl_sym[FT: TrivialRegisterPassable](lib, name)`: `lib.get_symbol[FT](name)` → アドレス → `Pointer(to=addr).unsafe_bitcast[FT]()[]`
  - フィールド型 `def(Int, Int32, Int32) thin abi("C") -> Int`（PQgetvalue）のように thin C-ABI 関数型で保持
  - `OwnedDLHandle(path, RTLD.NOW | RTLD.GLOBAL | RTLD.NODELETE)`（NOW: 欠損シンボルを起動時に検出、NODELETE: dlclose 後の関数ポインタ無効化を防ぐ）
  - opaque ハンドルは `Int`（0 = NULL）。理由: `Pointer(unsafe_from_address=0)` はコンパイル時制約エラー（§2.1 で再現）
  - `Result.__deinit__` で `PQclear`、`Result` は `Iterable, Movable, Sized`、`_RowIter[origin]` が `Pointer[Result, origin]` を持ち `__next__ raises StopIteration`
  - `PQcmdTuples` が空文字なら 0、`PG_DIAG_SEVERITY_NONLOCALIZED` を優先し無ければ `PG_DIAG_SEVERITY`
  - 接続失敗時 `PQfinish` 必須（「failed connection still allocates」）
  - 受け取った `char*` は **常に `String` にコピーしてから返す**（libpq のバッファ寿命に依存しない）

### 1.2 codetalcott/mojo-http PR #298 "m0-postgres" — https://github.com/codetalcott/mojo-http/pull/298
- Mojo 1.0 向け。`ExternalFunction["PQconnectdb", def(CStr) thin abi("C") -> Int].load(handle.borrow())` 方式
- **`ExternalFunction` は Mojo 1.1.0 の `std.ffi` に存在しない**（プローブで `package 'ffi' does not contain 'ExternalFunction'`）。採用不可
- 盗める知見: 「`check_symbol` を先に回してから load（load は欠損で abort）」「ハンドルと関数ポインタは同じ struct に置く（ポインタはハンドルの borrow を持たない）」

### 1.3 同リポジトリ PR #390 (m0-sqlite) / magmalake/sqlite.mojo / lz4.mojo
- `RTLD_NODELETE` で再オープンしないと「Connection より長生きする Statement が最初の step で segfault」（Linux で再現、macOS は dyld cache で隠れる）
- 1 ハンドル/プロセス、関数ポインタ表を 1 struct に集約、バージョン下限チェック（libpq でいう `PQlibVersion >= 140000`）

### 1.4 lee101/mojo-db — https://github.com/lee101/mojo-db
- ワイヤプロトコル自前実装（libpq 不使用）。HANDOFF §3 対象外。参考にしない

### 1.5 Phelsong/mojo-wayland
- 検索結果に「`get_function` が `def(...)->T` 型で `AnyTrait` になり使えない（Mojo 1.0.0）」とあったが README には記載なし。
  1.1.0 では `get_function[return_type]`（引数は呼び出し時に推論）が動作することをプローブで確認済み（§2.1）。問題なし

## 2. 公式ドキュメント + Mojo 1.1.0 での検証結果（official_docs）

参照: https://mojolang.org/docs/manual/c-ffi 、https://mojolang.org/docs/std/ffi 、https://mojolang.org/docs/std/ffi/OwnedDLHandle 、
https://mojolang.org/releases/v1.1.0/ 、https://www.postgresql.org/docs/current/libpq-exec.html

### 2.1 FFI（検証済み: probe-ffi / probe-global / probe-loader）

| 項目 | 事実 | 根拠 |
|---|---|---|
| `OwnedDLHandle.get_function[return_type: RegisterPassable = NoneType](name)` | 戻り値型だけ指定、引数は呼び出し時に推論。`PQconnectdb(cstring_span)` / `PQstatus(ptr)` / `PQfinish(ptr)` が動作 | probe-ffi 成功出力 `PQlibVersion = 180006`, `PQstatus = 1` |
| 同 戻り値 `_DLCallable[return_type, origin_of(self)]` | ハンドルの不変借用を持つため **struct フィールドに保持できない**（postgres.mojo のコメントどおり） | docs OwnedDLHandle |
| `get_symbol[FT](name) -> Optional[Pointer[FT, origin]]` + `unsafe_bitcast[FT]()[]` で thin 関数ポインタ取得 | **動作**。`var PQexec: def(PGconnPtr, CStr) thin abi("C") -> PGresultPtr` をフィールドに格納し呼べる | probe-global / probe-loader |
| `ExternalFunction` | **存在しない**（1.1.0） | probe-ext コンパイルエラー |
| `OpaquePointer`（origin 無し） | `RegisterPassable` でないため `get_function[OpaquePointer]` は不可。`Pointer[NoneType, MutUntrackedOrigin]` は可 | probe-ffi エラー → 修正で成功 |
| struct フィールドの origin | `MutAnyOrigin` / `ImmutAnyOrigin` を含む型は **フィールドに置けない**。`MutUntrackedOrigin` / `ImmUntrackedOrigin` を使う | probe-ext エラー |
| NULL ポインタ | `Pointer` は非 null。`Pointer(unsafe_from_address=0)` は**コンパイル時制約エラー**。`OptionalPointer` は `TrivialRegisterPassable` struct の**メンバにできない**が、thin 関数型の**戻り値型としては可**（`PQresultErrorField -> OptionalPointer[c_char, ImmUntrackedOrigin]` が動作、NULL は `not p`） | probe-loader |
| → 採用設計 | opaque 型は `@fieldwise_init struct PGconnPtr(TrivialRegisterPassable): var _addr: Int`（`is_null()` = `_addr == 0`）。`char*` 戻りで NULL があり得るもの（`PQresultErrorField`, `PQescapeLiteral/Identifier`, `PQparameterStatus`, `PQnotifies`）は `OptionalPointer[c_char, ImmUntrackedOrigin]`、NULL にならないもの（`PQgetvalue`, `PQerrorMessage`, `PQcmdTuples`, `PQfname`, `PQresultErrorMessage`）は `Pointer[c_char, ImmUntrackedOrigin]` | probe-loader 全体が PG17 で成功 |
| `String` → `const char*` | `s.as_c_string_span()` は **`mut self`**（NUL 付与で再確保しうる）。不変引数・イテレータ要素では呼べない → `var` のローカル所有コピーにしてから呼ぶ。`CStringSpan.ptr()` の origin は `origin_of(s)` なので thin 関数型の引数（`ImmUntrackedOrigin`）に渡すには `Pointer[c_char, ImmUntrackedOrigin](unsafe_from_address=Int(span.ptr()))` でキャスト。`CStringSlice` は非推奨名（`CStringSpan`） | probe-loader エラー → 修正で成功 |
| `const char* const*`（`PQconnectdbParams`） | `List[Int]` にアドレスを集め末尾 `0`、`Pointer[Int, ImmUntrackedOrigin](unsafe_from_address=Int(list.unsafe_ptr()))` を渡す。呼び出し中は元 `String` 群と `List` を生存させる（`_ = x^` を呼び出し後に置く） | probe-loader `connect_params` 成功 |
| `char*` → `String` | `String(unsafe_from_utf8_ptr=p)`（NUL 終端をコピー）。`c_char = Int8` | probe-ffi / global |
| `OwnedDLHandle(path, flags)` 失敗 | `raise Error("dlopen failed: /nonexistent/dir/libpq.so.5: cannot open shared object file: No such file or directory")`。`check_symbol("PQnotifies") == True`、未知名は False。フラグ `RTLD.NOW \| RTLD.GLOBAL \| RTLD.NODELETE` は `std.ffi.RTLD` | probe-env |
| `OwnedDLHandle` 1.1.0 | `Boolable` 準拠。null ハンドル破棄のクラッシュ修正済み | v1.1.0 release notes |

### 2.2 グローバル（検証済み: probe-lang / probe-global / probe-loader）

- **モジュールレベル `var` は不可**（`error: global variables are not supported`）
- `from std.ffi import _Global` → `comptime _STATE = _Global["pq_libpq", _open]`、`_STATE.get_or_create_ptr()` は **`raises Error`**。
  `raises PgError` の関数内から呼ぶには `try/except` で `PgError` に変換しないとコンパイルエラー
  （`cannot call function that may raise 'Error' in context that supports an error type of 'PgError'`）
- `_open() -> LoadState`（非 raising）。`LoadState(Movable)` = `Optional[LibpqFFI]` + `error: String`。2 回目の `libpq()` は同じインスタンス（probe-global `same global`）
- テストでのロード失敗再現: `from std.os import setenv`、`_ = setenv("PQ_MOJO_LIBPQ", "/nonexistent/...", True)` を **最初の `libpq()` より前**に呼ぶ（lazy 初期化なので専用テストファイルで成立。probe-env で setenv → getenv 反映を確認）

### 2.3 言語（検証済み: probe-lang / probe-iter / probe-parse）

- `def f() raises PgError -> T` + `@fieldwise_init struct PgError(Copyable, Writable)` で `except e: e.kind` が使える（discuss 確認の再現）
- **`extension` 構文は無い**（`expressions must not appear at file scope`）→ 組み込み型に `FromPgText` を後付けできない
- **`comptime match` は無い**（`'comptime' cannot be used with 'match'`）→ `comptime if T == Bool: ... elif T == Int32: ... else: comptime assert False, "..."`
- 型スイッチの戻し方: `rebind[T](value)` は参照を返すので `return rebind[T](v).copy()`（`T: Copyable`）。`T: Copyable & Movable` は「redundant」警告 → `T: Copyable` のみ
- `Optional[T](get[T](...))` は `T: Copyable` で通る。`get_optional` が `None` を返す形も確認
- デストラクタ名は **`__deinit__(deinit self)`**。`Movable` のみの struct を `^` で移動すると deinit は 1 回だけ走る
- **ASAP 破棄**: 値は最後の使用の直後に破棄される（`print(len(moved))` で deinit 出力が print より先に出た）。
  `Row[origin]` が `Pointer[Result, origin]` を持てば `Result` の寿命が延びる（origin 追跡）ので、`Result` 破棄後の `Row` 使用はコンパイル時に防がれる
- `Iterable` + `Iterator` の書き方（動作確認済み、そのまま使える）:
  ```mojo
  struct Result(Iterable, Movable, Sized):
      comptime IteratorType[iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]]: Iterator = RowIter[origin=iterable_origin]
      def __getitem__(ref self, i: Int) raises PgError -> Row[origin_of(self)]: ... Row[origin_of(self)](Pointer(to=self), i)
      def __iter__(ref self) -> Self.IteratorType[origin_of(self)]: return RowIter[origin_of(self)](Pointer(to=self), 0)
  struct Row[origin: ImmOrigin](Copyable): var _res: Pointer[Result, Self.origin]; var _index: Int
  struct RowIter[origin: ImmOrigin](Iterator):
      comptime Element = Row[Self.origin]
      def __next__(mut self) raises StopIteration -> Self.Element: ... raise StopIteration()
  ```
- 数値パース（prelude の `atol` / `atof`、`raises Error`）:
  - `atol`: `"42"`, `"-32768"`, `"32768"`, `"9223372036854775807"` OK。`"9223372036854775808"`（Int 範囲外）/ `""` / `"1.5"` / `"0x10"` は raise。
    **前後空白は許容**（`" 1"` → 1）。int2/int4 の範囲チェックは **自前**（`atol` は Int64 幅）
  - `atof`: `"1.5"`, `"NaN"`→nan, `"Infinity"`→inf, `"-Infinity"`→-inf, `"1e308"`, `"3.4028235e+38"` OK。`""` / `"abc"` は raise。
    `Float32(atof("1e39"))` は `inf`（float4 のテキストは PG 側で範囲内なので実害なし）
- `/proc/self/statm` は `open("/proc/self/statm", "r").read()` で読める。空白区切り 2 番目が resident pages（probe-leak の `rss_pages()`）
- `std.time.perf_counter_ns` で計測可

### 2.4 ツールチェーン（検証済み）

| 項目 | 事実 |
|---|---|
| `mojo package` | 非推奨（`warning: 'package' is deprecated; use 'precompile' instead`）。**`-o` は `.mojoc` 必須**（`.mojopkg` は `error: output path must have a '.mojoc' extension`）。`mojo precompile src/pq -o build/pq.mojoc` は現状のスケルトンで成功 |
| `.mojoc` の性質 | 配布形式ではない（コンパイラ版に紐づく）。`mojo build` 時の import 高速化用。REQ §5.1b の目的（パッケージビルドが通ること）は `.mojoc` で満たせる |
| docstring lint | `precompile` が `src/pq/__init__.mojo:1` に **警告**: `doc string summary should begin with a capital letter`（先頭が `pq:`）。「警告ゼロ」要件に抵触するので最初のタスクで直す。`--diagnose-missing-doc-strings` で欠落 docstring を診断できる（§5.1b の機械判定に使える） |
| `mojo format` | 既定行長 80。`pixi run fmt` は `mojo format src/ tests/ examples/ hello.mojo` |
| テスト | `pixi run test` → `tests/run_tests.sh` が `mojo run -I src tests/test_*.mojo` をファイルごとに実行。現状 3 件 PASS（ベースライン） |
| 警告の例 | `T: Copyable & Movable`（冗長）、未使用変数（`assignment to 'x' was never used`）、`UnsafePointer`（非推奨、`Pointer` を使う） |

## 3. libpq の挙動（PG17 / PG14 両方で確認、libpq 18.6）

| 操作 | 結果 |
|---|---|
| 受け入れクエリ `SELECT 1::int4, 'a'::text, NULL::int4, true, 1.5::float8, '\x0102'::bytea` | status 2 (TUPLES_OK)、OID = 23, 25, 23, 16, 701, 17。値 `1`, `a`, ``（isnull=1）, `t`, `1.5`, `\x0102`。PG14/PG17 同一 |
| 空白のみの SQL `"   "` | status 0 (PGRES_EMPTY_QUERY) |
| `PQexec` on 接続失敗後の conn | **NULL を返す**（`PgError(kind=Connection)` + `PQerrorMessage` の経路が必要） |
| `PQstatus(NULL)` | 1 (CONNECTION_BAD) を返す（クラッシュしない） |
| 構文エラー `SELEC 1` | status 7 (FATAL_ERROR)。フィールド S=`ERROR`, V=`ERROR`, C=`42601`, M=`syntax error at or near "SELEC"`, D/H/W=NULL, P=`1`。`PQerrorMessage(conn)` は `ERROR:  syntax error ...\nLINE 1: SELEC 1\n        ^\n`（複数行、末尾改行） |
| `PQresultErrorField` on 正常結果 | NULL |
| `PQfnumber` | `SELECT 1 AS FOO, 2 AS "BAR"` → `FOO`→0, `foo`→0, `BAR`→-1, `"BAR"`→1, `bar`→-1（**未引用名は小文字化、引用付きは厳密**） |
| `PQcmdTuples` | SELECT → `"1"`、`CREATE TEMP TABLE t(x int); INSERT INTO t VALUES (1),(2)` → status 1 (COMMAND_OK)、`"2"`（複数文は最後の文の結果）。DDL 単体は `""` |
| 誤パスワード | status 1、`PQerrorMessage` = `connection to server at "127.0.0.1", port 54317 failed: FATAL:  password authentication failed for user "pq"\n`（**パスワード文字列は含まれない**。host/port/user は含む） |
| 到達不能 (`port=1 connect_timeout=1`) | status 1、`connection to server at "127.0.0.1", port 1 failed: Connection refused\n\tIs the server running ...\n` |
| `PQescapeLiteral(conn, "O'Reilly \ \"x\"")` | ` E'O''Reilly \\ "x"'`（**バックスラッシュを含むと先頭に空白 + `E` プレフィックス**。リテラル比較のテストはこれを前提にする）。`PQescapeIdentifier` → `"O'Reilly \ ""x"""`。`PQfreemem` で解放、再利用なし |
| `PQescapeLiteral` の NULL 戻り | **再現できず**（Mojo の `"\xff"` は U+00FF の UTF-8 になり不正バイトにならない）。NULL 経路は OOM / 不正マルチバイトのみ。テストは「NULL なら `PgError(kind=Server)`」のコードパスをレビューで担保し、可能なら `String(unsafe_from_utf8=Span(...))` で 0xFF 単独バイトを作って試す（未検証） |
| connect / `SELECT 1` / close ループ | 1,000 回 3.5 s（**約 3.5 ms/回 → 10,000 回 ≈ 35 s/サーバー、2 サーバーで ≈ 70 s**）。RSS pages: 開始 66463 → 250 回目以降 66467 で**一定**。最初の数回で +4 ページ増えるのでウォームアップ必須 |

## 4. 盗める設計 / 使えるライブラリ（plan が採否表にする）

1. **FFI 表 struct `LibpqFFI`**（postgres.mojo）: `OwnedDLHandle` + 全関数ポインタを 1 struct に、`__init__` で `check_symbol` → `_dl_sym` の順。欠損シンボルは `PgError(kind=LibpqLoad)` 相当に集約
2. **`_Global` + `LoadState`**（本書 §2.2。postgres.mojo の abort 方式を「結果保持」に改良）
3. **`RTLD.NOW | RTLD.GLOBAL | RTLD.NODELETE`**（postgres.mojo / mojo-http #390）
4. **Int アドレスの newtype opaque 型**（postgres.mojo の `Int` 別名を、取り違え防止のため `PGconnPtr` / `PGresultPtr` / `PGcancelPtr` / `PGnotifyPtr` の別 struct にする）
5. **`Result(Iterable, Movable, Sized)` + `RowIter[origin]`**（postgres.mojo。ただし `Row` はスナップショットでなく `Pointer[Result, origin]` ビューにして REQ に合わせる — probe-iter で動作確認済み）
6. **エラーフィールド取得順**: `PG_DIAG_SEVERITY_NONLOCALIZED('V')` 優先、無ければ `'S'`（postgres.mojo）。SQLSTATE が無い結果はクライアント側エラー扱い（psycopg は `08006`。本プロジェクトでは `kind=Connection`）
7. **psycopg 3 `pq/_pq_ctypes.py`**（ローカル: `/home/parallels/workspaces/poc-amano/.venv/lib/python3.12/site-packages/psycopg/pq/_pq_ctypes.py`）: 全 libpq 関数の argtypes/restype 表。`_ffi/functions` のシグネチャ・レビューの照合元に使う。`PQgetvalue` の restype が `POINTER(c_char)`（NUL 終端前提にしない）、`PQescapeLiteral` の restype も `POINTER(c_char)`（NULL 可）と明記されている
8. **psycopg 3 `pq/pq_ctypes.py`**（同ディレクトリ）: `exec_` が NULL 戻りで `OperationalError(get_error_message())`、`escape_literal` が NULL 戻りで conn のエラーメッセージ、`finish` が「ポインタを None にしてから PQfinish」（二重解放防止の定石）、`PGnotify_struct = (relname: c_char_p, be_pid: c_int, extra: c_char_p)`（`next` は private）
9. **`PGnotify` レイアウト**（`libpq-fe.h` L228-235）: `char* relname; int be_pid; char* extra; struct pgNotify* next;` → x86-64/aarch64 で offset 0/8/16/24、size 32（`be_pid` 後に 4 byte パディング）。Mojo は `var relname: Int; var be_pid: c_int; var extra: Int; var next: Int` の `TrivialRegisterPassable` struct で自然アライメントが一致する（**未検証**: `size_of[PGnotify]() == 32` を comptime assert / テストで確認する）
10. **enum 値**（`libpq-fe.h` L82-152、本書で抽出済み）: `ConnStatusType` OK=0, BAD=1, STARTED=2, MADE=3, AWAITING_RESPONSE=4, AUTH_OK=5, SETENV=6, SSL_STARTUP=7, NEEDED=8, CHECK_WRITABLE=9, CONSUME=10, GSS_STARTUP=11, CHECK_TARGET=12, CHECK_STANDBY=13, ALLOCATED=14, AUTHENTICATING=15。
    `PostgresPollingStatusType` FAILED=0, READING=1, WRITING=2, OK=3, ACTIVE=4。
    `ExecStatusType` EMPTY_QUERY=0, COMMAND_OK=1, TUPLES_OK=2, COPY_OUT=3, COPY_IN=4, BAD_RESPONSE=5, NONFATAL_ERROR=6, FATAL_ERROR=7, COPY_BOTH=8, SINGLE_TUPLE=9, PIPELINE_SYNC=10, PIPELINE_ABORTED=11, TUPLES_CHUNK=12。
    `PGTransactionStatusType` IDLE=0, ACTIVE=1, INTRANS=2, INERROR=3, UNKNOWN=4。
    `PG_DIAG_*`（`postgres_ext.h` L55-72）: S, V, C, M, D, H, P, p, q, W, s, t, c, d, n, F, L, R
11. **C プロトタイプ**（`libpq-fe.h`、`.pixi/envs/default/include/`）: HANDOFF §5.2 の全関数を `grep` で抽出済み（本ターンのログ）。`PQcancel(PGcancel*, char* errbuf, int errbufsize)`、`PQescapeLiteral(PGconn*, const char*, size_t)`、`PQconnectdbParams(const char* const*, const char* const*, int expand_dbname)`、`PQsendQueryParams(PGconn*, const char*, int, const Oid*, const char* const*, const int*, const int*, int)` 等。`Oid = UInt32`、`size_t = c_size_t (UInt)`

## 5. 落とし穴と検証方法（plan は完了基準に写す）

| # | 落とし穴 | 回避策 | どう検証すれば踏んでいないと分かるか |
|---|---|---|---|
| P1 | `get_function` の戻り値は struct に保持できない / 毎回 `get_function` するとロックアップ・コスト | `get_symbol` + thin 関数ポインタのフィールド（§2.1） | `_ffi` に `get_function` 呼び出しが無いことを `grep -c get_function src/pq/_ffi` = 0 で確認。ロードが 1 回なのは `libpq()` を 2 回呼んで同じ `PQlibVersion` が返り、`OwnedDLHandle` 構築が `LoadState` 内の 1 箇所だけであることをレビュー |
| P2 | ロード失敗で `abort` して `PgError` にならない | `LoadState` 方式（§2.2）。`_open` は非 raising、全候補パスを試して失敗一覧を文字列に蓄積 | 専用テストファイル `tests/test_loader_fail.mojo` で `setenv("PQ_MOJO_LIBPQ", "/nonexistent/x.so", True)` 後に `Connection.open` → `PgError.kind == LibpqLoad` かつ message に試したパスを含む。トレースバック無しで終了 |
| P3 | 失敗した接続の `PGconn*` を `PQfinish` しない（リーク） / 二重 `PQfinish` | `open` は `PQstatus != OK` なら `PQerrorMessage` をコピー → `PQfinish` → raise。`Connection` は `Movable` のみ、`__deinit__` で `_addr != 0` のときだけ `PQfinish` | 誤パスワードで 1,000 回 `open` 失敗させて RSS が増えない（リークテストの異常系版）。`Connection` の copy がコンパイルエラーになる負のコンパイルテスト（コメントで記録、または `mojo run` が失敗することを run_tests 外で確認） |
| P4 | `PQexec` が NULL（接続断・OOM） | `PGresultPtr.is_null()` で `PgError(kind=Connection, message=PQerrorMessage)`。`PQclear(NULL)` は no-op だが呼ばない | 到達不能サーバーへ接続して失敗した conn に対し `execute` が `kind=Connection` を返す（probe-loader で NULL を確認済み）。サーバー停止後の挙動は docker を落とさず再現しにくいので `pg_terminate_backend` 相当は Phase 1 では「接続失敗後」で代替 |
| P5 | `PQerrorMessage` / `PQgetvalue` のバッファ寿命（`PQfinish` / `PQclear` 後に読む） | 受け取った `char*` は即 `String` にコピー。`Row.get` は値をコピーして返す | `Result` 破棄後の `Row` 使用がコンパイルエラーになる（origin）。`execute` 失敗経路で「エラー文字列コピー → `PQclear`」の順序をレビュー |
| P6 | `as_c_string_span()` が `mut self` で、不変引数では呼べない / 再確保でポインタが無効化 | 引数を `var` 所有コピーにしてから 1 回だけ呼び、呼び出し後まで生存させる（`_ = s^`） | `PQconnectdbParams` のテスト（`Dict[String,String]` 版 `open`）が通る。長い（> 64 byte、SSO を超える）キー・値でも通る |
| P7 | `PQfnumber` の小文字化: `get("Name")` は `name` 列に当たる、`get("\"Name\"")` は厳密一致 | libpq どおりにする（`column_index(name)` は `PQfnumber` を呼ぶ）。docstring に明記 | `SELECT 1 AS FOO, 2 AS "BAR"` で `column_index("FOO")==0`, `("BAR")` は `PgError(kind=TypeMismatch` or 別 kind…REQ は「存在しない列名 → PgError」なので kind は plan で決める）, `("\"BAR\"")==1` |
| P8 | 列 index 範囲外・行 index 範囲外で libpq が stderr に書いて空文字を返す（クラッシュはしない） | `Result` 側で `0 <= i < row_count/column_count` を先に検査して `PgError` | 範囲外 index / 負数 / 空結果（0 行）の `[0]` で `PgError`、stderr に libpq の `row number ... is out of range` が出ない |
| P9 | NULL と空文字の区別（`PQgetvalue` は NULL でも `""`） | `PQgetisnull` を先に見る | `SELECT NULL::text, ''::text` で `get_optional[String]` が None / Some("") |
| P10 | int2/int4 の範囲: `atol` は Int64 幅で通してしまう | 型スイッチ内で範囲チェック（int2: -32768..32767、int4: -2^31..2^31-1） | OID 完全一致で範囲外は来ないが、`get[Int32]` の境界値テスト（`2147483647`, `-2147483648`）と `get[Int16]` の `32767` / `-32768`。`Int` は `int8` のみ |
| P11 | float の特殊値 | `atof` が `NaN` / `Infinity` / `-Infinity` を処理（§2.3） | `SELECT 'NaN'::float8, 'Infinity'::float4, '-Infinity'::float8` で `isnan` / `isinf` 判定 |
| P12 | bytea hex: `\x` 無し・奇数桁・非 hex 文字 | 先頭 `\x` 必須、残り偶数長、各桁 hex のみ。それ以外 `kind=TypeMismatch` | `'\x'::bytea` → 空 List、`'\x0102'` → [1,2]、`'\xDEADbeef'`（大文字小文字混在）、`'abc'::text` を `get[List[UInt8]]` → OID 不一致で TypeMismatch、SQL で `'\\000'::bytea` を `SET bytea_output='escape'` 後に取ると TypeMismatch |
| P13 | `PQescapeLiteral` の先頭空白 + `E''` 形式 | そのまま返す（libpq の仕様）。docstring に例を書く | `escape_literal("O'Reilly")` == `'O''Reilly'`、バックスラッシュ入りは ` E'...'` で始まる。`escape_identifier("x\"y")` == `"x""y"` |
| P14 | `PQfreemem` 忘れ / 二重解放 | 文字列コピー直後に `PQfreemem`、1 箇所のみ | 1,000 回 `escape_literal` して RSS 一定 |
| P15 | 警告ゼロ: docstring 先頭大文字、未使用変数、`Copyable & Movable`、`UnsafePointer` | `mojo precompile --diagnose-missing-doc-strings` と `mojo build` の出力に `warning:` が無いことを最終判定に入れる | `pixi run package` と `pixi run test` の stderr を `grep -c warning` で 0 |
| P16 | `mojo package` → `.mojopkg` 不可 | `mojo precompile src/pq -o build/pq.mojoc`（§6） | `pixi run package` が exit 0 で `build/pq.mojoc` が生成 |
| P17 | リークテストの時間（10,000 回 ≈ 35 s/サーバー）と初期ページ増加 | 1,000 回ウォームアップ後にサンプル（例: 2,500 回ごとに 4 点）。判定は「後半サンプルが前半より大きいものが連続しない」か「最終 - ウォームアップ後 <= 許容ページ数（例 16 ページ）」。計測は 1 ファイルに閉じ、他テストの RSS を混ぜない | 判定ロジックのユニットテスト（単調増加列で fail、一定列で pass）。macOS では `CompilationTarget.is_macos()` で skip 出力 |
| P18 | ASAP 破棄で `Connection` が最後の使用直後に `PQfinish` される（`Result` を返した後 `Connection` が先に死ぬ） | `Result` は `PGresult*` を所有し `PQclear` だけ行うので `PQfinish` 後の `PQclear` は libpq 的に安全（`PGresult` は独立メモリ）。ただし `Row.get` 中に `Connection` が死んでも問題ない設計にする（`Result` は conn を参照しない） | `var r = conn.execute(...)` の後 `conn` を使わないテストで `r` のアクセスが成功する |
| P19 | テスト間の libpq ハンドル共有（プロセス内 1 つ）とロード失敗テストの干渉 | ロード失敗は専用ファイル（REQ §6 どおり）。`run_tests.sh` がファイルごとに別プロセス | `run_tests.sh` に対象ファイルのループがあり、失敗ファイルがあっても他のファイルが実行される（status 集約） |
| P20 | 2 サーバー × 全テスト実行時の環境変数受け渡し | `run_tests.sh` で `PQ_TEST_CONNINFO` を export してループ（無人シェルの規則はスクリプト内には及ばない） | `PQ_TEST_CONNINFO` 未設定で 54317 / 54314 の両方のログが出る。設定済みならその 1 つだけ |
| P21 | パスワードがエラーメッセージに混入 | conninfo / params を一切メッセージに入れない（REQ 4.4）。libpq のメッセージ自体はパスワードを含まない（§3） | 誤パスワード `WRONG_pw_123` を含む conninfo で `open` → `e.message` に `WRONG_pw_123` が無い。`Dict` 版でも同様 |

## 6. 要件への影響（提案。REQUIREMENTS.md 本文は変更していない）

1. **§5.1b `mojo package src/pq -o build/pq.mojopkg`** → `mojo precompile src/pq -o build/pq.mojoc`（`.mojopkg` は 1.1.0 で拒否される。`pixi run package` タスク名は維持）。受け入れは「`build/pq.mojoc` が生成され警告ゼロ」
2. **D8 / §4.3 `Row.get[T]`**: trait `FromPgText` 式は不可（`extension` 無し）。採用案は **`get[T: Copyable](col) raises PgError -> T` の `comptime if` 型スイッチ**（対応 T: `Bool`, `Int16`, `Int32`, `Int64`, `Int`, `Float32`, `Float64`, `String`, `List[UInt8]`。それ以外は `comptime assert False`）。
   型パラメータ式の API は保てるので「型別 getter」フォールバックは不要。PLAN.md の「決めた事項」に理由を記録すること（D8 の要請）
3. **§4.1 ロード**: 「ハンドルはプロセス内 1 つ」は `_Global` + `LoadState` で実現。ロード失敗の `PgError` は `libpq()` アクセサで生成（`abort` しない）。
   `PQlibVersion < 140000` の判定も `LoadState` 生成時に行い、失敗一覧に含める
4. **§4.2 `PGnotify`**: `TrivialRegisterPassable` struct（`relname: Int`, `be_pid: c_int`, `extra: Int`, `next: Int`）。受け入れに「`size_of[PGnotify]() == 32`」を加える提案
5. **§4.3 `column_index(name)` / `Row.get(name)`**: `PQfnumber` の小文字化規則をそのまま採用し docstring に書く（P7）。存在しない列名の `kind` は REQ に明記が無い（TypeMismatch か別 kind）→ plan で決めて記録
6. **§5.1 リークテスト**: 「ウォームアップ 1,000 回 → 以降 2,500 回ごとにサンプル」等の具体値と判定式を plan で固定（P17）。所要時間 ≈ 70 s を `run_tests.sh` の想定に入れる
7. **§5.1b 警告ゼロ**: 現状の `src/pq/__init__.mojo` の docstring が lint 警告を出す（先頭 `pq:`）。最初のタスクで修正
8. **§6 テスト環境**: `tests/run_tests.sh` に `PQ_TEST_CONNINFO` の既定 2 本ループを実装（現状は単一実行）。無人シェルからは `/home/parallels/.pixi/bin/pixi run test` で呼ぶ

## 7. ローカルプロジェクト（local_projects: `~/workspaces`）

- Mojo のソースは本リポジトリ以外に無い（`find ~/workspaces -name '*.mojo'` は pgcon のみ）。他の `.gsd-lite` プロジェクト（bizcore-factory 配下の components 等）は PL/pgSQL / TypeScript で、FFI の同型実装は無い
- 参考になるのは **psycopg 3 の `pq` パッケージ**（§4-7/8。`poc-amano` / `bizcore-factory` / `copilot-langgraph` の `.venv` に同一ファイル）。
  libpq 関数の argtypes/restype、NULL 戻りの扱い、`PGnotify` の ctypes 定義、`connection_summary`（host/port/user/db だけを表示しパスワードは出さない）が同型の設計
