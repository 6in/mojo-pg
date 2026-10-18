# TRACE — phase5-polish-bench-readme

PROGRESS.md は 1 ターン 40 行上限なので、生の値・表・転記はここに置く（決めた事項 13）。

## PLAN 訂正（turn N）

<!-- 1 件 1 行。`PLAN 訂正: <旧> → <新>（根拠）` の形 -->

- turn 4 / PLAN 訂正: T2 (b) の docstring **16 行 → 18 行**（`src/pq/result.mojo` の `Raises:` 2 箇所、`get_text`（旧 `:557`）と
  `get_text_slice`（旧 `:880`）が「`TYPE_MISMATCH` ... or when the cell is not valid UTF-8」と 1 つの項目で述べていた。
  同一行 grep（`src_utf8_and_type_mismatch_same_line`）には当たらないが UTF-8 失敗を `TYPE_MISMATCH` と書いており、
  `ENCODING` に分けた。決めた事項 3 の 16 行の列挙に漏れていただけで、要件・決定（D9）には反しない）
- turn 4 / PLAN 訂正: T2 (c) の対象行番号 `tests/test_notify.mojo:492,534` → **`:519,563`**（T1 で同ファイルが +32 行ずれた。
  `tests/test_decode_binary.mojo:470,481,489,497,538` は不変）
- turn 5 / PLAN 訂正: 追従先チェックリストの `async_reject_lost_calls` の T3 期待値 **≥ 4 → 3（不変）**（PLAN の表は
  `wait_notifications` が `_reject_lost` の 3 つ目の呼び出し元になると見込んでいたが、PLAN T3 (a) / 決めた事項 5 自身が
  「入口検査は `_collect_notifications` の中で `_reject_lost(method)` を 1 回」「`wait_notification` は `_collect_notifications`
  の薄いラッパ」と定めている。実装どおりに書くと呼び出し元は `notifications`（直接）と `_collect_notifications`（両公開待ちの
  共通入口）の **2 箇所 + def 1 = 3**。表の見込みが (a) の設計と食い違っていただけで、要件・決定には反しない。
  挙動は既存テスト `test_a_lost_connection_is_reported_with_a_fixed_message` が `wait_notification() called on a lost
  connection` の完全一致で担保しており、`method` 経由で正しく届いている）
- turn 5 / PLAN 訂正: T3 (c) の格子 **8 件 → 9 件**（⑧ `test_wait_notifications_keeps_collected_ones_when_a_later_one_is_rejected`
  に加えて `test_wait_notifications_keeps_collected_ones_across_two_round_trips` を足した。根拠は陽性対照の実測:
  `_collect_notifications` の `except` から `out` を `_pending` に戻す 7 行を消しても ⑧ は **PASS した**
  （`scratch/turn-005-notify-norestore.log`）。PLAN ⑧ の注が予見したとおりこのマシンは 2 件を 1 往復で届け、`ok` は
  `notifications()` 内側の `self._pending = found^` で保全されるため、⑧ は `out` 保全を判別しない。
  追加版は**第 3 の接続**から `SELECT pg_sleep(0.3); NOTIFY ...（不正 UTF-8）` を await せずに送り、listener が
  `wait_notifications(2, 3000)` に入った後に commit させることで 1 往復目が `ok` だけを運ぶ形を強制する。
  restore 7 行なしで **FAIL**（`scratch/turn-005-notify-norestore2.log`）、ありで PASS。
  要件・決定の追加ではなく、決めた事項 5 が定めた「`out` を `_pending` の先頭に戻す」の検証手段を足しただけ）
- turn 5 / PLAN 訂正: T3 (c) の前提「`tests/test_notify.mojo` の既存テストは 11 件」→ **12 件**
  （T2 で足した `test_a_lost_connection_is_reported_with_a_fixed_message` を数え落としていた。
  `test_notify_tests` = 12 + 12 = **24**。期待値 ≥ 21 の範囲内）
