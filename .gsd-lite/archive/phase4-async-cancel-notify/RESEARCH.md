# RESEARCH — phase4-async-cancel-notify

- 作成: 2026-10-17 / gsd-lite-research（turn 1）
- 入力: REQUIREMENTS.md / DECISIONS.md / HANDOFF.md §7・§9・§10、`archive/phase3-binary-all-types/RESEARCH.md`、
  `reflect/20261017-0254-phase3-binary-all-types.md`。`state.json.research.targets` = similar_oss / official_docs
- 検証環境: Mojo 1.1.0 (8189361e)、pixi env の `libpq.so.5`（`PQlibVersion` = 180006）、docker `postgres:17`（17.11、port 54317）/
  `postgres:14`（14.24、port 54314）、aarch64 Linux（Ubuntu、glibc）。`alpine/socat` イメージ（§2.5）
- **プローブ**（`.gsd-lite/logs/phase4-async-cancel-notify/scratch/`、gitignore 対象。結論は本書に転記済み）:
  - `turn-001-probe-poll.mojo` + `.log`: libc `poll` / `pipe` / `socketpair` / errno / 単調時計（§2.3）
  - `turn-001-probe-lang.mojo` + `.log`: OS 判定・C 型幅・UTF-8 検証 ctor（§2.4、§2.6）
  - `turn-001-name-*.mojo`（12 本）: stdlib 名の存在確認（1 ファイル 1 名。§2.4）
  - `turn-001-probe-async.mojo` + `-pg17.log` / `-pg14.log`: 非同期接続〜cancel〜NOTIFY〜切断〜接続失敗 4 種（A〜N の 14 節。§2.1・§2.2）。
    **PG17 と PG14 の差は NOTIFY の到着タイミングと `PQflush` の戻りだけ**（§2.7）
  - `turn-001-probe-async2.mojo` + `-pg17.log` / `-pg14.log`: 接続中の誤呼び出し、prepared、single-row の境界、tx 内 cancel、NOTIFY の到着、
    切断後の `PQgetResult`、multi-host（A〜H。§2.1・§2.2）。**PG17 / PG14 でタイミング以外の差ゼロ**
  - `turn-001-blackhole-compose.yml`: 「accept するが応答しない」リスナーの compose 定義（§2.5。そのまま `tests/docker-compose.yml` に写せる）
- サブエージェント 1 本（OSS / 公式 docs / macOS・Windows 定数の調査。約 10 分、90 ツール呼び出し。§1 と §2.3 の「出典」行はその報告から。報告の「`get_errno` / `monotonic` がある」は
  `turn-001-name-get_errno_a.mojo` / `_b.mojo` で実測して採用）
- 無人シェルの注意: `mojo` / `pixi` は PATH に無い → **`/home/parallels/.pixi/bin/pixi run mojo ...`**。lean-ctx MCP は未接続（素の Read / Bash で可）。
  プローブは **最初の 1 本（poll）をコンパイルしてから** 残りを書いた。やり直しは PROGRESS 参照（5 回、うち 4 回は Mojo の名前違い → §0.5 ☆ に転記）

## 0. 結論サマリ

1. **作る（BLOCKED にしない）**。要件を満たす既存 OSS は無い（Mojo 製の libpq 非同期ラッパーは 2026-10 時点で存在しない。§1）。
   盗める設計は psycopg 3 の generator 状態機械（connect / execute / fetch / notifies の 4 本。§1.1・§3）
2. **REQ §4・§5.1 の「要実測」は全部確認済みで、矛盾は無い**。確定した事実（§2.1 / §2.2）: `PQconnectPoll` の最初の戻りは **`PGRES_POLLING_WRITING`(2)**、
   `PQsendQueryParams` は戻った時点でパラメータバッファを読み終えている（直後に上書きしても結果は元の値）、`PGnotify` のレイアウトは offset 0 / 8 / 16 / 24
   （`relname` / `be_pid` / `extra` / `next`。`next` は常に 0 で返る）、cancel は呼び出しから **1〜4 ms** で `57014 canceling statement due to user request`
3. **REQ 本文を 3 箇所訂正した（§5）**: (a) §4.7 NOTIFY テストは「`notifications()` 1 回で 2 件」ではなく「2 件揃うまで `wait_notification` / 再試行（上限 2 s）」
   （**2 件の NOTIFY は別メッセージで届き、1 回の `PQconsumeInput` で 1 件しか取れないことがある**。PG14 で実測）、(b) §4.1 の `@parameter if` は Mojo 1.1.0 では
   **`comptime if`**、(c) §4.1 Windows 分岐の判定は `CompilationTarget.is_linux()` / `is_macos()` の **`else`**（`is_windows` も `platform_map(windows=)` も 1.1.0 に無い）
4. **`_platform/poll` は成立**: `@fieldwise_init struct PollFd(TrivialRegisterPassable)` 8 byte、`external_call["poll", c_int](Pointer(to=pfd), Int(1), c_int(timeout))`
   で readable / writable / timeout / `POLLHUP` / `POLLNVAL` の 5 状態を実測。`EINTR` は stdlib の **`std.ffi.get_errno() == ErrNo.EINTR`** で読める（OS 切替済み）。単調時計は
   **`std.time.monotonic()`（= `perf_counter_ns()` = `clock_gettime(CLOCK_MONOTONIC)`、差 0 ms）**。`POLL*` の使う 6 値は Linux（x86_64 / aarch64）と macOS で同一、Windows だけ別値（§2.3）
5. **タイムアウトテストの相手（D10）は `alpine/socat -u TCP-LISTEN:5432,fork,reuseaddr OPEN:/dev/null`**: TCP accept 後に何も書かない。libpq は SSLRequest を
   送って `PGRES_POLLING_READING`（status 7 = `CONNECTION_SSL_STARTUP`）で待ち続け、`poll(500)` が 501 ms で満了（実測）。`docker compose up -d --wait` は
   healthcheck 無しでも 0.7 s で healthy 扱い（§2.5）
6. **状態機械の境界で libpq 自身が守ってくれる箇所と、守ってくれない箇所**（§2.1 表 / §4）: 守る = 結果待ち中・最初の結果取得後〜NULL 前の `PQsendQuery`（0 +
   `another command is already in progress`）、接続中の `PQsendQuery`（0 + `no connection to the server`）、アイドルの `PQsetSingleRowMode`（0）。
   **守らない** = `PQsetSingleRowMode` は **最初の `PQgetResult` の後でも 1 を返す**（効果は無い）、`PQgetCancel` は接続中でも非 NULL、`PQconnectPoll` は OK 後に呼んでも 3。
   → REQ §4.2 の `USAGE` 格子（状態名入り）はクライアント側で持つしかない
7. **切断後の `PQgetResult` は NULL を返す前に 1 件、SQLSTATE 空の `PGRES_FATAL_ERROR` を返す**（`PQresultErrorMessage` = `server closed the connection
   unexpectedly ... invalid socket`、`PQstatus` = BAD、`PQsocket` = -1、`PQflush` = -1、`PQgetCancel` = NULL）。既存 `_take_result` の分類（sqlstate 空 + BAD →
   `CONNECTION`）がそのまま効き、2 回目で NULL なので `fetch_all` は止まる
8. **`Sending`（`PQflush` = 1）は 16 MB のクエリで PG17 では 1 回出たが PG14 では 0 回**: 非決定的なのでテストは「最終的に `Idle`・結果が正しい」だけを断定する（§4 P12）
9. **UTF-8**: `String(from_utf8=Span)` / `StringSlice(from_utf8=Span)` は検証して raise するが **位置を返さない**（メッセージは `Cannot construct a String from
   invalid UTF-8 data` / `StringSpan: buffer is not valid UTF-8`）。REQ §4.10「invalid UTF-8 at byte N of column M」には自前のスキャナが要る →
   **速い経路は stdlib の検証、失敗時だけ自前スキャナで N を求める**（§3-9。性能影響は失敗時のみ）

## 0.5 Mojo 1.1.0 既知の落とし穴（Phase 1〜3 からの転記 ★ + 今回の追加 ☆）

- ☆ **`external_call` は同じシンボル名を 1 プロセス（モジュール）内で 1 つの引数型列でしか呼べない**。`poll` を `(Pointer, Int, c_int)` と `(Int, Int, c_int)` で
  2 回書くと `existing function with conflicting signature`。**stdlib が既に使う `write` / `read` / `close` も同じ**（`std.io.FileDescriptor` が
  `write(Int, Pointer[NoneType], Int) -> Int` で呼んでいる）→ テストで pipe に書くのは `FileDescriptor(fd).write("A")`、`close` は
  `external_call["close", c_int](c_int(fd))` が stdlib と衝突しなかった（実測）。`_platform/poll` は `poll` と `__errno_location` だけ呼ぶ
