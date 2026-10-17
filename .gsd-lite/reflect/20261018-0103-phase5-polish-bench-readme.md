# 振り返り — phase5-polish-bench-readme（2026-10-18 01:03）

- 種別: ループ（verify round 3 合格後。verify_round 2、fix_round 0）
- 対象範囲: `8c48277...c88173e`（ブランチのコミット 24 件 = discuss 1 + research 1 + plan 1 + impl 9×2 + verify 3）+ `main` 側のマージ `cfa905b` と state 更新 `2b67f2f` / ターン 1〜14（reflect = 15）
- 前回の振り返り: `20261017-1925-phase4-async-cancel-notify.md`
- 差分: 38 ファイル +5,390 / −2,038（`.gsd-lite/` と archive 移動込み）。コード側 23 ファイル **+1,568 / −116**（`README.md` 406 行・`LICENSE` 202 行・`test_notify.mojo` +397・`async_conn.mojo` +231・`poll.mojo` +99・`bench_psycopg.py` 113 行・`pixi.lock` Bin 62,885 → 91,504）。Phase 4 のコード側 +5,851 の約 1/4
- 壁時計: turn 1 開始 21:46:56 JST → turn 14 終了 01:00:54 JST = **194 分**。turns.jsonl の所要合計 193.7 分と一致（ターン間の空白なし）

## 計測（turns.jsonl から）

| フェーズ | ターン数 | 試行数 | 所要（分） | リトライ | 出力トークン | キャッシュ読み | コスト（USD） | エンジン / モデル |
|---|---|---|---|---|---|---|---|---|
| research | 1 | 1 | 23.3 | 0 | 107,680 | 4,995,450 | 12.76 | claude / claude-fable-5-1 |
| plan | 1 | 1 | 13.6 | 0 | 70,119 | 3,736,359 | 9.41 | claude / claude-fable-5-1 |
| impl | 9 | 9 | 131.6 | 0 | 215,762 ※ | 55,097,088 | 52.26 | claude / claude-opus-5 |
| verify | 3 | 3 | 25.4 | 0 | 80,926 ※ | 7,591,089 | 16.94 | claude / claude-fable-5-1 |
| **合計** | **14** | **14** | **193.7** | **0** | **474,487 ※** | **71,419,986** | **91.36** | |

※ turn 5 / 9 / 14 は生ログに `result` イベントが 2 / 4 / 2 件あり、turns.jsonl は**最後の 1 件**だけを記録している（turn 9: 記録 `num_turns` 38 / 出力 13,688 に対し 4 件は 35 + 6 + 3 + 38 / 13,688 + 1,285 + 628 + 13,688。turn 5: 記録 18,914 に対し 1 件目は 24,531。turn 14: 記録 25 / 8,593 に対し 1 件目は 33 / 8,090）。`cost_usd` は累積値なので正しい。Phase 3 / 4 と同じ記録の欠け（Minus 3）

impl のターン別 所要（秒）/ コスト（USD）/ サブエージェント実本数（生ログ `subagent_stats.spawned`）/ PLAN の推奨本数:
T1 1,241 / 6.72 / 1 / 1、T2 1,518 / 8.96 / 1 / 1、T3 1,148 / 8.42 / 1 / 1、T4 1,326 / 4.75 / 0 / 0、T5 399 / 2.17 / 0 / 0、
T6 684 / 5.88 / 1 / 1、T7 731 / 6.08 / 0 / 0、F1 487 / 6.30 / 0 / 0、F2 361 / 2.98 / 0 / 0。**推奨と実本数は 9 ターンすべて一致**。
research 1,395 / 12.76 / 0 / —。verify round 1 679 / 7.41（`num_turns` 62）、round 2 453 / 5.30（61）、round 3 389 / 4.23（25）。