- turn 6 / PLAN 訂正: 追従先チェックリストの `loader_libpq_dll` の T4 期待値 **1 → ≥ 2（実測 3）**
  （表は RESEARCH §2.4 の「`grep -c "libpq.dll"` 0 → 1」をそのまま写していたが、PLAN T4 (c) 自身が
  `_default_candidates` の `else` の戻り値に加えて**モジュール docstring にも**「`libpq.dll` on Windows -- the last
  **unverified**」を書くことを完了基準にしている。実装どおりに書くと最低 2 箇所になる。実測 **2**
  （module docstring / `_default_candidates` の `else` の戻り値）。
  表の数え落としだけで、要件・決定には反しない。`loader_platform_map` = 0 は満たしている
  — 当初 `_default_candidates` の docstring に「`platform_map` には `windows=` が無い」と識別子で書いて 1 件になったので、
  同じ意味を「the stdlib's compile-time platform map」と言い換えて 0 に戻した）

## `test_zero_copy` の所要

転記元: `.gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-001-zerocopy-time.log`
（2026-10-17 21:58 JST、pg17 54317）。**単位は 1 行目から最後まですべてミリ秒（ms）**。

| 計測 | TestSuite の `Summary [ n ]` | wall（外側の計測） |
|---|---|---|
| `test_zero_copy`、`PQ_TEST_CONNINFO` 未設定（12 件） | 56.293 ms | 1835 ms |
| `test_zero_copy`、`PQ_TEST_CONNINFO` 設定（`run_tests.sh` と同じ。12 件） | 48.866 ms | 1625 ms |
| 対照 `test_result`（同じ `_connect` ヘルパ。15 件） | 65.512 ms | 1871 ms |
| `test_zero_copy` をビルドしてバイナリで実行（12 件） | 48.829 ms | build 3140 ms / run 52 ms |
| 対照 `test_result` をビルドしてバイナリで実行（15 件） | 71.727 ms | build 4145 ms / run 76 ms |

単位の裏取り: `build/final_check.log:48` の `PASS [ 2033.338 ] test_poll_result_counts_while_sleeping`
は `pg_sleep(2)` のテスト → `[ n ]` は秒ではなくミリ秒。

**結論**: TestSuite の `[ n ]` はミリ秒。1 テスト 3.4〜3.9 ms は接続 1 本の固定費で、対照の
`test_result` と同じ水準。REQ §1 / §4.5 が疑った「1 テスト 3.4〜3.9 秒」は単位の読み違いで、
**直すものは無い**。wall の 1.6〜1.9 秒はほぼ `mojo run` のコンパイルで、バイナリ実行は 52〜76 ms。

## `_after_send` -1 のコードレビュー

`src/pq/async_conn.mojo` の `_after_send` の `else`（`PQflush` が `-1`）は**到達不能**。分岐は
入れ（`AsyncState.BUSY` に置いてから raise）、陽性対照はテストではなくこのコードレビューで
担保する（REQ §4.5 / RESEARCH §2.7 / 決めた事項 17）。

libpq（PG18）の根拠 3 行:

1. `PQflush`（`fe-exec.c`）: `if (!conn || conn->status == CONNECTION_BAD) return -1; return pqFlush(conn);`
   → **`-1` を返すのは status が既に `CONNECTION_BAD` のときだけ**。
2. `pqSendSome`（`fe-misc.c`）: `sock == PGINVALID_SOCKET` のとき `write_failed = true` +
   「connection not open」+ `outCount = 0` + **`return 0`** → 送信先が無くても `-1` にならない。
3. `pqsecure_raw_write`（`fe-secure.c`）: `EPIPE` / `ECONNRESET` / default（`EBADF` を含む）の
   すべてで `write_failed = true` + `write_err_msg` を保存し **`n = len` を返す（成功したことにする）**
   → 書き込みエラーは `PQflush` の戻り値に出ない。

`PQsendQueryStart` は `status != CONNECTION_OK` なら 0 を返して失敗するので、`PQsendQuery` が
成功した時点で status は `CONNECTION_OK`。同一スレッドで `PQsendQuery` と直後の `PQflush` の
間に status が `CONNECTION_BAD` に変わる経路は無い → `_after_send` の `PQflush` は 0 か 1 のみ。

