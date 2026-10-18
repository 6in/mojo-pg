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

## turn 8 — impl — T6 統合（クリーン状態からの最終判定 + チェックリスト全行 + TRACE 対応表 + branch push）
- やったこと: コード変更 0。(a) `pixi run db-reset`（compose 3 台を `-v` で作り直し、3 台 `Healthy`）→ **`pixi run check` 6/6 PASS = 170 s**（11:17:29 → 11:20:19。閾値 247 s）、
  `pixi run package` 警告ゼロ、`pixi build -o dist` は初回が `Skipping (already exists)` だったので **`.conda` を消して再生成**（rc 0 / `pq-0.1.0-he8cfe8b_0.conda` 1 個）、`pixi install --locked` rc 0、
  `git diff --quiet main -- pixi.lock` rc 0（P3）、`mojo format` 差分なし（`check` 1/6 段）。(b) `actionlint` 2 本とも指摘 0、チェックリスト **全 101 key が期待値**（turn 7 との差分は
  `trace_checklist_section` 4 → 5 のみ = turn 7 が checklist 後に TRACE を書いたため。**PLAN 訂正は 0 件**）。(c) TRACE に「受け入れ基準対応表」（REQ §4 の A1〜F2 を 1 行ずつ、
  impl が確認した証跡と **verify の PR で確認**する分を列で分離 = CI 依存は B1〜B4 / B6 / C3 / F1 の CI 側）と「verify への申し送り」6 項目、「`check` の所要（turn 8）」「パッケージング再確認」「チェックリスト（turn 8）」を追記。
  (e) commit → `git push -u origin gsd-lite/phase6-packaging-ci` → `git status -sb` に `ahead` なし、`gh run list --branch gsd-lite/phase6-packaging-ci --limit 5` が **0 件**（P15 の陽性対照 = push では CI が走らない）。PR は作っていない（verify の仕事）
- 想定外: (1) **`skipped 1` の正体がこれまでの申し送りと違った**。turn 4〜7 の PROGRESS は 54314 の 1 件を「PG14 側の leak」と書いていたが、実測は 54317 = `SKIP test_interval_infinity_rejected_before_pg17`、
  54314 = `SKIP test_interval_infinity_on_pg17_and_later` の**サーバー版差による対称な 1 件ずつ**で、`test_leak.mojo` のファイル skip は `run_tests.sh:117` のカウンタ（`^SKIP ` 行だけ）に入らない別行だった。
  これを基に macOS ジョブの skipped 見込みを **15 件**（`_skip_on_macos` 14 箇所 + interval 1）と確定して申し送りに書いた（PLAN T6 (f) の「leak のみが正」は不正確だったので TRACE で訂正）。
  (2) `pixi build -o dist` は同じビルド ID の `.conda` が残っていると再ビルドせず `Skipping` で rc 0 を返す → 現在の木からのビルドを確かめるには一度消す必要がある
- やり直し: 0 回（既存テストの期待値変更も 0 件）
- 次への注意: **全タスク完了 → 次は `/gsd-lite-verify`**。verify の入口は TRACE の「verify への申し送り」6 項目（PR 作成 → `gh pr checks <PR> --watch` 上限 40 分 / artifact 名 3 + 3 の記録 /
  macOS の skipped **15 件**見込み / A2 git 経路を `https://github.com/6in/mojo-pg.git` + `branch` で再実測 / 2 回目 push で `Cache restored` / 堅牢性格子は任意）。
  **CI の初見は PR なので、落ちたら差し戻しの F タスク**（REQ §6）。ローカルで固定された基線は `check` 170 s・6/6 PASS・Linux 両サーバー `skipped 1`・`.conda` 1 個（`he8cfe8b_0`）・lock 不変。
  `pixi build` の再生成は `dist/*.conda` を消してから回す（上の想定外 (2)）

