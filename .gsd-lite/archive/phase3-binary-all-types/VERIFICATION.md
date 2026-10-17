# VERIFICATION — phase3-binary-all-types

- 作成: 2026-10-17 / gsd-lite-verify（turn 12 = round 1、turn 14 = round 2 で更新）
- 対象: `git diff main...HEAD`（`e60b46f` 起点、23 コミット + 本ターン。`src/` `tests/` `examples/` `pixi.toml` で 42 ファイル）
- 対象リポジトリの `CLAUDE.md` / `AGENTS.md`: 無し（規約観点は HANDOFF.md §4・§6 と PLAN「決めた事項」1〜14）
- 判定: **round 2 = 合格**（round 1 の指摘 F1 は修正済みで回帰なし。新しい指摘 0 件）。リモート無しのため `main` へ `--no-ff` でローカルマージ
- 実行エンジン: Claude Code（Claude Fable 5.1）

## 0. round 2（turn 14）の結果 — 「round 1 の格子の再確認 + F1 差分の回帰」のみ

round 1 以降の差分は `b185a69..HEAD` の 6 ファイル（`decode_binary.mojo` +25 / `types_numeric.mojo` docstring +6 / `params.mojo` コメント / `result.mojo` docstring / `__init__.mojo` docstring / `test_decode_binary.mojo` +19）で、PLAN F1 の対象ファイルと一致。コードの変更は `decode_numeric` の 1 箇所だけ。

| 確認 | 結果 |
|---|---|
| F1 (a) `decode_numeric` の正規化後 weight 検査 | digits を読み終えた後・`_from_parts` の前に先頭ゼロ群 `lead` を数え、`Int(weight) - lead < Int(Int16.MIN)` で `_binary_value_error("numeric", "weight <stripped> out of range after stripping <lead> leading zero groups")`。`_from_parts` はコード無変更（docstring に呼び出し側の責務）。PLAN の表 4 行と一致（境界 -32768 は成功、-32769 / -32770 は `TYPE_MISMATCH`） |
| F1 (b) テスト | `test_numeric_rejects_weight_underflow_after_strip` が表の 2〜4 行目を 1 関数で（`_ok[Decimal]` の `==`、`_assert_numeric_rejected`、message に `"weight"`）。`grep -c '^def test_' tests/test_decode_binary.mojo` = 78。既存 `test_numeric_minimum_weight_decodes` は無改変で PASS |
| F1 (c) 字句 3 件 | `params.mojo` コメント（1 GB は PG 側の上限、`c_int` は 0x7FFFFFFF まで wrap しない）/ `result.mojo` `get_text` (3) / `__init__.mojo` Zero-copy 節: いずれも「`pq` は `client_encoding` を設定しない」「libpq の既定は `server_encoding` / `PGCLIENTENCODING`」「UTF-8 は検証しない」の 3 点を含む |
| 既存テストの期待値の変更 | 0 件（impl 申告どおり。diff で確認） |
| round 1 の格子の再確認: ファズ probe | `turn-012-fuzz.mojo` を現 HEAD で再ビルド（`turn-014-fuzz`）して再実行。`FUZZ DONE`・クラッシュ 0。`BAD` 行は round 1 と**完全一致**（72 行、すべて dscale < 実桁の非正規化 numeric クラス。round 1 の「71 件」は数え間違いで正しくは 72）。crafted numeric の集計だけが `ok 6230 / err 41825` → **`ok 6224 / err 41831`** に変わり、weight underflow クラスの 6 入力が「黙って成功」から `TYPE_MISMATCH` に移った。他の格子（テキスト parser 8 種 182,304 呼び出し・バイナリ decoder 45,100 呼び出し・生 ctor 極値）は出力が round 1 と同一（`diff` で非 BAD 行も 1 行の集計差のみ） |
| round 1 の格子の再確認: 追従先チェックリスト | `turn-011-checklist.sh` 再実行 → 32 件 OK、不一致 0（ログ `turn-014-checklist.log`） |
| round 1 の格子の再確認: T7 陽性対照 | `turn-009-zerocopy-neg.mojo` が現 HEAD でも `:21:14: error: use of uninitialized value 'result'` で停止 |
| 最終判定コマンド | `pixi run check` をクリーンな作業木で実行: **6/6 PASS**（`final_check: PASS`、1/6 fmt no diff、3/6 docstring 診断 0 件、5/6 は 41 ファイル summary 全部 `0 failed`（PG17 21 + PG14 20、54314 の test_leak は `skipped (PQ_TEST_LEAK_SERVERS=1)`）、6/6 `matched lines: 0`。ログ `turn-014-check.log`） |

