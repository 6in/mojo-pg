# RESEARCH — phase6-packaging-ci

調査日: 2026-10-18（turn 1）。対象: `official_docs` + `similar_oss`（state.json）。
開発機: linux-aarch64 / pixi 0.82.0（`/home/parallels/.pixi/bin/pixi`）/ Mojo 1.1.0 / docker compose v5.5.0。
プローブはすべて `.gsd-lite/logs/phase6-packaging-ci/scratch/turn-001-*` に残した（gitignore 済み）。

## 0. 結論サマリ（REQ §6「research のプローブ」4 件 + 重大発見の有無）

| # | REQ §6 の問い | 結果 | 根拠 |
|---|---|---|---|
| (1) | `pixi build` が pixi-build-mojo + Mojo 1.1.0 で通るか | **通る**。`pq-0.1.0-he8cfe8b_0.conda`（462,288 B、中身は `lib/mojo/pq.mojoc` 449.78 KiB だけ）。2 回目以降は約 2 s | §2.1、`scratch/turn-001-pkg/out/` |
| (2) | conda-forge / modular-community に `pq` が無いか | **無い**。conda-forge の `pixi search pq` は `pqdm` / `pqrs` / `htmd-pdb2pqr` / `libpq` だけ。modular-community は `No packages found matching 'pq'`、recipes 70 件にも無し | §1.7 |
| (3) | `ubuntu-24.04-arm` で docker compose が使えるか | **使える**。公式イメージ一覧に Docker / Docker Compose / Buildx / gh あり。`postgres:17` `postgres:14` `alpine/socat` は linux/arm64 版が存在（開発機 aarch64 で稼働中） | §2.6 |
| (4) | macOS ランナーでの PostgreSQL 起動の前例 | **ある**。pgRouting `macos.yml`（`brew install postgresql@17` → `pg_ctl -D $(brew --prefix)/var/postgresql@17 start`）。macOS 15 / 26 イメージとも PostgreSQL は**未搭載**なので brew で入れる。既定の認証が trust なので `pg_hba.conf` を scram に書き換える必要あり（§2.8） | §1.6、§2.8 |

- **重大発見（discuss を覆すもの）: なし**。D2（conda パッケージ + Release）/ D3（3 OS）/ D5（brew PostgreSQL）/ D10（名前 `pq`）はそのまま成立。BLOCKED にしない
- 追加で確定した事実（plan が前提にしてよい）:
  - 利用側 4 経路すべて実測で `from pq import Connection` が通り、`Connection.open` が `PgError(kind=Connection …)` で落ちる（`LIBPQ_LOAD` でない）: path 依存 / git 依存（lock に commit hash）/ `pixi publish` が作る file チャンネル / **ダウンロードした `.conda` を `rattler-index` で索引した file チャンネル**（§2.3）
  - `preview = ["pixi-build"]` + `[package]` を**本物の pixi.toml に足しても `pixi.lock` は変わらない**（`pixi lock` → `Lock-file was already up-to-date`、`pixi install --locked` rc 0）。setup-pixi の `locked: true` 経路はそのまま動く（§2.2）
  - `[package] version = { workspace = true }` が通る → バージョンの出所は `[workspace] version` 1 箇所。`pixi workspace version get` が `0.1.0` を出す（§2.1、§2.12）
  - 生成 `.conda` の `hash_input.json` は `{"target_platform": …}` だけ → プラットフォームごとに別ハッシュ名になり Release の添付名は衝突しない見込み（§2.4）
  - Mojo examples の SIGPIPE: 既定 rc 141 を再確認。`signal(SIGPIPE, SIG_IGN)` + 明示 `write(2)` で rc 1 + `Broken pipe` にできるが、`print` 自体は失敗を報告しない（§2.13）
  - `_collect_notifications`: クライアント側 `close(PQsocket)` では **`notifications()` 側（復元済み経路）が先に `CONNECTION` を投げる**ので `wait_readable` 経路は単一スレッドの試験では到達できない。`_pending` はテストから読める（§2.14）

## 0.5 環境・ハーネス（Phase 5 reflect 提案の転記 + 今回の追加）

- `pixi` は **`/home/parallels/.pixi/bin/pixi` を絶対パスで**（Bash ツールは `.bashrc` を読まない。今回も `pixi: コマンドが見つかりません` から始まった）
- 先頭の変数代入は不可 → `env VAR=… cmd`。`/usr/bin/time` 無し → `date -Iseconds` で挟む
- `curl` / `md5sum` は allowlist 外 → `pixi run python` の `urllib`。今回 GitHub の中身は **`gh api repos/<o>/<r>/contents/<path> --jq .content | base64 -d`** で取れた（allowlist 内）
- Python は fd 1 が閉じていると `sys.stdout` が `None`、`SystemExit` は明示 flush を飛ばす
- lean-ctx（`ctx_*`）は未接続。通常ツールで進めてよい（スキル本文の環境メモ）
- **今回の追加**:
  - プロセス置換 `> >(exit 0)` は Bash ツール直書きではなく**スクリプトファイルにして `bash <file>`** で回す（`scratch/turn-001-sigpipe.sh`）
  - `external_call["write", …]` は **stdlib と同じ署名 `external_call["write", Int](Int, ptr, Int)`** でないと stdlib 側の `print` が `failed to legalize operation 'pop.external_call'`（`std/io/file_descriptor.mojo:75`）で**モジュール全体がコンパイル不能**になる。`c_int` / `Int32` 版は 2 回失敗した
  - Mojo 1.1.0: `fn` 廃止（`def`）、`len(String)` 不可（`byte_length()`）、`external_call` は `std.ffi`（`std.sys.ffi` ではない）、errno は `std.ffi.get_errno`、stderr は `from std.sys import stderr` + `print(..., file=stderr)`
  - `gh api -X GET search/code -f q='…'` でコード検索が使える（認証済み）。`gh api repos/<o>/<r>/releases/latest --jq .tag_name` で最新タグ
  - docker の DB は 9 時間前から起動済みだった（`docker compose ps`）。プローブ前に ps で確認してから使う
  - 本物の manifest を試すときは **feature / environments を落とさない**（bench を落とした縮小版では lock が「古い」判定になり、原因を取り違えかけた）

