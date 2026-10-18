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

## turn 4 — impl — T2 `PgErrorKind.ENCODING` + `notifications()` 先行チェック + UTF-8 4 バイト境界
- やったこと: `errors.mojo` に `ENCODING = Self(7)`（`write_to` → `"Encoding"`、kind は 8 値）、UTF-8 不正の raise 4 箇所を
  `ENCODING` に（**メッセージ文言は一字も変えず**）、`async_conn.mojo` に `_reject_lost(method)` を追加して `notifications` /
  `wait_notification` の入口（`_reject_connecting` の直後）で呼ぶ、docstring 18 行を `ENCODING` に、テスト 4 件分の変更。
  コミット `5094bcb`。サブエージェント 推奨 1 本 / 実 1 本（A = `tests/` 3 ファイル）
- 既存テストの期待値変更（全 7 行。T2 (c) のとおりで増減なし）: `tests/test_decode_binary.mojo:470,481,489,497,538`
  （`test_text_rejects_invalid_utf8_naming_the_byte_offset` / `_truncated_utf8_sequence` / `_overlong_utf8_encoding` /
  `_utf8_encoded_surrogate` / `test_jsonb_utf8_offset_skips_the_version_byte`）と `tests/test_notify.mojo:519,563`
  （`test_a_payload_that_is_not_utf8_is_rejected_and_dropped` / `test_a_channel_that_is_not_utf8_is_rejected_and_dropped`）。
  **理由はすべて同一**: UTF-8 不正の kind が `TYPE_MISMATCH` → `ENCODING` になったため。文言の断定行（`invalid UTF-8 at byte N`）は不変。
  OID 不一致・幅不一致・jsonb 版数・添字・NULL・numeric・domain の `TYPE_MISMATCH` は 1 行も変えていない
  （`test_decode_binary.mojo:146,159,167,179,197,332,339,390,394,642,650,907,920` と `test_zero_copy.mojo:469,474,551,552`）
- 陽性対照（2 件とも成立）: (d) `_reject_lost` の 2 呼び出しをコメントアウトして `test_notify` を 54317 で 1 回 →
  `test_a_lost_connection_is_reported_with_a_fixed_message` が **FAIL**（left = libpq の `server closed the connection
  unexpectedly ... connection not open`、right = `notifications() called on a lost connection`。
  `scratch/turn-004-notify-nocheck.log`）→ 復帰後 PASS。turn 1 の `probe-notify-bad.log` が示した「呼ぶたびに
  `connection not open` が 1 行ずつ伸びる」が消えたことに対応。(e) U+10FFFF の根拠: UTF-8 DB（54317、`server_encoding: UTF8`）に
  `SELECT E'\xf4\x8f\xbf\xbf'::text` を投げて **受理・4 バイト（244 143 191 191）で round-trip**（`scratch/turn-004-probe-u10ffff.log`）
  → 格子の `_first_invalid("f48fbfbf") == -1` の対照として妥当。`\xf4\x90\x80\x80`（U+110000）はサーバーが拒否するので単体格子のみ
- 検証と所要（単位付き）: `pixi run test` 両サーバー PASS（48 サマリすべて `0 failed`。`test_decode_binary` **88** 件 /
  `test_errors` **9** 件 / `test_notify` **12** 件、所要は両サーバーで 2 s / 0 s / 3 s）、`pixi run package` 警告ゼロ、
  `pixi run fmt` は 52 ファイル無変更、`pixi run check` **6/6 PASS、177 s**（閾値 247 s、基線 185 s を下回る。6/6 段の
  マッチ 0 行）。`docker exec ... psql` は **pg17 / pg14 とも 0 行**。
  チェックリストの T2 行は全行期待値（`errors_ENCODING`=3 / `errors_seven`=0 / `errors_eight`=2 / `errors_write_Encoding`=1 /
  `init_exactly_seven`=0 / `init_ENCODING`=6 / `src_TYPE_MISMATCH`=106（≤ 106）/ `tests_TYPE_MISMATCH`=91 / `src_ENCODING`=27 /
  `tests_ENCODING`=10 / `src_utf8_and_type_mismatch_same_line`=0 / `src_invalid_utf8_raise_sites`=4 / `test_errors_tests`=9 /
  `async_reject_lost_def`=1 / `async_reject_lost_calls`=3 / `async_lost_connection_text`=3 / `test_decode_binary_f4908080`=1 /
  `_f5808080`=1 / `_f48fbfbf`=1 / `test_decode_binary_tests`=88 / `test_notify_tests`=12 / `test_notify_lost_message_fixed`=2）。
  生ログ: `scratch/turn-004-{test,check,checklist,notify-nocheck,probe-u10ffff}.log`
- 想定外: (1) **PLAN 訂正 2 件**（TRACE.md「PLAN 訂正」節に記載）: docstring は決めた事項 3 の 16 行では足りず
  **18 行**（`result.mojo` の `Raises:` 2 箇所が「`TYPE_MISMATCH` ... or when the cell is not valid UTF-8」と 1 項目で
  述べていた。同一行 grep には当たらないので列挙から漏れていた）。`tests/test_notify.mojo` の対象行は T1 のずれで
  `:492,534` → `:519,563`。(2) `tests/test_errors.mojo` と `test_notify.mojo` は `TestSuite.discover_tests[__functions_in_module()]`
  方式で、`main()` へのテスト登録は不要だった（依頼文は手動登録を前提に書いていた）。(3) `src_TYPE_MISMATCH` は目安 105 ではなく
  **106**（`decode_binary.mojo:46` を「`TYPE_MISMATCH` ... except the UTF-8 check, which raises `ENCODING`」に直したので
  同じ行に両方が残る。期待値 ≤ 106 の範囲内）
- やり直し: 0 回
- 次への注意: 次は T3（`wait_notifications(n, timeout_ms)` + 契約外テスト 3 件 + 境界格子）。`_reject_lost` は既にあるので
  `wait_notifications` が **3 つ目の呼び出し元**（`async_reject_lost_calls` 3 → ≥ 4）。入口検査の順は
  `_reject_bad_timeout` → `n < 1` の `USAGE` → `_reject_connecting` → `_reject_lost`（決めた事項 5）。
  `wait_notification` を `_collect_notifications("wait_notification", 1, …)` のラッパにすると turn 4 で追加した
  `test_a_lost_connection_is_reported_with_a_fixed_message` が **`wait_notification()` の文言を完全一致で断定している**ので、
  `method` を取り違えると落ちる（回帰が効く）。`test_notify` のテスト数は 12 → ≥ 21。`check` は 177 s が最新基線。
  `env VAR=... pixi run ...` の形を使う（先頭の変数代入は不可）