- 権限拒否（permission_denials）: **Monitor × 1（turn 9**。examples 堅牢性格子 17 本の完了待ち `until grep -c '^--- rc=' … | grep -qx 17`。loop.log に WARN）。他 13 ターンは `[]`
- 無進捗の試行: 0。`attempt > 1` の行: 0（`turn-NNN-attempt2.log` も無い）
- 利用枠（rate_limit）: five_hour 0.09 → 0.31、seven_day 0.36 → 0.39。`resets_at` は 14 ターンとも 1792257600 で**マイルストーン中のリセットなし**（Phase 4 は 1 回リセットを挟んだ）
- 計画タスク数 / impl ターン数: 7 / 9（T1〜T7 が 7 ターンちょうど + F1 + F2）
- verify 差し戻し: **2 回**（round 1 = `bench_psycopg.py` の堅牢性 2 クラス + README §7 字句 1 件 → F1。round 2 = examples 6 本の docstring の字句 1 件 → F2。round 3 指摘 0）。BLOCKED: 0 回（`git log --all -- .gsd-lite/BLOCKED.md` 空）
- やり直し（PROGRESS の欄の合計）: **2 回**（turn 2 ×1 チェックリストの `ENCODING` パターン、turn 8 ×1 README のコード片の逐語化）。Mojo 言語・stdlib 由来は **0**（Phase 4 は 20 回中 12 回）
- PLAN 訂正: **9 件**（turn 4 ×2 / turn 5 ×3 / turn 6 ×1 は TRACE「PLAN 訂正」節、turn 7 ×1 / turn 8 ×2 は PLAN の該当タスク本文に追記。turn 3 / 9 / 11 / 13 は 0）
- Phase 4 との比較: 13 ターン / 260.4 分 / USD 130.81 → **14 ターン / 193.7 分 / USD 91.36**（コスト **−30 %**、所要 −26 %）。impl 1 ターンあたり USD 9.01 → **5.81**、親のキャッシュ読み 11.1M → **6.1M**
- 前回の提案の反映（PLAN「メモ」の反映表 + REQ §9 + 記録で照合）:
  - 守られた（7 件）: 1 縮小変換の行を常設（PLAN 決めた事項 6、RESEARCH §0.5.1、T3 (c)⑤ の `Int.MAX` / 2^31 / 2^32 格子）／2 所要見積もりの式（PLAN 検証コマンド節 `check` 180〜210 s。**実測 165〜215 s で初めて過大でなかった**。Interesting 3）／4 推奨本数の書き方 + テストのみ型は 1 本（9/9 一致、PROGRESS 各ターンに「推奨 N 本 / 実 M 本」）／6 RESEARCH §0.5 に Phase 4 の 9 件（☆ 節 + §0.5.1）／7 持ち越し整理 3 件を T1 の 1 コミット（`e40c69e`）／8 verify の REQ §9 2 行（REQ §9 にあり。今回 verify はサブエージェント 0 本・DB 作成なしで行使の機会なし）／9 F 項目に見込み行数 / テスト資源（turn 10「見込み +12 行、新しいテスト資源なし」、turn 12「6〜12 行」）／10 discuss で Phase 5 の範囲 3 件を決める（D3 / D10 / D12）
  - 部分的に守られた（1 件）: 3 PLAN 訂正を TRACE に 1 件 1 行 + PROGRESS 40 行上限。TRACE 節は turn 4〜6 の 6 件で使われたが turn 7 / 8 の 3 件は PLAN 本文へ追記。**PROGRESS 40 行は impl 9 ターン中 5 ターンが超過**（Minus 2）
  - 守られなかった（1 件）: 5 ツール側（`usage` / `num_turns` は依然「最後の `result`」。turns.jsonl のキーに `subagents` 無し。3 マイルストーン連続。Minus 3）
  - Phase 3 の提案で今回効かなかったもの: 「verify: 字句の指摘はクラスで名指しし `grep -rn` で全件を同梱」は REQ §9 に写されていたが round 1 が守らず F2 の原因になった（Minus 1）

## Plus（うまくいったこと）

