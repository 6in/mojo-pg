# DECISIONS — phase2-params-prepared-tx

## D1. マイルストーン範囲は HANDOFF Phase 2 の全部
- **選択**: params + PreparedStatement + Transaction（セーブポイント含む）
- **却下**: Phase 2 前半のみ（Transaction を次に回す。ループは短いが `__del__` 内 ROLLBACK の設計判断を先送りするだけ）、
  Phase 2 + Phase 3 の一部（バイナリ結果形式が混ざり verify の格子が倍になる）
- **理由**: §10 Phase 2 の受け入れ条件 4 つが明確で、無人ループ 1 回分として手頃

## D2. 堅牢性の受け入れ基準を入れる（差し戻し対象）
- **選択**: Phase 1 D2 と同じ。plan は初回タスクに含め、verify は差し戻す
- **理由**: `PQexecParams` のバッファ生存と `Transaction.__del__` の ROLLBACK が主戦場で、解放漏れ・二重解放が致命的

## D3. 持ち越しの小物は最初の 1 コミットで全部片付ける
- **選択**: docstring 3 件 + REQ 文言（`PQ_MOJO_LIBPQ` フォールバック無しを正とする）/ `final_check.sh` の fmt 判定 /
  未使用 OID 定数 4 件（params の型 OID として使う形で残す）/ `check` の leak 1 サーバー化
- **理由**: どれも小さく、Phase 2 本体の前に済ませると verify の残留リスク一覧が短くなる

## D4. リーク測定は `mojo build` したバイナリで回す
- **選択**: `run_tests.sh` が `test_leak.mojo` だけ `mojo build` してから実行。tolerance を 16 程度に戻せるか最初のタスクで実測し、
  効果が無ければ現状維持にフォールバック（理由を PROGRESS に記録）
- **却下**: 現状維持（tolerance 256 ページは 1 MiB 相当の漏れを見逃す）、`mallinfo2()` を FFI で読む（glibc 専用でさらに狭くなる）
- **出典**: reflect「次回への提案」Minus 2 / Interesting 3

## D5. パラメータは `List[Param]`（`Param` は variant 構造体、`@implicit` 構築）
- **確認済み事実**（discuss 時に Mojo 1.1.0 で検証）: `@implicit def __init__(out self, v: Int)` / `String` / `StringLiteral` の
  オーバーロードを持つ struct は `use([1, "a", Param.null()])` のリスト literal から `List[Param]` に変換できる
  （`StringLiteral` 用のオーバーロードが別途必要）
- **選択**: `execute(sql, params: List[Param])`。`Param` は Bool / Int16 / Int32 / Int64 / Int / Float32 / Float64 / String /
  `List[UInt8]` / NULL を保持
- **却下**: `Params` ビルダー（implicit 変換に依存しないが冗長）、ヘテロ可変長引数 `*args: *Ts`（1.1.0 の可変長ジェネリクスで
  blocked になるリスクが高い）

## D6. 送信形式は HANDOFF §5.3 どおり（数値 / bool / bytea はバイナリ + OID 明示、String はテキスト + OID 0）
- **選択**: Int16/Int32/Int64/Int/Float32/Float64/Bool/bytea はビッグエンディアンのバイナリ（`Int` は int8 = OID 20）、
  String はテキストで OID 0（サーバー推論）、NULL は OID 0 の NULL
- **却下**: 全部テキスト（実装最小だが float の往復精度と HANDOFF との差分）、全部バイナリ（String に OID 25 を付けると
  varchar/name 列でサーバー側キャストが要る）
- **付随**: エンコードは Phase 3 の `decode_binary` の逆として再利用できる形（`encode_binary` 相当）で書く

## D7. PreparedStatement は名前自動 + `__del__` で DEALLOCATE
- **選択**: `conn.prepare(sql, param_types=[])` が接続ごとの連番名（`pq_stmt_N`）を付け、`PreparedStatement.execute(params)` で実行。
  破棄時に `DEALLOCATE`（失敗は無視。接続断なら不要）。`Connection` への参照（`Row` と同じ origin パターン）を持ち、長生きできない
- **却下**: 名前ユーザー指定 + DEALLOCATE（HANDOFF のシグネチャだが名前衝突を 42P05 に任せることになる）、
  DEALLOCATE しない（接続が閉じるまでサーバー側に残る）
- **HANDOFF との差分**: `prepare(name, sql, param_types)` → `prepare(sql, param_types)`

## D8. `Transaction.__del__` の自動 ROLLBACK 失敗はフック関数で通知（既定は stderr）
- **確認済み事実**: struct フィールドに `var handler: def(PgError) thin` を持て、非キャプチャの `def` を代入・呼び出しできる
  （`def(PgError)` だけだと trait 型なのでフィールドにできない。`thin` が必要）
- **選択**: ハンドラは `def(PgError) thin` 型。既定実装は「`pq: implicit ROLLBACK failed: <message>`」を stderr に 1 行
- **却下**: stderr 固定（ユーザー判断: 差し替え可能にしたい）、無視（生きている接続で失敗しても気づけない）
- **出典**: HANDOFF §11「`__del__` 内のエラー」を Phase 2 で決定

## D9. フックは Connection ごとに登録（`conn.set_rollback_failure_handler(handler)`）
- **選択**: `Connection` がハンドラを保持し、`transaction()` が生成時にコピーして `Transaction` に持たせる。既定は stderr 実装
- **却下**: `transaction(on_rollback_failure=...)`（毎回指定が必要）、モジュールグローバル（Mojo でグローバル可変状態を扱いにくい）