round 2 で新しいクラスの探索はしていない（REQ §9 / skill の規則）。impl が turn 13 で挙げた契約外の字句 3 件（`params.mojo:643` docstring Raises と `:670` のメッセージ「libpq takes at most 1073741823」、`tests/test_connection.mojo:954` の「libpq takes `client_encoding` from the environment」）は F1 (c) と同型で round 1 で拾い切れなかったもの（round 1 はコメント行だけを名指しし、同じ関数の docstring / メッセージまで見なかった）。
文言だけで誤動作を伴わず、差し戻すと impl + verify の 2 ターンを文言に使うことになるので、§5 の残留リスク（次マイルストーンの持ち越し整理）に回して合格とする。

## 1. round 1 の進め方

- 並列レビュー（`subagents: auto`）: コードレビューとセキュリティチェックを**読み取り専用**のサブエージェント 2 本に分け、
  REQ §4 / §5 と PLAN「決めた事項」を渡して並行。テスト実行・判定・文書更新は親だけ
- 親は同時に (1) クリーンな `pixi run check`、(2) 堅牢性の格子プローブ（下記 §3）、(3) 追従先チェックリストの再実行、
  (4) T7 の陽性対照の再実行、(5) 文書の主張の照合を行った
- round 2 はサブエージェントを使わず親だけで回帰確認（差分が 1 関数 + docstring なので読み取りで足りる）

## 2. 受け入れ基準との突き合わせ

REQ §5.1 / §5.2 / §5.4 の各項目には PROGRESS turn 11「受け入れ基準 → テスト対応」の格子で対応先がある。
その格子のテストが実際に基準を検証していることをコードレビュー側がスポットチェック（`test_rejects_weight_over_limit` /
`test_numeric_minimum_weight_decodes` / `test_timetz_zone_sign_follows_postgres` / `test_slice_survives_a_keep_alive_marker` /
`test_binary_execute_does_not_leak` / `test_zero_copy_does_not_leak`。いずれも存在し、主張どおりの assert）。
期待値は実装の出力ではなく PG17 / PG14 の `*_send` 実測 hex と `::text` 出力から取られている（自己言及的な assert は無し）。

| 基準 | 確認 |
|---|---|
| §5.1 全型の text / binary 一致・境界値 | `pixi run check` 5/6 段で両サーバー 21 ファイル全 PASS（PG17 / PG14 とも `0 failed`。round 1 ログ `turn-012-check.log`、round 2 ログ `turn-014-check.log`） |
| §5.1 未対応 OID / 非文字列 OID の `get[String]` / 非 bytea の `get[List[UInt8]]` → `TYPE_MISMATCH` | `test_binary.mojo` 7 列 × 3 型 = 21 セル + 単体。ファズ（§3）でも kind は常に `TYPE_MISMATCH` |
| §5.1 `column_format(i)` | `test_binary.mojo` 3 件 |
| §5.1 拡張型 8 種の `$1` 往復（両形式） | `test_extended_numeric.mojo` / `test_extended_datetime.mojo` 7 件 |
| §5.1 `SHOW DateStyle` = `ISO, YMD` | `test_connection.mojo` 3 件（`open(String)` / `open(Dict)` の両方） |
| §5.1 ベンチが実行でき所要を表示 | turn 11 実測: text total 75〜80 ms / binary total 47〜48 ms（decode 33〜34 → 8 ms） |
| §5.1 zero-copy の値一致 + 消費する移動の後はコンパイルエラー | `test_zero_copy.mojo` 11 件 + 陽性対照 `turn-009-zerocopy-neg.mojo`（round 1 / round 2 とも `error: use of uninitialized value 'result'`） |
| §5.2 長さ不足 / 不正 uuid 長 / 不正 ndigits / jsonb 未知バージョン / 非 ISO / NULL / 空結果 / 切断後 | 単体 + サーバーテスト（turn 11 の格子）+ §3 のファズで **クラッシュ 0** |
| §5.2 **範囲外 weight** | round 1 で取りこぼし 1 件（F1）→ **round 2 で修正を確認**（`test_numeric_rejects_weight_underflow_after_strip` + ファズの crafted 6 入力が `TYPE_MISMATCH` に移動） |
| §5.2 `PQclear` / `PQfinish` / `PQfreemem` の呼び出しと二重解放なし | `test_leak` 14 件（check 5/6 段で PG17、RSS 完全フラット）、`_adopt` の SET 失敗経路はコードレビューで単一 `PQfinish`（`__deinit__`）を確認、`PQexec(` 4 行 / `PQfreemem(` 2 行から増えていない |
| §5.2 解放済みポインタへのアクセスが型・所有権の上で起こらない | `grep -rn -- '-> ref' src/pq/*.mojo` = 0、origin は `Row` → `Result` の borrow、一時オブジェクト由来の slice を返す経路なし（セキュリティチェック） |
| §5.2 10,000 回の binary execute でメモリ単調増加なし | `test_binary_execute_does_not_leak` / `test_zero_copy_does_not_leak`（turn 10 の陽性対照で `PQclear` 除去版が FAIL） |
| §5.4 docstring / fmt / `examples/binary.mojo` / `package` / `check` 6/6 | `pixi run check` **6/6 PASS**（1/6 fmt 差分なし、2/6 precompile、3/6 docstring 診断 0 件、4/6 examples 3 本、5/6 tests、6/6 `matched lines: 0`） |

