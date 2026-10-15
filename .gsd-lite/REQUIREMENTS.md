# REQUIREMENTS — phase1-sync-text-basic

出典: `HANDOFF.md`（§1〜§12）。本書は HANDOFF の Phase 1 を無人ループで実装するための確定仕様。
HANDOFF と矛盾する場合は本書が優先する（矛盾点は DECISIONS.md に理由を記す）。

## 1. 目的

Mojo 1.1.0 から libpq（C FFI、実行時ロード）で PostgreSQL に接続し、同期・テキスト形式でクエリを実行して
基本型を型安全に取得できる最小のライブラリ `pq` を作る。

## 2. スコープ（この マイルストーンでやること）

HANDOFF §9 Phase 1 のみ。

- `src/pq/_ffi/`: libpq のロード（§5.1）、opaque ポインタ型と enum 定数（§5.2）、HANDOFF §5.2 に列挙された**全関数**の 1:1 バインディング
  （非同期・通知・キャンセル用も含む。高レベル層から使うのは Phase 1 分だけ）
- `src/pq/connection.mojo`: `Connection`（open / execute(sql) / escape_literal / escape_identifier / server_version / status / transaction_status）
- `src/pq/result.mojo`: `Result` / `Row`（行数・列数・列名・列 index・列 OID・affected_rows・行アクセス）
- 型: bool / int2 / int4 / int8 / float4 / float8 / text 系（text, varchar, bpchar, name）/ bytea / NULL をテキスト形式で取得
- `src/pq/errors.mojo`: `PgError`
- テスト（`tests/test_*.mojo`）、`examples/basic.mojo`

## 3. スコープ外（やらないこと）

- Phase 2 以降: パラメータ付き実行（`PQexecParams`）、prepared statement、`Transaction`、バイナリ形式、
  numeric/date/timestamp/uuid/json 等の拡張型、非同期 API、LISTEN/NOTIFY、キャンセル、ベンチマーク、README 整備、Windows コードパス
- HANDOFF §3 の対象外（ワイヤプロトコル自前実装、プール、COPY、パイプライン、ORM、Mojo async 統合）
- zero-copy の Row アクセス（Phase 1 は値を必ずコピーして所有型で返す）
- SQL への文字列埋め込み API

## 4. 機能要件

### 4.1 libpq ロード（`_ffi/loader`）
- 探索順: 環境変数 `PQ_MOJO_LIBPQ`（フルパス）→ OS 既定名（Linux `libpq.so.5` → `libpq.so`、macOS `libpq.5.dylib` → `libpq.dylib` と Homebrew パス）
- 全て失敗したら、試したパスを列挙した `PgError(kind=LibpqLoad)` を投げる
- ロード後に `PQlibVersion()` を呼び、140000 未満なら `PgError(kind=LibpqLoad)`
- ハンドルはプロセス内 1 つ、関数ポインタはキャッシュする（毎回 `get_function` しない）
- 既存の `examples/hello_libpq.mojo` / `tests/test_smoke.mojo` の探索ロジックを `_ffi/loader` に移し、両者はそれを使う形に書き換えてよい

### 4.2 低レベル層（`_ffi`）
- HANDOFF §5.2 の表にある全関数（接続 / 同期実行 / 結果 / エスケープ / 非同期接続 / 非同期実行 / 通知）を libpq と同名で 1:1 公開。所有権管理はしない
- `PGconn*` / `PGresult*` / `PGcancel*` は別名の opaque 型（`PGconnPtr`, `PGresultPtr`, `PGcancelPtr`）で包み、取り違えをコンパイル時に防ぐ
- `PGnotify` 構造体のレイアウトを Mojo の struct で定義する（`relname`, `be_pid`, `extra`, `next`）
- enum（`ConnStatusType`, `ExecStatusType`, `PGTransactionStatusType`, `PostgresPollingStatusType`）は `libpq-fe.h` の値に合わせた定数群
- 高レベル層から使わないバインディング（非同期・通知・キャンセル・`PQexecParams` 系）は、シンボル解決（ロード時に全関数ポインタを取得できる）と
  型シグネチャのレビューまでを Phase 1 の検証範囲とし、動作テストは使うフェーズで行う