## 1. 類似 OSS（similar_oss）

### 1.1 ExtraMojo `.github/workflows/main.yml` — CI の雛形（最も近い前例）
- `on: [push, pull_request]`、`strategy.fail-fast: false`、matrix `os: [ubuntu-latest, ubuntu-24.04-arm, macos-14]`
- `prefix-dev/setup-pixi@v0.10.1`（`pixi-version: v0.80.0`, `cache: true`, `locked: true`）→ `pixi run build` → tests → `mojo format` + `git diff --exit-code`
- **`pixi publish --path . --target-dir dist`** で `.conda` を作り、`pixi exec --spec rattler-build=0.76.1 rattler-build test --package-file …` で生成物を検査
- 盗む: 3 OS matrix の形、`pixi publish --target-dir`（`pixi build -o` と同等。どちらも実測で動く）、生成物の事後検査という発想。`timeout-minutes` と `permissions` が無いのは REQ D9 で補う

### 1.2 kszucs/marrow `.github/workflows/release.yml` — タグ → Release
- `on.push.tags: ["v*"]`、`permissions: contents: write`、`needs: test`（reusable workflow）、`setup-pixi@v0.10.2`（`frozen: true`）→ `pixi build` → `softprops/action-gh-release@v2`（`files: marrow-*.conda`, `generate_release_notes: true`）
- 盗む: タグ駆動 + 先にテストを通す構造。本件は CHANGELOG を本文にする（D12）ので `generate_release_notes` は使わず `--notes-file`

### 1.3 thatstoasty/prism `pixi.toml` + `package.yml` — git 依存の実例
- `[dependencies] mog = { git = "https://github.com/thatstoasty/mog.git", tag = "v0.3.3" }`、`[package.run-dependencies]` にも同じ行。`mojo-compiler = ">=1.1.0,<1.2.0"`
- PR 時の `package.yml` は `pixi run mojo precompile prism` だけ（`permissions: contents: read, pull-requests: read`）
- 盗む: README の「git 依存」の書き方（`tag =` で固定）。`mojo-compiler` の範囲指定

### 1.4 sbrunk/duckdb.mojo — C ライブラリを FFI で包む同型
- `platforms` 3 つ（osx-arm64 / linux-64 / linux-aarch64）、`preview = ["pixi-build"]`、`mojo-compiler = "==1.1.0"`（host/build）、backend `pixi-build-mojo` `0.2.*` + channels 明示、`[package.build.config.pkg] name = "duckdb" path = "duckdb"`
- `[dependencies]` に `libduckdb-devel`（本件の `libpq` に相当）。ワークフローは `test.yml` / `codeql.yml`
- 盗む: backend の `version = "0.2.*"` + channels 明示（本件プローブもこの形で通した）。`pkg` を明示する（§2.1 の auto-derive の罠）

### 1.5 NuMojo `pixi.toml`
- `[package.build.config.pkg] name = "numojo"`、host/build/run に `mojo = "==1.0.0"` + `max-core`。古い Mojo 固定なので値は盗まない。形だけ参考

### 1.6 pgRouting `.github/workflows/macos.yml` — macOS ランナーの PostgreSQL 17
```yaml
brew install postgresql@17 postgis boost
brew link postgresql@17
…
pg_ctl -D $(brew --prefix)/var/postgresql@17 start
createuser -s postgres
createdb ___pgr___test___
```
- 盗む: データディレクトリ `$(brew --prefix)/var/postgresql@17`、`pg_ctl` 直接起動（`brew services` は launchd 経由で状態が見えにくい）。本件は `-w -t 60` で待ちに上限を付け、`createuser` の代わりにパスワード付きロールを作る（§2.8）

### 1.7 名前 `pq` の衝突確認（D10）
- conda-forge（`pixi search pq -c conda-forge --platform linux-64`）: `pqdm` / `pqrs` / `htmd-pdb2pqr` / `libpq` のみ。`pq` そのものは無い
- modular-community（`pixi search pq -c https://repo.prefix.dev/modular-community`）: `No packages found matching 'pq'`。`gh api repos/modular/modular-community/contents/recipes` 70 件（ExtraMojo … wgpu-mojo）にも `pq` / `mojo-pq` / `postgres` 系は無い
- → **`pq` のまま**。DECISIONS 追記不要

### 1.8 modular-community の recipe 提出（スコープ外の情報）
- `recipes/<name>/recipe.yaml`（rattler-build）+ test を PR で送る方式。D2 で却下済み。README に「将来の経路」として 1 行書く程度

### 1.9 `ikalnytskyi/action-setup-postgres` — 却下候補
- Linux / macOS / Windows 対応、`postgres-version` 15〜18、出力 `connection-uri`。macOS の導入手段が README から読めず、`pg_hba` の制御もできない（本件は「間違ったパスワードで失敗する」テストがあるので認証方式を自分で決めたい）。brew 直叩きの方が制御しやすい

## 2. 公式ドキュメント + 検証結果（official_docs）

