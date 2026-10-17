# TRACE — phase4-async-cancel-notify

- 作成: 2026-10-17 / gsd-lite-impl T8（turn 10）
- 目的: PROGRESS を 40 行に収めるため、30 行超の表をここに置く（REQ §9）。
  §1 は追従先チェックリストの最終実行、§2 は受け入れ基準の対応表、§3 は「未確認」行の処分。

## 1. 追従先チェックリストの最終実行

スクリプト `.gsd-lite/logs/phase4-async-cancel-notify/scratch/turn-002-checklist.sh` を **F1（turn 12）で再実行**した生の出力
（生ログ: `scratch/turn-012-checklist.log`）。期待値は PLAN.md「追従先チェックリスト」の表。`absent` は 1 つも残っていない。
T8（turn 10）の実行からの差は F1 が足した 5 行だけ: `init_TIMEOUT` 3 → 7、`test_poll_tests` 9 → 11、
`test_async_tests` 29 → 30、`test_notify_tests` 9 → 11、`datetime_asia_tokyo` 2 → 3（F1 (c)⑤ の SKIP 文言に添えたコメントが当たる）。

```
## T1 持ち越し整理 / blackhole / SKIP / §4.9
params_libpq_takes_at_most=0          # 期待 0
params_MaxAllocSize=3                 # 期待 ≥ 2
testconn_from_the_environment=0       # 期待 0
testconn_PGCLIENTENCODING=1           # 期待 1
timetz_time_of_day_is_not=0           # 期待 0
timetz_out_of_range_sites=1           # 期待 1
datetime_is_utc_calls=2               # 期待 2
datetime_asia_tokyo=3                 # 期待 ≥ 1
compose_blackhole=1                   # 期待 1
compose_54399=1                       # 期待 1
run_tests_SKIP=2                      # 期待 ≥ 2
run_tests_pipefail=2                  # 期待 ≥ 1
tests_print_SKIP=5                    # 期待 ≥ 5
leak_old_SKIP_colon=0                 # 期待 0
string_payload_def=1                  # 期待 1
string_payload_calls=2                # 期待 2
jsonb_version_checks=2                # 期待 ≤ 2
oid_varchar_checks=1                  # 期待 1
test_decode_binary_tests=88           # 期待 ≥ 85
test_extended_datetime_tests=19       # 期待 19
## T2 土台: adopt_result / TIMEOUT / _ffi / _platform/poll
conn_def_take_result=1                # 期待 1
conn_def_error_field=0                # 期待 0
result_def_adopt_result=1             # 期待 1
result_def_error_field=1              # 期待 1
result_SINGLE_TUPLE=3                 # 期待 ≥ 1
conn_adopt_result_calls=1             # 期待 1
errors_TIMEOUT=3                      # 期待 ≥ 2
errors_six=0                          # 期待 0
init_exactly_six=0                    # 期待 0
init_TIMEOUT=7                        # 期待 ≥ 1
ffi_PQsetSingleRowMode=3              # 期待 3（T2 で 2 → 3 に訂正済み）
ffi_PQconnectStart_plain=1            # 期待 1
testffi_PQsetSingleRowMode=1          # 期待 1
testffi_PQconnectStart_plain=1        # 期待 1
testffi_symbol_count_53=0             # 期待 0
testffi_symbol_count_55=1             # 期待 1
platform_init=exists                  # 期待 exists
platform_poll=exists                  # 期待 exists
poll_def_poll_socket=1                # 期待 1
poll_comptime_if=1                    # 期待 ≥ 1
poll_WSAPoll=10                       # 期待 ≥ 1
poll_EINTR=3                          # 期待 ≥ 1
poll_monotonic=4                      # 期待 ≥ 1
poll_external_call_symbols=2          # 期待 ≤ 3
test_poll=exists                      # 期待 exists
test_poll_tests=11                    # 期待 ≥ 7（F1 で +2）
## T3 / T4 AsyncConnection
async_conn=exists                     # 期待 exists
async_struct=1                        # 期待 1
async_state_struct=1                  # 期待 1
pollstate_struct=1                    # 期待 1
notification_struct=1                 # 期待 1
async_public_defs=27                  # 期待 ≥ 20
async_called_while=7                  # 期待 ≥ 6
async_cancel_insecure=2               # 期待 ≥ 1
init_async_import=1                   # 期待 1
conn_phase4_future=0                  # 期待 0
init_phase4=1                         # 期待 1
src_PQfinish_calls=5                  # 期待 ≥ 3
src_PQfreemem_calls=3                 # 期待 3
src_PQfreeCancel_calls=1              # 期待 1
src_PQexec_calls=4                    # 期待 4
test_async=exists                     # 期待 exists
test_async_tests=30                   # 期待 ≥ 20（F1 で +1）
test_notify=exists                    # 期待 exists
test_notify_tests=11                  # 期待 ≥ 8（F1 で +2）
example_async=exists                  # 期待 exists
example_notify=exists                 # 期待 exists
pixi_example_tasks=2                  # 期待 2
final_check_examples=2                # 期待 2
final_check_run_logged_examples=5     # 期待 5
## T6 leak
leak_tests=18                         # 期待 18
leak_Fourteen=0                       # 期待 0
leak_async_import=13                  # 期待 ≥ 1
## T7 UTF-8
utf8_unsafe_span=0                    # 期待 0
result_unsafe_ptr=6                   # 期待 6
utf8_from_utf8=2                      # 期待 ≥ 2
utf8_scanner_def=1                    # 期待 1
utf8_invalid_message=3                # 期待 ≥ 1
docs_not_validated=0                  # 期待 0
test_decode_binary_utf8_tests=8       # 期待 ≥ 5
## 全体
src_def_ref_return=0                  # 期待 0
tests_files_count=24                  # 期待 24
test_file_count=24                    # 期待 24
```