## D10. aborted 状態での `commit()` は `PgError` を投げる
- **事実**: PostgreSQL は aborted トランザクションでの `COMMIT` をエラーにせず `ROLLBACK` として成功させる（`PQcmdStatus` が `ROLLBACK`）
- **選択**: `commit()` 後に `PQcmdStatus` が `ROLLBACK` なら `PgError(kind=Server, sqlstate 空, message="COMMIT resulted in ROLLBACK ...")`。
  `Transaction` は終了済み（`__del__` は何もしない）
- **却下**: libpq どおり成功扱い（書き込み消失に気づけない）

## D11. API 誤用は `PgErrorKind.USAGE` を追加して表現
- **選択**: クライアント側で状態を追跡し、二重 `commit` / `rollback`、終了後の savepoint 操作、`PQtransactionStatus` が
  IDLE でないときの `transaction()`、終了後の `tx.execute` は `kind=USAGE`（サーバーに送らない）
- **却下**: 既存 kind（Server、sqlstate 空）で表現（サーバーエラーと区別できない）、サーバー任せ（ネスト BEGIN は WARNING で通る）
- **HANDOFF との差分**: `PgError.kind` に 6 番目の値 `USAGE` を追加

## D12. Transaction は `execute` を委譲で持ち、`conn.execute` も使える
- **選択**: `Transaction.execute(sql)` / `execute(sql, params)` / `prepare(...)` を `Connection` へ委譲。`conn.execute` は従来どおり呼べる
  （`Connection.execute` は `self` 不変なので `Transaction` は `ImmOrigin` の `Pointer[Connection]` で足りる。`Row` と同じパターン）
- **却下**: `conn.execute` だけ（どの tx の中か見えにくい）、tx が conn を排他借用（`execute` を `mut self` に変える Phase 1 API 変更と
  排他チェックの挙動依存）

## D13. discuss が判断した付随事項（ユーザーに聞かずに決めた小物）
- `execute(sql, params)` は params が空でも常に `PQexecParams` を使う（単一文のみ。複数文は 42601 のサーバーエラー。docstring に明記）
- `result_format` 引数は Phase 2 では作らない（取り得る値が Text だけになるため。Phase 3 で追加）
- `Transaction` の isolation level / READ ONLY オプションは作らない（プレーンな `BEGIN`。必要なら後続フェーズ）
- savepoint 名は `escape_identifier` を通して SQL に埋め込む（HANDOFF §5.3）。空文字は `USAGE`
- `PreparedStatement.__del__` の `DEALLOCATE` 失敗は無視（aborted tx 内や接続断で起こる。フックは呼ばない）
- `PQexecParams` のテキストパラメータは NUL 終端で渡るため、String パラメータに NUL バイトが含まれる場合は Phase 1 E10 と同じく
  送信前に `PgError`（kind=USAGE）で拒否する。バイナリ送信の bytea は長さ付きなので NUL を含んでよい
- `Param` の `Int` は int8（OID 20）。`Float32` / `Float64` の NaN / ±Infinity はバイナリで送れる（IEEE754 そのまま）
- `PQnparams` / `PQparamtype` / `PQcmdStatus` は未バインド（discuss 時に確認）なので `_ffi` に追加する（Phase 1 D5 の「全関数」は
  HANDOFF §5.2 の表の範囲で、この 3 つは表に無かった）

## D14. `Param` は `Optional[T]` と型付き NULL も受け付ける
- **選択**: `Optional[T]` からの `@implicit` 構築（`get_optional` との対称）と `Param.null(oid)`（`SELECT $1` のように型が推論できない文脈用）
- **却下**: 基本 9 型 + `null()` だけ（最小だが往復コードで `if v: ... else: Param.null()` が毎回要る）

## D15. PreparedStatement はパラメータ数をローカル検証し、`name()` を公開
- **選択**: `prepare` 直後に `PQdescribePrepared` → `PQnparams` / `PQparamtype` を保持。`execute(params)` の個数不一致は `kind=USAGE`。
  `param_count()` / `param_type_oid(i)` / `name()` を公開
- **却下**: 付属機能なし（個数不一致を 08P01 のサーバーエラーに任せる。プロトコルエラー扱いになり接続状態が不安定）

## D17. 実行パターン: 現在の設定を維持（すべて Claude、subagents=auto、reflect=true）
- **選択**: engine=claude、phase_engines={}。model: research / plan / verify / reflect = claude-fable-5-1、impl = claude-opus-5。
  subagents=auto、reflect=true。research 対象: official_docs / similar_oss / local_projects（全選択）
- **却下**: 実装だけ Codex / レビューだけ Codex（Phase 1 が同設定で 16 ターン完走しており、変える理由がない）

## D18. reflect 提案のうちスキル側の改善は今回は適用しない
- 対象: research スキルへの「stdlib シンボル名を grep で確定」手順、impl スキルのサブエージェント依頼文テンプレ 3 行、
  verify round 2 の「格子の再確認 + 回帰のみ」を既定化、`gsd-lite-loop.sh` の `ended_at`
- **理由**: スキルはテンプレートからの配置物で、discuss が独自変更すると次回の配置時に衝突する。代わりに REQUIREMENTS §9 で
  research / plan / impl に同じ内容を申し送る

## D16. 追加で固定する異常系（ユーザーが 4 つ全選択）
- 接続断中の tx 破棄でフックが呼ばれる / バイナリ送信の境界値往復 / 型不一致パラメータがサーバーエラー /
  rollback された tx 内で作られた prepared の挙動。REQUIREMENTS §5.1a に展開
