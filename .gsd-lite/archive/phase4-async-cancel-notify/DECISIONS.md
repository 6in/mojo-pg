# DECISIONS — phase4-async-cancel-notify

## D1. マイルストーン範囲は HANDOFF Phase 4 の全部

- 選択: `_platform/poll`、`AsyncConnection`、キャンセル、LISTEN/NOTIFY を 1 マイルストーンで
- 却下: 「非同期接続・実行・cancel まで（NOTIFY は次）」「非同期接続・実行だけ」— 受け入れ条件 §10 Phase 4 の 4 件が
  相互に依存（NOTIFY の受信は `PQconsumeInput` + poll の経路をそのまま使う）し、分けると次マイルストーンが同じ
  テスト基盤を作り直す

## D2. 隣接項目を 4 つとも入れる（ユーザー全選択）

- 持ち越し整理 4 件（REQ §6）、TestSuite の SKIP 集計（reflect 提案 (b)）、jsonb / 文字列系 OID 判定の一元化
  （VERIFICATION §5 残留リスク）、UTF-8 検証の方針決定（VERIFICATION §5「Phase 4 以降の判断」）
- 理由: いずれも VERIFICATION §5 / reflect が「次マイルストーンで」と名指しした項目で、先送りすると残留リスクが累積する

## D3. 堅牢性の受け入れ基準を入れる（差し戻し対象）

- Phase 1〜3 と同じ方針。非同期は状態遷移（接続ポーリング中 / 送信中 / 結果待ち / cancel 後 / タイムアウト後）が増えるので
  むしろ重要。plan が初回タスクに含め、verify は差し戻す

## D4. slug は `phase4-async-cancel-notify`

- Phase 1〜3 の命名（`phase3-binary-all-types`）に揃える。却下: `phase4-async`（内容がブランチ名から読めない）

## D5. `AsyncConnection` は別 struct。結果変換は共有関数に抜き出す

- 選択: `async_conn.mojo` に `AsyncConnection(Movable)` を新設し、`Connection._take_result` をモジュール関数 `adopt_result` に抜き出して両者が呼ぶ。
  同期側の公開 API は不変
- 却下: 「`Connection` に非同期メソッドを足す」— 途中状態で `execute` を呼ぶと libpq が前の結果を捨てる等の落とし穴を実行時検査で防ぐことになる。
  型で分ければブロッキング関数を非ブロッキング接続で誤って呼ぶ余地が消える／「別 struct + `into_sync()`」— タスクが 1 つ増え、用途が限定的。
  必要になれば次フェーズ

## D6. キャンセルは `PQgetCancel` / `PQcancel`（全版共通）

- 選択: HANDOFF §7.2 どおり。バインディングは既存。ブロッキングで別ソケットを張る（数 ms）。シグナルセーフ。実行時 dlsym なのでヘッダの
  deprecation 警告は出ない
- 却下: 「17+ は `PQcancelCreate` 系、それ以前は fallback」— 経路が 2 つになりテスト・リーク確認が倍。テスト環境の libpq は 18.6 で旧経路が CI で走らない／
  「`PQcancelCreate` 系のみ」— HANDOFF §2「libpq 14 以降」を破る
- 事実: pixi の libpq は 18.6（`libpq.so.5.18`）。`PQcancelCreate` / `PQsocketPoll` / `PQsetChunkedRowsMode` はヘッダにあるが使わない

## D7. poll は libc `poll` + Windows 分岐を「書くが未検証」

- 選択: `external_call["poll"]` と Mojo で定義した `struct pollfd`。Windows は `WSAPoll` / `SOCKET` 幅の分岐をコンパイル時 OS 判定で書き、
  docstring に未検証と明記（HANDOFF §2 OS 方針。Phase 5 がレビュー）
- 却下: 「libc poll のみ、Windows は Phase 5」— Phase 5 が「レビュー」でなく「新規作成」になる／「`PQsocketPoll` 優先 + fallback」— 14〜16 で fallback が要り
  経路が 2 つ。テスト環境では fallback が走らない

## D8. ブロッキング補助は `wait_*` + 完成形ヘルパー 3 つ

- 選択: `wait_readable` / `wait_writable`（タイムアウト付き）に加え `connect_blocking` / `fetch_all` / `wait_notification`。§10 Phase 4
  「タイムアウト付きの `wait_*` が規定時間で戻る」をこの経路でテストする
- 却下: 「`wait_*` のみ」— examples とテストが同じループを何度も書く／「補助なし」— §10 の受け入れ条件が満たせない
- `wait_notification` のタイムアウトは `None` を返す（例外にしない）: 待っても来ないのは正常な結果。他の 3 つは `TIMEOUT` を投げる

## D9. 送信 API は 4 種すべて（ユーザー全選択）

- `send(sql)` / `send(sql, params, result_format)` / `send_prepare` + `send_prepared` / `set_single_row_mode()`。
  バインディングは `PQsetSingleRowMode` だけ追加。`PGRES_SINGLE_TUPLE` を `adopt_result` の成功扱いに足す
- `send_prepared` は同期側 `PreparedStatement` を使わず名前文字列で指定する（`PreparedStatement` は `Connection` の origin を持つ）

## D10. タイムアウトテストの相手はローカルの「accept するが応答しない」リスナー

- 選択: docker-compose にサービスを 1 つ足す（`socat` 等。方法は research）。TCP は繋がり、startup packet 後の読み待ちで `wait_readable(timeout)` が
  満了する。外部ネットワーク非依存で決定論的
- 却下: 「外部ブラックホール（RFC 5737）」— 環境によって ICMP reject で即失敗しタイムアウトのテストにならない／「両方（外部は opt-in）」—
  走らないテストを増やすだけ

