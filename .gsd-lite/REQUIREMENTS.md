# REQUIREMENTS — phase2-params-prepared-tx

出典: `HANDOFF.md` §9 Phase 2 / §10 Phase 2 / §5.3（params / Transaction）/ §6 / §11、および
前回マイルストーン（`.gsd-lite/archive/phase1-sync-text-basic/`）の REQUIREMENTS / VERIFICATION 残留リスク /
`.gsd-lite/reflect/20261015-2308-phase1-sync-text-basic.md` の「次回への提案」。
HANDOFF と矛盾する場合は本書が優先する（矛盾点は DECISIONS.md に理由を記す）。
Phase 1 の仕様（`archive/.../REQUIREMENTS.md`）は本書で変更しない限りそのまま有効。

## 1. 目的

Phase 1 の `pq`（同期・テキスト・基本型）に、パラメータ付き実行（`PQexecParams`）、prepared statement
（`PQprepare` / `PQexecPrepared`）、トランザクション（BEGIN / COMMIT / ROLLBACK / セーブポイント）を追加する。

## 2. スコープ（このマイルストーンでやること）

HANDOFF §9 Phase 2 の全部。

- `src/pq/params.mojo`: パラメータの表現と `PQexecParams` / `PQexecPrepared` 用バッファ組み立て
- `Connection.execute(sql, params)`（パラメータ付き実行）
- `src/pq/prepared.mojo`（または同等）: `Connection.prepare(...)` と `PreparedStatement`
- `src/pq/transaction.mojo`: `Connection.transaction()` と `Transaction`（commit / rollback / savepoint / rollback_to / release）
- テスト（`tests/test_params.mojo` / `test_prepared.mojo` / `test_transaction.mojo` 等）、`examples/params.mojo`
- 冒頭の持ち越し整理（§6）とリーク測定方式の変更（§5.3）

## 3. スコープ外（やらないこと）

- Phase 3 以降: バイナリ**結果**形式（`decode_binary`）、numeric / date / timestamp / uuid / json 等の拡張型、
  非同期 API、LISTEN/NOTIFY、キャンセル、ベンチマーク、README 整備、Windows コードパス、zero-copy Row
- HANDOFF §3 の対象外（ワイヤプロトコル自前実装、プール、COPY、パイプライン、ORM、Mojo async 統合）
- SQL への文字列埋め込み API（HANDOFF §5.3「作らない」）
- CI（Phase 1 D7 と同じ。受け入れはローカル `pixi run test`）

## 4. 機能要件

### 4.1 パラメータ（`params.mojo`）
- `Param`: 値の variant 構造体。保持できるもの: `Bool` / `Int16` / `Int32` / `Int64` / `Int` / `Float32` / `Float64` / `String` /
  `List[UInt8]`（bytea）/ NULL
- 構築: 上記各型からの `@implicit __init__`（`StringLiteral` 用も別に用意する）、`Optional[T]`（上記 T）からの `@implicit __init__`
  （`None` は NULL）、`Param.null()`（OID 0）、`Param.null(oid: UInt32)`（型付き NULL）。
  これにより `conn.execute(sql, [1, "a", Param.null()])` と書ける
- 送信形式（HANDOFF §5.3 / §6）:

  | Mojo 型 | 送信形式 | paramTypes の OID | 備考 |
  |---|---|---|---|
  | `Bool` | バイナリ 1 byte | 16 | |
  | `Int16` | バイナリ 2 byte BE | 21 | |
  | `Int32` | バイナリ 4 byte BE | 23 | |
  | `Int64` / `Int` | バイナリ 8 byte BE | 20 | |
  | `Float32` | IEEE754 4 byte BE | 700 | NaN / ±Infinity はそのまま送れる |
  | `Float64` | IEEE754 8 byte BE | 701 | 同上 |
  | `String` | テキスト（NUL 終端） | 0（サーバー推論） | 埋め込み NUL は送信前に `kind=USAGE` で拒否 |
  | `List[UInt8]` | バイナリ（長さ付き） | 17 | 空・NUL 含みも可 |
  | NULL | NULL | 0 または指定 OID | |

- `PQexecParams` / `PQexecPrepared` に渡す `paramTypes` / `paramValues` / `paramLengths` / `paramFormats` は呼び出し中生存し、
  呼び出し後に解放される（`List` に保持）。`resultFormat` は常に 0（テキスト）。`result_format` 引数は作らない（Phase 3）
- エンコード関数は Phase 3 の `decode_binary` の逆として再利用できる形（例 `encode_binary.mojo` または `params.mojo` 内）にする

