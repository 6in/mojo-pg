# VERIFICATION — phase7-pool-copy-array

## round 1（turn 12、2026-10-20）— 判定: **差し戻し**（指摘 3 件 → F1、verify_round 1 / 4）

対象: `git diff main...HEAD`（コード 41 ファイル、`.gsd-lite/` を除く 27 ファイル / +9,100 行）。
HEAD `7556f21`。実行エンジン: Claude Code（claude-fable-5-1）。サブエージェント 2 本（コードレビュー / セキュリティ、読み取り専用）の報告を親が統合し、指摘は親が source と実測で再確認した。

### 観点と確認したこと

| 観点 | 確認したこと | 結果 |
|---|---|---|
| 最終判定コマンド | `db-reset` → `check`（クリーン状態、21:25:33 → 21:30:24） | **6/6 PASS、291 s**、`PASS` 1524 / `FAIL` 0（turn 9〜11 と同数 = 既存テストの期待値変更 0 件を `git diff --stat` の「追加のみ」でも確認） |
| 堅牢性格子（REQ §2.4 / D2、round 1 の一括プローブ） | `turn-011-robust-grid.sh` を再実行（`scratch/turn-012-robust-grid.log`） | **126 / 126 セル `unhandled_markers=0`**、7 本ビルド、rc 141 は `run_epipe` の 14 セルのみ（T9 と同一） |
| 追従先チェックリスト | `turn-002-checklist.sh`（`scratch/turn-012-checklist.log`） | 77 key すべて期待値。turn 11 との差は `trace_checklist_section` 7 → 8 だけ |
| README 抜粋照合 | `turn-008-readme-excerpts.py` | 9 ブロック missing 0（`missing_total=1` はインストール節の既知の NO-SOURCE、turn 10 基線と同じ） |
| PROGRESS 40 行 | `python3 -c` | 最新節 15 行 |
| 受け入れ基準 §4.1〜§4.4 | TRACE「受け入れ基準対応表」の各行をテスト名で `grep -n '^def test_'` | すべて実在。CI 3 OS は PR 未作成のため未実施（差し戻しのため PR は round 2 以降） |
| コードレビュー（親 + サブ A） | `copy.mojo` / `pool.mojo` / `connection.mojo` 差分 / `parse_array_literal` / `_decode_binary_array` / `encode_array` / `PooledConnection` 転送 11 本のシグネチャ | 指摘 3 件（下表）。バイナリ配列デコーダの境界検査（12 byte ヘッダ / 20 byte / `dim > 残り // 4` / 要素長語 / `elem_len ≤ 残り` / 末尾残り）、tokenizer の終了性（全ループが `i` を進めるか raise）、`PQfreemem` の全経路、プールの計数（`_borrowed` 先行デクリメント、捨てる経路の `return`、`min_size` 失敗時の局所 `List` 破棄）は問題なし |
| セキュリティ（サブ B） | 入力検証 / FFI バッファ寿命 / `_reject_nul` の適用 / 秘密情報 / SQL 組み立て / pixi・final_check の変更 | HIGH / MEDIUM なし。LOW 1 件は残留リスクへ |
| 文書の主張 | README / CHANGELOG / `__init__.mojo` docstring | 「19 型」は REQ §2.1 と同じ語彙（`Int64`/`Int` を 2 と数える）。`Iterator` の主張なし、スレッド非安全は一貫。古い件数なし |
| 決めた事項 7 / 20 | `CopyOut` 非 `Iterator` / 未完了 `CopyIn` の guard drop は再利用 | 申し送りどおり差し戻し対象にしない |

### 指摘（→ PLAN F1。grep パターン / 件数 / ファイルの 3 列）

| # | 内容 | 重さ | grep パターン（`grep -cE`） | 件数 | ファイル |
|---|---|---|---|---|---|
| 1 | `Transaction.commit()` / `rollback()` が `_done = True` を送信前に立てるが、T6 で `execute` に入った `_check_not_copying` は何も送らず `USAGE` を raise する → COPY 中の `commit()` は `tx` を「終了済み」にしつつ `COMMIT` も implicit `ROLLBACK` も出ない（サーバーは INTRANS のまま、`Transaction` API から閉じられない）。このマイルストーンで入った回帰 | MEDIUM（状態機械の誤り、データは `PQfinish` で ROLLBACK される） | `self\._done = True` | 2 | `src/pq/transaction.mojo:264,290` |
| 2 | `CopyIn.__deinit__` / `CopyOut.__deinit__` が、COPY を `Transaction` の ROLLBACK が既に終えた順序（T6 ⑭）でも中止を送り、libpq の `no COPY in progress` を `CONNECTION` として handler に報告する。既定 handler なら健全な接続で stderr に `implicit ROLLBACK failed`。テスト ⑭ はこれを `>= 1` で固定している | MEDIUM（誤報。T8 の PLAN 訂正 ② が記録していた挙動そのもの） | `_handler\(` | 4 | `src/pq/copy.mojo:261,493,495` |
| 3 | `CopyIn.write` の `-1` 後、libpq は `PQstatus` OK / `PQtransactionStatus` ACTIVE のまま → 以後の `execute` / `transaction()` / `prepare` が全部 `USAGE` `a COPY is in progress`（実態は死んだ接続）。出口は `reset()` のみで docstring に無い。`finish` / `abort` の `rc < 0` も同じく drain しない。実測: `scratch/turn-012-probe-failed-write.log`（stuck）/ `-end.log`（`PQputCopyEnd(0)` + drain で IDLE に戻り `execute` が `CONNECTION`） | MEDIUM（誤動作: 進行していない COPY を理由に全コマンド拒否） | `self\._done = True` | 3 | `src/pq/copy.mojo:320,372,409` |