- ☆ **`external_call` は `from std.ffi import external_call` が必要**（自動では見えない）。`size_of` は `from std.sys import size_of`（`sizeof` は無い）
- ☆ **OS 判定は `from std.sys.info import CompilationTarget` → `CompilationTarget.is_linux()` / `is_macos()` を `comptime if` で**。`is_windows()` は無い、
  `std.sys.info.os_is_*` も `std.sys.os_is_*` も無い、`platform_map` は `linux=` / `macos=` のみ（`windows=` は `unexpected keyword parameter`）。
  `@parameter if` は構文エラー（`'if' statement does not support decorators`）
- ☆ `std.os.errno` は無い。**errno は `from std.ffi import get_errno, ErrNo` → `get_errno() == ErrNo.EINTR`**（OS 切替済み。`Int(ErrNo)` は不可、`.value` で Int）。
  `external_call["__errno_location", Int]()` でも読めるが Linux 専用（§2.3）
- ☆ 単調時計は `from std.time import monotonic`（ns の `Int`。`perf_counter_ns()` と同値）。`std.time.now` は無い
- ☆ 1.1.0 の文字列スライス型の正式名は **`StringSpan`**（エラー文言 `StringSpan: buffer is not valid UTF-8`）。`StringSlice` も通る（別名）。既存コードは `StringSlice` で統一されているのでそのまま
- ☆ `std.ffi` の C 型: `c_int` 4 / `c_uint` 4 / `c_short` 2 / `c_ushort` / `c_long` 8 / `c_ulong` 8 / `c_size_t` / `c_ssize_t` がある
- ☆ `String.strip()` は `StringSpan` を返す → `String(...)` で包む。`t[byte=a:b]` も `StringSpan` で `List[String].append` には `String(...)` が要る
- ☆ `def f(mut s: String)` に `String("literal")` の一時値は渡せない（`must be mutable`）→ `var` に受けるか `var s: String` 引数の関数に `^` で渡す
- ☆ **`print(a, b)` の既定 `sep=" "`** で `"errbuf='", s, "'"` は `errbuf=' x '` になる。期待値照合で空文字と区別するなら `sep=""` か `String(...)` 連結
- ★（Phase 3 の 7 件）`Span[UInt8, origin]` は `[origin: ImmOrigin, //]` 前置が必須 / `(-0.0)::float8` は `'-0'::float8` で / `@fieldwise_init` は全フィールド公開 ctor を生む /
  `ImplicitlyCopyable` でない型は `List` 要素を `.copy()` / `List[T](a, b, c)` 不可・`[a, b, c]` リテラルで（**今回も 1 回踏んだ**。`var x: List[Int32] = [Int32(0), Int32(0)]`）/
  実引数の `String(...).as_bytes()` は一時オブジェクト由来 / モジュールレベル `var` 不可
- ★（Phase 3）`_ = x^` は破棄ではなく生存マーカー、origin 付き値の使用で破棄が延びる / `ref` 束縛は生存延長されない / `drop(res^)` / `var r2 = res^` 後の使用は
  `use of uninitialized value` / `Span(unsafe_ptr=, length=)` / `StringSlice(unsafe_from_utf8=)` は未検証・`String(from_utf8=)` は検証して raise /
  `Array[UInt8, 16](fill=0)` / `p[unsafe_offset=i]` / `//` `%` は床除算 / `-Int64.MIN` は wrap / `atol` は空白と `+` を通す / `s[byte=i]` / `Writable` で `String(x)` /
  `comptime if T == 自前型` は `rebind[T](v).copy()` / ASAP 破棄 × バッファ型は `_ = buffers^` で守る
- ★（Phase 2）`mojo format` はディレクトリ走査で `.gitignore` を尊重 / `SIMD.__rshift__` 符号拡張 / ローカル `List` は `return out^` / `String.as_bytes()` は `Span` /
  `def main() raises PgError` 不可 / `s += s` は aliasing エラー / `StaticString` は `@implicit` 変換元にならない / deref で origin 入れ子 / `std.os.setenv` は `Bool` /
  空 `List[UInt8]` の `unsafe_ptr()` は `capacity=len+1`
- ★（Phase 1）`len(String)` 不可 → `byte_length()` / `from std.math import isnan, isinf` / リスト literal は型注釈必須 / `::` は単項マイナスより強い / stdlib ソースは pixi env に無い
  （名前は 1 名 1 ファイルの `mojo run` で確定。今回 `turn-001-name-*.mojo` 12 本、1 本 2〜3 s）/ `UnsafePointer` は deprecated / `__deinit__(deinit self)` /
  素の `None` は `Optional[T](None)` / `size_t` は `c_size_t(...)` / libpq の既定 notice processor は stderr / `List[c_int]` を lengths / formats に

## 1. 類似 OSS（similar_oss。サブエージェント報告。行番号は 2026-10-17 の main）

### 1.1 psycopg 3 — https://github.com/psycopg/psycopg/blob/master/psycopg/psycopg/generators.py
- `_connect` :61-103: `connect_poll()` の READING → `WAIT_R`、WRITING → `WAIT_W` を **毎イテレーション `yield conn.socket, wait` で fd を再取得**（docstring :12「fileno may change」）。
  OK で break、FAILED は `finish_pgconn` して `OperationalError`、他（ACTIVE）は `InternalError`。**`nonblocking = 1` は接続完了後**（:102。本プロジェクトは start 直後。どちらも可）
- `_send` :138-157: `while pgconn.flush() != 0: ready = yield WAIT_RW; if ready & READY_R: pgconn.consume_input()` — コメント「この consume は notify を読むことがあり、PGconn に溜まって後で `fetch()` が拾う」
- `_fetch` :204-226: `is_busy()` なら `WAIT_R` → `consume_input()` → `is_busy()` 偽まで。**`get_result()` の前に `_consume_notifies(pgconn)`**（:224）→ 本プロジェクトの `poll_result` も
  `PQgetResult` 前後で通知がキューに残ることを前提にし、`notifications()` はいつ呼んでもよい設計（§2.2 J2 と一致）
- `_fetch_many` :160-201: NULL まで取り、`consume_input` が失敗（idle-in-transaction kill 等）したときは **既に FATAL_ERROR の結果があれば break、無ければ再 raise**（:174-183）。
  COPY_* / PIPELINE_SYNC で早期 break。結果列は丸ごと返し、カーソル側が最初の非 OK で raise
- `notifies` :283-296: `yield WAIT_R; consume_input(); while n := pgconn.notifies(): ...`
- cancel（`_connection_base.py` :296-320）: closed なら no-op（`_should_cancel`）。`connection.py` :479-516: 実行中に KeyboardInterrupt → cancel → **5 s 以内に `QueryCanceled` が来なければ `finish()`**
  （#1371）→ 本プロジェクトの `fetch_all(timeout_ms)` を cancel 後に呼ぶ形と同型
- `waiting.py` :441-498（https://github.com/psycopg/psycopg/blob/master/psycopg/psycopg/waiting.py）: `POLL_BAD = ~(POLLIN|POLLOUT)`。**revents にエラービットがあっても POLLIN が立っていれば libpq に渡す**
  （libpq の方が親切なエラーを出す）。**エラービットだけ**のときは `os.fstat` で fd 閉鎖を確かめて `OperationalError("connection socket closed")`。締め切りは `time.monotonic()`。
  EINTR は Python 側（PEP 475）任せ。コメント: 「Linux の select は fd ≥ 1024 不可」「fd を閉じると epoll.poll が hang」→ poll を選ぶ理由

### 1.2 psycopg2 / ruby-pg（C 実装の守り方）
- psycopg2 `pqpath.c` :706-760 `pq_get_result_async`: `PQconsumeInput()==0` → `CONNECTION_BAD` なら closed=2 + `OperationalError(PQerrorMessage)`；notifies / notices を処理してから `PQisBusy` → 1 なら「まだ」；
  **結果列の中のエラーは最初の FATAL_ERROR を保持し、後続は PQclear**（:751-760「handle the *first* error」）。`_pq_execute_async` :900-930: `PQflush` 0 → READ、1 → WRITE、-1 → error。
  `connection_int.c` :836-853: `PGRES_POLLING_FAILED` **と `PGRES_POLLING_ACTIVE` の両方**を失敗扱い（ACTIVE は `libpq-fe.h:125`「unused; keep for backwards compatibility」）
- ruby-pg `ext/pg_connection.c` :2554-2603 `wait_socket_readable`: **読み待ちの前に必ず `PQflush` を終わらせる**（:2578「before we wait for data, make sure everything has been sent」）、締め切りはループごとに再計算、
  起床後 `PQconsumeInput()==0` → `ConnectionBad`（:2595 コメント「PQisBusy is true on connection errors」）。`pgconn_sync_cancel` :2398-2417 は `char errbuf[256]`。
  `PQsetSingleRowMode()==0` は例外（:1938）。Windows は `WSAEventSelect`（`rb_io_wait` が遅い）。POLLERR / POLLHUP / EINTR はランタイム任せ
