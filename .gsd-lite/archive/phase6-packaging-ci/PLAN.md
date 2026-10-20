# PLAN — phase6-packaging-ci

- 作成: 2026-10-18 / gsd-lite-plan（turn 2）
- 入力: REQUIREMENTS.md / DECISIONS.md / RESEARCH.md / `.gsd-lite/reflect/20261018-0103-phase5-polish-bench-readme.md`（直近）/
  `.gsd-lite/reflect/20261017-1925-phase4-async-cancel-notify.md` / `archive/phase5-polish-bench-readme/PLAN.md`（書式の手本）/
  `pixi.toml` / `tests/final_check.sh` / `tests/run_tests.sh` / `tests/docker-compose.yml` / `src/pq/async_conn.mojo` / `tests/test_notify.mojo` / `tests/test_async.mojo` / `README.md` / `HANDOFF.md` §2
- 対象リポジトリ: `.`（in-repo 形）。`CLAUDE.md` / `AGENTS.md` は無い（`ls` で確認。Phase 5 PLAN と同じ）。リモート `origin` = `https://github.com/6in/mojo-pg.git`
  （`git remote -v`）、`gh api repos/6in/mojo-pg` → default branch `main`、`public`
- 無人シェルの注意（RESEARCH §0.5 と同じ）: `mojo` / `pixi` は PATH に無い → **`/home/parallels/.pixi/bin/pixi run ...`**。先頭の変数代入は不可（`env VAR=… cmd`）。
  `awk` / `sed` / `bash <任意パス>` / `curl` は allowlist（`.claude/settings.json`）に無い → **`/home/parallels/.pixi/bin/pixi run <cmd>` 経由で実行する**（`pixi:*` / `pixi run:*` は許可。
  例 `pixi run bash -n .github/scripts/macos-postgres.sh`）。`bash tests/...` / `python3` / `gh api|pr|run|workflow` / `docker` / `git` は直接可。
  docker は `tests-pg17-1` / `tests-pg14-1`（healthy）/ `tests-blackhole-1` が起動中（plan 時点 `docker compose ps`）。lean-ctx MCP は未接続（素の Read / Bash で可）。
  `> >(exit 0)` などプロセス置換は Bash ツール直書き不可 → スクリプトファイルにして `bash tests/...` か `pixi run bash <file>`
- research のプローブ（`.gsd-lite/logs/phase6-packaging-ci/scratch/turn-001-*`、gitignore 対象）は impl が**雛形として開いてよい**:
  `turn-001-pkg-full/pixi.toml`（本物の manifest + `[package]`。T2 の差分の原型。ただし `version` は `{ workspace = true }` に変える: `turn-001-pkg-inherit/pixi.toml`）、
  `turn-001-consumer-git/` と `turn-001-consumer-dl/`（利用側 smoke の `pixi.toml` + `main.mojo`。T2 の A2）、`turn-001-dl-channel/`（`rattler-index fs` 済みの file チャンネルの形）、
  `turn-001-notify-close.mojo`（`close(PQsocket)` 後の `_pending` 観測。T1 の E2 の背景）、`turn-001-sigpipe.sh` / `.mojo`（E1 の案 B の実測。採らないが根拠）
- **追従先チェックリストは実行可能スクリプト** `.gsd-lite/logs/phase6-packaging-ci/scratch/turn-002-checklist.sh`。plan ターンで 1 回実行し、現在値は
  `scratch/turn-002-checklist.log`（コミット `8380d18` の木）にある。下表は key / 直す場所 / 期待値の 3 列だけ。impl は各タスクの完了基準の最後で実行し、
  自タスクの行が期待値に到達していることを PROGRESS に 1 行で書く（生の値は `.gsd-lite/TRACE.md` の「チェックリスト（turn N）」節へ）。
  **PLAN の訂正は表のセルに書かず `TRACE.md` の「PLAN 訂正（turn N）」節に 1 件 1 行**

## 検証コマンド

impl の各ターンがテストに使うコマンド（リポジトリルートで実行。`cd` 不要）:

```bash
/home/parallels/.pixi/bin/pixi run db-up          # 環境の初期化（--wait 付き。T1 以降は --wait-timeout 180 付き。起動済みなら即終了）
/home/parallels/.pixi/bin/pixi run db-reset       # db-down（-v）→ db-up。フィクスチャ再適用。T6 の最終判定の前に 1 回
/home/parallels/.pixi/bin/pixi run test           # tests/run_tests.sh: 54317 → 54314 の順に tests/test_*.mojo を 1 ファイル 1 プロセス
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_notify.mojo         # T1（単一ファイル。PQ_TEST_CONNINFO 未設定なら 54317）
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_async.mojo          # T1（wait_readable 経路の回帰）
/home/parallels/.pixi/bin/pixi run package        # mojo precompile src/pq -o build/pq.mojoc（警告ゼロ確認）
/home/parallels/.pixi/bin/pixi run check          # 最終判定: bash tests/final_check.sh（6 段、exit 0 が合格）
/home/parallels/.pixi/bin/pixi build -o dist      # T2 以降: conda パッケージ生成（dist/pq-0.1.0-*.conda が 1 個）
/home/parallels/.pixi/bin/pixi install --locked   # T2 以降: lock が [package] 追加後も最新であること（rc 0。P3）
git diff --quiet main -- pixi.lock                # T2 以降: lock 不変（rc 0。P3）
/home/parallels/.pixi/bin/pixi exec --spec actionlint actionlint .github/workflows/ci.yml .github/workflows/release.yml   # T3 / T4: YAML 静的検査（conda-forge actionlint 1.7.12）
/home/parallels/.pixi/bin/pixi run bash -n .github/scripts/retry.sh .github/scripts/macos-postgres.sh .github/scripts/check-tag-version.sh   # T3 / T4: 構文（bash 3.2 互換は目視）
python3 -m py_compile .github/scripts/blackhole.py .github/scripts/release-notes.py   # T3 / T4
python3 .github/scripts/release-notes.py 0.1.0    # T4: CHANGELOG の 0.1.0 節を stdout に（空なら rc 1）
/home/parallels/.pixi/bin/pixi run bash .github/scripts/check-tag-version.sh v0.1.0   # T4: rc 0（v0.2.0 なら rc 1）
/home/parallels/.pixi/bin/pixi exec --spec rattler-index rattler-index fs <dir>       # T2: ダウンロード経路の file チャンネル索引
bash .gsd-lite/logs/phase6-packaging-ci/scratch/turn-002-checklist.sh   # 追従先チェックリスト（現在値を出す）
python3 -c "t=open('.gsd-lite/PROGRESS.md').read().split('\n## turn');print(len(t[-1].splitlines()))"   # T6: 最新ターン節の行数（≤ 40）
gh run list --branch gsd-lite/phase6-packaging-ci --limit 5   # T6: push で CI が走らないこと（P15。0 件が正）
```

- 環境の初期化（テストの前に毎回）: `/home/parallels/.pixi/bin/pixi run db-up`（起動済みなら即終了）
- 最終判定（クリーンな状態から全検査。verify と T6 が使う）: **`/home/parallels/.pixi/bin/pixi run db-reset` → `/home/parallels/.pixi/bin/pixi run check`** + `pixi build -o dist` + `git diff --quiet main -- pixi.lock`
  - 4/6 段（`final_check.sh:120-129`）は 5 本の examples、**本マイルストーンで増減なし**。6/6 段は `grep -cE 'warning:|WARNING:|implicit ROLLBACK failed'`（`final_check.sh:155`）。
    **見出し行・`print` にこれらの文字列を含めない**（CHANGELOG / README / YAML は `$LOG` に入らないので対象外）
  - `final_check.sh` は compose を呼ばない（compose は `pixi run db-up` だけ。RESEARCH §2.10）→ CI の macOS も **同じ `pixi run check`** を回す（REQ §2.5「同じスクリプト」）
- 所要見積もり（Phase 4 reflect の式）: `check` = Phase 5 末実測 **165〜215 s** + 新テストファイル 0 本 + 新テスト 1 件（T1。NOTIFY 3 件 + `wait_notifications(1, 5000)` 即時 ≈ 1 s）→ **170〜220 s**。
  閾値 **247 s**（REQ F1。超えたら PROGRESS に理由）。`pixi build` 初回 < 60 s（backend 取得）、2 回目以降 ≈ 2 s。`pixi exec actionlint` 初回 ≈ 10〜30 s（取得）。
  利用側 smoke: git 経路 ≈ 60〜120 s（利用側で backend を取ってビルド）、dl 経路 ≈ 30 s
- **CI の初見は verify の PR**: `ci.yml` の `on:` は `pull_request`（base main）と `push`（main）だけ（REQ B1 / P15）なので、**T6 の branch push では CI は走らない**。
  impl は静的検査（actionlint / `bash -n` / `py_compile` / grep）とローカル `check` + `pixi build` で品質を担保し、CI 固有の失敗は verify の差し戻し（F タスク）で直す（REQ §6）
- PG14 / PG17 の差: T1 の新テストは両サーバー同一期待値（NOTIFY / LISTEN のみ）

## 追従先チェックリスト

スクリプト `turn-002-checklist.sh` の key で書く（左列）。現在値は `scratch/turn-002-checklist.log`（2026-10-18、コミット `8380d18` の木）。`absent(...)` はファイル未作成。
期待値の「≥」「≤」は下限 / 上限。`= N` は「0 になる」「不変」の性質だけ（Phase 5 reflect）。

