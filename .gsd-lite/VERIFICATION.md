# VERIFICATION — phase3-binary-all-types

- 作成: 2026-10-17 / gsd-lite-verify（turn 12 = round 1）
- 対象: `git diff main...HEAD`（`e60b46f` 起点、21 コミット、`src/` `tests/` `examples/` `pixi.toml` で 42 ファイル +14,928 / -1,973）
- 対象リポジトリの `CLAUDE.md` / `AGENTS.md`: 無し（規約観点は HANDOFF.md §4・§6 と PLAN「決めた事項」1〜14）
- 判定: **round 1 = 指摘あり 1 件（F1）→ impl へ差し戻し**。合格時にこのファイルを round 2 の結果で更新する

## 1. round 1 の進め方

- 並列レビュー（`subagents: auto`）: コードレビューとセキュリティチェックを**読み取り専用**のサブエージェント 2 本に分け、
  REQ §4 / §5 と PLAN「決めた事項」を渡して並行。テスト実行・判定・文書更新は親だけ
- 親は同時に (1) クリーンな `pixi run check`、(2) 堅牢性の格子プローブ（下記 §3）、(3) 追従先チェックリストの再実行、
  (4) T7 の陽性対照の再実行、(5) 文書の主張の照合を行った
- 実行エンジン: Claude Code（Claude Fable 5.1）

## 2. 受け入れ基準との突き合わせ

REQ §5.1 / §5.2 / §5.4 の各項目には PROGRESS turn 11「受け入れ基準 → テスト対応」の格子で対応先がある。
その格子のテストが実際に基準を検証していることをコードレビュー側がスポットチェック（`test_rejects_weight_over_limit` /
`test_numeric_minimum_weight_decodes` / `test_timetz_zone_sign_follows_postgres` / `test_slice_survives_a_keep_alive_marker` /
`test_binary_execute_does_not_leak` / `test_zero_copy_does_not_leak`。いずれも存在し、主張どおりの assert）。
期待値は実装の出力ではなく PG17 / PG14 の `*_send` 実測 hex と `::text` 出力から取られている（自己言及的な assert は無し）。

| 基準 | 確認 |
|---|---|
| §5.1 全型の text / binary 一致・境界値 | `pixi run check` 5/6 段で両サーバー 21 ファイル全 PASS（PG17 / PG14 とも `0 failed`）。ログ `.gsd-lite/logs/phase3-binary-all-types/scratch/turn-012-check.log` |
| §5.1 未対応 OID / 非文字列 OID の `get[String]` / 非 bytea の `get[List[UInt8]]` → `TYPE_MISMATCH` | `test_binary.mojo` 7 列 × 3 型 = 21 セル + 単体。ファズ（§3）でも kind は常に `TYPE_MISMATCH` |
| §5.1 `column_format(i)` | `test_binary.mojo` 3 件 |
| §5.1 拡張型 8 種の `$1` 往復（両形式） | `test_extended_numeric.mojo` / `test_extended_datetime.mojo` 7 件 |
| §5.1 `SHOW DateStyle` = `ISO, YMD` | `test_connection.mojo` 3 件（`open(String)` / `open(Dict)` の両方） |
| §5.1 ベンチが実行でき所要を表示 | turn 11 実測: text total 75〜80 ms / binary total 47〜48 ms（decode 33〜34 → 8 ms） |
| §5.1 zero-copy の値一致 + 消費する移動の後はコンパイルエラー | `test_zero_copy.mojo` 11 件 + **陽性対照を再実行**: `turn-009-zerocopy-neg.mojo` が現 HEAD でも `error: use of uninitialized value 'result'` で停止 |
| §5.2 長さ不足 / 不正 uuid 長 / 不正 ndigits / jsonb 未知バージョン / 非 ISO / NULL / 空結果 / 切断後 | 単体 + サーバーテスト（turn 11 の格子）+ §3 のファズで **クラッシュ 0** |
| §5.2 **範囲外 weight** | **取りこぼし 1 件（F1）**。正規化後の weight が `Int16.MIN` を下回る wire 値がエラーにならず wrap する（§4-1） |
| §5.2 `PQclear` / `PQfinish` / `PQfreemem` の呼び出しと二重解放なし | `test_leak` 14 件（check 5/6 段で PG17、RSS 完全フラット）、`_adopt` の SET 失敗経路はコードレビューで単一 `PQfinish`（`__deinit__`）を確認、`PQexec(` 4 行 / `PQfreemem(` 2 行から増えていない |
| §5.2 解放済みポインタへのアクセスが型・所有権の上で起こらない | `grep -rn -- '-> ref' src/pq/*.mojo` = 0、origin は `Row` → `Result` の borrow、一時オブジェクト由来の slice を返す経路なし（セキュリティチェック） |
| §5.2 10,000 回の binary execute でメモリ単調増加なし | `test_binary_execute_does_not_leak` / `test_zero_copy_does_not_leak`（turn 10 の陽性対照で `PQclear` 除去版が FAIL） |
| §5.4 docstring / fmt / `examples/binary.mojo` / `package` / `check` 6/6 | `pixi run check` **6/6 PASS**（1/6 fmt 差分なし、2/6 precompile、3/6 docstring 診断 0 件、4/6 examples 3 本、5/6 tests、6/6 `matched lines: 0`） |

