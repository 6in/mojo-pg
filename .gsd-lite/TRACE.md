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

## チェックリスト（turn 5）

全文は `scratch/turn-005-checklist.log`。T3 の行と、不変であるべき行を転記する。T4 / T5 の key は
すべて `0` / `absent(...)`（未着手。turn 4 と同じ）。

```
## T3 ci.yml + .github/scripts
wf_ci_exists=exists            # 期待 exists
ci_os_ubuntu_latest=1          # 期待 ≥ 1
ci_os_ubuntu_arm=1             # 期待 ≥ 1
ci_os_macos_latest=1           # 期待 ≥ 1
ci_fail_fast_false=1           # 期待 1
ci_timeout_minutes=1           # 期待 ≥ 1（ジョブ 1 つなので 1）
ci_permissions=1               # 期待 ≥ 1（先頭 contents: read）
ci_secrets_refs=0              # 期待 0（P14）
ci_branches_main=2             # 期待 2（pull_request / push。P15）
ci_pull_request=1              # 期待 1
ci_setup_pixi_pinned=1         # 期待 1
ci_pixi_version=1              # 期待 1
ci_run_install_false=1         # 期待 1
ci_locked_true=1               # 期待 1
ci_pixi_run_check=3            # 期待 ≥ 1（step 名 / env コメント / run の 3 行）
ci_pixi_build=1                # 期待 ≥ 1（`pixi build -o dist` を維持。下の「`pixi build` の deprecated」参照）
ci_upload_artifact=2           # 期待 ≥ 2（.conda と final_check.log）
ci_artifact_pq_conda=1         # 期待 ≥ 1
ci_windows_reason=1            # 期待 ≥ 1（先頭コメント。B7）
ci_conninfo_5432=1             # 期待 ≥ 1
ci_retry_sh=4                  # 期待 ≥ 3（install / compose pull / build の 3 呼び出し + コメント 1）
scripts_retry=exists / scripts_macos_pg=exists / scripts_blackhole=exists   # 期待 exists ×3
macos_pg_scram=4               # 期待 ≥ 1
macos_pg_ctl_wait=1            # 期待 ≥ 1（`-w -t 60`）
macos_pg_wrong_password=3      # 期待 ≥ 1
macos_pg_schema_sql=2          # 期待 ≥ 1
macos_pg_reload=3              # 期待 ≥ 1
blackhole_held=5               # 期待 ≥ 1（P8）
tests_sh_bash4_only=0          # 期待 0（不変。final_check.sh / run_tests.sh は未変更）
## T1 / T2（不変）
async_restore_collected_def=1 / _sites=3 / async_wait_readable_timeout_return=3 /
test_notify_tests=25 / test_notify_restore_collected=2 / readme_sigpipe=2 / readme_rc_141=1 /
pixi_db_up_wait_timeout=1 / trace_exists=exists / trace_checklist_section=2（turn 3 / 4 の節で 2。T1 の期待は ≥ 1）/
pixi_preview=1 / pixi_package_section=1 / pixi_version_literal=1 / pixi_version_workspace=1 /
pixi_pkg_name_pq=2 / pixi_pkg_path=1 / pixi_backend_mojo=1 / pixi_mojo_compiler=3 /
pixi_run_dep_libpq=2 / gitignore_dist=1 / pixi_lock_changed_vs_main=0
## 全体（release.yml 待ち = T4）
workflows_files=1              # 期待 2（T4 で release.yml を足して到達）
all_timeout_minutes / all_permissions / all_secrets_refs / all_contents_write = absent(release.yml)
src_def_ref_return=0 / test_file_count=24 / examples_mojo_count=7 / final_check_examples=5   # 不変
```

## `pixi build` の deprecated をワークフローに書くか（turn 5 の判断）

turn 4 の「想定外 (1)」の宿題。**`pixi build -o dist` のまま書いた**（`pixi publish` に変えない）。根拠:

- 警告は deprecation のみで rc 0、生成物は `pixi publish --path . --target-dir dist` と同じ（RESEARCH §2.1 で確認済み）
- CI の pixi は `pixi-version: v0.82.0` に固定（決めた事項 5）＝ ローカルと同じ版なので、
  ローカルで通った形がそのまま CI で通る。`pixi publish` に変えると「ローカルで検証していない形」を CI に置くことになる
- チェックリストの key `ci_pixi_build` / `release_pixi_build` は `pixi build -o dist` を数えるので、
  **PLAN 訂正は不要**（パターンも期待値も変わらない）
- 警告は `pixi run check` の 6/6 段（`$LOG` の `warning:` 数え上げ）には入らない（`pixi build` は `final_check.sh` の外）

## blackhole / retry のローカル陽性対照

turn 5（T3）。親が自分で再実測した値（サブエージェントの報告とも一致）。ログは
`scratch/turn-005-retry-{false,true}-parent.log` / `turn-005-blackhole-parent.log`。

| 対照 | コマンド | 結果 | 判定 |
|---|---|---|---|
| retry 失敗 | `pixi run bash .github/scripts/retry.sh 2 1 false` | **rc 1**、`retry: attempt` 行 4 本（= 2 試行 × 「開始」「失敗」）、stderr 最終行 `retry: giving up after 2 tries` | PASS |
| retry 成功 | `pixi run bash .github/scripts/retry.sh 2 1 true` | **rc 0**、`attempt` 行 1 本（1 回で即 return） | PASS |
| blackhole 保持 | `python3 .github/scripts/blackhole.py 54398` を起動 → connect → `settimeout(0.5)` → `recv(1)` | **`TimeoutError`（= `socket.timeout`）を送出**。EOF の `b''` ではない = accept したソケットを閉じていない（P8） | PASS |
| 構文 | `pixi run bash -n retry.sh macos-postgres.sh` / `python3 -m py_compile blackhole.py` | いずれも rc 0 | PASS |
| actionlint | `pixi exec --spec actionlint actionlint .github/workflows/ci.yml` | 出力なし（指摘 0） | PASS |