| key | 変更の種類 / 直す場所 | 期待値（到達タスク） |
|---|---|---|
| `async_restore_collected_def` / `async_restore_collected_sites` | E2: `src/pq/async_conn.mojo:1627-1638,1656-1659` の復元を `_restore_collected` に切り出し、両 `except` から呼ぶ | **1 / 3**（T1。def + 2 呼び出し。P20） |
| `async_wait_readable_timeout_return` | `:1657` の `TIMEOUT` → `return out^` は残す（他 2 箇所は無関係） | **3**（不変） |
| `test_notify_tests` / `test_notify_restore_collected` | E2 のテスト 1 件（`tests/test_notify.mojo`。現在 24 件） | **≥ 25 / ≥ 1**（T1） |
| `readme_sigpipe` / `readme_rc_141` | E1（案 A）: README「既知の制限」に SIGPIPE / rc 141 の 2 行 | **≥ 1 / ≥ 1**（T1。P19） |
| `pixi_db_up_wait_timeout` | `pixi.toml:27` の `db-up` に `--wait-timeout 180`（P11） | **1**（T1） |
| `trace_exists` / `trace_checklist_section` | `.gsd-lite/TRACE.md` 新設（Phase 5 reflect: 「チェックリスト（turn N）」節を T1 で作る） | **exists / ≥ 1**（T1） |
| `pixi_preview` / `pixi_package_section` / `pixi_version_workspace` / `pixi_pkg_name_pq` / `pixi_pkg_path` / `pixi_backend_mojo` / `pixi_mojo_compiler` | T2: RESEARCH §2.1 の差分（`[workspace] preview`、`[package]`、`[package.build]`、`[package.build.config.pkg]`、host / build / run の `mojo-compiler`） | **1 / 1 / 1 / 2 / 1 / 1 / 3**（T2。P1 / P2。`pixi_pkg_name_pq` は `^name = "pq"` なので `[package]` と `[package.build.config.pkg]` の 2 行に当たる = 2） |
| `pixi_version_literal` | `version = "0.1.0"` は `[workspace]` の 1 行だけ（P4。`[package]` は `{ workspace = true }`） | **1**（不変） |
| `pixi_run_dep_libpq` | `[dependencies]` の `libpq = ">=14"` + `[package.run-dependencies]` の同じ行 | **2**（T2） |
| `gitignore_dist` | `.gitignore` に `dist/`（`pixi build -o dist` の出力） | **1**（T2） |
| `pixi_lock_changed_vs_main` | `[package]` 追加で lock が変わらない（RESEARCH §2.2 実測。**変わったら feature / environments を落としていないか疑う**） | **0**（T2 以降ずっと。P3） |
| `wf_ci_exists` / `ci_os_ubuntu_latest` / `ci_os_ubuntu_arm` / `ci_os_macos_latest` / `ci_fail_fast_false` | T3: `.github/workflows/ci.yml` の matrix 3 OS | **exists / ≥ 1 / ≥ 1 / ≥ 1 / 1**（T3） |
| `ci_timeout_minutes` / `ci_permissions` / `ci_secrets_refs` | D9: ジョブに `timeout-minutes: 45`、先頭 `permissions: contents: read`、`secrets.` 参照なし | **≥ 1 / ≥ 1 / 0**（T3。P14） |
| `ci_branches_main` / `ci_pull_request` | `on.pull_request.branches: [main]` + `on.push.branches: [main]`（P15） | **2 / 1**（T3） |
| `ci_setup_pixi_pinned` / `ci_pixi_version` / `ci_run_install_false` / `ci_locked_true` | `prefix-dev/setup-pixi@v0.11.2`（`pixi-version: v0.82.0`, `cache: false`, `run-install: false`）+ `retry.sh` で `pixi install --locked`（P12） | **1 / 1 / 1 / 0**（T3。`ci_locked_true` は F1 で 1 → 0） |
| `ci_pixi_run_check` / `ci_pixi_build` / `ci_upload_artifact` / `ci_artifact_pq_conda` | 3 ジョブとも `pixi run check` → `pixi build -o dist` → `upload-artifact@v7`（名前 `pq-conda-${{ matrix.os }}`） | **≥ 1 / ≥ 1 / ≥ 2 / ≥ 1**（T3。B2 / B4。2 つ目の upload は `final_check.log`） |
| `ci_windows_reason` / `ci_conninfo_5432` / `ci_retry_sh` | Windows ジョブ無しの理由コメント（B7）/ macOS の `PQ_TEST_CONNINFO`（RESEARCH §2.8）/ リトライ呼び出し | **≥ 1 / ≥ 1 / ≥ 3**（T3） |
| `scripts_retry` / `scripts_macos_pg` / `scripts_blackhole` | `.github/scripts/retry.sh` / `macos-postgres.sh` / `blackhole.py` | **exists ×3**（T3） |
| `macos_pg_scram` / `macos_pg_ctl_wait` / `macos_pg_wrong_password` / `macos_pg_schema_sql` / `macos_pg_reload` | RESEARCH §2.8: `pg_hba.conf` の `host` 行を `scram-sha-256` に → `pg_ctl reload`、`pg_ctl -w -t 60 start`、陽性対照 `password=WRONG`、`schema.sql` 適用 | **≥ 1 / ≥ 1 / ≥ 1 / ≥ 1 / ≥ 1**（T3。P6 / P7） |
| `blackhole_held` | `blackhole.py` が accept 済みソケットを `held` リストで保持（P8） | **≥ 1**（T3） |
| `tests_sh_bash4_only` | `tests/final_check.sh` / `run_tests.sh` に `mapfile` / `declare -A` / `${x,,}` を足さない（P10） | **0**（不変） |
| `wf_release_exists` / `release_tags_v` / `release_workflow_dispatch` / `release_ref_type_tag` | T4: `.github/workflows/release.yml`（`on.push.tags: ["v*"]` + `workflow_dispatch` = build までの dry run） | **exists / 1 / 1 / ≥ 1**（T4。P13） |
| `release_version_check_sh` / `release_notes_py` / `release_gh_release_create` / `release_gh_token` / `release_git_archive` / `release_pixi_build` / `release_dup_check` | C1 / C2 / C4: `check-tag-version.sh` → build 3 OS（`pixi build -o dist`）→ `release-notes.py` → `git archive` → 添付名の重複検査（`uniq -d`。P5）→ `gh release create`（`GH_TOKEN: ${{ github.token }}`。P16） | **≥ 1 ×7**（T4） |
| `release_contents_write` / `release_contents_read` / `release_timeout_minutes` / `release_secrets_refs` | `permissions` は先頭 `contents: read`、release ジョブだけ `contents: write`。3 ジョブに `timeout-minutes` | **1 / ≥ 1 / ≥ 3 / 0**（T4。P14） |
| `scripts_check_tag_version` / `check_tag_version_pixi` / `scripts_release_notes` | `.github/scripts/check-tag-version.sh`（`pixi workspace version get` と比較）/ `release-notes.py` | **exists / ≥ 1 / exists**（T4） |
| `changelog_exists` / `changelog_010_heading` / `changelog_unreleased_heading` / `changelog_keep_a_changelog` / `changelog_phase_lines` | `CHANGELOG.md`（Keep a Changelog。`## [Unreleased]` + `## [0.1.0] - 2026-10-18`。Phase 1〜5 の要約。P17） | **exists / 1 / 1 / ≥ 1 / ≥ 5**（T4） |
| `readme_en_heading` / `readme_git_dep` / `readme_tag_v010` / `readme_preview_pixi_build` / `readme_rattler_index` | D1 / D2: 英語節 `## English summary and install`、git 依存（`tag = "v0.1.0"`）+ `preview`、Release `.conda` + `rattler-index`（P18） | **1 / ≥ 2 / ≥ 2 / ≥ 2 / ≥ 1**（T5。英語節と日本語節の両方に） |
| `readme_dash_I_src` | 開発時の `-I src` の説明は残す（`README.md:36-41`） | **≥ 1**（不変） |
| `readme_ci_heading` / `readme_job_name_ubuntu` / `readme_job_name_arm` / `readme_job_name_macos` | D3: 「テストの回し方」に `### CI` 小節、ジョブ名 3 つ | **1 / ≥ 1 / ≥ 1 / ≥ 1**（T5） |
| `readme_required_status_checks` / `readme_branch_protection` | D4: ブランチ保護の手順（`gh api` + 画面。ジョブ名 3 つを contexts に） | **≥ 1 / ≥ 1**（T5） |
| `readme_windows_toolchain` / `readme_changelog` / `readme_release_workflow` / `readme_wait_timeout_180` / `readme_pg_ctl_60` / `readme_fork` | B7 / C4 / RESEARCH §5: Windows ジョブ無しの理由、CHANGELOG と release.yml の関係、待ち上限 2 値、fork PR は未検証と明記（P24） | **≥ 2 / ≥ 1 / ≥ 1 / ≥ 1 / ≥ 1 / ≥ 1**（T5） |
| `readme_h2` / `readme_six_stages` / `readme_compose_three` / `readme_unverified_windows` | README の既存節数は英語節 +1。「6 段」「3 つです」「未検証」は不変 | **11 / 1 / 2 / ≥ 3**（T5） |
| `workflows_files` / `all_timeout_minutes` / `all_permissions` / `all_secrets_refs` / `all_contents_write` | 全体: ワークフロー 2 本、`timeout-minutes` ≥ 4（ci 1 + release 3）、`permissions` ≥ 3、`secrets.` 0、`contents: write` 1 | **2 / ≥ 4 / ≥ 3 / 0 / 1**（T4 以降） |
| `src_def_ref_return` / `test_file_count` / `examples_mojo_count` / `final_check_examples` | 不変（新しい型・API・examples を足さない。REQ §3） | **0 / 24 / 7 / 5**（不変） |

## Tasks