- **14 ターン、リトライ 0・無進捗 0・BLOCKED 0 で完走し、7 タスクが 7 ターンちょうどで終わった**（根拠: turns.jsonl 全行 `attempt: 1` / `progressed: true`、コミット列は T1〜T7 / F1 / F2 すべて「コード 1 本 + 申し送り 1 本」の 2 コミット）
- **やり直しが 2 回（Phase 4 の 1/10）で、Mojo 言語由来は 0**（根拠: PROGRESS 全 14 ターンの「やり直し」欄）。T4 は本体を触る前に `scratch/turn-006-errno-probe.mojo` で `ErrNo.*.value` と `comptime if` 連鎖 + 3 要素 Tuple の形を通してから書いた（turn 6 陽性対照欄「これが無いと本体を壊してから気づく」）。RESEARCH §0.5 の ★☆ 計 30 件超が今回の変更範囲を覆っていた
- **research が REQ の事実誤り 2 件を 1 ターンで潰し、Phase 4 の「再現不能」を再現した**（根拠: turn 1 想定外 (1)〜(3)）。`test_zero_copy`「1 テスト 3.4 s」は TestSuite の ms を s と読んだ架空の性能問題（12 件 49〜56 ms）で D12 は空振りに、`fetch_all` の busy-spin は `pg_terminate_backend` でなく `close(PQsocket)` で 1500 ms 回ることを `probe-closefd` で実測 → T1 (b) の陽性対照「修正前 2003 ms `TIMEOUT` FAIL → 修正後 3.9 ms PASS」に直結した
- **陽性対照が全タスクで実測され、判別しなかった対照は判別しないと書いて差し替えられた**（根拠: turn 3 (b)(e) 3 件、turn 4 (d)(e) 2 件、turn 5「⑧ は restore 7 行を消しても PASS → 第 3 の接続 + `pg_sleep(0.3)` で 1 往復目を `ok` だけにする ⑨ を追加し restore なしで FAIL」、turn 6 の `else` 分岐複製ビルド 74,472 bytes、turn 8 の README コード片 / 型表の機械照合スクリプト 2 本）。verify round 1 は ⑨ と両スクリプトをそのまま再実行して根拠にした（VERIFICATION §1.2 / §1.4）
- **既存テストの期待値変更が計画どおり T2 の 7 行だけ**（根拠: turn 4「全 7 行。T2 (c) のとおりで増減なし」、他 8 ターンの同欄「ゼロ」、VERIFICATION §1.2「PROGRESS turn 4 の 7 行だけ（diff で確認）」）。D9 の影響範囲を RESEARCH §2.10 が grep 基線（src 125 / tests 97）で押さえ、チェックリスト `tests_TYPE_MISMATCH` 97 → 91 で毎ターン監視された
- **所要見積もりが 4 マイルストーン目で初めて当たった**（根拠: PLAN 検証コマンド節 `check` 180〜210 s、実測 185 / 177 / 177 / 182 / 215 / 169 / 187 / 190 / 184 / 189 / 約 165 / 189 / 186 s。閾値 247 s は一度も届かず）。Phase 4 reflect の式「前回末実測 + 接続 1 本 0.3 s + 明示的な待ち」をそのまま使った
- **サブエージェントの推奨本数と実本数が 9/9 一致し、F1 / F2 の差し戻し 2 ターンはそれぞれ 487 s / 361 s で終わった**（根拠: PLAN 各タスクの「並列サブ作業」行、生ログ `spawned`、turns.jsonl）。Phase 4 は T1〜T4 で推奨 1 / 実 0 のずれがあった
- **verify が自分の計測器の欠陥を見つけて直した**（根拠: VERIFICATION §5.3 (2)「`run_pipe` は stderr をパイプにつないでいて stdout の EPIPE を試していなかった → `> >(exit 0)` で本物の EPIPE」）。その結果 Mojo examples の SIGPIPE rc 141 が残留リスクとして開示された（§5.4）
- **コスト Phase 4 比 −30 %、impl 1 ターン USD 5.81**（根拠: 計測表、Phase 4 reflect 計測表）。差分が小さい仕上げフェーズなので単純比較はできないが、impl の親のキャッシュ読みが 11.1M → 6.1M / ターンに下がったのは PLAN 71 KB（Phase 4 101 KB）・PROGRESS 57 KB（82 KB）の縮小と整合する

## Minus（問題・無駄・やり直し）

