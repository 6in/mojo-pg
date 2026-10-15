# 振り返り — phase2-params-prepared-tx（2026-10-16 02:46）

- 種別: ループ（verify 合格後）
- 対象範囲: `05d7c84`（discuss）...`c540c2e`（verify round 1）= マイルストーンブランチ `gsd-lite/phase2-params-prepared-tx`（コミット 18 件。うちコード側 `src` / `tests` / `examples` / `pixi.toml` に触れたもの 7 件 = T1〜T7 各 1 コミット）/ ターン 1〜10。`main` へ `--no-ff` マージ済み（`e60b46f`）
- 前回の振り返り: `20261015-2308-phase1-sync-text-basic.md`
- 成果の規模（`git diff --stat e60b46f^1..e60b46f^2`）: 35 ファイル +9,740 / −1,343。コード側（`src` / `tests` / `examples` / `pixi.toml`）は 22 ファイル、約 +6,400 行。テスト 402 件（201 × PG14 / PG17。Phase 1 末は 114 × 2）
- 壁時計: discuss コミット 23:43 → マージ 02:43 = 約 3 時間 00 分（turns.jsonl の合計 10,855 s = 181 分。discuss は turns.jsonl に無い）

## 計測（turns.jsonl から）

| フェーズ | ターン数 | 試行数 | 所要（分） | リトライ | 出力トークン | キャッシュ読み | コスト（USD） | エンジン / モデル |
|---|---|---|---|---|---|---|---|---|
| research | 1 | 1 | 22.0 | 0 | 86,884 | 3,724,906 | 10.77 | claude / claude-fable-5-1 |
| plan | 1 | 1 | 18.7 | 0 | 84,633 | 2,696,034 | 10.32 | claude / claude-fable-5-1 |
| impl | 7 | 7 | 128.1 | 0 | 142,461 | 37,812,519 | 75.45 | claude / claude-opus-5 |
| verify | 1 | 1 | 12.2 | 0 | 15,082 | 2,603,911 | 14.03 | claude / claude-fable-5-1 |
| **合計** | **10** | **10** | **180.9** | **0** | **329,060** | **46,837,370** | **110.57** | |

impl のターン別所要（秒）/ コスト（USD）/ サブエージェント本数（PROGRESS の記述から）:
T1 1,252 / 11.07 / 2、T2 849 / 7.34 / 4、T3 1,211 / 13.04 / 3、T4 1,143 / 11.70 / 2、T5 1,395 / 16.73 / 3、T6 1,071 / 6.31 / 0、T7 763 / 9.27 / 2。
verify: round 1 のみ 729 s / USD 14.03（サブエージェント 2 本）。

- 権限拒否（permission_denials）: なし（10 ターンすべて `[]`）
- 無進捗の試行: 0。`attempt > 1` の行: 0（`turn-NNN-attempt2.log` も無い）
- 利用枠（rate_limit.five_hour）: 0.09 → 0.49（Phase 1 と同じく 5 時間枠の 40 % を 1 本で消費）
- 計画タスク数 / impl ターン数: **7 / 7**（1 タスク 1 ターンで計画どおり。差し戻し・追加タスクなし）
- verify 差し戻し: **0 回**（round 1 で合格。残留リスク 10 件は差し戻し対象外）/ BLOCKED: 0 回（`git log --all -- .gsd-lite/BLOCKED.md` は空）
- Phase 1 との比較: 15 ターン / 212 分 / USD 111.56 → 10 ターン / 181 分 / USD 110.57。差分量は約 1.5 倍（+6,423 → +9,740）、テスト数は 1.76 倍。impl 1 ターンあたりのコストは USD 6.43 → 10.78
- 前回の提案の反映（PLAN「メモ」の反映表 + 記録で照合）:
  - 守られた（8 件）: 1 陽性対照を完了基準に（T1 (g) / T6 (c)、PROGRESS turn 3 / 8 に系列あり）、2 `final_check.sh` 1/6 段の方式変更（turn 3）、3 RESEARCH §0.5 の落とし穴節、5 サブエージェント依頼文 3 行（scratch 59 件すべて `turn-NNN-` 接頭辞、`fmt` 衝突 0）、6 PROGRESS の ✓ を素のシェルで（turn 9 (e) の表を verify が全行再実行）、7 `mojo build` 化（D4 / T1）、8 `check` の leak 1 サーバー化（`PQ_TEST_LEAK_SERVERS=1`。`check` 96 s → 59〜111 s）、10 冒頭 1 コミットで小物（T1）
  - 対象外・該当なし（2 件）: 4 research スキルの stdlib grep 手順（D18 でスキル側は変更しない。さらに turn 1 想定外 (3) で pixi env に stdlib ソースが無いと判明し、提案の形では実行不能だった）、9 verify round 2 の運用（round 2 が発生しなかった）
  - 守られなかった（1 件）: 11 `gsd-lite-loop.sh` の `ended_at`（turns.jsonl 10 行すべて `null` のまま。D18 でツール側は対象外）

