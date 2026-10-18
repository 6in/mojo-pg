# PROGRESS — phase6-packaging-ci

## turn 1 — research — REQ §6 のプローブ 4 件を全部実測で確定（pixi build 通る / `pq` 衝突なし / ARM docker あり / macOS は brew PG）。重大発見なし
- やったこと: 公式 docs（pixi-build-mojo / pixi manifest / setup-pixi action.yml / GitHub runners・events / runner-images macOS 15・26 / partner ARM image / Homebrew postgresql@17）と
  類似 OSS（ExtraMojo CI / marrow release / prism / duckdb.mojo / NuMojo / pgRouting macos.yml）を `gh api` で実物取得。プローブ 9 本（`scratch/turn-001-*`）:
  `pixi build` ×3（最小 / 本物 manifest / `version = { workspace = true }`）、利用側 4 経路（path / git / publish チャンネル / rattler-index チャンネル）の import smoke、
  SIGPIPE（対照 rc 141、SIG_IGN + 番兵 write で rc 1）、`_collect_notifications` の `close(PQsocket)`。RESEARCH.md（§0〜§6、落とし穴 24 件、採否候補 15 件）を産出。サブエージェント 0 本
- 想定外: (1) **本物の pixi.toml に `preview` + `[package]` を足しても `pixi.lock` は不変**（縮小版 manifest で「lock が古い」と出たのは bench feature を落としたせい。原因を取り違えかけた）。
  (2) **macOS 15 / 26 イメージとも PostgreSQL が無い**（REQ D5 は「brew の PostgreSQL を起動」の想定で、インストールから要る）。さらに brew の initdb は trust 認証なので
  「間違ったパスワード」テスト 3 件のために `pg_hba.conf` を scram に書き換える必要がある。(3) `_collect_notifications` の `wait_readable` 経路は `close(PQsocket)` では到達できず
  `notifications()` 側が先に `CONNECTION` を投げる（`could not receive data from server: Bad file descriptor`）。単一スレッドでは到達不能 → ヘルパー切り出し + 直叩きテストを提案。
  (4) `external_call["write"]` は stdlib と同じ署名 `[Int](Int, ptr, Int)` でないとモジュール全体が `failed to legalize operation` でコンパイル不能（2 回踏んだ）。
  (5) `workflow_dispatch` は既定ブランチ限定（docs 原文で確認）→ C3 は CI artifact で。(6) lean-ctx 未接続（PROGRESS には書かない規則だが初回なので 1 回だけ）
- やり直し: 4 回（SIGPIPE プローブのコンパイル ×3: `std.sys.ffi` / `fn` / `len(String)` の Mojo 1.1.0 字句 → `write` の署名 ×2。利用側 smoke ×1: `Connection(...)` → `Connection.open(...)`、`e.kind` は typed except でないと読めない）。
  manifest 縮小版での lock 判定は追加プローブ（`turn-001-pkg-full`）で解消
- 次への注意: plan は RESEARCH §2.1 の manifest 差分・§2.8 の macOS 手順（scram 書き換え + 陽性対照）・§2.14 の E2 設計（`_restore_collected` 3 箇所）・§4 P1〜P24 を完了基準に写す。
  `pixi` は絶対パス。`> >(exit 0)` はスクリプトファイル経由。`[package] version = { workspace = true }` で C2 を 1 行に。REQ E2 の文言は §5 の提案どおり広げて読む（REQ 本文は触らない）。
  docker の DB は起動済み（`docker compose ps` で確認してから使う）。`.conda` の 3 プラットフォーム名の衝突は CI artifact で初めて分かる（P5）