## D11. `PgErrorKind.TIMEOUT` を新設、途中状態の誤呼び出しは既存 `USAGE`

- 選択: `TIMEOUT = Self(6)`（利用者がリトライ判定に使える）。誤呼び出し（送信中の再 send、未接続 send、送信前の `set_single_row_mode`）は
  Phase 2 からある `USAGE` でメッセージに現在の状態名を入れる
- 却下: 「既存 kind だけで表す」— 利用者がメッセージ文字列で判別することになる
- アイドル時の `cancel()` は何もしない（`USAGE` にしない）: 結果が届く直前に呼ぶ競合が正常に起こり、無害なため

## D12. UTF-8 は検証付きに切り替える

- 選択: text 列の `String` 化と zero-copy の `StringSlice` の両方を検証付きにし、失敗は `TYPE_MISMATCH`。`pixi run bench` で差を測って記録
  （受け入れ条件にしない）
- 却下: 「現状維持を恒久仕様に」— `SQL_ASCII` DB や偽造セルで利用者側が 1〜3 byte 読み越す余地が残る（VERIFICATION §5）／
  「既定は検証、接続単位で opt-out」— 分岐が全 text 経路に入りテストが 2 倍

## D13. 非同期接続の GUC 固定は Ready 後に非同期で SET を 1 往復（状態機械に組み込む）

- 選択: `poll_connect` が `PGRES_POLLING_OK` を得たら内部で同期側と同じ `_SESSION_SETUP_SQL` を `PQsendQuery` し、取り切るまで `NeedRead` / `NeedWrite`。
  `connection.mojo:164` の docstring が既にこの形を予告している。同期・非同期で同じ SQL・同じ失敗 kind
- 却下: 「conninfo `options` に合成」— 利用者の `options` との結合に `PQconninfoParse` の構造体定義か `expand_dbname` の上書き規則への依存が要る
  （Phase 3 D12 と同じ理由）／「固定しない」— 日時の text デコードが環境で壊れる

## D14. `poll_result()` は `Optional[Result]`、待つか完了かは `state()` / `is_busy()` で区別

- 選択: HANDOFF §7.2 の形。`None` は「今は無い」。NULL を受けた時点で内部状態を `Idle` にし、呼ぶ側は `state() == Busy` なら待つ。API が小さい
- 却下: 「3 状態 struct `PollOutcome`」— 型が 1 つ増える。Mojo に payload 付き enum が無く `Optional[Result] + Bool` の struct になり、
  結局アクセサで同じ区別をする

## D15. `AsyncConnection.state()` は 4 状態（Connecting / Idle / Sending / Busy）を公開

- 選択: `AsyncState` newtype。テストと examples が状態を断定でき、`USAGE` メッセージもこの名前で書ける
- 却下: 「公開しない」— 誤呼び出しのテストがメッセージ照合になる

## D16. discuss が判断した付随事項（ユーザーに聞かずに決めた小物）

- `AsyncConnection.__del__` は `PQfinish` だけ（結果が残っていても drain しない。libpq が片付ける）
- アイドル時の `cancel()` は no-op（D11）。`cancel()` は毎回 `PQgetCancel` → `PQcancel` → `PQfreeCancel`（`PGcancel` をキャッシュしない。所有権が単純）
- `socket()` は未接続 / 切断で `-1` を返し例外にしない（イベントループ組み込み用の素の値）
- `timeout_ms` の意味は libc `poll` と同じ（`0` 即時、`-1` 無期限、正のミリ秒。他は `USAGE`）。`EINTR` は残り時間で再試行
- `wait_notification` のタイムアウトは `None`、他の補助は `TIMEOUT`（D8）
- `fetch_all` は途中のエラー結果を見ても残りを取り切ってから投げる（接続を `Idle` に戻してから利用者に渡す）
- `Notification` のフィールド名は `channel` / `payload` / `backend_pid`（libpq の `relname` / `extra` / `be_pid` は使わない。意味で命名）
- SKIP 集計は `print("SKIP <test関数名>: <理由>")` + `run_tests.sh` の行数カウント。FAIL にはしない（§4.8）
- UTF-8 不正のメッセージは「invalid UTF-8 at byte N of column M」の形でセル全文を入れない（§4.10）
- examples は HANDOFF §4 の名前（`async_query.mojo` / `listen_notify.mojo`）
- `AsyncConnection` に `transaction()` / `prepare()` / `execute()` は作らない（BEGIN 等は `send`）
- タイムアウトリスナーのポートは `54399`（PG の 54317 / 54314 と同じ並び）
- REQ §9 の申し送りは Phase 3 reflect「次回への提案」の plan / impl / verify / research 項目をそのまま採用（スキル本文は変えない。Phase 2 D18 と同じ）
- Phase 3 reflect の「ツール側」提案（`gsd-lite-loop.sh` の `usage` 取得をサブエージェント込みに、`subagents` の記録）はマイルストーン外で
  ユーザーが行う。本マイルストーンでは扱わない

## D17. 実行パターン: 現在の設定を維持（すべて Claude、impl = claude-opus-5、他 = claude-fable-5-1、subagents = auto、reflect = true）

- Phase 1〜3 と同じ。research の対象は similar_oss + official_docs（local_projects は Phase 3 と同じく外す。`~/workspaces` に非同期 FFI の
  Mojo コードは無い見込みで貢献が小さい）
- 却下: 全フェーズ fable（impl のコストが上がる見込み）／impl だけ Codex（sandbox の準備が要り、Phase 1〜3 の impl 契約が Claude 前提で書かれている）