### 2.1 pixi-build-mojo の manifest（docs `pixi.prefix.dev/dev/build/backends/pixi-build-mojo/` + 実測）
- 必須: `[workspace] preview = ["pixi-build"]`（preview 機能。docs に「安定化まで変わりうる」と明記）
- `[package.build] backend = { name = "pixi-build-mojo", version = "0.2.*", channels = ["https://prefix.dev/pixi-build-backends", "https://prefix.dev/conda-forge"] }`。backend は **0.2.8.20261014.1408**（2026-10-14 ビルド）が linux-aarch64 / linux-64 / osx-arm64 の 3 つにある（`pixi search … --platform`）
- `[package.build.config.pkg]`: auto-derive は `<root>/<name>/__init__.mojo` → `<root>/src/__init__.mojo` の順に探す（docs）。本件は `src/pq/__init__.mojo` なので **`name = "pq"`, `path = "src/pq"` を明示**（実測で `mojo precompile src/pq -o $PREFIX/lib/mojo/pq.mojoc` が走った）。`bins` を指定すると `pkg` の auto-derive が止まる等の罠は明示指定で回避
- `mojo-compiler` 1.1.0 は `https://conda.modular.com/max` の 3 プラットフォームにある。host / build / run に `mojo-compiler = ">=1.1.0,<1.2"`、run に `libpq = ">=14"` を書いたところ `index.json` の `depends` が `["mojo-compiler >=1.1.0,<1.2", "libpq >=14"]` になった（利用側に libpq 18.6 が入った）
- **`[package] version = { workspace = true }` が通る**（`scratch/turn-001-pkg-inherit`、同名の `.conda` 生成）。`name` の継承は docs に例あり。`description` / `license` 等も継承可（docs「Most extra fields can be inherited」）。生成物の `about.json` は `{}` だったので、継承行を足して埋まるかは impl で確認（任意）
- 実測に使った最小 manifest（本物の pixi.toml に足す差分）:
```toml
[workspace]
preview = ["pixi-build"]            # platforms の次の行

[package]
name = "pq"
version = { workspace = true }

[package.build]
backend = { name = "pixi-build-mojo", version = "0.2.*", channels = [
  "https://prefix.dev/pixi-build-backends",
  "https://prefix.dev/conda-forge",
] }

[package.build.config.pkg]
name = "pq"
path = "src/pq"

[package.host-dependencies]
mojo-compiler = ">=1.1.0,<1.2"

[package.build-dependencies]
mojo-compiler = ">=1.1.0,<1.2"

[package.run-dependencies]
mojo-compiler = ">=1.1.0,<1.2"
libpq = ">=14"
```
- 所要: 初回（backend 取得 + precompile）1 分未満、2 回目以降 `took 2 seconds`。出力先 `pixi build -o <dir>` はフラット（subdir 無し）。`pixi publish --path . --target-dir dist` も同じ結果

### 2.2 `pixi.lock` への影響（実測 `scratch/turn-001-pkg-full`）
- 本物の `pixi.toml` + `pixi.lock` のコピーに §2.1 を足して `pixi lock` → **`Lock-file was already up-to-date`**、`diff` 0 行。`pixi install --locked` rc 0。`pixi run package` もそのまま動く（A4 の前提）
- 注意: bench feature / environments を落とした縮小版では `lock file not up-to-date` になった。lock は feature 構成に敏感で `[package]` には鈍感

### 2.3 利用側 4 経路（REQ A2。すべて `scratch/turn-001-consumer-*`、同じ `main.mojo`）
| 経路 | 利用側 pixi.toml | preview 必要 | 結果 |
|---|---|---|---|
| path | `pq = { path = "../turn-001-pkg" }` | 要 | import OK / `PgError(kind=Connection …)` |
| git | `pq = { git = "file:///…/turn-001-pkg", branch = "main" }` | 要 | 同上。lock に `conda_source: pq[…] @ git+file:///…?branch=main#a1976d9…`（commit 固定） |
| file チャンネル（`pixi publish --target-channel file:///…`） | channels 先頭に `file:///…/turn-001-channel`、`pq = "==0.1.0"` | 不要 | 同上。`pixi list` に `pq 0.1.0 he8cfe8b_0 … file:///…` |
| **ダウンロードした `.conda`**（Release 添付の想定） | `.conda` を `<dir>/linux-aarch64/` に置き `pixi exec --spec rattler-index rattler-index fs <dir>` → channels に `file:///<dir>` | 不要 | 同上（`scratch/turn-001-dl-channel` / `turn-001-consumer-dl`） |
- git / path は利用側で backend を取ってソースからビルドする（ネットワーク + 数十秒）。チャンネル経路はビルド無し
- README の推奨順: **git 依存（`tag = "v0.1.0"`）を主**、Release の `.conda` + `rattler-index` を副（手順 3 行）。conda 側の直 URL 依存（`url =`）は docs に見当たらず（PyPI 側のみ）、採らない
- 利用側の `mojo` 依存は `mojo = ">=1.1.0,<2"` のままで `mojo-compiler` / `mojo-python` が入る。`pq.mojoc` は `$CONDA_PREFIX/lib/mojo/`（`std.mojoc` と同じ場所）に置かれ、`-I` 無しで `from pq import …` が解決した

### 2.4 `.conda` の中身・ハッシュ・ファイル名
- zip 構成 `metadata.json` / `pkg-….tar.zst` / `info-….tar.zst`。`info/index.json`: `name pq / version 0.1.0 / build he8cfe8b_0 / subdir linux-aarch64 / depends [mojo-compiler >=1.1.0,<1.2, libpq >=14]`。`info/hash_input.json` = `{"target_platform": "linux-aarch64"}`
- ファイル: `lib/mojo/pq.mojoc` + `share/max/firstActivation`（0 B）+ info のみ。**`examples/` `tests/` `hello.mojo` は入らない**（A3 は `pkg.path = src/pq` の時点で構造的に満たす。verify は zip 一覧で確認: `python3 -c "import zipfile; …"` → `pkg-*.tar.zst` の中は `zstd` が要る。`pixi exec --spec zstd zstd -d -c` か `rattler-build`）
- ファイル名に subdir は入らない。ハッシュが `target_platform` で変わるので 3 プラットフォームの名前は衝突しない見込み（CI の artifact で実確認。衝突したら artifact / Release で `<name>-<subdir>.conda` に改名。rattler-index は `index.json` を読むので改名しても索引できる）

