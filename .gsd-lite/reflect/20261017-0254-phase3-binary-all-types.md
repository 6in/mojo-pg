# 振り返り — phase3-binary-all-types（2026-10-17 02:54）

- 種別: ループ（verify 合格後。verify round 1 → F1 差し戻し → round 2 合格）
- 対象範囲: `5aae03d`（discuss）...`56b96c7`（verify round 2）= マイルストーンブランチ `gsd-lite/phase3-binary-all-types`（コミット 25 件。うちコード側 `src` / `tests` / `examples` / `pixi.toml` に触れたもの 10 件 = T1〜T9 + F1 各 1 コミット）/ ターン 1〜14。`main` へ `--no-ff` マージ済み（`15e8a2c`）
- 前回の振り返り: `20261016-0246-phase2-params-prepared-tx.md`
- 成果の規模（`git diff --stat e60b46f...15e8a2c`）: 44 ファイル +15,403 / −2,106。テスト 546 件 × 2 サーバー（Phase 2 末は 201 × 2 = 2.7 倍）
- 壁時計: research 開始 22:29:23 JST → マージ 02:51:37 = 4 時間 22 分（turns.jsonl の合計 15,775 s = 263 分。ターン間の隙間は 1 s ずつで、待ちは無い。discuss は 15:52 のコミットで turns.jsonl に無い）

## 計測（turns.jsonl から）

| フェーズ | ターン数 | 試行数 | 所要（分） | リトライ | 出力トークン | キャッシュ読み | コスト（USD） | エンジン / モデル |
|---|---|---|---|---|---|---|---|---|
| research | 1 | 1 | 21.8 | 0 | 103,043 | 5,943,949 | 18.53 | claude / claude-fable-5-1 |
| plan | 1 | 1 | 17.7 | 0 | 80,327 | 2,941,510 | 10.04 | claude / claude-fable-5-1 |
| impl | 10 | 10 | 204.1 | 0 | 264,900 ※ | 77,192,568 ※ | 112.10 | claude / claude-opus-5 |
| verify | 2 | 2 | 19.3 | 0 | 86,384 | 9,375,884 | 23.39 | claude / claude-fable-5-1 |
| **合計** | **14** | **14** | **262.9** | **0** | **534,654 ※** | **95,453,911 ※** | **164.07** | |

※ turn 6 の `usage` は 188 トークン / `num_turns` 1 と記録されているが、生ログ `turn-006-attempt1.jsonl` 末尾の `modelUsage` は出力 153,239 / キャッシュ読み 29,031,355（Interesting 1）。表の impl 行は turns.jsonl の値のまま（実際は出力 +153k、キャッシュ読み +28.8M 程度大きい）。
`usage` はサブエージェント分を含まない（Phase 2 reflect Minus 6 と同じ）。

impl のターン別所要（秒）/ コスト（USD）/ サブエージェント本数（生ログ `subagent_stats.spawned`）/ PLAN の推奨本数:
T1 1,147 / 11.14 / 0 / 1、T2 1,467 / 13.28 / 3 / 3、T3 1,628 / 14.66 / 2 / 2、T4 1,462 / 21.75 / 2 / 2、T5 1,406 / 18.01 / 2 / 2、
T6 1,365 / 10.77 / 2 / 2、T7 1,082 / 6.44 / 0 / 0、T8 886 / 6.25 / 0 / 1、T9 835 / 5.12 / 0 / 0、F1 969 / 4.70 / 0 / 0。
verify: round 1 833 s / USD 17.81（サブエージェント 2 本）、round 2 325 s / USD 5.59（0 本）。