### 4.2 `Connection.execute(sql, params)`
- `execute(self, sql: String, params: List[Param]) raises PgError -> Result`（既存の `execute(sql)` と並ぶオーバーロード）
- params が空でも常に `PQexecParams` を使う。単一文のみ（複数文は 42601 のサーバーエラー）。docstring に明記
- 結果の扱い（ステータス判定 / `PgError` への変換 / `PQclear`）は Phase 1 の `execute(sql)` と同じ経路を共有する
- パラメータ個数とプレースホルダ数の不一致、型不一致（例: int4 列に `Int` = int8）はサーバーエラー（`kind=Server`、sqlstate 付き）
  のまま通す（ローカルで検証しない。prepared は §4.3 で検証する）

### 4.3 PreparedStatement（`prepared.mojo`）
- `Connection.prepare(self, sql: String, param_types: List[UInt32] = []) raises PgError -> PreparedStatement[origin]`
  - 名前は接続ごとの連番（`pq_stmt_N`。N は `Connection` が保持するカウンタ）。ユーザーは名前を指定しない
  - `PQprepare` 後に `PQdescribePrepared` でパラメータ数と型 OID を取得して保持する
- `PreparedStatement[origin: ImmOrigin]`: `Connection` への `Pointer`（`Row` と同じ origin パターン）を持ち、`Connection` より長生きできない。
  `Movable`、`Copyable` にしない
  - `execute(self, params: List[Param]) raises PgError -> Result`（`PQexecPrepared`）。`len(params)` が `param_count()` と違えば
    サーバーに送らず `kind=USAGE`
  - `param_count() -> Int`、`param_type_oid(i) raises PgError -> UInt32`（範囲外は Phase 1 と同じ範囲エラー）、`name() -> String`
  - `__del__` で `DEALLOCATE <name>`（`escape_identifier` 不要: 自動生成名は `[a-z0-9_]` のみ）。失敗は無視（aborted tx 内・接続断）。
    フックは呼ばない
- rollback された tx 内で prepare された文はサーバー側で消える。その後の `execute` は `kind=Server`（26000）、`__del__` の DEALLOCATE 失敗は無視

### 4.4 Transaction（`transaction.mojo`）
- `Connection.transaction(self) raises PgError -> Transaction[origin]`: `PQtransactionStatus` が `PQTRANS_IDLE` でなければ `kind=USAGE`
  （サーバーのネスト BEGIN は WARNING にしかならないため）。`BEGIN` を発行（isolation level 等のオプションは作らない）
- `Transaction[origin: ImmOrigin]`: `Connection` への `Pointer` と「終了済みか」の状態、ROLLBACK 失敗ハンドラのコピーを持つ。`Movable` のみ
  - `commit() raises PgError`: `COMMIT` を発行。結果の `PQcmdStatus` が `ROLLBACK`（aborted 状態だった）なら `kind=Server`、sqlstate 空、
    message に「COMMIT resulted in ROLLBACK」相当を入れて投げる。いずれにせよ終了済みにする
  - `rollback() raises PgError`: `ROLLBACK` を発行し終了済みにする
  - `savepoint(name)` / `rollback_to(name)` / `release(name)`: 名前は `escape_identifier` を通す。空文字は `kind=USAGE`
  - `execute(sql)` / `execute(sql, params)` / `prepare(sql, param_types)`: `Connection` へ委譲（`conn.execute` も引き続き使える）
  - 終了済み（commit / rollback 後）での `commit` / `rollback` / savepoint 系 / `execute` / `prepare` は `kind=USAGE`
  - `__del__`: 未終了なら `ROLLBACK` を発行。失敗（`PQexec` NULL / `COMMAND_OK` 以外 / `CONNECTION_BAD`）したら
    `PgError`（接続断なら `kind=Connection`、それ以外は `kind=Server`）を作ってハンドラに渡す（`__del__` からは投げない）
- ハンドラ: `Connection.set_rollback_failure_handler(mut self, handler: def(PgError) thin)`。既定実装は
  `pq: implicit ROLLBACK failed: <message>` を stderr に 1 行出す。`transaction()` 生成時に `Transaction` へコピーされる
  （生成後に差し替えても既存の `Transaction` には反映されない。docstring に明記）

### 4.5 エラー（`errors.mojo` の拡張）
- `PgErrorKind` に `USAGE` を追加（6 番目）。クライアント側で検出した API 誤用に使う。sqlstate 等は空
- 既存の 5 種（LibpqLoad / Connection / Server / NullValue / TypeMismatch）と Phase 1 の規則は変えない

### 4.6 `_ffi`
- Phase 1 でバインド済みの `PQexecParams` / `PQprepare` / `PQexecPrepared` / `PQdescribePrepared` を使う（動作テストは今回が初）
- **未バインド**（discuss 時に `functions.mojo` を確認）の `PQnparams` / `PQparamtype` / `PQcmdStatus` を同じ流儀（`_dl_sym`、`thin abi`）で
  追加し、`test_ffi.mojo` のシンボル解決テストと PLAN / PROGRESS の本数表記（現在 50 本）を更新する