### 2.5 setup-pixi と各アクションの最新版（2026-10-18 `gh api …/releases/latest`）
| アクション | 最新 | メモ |
|---|---|---|
| `prefix-dev/setup-pixi` | **v0.11.2** | inputs: `pixi-version`（既定なし → 最新。**`v0.82.0` に固定**して開発機と揃える）/ `locked`（lock があれば既定 true）/ `cache`（既定 true、lock 必須、key `pixi-<arch>-<sha256(lock)>`）/ `cache-write` / `environments` / `run-install`（既定 true）/ `activate-environment` / `post-cleanup`。**リトライ入力は無い** |
| `actions/checkout` | v7.0.1 | |
| `actions/upload-artifact` | v7.0.2 | `download-artifact` も v7 系 |
| `softprops/action-gh-release` | v3.0.3 | 採らない場合は `gh release create`（§2.12） |
| `nick-fields/retry` | v4.0.0 | `run` 相当の `command` を再試行できるが `uses` ステップは包めない |
| `prefix-dev/pixi` | v0.82.0 | 開発機と同じ |
- リトライの実装: setup-pixi に `run-install: false` を渡し、`pixi install --locked` を `for i in 1 2 3; do … && break; sleep 15; done` の `run` ステップで回す（`pixi build` / `docker compose pull` / `brew install` も同形）。**未確認**: `run-install: false` でも post ステップのキャッシュ保存が効くか → 2 回目の run で `Cache restored` を見る
- リポジトリ設定（`gh api repos/6in/mojo-pg/actions/permissions`）: `enabled: true, allowed_actions: all, sha_pinning_required: false` → タグ指定で可。`default_branch: main`、public

### 2.6 ランナー（docs `github-hosted-runners` + runner-images / partner-runner-images）
| ラベル | OS | arch | public の枠 | 備考 |
|---|---|---|---|---|
| `ubuntu-latest` | Ubuntu 24.04 | x64 | 4 vCPU / 16 GB、無料・無制限 | Docker / Compose あり |
| `ubuntu-24.04-arm` | Ubuntu 24.04 | arm64 | 4 vCPU / 16 GB、**public は無料・無制限** | partner-runner-images: Docker / Docker Compose / Buildx / gh あり。PostgreSQL 無し（不要） |
| `macos-latest` | docs のリンク先は **macOS 26 arm64**（image 20260907、macOS 26.6.2）。macOS 15 arm64（15.7.9）イメージも存在 | arm64 | 3 vCPU / 7 GB | Homebrew 6.0.22 / Python 3.14.7 / gh 2.100 / **bash 3.2.57** / PostgreSQL・socat・docker は一覧に無し（`nc` は macOS 標準の `/usr/bin/nc` が一覧外にある見込み。未確認） |
- `postgres:17` / `postgres:14` / `alpine/socat` の linux/arm64 版は開発機（aarch64）で 9 時間稼働中（`docker image inspect … {{.Architecture}}` = arm64）

### 2.7 GitHub Actions のイベント仕様（docs `events-that-trigger-workflows`）
- **`workflow_dispatch` は既定ブランチにファイルがあるときだけ**（UI の Run ボタンも同様）→ マージ前は使えない。C3 は CI 側の `pixi build` artifact で満たす（REQ §6 の見立てどおり）。release.yml に `workflow_dispatch`（input `dry-run`）を足しておけばマージ後の手動確認に使える
- `pull_request`: `GITHUB_SHA` はマージコミット、`GITHUB_REF` は `refs/pull/N/merge`。同一リポジトリのブランチの PR ではワークフローファイルは PR 側のものが使われる（REQ §6 の前提は成立）
- fork からの PR: `GITHUB_TOKEN` は read-only、`GITHUB_TOKEN` 以外の secrets は渡らない → ワークフローは secrets 不要・`permissions: contents: read` で足りる形にする（D9）。artifact upload はランタイムトークンで動く（未検証。本マイルストーンの PR は同一リポジトリ）
- `push.tags: ["v*"]` の形は docs の `tags` フィルタどおり

### 2.8 macOS の PostgreSQL（Homebrew formula `postgresql@17` 17.11 + pgRouting 前例）
- keg-only。bottle は Apple Silicon の sequoia / tahoe にある。依存 `icu4c@78 krb5 lz4 openssl@4 readline zstd`。`post_install` が **`initdb` を自動実行**（`init_data_dir` → `$(brew --prefix)/var/postgresql@17`、`--locale=en_US.UTF-8 -E UTF-8`、`--auth` 指定なし = **`trust`**、スーパーユーザー = ランナーの実行ユーザー）
- 起動: `"$(brew --prefix postgresql@17)/bin/pg_ctl" -D "$(brew --prefix)/var/postgresql@17" -l "$RUNNER_TEMP/pg.log" -o "-p 5432" -w -t 60 start`（`-w -t` で待ちに上限。REQ D9）
- **認証の罠**: テストは「間違ったパスワードで `password authentication failed`」を要求する（`tests/test_connection.mojo:545,558`、`tests/test_async.mojo:1616-1625`）。trust のままだと接続が通ってしまい FAIL。起動前に `pg_hba.conf` の `host` 行を `scram-sha-256` に書き換える（PG17 の `password_encryption` 既定は scram）。`local`（unix socket）は trust のまま残し、ロール作成はソケット経由で行う:
  - `psql -h "$(brew --prefix)/var/run" -d postgres -c "CREATE ROLE pq SUPERUSER LOGIN PASSWORD 'pq'" -c "CREATE DATABASE pq_test OWNER pq"`（compose の `POSTGRES_USER` はスーパーユーザーなので揃える。テストは一時 DB の作成と `pg_terminate_backend` を使う）。ソケットディレクトリは Homebrew 既定の `/tmp`（`unix_socket_directories` 未設定なら `/tmp`）。`-h /tmp` で可
  - `psql "host=127.0.0.1 port=5432 user=pq password=pq dbname=pq_test" -f tests/fixtures/schema.sql`（中身は `CREATE SCHEMA IF NOT EXISTS pqtest;` 1 行）
  - 陽性対照（ジョブ内の 1 ステップ）: `psql "host=127.0.0.1 user=pq password=WRONG dbname=pq_test" -c 'select 1'` が rc≠0 かつ `password authentication failed` を出す
