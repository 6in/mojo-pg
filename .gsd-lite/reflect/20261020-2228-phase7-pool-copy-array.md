# 振り返り — phase7-pool-copy-array（2026-10-20 22:28）

- 種別: ループ（verify 合格後）
- 対象範囲: main...7d4cee7（コミット 27 件 = discuss 1 / research 1 / plan 1 / impl 20 / verify 4）/ ターン 1〜14
- 前回の振り返り: `20261018-1252-phase6-packaging-ci.md`（前々回 `20261018-0103-phase5-polish-bench-readme.md`）
- 成果: PR #2（https://github.com/6in/mojo-pg/pull/2）、CI 3 / 3 SUCCESS。`git diff --stat main...HEAD` は 42 ファイル +15,979 / −2,053 行
  （うち `.gsd-lite/` が約 6,500 行、コードは 27 ファイル +9,100 行 = VERIFICATION round 1）。マージ・タグは人間

## 計測（turns.jsonl から）

| フェーズ | ターン数 | 試行数 | 所要（分） | リトライ | 出力トークン | キャッシュ読み | コスト（USD） | エンジン / モデル |
|---|---|---|---|---|---|---|---|---|
| research | 1 | 1 | 28.7 | 0 | 140,435 | 5,444,503 | 16.39 | claude / claude-fable-5-1 |
| plan | 1 | 1 | 16.4 | 0 | 80,642 | 3,939,057 | 10.64 | claude / claude-fable-5-1 |
| impl | 10 | 10 | 395.7（うち turn 10 の停止 165.0） | 0 | 459,303 ※ | 107,655,532 | 115.57 | claude / claude-opus-5 |
| verify | 2 | 2 | 38.6 | 0 | 34,039 ※ | 4,637,048 | 21.12 | claude / claude-fable-5-1 |
| **合計** | **14** | **14** | **479.4（実働 314.4）** | **0** | **714,419 ※** | **121,676,140** | **163.72** | |

※ turns.jsonl は 1 試行に `result` が複数あるとき**最後の 1 件**しか記録しない（Phase 5 / 6 の提案、未反映）。生ログの全 `result` を合算すると
turn 9 = 100 turns / 62,931（記録 39 / 19,125）、turn 10 = 143 / 53,181（記録 19 / 9,436）、turn 12 = 93 / 48,278（記録 35 / 28,989）、
turn 14 = 93 / 30,774（記録 18 / 5,050）。合算なら impl 546,854 / verify 79,052 / 合計 846,983。`cost_usd` は累積値なので影響なし。

- impl の所要（分）: T1 15.2 / T2 21.7 / T3 17.8 / T4 21.4 / T5 17.6 / T6 35.7 / T7 42.3 / **T8 190.2** / T9 12.6 / F1 21.4。verify: round 1 14.7 / round 2 23.9（CI 待ち 12.5 分込み）
- `check` の所要（s、PROGRESS 各ターン）: 263 / 310 / 368 / 318 / 298 / 266 / 321 / **423** / 298 / 291 / 280 / 288（turn 3〜14）
- 権限拒否（permission_denials）: `Monitor` × 1（turn 11、`tail -f …/turn-011-check.log | grep …` の完了待ち。loop.log:259 に WARN）
- 計画タスク数 / impl ターン数: 9 / 10（T1〜T9 が各 1 ターン + F1。分割・追加タスク 0）
- verify 差し戻し: verify_round 1 回（指摘 3 件 → F1、同型 1 タスクにまとめ）/ BLOCKED: 0 回
- サブエージェント: impl 5 本（T4 1 / T6 1 / T7 1 / T8 2）+ verify round 1 で 2 本（レビュー / セキュリティ）。round 2 は 0 本
- 前回の提案の反映（Phase 6 の 8 件、PLAN.md:371-386 の表）: 守られた 6 件（6-2 `verify_round_max` 4 / 6-3 チェックリストのコメント除外 / 6-5 待ち合わせファイル名を書かない /
  6-6 `gh run view --json event,headSha,createdAt` を VERIFICATION に写す / 6-7 key 総数 77 を PLAN と TRACE で一致 / 6-8 discuss の (a)〜(f) を D1 / D19 / D20 で処理）。
  対象外 1 件（6-1 第三者アクションのソース。今回アクションを足していない）。**守られなかった 1 件（6-4 ツール側の複数 `result` 合算、上の ※）**。
  Phase 5 の 5-4「`Monitor` を deny」は PLAN が「Phase 6 で使用 0 回」を理由に見送り、turn 11 で拒否が再発した

