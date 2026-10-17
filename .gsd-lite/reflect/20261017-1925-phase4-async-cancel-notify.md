# 振り返り — phase4-async-cancel-notify（2026-10-17 19:25）

- 種別: ループ（verify round 2 合格後。verify_round 1、fix_round 0）
- 対象範囲: `20524cd...7fe2bd8`（コミット 24 件 = discuss 1 + research 1 + plan 1 + impl 9×2 + verify 3 + マージ 1）/ ターン 1〜13（reflect = 14）
- 前回の振り返り: `20261017-0254-phase3-binary-all-types.md`
- 差分: 42 ファイル +9,230 / −1,587（`.gsd-lite/` と archive 込み）。コード側 28 ファイル +5,851 / −242（`async_conn.mojo` 1,588 行・`_platform/poll.mojo` 302 行・テスト 3 ファイル新設 2,602 行）

## 計測（turns.jsonl から）

| フェーズ | ターン数 | 試行数 | 所要（分） | リトライ | 出力トークン | キャッシュ読み | コスト（USD） | エンジン / モデル |
|---|---|---|---|---|---|---|---|---|
| research | 1 | 1 | 22.7 | 0 | 102,119 | 5,550,802 | 16.65 | claude / claude-fable-5-1 |
| plan | 1 | 1 | 16.0 | 0 | 77,060 | 3,909,407 | 10.55 | claude / claude-fable-5-1 |
| impl | 9 | 9 | 197.2 | 0 | 390,168 ※ | 99,543,280 | 81.06 | claude / claude-opus-5 |
| verify | 2 | 2 | 24.5 | 0 | 29,549 ※ | 4,618,458 | 22.55 | claude / claude-fable-5-1 |
| **合計** | **13** | **13** | **260.4** | **0** | **598,896 ※** | **113,621,947** | **130.81** | |

※ turn 10 / 11 / 13 は生ログに `result` イベントが 3 / 3 / 2 件あり、turns.jsonl は**最後の 1 件**だけを記録している（turn 10: 記録 `num_turns` 11 / 出力 4,408 に対し、生ログ 3 件の合計は 80 / 30,368。turn 11: 19 / 19,830 に対し 67 / 52,493）。`cost_usd` は累積値なので正しい。`usage` はサブエージェント分を含まない（Phase 2 / 3 と同じ。Interesting 4）

impl のターン別 所要（秒）/ コスト（USD）/ サブエージェント実本数（生ログ `subagent_stats.spawned`）/ PLAN の推奨本数:
T1 963 / 7.25 / 0 / 1、T2 1,418 / 8.05 / 0 / 1、T3 2,097 / 10.70 / 0 / 1、T4 970 / 7.35 / 0 / 1、T5 1,194 / 10.36 / 1 / 1、
T6 1,274 / 6.38 / 0 / 0、T7 1,738 / 12.18 / 1 / 1、T8 827 / 6.48 / 0 / 0、F1 1,351 / 12.30 / 0 / 0。
research 1,359 / 16.65 / 1 / 1。verify round 1 1,091 / 17.11 / 2、round 2 380 / 5.44 / 0。

