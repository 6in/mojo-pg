# VERIFICATION — phase6-packaging-ci

- round 1 / turn 9 / 2026-10-18（Claude Code）
- 対象: `git diff main...HEAD`（コード側 = `pixi.toml` / `.gitignore` / `.github/**` / `CHANGELOG.md` / `README.md` / `src/pq/async_conn.mojo` / `tests/test_notify.mojo`。
  `.claude/settings.json` の allowlist 追記も diff に含まれる = 無人ターンの許可リスト。挙動に影響なし）
- PR: **https://github.com/6in/mojo-pg/pull/1**（verify が作成。CI run `39090199560`）
- **判定: 差し戻し（指摘 1 件 → F1）**。ローカルの受け入れ基準はすべて満たすが、REQ B6「PR 上で 3 ジョブが緑」が **3 ジョブとも setup-pixi ステップで赤**
  （`Cannot cache without running install`）。設定 1 箇所の問題で、Mojo 側・スクリプト側に指摘なし

## 1. 指摘（round 1）

| # | 重さ | 指摘 | grep パターン | 件数（現在 → 期待） | ファイル |
|---|---|---|---|---|---|
| 1 | **差し戻し** | `prefix-dev/setup-pixi@v0.11.2` は `run-install: false` のとき `cache: true` を拒否する（`src/options.ts:207` `Cannot cache without running install`）。`cache` の既定は true（`action.yml`）なので**省略では直らず `cache: false` が要る**。さらに同 `options.ts:216` は `locked: true` も拒否する（`Cannot use \`locked: true\` when not running install`）ので、`cache` だけ直すと次の run はそこで落ちる。RESEARCH P12 が「未検証」と書いた相性そのもの | `cache: true` / `locked: true` | 4 → 0 / 4 → 0 | `ci.yml:56-58`、`release.yml:36-38,69-71,103-105` |

- 根拠（CI 実測）: run 39090199560 の 3 ジョブとも `Run prefix-dev/setup-pixi@v0.11.2` で 5〜9 s に失敗。`gh run view --log-failed` の該当行は
  `##[error]Cannot cache without running install`（Post ステップも同文）。以後のステップは全部スキップ、`final-check-log-*` は `No files were found`
- 根拠（静的）: `gh api repos/prefix-dev/setup-pixi/contents/src/options.ts?ref=v0.11.2` の検証節 =
  `runInstall === false && cache === true` → throw、`runInstall === false && frozen === true` → throw、`runInstall === false && locked === true` → throw、
  `runInstall === false && environments` → throw。`run-install: false` と両立する入力は `pixi-version` / `cache: false` だけ
- 直し方は PLAN F1。設計の選択: **A = 手動 install を維持**（`run-install: false` + `cache: false`、`locked` を外し、lock の強制は既存の `retry.sh 3 15 pixi install --locked`）。
  B = action に install させる（`locked: true` + `cache: true`、`run-install` を外す）は REQ §2.5「ネットワーク依存ステップはリトライする」を install で満たせない
  （setup-pixi にリトライ入力は無い: RESEARCH §2.5）ので却下。A の代償は環境キャッシュを使わないこと（毎 run で取得、見込み +1〜3 分/ジョブ。45 分の上限内）

## 2. 受け入れ基準の判定（REQ §4）