### 2.1 文書の主張

- PLAN「追従先チェックリスト」全 14 行 = 32 検査を `turn-011-checklist.sh` で**再実行**: 不一致 0 件（ログ `turn-012-checklist.log`）
- `src/pq/__init__.mojo` の型マッピング表（19 行）・Parameters 表・`## Result format` / `## Zero-copy access` 節を実装と読み合わせ: 矛盾なし。
  `params.mojo` 冒頭「Thirty-five `@implicit` constructors」= 実 ctor 数 35（grep は docstring 行込みで 36。PLAN turn 5 訂正どおり）
- `tests/test_leak.mojo` の「Fourteen tests」/ `TOLERANCE_PAGES = 256` / glibc arena の注記: 一致
- 「既存テストの期待値の変更」は impl 申告どおり 1 件のみ（`tests/test_prepared.mojo` の `find("3")` / `find("1")` → `find("takes 3 parameters, got 1")`。緩い検査を厳しくしただけで意図どおり）。他は追記のみ
- 字句の不正確さ 3 件を F1 (c) にまとめた（§4-2〜4）

## 3. 堅牢性の格子プローブ（round 1 で一括。round 2 は再確認のみ）

`scratch/turn-012-fuzz.mojo`（サーバー不要、`mojo build` 済み。再現は `bash` から実行してログを見る。ログ `turn-012-fuzz.log`）:

| 入力経路 | 格子 | 件数 | 結果 |
|---|---|---|---|
| テキスト parser 8 種（`Date` / `Timestamp` / `TimestampTz` / `Time` / `TimeTz` / `Interval` / `Decimal` / `UUID`） | 37 seed × {全 prefix / 全 suffix / 1 byte 削除 / 16 種の異常 byte（NUL・空白・`+`・`-`・`:`・`.`・`z`・0xFF・0xC3 先頭 byte・LF・`B`・`C`・`T` 等）で置換・挿入・末尾付加 / 2 倍化} + 長大入力 40 件（20 万桁 / 131,080 桁 / 16,384 桁小数 / 1,000 桁小数秒 / 11 桁日数 / 1,000 連続の空白・符号・区切り / `infinity BC` 等） | 22,788 入力 × 8 = **182,304 呼び出し** | **クラッシュ 0・kind の取り違え 0・往復不一致 0**（成功 2,152 / `TYPE_MISMATCH` 180,472）。`Decimal` / `UUID` は ctor（`USAGE`）と `parse`（`TYPE_MISMATCH`）の受理集合が一致 |
| バイナリ decoder 16 種 + OID 不一致 | 長さ 0〜40 × {0x00 / 0xFF / 0x80 / 0x7F / 0x01 / 0x40 / 0xC0 / 0xD0 / 0xF0 埋め・昇順・LCG 乱数 40 本} = 50 パターン/長さ、× 22 (T, OID) 組 | **45,100 呼び出し** + crafted numeric 3,027（ndigits 0〜5 × sign 7 値 × weight 9 値 × dscale 8 値 + 負の ndigits + 巨大 ndigits + 先頭ゼロ群 × `Int16.MIN`） | **クラッシュ 0・kind の取り違え 0**。成功値は `String()` → 再 parse → `==` と encode → decode → `==` の 2 往復を通し、**不一致は numeric の 1 クラスだけ**（§4-1 と、dscale が実桁より小さい非正規化 wire 値で `String()` は一致するが `==` が真にならない 71 件。PG の `numeric_recv` も同じ入力を `trunc_var` で切り捨てる。サーバーは送らない） |
| 生 ctor の極値 → `String()` / アクセサ（decode が範囲検査しない型 = サーバーが送れば到達する） | `Date(Int32.MIN+1 / MAX-1 / PG 範囲 ±1)`、`Timestamp` / `TimestampTz(Int64.MIN+1 / MAX-1 / PG 範囲 ±1)`、`Time` / `TimeTz(-1 / 86400000001 / Int64.MAX / Int64.MIN)`、`TimeTz` zone `Int32.MIN / MAX / ±57600 / 3661`、`Interval(Int64.MIN, Int32.MIN, Int32.MIN+1)` 等 6 値、`Decimal` 1e131071 / 1e-16383 | 約 40 | **クラッシュ 0**。PG 範囲外の値は PG が印字しない文字列（`-19:59:59.999999`、`+596523:14:08`）になるが例外・abort は無い。`Interval` の `Int32.MIN` 月 / `Int64.MIN` µs は往復一致、`Decimal` の両極も 2 往復一致 |
| 出力経路（stdout / stderr の fd） | ライブラリなので該当なし。`examples/` 2 本は `check` 4/6 段と `pixi run bench` で実行確認（turn 11） | — | — |
| 例外の親クラス | `PgError` 6 kind のまま（`errors.mojo` 無変更）。ファズで観測した kind は `TYPE_MISMATCH` / `USAGE` のみ | — | — |

補足: turn 8 の未確認「timetz の最大西 / 最大東のサーバー往復」は PG17 `timetz_send` で実測し、`0000000a0eebb000 0000e0c4`（`12:00:00-15:59` → 57540）/ `... ffff1f01`（`12:00:00+15:59:59` → -57599）が
`test_decode_binary.mojo:730-733` / `test_types_datetime.mojo:1254-1258` の期待値と一致した。

## 4. 指摘（round 1）

1. **`decode_numeric` が正規化後の weight 範囲外を検出しない**（`src/pq/types_numeric.mojo:253-264`、`src/pq/decode_binary.mojo:389-400`。差し戻し → F1 (a)(b)）。
   wire `0002 8000 0000 0000 0000 0001` は各フィールドが個別には範囲内なので全検査を通り、`_from_parts` の `stripped = -32769` が `Int16()` で `32767` に wrap、
   1e-131076 のつもりの値が 1e131068 として**エラー無しで**返る。ファズの crafted ケース・コードレビュー・セキュリティチェックの 3 経路で独立に検出。
   impl も turn 5「未確認」で挙げていた。REQ §5.2「範囲外 weight → PgError」/ D3「不正値は PgError」の契約内で、結果が**黙って別の値**になるため差し戻し
   （サーバーは正規化済みの値しか送らないので実害は malformed wire に限る。PG 自身は同じ入力を `value overflows numeric format` で拒否する）