- 権限拒否（permission_denials）: なし（14 ターンすべて `[]`）
- 無進捗の試行: 0。`attempt > 1` の行: 0（`turn-NNN-attempt2.log` も無い）。`.limit_retry` / `.retry` は 0
- 利用枠（rate_limit.five_hour）: 0.16 → 0.71（1 マイルストーンで 5 時間枠の 55 % を消費。Phase 1 / 2 は約 40 %）
- 計画タスク数 / impl ターン数: **9 / 10**（T1〜T9 が 1 タスク 1 ターン + 差し戻し F1 の 1 ターン）
- verify 差し戻し: **1 回**（round 1 の指摘 1 件 = F1 `decode_numeric` の正規化後 weight wrap + 字句 3 件。round 2 で合格、新規指摘 0）/ BLOCKED: 0 回（`git log --all -- .gsd-lite/BLOCKED.md` は空）
- やり直し（PROGRESS の欄）: research 4 / plan 0 / T1〜T4 各 0 / T5 1 / T6 0 / T7 1 / T8 0 / T9 0 / verify r1 1 / F1 0 / verify r2 0 = **計 7 回**（Phase 2 は 6 回。うち impl は 2 回、Phase 2 は 1 回）
- PLAN 訂正（impl が実測で書き換えた件数）: turn 3 2 件 / turn 4 4 件 / turn 5 4 件 / turn 7 1 件 / turn 8 1 件 / turn 11 1 件 = **13 件**（Minus 1・2）
- Phase 2 との比較: 10 ターン / 181 分 / USD 110.57 / +9,740 行 → 14 ターン / 263 分 / USD 164.07 / +15,403 行。差分量 1.58 倍・テスト数 2.7 倍をコスト 1.48 倍で。impl 1 ターンあたり USD 10.78 → 11.21
- 前回の提案の反映（REQ §9 と PLAN「メモ」の反映表 + 記録で照合）:
  - 守られた（11 件）: 1 持ち越し整理を T1 に（turn 3、REQ §6 の 10 件）／2 REQ §5.1a の訂正（D6、REQ §7）／3 「要実測」+ research が REQ を直す権限（D7。turn 1 で REQ 本文 5 箇所を訂正）／4 `|implicit ROLLBACK failed` の機械化（T1 (b)、turn 3 陽性対照で 1 / 0 を確認）／5 期待メッセージ 2 語以上（決めた事項 12、turn 8 (c)）／6 PROGRESS「確認済み / 未確認」+ 単位（turn 3〜14 のすべてで分離済み）／7 RESEARCH §0.5 への転記（RESEARCH 45 行目 §0.5 に ★ / ☆ 印）／8 非対称を突くプローブ（zero-copy の陽性対照 `probe-zerocopy-neg6`、PLAN メモ）／9 サブエージェント推奨本数の明記（PLAN 全タスクに記載。実本数は上の表）／10 最初の 1 本をコンパイルしてから（turn 1「probe-binary をコンパイルしてから残りを書いた」）／12 +83 ページは D4 (a) に決定 → T1 (h)
  - 部分的に守られた（1 件）: 11 ツール側 — turns.jsonl に `started_at` / `finished_at` が入った（14 行すべて非 null）。サブエージェント込みのトークン記録は未対応（`usage` は親だけ。Interesting 1）
  - REQ §9「reflect: `cost_usd` とサブエージェント本数の相関を確認する」: 下の Interesting 2 で実施

## Plus（うまくいったこと）