## turn 5 — impl — T3 `AsyncConnection.wait_notifications(n, timeout_ms)` + 契約外テスト 3 件 + 境界格子
- やったこと: `async_conn.mojo` に private `_collect_notifications(method, n, timeout_ms)` を置き、`wait_notification` を
  その `n = 1` ラッパに、公開 `wait_notifications(n, timeout_ms)` を `n < 1` の `USAGE` 付きで追加。予算切れは集まった分を
  返し例外にせず（D8）、途中の往復が落ちたら集めた分を `_pending` の先頭に戻してから raise。`__init__.mojo` の API 表 1 行 +
  `## Asynchronous use` 1 文、`test_notify.mojo` に 12 件、`test_async.mojo` に 2 行。コミット `9425933`。
  サブエージェント 推奨 1 本 / 実 1 本（A = `tests/test_notify.mojo` の 11 件 + ヘルパ 3 件）
- 既存テストの期待値変更: **ゼロ**（追加のみ。`test_notify.mojo` は A の 274 行が全部追記で削除 0、既存 12 件は不変。
  `test_async.mojo` は `_wait_notifications_error` の def 1 件と既存 2 テストへの 1 行追加だけで、既存の断定は 1 行も変えていない）
- 陽性対照（判別しなかった 1 件と、それを受けて足した 1 件）: PLAN T3 (c)⑧ は `_collect_notifications` の `except` から
  `out` を `_pending` に戻す 7 行を消しても **PASS**（`scratch/turn-005-notify-norestore.log`）。このマシンは 2 件を 1 往復で
  届けるため `ok` は `notifications()` 内側の `self._pending = found^` で保全され、⑧ は `out` 保全を判別しない
  （PLAN ⑧ の注が予見した経路）。そこで ⑨ `test_wait_notifications_keeps_collected_ones_across_two_round_trips` を追加:
  第 3 の接続から `SELECT pg_sleep(0.3); NOTIFY ...（不正 UTF-8）` を await せず送り、listener が `wait_notifications(2, 3000)`
  に入った後に commit させて 1 往復目を `ok` だけにする。restore 7 行なしで **FAIL**（`turn-005-notify-norestore2.log`）、ありで PASS。
  対照の前後に `diff` で `async_conn.mojo` がバックアップと同一に戻ったことを確認済み
- 検証と所要（単位付き）: `pixi run test` 両サーバー PASS（48 サマリすべて `0 failed`、`FAIL` の行 0。`test_notify` **24** 件 /
  `test_async` **31** 件、所要は両サーバーで 5 s / 7 s）、`pixi run package` 警告ゼロ、`pixi run fmt` 52 ファイル無変更、
  `pixi run check` **6/6 PASS、177 s**（基線 177 s と同値、閾値 247 s 以内）。`docker exec ... psql` は **pg17 / pg14 とも 0 行**。
  チェックリストの T3 行は全行期待値（`async_wait_notifications_def`=1 / `async_n_must_be`=1 / `async_reject_lost_calls`=3（訂正後）/
  `async_reject_lost_def`=1 / `async_lost_connection_text`=4 / `init_wait_notifications`=2 / `test_notify_wait_notifications_calls`=11 /
  `test_async_wait_notifications`=6 / `test_notify_mixed_case`=3 / `test_notify_unlisten`=2 / `test_notify_n_must_be`=2 /
  `test_notify_tests`=24 / `test_async_tests`=31 / `src_def_ref_return`=0 / `tests_files_count`=24）。
  生ログ: `scratch/turn-005-{test,check,checklist,notify-norestore,notify-norestore2}.log`
- 想定外: (1) **PLAN 訂正 3 件**（TRACE.md「PLAN 訂正（turn 5）」節）: `async_reject_lost_calls` の T3 期待値 ≥ 4 → **3（不変）**
  （PLAN の表は `wait_notifications` が 3 つ目の呼び出し元になると見込んでいたが、PLAN (a) 自身が「`_collect_notifications` の中で
  `_reject_lost(method)` を 1 回」「`wait_notification` は薄いラッパ」と定めている。実装どおりなら def 1 + `notifications` 1 +
  `_collect_notifications` 1 = 3）；(c) の格子 **8 件 → 9 件**（上記の陽性対照が理由）；(c) の前提「既存テスト 11 件」→ **12 件**。
  (2) A の報告どおり `_reject_bad_timeout` は下限違反（`-2`）でも上限と同一文面を出すので、格子の `-2` に
  `_assert_timeout_too_large` がそのまま使える（新 API も同じ関数を通しているので一致する）
- やり直し: 0 回
- 次への注意: 次は T4（Windows コードパスのレビュー。`poll.mojo` の `_poll_once` を `Tuple[Int, Int, Int]` 化 +
  `loader.mojo` の `_default_candidates` + TRACE に照合表 12 行 + `else` 分岐の複製ビルド）。**サブエージェント 0 本（親が全部）**。
  雛形は `scratch/turn-001-probe-lang.mojo`（`comptime if` 連鎖で `StaticString` を返す形、コンパイル済み）。
  `test_poll` 11 件は**不変**が完了基準なので `poll failed` の文言を断定しているテストが無いことを
  `grep -n 'poll failed' tests/test_poll.mojo` で再確認してから message を変える。(d) の複製ビルドは通らなくてもよく、
  結果を TRACE に 1〜3 行書けば進める（REQ §3: Windows でのコンパイルは対象外）。`check` は 177 s が基線。
  陽性対照を取るために src を一時的に壊すときは、先に `cp` でバックアップし、戻した後 `diff` で同一を確認する（turn 5 で有効だった）

## turn 6 — impl — T4 Windows コードパスのレビュー（`WSAGetLastError` / `libpq.dll` / 照合表）
- やったこと: `_platform/poll.mojo` の `_poll_once` を `Tuple[Int, Int, Int]`（ret, flags, err）にし、err を
  POSIX は `get_errno().value`、Windows は `external_call["WSAGetLastError", c_int]()` から読む形に。分類を
  `_is_interrupted`（Windows 常に False）/ `_is_usage_error`（POSIX `EBADF` / `EINVAL`、Windows 10009 / 10022 / 10038）の
  2 ヘルパに切り出し、message を `poll failed: errno <N>` に。docstring のシンボル数を two → three、Windows 注記に
  #8（2004 より前は接続失敗が `WSAPoll` に通知されない）と #11（`WSAStartup`）+ 一次資料 URL 3 本。
  `_ffi/loader.mojo` は `platform_map` を `def _default_candidates() -> StaticString` の `comptime if` 連鎖に置き換え
  （Windows = `libpq.dll`）。`TRACE.md` に照合表 12 行 + URL 4 本 + 結び。コミット `814e68b`。
  サブエージェント 推奨 0 本 / 実 0 本（PLAN どおり親が全部）
- 既存テストの期待値変更: **ゼロ**（`tests/` は 1 行も触っていない。`git show --stat 814e68b` の 4 ファイルは
  src 2 + TRACE.md + PLAN.md のみ。`poll failed:` の文言を変えたが `grep -n 'poll failed' tests/test_poll.mojo` は
  0 件で、断定しているテストは無い）