## turn 9 — verify — 差し戻し（指摘 1 件 = F1 setup-pixi 入力）/ PR #1 作成済み（https://github.com/6in/mojo-pg/pull/1）/ CI 3 ジョブとも setup-pixi で赤
- やったこと: diff 全体（コード・YAML・スクリプト 5 本・README・CHANGELOG）をレビュー + セキュリティ + 堅牢性格子（スクリプト argv / CHANGELOG 内容）。ローカル最終判定: `db-reset` → **`check` 6/6 PASS = 169 s**、
  `pixi build` 再生成 1 個、`pixi install --locked` rc 0、lock 不変、actionlint 0、チェックリスト 101 key すべて期待値（差分は `trace_checklist_section` 5 → 6 のみ）。**A2 の git 経路を GitHub URL で再実測 → PASS**（`scratch/turn-009-consumer-git.log`）。
  PR #1 を作成 → CI 起動（B1 のジョブ名 3 つ確認）→ **3 ジョブとも `setup-pixi@v0.11.2` が 5〜9 s で `Cannot cache without running install`**。VERIFICATION.md（判定表 / 指摘表 / 残留リスク 7 / round 2 の確認 6 項目）を書き、PLAN に F1 を追記。サブエージェント 0 本
- 想定外: (1) setup-pixi は `run-install: false` のとき `cache: true` だけでなく **`locked: true` も拒否する**（v0.11.2 `options.ts:207-217` を `gh api` で読んで確定。`cache` の既定は true なので省略では直らない）。RESEARCH P12 の「未検証」がそのまま赤になった。
  `cache` だけ直すと次の run が `locked` で落ちるので、F1 は両方を 1 回で直す。(2) ローカル `check` を回しながら PR を作ったため CI とローカルが並行し、所要が短縮できた（CI は 10 s で落ちたので待ち時間ゼロ）
- やり直し: 0 回（既存テストの期待値変更 0 件）
- 次への注意: impl は F1 だけ（YAML 4 箇所 + コメント + TRACE / PLAN 訂正）。**`cache: false` を明示し `locked: true` を削る**（省略不可）。コメントに key パターンの文字列を書かない。push 後に `gh run view <run-id>` で setup-pixi ステップの ✓ だけ確認（全ジョブ完了は待たない）。
  verify round 2 は VERIFICATION §7 の 6 項目（`gh pr checks 1 --watch` 上限 40 分 / `final-check-log-*` の `skipped`（macOS 15 件見込み）/ artifact 3 つの `.conda` 名 / macOS の `LibpqLoad` 有無 = 残留リスク 2 の判定 / F1 の回帰 grep）。
  macOS が `LibpqLoad` で赤なら修正は `PQ_MOJO_LIBPQ` を macOS ステップの env に足す（VERIFICATION §6-2）。PR 本文の「VERIFICATION の要約」は round 2 の合格時に `gh pr edit 1 --body-file` で更新する

## turn 10 — impl — F1 setup-pixi の入力を run-install 無効と両立する形に直す
- やったこと: `ci.yml` 1 箇所 + `release.yml` 3 箇所の `prefix-dev/setup-pixi@v0.11.2` の入力を `pixi-version` / cache 明示オフ / install 無効の 3 行に統一（旧 2 入力を削除）。
  設計は **A = 手動 install 維持**（lock の強制は既存の `retry.sh 3 15 pixi install --locked` が担うので REQ §2.5 のリトライ要件はそのまま）。`ci.yml:50-53` のコメントを実態に書き換え、
  PLAN の表 `:82` と決めた事項 5 を訂正、TRACE に turn 10 の 3 節（PLAN 訂正 2 件 / F1 の変更と検査表 / チェックリスト）。検証: `actionlint` 2 本とも指摘 0、cache 明示オフ **1 / 3**、旧 2 入力 **0 / 0**（grep rc 1）、
  **`pixi run check` 6/6 PASS = 175 s**（11:38:33 → 11:41:28、閾値 247 s、`final_check: PASS`、6/6 段 `matched lines: 0`、Linux 両サーバー `skipped 1`）、チェックリスト 101 key は turn 9 と **`ci_locked_true` 1 → 0 の 1 行だけ**差分。
  commit `2c89fb9` → push → PR #1 由来の run **39091056281** が 1 件増え、**3 ジョブとも `Run prefix-dev/setup-pixi@v0.11.2` が success**（F1 の期待結果どおり。全ジョブの完了は待たない = 緑 / 赤の判定は verify round 2）
- 想定外: (1) push 前の時点で **PR #1 に知らない run `39090682281`（02:36 UTC・`ce34301`・failure 20 s）が 1 件増えていた**（turn 9 が作った `39090199560` とは別。再実行と思われる）。F1 の判定は自分の push で増えた `39091056281` だけを見た。
  (2) コメント初稿が `retry.sh` に触れて `ci_retry_sh` が 1 増えた（やり直し参照）