- `PQ_TEST_CONNINFO="host=127.0.0.1 port=5432 user=pq password=pq dbname=pq_test"`（`key=value` 形式必須: `run_tests.sh` が末尾に ` password=` を足す）
- brew の時間対策: `HOMEBREW_NO_AUTO_UPDATE=1` / `HOMEBREW_NO_INSTALL_CLEANUP=1`。見込み 1〜3 分
- 使う libpq はランナー側の brew ではなく **pixi 環境の conda `libpq`**（loader の探索順は `libpq.5.dylib` が先。`PQ_MOJO_LIBPQ` は不要）

### 2.9 macOS の blackhole 代替（D5）
- `test_async.mojo:66` はポート **54399 固定**。listener が無ければ `SKIP test_connect_blocking_times_out: port 54399 refused`（`:1200`）を出し、`run_tests.sh` が `-- 127.0.0.1:5432 skipped N` に数える（REQ B3 の SKIP 件数はこの行）
- 案 A: `brew install socat` → `socat -u TCP-LISTEN:54399,bind=127.0.0.1,fork,reuseaddr OPEN:/dev/null &`（compose と同じ意味論）
- 案 B（推奨。追加インストール無し）: Python 3.14 で accept して応答しない listener を `nohup … &` で起動。**accept したソケットを閉じずに保持する**こと（閉じると EOF で `server closed the connection unexpectedly` になり、タイムアウト試験にならない）
  ```python
  import socket; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
  s.bind(("127.0.0.1", 54399)); s.listen(16); held=[]
  while True: held.append(s.accept())
  ```
- 検証: macOS ジョブのログで `test_connect_blocking_times_out` が PASS、`skipped` 行の件数が leak の SKIP だけ（§2.10）。立てられなければ SKIP として B3 の後段で可
- ステップをまたぐバックグラウンドプロセスは `nohup … &`（+ `disown`）で起動する。同じ `run` ステップ内で `check` を回せば確実

### 2.10 `final_check.sh` / `run_tests.sh` の macOS 互換
- `final_check.sh` が使う bash 機能: 配列、`read -r -d ''`、`${PIPESTATUS[0]}`、`shopt -s nullglob`、`$SECONDS`、`printf`。**bash 3.2 で全部使える**（`mapfile` / `declare -A` は使っていない）。外部コマンド `cp -r` / `find -print0` / `diff -r -q` / `grep -cE` / `tee -a` / `date '+%z'` は BSD 版で同じ
- compose を呼ぶのは `pixi run db-up` だけで `final_check.sh` 自身は呼ばない → **macOS も `pixi run check` をそのまま回せる**（REQ §2.2「可能な限り final_check.sh を流用」は差分ゼロで満たせる）。`PQ_TEST_CONNINFO` を export すれば `run_tests.sh` は 1 サーバーで回り、examples 6 本も同じ env を読む（`grep -l PQ_TEST_CONNINFO examples/*.mojo` 6 件）
- `test_leak.mojo` は `/proc/self/statm` を使うループを macOS で **`SKIP …: RSS sampling is Linux-only`** にする（`:787`）→ macOS の `skipped` 件数は leak 分 ≥ 1 が平常。verify は「SKIP の内訳が leak と（blackhole 無しなら）timeout だけ」で判定
- 所要: Linux ローカル 165〜215 s。macOS ランナー 3 vCPU + leak 短縮で同程度〜1.5 倍の見込み

### 2.11 docker compose の待ち上限
- `docker compose up -d --wait --wait-timeout <秒>`（compose v2.17+。開発機 v5.5.0 に存在、ランナーも v2 系）。`db-up` タスクに `--wait-timeout 180` を足せばローカルと CI が同じ（REQ D9「DB 起動待ちは上限付き」）。healthcheck 無しの blackhole は running で満たされる
- 事前 `docker compose -f tests/docker-compose.yml pull` をリトライループに入れる（ネットワーク依存）

### 2.12 リリースワークフローの部品
- Release 作成: **`gh release create "$TAG" --title "pq $TAG" --notes-file notes.md <files>`**（`gh` は 3 イメージとも搭載。`env: GH_TOKEN: ${{ github.token }}`、release ジョブだけ `permissions: contents: write`）。`softprops/action-gh-release@v3.0.3` でも可だが第三者アクションが増える。推奨: `gh`
- ソース tarball: `git archive --format=tar.gz --prefix="pq-$VER/" -o "pq-$VER.tar.gz" "$TAG"`（GitHub が自動添付する `Source code (tar.gz)` とは別名で衝突しない）
- タグとバージョンの一致（C2）: `VER="${GITHUB_REF_NAME#v}"; [ "$(pixi workspace version get)" = "$VER" ]`（`pixi workspace version get` は実測で `0.1.0`。`[package] version = { workspace = true }` にしておけば `grep` で 2 行拾う心配が無い）
- CHANGELOG 抽出（C4）: `awk -v v="$VER" '$0 ~ "^## \\[" v "\\]" {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md > notes.md`（空なら失敗させる: `[ -s notes.md ]`）
- 構成: `verify-version`（ubuntu、上の一致確認）→ `build`（3 OS matrix、`pixi build -o dist`、`upload-artifact`）→ `release`（ubuntu、`download-artifact` → tarball → `gh release create`）。`workflow_dispatch` + input `dry-run`（true なら release ジョブをスキップ）でマージ後の手動確認
- CI 側（B4）: 同じ build ステップで `.conda` を artifact 名 `pq-conda-${{ matrix.os }}` に保存。release.yml と ci.yml でビルド手順が二重になる → 共通化は reusable workflow か composite action だが、まず素直に 2 ファイルに書く方が読みやすい（plan 判断）