- ポートは **54398**（54399 は docker の `tests-blackhole-1` が使用中。CI の macOS では 54399 を使う:
  `test_async.mojo:66` が 54399 固定で、macOS には compose が無いため衝突しない）
- 後片付け: 起動した `blackhole.py` は停止済み（`pgrep -x python3` で残骸なし）
- `macos-postgres.sh` は **macOS 専用のため実動作は未検証**（Linux 開発機では brew / `pg_ctl` / BSD `sed -i ''` が無い）。
  静的検査は `bash -n` rc 0 + bash 3.2 互換（配列・`mapfile`・`declare -A`・`${x,,}` 不使用）のコードレビューまで。
  実動作の初見は **verify の PR の macOS ジョブ**（陽性対照 2 件がスクリプト内で `exit 1` するので、
  trust のまま通ってしまう事故はジョブの赤で検出できる）

## `check` の所要（turn 5）

| turn | タスク | コマンド | 開始 → 終了 | 所要 | 判定 |
|---|---|---|---|---|---|
| 5 | T3 | `pixi run check` | 2026-10-18T10:54:16+09:00 → 2026-10-18T10:57:09+09:00 | **173 s** | PASS 6/6（rc 0。閾値 247 s / 見積もり 170〜220 s の内側） |

Mojo 側は T3 で未変更なので turn 3（189 s）/ turn 4（183 s）と同じ範囲。`-- 127.0.0.1:54314 skipped 1`
（PG14 側の leak 1 件）は従来どおり。開始時刻は `build/final_check.log` の `=== [1/6 …]`、終了は `=== [6/6 …]` +
summary の 1 s。

## チェックリスト（turn 6）

全文は `scratch/turn-006-checklist.log`。T4 の行と全体行を転記する。T5 の key は
すべて `0`（未着手。`readme_h2=10` / `readme_dash_I_src=1` / `readme_six_stages=1` /
`readme_compose_three=2` / `readme_unverified_windows=3` / `readme_windows_toolchain=1` は turn 5 と同じ）。

```
## T4 release.yml + CHANGELOG + scripts
wf_release_exists=exists       # 期待 exists
release_tags_v=1               # 期待 1（`tags: ["v*"]` の 1 行だけ。下の「コメントが grep に当たる」参照）
release_workflow_dispatch=1    # 期待 1
release_version_check_sh=1     # 期待 ≥ 1
release_notes_py=2             # 期待 ≥ 1（verify-version と release の 2 ジョブで呼ぶ）
release_gh_release_create=1    # 期待 ≥ 1
release_gh_token=1             # 期待 ≥ 1（P16）
release_contents_write=1       # 期待 1（release ジョブのみ。P14）
release_contents_read=1        # 期待 ≥ 1（先頭）
release_timeout_minutes=3      # 期待 ≥ 3（10 / 45 / 15）
release_secrets_refs=0         # 期待 0（P14）
release_git_archive=1          # 期待 ≥ 1
release_ref_type_tag=3         # 期待 ≥ 1（先頭コメント + verify-version のステップ + release ジョブ）
release_pixi_build=1           # 期待 ≥ 1（`pixi build -o dist` = turn 5 の判断どおり）
release_dup_check=1            # 期待 ≥ 1（P5）
scripts_check_tag_version=exists  # 期待 exists
scripts_release_notes=exists      # 期待 exists
check_tag_version_pixi=2          # 期待 ≥ 1（コメント + 実行の 2 行）
changelog_exists=exists        # 期待 exists
changelog_010_heading=1        # 期待 1
changelog_unreleased_heading=1 # 期待 1
changelog_keep_a_changelog=1   # 期待 ≥ 1
changelog_phase_lines=5        # 期待 ≥ 5（Phase 1〜5 各 1 行）
## 全体
workflows_files=2              # 期待 2（ci.yml / release.yml）
all_timeout_minutes=4          # 期待 ≥ 4（ci 1 + release 3）
all_permissions=3              # 期待 ≥ 3（ci 1 + release 2）
all_secrets_refs=0             # 期待 0
all_contents_write=1           # 期待 1
## T1 / T2 / T3（不変）
async_restore_collected_def=1 / _sites=3 / test_notify_tests=25 / readme_sigpipe=2 / pixi_db_up_wait_timeout=1
pixi_preview=1 / pixi_package_section=1 / pixi_pkg_name_pq=2 / pixi_mojo_compiler=3 / pixi_lock_changed_vs_main=0
wf_ci_exists=exists / ci_branches_main=2 / ci_secrets_refs=0 / ci_upload_artifact=2 / tests_sh_bash4_only=0
src_def_ref_return=0 / test_file_count=24 / examples_mojo_count=7 / final_check_examples=5
```

**コメントが grep に当たる（turn 5 と同種の再発）**: `release.yml` の冒頭コメントに
「a `v*` tag push」、`permissions` 上のコメントに「raises this to `contents: write`」と書いたため
`release_tags_v=2` / `release_contents_write=2` / `all_contents_write=2`（期待はいずれも 1）になった。
コメントを言い換えて 1 に戻した（YAML の実体は変えていない）。**PLAN 訂正ではない**（期待値は正しく、
原因は実装側のコメント文言）。残るタスクでも「key のパターンと同じ文字列をコメントに書かない」。

## `check-tag-version.sh` / `release-notes.py` のローカル陽性対照（turn 6）

`check-tag-version.sh`（`scratch/turn-006-check-tag.sh` 経由。下記注記）:

| 引数 | stdout / stderr | rc | 期待 |
|---|---|---|---|
| `v0.1.0` | `tag v0.1.0 matches pixi.toml version 0.1.0` | **0** | 一致で 0（C2） |
| `v0.2.0` | `tag v0.2.0 != pixi.toml version 0.1.0`（stderr） | **1** | 不一致で 1 |
| `0.1.0` | `tag 0.1.0 must start with "v" (expected form: v<version>)`（stderr） | **1** | `v` 無しは不一致扱い（境界値） |

