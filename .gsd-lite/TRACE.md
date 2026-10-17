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

## Windows 照合表

<!-- T4 (e) -->

## examples 堅牢性の格子

<!-- T7 (b) -->

## 受け入れ基準対応表

<!-- T7 (d) -->

## 未確認行の処分表

<!-- T7 (e) -->