## 5. 受け入れ基準

### 5.1 HANDOFF §10 Phase 2
- `$1`〜`$n` のパラメータで全基本型（bool / int2 / int4 / int8 / float4 / float8 / text / bytea / NULL）を
  往復（INSERT → SELECT）でき、値が一致する
- SQL インジェクション文字列（`'; DROP TABLE x; --`）をパラメータで渡してもテーブルが残る
- `Transaction` を commit せずに破棄すると ROLLBACK される
- セーブポイントへのロールバックで部分的に取り消せる
- 上記すべてが PG 14 と PG 17 の両方で通る（`pixi run db-up` → `pixi run test`）。警告ゼロ、`fn` を使わない

### 5.1a 追加で押さえる異常系・境界（テストで固定する）
- 接続断中の tx 破棄: `pg_terminate_backend` で切った後に `Transaction` を破棄すると、テスト用ハンドラ（`set_rollback_failure_handler`）が
  `PgError(kind=Connection)` を受け取る
- バイナリ送信の境界値往復: 各整数型の最小 / 最大 / 0 / 負、`Float32` / `Float64` の NaN / +Infinity / -Infinity / -0.0、空 bytea、
  NUL を含む bytea、空文字列を `$1` で送り（INSERT → SELECT または `SELECT $1::<type>`）`get[T]` で一致する（NaN は `isnan` で判定）
- 型不一致パラメータ: int4 列に `Int`（int8）を渡すと sqlstate 付き（42804 等。値はテストで固定せず「非空」を assert）の
  `PgError(kind=Server)` になる
- rollback された tx 内で作られた prepared: その後の `execute` が `PgError(kind=Server, sqlstate=26000)`、破棄時の DEALLOCATE 失敗は無視され
  トレースバックを出さない
- `USAGE` 系: 二重 commit / rollback、終了後の savepoint・execute、tx 中の `transaction()`、prepared のパラメータ個数不一致、
  String パラメータの埋め込み NUL、空の savepoint 名
- aborted 状態での `commit()` が `PgError` になり、その後 `conn.execute` が通常どおり使える（tx が終了済み）
- `Transaction` を commit せずに破棄 → ROLLBACK（§5.1）に加え、破棄後に `PQtransactionStatus` が IDLE に戻る
- SQL インジェクション（§5.1）はテキスト送信（String）の経路で確認する

### 5.2 堅牢性（差し戻し対象。Phase 1 §5.2 を Phase 2 の API に拡張）
- どの入力・接続状態（未接続、接続失敗後、サーバー停止後、空 SQL、NULL パラメータ、パラメータ個数とプレースホルダ数の不一致、
  存在しない prepared 名、二重 commit / rollback、tx 破棄後の savepoint 操作）でもクラッシュ・トレースバックを出さず
  `PgError` で返す
- 正常系・異常系の両方で `PQclear` / `PQfinish` / `PQfreemem` が呼ばれ、二重解放しない。`PQexecParams` /
  `PQexecPrepared` に渡すバッファ（values / lengths / formats / types）は呼び出し中生存し、呼び出し後に解放される
- 解放済みポインタへのアクセスが型・所有権の上で起こらない（`PreparedStatement` / `Transaction` が `Connection` より長生きしない）
- 10,000 回のパラメータ付き execute / prepared execute / transaction（commit と rollback）のループでメモリ使用量が
  単調増加しない（`test_leak` に Phase 2 分のループを追加。判定方式は §5.3）

### 5.3 リーク測定方式（最初のタスクで切り替える）
- `tests/run_tests.sh` は `test_leak.mojo` だけ `mojo build` したバイナリで実行する（`mojo run` の常駐ヒープ約 100 MiB を避ける）
- 切り替え後に `TOLERANCE_PAGES` を 16 程度まで下げられるか実測し、下げられればその値にする。常駐ヒープが残り
  効果が無い場合は現状（payload 64 KiB + tolerance 256 + 早期 fail）を維持し、理由を PROGRESS に記録する
- 検出力の陽性対照: `PQclear` / `PQfinish` / `PQfreemem` のいずれかを消したコピーで FAIL することを impl が同じターンで実測し、
  サンプル列を PROGRESS に貼る（verify への「未実証」申し送りは不可）
- `pixi run check` では `test_leak` を 1 サーバー（PG 17）だけで回す（環境変数で片側 skip。`pixi run test` は両方）