- **差し戻し 1 回・リトライ 0・権限拒否 0・BLOCKED 0 で 14 ターン完走し、9 タスクが 9 ターンちょうど + 修正 1 ターンで終わった**（根拠: turns.jsonl 全行 `attempt: 1` / `progressed: true`、コミット列 T1〜T9 / F1 各「コード 1 本 + 申し送り 1 本」の 2 コミットで粒度が揃っている）
- **親が PG17 の `*_send` で期待値の原本を取り直す手順が 3 ターン連続で効き、PLAN の誤り 1 件と RESEARCH の省略 2 件を埋めた**（根拠: turn 7 想定外 (1) time `24:00:00` の hex が PLAN で誤り・33 値を取り直して発見／turn 5 想定外 (4) RESEARCH §2.2.2 の `...` 省略行を 23 値取り直し・手計算と完全一致／turn 8 想定外 (3) RESEARCH に無い timestamp 下限値を実測）。原本 SQL は `scratch/turn-007-wire.sql` に残っている
- **サブエージェント並列（T2 3 本・T3〜T6 各 2 本）の統合で親側の修正が 0 回**（根拠: turn 4「親の統合でも修正は不要」、turn 5 / 6 / 7 / 8 の同欄。`fmt` の整形のみ）。対象ファイルを重ならせず、契約（決めた事項の番号）を貼る依頼文の形が Phase 2 に続いて機能した
- **陽性対照 3 本（T1 (b) grep、T7 (c) コンパイルエラー 3 本、T8 (b) `PQclear` 除去）がすべて同ターンで実測・記録され、verify が round 1 / 2 で T7 の対照を再実行して現 HEAD でも成立を確認した**（根拠: turn 3 の 1 / 0、turn 9 の `use of uninitialized value 'result'` 3 本、turn 10 の `grew 67281 pages` 2 本、VERIFICATION §0 表「T7 陽性対照」）
- **verify round 1 の格子プローブ（約 230,000 呼び出し、クラッシュ 0）が本物の欠陥 F1 を見つけ、コードレビュー・セキュリティチェックと独立 3 経路で一致した**（根拠: VERIFICATION §3・§4-1、turn 12 想定外 (3)）。しかも F1 は impl が turn 5「未確認」で挙げていた項目と同一で、申し送りを verify が最初に読んで格子に入れた（Minus 2 の裏面）
- **verify round 2 を「round 1 の格子の再確認 + 差分の回帰」に限定する規則（REQ §9）が 325 s / USD 5.59 で済ませた**（根拠: turns.jsonl turn 14。round 1 の 833 s / USD 17.81 の 1/3）。マイルストーン全体で最安のターン
- **既存テストの期待値変更がマイルストーン全体で 1 件だけ**（根拠: turn 3「`find("3")` / `find("1")` → `find("takes 3 parameters, got 1")`」、turn 4〜13 の同欄はすべて「なし」、VERIFICATION §2.1）。`result_format` の既定 TEXT による後方互換が verify の照合で裏づけられた
- **ベンチが REQ §4.6 の目的を数値で示した**（根拠: turn 10 / 11 の `pixi run bench`。text total 75〜80 ms / binary 47〜48 ms、decode は 33〜35 → 8〜9 ms の約 4 倍）。turn 1 の素の libpq プローブ（text 41〜45 / binary 36〜39 ms）と同傾向
- **research が D7 で REQ 本文を 5 箇所訂正し、plan は RESEARCH §3 の 11 件を採否表、§4 の 30 件を対応表にして「対応先の無い落とし穴は無い」まで詰めた**（根拠: turn 1「やったこと」末尾、PLAN「メモ」の 2 表）

## Minus（問題・無駄・やり直し）