## Plus（うまくいったこと）

- **計画 9 タスクが 9 ターンで 1:1 に完了し、リトライ 0・BLOCKED 0・無進捗 0**（根拠: turns.jsonl 全 14 行 attempt 1 / progressed true、git log の T1〜T9 各 2 コミット、PLAN Tasks）。Phase 6（9 impl ターン / 4 verify ラウンド）より verify が 2 ラウンド少ない
- **既存テストの期待値変更 0 件を T1〜T9 で維持し、F1 の 1 件だけを PROGRESS に列挙 → verify が `git diff` で照合できた**（根拠: PROGRESS turn 3〜11 の各「期待値変更 0 件」、turn 13「既存テストの期待値変更（1 件）」、VERIFICATION round 2「期待値の変更」行）。T1 の `test_ffi` は `assert_equal(len(names), 55)` を変えず別テストにした（turn 3 想定外 (2)）
- **陽性対照が毎タスク 1 件に絞れた**（T2〜T7、T7 は 3 件すべて）。turn 4 は PLAN の「両方向マップ 2 件」が循環で検査にならないことを対照で暴き、literal 固定の 1 件を足した（根拠: PROGRESS turn 4〜9 の陽性対照欄）。F1 は修正前に 5 件を走らせて 4 件赤を見てから直した（turn 13）
- **サブエージェント 7 本すべてで「契約外の提案は未実装のまま報告」が守られ、親の統合修正は各 0〜1 箇所**。T7 のテスト担当 B が親の実装バグ 1 件（`for ref slot in self._idle` がコンパイル不可）を見つけた（根拠: PROGRESS turn 6 / 8 / 9 / 10 のサブエージェント欄）
- **T8 は README が examples を逐語で写す直列依存を、親が抜粋 34 行を先に確定して両方の依頼文に書くことで並列化し、照合器が 1 回目から 9 ブロック missing 0**（根拠: PROGRESS turn 10 想定外 (1)、turn-010-attempt1.log）
- **research の提案 11 件・盗める設計 12 件・落とし穴 P1〜P29 のすべてに PLAN が採否と完了基準の対応を表で書いた**（根拠: PLAN.md:388-424）。impl の PLAN 訂正は 10 件あったが、すべて TRACE「PLAN 訂正（turn N）」に根拠つきで残り、verify がそこから指摘 2 を拾った（Interesting 参照）
- **verify round 1 が同型 3 件を 1 つの F1 にまとめ、round 2 を「F1 回帰 + check + 格子」だけに絞ると宣言して 1 ラウンドで合格**（根拠: VERIFICATION round 1「round 1 で拾えた理由」「合格だった事項」、round 2「新しいクラスの探索はしていない」）。PR 作成 → `gh pr checks --watch` → `gh run view --json` の写しまで round 2 の 24 分に収まった
- **堅牢性格子 126 セル（T1 で 90、T9 で 126）が T9 / round 1 / round 2 で rc 分布まで完全一致**（根拠: PROGRESS turn 3 / 11 / 12 / 14、VERIFICATION 両 round）。Phase 5 提案 2 の「3 軸常設」が 3 回目で安定

## Minus（問題・無駄・やり直し）

- **turn 10（T8）が 190 分かかり、うち 165 分はネットワーク障害による停止だった**（根拠: turns.jsonl turn 10 `duration_s` 11411 に対し他の impl は 754〜2,535；生ログ `turn-010-attempt1.jsonl` に 09:23:05Z → 12:08:02Z の **9,897 s の空白**があり、直後の assistant 出力が `API Error: Can't reach the API server — check your internet or DNS (EAI_AGAIN)`（`turn-010-attempt1.log:13`）；`rate_limit.five_hour` が 0.31 → 0.01 で窓が更新）。
  作業自体は 21 分（09:02〜09:23）+ 4 分（12:08〜12:12）で済んでいる。ループは rc 0 / progressed true で記録し WARN を出さず、**PROGRESS turn 10 は停止に一言も触れていない**（やり直し 0 回、想定外 4 件は別件）。
  原因の見立て（推測:）CLI が DNS 障害中に再試行を続け、ループ側に 1 試行の壁時計上限も「record 間隔が N 分を超えたら警告」も無い