### 2.13 examples の SIGPIPE（実測 `scratch/turn-001-sigpipe.sh` / `.mojo`）
| ケース | rc | 出力 |
|---|---|---|
| 対照 `hello.mojo` ビルド → `> >(exit 0)` | **141** | 無し（Phase 5 §5.4 の再現） |
| プローブ（`signal(13, SIG_IGN)` + 明示 `write(2)` + `_exit(1)`）→ `> >(exit 0)` | **1** | stderr `stdout write failed, errno=Broken pipe` |
| 同 → 通常 stdout | 0 | 3 行すべて |
| 同 → `/dev/full` | 1 | stderr `… errno=No space left on device` |
- 分かったこと: (a) rc 141 は stdlib `print` が SIGPIPE 既定のまま write する結果で、`cat` / `grep` と同じ Unix の標準挙動。(b) SIG_IGN にすると `print` は黙って失敗し rc 0 になる（**最悪**: 出力が消えて成功扱い）。rc 1 にするには **明示の `write(2)` の戻り値を見る番兵**が要る。(c) その `external_call["write", Int](Int, ptr, Int)` は stdlib と同じ署名でないとモジュールごとコンパイル不能（§0.5）
- 選択肢（REQ E1、plan が選ぶ）:
  - **A. README 明記のみ（推奨）**: 「出力先が先に閉じると rc 141（SIGPIPE）。`head` に繋ぐ用途の標準挙動」を README「既知の制限」に 2 行。コード変更 0、`check` 不変。`bench_psycopg.py` が Python 公式手順で rc 1 を返すのとの非対称は 1 文で書く
  - B. examples 6 本に共通ヘルパー（SIG_IGN + 終了直前の番兵 write + rc 1）: 6 ファイル × 2〜3 行 + ヘルパー置き場（examples 配下に `_common.mojo` を置くと `-I src` の import 経路に乗らない → 各ファイルに複製）。`check` の examples 段は影響なし。Phase 5 の格子 `scratch/…/turn-012-robust-regress.sh` の `> >(exit 0)` 軸の期待値を 141 → 1 に変える
  - A の検証: README の該当 2 行が存在（grep）。B の検証: `bash turn-012-robust-regress.sh` 相当で 6 本とも rc 1 かつ stderr 1 行、通常実行の出力が不変（`diff`）

### 2.14 `_collect_notifications` の `out` 復元（実測 `scratch/turn-001-notify-close.mojo`、pg17）
- 現状のコード（`async_conn.mojo:1623-1659`）: `notifications()` の `except` では `out` → `_pending` の順で復元して raise、`wait_readable` の `except` は `TIMEOUT` なら `return out^`、それ以外は **復元せず raise**
- プローブ: LISTEN → 別接続で NOTIFY ×2 → `wait_notifications(1)` = 1 件（`_pending` 1）→ `close(PQsocket)` → `wait_notifications(2, 500)`:
  ```
  raised kind=CONNECTION  message: could not receive data from server: Bad file descriptor
  pending after raise: 1
  ```
  → ループ 1 周目の `notifications()`（`PQconsumeInput`）が先に `CONNECTION` を投げ、**`wait_readable` の except には到達しない**。`listener._pending` はテストファイルから直接読めた（Mojo にアクセス制御は無い）
- `wait_readable` が raise する条件（`:743-760`）: `socket() < 0`（`CONNECTION`、PQfinish 後のみ）/ poll の `EBADF` / `EINVAL` / `POLLNVAL`（**`USAGE`**。`poll.mojo:228-234`）/ POLLHUP・POLLERR のみで readable 無し（`CONNECTION`）。`pg_terminate_backend` では readable（EOF）になるので `wait_readable` は正常に返り、次の `notifications()` が投げる。単一スレッドの試験では **「`notifications()` が成功した直後に `wait_readable` だけが失敗する」状態を作れない**（close / shutdown / dup2 のどれも `PQconsumeInput` 側が先に落ちる）
- 推奨する直し方: 復元 5 行を `_restore_collected(mut self, out: List[Notification])` に切り出し、両方の `except` から呼ぶ。`wait_readable` 側は `TIMEOUT` 以外**すべて**（`CONNECTION` も `USAGE` も）で復元する
- テスト 1 件（REQ E2）: ヘルパーを直接叩く形が確実。手順: NOTIFY ×2 → `wait_notifications(1)` で `_pending` = [two] → `conn._restore_collected([one'])` → `assert len(conn._pending) == 2` かつ順序 `[one', two]`（古い順）→ 続けて `notifications()` が `[one', two]` を返す（公開 API で観測）。`wait_readable` 経路そのものは到達不能なので、両 except が同じヘルパーを呼ぶことをコードレビュー + grep（`_restore_collected(` が 3 箇所 = def + 2 呼び出し）で担保
- 既存の `test_wait_notifications_keeps_collected_ones_when_a_later_one_is_rejected`（`test_notify.mojo:981`）と `…_across_two_round_trips`（`:1005`）は `notifications()` 側の復元を押さえている。期待値変更なし

## 3. 盗める設計 / 使えるライブラリ（plan が採否表にする）