- やり直し: 1 回（`ci.yml` のコメント初稿が `retry.sh` に 2 回触れて `ci_retry_sh` が 4 → 5 になった → 「the install step below」に言い換えて 4 に戻した。turn 5 / 6 と同型のコメント混入。既存テストの期待値変更は 0 件）
- 次への注意: 次は **`/gsd-lite-verify`（round 2）**。VERIFICATION §7 の 6 項目のうち **「2 回目の run で `Cache restored`」は無効**（F1 でキャッシュを使わない設計にした = TRACE「PLAN 訂正（turn 10）」②）。
  残る確認は `gh pr checks 1 --watch`（上限 40 分）/ `final-check-log-*` の `skipped`（macOS 15 件見込み・Linux 1 件）/ artifact `pq-conda-*` 3 つの `.conda` 名 / macOS の `LibpqLoad` 有無（残留リスク 2。赤なら `PQ_MOJO_LIBPQ` を macOS ステップの env に）/
  F1 の回帰 grep（cache 明示オフ 1 + 3、旧 2 入力 0）。環境キャッシュ無しで毎 run の取得が +1〜3 分増える見込み。PR 本文の更新は round 2 合格時に `gh pr edit 1 --body-file`。
  **この申し送り / state のコミットは push していない（`ahead 1`）**: `ci.yml` の `concurrency` は `cancel-in-progress` なので、いま走っている run `39091056281` の最中に push すると**その run が cancel される**。
  verify は run `39091056281` の結果を取り切ってから push すること

## turn 11 — verify（round 2）— 差し戻し（指摘 1 件 = F2 macOS の poll セマンティクス）/ PR #1 の run 39091056281 は Linux 2 ジョブ緑・macOS 赤（2 テスト）
- やったこと: F1 の回帰（`cache: false` 1 / 3、旧 2 入力 0 / 0、actionlint 0、チェックリスト 101 key は `trace_checklist_section` +1 のみ）、ローカル `db-reset` → **`check` 6/6 PASS = 170 s**。
  CI を `gh pr checks 1 --watch` で待ち、3 ジョブとも setup-pixi / install 通過（F1 は効いた）。**Linux x86_64 9m52s / aarch64 8m26s とも緑**、`.conda` は `hb0f4dca_0` / `he8cfe8b_0`（名前は異なる = P5 OK）。
  **macOS は `check` 5/6 段で 2 テスト赤**（`test_connect_failures_name_their_cause` が `connection socket closed (POLLHUP/POLLERR)`、`test_socketpair_peer_close_sets_hangup_both_ways:215` の `writable`）。
  artifact 5 つとジョブログを `scratch/turn-011-*` に落として原因を特定: macOS の poll は POSIX どおり `POLLHUP` と `POLLOUT` を排他にする（Linux は両方立てる）。`wait_writable` の hangup 分岐が libpq より先に落とし、`test_poll` の期待値は Linux 固有。
  VERIFICATION §0（round 2）と PLAN F2（設計 A = hangup / error だけでも return して libpq に原因を言わせる + test_poll の `writable` assert を Linux 限定）を書いた。
  macOS の良い知らせ: `LibpqLoad` 0（残留リスク 2 解消）、blackhole accepting で timeout テスト PASS（3 解消）、skipped 15 = 申し送りどおり、brew PG 12 s、install 3 s（キャッシュ無しの代償は無視できる）。サブエージェント 0 本
- 想定外: (1) **macOS の赤はワークフローではなくライブラリの OS 差**（Phase 4 で Linux だけで実測した poll の flags 組み合わせ）。REQ §6「CI 固有の失敗は verify の差し戻しで直す」の想定内だが、F タスクが src に触る初めてのケース。
  (2) `gh run view --log-failed` は run 全体が完了するまで使えない（macOS だけ先に落ちた状態では `still in progress`）→ `if: always()` の `final-check-log-*` artifact と `gh api .../jobs/<id>/logs --allow-escape-sequences` で代替できた（T3 の設計が効いた）。
  (3) ローカルの `final_check.log` には `final_check: PASS` 行が入らない（stdout のみ）。合否は 6/6 段の見出しとバックグラウンドタスクの rc 0 で判定