実測 B（`scratch/turn-001-probe-closefd.log:10-13`）がこれを裏づける。`close(PQsocket)` した
IDLE 接続に `send("SELECT 1")` を出しても:

```
B send succeeded; BUSY: True SENDING: False
B state IDLE: False
B PQstatus BAD: False
B PQflush: 0
```

送信は「成功」し、`PQflush` は 0、status は OK のまま。

**なぜ `BUSY` に置くか**: libpq は `PQsendQuery` が成功した時点で `PGASYNC_BUSY`
（`pqAppendCmdQueueEntry`）。`pq` も `BUSY` に揃えておけば、エラーを無視して次に `send` した
呼び出し元は libpq の「another command is already in progress」より先に `pq` 自身の `USAGE`
（`send() called while Busy`）を受け取る。Phase 4 の「left at IDLE because there are no results
to drain」というコメントは、到達不能な分岐で状態を libpq とずらす理由にならないので消した。

## Windows 照合表（`_platform/poll.mojo` の `else` 分岐）

RESEARCH §2.3 の照合表をそのまま写した（turn 6 / T4）。一次資料:

- [F] https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsapoll （WSAPoll function）
- [S] https://learn.microsoft.com/en-us/windows/win32/api/winsock2/ns-winsock2-wsapollfd （WSAPOLLFD structure）
- [E] https://learn.microsoft.com/en-us/windows/win32/winsock/windows-sockets-error-codes-2 （Windows Sockets Error Codes）
- [H] https://raw.githubusercontent.com/mirror/mingw-w64/master/mingw-w64-headers/include/winsock2.h （フラグの数値。MS Learn には数値が無い）

