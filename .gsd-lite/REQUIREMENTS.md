# REQUIREMENTS — phase4-async-cancel-notify

- 対象: HANDOFF.md §9 Phase 4（非同期）。§7「非同期設計」と §10「Phase 4」の受け入れ条件が原本
- 前マイルストーン: `phase3-binary-all-types`（`.gsd-lite/archive/phase3-binary-all-types/`、reflect
  `.gsd-lite/reflect/20261017-0254-phase3-binary-all-types.md`）
- この文書は WHAT。WHY は `DECISIONS.md`

## 1. 目的

Mojo（1.1.0）から libpq の非ブロッキング API を使い、**明示的に状態を進める** `AsyncConnection` を提供する。
非同期接続・非同期クエリ送信 / 結果受信・キャンセル・LISTEN/NOTIFY を、OS のソケット poll（`_platform/poll`）と
組み合わせて同じスレッドで進められるようにする。Mojo 言語の `async` には依存しない（HANDOFF §7.3）。

## 2. スコープ（このマイルストーンでやること）

- HANDOFF §9 Phase 4 の全部: `_platform/poll`、`AsyncConnection`、キャンセル、LISTEN/NOTIFY（D1）
- 隣接項目 4 件（D2）: 持ち越し整理（§6）、TestSuite の SKIP 集計（§4.8）、jsonb / 文字列系 OID 判定の一元化（§4.9）、
  UTF-8 検証の方針決定（§4.10）
- 堅牢性の受け入れ基準を入れる（§5.2、差し戻し対象。D3）

## 3. スコープ外（やらないこと）

- Phase 5: ベンチマーク（psycopg 比較）、README、examples の総点検、Windows コードパスの**レビュー**（コードは今回書く。§4.2）
- Mojo の `async` / `await` 統合、イベントループの提供（状態機械 API の上に載せるアダプタは作らない。HANDOFF §7.3）
- HANDOFF §3 の対象外（ワイヤプロトコル自前実装、プール、COPY、パイプラインモード、ORM）
- 同期 `Connection` へのキャンセル追加（同一スレッドでブロック中に呼べないため。別スレッド / シグナルは対象外）
- 配列型・range・その他 §6 に無い型（Phase 6 候補）
- CI（Phase 1 D7 と同じ。受け入れはローカル `pixi run test`）

（以下の節はラウンドの進行に合わせて追記する）

## 4. 機能要件

### 4.1 `_platform/poll`（新規 `src/pq/_platform/poll.mojo`。D7）

- `poll_socket(fd: Int, want_read: Bool, want_write: Bool, timeout_ms: Int) raises PgError -> PollEvents`
  （名前は plan が決めてよい）。Linux / macOS は libc `poll()` を `external_call` で呼び、`struct pollfd` を Mojo の struct で定義する
  （`fd: Int32`、`events: Int16`、`revents: Int16`。レイアウトは両 OS で同じ。`POLLIN` / `POLLOUT` / `POLLERR` / `POLLHUP` / `POLLNVAL` の値は
  OS で異なる → research が確定）
- Windows は `WSAPoll`（`ws2_32.dll`）と `SOCKET`（ポインタ幅）の分岐を `@parameter if`（コンパイル時 OS 判定。手段は research）で**書くが未検証**。
  モジュール docstring に「未検証」と明記。Phase 5 がレビュー
- `timeout_ms`: `0` は即時、`-1` は無期限（libc `poll` と同じ）、それ以外は正のミリ秒。負の `-1` 以外は `USAGE`
- `EINTR` は残り時間で再試行する（単調時計で測る。手段は research）
- 戻り: 発生イベント（readable / writable / error / hangup / timeout）。`POLLNVAL` は `USAGE`（閉じたソケット）

### 4.2 `AsyncConnection`（新規 `src/pq/async_conn.mojo`。`pq` 直下で公開。D5）