- やり直し: 0 回（既存テストの期待値変更 0 件。差し戻しのため PR 本文の更新・push はしていない）
- 次への注意: impl は **F2 だけ**（`async_conn.mojo` の `wait_readable` / `wait_writable` 2 メソッド + `tests/test_poll.mojo` 1 テスト + TRACE「F2」節）。期待結果は PLAN F2 (e) の表が正。**ローカル（Linux）では F2 の (a) は観測できない**ので、
  完了基準は「汎用メッセージが src から消える（grep 0）+ 既存テスト全 PASS + 3 呼び出し側の busy loop 否定をレビューで書く」。macOS の PASS は verify round 3 が CI で判定する。
  push は **turn 10 / 11 の未 push コミット 2 つ + F2** を一緒に（`ahead 2` の状態。run `39091056281` は完了済みなので cancel の心配なし）。push 後は全ジョブの完了を待たない（F1 と同じ）。
  verify round 3 の確認項目は VERIFICATION §0.7 の 5 つ（3 ジョブ緑 / macOS の `.conda` 名 / F2 回帰 grep / F1 grep 不変 / 合格時 `gh pr edit 1 --body-file`）

## turn 12 — impl — F2 macOS の poll セマンティクス（POLLHUP と POLLOUT の排他）に追従
- やったこと: 設計 **A** を実装。`async_conn.mojo` の `wait_readable` / `wait_writable` から「要求方向のビット無し + hangup / error → 汎用 `CONNECTION`」の分岐（各 5 行）を削除し、
  **hangup / error だけでも return** するようにした（残る raise は `fd < 0` の `CONNECTION "no socket"` と `TIMEOUT`、`poll_socket` の `USAGE` のみ）。両 docstring の本文と `Raises:` を実態に書き換え、
  汎用メッセージは src から消えた（`grep -c 'POLLHUP/POLLERR'` = **0**）。`src/pq/__init__.mojo:290` の表は 3 種とも残るので不変。呼び出し側 3 箇所はコード変更なしで、
  次の libpq 呼び出しが必ず失敗を報告する（busy loop なし）ことを TRACE「F2」(b) の表に各 1 行で記録。`tests/test_poll.mojo` は `writable.writable` の 1 assert だけ `CompilationTarget.is_linux()` 下に移動（hangup 3 assert は両 OS 共通、テスト数 11 不変）。
  検証: test_poll **11 PASS** / test_async **31 PASS**（`test_connect_failures_name_their_cause` 含む）、`db-reset` → **`check` 6/6 PASS = 190 s**（12:02:54 → 12:06:04、閾値 247 s、6/6 段 `matched lines: 0`、`final_check: PASS`、
  両サーバー `SKIP` 1 件ずつ = `test_interval_infinity_*` の PG 版差）、`package` 警告 0、`is_linux` grep = 1、チェックリスト 101 key は turn 11 と **`trace_checklist_section` +1 の 1 行だけ**差分（`src_def_ref_return` 0 / `test_file_count` 24 / `async_*` 1・3・3 不変）。
  PLAN 訂正 0 件。commit `4d9deed`。サブエージェント 0 本
- 想定外: `trace_checklist_section` の +1 は turn 11（verify）が自分の見出しを足した分で、turn 12 の採取時点ではまだ自分の節を書いていなかった（TRACE に注記した）。F2 自体の実装は PLAN の表どおりで想定外なし
- やり直し: 0 回（既存テストの期待値変更 0 件 = 削除した assert はなく Linux 限定に移しただけ）
- 次への注意: 次は **`/gsd-lite-verify`（round 3）**。**push は未実施**（この申し送り / state のコミットと一緒に行う。turn 10 / 11 / 12 の 3 コミットがまとめて PR #1 に載る。run `39091056281` は完了済みなので `concurrency` の cancel の心配はない）。
  **F2 (a) の受け入れはローカル（Linux）では観測できない**: 判定は CI の macOS ジョブで `test_connect_failures_name_their_cause` と `test_socketpair_peer_close_sets_hangup_both_ways` が PASS すること。
  round 3 の確認は VERIFICATION §0.7 の 5 つ（3 ジョブ緑 / macOS の `.conda` 名が他 2 つと重複しないこと = P5 / F2 回帰 grep（`POLLHUP/POLLERR` 0・`is_linux` ≥ 1）/ F1 grep 不変（`cache: false` 1 + 3、旧 2 入力 0）/ 合格時 `gh pr edit 1 --body-file`）。
  macOS が **別の** 赤になった場合は、`wait_*` が return した後にどの libpq 呼び出しがどのメッセージを出したかを `final-check-log-macos-latest` で確かめる（TRACE「F2」(b) の表が予測値）

