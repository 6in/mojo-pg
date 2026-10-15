# 振り返り — phase1-sync-text-basic（2026-10-15 23:08）

- 種別: ループ（verify 合格後）
- 対象範囲: `35d1f36`（discuss）...`d3df55e`（verify round 2）= マイルストーンブランチ `gsd-lite/phase1-sync-text-basic`（コミット 27 件。うちコード側 `src` / `tests` / `examples` / `pixi.toml` に触れたもの 11 件）/ ターン 1〜15。`main` へ `--no-ff` マージ済み（`bf17283`）
- 前回の振り返り: なし（`.gsd-lite/reflect/` は空。初回）
- 成果の規模（`git diff --stat bf17283^1 bf17283^2`）: 30 ファイル +6,423 / −55。コード側は 23 ファイル +5,056 / −47。テスト 228 件（114 × PG14 / PG17）
- 壁時計: discuss コミット 19:35 → マージ 23:07 = 約 3 時間 32 分（turns.jsonl の合計 12,693 s = 212 分。discuss は turns.jsonl に無い）

## 計測（turns.jsonl から）

| フェーズ | ターン数 | 試行数 | 所要（分） | リトライ | 出力トークン | キャッシュ読み | コスト（USD） | エンジン / モデル |
|---|---|---|---|---|---|---|---|---|
| research | 1 | 1 | 18.0 | 0 | 87,556 | 4,828,214 | 10.38 | claude / claude-fable-5-1 |
| plan | 1 | 1 | 11.4 | 0 | 55,592 | 1,596,024 | 6.33 | claude / claude-fable-5-1 |
| impl | 11 | 11 | 157.6 | 0 | 243,541 | 53,003,993 | 70.71 | claude / claude-opus-5 |
| verify | 2 | 2 | 24.6 | 0 | 70,232 | 7,973,652 | 24.15 | claude / claude-fable-5-1 |
| **合計** | **15** | **15** | **211.6** | **0** | **456,921** | **67,401,883** | **111.56** | |

impl のターン別所要（秒）: T1 695 / T2 702 / T3 637 / T4 959 / T5 1,197 / T6 724 / T7 1,114 / T8 336 / **F1 1,907** / F2 691 / F3 491。
verify: round 1 1,022 s（USD 17.51 = 全ターン中最高額）/ round 2 455 s（USD 6.64）。
差し戻しに起因する分（F1〜F3 + verify round 2）= 3,544 s（59 分）/ USD 21.6 = 全体の 28 % / 19 %。

- 権限拒否（permission_denials）: なし（15 ターンすべて `[]`）
- 無進捗の試行: 0。`attempt > 1` の行: 0（`turn-NNN-attempt2.log` も存在しない）
- 利用枠（rate_limit.five_hour）: 0.07 → 0.47（マイルストーン 1 本で 5 時間枠の 40 % を消費）
- 計画タスク数 / impl ターン数: 8 / 11（T1〜T8 は 1 タスク 1 ターンで計画どおり。+3 は差し戻し F1〜F3）
- verify 差し戻し: verify_round 1 回（指摘 3 件 + 軽微まとめ 1 件 → F1 / F2 / F3）/ BLOCKED: 0 回（`git log --all -- .gsd-lite/BLOCKED.md` は空）
- 前回の提案の反映: 該当なし（初回）

## Plus（うまくいったこと）