- `Movable` のみ（`Connection` と同じ）。`__del__` で `PQfinish`（結果が残っていても libpq が片付ける。drain しない）
- `_pq: Pointer[LibpqFFI, MutUntrackedOrigin]` と `_conn: PGconnPtr` を持つ（`Connection` と同じ持ち方）
- **結果変換の共有**: `Connection._take_result`（PGresult → `Result` / `PgError`、失敗経路の `PQclear`）をモジュール関数
  （例 `result.mojo` か新規 `_result_adopt.mojo` の `adopt_result(pq, conn, res)`）に抜き出し、`Connection` と `AsyncConnection` の両方が呼ぶ。
  同期側の公開 API と挙動（kind の判定、診断フィールドの複製）は不変で、既存テストの期待値を変えない。`PGRES_SINGLE_TUPLE` も成功として扱う
  （§4.4）
- 接続:
  - `AsyncConnection.start(var conninfo: String) raises PgError -> AsyncConnection`（`PQconnectStartParams` +
    `PQsetnonblocking(1)`。`PQstatus == CONNECTION_BAD` なら即 `CONNECTION`）
  - `AsyncConnection.start(params: Dict[String, String])` も同形で提供
  - `poll_connect() raises PgError -> PollState`（`PQconnectPoll` の `PGRES_POLLING_READING / WRITING / OK / FAILED` を
    `NeedRead / NeedWrite / Ready / Failed` に写す。`Failed` は戻り値ではなく `CONNECTION` を投げる。**要実測**: `PQconnectPoll` は最初に
    `PGRES_POLLING_WRITING` を返す）
  - 接続直後の GUC 固定（D13）: `PQconnectPoll` が `PGRES_POLLING_OK` を返したら `poll_connect` は内部で同期側と同じ
    `_SESSION_SETUP_SQL`（`SET DateStyle TO 'ISO, YMD'; SET IntervalStyle TO 'postgres'`。`connection.mojo` の定数を共有）を `PQsendQuery` し、
    その結果を NULL まで取り切るまで `NeedRead` / `NeedWrite` を返し続ける。取り切ったら `Ready`。SET が失敗したら `CONNECTION`（同期側と同じ kind）。
    利用者には接続ポーリングの一部に見え、`state()` は `Connecting` のまま
  - `socket() -> Int`（`PQsocket`。未接続 / 切断で `-1`。例外にしない）
- 送信（D9。いずれも送信後に `PQflush` を呼び、0 なら送信完了、1 なら `NeedWrite` を返す / `flush() raises -> Bool` でも進められる）:
  - `send(var sql: String) raises PgError`（`PQsendQuery`。複数ステートメントを `;` で送れる唯一の経路）
  - `send(var sql: String, params: List[Param], result_format: ResultFormat = ResultFormat.TEXT) raises PgError`
    （`PQsendQueryParams`。Phase 2 の `Param` 列と Phase 3 の `result_format` をそのまま使う。**要実測**: libpq はパラメータバッファを
    `PQsendQueryParams` の中でコピーする → 戻った時点で解放可）
  - `send_prepare(var name: String, var sql: String, param_types: List[UInt32] = []) raises PgError`（`PQsendPrepare`）
  - `send_prepared(var name: String, params: List[Param], result_format: ResultFormat = ResultFormat.TEXT) raises PgError`
    （`PQsendQueryPrepared`。同期側 `PreparedStatement` は使わず名前文字列で指定）
  - `set_single_row_mode() raises PgError`（`PQsetSingleRowMode`。送信直後・最初の `poll_result` 前にだけ呼べる。0 が返れば `USAGE`。
    `_ffi` にバインディングを追加）
  - 送信中（`PQflush` が 1 のまま）または結果待ち中に再度 `send*` を呼ぶと `USAGE`（メッセージに現在の状態名）。未接続（`poll_connect`
    が `Ready` を返す前）も `USAGE`
