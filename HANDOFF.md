# HANDOFF: mojo-libpq — Mojo から PostgreSQL を使う libpq ラッパー

## 0. このドキュメントの使い方

- 引き継ぎ先: Claude Code（自律実装）
- フェーズ順（§9）に実装する。各フェーズの受け入れ条件（§10）を満たしてから次へ進む。
- Mojo の API は版ごとに変化が激しい。本書のコード片は**イメージ**であり、実装前に必ず手元の Mojo 版のドキュメント（`https://mojolang.org/llms.txt`、`https://mojolang.org/docs/manual/c-ffi/`、`https://docs.modular.com/mojo/std/ffi`）で確認すること。
- 不明点・判断が割れる点は §11 に追記し、勝手に仕様を広げない。

## 1. 目的

Mojo（1.x）から PostgreSQL に接続し、クエリ実行・結果取得・トランザクション・非同期実行を行えるライブラリを、C FFI で libpq を呼ぶ形で作る。

- 低レベル層: libpq 関数の 1:1 バインディング
- 高レベル層: RAII と型安全を備えた Mojo らしい API

## 2. 前提・環境

| 項目 | 内容 |
|---|---|
| Mojo | 1.1.0 以降（1.x の後方互換に依存） |
| 関数宣言 | `def` を使う。`fn` は 26.2 で非推奨。`def` は既定で non-raising、投げる場合は `raises` を明示 |
| FFI | `std.ffi` の `OwnedDLHandle`（実行時ロード、RAII）と `external_call`、C 型エイリアス（`c_int`, `c_char` 等）、`CStringSlice` |
| libpq | PostgreSQL 14 以降のクライアントライブラリ（ABI は `libpq.so.5`） |
| テスト用 DB | Docker の `postgres:17`（14 でも回すこと） |
| パッケージ管理 | pixi（Mojo の標準的な導入手段に合わせる） |

### OS サポート方針

| OS | 状態 | 方針 |
|---|---|---|
| Linux (x86_64, aarch64) | 一次対象 | CI 必須 |
| macOS (arm64) | 一次対象 | CI 必須 |
| Windows | Mojo のネイティブツールチェーンが未提供（2026-09 時点。Microsoft と協業で対応予定との発表あり） | **コードは対応可能な形で書くが、CI とテストは保留**。OS 依存部分を `platform` モジュールに隔離し、Windows 実装は「書くが未検証」と明記する |

## 3. スコープ

### 対象
- 同期 API: 接続、`PQexec`、`PQexecParams`、`PQprepare`/`PQexecPrepared`
- 結果形式: テキスト形式とバイナリ形式の両方
- 型: §6 の型マッピング表
- トランザクション（BEGIN/COMMIT/ROLLBACK、セーブポイント）
- 非同期 API: 非ブロッキング接続、非ブロッキングクエリ送信・受信、LISTEN/NOTIFY
- エスケープ関数（`PQescapeLiteral`, `PQescapeIdentifier`）
- エラー情報（SQLSTATE、メッセージ、詳細、ヒント、位置）

### 対象外（今回はやらない）
- ワイヤプロトコルの自前実装
- コネクションプール
- COPY プロトコル（Phase 5 以降の候補として §11 に記載）
- パイプラインモード（`PQenterPipelineMode`）
- ORM / クエリビルダ
- Mojo 言語の `async`/`await` への統合（言語側の async が未完成のため。§7.3 参照）

## 4. アーキテクチャ

```
┌────────────────────────────────────────────┐
│ pq (高レベル)                               │
│  Connection / Result / Row / Value          │
│  Transaction / PreparedStatement            │
│  AsyncConnection / Notification             │
│  decode (text / binary)                     │
├────────────────────────────────────────────┤
│ pq._ffi (低レベル)                           │
│  libpq 関数の 1:1 バインディング              │
│  opaque ポインタ型 (PGconnPtr, PGresultPtr)  │
├────────────────────────────────────────────┤
│ pq._platform                                │
│  libpq のロード、ソケット poll (OS 差分)      │
└────────────────────────────────────────────┘
                 │ OwnedDLHandle
                 ▼
            libpq (C)
```