## Plus（うまくいったこと）

- **差し戻し 0・リトライ 0・権限拒否 0・BLOCKED 0 で 10 ターン完走し、計画 7 タスクが 7 ターンちょうどで終わった**（根拠: turns.jsonl 全行 `attempt: 1` / `progressed: true`、VERIFICATION 冒頭「差し戻し 0 件」、コミット列 T1〜T7 各 1 本）。Phase 1 の差し戻し分（59 分 / USD 21.6）が丸ごと消えた
- **前回提案 1（陽性対照を完了基準に）が初回タスクで本物の欠陥を捕まえた**（根拠: PROGRESS turn 3 想定外 (1)、PLAN T1「PLAN 訂正（turn 3 実測）」）。`final_check.sh` 1/6 段の新方式は `mojo format` が `.gitignore` 配下を走査しないため永久 PASS の no-op だった。陽性対照なしなら Phase 2 全体で fmt 判定が飾りのまま通っていた
- **impl 7 ターン中 6 ターンが「やり直し 0 回」**（根拠: PROGRESS turn 4〜9 のやり直し欄。turn 3 のみ 1 回で、それも陽性対照の原因特定）。PLAN「未プローブ」4 項目のうち 3 項目は impl がそのまま通し（turn 5 / 6）、残る 1 項目（`Transaction.prepare` の origin）も同ターン内で代替設計に収めた（turn 7）
- **サブエージェント契約の「鵜呑みにせず自分で確かめる」が 3 回効いた**（根拠: turn 5 想定外 (1) A の契約外提案を親が決めた事項 5 の意図内と判断して採用 / turn 6 想定外 (1) B の「仕様が実物と合わない」報告を親が `scratch/turn-006-probe-int8-int4.mojo` で実測してから PLAN 訂正 / turn 9 想定外 (1) B が申し送りの欠落を grep で検出）。契約文に書かれていない欠陥（空 `bytea` の NULL 化、`PQexecPrepared` の型非対称、docstring 1 件）が impl の中で閉じた
- **T5 のサブエージェント C が `src/pq` のコピーにスタブを当てて自力で型検査を済ませ、統合後の修正ゼロ**（根拠: turn 7 想定外 (3)）。「依存先が未実装」の状態でもテストを独立に書けることを示した
- **verify が 1 ラウンド・729 s・USD 14.03 で合格判定を出した**（根拠: turns.jsonl turn 10、VERIFICATION §4 の格子 11 セル全部 `PgError`）。Phase 1 の round 1（1,022 s / USD 17.51）+ round 2（455 s / USD 6.64）に対し半分以下
- **REQ の受け入れ基準 2 件が実測と矛盾する問題を BLOCKED にせず 3 フェーズで一貫して処理した**（根拠: turn 1 想定外 (1) → RESEARCH §5 → PLAN 決めた事項 14 → VERIFICATION「14-1〜14-5 は PLAN を正とした」）。研究が実測で覆し、plan が読み替えを固定し、verify がそれを判定基準にした
- **PROGRESS が「やっていないこと」を正直に書き、verify がそれを埋めた**（根拠: turn 9 (d)「`pixi run test` は回していない」、VERIFICATION §5「正直な記述で、verify が今回回して両サーバー PASS を確認」）

## Minus（問題・無駄・やり直し）

