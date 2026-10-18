# 振り返り — phase6-packaging-ci（2026-10-18 12:52）

- 種別: ループ（verify round 4 合格後。verify_round 3 = 上限ちょうど、fix_round 1）
- 対象範囲: `main...44b1c17`（ブランチのコミット 24 件 = discuss 1 + research 1 + plan 1 + impl 17（T1〜T5 各 2・T6 1・F1〜F3 各 2）+ verify 4）/ ターン 1〜15（reflect = 16）。
  PR #1（https://github.com/6in/mojo-pg/pull/1）は OPEN・MERGEABLE、マージは人間（ローカルマージなし）
- 前回の振り返り: `20261018-0103-phase5-polish-bench-readme.md`
- 差分: 32 ファイル +4,911 / −1,796（`.gsd-lite/` と archive 移動込み）。コード側はコミット 8 本・17 ファイル約 +1,000 行（`.github/` 7 本 545 行、`README.md` +194、`src/pq/async_conn.mojo` +98、tests 4 本 +116、`pixi.toml` 39、`CHANGELOG.md` 21、`.claude/settings.json` +13 は discuss コミット `454f851`）
- 壁時計: turn 1 開始 09:51:46 JST → turn 15 終了 12:50:32 JST = **178.8 分**。turns.jsonl の所要合計 178.5 分と一致（ターン間の空白なし）

## 計測（turns.jsonl から）

| フェーズ | ターン数 | 試行数 | 所要（分） | リトライ | 出力トークン | キャッシュ読み | コスト（USD） | エンジン / モデル |
|---|---|---|---|---|---|---|---|---|
| research | 1 | 1 | 20.9 | 0 | 92,244 | 4,996,637 | 10.92 | claude / claude-fable-5-1 |
| plan | 1 | 1 | 12.7 | 0 | 62,372 | 2,447,215 | 7.54 | claude / claude-fable-5-1 |
| impl | 9 | 9 | 90.6 | 0 | 172,549 ※ | 43,657,987 | 41.51 | claude / claude-opus-5 |
| verify | 4 | 4 | 54.2 | 0 | 155,448 ※ | 12,115,843 | 26.68 | claude / claude-fable-5-1 |
| **合計** | **15** | **15** | **178.5** | **0** | **482,613 ※** | **63,217,682** | **86.65** | |

※ 生ログ（`turn-NNN-attempt1.jsonl`）に `result` イベントが turn 5 / 10 / 11 / 13 に 2 件、turn 15 に 3 件あり、turns.jsonl は**最後の 1 件**だけを記録している。
欠けた出力トークンは 13,928 + 19,563 + 4,357 + 8,942 + (8,222 + 2,641) = **57,653**（約 11 %。補正後 ≈ 540,266）。turn 10 は記録 `num_turns` 2 / 出力 282 に対し実際は 74 / 19,845。
`cost_usd` は累積値なので正しい。Phase 3〜5 と同じ記録の欠け（4 マイルストーン連続。Minus 3）

impl のターン別 所要（秒）/ コスト（USD）/ サブエージェント実本数（生ログ `subagent_stats.spawned`）/ PLAN の推奨本数:
T1 1,061 / 4.71 / 0 / 0、T2 485 / 3.72 / 0 / 0、T3 512 / 6.84 / 1 / 1、T4 527 / 4.72 / 1 / 1、T5 486 / 3.77 / 0 / 0、T6 472 / 4.15 / 0 / 0、
F1 547 / 4.69 / 0 / 0、F2 617 / 4.23 / 0 / 0、F3 730 / 4.69 / 0 / 0。**推奨と実本数は 9 ターンすべて一致**（Phase 5 と同じ）。impl 1 ターン平均 USD 4.61（Phase 5 5.81）。
verify round 1 709 / 7.09、round 2 785 / 6.40、round 3 1,053 / 8.75、round 4 707 / 4.44。