注記: スクリプトは `pixi` を **PATH から引く**（CI は `setup-pixi` が置く）。開発機では
`~/.pixi/bin` が PATH に無く、`pixi run bash <script>` の中でも引けない（rc 127 を 1 回踏んだ）ので、
PATH を足すだけのラッパ `scratch/turn-006-check-tag.sh` から 3 ケースを回した。
**スクリプト側に PATH のフォールバックは入れていない**（契約外。CI の前提は setup-pixi）。

`release-notes.py`:

| 引数 | 出力 | rc | 期待 |
|---|---|---|---|
| `0.1.0` | 先頭行 `### Added` + Phase 1〜5 の 5 行（リンク定義行は含まない） | **0** | 非空・先頭が `### `（T4 (c)） |
| `9.9.9` | `release-notes.py: no ## [9.9.9] section in CHANGELOG.md`（stderr） | **1** | 節が無い（P17） |
| `Unreleased` | `release-notes.py: ## [Unreleased] section in CHANGELOG.md is empty`（stderr） | **1** | 本文が空（P17。空節の分岐を実際に通した） |

節の終端は「次の `## [` 見出し」または「`[x.y.z]: ` 形式のリンク定義行」の手前。見出し直後と節末の
空行は落とすので、`## [0.1.0]` の次が空行でも出力の先頭は `### Added` になる。

静的検査: `actionlint .github/workflows/ci.yml .github/workflows/release.yml` 指摘 0（rc 0）、
`bash -n .github/scripts/check-tag-version.sh` rc 0、`python3 -m py_compile .github/scripts/release-notes.py` rc 0
（`__pycache__` はコミット前に削除）。

## `check` の所要（turn 6）

| turn | タスク | コマンド | 開始 → 終了 | 所要 | 判定 |
|---|---|---|---|---|---|
| 6 | T4 | `pixi run check` | 2026-10-18T11:03:37+09:00 → 2026-10-18T11:06:27+09:00 | **170 s** | PASS 6/6（rc 0 / `final_check: PASS`。閾値 247 s） |

T4 は YAML / Python / shell / Markdown のみで Mojo 側は未変更なので turn 3（189 s）/ 4（183 s）/
5（173 s）と同じ範囲。`-- 127.0.0.1:54314 skipped 1`（PG14 側の leak 1 件）も従来どおり。

## チェックリスト（turn 7）

生出力は `.gsd-lite/logs/phase6-packaging-ci/scratch/turn-007-checklist.log`。
turn 6 のログとの差分は **`readme_*` の 19 key + `readme_unverified_windows` + `trace_checklist_section` だけ**
（後者は turn 6 が checklist を回した後に TRACE 節を書いたため 3 → 4）。

### T5 README（D1〜D4 / B7 の README 側）

| key | 値 | 期待値 | 判定 |
|---|---|---|---|
| `readme_en_heading` | 1 | 1 | OK |
| `readme_git_dep` | 2 | ≥ 2 | OK（英語節 + 日本語節） |
| `readme_tag_v010` | 3 | ≥ 2 | OK（英語節 1 + 日本語節 2 = TOML と「v0.1.0 リリース後に使える」の注記） |
| `readme_preview_pixi_build` | 4 | ≥ 2 | OK（両節の TOML + 散文での言及 2） |
| `readme_rattler_index` | 2 | ≥ 1 | OK（両節の `pixi exec --spec rattler-index rattler-index fs`） |
| `readme_ci_heading` | 1 | 1 | OK |
| `readme_job_name_ubuntu` / `_arm` / `_macos` | 2 / 2 / 2 | ≥ 1 ×3 | OK（CI 小節の表 + ブランチ保護の `contexts`） |
| `readme_required_status_checks` | 1 | ≥ 1 | OK（`protection.json`） |
| `readme_branch_protection` | 1 | ≥ 1 | OK（`### ブランチ保護（人間が設定）`） |
| `readme_windows_toolchain` | 2 | ≥ 2 | OK（既存の「Windows の状態」+ CI 小節の不在理由） |
| `readme_changelog` | 2 | ≥ 1 | OK（リリース手順 1. と 5.） |
| `readme_release_workflow` | 2 | ≥ 1 | OK（CI 小節の `workflow_dispatch` + リリース手順 5.） |
| `readme_wait_timeout_180` | 1 | ≥ 1 | OK（CI 小節の待ち上限 3 段階） |
| `readme_pg_ctl_60` | 1 | ≥ 1 | OK（同上） |
| `readme_fork` | 1 | ≥ 1 | OK（CI 小節。未検証と明記 = P24） |
| `readme_h2` | 11 | 11 | OK（10 → 11。English 節 +1 だけ。CI / ブランチ保護 / リリース手順 / 自分のプロジェクトから使う は `###`） |

### T5 の不変行

| key | 値 | 期待値 | 判定 |
|---|---|---|---|
| `readme_dash_I_src` | 2 | ≥ 1 | OK（経路 3 の見出し下 + コマンド） |
| `readme_six_stages` | 1 | 1 | OK（**意図的に増やさなかった**: CI 小節では「6 段」を使わず「`tests/final_check.sh`」「1 工程」と書いた） |
| `readme_compose_three` | 2 | 2 | OK（新規の「3 つです」を書いていない。待ち上限は「3 段階」、経路は「3 つあり」と表記） |
| `readme_unverified_windows` | 4 | ≥ 3 | OK（3 → 4。CI 小節の fork 未検証が +1） |
| `readme_sigpipe` / `readme_rc_141` | 2 / 1 | ≥ 1 ×2 | OK（T1 のまま不変） |

### T1 / T2 / T3 / T4 / 全体（不変）

turn 6 のログと**完全一致**（上の差分のとおり `readme_*` 以外は 1 key も動いていない）。
`pixi_lock_changed_vs_main=0` / `src_def_ref_return=0` / `test_file_count=24` / `examples_mojo_count=7` /
`final_check_examples=5` / `tests_sh_bash4_only=0` / `workflows_files=2` / `all_secrets_refs=0` /
`all_contents_write=1` も不変。

## `check` の所要（turn 7）

