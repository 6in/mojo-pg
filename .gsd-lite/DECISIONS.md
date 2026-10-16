# DECISIONS — phase3-binary-all-types

## D1. マイルストーン範囲は HANDOFF Phase 3 の全部
- 選択: バイナリ結果形式（既存 8 型）+ §6 の拡張型 7 種をテキスト・バイナリ両方で解釈
- 却下: 「バイナリのみ」「拡張型テキストのみ」の分割 — Phase 3 の受け入れ条件（§6 全型の text/binary 一致）が未達のまま残るため

## D2. 隣接項目を 4 つとも入れる（ユーザー全選択）
- 拡張型のパラメータ送信（`Param` に自前型の ctor を足す。往復テストが自然に書ける）
- time / timetz / interval（§6 に無い日時系 3 型。日時構造体を作るなら追加コストは小さい）
- zero-copy Row（HANDOFF §11。Mojo 1.1.0 の origin 制約で成立しないリスクがあるため、成立条件を D-later で決める）
- text vs binary の簡易ベンチ（HANDOFF §8。合否判定は Phase 5 まで入れない）

## D3. 堅牢性の受け入れ基準を入れる（差し戻し対象）
- Phase 1 / 2 と同じ。decode_binary の長さ不足・不正値を `PgError` で返すことを verify の格子プローブ対象にする

## D4. リークの +83〜85 ページの一段は `TOLERANCE_PAGES = 256` を恒久仕様にする
- 選択: docstring に未特定の注記を書くだけ。2 マイルストーン・20 系列以上で偽陽性ゼロ、検出力は陽性対照 5 経路で実証済み
- 却下: 1 ターンの調査タスク（`mallinfo2()` / `MALLOC_ARENA_MAX=1`）— 約 USD 10 を消費して結論が出ない可能性があり、現行の判定で運用上の問題が無い

## D5. 持ち越しの小物は最初の 1 コミットで全部片付ける（Phase 2 D3 と同じ）
- Phase 2 VERIFICATION §6 の 1〜6・8・9 と、D4 の docstring 注記（REQ §6）

## D6. 前 REQ の陳腐化した記述は新 REQ §7「既知のサーバー挙動」として訂正して引き継ぐ
- Phase 2 REQ §5.1a の「rollback 後の prepared は失敗」「int8 → int4 は 42804」は実測と食い違っていた（reflect Minus 5）。
  archive の REQ は触らず、次に読まれる新 REQ に正を書く

## D7. research は REQ 本文を直す権限を持つ（reflect 提案 3）
- §5.1 のサーバー挙動断定は「要実測」。矛盾を見つけたら RESEARCH §5 に読み替えを書くのではなく REQ を直す

## D8. 結果形式は `result_format` キーワード引数（既定 TEXT）、`Row.get` は `PQfformat` で自動切替
- 選択: `execute(sql, params, result_format=)` / `PreparedStatement.execute(params, result_format=)`。後方互換で既定テキスト
- 却下: 別メソッド `execute_binary`（オーバーロード増）/ バイナリ既定（未対応 OID の列を含む SELECT が `get[String]` で読めなくなる破壊的変更）

## D9. バイナリ列の未対応 OID / 型不一致は `TYPE_MISMATCH` で厳密に弾く
- 選択: `get[String]` は文字列系 OID のみ、`get[List[UInt8]]` は bytea のみ。kind は 6 つのまま
- 却下: `get[List[UInt8]]` を生バイトの逃げ道にする（bytea と区別がつかず「OID が T に一致」規則の例外が増える）/
  `UNSUPPORTED_TYPE` kind の追加（Phase 1 の「kind は 6 つ」の約束を広げる）

## D10. `Decimal` は PG 内部表現（sign / weight / dscale / base-10000 digits）をそのまま持つ
- 選択: バイナリと無損失往復、テキストは自前 parse / format。`==` は PG `numeric_eq` と同じ値比較、`dscale()` は別途公開
- 却下: 正規化文字列の薄いラッパー（「バイナリで送る」を満たさない）/ `Int128` + scale（38 桁の範囲制限が仕様に残る）

## D11. 日時型は PG 内部表現（days / micros）+ 分解アクセサ
- 選択: `Date(days)` / `Timestamp`・`TimestampTz(micros)` / `Time(micros)` / `TimeTz(micros, offset_secs)` / `Interval(micros, days, months)`。
  `±infinity` は PG と同じ番兵 + `is_infinite()`。比較は整数比較
- 却下: 分解フィールド構造体（受信・送信の両方で変換、infinity に別フラグ）/ 生の整数だけ（テキスト parse に civil 変換が結局要る）

## D12. DateStyle / IntervalStyle は接続直後の `SET` 1 往復で固定、TimeZone は触らない
- 選択: `PQexec("SET DateStyle TO 'ISO, YMD'; SET IntervalStyle TO 'postgres'")`。conninfo を解析しないので堅牢。約 1 ms
- 却下: conninfo `options` へのマージ（`PQconninfoParse` の構造体レイアウト定義とユーザー options との結合が要る）/
  固定しない（利用者の環境で壊れる）
- TimeZone を UTC に固定しない理由: 利用者が `String` で読む他の時刻テキストの見え方を変えないため。timestamptz のオフセットは自前で解釈する

## D13. zero-copy Row は best-effort（不成立なら外す。unsafe 代替は公開しない）
- 選択: research のプローブで成立判定。不成立なら RESEARCH に根拠を書いてスコープから外し、verify は差し戻さない
- 却下: 必須（不成立で BLOCKED。人間の判断待ちでループが止まる）/ `MutUntrackedOrigin` の unsafe 代替（§5.2 の安全性要件を満たさない API を公開する）

## D14. discuss が判断した付随事項（ユーザーに聞かずに決めた小物）
- `ResultFormat` は `PgErrorKind` と同じ定数 struct 形式（`TEXT` / `BINARY`）。`Result.column_format(i)` を公開
- json / jsonb のパラメータは `String` のまま（専用型は作らない。YAGNI）
- 拡張型の `Optional[...]` ctor も足す（Phase 2 D14 との一貫性）
- `Decimal` のテキストは `1e5` 形式を受けない（PG の `numeric_out` は指数形式を出さない）
- ベンチは `examples/bench_formats.mojo` + `pixi run bench`。合否判定なし、数値の記録のみ
- `_ffi` の追加バインドは無し見込み（`PQfformat` / `PQgetlength` は Phase 1 で済み）
- 持ち越し整理（D5）に Phase 2 VERIFICATION §6-8（Transaction docstring の混用注記）も含める

## D15. 実行パターン: 現在の設定を維持（すべて Claude、impl = claude-opus-5、他 = claude-fable-5-1、subagents=auto、reflect=true）
- Phase 2 で差し戻し 0・10 ターン・USD 110 の実績。`GSD_LITE_ENGINE` は未設定（state の `engine` がそのまま効く）
- research.targets は `similar_oss` / `official_docs`（`local_projects` は今回得るものが少ない見込みのため外した）