- 差し戻しサイクルの所要: F1 + round 2 = 1,332 s / USD 11.09、F2 + round 3 = 1,670 s / 13.0、F3 + round 4 = 1,437 s / 9.13。**合計 74.0 分（壁時計の 41 %）/ USD 33.2（38 %）**
- 権限拒否（permission_denials）: turns.jsonl は 15 行とも `[]`、loop.log にも本マイルストーンの WARN なし。**ただし生ログ turn 5 の 1 件目の `result` に Bash 拒否 1 件**（`nohup python3 …/blackhole.py 54398 > … 2>&1 &` = バックグラウンド起動。`nohup` は allowlist 外）。turns.jsonl が最後の `result` だけを写すため落ちた（Minus 3）
- 無進捗の試行: 0。`attempt > 1` の行: 0（`turn-NNN-attempt2.log` も無い）
- 利用枠（rate_limit）: five_hour 0.08 → 0.33、seven_day 0.41 → 0.45。`resets_at` は 15 ターンとも 1792300800 でマイルストーン中のリセットなし。loop.log では `CLAUDE_TOKEN_ORG_A` / `ORG_B` の 2 トークンが交互に使われており、連続ターンの使用率は別口座の値（Interesting 7）
- 計画タスク数 / impl ターン数: **6 / 9**（T1〜T6 が 6 ターンちょうど + F1 / F2 / F3）
- verify 差し戻し: **3 回**（round 1 = F1 setup-pixi の入力 1 件、round 2 = F2 macOS poll セマンティクス 1 件、round 3 = F3 libpq 初回 poll 契約 + RSS の段 2 件、round 4 = 指摘 0）。verify_round_max 3 を**ちょうど使い切って合格**。BLOCKED: 0 回（`git log --all -- .gsd-lite/BLOCKED.md` 空）
- やり直し（PROGRESS の欄の合計）: **9 回**（turn 1 ×4 = research プローブの Mojo 1.1.0 字句と `write` 署名、turn 3 ×1 = 引数名 `out`、turn 5 ×1 / turn 6 ×2 / turn 10 ×1 = コメント文がチェックリスト key の grep に当たった同型 3 回 + `pixi` PATH ラッパ 1 回）。Phase 5 は 2 回
- PLAN 訂正: **4 件**（TRACE「PLAN 訂正」節 turn 3 ×1 / turn 4 ×1 / turn 10 ×2）。Phase 5 は 9 件。turn 10 の 2 件は F1 由来で plan 時点では知り得ない。turn 4 の `pixi_pkg_name_pq` 1 → 2 は RESEARCH §2.1 の manifest に `name = "pq"` が 2 行あるので plan で打てば分かった（Minus 6）
- PROGRESS の 1 ターン節の行数: 15 節すべて **10〜16 行**（上限 40。Phase 5 は 5 ターン超過・最大 64 行）
- 既存テストの期待値変更: **1 件**（`test_manual_connect_polling`、F3。PLAN F3 (b) が予告し PROGRESS turn 14 が列挙、VERIFICATION §R4.2 #3 が diff で照合）
- CI の run（PR #1、`gh run list --json`）: 6 本 + 進行中 1 本。`9488a0c` 赤 21 s（round 1）/ `ce34301` 赤 20 s（verify round 1 の自分の state コミット push が起動。Minus 5）/ `2c89fb9` 赤（macOS 2 件）/ `f4bb693` 赤（x86_64 1 件 + macOS 1 件）/ `b0b4ea6` **緑**（round 4）/ `44b1c17` 進行中（turn 15 の state コミット push が起動。本 reflect の push が `concurrency` で cancel する）
- Phase 5 との比較: 14 ターン / 193.7 分 / USD 91.36 → **15 ターン / 178.5 分 / USD 86.65**（差し戻し 2 → 3 回なのにコスト −5 %、所要 −8 %）。差し戻しサイクルを除くと 104.5 分 / USD 53.4
- 前回の提案の反映（PLAN「メモ」の反映表 + REQ §6 + 記録で照合、10 件）:
  - 守られた（6 件）: 1 VERIFICATION 指摘表の「grep パターン / 件数 / ファイル」3 列（§1 / §0.1 / §R3.1 の表すべて）／3 TRACE「チェックリスト（turn N）」節 + PROGRESS 40 行（全 15 節 ≤ 16 行、PLAN 検証コマンド節に python3 ワンライナー）／5 期待値の `≥`（PLAN 表。訂正 9 → 4 件）／8 RESEARCH §0.5「環境・ハーネス」（5 件転記 + 今回の追加 6 件）／9 discuss で (a)〜(d) を確定（D2 / D3 / D4 / D5、REQ §2.3）／10 切断の再現方式を列挙（RESEARCH §2.14 は close / shutdown / dup2 を試して「到達不能」と書いた）
  - 部分的に守られた（2 件）: 2 堅牢性格子 3 軸 → PLAN メモで**不採用を明記**（examples のコードを変えないため。verify §5 は scクリプト 5 本の argv 格子で代替）／4 Monitor の deny → `.claude/settings.json` の deny は `mcp__lean-ctx` のみで**未反映**。ただし Monitor の使用は 0 回（生ログ grep 0）で、待ちは `gh run watch` / `gh pr checks --watch` と `run_in_background` Bash に移った（Interesting 6）
  - 守られなかった（2 件）: 6 F 項目の見込み行数を `+/-` 単位で（PLAN F1〜F3 に行数の見込み無し。影響なし）／7 ツール側（`usage` / `num_turns` / `permission_denials` は依然「最後の `result`」。`subagents` キー無し。4 マイルストーン連続。Minus 3）