- 陽性対照 / (d) の複製ビルド: `scratch/turn-006-win-typecheck.mojo`（`_WsaPollFd` + `_WSA_POLL*` + `_poll_once` の
  `else` 本体 + `_is_interrupted` / `_is_usage_error` の Windows 側を `comptime if True:` 側に複製）を
  `pixi run mojo build -I src ... -o build/win-typecheck` → **出力ゼロ・exit 0 で 74,472 bytes の実行ファイルが生成**。
  型検査だけでなくリンクも通った（`external_call` は実行時解決）。実行はしていない。
  事前に `scratch/turn-006-errno-probe.mojo` で `ErrNo.{EINTR,EBADF,EINVAL}.value` = 4 / 9 / 22 と
  `comptime if` 連鎖 + 3 要素 Tuple の形が通ることを確認（これが無いと本体を壊してから気づく）
- 検証と所要（単位付き）: `pixi run test` 両サーバー PASS（48 サマリすべて `0 failed`、`FAIL` の行 0。
  `test_poll` **11** 件不変、`test_notify` 24 件 / `test_async` 31 件）、`pixi run package` 警告ゼロ、
  `pixi run check` **6/6 PASS を 2 回**（docstring 言い換えの前後。**182 s** と **215 s**。基線 177 s、閾値 247 s 以内）、
  `pixi run hello-libpq` が `PQlibVersion = 180006 (PostgreSQL 18.6)`、`test_loader_fail` PASS（候補全滅の経路）。
  `docker exec ... psql` は **pg17 / pg14 とも 0 行**。
  チェックリストの T4 行は全行期待値（`loader_libpq_dll`=2（訂正後 ≥ 2）/ `loader_platform_map`=0 /
  `loader_homebrew`=1 / `loader_default_candidates_def`=1 / `loader_CompilationTarget`=3 / `poll_WSAGetLastError`=5 /
  `poll_external_call_symbols`=3 / `poll_get_errno`=2 / `poll_10022`=2 / `poll_only_two_symbols`=0 /
  `poll_win10_2004`=2 / `poll_WSAStartup`=1 / `trace_wsapoll_table`=2 / `test_poll_tests`=11）。
  生ログ: `scratch/turn-006-{test,check,check2,checklist,win-typecheck}.log`
- 想定外: (1) **PLAN 訂正 1 件**（TRACE.md「PLAN 訂正」節）: チェックリストの `loader_libpq_dll` の T4 期待値
  **1 → ≥ 2**（表は RESEARCH §2.4 の `grep -c` 0 → 1 を写していたが、PLAN T4 (c) 自身がモジュール docstring にも
  `libpq.dll` を書くことを完了基準にしている。実測 2）。(2) `loader_platform_map` は最初 **1** だった
  — `_default_candidates` の docstring に「`platform_map` には `windows=` が無い」と識別子で理由を書いたため。
  期待値 0 は「もう `platform_map` を使っていない」という性質なので、理由を保ったまま
  「the stdlib's compile-time platform map」と言い換えて 0 に戻した（PLAN 訂正ではなく実装側の修正）。
  (3) `check` の 2 回目が 215 s（1 回目 182 s）。変更は docstring 1 文の言い換えだけなので同時実行していた
  何かのノイズ。閾値内なので追わない
- やり直し: 0 回
- 次への注意: 次は T5（pixi feature `bench` + `examples/bench_psycopg.py` + `pixi.lock` + 実測ログ）。
  雛形は `scratch/turn-001-pixi/`（`pixi.toml` の 3 ブロックと `examples/bench_psycopg.py` そのもの）。
  **`pixi.toml` は T1 で `db-reset` を足したので差分が重なる**（`[feature.bench.*]` / `[environments]` は
  既存ブロックの後に足す形で衝突しない）。(d) の実測は **`check` の直後に測らない**（REQ §9 / P14）ので、
  `check` を回したあとは数分あけるか、実測 → `check` の順にする。初回の bench 環境作成は 1 分前後かかる
  （`pixi run bench-psycopg` の 1 回目）。`pixi.lock` は**コミット対象**で `git diff --stat pixi.lock` を PROGRESS に。
  受け入れは「Mojo の `decode` 列で binary < text が 2 回とも成立」。`check` の基線は 182 s に更新（閾値 247 s）

## turn 7 — impl — T5 ベンチマーク（pixi feature `bench` + `bench_psycopg.py` + `pixi.lock` + 実測）
- やったこと: `pixi.toml` に `[feature.bench.dependencies]` / `[feature.bench.tasks] bench-psycopg` /
  `[environments] bench = { features = ["bench"], solve-group = "default" }` の 3 ブロックを `[tasks]` の後に追加
  （`scratch/turn-001-pixi/pixi.toml` のコメントごとそのまま。`[dependencies]` は不変）。
  `examples/bench_psycopg.py` は雛形を `cp`（`diff` 一致、先頭 docstring に `pixi run bench-psycopg` あり）。
  実測 → `check` の順で回し、コミット `cab18b2`。サブエージェント 推奨 0 本 / 実 0 本（PLAN どおり親が全部）
- 既存テストの期待値変更: **ゼロ**（`tests/` は 1 行も触っていない。コミットの 4 ファイルは
  `pixi.toml` / `pixi.lock` / `examples/bench_psycopg.py` / `PLAN.md`）
- (a) 環境: `pixi list -e default` の python **3.15.0 h0c7c799_101_cp315** / libpq **18.6 h4d8aa50_3** は不変、
  `pixi list -e bench` は python **3.14.8 hbec3b18_102_cp314** + psycopg **3.3.4 pyh848bd53_0** +
  psycopg-c **3.3.4 py314h3076274_0** + 同じ libpq **18.6 h4d8aa50_3**（solve-group が効いている）。
  `git diff --stat pixi.lock` = `pixi.lock | Bin 62885 -> 91504 bytes`（`.gitattributes` の `-diff` 指定のため
  行数ではなく Bin 表示。`grep -c psycopg-c pixi.lock` は **0 → 7**）
- (c) 堅牢性（`scratch/turn-007-bench-robust.{sh,log}`）: `password=wrong` は
  `failed: OperationalError connection failed: ... FATAL:  password authentication failed for user "pq"` の
  **1 行 + exit 1**、`port=54390 connect_timeout=3` は `... Connection refused` + libpq 自身のヒント行で
  **物理 2 行 + exit 1**。どちらも `Traceback` **0 行**、`^failed: OperationalError` **1 行**