round 1 で拾えた理由: 3 件とも「`_check_not_copying` が入ったことで変わった `execute` の失敗の仕方」を `Transaction` と `CopyIn` の状態機械が織り込んでいない同型の問題で、1 つの F タスクにまとめた（同型の指摘を小出しにしない）。

### 残留リスク（差し戻さない。要件外か実害が小さい）

- `CopyIn.write(Span)` の `c_int(len(bytes))`（`copy.mojo:314`）は 2 GiB 以上の 1 回の `write` で桁あふれし、libpq が黙って切り詰める。`encode_array` の `Int32(len(...))` も同じ上限。実用上到達しないが、`len > Int32.MAX` で `USAGE` にする 1 行で塞げる（次のマイルストーン候補）
- `parse_array_literal` は引用なし要素の末尾の `\ `（バックスラッシュでエスケープした空白）を trim する（`{a\ }` → `a`）。サーバー出力は必ず引用するので `PQgetvalue` からは到達しない
- CI 3 OS（REQ §4.4）は PR 作成後に初めて走る。差し戻しのため round 2 以降の verify が PR を作って待つ（`gh pr checks --watch`、上限約 40 分、`verify_round_max` 4）
- `check` の所要は 291 s（母数 260〜425 s の下側）。F1 でテスト 4〜5 件増えるので +20 s 程度

### 合格だった事項（round 2 は回帰確認だけ）

配列（テキスト / バイナリ / 送信）、COPY の正常系と USAGE 格子、プール全件、`Connection.reset()`、文書・examples・pixi・final_check、堅牢性格子 126 セル、セキュリティ観点。round 2 は F1 の差分（`transaction.mojo` / `copy.mojo` / `pool.mojo` docstring / `test_copy.mojo`）の回帰と、`check` 6/6 + 格子の再確認だけを行い、新しいクラスの探索はしない。

## round 2（turn 14、2026-10-20）— 判定: **合格**（指摘 0 件。state の `verify_round` は 1 / 4 のまま: 合格は +1 しない）→ push + PR

対象: F1 の差分 `git diff 5390545..HEAD`（`src/pq/copy.mojo` +90/−24、`src/pq/transaction.mojo` +35/−10、`src/pq/pool.mojo` docstring、`tests/test_copy.mojo` +296）
と、round 1 で合格だった事項の回帰確認。HEAD `1edf68e`。実行エンジン: Claude Code（claude-fable-5-1）。
round 1 の方針どおり**新しいクラスの探索はしていない**（格子の再確認 + F1 差分の回帰だけ）。サブエージェントは使わず親が読んだ（差分 4 ファイル・457 行で 1 人分）。

### 観点と確認したこと