## Plus（うまくいったこと）

- **15 ターン、リトライ 0・無進捗 0・BLOCKED 0 で完走し、6 タスクが 6 ターンちょうど、差し戻し 3 件もそれぞれ impl 1 ターンで閉じた**（根拠: turns.jsonl 全行 `attempt: 1` / `progressed: true`、コミット列 T1〜T5 / F1〜F3 が「コード 1 本 + 申し送り 1 本」の 2 コミット、PROGRESS turn 12 / 14 のやり直し 0 回）
- **research が REQ §6 の実測 4 件を全部プローブで確定し、T2（`[package]` + `pixi build` + 利用側 2 経路）がやり直し 0 回・485 s で終わった**（根拠: RESEARCH §0 表、turn 4「やり直し: 0 回」、`scratch/turn-001-pkg-*` 3 本 / `turn-001-consumer-*` 4 経路）。`pixi.lock` 不変（P3）は 15 ターン通して `pixi_lock_changed_vs_main=0`、macOS の「PG 未搭載 + trust 認証」（RESEARCH §2.8）は `macos-postgres.sh` が CI 初回実行（round 2）で 12 s・陽性対照 2 つとも OK（VERIFICATION §0.4）
- **CI の設計判断が verify の診断を支えた**: `fail-fast: false` で 1 OS の赤が他 2 OS の artifact を消さず、`if: always()` の `final-check-log-<os>` artifact と `gh api …/jobs/<id>/logs` で run 完了前に macOS の失敗テストを特定できた（根拠: turn 11 想定外 (2)、VERIFICATION §R3.4「`fail-fast: false` が効いて」）。`concurrency` cancel も意図どおり（§R4.4）
- **verify の 3 round の原因特定が毎回 1 ターンで決着し、同じ指摘が 2 度出なかった**（根拠: round 1 は setup-pixi `options.ts:207-217` を `gh api` で読んで `cache` と `locked` の**両方**の拒否を 1 回で押さえ（VERIFICATION §1「`cache` だけ直すと次の run はそこで落ちる」）、round 2 は POSIX poll の `POLLHUP` / `POLLOUT` 排他、round 3 は libpq 公式 docs の `PGRES_POLLING_WRITING` 契約 + `test_leak.mojo:148-170` 自身の記述。F2 / F3 の回帰 grep は round 3 / 4 で全部不変）
- **F3 の陽性対照を「新テストを先に書いて旧コードで赤を見る」で取り、macOS 固有の症状を Linux の開発機で観測可能にした**（根拠: turn 14「新テストを先に足して旧コードで走らせ `FAIL … Connection refused` を観測 → 実装後 32 PASS」、PLAN F3 (b)「Linux で観測できる陽性対照」）。締めた既存 assert は Linux では元から PASS で判別しないことも明記した（turn 14 想定外）
- **PROGRESS 40 行の上限を全 15 ターンが守り、PLAN 訂正は 9 → 4 件、チェックリストの生値は TRACE に移った**（根拠: 節の行数 10〜16、TRACE「チェックリスト（turn N）」節 turn 3〜15、PLAN 表の `≥`）。Phase 5 提案 3 / 5 がそのまま効いた
- **コストは Phase 5 比 −5 %、impl 1 ターン USD 4.61（Phase 5 5.81、Phase 4 9.01）**（根拠: 計測表）。差し戻し 3 回・ターン数 +1 でも下がったのは、F1〜F3 の impl が 547〜730 s / USD 4.2〜4.7 と小さく、T2 / T5 / T6 が 472〜486 s で終わったため
- **既存テストの期待値変更が計画どおりの 1 件だけで、PLAN → PROGRESS → VERIFICATION の 3 箇所で同じ 1 件が照合された**（根拠: PLAN F3 (b)、turn 14、VERIFICATION §R4.2 #3）