- **差し戻し round 2（F2）は round 1 が REQ §9 verify の規則「字句の指摘は `grep -rn` でリポジトリ全体を列挙して F 項目に同梱」を守らなかったことで生じた 1 ターン分**（根拠: turn 12 想定外 (2)、VERIFICATION §5.3「なぜ前ラウンドで拾えなかったか」、turn 14 次への注意）。README §7 の言い切りを直すとき同文の examples 6 本の docstring を見なかった。F2 + round 3 = turn 13 + 14 = **750 s / USD 7.21**（マイルストーンの 8 %）。原因の見立て: 規則は REQ §9 に散文で書かれているだけで、VERIFICATION の F 項目の形式に「grep パターン / 件数 / ファイル列」の欄が無く、守ったかどうかが記録に残らない。Phase 3 reflect の提案 → REQ §9 → 不履行、の経路は「書いても読まれない」型
- **PROGRESS 1 ターン 40 行の上限を impl 9 ターン中 5 ターンが超えた**（根拠: 見出し行番号から turn 4 **44** / turn 6 **44** / turn 7 **50** / turn 8 **64** / turn 9 **44** 行。Phase 4 は 4 ターン超過・最大 52 行）。超過分の中身はチェックリストの `key=値` を全件列挙する段落（turn 3 / 4 / 5 / 6 / 8 とも 4〜6 行）と、ベンチ 12 セルの転記（turn 7 / 8）。REQ §9 impl「チェックリストは 1 行、生の値は TRACE へ」は書かれていたが、TRACE に「チェックリスト（turn N）」節は作られず PROGRESS に残った。原因の見立て: TRACE の 7 節は PLAN T1 (h) が見出しを固定しており、チェックリストの生値の置き場が定義されていなかった
- **ツール側の記録が 3 ターンで実際より小さい（3 マイルストーン連続・未反映）**（根拠: 計測表の ※、turn 9 生ログに `result` 4 件・サブエージェント 0 本・Monitor 使用あり、turn 14 `result` 2 件・サブエージェント 0 本）。turns.jsonl のキー列は `attempt … usage` の 22 個で `subagents` は無い。Phase 4 reflect の提案 5 は「ユーザーがマイルストーン間に行う」とされたまま。推測: turn 9 の 4 件はバックグラウンドの Monitor / Bash 完了通知でセッションが再開されるたびに `result` が出る（Phase 4 reflect Interesting 4 の見立てと同じ。turn 14 は verify でサブエージェント 0 本なので同型）
- **Monitor ツールが 1 マイルストーンで 3 種類の不具合を出した**（根拠: turn 9 の permission_denials `Monitor` 1 件 = 格子 17 本の完了待ち、turn 9 想定外 (3)「`final_check` のパターンが pixi バナーに当たって空振り」、turn 11 想定外 (4)「`until grep` 監視が実在しない `final_check: PASS` を 2 回報告 → 前景の `until` ループで待ち直し」）。所要への影響は記録なし（PROGRESS に秒数が無い）。impl 自身が turn 11 で「監視の通知はログ実物で裏取りする」と結論し、turn 13 / 14 は Monitor を使っていない。原因の見立て: `Monitor` は allowlist に無く承認待ちになる（1 件は拒否）うえ、通知の信頼性が低い。deny して前景ループに統一するのが安い
- **impl の堅牢性格子 17 本に出力経路と入力エンコードの軸が無く、verify round 1 の 37 本が 2 クラスの欠陥を拾った**（根拠: VERIFICATION §3「なぜ impl の格子で拾えなかったか: RESEARCH の 15 本を踏襲し『DB 側の失敗』だけ」、turn 10 想定外 (2)）。F1 + round 2 = turn 11 + 12 = **940 s / USD 11.60**。D4 は「どの入力・**出力**状態でも」と書いていたが、PLAN T7 (b) の格子は badpw / badport / nolib / 不正 conninfo の 4 軸で出力状態を列挙していない。原因の見立て: RESEARCH §2.9 の 15 本が「examples が落ちる条件」の面で作られ、plan がそれを完了基準に写すだけで D4 の文言と突き合わせなかった
- **PLAN 訂正 9 件のうち 3 件は PLAN 自身の記述間の矛盾で、plan ターンで検出できた**（根拠: TRACE「PLAN 訂正」turn 5「表は ≥ 4 と見込んだが PLAN (a) 自身が『`_collect_notifications` の中で 1 回』と定めている」、turn 6「表は 1 を写していたが T4 (c) 自身が docstring にも書くことを完了基準にしている」、turn 8 ②「11 節 → 決めた事項 11 の列挙は 10 節」）。残り 6 件は T1 の行ずれ（turn 3 次への注意が予告済み）・同一行 grep の漏れ・陽性対照の結果による追加・公式 LICENSE の先頭空行・物理 2 行、で plan 時点では知り得ない。原因の見立て: チェックリストの期待値を `= N` で書いた行が多く、「増える方向」の key は `≥` で書けば 2 件（≥ 4 / 1）は訂正自体が不要だった
- **verify の F 項目の見込み行数が 3 倍外れた**（根拠: turn 10 次への注意「見込み +12 行」、turn 11 想定外 (3)「`.py` だけで +44 / −14。内側 try のインデントで本体 12 行が差分に乗る」）。影響は無い（1 ターンに収まった）が、前回提案 9 の「見込み行数」は差分の単位で書かないと reflect の判断材料にならない
- **記録の小さな欠け 2 件**: verify round 2 が `check` の開始時刻を取り忘れて所要が mtime からの概算「約 165 s」になった（turn 12 想定外 (3)）。Monitor 関連の待ち直しの所要が PROGRESS に無い（上記）