- → 本プロジェクトに写すもの: (a) `wait_readable` の前の `flush`（`fetch_all` は `Sending` なら先に `wait_writable` + `flush`）、(b) 「最初のエラーを保持して残りを取り切る」（D16 と同じ）、
  (c) `PGRES_POLLING_ACTIVE`(4) も `CONNECTION` にする

### 1.3 Mojo 製（GitHub、2026-10-17 時点）
- `dvirarad/mojo-postgres`（Apache-2.0、libpq `external_call`、**同期のみ**、Mojo 0.25.7）/ `lee101/mojo-pg`（MIT、自前ワイヤ、blocking + deadline、poll 無し）/ `lee101/mojo-db`（MIT、`SO_RCVTIMEO`、
  `__errno_location` 直書き）/ `ehsanmok/flare`（MIT、epoll / kqueue reactor、poll 無し）→ **libpq 非同期を Mojo で書いたものは無い**。採用する依存も無い
- **`mojothon/libc`**（MIT、Mojo ≥ 1.1、linux-64 + osx-arm64）`src/libc/poll/syscalls.mojo` :45-60 `struct pollfd(TrivialRegisterPassable) { fd: Int32; events: c_short; revents: c_short }`、
  :81 `def poll(fds: c_ptr[pollfd], nfds: c_ulong, timeout: Int32) -> Int32`、`errno/syscalls.mojo` :27-45 `get_errno` が `CompilationTarget.is_macos()` で `__error` / `__errno_location` を切替。
  **形は本書 §2.3 と同一（独立に同じ結論）**。ただし POLL* 定数が Linux 値だけで macOS の `POLLWRNORM` が違う（本プロジェクトは 6 値しか使わないので影響なし）。写さない（stdlib `get_errno` で足りる）

### 1.4 公式 docs の要点（出典 URL。§2 の実測と突き合わせ済み）
- libpq-connect: 「`PQsocket` は `PQconnectPoll` 呼び出しをまたいで同じと仮定するな」「最初のイテレーションは WRITING を返したものとして振る舞え」「**`connect_timeout` は `PQconnectPoll` では無視される**。経過時間の判断はアプリの責任」
  「失敗・放棄しても `PQfinish` は要る」（P1 / P2 / P3 / P23 の根拠）
- libpq-async: `PQsetnonblocking` は送信側のみ（`PQexec` は非ブロッキングを尊重しない）。`PQflush` 1 のときは **read-ready も待って `PQconsumeInput`**（サーバーが NOTICE を送れずに詰まる）。
  `PQisBusy` は読まない（`fe-exec.c:2064`: **`CONNECTION_BAD` なら 0 を返す** → §2.1 切断行の `isBusy 0` の理由）。「`PQgetResult` は NULL まで」「アクティブなコマンドが無ければ即 NULL」
- `fe-exec.c:1706-1715`: `no connection to the server`（status ≠ OK）/ `another command is already in progress`（asyncStatus ≠ IDLE）— メッセージは既存のエラーバッファに**追記**される（`PQerrorMessage` に前のエラーが残り得る）
- libpq-single-row-mode: 「`PQsendQuery` 直後、`PQconsumeInput` / `PQgetResult` の前にだけ呼べる。正しいタイミングなら 1、さもなくば 0」— **実測はこれより緩い（§2.1）**。`fe-exec.c:1941-1959 canChangeResultMode` は
  `asyncStatus == BUSY && !pgHavePendingResult` しか見ない。「0 行の TUPLES_OK が終端、その後も NULL まで `PQgetResult`」
- libpq-cancel: `PQcancel` 1 / 0、errbuf 256 推奨、「dispatch 成功は効果の保証ではない。失敗（既に完了）なら**何も見えない**」、`PGcancel` は read-only で別スレッドから呼べる、`fe-cancel.c:577-699` で自前 socket を
  **ブロッキング connect**。**PG18 docs は `PQcancel` を「deprecated で insecure（sslmode=require でも cancel 要求は暗号化されない）」と記す**（§4 P31。D6 の判断は変えない: libpq 14 対応のため）。
  サーバー `postgres.c:3621-3632`: コマンド読み取り中（アイドル）の cancel は**無視**（追加のエラーを送らない）→ §2.2 E と一致。57014 = `query_canceled`
- libpq-notify: 「`PQnotifies` は読まない。`PQconsumeInput` の後に」「`PQgetResult` / `PQexec` のたびに `PQnotifies` を見よ」「`PQfreemem` は `PGnotify` ポインタだけでよい（`relname` / `extra` は別アロケーションではない）」。
  **`libpq-fe.h:241-248` は 4 フィールド（`next` 込み、LP64 で 32 byte）**。sql-notify: payload は既定 8000 byte 未満、未指定なら空文字、tx 内は COMMIT まで届かない、同一 (channel, payload) は tx 内で 1 つに畳まれる。
  sql-listen: `LISTEN` も tx commit で効く
- libpq-exec / `fe-connect.c:5287-5327`: `PQfinish` は内部の作りかけ結果と**未読の PGnotify** を解放し、未読の受信データは捨てる。利用者が受け取った `PGresult` は `PQclear` が要る（既存 `Result` の責務）
- libpq-status: `PQsocket` は「正常運用中は変わらないが接続セットアップ / reset 中は変わり得る」、-1 = 接続なし

## 2. 公式ドキュメント + 検証結果（official_docs）

### 2.1 libpq 非同期 API（実測。probe-async A〜I・K〜N、probe-async2 A〜D・F〜H。PG17 / PG14 同一）

| 項目 | 事実（実測） | 根拠 |
|---|---|---|
| `PQconnectStartParams` | 非 NULL、`PQstatus` = 2（`CONNECTION_STARTED`）、`PQsocket` = 7（既に開いている）。名前解決失敗は **start の時点で** `PQstatus` = 1（BAD）、`PQsocket` = -1、`PQsetnonblocking` が **-1** | A / M-badhost |
| `PQsetnonblocking(1)` | 0、`PQisnonblocking` = 1。multi-host フォールバック後も 1 のまま | A / G |
| `PQconnectPoll` の列 | **2 (WRITING, status 3 MADE) → 1 (READING, status 7 SSL_STARTUP) → 2 (status 3) → 1 (status 4 AWAITING_RESPONSE) ×3 → 3 (OK, status 0)**。7 ステップ 5 ms。待たずに連続で呼んでも `2 1 1` と害なし。OK の後に呼ぶと 3 のまま | A / async2 A |
| 接続失敗 | refused: step 1 で 0（FAILED）、`PQsocket` 7 → **-1**、msg `Connection refused ...` / bad password: step 7 で 0、`FATAL:  password authentication failed for user "pq"`（status 1）。どちらも `PQfinish` は要る | M |
| 接続中の誤呼び出し | `PQsendQuery` → 0 + `no connection to the server`；`PQconsumeInput` → 1；`PQisBusy` → 0；`PQgetResult` → NULL；**`PQgetCancel` → 非 NULL**；`PQtransactionStatus` → 4（UNKNOWN）；`PQflush` → 0 | async2 A |
| アイドル | `PQflush` 0 / `PQisBusy` 0 / `PQconsumeInput` 1 / `PQgetResult` NULL（ブロックしない） | A |
| `PQsendQuery` 2 文（D13 の SET） | 1、`PQflush` 0、`PQisBusy` 1 → 結果 **2 件**（COMMAND_OK `SET` ×2）→ NULL | B |
| `PQsendQuery("SELECT pg_sleep(2), 1")` | `PQisBusy` が真の間に `poll(100)` を 20 回 = 2006 ms、カウンタ 20。結果 TUPLES_OK rows 1 → NULL | C |
| 結果待ち中の `PQsendQuery` | **0 + `another command is already in progress`**（`PQflush` 0） | G2 |
| 最初の結果取得後・NULL 前の `PQsendQuery` | **0 + 同じメッセージ**（`PQisBusy` は 0 なのに）。NULL を見るまで libpq は busy 扱い → `state()` は NULL まで `Busy` | G4 |
| エラー結果 | `SELECT 1/0` → FATAL_ERROR `22012` → NULL（1 件 + NULL） | F1 |
| 多文の途中でエラー | `SELECT 1; SELECT 1/0; SELECT 2` → TUPLES_OK(1), FATAL_ERROR 22012, **NULL**（3 文目は実行されず結果も無い） | F2 |
| 多文 3 件 | TUPLES_OK ×3 → NULL | F3 |
| 空文字列 | `PGRES_EMPTY_QUERY`(0) 1 件（sqlstate / msg 空）→ NULL。既存 `_take_result` は `SERVER "empty query"` | F4 |
| `PQsetSingleRowMode` | アイドル → **0**；`PQsendQuery` 直後 → 1；`PQconsumeInput` 後（データ到着済み）→ **1**；**最初の `PQgetResult`（完全な TUPLES_OK）の後 → 1 だが効果なし**；切断後 → 0 | H / async2 C・F |
| single-row の結果列 | `generate_series(1,3)` → **SINGLE_TUPLE(9) ×3 → TUPLES_OK(2) rows 0 → NULL**（4 件）。途中エラー: SINGLE_TUPLE ×1 → FATAL_ERROR 22012 → NULL。**多文に適用すると全文に効く**（`SELECT 1; SELECT 2` → 9, 2(0 rows), 9, 2(0 rows), NULL）。prepared にも効く | H1〜H4 / async2 B |
| `PQsendQueryParams` 後のバッファ | 送信直後に値を上書き（`hello-param` → `XXXX...`、int4 bytes → `FFFF`）しても結果は **`hello-param`**。libpq は呼び出し中にコピー済み → 戻った時点で解放可 | I |
| `PQsendPrepare` | 1 → 結果 **COMMAND_OK、cmd tag 空文字**（1 件）→ NULL | async2 B |
| `PQsendQueryPrepared` | resultFormat 1 → `PQfformat` 1。未知の名前 → FATAL_ERROR **`26000`** `prepared statement "nope" does not exist` → NULL | async2 B |
| `PQflush` = 1 の再現 | 16 MB の `SELECT length('...')`: **PG17 で 1 回だけ 1**（11 ms 後に 0）、PG14 では最初から 0。非決定的 | K |
| 切断（`pg_terminate_backend`） | 結果待ち中: FATAL_ERROR **`57P01`** 1 件 → 次の `PQconsumeInput` が **0**（`PQerrorMessage` = `FATAL: terminating connection ... server closed the connection unexpectedly ...`）、`PQstatus` 1、`PQsocket` **-1**。その後 `PQgetResult` は **1 件目 = FATAL_ERROR で sqlstate 空・`PG_DIAG_MESSAGE_PRIMARY` 空・`PQresultErrorMessage` = `server closed ... invalid socket`、2 件目 = NULL**。`PQflush` -1、`PQsendQuery` 0 + `no connection to the server`、`PQgetCancel` **NULL**、`PQnotifies` NULL、`PQsetSingleRowMode` 0、`PQconnectPoll` 0、`PQtransactionStatus` 4 | L / async2 F |
| multi-host `host=127.0.0.1,127.0.0.1 port=1,54317` | 8 ステップ 20 ms で OK。**fd 番号は 7 のまま**（閉じて開き直し同じ番号）。REQ の「毎回 `PQsocket` を読み直す」は維持（番号が変わらないのは偶然） | async2 G |
| 未読結果ありの `PQfinish` | クラッシュ無し（リークは `test_leak` で） | async2 H |