## Minus（問題・無駄・やり直し）

- **差し戻し 3 round がすべて開発機（linux-aarch64）で観測できない CI 固有の赤で、74.0 分 / USD 33.2（壁時計 41 % / コスト 38 %）を使い、verify_round 上限をちょうど使い切った**（根拠: turns.jsonl turn 10〜15、VERIFICATION §R4.7、state `verify_round: 3` / `verify_round_max: 3`）。うち **F1 は research で防げた**: RESEARCH P12 が「`run-install: false` とキャッシュ保存の相性は**未検証**」と書いたまま plan が `cache: true` + `locked: true` を決めた事項 5 に写し、verify round 1 が `gh api repos/prefix-dev/setup-pixi/contents/src/options.ts?ref=v0.11.2` を読んで数分で確定した（VERIFICATION §1）。同じ読みを research がしていれば round 1 + F1 = 1,256 s / USD 11.8 が不要だった。原因の見立て: 「未検証」を「CI で初めて分かる」と扱い、アクションのソースを静的に読む経路を研究の完了基準にしていなかった。F2 / F3① は OS 差で、推測: Phase 4 が Linux だけで実測した poll / `poll_connect` を POSIX / libpq の文書上の契約と突き合わせるレビューが無かった（F3① は libpq docs に明記された契約の違反で、Linux がそれを隠していた）。F3② は非決定的で防げない
- **同型のやり直しを 3 ターンで繰り返した: コメント・見出しの文がチェックリスト key の grep パターンに当たって件数が +1 になる**（根拠: turn 5 想定外 (2) `run-install: false` / `locked: true`、turn 6 想定外 (2) `v*` / `contents: write`、turn 10 やり直し `retry.sh`。turn 7 は「書く前に避けた」で 0 回）。各 1 回の再実行で軽いが、turn 6 の「次への注意」に書いても turn 10 で再発した。原因の見立て: チェックリスト `turn-002-checklist.sh` の key が YAML / sh のコメント行を除かずファイル全体を `grep -c` しており、`cache: false` のような説明に自然に出る語が key になっている
- **ツール側の記録が 5 ターンで実際より小さく、権限拒否 1 件が記録から消えた（4 マイルストーン連続・未反映）**（根拠: 計測表の ※、生ログ turn 5 の 1 件目 `result` に Bash 拒否 `nohup … &`、turns.jsonl `permission_denials: []`、loop.log に本マイルストーンの WARN なし。turn 10 は 2 / 282 vs 74 / 19,845）。拒否された `nohup` バックグラウンド起動は PROGRESS turn 5 にも書かれていない（サブエージェントに回したと推測）。`result` が複数になるターンは `run_in_background` Bash の回数と対応する（turn 5 ×5 / 10 ×1 / 11 ×2 / 13 ×2 / 15 ×2、turn 14 は 0 で `result` 1 件）
- **サブエージェントが親の待ち合わせファイルを上書きし、解除条件を自分で満たした**（根拠: turn 5 想定外 (1)「`scratch/turn-005-check.log` に自分の報告を書き、末尾に `final_check: PASS` を書き足した」）。親は `check` の合否を `build/final_check.log` の 6 段 + タスク rc から取り直した（判定は正しい）。Phase 5 の Monitor 不具合 3 種の次に出た、待ち方の新しい失敗。原因の見立て: 依頼文に親のログファイル名と解除条件を渡した
- **記録の中の推定が 3 件誤っていた**（根拠と事実: (1) turn 10 想定外 (1) / VERIFICATION §0.4「run `39090682281` は人間の re-run と推定」→ `gh run view --json` は `event: pull_request` / `headSha: ce34301` / 02:36:14Z = verify round 1 の state コミット（11:36:03 JST）push が起動した通常の run。(2) turn 4〜7 の PROGRESS「54314 の skipped 1 = PG14 側の leak」→ turn 8 が実測で `test_interval_infinity_*` の対称 1 件と訂正。(3) turn 12「push は未実施」→ turn 13 開始時に HEAD = origin（turn 13 想定外 (3)「ループ側が push した模様」、推測のまま））。原因の見立て: `gh run view <id> --json event,headSha` 1 コマンドで確定できる事実を推定で書いた。state コミットの push ごとに 3 OS の run が起動する事実（6 run 中 2 本が verify の state コミット由来、いま `44b1c17` の run も進行中）が記録に明示されていない
- **PLAN 訂正 4 件のうち 1 件は plan で打てば分かった**（根拠: TRACE「PLAN 訂正（turn 4）」`pixi_pkg_name_pq` 1 → 2、RESEARCH §2.1 の manifest に `name = "pq"` が `[package]` と `[package.build.config.pkg]` の 2 行）。Phase 5 reflect Interesting 5「現在値を打てば判明する型は 0 件」が今回 1 件に戻った
- **チェックリストの key 総数が記録の中で一致しない**（根拠: plan コミット `ec18cae` と PROGRESS turn 2「106 key」、turn 8 以降「全 101 key」。差の説明が TRACE / PROGRESS に無い）。判定への影響はないが、reflect が「全行期待値」の母数を確認できない
- **F 項目の見込み行数（Phase 5 提案 6）は書かれなかった**（根拠: PLAN F1〜F3 に行数の見込み無し）。3 件とも 1 ターンで収まったので影響なし

