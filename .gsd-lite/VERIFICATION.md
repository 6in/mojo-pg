# VERIFICATION — phase4-async-cancel-notify

- 作成: 2026-10-17 / gsd-lite-verify（turn 11 = round 1）
- 対象: `git diff main...HEAD`（`20524cd` 起点、19 コミット。`src/` `tests/` `examples/` `pixi.toml` で 28 ファイル +5,482 / -242）
- 対象リポジトリの `CLAUDE.md` / `AGENTS.md`: 無し（規約観点は HANDOFF.md §7・§9・§10 と PLAN「決めた事項」1〜17）
- 判定: **round 1 = 指摘あり（差し戻し）**。誤動作を伴う指摘 1 件（`timeout_ms` の 32 bit 切り捨て）+ D12 との整合 1 件（通知文字列の UTF-8 無検証）を PLAN **F1** に
  まとめた（文書・例の軽微 5 件を同梱）。受け入れ基準 §5.1 の 4 件・§5.4 の 5 項目はすべて満たしており、`check` は 6/6 PASS。round 2 は F1 の差分の回帰 + §3 の格子の再確認だけを行う
- 実行エンジン: Claude Code（Claude Fable 5.1）

## 1. round 1 の進め方

- 並列レビュー（`subagents: auto`）: コードレビュー（既存テストの期待値変更ゼロの照合 / リファクタの挙動保存 / UTF-8 スキャナ / テストが完了基準を検証しているか /
  `run_tests.sh` / 文書の主張）とセキュリティチェック（FFI メモリ安全 / バッファ / 入力検証 / インジェクション / 秘密情報 / 状態機械の堅牢性 / プラットフォーム分岐）を
  **読み取り専用**のサブエージェント 2 本に分けて並行。テスト実行・プローブ・判定・文書更新・マージは親だけ
- 親は同時に (1) クリーンな `pixi run check`（ログ `scratch/turn-011-check.log`）、(2) `src/pq/async_conn.mojo`（1,520 行）と `src/pq/_platform/poll.mojo`（265 行）の
  通読レビュー、(3) 堅牢性の格子プローブ（§3、`scratch/turn-011-probe-grid.mojo` / `.log`）、(4) 追従先チェックリストの再実行（`scratch/turn-011-checklist.log`）を行った

## 2. 受け入れ基準との突き合わせ

TRACE.md §2 の対応表（REQ §5.1 の 4 件 / §5.2 の 4 項目 / §5.3 / §5.4 / §4.8〜§4.10）を起点に、担うテスト関数が存在し主張どおりの assert をしていることを
コードレビュー側がスポットチェックし、親が `pixi run check` で全部を再実行した。

| 基準 | 確認 |
|---|---|
| §5.1-1 `pg_sleep(2)` 送信中にカウンタが進む | `test_poll_result_counts_while_sleeping`（check ログ: PASS 2,007 ms）。判定は「`None` の回数 ≥ 1 かつ経過 ≥ 2,000 ms」の両方 |
| §5.1-2 `cancel()` で `pg_sleep(10)` が 1 s 以内に中断、`57014` | `test_cancel_stops_a_running_statement`（PASS 143 ms。cancel 発行〜raise < 1,000 ms を単調時計で断定） |
| §5.1-3 別接続の `NOTIFY ch, 'payload'` を受け取る | `test_wait_notification_receives_both_payloads`（payload 2 件・順序・`backend_pid` 一致・3 回目は `None`） |
| §5.1-4 応答しない接続先でタイムアウト付き待ちが規定時間で戻る | `test_connect_blocking_times_out`（blackhole 54399、PASS 623 ms、500 ≤ 経過 < 1,500 ms）+ `wait_readable(50)` → `TIMEOUT` |
| §5.2 状態 9 種 × 入力でクラッシュせず `PgError` | `test_async` 29 件 / `test_notify` 9 件 / `test_poll` 9 件（両サーバー `0 failed`）+ §3 の追加プローブ 5 本でクラッシュ 0 |
| §5.2 `PQfinish` / `PQclear` / `PQfreeCancel` / `PQfreemem` が呼ばれ二重解放なし | `test_leak` 18 件（check 5/6 段 PG17、Phase 4 の 4 ループとも RSS 平坦）。`PQfreemem` 除去の陽性対照は turn 8 で FAIL を実測、`PQfreeCancel` はコードレビュー担保（§5） |
| §5.2 `AsyncConnection` は `Movable` のみ | `struct AsyncConnection(Movable)`（`async_conn.mojo:277`）。`Copyable` は `Notification` と docstring の 2 行のみ |
| §5.2 10,000 回 execute / 1,000 回 NOTIFY で単調増加なし | `test_async_execute_does_not_leak` / `test_notify_receive_does_not_leak` 他 2 本 |
| §5.4 docstring / fmt / examples / package / check | `pixi run check` **6/6 PASS**（1/6 fmt 差分なし、3/6 docstring 診断 0、4/6 examples 5 本、5/6 両サーバー 47 サマリ全部 `0 failed`、6/6 `matched lines: 0`。18:38:45 → 18:41:44 = **179 s**） |
| §4.8 SKIP 集計 | check ログに `-- 127.0.0.1:54317 skipped 1` / `-- 127.0.0.1:54314 skipped 1` |
| §4.9 / §4.10 | `_string_payload` 一元化 / `_validated_utf8` の 3 経路（コードレビュー側の確認は §4） |