| # | 候補 | 出典 | 推奨 |
|---|---|---|---|
| 1 | 3 OS matrix + `fail-fast: false` + setup-pixi `cache/locked` | ExtraMojo | 採る |
| 2 | `pixi build -o dist`（= `pixi publish --target-dir`）→ `upload-artifact` | ExtraMojo / marrow | 採る |
| 3 | backend `0.2.*` + channels 明示、`pkg` の `name`/`path` 明示 | duckdb.mojo | 採る（実測済み） |
| 4 | `[package] version = { workspace = true }` | pixi docs + 実測 | 採る（C2 を 1 行にする） |
| 5 | git 依存 `{ git = …, tag = "vX.Y.Z" }` を README の主経路に | prism | 採る |
| 6 | Release `.conda` → `rattler-index fs` で file チャンネル | 実測 | 採る（README 副経路） |
| 7 | `gh release create --notes-file` | docs | 採る（第三者アクション不要） |
| 8 | `softprops/action-gh-release` | marrow | 却下（7 で足りる） |
| 9 | `nick-fields/retry` | — | 却下（bash の `for` ループで同じ。`uses` は包めない） |
| 10 | `ikalnytskyi/action-setup-postgres` | — | 却下（§1.9） |
| 11 | brew `postgresql@17` + `pg_ctl -w -t 60` + `pg_hba` scram 書き換え | pgRouting + formula | 採る |
| 12 | blackhole = Python 3.14 の listener（`nohup`） | 実測なし（ロジックは compose と同じ） | 採る。socat は fallback |
| 13 | `docker compose up -d --wait --wait-timeout 180` | compose docs / 開発機 | 採る（`db-up` タスクに入れる） |
| 14 | `rattler-build test --package-file` で生成物の事後検査 | ExtraMojo | 任意（本件は利用側 smoke で代替。verify の A2 で十分） |
| 15 | reusable workflow で build を ci / release 共有 | marrow | 保留（まず 2 ファイルに素直に書く） |

## 4. 落とし穴と検証方法（plan は完了基準に写す）

| # | 落とし穴 | どう検証すれば踏んでいないと分かるか |
|---|---|---|
| P1 | `preview = ["pixi-build"]` を `[workspace]` に書き忘れ → `pixi build` が `[package.build]` を拒否 | `pixi build -o dist` rc 0、`dist/pq-0.1.0-*.conda` 1 個 |
| P2 | `pkg` を auto-derive に任せる → `src/pq` は見つからない / `bins` を書くと `pkg` が止まる | `.conda` の一覧に `lib/mojo/pq.mojoc` が 1 個（zip 一覧 + `pkg-*.tar.zst`） |
| P3 | `[package]` 追加で lock が古い判定 → `setup-pixi locked` が赤 | ローカル `pixi install --locked` rc 0 かつ `git diff --quiet pixi.lock`（実測: 変わらない。**変わったら feature を落としていないか疑う**） |
| P4 | `version` が `[workspace]` と `[package]` の 2 行になり C2 の grep が 2 件拾う | `[package] version = { workspace = true }`、`grep -c '^version = "' pixi.toml` = 1、`pixi workspace version get` = `0.1.0` |
| P5 | 生成 `.conda` の名前が 3 プラットフォームで同じ → Release 添付が衝突 | CI の 3 artifact のファイル名を VERIFICATION に写し、互いに異なること（同じなら `-<subdir>` 改名） |
| P6 | macOS: trust 認証で「間違ったパスワード」テスト 3 件が FAIL | ジョブ内の陽性対照 `psql … password=WRONG` が `password authentication failed`；`check` ログで `test_open_conninfo_wrong_password_does_not_leak_it` PASS |
| P7 | macOS: PostgreSQL 起動待ちが無限 / `brew` が auto-update で数分 | `pg_ctl -w -t 60`、`HOMEBREW_NO_AUTO_UPDATE=1`。ステップの所要をログで確認（≤ 4 分） |
| P8 | macOS: blackhole の accept 済みソケットを閉じる → `server closed the connection` で timeout 試験にならない | ログに `test_connect_blocking_times_out` PASS（SKIP でない）。Python 版は `held.append` で保持 |
| P9 | macOS: バックグラウンドの listener / postgres がステップ終了で死ぬ | `check` と同じステップで起動するか `nohup … & disown`。ログの `skipped` 行の内訳が leak だけ |
| P10 | `final_check.sh` の bash 4 依存（`mapfile` 等）を今後足す | macOS ジョブが緑であること自体が検査。スクリプトを触るタスクは「bash 3.2 で動く構文のみ」を完了基準に |
| P11 | `docker compose up --wait` が healthcheck 失敗で永久待ち | `--wait-timeout 180`。陽性対照（任意）: `--wait-timeout 1` が rc≠0 で返る |
| P12 | setup-pixi にリトライが無い → ネットワーク失敗で赤 | `run-install: false` + `for` 3 回。2 回目の run で `Cache restored` を確認（`run-install: false` とキャッシュ保存の相性は未検証） |
| P13 | `workflow_dispatch` を頼りに C3 を確認しようとする | C3 は CI artifact で確認（§2.7）。release.yml の dispatch はマージ後の確認用と README に書く |
| P14 | `permissions` を省略 → 既定（write-all になりうる）で D9 違反 | 各ワークフロー先頭に `permissions: contents: read`、release ジョブだけ `contents: write`。`grep -n permissions .github/workflows/*.yml` |
| P15 | `pull_request` の `branches: [main]` 忘れ / `push` に `branches` 忘れでブランチ push ごとに 3 ジョブ走る | ワークフロー YAML の `on:` を目視 + 本マイルストーンの push で run が 1 セットだけ（`gh run list`） |
| P16 | `gh release create` が `GH_TOKEN` 未設定で失敗 | release ジョブ `env: GH_TOKEN: ${{ github.token }}`。マージ前は dry-run 不可なので、YAML レビュー + `actionlint`（`pixi exec actionlint`、conda-forge にあり。任意） |
| P17 | CHANGELOG の見出し形式（`## [0.1.0] - 2026-…`）と awk が合わず本文が空 | ローカルで awk を実行し `notes.md` が非空（`[ -s ]`）。ワークフローも `[ -s notes.md ]` で失敗させる |
| P18 | `.conda` を直接 `pixi add` できると README に書く | README の手順は実測した 2 経路（git tag / `rattler-index`）だけ。verify は README のコマンドを別ディレクトリで実行 |
| P19 | SIGPIPE 案 B で SIG_IGN だけ入れて番兵を忘れる → 出力消失で rc 0 | `> >(exit 0)` で rc 1 + stderr 1 行（格子 `turn-012-robust-regress.sh` の軸）。案 A なら README grep のみ |
| P20 | `_collect_notifications` の復元を `CONNECTION` だけに限定（`USAGE` 経路が残る） | `_restore_collected(` が def + 2 呼び出し = 3 箇所（grep）。テストはヘルパー直叩き + `notifications()` 観測（§2.14） |
| P21 | `check` の所要が 247 s を超える（新テスト + lock 不変で増えないはず） | `date -Iseconds` で挟んで PROGRESS に記録。超えたら理由 |
| P22 | macOS ジョブで `mojo format`（stage 1）が BSD `find` の順序差で diff を誤検知 | `diff -r -q` はファイル単位なので順序無関係。緑なら OK |
| P23 | CI の `pixi build` が backend を毎回ダウンロード（キャッシュ外）→ 1〜2 分 + ネットワーク依存 | リトライループに入れる。所要は許容（timeout-minutes 45 の内側） |
| P24 | fork PR で artifact upload が read-only token で失敗 | 本マイルストーンは同一リポジトリの PR なので対象外。README「CI」節に「fork からの PR でも動く想定（未検証）」と正直に書く |

