# DECISIONS — phase5-polish-bench-readme

## D1. slug は `phase5-polish-bench-readme`
- **選択**: 既存の `phaseN-<内容>` 命名に揃える
- **却下**: `phase5-finish`（内容が名前から分からない）

## D2. psycopg 比較は pixi に python + psycopg を足して `pixi run bench-psycopg`
- **選択**: 誰でも同じ手順で再現できる。依存は conda-forge の psycopg（pixi の feature / 任意依存にできるかは research）
- **却下**: ホストの pyenv python3 で 1 回測って README に記録（再現手順が環境依存）／psycopg 比較をやらない（HANDOFF §8 の参考値を落とす）

## D3. 持ち越し 4 件と契約外提案 7 件の採否判断をスコープに入れる
- **選択**: テスト DB の後始末 / `fetch_all` busy-spin + `PQflush` -1 / `test_zero_copy` の接続固定費の調査 / 契約外提案 7 件の採否（採否自体は D5 以降）
- **理由**: 3 件は Phase 4 が「Phase 5 が引き取る」と書いたまま決定が無かった（reflect の提案）。仕上げで一掃する

## D4. 堅牢性の受け入れ基準を入れる（examples / bench も対象）
- **選択**: どの入力・出力状態でもトレースバックを出さず、既存データを失わない。examples / bench は `PgError` を表示して終了コード 1
- **却下**: 入れない（仕上げなので既存水準に任せる）。Phase 1〜4 と同じ水準を保つ

## D5. 契約外提案 7 件はすべて採用する
- **選択**: API 系 3 件（`notifications()` の `PQstatus == CONNECTION_BAD` 先行チェック／`AsyncConnection.wait_notifications(n, timeout_ms)`／
  `PgErrorKind.ENCODING` 新設）とテスト系 4 件（UTF-8 スキャナの 4 バイト境界 `f4 90 80 80` / `f5 80 80 80`／`UNLISTEN` 後に来ない／
  LISTEN していないチャンネルの無視／`LISTEN "Mixed Case"`）
- **トレードオフとして提示したもの**: `wait_notifications` は新 API（README とテストが増える）、`ENCODING` は既存テストの期待値変更と利用者の
  `except` 分岐が増える、LISTEN していないチャンネルの無視はサーバ側の振る舞いで pq のコードを通らない。ユーザーはそれでも全件採用を選んだ

## D6. Windows はレビュー + loader に `libpq.dll` を追加 + README に未検証明記
- **選択**: `_platform/poll.mojo` の `WSAPoll` 分岐を Microsoft Docs と照合して指摘を直し、`_ffi/loader.mojo` の探索リストに Windows の行（`libpq.dll`）を足す。
  照合結果は表で TRACE に残す。README に「コードはあるが未検証」と明記（HANDOFF §2 / §10 Phase 5）
- **却下**: レビューと README 明記のみ（HANDOFF §10「DLL 名が存在」を満たせない）

## D7. README は日本語
- **選択**: HANDOFF / .gsd-lite と揃える。docstring は英語のまま
- **却下**: 英語（公開時にそのまま使えるが、ユーザーは日本語を選択）／英日併記（ベンチ結果の転記が 2 箇所になる）

## D8. `wait_notifications(n, timeout_ms)` はタイムアウト時に集まった分を返す
- **選択**: 0〜n-1 件のリストを返し、エラーにしない。既存 `wait_notification` が None を返す設計（「来ない」は listen の通常の結果）と揃える
- **却下**: `TIMEOUT` を投げて集まった分を次回に持ち越す（既存 API と意味が食い違う）

## D9. `PgErrorKind.ENCODING` は UTF-8 検証失敗のすべてに適用
- **選択**: `result.mojo` / `decode_binary.mojo` の `_validated_utf8` と `async_conn.mojo` の通知検証をすべて `ENCODING` にする。
  既存テストの期待値 `TYPE_MISMATCH` → `ENCODING` を直す。メッセージ文言（`invalid UTF-8 at byte N of ...`）は変えない
- **却下**: 通知だけ（同じ「UTF-8 でない」が列と通知で kind が割れる）

## D10. テスト DB の後始末はテスト自身の DROP + `pixi run db-reset`
- **選択**: `test_notify` の `SQL_ASCII` テストが末尾で `DROP DATABASE`（失敗経路でも残らないよう `IF EXISTS` で先頭にも）。
  加えて `pixi run db-reset` タスク（`db-down` + `db-up` 相当）を足す。`check` は変えない
- **却下**: `db-reset` だけを `check` 先頭で呼ぶ（毎回コンテナ再作成で所要増）／テストの DROP だけ（途中終了で残った DB の扱いが要る）

## D11. 著作権名義は `0hya6in`
- **選択**: git の user.name と揃える。LICENSE は Apache-2.0 全文、README の末尾に `Copyright 2026 0hya6in` と Apache-2.0 の表記
- **却下**: 著作権者行を書かない

## D12. `test_zero_copy` の接続固定費は原因特定 + 記録、テスト側なら直す、src 側なら記録のみ
- **選択**: 仕上げフェーズで src の接続経路を変えるリスクを避ける。src 側なら README の既知の制限か VERIFICATION の残留リスクに書く
- **却下**: 必ず直す（接続経路の変更が全テストに波及し得る）／記録のみ（テスト側の原因なら安く直せる）

## D13. CI は今回も対象外
- **選択**: git remote が無く検証できない。remote ができたら別マイルストーン。README にはローカルの回し方だけ書く（Phase 1 D7 の継続）
- **却下**: GitHub Actions を未検証で置く

## D14. 実行パターンは現在の設定を維持
- **選択**: 全フェーズ Claude（`engine: claude`, `phase_engines: {}`）、model は research / plan / verify / reflect = claude-fable-5-1、impl = claude-opus-5、
  `subagents: auto`、`reflect: true`。research の対象は official_docs + similar_oss（local_projects は前例が薄いので外す）
- **却下**: impl も fable-5-1（コスト増）／impl を Codex（sandbox の検証が要る）