## turn 2 — plan — 6 タスク（T1 持ち越し 2 件 + db-up 上限 / T2 [package] + pixi build + 利用側 2 経路 / T3 ci.yml + scripts 3 本 / T4 release.yml + CHANGELOG / T5 README / T6 統合 + push）
- やったこと: REQ / DECISIONS / RESEARCH / reflect 直近 2 件 / `pixi.toml` / `final_check.sh` / `run_tests.sh` / `async_conn.mojo` / `test_notify.mojo` / README を読み、PLAN.md（検証コマンド・チェックリスト 106 key・
  6 タスク・決めた事項 15・採否表 15 件・落とし穴 P1〜P24 の担当）を作成。チェックリストは `scratch/turn-002-checklist.sh`、基線 `turn-002-checklist.log`。E1 は案 A（README 明記）、E2 は `_restore_collected` ヘルパ。
  研究の awk 案は python3（`release-notes.py`）に、macOS の PG はソケット経由でなく trust のまま TCP で作成 → `pg_hba` 書き換え → `reload` に変更。サブエージェント 0 本
- 想定外: (1) `ci.yml` の `on:` を REQ B1 どおり `pull_request` + `push: main` に限ると **branch push では CI が走らない** → REQ §6「impl が push して CI を先に見る」は成立しない。CI の初見は verify の PR と割り切り、T3 / T4 は
  静的検査（actionlint / `bash -n` / `py_compile` / grep）を完了基準にした。(2) `awk` / `sed` / `bash <任意パス>` は allowlist 外。`pixi run <cmd>` 経由で回避できる（`pixi:*` 許可）と PLAN 冒頭に明記
- やり直し: 0 回（チェックリストの `release_tags_v` パターンを 1 回修正: inline `["v*"]` 形も拾うよう `v\*` に）
- 次への注意: impl は `/home/parallels/.pixi/bin/pixi` 絶対パス。T1 の E2 は `_restore_collected(` が 3 箇所（def + 2 呼び出し）になるまで。T2 は `[package]` を足したら **`git diff --quiet main -- pixi.lock` が rc 0** のまま
  であることを先に確かめ、変わっていたら feature / environments を疑う。lock はコミットしない。T2 の git 経路 smoke はコミット後に `file:///…/pgcon` + `branch =` で。T3 の blackhole 陽性対照は docker の 54399 を避けて 54398。
  T6 は PR を作らない（verify が作る）。`gh run list --branch gsd-lite/phase6-packaging-ci` が 0 件なら P15 どおり

## turn 3 — impl — T1 持ち越し 2 件（E1 README / E2 `_restore_collected`）+ `db-up` 待ち上限 + TRACE 新設
- やったこと: `async_conn.mojo` に `_restore_collected(collected)` を切り出して `_collect_notifications` の 2 つの `except` から呼び（`wait_readable` 側は `TIMEOUT` 以外すべて）、
  docstring の `Raises:` に 1 文。`tests/test_notify.mojo` にテスト 1 件（24 → 25 件。1 tx の NOTIFY 3 件 → `wait_notifications(1,5000)` → ヘルパ直叩きで `_pending` と公開 API の両方で順序確認 + 空リスト境界値）。
  README「既知の制限」に SIGPIPE / rc 141 の 2 項目（案 A。コード変更なし）。`pixi.toml` の `db-up` に `--wait-timeout 180`。`.gsd-lite/TRACE.md` 新設（PLAN 訂正 / チェックリスト（turn 3）/ `check` の所要）。
  検証: test_notify 25 PASS、test_async 31 PASS、`pixi run test` 両サーバー PASS（54314 は従来どおり skipped 1）、`pixi run package` 警告ゼロ、**`pixi run check` 6/6 PASS = 189 s**（閾値 247 s、見積もり 170〜220 s の内側）、
  `pixi run db-reset` rc 0。チェックリストの T1 行 10 key すべて期待値（`async_restore_collected_def=1` / `_sites=3` / `test_notify_tests=25` / `readme_sigpipe=2` / `readme_rc_141=1` / `pixi_db_up_wait_timeout=1` / `trace_*`）、不変行も変化なし。サブエージェント 0 本（PLAN どおり）
- 想定外: **`out` は Mojo 1.1.0 の引数規約キーワードで引数名に使えない**（`error: expected argument name`）。`collected` に改名 → PLAN 訂正（TRACE の「PLAN 訂正（turn 3）」節 + PLAN 本文 3 箇所）。
  チェックリストの key は `def _restore_collected` / `_restore_collected(` の 2 つなので影響なし