- **ツール側提案「複数 `result` の合算」が 5 回目も未反映で、計測表の出力トークンが impl −87,551 / verify −45,013 過小**（根拠: PLAN.md:376「ユーザー側。未反映のまま」、上の ※ の数値。turn 10 は 16 `result` で記録が 19 / 9,436）。停止したターンほど記録が小さく見える
- **`Monitor` の拒否 1 件（turn 11）**。Phase 5-4 の「deny に入れる」を PLAN が「Phase 6 で使用 0 回」を理由に見送った結果（根拠: turns.jsonl turn 11 `permission_denials`、loop.log:259、PLAN.md:383）。実害は 1 呼び出しで、agent は前景待ちに切り替えたが、settings の提案を plan が採否判断する形になっている
- **verify round 1 の 3 件（F1）が impl で見つからなかった**: T6 が `_check_not_copying` を 7 箇所に入れたとき、`Transaction.commit / rollback` の `_done = True` の順序、`CopyIn / CopyOut.__deinit__` の二重中止、`write` 失敗後の出口が PLAN の完了基準に無かった。T6 ⑭ のテストは誤報を `>= 1` で固定し、T8 の PLAN 訂正 ② は「handler を呼ぶのは `CopyIn.__deinit__`」と観測を事実として記録した
  （根拠: VERIFICATION round 1 指摘 1〜3、PROGRESS turn 8 PLAN 訂正 ②、turn 12 想定外 (1)(2)）。コスト: F1 21.4 分 / USD 7.52 + verify round 1 の差し戻し分。
  原因の見立て: ガードを N 箇所に足す変更は「ガード × 既存の状態遷移（commit / rollback / deinit / 失敗後の次コマンド）」の格子が要るのに、PLAN は「7 箇所」という箇所数だけを完了基準にした。推測: 観測に合わせて期待値を書き換えるときに「設計どおりか」を問う手順が無い
- **`check` の所要の揺れ（263〜423 s、同じ木で ±125 s）に毎ターン PROGRESS の 2〜4 行が割かれ、閾値が 2 つ並立した**（turn 3 で per-turn 300 → 380 に訂正、T9 (b) は 300 のまま、turn 10 が「2 連続超過」を報告、turn 11 がクリーン 298 s で据え置き。根拠: PROGRESS turn 3 / 5 / 6 / 10 / 11 / 13）。
  原因の見立て: 1 サーバー目のコンパイル時間がキャッシュ状態で 91〜290 s 動く（turn 10 の内訳、turn 11 想定外 (1)）。1 回の測定で判定する閾値と揺れの大きさが合っていない
- **turn 10 冒頭で `--where` を存在しないパス（`.claude/skills/gsd-lite-impl/gsd-lite-loop.sh`）で呼び、続く `find / -name gsd-lite-loop.sh` が 120 s タイムアウト → `pkill`**（根拠: `turn-010-attempt1.jsonl` 最初の Bash 5 件、gap 120 s）。他のターンはリポジトリ直下の `gsd-lite-loop.sh` を使えている。スキル本文の「`gsd-lite-loop.sh --where` を実行」がパスを書いていない
- **turn 11 の TRACE 追記が `python3 -c "..."` にバックティックを混ぜて本文が空に化け、1 回書き直し**（根拠: PROGRESS turn 11 想定外 (2)、やり直し 1 回）。Phase 5 提案 7 の環境節に「長い本文は Write で」が無い
- **turn 8 でサブエージェントが `test_copy.mojo` を書いている最中に親が `check` を回し、1 件欠けた版で計測**（根拠: PROGRESS turn 8 想定外 (4)）。Phase 6-5「待ち合わせファイル名を書かない」を守っても起きる別の競合（親が完了通知を待たずに検証を始めた）

## Interesting（気づき・意外だったこと）