- **PLAN「追従先チェックリスト」の grep 期待値が 4 件誤っていた**（根拠: turn 3 想定外 (2) `grep -rn 'is Phase 3'` は該当文が行送りされ変更前でも 0 件／turn 4 想定外 (3) `^def decode_` が `decode_binary` 自身を数え落とし 14 → 15／turn 5 想定外 (3) `@implicit` が docstring 行も数え 35 → 36／turn 11 想定外 (2) `bench_formats` のコメント行を拾って FAIL）。原因の見立て: plan がそのコマンドを現在の木で実行せずに期待値を書いた（4 件とも「現在値」を 1 回打てば判明する種類）。いずれも impl が同ターンで直したので手戻りは PLAN 訂正 4 件分だが、T9 (b) で初めて全行がスクリプト化された（`turn-011-checklist.sh`）。plan 時点でスクリプトになっていれば impl が毎ターン回せた
- **F1（numeric の正規化後 weight wrap）は impl が turn 5 で「未確認」と挙げ、T6 と verify に判断を委ねたまま 6 ターン通過し、T9 の総点検でも「decode 側は weight が Int16 の生フィールドなので範囲外が作れず」と誤って処分された**（根拠: turn 5 未確認「`_from_parts` は weight が `Int16.MIN` でかつ先頭ゼログループがあるとき stripped weight が wrap する」、turn 11 §5.2「範囲外 weight」の行、VERIFICATION §4-1）。差し戻しの 3 ターン（verify r1 の一部 + F1 969 s + r2 325 s）で約 22 分 / USD 10.3（F1 + r2）、round 1 を含めれば 35 分 / USD 28.1。原因の見立て: 「未確認」の処分先が「T6 か verify の判断」と二重で、どちらも自分の担当と読まなかった。T9 (c) の「対応先の無い項目を足す」は REQ の項目単位で見て、PROGRESS の「未確認」行を 1 行ずつ処分する手順が無かった
- **verify round 1 が字句の指摘でコメント行だけを名指しし、同じ関数の docstring / エラーメッセージ / テスト docstring を見なかったため、同型 3 件が残留リスクとして次マイルストーンに持ち越しになった**（根拠: turn 13 未確認「契約外の提案」3 件、turn 14 想定外 (2)、VERIFICATION §5 先頭）。差し戻すと 2 ターン使うので合格にした判断は妥当だが、round 1 で `grep -n '1073741823\|client_encoding'` を 1 回打っていれば F1 (c) に同梱できた
- **PLAN の所要見積もりが前回と同じ向きに過大だった**（根拠: turn 3 想定外 (3)「`check` 2〜3 分 / `test` 7〜8 分」→ 実測 113 s / 約 200 s。PLAN 訂正）。Phase 2 reflect Minus 4 と同じ型（+10 s の SET 往復を体感差と見積もった）。`check` は T1〜F1 の 10 ターンで 112〜143 s に収まり、PLAN「3 分を超えたら書く」の閾値に一度も届かなかった
- **turn 6 の turns.jsonl 記録が壊れている（ツール側）**（根拠: `usage.output_tokens` 188 / `num_turns` 1 / `cache_read` 244,154 なのに `cost_usd` 21.75 で impl 最高額。`turn-006-attempt1.log` 末尾「That was a leftover wait-timer from before the sub-agents reported; no action needed.」、生 jsonl の最終 `result` は `result_index: 5` で `modelUsage` は出力 153,239 / キャッシュ読み 29,031,355 / `subagent_stats.spawned: 2`）。原因の見立て: ループが**最後の `result` イベント**から `usage` / `num_turns` を取っており、サブエージェント完了通知で再起動したごく短い応答の値を拾った。`cost_usd` は累積なので正しい。前回 Minus 6（`usage` がサブエージェント分を含まない）も未解消
- **PROGRESS.md が 82 KB（373 行、約 36k トークン）、PLAN.md が 87 KB に膨らみ、impl の各ターンが毎 API 呼び出しでこれを読み直している**（根拠: `wc -c`、turns.jsonl のキャッシュ読み turn 3 16.8M / turn 5 15.4M（親だけの値）。turn 11 の受け入れ基準対応表 32 行と追従先チェックリスト表 14 行が PROGRESS 1 ターン分で 70 行）。実害は確定できないが（Interesting 3）、1 ターンのキャッシュ読み 5〜17M トークンの大半はこの 4 ファイルの再読込と推測される
- **研究プローブのやり直し 4 回のうち 3 回は Mojo 1.1.0 の ctor / 添字の名前違い**（根拠: turn 1 やり直し欄: `Span(ptr=)` → `unsafe_ptr=`、`String(bytes=)` → `from_utf8=`、`p[i]` deprecated、`s[0:4]` / `rjust`）。前回提案 10「最初の 1 本をコンパイルしてから」は守られたが、2 本目以降も別の ctor で 1 回ずつ落ちた。RESEARCH §0.5 に無かった名前なので転記の効果は及ばない

## Interesting（気づき・意外だったこと）

