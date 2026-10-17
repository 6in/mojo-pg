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

## turn 2 — plan — 7 タスク（T1 持ち越し整理 / T2 ENCODING + 先行チェック / T3 wait_notifications + 契約外テスト / T4 Windows / T5 bench / T6 README + LICENSE / T7 統合）
- やったこと: REQ / DECISIONS / RESEARCH / 直近 2 件の reflect / HANDOFF §5.1・§8・§10 と `src/pq` `tests` `examples` `pixi.toml` の実物を読み、PLAN.md（検証コマンド、チェックリスト 29 行、
  決めた事項 20、採否表 9 行、P1〜P20 の対応先）を作成。チェックリストは実行可能スクリプト `scratch/turn-002-checklist.sh`（82 key）にして現在の木で 1 回実行（`scratch/turn-002-checklist.log`）。
  行番号・件数はすべて grep / Read の結果（`TYPE_MISMATCH` の基線 src 125 / tests 97 は RESEARCH と一致）。サブエージェント 0 本
- 想定外: (1) RESEARCH §6 の T2 は src 5 + tests 3 ファイルに `wait_notifications` の 11 件が乗る規模で、1 ターンを超える見込み → T2 / T3 に分けて 7 タスクにした。
  (2) `examples/` の docstring で `pixi run` を書いているのは `bench_formats` の 1 本だけ（RESEARCH §2.9 は「実行方法が無いのは hello_libpq」と書いたが、`pixi run <task>` の明記は 6 本に無い）→ T1 / T6 で 7 本に揃える。
  (3) チェックリストの `ENCODING` パターンが `PGCLIENTENCODING` / `ENCODING 'SQL_ASCII'` に当たったので `PgErrorKind.ENCODING` 等に絞った（スクリプト修正 1 回）。
  (4) `curl` と `md5sum` は allowlist に無い → LICENSE は `pixi run python <scratch .py>` で取得（決めた事項 12）
- やり直し: 1 回（チェックリストの `ENCODING` パターンを絞って再実行。上記 (3)）
- 次への注意: impl は先頭の未完了タスク T1 から。T1 (b) は修正前に 1 回走らせて `TIMEOUT` で落ちることを見る（陽性対照）。T1 (d) は `_open(_conninfo())`（`pq_test` 側）から発行し、
  `conn.transaction()` の中では発行しない。`close(PQsocket)` 後〜`__del__` の間に fd を開かない。PLAN 訂正は `TRACE.md`「PLAN 訂正（turn N）」節に 1 件 1 行（表のセルに書かない）。
  時間は単位付き（TestSuite は ms）。bench（T5）は `check` 直後に測らない

## turn 3 — impl — T1 持ち越し整理 + hello_libpq 堅牢性 + TRACE.md 新設
- やったこと: `fetch_all` のドレイン打ち切りを `e.kind == CONNECTION or PQstatus == BAD` に（+ docstring）、`test_async` に `close(PQsocket)` 方式のテスト 1 件（30 → 31 件）、
  `_after_send` の -1 分岐を `BUSY` に置いてから raise（+ 到達不能の根拠を docstring）、`test_notify` に `_drop_ascii_database()`（先頭 + 2 テスト末尾、`42P04` 容認を削除）、
  `pixi.toml` に `db-reset`、`examples/hello_libpq.mojo` を `def main():` + `try/except` + `exit(1)` に、`.gsd-lite/TRACE.md` 新設（7 節の見出し + 2 節を記入）。コミット `e40c69e`。
  サブエージェント 推奨 1 本 / 実 1 本（A = (d)(e) の `tests/test_notify.mojo`）
- 陽性対照（3 件すべて成立）: (b) 修正前の `test_fetch_all_stops_draining_on_a_closed_socket` は **2003.537 ms で `kind=Timeout`** の FAIL → (a) 投入後 **3.851 ms で PASS**。
  (e) 末尾 DROP をコメントアウトした scratch コピー（`scratch/turn-003-notify-nodrop.mojo`）を 54317 で 1 回 → `pq_test_ascii` が **1 行残る** → 本物の `test_notify` を走らせて **0 行**に戻る
  （先頭の `IF EXISTS` が回収した）。(c) は到達不能なのでコードレビュー（TRACE.md「`_after_send` -1 のコードレビュー」節に libpq の根拠 3 行 + 実測 B を転記）