### 4.3 高レベル層
- `Connection.open(conninfo: String) raises PgError -> Connection`
- `Connection.open(params: Dict[String, String]) raises PgError -> Connection`（`PQconnectdbParams`）
- `Connection` / `Result` は `Movable` のみ（`Copyable` にしない）。`__del__` でそれぞれ `PQfinish` / `PQclear`
- `execute(sql) raises PgError -> Result`。`PGRES_TUPLES_OK` / `PGRES_COMMAND_OK` 以外は `PgError(kind=Server)` にして `PQclear` する
  - 空文字・空白のみの SQL（`PGRES_EMPTY_QUERY`）は `PgError(kind=Server, message="empty query")`
  - 複数文（`a; b`）は libpq どおり最後の文の結果を返す。途中の文が失敗したらそのエラー。docstring に明記
  - `PQexec` が NULL を返した（メモリ不足・接続断）場合は `PgError(kind=Connection)` に `PQerrorMessage` を入れる
- `open` は `PQstatus != CONNECTION_OK` なら `PQerrorMessage` を `PgError(kind=Connection)` に入れ、`PQfinish` してから投げる
  （libpq は失敗時も非 NULL の `PGconn*` を返す）
- libpq の NOTICE（`PQsetNoticeProcessor`）は Phase 1 では既定動作（stderr）のまま。`_ffi` にもバインドしない
- `Row.get[T](col)` / `Row.get_optional[T](col)`。`col` は index または列名。NULL を `get` で取ると `kind=NullValue`、
  OID と T の不一致・テキストのパース失敗は `kind=TypeMismatch`
  - 型照合: `Bool` / `Int16` / `Int32` / `Int64` / `Int` / `Float32` / `Float64` / `List[UInt8]` は表の OID と**完全一致**のみ
    （拡幅 int2→Int32 等は認めない）。`String` は**任意の OID** でテキスト表現をそのまま返す
  - bytea は `\x` hex 形式のみ解釈する。旧 escape 形式（PG 14+ の既定ではない）は `kind=TypeMismatch`
  - 第一候補は trait（例 `FromPgText`）による型パラメータ式。Mojo 1.1.0 で素直に書けないと research / plan で判明した場合は、
    型別 getter（`get_bool` / `get_int16` / `get_int32` / `get_int64` / `get_float32` / `get_float64` / `get_string` / `get_bytes` と
    各 `*_optional`）へのフォールバックを認める。切り替えた場合は理由を PLAN.md に記録する
- `Result` は `__getitem__(row_index) -> Row` と `for row in result` の行イテレーションの両方を持つ
- `escape_literal` / `escape_identifier` は `PQfreemem` で解放し、NULL 戻り（失敗）は `PgError(kind=Server)`

### 4.4 エラー（`errors`）
- 公開 API が投げる型は `PgError` の 1 種類のみ（`raises PgError`）
- フィールド: `kind`（LibpqLoad / Connection / Server / NullValue / TypeMismatch）、`message`、
  `sqlstate`、`severity`、`detail`、`hint`、`position`、`context`（サーバーエラー以外は空文字）
- `PQresultErrorField` の `PG_DIAG_*` から埋める
- メッセージに接続文字列のパスワードを含めない。ルール: エラーメッセージに conninfo / params を一切埋め込まず、libpq の
  `PQerrorMessage` / `PQresultErrorMessage` の文字列と `pq` 側の固定文言だけで構成する

### 4.5 型マッピング（Phase 1、テキスト形式）

