# REQUIREMENTS — phase6-packaging-ci

マイルストーン: `phase6-packaging-ci`（ブランチ `gsd-lite/phase6-packaging-ci`、base `main`）
前提: Phase 0〜5 完了。リポジトリは公開 GitHub `6in/mojo-pg`（Actions 有効、`gh` 認証済み、`main` は origin と同期）。
開発機は linux-aarch64 / Mojo 1.1.0 / pixi 0.82.0。

## 1. 目的（WHAT）

1. **配布物を作る**: `pq` を他プロジェクトから `pixi` で依存指定できる conda パッケージにする（`pixi build`）。
2. **CI を置く**: GitHub Actions で Linux x86_64 / Linux aarch64 / macOS arm64 の 3 プラットフォームを回し、
   既存の受け入れゲート（`pixi run check` 相当）を自動化する。HANDOFF §2「Linux と macOS は CI 必須」を満たす。
3. **リリース**: タグから GitHub Release を作り、ソース tarball と各プラットフォームの `.conda` を添付する。
4. **README**: 「自分のプロジェクトから使う」を pixi 依存指定の書き方（git 依存 / Release 添付の `.conda`）で拡充する。
5. **持ち越し 2 件**（Phase 5 VERIFICATION §6.3）を同梱する: examples の SIGPIPE rc 141、`_collect_notifications` の `out` 復元。

## 2. 要求

### 2.1 パッケージング（conda / pixi build）
- `pixi.toml` に `[package]` と pixi-build-mojo バックエンドの設定を追加し、`pixi build` が `.conda` を生成する。
- パッケージは `src/pq`（`__init__.mojo` を持つディレクトリ）を含む。`hello.mojo` / `examples/` / `tests/` は含めない。
- 利用側の確認: 別ディレクトリの最小 pixi プロジェクトから依存指定（git 依存または生成した `.conda` のローカルチャンネル）で
  `from pq import Connection` が通ることを検証する（research で手段の実在と Mojo 1.1.0 との相性を確認してから plan）。
- 既存の `pixi run package`（`.mojoc`）は残してよいが、README の配布手段としては conda パッケージを主にする。

### 2.2 CI（GitHub Actions）
- マトリクス: `ubuntu-latest`（x86_64）/ `ubuntu-24.04-arm`（aarch64）/ `macos-latest`（arm64）。Windows ジョブは置かない（理由を明記）。
- 環境構築は `prefix-dev/setup-pixi` + `pixi.lock`（ロック尊重）。
- Linux: `tests/docker-compose.yml`（PG 17 / PG 14 / blackhole）をそのまま使い、`pixi run check` を回す。
- macOS: ジョブ内で Homebrew の PostgreSQL（17 系 1 本）を起動し `tests/fixtures/schema.sql` を適用、`PQ_TEST_CONNINFO` でそこを指して
  テストと examples を実行する。PG 14 は macOS では回さない。blackhole（接続を受けて何も返さない listener）は `socat` か `nc` で
  ジョブ内に代替を立てる。立てられない場合は接続タイムアウトのテストだけ SKIP（`SKIP` 行として数える）。
- Linux のゲートは `pixi run check` をそのまま 1 ジョブで回す（ローカルと CI の判定を同じスクリプトに揃える）。
  macOS も可能な限り `final_check.sh` を流用する（compose を呼ばない形で同じ 6 段を通す。差分は research / plan で決める）。
- トリガー: `pull_request`（base `main`）と `push`（`main`）。
- CI ジョブは `pixi build` も実行し、生成した `.conda` をジョブの artifact として保存する（リリース経路のビルド部分を PR ごとに検証するため）。
- Windows ジョブは置かない。ワークフローのコメントと README に理由（Mojo の Windows ツールチェーン未提供）を書く。

### 2.2b リリースワークフロー
- `v*` タグの push で動く release ワークフロー: 3 プラットフォームで `pixi build` → GitHub Release を作成し、`.conda` とソース tarball を添付。
- タグ名（`v0.1.0`）と `pixi.toml` の `version`（`0.1.0`）が一致しないときは失敗させる。
- **タグは人間が打つ**。マイルストーン内ではワークフローの整備と、タグを使わない経路（CI の artifact / `workflow_dispatch`）での動作確認まで。
  v0.1.0 の Release 作成はマージ後に人間が行う。

