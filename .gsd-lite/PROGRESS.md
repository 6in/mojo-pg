# PROGRESS — phase5-polish-bench-readme

## turn 1 — research — REQ §7 の要実測 7 項目を全部プローブで確定。REQ の事実誤り 2 箇所を訂正
- やったこと: 公式 docs（WSAPoll / WSAPOLLFD / Winsock error codes / psycopg 3 cursors・params・pq・install / PG14 DROP DATABASE / libpq fe-exec・fe-misc・fe-secure ソース / Apache-2.0）
  と conda-forge を調べ、プローブ 6 本 + スクラッチ pixi 環境 1 つで実測（`.gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-001-*`）。RESEARCH.md（§0〜§6、照合表 12 行、落とし穴 20 件）を産出。サブエージェント 0 本
- 想定外: (1) **`test_zero_copy` の「1 テスト 3.4〜3.9 s」は TestSuite の単位（ms）の読み違い**で、性能問題は存在しない（12 件 49〜56 ms、バイナリ実行 52 ms）。
  REQ §1 / §4.5 を訂正した。(2) REQ §1「pixi 環境に python が無い」は誤りで、python 3.15 は mojo の依存で入っている（psycopg が無いだけ）。訂正した。
  (3) `fetch_all` の busy-spin は `close(PQsocket)` で**再現できた**（1500 ms 回って `TIMEOUT`）。Phase 4 の「再現不能」は `pg_terminate_backend` 方式しか試していなかったため。
  (4) `notifications()` は BAD で既に `CONNECTION` を投げる（空リストは返さない）が、libpq の message が呼ぶたびに `connection not open` を 1 行ずつ蓄積する。先行チェックの効果はそこ。
  (5) `hello_libpq.mojo` だけ `raise Error` で `Unhandled exception caught during execution` + `stack trace was not collected` の 2 行が出る（他 6 本は要件どおり）。
  (6) Windows 照合で誤り 1 件: `ret < 0` の後の `get_errno()` は Windows では `WSAGetLastError()` でないと取れない
- やり直し: 0 回（プローブ 6 本はすべて 1 回でコンパイル・実行。`cat /etc/os-release` が lean-ctx のルート制限で拒否 → `lsb_release -ds` に切替、1 コマンド）
- 次への注意: plan は RESEARCH §6 のタスク分割（T1〜T6）と §4 の P1〜P20 を完了基準に写す。`fetch_all` のテストは `close(PQsocket)` 方式（`pg_terminate_backend` では差分が出ない）。
  `notifications()` 先行チェックのテストは「message が伸びない」を断定。`_after_send` -1 は到達不能（libpq ソースで根拠あり）→ コードレビュー担保。
  時間を書くときは**単位を明記**（TestSuite は ms）。bench は `check` 直後に測らない。`pixi.lock` は bench 環境ぶん増える（コミット対象）
