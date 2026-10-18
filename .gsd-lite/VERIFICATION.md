# VERIFICATION — phase6-packaging-ci

- **round 2 / turn 11 / 2026-10-18（Claude Code）** — 直近の節は §0。round 1（turn 9）の記録は §1 以降にそのまま残す
- 対象: `git diff main...HEAD`（コード側 = `pixi.toml` / `.gitignore` / `.github/**` / `CHANGELOG.md` / `README.md` / `src/pq/async_conn.mojo` / `tests/test_notify.mojo`。
  `.claude/settings.json` の allowlist 追記も diff に含まれる = 無人ターンの許可リスト。挙動に影響なし）
- PR: **https://github.com/6in/mojo-pg/pull/1**（verify が round 1 で作成。round 1 = run `39090199560`、round 2 = run `39091056281`）
- **判定（round 2）: 差し戻し（指摘 1 件 → F2）**。F1 は効いて 3 ジョブとも setup-pixi / install を通過、**Linux 2 ジョブは緑**（B2 / B4 / C3 の Linux 側 ✅）。
  **macOS だけ `pixi run check` の 5/6 段で 2 テスト赤**（B3 / B6 ❌）。原因は macOS の poll(2) が `POLLHUP` と `POLLOUT` を同時に立てないこと（POSIX どおり）で、
  ライブラリの `wait_writable` が libpq より先に汎用メッセージで落とす + `test_poll` の期待値が Linux 固有。F1 の差分自体に回帰なし
- 判定（round 1）: 差し戻し（指摘 1 件 → F1）。3 ジョブとも setup-pixi で `Cannot cache without running install`（§1）

## 0. round 2（turn 11）— F1 の回帰確認 + CI 実測

### 0.1 指摘（round 2）

| # | 重さ | 指摘 | grep パターン | 件数（現在 → 期待） | ファイル |
|---|---|---|---|---|---|
| 2 | **差し戻し** | macOS で接続拒否（127.0.0.1:1）を `wait_writable` が **`connection socket closed (POLLHUP/POLLERR)`** として投げ、libpq の `Connection refused` が出ない（`test_connect_failures_name_their_cause` 赤）。macOS の poll は接続失敗を `POLLHUP` だけで報告する（`POLLOUT` 無し）ので `async_conn.mojo:787-793` の「要求方向のビット無し + hangup」分岐に入る。Linux は `POLLOUT|POLLERR|POLLHUP` なので `:787` で return → `PQconnectPoll` が原因を名乗る。直し方は「hangup / error だけでも return して次の libpq 呼び出しに言わせる」（Phase 4 RESEARCH §4 P5 と同じ方針）。同じ run で `test_socketpair_peer_close_sets_hangup_both_ways:215`（書き側 poll の `writable`）も赤 = 同じクラス（POLLHUP / POLLOUT の排他）。`poll_socket` は flags をそのまま返しており正しい。テスト側は Linux 限定の assert にする | `POLLHUP/POLLERR`（src）/ `is_linux`（test_poll） | 2 → 0 / 0 → ≥ 1 | `src/pq/async_conn.mojo:748-760,781-793`、`tests/test_poll.mojo:207-216` |

- 根拠（CI 実測）: `final-check-log-macos-latest`（`scratch/turn-011-macos-artifact/final_check.log`）の 5/6 段。
  `test_async.mojo`: `FAIL [17.769] test_connect_failures_name_their_cause — At tests/test_async.mojo:1613:16: AssertionError: connection socket closed (POLLHUP/POLLERR)`（30/31 PASS）。
  `test_poll.mojo`: `FAIL [0.033] test_socketpair_peer_close_sets_hangup_both_ways — At tests/test_poll.mojo:215:16: AssertionError: condition was unexpectedly False`（10/11 PASS。`:213-214` の `readable.readable` / `readable.hangup` は通過 = 読み側は `POLLIN|POLLHUP`）。
  他の 22 ファイル全 PASS、`-- 127.0.0.1:5432 skipped 15`、`--- FAIL: 5/6 tests`
- 根拠（仕様）: POSIX poll(2)「`POLLHUP` と `POLLOUT` は排他」。Linux は socket で両方立てる（Phase 4 RESEARCH §2.3 の実測 `20 = POLLOUT|POLLHUP`。接続拒否は `POLLOUT|POLLERR|POLLHUP`）。
  本テストが Linux 3 環境（開発機 / x86_64 / aarch64）で PASS し macOS だけ落ちる事実と一致