- 検証と所要（単位付き）: `pixi run test` 両サーバー PASS（**既存テストの期待値変更ゼロ**。変えたのは (d) の docstring と追加分だけ）、`test_notify` は 54317 / 54314 とも **3 s**、`test_async` は **7 s**。
  `pixi run package` 警告ゼロ。`pixi run db-reset` exit 0 で **3 s**（3 コンテナ `Up` + pg17/pg14 healthy、直後の `pixi run db-up` は **0 s** で即終了）。
  `pixi run check` **6/6 PASS、185 s**（閾値 247 s 以内、見込み 180〜210 s の下限寄り）。`docker exec ... psql` が **pg17 / pg14 とも 0 行**（`pq_test_ascii` が残らない）。
  `pixi run hello-libpq` は `PQlibVersion = 180006 (PostgreSQL 18.6)`、`PQ_MOJO_LIBPQ=/nonexistent/libpq.so` 付きは `failed: PgError(kind=LibpqLoad, ...)` の 1 行 + **終了コード 1**、
  `Unhandled` / `stack trace` / `Traceback` は **0 件**（`scratch/turn-003-hello-nolib.log`）。
  チェックリストの T1 行は全行期待値（`async_fetch_all_kind_connection`=1 / `async_after_send_left_at_idle`=0 / `async_after_send_PGASYNC_BUSY`=1 / `test_async_tests`=31 / `test_async_close_call`=1 /
  `notify_drop_ascii_calls`=4 / `notify_with_force`=2 / `notify_42P04`=0 / `pixi_db_reset`=1 / `hello_raise_error`=0 / `examples_raise_error`=0 / `hello_def_main_plain`=1 / `hello_pixi_run`=1 /
  `trace_exists`=exists / `trace_zero_copy`=4 / `examples_pixi_run`=2）。生ログ: `scratch/turn-003-{check,test,checklist,db-reset,hello-nolib}.log`
- 想定外: (1) サブエージェント A が開始した時点で pg17 に**前の実行の `pq_test_ascii` が残っていた**（research turn のプローブの残骸）。A が先に手で DROP してから陽性対照を測ったので
  対照は有効。この残骸自体が「末尾 DROP が無いと残る」ことの裏づけでもある。(2) `PQ_MOJO_LIBPQ=... pixi run ...` の形（先頭の変数代入）は無人シェルの作法で禁止なので `env PQ_MOJO_LIBPQ=... pixi run ...` を使った（通った）。
  (3) `/usr/bin/time` が無い → `bash -c 'S=$(date +%s); ...'` で計測した。(4) `test_notify` 実行中に stderr に `NOTICE: database "pq_test_ascii" does not exist, skipping` が 1 行出る
  （2 件目の ASCII テストの先頭 DROP。1 件目の末尾 DROP が効いている証拠）。`check` の 6/6 段のパターン（`warning:|WARNING:|implicit ROLLBACK failed`）には当たらず 0 件のまま
- やり直し: 0 回
- 次への注意: 次は T2（`ENCODING` + `notifications()` 先行チェック + UTF-8 4 バイト境界）。**既存テストの期待値を 7 行変える唯一のタスク**なので、変えた行と理由を PROGRESS に全部列挙する
  （`test_notify.mojo:492,534` と `test_decode_binary.mojo:470,481,489,497,538`。行番号は T1 で `test_notify.mojo` が +32 行ずれたので **grep で取り直す**）。
  docstring 16 行は `grep -n -B2 -A2 'UTF-8' src/pq/*.mojo` で複数行 docstring も拾う（同一行 grep だけでは漏れる）。`_reject_lost` は `notifications` / `wait_notification` の 2 入口に入れ、
  T3 で `wait_notifications` が 3 つ目になる。`env VAR=... pixi run ...` が使える。`check` は 185 s が基線