- **turns.jsonl の `usage` は 2 種類の欠けを持つ**（根拠: Minus 5。turn 6 の `modelUsage` 出力 153,239 と turns.jsonl 188 の差、他ターンの `usage` にサブエージェント分が無いこと）。出力トークンあたりのコストが turn 4 で USD 0.89 / 1k（出力 14,836 / USD 13.28）、turn 9 で USD 0.18 / 1k（35,517 / USD 6.44）と 5 倍の幅になるのはこのため。ターンの重さは `cost_usd` でしか読めない
- **サブエージェント本数とコストの相関（REQ §9 で reflect に依頼された検証）**: 2〜3 本のターン（T2〜T6）は USD 10.77〜21.75（平均 15.7）、0 本のターン（T1 / T7 / T8 / T9 / F1）は USD 4.70〜11.14（平均 6.7）。向きは Phase 2 の推測どおりだが、2〜3 本のタスクは型モジュール新設 + codec + テスト 3〜4 ファイルの大物で、0 本は 1〜2 ファイル完結なので**タスク規模と分離できない**。同じ 2 本でも T6（テスト 2 ファイルのみ）は USD 10.77、T4 は 21.75 で 2 倍の差があり、本数より「親が読む契約と原本の量」が効いている可能性（推測）
- **サブエージェント 0 本のターン同士では親のキャッシュ読みとコストが単調に並ぶ**（根拠: turn 3 16.8M → USD 11.14、turn 9 8.4M → 6.44、turn 10 8.5M → 6.25、turn 11 6.0M → 5.12、turn 13 6.4M → 4.70）。推測: 0 本のターンのコストはほぼ親の文脈再読込で決まる。Minus 6 の PROGRESS / PLAN の肥大がここに乗る
- **impl は PLAN の推奨本数から 2 回とも下方に外れ、理由を書いていた**（根拠: turn 3「A と親の対象ファイルが重なるため」推奨 1 → 0、turn 10「並列サブ作業が 1 つなので自分で順に実装」推奨 1 → 0）。どちらも Phase 2 reflect Interesting 1 の「1 ファイル完結・実行待ち支配なら 0 本」と同じ判断で、コストは 11.14 / 6.25
- **T9 の総点検は「REQ の項目に対応先があるか」では網羅できたが、自分の過去ターンの「未確認」を誤って処分した**（根拠: Minus 2）。対応表は 32 行あって VERIFICATION §2 がそのまま使った（Plus）。一方、impl が自分の懸念を「生フィールドの範囲」で考え直して「作れない」と結論したのは、懸念の主語（正規化後の weight）と違うものを見ていた
- **verify の「修正後にファズで期待される変化」は BAD 行ではなく `ok / err` の集計に出た**（根拠: turn 14 想定外 (1)。round 1 の weight wrap は `String()` → 再 parse → `==` の往復が wrap 値同士で一致するため `ok` 側に数えられていた。BAD 72 行は dscale クラスで不変、crafted の `ok 6230 → 6224`）。round 1 の VERIFICATION が「71 件」と書いていたのも数え間違いで、round 2 が訂正した
- **ターン間の申し送りの誤りは 1 件に減った**（根拠: turn 11 想定外 (3)「型マッピング表はまだ Phase 1 の 8 型のまま」（turn 10 の申し送り）は実物では 17 型まで足されていた。Phase 2 は 3 件）。「確認済み / 未確認」の分離（前回提案 6）の効果と読める。残った 1 件は「未確認」側に書かれていた
- **Mojo 1.1.0 / PG の新しい落とし穴 7 件が impl / verify 中に見つかり、RESEARCH §0.5 に無かった**（根拠: turn 4 (1) `Span[UInt8]` は origin 無しで推論不能・`[origin: ImmOrigin, //]` が必須／turn 4 (2) `(-0.0)::float8` は numeric リテラルで負のゼロにならない／turn 5 (1) `@fieldwise_init` が正規化を飛ばす公開 ctor を生む／turn 7 (3) `Copyable` だが `ImplicitlyCopyable` でない型は `List` から `.copy()` が要る／turn 9 (2) `List[Int](-1, a, b)` の可変長 ctor は不可、角括弧リテラルで／turn 9 (3) 実引数の `String("...").as_bytes()` は一時オブジェクト由来／turn 12 (2) モジュールレベル `var` は不可）。研究プローブ 11 本でも届かない種類
- **TestSuite に skip API が無く、PG17 / PG14 分岐テスト 2 件は非該当サーバーで早期 return して PASS 表示される**（根拠: turn 8 想定外 (5)、VERIFICATION §5）。「走っていないのに緑」が集計上は見えない。`test_timestamp_params_round_trip` の非 UTC 分岐も CI で一度も走っていない（turn 8 / 11 / VERIFICATION §5）
- **`check` の所要は 10 ターンで 112〜143 s に収まり、追加テスト 345 件の寄与は約 30 s**（根拠: turn 3 113 s → turn 13 143 s。サーバー不要の単体テストは各 25〜140 ms で、所要は接続あたり 3〜7 s のサーバーテスト（turn 9）が支配）
- **loop.log の記録と turns.jsonl は一致するが、loop.log は 3 マイルストーン分が連続して残っている**（根拠: `loop.log` 1〜41 行 Phase 1、42〜68 行 Phase 2、69 行以降 Phase 3。Phase 2 reflect Interesting 8 と同じ）