| # | 項目 | poll.mojo の現状 | 根拠 | 判定 |
|---|---|---|---|---|
| 1 | `WSAPOLLFD` = `{ SOCKET fd; SHORT events; SHORT revents; }`、`SOCKET` = `UINT_PTR`（x64 で 8 byte）→ 16 byte | `_WsaPollFd(fd: Int, events: Int16, revents: Int16)`、`size_of` = 16（実測） | [S] 構造体定義、[H] typedef、`probe-lang.log` | **一致** |
| 2 | `POLLRDNORM 0x0100`、`POLLRDBAND 0x0200`、`POLLIN = RDNORM\|RDBAND = 0x0300`、`POLLWRNORM 0x0010 = POLLOUT`、`POLLERR 0x0001`、`POLLHUP 0x0002`、`POLLNVAL 0x0004` | `_WSA_POLLIN 0x0300`、`_WSA_POLLOUT 0x0010`、`_WSA_POLLERR 0x0001`、`_WSA_POLLHUP 0x0002`、`_WSA_POLLNVAL 0x0004` | [H] `#define` 行、[S]「POLLIN は RDNORM と RDBAND の組」 | **一致** |
| 3 | `events` に置けるのは `POLLPRI` / `POLLRDBAND` / `POLLRDNORM` / `POLLWRNORM` のみ。他の値は `SOCKET_ERROR` + `WSAEINVAL`。`POLLPRI` は MS プロバイダで失敗 | ERR / HUP / NVAL を `events` に入れない（docstring 明記）、`POLLPRI` を使わない | [F] Remarks、[S] events | **一致**（`POLLRDBAND` を要求するのは許容範囲。`0x0100` だけにする案は任意） |
| 4 | `timeout`（INT）: > 0 は ms、0 は即時、< 0 は無期限 | `c_int(timeout_ms)`、-1 で無期限 | [F] Parameters / Remarks | **一致** |
| 5 | 戻り値: 0 = タイムアウト、> 0 = `revents` 非 0 の要素数、`SOCKET_ERROR`(-1) = 失敗 | `ret == 0` → timeout、`ret < 0` → エラー、それ以外は flags | [F] Return value | **一致** |
| 6 | **失敗理由は `WSAGetLastError()`**（`ws2_32.dll`）。Winsock は errno を設定しない。`WSAEINVAL` 10022 / `WSAENOTSOCK` 10038 / `WSAEBADF` 10009 / `WSAEFAULT` 10014 / `WSAENETDOWN` 10050 / `WSAENOBUFS` 10055 / `WSANOTINITIALISED` 10093 / `WSAEINTR` 10004（`WSACancelBlockingCall` 時のみ） | `poll_socket` が `get_errno()` → `ErrNo.EINTR` / `EBADF` / `EINVAL` を見る（POSIX の値 4 / 9 / 22） | [E] 冒頭「WSAGetLastError を直後に呼ぶ」+ 一覧、[F] Return value「Call the WSAGetLastError function」 | **不一致 → 直す**。`_poll_once` の `else` 分岐で `external_call["WSAGetLastError", c_int]()` を読み、10022 / 10038 / 10009 → `USAGE`、それ以外 → `CONNECTION`、`EINTR` 再試行はしない（§3-2 の形） |
| 7 | `revents` の `POLLNVAL` = 無効なソケット。`fd` が負の要素は無視され `revents` は [F] では `POLLNVAL`、[S] では「クリア」（**公式同士で食い違い**） | `POLLNVAL` → `USAGE`（`poll: fd N is not open`） | [F] Remarks 末尾、[S] Remarks | **一致**（`PQsocket` = -1 のときは [F] なら `USAGE`、[S] なら要素 0 個扱いで `WSAEINVAL`「none of the sockets valid」→ #6 修正後は同じ `USAGE`） |
| 8 | **Windows 10 2004 以降**、TCP 接続失敗は `POLLHUP \| POLLERR \| POLLWRNORM` で通知。それ以前は通知されない（既知の仕様差） | 非同期接続は `wait_writable` で待つ → 古い Windows では接続失敗が予算切れ（`TIMEOUT`）まで分からない | [F] Remarks の Note | **README に明記**（コード変更なし。「Windows 10 2004 より前は接続失敗の検出がタイムアウト頼み」） |
| 9 | `WSAPoll` は Vista 以降、`Ws2_32.dll`、`WSAAPI` = `WINAPI`（x64 では既定の呼出規約と同一） | `external_call["WSAPoll", c_int](Pointer, Int(1), c_int)` | [F] Requirements、[H] `#define WSAAPI WINAPI` | **一致**（x64 前提。シンボル解決は未検証のまま） |
| 10 | `nfds` は `ULONG`（32 bit） | `Int(1)`（64 bit） | [F] Syntax | **許容**（x64 ABI は下位 32 bit を使う。POSIX 側の `nfds_t` も 64 bit で同じ書き方） |
| 11 | `WSAStartup` 未実行だと `WSANOTINITIALISED` 10093 | `poll_socket` は libpq の `PQsocket` にしか使わない。libpq は接続開始時に `WSAStartup` を呼ぶ（fe-connect.c、`#ifdef WIN32`。未取得） | [E] 10093 | **一致の見込み**（docstring に「libpq の socket 以外に使う場合は WSAStartup が要る」を 1 行） |
| 12 | `SOCKET` は符号なし、`PQsocket` は `int` | `fd: Int` | libpq の `PQsocket` は `int` を返す（全 OS） | **一致** |

**#6 を直した**（`_poll_once` が `Tuple[Int, Int, Int]`（ret, flags, err）を返し、err は POSIX なら
`get_errno().value`、Windows なら `WSAGetLastError()`。分類は `_is_interrupted`（Windows は常に False）と
`_is_usage_error`（Windows は 10009 / 10022 / 10038）の 2 ヘルパ。message は `poll failed: errno <N>`）。
**#8 / #11 は docstring と README**（コード変更なし。docstring はモジュール冒頭の Windows 注記に入れた。
README は T6）。他の 10 行は一致のまま、コードは触っていない。

`else` 分岐の複製ビルド（T4 (d)、P12）:

```
pixi run mojo build -I src .gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-006-win-typecheck.mojo -o build/win-typecheck
```