### 2.2c verify と PR
- verify は `gsd-lite/phase6-packaging-ci` を push して PR を作り、**PR 上の CI が緑になることを合格条件に含める**
  （`gh pr checks <PR> --watch` 等で完了を待ち、赤なら差し戻す）。マージは人間が行う。

### 2.3 持ち越し 2 件
- examples の SIGPIPE: 対応方針（README 明記のみ / examples 側で検知して rc 1）は plan が選ぶ。stdlib の挙動は変えない。
- `_collect_notifications`: `wait_readable` が `CONNECTION` で抜ける経路でも `out` を復元する（1 分岐 + テスト 1 件程度）。

## 3. スコープ外（やらないこと）
- modular-community チャンネルへの recipe 提出（外部リポジトリへの PR。採らない）
- Windows 実機検証・Windows CI ジョブ（ツールチェーン無し。README の「未検証」明記は維持）
- 新しい型・新しい API の追加、HANDOFF §3 の対象外（プール、COPY、配列型 ほか）
- ベンチマークの再計測

### 2.3b ブランチ保護
- main の保護（PR の CI を required status checks にする）は**設定しない**。README（または `docs/`）に `gh api` / 画面での設定手順を書くだけ。
  リポジトリ設定の変更は人間が行う。

### 2.4 配布名・ドキュメント・変更履歴
- conda パッケージ名は **`pq`**（import 名と同じ）。research で conda-forge / modular-community に同名パッケージが無いことを確認し、
  衝突があれば `mojo-pq` に落とす（その場合 DECISIONS に追記して plan へ）。バージョンは `pixi.toml` の `0.1.0` を単一の出所にする。
- README は日本語のまま。先頭近くに**英語の短い概要 + インストール（pixi 依存指定）節**を 1 つ置く。全訳はしない。
- `CHANGELOG.md` を Keep a Changelog 形式で新設し、`0.1.0` の節に Phase 1〜5 の成果の要約を書く。release ワークフローは
  該当版の節を Release 本文に使う。

### 2.5 堅牢性（受け入れ基準に含める）
- 全ジョブに `timeout-minutes` を置く。DB の起動待ちは上限付きで、超えたら明示的に失敗する（ハングしない）。
- `setup-pixi` 等のネットワーク依存ステップは失敗時にリトライする（アクションのオプションか再試行ステップ）。
- ワークフローは **secrets を要求しない**（fork からの PR でも CI が動く。Release 作成は `GITHUB_TOKEN` の既定権限で足りる範囲にし、
  `permissions` を最小にする）。
- CI の判定はローカルの `pixi run check` と同じ基準（同じスクリプト）で、CI だけ緩める・厳しくすることをしない。

## 4. 受け入れ基準

### 4.1 パッケージング
- A1. `pixi build` がこのリポジトリで成功し、`pq-0.1.0-*.conda` が生成される（開発機 linux-aarch64 で実測）。
- A2. 別ディレクトリの最小 pixi プロジェクト（`channels` に conda.modular.com/max + conda-forge）から `pq` を依存指定
  （git 依存、または生成した `.conda` を置いたローカルチャンネル。どちらも検証する）して `pixi install` が通り、
  `from pq import Connection` を使う 1 ファイルが `mojo run` で動く（DB 接続は不要。`PgErrorKind.LIBPQ_LOAD` 以外で落ちない）。
- A3. 生成パッケージに `examples/` `tests/` `hello.mojo` が含まれない。
- A4. `pixi run check` が従来どおり PASS（`[package]` 追加で既存タスクが壊れない）。

### 4.2 CI
- B1. `.github/workflows/ci.yml` が `pull_request`（base main）と `push`（main）で動き、Linux x86_64 / Linux aarch64 / macOS arm64 の 3 ジョブを持つ。
- B2. Linux 2 ジョブは `docker compose`（PG17 / PG14 / blackhole）を立てて `pixi run check` を実行し、`final_check: PASS` で緑になる。
- B3. macOS ジョブは Homebrew の PostgreSQL（17 系）を起動して fixtures を適用し、`PQ_TEST_CONNINFO` でテストと examples を実行して緑になる。
  blackhole 代替が立てられない場合は接続タイムアウトのテストだけ SKIP とし、SKIP 件数がログに出る。
- B4. 各ジョブで `pixi build` が成功し `.conda` が artifact として保存される。
- B5. 全ジョブに `timeout-minutes` があり、DB 起動待ちに上限がある。ワークフローは secrets を参照しない。`permissions` が最小。
- B6. **このマイルストーンの PR 上で 3 ジョブが緑**（verify の合格条件。`gh pr checks` で確認）。
- B7. Windows ジョブが無い理由がワークフローのコメントと README にある。