### 2.1 文書の主張

- 追従先チェックリスト（PLAN、85 行）を再実行: **全行が期待値**。TRACE.md §1 の生出力との差分は `init_TIMEOUT` の 1 行だけ（TRACE 3 → 現在 **6**。期待 ≥ 1 なので合格。
  T8 が公開 API 表を足した**後**にスクリプトを再実行しなかったため TRACE の値が古い。字句のみ）
- `check` 所要 179 s は PROGRESS turn 10 の 180 s と一致

## 3. 堅牢性の格子プローブ（round 1 で一括）

ライブラリなので格子は「入力（`timeout_ms` / SQL / conninfo / 状態）× 接続の生死 × 例外 kind」。テスト 47 件が押さえていない面を 5 本追加した
（`scratch/turn-011-probe-grid.mojo`、ログ `turn-011-probe-grid.log`）:

| # | プローブ | 結果 |
|---|---|---|
| P1 | `poll_socket(fd, True, False, 2^32 + 50)`（空 pipe） | **50 ms で `timeout`**。`c_int(timeout_ms)` の切り捨て（`poll.mojo:165`）。`2^31` ちょうどなら負値 = 無期限待ちになる。クラッシュせず、入力は「25 日超のタイムアウト」なので残留リスク（§5） |
| P2 | データ受信済みの `fetch_all(0)` | `TIMEOUT "fetch_all timed out after 0 ms"`、状態 `Busy` のまま。`poll_result` ループで `Idle` に復帰。契約どおり（0 は「予算なし」で `wait_*` の「1 回だけ見る」とは違う）。docstring は 0 の意味を書いていない（§5） |
| P3 | 16 MB `send` が `Sending` のまま別接続から `pg_terminate_backend` → `flush` / `poll_result` ループ | 3 回中 1 回 `Sending` を観測。**4 ステップで `Idle`・`CONNECTION_BAD`** に到達（step 2 `SERVER 57P01`、step 4 `CONNECTION`）。turn 7 で直した「切断で `Busy` に固まる」バグの `Sending` 側は起きない（libpq が `PQflush` -1 で outCount を捨て、次の `PQflush` が 0 を返すため） |
| P4 | `LISTEN` 後に backend を terminate → `wait_notification(3000)` | **0 ms で `CONNECTION`**（`None` を返して 3 s 待つことも、無限ループもしない） |
| P5 | `connect_blocking(conninfo, 0)` | `TIMEOUT "connect_blocking timed out after 0 ms"`（P2 と同じ意味論。設計どおり） |

## 4. 指摘（round 1 → PLAN F1）

1. **`timeout_ms` が 2^31 以上で黙って誤動作する**（`src/pq/_platform/poll.mojo:165` `c_int(timeout_ms)`、同 `:178`。上限検査は `poll_socket:219` / `async_conn.mojo:255-274` `_reject_bad_timeout` とも `< -1` だけ）。
   `2^32+50` → 50 ms で `timeout`（親プローブ P1）、`2^31` → `-2147483648` = 無期限、`Int.MAX` → `c_int` は `-1` だが deadline `monotonic() + timeout_ms * 1_000_000` が Int64 を溢れて
   `fetch_all(Int.MAX)` が **0 ms で `TIMEOUT`**、状態 `Busy` のまま（セキュリティ側 `scratch/turn-011-sec-timeout.mojo` で 4 入口を再現）。クラッシュはしないが「`-1` 以外の無期限」を渡した利用者が
   黙って即時タイムアウト／無限待ちになる = 誤動作。REQ §4.1 は上限を定めていないので、修正は「`> 2147483647` を既存の `USAGE` 文言に統合」（F1 表 1〜3）。
   親・セキュリティの 2 経路で独立に検出
2. **`notifications()` の `channel` / `payload` が UTF-8 無検証**（`async_conn.mojo:1344-1353` `String(unsafe_from_utf8_ptr=)`）。`SQL_ASCII` DB で `NOTIFY ch, E'ab\xC3\x28\xF0'` を送ると
   不正 UTF-8 の Mojo `String` ができる（セキュリティ側が `scratch/turn-011-sec-ascii-notify.mojo` で再現。同じバイトは text 列経路で `TYPE_MISMATCH "invalid UTF-8 at byte 2 of column 0"`）。
   REQ §4.10 / D12 の文言は「text 列」なので要件違反ではないが、D12 が現状維持を却下した理由（利用者側の codepoint 走査が 1〜3 byte 読み越す余地）が通知 payload にそのまま当たり、
   パッケージ内で同じ値型の扱いが食い違う。F1 で差し戻すついでに揃える（表 4〜7。`PQfreemem` は検査結果に関わらず呼ぶ、正常分は `_pending` に戻す）