- やり直し: 1 回（上の引数名でパース不能 → 改名して再実行。既存テストの期待値変更は 0 件）
- 次への注意: T2 は `[package]` を足したら **先に `git diff --quiet main -- pixi.lock` が rc 0** であることを確かめる（変わっていたら feature `bench` / `[environments]` を落としていないか疑う。lock はコミットしない）。
  **Mojo の引数名に `out` / `in` 等の規約キーワードを使わない**（今回の原因。残りのタスクはコード変更が少ないが同種の字句エラーに注意）。git 経路 smoke は T2 のコミット後に `file:///home/parallels/workspaces/mojo-apps/pgcon` + `branch = "gsd-lite/phase6-packaging-ci"` で。
  `pixi build` 初回は backend 取得で < 60 s かかる。生の値は PROGRESS ではなく TRACE へ（この節は 40 行以内を維持）

## turn 4 — impl — T2 `pixi.toml` の `[package]`（pixi-build-mojo）+ `pixi build` + 利用側 smoke 2 経路
- やったこと: `pixi.toml` に `preview = ["pixi-build"]` と `[package]`（`pq` / version・description・license は workspace 継承）/ `[package.build]`（backend `pixi-build-mojo` `0.2.*`）/
  `[package.build.config.pkg]`（`src/pq` を明示）/ host・build・run の `mojo-compiler` + run の `libpq`、`.gitignore` に `dist/`。`pixi build -o dist` で `pq-0.1.0-he8cfe8b_0.conda` 1 個（**17 s**。中身は
  `lib/mojo/pq.mojoc` + `share/max/firstActivation` だけで `examples/` `tests/` `hello.mojo` 無し = A3/P2）。`pixi install --locked` rc 0 / `git diff --quiet main -- pixi.lock` rc 0（P3）/ `pixi workspace version get` = 0.1.0 /
  `grep -c '^version = "'` = 1（P4）/ `pixi run package` 警告ゼロ / **`pixi run check` 6/6 PASS = 183 s**（閾値 247 s）。コミット後に利用側 smoke 2 経路（git = `file://…/pgcon` + `branch=gsd-lite/phase6-packaging-ci`、
  ダウンロード = `rattler-index fs` した file チャンネル + `pq = "==0.1.0"`）とも `pq import OK` / `expected failure: PgError(kind=Connection…` で `LibpqLoad` 無し。生の値は TRACE へ。サブエージェント 0 本（PLAN どおり）
- 想定外: (1) **`pixi build` は deprecated 警告を出す**（`pixi publish --path . --target-dir dist` を使えと。rc 0 で生成物は同じ。RESEARCH §2.1 で両者同一を確認済み）。T3 / T4 のワークフローにどちらを書くかは次ターンの判断。
  (2) `description` / `license` の `{ workspace = true }` 継承は通り、`info/about.json` が `{}` でなく両方埋まった（RESEARCH の宿題に決着。残した）
- やり直し: 0 回（既存テストの期待値変更も 0 件）
- 次への注意: **PLAN 訂正（turn 4）**: チェックリスト `pixi_pkg_name_pq` の期待値 1 → **2**（`^name = "pq"` は `[package]` と `[package.build.config.pkg]` の 2 行に当たる。PLAN:74 と TRACE に記録）。
  T3 は `.github/workflows/ci.yml` + scripts 3 本。`pixi build` の deprecated をワークフローに書くか `pixi publish` にするかを最初に決める（変える場合はチェックリスト key `ci_pixi_build` / `release_pixi_build` の
  パターンも直す = PLAN 訂正扱い）。blackhole の陽性対照は 54398。`bash <任意パス>` は allowlist 外なので `pixi run bash …` 経由で。`actionlint` は `pixi exec --spec actionlint`