| 基準 | 判定 | 確認したこと（round 1） |
|---|---|---|
| A1 | ✅ | `dist/*.conda` を消して `pixi build -o dist` → `pq-0.1.0-he8cfe8b_0.conda` 1 個（rc 0。deprecated 警告は turn 5 の判断どおり無視） |
| A2 | ✅ | **GitHub の URL で git 経路を再実測**: `scratch/turn-009-consumer-git/`（`pq = { git = "https://github.com/6in/mojo-pg.git", branch = "gsd-lite/phase6-packaging-ci" }`、`preview = ["pixi-build"]`、channels max + conda-forge）→ `pixi run smoke` が `pq import OK` + `expected failure: PgError(kind=Connection, …Connection refused` で `LibpqLoad` 無し（`scratch/turn-009-consumer-git.log`）。ダウンロード経路は turn 4 の実測（`turn-004-consumer-dl.log`）を採用 |
| A3 | ✅ | turn 4 の `pkg-*.tar.zst` 内容（`lib/mojo/pq.mojoc` + `share/max/firstActivation`）+ 今回の git 経路ビルドログも同じ 2 content files（`Package statistics: 7 files (2 content, 5 metadata)`） |
| A4 / F1 / F2 | ✅ | `pixi run db-reset` → `pixi run check` **6/6 PASS、169 s**（11:25:41 → 11:28:30。閾値 247 s）。両サーバー `skipped 1`（54317 = `test_interval_infinity_rejected_before_pg17`、54314 = `…_on_pg17_and_later`）、6/6 段 `matched lines: 0`、1/6 段 差分なし。`pixi install --locked` rc 0、`git diff --quiet main -- pixi.lock` rc 0 |
| B1 | ✅ | PR 作成で `CI` が `pull_request` で起動し、ジョブ名が **`check (ubuntu-latest)` / `check (ubuntu-24.04-arm)` / `check (macos-latest)`** の 3 つ（`gh pr checks 1`）。T6 の branch push では 0 件だった（P15） |
| B2 / B3 / B4 | ⏳ | **round 2 で確認**（setup-pixi で止まり、`pixi run check` 以降は未実行） |
| B5 | ✅ | `all_timeout_minutes=4` / `all_permissions=3` / `all_secrets_refs=0` / `all_contents_write=1`、待ち上限 = compose `--wait-timeout 180` + `pg_ctl -w -t 60` + ジョブ 45 分 |
| B6 | ❌ | 3 ジョブとも赤（指摘 1）。**round 2 の合格条件** |
| B7 | ✅ | `ci_windows_reason=1`、`readme_windows_toolchain=2` |
| C1 / C2 / C4 | ✅ | `release.yml` の構成レビュー（下 §3）。`check-tag-version.sh` 3 値（`v0.1.0` rc 0 / `v0.2.0` rc 1 / `"v0.1.0 ; echo injected"` rc 1、注入なし）。`release-notes.py` 3 値（引数なし rc 1 usage / `0.1.0` 非空で先頭 `### Added` / `Unreleased` 空節 rc 1）。`release.yml` の setup-pixi 3 箇所も指摘 1 の対象（タグ push 時に同じ理由で落ちる） |
| C3 | ⏳ | CI の `pq-conda-*` artifact で確認 = round 2 |
| D1〜D4 | ✅ | チェックリスト `readme_*` 22 key すべて期待値（`turn-009-checklist.log`）。目視: 英語節は実測した 2 経路のみ、ジョブ名 3 つが `protection.json` の `contexts` に一致、リリース手順 5 段が `release.yml` の 3 ジョブと整合 |
| E1 | ✅ | README「既知の制限」2 項目、コード変更 0 |
| E2 | ✅ | §3 のコードレビュー。`_restore_collected(` 3 箇所、両 `except` から呼ぶ、`TIMEOUT` は `return out^` のまま。テスト 25 件 PASS（両サーバー） |

チェックリスト全 101 key: turn 8 のログとの差分は `trace_checklist_section` 5 → 6 のみ（単調増加の性質）。PLAN 訂正なし（F1 で `ci_locked_true` 1 → 0 が入る）。

## 3. コードレビュー

- **E2（`src/pq/async_conn.mojo`）**: `_restore_collected` は旧 5 行と同一の意味（`collected` → 旧 `_pending` の順で新リストを作って置き換え）。`_collect_notifications` は
  `notifications()` 側 `except` と `wait_readable` 側 `except`（`TIMEOUT` 以外すべて）で呼び、`raise e^` の前に `out` を消費しない（`out` は借用のまま）。docstring `Raises:` に 1 文追加。
  テスト `test_restore_collected_puts_them_back_in_front` は `_pending` 直読みと `_notifications()` の両方で順序を確認し、空リストの境界値あり。
  1 tx 内の NOTIFY 3 件が 1 往復で届く前提は既存 `test_wait_notifications_keeps_collected_ones_across_two_round_trips` と同じ（残留リスク §6-5）
- **`ci.yml`**: 3 OS 同一の `pixi run check`、OS 差はステップ条件のみ。`PQ_TEST_CONNINFO` の `${{ … || '' }}` は Linux で空文字 → `run_tests.sh:37` の `-n` 判定で両サーバー（意図どおり）。
  examples 5 本はすべて `PQ_TEST_CONNINFO` を読む（`examples/*.mojo` の `getenv`）ので macOS でも 5432 を指す。blackhole は stdout / stderr をファイルに向けて `nohup … &` → 接続確認。
  `concurrency` は `refs/pull/N/merge` 単位で cancel。**指摘 1 以外に問題なし**