### 2.2 cancel / NOTIFY（probe-async D・E・J、probe-async2 D・E）

| 項目 | 事実（実測） | 根拠 |
|---|---|---|
| cancel 結果待ち中 | `PQgetCancel` 非 NULL、`PQcancel` = 1、errbuf 空、呼び出し 1〜4 ms。結果: **FATAL_ERROR `57014` `canceling statement due to user request`** → NULL。cancel 呼び出しから結果まで **1〜4 ms**（REQ の 1 s 以内を満たす）。`PQtransactionStatus` → 0（IDLE） | D |
| cancel アイドル | `PQcancel` = 1（2 ms）、その後 `PQconsumeInput` 1 / `PQisBusy` 0 / `PQgetResult` NULL、次の `SELECT 42` は正常。**無害**（D11 どおり） | E |
| cancel tx 内 | `BEGIN` → `pg_sleep(10)` を cancel → 57014 → `PQtransactionStatus` **3（INERROR）** → 次文は `25P02` → `ROLLBACK` で復帰 | async2 D |
| cancel 切断後 | `PQgetCancel` = NULL（REQ: `CONNECTION`） | L |
| `PGnotify` レイアウト | `relname` char* @0、`be_pid` int @8、`extra` char* @16、`next` @24（**常に 0**）。`_ffi/types.mojo` の `PGnotify` 定義（Int, c_int, Int, Int）と一致。`PQfreemem` で解放 | J |
| NOTIFY 受信の形 | `PQnotifies` は `PQconsumeInput` の前は NULL（読まない）。`consumeInput` 後に 2 件（payload `payload-1` / 空文字）。`be_pid` は通知側の `pg_backend_pid()` と一致（1208195） | J |
| **到着は 1 件ずつ別メッセージ** | 同期側で `NOTIFY` を 2 回実行し終えた後でも、1 回の `wait_readable + PQconsumeInput` で **PG14 は 1 件、PG17 は 2 件**取れた（async2 E では両方 1 ラウンド）。2 件目は次の読み取りで来る → **テストは「揃うまで再試行」** | J / E |
| クエリ実行中の NOTIFY | `pg_sleep(0.5)` 中に送られた NOTIFY は結果ドレイン後の `PQnotifies` で取れる（結果処理が通知も拾う） | J2 |
| payload 7999 byte | 受信 7999 byte（上限 8000 未満）。UTF-8 `héllo` は 6 byte そのまま | J3 |
| tx 内 NOTIFY | 通知側 `BEGIN; NOTIFY` では届かず、`COMMIT` 後に届く | async2 E2 |
| 自分への NOTIFY | 同じ接続で `NOTIFY ch` → 結果ドレイン直後に `PQnotifies` 非 NULL | async2 E3 |

### 2.3 `_platform/poll`（probe-poll + ヘッダ照合）

- **Linux の値（`/usr/include/asm-generic/poll.h`。x86_64 / aarch64 共通）**: `POLLIN 0x0001` / `POLLPRI 0x0002` / `POLLOUT 0x0004` / `POLLERR 0x0008` /
  `POLLHUP 0x0010` / `POLLNVAL 0x0020`。`struct pollfd { int fd; short events; short revents; }`（8 byte）。`nfds_t` = `unsigned long`（8 byte、glibc）。
  `EINTR` = 4、`EAGAIN` = 11、`EBADF` = 9（`asm-generic/errno-base.h`）
- **macOS（xnu `bsd/sys/poll.h`、https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/poll.h）**: `:67-73, 88-90` `POLLIN 0x0001` / `POLLPRI 0x0002` / `POLLOUT 0x0004` /
  `POLLERR 0x0008` / `POLLHUP 0x0010` / `POLLNVAL 0x0020`（**使う 6 値は Linux と同一**。違うのは `POLLWRNORM`(= POLLOUT) / `POLLWRBAND 0x0100` で、使わない）。`:95-99` `struct pollfd` 同形、
  **`:101 typedef unsigned int nfds_t`（4 byte。glibc は 8 byte）** → 引数は `Int(1)` のレジスタ渡しでどちらも可。Apple の `poll(2)` は `/dev/*` を扱えない（BUGS）がソケット / pipe は可。
  errno は `__error()`（xnu `bsd/sys/errno.h:81-82`）。`CLOCK_MONOTONIC` = 6（Linux は 1。Mojo `std/time/time.mojo:40` が切替済み）
- **Windows `WSAPoll`（https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsapoll、`ns-winsock2-wsapollfd`、mingw-w64 `winsock2.h:1179-1196`）**:
  `WSAPOLLFD { SOCKET fd; SHORT events; SHORT revents; }` = **16 byte（fd @0 8 byte、events @8、revents @10）**。`POLLRDNORM 0x0100` / `POLLRDBAND 0x0200` / **`POLLIN 0x0300`** / `POLLPRI 0x0400` /
  `POLLWRNORM 0x0010` / **`POLLOUT 0x0010`** / `POLLWRBAND 0x0020` / **`POLLERR 0x0001` / `POLLHUP 0x0002` / `POLLNVAL 0x0004`**。`int WSAPoll(LPWSAPOLLFD, ULONG fds, INT timeout)`、`Ws2_32.dll`。
  落とし穴: `events` に `POLLERR` / `POLLHUP` / `POLLNVAL` / `POLLPRI` を入れると `SOCKET_ERROR` + `WSAEINVAL`（エラーは常に返るので要求しない）、戻り -1 の errno は `WSAGetLastError()`、
  **Windows 10 2004 より前は connect 失敗を報告しない**（2004 以降は `POLLHUP|POLLERR|POLLWRNORM`）、`WSAStartup` が要る（libpq が内部で呼ぶ: `PQconnectStart` 時点で済む見込み。未検証）
  → 定数は OS 分岐の中で定義し、戻り値は OS 非依存の `PollEvents`（readable / writable / error / hangup / invalid / timeout）に写す。Linux x86_64 は `arch/x86/include/uapi/asm/` に `poll.h` が無く
  asm-generic を使う（aarch64 と同じ値）。glibc `io/sys/poll.h:33` `nfds_t = unsigned long`