## 次回への提案（実行可能な形で）

- [ ] **次マイルストーンの T1（持ち越し整理）に VERIFICATION §5 の先頭 2 項目を 1 コミットで入れる**: (1) `params.mojo:643` docstring Raises と `:670` のメッセージ「libpq takes at most 1073741823」→ 上限は PG 側（`MaxAllocSize` 1 GB）の言い方に、(2) `tests/test_connection.mojo:954` の「libpq takes `client_encoding` from the environment」→ 既定は `server_encoding` / `PGCLIENTENCODING`、(3) `decode_timetz` に時刻部 0..86400000000 の範囲検査（`decode_time` と同じ `_binary_value_error`）、(4) `test_timestamp_params_round_trip` の非 UTC 分岐を `options='-c TimeZone=Asia/Tokyo'` の専用接続で 1 ケース回す（または分岐を消す）（Minus 3、Interesting 9）
- [ ] **plan: 追従先チェックリストは表ではなく最初から実行可能なスクリプト（`.gsd-lite/logs/<slug>/scratch/turn-002-checklist.sh`）として書き、plan ターンでそれを現在の木で 1 回実行して「現在値」を各行に記録する**。期待値は「現在値 + 差分」で書く。impl は各ターンの完了基準に「スクリプトを実行し自タスクの行が期待値に到達」を含め、T9 相当の総点検は再実行だけにする（Minus 1。4 件の誤りはすべて「現在値を 1 回打てば判明」する種類で、turn 11 でスクリプト化したら 32 件 green だった）
- [ ] **impl: PROGRESS「未確認」で「誤った値が黙って返る経路」を述べる行は、同ターンでテスト 1 件（期待は `TYPE_MISMATCH` か成功のどちらかを明記）にするか、PLAN の該当タスクに「(x) この行を処分する」を追記する。処分先を「T6 か verify の判断」のように二重に書かない**。最終タスク（T9 相当）の完了基準に「PROGRESS の全『未確認』行を列挙し、各行を テスト追加 / 契約外と明記 / verify 申し送り のいずれか 1 つに振り分けた表」を入れる（Minus 2。F1 の差し戻し 3 ターン = 約 35 分 / USD 28）
- [ ] **verify: 字句の指摘はクラスで名指しする**。文言を 1 箇所指摘したら、同じキーワードを `grep -rn` でリポジトリ全体から列挙し（コメント・docstring・エラーメッセージ・テスト docstring）、F 項目に全部を同梱する（Minus 3。round 1 がコメント 1 行だけ名指しして同型 3 件が持ち越しになった）
- [ ] **verify: 差し戻し時の「修正後にプローブで期待される変化」は BAD 行の増減ではなく、集計値を「どの数がいくつからいくつへ」で書く**（例「crafted の `ok 6230 → 6224`」）。round 2 はその数だけ照合する（Interesting 6）
- [ ] **plan: 所要見積もりは「前マイルストーン末の実測 + 新テスト 1 ファイルあたり接続数 × 3〜7 s」で書き、往復 1 回あたりの差（ms 単位）を分単位の見積もりに足さない**（Minus 4。Phase 2 / 3 で 2 回連続過大。`check` は 10 ターン 112〜143 s）
- [ ] **impl: PROGRESS 1 ターン分の申し送りは 40 行を上限とし、受け入れ基準対応表・チェックリスト表のような 30 行超の表は `$MS/` 配下の別ファイル（例 `TRACE.md`）に置いて PROGRESS からはパスと行数だけ書く**。verify はそのファイルを読む（Minus 6、Interesting 3。PROGRESS 82 KB / PLAN 87 KB を impl の全 API 呼び出しが読み直している。D18 によりスキルは変えないので REQ §9 に書く）
- [ ] **research: RESEARCH の期待値表は `...` で桁を省略しない。長い値は全桁か、原本を取った SQL と出力ログのパス（`scratch/turn-001-*.log`）を同じ行に書く**。plan は hex 期待値を RESEARCH のログからコピーし、手で計算・転記しない。impl への申し送り「親が `*_send` で原本を取り直す」（turn 5 / 7 / 8 で 3 回効いた手順。原本 SQL は `scratch/turn-007-wire.sql`）は次 PLAN にも常設する（Plus 2、turn 5 想定外 (4)、turn 7 想定外 (1)）
- [ ] **次マイルストーンの RESEARCH §0.5 に今回の落とし穴 7 件を追加する**: `Span[UInt8, origin]` は `[origin: ImmOrigin, //]` 前置が必須／`(-0.0)::float8` は numeric リテラル経由で `'-0'::float8` と書く／`@fieldwise_init` は全フィールドの公開 ctor を生む（Mojo に可視性制御なし）／`ImplicitlyCopyable` でない型は `List` 要素を `.copy()`／`List[T](a, b, c)` 可変長 ctor 不可、`[a, b, c]` リテラルで／実引数の `String(...).as_bytes()` は一時オブジェクト由来の span／モジュールレベル `var` 不可（`struct State` を `mut` で渡す）（Interesting 8）
- [ ] **discuss: TestSuite に skip が無い問題の扱いを決める**: (a) 分岐テストは名前（`_on_pg17_and_later` / `_before_pg17`）で判別する現状維持、(b) 早期 return の前に `print("SKIP <name>")` を出し `run_tests.sh` がサーバー別に SKIP 件数を集計する 10 行の変更。推奨は (b)（「走っていないのに緑」が 2 件 + 非 UTC 分岐 1 件あり、集計で見えないままになっている。Interesting 9）
- [ ] **plan: サブエージェント推奨本数の判断に「テストのみ 2 ファイル」の型を足す**: T6 型（`src/` を触らずテスト 2 ファイル）は 2 本で USD 10.77、T4 型（型モジュール + codec + テスト）は 2 本で 21.75。次回は T6 型を 1 本（親がもう 1 ファイルを書く）で試し、reflect が USD を比べる。impl は PROGRESS「やったこと」に「推奨 N 本 / 実 M 本」を 1 語で書き、reflect が生ログを掘らずに済むようにする（Interesting 2・4）
- [ ] **ツール側（マイルストーン間にユーザーが行う）**: `gsd-lite-loop.sh` の `usage` / `num_turns` 取得を「最後の `result` イベント」から「`result` のうち `num_turns` 最大のもの（または `modelUsage` の合計）」に変え、`subagent_stats.spawned` を turns.jsonl に `subagents` として記録する（Minus 5、Interesting 1。turn 6 が 188 トークン / 1 turn と記録された）。`finished_at` の追加は反映済み（前回提案 11）
