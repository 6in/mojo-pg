# TRACE — phase6-packaging-ci

PROGRESS.md は 1 ターン 40 行までなので、生の値（チェックリストの出力・所要・ログ名）はこのファイルに置く。
節立ては PLAN.md「決めた事項 12」。

## PLAN 訂正（turn 3）

- T1 (a) の引数名: `def _restore_collected(mut self, out: List[Notification])` → **`collected: List[Notification]`**
  （根拠: `out` は Mojo 1.1.0 の引数規約キーワードで、`src/pq/async_conn.mojo:1582:41: error: expected argument name` でパースできない。
  要件・決定は引数名に触れていない。チェックリストの key は `def _restore_collected` / `_restore_collected(` の 2 つで、どちらも影響なし）

## チェックリスト（turn 3）

`bash .gsd-lite/logs/phase6-packaging-ci/scratch/turn-002-checklist.sh` の出力（全文は
`scratch/turn-003-checklist.log`）。T1 の行と、不変であるべき行を転記する。T2〜T5 の key はすべて
`0` / `absent(...)`（未着手。基線 `turn-002-checklist.log` と同じ）。

```
## T1 持ち越し 2 件（E1 README / E2 _restore_collected）+ db-up 上限 + TRACE
async_restore_collected_def=1            # 期待 1
async_restore_collected_sites=3          # 期待 3（def + 2 呼び出し。P20）
async_wait_readable_timeout_return=3     # 期待 3（不変）
test_notify_tests=25                     # 期待 ≥ 25（24 → 25）
test_notify_restore_collected=2          # 期待 ≥ 1（ヘルパ直叩き 2 箇所: 3 件と空リスト）
readme_sigpipe=2                         # 期待 ≥ 1
readme_rc_141=1                          # 期待 ≥ 1
pixi_db_up_wait_timeout=1                # 期待 1
trace_exists=exists                      # 期待 exists（このファイル）
trace_checklist_section=1                # 期待 ≥ 1
## 全体（不変）
src_def_ref_return=0
test_file_count=24
examples_mojo_count=7
final_check_examples=5
tests_sh_bash4_only=0
pixi_lock_changed_vs_main=0
pixi_version_literal=1
readme_dash_I_src=1
readme_six_stages=1
readme_compose_three=2
readme_unverified_windows=3
readme_h2=10                             # T5 で 11 になる
```

（`trace_exists` / `trace_checklist_section` はこのファイルを書いた後の値。`turn-003-checklist.log` は
このファイルより前に走らせたので `absent` と出ている）

## `check` の所要

| turn | タスク | コマンド | 開始 → 終了（`date -Iseconds`） | 所要 | 判定 |
|---|---|---|---|---|---|
| 3 | T1 | `pixi run check` | 2026-10-18T10:37:38+09:00 → 2026-10-18T10:40:47+09:00 | **189 s** | PASS 6/6（閾値 247 s / 見積もり 170〜220 s の内側） |

基線（Phase 5 末の実測）: 165〜215 s。T1 で足したテストは 1 件（`test_restore_collected_puts_them_back_in_front` =
11.2 ms）で、所要への影響は測定誤差の範囲。

単体の実測（turn 3）:

- `pixi run mojo run -I src tests/test_notify.mojo` → 25 tests / 25 passed / 0 failed / 0 skipped（3396 ms）
- `pixi run mojo run -I src tests/test_async.mojo` → 31 tests / 31 passed / 0 failed / 0 skipped（3566 ms）
- `pixi run test` → 54317 / 54314 の両サーバーで全ファイル PASS（54314 は `skipped 1` = PG14 で持たない 1 件、従来どおり）
- `pixi run package` → 出力なし（警告ゼロ）
- `pixi run db-reset` → rc 0（`--wait-timeout 180` 付きの `db-up` で 3 コンテナ Healthy）

## 利用側 smoke 2 経路

T2 で記入（git 経路 / ダウンロード経路）。

## blackhole / retry のローカル陽性対照

T3 で記入。

## 受け入れ基準対応表

T6 で記入（REQ §4 の A1〜F2）。

## verify への申し送り

T6 で記入。
