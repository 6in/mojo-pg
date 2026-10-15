# DECISIONS — phase1-sync-text-basic

## D1. マイルストーン範囲は HANDOFF Phase 1 のみ
- **選択**: Phase 1（同期・テキスト・基本型）だけ
- **却下**: Phase 1+2（ループが長くなり `__del__` 内 ROLLBACK 通知など追加の設計判断が混ざる）、
  Phase 1〜3（Decimal/Date 等の自前型設計が必要で 1 マイルストーンとして大きすぎる）
- **理由**: 無人ループ 1 回分として手頃で、§10 Phase 1 の受け入れ条件が明確

## D2. 堅牢性の受け入れ基準を入れる
- **選択**: 入れる（REQUIREMENTS §5.2）。plan は初回タスクに含め、verify は差し戻し対象にする
- **理由**: FFI ラッパーでは解放済みポインタ・NULL ポインタ・二重解放が致命的

## D3. エラー型は単一 `PgError` + `kind`
- **確認済み事実**（discuss 時に Mojo 1.1.0 で検証）:
  - `def f() raises MyErr:` で独自 struct を投げられ、`except e` で `e.code` 等のフィールドにアクセスできる
  - 1 関数が宣言できる raise 型は 1 つ。`raises A | B` は構文エラー
  - 無型 `raises` の関数から typed-raises の関数を呼ぶと、`except e` で捕捉できる（表示は Writable 経由）
- **選択**: 公開 API は全て `raises PgError`。`kind` で LibpqLoad / Connection / Server / NullValue / TypeMismatch を区別
- **却下**: 関数ごとに別 struct（HANDOFF の ConnectionError / LibpqLoadError 等。`Connection.open` が
  ロード失敗と接続失敗の両方を起こすため 1 関数 1 型の制約と衝突する）、組み込み `Error` のみ（sqlstate 判定が文字列解析になる）
- **HANDOFF との差分**: §5.3 errors の `ConnectionError` / `LibpqLoadError` / `NullValueError` / `TypeMismatchError` は
  `PgError.kind` の値として表現する

## D4. テスト DB は env で指定、既定で PG 14 と 17 の両方
- **選択**: `PQ_TEST_CONNINFO` 未設定なら `run_tests.sh` が 54317 と 54314 の両方に対して全テストを実行。到達不能なら失敗
- **却下**: 既定 17 のみ（§10 共通条件「両方」を verify が別途回す必要がある）、未到達ならスキップ（docker 停止中に
  全通過と誤認するリスク）

## D5. `_ffi` は HANDOFF §5.2 の全関数を今回バインドする（ユーザー判断。推奨は「Phase 1 で使うものだけ」だった）
- **選択**: 非同期・通知・キャンセル・`PQexecParams` 系も含めて §5.2 の全関数を 1:1 で定義し、`PGnotify` レイアウトと全 enum も定義する
- **理由**: 低レベル層を早期に完成させ、後フェーズは高レベル層に集中する
- **リスク対策**: 未使用バインディングはロード時のシンボル解決と型シグネチャのレビューまでを検証範囲とし、動作テストは使うフェーズに委ねる
- **却下**: Phase 1 で使う関数だけ（未検証コードを増やさないが、後フェーズごとに `_ffi` を触る）

## D6. リーク検証は `/proc/self/statm` を読む（Linux 専用、macOS は skip）
- **選択**: テスト内で RSS を読み、ウォームアップ後の複数サンプルで単調増加していないことを判定。10,000 回は維持
- **却下**: 外部スクリプトで `ps` をサンプル（判定ロジックがシェル側に分散）、回数を 1,000 に減らす（1 接続あたり数 ms で不要）

## D7. CI はこのマイルストーンに含めない
- **選択**: ローカル `pixi run test` を受け入れ基準にする。CI は Phase 5 か別マイルストーン
- **却下**: 未検証のワークフローファイルだけ置く（remote が無く検証不能）

## D8. `Row.get[T]` は trait 式を第一、型別 getter をフォールバックとして許容
- **選択**: `get[T: FromPgText](col)` を目指す。research / plan で Mojo 1.1.0 の制約により不可と判明したら型別 getter に切り替えてよい（理由を PLAN.md に記録）
- **却下**: trait 式必須（書けなければ blocked でループが止まる）、最初から型別 getter（Phase 3 で型が増えると膨らむ）

## D9. 空 SQL は PgError、複数文は libpq どおり
- **選択**: `PGRES_EMPTY_QUERY` は `PgError(kind=Server)`。複数文は最後の結果（docstring に明記）
- **却下**: 空は空 Result（呼び出し側がミスに気づきにくい）、複数文を事前拒否（文字列リテラル内の `;` を誤検知）

## D10. 型照合は数値/bool/bytea が OID 完全一致、String は任意 OID
- **選択**: 拡幅変換は認めない。`get[String]` はどの列でもテキスト表現を返す（HANDOFF「上記以外は String」の一般化）
- **却下**: 整数の拡幅許容（テスト行列が増える）、String も完全一致（未知 OID 以外で生文字列が取れず不便）
- **付随決定**（discuss が判断）: bytea は hex 形式のみ。NOTICE は libpq 既定（stderr）のまま。エラーメッセージに conninfo を埋め込まない

## D11. 品質基準: docstring / `mojo format` 差分なし / examples/basic.mojo 単体実行 / `.mojopkg` パッケージ可
- **選択**: 4 つすべてを受け入れ基準（差し戻し対象）にする（ユーザーが全選択）
- **理由**: verify が機械的に判定でき、配布形態（.mojopkg）のビルドエラーを早期に発見できる

## D12. 実行パターン: すべて Claude、subagents=auto、reflect=true
- **選択**: engine=claude、phase_engines={}（現状維持）。モデル research/plan/verify/reflect = claude-fable-5-1、impl = claude-opus-5。
  subagents=auto、reflect=true
- **research 対象**: official_docs / similar_oss / local_projects（全選択）
- **却下**: 実装や検証を Codex / OpenCode に分ける案（初回マイルストーンは単一ホストで挙動を確認する）