- **ターン間の申し送りに誤りが 3 回あった**。(a) turn 5 の申し送り (4)「`Connection.open` が ~3.6〜4.0 s/回、test_params 117 s / 142 s」は `Summary [ N ]` の **ms を s と読んだ誤り**で、turn 6 想定外 (2) が訂正（実際は ~4 ms/回）。この誤りは「verify への接続共有案の申し送り」という不要な提案まで生んでいた。(b) turn 6 の申し送り (2)「`Transaction.prepare` は委譲で返せる見込み」は外れ（turn 7 想定外 (1)。deref を挟むと origin が入れ子になる）。(c) turn 8 の申し送り (3)「docstring 照合の残りは 4 番だけ」は 2 番も欠けていた（turn 9 想定外 (1)）。いずれも次ターンが grep / プローブで確かめたので手戻りはゼロだが、申し送りの信頼度そのものは低い。原因の見立て: (a) は TestSuite の出力に単位が無いこと、(b)(c) は「見込み」と「確認済み」が同じ文体で書かれていること
- **verify の残留リスク 10 件のうち 6 件は plan の完了基準の書き方で防げた文書・テスト門番**（根拠: VERIFICATION §6-1〜6）。特に 6-2「`check` 6/6 段が `implicit ROLLBACK failed` を数えない」は、turn 7 / 8 / 9 の 3 ターンで impl が同じ `grep -c ... = 0` を手で回しており（PROGRESS turn 7 表 / turn 8 表 / turn 9 (d) 表）、T5 で `final_check.sh` の grep パターンに 1 語足せば機械化できた。6-3「`find("1") >= 0` の落ちない断定」は PLAN T4 (b)-2 の期待文言が `1` 1 文字だったことに由来する
- **research のプローブで 5 回やり直し**（根拠: PROGRESS turn 1 やり直し欄: `List[UInt8](1,2,3)` ctor ×3 ファイル / `s[i]` / `UnsafePointer` / `c_size_t` / 素の `None`）。前回提案 4（stdlib シンボルを grep で確定）は D18 と「stdlib ソースが pixi env に無い」（turn 1 想定外 (3)）で実行不能だった。代替の「docs サイト + コンパイルエラーの候補」は PLAN に書かれたが research 自身は使えていない。推測: 5 回のうち 3 回は同じ ctor の誤りを 3 ファイルに複製したもので、最初の 1 ファイルを通してから残りを書けば 2 回で済んだ
- **PLAN の所要見積もりが過大だった**（根拠: turn 8 想定外「`check` 2〜3 分」→ 実測 82 s、PLAN 訂正）。Phase 2 の 4 ループが接続 1 本を使い回すことを plan が所要に織り込んでいなかった。影響は見積もりの訂正 1 回だけ
- **REQ 本文が陳腐化したまま残っている**（根拠: turn 2 想定外 (2)「REQ 本文は触っていない。verify はこの項を正とする」、VERIFICATION「14-1〜14-5 は PLAN を正とした」）。REQ §5.1a の「rollback 後の prepared は失敗」「int8 → int4 は 42804」は実装・テストと食い違う記述のまま。次のマイルストーンが REQ を読むと誤解する
- **記録の不足（前回と同じ 1 件 + 新規 1 件）**: turns.jsonl の `ended_at` が 10 行すべて `null`（前回提案 11 未反映）。新規: **`usage` にサブエージェント分が入っていない**とみられ、出力トークンあたりのコストが USD 0.12〜1.52 / 1k と 13 倍の幅になる（根拠: turn 5 は `output_tokens` 8,602 / `num_turns` 15 で USD 13.04、turn 8 はサブエージェント 0 本で `output_tokens` 32,443 / `num_turns` 73 で USD 6.31）。推測: `cost_usd` はサブエージェント込み、`usage` / `num_turns` は親だけ。ターンの重さを `usage` で読めない

## Interesting（気づき・意外だったこと）