- [x] T1: 持ち越し 2 件（E1 = README 明記 / E2 = `_restore_collected` + テスト 1 件）+ `db-up` の待ち上限 + `TRACE.md` 新設 + `check` 基線
  - 完了基準:
    - (a) **E2**（REQ §2.3 / RESEARCH §2.14 推奨形 / 決めた事項 2）: `src/pq/async_conn.mojo` に private `def _restore_collected(mut self, collected: List[Notification])`
      （docstring 付き。`collected` の要素を先頭に、続けて現在の `_pending` を並べた新しい `List` を `self._pending` に置く = 現状 `:1632-1637` の 5 行そのもの）。
      `_collect_notifications`（`:1582`）の **2 つの `except`** から呼ぶ: `notifications()` 側（`:1627-1638`）は 5 行をヘルパ呼び出しに置き換えて `raise e^`、
      `wait_readable` 側（`:1656-1659`）は `TIMEOUT` なら従来どおり `return out^`、**それ以外はすべて**（`CONNECTION` も `USAGE` も）`self._restore_collected(out)` してから `raise e^`。
      `_collect_notifications` の docstring（`:1609-1616` の `Raises:`）に「collected notifications are put back in front of `_pending` on every raise」の趣旨を 1 文。
      陽性対照はコードレビュー + grep（`_restore_collected(` = 3 箇所。P20。経路自体は単一スレッドで到達不能: RESEARCH §2.14）
    - (b) テスト 1 件（`tests/test_notify.mojo`、`test_restore_collected_puts_them_back_in_front`）: LISTEN `pq_t6_rc` → sender が 1 トランザクションで `NOTIFY pq_t6_rc, 'one'` / `'two'` / `'three'`
      （`:656-659` の 1 tx 複数 NOTIFY の形）→ `_wait_notifications(listener, 1, 5000)` が 1 件（payload `one`）→ `assert_equal(len(listener._pending), 2)`（`two`, `three`。Mojo にアクセス制御は無いので直接読める）→
      `listener._restore_collected(got)`（`got` は返ってきた 1 件のリスト）→ `len(listener._pending) == 3` かつ payload 順 `one` / `two` / `three` →
      `_notifications(listener)` が **3 件を同じ順で返す**（公開 API での観測）→ 境界値: `listener._restore_collected(List[Notification]())`（空）の後 `_notifications` が 0 件のまま（`_pending` 不変、例外なし）。
      既存 `test_wait_notifications_keeps_collected_ones_*`（`:981,1005`）は期待値不変で PASS
    - (c) **E1（案 A。決めた事項 1）**: README「既知の制限」に 2 行 — 「examples / bench の出力先（パイプ）が先に閉じると、Mojo の `print` は SIGPIPE の既定動作で終了コード **141** になる
      （`head` に繋ぐ用途の Unix 標準挙動。`cat` / `grep` と同じ）。`examples/bench_psycopg.py` だけは Python 公式手順で検知して終了コード 1 を返す（非対称は意図的）」の趣旨。コード変更 0
    - (d) `pixi.toml:27` の `db-up` を `docker compose -f tests/docker-compose.yml up -d --wait --wait-timeout 180` に（P11。開発機 compose v5.5.0 に `--wait-timeout` あり: `docker compose up --help`）。
      `pixi run db-reset` が rc 0（陽性対照は任意: `--wait-timeout 1` で rc≠0）
    - (e) `.gsd-lite/TRACE.md` を新設（決めた事項 12 の節立て）。「チェックリスト（turn N）」節に `turn-002-checklist.sh` の生出力、「`check` の所要」節に基線
    - (f) `pixi run mojo run -I src tests/test_notify.mojo` と `tests/test_async.mojo` が PASS（両方 54317）、`pixi run test` 両サーバー PASS、`pixi run package` 警告ゼロ、`pixi run check` 6/6 PASS
      （所要を `date -Iseconds` で挟んで単位付きで PROGRESS に）。チェックリストの T1 行（`async_restore_collected_*` / `test_notify_*` / `readme_sigpipe` / `readme_rc_141` / `pixi_db_up_wait_timeout` / `trace_*`）が期待値
  - 対象: `src/pq/async_conn.mojo`, `tests/test_notify.mojo`, `README.md`（既知の制限のみ）, `pixi.toml`（`db-up` のみ）, `.gsd-lite/TRACE.md`
  - 依存: なし
  - 並列サブ作業: サブエージェント **0 本（親が全部）**（src 10 行 + テスト 1 件 + 文書 2 行）

- [x] T2: `pixi.toml` の `[package]`（pixi-build-mojo）+ `pixi build` + 利用側 smoke 2 経路（A1〜A4）
  - 完了基準:
    - (a) `pixi.toml` に RESEARCH §2.1 の差分（決めた事項 3）: `[workspace]` に `preview = ["pixi-build"]`（`platforms` の次の行）、末尾に `[package]`（`name = "pq"`, `version = { workspace = true }`）、
      `[package.build]`（backend `pixi-build-mojo` `0.2.*` + channels 2 つ）、`[package.build.config.pkg]`（`name = "pq"`, `path = "src/pq"`）、
      `[package.host-dependencies]` / `[package.build-dependencies]` / `[package.run-dependencies]` に `mojo-compiler = ">=1.1.0,<1.2"`、run に `libpq = ">=14"`。各節に 1 行コメント（preview 機能であること、`pkg` を明示する理由 = auto-derive は `src/pq` を見つけない）。
      `description` / `license` の `{ workspace = true }` 継承は**任意**（足して `pixi build` が通れば残す。通らなければ外して PROGRESS に 1 行）
    - (b) `.gitignore` に `dist/` を追加。`pixi build -o dist` rc 0、`ls dist/pq-0.1.0-*.conda` が **1 個**（P1）。`python3 -c "import zipfile,sys; print(zipfile.ZipFile(sys.argv[1]).namelist())" dist/pq-0.1.0-*.conda`
      で `metadata.json` / `pkg-*.tar.zst` / `info-*.tar.zst` の 3 エントリ。`pkg-*.tar.zst` の中身は `pixi exec --spec zstd zstd -d -c <pkg-*.tar.zst> | tar -t` で **`lib/mojo/pq.mojoc` を含み `examples/` `tests/` `hello.mojo` を含まない**（A3 / P2。
      zip から取り出すのも python3 の `ZipFile.extract`）
    - (c) `pixi install --locked` rc 0 かつ `git diff --quiet main -- pixi.lock` rc 0（P3。lock を**コミットしない**。変わっていたら feature を落としていないか先に疑う）。`pixi workspace version get` = `0.1.0`、`grep -c '^version = "' pixi.toml` = 1（P4）。
      `pixi run package` / `pixi run check` が従来どおり PASS（A4）
    - (d) **ここで一度コミット**（git 経路の smoke は committed な木を参照するため）。その後 A2 の 2 経路を `.gsd-lite/logs/phase6-packaging-ci/scratch/` 配下で実測（`turn-001-consumer-*` の `pixi.toml` + `main.mojo` を雛形に）:
      - git 経路 `turn-NNN-consumer-git/`: `pq = { git = "file:///home/parallels/workspaces/mojo-apps/pgcon", branch = "gsd-lite/phase6-packaging-ci" }`、`preview = ["pixi-build"]`、channels `conda.modular.com/max` + `conda-forge`。
        `pixi run smoke`（`mojo run main.mojo`）の出力に `pq import OK` と `expected failure: PgError(kind=Connection` があり **`LibpqLoad` が無い**
      - ダウンロード経路 `turn-NNN-consumer-dl/`: `dist/*.conda` を `turn-NNN-dl-channel/linux-aarch64/` にコピー → `pixi exec --spec rattler-index rattler-index fs <turn-NNN-dl-channel>` → 利用側 channels 先頭に `file://<そのパス>`、`pq = "==0.1.0"`、`preview` 不要。
        同じ smoke が同じ出力。`pixi list` に `pq 0.1.0`
      - 2 経路の出力ログを `scratch/turn-NNN-consumer-{git,dl}.log` に残し、TRACE「受け入れ基準対応表」の A2 に転記（verify は PR 後に GitHub の URL で git 経路を再実測: RESEARCH §6）
    - (e) チェックリストの T2 行（`pixi_preview` / `pixi_package_section` / `pixi_version_*` / `pixi_pkg_*` / `pixi_backend_mojo` / `pixi_mojo_compiler` = 3 / `pixi_run_dep_libpq` = 2 / `gitignore_dist` / `pixi_lock_changed_vs_main` = 0）が期待値。
      所要（`check` / `pixi build` 初回・2 回目 / smoke 2 経路）を単位付きで PROGRESS に
  - 対象: `pixi.toml`, `.gitignore`, `.gsd-lite/TRACE.md`, `.gsd-lite/logs/phase6-packaging-ci/scratch/turn-NNN-consumer-*`（gitignore 対象）
  - 依存: T1
  - 並列サブ作業: サブエージェント **0 本（親が全部）**（manifest 1 ファイル + 実測）