## Interesting（気づき・意外だったこと）

- **開発機と CI の差は 3 round とも別の層で出た**: アクションの入力検証（F1）/ カーネルの poll セマンティクス（F2）/ libpq の状態機械のタイミング + ランナーの RSS の段（F3）（根拠: VERIFICATION §1 / §0.1 / §R3.1）。REQ §6「CI 固有の失敗は verify の差し戻しで直す」はこれを予見していたが、`verify_round_max: 3` は余裕ゼロで、F3② の段が round 4 で再現していれば BLOCKED だった。「成果物が 3 OS の CI」のマイルストーンでは round 上限が設計上の制約になる
- **他 OS の CI がライブラリの正しさのレビューとして働いた**: F3① は Phase 4 から存在した libpq 契約違反（`PQconnectStart` 直後に `PQconnectPoll` を呼ぶ）で、Linux は `connect()` 内で RST を処理し終えるため常に隠れ、macOS では 2 回に 1 回だけ露見した（round 2 PASS 7.3 ms / round 3 FAIL 1.55 ms。VERIFICATION §R3.1）。F2 も汎用メッセージ `connection socket closed (POLLHUP/POLLERR)` を src から消し、切断理由を常に libpq の文言にする改善になった。ワークフロー整備のマイルストーンで `async_conn.mojo` が +98 行変わったのはこのため
- **verify round 1 は PR 作成とローカル `check` を並行させ、CI の赤を待ち時間ゼロで得た**（根拠: turn 9 想定外 (2)「CI は 10 s で落ちたので待ち時間ゼロ」）。round 3 が最長（1,053 s）なのは 2 OS × 2 件の赤を artifact 3 本から特定し、設計の選択肢 A / B / C を 2 件分書いたため（§R3.1）
- **macOS ジョブは 3m46s で Linux（8 分前後）の半分以下、キャッシュ無し（F1 の代償 +1〜3 分見込み）は install 3 s・brew PG 12 s で無視できた**（根拠: VERIFICATION §0.4 / §R4.4）。Linux の `check` は 440〜469 s でローカル 170 s の 2.6 倍（docker pull + 2 サーバー）。見積もり「macOS は brew +2〜4 分」は過大
- **ローカル `check` は 12 回の実測で 169〜190 s、閾値 247 s に一度も近づかず、見積もり 170〜220 s が 2 マイルストーン連続で当たった**（根拠: PROGRESS turn 3〜15 の `check` 所要、PLAN 検証コマンド節）。揺れ幅 21 s は Phase 5 の 46 s より小さい
- **Phase 5 提案 4（Monitor を deny）は設定されなかったが Monitor の使用は 0 回で、待ちは `gh run watch` / `gh pr checks --watch` と `run_in_background` Bash に移った**（根拠: 生ログ `"name":"Monitor"` 0 件、`run_in_background` 計 14 回、settings.json の deny は `mcp__lean-ctx` のみ）。待ちは安定した（誤報 0）が、その完了通知が `result` を複数にして Minus 3 の記録欠けを広げた
- **ループは 2 つのトークンを交互に使っている**（根拠: loop.log `(token: CLAUDE_TOKEN_ORG_A)` / `ORG_B` が turn ごとに交替）。turns.jsonl の `rate_limit` は口座ごとの値なので、連続ターンの `five_hour` 0.08 → 0.33 は 1 本の推移ではない。Phase 5 reflect の「リセットなし」の読みも同じ注意が要る
- **`pixi build` の 2 つの挙動を impl が初めて踏んだ**: deprecated 警告（turn 4。`pixi publish` を使えと）と、同じビルド ID の `.conda` が残っていると再ビルドせず `Skipping` で rc 0（turn 8）。research は `pixi build` を 3 回回したが毎回新規ディレクトリだったので後者を見なかった。T6 / verify は「`dist/*.conda` を消してから」を手順にした
- **research の `pixi.lock` の誤判定（縮小 manifest で「lock が古い」）は同ターンで原因を突き止め、PLAN の「変わったら feature を疑う」注意になった**（根拠: turn 1 想定外 (1)、PLAN impl への注意）。結果 15 ターン通して lock は不変で、注意が発動する場面はなかった。害のない保険
- **サブエージェントを使った 2 ターン（T3 / T4）のうち T3 は impl 最高額（USD 6.84）**、T4 は 4.72（根拠: turns.jsonl）。T3 は YAML 1 + スクリプト 3 + 陽性対照 3 で差分最大なので本数の効果とは言えないが、「1 本でも親の待ち合わせの失敗（Minus 4）が 1 回」は本数に比例しないコスト