- **round 1 で拾えなかった理由**: round 1 の macOS ジョブは setup-pixi で止まり `pixi run check` に到達していない（§8）。macOS 実行は round 2 が初見。開発機は linux-aarch64 なのでローカルでは観測不能（REQ §6 の想定どおり）
- 設計の選択（PLAN F2）: **A = ライブラリで「hangup / error だけ」を ready として返す**。B（`CompilationTarget.is_macos()` 分岐）は同じ状態を OS で違う種類にするだけで却下、
  C（`test_async` の期待値を macOS で緩める）は REQ §2.5「CI だけ緩めない」に反し、テスト名の意図（原因を名乗る）も失うので却下。A の副作用: 汎用メッセージが消え、切断の理由は常に libpq の文言になる（Linux でも
  `POLLHUP` 単独が起きる状況は TCP ではまれ。既存テストにこのメッセージを期待するものは無い: `grep -rn 'socket closed' tests` = 0）

### 0.2 F1 の回帰（VERIFICATION §7-5）

| 検査 | 結果 |
|---|---|
| `grep -c 'cache: false'`（ci / release） | **1 / 3** |
| `grep -c -e 'cache: true' -e 'locked: true'`（2 本とも） | **0 / 0**（rc 1） |
| `pixi exec --spec actionlint actionlint ci.yml release.yml` | 指摘 0 |
| チェックリスト全 101 key（`scratch/turn-011-checklist.log`） | turn 10 との差分は `trace_checklist_section` 6 → 7 のみ。`ci_locked_true=0` |
| CI の setup-pixi ステップ（run `39091056281`） | 3 ジョブとも ✓（`with: pixi-version: v0.82.0 / cache: false / run-install: false` がログに出る）。`pixi install --locked` も 3 ジョブとも 1 回目で成功 |

### 0.3 ローカル最終判定（round 2）

- `pixi run db-reset`（3 台 Healthy）→ **`pixi run check` 6/6 PASS = 170 s**（11:46:32 → 11:49:22。閾値 247 s）。1/6 段 差分なし、Linux 両サーバー `skipped 1`（54317 / 54314 の interval 対称 1 件）、6/6 段通過

### 0.4 CI 実測（round 2 / run `39091056281`、`pull_request`、2026-10-18T02:42:37Z、コミット `2c89fb9`）

| ジョブ | 結果 | 所要 | `check` 段 | skipped | `.conda`（artifact `pq-conda-<os>`） |
|---|---|---|---|---|---|
| `check (ubuntu-latest)` | ✅ | 9m52s | 6/6（02:43:00 → 02:52:20）、FAIL 0 | 1 / 1（両サーバー） | **`pq-0.1.0-hb0f4dca_0.conda`**（461,664 B） |
| `check (ubuntu-24.04-arm)` | ✅ | 8m26s | 6/6（02:43:04 → 02:50:58）、FAIL 0 | 1 / 1 | **`pq-0.1.0-he8cfe8b_0.conda`**（461,660 B。開発機の `dist/` と同名 = 同プラットフォーム） |
| `check (macos-latest)` | ❌ | 4m41s | 5/6 で FAIL 2（02:43:07 → 02:47:14 = 247 s） | **15**（`_skip_on_macos` 14 + interval 1 = 申し送りどおり） | 未生成（`pixi build` に到達せず） |

- macOS の前段（`macos-postgres.sh`、P7）: `brew install postgresql@17`（17.11_1、bottle）**12 s** で全段完了（02:42:53 → 02:43:05。initdb は formula の post_install 済みでスキップ、`pg_ctl -w` 即時、scram 切替 + reload、陽性対照 2 つ OK）。
  blackhole: `blackhole 54399 accepting` → `test_connect_blocking_times_out` **PASS（560 ms）** = REQ §2.2 の「SKIP に落とす」経路は使わず本番と同じ判定
