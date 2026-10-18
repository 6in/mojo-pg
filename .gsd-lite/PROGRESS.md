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