## 次回への提案（実行可能な形で）

- [ ] **research: 採用する第三者アクションごとに、入力の検証コード（`gh api repos/<o>/<r>/contents/src/options.ts?ref=<tag>` または `action.yml`）を読み、「使う入力の組み合わせが拒否されない」ことを RESEARCH の表に 1 行で書く**。アクションの入力に「未検証」を残すときは plan が完了基準に「ソースを読んで確定」を置き、CI 待ちに回さない（Minus 1。F1 + round 2 = 1,332 s / USD 11.09）
- [ ] **plan: 成果物が複数 OS の CI になるマイルストーンでは `verify_round_max` を 4 にし、verify が OS 固有の赤をライブラリ側で見つけたら F 項目に「同じモジュールの他の経路を POSIX / libpq の文書上の契約と突き合わせる 1 行」を必ず含める**（F2 → F3① は同じ `async_conn.mojo` の poll 経路で 2 round 消費。Interesting 1・2）。研究段階で macOS 実機が無い制約は変わらないので、契約との照合を実機の代わりにする
- [ ] **plan: チェックリスト生成スクリプトで YAML / sh / py の key は `grep -v -E '^\s*#'` を挟んでから `grep -c` する**（コメント行を母数から外す）。合わせて impl の規則「コメントを書いたらコミット前にチェックリストを 1 回回す」を gsd-lite-impl の固定文言にする（Minus 2。同型 3 回）
- [ ] **ツール側（マイルストーン間にユーザーが行う。4 回目）**: `gsd-lite-loop.sh` で 1 試行の生ログに `result` が複数あるとき `num_turns` / `usage` 各項目は**全 `result` の合計**、`permission_denials` は**全件の和**、`cost_usd` は最後の値。`subagent_stats.spawned` を `subagents` として記録する（Minus 3。turn 5 の Bash 拒否 `nohup … &` が WARN にならなかった。turn 10 は 2 / 282 vs 74 / 19,845）。あわせて `nohup` を allowlist に足すか、「バックグラウンド起動は `run_in_background` Bash で」を impl の規則にする
- [ ] **impl: サブエージェントの依頼文に「親が待ち合わせに使うファイル名と解除条件」を書かない**。渡すのはサブ側の出力ファイル名だけ、親の待ちは「スクリプト自身が書くファイル（`build/final_check.log` 等）+ タスクの rc」で判定する。gsd-lite-impl のサブエージェント雛形に 1 行足す（Minus 4）
- [ ] **verify / impl: 自分が起動していない CI run を見つけたら `gh run view <id> --json event,headSha,createdAt` の結果を VERIFICATION / PROGRESS に写し、推定で書かない**。あわせて PLAN / REQ に「state コミットの push ごとに 3 OS の run が起動する（`concurrency` が古いものを cancel する）」を事実として書く。差し戻し round の verify は state コミットを push しない（次の impl の push に載せる）運用にするか、ループ側で「差し戻し / reflect の state のみコミットは push しない」を選ぶ（Minus 5。6 run 中 2 本 + 進行中 1 本が state コミット由来）
- [ ] **plan: チェックリストの key 総数を PLAN 表の見出しに 1 回書き、impl / verify の TRACE「チェックリスト（turn N）」節は同じ総数を書く**。数が変わったら PLAN 訂正として 1 行（Minus 7。106 vs 101）。plan の最後に `≥` 行以外の `= N` 行について「RESEARCH の雛形を grep して現在値を取る」を 1 回行う（Minus 6。`pixi_pkg_name_pq`）
- [ ] **discuss（次マイルストーンの前に人間が決めること、記録から）**: (a) PR #1 のマージ・README「ブランチ保護」・`v0.1.0` タグ（VERIFICATION §R4.7）。(b) `CHANGELOG.md` の `0.1.0` 節に Phase 6 の成果（conda パッケージ / CI / Release）を足すか（VERIFICATION §0.6 新規 9。REQ の文言が「Phase 1〜5」だったので verify は足していない）。(c) 2026-10-19 の `ubuntu-latest` → Ubuntu 26 移行後の main の run を一度見る（残留リスク 12）。(d) `is_leaking` の段除外は CI 未実測（残留リスク 13）、x86_64 で段が再発したときの run を確認。(e) `.gsd-lite/` 一式（+4,911 行の大半）が PR に載っている。main の履歴に残すか、squash / gitignore にするかを次マイルストーンの前に決める。(f) 残る候補は Windows（ツールチェーン待ち）、modular-community recipe（D2 で却下）、HANDOFF §3（プール / COPY / 配列型）。採る前に research のプローブ 1 本で実在を確かめる規則は継続