- (d) 実測（`scratch/turn-007-bench.log`。アイドル時・`check` の**前**。loadavg 0.74 → 0.92）:
  Mojo `decode` は pass1 binary **12 / 11 / 11 ms** vs text **42 / 42 / 44 ms**、pass2 binary **12 / 12 / 14 ms** vs
  text **41 / 41 / 41 ms** → **binary < text が 2 回とも成立**（受け入れ充足。RESEARCH 実測 12 vs 44 と同じ桁）。
  Mojo 合計は binary 50 / 50 / 51 と 47 / 49 / 53、text 83 / 86 / 88 と 81 / 81 / 83（合計も binary 勝ち、記録のみ）。
  psycopg は **impl=c** / 3.3.4 / libpq 180006 / server 170011 / python 3.14.8 で、decode binary 35 / 35 / 34 と
  34 / 34 / 34 ms、text 44 / 45 / 41 と 42 / 41 / 42 ms、合計 binary 71 / 73 / 70 と 71 / 70 / 70 ms。
  ヘッダ（README の計測環境欄の原本）: Ubuntu 24.04.5 LTS / Linux 6.8.0-147-generic aarch64 / nproc 4 /
  MemTotal 16,337,280 kB / Mojo 1.1.0 (8189361e) / PostgreSQL **17.11 (Debian 17.11-1.pgdg13+2)**
- 検証と所要（単位付き）: `pixi run check` **6/6 PASS**（`final_check: PASS`、`FAIL` の行 0。
  23:53:32 → 23:56:21 = **169 s**。基線 182 s、閾値 247 s 以内）。
  bench 2 本の所要: `pixi run bench`（Mojo）と `pixi run bench-psycopg` の 4 回ぶんを含む (d) の 1 パスが
  23:53:01 → 23:53:08 = **7 s**（1 本あたり 1〜2 s）。**bench 環境の初回作成は 3 s**（`scratch/turn-007-bench-first.log`。
  PLAN の見込み「1 分前後」より速かった — 既に solve 済みのパッケージがキャッシュにあったため）。
  チェックリストの T5 行は全行期待値（`pixi_feature_bench`=2 / `pixi_bench_psycopg`=1 / `pixi_environments`=1 /
  `lock_psycopg_c`=7（≥ 3）/ `bench_py`=exists / `bench_py_binary`=2（≥ 1）/ `bench_py_psycopg_error`=1（≥ 1））。
  参考: `examples_pixi_run`=**2**（T6 で 7 に）、`src_def_ref_return`=0 / `tests_files_count`=24 / `test_file_count`=24
  （T7 の期待値どおり）。生ログ: `scratch/turn-007-{bench-first,bench-robust,bench,checklist,check}.log`
- 想定外: (1) **PLAN 訂正 1 件**（PLAN T5 (c) に追記）: 「`failed: OperationalError ...` の **1 行**」→
  「**1 レコード**」。接続拒否では libpq の message 自体が `Is the server running on that host ...` の
  ヒント行を含むので物理 2 行になる。判定は `^failed: OperationalError` が 1 行 + `Traceback` 0 行 + exit 1。
  (2) 初回の bench 環境作成が 3 s（見込み 1 分前後）。遅いほうに外れていないので追わない。
  (3) `pixi` が PATH に無く `pixi: コマンドが見つかりません`（Bash ツールは `.bashrc` を読まない構成）。
  **`/home/parallels/.pixi/bin/pixi` を絶対パスで呼ぶ**ことで解決。`/usr/bin/time` も無いので所要は `date -Iseconds` で挟む
- やり直し: 0 回
- 次への注意: 次は T6（`README.md` + `LICENSE` + examples 5 本の docstring）。サブエージェント **1 本**
  （A: `LICENSE` 取得 + examples 5 本の docstring、親: `README.md` + (d)）。
  **`pixi` は `/home/parallels/.pixi/bin/pixi` を絶対パスで**（サブエージェントにも伝える）。
  (a) の LICENSE 取得は `pixi run python <scratch>/turn-00N-fetch-license.py` で（`curl` は allowlist 外）。
  README のベンチ節に転記する数値は **`scratch/turn-007-bench.log`** が原本で、3 回の値を `a / b / c` で並べる
  （Mojo decode: binary `12 / 11 / 11`、text `42 / 42 / 44`。計測環境は上の「ヘッダ」行をそのまま使う。
  PostgreSQL は **17.11**、psycopg **3.3.4** + psycopg-c 3.3.4 impl=c、python **3.14.8**、libpq 18.6 conda-forge）。
  1 行要約の「N 倍」は decode で **約 3.7 倍**（42 / 11.3）。再現手順の「初回は環境作成で 1 分前後」は
  実測 3 s だったので「初回は bench 環境の作成が入る」程度の書き方にする。`check` の基線は 169 s に更新（閾値 247 s）

## turn 8 — impl — T6 `README.md` + `LICENSE` + examples 5 本の docstring
- やったこと: サブエージェント **推奨 1 本 / 実 1 本**（A: `LICENSE` 取得 + examples 5 本の docstring。
  親: `README.md` + (d) 検証）。コミット `5c5a94d`（8 ファイル、+628 / -18）
- 既存テストの期待値変更: **ゼロ**（`tests/` は 1 行も触っていない。`src/` も不変）
- (a) `LICENSE`: `urllib.request.urlretrieve` で 1 回で取得（`scratch/turn-008-fetch-license.py`）。
  **202 行 / 11,358 bytes**（公式値と完全一致）、`grep -c APPENDIX` = **1**、`license_apache` = 4。
  CRLF なし（LF のみ）。無改変で置いた
- (b) `README.md`: 日本語 **10 節**（`readme_h2` = 10）。コード片 **6 本**（basic / params ×2（バインド・
  トランザクション）/ binary / async_query / listen_notify）、各 9〜15 行、直前に抜粋元ファイル名。
  **逐語一致を機械確認**: `scratch/turn-008-readme-excerpts.py` → `blocks=6 missing_total=0`
  （ログ `scratch/turn-008-readme-excerpts.log`）。原文のインデントのまま載せている
- (d) 型表の目視突き合わせ: `scratch/turn-008-typetable.py` で `src/pq/__init__.mojo:42-62` と機械比較 →
  **ヘッダ + 19 データ行で件数一致、OID 列 19 行すべて一致、Mojo 型列も一致**。差分 4 件はすべて
  日本語化した散文のみ（`int8` 行の `(also readable as `Int`)` → `（`Int` でも読める）`、
  最終行 `anything else` → `上記以外` / `--` → `—` / 「テキストでは `String`、バイナリでは無し」）。
  OID と Mojo 型は 1 つも変えていない。`readme_type_oids` = **17**（期待 ≥ 17）
- (d) `PgErrorKind` の突き合わせ: README の 8 行が `src/pq/errors.mojo` の宣言順
  （`LIBPQ_LOAD` 0 / `CONNECTION` 1 / `SERVER` 2 / `NULL_VALUE` 3 / `TYPE_MISMATCH` 4 / `USAGE` 5 /
  `TIMEOUT` 6 / `ENCODING` 7）と一致。印字名も `write_to` の 8 文字列（`LibpqLoad` … `Encoding`）と一致