### 2.1 文書の主張

- PLAN「追従先チェックリスト」全 14 行 = 32 検査を `turn-011-checklist.sh` で再実行: round 1 / round 2 とも不一致 0 件
- `src/pq/__init__.mojo` の型マッピング表（19 行）・Parameters 表・`## Result format` / `## Zero-copy access` 節を実装と読み合わせ: 矛盾なし。
  `params.mojo` 冒頭「Thirty-five `@implicit` constructors」= 実 ctor 数 35（grep は docstring 行込みで 36。PLAN turn 5 訂正どおり）
- `tests/test_leak.mojo` の「Fourteen tests」/ `TOLERANCE_PAGES = 256` / glibc arena の注記: 一致
- 「既存テストの期待値の変更」は milestone 全体で 1 件のみ（`tests/test_prepared.mojo` の `find("3")` / `find("1")` → `find("takes 3 parameters, got 1")`。緩い検査を厳しくしただけで意図どおり）。F1 でも 0 件
- 字句の不正確さ 3 件は F1 (c) で修正済み（§4-2〜4）

## 3. 堅牢性の格子プローブ（round 1 で一括。round 2 は同じ probe を再ビルドして再確認のみ）

`scratch/turn-012-fuzz.mojo`（サーバー不要、`mojo build` 済み。round 1 ログ `turn-012-fuzz.log`、round 2 ログ `turn-014-fuzz.log`）:

| 入力経路 | 格子 | 件数 | 結果 |
|---|---|---|---|
| テキスト parser 8 種（`Date` / `Timestamp` / `TimestampTz` / `Time` / `TimeTz` / `Interval` / `Decimal` / `UUID`） | 37 seed × {全 prefix / 全 suffix / 1 byte 削除 / 16 種の異常 byte（NUL・空白・`+`・`-`・`:`・`.`・`z`・0xFF・0xC3 先頭 byte・LF・`B`・`C`・`T` 等）で置換・挿入・末尾付加 / 2 倍化} + 長大入力 40 件（20 万桁 / 131,080 桁 / 16,384 桁小数 / 1,000 桁小数秒 / 11 桁日数 / 1,000 連続の空白・符号・区切り / `infinity BC` 等） | 22,788 入力 × 8 = **182,304 呼び出し** | **クラッシュ 0・kind の取り違え 0・往復不一致 0**（成功 2,152 / `TYPE_MISMATCH` 180,472）。`Decimal` / `UUID` は ctor（`USAGE`）と `parse`（`TYPE_MISMATCH`）の受理集合が一致。round 2 も同一 |
| バイナリ decoder 16 種 + OID 不一致 | 長さ 0〜40 × {0x00 / 0xFF / 0x80 / 0x7F / 0x01 / 0x40 / 0xC0 / 0xD0 / 0xF0 埋め・昇順・LCG 乱数 40 本} = 50 パターン/長さ、× 22 (T, OID) 組 | **45,100 呼び出し** + crafted numeric 3,027（ndigits 0〜5 × sign 7 値 × weight 9 値 × dscale 8 値 + 負の ndigits + 巨大 ndigits + 先頭ゼロ群 × `Int16.MIN`） | **クラッシュ 0・kind の取り違え 0**。成功値は `String()` → 再 parse → `==` と encode → decode → `==` の 2 往復を通し、不一致は numeric の **dscale が実桁より小さい非正規化 wire 値の 72 件だけ**（`String()` は一致するが `==` が真にならない。PG の `numeric_recv` も同じ入力を `trunc_var` で切り捨てる。サーバーは送らない）。round 1 で見つかった weight wrap クラス（§4-1）は round 2 で 6 入力とも `TYPE_MISMATCH` に移動（crafted の `ok 6230 → 6224`） |
| 生 ctor の極値 → `String()` / アクセサ（decode が範囲検査しない型 = サーバーが送れば到達する） | `Date(Int32.MIN+1 / MAX-1 / PG 範囲 ±1)`、`Timestamp` / `TimestampTz(Int64.MIN+1 / MAX-1 / PG 範囲 ±1)`、`Time` / `TimeTz(-1 / 86400000001 / Int64.MAX / Int64.MIN)`、`TimeTz` zone `Int32.MIN / MAX / ±57600 / 3661`、`Interval(Int64.MIN, Int32.MIN, Int32.MIN+1)` 等 6 値、`Decimal` 1e131071 / 1e-16383 | 約 40 | **クラッシュ 0**。PG 範囲外の値は PG が印字しない文字列（`-19:59:59.999999`、`+596523:14:08`）になるが例外・abort は無い。`Interval` の `Int32.MIN` 月 / `Int64.MIN` µs は往復一致、`Decimal` の両極も 2 往復一致。round 2 も同一 |
| 出力経路（stdout / stderr の fd） | ライブラリなので該当なし。`examples/` 2 本は `check` 4/6 段と `pixi run bench` で実行確認（turn 11） | — | — |
| 例外の親クラス | `PgError` 6 kind のまま（`errors.mojo` 無変更）。ファズで観測した kind は `TYPE_MISMATCH` / `USAGE` のみ | — | — |

