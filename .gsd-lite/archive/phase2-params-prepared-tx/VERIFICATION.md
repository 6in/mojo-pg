# VERIFICATION — phase2-params-prepared-tx

- 検証: 2026-10-16 / gsd-lite-verify（turn 10、verify round 1）
- 判定: **合格**（差し戻し 0 件。残留リスク 10 件を §6 に列挙 — すべて文書・テスト門番・極端入力の類で、データ損失・誤動作・クラッシュを伴うものは無い）
- 対象: `git diff main...HEAD`（34 ファイル、+9,424 / −1,191）。コード部分は `src/pq/{params,prepared,transaction,encode_binary}.mojo`（新規）、
  `src/pq/{connection,result,errors,__init__}.mojo` / `src/pq/_ffi/functions.mojo`（変更）、`tests/test_{params,prepared,transaction,savepoint,encode_binary}.mojo`（新規）、
  `tests/test_{leak,ffi,errors,result}.mojo` / `tests/{run_tests,final_check}.sh`（変更）、`examples/params.mojo`、`pixi.toml`
- 判定の基準: REQUIREMENTS §4〜§6 と PLAN「決めた事項」（REQ を読み替えた 14-1〜14-5 は PLAN を正とした）。`CLAUDE.md` / `AGENTS.md` は対象リポジトリに無い
- 進め方: コードレビューとセキュリティチェックを読み取り専用のサブエージェント 2 本に並行させ、親が自分のレビュー・堅牢性プローブ・テスト実行と統合して判定した。
  サブエージェントはファイルを変更していない（`git status --short` が空のまま）

## 1. 検証コマンド（クリーンな作業木から verify が自分で回したもの）

| コマンド | 結果 |
|---|---|
| `pixi run db-up` | pg17 / pg14 とも Healthy |
| `pixi run check`（最終判定、6 段） | **6/6 PASS**（`final_check: PASS`）。02:34:21 → 02:35:45 = **84 s**。3/6 `missing doc strings outside _ffi: 0`、6/6 `matched lines in build/final_check.log: 0`（`warning:` も `WARNING:` も 0 件） |
| `pixi run test`（両サーバー、test_leak も両方） | **exit 0**。`tests run` 26 件（13 ファイル × 2 サーバー）、`N failed`（N ≥ 1）0 件、`warning:` / `WARNING:` 0 件 |
| `grep -c 'implicit ROLLBACK failed' build/final_check.log` | **0**（既定ハンドラは `check` の全行程で一度も鳴っていない） |

テスト本数（各サーバー同数）: test_connection 28 / test_decode_text 49 / test_encode_binary 14 / test_errors 7 / test_ffi 7 / test_leak 12 /
test_loader_fail 1 / test_params 31 / test_prepared 13 / test_result 15 / test_savepoint 7 / test_smoke 4 / test_transaction 13 = **201 本 × 2**。

リーク系列（`pixi run test`、built binary、`TOLERANCE_PAGES = 256`）— Phase 2 の 4 系列はどちらのサーバーでも増分 0〜16 ページ:

```
PG17  execute(sql, params) [4642 ×8, 4658]   prepare/execute/drop [4659 ×9]
      transaction/commit   [4659 ×9]         transaction/drop     [4659 ×9]
PG14  execute(sql, params) [4678 ×9]         prepare/execute/drop [4679 ×9]
      transaction/commit   [4679 ×9]         transaction/drop     [4679 ×9]
```

Phase 1 の 4 系列も平坦（PG17 connect `[4087, 4088 ×8]`、PG14 `[4174, 4175 ×8]`）。この回は +83 ページの一段は出なかった。

## 2. 受け入れ基準の達成状況

### REQ §5.1（HANDOFF §10 Phase 2）
- 全基本型の `$1`〜`$n` 往復（bool / int2 / int4 / int8 / float4 / float8 / text / bytea / NULL）: `test_params` の 10 列テーブル往復 + `column_type_oid` 10 個の一致 ✓
- SQL インジェクション文字列をテキスト経路で: `test_params`（count 1、原文一致、テーブル残存）✓
- commit せずに破棄 → ROLLBACK: `test_transaction`（count 0、`PQTRANS_IDLE`）✓
- セーブポイントで部分取り消し: `test_savepoint`（count 1）✓
- PG 14 / PG 17 両方で通る、警告ゼロ、`fn` 無し: 上の表 / `grep -rnE '^[[:space:]]*fn ' src tests examples hello.mojo` = 0 件 ✓