- (c) docstring: 5 本とも `Run it with \`pixi run example-<task>\`.` の 1 行を既存の
  「The server comes from ...」段落の先頭に追加（`bench_formats.mojo:15` と同形）。
  「何を見せるか」「前提」「`PgError` は印字して非 0」は 5 本とも既にあり**足していない**。
  タスク名は `pixi.toml:17-21` で確認（`async_query` → `example-async`、`listen_notify` → `example-notify`
  とファイル名と不一致の 2 本があるため推測せず確認）。`examples_pixi_run` = **7**
- README のベンチ数値の原本: `scratch/turn-007-bench.log` の **pass 1**。転記した 12 セル
  （Mojo text 40/43/44・42/42/44・83/86/88、Mojo binary 38/39/39・**12/11/11**・50/50/51、
  psycopg text 40/42/42・44/45/41・84/87/83、psycopg binary 35/38/36・35/35/34・71/73/70）は
  ログと 1 つずつ照合して一致。1 行要約は decode 約 **3.7 倍**（42 → 11）、合計約 **1.7 倍**（83 → 50）
- 検証と所要: `pixi run fmt` = `52 files left unchanged`（統合後 1 回）。
  `pixi run check` **6/6 PASS**（`final_check: PASS`、`FAIL` 0 行。00:03:59 → 00:07:06 = **187 s**。
  基線 169 s、閾値 247 s 以内）。4/6 段で 5 本の examples が docstring 変更後も全部走った
  （`column_format(0) = Binary` / `rows = 2` / `backend_pid = 165867` まで出ている）。
  `pixi run hello-libpq` = `PQlibVersion = 180006 (PostgreSQL 18.6)`。
  チェックリストの T6 行は**全行期待値**（`readme`/`license` = exists、`readme_h2` = 10、
  `readme_copyright` = 1、`readme_unverified_windows` = 3、`readme_ENCODING` = 3、
  `readme_wait_notifications` = 2、`readme_db_reset` = 2、`readme_bench_psycopg` = 2、
  `readme_PQ_MOJO_LIBPQ` = 1、`readme_type_oids` = 17、`readme_examples_links` = 9、
  `license_appendix` = 1、`license_lines` = 202、`examples_pixi_run` = 7）。
  T7 の期待値も現時点で `src_def_ref_return` = 0 / `tests_files_count` = 24 / `test_file_count` = 24。
  生ログ: `scratch/turn-008-{checklist,readme-excerpts,typetable,check,hello}.log`
- 想定外: (1) **PLAN 訂正 2 件**（PLAN T6 (a)(b) に追記）: ① 完了基準の `head -3 LICENSE` は実物と
  1 行ずれていた — 公式 `LICENSE-2.0.txt` は**先頭が空行**なので期待の 3 行は 2〜4 行目に出る。
  `head -3` → `head -4` に訂正（ファイルは無改変を優先。行数 202 / バイト数 11,358 が公式値と完全一致
  しているので全文同一の裏は取れている）。② (b) の「節立て 11 節」は決めた事項 11 の列挙が 1〜10 の
  **10 節**なので「10 節」に訂正（チェックリストの `readme_h2 ≥ 10` は充足）。
  (2) サブエージェントへの依頼文に書いたビルド確認コマンドに `-I src` が無く
  `error: unable to locate module 'pq'` になった。`pixi.toml:24` の `build` タスクと同じ
  `mojo build -I src examples/<f>.mojo` で 5 本ともエラー・警告なしで通った（判断はサブ側で正しく修正済み）。
  (3) `check` が 187 s（前ターン 169 s）。閾値 247 s 内なので追わない
- やり直し: **1 回**（README のコード片。最初に 8 スペース分デインデントして書き、さらに
  async 例で `try`/`except` を省いた縮約形にしてしまった。P18 の「抜粋した行がそのまま存在する」を
  満たさないので、6 本すべて**原文のインデントのまま・行単位で逐語**に書き直し、
  `scratch/turn-008-readme-excerpts.py` で機械確認するところまでやった）
- 次への注意: 次は **T7（統合。最後のタスク）**。サブエージェント **0 本（親が全部）**。
  **`pixi` は `/home/parallels/.pixi/bin/pixi` を絶対パスで**。
  T7 で使う値: `check` の基線は **187 s**（閾値 247 s）、コンテナは起動済み（pg17 54317 / pg14 54314 /
  blackhole 54399）だが (a) は `pixi run db-reset` から始める。
  (b) の格子は `scratch/turn-001-examples-robust.sh` を `turn-009-examples-robust.sh` にコピーして
  `bench-psycopg` の badpw / badport 2 本 + `hello_libpq nolib` を足して **17 本以上**。
  `bench-psycopg` は `bench` 環境なので `pixi run bench-psycopg` のまま `PQ_TEST_CONNINFO` を付ける。
  (d)(e) は `TRACE.md` に 2 節追加（受け入れ基準対応表 / 未確認行の処分表）。
  (e) の「未確認」行は turn 3 以降の PROGRESS を `grep -n '未確認' .gsd-lite/PROGRESS.md` で拾う。
  (f) のチェックリストは `turn-008-checklist.log` が直前の全行の現在値（T6 行まで全部期待値なので、
  T7 では `turn-009-checklist.log` を取り直して全行を突き合わせるだけ）

## turn 9 — impl — T7 統合（check / 堅牢性格子 / 後始末 / 対応表 / 処分表）
- やったこと: サブエージェント **推奨 0 本 / 実 0 本**（PLAN どおり親が全部）。コードは 1 行も変えていない
  （`src/` / `tests/` / `examples/` / `pixi.toml` は不変）。`TRACE.md` に T7 の 3 節を書き、コミット `7d900d6`
  （`TRACE.md` + `PLAN.md` の 2 ファイル、+79 / -4）
- 既存テストの期待値変更: **ゼロ**（`tests/` は 1 行も触っていない）
- (a) `pixi run db-reset`（3 コンテナとも `Healthy`。`scratch/turn-009-db-reset.log`）→ `pixi run check`
  **6/6 PASS**（`final_check: PASS`、`FAIL` の行 0、6/6 段の `matched lines in build/final_check.log: 0`。
  00:10:02 → 00:13:12 = **190 s**。基線 187 s、閾値 **247 s** 以内）。`pixi run test` 両サーバー PASS
  （`0 failed` のサマリ **48 件**、`FAIL` 0 行。**`test_leak` は両サーバーで実行** = 85 s / 82 s、
  合計 00:13:27 → 00:17:44 = **257 s**。`skipped 1` は各サーバー 1 件ずつの
  `test_interval_infinity_*`（PG 版数条件つきテスト。pg17 側と pg14 側で逆の 1 件が飛ぶ））