| turn | タスク | コマンド | 開始 → 終了 | 所要 | 判定 |
|---|---|---|---|---|---|
| 7 | T5 | `pixi run check` | 2026-10-18T11:11:22+09:00 → 2026-10-18T11:14:18+09:00 | **176 s** | PASS 6/6（rc 0 / `final_check: PASS`。閾値 247 s） |

T5 は `README.md` 1 ファイルのみ（Mojo / YAML / スクリプト未変更）なので
turn 3（189 s）/ 4（183 s）/ 5（173 s）/ 6（170 s）と同じ範囲。
README は `check` の 6 工程いずれの入力でもない（`mojo format` の対象外、`build/final_check.log` に入らない）ため、
6/6 工程の `matched lines in build/final_check.log: 0` も不変。
`-- 127.0.0.1:54314 skipped 1`（PG14 側の leak 1 件）も従来どおり。
生出力は `scratch/turn-007-check-stdout.log`。

## README に書いたコマンドの実測根拠（turn 7。P18）

| README の記述 | 実測した turn / 証跡 |
|---|---|
| git 依存（`preview` + 2 チャンネル + `pq = { git = …, tag = … }`） | turn 4 の A2 git 経路（`scratch/turn-004-consumer-git/pixi.toml` + `turn-004-consumer-git.log`）。**実測は `branch = "gsd-lite/phase6-packaging-ci"`** で、README は `tag = "v0.1.0"` の形。タグは未作成なので「v0.1.0 のリリース後に使える」と注記した（決めた事項 13） |
| Release `.conda` + `rattler-index fs` + `file://` チャンネル + `pq = "==0.1.0"` | turn 4 の A2 dl 経路（`scratch/turn-004-consumer-dl/pixi.toml` + `turn-004-consumer-dl.log`、`turn-004-dl-channel/`） |
| `-I src`（開発時） | 既存（Phase 1〜5 から不変） |
| `pixi run package` は配布手段でない | `pixi.toml:38`（`mojo precompile … -o build/pq.mojoc`）。REQ §2.1 |
| CI のジョブ名 3 つ / 待ち上限 3 値 / artifact 名 | `.github/workflows/ci.yml:36,40,46,105,112,120` と `pixi.toml:32`、`macos-postgres.sh` の `pg_ctl -w -t 60`（turn 5） |
| macOS で PG 14 が回らない / leak が SKIP | `run_tests.sh:37-38`（`PQ_TEST_CONNINFO` が 1 台に固定）、`test_leak.mojo:788`（`RSS sampling is Linux-only`） |
| `workflow_dispatch` は既定ブランチ必須 | P13（RESEARCH。GitHub の仕様。実測はしていない = 仕様の引用と明記） |
| `gh api … /branches/main/protection --input protection.json` | **未実行**（D15 / REQ §6「impl はリポジトリ設定を変えない」）。README にも「無人ターンは設定しません」と明記。verify / 人間が実行する |

## チェックリスト（turn 8）

生出力は `.gsd-lite/logs/phase6-packaging-ci/scratch/turn-008-checklist.log`（T6 = 全行の確認）。
turn 7 のログとの差分は **`trace_checklist_section` の 4 → 5 だけ**（turn 7 が checklist を回した後に
TRACE の turn 7 節を書いたため。他 100 key は 1 つも動いていない）。

**全行が PLAN:66-101 の期待値に到達**（T1 10 key / T2 11 key / T3 31 key / T4 23 key / T5 22 key / 全体 9 key）。
`≥` 行の実測値は T1 `test_notify_tests=25` / `readme_sigpipe=2`、T3 `ci_retry_sh=4` / `blackhole_held=5` /
`macos_pg_scram=4`、T4 `release_timeout_minutes=3` / `release_ref_type_tag=3` / `changelog_phase_lines=5`、
T5 `readme_h2=11`（= の行）など。`= N`（不変・0）の行も全部一致:
`pixi_lock_changed_vs_main=0` / `pixi_version_literal=1` / `tests_sh_bash4_only=0` / `ci_secrets_refs=0` /
`release_secrets_refs=0` / `all_secrets_refs=0` / `all_contents_write=1` / `src_def_ref_return=0` /
`test_file_count=24` / `examples_mojo_count=7` / `final_check_examples=5` / `readme_six_stages=1` /
`readme_compose_three=2` / `workflows_files=2`。

**PLAN 訂正（turn 8）: なし**（turn 4 の `pixi_pkg_name_pq` 1 → 2 が唯一の訂正で、以降は発生せず）。

## `check` の所要（turn 8。T6 = クリーン状態からの最終判定）

| turn | タスク | コマンド | 開始 → 終了 | 所要 | 判定 |
|---|---|---|---|---|---|
| 8 | T6 | `pixi run db-reset` → `pixi run check` | 2026-10-18T11:17:19+09:00 → 2026-10-18T11:20:19+09:00 | **`check` 170 s**（db-reset 含め 180 s） | PASS 6/6（rc 0 / `final_check: PASS`。閾値 247 s） |

`db-reset` は compose 3 台を `-v` で落として再作成（`--wait-timeout 180` 付き、3 台とも `Healthy`）→
フィクスチャ再適用。turn 3（189 s）/ 4（183 s）/ 5（173 s）/ 6（170 s）/ 7（176 s）と同じ範囲で、
**クリーンな DB からでも 165〜215 s の見積もり内**（REQ F1）。生出力は `scratch/turn-008-check-stdout.log`。

6 工程の内訳と `skipped` の実測（verify が CI ログと見比べるための基線）:

| 工程 | 結果 |
|---|---|
| 1/6 fmt | 差分なし（`mojo format` = REQ F2） |
| 2/6 precompile `src/pq` | 警告なし |
| 3/6 docstring diagnostics | 警告なし |
| 4/6 examples | 5 本（`final_check_examples=5` のまま） |
| 5/6 tests 両サーバー | 54317 = 全 PASS + `skipped 1`、54314 = 全 PASS + `skipped 1` + `test_leak.mojo` はファイルごと skip（`PQ_TEST_LEAK_SERVERS=1`） |
| 6/6 zero warnings | `matched lines in build/final_check.log: 0` |