- **リトライ・無進捗・権限拒否がゼロ**で 15 ターン走り切った（根拠: turns.jsonl 全行 `attempt: 1` / `progressed: true` / `permission_denials: []`）。無人シェルの作法（フルパス `pixi`、`-F` コミット、scratch 置き場）が初回から機能した
- **T8（品質仕上げ）がコード変更ゼロで全基準を満たした**（根拠: PROGRESS turn 10 想定外 (3)、コミット `a0ec2c7` は PLAN と state のみ）。T1 で `pixi run check` を作って各ターンが緑を維持したため、整形・docstring・警告の負債が最後に溜まらなかった
- **research のプローブ 9 本が PLAN に直結した**（根拠: PROGRESS turn 1、PLAN 内の `RESEARCH` 参照 13 箇所、RESEARCH §5 の落とし穴 21 件をタスクに対応づけ）。`extension` 不可 / `.mojopkg` 不可 / `ExternalFunction` 不可 などを impl 前に潰し、impl 11 ターンでこれらに起因するやり直しは 0
- **「テストを契約表から独立に書く」サブエージェント分割が当たった**（根拠: turn 3〜8 の「やり直し: 0 回」が 4 ターン。turn 5 は B が実装を読まずに 49 件を書いて初回から全 PASS、turn 6 は 3 本並行で統合時のコード修正ゼロ）
- **verify round 1 が本物の偽陰性を陽性対照で暴いた**（根拠: VERIFICATION round 1 指摘 1、PROGRESS turn 11 想定外 (1)。`PQclear` を全削除しても 8/8 PASS）。指摘を E1〜E16 の期待結果表にしたことで F2 / F3 のやり直しが 0 回、round 2 の指摘 0 件（根拠: PROGRESS turn 13 / 14 / 15）
- **verify round 2 を「格子の再確認 + 回帰のみ」に絞って 455 s / USD 6.64 で終えた**（根拠: turns.jsonl turn 15、PROGRESS turn 11 の申し送り）。round 1 の 1,022 s / USD 17.51 の半分以下
- **PLAN 訂正が毎回「実測を正」に根拠付きで記録された**（根拠: PROGRESS turn 3 / 6 / 7 / 9 / 10 / 12 / 14 の「PLAN 訂正」欄。63 バイト切り詰め、`::` の結合順、`_ = x^` の寿命 など）。要件・決定には触れない線引きが守られた
- **負のコンパイル確認**（`Connection` のコピー禁止、`Row[origin]` の借用検査）を scratch で実測して PROGRESS に残した（根拠: turn 6 / 7、`scratch/turn-006-neg-copy.mojo` / `turn-007-neg-row-escape*.mojo`）

## Minus（問題・無駄・やり直し）

- **verify 差し戻し 1 回は impl が自分で閉じられた**（根拠: PROGRESS turn 9 の verify への申し送り (1)「陽性側は未実証」、turn 15 の次への注意 (1)、F1 = 1,907 s で impl 最長）。原因: T7 の完了基準に陽性対照（free を消したら FAIL する）が無く、impl が「未実証」と書いて先へ進んだ。差し戻し分 59 分 / USD 21.6 のうち F1 分（32 分 / USD 5.88）+ verify round 2 の一部は、T7 の完了基準 1 行で防げた
- **tolerance の数値を 2 回訂正し、2 回目で 1 回目の論拠を取り消した**（根拠: turn 9「16 → 256。100 B/回でも全区間で増えるので検出力は落ちない」→ turn 12「成立しない。コンパイラの解放済みプールが吸収する」）。原因の見立て: RSS を `mojo run` プロセスで測る設計（D6）が持つ前提（ヒープがクリーン）を research で検証しなかった。推測: `mojo build` したバイナリで測る案（F1 (c)）なら tolerance 問題ごと消えた可能性がある
- **`pixi run check` の 1/6 段が未コミット差分で落ちる仕様が 3 ターンで「想定外」に書かれた**（根拠: PROGRESS turn 8 想定外 (1) / turn 12 (4) / turn 13 (4)、turn 15 次への注意 (3)）。turn 8 で「設計どおり」と判断して直さず、申し送りだけで済ませたため毎ターン 1 回分の `check`（約 97 s）が無駄になった
- **research の プローブで 7 回やり直し**（根拠: PROGRESS turn 1 やり直し欄: `ImmAnyOrigin` → `ImmutAnyOrigin` → `ImmUntrackedOrigin`、`OpaquePointer`、`ExternalFunction` 等）。原因の見立て: Mojo 1.1.0 のシンボル名を記憶で書いてコンパイラに聞いた。stdlib のソース / パッケージから名前を grep する手順が無い
- **PLAN の完了基準に達成不可能な条件が 1 件あった**（根拠: turn 3 想定外 (1)、docstring 診断が合成 dunder を struct 宣言行に報告するため「= 0」が不可能で、判定側を訂正）。research §2.4 ツールチェーンでは `--diagnose-missing-doc-strings` の挙動を実測していなかった（推測: RESEARCH の見出しからの判断）
- **サブエージェントの `fmt` が他方の編集中ファイルを書き換えた**（根拠: turn 6 想定外 (7)）。turn 7 以降「fmt は親だけ」で衝突ゼロになったが、依頼文テンプレに最初から無かった
- **サブエージェント契約文の型表記の省略で 1 回やり直し**（根拠: turn 7 想定外 (2)、`Row` と書いて `Row[origin]` と読まれず 6 ヘルパーの署名修正）
- **scratch のファイル名規約が守られていない**（根拠: `scratch/` に `t4a-probe.mojo` / `t4b-probe-pg14.mojo` / `t5a-probe.mojo` / `basic_copy.mojo` / `init_copy.mojo` / `probe_exit.mojo` / `probe_exports.mojo` / `fmtcheck` の 8 件が `turn-NNN-` 接頭辞なし）。推測: サブエージェントが作ったもので、依頼文に規約が入っていない
- **記録の不足**: turns.jsonl の `ended_at` が全 15 行 `null`（`started_at` + `duration_s` から復元はできる）。また `tests/docker-compose.yml` の `0.0.0.0` 公開（Phase 0 の既存ファイル）は verify round 1 のセキュリティレビューまで誰も見ていない（根拠: VERIFICATION round 1 セキュリティ欄、PROGRESS turn 11 想定外 (6)）