**全 85 行が期待値に到達**（`absent` 0 件、下回る行 0 件）。

## 2. 受け入れ基準の対応表（REQ §5）

### 2.1 §5.1 — HANDOFF §10 Phase 4 の 4 件

| REQ §5.1 | 担うテスト関数 / コマンド | PASS |
|---|---|---|
| `pg_sleep(2)` 送信中に他の処理（カウンタ）が進む | `test_poll_result_counts_while_sleeping`（`tests/test_async.mojo:1071`）。判定は「カウンタ ≥ 1 **かつ** 経過 ≥ 2,000 ms」 | turn 5（T3 ④） |
| `cancel()` で `pg_sleep(10)` が 1 秒以内に中断、SQLSTATE `57014` | `test_cancel_stops_a_running_statement`（`tests/test_async.mojo:1199`）。cancel 発行から raise まで < 1,000 ms を断定 | turn 6（T4 (b) ①） |
| 別接続からの `NOTIFY ch, 'payload'` を受け取れる | `test_wait_notification_receives_both_payloads`（`tests/test_notify.mojo:373`）。2 件の payload と `backend_pid` 一致 | turn 6（T4 (c) ①） |
| 応答しない接続先でタイムアウト付きの待ちが規定時間で戻る | `test_connect_blocking_times_out`（`tests/test_async.mojo:1131`、blackhole 54399）+ `wait_readable(50)` の `TIMEOUT` | turn 5（T3 ⑦） |

### 2.2 §5.2 — 堅牢性の 4 項目