3. 文書・例（F1 (c) に同梱。いずれも字句・例の形で誤動作なし）: ① `connect_blocking` の Raises が `SERVER` を落としている（`_drain_setup` の SET 拒否経路。`__init__.mojo:266` と `async_conn.mojo:826-830`）
   ② `fetch_all` / `connect_blocking` の `timeout_ms = 0` が「最初の wait 前に `TIMEOUT`」であることが docstring に無い（親プローブ P2 / P5） ③ TRACE.md §1 `init_TIMEOUT=3` が古い（現在 6）
   ④ `examples/async_query.mojo:46-52` が最初の結果で `break` して `BUSY` のまま drop（パッケージ docstring の「`None` + `IDLE` で終了」と食い違う。`PQfinish` で安全ではある）
   ⑤ `tests/test_extended_datetime.mojo:787` の `SKIP` 行は関数が続けて Tokyo ケースを走らせるので SKIP 集計とずれる（UTC コンテナでは到達しない）

## 5. 残留リスク（差し戻さない。要件外か、誤動作・データ損失を伴わない）

- **`fetch_all` が `PQstatus` を BAD にしない `CONNECTION` エラーで busy-spin し得る**（`async_conn.mojo:1453-1461`: 例外後に待たず `continue`）。`PQconsumeInput` が 0 を返しつつ BAD にならないのは
  バッファ拡張失敗（OOM 級）だけで再現不能。`timeout_ms = -1` なら無限に回る。Phase 5 候補: `kind == CONNECTION` なら status に関わらず drain を打ち切る
- **`_after_send` で `PQflush` が -1 のとき pq は `IDLE`、libpq は `PGASYNC_BUSY`** → 次の `send` が libpq の `another command is already in progress` を含む `CONNECTION` になり、モジュール docstring（`:35-39`）と食い違う。
  PG12 以降の libpq は書き込み失敗を `write_failed` + 戻り 0 にするので -1 は稀。TRACE §3 #5 のとおり契約外のまま
- **`fetch_all` が切断時に `BUSY` のまま返ることがある**（`adopt_result` が CONNECTION を投げた時点で status が BAD → break。状態は変えない）。次の `poll_result` 1 回で `IDLE` に戻る（`test_a_terminated_backend_ends_the_command` のループがこの形）。ハングはしない
- **`Sending` 中の切断**は libpq が `PQflush` -1 で outCount を捨てるため次の `flush` が 0 を返し、`poll_result` → `IDLE` に 4 ステップで到達（親プローブ P3）。状態機械は固まらない
- **`wait_readable(50)` の経過時間は `test_async` で断定していない**（kind だけ）。`poll_socket` 側の `test_poll` 3 件が時間を断定するので間接担保
- **`PQfreeCancel` 欠落は RSS で検出不能**（`PGcancel` 数百 byte。turn 8 実測）。`async_conn.mojo:1297` の 1 行をコードレビューで担保（TRACE §3 #2 / #8）
- **Windows 分岐は未コンパイル・未検証**（`comptime if` の非選択側。モジュール docstring に unverified。Phase 5「Windows コードパスのレビュー」）
- **`test_zero_copy` の 1 テスト 3.4〜3.9 s**（Phase 4 以前からの接続固定費。A/B 済み。Phase 5 ベンチマーク）
- **malformed conninfo を `start(String)` に渡すと libpq がそのトークンを echo する**（Phase 1 からの既知。`start(Dict)` で回避。docstring 明記済み）
- `notifications()` が集めた正常な通知は F1 後も「不正 1 件を捨てる」設計なので、`SQL_ASCII` DB では通知の取りこぼしが起こり得る（検証付きにする以上は不可避。UTF-8 DB では到達しない）
- サブエージェントの契約外提案（TRACE.md 末尾の 7 件）は Phase 5 以降の判断のまま

## 6. 計測（単位 s）

- round 1（turn 11）: `pixi run check` 6/6 PASS = 179 s（18:38:45 → 18:41:44）。親プローブ: コンパイル + 実行 約 40 s。
  サブエージェント 2 本: コードレビュー 578 s / 46 ツール呼び出し / 212k トークン、セキュリティ 580 s / 28 ツール呼び出し / 126k トークン（並行）

## 7. マージ

- round 1 は差し戻しのためマージしない。`git remote get-url origin` → `No such remote 'origin'`（ローカルのみ）なので、round 2 合格時は `main` へ `--no-ff` でローカルマージする