- 権限拒否（permission_denials）: なし（13 ターンすべて `[]`）
- 無進捗の試行: 0。`attempt > 1` の行: 0（`turn-NNN-attempt2.log` も無い）
- 利用枠（rate_limit.five_hour）: turn 1 で 0.14、turn 1〜2 の間に 5 時間枠がリセット（`resets_at` 1792219200 → 1792237200）、turn 2〜13 で 0 → 0.27。seven_day 0.28 → 0.33。Phase 3（1 枠で 55 %）より軽い
- 計画タスク数 / impl ターン数: 8 / 9（T1〜T8 が 8 ターンちょうど + F1）
- verify 差し戻し: 1 回（round 1 = 誤動作 1 + D12 整合 1 + 文書・例 5 を F1 に同梱）。round 2 指摘 0。BLOCKED: 0 回
- やり直し（PROGRESS の欄の合計）: 20 回（turn 1 ×5 / 2 ×1 / 3 ×1 / 4 ×2 / 5 ×3 / 6 ×0 / 7 ×3 / 8 ×1 / 9 ×1 / 10 ×0 / 11 ×1 / 12 ×2 / 13 ×0）。うち Mojo 1.1.0 の言語・stdlib 由来が 12、テストの競合・バグ修正が 4、記録・手順が 4
- Phase 3 との比較: 14 ターン / 262.9 分 / USD 164.07 → **13 ターン / 260.4 分 / USD 130.81**（−20 %）。impl 1 ターンあたり USD 11.21 → **9.01**。ただし impl 1 ターンあたりの親のキャッシュ読みは 7.7M → **11.1M**（Interesting 1）
- 前回の提案の反映（REQ §9 と PLAN「reflect 提案の反映」表 + 記録で照合）:
  - 守られた（9 件）: 1 持ち越し整理 4 件を T1 の 1 コミットに（turn 3、`fa6f21e`）／2 チェックリストを実行可能スクリプト + 現在値（turn 2 `turn-002-checklist.sh`、PLAN 表「現在値」列、impl 全ターンが自タスク行を実行、T8 は再実行だけ）／3 「未確認」行の処分表（TRACE.md §3、10 件 → テスト 1 / 契約外 7 / verify 申し送り 2）／4 verify の字句指摘をクラスで（VERIFICATION §4-3、5 件同梱、round 2 の新規指摘 0）／5 「期待される変化」を数で（VERIFICATION §8.1、round 2 が 380 s）／8 RESEARCH の期待値を省略しない（turn 1 次への注意）／9 §0.5 に 7 件転記（RESEARCH §0.5 ★☆）／10 SKIP 集計 (b)（D2 → REQ §4.8 → T1 (f)(g)）／11 「テスト 2 ファイル型を 1 本」の実験（T5。結果は Interesting 2）
  - 部分的に守られた（2 件）: 6 所要見積もりの式（式は PLAN 検証コマンド節に使われたが 3 回連続で過大。Minus 2）／7 PROGRESS 40 行上限 + TRACE.md（TRACE.md は新設され verify が読んだが、turn 5 / 7 / 9 / 12 が 43 / 52 / 47 / 41 行で超過。Minus 3）
  - 守られなかった（1 件）: 12 ツール側（`usage` / `num_turns` は依然「最後の `result`」。turns.jsonl のキーに `subagents` は無い。`finished_at` は Phase 3 で反映済み。Minus 4）

## Plus（うまくいったこと）