- macOS の `pixi install --locked`: **3 s**（02:42:50 → 02:42:53）。キャッシュ無し（F1 の A）の代償 +1〜3 分の見込みは実測で無視できる規模
- **`LibpqLoad` 0 件**（macOS ログ）。pixi 環境の conda `libpq` を dyld が葉名で見つけた = 残留リスク §6-2 は解消
- `.conda` の名前は x86_64 `hb0f4dca_0` と aarch64 `he8cfe8b_0` で異なる（P5 の衝突は 2 つの間では無い。macOS は round 3 で確認）
- 付記: `ubuntu-latest` に「2026-10-19 から Ubuntu 26 に移行」の注記が今回も出た（§6-6）。round 3 の run は OS が変わっている可能性がある
- 付記: run 一覧に turn 9 の `39090199560` と turn 10 の push の間に **run `39090682281`（02:36:14Z、`ce34301`、failure 20 s）** がある。無人ターンは起動していない（人間の re-run と推定）。判定には使っていない

### 0.5 受け入れ基準の更新（round 2 で動いた行だけ。他は §2 のまま）

| 基準 | round 1 | round 2 | 確認したこと |
|---|---|---|---|
| B2 | ⏳ | ✅ | Linux 2 ジョブが compose 3 台 → `pixi run check` 6/6 で緑（上表） |
| B3 | ⏳ | ❌ | macOS は brew PG + fixtures + blackhole まで正常、`check` 5/6 段で 2 テスト赤（指摘 2） |
| B4 | ⏳ | ✅（Linux）/ ⏳（macOS） | `pq-conda-ubuntu-latest` / `pq-conda-ubuntu-24.04-arm` に `.conda` 1 個ずつ。macOS は `pixi build` 未到達 |
| B6 | ❌ | ❌ | 2 / 3 ジョブ緑。**round 3 の合格条件** |
| C3 | ⏳ | ✅（Linux） | CI 側の `pixi build` artifact 2 つで確認。macOS は round 3 |
| F1（CI 側） | ⏳ | ✅（Linux）/ ❌（macOS） | Linux の `check` は 9.3〜9.5 分（ジョブ全体 8〜10 分、45 分の内側）。macOS の `check` は 247 s で 5/6 まで |

### 0.6 残留リスクの更新

- §6-2（macOS の libpq 探索）→ **解消**（`LibpqLoad` 0、全 DB テストが 5432 に接続）
- §6-3（macOS の blackhole）→ **解消**（accepting、timeout テスト PASS）
- §6-5（E2 テストの flaky 候補）→ 3 ジョブとも `test_notify.mojo` 25/25 PASS（macOS 含む）。今回は出ていない
- §6-7（キャッシュ無しの所要）→ macOS install 3 s、Linux ジョブ合計 8〜10 分。影響は無視できる
- 新規 8: **F2 の設計 A は `wait_*` の挙動変更**（hangup / error だけでも return）。Linux では TCP で `POLLHUP` 単独がまれなので既存の経路は変わらないが、
  呼び出し側が wait の後に libpq を呼ばずに再び wait する使い方だと busy loop になり得る（ライブラリ内 3 箇所は libpq を呼ぶ: PLAN F2 (b)）。公開 API を直接使う利用者向けに docstring で「次に libpq を呼ぶ」ことを明記する
- 新規 9（人間向け・差し戻さない）: `CHANGELOG.md` の `0.1.0` 節は REQ §2.4 どおり Phase 1〜5 の要約で、**Phase 6 の成果（conda パッケージ / CI / Release ワークフロー）が載っていない**。
  v0.1.0 の Release 本文がこの節になるので、タグを打つ前に人間が 1 行足すかを判断する（REQ の文言が「Phase 1〜5」なので verify は要件追加しない）

### 0.7 round 3 で確認すること（回帰確認のみ）

1. `gh pr checks 1 --watch`（上限 40 分）で **3 ジョブ緑**（B6）。macOS の `final-check-log-macos-latest` で `test_connect_failures_name_their_cause` と `test_socketpair_peer_close_sets_hangup_both_ways` が PASS、`skipped 15` 不変、`--- FAIL` 行なし
2. `pq-conda-macos-latest` の `.conda` 名が `hb0f4dca_0` / `he8cfe8b_0` と異なること（P5）
3. F2 の回帰 grep: `POLLHUP/POLLERR` src 0、`is_linux` test_poll ≥ 1、`test_file_count=24`、`src_def_ref_return=0`。Linux 2 ジョブが引き続き緑（`wait_*` の挙動変更で Linux の既存テストが落ちないこと）
4. F1 の回帰 grep（§0.2 の表）は F2 がワークフローを触らないので数値不変
5. 合格時: PR 本文を `gh pr edit 1 --body-file` で更新（VERIFICATION の要約 + 実行エンジン名）、round 3 で `reflect` へ

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