## Interesting（気づき・意外だったこと）

- **PROGRESS の記録に矛盾がある**: turn 8 / 9 は `rg ...` で ✓ と書いているが、turn 10 で `rg` がこの環境に無いことが判明（根拠: PROGRESS turn 10 想定外 (1)「MCP 側の検索ツール経由だったと思われる」）。impl が「実行したコマンド」として書いた検査の一部は素のシェルでは再現できない形だった。turn 10 で `grep` に置き換えて同じ結論を得たので結果は正しい
- **Mojo 1.1.0 固有の落とし穴 2 つがテストの読み方を変えた**（根拠: turn 7 想定外 (1)、turn 11 想定外 (1)）。(a) `_ = x^` は寿命を終わらせない生存マーカー。既存テストの `_ = conn^` の意味が turn 7 で初めて正しく理解された。(b) `mojo run` はコンパイラを同一プロセスで動かし、解放済みヒープ約 100 MiB が常駐してリークを吸収する。どちらも RESEARCH に無く、次のマイルストーンの RESEARCH に先回りで載せる価値がある（turn 15 次への注意 (2)）
- **+83 ページの一段は 6 回中 3 回出て出所不明のまま**（根拠: turn 9 / 10 / 12、VERIFICATION round 1 / 2 のサンプル列）。tolerance 256 で吸収しているだけで、根本は未特定
- **verify round 1 が単一ターンで最も高額**（USD 17.51、出力 59,867 トークン、`num_turns` 98）。コードレビュー / セキュリティのサブエージェント 2 本 + 親の堅牢性格子 + 陽性対照の実測を 1 ターンに詰めた結果だが、指摘 3 件すべてが本物だったので費用対効果は高い
- **impl のコストはターン数ではなく「実測の多さ」で決まった**: T5（USD 10.54、1,197 s）と T6（USD 10.78、959 s）は負のコンパイル確認や実測 7 件を含む。T8 は USD 3.16 / 336 s。F1 は 1,907 s で最長なのに USD 5.88（待ち時間 = `check` と 10,000 回ループの実行が支配）
- **`pg_terminate_backend` の期待表は research が未検証のまま PLAN に入り、impl が実測で覆し（turn 6）、verify が分類を再度覆した（round 1 → F2）**。同じ 1 ケースが 3 フェーズで 3 回書き換わった。PLAN に「未プローブ」と明記されていたので手戻りは最小で済んだ
- **D5（50 本全バインド。推奨は「使う分だけ」）はユーザー判断で採用され、記録上の追加コストは見えない**（根拠: DECISIONS D5、turn 3 で B 1 本が 4 ファイルを 1 ターンで完了）。推測: ヘッダ行番号付きの表を plan が作ったので 50 本でも 20 本でも手間は変わらなかった
- **`check` 1 回 84〜101 s のうち `test_leak` が 43〜47 s/サーバーで半分以上**（根拠: turn 10 / 12 / 14）。マイルストーン後半の impl ターンは `check` を 2 回回すだけで 3 分以上が待ち時間

## 次回への提案（実行可能な形で）