2. `src/pq/params.mojo:655-657` コメントの根拠が不正確（`c_int` は 0x7FFFFFFF まで wrap しない。正しい根拠は PG の 1 GB 上限）。字句 → F1 (c)
3. `src/pq/result.mojo` `get_text` docstring (3)「`client_encoding` at the `UTF8` the container and libpq default to」— libpq の既定は `server_encoding` / `PGCLIENTENCODING` で UTF-8 とは限らない。字句 → F1 (c)
4. `src/pq/__init__.mojo` `## Zero-copy access`「`client_encoding` is `UTF8` and that is the guarantee」— 同上。字句 → F1 (c)

## 5. 残留リスク（差し戻さない。要件外か、誤動作・データ損失を伴わない）

- **UTF-8 無検証**（`String(unsafe_from_utf8=)` / `StringSlice(unsafe_from_utf8=)`。P20 / 決めた事項 3・9 で意図的）: `SQL_ASCII` のデータベースや偽造 binary セルで末尾が UTF-8 先頭 byte だけの値が来ると、
  **利用者側**の codepoint 走査が slice 末尾を 1〜3 byte 読み越す可能性がある。`pq` 自身は `PQgetlength` の範囲しか読まない。docstring に明記済み（F1 (c) で文言を正確にする）。検証付き `String(from_utf8=)` に切り替えるかは Phase 4 以降の判断
- **`decode_timetz` が時刻部の範囲（0..86400000000）を検査しない**（`decode_time` は検査する）。malformed wire で `-19:59:59.999999` のような PG が印字しない文字列になるが、abort も読み越しも無い（ファズで確認）。PG の `timetz_recv` 自体は範囲検査するので正規のサーバーからは到達しない
- **非正規化 numeric（dscale < 実桁）** は `String()` が PG の `trunc_var` と同じく切り捨てるが `==` は隠れた桁を見る。サーバーは送らない
- **decode エラーのメッセージにセル全文が入る**（`cannot decode "<text>" as <type>`。Phase 1 からの流儀）: 巨大セルや制御文字入りセルがログに出る
- `encode_numeric` の `UInt16(ndigits)` は 65,536 群以上の `Decimal` を手で組んだときだけ切れる（サーバー側が長さ不一致で拒否。利用者入力のみ）
- `ResultFormat.write_to` は 0 / 1 以外で何も書かない（`PQfformat` は 0 / 1 しか返さない）
- `get_text`（`result.mojo`）と `decode_binary[String]` に jsonb version byte 検査と文字列系 5 OID の判定が 2 か所ある（7 つ目の文字列系 OID を足すときに片方を忘れる余地）。整理は Phase 4 以降
- `tests/test_extended_numeric.mojo` が OID 定数を自前定義（決めた事項 11 の「唯一の置き場」は `src/` の規則なので違反ではない）
- PG17 限定 / PG14 限定のテスト 2 件は非該当サーバーで早期 return して PASS 表示（turn 8 想定外 (5)。名前で判別できる）
- `test_timestamp_params_round_trip` の非 UTC 分岐はコンテナが `Etc/UTC` 固定のため CI で走らない（turn 8 以来の未確認）
- 拡張型の NULL binary と `PreparedStatement` / `Transaction` 経由の binary を**拡張型で**は見ていない（既存 8 型は `test_binary.mojo` が押さえ、経路は同じ `_take_result` / `Row.get`）
- `Decimal` の `@fieldwise_init` が正規化を飛ばせる 4 引数の公開 ctor を生む（turn 5 想定外 (1)。Mojo に可視性制御が無い）

## 6. 計測（turn 12。単位 s）

- `pixi run check`: 6/6 PASS（1/6 fmt 1 s・2/6 1 s・3/6 1 s・4/6 4 s・5/6 約 130 s・6/6 0 s）
- ファズ probe: ビルド約 40 s、実行約 25 s（約 230,000 呼び出し）
- サブエージェント 2 本: コードレビュー約 8 分 / セキュリティ約 5 分