- [x] T3: `.github/workflows/ci.yml`（3 OS × 1 ジョブ `check`）+ `.github/scripts/{retry.sh, macos-postgres.sh, blackhole.py}`（B1〜B5 / B7 の静的部分）
  - 完了基準:
    - (a) `ci.yml`（決めた事項 4〜7）: `name: CI`、`on: pull_request: branches: [main]` / `push: branches: [main]`、先頭 `permissions: contents: read`、
      `concurrency: { group: ci-${{ github.ref }}, cancel-in-progress: true }`、ジョブ `check`（`name: check (${{ matrix.os }})`、`runs-on: ${{ matrix.os }}`、`timeout-minutes: 45`、
      `strategy: { fail-fast: false, matrix: { os: [ubuntu-latest, ubuntu-24.04-arm, macos-latest] } }`）。ファイル先頭のコメントに **Windows ジョブを置かない理由**
      （HANDOFF §2:34 の文言「Mojo のネイティブツールチェーンが未提供」。英語で可）と「fork からの PR は secrets 不要で動く想定（未検証）」（P24）。
      ステップ（順に）: `actions/checkout@v7` → `prefix-dev/setup-pixi@v0.11.2`（`pixi-version: v0.82.0`, `locked: true`, `cache: true`, `run-install: false`）→
      `bash .github/scripts/retry.sh 3 15 pixi install --locked` → **Linux だけ**（`if: runner.os == 'Linux'`）`bash .github/scripts/retry.sh 3 15 docker compose -f tests/docker-compose.yml pull` → `pixi run db-up` →
      **macOS だけ**（`if: runner.os == 'macOS'`）`bash .github/scripts/macos-postgres.sh`（env `HOMEBREW_NO_AUTO_UPDATE=1` / `HOMEBREW_NO_INSTALL_CLEANUP=1`）→
      `nohup python3 .github/scripts/blackhole.py 54399 > "$RUNNER_TEMP/blackhole.log" 2>&1 &`（+ `sleep 1` + python3 で 127.0.0.1:54399 に connect できることの確認。**stdout / stderr をファイルに向ける**: パイプを握ったままだとステップが終わらない）→
      全 OS `pixi run check`（macOS だけ `env: PQ_TEST_CONNINFO: host=127.0.0.1 port=5432 user=pq password=pq dbname=pq_test`。`if: always()` は付けない）→
      `bash .github/scripts/retry.sh 3 15 pixi build -o dist` → `ls -l dist` → `actions/upload-artifact@v7`（`name: pq-conda-${{ matrix.os }}`, `path: dist/*.conda`, `if-no-files-found: error`）→
      `if: always()` で `actions/upload-artifact@v7`（`name: final-check-log-${{ matrix.os }}`, `path: build/final_check.log`, `if-no-files-found: warn`。verify がログを読むため）
    - (b) `retry.sh`: `bash .github/scripts/retry.sh <tries> <sleep_sec> <cmd...>`。成功で即 rc 0、全失敗で最後の rc を返し `retry: giving up after N tries` を stderr に。bash 3.2 互換（配列不使用）。
      ローカル陽性対照: `pixi run bash .github/scripts/retry.sh 2 1 false` が rc≠0 かつ 2 回試行、`... 2 1 true` が rc 0
    - (c) `macos-postgres.sh`（RESEARCH §2.8 / 決めた事項 6。bash 3.2、`set -euo pipefail`）: `brew install postgresql@17`（`retry.sh 3 30` で包む）→ `PGBIN="$(brew --prefix postgresql@17)/bin"`、`PGDATA="$(brew --prefix)/var/postgresql@17"`
      （`PG_VERSION` が無ければ `initdb -D "$PGDATA"`）→ `pg_ctl -D "$PGDATA" -l "$RUNNER_TEMP/pg.log" -o "-p 5432" -w -t 60 start` → trust のまま TCP で
      `psql -h 127.0.0.1 -p 5432 -d postgres -c "CREATE ROLE pq SUPERUSER LOGIN PASSWORD 'pq'" -c "CREATE DATABASE pq_test OWNER pq"` →
      `psql "host=127.0.0.1 port=5432 user=pq password=pq dbname=pq_test" -f tests/fixtures/schema.sql` → `pg_hba.conf` の `^host` 行末 `trust` を `scram-sha-256` に（`sed -i '' -E`。BSD sed）→ `pg_ctl -D "$PGDATA" reload` →
      陽性対照 2 つ: 正しいパスワードで `select 1` が rc 0、`password=WRONG` が rc≠0 **かつ** stderr に `password authentication failed`（無ければ `exit 1`。P6）。
      各段を `echo "== ..."` で区切る（所要の目安を verify が読む。P7）
    - (d) `blackhole.py`（RESEARCH §2.9 案 B）: `sys.argv[1]` のポートで `127.0.0.1` に bind、`SO_REUSEADDR`、`listen(16)`、accept したソケットを `held` リストに**保持し続ける**（閉じない。P8）。応答は書かない。
      ローカル陽性対照（docker の blackhole と衝突しないポート、例 54398）: `python3 .github/scripts/blackhole.py 54398 > scratch/turn-NNN-blackhole.log 2>&1 &` → python3 で connect → `settimeout(0.5)` → `recv(1)` が **`socket.timeout`**（EOF の `b''` ではない）→ kill。
      結果を TRACE に 1 行
    - (e) 静的検査: `pixi exec --spec actionlint actionlint .github/workflows/ci.yml` が指摘 0、`pixi run bash -n` 3 スクリプト rc 0、`python3 -m py_compile blackhole.py` rc 0。
      grep: `timeout-minutes` ≥ 1 / `permissions:` ≥ 1 / `secrets.` = 0 / `branches: [main]` = 2（P14 / P15）。`tests/final_check.sh` / `run_tests.sh` は**触らない**（P10。チェック `tests_sh_bash4_only` = 0）
    - (f) `pixi run check` 6/6 PASS（Mojo 側は不変だが最終判定コマンドなので回す）。チェックリストの T3 行（`wf_ci_exists` 〜 `blackhole_held`）が期待値
  - 対象: `.github/workflows/ci.yml`, `.github/scripts/retry.sh`, `.github/scripts/macos-postgres.sh`, `.github/scripts/blackhole.py`, `.gsd-lite/TRACE.md`
  - 依存: T2
  - 並列サブ作業: サブエージェント **1 本（親を除く）**。インターフェースは決めた事項 6〜7（引数・env・ポート・終了コード）で固定済み:
    - A: `.github/scripts/retry.sh` + `macos-postgres.sh` + `blackhole.py` の 3 本と (b)(c)(d) のローカル陽性対照（対象: `.github/scripts/*`。**ci.yml は触らない**）
    - 親: `ci.yml` + (e)(f) + TRACE

- [x] T4: `.github/workflows/release.yml` + `.github/scripts/{check-tag-version.sh, release-notes.py}` + `CHANGELOG.md`（C1 / C2 / C4。C3 は CI artifact で verify）
  - 完了基準:
    - (a) `release.yml`（決めた事項 8〜10）: `name: Release`、`on: push: tags: ["v*"]` + `workflow_dispatch:`（入力なし。**dispatch = build までの dry run**。既定ブランチにマージ後しか起動できない: P13）、
      先頭 `permissions: contents: read`、ジョブ 3 つ:
      ① `verify-version`（`ubuntu-latest`、`timeout-minutes: 10`）: checkout → setup-pixi（T3 と同じ入力）→ `bash .github/scripts/check-tag-version.sh "$GITHUB_REF_NAME"`
      （**タグのときだけ**: `if: github.ref_type == 'tag'` のステップ。dispatch ではスキップ）→ `python3 .github/scripts/release-notes.py "$(pixi workspace version get)" > notes.md` → `test -s notes.md`（P17）
      ② `build`（`needs: verify-version`、matrix 3 OS、`fail-fast: false`、`timeout-minutes: 45`）: checkout → setup-pixi → `retry.sh 3 15 pixi install --locked` → `retry.sh 3 15 pixi build -o dist` → `ls -l dist` →
      `upload-artifact@v7`（`name: release-conda-${{ matrix.os }}`, `path: dist/*.conda`, `if-no-files-found: error`）
      ③ `release`（`needs: build`、`if: github.ref_type == 'tag'`、`ubuntu-latest`、`timeout-minutes: 15`、**このジョブだけ** `permissions: contents: write`）: checkout → setup-pixi →
      `actions/download-artifact@v7`（`pattern: release-conda-*`, `path: dist`, `merge-multiple: true`）→ 添付名の重複検査 `ls dist/*.conda | xargs -n1 basename | sort | uniq -d` が空でなければ `exit 1`
      （P5。衝突したら人間が `-<subdir>` 改名を足す。メッセージにそう書く）→ `VERSION="${GITHUB_REF_NAME#v}"` で `git archive --format=tar.gz --prefix="pq-$VERSION/" -o "pq-$VERSION.tar.gz" HEAD` →
      `python3 .github/scripts/release-notes.py "$VERSION" > notes.md` → `gh release create "$GITHUB_REF_NAME" --title "pq $GITHUB_REF_NAME" --notes-file notes.md dist/*.conda "pq-$VERSION.tar.gz"`
      （`env: GH_TOKEN: ${{ github.token }}`。P16）。`secrets.` 参照なし
    - (b) `check-tag-version.sh <tag>`: `pixi workspace version get` と `${tag#v}` を比較、一致で rc 0、不一致で `tag v0.2.0 != pixi.toml version 0.1.0` を stderr に出して rc 1（C2）。
      ローカル: `pixi run bash .github/scripts/check-tag-version.sh v0.1.0` rc 0、`... v0.2.0` rc 1、`... 0.1.0`（`v` 無し）rc 1（境界値）
    - (c) `release-notes.py <version>`: `CHANGELOG.md` の `## [<version>]` 見出しの次の行から、次の `## [` 見出しまたは `[x.y.z]: ` 形式のリンク定義行の手前までを stdout に出す。節が無い / 本文が空なら stderr にメッセージ + rc 1（P17）。
      ローカル: `python3 .github/scripts/release-notes.py 0.1.0` が非空で先頭が `### ` 見出し、`... 9.9.9` が rc 1
    - (d) `CHANGELOG.md`（決めた事項 11）: Keep a Changelog 1.1.0 の冒頭定型（`keepachangelog.com` へのリンク + SemVer）、`## [Unreleased]`（空）、`## [0.1.0] - 2026-10-18` に `### Added` で Phase 1〜5 の成果を 1 Phase 1〜3 行
      （`archive/phase{1..5}-*/REQUIREMENTS.md` §1 目的と README「概要」から: 同期接続 / パラメータ・プリペアド・トランザクション / バイナリ 19 型 / 非同期・cancel・LISTEN-NOTIFY / bench・README・LICENSE。
      末尾に `[Unreleased]: https://github.com/6in/mojo-pg/compare/v0.1.0...HEAD` と `[0.1.0]: https://github.com/6in/mojo-pg/releases/tag/v0.1.0`）。「Phase N」の語を各行に含める（`changelog_phase_lines` ≥ 5）
    - (e) 静的検査: `pixi exec --spec actionlint actionlint .github/workflows/release.yml` 指摘 0、`pixi run bash -n check-tag-version.sh` rc 0、`py_compile release-notes.py` rc 0。
      grep: `contents: write` = 1（release ジョブのみ）、`timeout-minutes:` ≥ 3、`secrets.` = 0、`github.ref_type == 'tag'` ≥ 1
    - (f) `pixi run check` 6/6 PASS。チェックリストの T4 行 + 全体行（`workflows_files` = 2 / `all_*`）が期待値
  - 対象: `.github/workflows/release.yml`, `.github/scripts/check-tag-version.sh`, `.github/scripts/release-notes.py`, `CHANGELOG.md`, `.gsd-lite/TRACE.md`
  - 依存: T3（`retry.sh` と setup-pixi の入力を揃える）
  - 並列サブ作業: サブエージェント **1 本（親を除く）**:
    - A: `CHANGELOG.md`（対象: `CHANGELOG.md` のみ。形式と見出しは決めた事項 11 を「必ず満たす 1 行」として渡す。`archive/*/REQUIREMENTS.md` を読んで要約）
    - 親: `release.yml` + 2 スクリプト + (b)(c)(e)(f)