- **13 ターン、リトライ 0・権限拒否 0・BLOCKED 0・差し戻し 1 回で完走し、8 タスクが 8 ターンちょうどで終わった**（根拠: turns.jsonl 全行 `attempt: 1` / `progressed: true`、コミット列は T1〜T8 / F1 すべて「コード 1 本 + 申し送り 1 本」の 2 コミット）
- **追従先チェックリストのスクリプト化が機能した**: 85 行の key を impl が毎ターン自タスク分だけ照合し、T8 は再実行のみ、verify は round 1 / 2 で再実行して「diff なし」を根拠にした（根拠: turn 2 やったこと、turn 3〜10 の「チェックリスト」行、VERIFICATION §2.1 / §8.3）。PLAN の期待値訂正は 3 件（`_skip_on_macos` 11 → 10、`ffi_PQsetSingleRowMode` 2 → 3、`result_unsafe_ptr` 期待 3 → 6）で、Phase 3 の 4 件と違い「現在値を打てば判明する」種類は 1 件だけ。他 2 件は `mojo format` の行割りと T2 のコード移動が原因で plan 時点では知り得ない
- **T5 のテスト格子が本物の状態機械バグを露わにし、同ターンで直した**: 切断時に `poll_result` が永遠に `BUSY` を保ち以降の `send` が全部 `USAGE` になる経路（根拠: turn 7 やったこと「`src/` の差分: バグ修正 1 件」、プローブ `scratch/turn-007-probe-disconnect.mojo`）。PLAN が T5 に「テストが露わにしたバグ」の枠を用意していたので src 変更が逸脱にならなかった
- **verify round 1 の格子プローブと読み取り専用サブエージェント 2 本が独立に同じ欠陥（`timeout_ms` の `c_int` 切り捨て）に到達した**（根拠: VERIFICATION §4-1「親・セキュリティの 2 経路で独立に検出」、§3 P1）。round 2 は「数の照合 + 格子の再実行」に限定して 380 s / USD 5.44 で合格（マイルストーン最安のターン）
- **陽性対照 5 本が全部同ターンで実測され、見えなかったものは見えないと書かれた**（根拠: turn 3 (f) exit code 1、turn 7 の状態検査除去 → libpq 文言、turn 8 の `PQfreemem` 除去 → RSS 単調増加 FAIL と **`PQfreeCancel` 除去は平坦のまま = 契約外と明記**、turn 9 スキャナ 4 入力、turn 12 `if True: return`）
- **既存テストの期待値変更がマイルストーン全体でゼロ**（根拠: turn 3〜12 の各「既存テストの期待値変更」欄、VERIFICATION §8.2 コードレビュー確認。唯一の既存テスト変更は turn 9 の `_wait_until_active` で手順のみ）
- **「期待値の取り直し」の常設手順が、テストが flaky になる前に 1 件の食い違いを捕まえた**: `pg_terminate_backend(pg_backend_pid())` の自己終了は `57P01` ではなく `CONNECTION`（根拠: turn 7「期待値の取り直し」）。turn 5 / 6 でも 5 + 3 値を取り直し全部一致
- **T8 の TRACE.md（チェックリスト生出力 / 受け入れ基準対応表 / 未確認処分表）を verify が起点に使った**（根拠: VERIFICATION §2「TRACE.md §2 の対応表を起点に」、turn 12 が F1 の対応表を §4 に追加）
- **コストが Phase 3 比 −20 %（USD 164.07 → 130.81）で、所要は同じ 260 分、差し戻しも同じ 1 回**（根拠: 計測表、Phase 3 reflect 計測表）

## Minus（問題・無駄・やり直し）