## Interesting（気づき・意外だったこと）

- **Phase 4 が「Phase 5 が引き取る」と書いた 3 件のうち 1 件は存在しない問題だった**（根拠: turn 1 想定外 (1)、RESEARCH §0.5 ◇ 1 件目、TRACE「`test_zero_copy` の所要」節）。D12 は「原因特定 + 記録、テスト側なら直す」まで決めていたが、research の最初のプローブで単位の読み違いと判明し、決定ごと不要になった。discuss で決める前に 1 プローブ打てば消えていた決定
- **Phase 4 の「再現不能」は再現方法の問題だった**（根拠: turn 1 想定外 (3)「Phase 4 は `pg_terminate_backend` 方式しか試していなかった」、RESEARCH §2.7、libpq ソースの `pqsecure_raw_write` が EBADF を成功扱いにする記述）。サーバー側から切る方式では `PQstatus` が BAD になるので drain が止まり、クライアント側の fd を閉じる方式でだけ BAD にならず回る。「再現不能」は「この方式では再現しない」と書くべきだった
- **REQ §9 の reflect への宿題「テスト 2 ファイル型を 1 本」の USD 比較**: T2（src 4 ファイル親 + tests 3 ファイルをサブ 1 本）1,518 s / USD 8.96、T3（src 1 + `__init__` 親 + `test_notify` 12 件をサブ 1 本）1,148 s / USD 8.42、T6（README 親 + LICENSE / docstring 5 本をサブ 1 本）684 s / USD 5.88。Phase 3 T6（2 本）USD 10.77、Phase 4 T5（1 本）10.36（根拠: turns.jsonl、生ログ `spawned`、Phase 3 / 4 reflect）。1 本は 2 本より高くならず、今回はむしろ安い。ただし今回の 3 タスクは差分が小さく（+397 / +231 行）、モデルは全マイルストーン同じ claude-opus-5 なので「1 本で十分」までは言えても「1 本が安い」とは言えない
- **所要見積もりが当たった年に限って、見積もりに無い `check` の揺れ幅（169〜215 s = 46 s）が出た**（根拠: turn 6「2 回目 215 s、変更は docstring 1 文」、TRACE 処分表 #9「同時実行のノイズ」）。閾値 247 s（前回末 + 60 s）は揺れ幅を吸収したので、式の「+60 s」は見積もり誤差ではなくノイズの吸収幅として機能している
- **チェックリスト 82 key に「現在値を打てば判明する」型の誤りが 0 件**（根拠: TRACE「PLAN 訂正」6 件 + PLAN 本文 3 件の内訳。Phase 3 は 4 件、Phase 4 は 1 件）。plan ターンでスクリプトを 1 回実行する運用（Phase 3 提案 2）が 2 マイルストーンで定着した。残った誤りは PLAN の記述間の矛盾（Minus 6）に移った
- **verify 3 ラウンドの `num_turns` は 62 / 61 / 25 で、round 2 は「格子の再確認 + F1 の回帰だけ」と限定したのに round 1 と同じ長さ**（根拠: turns.jsonl）。round 2 は 42 レコードの格子を HEAD から再ビルドして回し（VERIFICATION §5.2）、さらに計測器の欠陥を直して EPIPE を試し直した（§5.3）。限定は「新しいクラスを探さない」であって「手を抜く」ではなく、結果として 1 件の指摘と 1 件の残留リスクを出した
- **`pixi` が PATH に無い問題は PLAN が turn 2 から絶対パスで書いていたのに turn 7 で踏んだ**（根拠: `git show 1216e3c:.gsd-lite/PLAN.md` に `/home/parallels/.pixi/bin/pixi` 17 件、turn 7 想定外 (3)）。turn 3〜6 の PROGRESS は `pixi run test` と書いているが実際の呼び方は記録されていない。推測: impl は PLAN の検証コマンド節を写さず PROGRESS の前ターンの表記（`pixi run …`）を真似た。turn 7 以降は毎ターン「`pixi` は絶対パスで」が次への注意に並ぶ（6 回）
- **無人シェルの作法に当たった 2 件はどちらも 1 回で回避された**（根拠: turn 3 想定外 (2)「`PQ_MOJO_LIBPQ=… pixi run` は先頭の変数代入で禁止 → `env VAR=… pixi run …`」、turn 2 想定外 (4)「`curl` / `md5sum` は allowlist に無い → `pixi run python` の `urllib`」）。研究・計画の段階で allowlist を意識した判断が 2 件とも PLAN 決めた事項に残り、impl は迷わなかった
- **bench 環境の初回作成は見込み 1 分に対し 3 s**（根拠: turn 7「既に solve 済みのパッケージがキャッシュにあったため」、RESEARCH §2.1 が research ターンにスクラッチ pixi 環境を作っていた）。research のプローブが impl の環境作成を前倒ししていた形で、見積もりが遅い方向に外れたのは害が無い
- **`result` イベントの複数発生はサブエージェントと無関係という Phase 4 の見立てが補強された**（根拠: turn 9 サブ 0 本・Monitor 使用・`result` 4 件、turn 14 サブ 0 本・`result` 2 件、turn 3 / 4 / 8 サブ 1 本・`result` 1 件）。バックグラウンド待ち（Monitor / `run_in_background` Bash）の完了通知が契機でほぼ確定
- **verify round 1 が README の 12 セル × 4 行・型表 19 行・コード片 6 本・Windows 照合表 12 行を 679 s で全部突き合わせた**（根拠: VERIFICATION §1.4、turn 10 やったこと）。impl が機械照合スクリプト（`turn-008-readme-excerpts.py` / `turn-008-typetable.py`）と原本ログ（`turn-007-bench.log`）を残していたため、verify は再実行と目視だけで済んだ。文書の多いマイルストーンで verify が impl より短い（25.4 分 vs 131.6 分）のはこの資産による