→ **出力ゼロ・exit 0 で `build/win-typecheck`（74,472 bytes）が生成された**。`_WsaPollFd` と `_WSA_POLL*`、
`_poll_once` の `else` 本体、`_is_interrupted` / `_is_usage_error` の Windows 側を `comptime if True:` 側に
複製したもので、型検査だけでなくリンクも通った（`external_call` は実行時解決なので Linux に `WSAPoll` /
`WSAGetLastError` が無くてもリンクは成功する）。**実行はしていない**（`main` は `size_of` を出すだけだが
PLAN T4 (d) のとおり走らせない。`size_of(_WsaPollFd)` = 16 は RESEARCH の `probe-lang.log` が実測済み）。
Windows 実機での動作は依然として未検証（REQ §3）。

## examples 堅牢性の格子

<!-- T7 (b)。REQ §5 堅牢性（D4）/ P17 -->

スクリプト `.gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-009-examples-robust.sh`
（turn 1 のプローブ 15 本に `bench_psycopg` の badpw / badport 2 本を足した 17 本）。
生ログ `scratch/turn-009-examples-robust.log`（2026-10-18 00:18、`pixi run check` の後）。
判定は 3 つ: `rc=1` / `unhandled_markers=0`（`traceback|unhandled|abort|segfault|core dumped|fatal error` を
大小無視で grep）/ 出力が `failed: ...` の 1 レコード。

- `BADPW` = `host=127.0.0.1 port=54317 user=pq password=wrong dbname=pq_test`
- `BADPORT` = `host=127.0.0.1 port=54390 user=pq password=pq dbname=pq_test connect_timeout=3`

| # | ケース | rc | lines | unhandled | 出力の 1 行目 |
|---|---|---|---|---|---|
| 1 | `basic` badpw | 1 | 2 | 0 | `failed: PgError(kind=Connection, message=connection to server ... password authentication failed ...)` |
| 2 | `basic` badport | 1 | 3 | 0 | `failed: PgError(kind=Connection, ... Connection refused` + libpq のヒント行） |
| 3 | `params` badpw | 1 | 2 | 0 | 同上（`kind=Connection`） |
| 4 | `params` badport | 1 | 3 | 0 | 同上 |
| 5 | `binary` badpw | 1 | 2 | 0 | 同上 |
| 6 | `binary` badport | 1 | 3 | 0 | 同上 |
| 7 | `async_query` badpw | 1 | 2 | 0 | 同上 |
| 8 | `async_query` badport | 1 | 3 | 0 | 同上 |
| 9 | `listen_notify` badpw | 1 | 2 | 0 | 同上 |
| 10 | `listen_notify` badport | 1 | 3 | 0 | 同上 |
| 11 | `bench_formats` badpw | 1 | 2 | 0 | 同上 |
| 12 | `bench_formats` badport | 1 | 3 | 0 | 同上 |
| 13 | `hello_libpq` nolib（`PQ_MOJO_LIBPQ=/nonexistent/libpq.so`） | 1 | 1 | 0 | `failed: PgError(kind=LibpqLoad, message=libpq not found. tried: /nonexistent/libpq.so: dlopen failed ...)` |
| 14 | `basic` 不正 conninfo（`port=abc`） | 1 | 2 | 0 | `failed: PgError(kind=Connection, message=invalid integer value "abc" for connection option "port")` |
| 15 | `basic` nolib | 1 | 1 | 0 | `failed: PgError(kind=LibpqLoad, ...)` |
| 16 | `bench_psycopg` badpw | 1 | 2 | 0 | `failed: OperationalError connection failed: ... FATAL:  password authentication failed for user "pq"`（1 行目は pixi のタスクバナー） |
| 17 | `bench_psycopg` badport | 1 | 3 | 0 | `failed: OperationalError connection failed: ... Connection refused` + libpq のヒント行 |

**結果 17/17**: 全行 `rc=1` かつ `unhandled_markers=0`。`Traceback` / `Unhandled` / `stack trace` は 1 行も出ていない
（`lines` の 2〜3 は libpq 自身が message に含める改行・ヒント行と pixi のバナーで、レコードは 1 件。PLAN T5 (c) の訂正と同じ判定）。
examples 7 本（`hello_libpq` を含む）と bench 2 本（Mojo の `bench_formats`、psycopg）がすべて `PgError` /
`psycopg.Error` を印字して終了コード 1 で終わる。この格子は `check` に入れていない（決めた事項 / RESEARCH §3-9:
`check` に + 70 s 載せない）ので、verify は上記スクリプトを再実行して再現できる
（PLAN の見積もり ≈ 70 s。今回はログの書き込み完了が 00:18:24、起動が 00:17:45 以降なので **40 s 弱**）。