- **`release.yml`**: `verify-version`（タグのときだけ `check-tag-version.sh`、常に `release-notes.py` → `test -s`）→ `build` 3 OS → `release`（`if: github.ref_type == 'tag'`、このジョブだけ `contents: write`、
  `download-artifact` の flat `dist/` を `uniq -d` で衝突検査、`git archive HEAD`、`gh release create --notes-file`）。`VERSION="${GITHUB_REF_NAME#v}"` はタグが `version` と一致した後にしか使われないので
  パス注入の余地なし。`verify-version` / `release` は `pixi install` を呼ばない（`pixi workspace version get` は環境不要）
- **スクリプト 5 本**: bash 3.2 互換（配列・`mapfile` なし）、`set -euo pipefail`（`retry.sh` だけ `set -u`。理由コメントあり）。`macos-postgres.sh` は trust のまま TCP で role / DB / schema →
  `sed -i '' -E` で `host` 行だけ scram → `reload` → 陽性対照 2 つ（正パスワード rc 0、`WRONG` rc≠0 **かつ** `password authentication failed`）。`blackhole.py` は `127.0.0.1` のみ bind、`held` で保持
- **文書の主張**: README「19 の型」= 英語節 `19 types` = CHANGELOG Phase 3 `19 の型`（一致）。README CI 小節の「機能ブランチへの push では走りません」は T6 実測（0 件）+ 今回の PR 起動で裏付け。
  「待ち上限は 3 段階」の 3 値は `pixi.toml:32` / `macos-postgres.sh:141` / `ci.yml:58` と一致。TRACE 受け入れ基準対応表の「verify の PR で確認」列は B1〜B4 / B6 / C3 / F1 で、本書 §2 と同じ区分。
  PROGRESS turn 3〜8 の「既存テストの期待値変更 0 件」は diff と一致（`tests/` の変更は追加 1 件のみ）
- `.claude/settings.json`: `gh pr checks` / `gh run` / `docker` / `python3` 等の allowlist 追記。無人ターンの運用用で成果物の挙動に無関係（PLAN の対象外だが差し戻し理由にはしない）

## 4. セキュリティチェック

- トリガーは `pull_request`（`pull_request_target` ではない）+ `push: main`。先頭 `permissions: contents: read`、`release` ジョブだけ `contents: write`。`secrets.` 参照 0（fork PR でも動く前提は未検証のまま README に明記）
- 第三者アクションは 4 つ（`actions/checkout@v7` / `prefix-dev/setup-pixi@v0.11.2` / `actions/upload-artifact@v7` / `actions/download-artifact@v7`）。**タグ固定で SHA 固定ではない**（残留リスク §6-1）
- 秘密情報のハードコードなし（`pq` / `pq` はテスト用 DB の資格情報で compose と同じ。CI ランナー内の 127.0.0.1 のみ）
- 入力の扱い: `check-tag-version.sh` はタグを引数として受け、`case` と文字列比較のみ（上の注入プローブで確認）。`release-notes.py` は `startswith("## [%s]")` の文字列一致で正規表現に版文字列を入れない。
  `blackhole.py` は `int(argv[1])` 失敗で rc 1。`retry.sh` は `"$@"` で eval なし
- `gh release create` は `github.token`。タグを push できる人 = Release を作れる人（意図どおり。D15 で人間のみ）

## 5. 堅牢性格子（round 1 で一括。入力経路 × 例外）

| 経路 | 試したこと | 結果 |
|---|---|---|
| `retry.sh` argv | `2 1 false` / `0 1 false` / 引数 2 個 | rc 1 + 2 試行 + `giving up` / **tries=0 は何も実行せず rc 0**（§6-4）/ usage rc 2 |
| `check-tag-version.sh` argv | `v0.1.0` / `v0.2.0` / `v0.1.0 ; echo injected` / `0.1.0`（turn 6） | rc 0 / rc 1 / rc 1（注入なし、文字列として表示）/ rc 1 |
| `release-notes.py` argv + CHANGELOG 内容 | 引数なし / `0.1.0` / `Unreleased`（空節）/ `9.9.9`（turn 6） | rc 1 usage / 非空 / rc 1 `is empty` / rc 1 `no … section` |
| `blackhole.py` argv | 非数値 / ポート使用中（静的） | rc 1 メッセージ / `OSError` のトレースバックで rc 1 → ci.yml の接続確認が落ちてジョブ赤（§6-3） |
| Mojo 側 | E2 は新しい入力経路なし（内部ヘルパ）。Phase 5 の格子 `turn-012-robust-regress.sh` は E1 が案 A（コード変更 0）のため期待値不変 | 再実行せず（REQ に堅牢性の受け入れ基準は CI 側だけ: §2.5） |