- **Mojo からの呼び方（実測、probe-poll）**:
  ```
  @fieldwise_init
  struct PollFd(TrivialRegisterPassable):
      var fd: Int32
      var events: Int16
      var revents: Int16
  var pfd = PollFd(Int32(fd), events, Int16(0))
  var ret = external_call["poll", c_int](Pointer(to=pfd), Int(1), c_int(timeout_ms))   # nfds は Int(1) でよい（64 bit レジスタ渡し）
  var e = Pointer[c_int, MutUntrackedOrigin](unsafe_from_address=external_call["__errno_location", Int]())[]  # ret < 0 のとき
  ```
  `size_of[PollFd]()` = 8（C と一致）
- **実測表（pipe / socketpair）**:

| 状況 | ret | revents | 経過 |
|---|---|---|---|
| 空の pipe 読み側、`POLLIN`、timeout 50 | 0 | 0 | 50 ms |
| pipe 書き側、`POLLOUT`、timeout 0 | 1 | 4 | 0 |
| 1 byte 書いた後の読み側、`POLLIN`、timeout 0 / -1 | 1 | 1 | 0（-1 でも即返る） |
| 書き側 close 後の読み側（未読 1 byte あり） | 1 | **17 = POLLIN\|POLLHUP** | 0 |
| close 済み fd | **1** | **32 = POLLNVAL** | 0（**ret は -1 ではない**。errno 0） |
| fd = -1 | 0 | 0 | 20 ms（無視され timeout） |
| nfds = 0、timeout 10 | 0 | — | 10 ms（純粋な sleep） |
| socketpair 片側、`POLLIN` / `POLLOUT` | 0 / 1 | 0 / 4 | 0 |
| 相手 close 後、`POLLIN` / `POLLOUT` | 1 / 1 | **17** / **20 = POLLOUT\|POLLHUP** | 0 |

- **単調時計**: `clock_gettime(CLOCK_MONOTONIC=1)` の ns と `std.time.perf_counter_ns()` の差は 0 ms（同じ時計）。**`std.time.monotonic() -> Int`（ns）も存在し `perf_counter_ns()` と同値**
  （実測 `263037006663462` が両方）→ 名前が意図を表す `monotonic()` を使う。`EINTR` 再試行の残り時間はこれで測る
- **errno は `from std.ffi import get_errno, ErrNo`（stdlib 公開。`std/sys/_libc_errno.mojo` が `__errno_location` / `__error` を OS で切替）**: `get_errno()` は `ErrNo`（`Writable`: `Bad file descriptor`、
  `.value` = 9、`== ErrNo.EBADF` / `ErrNo.EINTR`（`.value` 4）で比較。`Int(e)` は不可）。`__errno_location` の直書きは不要（probe-poll で動いたが stdlib 版に替える）
- **`socketpair(AF_UNIX=1, SOCK_STREAM=1, 0, fds)` / `pipe(fds)` はどちらも `external_call` で呼べる**（`fds` は `List[Int32]` 2 要素の `unsafe_ptr()`）。
  書き込みは `std.io.FileDescriptor(fd).write("A")`（§0.5 ☆ の `write` 衝突を避ける）。`close` は `external_call["close", c_int](c_int(fd))`
- `EINTR` の実測は無理に行わない（シグナルハンドラの登録が要る）。回避策はコードレビュー項目（§4 P4）

### 2.4 Mojo 1.1.0 言語（probe-lang + name-*）

- `CompilationTarget.is_linux()` → True、`is_macos()` → False（aarch64 Linux）。`comptime if CompilationTarget.is_linux(): ... elif CompilationTarget.is_macos(): ... else: ...`
  がコンパイル・実行とも通る。**`else` が Windows 分岐の置き場**（§0-3c）
- `c_short` 2 / `c_long` 8 / `c_ulong` 8 / `c_uint` 4 byte
- 存在する名前: `std.sys.info.platform_map`（`linux=` / `macos=` のみ）、`std.sys.CompilationTarget`、`std.ffi.c_ssize_t`。
  存在しない名前: `std.sys.os_is_*`、`std.sys.info.os_is_*`、`CompilationTarget.is_windows`、`std.os.errno`、`std.sys.is_x86`、
  `std.collections.string.utf8` / `.string_slice` モジュール（UTF-8 検証関数は公開されていない）

### 2.5 「accept するが応答しない」リスナー（D10）

- compose 定義（`scratch/turn-001-blackhole-compose.yml`。`tests/docker-compose.yml` にサービス追加）:
  ```yaml
  blackhole:
    image: alpine/socat
    command: -u TCP-LISTEN:5432,fork,reuseaddr OPEN:/dev/null
    ports:
      - "127.0.0.1:54399:5432"
  ```
  `-u` は単方向（TCP → /dev/null）なので**クライアントに 1 byte も返さず、接続も閉じない**。`fork` で複数接続可、`reuseaddr` で再起動即可
- 実測: `docker compose up -d --wait` は **0.66 s で `Healthy`**（healthcheck 無しのサービスは running = healthy 扱い）。Python で startup packet を送って
  `recv` が 0.7 s / 1.0 s で timeout（応答ゼロ）。libpq 側（probe-async N）: step 1 = 2 (WRITING)、step 2 = 1 (READING、status 7 SSL_STARTUP)、
  `poll(POLLIN, 500)` が **501 ms** で満了、`PQstatus` は 7 のまま、`PQerrorMessage` 空。→ `connect_blocking(conninfo, 500)` は `TIMEOUT` で
  500〜1500 ms の範囲に収まる見込み（処理は 1 ms 未満）
- イメージは `alpine/socat:latest`（初回 pull 済み）。CI 無しなので tag 固定は任意

### 2.6 UTF-8 検証（probe-lang）

| 入力 | `String(from_utf8=Span)` | `StringSlice(from_utf8=Span)` |
|---|---|---|
| `68 c3 a9`（`hé`） | OK、`byte_length` 3 | OK |
| `61 62 c3 28 63`（途中で不正） | raise `Cannot construct a String from invalid UTF-8 data` | raise `StringSpan: buffer is not valid UTF-8` |
| `61 e2 82`（末尾切れ） | raise（同文） | — |
| `c0 80`（overlong） | raise | — |
| `ed a0 80`（サロゲート） | raise | — |

- raise の型は素の `Error`、**不正位置は無い**。REQ §4.10 の「byte N」は自前で求める（§3-9）。既存の 3 経路: `result.mojo:435 _text`（`String(unsafe_from_utf8_ptr=)`、
  テキスト形式の全セル）、`decode_binary.mojo:715,725`（`String(unsafe_from_utf8=bytes)`、バイナリの文字列系 OID）、`result.mojo:765 get_text`
  （`StringSlice(unsafe_from_utf8=bytes)`）。`_text` は長さを `PQgetlength` で取って `Span` 化してから検証する形に変える（`unsafe_from_utf8_ptr` は strlen 走査）

### 2.7 PG14 と PG17 の差（probe-async / async2 の diff）

1. NOTIFY 2 件の到着が 1 回の `PQconsumeInput` に揃うか（PG17 は揃った、PG14 は 1 件 + 次回）— **タイミング差であって仕様差ではない**（async2 E では PG14 も 1 ラウンドで 2 件）
2. 16 MB クエリの最初の `PQflush`（PG17: 1、PG14: 0）— 同じくタイミング
3. 他は全行一致（cancel の ms、`57014`、`57P01`、`26000`、`25P02`、single-row の列、切断後の挙動、multi-host）。**サーバー版分岐のテストは Phase 4 には不要**

## 3. 盗める設計 / 使えるライブラリ（plan が採否表にする）

1. **psycopg 3 の 4 generator を Mojo のメソッドに写す**（§1.1）: `connect`（`PQconnectPoll` を WRITING 前提で開始、READING / WRITING で yield）、`send`（`PQflush` が 1 なら
   RW 待ち → `PQconsumeInput` → 再 `PQflush`）、`fetch_many`（`PQconsumeInput` → `PQisBusy` なら R 待ち → `PQgetResult` を NULL まで）、`notifies`（`PQconsumeInput` → `PQnotifies` を NULL まで）。
   本プロジェクトは yield の代わりに **1 ステップ進めて戻り値（`PollState` / `Optional[Result]`）で待ち方を返す**
2. **`PollState` / `AsyncState` は `ResultFormat` と同じ `@fieldwise_init struct X(Equatable, TrivialRegisterPassable, Writable)` + `comptime NeedRead = Self(0)`**。
   `write_to` で名前を書く（`USAGE` メッセージ `send() called while Busy` に使う）