### ディレクトリ構成（案）

```
mojo-libpq/
  pixi.toml
  README.md
  HANDOFF.md
  src/pq/
    __init__.mojo
    _ffi/
      __init__.mojo
      loader.mojo        # libpq の探索・ロード
      types.mojo         # PGconnPtr, PGresultPtr, ConnStatus, ExecStatus 等
      functions.mojo     # 1:1 バインディング
    _platform/
      poll.mojo          # poll / WSAPoll の抽象
    connection.mojo
    result.mojo
    value.mojo
    params.mojo
    decode_text.mojo
    decode_binary.mojo
    transaction.mojo
    async_conn.mojo
    errors.mojo
  tests/
    docker-compose.yml
    fixtures/schema.sql
    test_*.mojo
  examples/
    basic.mojo
    params.mojo
    binary.mojo
    async_query.mojo
    listen_notify.mojo
```

## 5. 機能要件

### 5.1 libpq のロード（`_ffi/loader`）

探索順:
1. 環境変数 `PQ_MOJO_LIBPQ`（フルパス）
2. OS 既定名
   - Linux: `libpq.so.5` → `libpq.so`
   - macOS: `libpq.5.dylib` → `libpq.dylib`。加えて Homebrew の既定パス（`/opt/homebrew/opt/libpq/lib`, `/usr/local/opt/libpq/lib`）
   - Windows: `libpq.dll`
3. すべて失敗したら、試したパスを列挙したエラーを投げる

- ロード後に `PQlibVersion()` を呼び、14 未満ならエラー。
- ハンドルはプロセス内で 1 つにし、全関数ポインタをキャッシュする（毎回 `get_function` しない）。

### 5.2 低レベル層（`_ffi/functions`）

libpq のシグネチャどおりに 1:1 で公開する。名前は libpq と同じ（`PQconnectdb` など）。所有権の管理はしない（高レベル層の責務）。

最低限バインドする関数:

| 区分 | 関数 |
|---|---|
| 接続 | `PQconnectdb`, `PQconnectdbParams`, `PQfinish`, `PQreset`, `PQstatus`, `PQerrorMessage`, `PQserverVersion`, `PQparameterStatus`, `PQtransactionStatus`, `PQlibVersion` |
| 同期実行 | `PQexec`, `PQexecParams`, `PQprepare`, `PQexecPrepared`, `PQdescribePrepared` |
| 結果 | `PQresultStatus`, `PQresultErrorMessage`, `PQresultErrorField`, `PQntuples`, `PQnfields`, `PQfname`, `PQfnumber`, `PQftype`, `PQfformat`, `PQfmod`, `PQgetvalue`, `PQgetlength`, `PQgetisnull`, `PQcmdTuples`, `PQclear` |
| エスケープ | `PQescapeLiteral`, `PQescapeIdentifier`, `PQfreemem` |
| 非同期接続 | `PQconnectStartParams`, `PQconnectPoll`, `PQsocket`, `PQsetnonblocking`, `PQisnonblocking` |
| 非同期実行 | `PQsendQuery`, `PQsendQueryParams`, `PQsendPrepare`, `PQsendQueryPrepared`, `PQflush`, `PQconsumeInput`, `PQisBusy`, `PQgetResult`, `PQgetCancel`, `PQcancel`, `PQfreeCancel` |
| 通知 | `PQnotifies`（`PGnotify` 構造体のレイアウトを Mojo の struct で定義） |

- `PGconn*` / `PGresult*` / `PGcancel*` は opaque ポインタとして別の型名で包む（取り違えをコンパイル時に防ぐ）。
- enum（`ConnStatusType`, `ExecStatusType`, `PGTransactionStatusType`, `PostgresPollingStatusType`）は Mojo の定数群で定義し、値は `libpq-fe.h` に合わせる。

### 5.3 高レベル層