### REQ §5.1a（追加の異常系・境界。PLAN 決めた事項 14 の読み替えを含む）
- 接続断中の tx 破棄でハンドラが `Connection|...` を受ける ✓（`test_transaction`）
- 境界値往復（整数の端 / NaN / ±Inf / −0.0 のビット保存 / 空・NUL 入り bytea / 空文字 / 64 KiB × 2）✓（`test_params` 8 本 + `test_encode_binary` 14 本）
- 型不一致: 14-2 の題材（`Bool` → int4 = 42804、`Int(3000000000)` → int4 = 22003、`Int(5)` は成功）✓
- rollback 後の prepared: 14-1 どおり **成功**を固定し、26000 は手動 `DEALLOCATE` 後の `execute` で固定、破棄は静か ✓（`test_prepared`）
- USAGE 系 6 種（二重 commit / rollback、終了後の savepoint・execute・prepare、tx 中の `transaction()`、個数不一致、String の NUL、空 savepoint 名）✓
- aborted 状態の `commit()` → `SERVER` / sqlstate 空 / message に `ROLLBACK`、その後 `conn.execute` が通る ✓
- 破棄後に `PQtransactionStatus` が IDLE ✓

### REQ §5.2（堅牢性）
- クラッシュ・トレースバック無し: テストと §4 の格子プローブのすべてで `PgError` が返った（下記）✓
- `PQclear` / `PQfinish` / `PQfreemem`: `_take_result` の全失敗経路、describe 失敗時の DEALLOCATE 結果、2 つの `__deinit__` の生 `PQexec` 結果すべてで `PQclear`。
  `Result` に渡した `PGresult` は 1 回だけ ✓。陽性対照（PROGRESS turn 3 / 8）が 5 経路で FAIL することを impl が実測済み
- バッファ生存: `_ParamBuffers` は `bufs` を全部作ってからアドレスを取り、`_ = buffers^` / `_ = sql^` / `_ = name^` は 4 箇所すべて libpq 呼び出しの後 ✓。
  stride は `lengths` / `formats` が `List[c_int]`、`values` が `List[Int]`（ポインタ幅）、`types` が `List[UInt32]` ✓
- 解放済みポインタ: `PreparedStatement[origin]` / `Transaction[origin]` は `origin_of(self)` の `Pointer[Connection]` で `Connection` より長生きできない。`Movable` のみ（`Copyable` 無し）✓
- 10,000 回ループ 4 本で RSS が単調増加しない（上の系列）✓

### REQ §5.3（リーク測定方式）
- `run_tests.sh` が `test_leak.mojo` だけ `mojo build` → `build/test_leak` を実行 ✓。`TOLERANCE_PAGES` は 16 系列の実測（+83 の一段 2 回）で 256 維持、理由は PROGRESS turn 3 ✓
- 陽性対照: `PQclear`（Result）/ `PQfreemem`（escape_literal）/ prepared の DEALLOCATE 結果 / tx の ROLLBACK 結果 の 4 経路で FAIL のサンプル列が PROGRESS に貼られている ✓
- `check` は `PQ_TEST_LEAK_SERVERS=1` で 1 サーバー、`test` は両方 ✓（ログに `skipped (PQ_TEST_LEAK_SERVERS=1)` が 54314 側で 1 行）

### REQ §5.4（品質）
- docstring: `check` 3/6 段 `missing doc strings outside _ffi: 0` ✓
- fmt 差分 0: `check` 1/6 段（コピーに明示ファイル列で `mojo format` → `diff -r`）PASS ✓
- `examples/params.mojo` 単体実行 + `pixi.toml` の `example-params` ✓（4/6 段で basic と params の 2 本）
- `pixi run package`: 2/6 段 PASS（警告ゼロ）✓

### REQ §6（持ち越し整理）
- docstring 3 件（`execute` の CONNECTION 説明 / `Row.get[T](name)` の NUL メッセージ / `PAYLOAD_BYTES`）: 差分で確認 ✓
- `PQ_MOJO_LIBPQ` は 1 本のみ: `loader.mojo:10` の既存文言（コード変更なし）✓
- `final_check.sh` 1/6 段を `git diff` 判定からフォーマッタ自身の差分判定に ✓（コピー先が `.gitignore` 配下で no-op になる欠陥を impl が陽性対照で発見・修正済み）
- `OID_TEXT` 等 4 定数は削除せず残す ✓（`OID_TEXT` は `test_prepared` が参照）
- `check` の leak 1 サーバー化 ✓