**`skipped 1` の正体を特定した**（これまでの PROGRESS は 54314 の 1 件を「leak」と書いていたが実際は別物）:
54317 は `SKIP test_interval_infinity_rejected_before_pg17: server 17+`、
54314 は `SKIP test_interval_infinity_on_pg17_and_later: server < 17`。
どちらもサーバー版差による対称な 1 件で、`test_leak.mojo` の skip は `run_tests.sh:117` の
カウンタ（`^SKIP ` 行のみ）に入らない別行（`-- 127.0.0.1:54314 tests/test_leak.mojo skipped`）。

## パッケージング再確認（turn 8）

| 項目 | コマンド | 結果 |
|---|---|---|
| `.conda` 再生成 | `rm dist/pq-0.1.0-he8cfe8b_0.conda` → `pixi build -o dist` | rc 0。`dist/` に `pq-0.1.0-he8cfe8b_0.conda` **1 個**（ビルド ID も turn 4 と同一 = `he8cfe8b_0`） |
| lock 不変 | `pixi install --locked` → `git diff --quiet main -- pixi.lock` | 両方 rc 0（P3） |
| 作業ツリー | `git status --short` | 空（`dist/` `build/` は gitignore 済み） |
| YAML 静的検査 | `pixi exec --spec actionlint actionlint .github/workflows/{ci,release}.yml` | 指摘 **0**（2 本とも） |

初回の `pixi build` は既存ファイルを `Skipping 'pq-0.1.0-he8cfe8b_0.conda' (already exists)` で再利用したため、
**現在の木からのビルドを確かめるのに一度消してから回し直した**（deprecated 警告は turn 5 の判断どおり無視。rc 0）。

## 受け入れ基準対応表

REQ §4 の A1〜F2。「静的に確認（impl）」= このマイルストーン中にローカルで実測・grep した分、
「**verify の PR で確認**」= GitHub Actions の run を見るまで埋まらない分（REQ §2.2c / B6）。

| 基準 | 担ったタスク | 証跡（impl が確認した分） | verify に残る分 |
|---|---|---|---|
| A1 `pixi build` 成功 + `.conda` 生成 | T2 / T6 | turn 4（17 s で `pq-0.1.0-he8cfe8b_0.conda`）+ turn 8（dist を消して再生成、1 個、rc 0） | なし（完了） |
| A2 別プロジェクトから git / ローカルチャンネル依存で `mojo run` | T2 | turn 4 の 2 経路（`scratch/turn-004-consumer-git.log` / `turn-004-consumer-dl.log`。両方 `pq import OK` + `PgError(kind=Connection` で `LibpqLoad` 無し） | git 経路を `https://github.com/6in/mojo-pg.git` + `branch` で再実測（RESEARCH §6。PR 後） |
| A3 `.conda` に `examples/` `tests/` `hello.mojo` が無い | T2 | turn 4（`pkg-*.tar.zst` の中身は `lib/mojo/pq.mojoc` + `share/max/firstActivation` だけ） | なし（完了） |
| A4 `pixi run check` が従来どおり PASS | T2〜T6 | turn 4（183 s）/ 5（173 s）/ 6（170 s）/ 7（176 s）/ 8（170 s）すべて 6/6 PASS | なし（完了） |
| B1 `ci.yml` が PR(main) / push(main) で 3 OS | T3 | `wf_ci_exists` / `ci_pull_request=1` / `ci_branches_main=2` / `ci_os_*` 3 key / `ci_fail_fast_false=1` + actionlint 0 | **verify の PR で確認**（3 ジョブが実際に起動すること） |
| B2 Linux 2 ジョブが compose を立てて `final_check: PASS` | T3 | `ci.yml` の `db-up` / `docker compose pull` / `pixi run check` ステップ（`ci_pixi_run_check=3`）。ローカルでは同じ `pixi run check` が 6/6 PASS | **verify の PR で確認**（CI 上の緑） |
| B3 macOS が brew PG17 + `PQ_TEST_CONNINFO` で緑 / blackhole 代替が無ければ SKIP 件数がログに出る | T3 | `macos-postgres.sh` の `bash -n` rc 0 と grep 5 key（`scram` / `pg_ctl -w -t 60` / `WRONG` 対照 / `schema.sql` / `reload`）、`blackhole.py` のローカル陽性対照（`recv` が `TimeoutError`）、`ci_conninfo_5432=1`。**brew / macOS 自体は開発機（linux-aarch64）で実行不能** | **verify の PR で確認**（`macos-postgres.sh` の初実行。skipped の見込みは下の申し送り 3 を参照） |
| B4 各ジョブで `pixi build` 成功 + `.conda` を artifact 保存 | T3 | `ci_pixi_build=1` / `ci_upload_artifact=2` / `ci_artifact_pq_conda=1`（`pq-conda-${{ matrix.os }}`）+ ローカルの `pixi build` rc 0 | **verify の PR で確認**（3 artifact の実体とファイル名） |
| B5 全ジョブに `timeout-minutes` / DB 待ちに上限 / secrets 参照なし / `permissions` 最小 | T3 / T4 | `all_timeout_minutes=4` / `all_permissions=3` / `all_secrets_refs=0` / `all_contents_write=1`、待ち上限 = `--wait-timeout 180`（`pixi.toml:32`）と `pg_ctl -w -t 60` と ジョブ 45 分 | なし（静的に確定） |
| B6 PR 上で 3 ジョブが緑 | — | （impl は PR を作らない: D15 / 決めた事項 14） | **verify の PR で確認**（`gh pr checks --watch`） |
| B7 Windows ジョブ不在の理由が YAML と README に | T3 / T5 | `ci_windows_reason=1`（`ci.yml` 先頭コメント）+ `readme_windows_toolchain=2` | なし（完了） |
| C1 `release.yml` が `v*` タグ push で 3 プラットフォーム `.conda` + tarball を添付する構成 | T4 | `wf_release_exists` / `release_tags_v=1` / `release_pixi_build=1` / `release_git_archive=1` / `release_gh_release_create=1` / `release_gh_token=1` / `release_dup_check=1` + actionlint 0 | タグ push と Release 作成は **マイルストーン内で行わない**（REQ C3 の明示）。構成レビューのみ |
| C2 タグと `version` の不一致で落ちるステップ | T4 | `check-tag-version.sh` のローカル陽性対照 3 値（`v0.1.0` rc 0 / `v0.2.0` rc 1 / `0.1.0` rc 1。turn 6）+ `release_version_check_sh=1` / `release_ref_type_tag=3` | なし（完了。CI 上の実行は `verify-version` ジョブで PR 外） |
| C3 タグを使わない経路でビルド部分が確認済み | T3 / T4 | ローカル `pixi build` rc 0（turn 4 / 8）。`workflow_dispatch` は既定ブランチに無いと起動不可（P13） | **verify の PR で確認**（CI の `pq-conda-*` artifact が C3 の経路。REQ C3 の「CI 側の `pixi build` artifact」） |
| C4 `CHANGELOG.md` に `0.1.0` 節 + Release 本文に使う | T4 | `changelog_010_heading=1` / `changelog_unreleased_heading=1` / `changelog_phase_lines=5` + `release-notes.py` の陽性対照 3 値（`0.1.0` 非空 / `9.9.9` rc 1 / 空節 rc 1。turn 6）+ `release.yml` の `--notes-file` | なし（完了。実際の Release 本文はタグ push 時） |
| D1 英語の概要 + インストール節 | T5 | `readme_en_heading=1`（`## English summary and install`）+ `readme_git_dep` / `readme_rattler_index` が英語節にも | なし（完了） |
| D2 日本語インストール節に git / `.conda` の依存指定 | T5 | `readme_git_dep=2` / `readme_tag_v010=3` / `readme_preview_pixi_build=4` / `readme_rattler_index=2` / `readme_dash_I_src=2` | なし（完了） |
| D3 「テストの回し方」に CI の説明 | T5 | `readme_ci_heading=1` + `readme_job_name_{ubuntu,arm,macos}=2` 各 + `readme_wait_timeout_180` / `readme_pg_ctl_60` / `readme_fork` / `readme_windows_toolchain` | なし（完了） |
| D4 ブランチ保護の手順（job 名を含む） | T5 | `readme_branch_protection=1` / `readme_required_status_checks=1`（`protection.json` の `contexts` にジョブ名 3 つ） | 設定自体は**人間 / verify**（impl はリポジトリ設定を変えない: D15） |
| E1 SIGPIPE は README 明記（案 A）+ `check` PASS | T1 | `readme_sigpipe=2` / `readme_rc_141=1`、コード変更 0、`check` 6/6 PASS | なし（完了） |
| E2 `wait_readable` の非 TIMEOUT 経路でも `out` を復元 + テスト 1 件 | T1 | `async_restore_collected_def=1` / `_sites=3`（def + 2 呼び出し）/ `test_notify_tests=25`（24 → 25）/ `test_notify_restore_collected=2` | なし（完了。経路自体は単一スレッドで到達不能なのでテストはヘルパ直叩き + `notifications()` 観測） |
| F1 `check` PASS（247 s 以内） | T6 | turn 8 = **170 s**（クリーンな DB から。閾値 247 s、見積もり 170〜220 s の下端） | CI の所要は **verify の PR で確認**（3 OS、見込み 8〜13 分 + macOS brew 2〜4 分） |
| F2 警告ゼロ / `mojo format` 差分なし | T6 | `check` 1/6 段で差分なし、6/6 段で `matched lines: 0`、`pixi run package` 警告ゼロ | なし（完了。CI も同じ `pixi run check` を回す） |