### 4.3 リリース
- C1. `.github/workflows/release.yml` が `v*` タグの push で動き、3 プラットフォームの `.conda` とソース tarball を Release に添付する構成になっている。
- C2. タグと `pixi.toml` の `version` の不一致で失敗するステップがある。
- C3. タグを使わない経路（`workflow_dispatch`、または CI 側の `pixi build` artifact）でビルド部分の動作が確認されている。
  タグ push と Release 作成はマイルストーン内で**行わない**。
- C4. `CHANGELOG.md` に `0.1.0` の節があり、release ワークフローがその節を Release 本文に使う。

### 4.4 README
- D1. 英語の概要 + インストール節（pixi 依存指定の例）が README 先頭近くにある。
- D2. 日本語の「インストール」節に pixi 依存指定（git / Release の `.conda`）の書き方がある。
- D3. 「テストの回し方」に CI の説明（どこで何が回るか、macOS の差分、Windows が無い理由）が追記されている。
- D4. main のブランチ保護を人間が設定する手順（required checks にする job 名を含む）が書かれている。

### 4.5 持ち越し
- E1. examples の SIGPIPE: plan が選んだ方針（README 明記のみ / examples で検知して rc 1）が実装され、`check` が PASS。
- E2. `_collect_notifications` が `wait_readable` の `CONNECTION` 経路でも `out` を復元する。テスト 1 件追加。

### 4.6 共通
- F1. `pixi run check` が PASS（所要は前回末 165〜215 s + 新テスト分。247 s を大きく超えたら PROGRESS に理由を書く）。
- F2. 警告ゼロ。`mojo format` 差分なし。

## 5. 用語集
- **check**: `tests/final_check.sh`（`pixi run check`）。fmt / precompile / docstring / examples / tests / zero-warnings の 6 段
- **配布物**: `pixi build` が生成する `.conda`（プラットフォーム別）とソース tarball
- **持ち越し**: Phase 5 VERIFICATION §6.3 の残留リスクのうち本マイルストーンで引き取る 2 件

## 6. フェーズ横断の注意（plan / impl / verify 向け）
- **外向きの操作の線引き**: 無人ターンが行ってよいのは `gsd-lite/phase6-packaging-ci` の push と PR 作成・更新だけ。
  タグ push、Release 作成、リポジトリ設定（ブランチ保護・Actions 設定）の変更、main への push はしない。
- **verify の CI 待ち**: PR 作成後 `gh pr checks <PR> --watch`（または `gh run watch`）で 3 ジョブの完了を待つ。上限はおおよそ 40 分。
  赤なら失敗ジョブのログ（`gh run view --log-failed`）の要点を VERIFICATION に写して差し戻す。CI の再実行は `gh run rerun --failed` を 1 回まで。
- **PR 上で CI が走る前提**: ワークフローは PR のブランチ側にあれば `pull_request` で動く（default branch に無くてもよい）。
  `workflow_dispatch` は default branch にファイルが無いと起動できない場合があるので、タグ無し経路の確認は CI 側の `pixi build` artifact を主にする（research で確認）。
- **research のプローブ**: 採る前に実在を確かめる（Phase 5 reflect）。最低限 (1) `pixi build` を実際に 1 回通す（pixi-build-mojo + Mojo 1.1.0）、
  (2) conda-forge / modular-community に `pq` が無いことを確認、(3) `ubuntu-24.04-arm` で docker compose が使えること、(4) macOS ランナーでの PostgreSQL 起動手順の前例。
- **ローカルの開発機は linux-aarch64**。x86_64 と macOS は CI でしか検証できないので、impl は PR 作成前にローカルで `pixi run check` と `pixi build` を通し、
  CI 固有の失敗は verify の差し戻しで直す（impl が CI を待つ必要はない。ただし impl が push して CI を先に見ることは妨げない）。
- **Phase 5 reflect の運用提案を引き継ぐ**: チェックリスト期待値は `≥` で書く／VERIFICATION の指摘表に grep パターン・件数・ファイルの 3 列／
  TRACE.md に「チェックリスト（turn N）」節／PROGRESS の最新ターン節は 40 行以内／サブエージェント完了待ちは `sleep` か完了通知で（mtime ループ禁止）。