#### Connection
- `Connection.open(conninfo: String) raises -> Connection`
- `Connection.open(params: Dict[String, String]) raises -> Connection`（`PQconnectdbParams`）
- `Movable` のみ。`Copyable` にしない（libpq の接続はスレッド安全でなく、二重 `PQfinish` を防ぐため）。
- `__del__` で `PQfinish`。
- メソッド:
  - `execute(sql) raises -> Result`
  - `execute(sql, params, result_format=Text) raises -> Result`
  - `prepare(name, sql, param_types=None) raises -> PreparedStatement`
  - `transaction() raises -> Transaction`
  - `escape_literal(s) raises -> String` / `escape_identifier(s) raises -> String`
  - `server_version() -> Int`、`status()`、`transaction_status()`

#### Result
- `PQclear` を `__del__` で呼ぶ。`Movable` のみ。
- `row_count()`, `column_count()`, `column_name(i)`, `column_index(name)`, `column_type_oid(i)`, `affected_rows()`
- `__getitem__(row) -> Row`、行イテレーション
- `PQgetvalue` が返すポインタは Result に紐づく。
  - Phase 1: 値は必ずコピーして所有型で返す（安全側）。
  - Phase 3 以降: `Result` の origin を持つ `StringSlice`/`Span` で zero-copy アクセスを追加する（任意。§11）。

#### Row / Value
- `row.get[T](col) raises -> T`（`col` は index または名前）
- `row.get_optional[T](col) raises -> Optional[T]`（NULL 許容）
- NULL を `get[T]` で取ったら `NullValueError`。
- 型不一致（OID と T が合わない）は `TypeMismatchError`。テキスト形式ではパース失敗も同じエラーにする。

#### パラメータ（`params`）
- `PQexecParams` の `paramTypes`, `paramValues`, `paramLengths`, `paramFormats` を組み立てる。
- 呼び出し中は全バッファを生存させる（`List[...]` に保持し、呼び出し後に解放）。
- 引数の型ごとに送信形式を選ぶ:
  - `Int`, `Int32`, `Int16`, `Float64`, `Float32`, `Bool`, `List[UInt8]`（bytea）はバイナリで送る
  - `String` はテキストで送る
  - `None` / 空の `Optional` は NULL
- SQL への文字列埋め込み API は**作らない**。

#### Transaction
- `conn.transaction()` で BEGIN。`commit()` / `rollback()`。
- `commit`/`rollback` されずに破棄されたら `__del__` で ROLLBACK（エラーは握りつぶさずログ用のフックへ。Mojo で `__del__` から投げられない点に注意）。
- `savepoint(name)`、`rollback_to(name)`、`release(name)`。名前は `escape_identifier` を通す。

#### errors
- `PgError` に `sqlstate`, `severity`, `message`, `detail`, `hint`, `position`, `context` を持たせる（`PQresultErrorField` の `PG_DIAG_*`）。
- 接続エラーは `ConnectionError`。ロード失敗は `LibpqLoadError`。
- メッセージに接続文字列のパスワードを含めない。

## 6. 型マッピング

| PostgreSQL | OID | Mojo 型 | テキスト形式 | バイナリ形式 |
|---|---|---|---|---|
| bool | 16 | `Bool` | `t`/`f` | 1 byte |
| int2 | 21 | `Int16` | 10進 | 2 byte ビッグエンディアン |
| int4 | 23 | `Int32` | 10進 | 4 byte BE |
| int8 | 20 | `Int64` / `Int` | 10進 | 8 byte BE |
| float4 | 700 | `Float32` | 10進（`NaN`, `Infinity`, `-Infinity`） | IEEE754 BE |
| float8 | 701 | `Float64` | 同上 | IEEE754 BE |
| text, varchar, bpchar, name | 25, 1043, 1042, 19 | `String` | そのまま | そのまま（UTF-8） |
| bytea | 17 | `List[UInt8]` | `\x` hex 形式 | 生バイト |
| numeric | 1700 | `Decimal`（自前 struct：符号・桁・スケール）＋ `String` 変換 | 10進文字列 | ndigits, weight, sign, dscale, base-10000 digits |
| date | 1082 | `Date`（自前） | `YYYY-MM-DD` | int32: 2000-01-01 からの日数 |
| timestamp | 1114 | `Timestamp`（自前） | ISO 形式 | int64: 2000-01-01 からのマイクロ秒 |
| timestamptz | 1184 | `TimestampTz`（UTC 保持） | ISO＋オフセット | int64 µs（UTC） |
| uuid | 2950 | `UUID`（16 byte） | 8-4-4-4-12 | 16 byte |
| json | 114 | `String` | そのまま | そのまま |
| jsonb | 3802 | `String` | そのまま | 先頭 1 byte のバージョン（=1）＋テキスト |
| 上記以外 | — | `String`（テキスト形式で取得） | — | 未対応 OID はエラー |