- **差し戻し F1 の主因「`timeout_ms` ≥ 2^31 の黙った誤動作」は、PLAN の境界値リストに上限が無かったために impl が試さなかった**（根拠: PLAN「観点の担当」境界値「`timeout_ms` の -1 / 0 / 正 / -2」、決めた事項 1 に `c_int(timeout_ms)` の縮小変換が明記、turn 4 の T2 テストは `-2` のみ、VERIFICATION §4-1）。F1 + round 2 で 1,731 s / USD 17.74（Phase 3 の F1 + r2 は 1,294 s / USD 10.3）。原因の見立て: 落とし穴 34 件は libpq の挙動に偏り、「Mojo の `Int` を C の 32 bit に渡す」型の境界が観点に入っていなかった
- **PLAN の所要見積もりが 3 マイルストーン連続で過大**（根拠: PLAN 検証コマンド節「`check` 260〜300 s / `test` 330〜360 s」に対し実測 `check` 133〜221 s / `test` 216〜314 s。turn 3 想定外 (3)、turn 10 確認済み欄）。前回提案 6 の式「新テスト 1 ファイルあたり接続数 × 3〜7 s」を使ったが、実測は `test_async` 10〜12 接続で 2.6〜3.6 s（turn 5）= 接続 1 本 0.3 s 以下。接続 3〜7 s は `test_zero_copy` だけの性質（turn 9 想定外 (2)）で一般化できない
- **PROGRESS 1 ターン 40 行の上限を 4 ターンが超え、PLAN.md は 101 KB（510 行）で過去最大**（根拠: `wc -c`、PROGRESS 見出し行番号から turn 5 43 / turn 7 52 / turn 9 47 / turn 12 41 行、PLAN チェックリスト表の `utf8_*` 行がセル内に訂正 3 回分を抱えて 2 行 600 文字超）。impl の親のキャッシュ読みは 1 ターン平均 11.1M（Phase 3 7.7M、F1 は 18.5M）。原因の見立て: PLAN 訂正を表のセルに追記する運用で PLAN が肥大し、PROGRESS は「検証（所要つき）」「チェックリスト」の 2 行が毎ターン 6〜8 行ずつ占める
- **ツール側の記録が 3 ターンで実際より小さい**（根拠: turn 10 生ログに `init` 3 件・`task_notification` 7 件・`result` 3 件、turns.jsonl は最後の 1 件 `num_turns` 11 / 出力 4,408。turn 11 は 3 件中の最後 19 / 19,830、turn 13 は 2 件中の最後。前回提案 12 は未反映、キーに `subagents` 無し）。推測: バックグラウンドタスクの完了通知でセッションが再開されるたびに `result` が出る（turn 10 はサブエージェント 0 本なので `run_in_background` の Bash 由来）。この表の出力トークン列はこの 3 ターン分だけ過小
- **verify round 1 がサブエージェントの完了を出力ファイルの mtime ループで待とうとして即終了し、`sleep 300` で待ち直した**（根拠: turn 11 想定外 (1) / やり直し 1 回）。所要への影響は記録なし。出力は完了時にまとめて書かれるので mtime では待てない（Phase 3 でも同じ事象。memory `gsd-lite-verify-waiting` に記録済みだが REQ §9 には無い）
- **テストが両サーバーに `pq_test_ascii` DB を恒久的に残し、verify のセキュリティ側も `pq_sec_ascii` DB を作って消した**（根拠: turn 12 次への注意「消さずに残る」、turn 13 次への注意、turn 11 想定外 (2)）。`db-up` は compose の起動だけで DB の状態を戻さないので、環境が「テストを 1 回走らせた後」の形で固定される。「読み取り専用」の verify サブエージェントが DB には書いた
- **やり直し 20 回のうち 12 回が Mojo 1.1.0 の言語・stdlib 由来で、RESEARCH §0.5（★ 7 + ☆ 8）に無い名前・制約だった**（根拠: turn 1 やり直し欄 4 件、turn 3 (1) `return e^`、turn 4 (2) 一時値への mutating 呼び出し、turn 5 (2)(3) `try` 内の例外型 / `Optional = None` 警告、turn 7 (2) `prefix^ + chr(0)` の解釈、turn 8 (1) 同警告、turn 12 やり直し 2 件）。いずれも 1 回のコンパイルで直ったので 1 件数分だが、転記の効果が及ばない種類が毎マイルストーン出る

## Interesting（気づき・意外だったこと）