### REQ §4（機能要件）の API 表面
- `Param` の `@implicit` 19 本 + `null()` / `null(oid)` + `oid()` / `is_null()` / `is_binary()`、値アクセサ無し ✓
- `Connection.execute(sql, params)` は空 params でも `PQexecParams`、`resultFormat` 0 固定、`result_format` 引数無し ✓
- `Connection.prepare(sql, param_types=[])` → `PreparedStatement[origin]`（`pq_stmt_N` 接続ごと連番、`PQdescribePrepared` で型保持、`execute` / `param_count` / `param_type_oid` / `name`、`__deinit__` で DEALLOCATE・失敗無視・フック無し）✓
- `Connection.transaction()`（非 IDLE は USAGE、`CONNECTION_BAD` は CONNECTION = 14-3）→ `Transaction[origin]`（commit / rollback / savepoint / rollback_to / release / execute ×2 / prepare、`__deinit__` で ROLLBACK → 失敗はハンドラ）、
  `set_rollback_failure_handler`（生成時コピー、既定は stderr 1 行）✓
- `PgErrorKind.USAGE = 5`（`"Usage"`）、`_ffi` 53 本（`PQcmdStatus` / `PQnparams` / `PQparamtype`）✓

## 3. セキュリティチェック（サブエージェント + 親の確認）

- SQL 組み立て箇所は 4 種のみ: `DEALLOCATE <name>`（名前は `_next_stmt_name` が生成する `pq_stmt_<Int>` で `[a-z0-9_]` のみ。パッケージ内で `PreparedStatement[...](...)` を構築する箇所は `connection.mojo` / `transaction.mojo` の 2 箇所だけ）、
  `SAVEPOINT` / `ROLLBACK TO SAVEPOINT` / `RELEASE SAVEPOINT`（必ず `escape_identifier` = `_reject_nul` → `PQescapeIdentifier`）、`BEGIN` / `COMMIT` / `ROLLBACK`（定数）。パラメータ値は SQL 文字列に一切触れない ✓
- 入力検証: String パラメータの NUL は FFI 前に USAGE（位置 `$N` のみ、値は非表示）、個数不一致は FFI 前に USAGE、`param_type_oid` は負も範囲外も拒否、空 savepoint 名は USAGE ✓
- 秘密情報: ソース・テスト・例にあるのは docker テスト DB（127.0.0.1:54317 / 54314、`pq` / `pq`）のみ。`run_tests.sh` の見出しは host:port だけでパスワードをログに出さない。`Param` は `Writable` / `Stringable` 非準拠で値を返すアクセサが無い ✓
- シェル: `final_check.sh` の `find -print0 | read -d ''`、配列・変数はすべてクォート、`eval` 無し、`rm -rf` は固定相対パス `build/fmtcheck` ✓
- デストラクタ: どちらも raise せず、接続断（NULL 結果）でも `PQclear` 対象が無いことを判定して安全に抜ける ✓

## 4. 堅牢性の格子（round 1。ライブラリなので「入力経路 = API 引数、出力経路 = 戻り値 / stderr、例外クラス = `PgErrorKind`」に読み替えた）

入力経路 × 状態のうちテストが固定しているもの: sql（空 / NUL / 複数文 / aborted tx 内）、params（NULL / 空リスト / NUL / 境界値 / 64 KiB / 個数不一致 / 型不一致 / 12 本混在）、
savepoint 名（空 / 引用符 / 大文字 / 存在しない / release 後）、prepared（構文エラー / 複数文 / 手動 DEALLOCATE 後 / ROLLBACK 後 / 接続断後）、tx（二重終了 / 終了後の全操作 / ネスト / INERROR からの commit / 接続断中の破棄）。

テストに無いセルを `scratch/turn-010-grid/probe.mojo`（PG17）で一括プローブした。**全セルが `PgError` で返り、トレースバック無し**:

| セル | 結果 |
|---|---|
| savepoint / rollback_to / release の名前に NUL | `TypeMismatch` / `embedded NUL byte in s`、tx は INTRANS のまま、`commit()` が通る |
| `prepare("SELECT $1::int4", [23, 25, 20])`（ヒントがプレースホルダより多い） | サーバーが 3 パラメータとして受理（`param_count() == 3`）、`execute([Int32(7)])` は USAGE（`takes 3 parameters, got 1`）。「describe の結果が正」の docstring どおり |
| `prepare("SELECT $1", [999999])`（存在しない OID） | `Server` / `XX000` / `cache lookup failed for type 999999`、次の `prepare` は通る（番号は消費され `pq_stmt_3`） |
| INERROR のまま tx を破棄 | `__deinit__` の ROLLBACK が成功し IDLE、ハンドラは鳴らない |
| 0 パラメータの prepared（`SELECT 42`） | `param_count() == 0`、`execute(List[Param]())` が 42、`execute([Int32(1)])` は USAGE、`param_type_oid(0)` は `out of range (0..-1)` |
| tx 生存中に `conn.execute("COMMIT")` を手で送ってから破棄 | COMMIT は効いている（行は残る）。`__deinit__` の ROLLBACK に対しサーバーが `WARNING:  there is no transaction in progress` を stderr に出す（libpq の notice processor）。データ損失無し |
| 200 パラメータ（`$1 + ... + $200`、Int32） | 20100（stride のずれ無し） |
| 70 文字の savepoint 名 | サーバーが 63 文字に切り詰める `NOTICE:` を 3 回出すが savepoint / rollback_to / release は全部通る |
| tx 内の空 SQL | `Server` / `empty query`、tx は INTRANS のまま（abort しない）、`commit()` が通る |
| `Optional[String]` に NUL | `Usage` / `embedded NUL byte in parameter $2` |
| tx 生存中に `pg_terminate_backend` → `tx.commit()` | `Connection` / `no connection to the server`、2 回目の `commit()` は `Usage`（終了済み）、破棄・接続破棄とも静か |

## 5. 文書の主張の照合

- 追従先チェックリスト全行を素のシェルで再実行: libpq 53 / 53、`fifty` 0、`five failure` 系 0、`PQexec(` 4 行（connection ×2 / prepared / transaction）、`PQfreemem(` 2 行、
  `__def test_` leak 12 / params 31 / prepared 13 / transaction 13 / savepoint 7 / encode 14、`fn` 0、`__del__` 0、`examples/params.mojo` が `pixi.toml:18` と `final_check.sh:120` の両方、`PQ_TEST_LEAK_SERVERS` 5 行 ✓
- `grep -n '50 本' .gsd-lite/PLAN.md .gsd-lite/PROGRESS.md` の 2 件はチェックリスト自身の行と turn 3 の履歴で、PLAN T7「PLAN 訂正（turn 9）」の説明どおり陳腐化した主張ではない ✓
- PLAN 冒頭の所要の目安「80〜115 s」に対し今回の `check` は 84 s で範囲内 ✓
- PROGRESS turn 9 の「`pixi run test` は回していない」は正直な記述で、verify が今回回して両サーバー PASS を確認した ✓
- PLAN 訂正 4 件（turn 3 fmt no-op / turn 4 シフト / turn 6 `[1, 2, "x"]` → `Int32` / turn 7 `_prepare_parts`）は要件・決定に反しない範囲で、理由が実測つきで書かれている ✓
- 冒頭要約と本文の不一致: 無し

## 6. 残留リスク（差し戻さない。次マイルストーンの「持ち越し整理」候補として番号付き）

文書・テスト門番（Phase 1 の残留 docstring 3 件と同じ扱い。まとめて 1 コミットで直せる規模）:

1. **`src/pq/prepared.mojo:130-131` の docstring が実態より広い**: `PreparedStatement.execute` は「`Connection.execute(sql, params)` と同じ型表」と言うが、`PQexecPrepared` は `paramTypes` を送らないので
   `prepare("SELECT $1::int4")` に `[1]`（`Int` = int8 8 byte）を渡すと `22P03`（`conn.execute` 側は assignment cast で成功する非対称。PLAN turn 6 訂正）。
   `src/pq/__init__.mojo` §Parameters の「the OID sent in `paramTypes`」も prepared 経路には当たらない。`grep -rn 22P03 src/` が 0 件なので、
   「prepared では `PQprepare` 時点の型と同じ幅の値（`$1::int4` なら `Int32`）を渡す」を両方に 1 文ずつ足す