## verify への申し送り

1. **PR を作って CI を待つ**（impl は作っていない）。`gh pr create` → `gh pr checks <PR> --watch`（上限 **40 分**。
   ジョブ `timeout-minutes: 45` + macOS brew 2〜4 分を見込む）。必須の 3 ジョブ名は
   `check (ubuntu-latest)` / `check (ubuntu-24.04-arm)` / `check (macos-latest)`
2. **artifact 名を VERIFICATION に写す**（P5 = release の `uniq -d` 重複検査の根拠）: `pq-conda-ubuntu-latest` /
   `pq-conda-ubuntu-24.04-arm` / `pq-conda-macos-latest` の 3 つと、中の `.conda` の**ファイル名**
   （linux-aarch64 は `pq-0.1.0-he8cfe8b_0.conda`。x86_64 / osx-arm64 のハッシュが互いに違えば flat な `dist/` で衝突しない）。
   `final-check-log-<os>` の 3 artifact は `build/final_check.log` で、6 工程と `skipped` 行を読む用
3. **macOS ジョブの `skipped` の見込みは 15 件**（turn 8 で内訳を特定した）: `test_leak.mojo` の
   `_skip_on_macos` が **14 箇所**（`SKIP <name>: RSS sampling is Linux-only`）+ PG17 なので
   `SKIP test_interval_infinity_rejected_before_pg17` **1 件**。`test_connect_blocking_times_out` は
   blackhole が立てば **PASS が正**（立たなければ `SKIP … port 54399 refused` が 1 件増えて 16）。
   PG14 は Linux だけなので `test_interval_infinity_on_pg17_and_later` の SKIP は macOS には出ない。
   Linux 2 ジョブは 54317 / 54314 とも `skipped 1`（上の基線と同じ）
4. **A2 の git 経路を再実測**（RESEARCH §6）: 別ディレクトリの最小 pixi プロジェクトから
   `pq = { git = "https://github.com/6in/mojo-pg.git", branch = "gsd-lite/phase6-packaging-ci" }`
   （`preview = ["pixi-build"]` + channels `https://conda.modular.com/max` と `conda-forge`）で
   `pq import OK` + `PgError(kind=Connection` を確認する。turn 4 は `file://` の local path で実測済み
5. **2 回目の run で setup-pixi のキャッシュ**（P12）: PR に 2 回目の push をしたら
   `Cache restored` のログ行を確認する（1 回目は `Cache not found` が正）