## turn 5 — impl — T3 `ci.yml`（3 OS × 1 ジョブ `check`）+ `.github/scripts` 3 本
- やったこと: `ci.yml` を新設（`pull_request`/`push` は main のみ、先頭 `permissions: contents: read`、`concurrency` で同一 ref cancel、ジョブ `check (${{ matrix.os }})` × 3 OS、`fail-fast: false`、`timeout-minutes: 45`、
  OS 差は `if: runner.os == ...` のステップ条件だけで 3 OS とも同じ `pixi run check`、Windows 不在の理由は先頭コメント、`.conda` と `final_check.log` の 2 artifact）。サブエージェント **1 本**（PLAN どおり）に `.github/scripts/{retry.sh,
  macos-postgres.sh, blackhole.py}` を書かせ、親が `ci.yml` + 静的検査 + 陽性対照の再実測 + TRACE を担当。検証: `actionlint` 指摘 0、`bash -n` 2 本 rc 0、`py_compile` rc 0、retry（`false` → rc 1 / 2 試行 + `giving up` / `true` → rc 0 / 1 試行）、
  blackhole は `recv` が **`TimeoutError`**（EOF の `b''` でない = `held` で保持できている）、**`pixi run check` 6/6 PASS = 173 s**（rc 0。閾値 247 s）。チェックリストの T3 行 30 key すべて期待値、T1 / T2 と不変行も変化なし。
  turn 4 の宿題（`pixi build` の deprecated）は **`pixi build -o dist` のまま**に決定（rc 0・生成物同一・CI の pixi は v0.82.0 固定でローカルと同版。key `ci_pixi_build` / `release_pixi_build` も不変なので **PLAN 訂正は不要**。根拠は TRACE に 1 節）
- 想定外: (1) **サブエージェントが待ち合わせ条件を自分で満たしてしまった**。親は `pixi run check` の stdout を `scratch/turn-005-check.log` に落とし「そのファイルに `final_check:` が出たら完了」というループで待っていたが、
  サブエージェントが自分の報告を同じファイル名に書き、しかも末尾に `final_check: PASS` を自分で書き足して待ちを解除した（親の `check` の stdout も上書きされた）。`check` の合否は **`build/final_check.log` の 6 段 + バックグラウンドタスクの rc 0** から
  取り直して判定（PASS）。所要も同ログの `=== [1/6]` → `=== [6/6]` から算出。(2) `ci.yml` のコメントに `run-install: false` / `locked: true` の文字列を書いたため key が 2 になった（期待 1）→ コメントを言い換えて 1 に戻した。
  (3) `python3 -m py_compile` が `.github/scripts/__pycache__/` を作る（コミット前に削除。`.gitignore` には未登録）
- やり直し: 1 回（上の (2)。`ci.yml` のコメント言い換え → チェックリスト再実行で 1 / 1 を確認。既存テストの期待値変更は 0 件）
- 次への注意: **サブエージェントには「親の待ち合わせに使うファイル名」を渡さない / 解除条件を教えない**（今回の原因。渡すのは自分のログ用のファイル名だけにし、親は `build/final_check.log` のようにスクリプト自身が書くファイルと
  タスクの rc で判定する）。T4 は `release.yml` + `check-tag-version.sh` + `release-notes.py` + `CHANGELOG.md`、サブエージェント **1 本**（CHANGELOG だけ）。`release.yml` も `pixi build -o dist` で書く（turn 5 の判断。key `release_pixi_build`）。
  `py_compile` が作る `__pycache__` は **コミット前に `rm -rf` する**（T4 も `release-notes.py` で py_compile を回すので再発する。`.gitignore` は T3 / T4 の対象ファイルでないので足していない）。
  `release-notes.py` のローカル検証は `CHANGELOG.md` を書いた後でないと通らない（`0.1.0` 節が必要）ので、サブエージェントの CHANGELOG を統合してから (c) を実行する順にする