### 5.4 品質基準（差し戻し対象。Phase 1 §5.1b と同じ）
- `pq` 直下の公開 struct / メソッドに docstring がある（`_ffi` はモジュール docstring のみでよい）
- `pixi run fmt` を実行しても差分なし（判定は §6 で修正後の `final_check.sh` による）
- `examples/params.mojo`（接続 → パラメータ付き INSERT/SELECT → トランザクション）が単体で実行できる。`pixi.toml` にタスクを追加する
- `pixi run package`（`mojo precompile src/pq -o build/pq.mojoc`）が通る

## 6. 持ち越し整理（最初の 1 コミットにまとめる）

前回 VERIFICATION 残留リスク / reflect 提案から、以下を Phase 2 の本体より前に片付ける:

1. docstring 3 件: `Connection.execute` の `CONNECTION` 説明に「sqlstate を伴わない切断」と明記 /
   `Row.get[T](name)` / `get_optional[T](name)` の NUL メッセージの引数名を委譲先に揃える（または docstring 側を直す）/
   `tests/test_leak.mojo` の `PAYLOAD_BYTES` docstring の `ABORT_PAGES` 説明を実装に合わせる
2. `PQ_MOJO_LIBPQ` 設定時はその 1 本のみでフォールバックしない、を正とする（Phase 1 REQ §4.1 の「→」表記を本書で上書き。
   loader の docstring は既にその旨）
3. `tests/final_check.sh` の 1/6 段（fmt）を `git diff` 判定からフォーマッタ自身の差分判定に変える
   （コピーに `mojo format` を適用して元と比較、または `--check` 相当）。コミット前の作業木でも `check` が回せること
4. 未使用の `OID_TEXT` / `OID_VARCHAR` / `OID_BPCHAR` / `OID_NAME` は削除せず、params の型 OID として使う形で残す
5. `pixi run check` の `test_leak` を 1 サーバーだけにする（§5.3）

## 7. テスト環境
- Phase 1 §6 と同じ（`tests/docker-compose.yml`、pg17 = 54317 / pg14 = 54314、`PQ_TEST_CONNINFO` で上書き、到達不能は失敗）
- `tests/fixtures/schema.sql` は `pqtest` スキーマのみ。Phase 2 のテーブルはテスト内で `CREATE TEMP TABLE` または
  `pqtest.<name>` を作って自分で片付ける（両サーバー・複数プロセスで衝突しない名前にする）

## 9. 後続フェーズへの申し送り（前回 reflect より）

- **research**: RESEARCH.md 冒頭に「Mojo 1.1.0 既知の落とし穴」節を `.gsd-lite/reflect/20261015-2308-phase1-sync-text-basic.md` の
  「次回への提案」3 項目目から転記する（`_ = x^` は破棄でない / `mojo run` の常駐ヒープ / `len(String)` 不可 → `byte_length()` /
  リスト literal は `List[Int]` 注釈必須 / `with` 内 `var` のスコープ / `rg` 無し・`pixi` はフルパス 等）。
  プローブを書く前に pixi 環境内の Mojo stdlib ソースの場所を 1 回特定し、`Origin` / `Pointer` / `Optional` 系の型名はそこから写す。
  既存のテスト環境ファイル（`tests/docker-compose.yml` の公開ポート等）も対象に含める
- **plan**: 検出力を主張するテスト（leak / フック呼び出し）の完了基準に「陽性対照で FAIL することを impl が同じターンで実測し
  PROGRESS にサンプル列を貼る」を最初から書く。`final_check.sh` の fmt 判定修正（§6-3）は最初のタスクに置き、それまでは
  「`check` はコミット後に回す」を検証コマンド節に書く。`PQ_TEST_LEAK_SERVERS=1` のような環境変数名は plan が決める
- **impl**: サブエージェントへの依頼文に (a) 型パラメータを持つ型は `Row[origin]` のようにフルに書く、(b) `fmt` は親が統合後に 1 回だけ、
  (c) scratch は `.gsd-lite/logs/<slug>/scratch/turn-NNN-<name>` 固定、を必ず入れる。PROGRESS の「追従先チェックリスト ✓」は素のシェルで
  再現できるコマンド（`grep -rn ...`）で書く
- **verify**: round 2 以降は「round 1 の格子の再確認 + 差し戻し分の回帰」に限定してよい（Phase 1 で半分以下の時間で合格判定できた実績）

## 8. 用語集
- **params / パラメータ**: `$1`〜`$n` に束縛する値。SQL 文字列に埋め込まない
- **prepared statement**: `PQprepare` でサーバー側に名前付きで登録した文。`PQexecPrepared` で実行
- **Transaction**: `BEGIN` から `COMMIT` / `ROLLBACK` までを表す所有型。破棄時に未完了なら ROLLBACK
- **savepoint**: トランザクション内の部分ロールバック点（`SAVEPOINT` / `ROLLBACK TO` / `RELEASE`）
- （Phase 1 の用語: 低レベル層 `_ffi` / 高レベル層 `pq` / conninfo / `PgError.kind`）