| REQ §5.2 | 担うテスト関数 / コマンド | PASS |
|---|---|---|
| 状態 9 種 × 入力でクラッシュせず `PgError` | 未接続: `test_send_while_connecting_is_usage`（`send`）/ `test_every_call_while_connecting_is_usage`（`cancel` / `consume_input` / `poll_result` / `notifications` / `fetch_all` の 5 本、いずれも握手は壊れない）。接続ポーリング中: `test_manual_connect_polling` / `test_connect_failures_name_their_cause`（3 種）。送信中・結果待ち: `test_send_while_a_command_is_in_flight_is_usage` / `test_a_large_statement_is_written_in_instalments`。結果取得後: `test_send_between_two_results_is_usage` / `test_single_row_mode_outside_its_window_is_usage`。切断: `test_a_terminated_backend_ends_the_command` / `test_cancel_after_the_backend_is_gone_is_connection` / `test_notifications_reports_a_lost_connection`。cancel 後: `test_cancel_inside_a_transaction_still_owes_a_rollback` / `test_cancel_while_idle_is_a_no_op`。タイムアウト後: `test_connect_blocking_times_out` / `test_a_budget_below_minus_one_is_usage` / `test_an_idle_connection_has_nothing_to_collect`。未読結果ありの drop: `test_dropping_a_connection_with_unread_results_is_safe` | turn 5〜7（T3 ⑨ / T4 / T5） |
| `PQfinish` / `PQclear` / `PQfreeCancel` / `PQfreemem` が正常系・異常系で呼ばれ二重解放しない | `test_async_execute_does_not_leak`（10,000 回）/ `test_async_cancel_does_not_leak`（1,000 回）/ `test_notify_receive_does_not_leak`（1,000 回）/ `test_async_drop_with_pending_results_does_not_leak`（1,000 回）。呼び出し本数はチェックリスト `src_PQfinish_calls=5` / `src_PQfreemem_calls=3` / `src_PQfreeCancel_calls=1` | turn 8（T6） |
| `AsyncConnection` は `Movable` のみ | `grep -c 'Copyable' src/pq/async_conn.mojo` = **2**: `struct Notification(Copyable, ...)`（`:196`）と、`AsyncConnection` の docstring が「`Movable` and not `Copyable`」と述べる 1 行（`:43`）。`struct AsyncConnection(Movable)`（`:277`）に `Copyable` は無い。**PLAN 訂正**: 表の「`Notification` の 1 行だけ」は docstring の 1 行を数え落としたもの | turn 5（T3 (a)） |
| 10,000 回の非同期 execute と 1,000 回の NOTIFY 受信で RSS が単調増加しない | 上の 4 ループ（`MAIN_ITERATIONS = 10000` / `ERROR_ITERATIONS = 1000`、`TOLERANCE_PAGES = 256`） | turn 8（T6） |

### 2.3 §5.3 — リーク測定方式

| REQ §5.3 | 担うテスト関数 / コマンド | PASS |
|---|---|---|
| `mojo build` したバイナリで実行、`check` は 1 サーバー | `tests/run_tests.sh:90`（`build/test_leak`）、`tests/final_check.sh:133`（`PQ_TEST_LEAK_SERVERS=1`） | turn 3 以降 毎ターン |
| `TOLERANCE_PAGES = 256` は恒久仕様 | `tests/test_leak.mojo`（変更なし） | — |
| 新しい解放経路の陽性対照を同ターンで実測 | `PQfreemem`（`PGnotify`）除去 → `test_notify_receive_does_not_leak` が FAIL（turn 8 PROGRESS にサンプル列）。`PQfreeCancel` 除去は**フラットのまま = 陽性対照にならない**（`PGcancel` は数百 byte で RSS に出ない）。§3 の ④ として「契約外」に分類し、コードレビューで担保 | turn 8（T6 (b)） |

### 2.4 §5.4 — 品質基準の 5 項目

| REQ §5.4 | コマンド / 確認 | PASS |
|---|---|---|
| `pq` 直下の公開 struct / メソッドに docstring | `pixi run check` 3/6 段（`--diagnose-missing-doc-strings`、`_ffi` 除外）が **0** | turn 10（T8） |
| `pixi run fmt` で差分なし | `52 files left unchanged` | turn 10（T8） |
| `examples/async_query.mojo` / `listen_notify.mojo` が単体で実行できる | `pixi run example-async` / `pixi run example-notify`（`pixi.toml`）、`check` 4/6 段にも 2 行 | turn 10（T8）/ turn 6（T4 (d)） |
| `pixi run package` が通る | 警告ゼロ | turn 10（T8） |
| `pixi run check` が全段 PASS | 6/6（`final_check: PASS`、18:31:40 → 18:34:40 = **180 s**。6/6 段の `matched lines ... : 0`） | turn 10（T8） |