- **PLAN の「推奨本数 1」は T1〜T4 で実 0 本だった**（根拠: turn 3〜6 やったこと「サブ作業は 1 本だけなのでサブエージェントは使わず」、生ログ `spawned: 0`）。plan は「並列サブ作業の本数」を書き、impl は「サブ作業が 1 本なら親が書く方が速い」と読んだ。結果 impl 9 ターン中 7 ターンがサブエージェント 0 本で、コストは Phase 3 比 −20 %、差し戻し回数は同じ。並列度を下げても品質・所要が落ちなかった
- **REQ §9 の実験「テスト 2 ファイル型を 1 本」の結果**: T5 = 1 本・1,194 s・USD 10.36・+1,022 行（テスト 22 件 + src バグ修正）に対し、Phase 3 T6 = 2 本・1,365 s・USD 10.77（根拠: turns.jsonl turn 7、`git show --stat 159a073`、Phase 3 reflect 計測）。1 本にしてもコストは下がらないが上がりもせず、親が自分でテストを書いたことで src のバグを同ターンで直せた。T7（1 本、スキャナ + 単体をサブ側）は USD 12.18 で impl 最高額クラス
- **F1 が Phase 3 の F1 より 7 割高いのは、verify が D12 整合（通知の UTF-8）を「ついでに揃える」で同梱し、`SQL_ASCII` の専用 DB をテストが作る形になったため**（根拠: VERIFICATION §4-2、turn 12 `num_turns` 148 = 全ターン最多、`4f109c8` の `test_notify.mojo` +144 行）。同梱しなければ残留リスクとして持ち越されていたので、差し戻し 1 ターンに収まった以上は妥当。ただし「ついで」の規模は差し戻し前に見積もられていない
- **`result` イベントが 1 ターンに複数ある現象はサブエージェントとは無関係**（根拠: turn 10 はサブエージェント 0 本で `init` 3 件、turn 7 / 9 はサブエージェント 1 本で `result` 1 件）。`run_in_background` の Bash（`pixi run test` 等）の完了通知が契機と推測。Phase 3 の turn 6 と同じ型だが原因の見立てが変わった
- **`check` の所要はテストを足しても増えなかった**: 152 → 133 → 221 → 169 → 158 → 169 → 187 → 180 → 175 → 167 s（turn 3〜13）。16 MB クエリ・切断・leak 4 ループを足した T5 / T6 で +0〜11 s。支配しているのは Phase 3 以前からの leak 74 s と `test_zero_copy` 46 s（turn 8 / 9 の計測）。「5 分を超えたら書く」の閾値は一度も届かず、Phase 3 と同じ結論
- **落とし穴 34 件すべてにタスクの対応先があったのに、差し戻された欠陥は 34 件の外だった**（根拠: PLAN「対応先の無い落とし穴は無い」、VERIFICATION §4-1）。網羅表は「挙げた物の抜け」は防ぐが「挙げる観点の抜け」は防がない。Minus 1 の境界値リストの話と同根
- **turn 9 で `test_notify` の競合（listener の backend がクエリを読む前に NOTIFY が commit する）が通しの 1 回目で初めて落ちた**（根拠: turn 9 想定外 (1)。単体 3 回連続 PASS で flake と確認してから `_wait_until_active` を挿入）。T4 / T5 の 2 ターンでは出なかった既存の競合を、無関係な T7 のターンが負担した。impl が「T7 とは無関係」と原因まで特定して直したので verify に持ち越さなかった
- **research ターンが出力トークン最多（102,119）でやり直しも最多（5 回）**、一方で REQ の「要実測」8 件は矛盾なしで、REQ 本文の訂正は 3 箇所（根拠: turn 1）。Phase 3（5 箇所訂正）より REQ が正確だったのは discuss が §4.7 等をすでに「要実測」と印していたため
- **5 時間の利用枠がマイルストーン中にリセットされた**（根拠: turn 1 `resets_at` 1792219200 → turn 2 以降 1792237200、`five_hour` 0.14 → 0 → 0.27）。4 時間 20 分のマイルストーンは 1 枠に収まらない

## 次回への提案（実行可能な形で）