## 受け入れ基準対応表

<!-- T7 (d)。HANDOFF §10 Phase 5 の 3 項目 + REQ §5 の各行 -->

| 受け入れ基準（出典） | 担保したタスク | テスト / 検査 | ログ |
|---|---|---|---|
| HANDOFF §10-1: ベンチマーク結果が README にある | T5 (d) + T6 (b) | `README.md` §6（Mojo / psycopg × text / binary、3 回の値を `a / b / c`、計測環境 + 日付 + 再現手順）。12 セルを原本ログと 1 つずつ照合（turn 8） | `scratch/turn-007-bench.log`（原本・pass 1）、`turn-007-bench-first.log` |
| HANDOFF §10-2: `examples/` が全部実行できる | T1 (g) + T6 (c) + T7 (a)(b) | `check` 4/6 段が 5 本を実行、`pixi run hello-libpq` と `pixi run bench`/`bench-psycopg` は `check` 外で別途。7 本すべて docstring に `pixi run <task>`（`examples_pixi_run` = 7） | `scratch/turn-009-check.log`、`turn-008-hello.log`、`turn-007-bench.log` |
| HANDOFF §10-3: Windows 用コード（`WSAPoll`、DLL 名）が存在し、未検証であることが README に明記 | T4 (a)(b)(c)(e) | `poll.mojo` の `WSAPoll` / `WSAGetLastError` / 10009・10022・10038 分類、`loader.mojo` の `libpq.dll`、TRACE 照合表 12 行 + URL 4 本、`README.md` §8（`readme_unverified_windows` = 3） | `scratch/turn-006-win-typecheck.log`、`turn-009-checklist.log` |
| REQ §5 共通: `pixi run check` が PASS（fmt / precompile / docstring / examples / tests 両サーバー / 警告ゼロ） | T7 (a) | `pixi run check` 6/6 PASS（`final_check: PASS`）。`pixi run test` も両サーバー PASS（leak 両方） | `scratch/turn-009-check.log`、`turn-009-test.log` |
| REQ §5 堅牢性（D4）: DB 未起動・認証失敗・切断・不正引数でトレースバックを出さず、既存データを失わない。examples / bench は `PgError` を印字して exit 1 | T1 (g) + T5 (c) + T7 (b) + T3 (a) | 格子 17 本が全行 `rc=1` / `unhandled_markers=0`。既存データの保全は `wait_notifications` の `out` 復元テスト ⑧⑨（`test_notify.mojo`）と `_drop_ascii_database` の「失敗を握って元の結果を隠さない」形で担保 | `scratch/turn-009-examples-robust.log`、`turn-007-bench-robust.log`、`turn-005-notify-norestore2.log` |
| REQ §5 持ち越し: `fetch_all` が `kind == CONNECTION` で打ち切る | T1 (a)(b) | `test_fetch_all_stops_draining_on_a_closed_socket`（`tests/test_async.mojo`。修正前は 2000 ms 後に `TIMEOUT` で FAIL = 陽性対照） | `scratch/turn-001-probe-closefd.log`、`turn-003-check.log` |
| REQ §5 持ち越し: `PQflush` -1 の分岐がコードにある（到達困難ならレビューで担保し TRACE に記載） | T1 (c) | TRACE「`_after_send` -1 のコードレビュー」節（libpq 根拠 3 行）。`async_after_send_PGASYNC_BUSY` ≥ 1 / `left_at_idle` = 0 | `scratch/turn-003-checklist.log`、`turn-009-checklist.log` |
| REQ §5 持ち越し: `test_notify` 実行後に `pq_test_ascii` が残らない | T1 (d)(e) + T7 (c) | `_drop_ascii_database()` を先頭と末尾（`WITH (FORCE)`）。`docker exec psql ... pg_database` が pg17 / pg14 とも 0 行（turn 3・4・5・6 と T7 で再確認）。陽性対照は末尾 DROP を外した scratch が 1 行残すこと | `scratch/turn-003-{db-reset,check}.log`、`turn-009-pgdatabase.log` |
| REQ §5 持ち越し: `test_zero_copy` の原因が TRACE に記録されている | T1 (h) | TRACE「`test_zero_copy` の所要」節（5 行の表、単位 ms、結論「接続 1 本の固定費。直すものは無い」） | `scratch/turn-001-zerocopy-time.log` |
| REQ §5 契約外提案: 新テストがすべて PASS | T2 / T3 | `test_errors` 9 / `test_decode_binary` 88 / `test_notify` 24 / `test_async` 31 / `test_poll` 11（全サマリ `0 failed`） | `scratch/turn-009-test.log` |
| REQ §5 契約外提案: `ENCODING` への期待値変更で取りこぼしが無い（`grep -rn 'invalid UTF-8' tests/` の全件が `ENCODING`） | T2 (c) | `tests_TYPE_MISMATCH` = 91 / `tests_ENCODING` ≥ 8 / `src_utf8_and_type_mismatch_same_line` = 0 / `src_invalid_utf8_raise_sites` = 4。変更した 7 行は PROGRESS turn 4 に全列挙 | `scratch/turn-004-checklist.log`、`turn-009-checklist.log` |
| REQ §5 Windows: 照合表が TRACE にあり `loader.mojo` に `libpq.dll` の行がある。Linux / macOS の挙動は変わらない | T4 (c)(e)(f) | `trace_wsapoll_table` ≥ 1 / `loader_libpq_dll` ≥ 2 / `test_poll_tests` = 11（不変）。挙動不変は `check` PASS で担保 | `scratch/turn-006-{checklist,check}.log`、`turn-009-check.log` |
| REQ §5 README: コード片は `examples/` から抜粋し `examples/` の実行で検証済み。型表と `PgErrorKind` 一覧が実装と一致 | T6 (b)(d) | `turn-008-readme-excerpts.py`（6 ブロック逐語一致 `missing_total=0`）、`turn-008-typetable.py`（OID 19 行・Mojo 型列が `__init__.mojo:42-62` と一致）、`PgErrorKind` 8 値が `errors.mojo` の宣言順・印字名と一致 | `scratch/turn-008-{readme-excerpts,typetable}.log` |
| REQ §5 所要: `check` が 167〜187 s + 60 s = 247 s を超えない | T7 (a) | 各ターンの `check` 実測（185 / 177 / 177 / 182・215 / 169 / 187 s）と T7 の実測。すべて閾値以内 | `scratch/turn-00{3,4,5,6,7,8,9}-check*.log` |