補足: turn 8 の未確認「timetz の最大西 / 最大東のサーバー往復」は PG17 `timetz_send` で実測し、`0000000a0eebb000 0000e0c4`（`12:00:00-15:59` → 57540）/ `... ffff1f01`（`12:00:00+15:59:59` → -57599）が
`test_decode_binary.mojo:730-733` / `test_types_datetime.mojo:1254-1258` の期待値と一致した。

## 4. 指摘（round 1。すべて F1 で修正済み、round 2 で確認）

1. **`decode_numeric` が正規化後の weight 範囲外を検出しない**（round 1 時点の `src/pq/types_numeric.mojo:253-264`、`src/pq/decode_binary.mojo:389-400`。→ F1 (a)(b)、**修正確認済み**）。
   wire `0002 8000 0000 0000 0000 0001` は各フィールドが個別には範囲内なので全検査を通り、`_from_parts` の `stripped = -32769` が `Int16()` で `32767` に wrap、
   1e-131076 のつもりの値が 1e131068 として**エラー無しで**返っていた。ファズの crafted ケース・コードレビュー・セキュリティチェックの 3 経路で独立に検出。
   impl も turn 5「未確認」で挙げていた。REQ §5.2「範囲外 weight → PgError」/ D3「不正値は PgError」の契約内で、結果が**黙って別の値**になるため差し戻した
   （サーバーは正規化済みの値しか送らないので実害は malformed wire に限る。PG 自身は同じ入力を `value overflows numeric format` で拒否する）
2. `src/pq/params.mojo` コメントの根拠が不正確（`c_int` は 0x7FFFFFFF まで wrap しない。正しい根拠は PG の 1 GB 上限）。→ F1 (c)、修正確認済み
3. `src/pq/result.mojo` `get_text` docstring (3) の `client_encoding` の説明 — libpq の既定は `server_encoding` / `PGCLIENTENCODING` で UTF-8 とは限らない。→ F1 (c)、修正確認済み
4. `src/pq/__init__.mojo` `## Zero-copy access` の同文 — 同上。→ F1 (c)、修正確認済み

## 5. 残留リスク（差し戻さない。要件外か、誤動作・データ損失を伴わない）

- **F1 と同型の字句 3 件（次マイルストーンの持ち越し整理に）**: `src/pq/params.mojo:643` docstring Raises「longer than libpq's `paramLengths` can carry (1073741823 bytes)」と `:670` のエラーメッセージ「libpq takes at most 1073741823」は、
  F1 (c) で直したコメントと同じ「1 GB を `paramLengths` の限界と見る」言い方のまま（上限は PG 側。メッセージの部分文字列を見るテストは無い）。`tests/test_connection.mojo:954` の「libpq takes `client_encoding` from the environment」も既定が `server_encoding` である点が落ちている。
  round 1 でコメント行だけ名指しして同じ関数の docstring / メッセージを見なかったのが原因