6. 任意: Phase 5 の堅牢性格子 `scratch/turn-012-robust-regress.sh` は期待値不変
   （E1 が案 A = コード変更なしのため。`> >(exit 0)` 軸の rc 141 もそのまま）

## PLAN 訂正（turn 10）

1. チェックリスト `ci_locked_true` の期待値 **1 → 0**。`prefix-dev/setup-pixi@v0.11.2` は install を切った状態では
   cache と lock の 2 入力を受け付けない（`src/options.ts:207-217`）ため、F1 で `ci.yml` から当該行を削除した。
   PLAN:82 の表と「決めた事項 5」の記述も `cache: false`（lock 入力なし）に直した
2. TRACE「verify への申し送り」の **5（2 回目の run で `Cache restored`）は無効**。setup-pixi のキャッシュは使わない
   （毎 run で環境を取得。+1〜3 分の見込み）。verify round 2 はこの項目を確認対象から外す

## F1 setup-pixi 入力の修正（turn 10）

- 変更箇所 **4 つ**（いずれも `with:` を `pixi-version: v0.82.0` / `cache: false` / `run-install: false` の 3 行に）:
  `ci.yml` の `check` ジョブ 1 箇所、`release.yml` の `verify-version` / `build` / `release` の 3 箇所
- 採った設計は **A（手動 install 維持）**: lock の強制は既存の `bash .github/scripts/retry.sh 3 15 pixi install --locked`
  ステップが担う（REQ §2.5 のリトライ要件を満たしたまま）。B（action に install させる）は install にリトライが付かない
- `verify-version` / `release` ジョブは install を呼ばない（`pixi workspace version get` のみ / `gh` のみ）が、入力は 3 ジョブで揃えた
- コメントは key のパターン文字列（`locked: true` / `run-install: false` / `cache: true` / `cache: false`）を含まない言い回しに統一

| 検査 | 結果 |
|---|---|
| `pixi exec --spec actionlint actionlint .github/workflows/ci.yml .github/workflows/release.yml` | 指摘 0 |
| `grep -c 'cache: false'`（ci / release） | **1 / 3** |
| `grep -c 'cache: true'` / `grep -c 'locked: true'`（2 本とも） | **0 / 0**（grep rc 1） |
| `pixi run check` | **6/6 PASS = 175 s**（11:38:33 → 11:41:28。閾値 247 s）。`final_check: PASS`、6/6 段 `matched lines: 0`、Linux 両サーバー `skipped 1` |

## チェックリスト（turn 10）

`scratch/turn-010-checklist.log`（全 101 key）。**turn 9 のログとの差分は 1 行だけ**:

```
38c38
< ci_locked_true=1
---
> ci_locked_true=0
```

setup-pixi 周辺の現在値: `ci_setup_pixi_pinned=1` / `ci_pixi_version=1` / `ci_run_install_false=1` /
`ci_locked_true=0` / `ci_retry_sh=4`（不変）。他の全行は turn 9 と同値。

- 途中経過: 最初のコメント案が `retry.sh` に 2 回触れて `ci_retry_sh` が 4 → 5 になったため、
  「the install step below」に言い換えて 4 に戻した（turn 5 / 6 と同じ型の混入。検出はチェックリストの diff）

## CI 実測（turn 11 / verify round 2 / run 39091056281）

生ログ: `scratch/turn-011-macos-artifact/final_check.log`（872 行）/ `turn-011-arm-artifact/` / `turn-011-x64-artifact/` /
`turn-011-macos-job.log`（ジョブ全体、`gh api .../jobs/<id>/logs`）。`.conda` は `turn-011-conda-arm/` / `turn-011-conda-x64/`

| ジョブ | 結果 | 所要 | 5/6 段 | skipped | `.conda` |
|---|---|---|---|---|---|
| `check (ubuntu-latest)` | ✅ | 9m52s | FAIL 0 | 1 / 1 | `pq-0.1.0-hb0f4dca_0.conda` 461,664 B |
| `check (ubuntu-24.04-arm)` | ✅ | 8m26s | FAIL 0 | 1 / 1 | `pq-0.1.0-he8cfe8b_0.conda` 461,660 B |
| `check (macos-latest)` | ❌ | 4m41s | FAIL 2（test_async 30/31、test_poll 10/11） | 15 | 未到達 |

macOS の段ごとの時刻（UTC）: setup-pixi 02:42:49 → install 02:42:50〜53（3 s）→ `macos-postgres.sh` 02:42:53〜05（12 s。brew bottle 17.11_1、initdb スキップ、
scram 切替 + reload、陽性対照 2 つ OK）→ blackhole 02:43:05〜07（accepting）→ `pixi run check` 02:43:07〜02:47:14（247 s、5/6 で `--- FAIL`）。
`LibpqLoad` 0 件。`test_connect_blocking_times_out` PASS 560 ms

macOS の赤 2 件（verify の読み）:

```
FAIL [ 17.769 ] test_connect_failures_name_their_cause
  At tests/test_async.mojo:1613:16: AssertionError: connection socket closed (POLLHUP/POLLERR)
FAIL [ 0.033 ] test_socketpair_peer_close_sets_hangup_both_ways
  At tests/test_poll.mojo:215:16: AssertionError: condition was unexpectedly False
```

- 共通の原因: macOS の poll(2) は POSIX どおり `POLLHUP` と `POLLOUT` を同時に立てない。Linux は socket で両方立てる（Phase 4 RESEARCH §2.3 の `20 = POLLOUT|POLLHUP`）
- ① は `async_conn.mojo:787-793`（`wait_writable` の「要求方向ビット無し + hangup」→ 汎用 CONNECTION）に入る。Linux は `POLLOUT` があるので `:787` で return → `PQconnectPoll` が `Connection refused` を名乗る
- ② は `poll_socket` の flags そのまま。`:213-214`（読み側 `POLLIN|POLLHUP`）は通過、`:215`（書き側 `POLLOUT`）が False
- → PLAN **F2**（設計 A: hangup / error だけでも return して libpq に言わせる + test_poll の `writable` assert を Linux 限定）

