# REQUIREMENTS — phase7-pool-copy-array

HANDOFF §3 で「対象外（今回はやらない）」としていた 3 件（コネクションプール / COPY プロトコル /
配列型）を `pq` に追加する。対象リポジトリは in-repo（`.`）、base は `main`（`v0.1.0` タグ済み、PR #1 マージ済み）。

## 1. 目的（WHAT）

- `Row.get[T]` / `Param` で PostgreSQL の配列型を扱えるようにする（§2.1）
- `COPY ... FROM STDIN` / `COPY ... TO STDOUT` を libpq の COPY API で扱えるようにする（§2.2）
- 同期 `Connection` を再利用するコネクションプールを追加する（§2.3）
- 既存の受け入れ条件（`pixi run check` 6/6 PASS、CI 3 OS 緑、警告ゼロ）を維持する

## 2. 要求

### 2.1 配列型

- **受信**: `Row.get[List[T]](col)` / `get_optional[List[T]]` で 1 次元配列を取得できる。
  `T` は既存の型マッピング表の 19 型すべて（`Bool`, `Int16`, `Int32`, `Int64`/`Int`, `Float32`, `Float64`,
  `String`（text/varchar/bpchar/name/json/jsonb）, `List[UInt8]`（bytea）, `Decimal`, `UUID`, `Date`, `Time`,
  `TimeTz`, `Timestamp`, `TimestampTz`, `Interval`）。要素のデコードは既存の `decode_text` / `decode_binary` を再利用する
- 配列の OID は要素 OID と 1:1 で対応づける（`_int4` = 1007 など。`pg_type.typarray` の値を定数表にする）。
  列 OID が `List[T]` の `T` に対応する配列 OID と一致しない場合は `TYPE_MISMATCH`（既存の「拡張変換なし」規則を踏襲）