- [x] T5: README（英語の概要 + インストール節 / 日本語インストール節の pixi 依存指定 / CI 小節 / ブランチ保護手順 / Windows 理由 / リリース手順）（D1〜D4、B7 の README 側）
  - 完了基準:
    - (a) 先頭の日本語段落（`README.md:1-5`）の直後に **`## English summary and install`** を 1 節（英語。決めた事項 13）: 2〜4 文の概要（libpq FFI、sync / async / binary / LISTEN-NOTIFY、Mojo 1.1.0、Linux + macOS、Windows untested）+
      インストール 2 経路のコード片 — (1) `pixi.toml` の `[dependencies]` に `pq = { git = "https://github.com/6in/mojo-pg.git", tag = "v0.1.0" }`（`[workspace]` に `preview = ["pixi-build"]`、channels `https://conda.modular.com/max` + `conda-forge` が必要と 1 文）、
      (2) Release の `.conda` を `<dir>/<subdir>/` に置いて `pixi exec --spec rattler-index rattler-index fs <dir>` → channels 先頭に `file://<dir>`、`pq = "==0.1.0"`（P18: 実測した 2 経路だけ。`url =` 依存は書かない）。
      `from pq import Connection` の 3 行の例
    - (b) 日本語「インストール」節（`:26-41`）: 「自分のプロジェクトから使う」を (a) と同じ 2 経路 + 既存の `-I src`（開発時）の 3 つに拡充。順序は git 依存 → Release `.conda` → `-I src`。git 依存はビルドに数十秒〜数分 + ネットワークが要ること、
      `.conda` はビルド無しであることを各 1 文。`pixi run package`（`.mojoc`）は「配布手段ではない」と 1 文（REQ §2.1）
    - (c) 「テストの回し方」（`:344-368`）に **`### CI`** 小節: ワークフロー `ci.yml` のトリガー（PR → main / push main）、ジョブ 3 つの表（`check (ubuntu-latest)` / `check (ubuntu-24.04-arm)` / `check (macos-latest)`: 何が回るか、
      Linux = compose 3 台 + `pixi run check`、macOS = brew `postgresql@17` 1 台 + Python の blackhole + 同じ `pixi run check`、PG 14 は Linux だけ、leak の RSS 検査は macOS で SKIP）、待ち上限
      （ジョブ 45 分 / compose `--wait-timeout 180` 秒 / `pg_ctl -w -t` **60 秒**）、各ジョブが `pixi build` の `.conda` を artifact `pq-conda-<os>` に置くこと、Windows ジョブが無い理由（HANDOFF §2 の文言）、
      fork からの PR は secrets 不要で動く想定だが未検証（P24）、`release.yml` の `workflow_dispatch` は build までの dry run（マージ後に使える）
    - (d) **ブランチ保護の手順**（D4 / D13。CI 小節の末尾か独立小節 `### ブランチ保護（人間が設定）`）: 画面（Settings → Branches → Add rule → Require status checks）と `gh api` の両方。`gh api` 例は
      `gh api -X PUT repos/6in/mojo-pg/branches/main/protection --input protection.json` + `protection.json`（`required_status_checks.contexts` に上のジョブ名 3 つ、`enforce_admins` / `required_pull_request_reviews` / `restrictions` は `null` か最小）。
      「無人ターンは設定しない」と 1 文
    - (e) **リリース手順（人間向け）**: `CHANGELOG.md` の該当版の節を書く → `pixi.toml` の `version` を上げる → `git tag v0.1.0` → `git push origin v0.1.0` → `release.yml` が 3 OS の `.conda` + `pq-0.1.0.tar.gz` を Release に添付、本文は CHANGELOG の節。
      タグと `version` の不一致は `verify-version` ジョブで失敗（C2）。modular-community への recipe 提出は「将来の経路」と 1 行（RESEARCH §1.8）
    - (f) 「概要と対応環境」の OS 行（`:13`）に「CI: Linux x86_64 / aarch64 / macOS arm64」を足す。既存の「6 段」「3 つです」「未検証」「`-I src`」は残す（チェック不変行）
    - (g) README の全コマンドは実測した形だけ（P18）。`pixi run check` 6/6 PASS（README は `check` の対象外だが最終判定）。チェックリストの T5 行（`readme_*`）が期待値（`readme_h2` = 11）
  - 対象: `README.md`, `.gsd-lite/TRACE.md`
  - 依存: T4（CHANGELOG / release.yml / ジョブ名が確定してから）
  - 並列サブ作業: サブエージェント **0 本（親が全部）**（1 ファイル）

- [x] T6: 統合（クリーン状態からの最終判定 + lock 不変 + チェックリスト全行 + TRACE 受け入れ基準対応表 + branch push）
  - 完了基準:
    - (a) `pixi run db-reset` → `pixi run check` **6/6 PASS**（所要 ≤ 247 s。`date -Iseconds` で挟む。P21）、`pixi run package` 警告ゼロ、`pixi build -o dist` rc 0（`.conda` 1 個）、`pixi install --locked` rc 0、
      `git diff --quiet main -- pixi.lock` rc 0（P3）、`mojo format` 差分なし（`check` 1/6 段）
    - (b) `pixi exec --spec actionlint actionlint .github/workflows/*.yml` 指摘 0。チェックリスト **全行**が期待値（生出力を TRACE「チェックリスト（turn N）」節に。差分が出た行は PLAN 訂正として TRACE に）
    - (c) TRACE「受け入れ基準対応表」: REQ §4 の A1〜F2 の各項目に「どのタスク / どの証跡（ログ名・grep・CI 待ち）で満たすか」を 1 行ずつ。**CI 依存の項目（B2 / B3 / B4 / B6 / C3 / F の CI 側）は「verify の PR で確認」と明記**し、
      impl が確認できた静的部分（YAML の存在・grep）を分けて書く
    - (d) PROGRESS の最新ターン節が 40 行以内（検証コマンド節の python3 ワンライナー）
    - (e) `git status` clean → `git push -u origin gsd-lite/phase6-packaging-ci` → `git status -sb` に `ahead` が無い。`gh run list --branch gsd-lite/phase6-packaging-ci --limit 5` が **0 件**（push では CI が走らない = P15 の陽性対照。
      走っていたら `on:` を見直す）。**PR は作らない**（verify の仕事。REQ §2.2c / D8）
    - (f) PROGRESS「次への注意」に verify 向けの申し送り: PR 作成 → `gh pr checks <PR> --watch`（上限 40 分）、3 artifact `pq-conda-*` のファイル名を VERIFICATION に写す（P5）、macOS ジョブの `skipped` 行の内訳（leak のみが正。
      `test_connect_blocking_times_out` は PASS が正）、A2 の git 経路を `https://github.com/6in/mojo-pg.git` + `branch = "gsd-lite/phase6-packaging-ci"` で別ディレクトリから再実測、2 回目の run で setup-pixi の `Cache restored`（P12）
  - 対象: `.gsd-lite/TRACE.md`, `.gsd-lite/PROGRESS.md`（コード変更なし。差分が出たら該当タスクの対象ファイル）
  - 依存: T5
  - 並列サブ作業: サブエージェント **0 本（親が全部）**