- 受信:
  - `consume_input() raises PgError`（`PQconsumeInput`。0 なら `CONNECTION`）
  - `is_busy() -> Bool`（`PQisBusy`）
  - `poll_result() raises PgError -> Optional[Result]`（D14）: `PQconsumeInput`（0 なら `CONNECTION`）→ `PQisBusy` が真なら `None`
    （まだ来ていない。呼ぶ側は `wait_readable` して再試行）→ 偽なら `PQgetResult`。非 NULL なら `adopt_result` した `Result`、NULL なら `None` を返し
    状態を `Idle` に遷移。「待つべきか完了か」は呼ぶ側が `state()`（`Busy` なら待つ、`Idle` なら完了）または `is_busy()` で区別する。
    `Idle` で呼んだら `None`（例外にしない）
  - `state() -> AsyncState`（D15）: `Connecting` / `Idle` / `Sending`（`PQflush` が 1 を返したまま）/ `Busy`（結果待ち）。
    `AsyncState` は `Equatable, TrivialRegisterPassable, Writable` の Int newtype で `pq` 直下に公開。`USAGE` のメッセージはこの名前を使う
    （例 `send() called while Busy`）。`status()`（`PQstatus`）と `transaction_status()` も同期側と同じく公開
  - エラー結果（`PGRES_FATAL_ERROR` 等）は `adopt_result` が `PgError` として投げる。投げた後も状態機械は壊れず、次の `poll_result` で残りの
    結果（通常は直後に NULL）を取り切れる
- キャンセル（D6）:
  - `cancel() raises PgError`（`PQgetCancel` → `PQcancel(errbuf 256)` → `PQfreeCancel`。`PQgetCancel` が NULL / `PQcancel` が 0 なら
    `CONNECTION`、errbuf の文言を message に）。呼べるのは結果待ち中。アイドル時は何もしない（`USAGE` にしない。競合で無害）
  - 中断された結果は `poll_result` が SQLSTATE `57014` の `PgError`（kind `SERVER`）として返す
- 通知（D1）:
  - `Notification(Copyable, Movable, Equatable, Writable)`: `channel: String`、`payload: String`、`backend_pid: Int`
  - `notifications() raises PgError -> List[Notification]`（`PQconsumeInput` → `PQnotifies` を NULL まで → 各 `PGnotify` を
    `PQfreemem`。`PGnotify` の `relname` / `extra` / `be_pid` を所有型にコピー）
- ブロッキング補助（D8。タイムアウトは `TIMEOUT`。`timeout_ms` の意味は §4.1）:
  - `wait_readable(timeout_ms: Int) raises PgError` / `wait_writable(timeout_ms: Int) raises PgError`（`_platform/poll`。
    タイムアウトで `TIMEOUT`、`POLLERR` / `POLLHUP` で `CONNECTION`）
  - `AsyncConnection.connect_blocking(var conninfo: String, timeout_ms: Int) raises PgError -> AsyncConnection`
    （`start` → `poll_connect` ループ。経過時間は全体で `timeout_ms`。`Dict` 版も）
  - `fetch_all(timeout_ms: Int) raises PgError -> List[Result]`（`send*` の後、NULL まで回す。途中でエラー結果が来たら**残りを取り切ってから**
    その `PgError` を投げる。全体で `timeout_ms`）
  - `wait_notification(timeout_ms: Int) raises PgError -> Optional[Notification]`（`notifications()` が空なら `wait_readable` して再試行。
    タイムアウトは `None`（例外にしない。待っても来ないのは正常））
- `AsyncConnection` には `transaction()` / `prepare()` / `execute()` を**作らない**（§3）。BEGIN 等は `send` で送る

### 4.3 `PollState`（`pq` 直下で公開）

- `Equatable, TrivialRegisterPassable, Writable` の Int newtype（`ResultFormat` と同じ流儀）。定数 `NeedRead` / `NeedWrite` / `Ready`
  （`Failed` は例外になるので定数は作らない）

### 4.4 `PgErrorKind.TIMEOUT`（`errors.mojo`。D11）

- `comptime TIMEOUT = Self(6)` を追加。`write_to` の名前表にも追加。意味: 「`timeout_ms` 以内に待っている状態変化が来なかった。接続は使える」
- `adopt_result`（§4.2）は `PGRES_SINGLE_TUPLE` を `PGRES_TUPLES_OK` と同じ成功扱いにする（同期側では到達しないので挙動不変）

### 4.5 `_ffi` の追加