3. **`adopt_result(pq, conn, res)` の抜き出し**: `connection.mojo:613-691 _take_result` の本文をモジュール関数へ（`PGRES_SINGLE_TUPLE` を成功に足す 1 行だけ変更）。
   `Connection._take_result` は `return adopt_result(self._pq, self._conn, res)` の 1 行に。`_error_field` も一緒に移す。置き場は `result.mojo`（`Result` を作る側）が自然
4. **`poll_connect` の D13 組み込み**: `PQconnectPoll` が 3 を返したら `PQsendQuery(_SESSION_SETUP_SQL)` → `PQflush` → 内部フラグ `_setup_pending = True`。以降の `poll_connect` は
   `PQconsumeInput` → `PQisBusy` なら `NeedRead` → `PQgetResult` 2 件（COMMAND_OK を確認、FATAL なら `CONNECTION`）→ NULL で `Ready`・`state = Idle`。
   結果件数は **2 + NULL**（§2.1 B）
5. **`state()` の遷移規則（libpq の実測に合わせる）**: `Connecting`（start〜`poll_connect` が `Ready`）→ `Idle` →（`send*` 成功）→ `PQflush` が 1 なら `Sending`、0 なら `Busy`
   →（`poll_result` が NULL）→ `Idle`。**`PQisBusy` が 0 でも NULL を見るまで `Busy`**（§2.1 G4）。`consume_input` が 0 を返したら `CONNECTION` を投げ、状態は `Busy` のまま
   でよい（次の `poll_result` が FATAL(sqlstate 空) → `CONNECTION`、その次が NULL → `Idle`。§2.1 切断行）
6. **`set_single_row_mode` のクライアント側ガード**: `_single_row_allowed` フラグを `send*` 成功時に True、`poll_result` / `consume_input` / `is_busy` のいずれかの呼び出しで False に。
   False なら `USAGE`（libpq の戻り値 1 は信用しない。§2.1）
7. **`cancel()`**: `state() == Busy or Sending` のときだけ `PQgetCancel` → `PQcancel(errbuf 256)` → `PQfreeCancel`。`Idle` は no-op（D11）。`Connecting` は **`USAGE` を提案**（§5-6）。
   `PQgetCancel` NULL / `PQcancel` 0 → `CONNECTION`（errbuf を message に。成功時 errbuf は空）
8. **`fetch_all(timeout_ms)`**: 全体の締め切り `deadline = perf_counter_ns() + timeout_ms*1e6`。ループ: `poll_result()` → `Some` なら append、`None` かつ `state()==Idle` なら終了、
   `None` かつ `Busy` なら `wait_readable(残り ms)`。`adopt_result` が投げたら `first_error` に保存して続行、NULL 到達後に `first_error` を投げる（D16）。
   残り ms が 0 以下なら `TIMEOUT`
9. **UTF-8（§4.10）の 2 段構え**: 速い経路 `String(from_utf8=span)` / `StringSlice(from_utf8=span)`（stdlib、SIMD 想定）。raise したら `_utf8_first_invalid(span) -> Int`
   （RFC 3629 の表 3-7 を素直に書いた 30 行のスキャナ。overlong / サロゲート / 末尾切れを弾く）で N を求め `TYPE_MISMATCH("invalid UTF-8 at byte N of column M")`。
   単体テストはスキャナに §2.6 の 5 バイト列を直接渡す（`c3 28` → 2、`e2 82` 末尾切れ → 1、`c0 80` → 0、`ed a0 80` → 0）。
   **陽性対照**: stdlib が raise する入力でスキャナが -1 を返さないこと（5 件全部）
10. **文字列系 OID の一元化（§4.9）**: `decode_binary.mojo` に `def _string_payload(bytes: Span[UInt8, origin], oid: UInt32) raises PgError -> Span[UInt8, origin]`
    （jsonb は version byte 検査 + 1 byte 剥がし、5 OID はそのまま、他は `_binary_oid_error`）を 1 つ置き、`decode_binary[String]`（`:706-725`）と `Row.get_text`（`:746-764`）が呼ぶ
11. **SKIP 集計（§4.8）**: `print("SKIP <name>: <reason>")` の後 `return`。`run_tests.sh` は `mojo run ... | tee` で出力を取り `grep -c '^SKIP '` を `skipped` に加算、サーバーごとに
    `-- <label> skipped N` を出す（約 10 行）。既存 2 件は `test_extended_datetime.mojo:840,875`、`test_leak.mojo:573`（`SKIP: RSS sampling is Linux-only` → 形式を揃える）
12. **テストの NOTIFY 受信は `wait_notification(2000)` を 2 回**（または `notifications()` を揃うまで 2 s 上限で再試行）。期待 payload は親が `psql` 相当（同期 `Connection`）で
    取り直す（REQ §9 常設）
13. **`wait_readable` の前に送信を終わらせる（ruby-pg :2578）**: `fetch_all` / `wait_notification` は `state() == Sending` なら先に `wait_writable` → `flush()`。`poll_result` 自体は
    `Sending` でも呼べる（`PQconsumeInput` → `PQisBusy` 真 → `None`）が、呼ぶ側が readable だけ待つとデッドロックし得る（libpq-async の注意）。`wait_readable` の docstring に書く
14. **`PollEvents` の判定順（psycopg `waiting.py` :446-491）**: `POLLNVAL` → `USAGE`；`POLLIN` / `POLLOUT` が立っていればエラービット併存でも readable / writable として返す（libpq に読ませて本当のエラー文言を得る）；
    **エラービットだけ**（`POLLERR` / `POLLHUP` 単独）→ `CONNECTION("socket closed")`。REQ §4.2「`POLLERR` / `POLLHUP` で `CONNECTION`」はこの「単独のとき」の意味で実装する（§5-11）
15. **`_platform/poll` の形（mojothon/libc と同型、§1.3）**: `def poll_socket(fd: Int, want_read: Bool, want_write: Bool, timeout_ms: Int) raises PgError -> PollEvents`、`PollEvents` は
    `@fieldwise_init struct PollEvents(TrivialRegisterPassable, Writable)` に `readable / writable / hangup / error: Bool`（timeout は全部 False）。OS 定数は `comptime if` の中の `comptime`

## 4. 落とし穴と検証方法（plan は完了基準に写す）