- 日時は `infinity`/`-infinity`（テキスト）と int64 の最大値/最小値（バイナリ）を特別値として扱う。
- テキストの `DateStyle` は ISO 前提。接続直後に `SET DateStyle = 'ISO, YMD'` を発行するか、`options` で指定する。
- 配列型（`_int4` など）は Phase 5 の候補（§11）。

## 7. 非同期設計

### 7.1 方針
libpq の非ブロッキング API と OS のソケット poll で、**明示的に状態を進める API** として作る。Mojo の `async` には依存しない。

### 7.2 API
- `AsyncConnection.start(conninfo) raises -> AsyncConnection`（`PQconnectStartParams`。`PQsetnonblocking(1)` を設定）
- `poll_connect() raises -> PollState`（`PQconnectPoll` の結果を `NeedRead`/`NeedWrite`/`Ready`/`Failed` に写す）
- `socket() -> Int`（イベントループへの組み込み用）
- `send(sql, params=...) raises`（`PQsendQueryParams`、続けて `PQflush` が 0 になるまで書き込み待ち）
- `poll_result() raises -> Optional[Result]`（`PQconsumeInput` → `PQisBusy` が偽なら `PQgetResult`。NULL 結果で 1 クエリ完了）
- `notifications() raises -> List[Notification]`（`PQnotifies` を空になるまで取得し、`PQfreemem`）
- `cancel() raises`（`PQgetCancel`/`PQcancel`）
- 補助: `wait_readable(timeout_ms)` / `wait_writable(timeout_ms)` と、これらを使ったブロッキング版 `run_until_complete` 相当のヘルパー

### 7.3 Mojo `async` との関係
言語側の async が完成した段階で、上記の状態機械 API の上に薄いアダプタを載せる。今回は作らないが、状態機械 API はアダプタを載せられる形にしておく（各メソッドは 1 ステップだけ進めて即座に戻る）。

### 7.4 OS 差分（`_platform/poll`）
- Linux/macOS: libc の `poll()`（`external_call`）
- Windows: `ws2_32.dll` の `WSAPoll`。`PQsocket` が返すのは `SOCKET`（ポインタ幅の整数）である点に注意
- `struct pollfd` のレイアウトを OS ごとに定義する

## 8. 非機能要件

- **安全性**: 解放済みポインタへのアクセスが型・所有権の上で起こらないこと。`Result` より長生きする参照を返さない（Phase 1 はコピーで担保）。
- **リーク**: 正常系・異常系の両方で `PQclear`/`PQfinish`/`PQfreemem` が呼ばれること。テストで確認する（§10）。
- **性能**: 10 万行 × 5 列（int4, int8, float8, text, timestamp）の取得で、バイナリ形式がテキスト形式より速いこと。参考値として psycopg 3（同じクエリ、同じ形式）と比較し、結果を README に記録する（勝敗は受け入れ条件にしない）。
- **ドキュメント**: 公開 API には docstring。`examples/` の各ファイルは単体で実行できること。
- **ライセンス**: Apache-2.0（Mojo 本体と揃える）。libpq は PostgreSQL License で、同梱はしない（実行環境の libpq を使う）。

## 9. フェーズ計画

| Phase | 内容 | 主な成果物 |
|---|---|---|
| 0 | 環境構築 | pixi プロジェクト、docker-compose（PG 14/17）、libpq ロードと `PQlibVersion` 表示の hello |
| 1 | 同期・テキスト・基本型 | 低レベル（接続・同期実行・結果・エスケープ）、`Connection`/`Result`/`Row`、bool/int/float/text/bytea/NULL、`PgError` |
| 2 | パラメータ・prepared・トランザクション | `params`、`PreparedStatement`、`Transaction`（セーブポイント含む） |
| 3 | バイナリ形式 | `decode_binary`、§6 の全型（numeric, date, timestamp, timestamptz, uuid, jsonb 含む）、テキスト形式でも同じ型を解釈 |
| 4 | 非同期 | `_platform/poll`、`AsyncConnection`、キャンセル、LISTEN/NOTIFY |
| 5 | 仕上げ | ベンチマーク、README、examples、Windows 用コードパスのレビュー |