- (b) 堅牢性の格子 **17/17**: 全行 `rc=1` かつ `unhandled_markers=0`
  （`Traceback` / `Unhandled` / `stack trace` / `abort` / `segfault` が 0 件）。
  examples 7 本 × badpw / badport + `hello_libpq` nolib + `basic` nolib + `basic` 不正 conninfo（`port=abc`）+
  **`bench-psycopg` badpw / badport の 2 本を新規に追加**（turn 1 の 15 本 → 17 本）。
  スクリプト `scratch/turn-009-examples-robust.sh`、生ログ `scratch/turn-009-examples-robust.log`、所要 40 s 弱。
  表は `TRACE.md`「examples 堅牢性の格子」節
- (c) 後始末: `pixi run test` の後に `docker exec ... psql` を**両サーバー**で実行し
  `pq_test_%` が **pg17 0 行 / pg14 0 行**（`scratch/turn-009-pgdatabase.log`）
- (d) `TRACE.md`「受け入れ基準対応表」節: HANDOFF §10 Phase 5 の 3 項目 + REQ §5 の 11 行を
  **14 行の表**（基準 → 担保タスク → テスト / 検査 → ログ）に
- (e) `TRACE.md`「未確認行の処分表」節: `grep -n '未確認' .gsd-lite/PROGRESS.md` は turn 3〜8 の本文に
  **0 件**（ヒット 2 件は turn 8 の「次への注意」が手順を書いた行そのもの）。そこで同趣旨の
  「断定しきれなかった / 追わなかった」行を turn 3〜8 の想定外・陽性対照・やり直しから **13 件**拾い、
  **テスト追加 2 / 契約外と明記 5 / PLAN 訂正済み 5 / verify 申し送り 1** に振り分けた。
  ★（誤った値が黙って返る・状態機械が壊れる経路）は 3 件 — `_after_send` -1（到達不能 → コードレビューで担保）、
  `wait_notifications` の `out` 保全（⑨ のテストで担保）、Windows の `_is_usage_error` 分類（スコープ外 → verify 申し送り）
- (f) チェックリスト **全行が期待値**（`scratch/turn-009-checklist.log`。turn 8 との差は
  `trace_zero_copy` 4 → **5** の 1 行だけで、これは今回 TRACE に足した 3 節が `test_zero_copy` に言及したため。
  期待値 ≥ 1 を満たす）。T7 の 3 行も `src_def_ref_return`=**0** / `tests_files_count`=**24** / `test_file_count`=**24**。
  **PLAN 訂正は 0 件**（TRACE の「PLAN 訂正」節に追記なし）
- (g) `git status` クリーン（`pixi.lock` / `README.md` / `LICENSE` / `examples/bench_psycopg.py` は
  turn 7・8 でコミット済み）。全 7 タスク `- [x]` になったので `phase: "verify"` / `next_command: "/gsd-lite-verify"` へ
- 想定外: (1) **`pixi run check` の 5/6 段は `test_leak` を 1 台目だけで回す**（段の見出しにそう書いてある）ので、
  PLAN (a) の「leak 両方」は `pixi run test` を別に回して初めて満たせた（`check` だけでは足りない）。
  (2) `check` が 190 s で基線 187 s より 3 s 長い（閾値 247 s 内。turn 6 で 215 s まで揺れているのと同じノイズ）。
  (3) 待ち合わせに使った監視コマンドの grep パターン `final_check` が
  ログ先頭の pixi バナー（`bash tests/final_check.sh`）に当たって一度空振りした → `final_check: (PASS|FAIL)` に直した
- やり直し: 0 回
- 次への注意: 次は **verify**（全タスク完了）。verify が再実行できる証跡: `check`（190 s）/ `pixi run test`（257 s、leak 両方）/
  `scratch/turn-009-examples-robust.sh`（17 本、40 s 弱）/ `scratch/turn-002-checklist.sh`（全行期待値）/
  `turn-008-readme-excerpts.py`（README コード片の逐語一致）/ `turn-008-typetable.py`（型表 19 行）。
  **`pixi` は `/home/parallels/.pixi/bin/pixi` を絶対パスで**。verify 用 DB を作るなら `pq_verify_<turn>` で同ターンに消す。
  申し送り 1 件: Windows 実機は未検証（REQ §3 スコープ外。TRACE「未確認行の処分表」#7 と README §8 で開示済み）

## turn 10 — verify — 指摘あり（F1 の 1 タスク、指摘 3 件）/ round 1 → impl に差し戻し / マージなし
- やったこと: `git diff main...HEAD` のコード 20 ファイルを読み（サブエージェント 0 本）、`pixi run check` をクリーンな木で再実行（**6/6 PASS、184 s**、`0 failed` 47 件、
  `pg_database` 両サーバー 0 行）、チェックリスト再実行（turn 9 と完全一致）、README のベンチ 12 セル × 4 行を `turn-007-bench.log` pass 1 と照合（一致）、
  コード片 6 本 / 型表 19 行のスクリプト再実行（一致）、Windows 照合表 12 行を Microsoft Learn の 2 ページと突き合わせ（一致）。
  round 1 の堅牢性格子 **37 本**（`scratch/turn-010-robust-grid.sh` / `.log`: 入力 = 非 UTF-8 / 制御文字 / 100 KB / 引用符不整合 / URI / `libc.so.6` / ディレクトリ / 空ファイル、
  出力 = `/dev/full` / 閉じた stdout / パイプ閉鎖）。Mojo 側は全面クリーン、**`bench_psycopg.py` だけ 2 クラスで外れた** → PLAN 末尾に F1、`VERIFICATION.md` に round 1 を記録
- 指摘: (1) `bench_psycopg.py` は非 UTF-8 の conninfo で `UnicodeEncodeError`（`ValueError` の子）の **Traceback**（`except psycopg.Error` の素通り）；
  (2) stdout が `/dev/full` だと終了時 flush の `OSError` が **`Exception ignored` + exit 120**（正常・badpw とも）；(3) README §7「URI は受けません」は examples には当たらない（文書のみ、F1 (c) に同梱）
- 想定外: (1) 1 MB の環境変数は `env` 自体が E2BIG で渡せない（ハーネスの限界）→ 100 KB で再試行し 3 本とも `server closed the connection` + exit 1 で合格。
  (2) impl の格子 17 本は RESEARCH の 15 本を踏襲して「DB 側の失敗」だけだったため、出力経路と入力エンコードのクラスが無かった（VERIFICATION §3 に理由を記載）
- やり直し: 0 回
- 次への注意: impl は **F1 だけ**（`examples/bench_psycopg.py` + README §7 の 1〜2 行。見込み +12 行、新しいテスト資源なし）。期待結果は PLAN F1 の**表 1 つ**が唯一の正。
  検証は `scratch/turn-010-robust-grid.sh` の `bench_psycopg.py` 節（`PY=.pixi/envs/bench/bin/python` で pixi のバナー無し）を `turn-NNN-bench-robust.sh` に写して回す。
  `pixi` は `/home/parallels/.pixi/bin/pixi` を絶対パスで。`check` の基線は 184 s（閾値 247 s）。round 2 の verify は格子の再確認 + F1 の回帰だけ（新クラスの探索はしない）