`pixi run test`（両サーバー、T8 で再実行）: 18:26:15 → 18:31:29 = **314 s**、exit 0、
**48 サマリすべて `0 failed`**（`grep 'tests run' | grep -vc ' 0 failed'` = 0）、
SKIP 集計行は `-- 127.0.0.1:54317 skipped 1` と `-- 127.0.0.1:54314 skipped 1` の 2 本。
examples の単体実行: `pixi run example-async` → `n = 1` / `empty polls while waiting = 19`、
`pixi run example-notify` → `channel = pq_example` / `payload = hello from pq` / `backend_pid = 1541121`。

### 2.5 §4.8 / §4.9 / §4.10 の担当タスク

| REQ | 担うもの | PASS |
|---|---|---|
| §4.8 SKIP 集計 | `tests/run_tests.sh` の `tee` + `${PIPESTATUS[0]}` + `-- <label> skipped N`。陽性対照は port=1 での exit code ≠ 0 | turn 3（T1 (f)(g)） |
| §4.9 文字列系 OID 判定の一元化 | `decode_binary._string_payload`（`decode_binary[String]` と `Row.get_text` の 2 呼び出し）+ 単体 1 件 | turn 3（T1 (h)） |
| §4.10 UTF-8 検証 | `_utf8_first_invalid` / `_validated_utf8`、`String` になる 3 経路、`test_decode_binary.mojo` の 8 件 | turn 9（T7） |

## 3. PROGRESS の「未確認」行の処分（REQ §9 impl 項目）

PROGRESS 全 9 ターンの「未確認」行を列挙し、各行を **テスト追加 / 契約外 / verify 申し送り** のいずれか 1 つに振り分けた。
「誤った値が黙って返る経路」「状態機械が壊れる経路」を述べた行は**残っていない**（下表の「性質」列）。

| # | 未確認の内容（初出） | 性質 | 処分 | 根拠 |
|---|---|---|---|---|
| 1 | `"x" * 16000000` の形の文字列反復が Mojo 1.1.0 にあるか（turn 2） | 実装手段の選択 | **テスト追加（済）** | `test_a_large_statement_is_written_in_instalments`（`test_async.mojo:1441`）が 16 MB 文を送る。turn 7 で実装手段ごと決着 |
| 2 | `PGcancel` の確保サイズが leak の陽性対照に出るか（turn 2） | 測定の検出力 | **契約外** | turn 8 実測: `PQfreeCancel` を消してもフラット（数百 byte は RSS に出ない）。§2.3 に記載 |
| 3 | `poll.mojo` の Windows 分岐（`WSAPoll` / 16 byte / 別定数）がコンパイルされていない（turn 4） | 他 OS での可動性 | **verify 申し送り** | `comptime if` の非選択側。モジュール docstring に **unverified** と明記済み（`_platform/poll.mojo:17-23`、P8）。Phase 5「Windows 用コードパスのレビュー」が引き取る |
| 4 | `EINTR` の実挙動（シグナル下での再試行）（turn 4） | 到達困難な分岐 | **契約外** | RESEARCH §2.3 の方針どおりテストしない。コードレビューで担保: `_platform/poll.mojo:236`（`err == ErrNo.EINTR`）と `:228,238`（`monotonic()` の締め切りからの残り ms 再計算） |
| 5 | `_after_send` で `PQflush` が -1 を返したときに状態を `IDLE` のままにしている（turn 6） | 到達困難な分岐 | **契約外** | turn 7 の T5 ④（切断テスト）でも再現せず。libpq に -1 を返させる条件（送信途中の切断）を同一スレッドから作れない。状態機械は壊れない（結果が無いので drain 不要） |
| 6 | `PQcancel` が 0 を返す経路（errbuf の文言を message にする分岐）（turn 6） | 到達困難な分岐 | **契約外** | turn 7 の T5 ②（切断後 cancel）は `PQgetCancel` が NULL を返す側に当たった。どちらに転んでも `CONNECTION` なので誤値は返らない |
| 7 | `PQsetSingleRowMode` が 0 を返す経路（turn 6） | 到達困難な分岐 | **契約外** | クライアント側ガード（`_single_row_allowed`）を通った後は libpq が 0 を返さない（決めた事項 12）。返っても `USAGE` 同文 |
| 8 | `PQfreeCancel` 欠落の陽性対照が見えない（turn 8） | 測定の検出力 | **契約外** | #2 と同一事象。コードレビュー担保（`src_PQfreeCancel_calls=1`） |
| 9 | `_validated_utf8` の「スキャナが -1 を返した（stdlib と食い違った）」分岐（turn 9） | 到達不能な分岐 | **契約外** | `decode_binary.mojo:339-345`（`if offset < 0:` の分岐）。どちらに転んでも `TYPE_MISMATCH` を投げる（位置が出ないだけ）ので誤値は返らない |
| 10 | `test_zero_copy` が 1 テスト 3.4〜3.9 s かかる原因（turn 9） | 性能の未調査 | **verify 申し送り** | turn 9 に A/B 済み（Phase 4 以前からの既存の性質。接続あたりの固定費）。正しさには影響しない。Phase 5 の「ベンチマーク」が引き取る |