- **turn 10 は 2 時間 45 分の停止後、「Those are my stale wait timers draining」と言って残作業を 4 分で終え、コミットも正常だった**（根拠: gap 出力 12:08〜12:12、git log `3caaec0` 21:10:33）。記録 3 系統（turns.jsonl / 生ログ / PROGRESS）のうち**生ログの timestamp だけが真相を持っていた**。turns.jsonl は `duration_s` で異常を示しつつ `num_turns` 19 で「軽いターン」に見える
- **impl が観測を正しく記録していたから verify が拾えた**: T8 の PLAN 訂正 ②（`PQexec("ROLLBACK")` は COPY 中でも成功するので handler に到達するのは `CopyIn.__deinit__`）は誤報そのものの観測記録で、verify はこれを読んで指摘 2 を立てた（根拠: PROGRESS turn 12 想定外 (1)「TRACE の記録が効いた例」）。記録の精度が指摘の精度になった一方、impl 自身は「設計どおりか」を問わなかった（Minus 4）
- **単位の読み違い**: `TestSuite` の `Summary [ N ]` はミリ秒で、turn 4 / 5 の PROGRESS が「0.065 s」「0.126 s」と秒として書き、turn 7 が `turn-007-time.sh` で実測して訂正（根拠: PROGRESS turn 7 想定外 (3)）。turn 8 は「サブエージェントの報告も同じ誤読の可能性」を注意に書いた
- **同じコード量で `check` が 423 s（turn 10）と 298 s（turn 11）**: turn 11 は堅牢性格子が先に 7 本をビルドしてキャッシュを温めていた（根拠: PROGRESS turn 11 想定外 (1)）。「クリーン」と「暖機後」は別の母数で、PLAN の閾値はどちらを指すか決めていなかった
- **F1 (d) ④ は修正前から green（陽性対照にならなかった）、`finish` / `abort` の `rc < 0` の drain はどのテストも踏めない**（根拠: PROGRESS turn 13 想定外、VERIFICATION round 2 残留リスク）。verify の「同型 3 件」のうちテストで固定できたのは 2 経路で、残り 1 経路は記録のみ
- **前回提案の適用そのものに 1 やり直し**: Phase 6-3（チェックリストのコメント除外）を適用したら README の見出し `#` も落ちて `readme_h2=0` になり、plan が `.md` を除外しない分岐を足した（根拠: PROGRESS turn 2 想定外 (1)、やり直し 1 回）
- **Mojo 1.1.0 の言語制約の新規発見が impl 中に 10 件超**（`E: Copyable & Deinitable`、`List[Optional[Int32]]` の literal、`ref` 束縛、`deinit self` 消費、モジュール `var` 不可、`try` 内の `raise Error`、`len(String)`、`Parameters:` docstring 必須 等）で、やり直しは全部コンパイル段階、**テストの赤は T1〜T9 で 0 回**（根拠: PROGRESS turn 4〜9 のやり直し欄）。RESEARCH §0.5 の転記は効いているが、毎ターン新規が出る
- **サブエージェントの併用は T6（35.7 分 / USD 23.04）と T7（42.3 分）で impl の最長 2 ターン**になった。T4（1 本、21.4 分）と T8（2 本、実働 25 分）は平均的で、長さは並列化よりタスク本体（COPY / Pool の新規モジュール）由来と読める（根拠: turns.jsonl の duration / cost、PROGRESS 各欄）
- **コスト比**: Phase 6 は USD 86.65 / 178.5 分 / 15 ターン、今回は USD 163.72 / 479 分（実働 314 分）/ 14 ターンで、コード diff は +9,100 行（Phase 6 は +4,911 行の大半が `.gsd-lite`）。1 ターンあたりは impl USD 11.6、verify USD 10.6
- **`Read` ツールの dedup スタブ**が turn 12 で未読の `copy.mojo` / `pool.mojo` に出て `cat -n` で代替、turn 14 は `Read(offset=)` で回避（根拠: PROGRESS turn 12 想定外 (3)、turn 14 注意 (3)）。ハーネス側の挙動で、回避法が 2 つ記録された

## 次回への提案（実行可能な形で）