## turn 13 — verify（round 3）— 差し戻し（指摘 2 件 = F3）/ PR #1 の run 39092567451 は aarch64 緑・x86_64 1 テスト赤・macOS 1 テスト赤（round 2 の 2 件は PASS）
- やったこと: F2 の回帰（`POLLHUP/POLLERR` 0 / `is_linux` 1 / F1 grep 1+3・0 / actionlint 0 / チェックリスト 101 key は `trace_checklist_section` +2 のみ）、ローカル `db-reset` → **`check` 6/6 PASS = 177 s**。
  turn 12 の state コミットは開始時点で既に origin と一致し、その push で起動した run `39092567451` を `gh run watch` で待った（自分では push していない）。F2 は効いた: macOS で round 2 の 2 テスト PASS、`test_poll` 11/11、`skipped 15`、aarch64 Linux 緑（`.conda` `he8cfe8b_0`）。
  新しい赤 2 件を artifact（`scratch/turn-013-{macos,x64,arm}-artifact/`）と `--log-failed` から特定: ① macOS `test_multi_host_conninfo_reaches_the_second_host`（`could not receive data from server: Connection refused`、1.55 ms。round 2 は 7.3 ms で PASS）=
  `start` 直後に待たず `PQconnectPoll` を呼ぶ libpq 契約違反が macOS の競合で表面化し、拒否が `SO_ERROR` 経路（次ホストへ乗り換え）でなく read 失敗（全体失敗）として出た。② x86_64 `test_connect_query_close_does_not_leak` の RSS 系列 `[6205 ×4, 6718 ×5]` = 513 ページの一度きりの段 + 平坦な尾
  （`test_leak.mojo:148-170` が自ら書いている現象で、x86_64 ランナーでは許容 256 を超えた。リークではない偽陽性）。VERIFICATION §R3（指摘表 / 根拠 / 回帰表 / CI 表 / 残留リスク 10〜12 / round 4 の 5 項目）と PLAN F3（`poll_connect` 初回 `NEED_WRITE` + `is_leaking` の形による除外）を書いた。サブエージェント 0 本
- 想定外: (1) **x86_64 Linux が round 2 の緑から赤に転じた**（非決定的な RSS の段。`wait_*` の変更とは無関係 = 同期 `Connection` のループ）。(2) macOS の赤が F2 の対象と別テストで、しかも round 2 では PASS していた = 競合依存。round 2 で「同じクラスを一括で洗う」対象にできなかった種類（結果が確率的）。
  (3) ローカル HEAD が既に origin と一致していた（turn 12 の申し送りは「push 未実施」だったが、ループ側が push した模様）。CI 待ちを push 無しで始められた
- やり直し: 0 回（既存テストの期待値変更 0 件 — F3 で 1 件（`test_manual_connect_polling`）を変える予定として PLAN に明記）
- 次への注意: impl は **F3 だけ**（`async_conn.mojo` フィールド 1 + `poll_connect` / `test_async.mojo` 既存 1 件の締め + 新 1 件 / `test_leak.mojo` `is_leaking` + 設計説明 + 単体 2 件 / TRACE「F3」）。期待結果は PLAN F3 (d) の表が正。**既存テストの期待値変更 1 件を PROGRESS に列挙する**。
  新テスト `…_even_when_refused` は Linux で旧コードが `CONNECTION` を raise する陽性対照なので、実装前に 1 回走らせて赤を見てから直すと確実。`test_leak` 単体はローカル 70〜80 s。push は turn 13 のコミットと一緒に（run 完了済み、cancel の心配なし）。
  **verify round 4 は verify_round 上限**: 赤なら BLOCKED になる。round 4 の確認項目は VERIFICATION §R3.7 の 5 つ（3 ジョブ緑 / macOS `.conda` 名 = P5 / F3 grep とテスト数 32・20・11 / F2・F1 grep 不変 / 合格時 `gh pr edit 1 --body-file`）。
  macOS の multi-host がなお赤なら、メッセージが `connection to server at "127.0.0.1", port 1 failed:` 形か `could not receive data` 形かで機序を切り分ける（VERIFICATION 残留リスク 10）