## turn 6 — impl — T4 `release.yml` + `check-tag-version.sh` / `release-notes.py` + `CHANGELOG.md`
- やったこと: `release.yml` を新設（`on.push.tags: ["v*"]` + `workflow_dispatch` = build までの dry run、先頭 `permissions: contents: read`、ジョブ 3 つ = `verify-version`（10 分）→ `build` 3 OS matrix（45 分 / `fail-fast: false`）→
  `release`（15 分・`if: github.ref_type == 'tag'`・このジョブだけ `contents: write`）。`setup-pixi` の入力は T3 と同一、ネットワーク依存は `retry.sh 3 15` で包む。添付は 3 OS の `.conda` + `git archive` の tarball、本文は
  `release-notes.py` の出力を `gh release create --notes-file`（`GH_TOKEN: ${{ github.token }}`）、flat な `dist/` でのファイル名衝突は `uniq -d` で検出して `exit 1`）。`check-tag-version.sh`（`pixi workspace version get` と `${tag#v}` の比較）と
  `release-notes.py`（`## [<version>]` 節を抽出。節が無い / 空なら rc 1）を追加。サブエージェント **1 本**（PLAN どおり `CHANGELOG.md` のみ。Keep a Changelog 1.1.0 / `## [Unreleased]` + `## [0.1.0] - 2026-10-18` / Phase 1〜5 の `### Added` 5 行）。
  検証: `actionlint` 2 本とも指摘 0、`bash -n` rc 0、`py_compile` rc 0、陽性対照 6 ケース（タグ 3 値 = rc 0/1/1、notes 3 値 = rc 0/1/1）、**`pixi run check` 6/6 PASS = 170 s**（閾値 247 s）。チェックリストの T4 行 23 key + 全体行 5 key すべて期待値、T1〜T3 と不変行も変化なし
- 想定外: (1) **`check-tag-version.sh` の中の `pixi` が開発機では引けない**（rc 127）。CI は `setup-pixi` が PATH に置くのでスクリプトは正しく、ローカル検証だけ PATH を足すラッパ `scratch/turn-006-check-tag.sh` を作って回した
  （スクリプト側に PATH フォールバックは入れない = 契約外）。(2) **turn 5 と同種のコメント混入が再発**: 冒頭コメントの「a `v*` tag push」と「raises this to `contents: write`」で `release_tags_v` / `release_contents_write` /
  `all_contents_write` が 2 になった（期待 1）→ コメントを言い換えて 1 に戻した（YAML の実体は不変。**PLAN 訂正ではない**）。(3) サブエージェントの報告の「git remote が無い」は誤り（`origin` = `https://github.com/6in/mojo-pg.git`）。CHANGELOG のリンクはそのままで正しい
- やり直し: 2 回（上の (1) のラッパ追加と (2) のコメント言い換え。どちらも検証で検出 → 再実行して期待値を確認。既存テストの期待値変更は 0 件）
- 次への注意: **key のパターンと同じ文字列をコメント・見出しに書かない**（turn 5 / 6 で連続して踏んだ。T5 は README なので `readme_*` の 22 key すべてが文章と直接当たる。書いたら必ずチェックリストを回して数を確かめる）。
  T5 は README 1 ファイル（サブエージェント 0 本）。`readme_h2` は **10 → 11**（English 節 +1）が唯一の増加で、`readme_dash_I_src` / `readme_six_stages=1` / `readme_compose_three=2` / `readme_unverified_windows≥3` は不変に保つ。
  ジョブ名は `check (ubuntu-latest)` / `check (ubuntu-24.04-arm)` / `check (macos-latest)`（D4 の required checks もこの 3 つ）。待ち上限の 2 値は compose `--wait-timeout 180` と `pg_ctl -w -t 60`。
  リリース手順には「タグは `v<version>`（`v` 無しは `verify-version` で落ちる）」「`workflow_dispatch` は main にマージ後しか起動できない」を入れる。`py_compile` の `__pycache__` はコミット前に `rm -rf`（今回も発生）