## 10. 受け入れ条件

### 共通
- `pixi run test` で Linux と macOS の全テストが通る（PG 14 と 17 の両方）。
- 警告ゼロでビルドできる（非推奨の `fn` を使わない）。

### Phase 1
- 正しい接続文字列で接続でき、誤ったパスワードで `ConnectionError` が出る（メッセージにパスワードを含まない）。
- `SELECT 1::int4, 'a'::text, NULL::int4, true, 1.5::float8, '\x0102'::bytea` の各値を正しい型で取得できる。
- 構文エラーの SQL で `PgError.sqlstate == "42601"`。
- 10,000 回の connect/query/close ループでメモリ使用量が単調増加しない（RSS をサンプリングして判定）。

### Phase 2
- `$1`〜`$n` のパラメータで全基本型を往復（INSERT → SELECT）でき、値が一致する。
- SQL インジェクション文字列（`'; DROP TABLE x; --`）をパラメータで渡してもテーブルが残る。
- `Transaction` を commit せずに破棄すると ROLLBACK される。
- セーブポイントへのロールバックで部分的に取り消せる。

### Phase 3
- §6 の全型について、テキスト形式とバイナリ形式で取得結果が一致する（境界値: 最小値・最大値・0・負数・NaN・±Infinity・`infinity` 日時・numeric の大きな桁と小数）。
- 未対応 OID をバイナリで要求したら明示的なエラーになる。

### Phase 4
- `pg_sleep(2)` を送信中に、同じスレッドで他の処理（カウンタのインクリメント）が進む。
- `cancel()` で `pg_sleep(10)` が 1 秒以内に中断され、SQLSTATE `57014` が得られる。
- 別接続からの `NOTIFY ch, 'payload'` を `notifications()` で受け取れる。
- 接続先が応答しない場合（ブラックホールアドレス等）に、タイムアウト付きの `wait_*` が規定時間で戻る。

### Phase 5
- ベンチマーク結果が README にある。
- `examples/` が全部実行できる。
- Windows 用コード（`WSAPoll`、DLL 名）が存在し、未検証であることが README に明記されている。

## 11. 未確定事項・判断メモ

- **zero-copy の Row アクセス**: Result の origin に紐づく `StringSlice` を返す API。Mojo の origin の書き方が版で変わっているため、Phase 3 完了後に必要なら着手。
- **`__del__` 内のエラー**: Transaction の自動 ROLLBACK 失敗をどう通知するか（フック関数、stderr、無視）。Phase 2 で決めて記録する。
- **Decimal 型**: 標準ライブラリに相当型がないため自前で作る。演算は対象外とし、`String` との相互変換と比較だけにする。
- **配列型・COPY・パイプラインモード**: 今回は対象外。要望があれば Phase 6。
- **Windows**: Mojo のツールチェーンが出たら CI を追加する。それまでは「コードはあるが未検証」。
- **libpq の同梱**: しない前提。配布形態を検討する段階で再判断。

## 12. 参考

- Mojo C FFI マニュアル: https://mojolang.org/docs/manual/c-ffi/
- Mojo `std.ffi`: https://docs.modular.com/mojo/std/ffi
- Mojo 26.2 changelog（`def`/`fn` 統一）: https://docs.modular.com/mojo/changelog/v0.26.2/
- libpq ドキュメント: https://www.postgresql.org/docs/current/libpq.html
  - 非同期: https://www.postgresql.org/docs/current/libpq-async.html
  - 通知: https://www.postgresql.org/docs/current/libpq-notify.html
- バイナリ形式の参照実装: PostgreSQL の `src/backend/utils/adt/*.c` の `*_send`/`*_recv`