- **サブエージェント 0 本の T6 が impl で最安（USD 6.31）だった一方、親の出力トークンは最多（32,443）**（根拠: turns.jsonl turn 8、PROGRESS turn 8「やったこと」にサブエージェントの記述なし）。逆に 3 本使った T5 は USD 16.73 で最高額。推測: サブエージェントは「親の文脈を増やさずに並列化する」代わりに総トークンを増やす。T6 のように 1 ファイル完結で実行待ちが支配的なタスクでは親が直接書くほうが安い
- **Phase 1 より 1.5 倍の差分を 2/3 のターン数・同じコストで出した**（計測表の比較行）。推測: 差し戻しの消滅（−59 分）とサブエージェント並列化（1 ターンに 2〜4 ファイルを同時に）の両方が効き、後者がコストを impl 1 ターンあたり USD 6.4 → 10.8 に押し上げた
- **+83 ページの一段が今回も 6 回出て出所不明のまま**（根拠: PROGRESS turn 3 (f) で 16 系列中 2 回 + (h) で 1 回、turn 4 で PG14 1 回、turn 7 で PG17 1 回、turn 8 で PG14 1 回。verify の実行では 0 回）。`mojo build` バイナリでも出るので「`mojo run` の常駐ヒープ」説（Phase 1 reflect）は否定された（turn 3 想定外 (2)）。T1 で 256 を維持した判断は 16 系列の実測に基づいており、turn 4 / 8 の +85 で「16 に下げていれば偽陽性」が実証された
- **Mojo 1.1.0 の新しい落とし穴 7 件が impl 中に見つかり、どれも RESEARCH §0.5 に無かった**（根拠: turn 3 想定外 (1) `mojo format` は `.gitignore` を尊重 / turn 4 想定外 `SIMD.__rshift__` の rhs は `Self` 固定・符号付きシフトは符号拡張・`return out^` が必要 / turn 5 想定外 (2)〜(5) `as_bytes()` は `Span`・`def main() raises PgError` 不可・`s += s` の aliasing・`StaticString` は `@implicit` の対象外 / turn 7 想定外 (1)(2) deref を挟む origin の入れ子・`setenv` は raise しない）。研究プローブ 6 本でも網羅できない種類（format ツール・型推論の細部）
- **libpq の `PQexecPrepared` が `paramTypes` を送らない非対称は research のプローブ対象だったのに PLAN の期待値が誤っていた**（根拠: turn 6 想定外 (1)、RESEARCH §2.1 に `PQprepare` / `PQexecPrepared` のプローブあり、PLAN T4 (b)-1 の `[1, 2, "x"]`）。プローブは「通る形」だけを確かめており、「`Int`（int8）を int4 の prepared に渡す」組み合わせは試していなかった。残留リスク 1（docstring）として次に持ち越し
- **`mojo format` の挙動は 2 段階で誤解された**（根拠: turn 3 やり直し欄: 最初「`comptime` 行を整形しない」と疑い、単一ファイル指定とディレクトリ指定の差から `.gitignore` 尊重に辿り着いた）。陽性対照が無ければ「設計どおり」で通っていた典型
- **discuss が書いた受け入れ基準 2 件がサーバーの実挙動と矛盾した**（根拠: turn 1 想定外 (1)）。prepared statement は ROLLBACK で消えない（PREPARE は非トランザクショナル）、int8 パラメータを int4 列に入れても assignment cast で成功する。discuss は実測せずに書き、research が最初のプローブで覆した。要件の「具体的な sqlstate / 失敗の断定」は discuss 時点では仮説にすぎない
- **loop.log に 2 マイルストーン分が連続して残り、turns.jsonl はマイルストーン別に分かれている**（根拠: `.gsd-lite/logs/loop.log` 1〜41 行目が Phase 1、42 行目以降が Phase 2）。`.limit_retry` / `.retry` は 0 で、利用枠による待ちは発生していない

## 次回への提案（実行可能な形で）