- [x] F1: setup-pixi の入力を `run-install: false` と両立する形に直す（`cache: false` を明示し `locked: true` を外す。ci.yml 1 箇所 + release.yml 3 箇所）+ コメント + PLAN 訂正（verify round 1 / VERIFICATION §1）
  - 背景: PR #1 の CI run `39090199560` で 3 ジョブとも `prefix-dev/setup-pixi@v0.11.2` が 5〜9 s で `##[error]Cannot cache without running install`。setup-pixi v0.11.2 `src/options.ts:207-217` は
    `runInstall === false` のとき **`cache === true` と `locked === true` の両方**を拒否する。`cache` の既定は true（`action.yml`）なので省略では直らず、`cache` だけ直すと次は
    `Cannot use \`locked: true\` when not running install` で落ちる。設計は **A = 手動 install 維持**（REQ §2.5 のリトライを `retry.sh 3 15 pixi install --locked` で満たす）。
    B（action に install させて `locked` / `cache` を残す）は install にリトライが付かないので採らない（VERIFICATION §1 に理由）
  - 完了基準:
    - (a) `.github/workflows/ci.yml` と `.github/workflows/release.yml` の **4 箇所**の `prefix-dev/setup-pixi@v0.11.2` の `with:` を `pixi-version: v0.82.0` / `cache: false` / `run-install: false` の 3 行にする
      （`locked: true` と `cache: true` の行を削除。lock の強制は既存の `bash .github/scripts/retry.sh 3 15 pixi install --locked` ステップが担う。`verify-version` / `release` ジョブは install を呼ばないので入力だけ揃える）
    - (b) `ci.yml:50-53` のコメント（"`cache: true` still keys off pixi.lock, and the locked input makes a stale lock fail here"）を実態に書き換える: 「setup-pixi は run-install を切ると cache / locked を受け付けない（v0.11.2 `options.ts`）。
      lock の強制は次の retry.sh ステップの `--locked`、環境キャッシュは使わない（毎 run で取得。+1〜3 分の見込み）」の趣旨。**key のパターン文字列（`locked: true` / `run-install: false` / `cache: true` / `cache: false`）をコメント・見出しに書かない**（turn 5 / 6 の再発防止）
    - (c) TRACE「PLAN 訂正（turn 10）」に 2 行: ① チェックリスト `ci_locked_true` の期待値 **1 → 0**（PLAN:82 の表・決めた事項 5・T3 (a) の `locked: true` / `cache: true` は F1 で無効）、
      ② TRACE「verify への申し送り」5（2 回目の run で `Cache restored`）は無効 = キャッシュを使わない。PLAN 決めた事項 5 の `locked: true`、`cache: true` の語を `cache: false`（`locked` なし）に直す
    - (d) 期待結果（**この表だけが正**。本文・テストはこれを参照する）:

      | 条件 | 結果 |
      |---|---|
      | `pixi exec --spec actionlint actionlint .github/workflows/ci.yml .github/workflows/release.yml` | 指摘 0 |
      | `grep -c 'cache: false' .github/workflows/ci.yml` / `… release.yml` | 1 / 3 |
      | `grep -c 'cache: true'` と `grep -c 'locked: true'`（2 本とも） | 0（grep の rc 1 が正） |
      | checklist `ci_run_install_false` / `ci_setup_pixi_pinned` / `ci_pixi_version` | 1 / 1 / 1（不変） |
      | checklist `ci_locked_true` | **0**（PLAN 訂正 ①） |
      | checklist の他の全行 | turn 9 のログ（`scratch/turn-009-checklist.log`）と同値（`trace_checklist_section` は +1 可） |
      | `pixi run check` | 6/6 PASS（Mojo 側不変だが最終判定コマンド。所要 ≤ 247 s） |
      | push 後 `gh run list --branch gsd-lite/phase6-packaging-ci --limit 3` | PR #1 由来の新しい run が 1 件増える |
      | その run の `gh run view <run-id>` | 3 ジョブとも `Run prefix-dev/setup-pixi@v0.11.2` が ✓（**全ジョブの完了は待たない**。緑 / 赤の判定は verify round 2） |

    - (e) `git status` clean（`__pycache__` / `dist/` / `build/` は無いか gitignore）→ commit → `git push origin gsd-lite/phase6-packaging-ci`（既存 PR #1 に載る。PR は作らない）→ 上の表の最後の 2 行
  - 対象: `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `.gsd-lite/TRACE.md`, `.gsd-lite/PLAN.md`（決めた事項 5 と表 `:82` の語句のみ）
  - 依存: T6
  - 並列サブ作業: サブエージェント **0 本（親が全部）**（YAML 4 箇所 + コメント + 文書）

- [x] F2: macOS の poll セマンティクス（`POLLHUP` と `POLLOUT` が排他）に合わせる — `wait_readable` / `wait_writable` のハングアップ分岐を「libpq に原因を言わせる」形にし、`test_poll` の socketpair 期待値を Linux 限定にする（verify round 2 / VERIFICATION §0）
  - 背景: PR #1 の run `39091056281` で Linux 2 ジョブは緑、**macOS だけ `pixi run check` 5/6 段で 2 テスト赤**（`final-check-log-macos-latest`。`scratch/turn-011-macos-artifact/final_check.log`）:
    ① `tests/test_async.mojo:1613` `test_connect_failures_name_their_cause` — 127.0.0.1:1 への接続拒否で `wait_writable` が **`connection socket closed (POLLHUP/POLLERR)`** を投げ、libpq の `Connection refused` が出ない。
    macOS の poll(2) は接続拒否を `POLLHUP`（`POLLOUT` 無し）で報告するので `async_conn.mojo:787-793` の「要求方向のビット無し + hangup」分岐に入る（Linux は `POLLOUT` を伴うので `:787` で return し、次の `PQconnectPoll` が原因を名乗る）。
    ② `tests/test_poll.mojo:215` `test_socketpair_peer_close_sets_hangup_both_ways` — ピア close 後の書き側 poll で `writable` が False。POSIX は `POLLHUP` と `POLLOUT` を排他と定め、macOS はそれに従う（Linux は socket で両方立てる: Phase 4 RESEARCH §2.3 の実測 `20 = POLLOUT|POLLHUP`）。
    `poll_socket` 自体は flags をそのまま返しているので正しく、**テストの期待値が Linux 固有**。
    採る設計は **A = ライブラリ側で「hangup / error だけ」を ready として返し、次の libpq 呼び出し（`PQconnectPoll` / `PQconsumeInput` / `PQflush`）に本当の原因を言わせる**（Phase 4 RESEARCH §4 P5「libpq の切断メッセージの方が親切」と同じ方針。
    `POLLHUP` 単独は全 OS で正当な報告なので OS 分岐にしない）。B = ライブラリに `CompilationTarget.is_macos()` 分岐（同じ状態を OS で違う種類に分けるだけ）、C = `test_async` の期待値を macOS で緩める（REQ §2.5「CI だけ緩めない」に反し、テスト名「原因を名乗る」の意図も失う）は採らない（VERIFICATION §0 に理由）
  - 完了基準:
    - (a) `src/pq/async_conn.mojo` の `wait_readable`（`:748-760`）/ `wait_writable`（`:781-793`）: poll が `hangup` / `error` を報告し要求方向のビットが無いとき、**raise せず return する**（`timeout` → `TIMEOUT`、`fd < 0` → `CONNECTION "no socket"`、`USAGE` は不変）。
      汎用メッセージ `connection socket closed (POLLHUP/POLLERR)` は **src から消える**（grep 0）。両 docstring の本文と `Raises:` を実態に直す（「hangup / error だけでも返る。切断の理由は次の libpq 呼び出しが名乗る（`PQconnectPoll` の `Connection refused`、`PQconsumeInput` の
      `server closed the connection unexpectedly`）」の趣旨。`CONNECTION` は「socket が無い」のときだけ）。`src/pq/__init__.mojo:290` の表（`TIMEOUT`, `CONNECTION`, `USAGE`）は**そのまま正しい**ので触らない
    - (b) 呼び出し側 3 箇所（`_poll_to_ready` `:834-838` / `_wait_for` `:1473-1477` / `_collect_notifications` `:1665-1671`）が、return 後の次の libpq 呼び出しで失敗を報告し busy loop にならないことをコードレビューで確認し、根拠を TRACE「F2」節に各 1 行
      （`PQconnectPoll` は `SO_ERROR` を読んで `PGRES_POLLING_FAILED`、`PQconsumeInput` は `recv` 0 / -1 で 0 を返す、`PQflush` は send 失敗で -1）。コード変更はしない見込み
    - (c) `tests/test_poll.mojo:207-216`: `hangup` の 2 つの assert は両 OS 共通のまま、**`assert_true(writable.writable)` は Linux だけ**（`test_leak.mojo:77,787` と同じ `from std.sys.info import CompilationTarget` + `CompilationTarget.is_linux()`。
      コメントに「POSIX は POLLHUP と POLLOUT を排他と定義、Linux は socket で両方立てる」の趣旨）。macOS 側では `writable` を assert しない（将来の変更に追従させない）。テスト数 11 不変、`readable.readable` / `readable.hangup` は不変
    - (d) 新しいテストファイル / 新しい型・API は足さない。(a) の受け入れは **CI の macOS で `test_connect_failures_name_their_cause` が PASS すること**（Linux では `POLLOUT` を伴うため経路差なし）。ローカル（Linux）では既存テストの期待値変更 **0 件**で全 PASS
    - (e) 期待結果（**この表だけが正**。本文・テストはこれを参照する）:

      | 条件 | 結果 |
      |---|---|
      | `grep -c 'POLLHUP/POLLERR' src/pq/async_conn.mojo` | 0（grep の rc 1 が正） |
      | `grep -c 'is_linux' tests/test_poll.mojo` | ≥ 1 |
      | `pixi run mojo run -I src tests/test_poll.mojo` / `tests/test_async.mojo`（54317） | 11 PASS / 31 PASS（既存の期待値変更 0 件） |
      | `pixi run check`（`db-reset` の後） | 6/6 PASS、所要 ≤ 247 s、6/6 段 `matched lines: 0`、Linux 両サーバー `skipped 1` |
      | `pixi run package` | 警告 0 |
      | checklist `src_def_ref_return` / `test_file_count` / `async_*` 4 key | 0 / 24 / 不変（`trace_checklist_section` は +1 可、他の全行は `scratch/turn-011-checklist.log` と同値） |
      | push 後 `gh run list --branch gsd-lite/phase6-packaging-ci --limit 3` | PR #1 由来の run が 1 件増える（**全ジョブの完了は待たない**。緑 / 赤の判定は verify round 3） |
    - (f) `git status` clean → commit → `git push origin gsd-lite/phase6-packaging-ci`（**turn 10 / 11 の未 push コミット 2 つも一緒に載る**。run `39091056281` は完了済みなので cancel の心配はない）。PR は作らない
  - 対象: `src/pq/async_conn.mojo`（`wait_readable` / `wait_writable` の 2 メソッドのみ）, `tests/test_poll.mojo`（1 テスト）, `.gsd-lite/TRACE.md`
  - 依存: F1
  - 並列サブ作業: サブエージェント **0 本（親が全部）**（src 2 メソッド + テスト 1 件）

- [x] F3: `poll_connect` の最初の答えを `NEED_WRITE` に固定（libpq の「`PQconnectStart` 直後は `PGRES_POLLING_WRITING` とみなす」契約に揃える）+ `is_leaking` の一度きりの RSS ステップを形で除外（verify round 3 / VERIFICATION §R3。**verify_round 上限 = 次の verify で赤なら BLOCKED**）
  - 背景: PR #1 の run `39092567451`（コミット `f4bb693`）。F2 は効いた（macOS で round 2 の 2 テストは PASS、`test_poll` 11/11、aarch64 Linux 緑）が、別の 2 件:
    ① **macOS** `tests/test_async.mojo:1568` `test_multi_host_conninfo_reaches_the_second_host` — `could not receive data from server: Connection refused`（1.55 ms）。libpq は最初のホスト（port 1）の拒否を `CONNECTION_STARTED` の `getsockopt(SO_ERROR)` で見たときだけ次ホストへ乗り換える。
    `_poll_to_ready`（`async_conn.mojo:813`）もテスト補助（`test_async.mojo:660,683`）も **`start` 直後に待たずに `poll_connect` → `PQconnectPoll`** を呼ぶので、macOS（loopback の RST を別スレッドで処理）ではカーネルが拒否を記録する前に `SO_ERROR = 0` を読み、libpq は接続成功とみなして
    `CONNECTION_MADE` → 次の read で拒否が出て全体失敗（乗り換えなし）。round 2 は競合に勝って PASS（7.3 ms）。Linux は `connect()` 内で RST まで処理し終えるので常に `SO_ERROR` 経路。libpq 公式 docs: *If you have yet to call PQconnectPoll, i.e., just after the call to PQconnectStart, behave as if it last returned PGRES_POLLING_WRITING.*
    ② **x86_64 Linux** `tests/test_leak.mojo:931` `test_connect_query_close_does_not_leak` — `connect/query/close RSS pages: [6205, 6205, 6205, 6205, 6718, 6718, 6718, 6718, 6718]`。513 ページの**一度きりの段** + 平坦な尾 = `test_leak.mojo:148-170` が自ら書いている「任意の反復で出る一度きりのステップ」で、
    x86_64 GitHub ランナーではそれが 256 の許容を超えた（aarch64 ランナーは round 2 に 84 ページ、開発機は 1 ページ）。反復ごとの成長ではないのでリークではない
    採る設計: ① = **A: 公開 API `poll_connect` の最初の答えを常に `NEED_WRITE` にする**（`PQconnectPoll` を呼ばずに返す。`_poll_to_ready` / テスト補助 / 利用者コードは変更なしで libpq の順序に揃う）。B = `_poll_to_ready` だけ直す（利用者の手回しとテスト補助が残る）、C = テストを macOS で緩める（REQ §2.5）は採らない。
    ② = **A: `is_leaking` が「上昇 1 回だけ + その後 2 サンプル以上が段の値を超えない」系列を総成長の判定から外す**（大きさでなく形）。B = `TOLERANCE_PAGES` を上げる（`:151`「256 は恒久仕様」に反し、次の段で再発）、C = warmup を増やす（段は任意の反復で出る）は採らない（VERIFICATION §R3.1 に理由）
  - 完了基準:
    - (a) `src/pq/async_conn.mojo`: `AsyncConnection` に private フィールド 1 つ（例 `_connect_polled: Bool`、docstring 付き。`__init__` `:365-370` で `False`）。`poll_connect`（`:665`）は `_state == CONNECTING` かつ `not _setup_pending` で**初回**なら、フィールドを `True` にして `PQconnectPoll` を呼ばずに `PollState.NEED_WRITE` を返す。
      2 回目以降は従来どおり。docstring の「The first answer is not fixed -- libpq may want either direction…」（`:669-672`）を「最初の答えは常に `NEED_WRITE`: libpq は `PQconnectStart` の直後を `PGRES_POLLING_WRITING` が返ったものとして扱えと定める。先に `PQconnectPoll` を呼ぶと `SO_ERROR` をカーネルが拒否を記録する前に読み、
      拒否が次ホストへの乗り換えでなく次の read の失敗として出る（macOS で実測）」の趣旨に書き換える。`start` の docstring（`:429-431`）の「Drive it with `poll_connect`」はそのままで可。`src/pq/__init__.mojo:205` の説明は変更不要（「`start` then `poll_connect` until it answers READY」は依然正しい）。
      `wait_readable` / `wait_writable` / `_poll_to_ready` / `connect_blocking` は**触らない**
    - (b) `tests/test_async.mojo`: 既存 `test_manual_connect_polling`（`:1110-1130`）の最初の assert を **`step == PollState.NEED_WRITE`** に締め、コメント（`:1114-1115`「Which direction libpq wants first depends on…」）を契約の説明に直す（**既存テストの期待値の変更 1 件** — PROGRESS に列挙）。
      新テスト 1 件 `test_first_poll_connect_is_need_write_even_when_refused`: `_start("host=127.0.0.1 port=1 user=pq dbname=pq_test")` → `_poll_connect(conn) == PollState.NEED_WRITE`（**raise しない**。旧コードは Linux ではここで `SO_ERROR` 済みのため `CONNECTION` を raise する = Linux で観測できる陽性対照）→
      続けて `_poll_connect_to_failure(conn)` が `CONNECTION` で `Connection refused` を含む。テスト数 31 → **32**
    - (c) `tests/test_leak.mojo`: `is_leaking`（`:246-275`）に第 3 の規則を足す — 単調増加なら従来どおりリーク。総成長が許容を超えても、**上昇（`samples[i] > samples[i-1]`）がちょうど 1 回で、その後に 2 サンプル以上あり、いずれも `samples[i]` を超えない**なら「一度きりの段」としてリークでない。それ以外は従来どおり。
      docstring の 2 signals の説明に 3 つ目を追記し、`TOLERANCE_PAGES` の説明（`:148-170`）の「256 pages (1 MiB) clears two such steps」の段落を「段は大きさでなく形（1 段 + 平坦な尾）で除外する。x86_64 ランナーで 513 ページの段を実測（run `39092567451`）」の趣旨に更新。
      単体テスト 2 件追加（DB 不要）: `test_is_leaking_accepts_a_single_step_plateau`（`[100, 100, 100, 100, 613, 613, 613, 613, 613]`, tol 16 → False）、`test_is_leaking_detects_two_steps_beyond_tolerance`（`[100, 100, 300, 300, 300, 520, 520, 520, 520]`, tol 16 → True）。
      既存 4 件は**不変**（`[100, 100, 100, 120]` は段の後に 0 サンプルなので従来どおり True）。テスト数 18 → **20**。`ABORT_PAGES` / `_sample` / 各ループ本体は触らない
    - (d) 期待結果（**この表だけが正**。本文・テストはこれを参照する）:

      | 条件 | 結果 |
      |---|---|
      | `grep -c 'PGRES_POLLING_WRITING' src/pq/async_conn.mojo`（`poll_connect` docstring） | ≥ 1 |
      | `grep -c '^def test_' tests/test_async.mojo` / `tests/test_leak.mojo` / `tests/test_poll.mojo` | 32 / 20 / 11 |
      | `pixi run mojo run -I src tests/test_async.mojo`（54317） | 32 PASS（`test_manual_connect_polling` の締めた assert と新テストを含む） |
      | `pixi run mojo run -I src tests/test_leak.mojo`（54317。約 70〜80 s） | 20 PASS、`connect/query/close RSS pages:` の系列を TRACE「F3」節に写す |
      | `pixi run check`（`db-reset` の後） | 6/6 PASS、所要 ≤ 247 s、6/6 段 `matched lines: 0`、Linux 両サーバー `skipped 1` |
      | `pixi run package` | 警告 0 |
      | F2 / F1 の grep（VERIFICATION §R3.2 の表） | 数値不変（`POLLHUP/POLLERR` 0 / `is_linux` 1 / `cache: false` 1 + 3 / 旧 2 入力 0） |
      | checklist `src_def_ref_return` / `test_file_count` / `async_*` 4 key | 0 / 24 / 不変（`trace_checklist_section` は +1 可、他の全行は `scratch/turn-013-checklist.log` と同値） |
      | push 後 `gh run list --branch gsd-lite/phase6-packaging-ci --limit 3` | PR #1 由来の run が 1 件増える（**全ジョブの完了は待たない**。緑 / 赤の判定は verify round 4） |
    - (e) TRACE「F3」節: (a) の変更表、(b)(c) のテスト表、`test_leak` のローカル系列、「既存テストの期待値の変更 1 件」の明記。チェックリスト（turn 14）
    - (f) `git status` clean → commit → `git push origin gsd-lite/phase6-packaging-ci`（turn 13 の verify コミットも一緒に載る。run `39092567451` は完了済みなので `concurrency` の cancel の心配はない）。PR は作らない
  - 対象: `src/pq/async_conn.mojo`（フィールド 1 + `poll_connect` のみ）, `tests/test_async.mojo`（既存 1 件の締め + 新 1 件）, `tests/test_leak.mojo`（`is_leaking` + 設計説明 + 単体テスト 2 件）, `.gsd-lite/TRACE.md`
  - 依存: F2
  - 並列サブ作業: サブエージェント **0 本（親が全部）**（src 1 メソッド + テスト 3 件）

## 決めた事項

1. **E1 は案 A（README 明記のみ）**（REQ §2.3「plan が選ぶ」/ RESEARCH §2.13）。根拠: rc 141 は stdlib `print` が SIGPIPE 既定のまま write した結果で `cat` / `grep` と同じ Unix 標準挙動。案 B は `SIG_IGN` + 番兵 `write(2)` を
   examples 6 本に複製する必要があり（`_common.mojo` は `-I src` の経路に乗らない）、しかも `external_call["write"]` の署名を誤るとモジュールごとコンパイル不能（RESEARCH §0.5）。REQ §2.3「stdlib の挙動は変えない」にも案 A が近い。
   Phase 5 の格子 `turn-012-robust-regress.sh` の `> >(exit 0)` 軸の期待値 141 は**不変**
2. **E2 は `_restore_collected(mut self, collected: List[Notification])` ヘルパ**（RESEARCH §2.14 推奨形）。本体は現状 `async_conn.mojo:1632-1637` の 5 行（`out` → `_pending` の順の新リスト）。呼び出しは `notifications()` 側 `except`（`:1627`）と
   `wait_readable` 側 `except`（`:1656`）の 2 箇所、後者は `TIMEOUT` 以外**すべての kind**（REQ E2 の「`CONNECTION` 経路」は RESEARCH §5 の提案どおり広げて読む。`USAGE` も含む）。テストはヘルパ直叩き + `notifications()` 観測
   （経路は単一スレッドで到達不能: `close(PQsocket)` では `notifications()` 側が先に `CONNECTION` を投げる。`scratch/turn-001-notify-close.mojo`）
3. **`pixi.toml` の差分は RESEARCH §2.1 の最小 manifest + `version = { workspace = true }`**（`scratch/turn-001-pkg-inherit` で実測済み）。backend `pixi-build-mojo` `0.2.*`（0.2.8.20261014.1408 が 3 プラットフォームにある）、
   channels `https://prefix.dev/pixi-build-backends` + `https://prefix.dev/conda-forge`、`mojo-compiler = ">=1.1.0,<1.2"`（host / build / run）、run に `libpq = ">=14"`。パッケージ名 **`pq`**（D10。conda-forge / modular-community に同名なし: RESEARCH §1.7）。
   出力先 `pixi build -o dist`（`dist/` は gitignore）。`pixi.lock` は**不変**（RESEARCH §2.2）