## 4. F1（verify round 1 の差し戻し）の期待結果 7 件（turn 12）

PLAN F1「期待結果」の表の各行と、それを担うテスト。

| # | 担うテスト関数 / 実測 | PASS |
|---|---|---|
| 1 | `test_timeout_above_c_int_max_is_rejected`（`test_poll.mojo`、経過 < 100 ms）/ `test_a_budget_above_c_int_max_is_usage_at_every_entry`（`test_async.mojo`、`wait_readable` / `fetch_all` / `wait_notification` / `connect_blocking` の 4 入口） | turn 12 |
| 2 | `test_timeout_at_c_int_max_is_accepted`（1 byte 書いた pipe、`readable=True`・経過 < 100 ms） | turn 12 |
| 3 | 既存の `test_timeout_below_minus_one_is_rejected` / `test_a_budget_below_minus_one_is_usage`（部分文字列 `"timeout_ms must be"` のまま無変更） | turn 12 |
| 4 | `test_a_payload_that_is_not_utf8_is_rejected_and_dropped`（`TYPE_MISMATCH` / `invalid UTF-8 at byte 2` + `notification payload` / `"ab"` を含まない / `state()` = Idle） | turn 12 |
| 5 | 同テスト後半（`NOTIFY pq_f1, 'ok'` が届く） | turn 12 |
| 6 | 既存の `test_payload_survives_the_byte_limit_and_utf8`（`héllo`、期待値変更ゼロ） | turn 12 |
| 7 | 4・5 とも `wait_notification` 経由（`None` に写らず `TYPE_MISMATCH` が伝播） | turn 12 |

陽性対照（`_reject_bad_notification_text` の先頭に `if True: return` を入れたコピーで 1 回実測し、すぐ戻した）:
`scratch/turn-012-ascii-notify.mojo` が `notification payload bytes: 0x61 0x62 0xc3 0x28  byte_length 4` を印字。
検査を戻すと同じプローブが `PgError(kind=TypeMismatch, message=invalid UTF-8 at byte 2 of notification payload)`。

契約外の提案（サブエージェントが挙げ、実装しなかったもの。Phase 5 以降の判断）:
`AsyncConnection.wait_notifications(n, timeout_ms)` / `notifications()` 側での `PQstatus == CONNECTION_BAD` 先行チェック /
`UNLISTEN` 後に来ないことのテスト / LISTEN していないチャンネルの無視 / `LISTEN "Mixed Case"` /
`f4 90 80 80` と `f5 80 80 80` の 4 バイト境界をスキャナの単体に足す案 / 検証失敗に専用の `PgErrorKind.ENCODING` を作る案。