| PostgreSQL | OID | Mojo 型 | テキスト表現 |
|---|---|---|---|
| bool | 16 | `Bool` | `t` / `f` |
| int2 | 21 | `Int16` | 10 進 |
| int4 | 23 | `Int32` | 10 進 |
| int8 | 20 | `Int64`（`Int` でも取得可） | 10 進 |
| float4 | 700 | `Float32` | 10 進、`NaN` / `Infinity` / `-Infinity` |
| float8 | 701 | `Float64` | 同上 |
| text, varchar, bpchar, name | 25, 1043, 1042, 19 | `String` | そのまま |
| bytea | 17 | `List[UInt8]` | `\x` hex 形式 |
| 上記以外 | — | `String` としてのみ取得可 | そのまま |

## 5. 受け入れ基準

### 5.1 HANDOFF §10（共通 + Phase 1）
- `pixi run db-up` → `pixi run test` で全テストが PG 14 と PG 17 の両方に対して通る（Linux）
- 警告ゼロでビルドできる（`fn` を使わない。`def` + 明示 `raises`）
- 正しい接続文字列で接続でき、誤ったパスワードで `PgError(kind=Connection)` になり、メッセージにパスワードを含まない
- `SELECT 1::int4, 'a'::text, NULL::int4, true, 1.5::float8, '\x0102'::bytea` の各値を正しい型で取得できる
- 構文エラーの SQL で `PgError.sqlstate == "42601"`
- 10,000 回の connect / query / close ループでメモリ使用量が単調増加しない。判定はテスト内で `/proc/self/statm` を読み、
  ウォームアップ後の複数サンプルで比較する（Linux 専用。macOS ではこのテストを skip し、その旨を出力する）

### 5.1b 品質基準（差し戻し対象）
- `pq` 直下の公開 struct / メソッドに docstring がある（`_ffi` はモジュール docstring のみでよい）
- `pixi run fmt`（`mojo format`）を実行しても `git diff` が空
- `examples/basic.mojo`（接続 → SELECT → 行表示）が単体で実行できる。`pixi.toml` にタスクを追加する
- `mojo package src/pq -o build/pq.mojopkg` が通る（`pixi run package` タスクを追加する）

### 5.2 堅牢性（差し戻し対象）
- どの入力・接続状態（未接続、接続失敗後、サーバー停止後、空文字 SQL、NULL 結果、列 index 範囲外、存在しない列名）でも
  クラッシュ・トレースバックを出さず `PgError` で返す
- 正常系・異常系の両方で `PQclear` / `PQfinish` / `PQfreemem` が呼ばれ、二重解放しない（`open` 失敗時の `PQfinish` を含む）
- 解放済みポインタへのアクセスが型・所有権の上で起こらない（`Result` より長生きする参照を返さない）

### 5.3 スコープ外と明記する事項
- CI（GitHub Actions 等）は作らない。git remote も未設定。受け入れはローカルの `pixi run test` で判定する

## 6. テスト環境
- テスト DB は `tests/docker-compose.yml`（pg17 = localhost:54317、pg14 = localhost:54314、user/pass/db = pq/pq/pq_test）
- 接続先は環境変数 `PQ_TEST_CONNINFO` で上書き可。未設定なら `tests/run_tests.sh` が 54317 と 54314 の両方に対して全テストを実行する
- DB に到達できない場合はテスト失敗（スキップにしない）
- `mojo test` サブコマンドは無い。各 `tests/test_*.mojo` が `TestSuite` の `main()` を持ち、`run_tests.sh` がファイルごとに別プロセスで実行する
  （libpq ハンドルはプロセス内 1 つなので、ロード失敗のテストは専用ファイルで `PQ_MOJO_LIBPQ` に存在しないパスを与えて行う）

## 7. 用語集
- **低レベル層 / `_ffi`**: libpq 関数の 1:1 バインディング。所有権を持たない
- **高レベル層 / `pq`**: RAII と型安全を持つ公開 API
- **conninfo**: libpq の接続文字列（`host=... port=... user=...` または URI）
- **PgError.kind**: エラー分類。LibpqLoad / Connection / Server / NullValue / TypeMismatch