2. **`tests/final_check.sh` 6/6 段が `implicit ROLLBACK failed` を数えていない**: 既定ハンドラの出力は `warning:` / `WARNING:` のどちらにも一致しないので、暗黙 ROLLBACK が失敗し始めても `check` は PASS する。
   PLAN T5 (b)-12 / T7 (d) は手動 `grep -c` で 0 を確認する運用。grep パターンに `|implicit ROLLBACK failed` を足せば機械化できる（見出しにこの文字列を入れない）
3. **`tests/test_prepared.mojo:543-544` の `message.find("1") >= 0` は落ちない断定**: 個数不一致メッセージには `pq_stmt_1` も含まれるので「got 1」の確認になっていない（PLAN T4 (b)-2 の文面どおりではある）。
   `"takes 3 parameters, got 1"` の部分一致にする。verify のプローブでは `takes 0 parameters, got 1` / `takes 3 parameters, got 1` を実測しており挙動自体は正しい
4. **`Connection.__init__` の docstring に `_stmt_counter` / `_rollback_failure_handler` が無い**（PLAN 決めた事項 23）。フィールド docstring はあるので 3/6 段は通る
5. **`param_type_oid(0)` の 0 パラメータ文での文言 `out of range (0..-1)`**（cosmetic）
6. **savepoint 名の NUL メッセージが `embedded NUL byte in s`**（`escape_identifier` の引数名 `s`）。`Transaction` の docstring は kind だけを約束しているので矛盾ではないが、Phase 1 の `name` 問題と同型。
   docstring に「message は `escape_identifier` の引数名 `s` を指す」と書くか、savepoint 側で `_reject_nul(name, "name")` を先に呼ぶ

仕様の読み方（REQ / DECISIONS に 1 行足すか、docstring で明示する）:

7. **REQ §4.4「接続断なら `kind=Connection`」より実装は狭い**: `Transaction.__deinit__` の分類は `_take_result` と同じ Phase 1 規則（sqlstate 付き FATAL は `SERVER`、次の呼び出しで `CONNECTION`）なので、
   `transaction()` 直後に外部から backend を kill され、間に `execute` が無いまま破棄されると ROLLBACK 自体が `57P01` を受けてハンドラには `SERVER`（sqlstate `57P01`）が渡る。
   REQ §5.1a-1 の経路（同じ接続で `pg_terminate_backend` → `execute` が CONNECTION で raise → 破棄）は `CONNECTION` でテスト済み。`__deinit__` の docstring はこの規則を明記している
8. **tx 生存中に `conn.execute("COMMIT")` / `"ROLLBACK"` を手で送る混用**: `Transaction` は自分の `_done` を知らないので破棄時の ROLLBACK がサーバー WARNING（stderr）になる。データは手動 COMMIT の結果どおりで損失は無い。
   `Transaction` docstring の「conn.execute との混用」節に 1 文足す

極端入力・設計上の受容（Phase 3 以降の判断材料）:

9. **`c_int(len(_data))` の範囲検査が無い**（`params.mojo:455`）: 2 GiB 以上の bytea パラメータで `paramLengths[i]` が負に折り返し、libpq 側で範囲外読みになり得る。
   サーバーのフィールド上限は 1 GiB − 1 なので成功し得ない入力だが、`PgError` ではなくクラッシュになる。`len > 0x3FFFFFFF` で USAGE を投げる 1 行が候補（テストで 2 GiB を確保するのは非現実的なので単体で検査できる形に）
10. **`_next_stmt_name` の `MutUntrackedOrigin` 書き込み**（PLAN 決めた事項 9 が受容）と、**`Transaction` / `PreparedStatement` 生存中でも `conn` への `mut self` 呼び出し（`set_rollback_failure_handler`）が Mojo 1.1.0 では通る**こと
    （`test_transaction.mojo:1090` が実例）。origin は `conn` の破棄・移動を防いでおり、`Connection` に `close()` が無い現状では生存ポインタの危険は無い。
    将来 `close(mut self)` を足すときに `Transaction` 生存中の呼び出しを型で防げないことを設計メモに残す。`PreparedStatement.__init__` が公開で任意の `name` を取れる点も同類（自分の接続への自己注入のみで権限境界は無い）

## 7. マージ

- リモート無し（`git remote get-url origin` → `No such remote 'origin'`）→ (a) ローカルで `main` に `--no-ff` マージ。ブランチ `gsd-lite/phase2-params-prepared-tx` は残す
- `reflect: true` なので `phase: "reflect"` / `next_command: "/gsd-lite-reflect"` に遷移