- [ ] **次マイルストーンの T1（持ち越し整理）に VERIFICATION §6 の 1〜6 と 9 を 1 コミットで入れる**: (1) `prepared.mojo` と `__init__.mojo` に「prepared は `PQprepare` 時点の型と同じ幅の値を渡す（`$1::int4` なら `Int32`）」を 1 文ずつ、(2) `final_check.sh` 6/6 段の grep パターンに `|implicit ROLLBACK failed` を追加（見出しにこの文字列を入れない）、(3) `test_prepared.mojo:543-544` を `"takes 3 parameters, got 1"` の部分一致に、(4) `Connection.__init__` docstring に `_stmt_counter` / `_rollback_failure_handler`、(5)(6) `out of range (0..-1)` と savepoint 名の NUL メッセージ `in s` の扱い、(9) `params.mojo:455` の `c_int(len(_data))` に `len > 0x3FFFFFFF` で USAGE を投げる 1 行（Minus 2、VERIFICATION §6）
- [ ] **discuss で REQ §5.1a の陳腐化した 2 行を直す（または決めた事項 14 を REQ に昇格する）**: 「rollback 後の prepared は失敗」→「成功。手動 DEALLOCATE 後は 26000」、「int8 → int4 は 42804」→「`Bool` → int4 が 42804、`Int(3000000000)` → int4 が 22003、`Int(5)` は成功」。次の REQ を書くときに前の REQ を正として読まないため（Minus 5、Interesting 7）
- [ ] **discuss が書く受け入れ基準のうちサーバー挙動を断定するもの（sqlstate・成功 / 失敗・command tag）に「要実測」印を付け、research の最初のプローブ対象にする**。research は矛盾を見つけたら RESEARCH §5 ではなく REQ 本文を直す権限を持つ（今回は「REQ 本文は触らない」規則で PLAN に読み替えが散った）（Interesting 7、Plus 7）
- [ ] **plan: 「完了基準で `grep -c X = 0` を複数タスクが繰り返す」ものは、最初に導入するタスクの完了基準に「`final_check.sh` の該当段に機械化する」を書く**。今回なら T5 の完了基準に「6/6 段のパターンに `implicit ROLLBACK failed` を足す」（Minus 2。turn 7 / 8 / 9 で手動 grep を 3 回）
- [ ] **plan: テスト仕様の期待メッセージは 2 語以上の部分文字列で書く**（`"1"` ではなく `"got 1"`、できれば `"takes 3 parameters, got 1"`）。1 文字・1 語の期待は別の文字列にも一致して落ちない断定になる（Minus 2、VERIFICATION §6-3）
- [ ] **impl の申し送り（PROGRESS「次への注意」）は「確認済み」と「見込み」を分けて書き、見込みには `未確認:` 接頭辞を付ける**。次ターンは `未確認:` の項目だけを最初の 1 プローブで確かめる。所要の数値には必ず単位を書き、TestSuite の `Summary [ N ]` は **ms** と明記する（Minus 1 の (a)(b)(c)）。D18 によりスキルは変えないので REQ §9 に書く
- [ ] **次マイルストーンの RESEARCH §0.5 に今回の落とし穴 7 件を追加する**: `mojo format` はディレクトリ走査で `.gitignore` を尊重（明示ファイル列なら無視されない）/ `SIMD.__rshift__` の rhs は `Self` 固定・符号付き右シフトは符号拡張（`bitcast` でゼロ拡張）/ ローカル `List` は `return out^` / `String.as_bytes()` は `Span`（`List[UInt8]` が要るならコピー）/ `def main() raises PgError` 不可（`raises` のみ）/ `s += s` は aliasing エラー / `StaticString` は `@implicit` の変換元にならない / deref を挟むと origin が入れ子になり struct の origin パラメータは変換不能（`rebind` も不可）/ `std.os.setenv` は raise しない（`Bool` を返す）/ 空 `List[UInt8]` の `unsafe_ptr()` を libpq に渡す経路は `capacity=len+1` で非 NULL を保証（Interesting 4、turn 5 想定外 (1)）
- [ ] **research のプローブは「通る形」だけでなく「仕様上の非対称を突く形」を 1 本含める**: libpq の `PQexecParams`（型同送）と `PQexecPrepared`（型なし）に同じ `Param` 列を渡して差を記録する、のように API 対のペアで試す（Interesting 5）
- [ ] **plan にタスクごとの「サブエージェント推奨本数」を書き、1 ファイル完結・実行待ち支配のタスクは 0 本と明記する**（T6 が 0 本で最安 USD 6.31、T5 が 3 本で最高 USD 16.73。Interesting 1）。推測を含むので、次回 1 マイルストーン分の `cost_usd` でサブエージェント本数との相関を reflect が確認する
- [ ] **research を書く前に同じ誤りを複数ファイルに複製しない**: プローブの最初の 1 本をコンパイルしてから残りを書く（turn 1 の 5 回のうち 3 回が同じ ctor 誤りの複製。Minus 3）
- [ ] **ツール側（マイルストーン間にユーザーが行う）**: `gsd-lite-loop.sh` が turns.jsonl に `ended_at` を書く（2 マイルストーン連続で `null`）。可能ならサブエージェント込みの出力トークン（または Agent 呼び出し回数）も記録し、`cost_usd` との対応を読めるようにする（Minus 6）
- [ ] **+83 ページの一段の扱いを discuss で決める**: (a) 出所不明のまま `TOLERANCE_PAGES = 256` を恒久仕様とし `test_leak.mojo` の docstring に「+83〜85 ページの一段が 1 回出ることがある（glibc arena の拡張と推測、未特定）」と書く、(b) 1 ターンの調査タスク（`mallinfo2()` / `MALLOC_ARENA_MAX=1` で再現するか）を次の PLAN に入れる。推奨は (a)（2 マイルストーン・20 系列以上で偽陽性ゼロ、検出力は陽性対照 5 経路で実証済み。Interesting 3）