- [ ] **検出力を主張するテスト（リーク・タイムアウト・リトライ等）のタスクは、完了基準に「陽性対照: 該当の free / 処理を消したコピーで FAIL することを実測して PROGRESS にサンプル列を貼る」を plan が最初から書く**。verify への「未実証」の申し送りは禁止し、impl が同じターンで回す（Minus 1、turn 9 → turn 11 → F1 の 59 分）
- [ ] **`tests/final_check.sh` の 1/6 段を `git diff` 判定からフォーマッタ自身の差分判定に変える**（例: `mojo format` をコピー先に適用して元と比較する、または `--check` 相当があればそれを使う）。次のマイルストーン冒頭の 1 コミット。直すまでは PLAN「検証コマンド」節に「`check` はコミット後に回す」を最初から書く（Minus 3、3 ターン × 約 97 s の無駄）
- [ ] **次のマイルストーンの RESEARCH 冒頭に「Mojo 1.1.0 既知の落とし穴」節を引き継ぐ**: `_ = x^` は生存マーカーで破棄ではない / `mojo run` の常駐ヒープ約 100 MiB（リーク測定は `mojo build` したバイナリで行うか 64 KiB 以上の payload）/ docstring 診断は合成 dunder を struct 行に報告する / `len(String)` 不可 → `byte_length()` / `from std.math import isnan` / リスト literal は `Array` なので `List[Int]` 注釈必須 / `platform_map` は `List` を返せない / `with` 内 `var` は外から見えない / `::` は単項マイナスより強い / `rg` 無し・`pixi` はフルパス（Interesting 2、Minus 5）
- [ ] **research スキルに「プローブを書く前に stdlib のシンボル名を grep で確定する」手順を足す**（pixi 環境内の Mojo stdlib ソースまたはパッケージの場所を research 冒頭で 1 回特定し、`Origin` / `Pointer` 系の型名はそこから写す）。turn 1 の 7 回やり直しのうち名前違いが 4 件（Minus 4）
- [ ] **impl スキルのサブエージェント依頼文テンプレに 3 行を固定で入れる**: (a) 型パラメータを持つ型は `Row[origin]` のようにフルに書く、(b) `fmt` は親が統合後に 1 回だけ走らせる（サブエージェントは実行禁止）、(c) scratch ファイルは `.gsd-lite/logs/<slug>/scratch/turn-NNN-<name>` 固定（Minus 6 / 7 / 8）
- [ ] **PROGRESS の「追従先チェックリスト ✓」には実行したコマンドを素のシェルで再現できる形で書く**（MCP 検索ツールで見た結果を `rg ...` として書かない。verify / reflect が再実行できることを優先）（Interesting 1）
- [ ] **リーク測定を `mojo run` の RSS から切り替えるか discuss で聞く**: 選択肢 (a) 現状維持（payload 64 KiB + tolerance 256 ページ + 早期 fail）、(b) `mojo build` したバイナリで `run_tests.sh` から回す（常駐ヒープが消え tolerance を 16 に戻せる見込み）、(c) `mallinfo2()` を FFI で読む。推奨は (b) を Phase 2 の最初のタスクで試す（Minus 2、Interesting 3）
- [ ] **`check` の待ち時間を減らす**: `test_leak.mojo` を `pixi run check` では 1 サーバーだけで回す（または `PQ_TEST_LEAK_SERVERS=1` のような環境変数で片側 skip）案を plan で検討する。差分なしの 2 サーバー × 45 s が毎ターン 2 回かかっている（Interesting 8）
- [ ] **verify round 2 の「格子の再確認 + 回帰のみ」の運用を verify スキルの既定にする**（round 1 の半分以下の時間・コストで合格判定できた実績。Plus 6）
- [ ] **次のマイルストーン冒頭で 1 コミットにまとめて直す小物**: VERIFICATION round 2 残留リスクの docstring 3 件（`execute` の CONNECTION 説明 / `Row.get(name)` の引数名 / `test_leak` の `PAYLOAD_BYTES` 説明）、REQ §4.1 の `PQ_MOJO_LIBPQ` フォールバック文言を実装（設定時はその 1 本のみ）に揃える、未使用の `OID_TEXT` 等 4 定数の扱い（turn 15 次への注意 (4)、VERIFICATION 残留リスク）
- [ ] **`gsd-lite-loop.sh` の turns.jsonl に `ended_at` を書く**（全 15 行 `null`。Minus 9）。research の対象に「既存のテスト環境ファイル（compose の公開ポート等）」を 1 行足す（docker-compose の `0.0.0.0` が verify round 1 まで残った）