- `PQsetSingleRowMode` のバインディング（`libpq-fe.h:528`）。他は Phase 1 で既存（§8）
- `PGnotify` 構造体は `_ffi/types.mojo` に既存。レイアウト（`relname: char*`、`be_pid: int`、`extra: char*`、`next: PGnotify*`）を
  research が `libpq-fe.h` と照合し、**要実測**で `NOTIFY` 1 件を受けて確認する

### 4.6 examples と pixi タスク

- `examples/async_query.mojo`: 非同期接続 → `send("SELECT pg_sleep(2), 1")` → `poll_result` が `None` のあいだカウンタを進めつつ `wait_readable(100)`
  → 結果と最終カウンタを表示。`pixi run example-async`
- `examples/listen_notify.mojo`: `AsyncConnection` で `LISTEN ch` → 同期 `Connection` で `NOTIFY ch, 'payload'` → `wait_notification(2000)` で受信表示。
  `pixi run example-notify`

### 4.7 テスト（`tests/test_async.mojo` / `tests/test_notify.mojo` / `tests/test_poll.mojo` / `test_leak.mojo` 追記。分割は plan）

- §5.1 の 4 件を 1 件ずつテストにする。`pg_sleep(2)` のカウンタは「`poll_result` が `None` を返した回数 ≥ 1 かつ経過 ≥ 2 s」で判定
- cancel: `send("SELECT pg_sleep(10)")` → `wait_readable(100)` を 1 回 → `cancel()` → `fetch_all(5000)` が `57014` で失敗し、`cancel()` 呼び出しから
  例外までの経過が 1 s 未満（単調時計）
- NOTIFY: 別 `Connection` から `NOTIFY` 2 件（payload あり / 空）→ `notifications()` が 2 件、順序とフィールドが一致。`backend_pid` が
  `SELECT pg_backend_pid()` と一致
- タイムアウト: docker-compose に「accept するが応答しない」リスナー（D10。ポートは `54399`、方法は research）を足し、
  `connect_blocking(conninfo, 500)` が `TIMEOUT` で戻り、経過が 500 ms 以上 1,500 ms 未満
- 状態誤りの `USAGE` 格子: 未接続 send / 結果待ち中 send / 送信前 `set_single_row_mode` / アイドル cancel（例外なし）
- `_platform/poll` 単体: 自分で `socketpair` または `pipe` を作り、書いてから `POLLIN`、空で `timeout_ms=50` がタイムアウト、閉じた fd で `USAGE`
  （手段は research。`external_call["pipe"]` で十分）
- 既存テストの期待値変更: `adopt_result` の抜き出しで**ゼロ**であること（verify が照合）

### 4.8 TestSuite の SKIP 集計（D2。reflect 提案 (b)）

- 分岐で走らないテストは早期 return の直前に `print("SKIP <test関数名>: <理由>")` を出す（既存 2 件 `_on_pg17_and_later` / `_before_pg17` と
  今回追加するサーバー版依存テストすべて）
- `tests/run_tests.sh` はファイルごとの出力から `^SKIP ` 行を数え、サーバーごとに `-- <label> skipped N` を末尾に出す（約 10 行。FAIL にはしない）
- `final_check.sh` は変更しない（集計は情報表示）

### 4.9 jsonb / 文字列系 OID 判定の一元化（D2）

- `result.mojo` の `get_text` と `decode_binary.mojo` の `decode_binary[String]` に重複する「文字列系 5 OID（text / varchar / bpchar / name / json）
  の判定」と「jsonb version byte（=1）の検査」を 1 つの関数に寄せ、両方から呼ぶ。挙動不変、既存テストの期待値変更ゼロ

### 4.10 UTF-8 検証（D2 / D12）

- text 列の `String(unsafe_from_utf8=)` と zero-copy の `StringSlice(unsafe_from_utf8=)` を検証付き（`from_utf8=` 相当。手段は research）に切り替える。
  不正な列は `TYPE_MISMATCH`（メッセージはセル全文ではなく「invalid UTF-8 at byte N of column M」の形。Phase 3 残留リスク「セル全文がログに出る」を
  この経路では避ける）