## 6. 残留リスク（差し戻さない）

1. アクションがタグ固定（`@v7` / `@v0.11.2`）で SHA 固定ではない。PLAN 決めた事項 5 の選択。供給網リスクは低〜中、固定したければ `gh api …/git/ref/tags/v7` の SHA に置き換える
2. **macOS での libpq 探索は未検証**（loader は `libpq.5.dylib` → `libpq.dylib` → Homebrew `libpq` formula の 2 パス。pixi 環境の conda `libpq` を dyld が葉名で見つけるかは macOS でしか分からない。
   brew `postgresql@17` は `libpq` formula を入れない）。round 2 の macOS が `LibpqLoad` で赤なら、`ci.yml` の macOS ステップに `PQ_MOJO_LIBPQ: ${{ github.workspace }}/.pixi/envs/default/lib/libpq.5.dylib` を足すのが修正
3. macOS の blackhole が立たない場合、ci.yml の接続確認ステップで**ジョブが赤**になる（REQ §2.2 の「SKIP で済ます」ではなく fail-loud。PLAN T3 (a) の設計。`blackhole.py` は 127.0.0.1:54399 に bind するだけなので新品ランナーで失敗する要因は薄い）
4. `retry.sh` は `tries=0` で何も実行せず rc 0 を返す。ワークフローは常に `3` を渡すので到達しない
5. E2 のテストは 1 tx の NOTIFY 3 件が 1 往復で届く前提（既存テストと同じ。localhost では安定。CI の遅いランナーで分割されたら `assert_equal(len(listener._pending), 2)` が落ちる可能性 = flaky 候補）
6. `ubuntu-latest` は 2026-10-19 から Ubuntu 26 に移行する旨の注記が run に出た。compose / docker の有無は変わらない見込みだが、round 2 以降の run で OS が変わり得る
7. キャッシュを使わない（F1 の選択 A）ので、毎 run で pixi 環境を取得する。所要 +1〜3 分/ジョブの見込み。`timeout-minutes: 45` の内側

## 7. round 2 で確認すること（回帰確認のみ。新しい探索はしない）

1. `gh pr checks 1 --watch`（上限 40 分）で **3 ジョブ緑**（B6）。赤なら `gh run view --log-failed` の要点をここに写して差し戻し
2. `final-check-log-<os>` 3 本の `=== [6/6]` と `final_check: PASS`、Linux は `skipped 1` × 2 サーバー、macOS は **`skipped 15`**（`_skip_on_macos` 14 + interval 1。blackhole が立たなければ 16）
3. `pq-conda-<os>` 3 artifact の中の `.conda` ファイル名（linux-aarch64 = `pq-0.1.0-he8cfe8b_0.conda`。3 つが互いに違えば release の flat `dist/` で衝突しない = P5）
4. macOS の `== ...` 各段の所要（`macos-postgres.sh`。P7）と `LibpqLoad` の有無（§6-2）
5. F1 の差分の回帰: `grep -c 'cache: false'` = 1 / 3、`locked: true` / `cache: true` = 0、actionlint 0、`ci_locked_true=0`、他の checklist 行は不変
6. §6-5 の flaky 候補が CI で出たかどうか

## 8. CI 実測（round 1）

- run `39090199560`（`pull_request`、2026-10-18T02:28:21Z）。3 ジョブとも `Set up job` ✓ → `checkout@v7` ✓ → `setup-pixi@v0.11.2` ✗（5〜9 s）→ 以降スキップ → `upload-artifact@v7`（`if: always()`）は動いた（`No files were found` の warn）
- アクションのタグ実在は確認できた: `checkout@v7` / `upload-artifact@v7` が実行された（`download-artifact@v7` は release.yml のみで未実行）