4. **CI は 1 ワークフロー `ci.yml`、1 ジョブ `check` × matrix 3 OS、OS 差は `if: runner.os == ...` のステップ条件で**（ジョブを Linux / macOS に分けない）。ジョブ名は `check (ubuntu-latest)` / `check (ubuntu-24.04-arm)` / `check (macos-latest)`
   （matrix の既定命名と同じだが `name:` で固定。D4 の required checks の名前がこれ）。`fail-fast: false`（ExtraMojo）。`concurrency` で同一 ref の古い run を cancel（PR の連続 push で 3 ジョブ × 複数が走るのを防ぐ）
5. **アクションのバージョン**（RESEARCH §2.5、2026-10-18 時点の最新）: `actions/checkout@v7`、`prefix-dev/setup-pixi@v0.11.2`（`pixi-version: v0.82.0` = 開発機と同じ、`cache: false`、`run-install: false`。F1 の訂正: install を切ると action が cache / lock の入力を拒否する）、
   `actions/upload-artifact@v7`、`actions/download-artifact@v7`。第三者アクションはこの 4 つだけ（`softprops/action-gh-release` / `nick-fields/retry` / `ikalnytskyi/action-setup-postgres` は採らない: RESEARCH §3）
6. **リトライは `.github/scripts/retry.sh <tries> <sleep_sec> <cmd...>`**（bash の `for`。`uses:` は包めないので `run:` のネットワーク依存ステップ = `pixi install --locked` / `docker compose pull` / `brew install` / `pixi build` に当てる）。
   ジョブ `timeout-minutes: 45`（見込み 8〜13 分 + macOS brew 2〜4 分）、release の `verify-version` 10 分 / `release` 15 分