## チェックリスト（turn 11）

`scratch/turn-011-checklist.log`（全 101 key）。**turn 10 のログとの差分は 1 行だけ**（単調増加の性質）:

```
11c11
< trace_checklist_section=6
---
> trace_checklist_section=7
```

F1 の回帰 grep: `cache: false` = 1 / 3、`cache: true` + `locked: true` = 0 / 0、actionlint 指摘 0。ローカル `check` 6/6 PASS = 170 s（11:46:32 → 11:49:22）

## F2 macOS の poll セマンティクスへの追従（turn 12）

設計 **A**（PLAN F2 の背景。B = OS 分岐 / C = テスト緩和は採らない）: `wait_readable` / `wait_writable` は poll が hangup / error
だけを報告した場合も **raise せず return** し、切断の理由は次の libpq 呼び出しに名乗らせる。

### (a) src の変更（`src/pq/async_conn.mojo` 2 メソッドのみ）

| 変更 | 内容 |
|---|---|
| `wait_readable`（旧 `:756-760`） | `if events.hangup or events.error: raise CONNECTION ...` の 5 行を削除。`if events.readable: return` も不要になったので削除（timeout 以外は return で抜ける） |
| `wait_writable`（旧 `:789-793`） | 同じ 5 行 + `if events.writable: return` を削除 |
| docstring 2 本 | 本文に「hangup / error だけでも返る。理由は次の libpq 呼び出しが名乗る」の段落を追加。`Raises:` の `CONNECTION` は **socket が無いときだけ**に直した |
| 残す挙動 | `fd < 0` → `CONNECTION "no socket: connection is closed"`、`events.timeout` → `TIMEOUT "wait_* timed out after N ms"`、`poll_socket` の `USAGE`（範囲外 `timeout_ms`）は不変 |
| `src/pq/__init__.mojo:290` の表 | 触っていない（`TIMEOUT` / `CONNECTION` / `USAGE` の 3 種はいずれも残るため記述は正しい） |

汎用メッセージは src から消えた: `grep -c 'POLLHUP/POLLERR' src/pq/async_conn.mojo` → **0**（rc 1）。

### (b) 呼び出し側 3 箇所の busy loop 否定（コードレビュー。コード変更なし）

| 呼び出し側 | return 直後の libpq 呼び出し | 失敗の報告のされ方 |
|---|---|---|
| `_poll_to_ready`（`:830-834`。`while True` の connect 駆動） | ループ先頭に戻り `poll_connect()` → `PQconnectPoll` | `PQconnectPoll` が `SO_ERROR` を読んで `PGRES_POLLING_FAILED` → `poll_connect` が `CONNECTION`（libpq の `Connection refused`）を raise。1 周で終わる |
| `_wait_for`（`:1466-1470`。`fetch_all` の `SENDING` 分岐 → `flush()`） | `flush()` → `PQflush` | 送信が失敗した接続では `PQflush` が `-1` → `flush` が `_connection_error()` を raise、`0` を返した場合は状態が `BUSY` に進み次周の `poll_result` → `PQconsumeInput` が 0 を返して `CONNECTION`。どちらでも 1〜2 周で終わる（`1` を返し続けるには送信可能であることが必要 = hangup のみの状態と両立しない） |
| `_collect_notifications`（`:1658-1664`） | ループ先頭に戻り `notifications()` → `PQconsumeInput` | EOF / エラーの `recv` で `PQconsumeInput` が 0 → `_connection_error()`（`server closed the connection unexpectedly` 等）。`except` が `_restore_collected(out)` してから raise するので収集済み通知も失われない。1 周で終わる |

### (c) テストの変更（`tests/test_poll.mojo` 1 テスト）

`test_socketpair_peer_close_sets_hangup_both_ways`: `readable.readable` / `readable.hangup` / `writable.hangup` の 3 assert は両 OS 共通のまま、
`assert_true(writable.writable)` だけを `if CompilationTarget.is_linux():` の下に置いた（`test_leak.mojo:77,787` と同じ import / 判定の形）。
macOS では `writable` を assert しない。テスト数 **11 不変**、既存テストの期待値変更は **0 件**。

### (e) 期待結果の実測（PLAN F2 (e) の表）

| 条件 | 結果 |
|---|---|
| `grep -c 'POLLHUP/POLLERR' src/pq/async_conn.mojo` | **0**（rc 1） |
| `grep -c 'is_linux' tests/test_poll.mojo` | **1**（≥ 1） |
| `pixi run mojo run -I src tests/test_poll.mojo` | **11 tests run: 11 passed, 0 failed** |
| `pixi run mojo run -I src tests/test_async.mojo`（54317） | **31 tests run: 31 passed, 0 failed**（`test_connect_failures_name_their_cause` PASS） |
| `pixi run check`（`db-reset` の後） | **6/6 PASS = 190 s**（12:02:54 → 12:06:04、閾値 247 s）、6/6 段 `matched lines in build/final_check.log: 0`、`final_check: PASS`、両サーバー `SKIP` 1 件ずつ（`test_interval_infinity_*` の PG 版差） |
| `pixi run package` | 警告 0（出力は pixi のタスク行のみ） |
| checklist `src_def_ref_return` / `test_file_count` / `async_*` 4 key | **0 / 24 / 1・3・3（不変）** |

**macOS の `test_connect_failures_name_their_cause` の PASS はローカル（Linux）では観測できない**（Linux は `POLLOUT` を伴うので (a) の分岐に入らず経路差が出ない）。
CI の macOS ジョブでの判定は verify round 3。

## チェックリスト（turn 12）

`scratch/turn-012-checklist.log`（全 101 key。この節を書く前に採取）。**turn 11 のログとの差分は 1 行だけ**
（turn 11 が「チェックリスト（turn 11）」の見出しを足した分の単調増加。この節を足した後は 9 になる）:

```
11c11
< trace_checklist_section=7
---
> trace_checklist_section=8
```

PLAN 訂正は **0 件**（F2 の期待結果は表のとおり実測と一致）。