## turn 11 — impl — F1 bench_psycopg.py の堅牢性 2 クラス + README §7 の URI 字句
- やったこと: サブエージェント **推奨 0 本 / 実 0 本**（PLAN どおり親が全部）。`examples/bench_psycopg.py` の
  例外処理を 2 段に（`except psycopg.Error` は残し `except ValueError` を追加、明示 `sys.stdout.flush()` +
  `except OSError` → fd 1 を `/dev/null` に dup2 して stderr に 1 行 + exit 1）、README §7 の URI の言い切りを
  テスト側の制約として書き直し。コミット `41a4ef3`（`.py` + README + PLAN、+49 / -20）
- 既存テストの期待値変更: **ゼロ**（`tests/` と `src/` は 1 行も触っていない）
- (a) 実装: `main()` は `status` を持ち回って最後に 1 回だけ `sys.exit(status)`（内側で `sys.exit` すると
  `SystemExit` が明示 flush を飛ばし、暗黙 flush で `Exception ignored` に戻ってしまう）。
  `_discard_stdout()` は Python 公式の SIGPIPE 手順。`_run` の `sys.exit(1)`（件数不一致）は不変
- (b) 検証 `scratch/turn-011-bench-robust.sh` / `.log`（**15 レコード** = PLAN の表 6 行 + turn 10 格子の残り 8 行 +
  版数行）: 全行 `traceback=0 exception_ignored=0`。表の 6 行はすべて期待どおり —
  非 UTF-8 conninfo → `failed: UnicodeEncodeError ...` 1 レコード / rc 1、`/dev/full`（正常・badpw）→
  stderr に `failed: OSError [Errno 28] ...` 1 行 / **rc 120 → rc 1**、閉じたパイプ → rc 0、badpw / badport →
  `failed: OperationalError ...` / rc 1、正常 → rc 0。`pixi run bench-psycopg` は rc 0 で 1 行目
  `psycopg 3.3.4 impl=c libpq=180006 server=170011 python=3.14.8`（`scratch/turn-011-bench-psycopg.log`、
  text 82/82/82 ms vs binary 71/69/68 ms で decode も binary < text）
- (c) README §7: 「`key=value ...` 形式のみ」は `tests/run_tests.sh:10-13` の制約（末尾に ` password=...` を
  付け足す）と明記し、`examples/` は `PQconnectdb` に素通しなので URI でも動くと追記（+3 行）
- (d) `pixi run check` **6/6 PASS**（`final_check: PASS`、rc 0、`FAIL` 0 行、`0 failed` のサマリ 47 件、
  6/6 段の `matched lines ... : 0`。00:36:09 → 00:39:18 = **189 s**。基線 184 s、閾値 247 s 以内。
  `scratch/turn-011-check.log`）。チェックリストは **全行が期待値**（`scratch/turn-011-checklist.log`。
  turn 10 との差は `readme_examples_links` 9 → **10** の 1 行だけで、README に増やした `examples/` の
  言及ぶん。期待値 ≥ 7 を満たす。`bench_py_psycopg_error` = **1**（不変））
- 想定外: (1) `except (psycopg.Error, ValueError)` と 1 つにまとめると追従先チェックリストの
  `bench_py_psycopg_error`（文字列 `except psycopg.Error` の件数）が 0 になるので、ハンドラを 2 つに分けた
  （PLAN (a) の書き方どおり。期待値 ≥ 1 は不変）。(2) fd 1 が閉じている場合 Python は `sys.stdout` を
  **None** にし `print` が no-op になる（実測）ため、明示 flush は `if sys.stdout is not None` で守る必要があった
  （守らないと `AttributeError` で turn 10 でクリーンだった「closed stdout」2 行が Traceback に退行する）。
  (3) 差分は見込み +12 行に対し `.py` だけで +44 / -14（内側 try のインデントで本体 12 行が差分に乗る）。
  (4) Monitor ツールの `until grep` 監視が実在しない `final_check: PASS` を 2 回報告した（ログ実物は未完了）→
  前景の `until` ループで待ち直して確認。**監視の通知はログ実物で裏取りする**
- やり直し: 0 回
- 次への注意: 次は **verify round 2**（PLAN の全タスク + F1 完了）。VERIFICATION §2 の指示どおり
  「格子の再確認 + F1 の回帰（表の 6 行）」だけで、新しいクラスは探さない。再実行できる証跡:
  `scratch/turn-011-bench-robust.sh`（15 レコード、約 50 s）/ `turn-009-examples-robust.sh`（17 本）/
  `turn-002-checklist.sh`（全行期待値）/ `turn-011-check.log`（189 s）。`pixi` は
  `/home/parallels/.pixi/bin/pixi` を絶対パスで。Monitor の通知は信用せずログで裏取り

## turn 12 — verify — 指摘あり（F2 の 1 タスク、文書のみ 6 行）/ round 2 → impl に差し戻し / マージなし
- やったこと: F1 の差分（`bench_psycopg.py` + README §7）をレビューし、`db-reset` → `pixi run check` **6/6 PASS**（約 165 s、`0 failed` 47 件、
  `pg_database` 両サーバー 0 行）、チェックリスト（turn 11 と完全一致）、round 1 格子 + F1 の表 6 行を `scratch/turn-012-robust-regress.sh`
  （**42 レコード**、Mojo 3 本は HEAD から再ビルド）で再確認 → 全行クリーン、`pixi run bench` で decode binary 13 < text 42 ms、
  README コード片 / 型表のスクリプト再実行（一致）。サブエージェント 0 本。VERIFICATION §5 に記録
- 指摘: examples 6 本の docstring「never a `postgres://` URI」が F1 (c) 後の README §7 と矛盾（REQ §4.3）→ PLAN 末尾に **F2**（文書のみ、6〜12 行、新しいテスト資源なし）
- 想定外: (1) round 1 / F1 (b) の `run_pipe` は `2>&1 1>&3 | head` の順序で **stderr をパイプに**つないでいて stdout の EPIPE を試していなかった。
  `> >(exit 0)` に直して本物の EPIPE を試すと `bench_psycopg.py` は `failed: BrokenPipeError` + rc 1（合格）、Mojo examples は rc 141（SIGPIPE。残留リスクに記載）。
  (2) round 1 が README の言い切りを直すとき同文をリポジトリ全体で grep しなかった（REQ §9 verify の規則）。それが今回の F2 の原因。
  (3) `check` の所要は開始時刻を記録し忘れ、ログの mtime からの概算（約 165 s）になった