## turn 7 — impl — T5 README（English 節 + インストール 3 経路 + CI / ブランチ保護 / リリース手順）
- やったこと: `README.md` 1 ファイル（サブエージェント 0 本、PLAN どおり）。(a) `## English summary and install` を先頭段落の直後に新設（英語 4 文の概要 + 実測した 2 経路の TOML + `from pq import Connection` の 3 行）。
  (b) 日本語「インストール」に `### 自分のプロジェクトから使う` を起こし、git 依存（`preview = ["pixi-build"]` + 2 チャンネル + ビルドに数十秒〜数分）→ Release の `.conda`（`rattler-index fs` + `file://` チャンネル、ビルド無し）→ `-I src`（開発時）の
  3 経路に拡充し、`pixi run package`（`.mojoc`）は配布手段でないと 1 文。(c) 「テストの回し方」に `### CI`（トリガー = PR → main / push main、ジョブ 3 つの表 = Linux は compose 3 台で PG17/PG14 両方・macOS は brew `postgresql@17` 1 台 + Python blackhole で PG14 なし・leak の RSS 検査は
  Linux 専用で SKIP、待ち上限 3 値 = ジョブ 45 分 / `--wait-timeout 180` / `pg_ctl -w -t` 60 秒、artifact `pq-conda-<os>` と `final-check-log-<os>`、Windows ジョブ不在の理由、fork PR は未検証）。(d) `### ブランチ保護（人間が設定）`（画面手順 + `protection.json` の
  `required_status_checks.contexts` にジョブ名 3 つ + `gh api -X PUT`。「無人ターンは設定しません」を明記 = D15）。(e) `### リリース手順（人間が行う）` 5 手順（CHANGELOG → `version` → main マージ → `v` 付きタグ push → `release.yml` の 3 ジョブ。modular-community は「将来の経路」1 行）。
  (f) 「概要と対応環境」に CI 行。検証: **`pixi run check` 6/6 PASS = 176 s**（rc 0 / `final_check: PASS`。閾値 247 s）。チェックリストの T5 行 22 key すべて期待値（`readme_h2` = 10 → **11**、`readme_en_heading` = 1、`readme_git_dep` = 2、`readme_tag_v010` = 3、
  `readme_preview_pixi_build` = 4、`readme_windows_toolchain` = 1 → 2、`readme_fork` = 1 ほか）。turn 6 のログとの差分は **`readme_*` だけ**（`trace_checklist_section` 3 → 4 は turn 6 が checklist 後に TRACE を書いたため）。生出力と根拠表は TRACE の turn 7 の 3 節へ
- 想定外: なし（turn 6 の「次への注意」どおり、key と衝突する文字列を**書く前に**避けた: CI 小節では「6 段」を使わず「`tests/final_check.sh`」「1 工程」、待ち上限は「3 段階」、経路は「3 つあり」と表記して `readme_six_stages` = 1 / `readme_compose_three` = 2 を保った。
  turn 5 / 6 で 2 回続いたコメント混入の再発は 0 回）。`py_compile` を回していないので `__pycache__` も発生せず
- やり直し: 0 回（既存テストの期待値変更も 0 件）
- 次への注意: 残りは **T6（統合 + push）のみ**で、コード変更は無い見込み。手順は (a) `pixi run db-reset` → `pixi run check` を `date -Iseconds` で挟んで ≤ 247 s を確認 → `pixi run package` 警告ゼロ → `pixi build -o dist`（`.conda` 1 個）→ `pixi install --locked` →
  `git diff --quiet main -- pixi.lock`、(b) `actionlint` 2 本 + チェックリスト**全行**（差分が出た行は TRACE に PLAN 訂正として）、(c) TRACE「受け入れ基準対応表」= REQ §4 の A1〜F2 を 1 行ずつ（**CI 依存の B2 / B3 / B4 / B6 / C3 / F の CI 側は「verify の PR で確認」と明記**し、
  impl が静的に確認できた分と分ける）、(d) PROGRESS の最新ターン節 ≤ 40 行（`python3 -c` のワンライナー。**この turn 7 の節は 16 行**なので T6 も同程度に収める）、(e) `git status` clean → `git push -u origin gsd-lite/phase6-packaging-ci` → `git status -sb` に `ahead` なし →
  `gh run list --branch gsd-lite/phase6-packaging-ci --limit 5` が **0 件**（P15 の陽性対照。走っていたら `on:` を見直す）、**PR は作らない**（verify の仕事）。(f) TRACE「verify への申し送り」も T6 で記入（PLAN T6 (f) の 5 項目）。
  `pixi build -o dist` は T2 以降 `dist/` へ出すので `git status` を汚さない（`.gitignore` 済み）が、`build/` と同様コミット前に `git status --short` を必ず見る