- [ ] **ツール側（マイルストーン間にユーザーが行う）: `gsd-lite-loop.sh` に停止検知を足す**。生ログの連続する record の `timestamp` 差が 15 分を超えたら `WARN turn N stalled Ns` を loop.log に出し、turns.jsonl に `stall_s`（最大間隔）を記録する。あわせて 1 試行の壁時計上限（impl 90 分 / verify 60 分など）を超えたら attempt を打ち切って再試行する（Minus 1 / Interesting 1。turn 10 の 165 分）
- [ ] **ツール側（5 回目）: 1 試行の生ログに `result` が複数あるとき `num_turns` / `usage` 各項目は全 `result` の合計、`permission_denials` は全件の和、`cost_usd` は最後の値**（Minus 2。turn 10 は 16 `result` で 143 / 53,181 が 19 / 9,436 に記録）
- [ ] **settings: `Monitor` を `.claude/settings.json` の deny に入れる**（Phase 5-4 の再掲、turn 11 で拒否 1 件）。あわせて gsd-lite-plan の「前回提案の反映」表の規則に「settings / ツール側の提案は plan が採否を決めず『ユーザー側』と書くだけ」を足す（Minus 3。PLAN.md:383 が「使用 0 回」を理由に見送った）
- [ ] **plan: 既存の経路に検査（ガード）を N 箇所足すタスクには、「ガード × 既存の状態遷移」の格子を完了基準の表にする**。列は commit / rollback / `__deinit__` / 失敗後の次コマンド / `reset()`、各セルに期待結果（送るもの・raise・handler 回数）を書き、テストは格子の行ごとに 1 件（Minus 4。T6 の `_check_not_copying` 7 箇所 → 差し戻し 3 件 = F1 21 分 / USD 7.52）
- [ ] **impl: 観測に合わせて期待値や PLAN を訂正するとき、PROGRESS の PLAN 訂正欄に「設計どおり / 観測のみ」の 1 語を付け、「観測のみ」は TRACE の verify 申し送りに列挙する**。verify はその列挙を最初に読み、各項目に「設計として正しいか」を 1 行で判定する（Minus 4 / Interesting 2。T8 訂正 ② の型）
- [ ] **plan: `check` の閾値は「`db-reset` 直後のクリーン状態で 1 回、堅牢性格子を回す前」だけに定義し、各ターンの所要は TRACE に 1 行記録するだけで閾値判定しない**。5/6 段は 1 サーバー目と 2 サーバー目を分けて記録する（Minus 5 / Interesting 4。閾値 2 つ並立と毎ターンの 2〜4 行）
- [ ] **スキル: 全 gsd-lite スキル冒頭の「`gsd-lite-loop.sh --where`」を「`bash ./gsd-lite-loop.sh --where`（リポジトリ直下。`find` で探さない）」に書き換える**。あわせて impl / verify の無人シェルの作法に「長い本文は Write でファイルに書いてから `cat >>` / `python3 <file>` で連結する（`python3 -c` に本文を埋めない）」を足す（Minus 6・7。120 s + `pkill`、TRACE 書き直し 1 回）
- [ ] **impl: サブエージェント併用ターンで親が `check` を回すのは、サブの完了通知を受け取ってからだけ**。並行中に測るなら親が書いた単体テストファイルの `mojo run` に限る。gsd-lite-impl のサブエージェント雛形に 1 行足す（Minus 8）
- [ ] **research: RESEARCH §0.5 の環境節に「`TestSuite` の `Summary [ N ]` はミリ秒、所要は `final_check.log` の `took Ns` で読む」を 1 行足す**（Interesting 3。turn 4 / 5 の誤読 + サブエージェント報告の注意）
- [ ] **discuss（次マイルストーンの前に人間が決めること、記録から）**: (a) PR #2 のマージとタグ（verify は人間に委ねた）。(b) 残留リスク 4 件を採るか: 2 GiB 超の 1 回 `write` / `encode_array` の `Int32` 長（1 行で `USAGE`）、`parse_array_literal` の引用なし末尾 `\ ` の trim、`finish` / `abort` の `rc < 0` drain の未踏経路、`check` 所要の揺れ。
  (c) REQ から外した `CopyOut` の `Iterator`（決めた事項 7、Mojo の `raises StopIteration` 制約）と D9 で却下した `AsyncConnection` の COPY を次に採るか。(d) D19 の `.gsd-lite/` 追跡で PR の約 6,500 行が成果物 — 継続か squash か（Phase 6 (e) と同じ問い、今回は D19 で「継続」）。
  (e) Phase 7 で見つかった Mojo 1.1.0 の制約 10 件超を RESEARCH §0.5 に転記するのは research の仕事のままでよいか、スキル側に常設の「言語制約」ファイルを持つか