## 5. 要件への影響（提案。REQUIREMENTS.md 本文は書き換えない）

- **E2 の文言**: 「`wait_readable` が `CONNECTION` で抜ける経路でも `out` を復元する」→ 実測では `wait_readable` 側で起こりうる種別は `CONNECTION` と `USAGE`（§2.14）。「`TIMEOUT` 以外のすべての例外で復元する」に広げ、テストは「復元ヘルパーの単体 + 公開 API での観測」を受け入れ基準にする（経路自体は単一スレッドで到達不能）
- **A2**: 「git 依存または `.conda` のローカルチャンネル。どちらも検証する」→ `.conda` 側は **`rattler-index fs` での索引を手順に含める**（`pixi publish --target-channel` はソースからのビルドなので Release 添付の検証にはならない）
- **B3**: macOS の SKIP 件数には leak の `RSS sampling is Linux-only` が常に含まれる。受け入れは「SKIP の内訳が leak（+ blackhole 無しなら timeout）だけ」と書く方が検査しやすい
- **B5 / D9**: macOS の DB 起動待ち上限は `pg_ctl -w -t 60`、Linux は `--wait-timeout 180`。両方を README「テストの回し方 / CI」に数値で書く
- **C2**: `[package] version = { workspace = true }` を前提に「`pixi workspace version get` とタグの比較」と書ける
- **D4（ブランチ保護）**: required checks の名前は matrix のジョブ名（例 `check (ubuntu-latest)`）。plan で `name:` を固定し、README の `gh api` 例に 3 つの名前をそのまま書く
- **スコープ**: Windows ジョブ無しの理由は HANDOFF §2 の文言（ネイティブツールチェーン未提供）をそのまま引く

## 6. plan への申し送り

- **タスク分割案（7 ± 1）**:
  - T1 持ち越し 2 件（E1 = README 2 行 or ヘルパー、E2 = `_restore_collected` + テスト 1 件）— 他と独立、最初に `check` を回して基線を取る
  - T2 `pixi.toml` の `[package]`（§2.1 の差分 + `db-up` に `--wait-timeout`）+ ローカル `pixi build` + A2 の利用側 2 経路（git tag はまだ無いので branch / path で、verify が PR 後に git ブランチで再確認）
  - T3 `.github/workflows/ci.yml`（Linux 2 ジョブ）+ 共通の build/artifact ステップ
  - T4 ci.yml の macOS ジョブ（brew PG + pg_hba + blackhole + `check`）
  - T5 `release.yml` + `CHANGELOG.md`
  - T6 README（英語節 / インストール / CI 説明 / ブランチ保護手順 / Windows 理由）
  - T7 統合（push → PR 作成は verify の仕事。impl は push まで許可。`gh run watch` で先に見てよい）
- **impl が CI を待たない前提**（REQ §6）なので、T3 / T4 は YAML の静的検査を完了基準にする: `pixi exec actionlint .github/workflows/*.yml`（任意）、`grep` で `timeout-minutes` / `permissions` / `secrets` 不在を数える
- **所要見積もり**: ローカル `check` 165〜215 s（前回末）+ E2 のテスト 1 件 ≈ +1 s。閾値 247 s 据え置き。CI 1 ジョブ: setup-pixi 2〜4 分（初回）+ docker pull 1 分 + check 3〜6 分 + build 1〜2 分 ≈ 8〜13 分、macOS は brew +2〜4 分。`timeout-minutes: 45`
- **チェックリストの key 候補**（`≥` で書く）: `workflows_files ≥ 2`、`timeout_minutes_lines ≥ 4`（3 ジョブ + release）、`permissions_lines ≥ 2`、`secrets_refs = 0`、`restore_collected_sites = 3`、`readme_en_section = 1`、`changelog_010_heading = 1`、`pixi_lock_changed = 0`
- **verify への申し送り**: PR 作成後 `gh pr checks <PR> --watch`；3 artifact のファイル名を VERIFICATION に写す（P5）；macOS の `skipped` 内訳；A2 の git 経路は `{ git = "https://github.com/6in/mojo-pg.git", branch = "gsd-lite/phase6-packaging-ci" }` で別ディレクトリから実測