| # | 落とし穴 | 回避策 | どう検証すれば踏んでいないと分かるか |
|---|---|---|---|
| P1 | `PQconnectStartParams` が BAD を返した後に `PQsetnonblocking` を呼ぶ（-1）/ `PQsocket` -1 を poll する | start 直後に `PQstatus == CONNECTION_BAD` なら `PQfinish` して `CONNECTION`（REQ §4.2） | `AsyncConnection.start("host=nonexistent.invalid ...")` が `CONNECTION`（message に `could not translate host name`）、refused（port 1）は `poll_connect` が `CONNECTION`（`Connection refused`） |
| P2 | `PQconnectPoll` 前に POLLIN で待つ（最初は WRITING） | 最初の `poll_connect` は待たずに呼ぶ。`connect_blocking` は戻り値で待ち方を選ぶ | `poll_connect()` の最初の戻りが `NeedRead` または `NeedWrite` のどちらでも `connect_blocking` が完了する（実測の列 2,1,2,1,1,1,3 を docstring に） |
| P3 | 接続ごとに `PQsocket` を読み直さない（multi-host で fd が変わり得る） | `wait_*` は毎回 `PQsocket` を呼ぶ。`socket()` を保持しない | `host=127.0.0.1,127.0.0.1 port=1,<port>` で `connect_blocking` が成功（実測 8 ステップ 20 ms）。fd 変化そのものは断定しない |
| P4 | `poll` の `EINTR` を失敗にする / 残り時間を測り直さない | `ret == -1 and errno == EINTR` → `deadline - perf_counter_ns()` で再試行。他の errno は `CONNECTION`（`EBADF` / `EINVAL` は `USAGE`） | シグナルは起こせないのでコードレビュー: `_platform/poll` に `EINTR` 分岐と `perf_counter_ns` の再計算がある |
| P5 | `POLLNVAL` を readable 扱い / ret -1 を期待 | `revents & POLLNVAL` → `USAGE`（閉じた fd）。ret 1 で来る（§2.3） | 単体: pipe の両端を close した fd で `USAGE`。`POLLHUP` だけ（17 / 20）は `CONNECTION` でなく「readable」として返し、呼ぶ側が `PQconsumeInput` で切断を検出（libpq の切断メッセージの方が親切） |
| P6 | `timeout_ms < -1` を libc に渡す（Linux は無期限扱い） | `USAGE`（REQ §4.1） | 単体: `-2` → `USAGE`、`-1` は無期限（データありで即返る）、`0` 即時 |
| P7 | `external_call["write"]` 等を独自シグネチャで宣言して stdlib と衝突（§0.5 ☆） | `_platform/poll` は `poll` / `__errno_location`（macOS `__error`）だけ。テストの pipe 書きは `FileDescriptor` | コンパイルが通る（`test_poll.mojo` を `mojo run`） |
| P8 | Windows 分岐を `is_windows` で書く（存在しない） | `comptime if is_linux / elif is_macos / else`。`else` の docstring に「Windows、未検証」。`WSAPoll` は `external_call["WSAPoll", c_int]` で `WSAPOLLFD(fd: Int, events: Int16, revents: Int16)`（SOCKET 8 byte）、定数は §2.3 の Windows 値 | `pixi run package` と全テストが Linux で通る（else 分岐はコンパイルされない）。Phase 5 レビュー項目 |
| P9 | `state()` を `PQisBusy` から導く（最初の結果取得後〜NULL 前に `Idle` になる） | 自前の状態変数。NULL を見たときだけ `Idle` | 格子: `send("SELECT 1; SELECT 2")` → `poll_result` 1 件取得後 `state() == Busy`、この時点の `send` が `USAGE`（libpq に届く前。message `send() called while Busy`）。陽性対照: 状態検査を外すと libpq の `another command is already in progress` が `CONNECTION` として出る |
| P10 | D13 の SET を 1 結果だと思って `Ready` を早く返す | 結果 2 件 + NULL をドレイン（§2.1 B）。`CONNECTION_OK` 後に `SHOW DateStyle` | `connect_blocking` 後に `send("SHOW DateStyle")` → `ISO, YMD`、`state() == Idle`、`transaction_status() == PQTRANS_IDLE` |
| P11 | `poll_result` が `adopt_result` の raise で状態を壊す（NULL を取り切れない） | raise の前に内部状態は変えない（`Busy` のまま）。次の `poll_result` が NULL → `Idle` | `send("SELECT 1/0")` → `poll_result` が `SERVER 22012` → もう 1 回 `poll_result` が `None` で `state() == Idle` → `send("SELECT 1")` 成功。多文版 `SELECT 1; SELECT 1/0; SELECT 2` は 1 件 + エラー + NULL（3 文目の結果は無い） |
| P12 | `Sending` 状態をテストで断定する（`PQflush` = 1 は非決定的、§2.1 K） | `send*` の戻り後 `state()` は `Sending` **または** `Busy`。`flush()` は `Sending` でなければ no-op で `True` | テスト: 16 MB クエリ送信 → `flush()` を `True` までループ（0 回以上）→ `fetch_all` の値が `16000000`。「`Sending` を 1 回は観測」は書かない |
| P13 | `set_single_row_mode` を libpq の戻り値で判定（1 件目取得後も 1） | §3-6 のフラグ。`USAGE` メッセージに状態 | 格子: アイドル → `USAGE`、`send` 直後 → OK、`poll_result` 1 回呼んだ後 → `USAGE`。正例: `generate_series(1,3)` が `Result` 4 件（1 行 ×3 + 0 行）。多文は全文に効く（`SELECT 1; SELECT 2` → 4 件）。prepared でも効く |
| P14 | single-row の最後の 0 行 `TUPLES_OK` を落とす / エラー途中を落とす | `adopt_result` は 0 行も `Result`。途中エラーは `fetch_all` が残りを取り切って投げる | `fetch_all` の件数 4、途中エラー `generate_series(1,2), 1/(2-generate_series(1,2))` は 1 件取れた後 `SERVER 22012`、`state() == Idle` |
| P15 | cancel の 57014 を `fetch_all` が取り逃す / tx 内で `INERROR` を放置 | 57014 は普通の `SERVER` エラー。tx 内なら利用者が `ROLLBACK` | テスト: `cancel()` → `fetch_all(5000)` が `SERVER 57014`、`cancel()` 呼び出し〜raise が 1 s 未満（実測 1〜4 ms）。tx 内: `transaction_status() == PQTRANS_INERROR`、`send("ROLLBACK")` で `IDLE` |
| P16 | アイドル cancel を `USAGE` にする / 接続中 cancel を通す（`PQgetCancel` は非 NULL） | `Idle` no-op、`Connecting` は `USAGE`（提案 §5-6）、切断後は `PQgetCancel` NULL → `CONNECTION` | 格子 4 件: idle（例外なし、次の `send` 正常）/ connecting（`USAGE`）/ busy（57014）/ 切断後（`CONNECTION`） |
| P17 | `PQcancel` の errbuf を `String(unsafe_from_utf8_ptr=)` で読んで `PGcancel` を先に free する | 読んでから `PQfreeCancel`。成功時は空文字（message に入れない） | リーク: `test_leak` の cancel ループ 1,000 回 + 陽性対照（`PQfreeCancel` を消すと FAIL） |
| P18 | `notifications()` 1 回で全件取れると仮定（§2.2 到着行） | `wait_notification` でループ。テストは 2 s 上限で揃うまで | テスト: NOTIFY 2 件（payload あり / 空）→ `wait_notification(2000)` ×2 が両方 `Some`、順序 `payload-1`, `` 、`channel`、`backend_pid == 通知側 pg_backend_pid()`。3 回目は `None`（タイムアウト 200 ms） |
| P19 | `PGnotify` を `PQfreemem` し忘れ / `relname` を free 後に読む | `String` に複製してから `PQfreemem` | `test_leak` に NOTIFY 1,000 件受信 + 陽性対照（`PQfreemem` を消すと FAIL） |
| P20 | NOTIFY が結果ドレイン中に来ると `poll_result` だけで消える | libpq が内部キューに溜める（§2.2 J2）。`notifications()` はいつでも呼べる | テスト: `send("SELECT pg_sleep(0.3)")` 中に別接続が NOTIFY → `fetch_all` 後の `notifications()` が 1 件 |
| P21 | 切断後に `fetch_all` が止まらない / `CONNECTION` が出ない | `consume_input` 0 → `CONNECTION`。`PQgetResult` の 1 件目は sqlstate 空 + BAD → `adopt_result` が `CONNECTION`、2 件目 NULL | テスト: 別接続から `pg_terminate_backend` → `fetch_all` が `SERVER 57P01` または `CONNECTION`（どちらが先に見えるかは競合。両方許容）、その後 `send` が `CONNECTION`、`socket() == -1`、`status() == CONNECTION_BAD` |
| P22 | `__del__` で結果が残っていると二重解放 / クラッシュ | `PQfinish` だけ（libpq が片付ける。§2.1 H） | テスト: `send("SELECT 1; SELECT 2")` → `wait_readable` → `consume_input` → drop。クラッシュ無し。`test_leak` ループに「結果を取らずに drop」を含める |
| P23 | タイムアウトテストに `connect_timeout` を conninfo に入れる（libpq のブロッキング用。`PQconnectPoll` には効かない） | 入れない。`connect_blocking(conninfo, 500)` の全体締め切りで測る | テスト: 54399 へ `connect_blocking(..., 500)` が `TIMEOUT`、経過 500〜1500 ms（実測 501 ms）。`db-up` 後に `blackhole` が `Up` |
| P24 | `wait_*` の `TIMEOUT` と `wait_notification` の `None` を混同 | D8 どおり。`fetch_all` / `connect_blocking` は `TIMEOUT` | `wait_readable(50)`（アイドル接続）→ `TIMEOUT`。`wait_notification(50)` → `None` |
| P25 | `_text` を `String(from_utf8=)` に替えたら `PQgetlength` を使わず strlen になる / NUL 入り text が切れる | `PQgetvalue` + `PQgetlength` で `Span` → 検証 | 既存テストの期待値変更ゼロ（verify 照合）+ `pixi run bench` の text 列の差を PROGRESS に |
| P26 | UTF-8 不正の位置 N が stdlib から取れない（§2.6） | §3-9 の 2 段構え | 単体 5 件（§3-9）+ 陽性対照 |
| P27 | `adopt_result` 抜き出しで `Connection` の挙動が変わる | `_take_result` は 1 行の委譲に | 既存テスト 546 件 × 2 の期待値変更ゼロ、`grep -c "def _take_result" = 1`、`grep -c "PGRES_SINGLE_TUPLE" src/pq/result.mojo >= 1` |
| P28 | SKIP 集計が `mojo run` の終了コードを飲む | `set -o pipefail` か `PIPESTATUS[0]`（`final_check.sh:39-42` と同じ） | 陽性対照: 1 テストを一時的に fail させて `run_tests.sh` が非 0 |
| P29 | `test_leak` の非同期 10,000 回が遅い | 1 接続を使い回し、`send` → `fetch_all` のみ（`pg_sleep` 無し）。Phase 3 の同期 10,000 回と同程度（数 s） | `-- took Ns` が +15 s 以内 |
| P30 | examples が `--wait` 前に走る / blackhole が無いと `check` が落ちる | `db-up` は compose 全体（blackhole 込み）。タイムアウトテストは 54399 が `ECONNREFUSED` なら `SKIP`（理由付き） | `pixi run db-up` 後 `docker compose ps` に `blackhole` が `Up` |
| P31 | `PQcancel` は PG18 docs で「deprecated・insecure（cancel 要求は TLS で保護されない）」 | D6 どおり使う（libpq 14 対応）。`cancel()` の docstring に「cancel 要求は暗号化されない。`PQcancelBlocking`（17+）への切替は Phase 5 以降の判断」と明記 | `grep -c "not encrypted\|PQcancelBlocking" src/pq/async_conn.mojo` ≥ 1（docstring） |
| P32 | `is_busy()` で切断を検出しようとする（`PQisBusy` は `CONNECTION_BAD` なら 0） | 切断検出は `consume_input()`（0 → `CONNECTION`）と `poll_result` の sqlstate 空 FATAL。`is_busy()` は「結果が揃ったか」だけ | 切断テスト（P21）で `is_busy() == False` かつ `state() == Busy` の瞬間があっても `poll_result` が `CONNECTION` を投げる |
| P33 | `PGRES_POLLING_ACTIVE`(4) を `NeedRead` 扱いにして無限ループ | psycopg2 と同じく `CONNECTION`（libpq-fe.h「unused」） | コードレビュー: `poll_connect` の分岐に 0 / 1 / 2 / 3 以外 → `CONNECTION` |
| P34 | `PQerrorMessage` は追記式で前のエラーが残る（`fe-exec.c:1706-1715`） | `USAGE` 格子はクライアント側で先に弾く（libpq に届かせない）。`CONNECTION` の message は libpq 文言のまま（Phase 1 方針） | USAGE 格子のメッセージが `send() called while Busy` 等の自前文言で、libpq 文言を含まない |