- [ ] **plan: 「境界値」の観点に縮小変換の行を常設する**: 決めた事項に `c_int(x)` / `Int32(x)` / `Int16(x)` / `UInt32(x)` と書いた引数は、その値域の上限ちょうど・上限 +1・`Int.MAX`・`-1` を完了基準のテストに列挙し、チェックリストに `<arg>_max_guard`（`> <上限>` の検査行の `grep -c` ≥ 1）を足す。研究の落とし穴表にも「Mojo → C の型幅」を 1 節設ける（Minus 1、Interesting 5）
- [ ] **plan: 所要見積もりの式を Phase 4 の実測で置き換える**: `check` = 前回末実測（Phase 4 末 **167〜187 s**） + 新テストファイル数 × 5 s（コンパイル） + 新テストの明示的な `pg_sleep` / タイムアウト秒の合計 + leak 新ループの単体実測。接続は 1 本 0.3 s で数え、「3〜7 s」は使わない。`pixi run test` = `check` + leak 74 s（PG14 分）+ 60 s。閾値「5 分を超えたら書く」は「`check` が前回末 +60 s を超えたら書く」に（Minus 2）
- [ ] **plan / impl: PLAN 訂正は表のセルに追記しない**。チェックリスト表は「key / 直す場所 / 期待値」の 3 列だけにし、現在値はスクリプトの出力ログ（`scratch/turn-002-checklist.log`）へ。impl の PLAN 訂正は `.gsd-lite/TRACE.md` に「PLAN 訂正（turn N）」節を設けて 1 件 1 行で積む。PROGRESS の「検証（所要つき）」は 2 行（test / check の所要と結果）、「チェックリスト」は「自タスク行 N 件すべて期待値（例外: key=値）」の 1 行に固定し、生の値は TRACE に置く（Minus 3）
- [ ] **plan: 「推奨本数」を「サブエージェント N 本（親を除く）」と書き、サブ作業が 1 本だけのタスクは「0 本（親が全部）」と明記する**。テストのみ 2 ファイル型は 1 本を既定にする（T5 の実験: 2 本と同コストで親が src のバグを拾えた）。reflect は「実本数 × コスト」を表に出すので impl は PROGRESS「やったこと」の「推奨 N 本 / 実 M 本」を続ける（Interesting 1・2）
- [ ] **ツール側（マイルストーン間にユーザーが行う）**: `gsd-lite-loop.sh` で 1 試行の生ログに `result` が複数あるとき、`num_turns` と `usage` の各項目は**全 `result` の合計**、`cost_usd` は最後の値にする。`subagent_stats.spawned` を `subagents` として turns.jsonl に記録する（前回提案 12 の未反映分。Minus 4。turn 10 は 11 vs 80 / 4,408 vs 30,368）
- [ ] **research: RESEARCH §0.5 に Phase 4 の落とし穴 9 件を追加する**: `PgError` を値で返すとき `return e^`／`except e: return e^` の `try` 本体から `Error` を投げるヘルパ（`assert_*`）を呼べない（判定は `try` の外へ）／`var x: Optional[T] = None` は `except` が必ず脱出すると「assignment never used」警告（宣言だけにする）／`FileDescriptor(fd).write()` は一時値への mutating 呼び出しで不可（`var` に受ける）／`prefix^ + chr(0)` は `^` 演算子と解釈される（借用引数にする）／`self._field^` でフィールドから move out 不可（`copy()` + `clear()`）／`print("SKIP ...")` は 80 桁を超えると `mojo format` が割り grep パターンが外れる／`len(StringSlice)` は `byte_length()`／`__origin_of` は `origin_of`（Minus 7）
- [ ] **次マイルストーンの T1（持ち越し整理）に 3 件を 1 コミットで入れる**: (1) `tests/test_notify.mojo` の `SQL_ASCII` テストが作る `pq_test_ascii` DB をテスト末尾で `DROP DATABASE`（または `pixi run db-reset` タスクを足して `check` の先頭で呼ぶ）、(2) VERIFICATION §5 先頭「`fetch_all` が `PQstatus` BAD にならない `CONNECTION` エラーで busy-spin」→ `kind == CONNECTION` なら status に関わらず drain を打ち切る、(3) 同 §5「`_after_send` で `PQflush` が -1 のとき pq は `IDLE`、libpq は `BUSY`」→ -1 のとき `BUSY` に置く（どちらも 1 分岐 + テスト 1 件ずつ）（Minus 6、VERIFICATION §5）
- [ ] **verify: REQ §9 に 2 行足す**: (a) サブエージェントの完了は出力ファイルの mtime で待たず、`sleep <見込み秒>` の Bash 1 本（または完了通知）で待つ（出力は完了時にまとめて書かれる。Phase 3 / 4 で 2 回同じ失敗）、(b) 「読み取り専用」はテスト DB も含む。検証のために DB を作る必要があるなら名前を `pq_verify_<turn>` にして同ターンで消し、PROGRESS に書く（Minus 5・6）
- [ ] **verify: 差し戻しに「ついで」の項目を同梱するときは F 項目に「見込み行数 / 新しいテスト資源（DB・コンテナ）の有無」を 1 行書き、impl は F1 の PROGRESS で項目ごとの所要を分けて書く**。reflect が「同梱が 1 ターンに収まる規模か」を判断できる記録にする（Interesting 3。今回は収まったが根拠が無い）
- [ ] **discuss: Phase 5 の範囲に「`db-reset` 相当の環境整備」と「Windows 分岐のレビュー」「`test_zero_copy` の接続固定費」を入れるか聞く**（turn 10 verify 申し送り 2 件、turn 13 次への注意。3 件とも Phase 4 が「Phase 5 が引き取る」と書いたまま決定が無い）