- やり直し: 0 回
- 次への注意: impl は **F2 だけ**（examples 6 本の docstring 1 文ずつ。`src/` / `tests/` / README は触らない）。期待結果は PLAN F2 の**表 1 つ**が唯一の正。
  `grep -rn 'never a .postgres://. URI' examples/ README.md src/pq tests/run_tests.sh` が 0 件になること（`run_tests.sh:10-11` の「NOT a postgres:// URI」は残す）。
  `pixi` は `/home/parallels/.pixi/bin/pixi` を絶対パスで。`check` の基線は 165〜189 s（閾値 247 s）。verify round 3 は「F2 の grep + `check` + チェックリスト同値」だけで、格子の再実行は不要（コード不変）

## turn 13 — impl — F2 examples 6 本の docstring の URI 字句
- やったこと: サブエージェント **推奨 0 本 / 実 0 本**（PLAN どおり親が全部）。`examples/` 6 本
  （`basic` / `params` / `binary` / `async_query` / `listen_notify` / `bench_formats`）の docstring の
  「`key=value ...` form only, never a `postgres://` URI」を「a `key=value ...` string or a
  `postgresql://` URI, passed to `PQconnectdb` as is」に言い換え（`src/pq/connection.mojo:169-172` と同じ趣旨）。
  コミット `4c20636`（6 本 + PLAN、+19 / -18）
- 既存テストの期待値変更: **ゼロ**（`src/` / `tests/` / `README.md` / `bench_psycopg.py` は 1 行も触っていない）
- (a) 実装: 5 本は同一の 3 行ブロックなので同一文に統一、`bench_formats.mojo:15-18` だけ前後の文が違うので
  折り返し位置を合わせて 4 行に（全行 80 桁以内。`mojo format` は 1/6 段で無変更）
- (b) 検証: `grep -rn 'never a .postgres://. URI' examples/ README.md src/pq tests/run_tests.sh` が **0 件**
  （rc=1）。`tests/run_tests.sh:11-12` の「postgres:// URI）」はテスト側の真の制約なので**残っている**
  （パターンの `never a` に当たらない）。`/home/parallels/.pixi/bin/pixi run check` **6/6 PASS**
  （`final_check: PASS`、`FAIL` 0 行、`0 failed` のサマリ 47 件、6/6 段 `matched lines ...: 0`。
  00:49:59 → 00:53:08 = **189 s**。基線 165〜189 s、閾値 247 s 以内。`scratch/turn-013-check.log`）。
  チェックリスト（`scratch/turn-013-checklist.log`）は `turn-012-checklist.log` と **diff 0**（完全一致）で
  `examples_pixi_run` = 7 / `readme_h2` = 10 / `readme_examples_links` = 10 / `hello_*` / `examples_raise_error` = 0
  がすべて期待値
- 想定外: なし
- やり直し: 0 回
- 次への注意: PLAN の全タスク（T1〜T7 / F1 / F2）が完了 → **verify round 3**。コードは不変（文書 6 行だけ）なので
  VERIFICATION 申し送りどおり「F2 の `grep` 0 件 + `check` 6/6 + チェックリスト同値」の 3 点だけで、
  堅牢性格子（`scratch/turn-012-robust-regress.sh`）と bench の再実行は不要。再実行できる証跡:
  `scratch/turn-013-check.log`（189 s）/ `turn-013-checklist.log`（turn 12 と同値）。
  `pixi` は `/home/parallels/.pixi/bin/pixi` を絶対パスで

## turn 14 — verify — 合格（指摘 0 件）/ round 3 / `main` にローカルマージ済み（`--no-ff`）
- やったこと: F2 の差分（examples 6 本の docstring、+18 / -17）をレビューし、PLAN F2 の表どおり `grep -rn 'never a .postgres://. URI' …` **0 件**、
  README §7 / `connection.mojo:169-172` / `run_tests.sh:10-13` と矛盾なし、80 桁超 0 行。`db-up`（3 台 Healthy）→ `pixi run check` **6/6 PASS**
  （`final_check: PASS`、rc 0、`0 failed` 47 件、`FAIL` / `Traceback` 0 行、6/6 段 `matched lines` 0。00:55:46 → 00:58:52 = **186 s**、閾値 247 s）、
  チェックリスト 82 key は `turn-013-checklist.log` と `diff` 空、`pg_database` は pg17 / pg14 とも 0 行。VERIFICATION §6 を書いて branch にコミット（`c88173e`）→
  `git checkout main` → `git merge --no-ff gsd-lite/phase5-polish-bench-readme`（衝突なし、38 ファイル）。ブランチは残した。サブエージェント 0 本。
  格子（`turn-012-robust-regress.sh`）と bench の再実行は省略（コード不変。PLAN F2 の表で任意）。生ログ: `scratch/turn-014-{check,checklist}.log`
- 想定外: なし（lean-ctx MCP は未接続だが PROGRESS の対象外）
- やり直し: 0 回
- 次への注意: 次は **reflect**。材料: verify は 3 ラウンド（round 1 = 堅牢性 2 クラス + README 字句、round 2 = round 1 が同文をリポジトリ全体で grep しなかったことによる docstring 6 本の差し戻し、
  round 3 = 合格）。round 2 の F2 は「字句の指摘はクラスで名指しし `grep -rn` で全件を同梱する」（REQ §9 verify）を round 1 が守っていれば F1 に同梱できた 1 ターン分。
  他に reflect の材料: `check` の所要は 165〜215 s で揺れた（閾値 247 s 内）、impl の格子 17 本は「DB 側の失敗」だけで出力経路・入力エンコードの面が無かった（verify round 1 が補った）、
  `test_zero_copy` の「3.4 s」は単位の読み違いで性能問題は無かった（research turn 1）。REQ §9 の「テスト 2 ファイル型を 1 本」の USD 比較も reflect の宿題。
  作業ツリーは `main` 上（マージ済み）。次マイルストーンの discuss が `main` から始める

## turn 15 — reflect — phase5-polish-bench-readme
- やったこと: 振り返りを `.gsd-lite/reflect/20261018-0103-phase5-polish-bench-readme.md` に作成（提案 11 件。計測: 14 ターン / 193.7 分 / USD 91.36、Phase 4 比 −30 %。
  Plus 9 / Minus 8 / Interesting 11）。turns.jsonl・生ログ 14 本の `result` / `subagent_stats`・PROGRESS・PLAN・TRACE・VERIFICATION・REQ §9・DECISIONS・RESEARCH §0.5・直近 2 件の reflect・ブランチの 24 コミットを読んだ
- 想定外: lean-ctx MCP 未接続（対象外）。turns.jsonl は turn 5 / 9 / 14 で複数 `result` の最後だけを記録（3 マイルストーン連続。振り返りの ※ に記載）
- やり直し: 0 回
- 次への注意: 提案の要点 — verify の字句指摘に「grep パターン / 件数 / ファイル」列を必須化、堅牢性格子を入力 × 出力 × 依存の 3 軸で PLAN に常設、`Monitor` を deny して前景 `until` に統一、PROGRESS 40 行はチェックリスト生値を TRACE へ