- `pixi run bench` で text 列の decode 時間を切替前後で測り PROGRESS に記録する（受け入れ条件にしない。Phase 3 実測: text total 75〜80 ms）
- テスト: `SELECT E'\xC3\x28'::bytea::text` は PG が拒否するので、偽造は `decode_text` / `decode_binary` の単体テストにバイト列を直接渡して行う

## 5. 受け入れ基準

### 5.1 HANDOFF §10 Phase 4（サーバー挙動を断定する項目は「要実測」。research が最初のプローブ対象にし、矛盾があれば REQ 本文を直してよい）

- `pg_sleep(2)` を送信中に、同じスレッドで他の処理（カウンタのインクリメント）が進む
- `cancel()` で `pg_sleep(10)` が 1 秒以内に中断され、SQLSTATE `57014` が得られる（要実測: 57014 は `query_canceled`）
- 別接続からの `NOTIFY ch, 'payload'` を `notifications()` で受け取れる
- 接続先が応答しない場合に、タイムアウト付きの `wait_*` が規定時間で戻る

### 5.2 堅牢性（差し戻し対象。Phase 1〜3 §5.2 を非同期 API に拡張）

- どの入力・出力・接続状態（未接続、接続ポーリング中、送信中（`PQflush` 未完）、結果待ち、結果取得後、切断、cancel 後、
  タイムアウト後、`__del__` 直前に結果が残っている）でもクラッシュ・トレースバックを出さず `PgError` で返す
- 正常系・異常系の両方で `PQfinish` / `PQclear` / `PQfreeCancel` / `PQfreemem`（`PGnotify`）が呼ばれ、二重解放しない
- 解放済みポインタへのアクセスが型・所有権の上で起こらない（`AsyncConnection` は `Movable` のみ）
- 10,000 回の非同期 execute（send → poll → Result）のループと 1,000 回の NOTIFY 受信でメモリ使用量が単調増加しない
  （`test_leak` に Phase 4 分のループを追加。判定方式は §5.3）

### 5.3 リーク測定方式（Phase 2 D4 / Phase 3 §5.3 を維持）

- `test_leak.mojo` は `mojo build` したバイナリで実行、`pixi run check` は 1 サーバー（`PQ_TEST_LEAK_SERVERS=1`）
- `TOLERANCE_PAGES = 256` は恒久仕様
- 検出力の陽性対照: 新しく追加する解放経路（`PQfreeCancel`、`PQfreemem` for `PGnotify`）を消したコピーで FAIL することを
  impl が同じターンで実測し、サンプル列を PROGRESS に貼る

### 5.4 品質基準（差し戻し対象。Phase 1〜3 と同じ）

- `pq` 直下の公開 struct / メソッドに docstring がある（`_ffi` / `_platform` はモジュール docstring のみでよい）
- `pixi run fmt` を実行しても差分なし
- `examples/async_query.mojo`（非同期送信中にカウンタを進めつつ結果を受ける）と `examples/listen_notify.mojo`
  （LISTEN → 別接続 NOTIFY → 受信表示）が単体で実行できる。`pixi.toml` にタスクを追加する
- `pixi run package` が通る
- `pixi run check` が全段 PASS

## 6. 持ち越し整理（最初の 1 コミットにまとめる。Phase 3 VERIFICATION §5 より）

1. `src/pq/params.mojo:643` docstring Raises と `:670` のメッセージ「libpq takes at most 1073741823」→ 上限は PG 側
   （`MaxAllocSize` 1 GB）の言い方に直す（F1 (c) で直したコメントと揃える）
2. `tests/test_connection.mojo:954` の「libpq takes `client_encoding` from the environment」→ 既定は `server_encoding`、
   環境変数は `PGCLIENTENCODING` と書く
3. `decode_timetz` に時刻部 0..86400000000 の範囲検査を足す（`decode_time` と同じ `_binary_value_error`）。テスト 1 件
4. `test_timestamp_params_round_trip` の非 UTC 分岐を `options='-c TimeZone=Asia/Tokyo'` の専用接続で 1 ケース回す
   （または分岐を消す。impl が実測して選ぶ）