## 5. 要件への影響

**直した（REQUIREMENTS.md に `（research turn 1 訂正）` 印）**:
1. §4.7 NOTIFY テスト: 「`notifications()` が 2 件」→「`wait_notification(2000)` を 2 回（または揃うまで 2 s 上限で再試行）で 2 件」（§2.2 到着行、P18）
2. §4.1 Windows 分岐の記述: `@parameter if` → `comptime if`、判定は `CompilationTarget.is_linux()` / `is_macos()` の `else`（P8）
3. §4.1 `POLL*` の値: 「OS で異なる → research が確定」→ Linux / macOS 同一（§2.3）、Windows のみ別値、を本文に

**提案（REQ は変えていない。plan が採否を決める）**:
4. §4.2 `state()` の `Sending` は「観測できることもある」扱い。テストは最終状態と値だけを断定（P12）
5. §4.2 `set_single_row_mode` の `USAGE` 条件を「`send*` の後、`poll_result` / `consume_input` / `is_busy` のどれかを呼ぶ前」と明記（libpq の戻り値は使わない。P13）
6. §4.2 `cancel()` を `Connecting` で呼んだら `USAGE`（`PQgetCancel` は非 NULL なので自前判定。P16）
7. §4.7 の格子に「切断後」の 1 列を足す（`pg_terminate_backend`。P21）。テストは競合を許容する 2 値期待
8. §4.7 タイムアウトテストは 54399 が refused なら `SKIP`（§4.8 の集計に乗る。P30）
9. §5.2 の「cancel 後」状態は tx 内なら `INERROR` と明記（P15）
10. §4.6 `examples/listen_notify.mojo` は `wait_notification(2000)` の戻りが `None` なら「no notification within 2 s」と表示して終了コード 0（CI 無しの手動実行で詰まらない）
11. §4.2 `wait_*` の「`POLLERR` / `POLLHUP` で `CONNECTION`」は「`POLLIN` / `POLLOUT` を伴わない単独のとき」に限定（§3-14。`POLLIN|POLLHUP` = 未読データ + 切断は readable として返し
    `consume_input` が libpq の文言で `CONNECTION` を出す）
12. §4.2 `cancel()` docstring に PG18 の deprecated / insecure 注記（P31）。D6 は変えない
13. `poll_connect` は `PGRES_POLLING_ACTIVE`(4) も `CONNECTION`（P33）

## 6. plan への申し送り

- **モジュール配置案**: `src/pq/_platform/__init__.mojo`（空）+ `_platform/poll.mojo`（`PollFd` 2 種・`PollEvents` struct・`poll_socket(fd, want_read, want_write, timeout_ms)`、
  約 150 行、docstring に Windows 未検証）/ `src/pq/async_conn.mojo`（`AsyncState`、`PollState`、`Notification`、`AsyncConnection`。約 900 行）/
  `result.mojo` に `adopt_result` + `_error_field` 移設（`connection.mojo` から -80 行）/ `errors.mojo` に `TIMEOUT` / `_ffi/functions.mojo` に `PQsetSingleRowMode`（2 箇所）/
  `decode_binary.mojo` に `_string_payload` と `_utf8_first_invalid` / `__init__.mojo` に再エクスポート
- **テストファイル案**: `tests/test_poll.mojo`（サーバー不要。pipe / socketpair の 7 ケース、P5 / P6）、`tests/test_async.mojo`（接続・GUC・pg_sleep カウンタ・cancel 4 格子・USAGE 格子・
  single-row・多文・エラー後復帰・切断・16 MB flush・タイムアウト。接続 10〜12 本 × 3〜7 s + pg_sleep 2 s + cancel + timeout 0.5 s ≈ **40〜60 s / サーバー**）、
  `tests/test_notify.mojo`（2 件・順序・pid・7999 byte・クエリ中到着・tx 内 NOTIFY は COMMIT 後。接続 4 本 ≈ 15 s）、`tests/test_decode_binary.mojo` に UTF-8 スキャナ 5 件、
  `test_leak.mojo` に非同期 10,000 回 + NOTIFY 1,000 件 + cancel 1,000 回（+10〜15 s、1 サーバー）
- **所要見積もり**: `check` は前回末 112〜143 s + 新テスト（test_async 50 s + test_notify 15 s）× 2 サーバー + leak 15 s ≈ **260〜300 s**。plan は `final_check.sh` の
  タイムアウトがあれば確認。examples 2 本は各 3〜5 s（`async_query` は pg_sleep 2 s 込み）
- **期待値の出典**: 本書 §2.1 / §2.2 の sqlstate（`57014` / `57P01` / `22012` / `26000` / `25P02`）、メッセージ（`canceling statement due to user request` /
  `another command is already in progress` / `no connection to the server`）、`PQconnectPoll` の列、single-row の件数は全部 PG17 / PG14 実測。
  原本ログ: `scratch/turn-001-probe-async-pg17.log`（165 行）/ `-pg14.log`、`turn-001-probe-async2-pg17.log` / `-pg14.log`、`turn-001-probe-poll.log`
- **サブエージェント推奨本数**（REQ §9 の実験）: `_platform/poll` + `test_poll`（1 ファイル完結 + テスト 1）は 0 本。`async_conn.mojo` は 1 ファイルだが大きく、
  テスト 2 ファイル（`test_async` / `test_notify`）が「`src/` を触らずテスト 2 ファイル」型 → **1 本**（親が `test_notify` を書く。REQ §9 の実験条件）。
  `adopt_result` 抜き出し・`TIMEOUT`・`_ffi` 追加・§4.9 / §4.10 は親が直接（0 本）
- **陽性対照を完了基準に**: leak（`PQfreeCancel` / `PQfreemem` を消したコピーで FAIL。P17 / P19）、USAGE 格子（状態検査を外すと libpq のメッセージが `CONNECTION` で出る。P9）、
  UTF-8 スキャナ（stdlib が raise する 5 入力で -1 を返さない。P26）、SKIP 集計（P28）
- **チェックリストスクリプト（REQ §9）の行の候補**: `grep -c "def _take_result" src/pq/connection.mojo` = 1 / `grep -c "def adopt_result" src/pq/result.mojo` = 1 /
  `grep -c "PQsetSingleRowMode" src/pq/_ffi/functions.mojo` = 2 / `grep -c "TIMEOUT" src/pq/errors.mojo` ≥ 2 / `grep -c "unsafe_from_utf8" src/pq/result.mojo src/pq/decode_binary.mojo`
  = 0（検証付きに置換後）/ `grep -c "^SKIP " <test log>` / `grep -c "blackhole" tests/docker-compose.yml` = 1 / `grep -c "example-async\|example-notify" pixi.toml` = 2
- **impl への申し送り**: 親が同期 `Connection` で `pg_backend_pid()` / `57014` の message / NOTIFY payload を取り直す（REQ §9 常設）。`PGnotify` の読み出しは
  `_ffi/types.mojo` の `PGnotify` struct を `Pointer[PGnotify, MutUntrackedOrigin](unsafe_from_address=n._addr)[]` で読む（offset は §2.2 で照合済み）
- **REQ §9 の verify 申し送り**: `adopt_result` 抜き出し・§4.9・§4.10 で既存テストの期待値変更ゼロ（§4.10 だけ新規 5 件が増える）