7. **macOS の PostgreSQL は `macos-postgres.sh` 1 本**（RESEARCH §2.8 / pgRouting）: brew `postgresql@17`、`PGDATA = $(brew --prefix)/var/postgresql@17`、`pg_ctl -w -t 60 start`、**trust のまま TCP でロール / DB / schema を作ってから** `pg_hba.conf` の
   `host` 行を `scram-sha-256` に書き換え `pg_ctl reload`（ソケットディレクトリに依存しない。research の `-h /tmp` 案は捨てる）、陽性対照は正パスワード rc 0 + `WRONG` が `password authentication failed`。
   `PQ_TEST_CONNINFO = "host=127.0.0.1 port=5432 user=pq password=pq dbname=pq_test"`（`key=value` 形式。`run_tests.sh:10-13`）。libpq は pixi 環境の conda 版（`PQ_MOJO_LIBPQ` 不要）。
   blackhole は `blackhole.py 54399`（`test_async.mojo:66` のポート固定）を `nohup … > file 2>&1 &` で別ステップで起動（stdout をファイルに向けないとステップが終わらない）。立てられなくてもテストは `SKIP … port 54399 refused`（`:1200`）で済む（B3 後段）
8. **release.yml は `verify-version` → `build`（3 OS）→ `release` の 3 ジョブ**（RESEARCH §2.12）。Release 作成は `gh release create --notes-file`（`gh` は 3 イメージ搭載。第三者アクション不要）。`permissions` は先頭 `contents: read`、`release` ジョブだけ `contents: write`。
   `workflow_dispatch` は入力なし = **build までの dry run**（`release` ジョブは `if: github.ref_type == 'tag'`）。dispatch は既定ブランチにファイルが無いと起動できない（P13）ので C3 は CI の `pq-conda-*` artifact で満たす
9. **タグと version の一致は `check-tag-version.sh <tag>`**（`pixi workspace version get` = `0.1.0` と `${tag#v}` の文字列比較。`[package] version = { workspace = true }` なので出所は 1 行: P4）。`v` 無しのタグは不一致扱い（`push.tags: ["v*"]` なので届かないが境界値として）
10. **CHANGELOG 抽出は `release-notes.py <version>`（python3）**（research の awk 案を python3 に変更: `awk` は allowlist 外でローカル検証できず、python3 は 3 ランナーとも搭載 + allowlist 内）。節の終端は次の `## [` または `[x.y.z]: ` リンク定義行
11. **`CHANGELOG.md` は Keep a Changelog 1.1.0 形式、`## [Unreleased]` + `## [0.1.0] - 2026-10-18`**（D12）。日付はコンテンツ確定日（人間がタグを打つ日に書き換えてよい、と README のリリース手順に 1 文）。
    `### Added` 1 本に Phase 1〜5 を各 1〜3 行、末尾にリンク定義 2 行
12. **`.gsd-lite/TRACE.md` の節立て**（Phase 5 と同形）: 「PLAN 訂正（turn N）」/「チェックリスト（turn N）」/「`check` の所要」/「利用側 smoke 2 経路」/「blackhole / retry のローカル陽性対照」/「受け入れ基準対応表」/「verify への申し送り」。
    PROGRESS は 1 ターン 40 行上限、生の値は TRACE へ
13. **README の節立て**: 1 概要と対応環境 / **1.5 English summary and install（新）** / 2 インストール（拡充）/ 3〜6 不変 / 7 テストの回し方（`### CI` + `### ブランチ保護（人間が設定）` + `### リリース手順（人間が行う）` を追加）/ 8 Windows の状態 / 9 既知の制限（E1 の 2 行）/ 10 ライセンス。
    `## ` 見出しは 10 → **11**。日本語のまま、英語は 1 節だけ（D11）。git 依存の例は `tag = "v0.1.0"`（prism の形。タグはまだ無いので README は「v0.1.0 リリース後に使える」と 1 文。verify は `branch =` で実測）
14. **impl は PR を作らない、タグを打たない、リポジトリ設定を変えない**（D15 / REQ §6）。T6 の push は `gsd-lite/phase6-packaging-ci` だけ。CI は verify の PR で初めて走る（`ci.yml` の `on:` に feature branch を足さない: B1 の文言どおり + P15）
15. **サブエージェントの推奨本数**（Phase 4 reflect の書式）: T1 0 / T2 0 / T3 1 / T4 1 / T5 0 / T6 0。サブエージェント完了待ちは `sleep <見込み秒>` か完了通知で（mtime ループ禁止: REQ §6）

## メモ

- **タスク数 6**（RESEARCH §6 の 7 案から T7 を T6 に統合 = 統合 + push。8 未満だが要件の規模に合わせた: 「小規模な要件を 8 に増やさない」）。各タスクは 1 ターンで実装 + 検証 + コミットが収まる見込み（最大は T3: YAML 1 + スクリプト 3 + 陽性対照 3。サブエージェント 1 本で並行）
- **RESEARCH §3「盗める点」の採否**:

  | # | 候補 | 採否 | 理由 |
  |---|---|---|---|
  | 1 | 3 OS matrix + `fail-fast: false` + setup-pixi `cache/locked`（ExtraMojo） | 採用 | 決めた事項 4〜5 |
  | 2 | `pixi build -o dist` → `upload-artifact` | 採用 | T3 / T4 |
  | 3 | backend `0.2.*` + channels 明示、`pkg` の `name`/`path` 明示（duckdb.mojo） | 採用 | 決めた事項 3（実測済み） |
  | 4 | `[package] version = { workspace = true }` | 採用 | 決めた事項 3 / 9（C2 を 1 行に） |
  | 5 | git 依存 `{ git = …, tag = "vX.Y.Z" }` を README の主経路に（prism） | 採用 | T5 (a)(b) |
  | 6 | Release `.conda` → `rattler-index fs` で file チャンネル | 採用 | T2 (d) / T5（副経路） |
  | 7 | `gh release create --notes-file` | 採用 | 決めた事項 8 |
  | 8 | `softprops/action-gh-release` | 却下 | 7 で足りる。第三者アクションを増やさない |
  | 9 | `nick-fields/retry` | 却下 | `retry.sh`（`uses:` は包めない） |
  | 10 | `ikalnytskyi/action-setup-postgres` | 却下 | `pg_hba` を自分で制御したい（RESEARCH §1.9） |
  | 11 | brew `postgresql@17` + `pg_ctl -w -t 60` + `pg_hba` scram 書き換え | 採用（手順を変更） | trust のまま TCP で作成 → 書き換え → `reload`。ソケットパス依存を消す（決めた事項 7） |
  | 12 | blackhole = Python 3.14 の listener | 採用 | T3 (d)。socat は fallback にしない（brew install が増える）。立てられなければ SKIP で可 |
  | 13 | `docker compose up -d --wait --wait-timeout 180` | 採用 | T1 (d)（ローカルと CI が同じ `db-up`） |
  | 14 | `rattler-build test --package-file` | 却下 | 利用側 smoke 2 経路（T2）で代替 |
  | 15 | reusable workflow で build を ci / release 共有 | 保留（却下） | 2 ファイルに素直に書く。手順は `retry.sh` + 同じ setup-pixi 入力で揃える |
- **落とし穴 → 担うタスク**（RESEARCH §4。対応先の無いものは無い）: P1 / P2 / P3 / P4 → T2；P5 → T4（重複検査）+ verify；P6 / P7 / P8 / P9 / P10 / P12 / P14 / P15 / P22 / P23 → T3；P11 → T1；P13 / P16 / P17 → T4；P18 / P24 → T5；P19 / P20 → T1；P21 → T6
- **並行性・境界値・異常系の担当**: 異常系 = T3 の retry 陽性対照（`false` で 2 回試行）/ macOS の `WRONG` パスワード対照 / T4 の `check-tag-version.sh` 不一致 3 値と `release-notes.py` の存在しない版；境界値 = T1 の `_restore_collected` 空リスト、
  T4 の `v` 無しタグ；並行性 = CI の `concurrency` cancel（T3）と `fail-fast: false`（1 OS の赤が他 2 OS のログを消さない）。縮小変換（Phase 4 reflect）は**対象なし**（本マイルストーンで Mojo → C に渡す整数を足さない）
- **reflect 提案の反映**（直近 2 件）:
  - Phase 5「`≥` で期待値」→ 反映（表）。「TRACE の『チェックリスト（turn N）』節を T1 で作る + PROGRESS 40 行の 1 コマンド」→ 反映（T1 (e) / T6 (d) / 検証コマンド）。「堅牢性格子を 3 軸で常設」→ **不採用**（examples / 入力経路のコードを変えない。E1 は案 A。
    格子 `turn-012-robust-regress.sh` の期待値は不変なので verify が任意で再実行）。「verify の指摘表 3 列」「F の見込み行数」→ verify 向け（T6 (f) の申し送りに含める）。「Monitor deny / sleep 待ち」→ 決めた事項 15。「research §0.5」→ research 済み
  - Phase 4「縮小変換の行」→ 対象なし（上）。「所要見積もりの式」→ 反映（検証コマンド節）。「PLAN 訂正は TRACE、チェックリスト 3 列」→ 反映。「推奨本数は『サブエージェント N 本（親を除く）』」→ 反映（各タスク + 決めた事項 15）
- **impl への注意**:
  - `pixi` / `mojo` は絶対パス経由。allowlist 外の `awk` / `sed` / `bash <非 tests パス>` は `pixi run <cmd>` で。`> >(exit 0)` 等はスクリプトファイル経由
  - **`pixi.lock` が変わったら手を止めて疑う**（`[package]` では変わらない。feature `bench` / `[environments]` を落としていないか）。lock をコミットしない
  - YAML の `${{ }}` と shell の `$VAR` を混ぜない。`run:` の複数行は `|` で。macOS の bash は 3.2（配列・`mapfile` 不可、`sed -i ''`）。`set -euo pipefail` はスクリプト側で
  - `final_check.sh` / `run_tests.sh` は**触らない**（macOS でも bash 3.2 でそのまま動く: RESEARCH §2.10）。6/6 段に `warning:` 等の文字列を足さない
  - CHANGELOG / README / YAML / スクリプトは `mojo format` の対象外。`check` 1/6 段には影響しない
  - サブエージェントへの依頼文には「PLAN.md の決めた事項 6〜7 / 11 に無い挙動（fallback、追加の環境変数、追加アクション）は実装せず『契約外の提案』として報告」の固定文言を入れる（gsd-lite-impl の規則）
  - verify の CI 待ちが本マイルストーンの実質的な最終検証。impl ができるのは静的検査までなので、T3 / T4 の YAML は `actionlint` 指摘 0 + grep の数え上げを省略しない
