# TRACE — phase6-packaging-ci

PROGRESS.md は 1 ターン 40 行までなので、生の値（チェックリストの出力・所要・ログ名）はこのファイルに置く。
節立ては PLAN.md「決めた事項 12」。

## PLAN 訂正（turn 3）

- T1 (a) の引数名: `def _restore_collected(mut self, out: List[Notification])` → **`collected: List[Notification]`**
  （根拠: `out` は Mojo 1.1.0 の引数規約キーワードで、`src/pq/async_conn.mojo:1582:41: error: expected argument name` でパースできない。
  要件・決定は引数名に触れていない。チェックリストの key は `def _restore_collected` / `_restore_collected(` の 2 つで、どちらも影響なし）

## PLAN 訂正（turn 4）

- チェックリスト T2 行の `pixi_pkg_name_pq` の期待値: **1 → 2**
  （根拠: key の実体は `grep -c '^name = "pq"' pixi.toml` で、RESEARCH §2.1 の差分には `[package]` と
  `[package.build.config.pkg]` の両方に `name = "pq"` がある。実測 2。要件・決定に触れない数え方の誤り）

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

## チェックリスト（turn 4）

全文は `scratch/turn-004-checklist.log`。T2 の行と、不変であるべき行を転記する。T3〜T5 の key は
すべて `0` / `absent(...)`（未着手。turn 3 と同じ）。

```
## T2 pixi.toml [package] / pixi build / 利用側 smoke
pixi_preview=1                 # 期待 1
pixi_package_section=1         # 期待 1
pixi_version_literal=1         # 期待 1（P4。`[package]` 側は { workspace = true } なので増えない）
pixi_version_workspace=1       # 期待 1
pixi_pkg_name_pq=2             # 期待 2（上の PLAN 訂正（turn 4））
pixi_pkg_path=1                # 期待 1
pixi_backend_mojo=1            # 期待 1
pixi_mojo_compiler=3           # 期待 3（host / build / run）
pixi_run_dep_libpq=2           # 期待 2（[dependencies] と [package.run-dependencies]）
gitignore_dist=1               # 期待 1
pixi_lock_changed_vs_main=0    # 期待 0（P3）
## T1（不変）
async_restore_collected_def=1 / _sites=3 / async_wait_readable_timeout_return=3 /
test_notify_tests=25 / test_notify_restore_collected=2 / readme_sigpipe=2 / readme_rc_141=1 /
pixi_db_up_wait_timeout=1 / trace_exists=exists / trace_checklist_section=1
## 全体（不変）
src_def_ref_return=0 / test_file_count=24 / examples_mojo_count=7 / final_check_examples=5 /
tests_sh_bash4_only=0 / readme_dash_I_src=1 / readme_six_stages=1 / readme_compose_three=2 /
readme_unverified_windows=3 / readme_h2=10
```

## `pixi build` の所要と生成物（turn 4）

| 回 | コマンド | 開始 → 終了 | 所要 | 結果 |
|---|---|---|---|---|
| 1 | `pixi build -o dist` | 2026-10-18T10:44:02+09:00 → 2026-10-18T10:44:19+09:00 | **17 s** | `dist/pq-0.1.0-he8cfe8b_0.conda` 1 個（recipe 本体は `took 2 seconds`。backend は turn 1 のプローブで取得済みのため初回 60 s 級にはならず） |

- `pixi run check`: 2026-10-18T10:45:03+09:00 → 2026-10-18T10:48:06+09:00 = **183 s**、PASS 6/6（閾値 247 s）
- `pixi run package` → 出力なし（警告ゼロ）、`pixi install --locked` → rc 0、`git diff --quiet main -- pixi.lock` → rc 0
- `pixi workspace version get` = `0.1.0`
- `.conda` の zip エントリ 3 個: `metadata.json` / `pkg-pq-0.1.0-he8cfe8b_0.tar.zst` / `info-pq-0.1.0-he8cfe8b_0.tar.zst`
- `pkg-*.tar.zst` の中身（A3 / P2）: **`lib/mojo/pq.mojoc`（449.8 KiB）と `share/max/firstActivation` の 2 つだけ**。
  `examples/` / `tests/` / `hello.mojo` は**無い**
- `info/index.json` の `depends` = `["mojo-compiler >=1.1.0,<1.2", "libpq >=14"]`、`subdir` = `linux-aarch64`
- `info/about.json` = `{"description": "mojo-libpq: PostgreSQL client for Mojo via libpq C FFI", "license": "Apache-2.0"}`
  → `description` / `license` の `{ workspace = true }` 継承は**通ったので残した**（PLAN T2 (a) の「任意」部分）
- 観測した警告: `pixi build` は「deprecated、`pixi publish --path . --target-dir dist` を使え」と出す（rc 0。
  RESEARCH §2.1 で両者が同じ結果になることは確認済み。T3 / T4 のワークフローでどちらを書くかは次ターンの判断）

## 利用側 smoke 2 経路（turn 4。REQ A2）

どちらも同じ `main.mojo`（`from pq import Connection, PgError` → 閉じたポートへ接続）。
ログは `scratch/turn-004-consumer-git.log` / `scratch/turn-004-consumer-dl.log`。

| 経路 | 依存の書き方 | 出力 | 判定 |
|---|---|---|---|
| git | `pq = { git = "file:///home/parallels/workspaces/mojo-apps/pgcon", branch = "gsd-lite/phase6-packaging-ci" }` + `preview = ["pixi-build"]` | `pq import OK` / `expected failure: PgError(kind=Connection, message=connection to server at "127.0.0.1", port 1 failed: Connection refused` | PASS（`LibpqLoad` 無し。チェックアウト `…/git-v0/checkouts/cfb6b27deff335b2/3dfed07` = このブランチのコミット `3dfed07` を precompile） |
| ダウンロード | `file://…/turn-004-dl-channel`（`rattler-index fs` 済み）を channels 先頭に + `pq = "==0.1.0"`（`preview` 不要） | 同上 | PASS（`pixi list` に `pq 0.1.0 he8cfe8b_0`（file チャンネル）と `libpq 18.6`（conda-forge）） |

verify は PR 後に GitHub の URL（`https://github.com/6in/mojo-pg.git`）で git 経路を再実測する（RESEARCH §6）。

## blackhole / retry のローカル陽性対照

T3 で記入。

## 受け入れ基準対応表

T6 で記入（REQ §4 の A1〜F2）。

## verify への申し送り

T6 で記入。