## 7. 既知のサーバー挙動（Phase 2 / 3 で実測済み。前 REQ の訂正を引き継ぐ）

- rollback 後の prepared statement は成功する。手動 `DEALLOCATE` 後は `26000`
- `Bool` → int4 は `42804`、`Int(3000000000)` → int4 は `22003`、`Int(5)` → int4 は成功
- 接続直後に `SET DateStyle = 'ISO, YMD'` と `IntervalStyle = 'postgres'` を 1 往復で固定（Phase 3 D12）。TimeZone は触らない
- テスト用コンテナは `Etc/UTC` 固定

## 8. テスト環境

- Phase 1〜3 と同じ: `tests/docker-compose.yml`（PG 17 = 54317、PG 14 = 54314）、`pixi run db-up`、`pixi run test`
- pixi 環境の libpq は **18.6**（`libpq.so.5.18`。`PQcancelCreate` / `PQsocketPoll` / `PQsetChunkedRowsMode` のヘッダあり）。
  実行時ロードは `libpq.so.5` の探索なので、利用者環境では 14 のこともある（HANDOFF §2）
- `tests/fixtures/schema.sql` の `pqtest` スキーマ。Phase 4 のテーブルは各テストが自分で作る

## 9. 後続フェーズへの申し送り（前回 reflect より。スキル本文は変えないのでここに書く）

- **research**:
  - RESEARCH §0.5「Mojo 1.1.0 既知の落とし穴」に Phase 1 / 2 分に加えて Phase 3 の 7 件を足す（`Span[UInt8, origin]` は `[origin: ImmOrigin, //]` 前置 /
    `(-0.0)::float8` は `'-0'::float8` で / `@fieldwise_init` は全フィールド公開 ctor を生む / `ImplicitlyCopyable` でない型は `List` 要素を `.copy()` /
    `List[T](a, b, c)` 不可・`[a, b, c]` リテラルで / 実引数の `String(...).as_bytes()` は一時オブジェクト由来 / モジュールレベル `var` 不可）
  - 期待値表は `...` で桁を省略しない。長い値は全桁か、原本を取った SQL と出力ログのパス（`scratch/turn-001-*.log`）を同じ行に書く
  - プローブは最初の 1 本をコンパイルしてから残りを書く。「仕様上の非対称を突く形」を 1 本含める（例: `PQsendQueryParams` 直後に `Param` バッファを
    解放して結果が壊れないか / `PQconnectPoll` の最初の戻り値 / `PQcancel` をアイドル時に呼んだときの戻り）
  - §5.1 と §4 の「要実測」はすべて最初のプローブ対象。矛盾を見つけたら REQ 本文を直してよい
  - Phase 4 固有の確認: libc `poll` の `POLL*` 定数（Linux x86_64 / aarch64 / macOS）、`struct pollfd` レイアウト、`external_call` で `poll` を呼ぶ形、
    コンパイル時 OS 判定の書き方、単調時計の取り方、`pipe` / `socketpair` の呼び方、`PGnotify` のレイアウト照合、`String(from_utf8=)` 相当の有無、
    docker-compose で「accept するが応答しない」リスナーを作る最短の方法
- **plan**:
  - **追従先チェックリストは表ではなく最初から実行可能なスクリプト**（`.gsd-lite/logs/<slug>/scratch/turn-002-checklist.sh`）として書き、plan ターンで
    現在の木で 1 回実行して「現在値」を各行に記録する。期待値は「現在値 + 差分」。impl の各タスクの完了基準に「スクリプトを実行し自タスクの行が期待値に
    到達」を含め、最終タスクの総点検は再実行だけにする
  - 所要見積もりは「前マイルストーン末の実測（`check` 112〜143 s、テスト 546 件 × 2）+ 新テスト 1 ファイルあたり接続数 × 3〜7 s」で書く。
    往復 1 回あたりの ms を分単位の見積もりに足さない
  - 完了基準で `grep -c X = 0` を複数タスクが繰り返すなら最初のタスクで `final_check.sh` に機械化する。期待メッセージは 2 語以上の部分文字列
  - タスクごとに「サブエージェント推奨本数」を書き、1 ファイル完結・実行待ち支配のタスクは 0 本と明記。**今回の実験**: 「`src/` を触らずテスト 2 ファイル」型の
    タスクは 1 本（親がもう 1 ファイルを書く）で指定し、reflect が Phase 3 の 2 本（USD 10.77）と比べる
  - 陽性対照を完了基準に書く（リーク検出、`final_check.sh` の新しい grep、`USAGE` 格子）
  - impl への申し送り「親が `*_send` で原本を取り直す」は今回は「親が `psql` / 同期 `Connection` で期待値（`pg_backend_pid`、`57014`、NOTIFY の
    payload）を取り直す」として常設する