| 観点 | 確認したこと | 結果 |
|---|---|---|
| 最終判定コマンド | `db-reset` → `check`（クリーン状態、22:02:57 → 22:07:45、`scratch/turn-014-check.log`） | **6/6 PASS、288 s**（閾値 300 s 内）、`PASS` 1534 / `FAIL` 0（= round 1 の 1524 + F1 の 5 件 × 2 サーバー）、6/6 段 `matched lines: 0` |
| 堅牢性格子（REQ §2.4、round 1 の格子の再確認） | `turn-011-robust-grid.sh` 再実行（`scratch/turn-014-robust-grid.log`） | **126 / 126 セル `unhandled_markers=0`**。`===` / `--- rc=` 行は round 1 と**完全一致**（差は build 行の HEAD ハッシュのみ）、rc 141 は `run_epipe` の 14 セルのみ |
| 追従先チェックリスト | `turn-002-checklist.sh`（`scratch/turn-014-checklist.log`） | 77 key、turn 13 の基線と `diff` 差分 0（`test_copy_tests`=26、`absent` 0） |
| F1 (a) 指摘 1 | `transaction.mojo` `commit` / `rollback`: `_check_not_copying()` が `_done = True` の前にあること、docstring の Raises に USAGE の文言と「block left open」 | 一致。`Transaction.__deinit__` は生の `PQexec("ROLLBACK")` のままで `_check_not_copying` を通らない（COPY 中の drop でも implicit ROLLBACK が出る。テスト ⑭ の `count == 0` が証明） |
| F1 (c) 指摘 2 | `CopyIn.__deinit__` / `CopyOut.__deinit__` の `PQtransactionStatus != PQTRANS_ACTIVE` ガード | `_done` の次に置かれ、`ACTIVE` なら従来どおり中止 / 読み捨て。ガードが真になるのは「他の経路が COPY を終えた後」だけ（COPY 中の同期接続は常に `ACTIVE`、`PQstatus` が BAD の接続は `UNKNOWN` → 何も送らないが次のコマンドが `CONNECTION` を返すので塞がらない） |
| F1 (b) 指摘 3 | `CopyIn.write` の `rc != 1`: `PQerrorMessage` → `PQputCopyEnd(0)` → `_drain_results` → `_done` → raise の順。`finish` / `abort` の `rc < 0` も drain | 一致。drain は `PQgetResult` が NULL まで。接続が切れた場合 libpq の `getCopyResult` が `asyncStatus` を IDLE に戻して FATAL 1 件 → NULL になるので終了する（テスト ③ の `transaction_status() == IDLE` が実測） |
| F1 (d) テスト 5 件 | `test_copy.mojo` 21 → 26 件。②×2 / ③ / ④ / ⑤ が PLAN の期待結果表の各行を断言しているか | ②: `USAGE` 文言 + `finish()==1` + 後続 `commit`/`rollback` + `count`。③: `CONNECTION` + `IDLE` + `reset()` → usable。④: `finish` が `CONNECTION` + 後続 `execute` も `CONNECTION` + `IDLE`。⑤: handler 0 回 + `count 0` + usable。陽性対照は TRACE「陽性対照（turn 13）」の 4 件赤（④ は修正前から green = 指摘 3 の対照ではなく REQ §4.2 の未テスト分。正しく記録されている） |
| 期待値の変更 | PROGRESS turn 13 の列挙 1 件（`test_transaction_destroyed_before_its_copy_in` の handler `>= 1` → `== ""`） | 意図どおり（指摘 2 の誤報を固定していた断言の除去）。`git diff` 上も既存テストの変更はこの 1 件だけ |
| 文書の主張 | `copy.mojo` モジュール docstring / `Transaction.copy_in` の order 段落 / `Pool.acquire` の Raises / README / CHANGELOG | README・CHANGELOG は F1 で無変更（COPY の破棄挙動や handler に触れる記述が元から無いことを `grep` で確認）。`Pool.acquire` の Raises は実装（`reset` 失敗は飲んで `_open_one` の失敗を上げる）と一致するよう直っている。古い件数なし |
| セキュリティ（F1 差分） | 新しい入力経路なし。`reason` は従来と同じ `PQerrorMessage` の写し、FFI 呼び出しの追加は `PQtransactionStatus` / `PQputCopyEnd(conn, 0)` のみ | 指摘なし |
| PROGRESS 最新節 | turn 13 節 | 18 行（≤ 40） |

### 残留リスク（round 1 から引き継ぎ + 追加 1 件）

- round 1 の 3 件（2 GiB 超の 1 回 `write` / `encode_array` の `Int32` 長、`parse_array_literal` の引用なし末尾 `\ `、`check` 所要の揺れ）は据え置き
- `finish` / `abort` の `rc < 0` 側の drain はテスト未踏（同期接続で `PQputCopyEnd` が負を返す形を作れない。libpq は書き込み失敗を `write_failed` で遅延させて 1 を返す）。到達するのは OOM か `asyncStatus` 不整合だけで、後者は `_check_active` が先に `USAGE` にする
- CI 3 OS（REQ §4.4）はこの PR で初めて走る。結果は下の「PR / CI」節

### PR / CI

- PR: https://github.com/6in/mojo-pg/pull/2（`gh pr create --base main`、HEAD `f6c4fdb`。マージは人間 / CI）
- CI run: `39428167302`（event `pull_request`、headSha `f6c4fdb`、created 2026-10-20T13:10:35Z = 自分の push が起動した run）
- CI: **3 / 3 SUCCESS**（`gh pr checks 2 --watch`、13:10:38Z 開始 → 13:23:03Z 完了 = 約 12.5 分、再実行なし）。
  `check (ubuntu-latest)` 13:19:44Z / `check (ubuntu-24.04-arm)` 13:23:03Z / `check (macos-latest)` 13:17:08Z → REQ §4.4「CI 3 OS 緑」達成

### 判定

受け入れ基準 §4.1〜§4.4 と §2.4 をすべて満たす。差し戻しなし。`reflect: true` なので `phase: "reflect"` へ（マージは人間 / CI、タグ・Release は人間）。