- **F1 の検査は PG より 1 ケース厳しい**: 全ゼロ digits で weight が `Int16.MIN` 近傍の非正規化 wire（例 `0001 8000 0000 0000 0000`）は PG の `make_result` が 0 に正規化して受理するが、pq は先頭ゼロ群を数えて `TYPE_MISMATCH` にする。サーバーはゼロを `ndigits 0 / weight 0` で送るので到達しない。エラー側に倒れるだけで誤値にはならない
- **UTF-8 無検証**（`String(unsafe_from_utf8=)` / `StringSlice(unsafe_from_utf8=)`。P20 / 決めた事項 3・9 で意図的）: `SQL_ASCII` のデータベースや偽造 binary セルで末尾が UTF-8 先頭 byte だけの値が来ると、
  **利用者側**の codepoint 走査が slice 末尾を 1〜3 byte 読み越す可能性がある。`pq` 自身は `PQgetlength` の範囲しか読まない。docstring に明記済み（F1 (c) で文言を正確にした）。検証付き `String(from_utf8=)` に切り替えるかは Phase 4 以降の判断
- **`decode_timetz` が時刻部の範囲（0..86400000000）を検査しない**（`decode_time` は検査する）。malformed wire で `-19:59:59.999999` のような PG が印字しない文字列になるが、abort も読み越しも無い（ファズで確認）。PG の `timetz_recv` 自体は範囲検査するので正規のサーバーからは到達しない
- **非正規化 numeric（dscale < 実桁）** は `String()` が PG の `trunc_var` と同じく切り捨てるが `==` は隠れた桁を見る（ファズの 72 件）。サーバーは送らない
- **decode エラーのメッセージにセル全文が入る**（`cannot decode "<text>" as <type>`。Phase 1 からの流儀）: 巨大セルや制御文字入りセルがログに出る
- `encode_numeric` の `UInt16(ndigits)` は 65,536 群以上の `Decimal` を手で組んだときだけ切れる（サーバー側が長さ不一致で拒否。利用者入力のみ）
- `ResultFormat.write_to` は 0 / 1 以外で何も書かない（`PQfformat` は 0 / 1 しか返さない）
- `get_text`（`result.mojo`）と `decode_binary[String]` に jsonb version byte 検査と文字列系 5 OID の判定が 2 か所ある（7 つ目の文字列系 OID を足すときに片方を忘れる余地）。整理は Phase 4 以降
- `tests/test_extended_numeric.mojo` が OID 定数を自前定義（決めた事項 11 の「唯一の置き場」は `src/` の規則なので違反ではない）
- PG17 限定 / PG14 限定のテスト 2 件は非該当サーバーで早期 return して PASS 表示（turn 8 想定外 (5)。名前で判別できる）
- `test_timestamp_params_round_trip` の非 UTC 分岐はコンテナが `Etc/UTC` 固定のため CI で走らない（turn 8 以来の未確認）
- 拡張型の NULL binary と `PreparedStatement` / `Transaction` 経由の binary を**拡張型で**は見ていない（既存 8 型は `test_binary.mojo` が押さえ、経路は同じ `_take_result` / `Row.get`）
- `Decimal` の `@fieldwise_init` が正規化を飛ばせる 4 引数の公開 ctor を生む（turn 5 想定外 (1)。Mojo に可視性制御が無い）

## 6. 計測（単位 s）

- round 1（turn 12）: `pixi run check` 6/6 PASS 約 140 s。ファズ probe ビルド約 40 s・実行約 25 s（約 230,000 呼び出し）。サブエージェント 2 本: コードレビュー約 8 分 / セキュリティ約 5 分
- round 2（turn 14）: `pixi run check` 6/6 PASS = 131 s（1/6〜4/6 計 7 s、5/6 124 s、6/6 0 s。ログの段見出しの時刻差）。ファズ probe 再ビルド + 再実行は round 1 と同程度。サブエージェント 0 本

## 7. マージ

- `git remote get-url origin` → `No such remote 'origin'`（ローカルのみ）→ `git checkout main` → `git merge --no-ff gsd-lite/phase3-binary-all-types`。結果: **衝突なしでマージ成功**（merge commit `15e8a2c`、43 ファイル +15,327 / -2,130）。ブランチ `gsd-lite/phase3-binary-all-types` は削除せず残す。次は `/gsd-lite-reflect`（state の `reflect: true`）
