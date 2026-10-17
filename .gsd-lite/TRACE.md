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

<!-- T7 (b) -->

## 受け入れ基準対応表

<!-- T7 (d) -->

## 未確認行の処分表

<!-- T7 (e) -->