## 次回への提案（実行可能な形で）

- [ ] **verify: VERIFICATION の指摘表に「grep パターン / 件数 / ファイル」の 3 列を必須にする**。字句・文言・docstring に関する指摘は 1 件につき `grep -rn '<語>' src tests examples README.md` の件数とファイル名を同じ行に書き、F 項目はその全ファイルを対象にする。件数 0 の指摘は「README だけ」と明記する。REQ §9 の散文は残し、形式の方で守らせる（Minus 1。F2 + round 3 = 750 s / USD 7.21）
- [ ] **plan: 堅牢性格子の軸を PLAN に 3 軸で常設する**: 入力（conninfo 空 / `postgresql://` URI / 非 UTF-8 / 制御文字 / 100 KB / 存在しない DB）× 出力（`/dev/full` / 閉じた fd 1 / `> >(exit 0)` の EPIPE）× 依存（libpq 不在 / `libc.so.6` / ディレクトリ / 空ファイル）。雛形は `.gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-012-robust-regress.sh`（42 レコード、`run_pipe` 修正済み）を次の slug の scratch にコピーして使う。RESEARCH の格子を写すときは D4 相当の受け入れ基準の文言（「どの入力・出力状態でも」）と軸を突き合わせる 1 行を plan の完了基準に置く（Minus 5。F1 + round 2 = 940 s / USD 11.60）
- [ ] **impl: TRACE.md に「チェックリスト（turn N）」節を T1 で作り、PROGRESS のチェックリスト段落は「自タスク行 N 件すべて期待値（例外: key=値）。生値は TRACE」の 1 行に固定する**。PLAN の最終タスク（T7 相当）の完了基準に `awk '/^## turn/{n=0} {n++} END{print n}' .gsd-lite/PROGRESS.md` 相当で「最新ターン節が 40 行以内」を検査する 1 コマンドを検証コマンド節に置く（Minus 2。5 ターン超過、最大 64 行）
- [ ] **settings: `Monitor` を `.claude/settings.json` の deny に入れ、完了待ちは前景の `until grep -qE 'final_check: (PASS|FAIL)' <log>; do sleep 5; done` に統一する**。待ちの前後に `date -Iseconds` を打って所要を PROGRESS に書く（Minus 4・8。拒否 1 + 誤報 2 + パターン空振り 1。turn 12 の所要概算も解消）
- [ ] **plan: チェックリストの期待値は「増える方向」の key を `≥ 現在値 + 最小増分` で書き、`= N` は「0 になる」「不変」の性質だけに使う**。あわせて plan ターンの最後に「期待値の根拠がタスク本文の『N 箇所に書く』と一致するか」を表の `≥` 行だけ見直す（Minus 6。9 件中 3 件が PLAN 内の矛盾、うち 2 件は `≥` なら訂正不要）
- [ ] **verify: F 項目の「見込み行数」は `git diff --stat` の `+/-` 単位で書き、既存関数の中にブロックを足す変更はその関数の行数を見込みに入れる**（Minus 7。+12 → +44 / −14）
- [ ] **ツール側（マイルストーン間にユーザーが行う。3 回目）**: `gsd-lite-loop.sh` で 1 試行の生ログに `result` が複数あるとき `num_turns` と `usage` 各項目は**全 `result` の合計**、`cost_usd` は最後の値。`subagent_stats.spawned` を `subagents` として turns.jsonl に記録する（Minus 3。turn 9 は 38 / 13,688 vs 合計 82 / 29,289）
- [ ] **research: RESEARCH §0.5 に「環境・ハーネス」小節を 1 つ設け、今回の ◇ 9 件に加えて非 Mojo の 5 件を転記する**: `pixi` は `/home/parallels/.pixi/bin/pixi` を絶対パスで（Bash ツールは `.bashrc` を読まない）／`/usr/bin/time` 無し → `date -Iseconds` で挟む／先頭の変数代入は不可で `env VAR=… cmd`／Python は fd 1 が閉じていると `sys.stdout` が `None`、`SystemExit` は明示 flush を飛ばす／`curl` `md5sum` は allowlist 外で `pixi run python` の `urllib` を使う（Interesting 7・8、turn 7 (3)、turn 11 (2)）
- [ ] **discuss（次マイルストーンの範囲を決めるとき）**: Phase 5 は仕上げなので、次に残っている候補は VERIFICATION §6.3 の残留リスク 5 件と REQ §3 のスコープ外 2 件だけ。聞くべきこと: (a) git remote を作って CI（D13 の継続条件が「remote ができたら」）、(b) Windows 実機（照合表 12 行 + `libpq.dll` 行 + 複製ビルドまで済み）、(c) Mojo examples の SIGPIPE rc 141 を `print` の失敗検知で rc 1 にするか（stdlib の挙動なので pq の対象外のまま README に書くか）、(d) `_collect_notifications` の `wait_readable` CONNECTION 経路の `out` 復元（実害なしと判定済み）。前回のように「Phase N+1 が引き取る」と書いたまま決定を持ち越さず、(a)〜(d) は採る / 採らないを discuss で確定する。採る前に research のプローブ 1 本で実在を確かめる（Interesting 1。D12 は存在しない問題に対する決定だった）
- [ ] **discuss: 「再現不能」を書くときは試した方式を列挙し、`close(PQsocket)` 方式（クライアント側 fd を閉じる）を切断系の再現方式に常設する**（Interesting 2。Phase 4 の持ち越し 1 件は方式の違いだった）