- 表現は Mojo 標準の `List[T]`（自前の配列 struct は作らない）。空配列 `{}` は空の `List`
- **受信形式**: テキストとバイナリの両方。既存 19 型と同じく届いた形式（`PQfformat`）でデコーダを選ぶ。
  テキストは配列リテラル（`{1,2,3}`、引用符 `"..."` と `\` エスケープ、区切り文字は `,`。`box` 型の `;` は対象外）のパーサ、
  バイナリは `array_send` 形式（int32 ndim / flags / elemtype OID、各次元の dim / lbound、要素ごとに int32 長（-1 = NULL）+ 要素バイト列）
- **NULL 要素**: `get[List[T]]` は NULL 要素があれば `NULL_VALUE`。`get[List[Optional[T]]]` は NULL 要素を `None` として返す
  （列 NULL を扱う `get_optional` とは別軸。`get_optional[List[Optional[T]]]` で両方 NULL 許容）
- **多次元**: ndim ≥ 2（テキストの `{{...}}` / バイナリの ndim）は `TYPE_MISMATCH`。非 1 始まりの添字（テキストの `[0:1]=` 接頭辞 /
  バイナリの lbound ≠ 1）は読み飛ばして要素だけ返す（データは失わない）
- **送信**: `Param(List[T])` と `Param(List[Optional[T]])` を 19 型分追加し、既存の単体型と同じくバイナリで送る
  （`paramTypes` に配列 OID、`paramFormats` = 1、`array_recv` が受ける形式で組み立てる。ndim = 1、lbound = 1、NULL 要素は長さ -1）。
  要素が `String` の配列もバイナリで送る（配列ヘッダが必要なため）。空 `List` は ndim = 0 の空配列として送る

### 2.2 COPY

- **方向**: `COPY ... FROM STDIN`（COPY IN）と `COPY ... TO STDOUT`（COPY OUT）の両方。同期 `Connection` のみ
  （`AsyncConnection` の COPY はスコープ外 §3）
- **低レベル**: `PQputCopyData`, `PQputCopyEnd`, `PQgetCopyData` を `LibpqFFI` に追加（`libpq-fe.h` のシグネチャどおり 1:1）
- **データ**: バイト列の素通し。利用側が text / CSV / binary 形式の行を `Span[UInt8]`（または `String`）で渡し、
  ライブラリは転送・終端・エラー回収だけを行う。`WITH (FORMAT ...)` は SQL 側で指定する。行の型付きエンコード / デコードはしない
- **API**（RAII。`Transaction[origin_of(self)]` と同じ origin パターン）:
  - `conn.copy_in(sql) raises -> CopyIn[origin]`: `PQexec(sql)` の結果が `PGRES_COPY_IN` でなければ `PgErrorKind.USAGE`
    （通常の結果なら解放してから投げる）。`write(bytes: Span[UInt8])` / `write(s: String)` は `PQputCopyData`（同期接続では 1 を返すまで完了。
    -1 は `PgError`）。`finish() raises -> Result` は `PQputCopyEnd(NULL)` → `PQgetResult` で `PGRES_COMMAND_COMPLETE` を回収し
    `affected_rows()` が COPY 行数。`abort(message: String) raises` は `PQputCopyEnd(message)` → サーバの `57014` 相当エラーを回収して握りつぶす
    （接続はアイドルに戻る）
  - `conn.copy_out(sql) raises -> CopyOut[origin]`: 結果が `PGRES_COPY_OUT` でなければ `USAGE`。`next() raises -> Optional[List[UInt8]]` は
    `PQgetCopyData(async=0)` で 1 行（改行を含む生バイト）を返し、-1（終端）で `None` を返したあと `PQgetResult` を回収して完了。
    -2 は `PgError`。`PQfreemem` を必ず呼ぶ。`Iterator` としても使える
  - 未完了のまま `__del__` された場合: `CopyIn` は `PQputCopyEnd("aborted by pq")` と残り結果の回収、`CopyOut` は残り行の読み捨てと結果回収を行い、
    接続を使える状態に戻す。失敗は `Connection.set_rollback_failure_handler` と同じフックに通知する（`__del__` から投げられないため）
  - COPY 中の `Connection` は他の `execute` / `transaction` / `copy_*` を `PgErrorKind.USAGE` で拒否する（`transaction()` の二重開始と同じ客側検査）
- **トランザクション内 COPY**: `Transaction` の中で `copy_in` を使えること（`tx.connection()` 経由か、`Transaction` に同名メソッドを足すかは plan が既存の
  `Transaction.execute` の形に合わせる）

### 2.3 コネクションプール

- **スレッドモデル**: 単一スレッド前提、ロックなし。`Connection` と同じく `Movable` のみで、スレッド安全でないことを docstring と README に明記する
  （事実: Mojo 1.1.0 の標準ライブラリにスレッド / mutex / `parallelize` は無く `std.atomic` だけ。discuss でプローブ済み）
- **生成**: `Pool.open(conninfo: String, max_size: Int) raises -> Pool` と `Pool.open(params: Dict[String, String], max_size: Int)`
  （`Connection.open` の 2 オーバーロードに揃える）。接続は遅延で開く（`acquire` 時に空きが無ければ `Connection.open`）。
  `max_size` ≤ 0 は `USAGE`
- **貸し出し**: `acquire()`。空きがあれば再利用、無ければ総数 < `max_size` の間は新規に開き、`max_size` に達していれば**即座に** `PgErrorKind.USAGE`
  （単一スレッドでは返却を待てない）
- **健全性**: 貸し出す前に `PQstatus` を見て `CONNECTION_OK` でなければ `PQreset`、それでも駄目なら捨てて新規に開く
  （`PQreset` を `LibpqFFI` から使う。`Connection` に `reset()` を足すかは plan が決める。`Connection.open` が固定する `DateStyle` / `IntervalStyle` は
  reset 後に再設定が必要）。往復（`SELECT 1`）はしない
- **返却時の後始末**: `PQtransactionStatus` が `INTRANS` / `INERROR` なら `ROLLBACK` を送ってから戻す。`ACTIVE`（COPY 途中等）/ `UNKNOWN` /
  `PQstatus != OK` の接続は捨てる（`PQfinish`）。`SET` した GUC、prepared statement、一時テーブルは残る（README の既知の制限に明記）
- **終了**: `close()` と `__del__` で保持中の空き接続を `PQfinish`。貸し出し中の接続が `Pool` より長生きしないことは origin（`Pool` を借りる guard）で
  コンパイル時に保証する（`Transaction[origin_of(self)]` と同じ）
- **貸し出し API**: `acquire(ref self) raises -> PooledConnection[origin_of(self)]`。RAII ガードで、`__del__` 時に後始末（上記）をして
  プールへ自動返却する。`PooledConnection` は `Connection` の公開メソッド（`execute` 2 種 / `prepare` / `transaction` / `copy_in` / `copy_out` /
  `escape_literal` / `escape_identifier` / `server_version` / `status` / `transaction_status`）を同じシグネチャで転送する。
  `ref` や `Connection` そのものは返さない（README「`pq` が `ref` を返すことはありません」の維持）。`Movable` のみ
- **オプション**（`Pool.open` のキーワード引数。既定値は括弧内）:
  - `min_size: Int`（0）: `open` 時にこの本数を先に開く。`min_size > max_size` は `USAGE`。open 失敗はそのまま `PgError` を投げ `Pool` は作られない
  - `max_lifetime_s: Int`（0 = 無期限）: 開いた時刻（`std.time`）から超過した接続は返却時に `PQfinish` して保持しない
  - 統計: `size()`（保持 + 貸し出し中の総数）/ `idle()`（空き）/ `borrowed()`（貸し出し中）

### 2.4 堅牢性（受け入れ基準に含める）

- どの入力・出力状態でもトレースバックを出さず、既存データを失わない。plan は堅牢性格子
  （入力 × 出力 × 依存の 3 軸。Phase 5 reflect の雛形 `archive/phase5-polish-bench-readme` 配下の scratch を参照）を
  初回タスクに含め、verify は該当指摘で差し戻せる
- 今回の「入力」軸に足すもの: 配列リテラルの不正形（閉じ括弧なし / 引用符の途中終端 / 要素 NULL / 多次元 / 空）、
  バイナリ配列ヘッダの不正（ndim 異常 / elemtype 不一致 / 長さ超過）、COPY の途中切断（クライアント側 `close(PQsocket)` 方式）、
  プールの枯渇 / 死んだ接続の再利用

## 3. スコープ外（やらないこと）

- パイプラインモード（`PQenterPipelineMode`）
- Mojo 言語の `async` / `await` への統合
- Windows 実機 / CI（ツールチェーン待ち。コードパスは従来どおり「書くが未検証」）
- modular-community recipe（Phase 6 D2 で却下済み）
- 多次元配列の形状保持（ndim ≥ 2 は `TYPE_MISMATCH`。D6）、`box` 型など区切り文字が `,` でない配列
- `AsyncConnection` の COPY（D9）。COPY の型付き行エンコーダ / デコーダ（D10）
- スレッド安全なプール、返却待ち（ブロッキング）の `acquire`、非同期プール（D12 / D13）
- 返却時の `DISCARD ALL`（D15）
- `.gsd-lite/` の履歴整理（このまま追跡する。D19）

## 4. 受け入れ基準

### 4.1 配列型

- 19 型それぞれについて、`SELECT ARRAY[...]::<type>[]` をテキスト形式とバイナリ形式で取得した `List[T]` が一致し、
  Phase 3 の境界値（最小 / 最大 / 0 / 負数 / NaN / ±Infinity / `infinity` 日時 / numeric の大きな桁）が要素としても往復する
- 空配列 `'{}'::int4[]` が空の `List` になる
- 配列 OID と `T` の不一致（`int2[]` を `List[Int32]` で読む）は `TYPE_MISMATCH`
- 配列列を `String` で読むと、テキスト形式ではリテラルがそのまま返る（既存のワイルドカード規則の維持）

### 4.2 COPY

- `copy_in` で text 形式 10 万行（`int4, int8, float8, text, timestamp` の 5 列。bench と同じ形）を流し込み、`finish().affected_rows()` が 100000、
  `SELECT count(*)` が一致する。CSV 形式（`WITH (FORMAT csv)`）と binary 形式（PGCOPY ヘッダを利用側が組み立てる）でも各 1 件往復する
- `copy_out` で同じテーブルを取り出し、行数と内容が `copy_in` に渡したバイト列と一致する
- `abort()` した COPY IN はテーブルに行を残さない。`finish()` を呼ばずに `CopyIn` を破棄した場合も同じで、その後の `execute` が通る
- `copy_out` を途中で破棄した後の `execute` が通る
- COPY 中の `execute` / `transaction` / 2 つ目の `copy_*` は `USAGE` で、サーバには何も送られない
- 不正なデータ（text 形式で列数が足りない行）は `finish()` が SQLSTATE `22P04` 等の `PgError.SERVER` を投げ、接続はアイドルに戻る
- 途中切断（クライアント側 `close(PQsocket)`）で `write` / `next` / `finish` が `PgErrorKind.CONNECTION` を投げ、トレースバックを出さない
- `Transaction` 内の `copy_in` を `rollback()` すると行が残らない

### 4.3 プール

- `max_size=2` のプールから `acquire` を 2 回成功、3 回目が `USAGE`（サーバに接続は 2 本だけ。`pg_stat_activity` で確認）。
  1 つを drop した後の `acquire` が成功し、`backend_pid` が drop した接続と同じ（再利用の証明）
- `min_size=2` で `open` 直後に `idle() == 2`、`size() == 2`、`pg_stat_activity` にも 2 本
- `transaction()` を commit せずにガードを drop → 返却時に ROLLBACK され、次の利用者の `transaction_status()` が IDLE、変更が残っていない
- `copy_in` を未完了のままガードを drop → その接続は捨てられ `size()` が 1 減り、次の `acquire` は新規接続（`backend_pid` が変わる）
- 貸し出し中にサーバ側から `pg_terminate_backend` された接続を返却 → 捨てられ、次の `acquire` は新規接続で `execute` が通る
- `max_lifetime_s=1` で 1 秒以上経った接続は返却時に閉じられ、次の `acquire` の `backend_pid` が変わる
- `close()` 後の `acquire` は `USAGE`。`Pool` の `__del__` で空き接続が `PQfinish` される（test_leak 相当の RSS 判定を 1 ケース足す）
- `max_size <= 0` / `min_size > max_size` は `USAGE` で、サーバに接続しない

### 4.4 共通

- `pixi run check` 6/6 PASS（PG 14 / 17 両方）、CI 3 OS 緑、`mojo build` 警告ゼロ
- README: 型マッピング表に配列の行（`T[]` → `List[T]` / `List[Optional[T]]`、両形式）、クイックスタートに COPY とプールの節、
  「既知の制限」から「配列型・COPY・コネクションプールは対象外」を外して残る制限（多次元 / 非同期 COPY / スレッド安全性 / GUC が残る）に書き換える。
  CHANGELOG `[Unreleased]` に Phase 7 として追記（タグは人間。Phase 6 D7 を継続）
- `examples/`: `copy.mojo`（COPY IN → COPY OUT の往復）と `pool.mojo`（`max_size` と再利用）を新設し、`pixi.toml` の `example-*` タスクに足す。
  配列は `examples/params.mojo` か `binary.mojo` に `= ANY($1)` と `List[T]` の受信を追記する。全 examples が単体で実行できること
- `Connection.execute` の docstring の「COPY は未対応」の記述（`src/pq/connection.mojo:266-269` 付近）を `copy_in` / `copy_out` への案内に書き換える
- state の `verify_round_max` は 4（D1）
- §2.4 の堅牢性

## 5. 用語集

- **配列 OID**: `pg_type.typarray`。要素型 OID ごとに 1 つ（例: int4 = 23 → `_int4` = 1007）
- **要素デコーダ**: 既存の `decode_text[T]` / `decode_binary[T]`。配列デコーダは要素ごとにこれを呼ぶ
- **COPY IN / COPY OUT**: libpq の `PGRES_COPY_IN`（`COPY ... FROM STDIN`）/ `PGRES_COPY_OUT`（`COPY ... TO STDOUT`）
- **プール**: 同期 `Connection` を保持して貸し出す器。詳細は §2.3

## 6. フェーズ横断の注意（plan / impl / verify 向け）

- **外向きの操作の線引き**（Phase 6 D15 を継続）: 無人ターンが行ってよいのは `gsd-lite/phase7-pool-copy-array` の push と
  PR 作成・更新だけ。タグ push、Release 作成、リポジトリ設定変更、main への push はしない
- **verify の CI 待ち**: PR 作成後 `gh pr checks <PR> --watch` で 3 ジョブを待つ（上限約 40 分）。再実行は `gh run rerun --failed` 1 回まで。
  自分が起動していない run は `gh run view <id> --json event,headSha,createdAt` を写してから判断する
- **research のプローブ**: 採る前に実在を確かめる。最低限 (1) `std.atomic` 以外の並行プリミティブが Mojo 1.1.0 に無いことの再確認
  （discuss のプローブ: `std.threading` / `std.sync` / `parallelize` は不在、`std.atomic.Atomic[T]` は存在）、
  (2) `PQputCopyData` / `PQputCopyEnd` / `PQgetCopyData` のシグネチャを `libpq-fe.h` で確認、
  (3) 配列のバイナリ形式を `array_send` / `array_recv`（`src/backend/utils/adt/arrayfuncs.c`）で確認、
  (4) 19 型の `typarray` OID を `SELECT oid, typname, typarray FROM pg_type` で実測
- **ローカルの開発機は linux-aarch64**。x86_64 と macOS は CI でしか検証できない
- **Phase 5 / 6 reflect の運用提案を引き継ぐ**: チェックリスト期待値は `≥` で書く／VERIFICATION の指摘表に grep パターン・件数・ファイルの 3 列／
  TRACE.md に「チェックリスト（turn N）」節／PROGRESS の最新ターン節は 40 行以内／サブエージェント完了待ちは `sleep` か完了通知で／
  YAML / sh の key を数えるときはコメント行を除外／サブエージェントの依頼文に親の待ち合わせファイル名を書かない
