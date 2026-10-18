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