- **impl**:
  - PROGRESS「次への注意」は「確認済み」と「見込み」を分け、見込みには `未確認:` 接頭辞。所要の数値には単位
  - **PROGRESS「未確認」で「誤った値が黙って返る経路」や「状態機械が壊れる経路」を述べる行は、同ターンでテスト 1 件にするか、PLAN の該当タスクに
    「(x) この行を処分する」を追記する。処分先を二重に書かない**。最終タスクの完了基準に「PROGRESS の全『未確認』行を列挙し、各行を
    テスト追加 / 契約外と明記 / verify 申し送り のいずれか 1 つに振り分けた表」を入れる
  - **PROGRESS 1 ターン分の申し送りは 40 行を上限**とし、30 行超の表（受け入れ基準対応表・チェックリスト結果）は `.gsd-lite/TRACE.md` に置いて
    PROGRESS からはパスと行数だけ書く。verify は `TRACE.md` を読む
  - PROGRESS「やったこと」に「推奨 N 本 / 実 M 本」を 1 語で書く
  - サブエージェント依頼文に (a) 型パラメータを持つ型はフルに書く、(b) `fmt` は親が統合後に 1 回、(c) scratch は
    `.gsd-lite/logs/<slug>/scratch/turn-NNN-<name>` 固定、を必ず入れる
- **verify**:
  - **字句の指摘はクラスで名指しする**: 文言を 1 箇所指摘したら同じキーワードを `grep -rn` でリポジトリ全体から列挙し（コメント・docstring・
    エラーメッセージ・テスト docstring）、F 項目に全部を同梱する
  - 差し戻し時の「修正後にプローブで期待される変化」は集計値を「どの数がいくつからいくつへ」で書く。round 2 はその数だけ照合する
  - round 2 以降は「round 1 の格子の再確認 + 差し戻し分の回帰」に限定してよい
  - `adopt_result` 抜き出しと §4.9 / §4.10 で既存テストの期待値変更がゼロかを照合する（§4.10 の UTF-8 だけは新規テストが増える）
- **reflect**: 「テスト 2 ファイル型を 1 本」の実験の USD を Phase 3 T6（2 本・USD 10.77）と比べる。`subagent_stats.spawned` は生ログから

## 10. 用語集

- **非同期 API / AsyncConnection**: libpq の非ブロッキング関数群（`PQconnectStart*` / `PQsend*` / `PQconsumeInput` / `PQisBusy` /
  `PQgetResult`）を 1 ステップずつ進める Mojo の struct。Mojo の `async` とは無関係
- **poll 抽象 / `_platform/poll`**: ソケット 1 本の読み / 書き可能待ちを OS 差分を隠して提供する関数（Linux / macOS は libc `poll`）
- **PollState**: `PQconnectPoll` の結果の写し（`NeedRead` / `NeedWrite` / `Ready` / `Failed`）
- **cancel**: 実行中クエリの中断要求。サーバー側は SQLSTATE `57014`（`query_canceled`）で応答する
- **Notification**: `PGnotify`（`relname` = channel、`extra` = payload、`be_pid`）の Mojo 値型
- **タイムアウト**: `wait_*` の `timeout_ms`。経過しても状態が変わらなければ `PgError`（kind はラウンドで確定）
- （Phase 1〜3 の用語: 低レベル層 `_ffi` / 高レベル層 `pq` / conninfo / `PgError.kind` / params / prepared statement / Transaction /
  savepoint / 結果形式 / 拡張型 / zero-copy）