## 未確認行の処分表

<!-- T7 (e)。REQ §9 impl 項目 -->

`grep -n '未確認' .gsd-lite/PROGRESS.md` の実行結果は turn 3〜8 の本文に **0 件**
（2 件のヒットは turn 8「次への注意」が T7 (e) の手順を書いた行そのもので、未確認事項ではない）。
そこで同じ趣旨の「このターンでは断定しきれなかった／追わなかった」行を turn 3〜8 の
**想定外・陽性対照・やり直し**から全部拾い、各行を 1 つの処分先に振り分けた。
「誤った値が黙って返る経路」「状態機械が壊れる経路」を述べる行は ★ を付けた。

| # | turn | 拾った行（要旨） | 処分 | 根拠 / 行き先 |
|---|---|---|---|---|
| 1 | 3 (c) | `_after_send` の `PQflush == -1` 分岐は同一スレッドでは到達不能（★ 状態機械: ここで `IDLE` のままだと次の `send` が libpq の文言で落ちる） | **契約外と明記** | テストを書けないのでコードレビューで担保。TRACE「`_after_send` -1 のコードレビュー」節（libpq 根拠 3 行 + `probe-closefd.log` B）。`BUSY` を置く 1 行は `check` のコンパイルで存在を担保 |
| 2 | 3 (4) | `test_notify` 実行中に stderr に `NOTICE: database "pq_test_ascii" does not exist, skipping` が 1 行出る | **契約外と明記** | 2 件目の ASCII テストの先頭 `DROP IF EXISTS` が出す NOTICE で、1 件目の末尾 DROP が効いている証拠。`check` 6/6 段のパターン（`warning:|WARNING:|implicit ROLLBACK failed`）には当たらない（RESEARCH P7）。T7 (a) の `check` で 0 件を再確認 |
| 3 | 4 (3) | `src_TYPE_MISMATCH` が目安 105 ではなく 106（`decode_binary.mojo:46` に両方の語が残る） | **PLAN 訂正済み** | 期待値 ≤ 106 の範囲内。チェックリスト `src_TYPE_MISMATCH` で毎ターン監視（T7 (f) で再確認） |
| 4 | 4 (2) | `test_errors` / `test_notify` は `discover_tests[__functions_in_module()]` 方式で `main()` への登録が不要だった | **契約外と明記** | 依頼文の前提が古かっただけで実装は正しい。テスト件数（`test_errors_tests` = 9 / `test_notify_tests` = 24）がチェックリストで担保 |
| 5 | 5 (陽性対照) | PLAN T3 (c)⑧ は restore 7 行なしでも PASS = `out` 保全を判別しない（★ 誤った値: 保全が壊れると集めた通知が黙って消える） | **テスト追加** | ⑨ `test_wait_notifications_keeps_collected_ones_across_two_round_trips` を追加（restore なしで FAIL を確認。`turn-005-notify-norestore2.log`）。PLAN 訂正（turn 5）に記載 |
| 6 | 5 (1) | `async_reject_lost_calls` の T3 期待値 ≥ 4 → 3（不変） | **PLAN 訂正済み** | `_collect_notifications` に 1 箇所集約した結果。PLAN 表と TRACE「PLAN 訂正（turn 5）」 |
| 7 | 6 (d) | Windows `else` 分岐は複製ビルドで型検査・リンクが通るところまで。**Windows 実機での動作は未検証**（★ 状態機械: `_is_usage_error` の分類違いは Windows でだけ出る） | **verify 申し送り**（スコープ外） | REQ §3「Windows での実行・コンパイルは対象外」。TRACE「Windows 照合表」+ `README.md` §8「未検証」の明記 + `loader.mojo` docstring の `unverified` で開示。照合表 12 行は verify が URL と突き合わせる |
| 8 | 6 (1)(2) | `loader_libpq_dll` 1 → ≥ 2、`loader_platform_map` が最初 1 だった | **PLAN 訂正済み / 実装修正済み** | 前者は PLAN 訂正（turn 6）、後者は docstring の言い換えで 0 に戻した（識別子を使わずに理由を残す形） |
| 9 | 6 (3), 8 (3) | `check` の所要が 215 s / 187 s と揺れる（同時実行のノイズ） | **契約外と明記** | 閾値 247 s（決めた事項 20）以内なので追わない。T7 (a) の実測を基線として PROGRESS に記録 |
| 10 | 7 (1) | bench の堅牢性は「`failed: OperationalError` の 1 行」ではなく物理 2 行（libpq のヒント行） | **PLAN 訂正済み** | 判定を「`^failed: OperationalError` が 1 行 + `Traceback` 0 行 + exit 1」に訂正（PLAN T5 (c)）。T7 (b) の格子でも同じ判定 |
| 11 | 7 (2) | bench 環境の初回作成が 3 s（見込み 1 分前後） | **契約外と明記** | 遅いほうに外れていないので追わない。README の再現手順は「初回は bench 環境の作成が入る」と書き、秒数を約束していない |
| 12 | 8 (1) | `head -3 LICENSE` が 1 行ずれていた（公式ファイルは先頭が空行） | **PLAN 訂正済み** | `head -4` に訂正。全文同一の裏は行数 202 / 11,358 bytes が公式値と一致していることで取っている |
| 13 | 8 (やり直し 1 回) | README のコード片が最初 `examples/` と逐語一致していなかった | **テスト追加（機械確認）** | `scratch/turn-008-readme-excerpts.py` で 6 ブロックを行単位に照合（`blocks=6 missing_total=0`）。verify も同スクリプトで再現できる |
