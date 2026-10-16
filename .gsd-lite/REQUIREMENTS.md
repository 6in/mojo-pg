# REQUIREMENTS — phase3-binary-all-types

- 作成: 2026-10-16（discuss）
- 対象リポジトリ: このリポジトリ（in-repo 形）。base = `main`（Phase 2 マージ済み `e60b46f`）
- 前提文書: `HANDOFF.md` §6（型マッピング）/ §9 Phase 3 / §10 Phase 3 / §11、
  `.gsd-lite/archive/phase2-params-prepared-tx/`（前マイルストーンの成果物）、
  `.gsd-lite/reflect/20261016-0246-phase2-params-prepared-tx.md`（直近の振り返り）

## 1. 目的

`Result` をバイナリ結果形式でも読めるようにし、HANDOFF §6 の全型（numeric / date / timestamp / timestamptz /
uuid / json / jsonb）をテキスト・バイナリの両形式で `Row.get[T]` できるようにする。同じ型をパラメータとしても
送れるようにし、日時系の time / timetz / interval も加える。

## 2. スコープ（このマイルストーンでやること）

- バイナリ結果形式: `execute(sql, params)` / `PreparedStatement.execute(params)` で結果形式を選べる（§4.1）
- `decode_binary`: 既存 8 型（bool / int2 / int4 / int8 / float4 / float8 / text 系 / bytea）のバイナリ解釈（§4.2）
- 拡張型（§4.3）: numeric → `Decimal`、date → `Date`、timestamp → `Timestamp`、timestamptz → `TimestampTz`、
  uuid → `UUID`、json / jsonb → `String`、time → `Time`、timetz → `TimeTz`、interval → `Interval`。
  テキスト形式・バイナリ形式の両方で `get[T]` / `get_optional[T]` できる
- 拡張型のパラメータ送信: `Param` が上記の自前型を受け付けてバイナリで送る（§4.4）
- zero-copy Row アクセス（HANDOFF §11。§4.5。成立条件つき）
- text vs binary の簡易ベンチ（§4.6。合否判定なし）
- 持ち越し整理（§6）
- Phase 1 / 2 と同じ堅牢性・品質基準（§5.2 / §5.4）

## 3. スコープ外（やらないこと）

- Phase 4 以降: 非同期 API、LISTEN/NOTIFY、キャンセル、README 整備、Windows コードパス、psycopg 比較ベンチ
- 配列型（`_int4` 等）、range / multirange、hstore、enum、複合型、その他 §6 に無い型（Phase 6 候補）
- `Decimal` の算術演算（HANDOFF §11: `String` 相互変換と比較だけ）
- タイムゾーン名の解決（`TimestampTz` は UTC 保持。ローカル時刻への変換 API は作らない）
- 列ごとの結果形式指定（libpq の `PQexecParams` は全列一括のため）
- 既存の「widening なし」規則の変更（int2 列を `Int32` で読む等は引き続き `TYPE_MISMATCH`）
- HANDOFF §3 の対象外（ワイヤプロトコル自前実装、プール、COPY、パイプライン、ORM、Mojo async 統合）
- CI（Phase 1 D7 と同じ。受け入れはローカル `pixi run test`）

## 4. 機能要件

### 4.1 結果形式の選択（`connection.mojo` / `prepared.mojo` / `result.mojo`）
- `ResultFormat`（`pq` 直下で公開。`TEXT = 0` / `BINARY = 1`。`PgErrorKind` と同じ定数 struct 形式）
- `Connection.execute(sql, params, result_format: ResultFormat = ResultFormat.TEXT)` と
  `PreparedStatement.execute(params, result_format = ResultFormat.TEXT)` に**キーワード引数**を足す。既定はテキストで後方互換。
  `execute(sql)` 単体は `PQexec`（テキスト固定）のまま。バイナリが欲しければ `execute(sql, [], result_format=BINARY)`
- `Row.get[T]` / `get_optional[T]` は列の `PQfformat` を見てテキスト / バイナリの decode を自動で切り替える
  （呼び出し側は形式を意識しない）。`Result.column_format(i) -> ResultFormat` を公開する
- バイナリ形式の列に対する `T` と OID の対応は §4.2 / §4.3 の表のとおり**厳密**。それ以外は `TYPE_MISMATCH`:
  - `get[String]` はバイナリでは文字列系 OID（text / varchar / bpchar / name / json / jsonb）のみ。
    その他の OID（未対応型を含む）は `TYPE_MISMATCH` で、メッセージに OID と「text 形式で取り直せ」を含める
  - `get[List[UInt8]]` は bytea（17）のみ（生バイトの逃げ道にしない）
  - 新しい `PgErrorKind` は足さない（6 つのまま）
- テキスト形式の規則は Phase 1 のまま（`get[String]` は任意 OID、widening なし）

### 4.2 `decode_binary`（既存 8 型。HANDOFF §6 の「バイナリ形式」列）
| OID | `T` | バイナリ |
|---|---|---|
| 16 bool | `Bool` | 1 byte（0 / 1。それ以外は `TYPE_MISMATCH`） |
| 21 int2 | `Int16` | 2 byte BE |
| 23 int4 | `Int32` | 4 byte BE |
| 20 int8 | `Int64` / `Int` | 8 byte BE |
| 700 float4 | `Float32` | IEEE 754 4 byte BE（NaN / ±Inf / -0.0 をそのまま） |
| 701 float8 | `Float64` | IEEE 754 8 byte BE |
| 25 / 1043 / 1042 / 19 | `String` | UTF-8 そのまま（長さは `PQgetlength`。NUL を含み得るので `PQgetvalue` の C 文字列扱いをしない） |
| 17 bytea | `List[UInt8]` | 生バイト（`PQgetlength` の長さ） |
- 長さが型の固定長と一致しない列は `TYPE_MISMATCH`（メッセージに期待長と実長）
- `decode_binary.mojo` に `decode_binary[T](ptr, length, oid)` を置き、`decode_text` と同じ 1 箇所で型表を持つ。
  `Row.get` の分岐は「format を見てどちらかを呼ぶ」だけにする

### 4.3 拡張型（`types.mojo` 等の新モジュール。すべて `pq` 直下で公開、`Copyable & Movable & Equatable & Writable`）
| PostgreSQL | OID | Mojo 型 | 内部表現 | テキスト | バイナリ |
|---|---|---|---|---|---|
| numeric | 1700 | `Decimal` | `sign` / `weight: Int16` / `dscale: Int16` / `digits: List[Int16]`（base-10000）+ NaN / +Inf / -Inf（PG14 以降）フラグ | 10 進文字列を自前 parse / format（`1.50`、`-0.001`、`1e5` 形式は受けない） | ndigits, weight, sign, dscale, digits（`numeric_send` と同じ）。**サーバーは ±Infinity を dscale=32 で送ってくる**（research turn 1 実測。NaN は 0）。decode は sign が special なら weight / dscale を無視、encode は 0 を送る（サーバーは受理し 32 に正規化して返す）。往復テストは値比較 |
| date | 1082 | `Date` | `days: Int32`（2000-01-01 起点） | `YYYY-MM-DD`（紀元前 ` BC` 付きは受ける） | int32 |
| timestamp | 1114 | `Timestamp` | `micros: Int64`（2000-01-01 00:00:00 起点） | `YYYY-MM-DD HH:MM:SS[.ffffff]` | int64 |
| timestamptz | 1184 | `TimestampTz` | `micros: Int64`（UTC） | 同上 + オフセット（`+09`、`+09:30`、`-03:00:30`）を解釈して UTC に正規化 | int64（UTC） |
| time | 1083 | `Time` | `micros: Int64`（0〜86400000000） | `HH:MM:SS[.ffffff]` | int64 |
| timetz | 1266 | `TimeTz` | `micros: Int64` + `offset_secs: Int32`（PG と同じ符号規則。西が正） | `HH:MM:SS[.ffffff]±HH[:MM[:SS]]` | int64 + int32 |
| interval | 1186 | `Interval` | `micros: Int64` / `days: Int32` / `months: Int32` | IntervalStyle `postgres` 形式（`1 year 2 mons 3 days 04:05:06.789`、負値 `-1 days +02:00:00` 含む）。**PG17 以降は `infinity` / `-infinity` もある**（research turn 1 訂正。PG14 には無い: `'infinity'::interval` は 22007） | int64 + int32 + int32（この順。PG17 の ±infinity は 3 フィールド全部 `MAX` / 全部 `MIN` が番兵） |
| uuid | 2950 | `UUID` | 16 byte（`InlineArray[UInt8, 16]` 相当） | `8-4-4-4-12`（大文字小文字どちらも受ける。出力は小文字） | 16 byte |
| json | 114 | `String` | — | そのまま | そのまま |
| jsonb | 3802 | `String` | — | そのまま | 先頭 1 byte のバージョン（= 1。それ以外は `TYPE_MISMATCH`）を剥がしてテキスト |
- 日時系の `±infinity`: PG と同じ番兵（`Int64.MAX` / `Int64.MIN`、date は `Int32.MAX` / `Int32.MIN`、interval は 3 フィールド全部 MAX / 全部 MIN = PG17 の番兵）を保持し
  `is_infinite()` / `is_finite()` を持つ（research turn 1 訂正: interval も含める。PG14 では interval の無限値は発生しないので、PG14 向けテストは送らない）。
  テキストは `infinity` / `-infinity` と相互変換
- テキスト形式の細部（research turn 1 で実測）: timestamptz の ` BC` は**オフセットの後**（`0001-01-01 00:00:00+00 BC`）。オフセットは `+09` / `+05:30` / `+05:53:28` の 3 幅。
  小数秒は末尾ゼロを削った 1〜6 桁（`.5` = 500000 µs）。年は 4 桁ゼロ埋めで 4 桁超はそのまま（`10000-01-01`）。interval の複数形は値 ≠ 1 のとき（`-1 days`）、
  `+` 接頭辞は「前に出した成分が負で、この成分が正」のとき（`-1 years +1 day`）、時刻部の時は 2 桁以上で上限なし（`36:00:00`）。詳細は RESEARCH §2.2.3
- 日時系の分解アクセサ `year() / month() / day() / hour() / minute() / second() / microsecond()` と構築子
  `Date.from_ymd(y, m, d) raises` / `Timestamp.from_ymd_hms(...)` / `TimestampTz.from_utc(...)`（範囲外は `USAGE`）。
  `Interval` は `months / days / micros` の 3 フィールドのまま（正規化はサーバーに任せる）
- `write_to` / `String(x)` は PG のテキスト形式と同じ文字列を返す（往復テストはこれを使う）
- `==` の意味: 日時系は内部整数の比較。`Decimal` は **PG の `numeric_eq` と同じ値比較**（`1.0 == 1.00` は真。`dscale()` は別途読める）。
  NaN 同士は PG と同じく「等しい」（`numeric` の NaN は比較で等しい）
- `Decimal` の `String` 相互変換: `Decimal("1.50")` / `String(d)` が無損失（`dscale` を保つ）。`Decimal` 同士の算術は作らない
- テキスト形式の解釈前提（§4.7 で固定）: `DateStyle = 'ISO, YMD'`、`IntervalStyle = 'postgres'`。
  非 ISO の文字列（`01/02/2024` 等）は `TYPE_MISMATCH`

### 4.4 拡張型のパラメータ送信（`params.mojo` / `encode_binary.mojo`）
- `Param` に `Decimal` / `Date` / `Timestamp` / `TimestampTz` / `Time` / `TimeTz` / `Interval` / `UUID` の `@implicit` ctor と
  `Optional[...]` 版（Phase 2 D14 と同じ）を足す。すべて**バイナリ**で送り、OID は §4.3 の値を `paramTypes` に入れる
- json / jsonb は `String` として送る（型は SQL 側のキャストに任せる。専用型は作らない）
- `encode_binary.mojo` に各型の `encode_*` を足し、`decode_binary` との往復テストを単体で持つ（サーバー不要）

### 4.5 zero-copy Row アクセス（best-effort。HANDOFF §11）
- 候補 API: `Row[origin].get_text(col) raises -> StringSlice[origin]`、`Row[origin].get_bytes(col) raises -> Span[UInt8, origin]`
  （`Result` の `PQgetvalue` 領域を指す。NULL は `NULL_VALUE`。`get_text` はテキスト形式または文字列系 OID のバイナリ列のみ）
- **成立条件**: research がプローブで「`Result` を破棄した後にその slice を使うコードがコンパイルエラーになる」ことを確かめる。
  不成立（origin が付けられない / `Result` の移動を防げない）なら RESEARCH に根拠を書いてスコープから外し、
  REQ §2 のこの項を「見送り」に書き換える。unsafe な代替 API は公開しない
- **research turn 1 の判定: 成立**（RESEARCH §2.3.1）。「破棄」の形は **`Result` を消費する移動**（`var r2 = res^` / 関数へ `res^` を渡す）で、
  その後の slice 使用は `error: use of uninitialized value 'res'` になる。**`_ = res^` はエラーにならず、`Result` の破棄が slice の最後の使用の後まで延びる**
  （安全だがエラーではない。Mojo の `_ = x^` は生存マーカー）。docstring はこの区別を書く
- 成立した場合、§5.2 の「`Result` より長生きしない」はコンパイルエラーの陽性対照（**消費する移動の形**。PROGRESS にエラーメッセージを貼る）で示す

### 4.6 text vs binary の簡易ベンチ（`examples/bench_formats.mojo`、`pixi run bench`）
- 10 万行 × 5 列（int4, int8, float8, text, timestamp）を `generate_series` で作り、text / binary で全行 `get[T]` した所要を表示
- 合否判定は**しない**（HANDOFF §8 の「バイナリが速い」は Phase 5 で psycopg と並べて判定）。数値は PROGRESS と verify に記録する
- `examples/` の規約どおり単体で実行でき、`PQ_TEST_CONNINFO` が無ければ 54317 に繋ぐ

### 4.7 接続時の GUC 固定（`connection.mojo`）
- `Connection.open` は接続成功直後に `PQexec("SET DateStyle TO 'ISO, YMD'; SET IntervalStyle TO 'postgres'")` を 1 回送る
  （1 往復、約 1 ms）。失敗したら `PQfinish` してから `PgError(kind=Connection または Server)` を投げる（接続オブジェクトを返さない）
- `TimeZone` は触らない。timestamptz / timetz のテキストはオフセットを解釈して UTC に正規化する
- Phase 4 の非同期接続も同じ SET を最初のクエリステップとして送る（申し送り。今回は実装しない）
- `test_connection` に「`SHOW DateStyle` が `ISO, YMD`」を 1 件足す

### 4.8 `_ffi`
- 追加バインドは不要の見込み（`PQfformat` / `PQgetlength` / `PQftype` は Phase 1 で済み）。必要になったら HANDOFF §5.2 の表に従って足す

## 5. 受け入れ基準

### 5.1 HANDOFF §10 Phase 3
- §6 の全型（+ time / timetz / interval）について、テキスト形式とバイナリ形式で `get[T]` の結果が一致する。
  境界値: 整数の最小 / 最大 / 0 / 負、float の NaN / ±Infinity / -0.0、`infinity` / `-infinity` の日時、
  numeric の大きな桁（例: 1e130 相当）・小数（例: 0.000001）・負・0・NaN、uuid の全ゼロ / 全 F、空文字列、
  NUL を含む bytea、jsonb のネスト
- 未対応 OID をバイナリで要求したら `PgError(kind=TypeMismatch)`（§4.1）になり、トレースバックを出さない。
  バイナリ列の `get[String]`（非文字列 OID）/ `get[List[UInt8]]`（非 bytea）も同じ
- バイナリ形式で `execute` した結果の `column_format(i)` が `BINARY`、`execute(sql)` の結果は `TEXT`
- 拡張型 8 種を `$1` で送り（§4.4）`SELECT $1::<type>` で同じ値が返る（text / binary の両結果形式）
- `SHOW DateStyle` が `ISO, YMD`（§4.7）。`examples/bench_formats.mojo` が実行でき所要を表示する（§4.6）
- zero-copy（§4.5）が成立した場合: `get_text` / `get_bytes` の値が `get[String]` / `get[List[UInt8]]` と一致し、`Result` を消費する移動（`var r2 = res^` 等）の後の使用がコンパイルエラー
  （research turn 1 訂正: `_ = res^` は生存延長であってエラーにならない）

### 5.2 堅牢性（差し戻し対象。Phase 1 / 2 §5.2 を Phase 3 の API に拡張）
- どの入力・出力状態（長さ不足のバイナリ列、不正な uuid 長、numeric の不正 ndigits / 範囲外 weight、
  jsonb の未知バージョンバイト、テキスト形式の非 ISO 日時文字列、NULL、空結果、未接続・切断後）でも
  クラッシュ・トレースバックを出さず `PgError` で返す
- 正常系・異常系の両方で `PQclear` / `PQfinish` / `PQfreemem` が呼ばれ、二重解放しない
- 解放済みポインタへのアクセスが型・所有権の上で起こらない（zero-copy の slice / span が `Result` より長生きしない: 消費する移動はコンパイルエラー、`_ = res^` は `Result` の生存が延びる。
  公開 API は `ref` を返さない — `ref` 束縛は生存延長されない。RESEARCH §0.5）
- 10,000 回のバイナリ形式 execute（拡張型の列を含む）のループでメモリ使用量が単調増加しない
  （`test_leak` に Phase 3 分のループを追加。判定方式は §5.3）

### 5.3 リーク測定方式（Phase 2 D4 を維持）
- `test_leak.mojo` は `mojo build` したバイナリで実行、`pixi run check` は 1 サーバー（`PQ_TEST_LEAK_SERVERS=1`）
- **`TOLERANCE_PAGES = 256` を恒久仕様とする**。docstring に「+83〜85 ページの一段が 1 回出ることがある
  （glibc arena の拡張と推測、未特定）」を書く（§6 の持ち越し整理に含める）
- 検出力の陽性対照: 新しく追加する解放経路（zero-copy で `Result` を保持する経路があればそれ）を消したコピーで
  FAIL することを impl が同じターンで実測し、サンプル列を PROGRESS に貼る

### 5.4 品質基準（差し戻し対象。Phase 1 §5.1b / Phase 2 §5.4 と同じ）
- `pq` 直下の公開 struct / メソッドに docstring がある（`_ffi` はモジュール docstring のみでよい）
- `pixi run fmt` を実行しても差分なし（`final_check.sh` 1/6 段）
- `examples/binary.mojo`（接続 → バイナリ形式で全型 SELECT → 値の表示）が単体で実行できる。`pixi.toml` にタスクを追加する
- `pixi run package` が通る
- `pixi run check` が 6/6 段 PASS

## 6. 持ち越し整理（最初の 1 コミットにまとめる。Phase 2 VERIFICATION §6 より）

1. `src/pq/prepared.mojo` と `src/pq/__init__.mojo` に「prepared は `PQprepare` 時点の型と同じ幅の値を渡す
   （`$1::int4` なら `Int32`。`Int` = int8 を渡すと `22P03`）」を 1 文ずつ足す
2. `tests/final_check.sh` 6/6 段の grep パターンに `|implicit ROLLBACK failed` を追加（見出しにこの文字列を入れない）
3. `tests/test_prepared.mojo:543-544` の `find("1")` を `"takes 3 parameters, got 1"` の部分一致に
4. `Connection.__init__` docstring に `_stmt_counter` / `_rollback_failure_handler`
5. `param_type_oid(0)` の 0 パラメータ文での文言 `out of range (0..-1)` を `(no parameters)` 等に
6. savepoint 名の NUL を `_reject_nul(name, "name")` で先に弾く（メッセージが `in s` でなく `in name` になる）
7. `params.mojo` の `c_int(len(_data))` に `len > 0x3FFFFFFF` で `USAGE` を投げる 1 行（§9 の残留リスク）
8. `tests/test_leak.mojo` の docstring に §5.3 の +83〜85 ページ注記
9. `Transaction` docstring の「conn.execute との混用」節に「手で `COMMIT` / `ROLLBACK` を送ると破棄時の ROLLBACK が
   サーバー WARNING になる（データは手動 COMMIT どおり）」を 1 文
10. （research turn 1 追加）`result.mojo` モジュール docstring・`Row` / `RowIter`・`prepared.mojo`・`transaction.mojo`・`connection.prepare` / `transaction` の docstring にある
    「`Result`（`Connection`）より長生きするのはコンパイルエラー」を「消費する移動（`var r2 = res^` / 関数へ `res^`）の後の使用がコンパイルエラー。`_ = res^` は破棄ではなく生存延長で、
    `PQclear` は `Row` の最後の使用の後に走る」に直す（RESEARCH §2.3.1 で実測: 現行の文言のまま書いたコードはコンパイルが通り、安全に動く）

## 7. 既知のサーバー挙動（Phase 2 で実測済み。前 REQ の誤記を訂正した正）

- prepared statement は ROLLBACK で消えない（`PREPARE` は非トランザクショナル）。手動 `DEALLOCATE` 後の実行は `26000`
- `conn.execute(sql, params)` で `Int`（int8）を int4 列に渡すと assignment cast で成功する。`Bool` → int4 は `42804`、
  `Int(3000000000)` → int4 は `22003`。`PQexecPrepared` は `paramTypes` を送らないので `$1::int4` に `Int` を渡すと `22P03`
- `Connection.open` は ~4 ms/回（TestSuite の `Summary [ N ]` は **ms**）

## 8. テスト環境

- Phase 1 / 2 と同じ: `tests/docker-compose.yml`（PG 17 = 54317、PG 14 = 54314）、`pixi run db-up`、`pixi run test`
- `tests/fixtures/schema.sql` の `pqtest` スキーマ。Phase 3 のテーブルは各テストが自分で作る

## 9. 後続フェーズへの申し送り（前回 reflect より。スキル本文は変えないのでここに書く）

- **research**: RESEARCH §0.5「Mojo 1.1.0 既知の落とし穴」に Phase 1 分に加えて Phase 2 の 7 件を足す
  （`mojo format` は `.gitignore` を尊重 / `SIMD.__rshift__` の rhs は `Self` 固定・符号付き右シフトは符号拡張 /
  ローカル `List` は `return out^` / `String.as_bytes()` は `Span` / `def main() raises PgError` 不可 / `s += s` は aliasing /
  `StaticString` は `@implicit` 非対象 / deref を挟む origin の入れ子は変換不能 / `std.os.setenv` は raise しない /
  空 `List[UInt8]` の `unsafe_ptr()` は `capacity=len+1`）。
  プローブは最初の 1 本をコンパイルしてから残りを書く。「通る形」だけでなく「仕様上の非対称を突く形」を 1 本含める
  （例: 同じ列を text と binary で取って差を記録）。**§5.1 のうちサーバー挙動を断定する項目は「要実測」とし最初のプローブ対象にする。
  矛盾を見つけたら REQ 本文を直してよい**（RESEARCH §5 に読み替えを散らさない）
- **plan**: 完了基準で `grep -c X = 0` を複数タスクが繰り返すなら最初のタスクで `final_check.sh` に機械化する。
  テスト仕様の期待メッセージは 2 語以上の部分文字列で書く。タスクごとに「サブエージェント推奨本数」を書き、
  1 ファイル完結・実行待ち支配のタスクは 0 本と明記する。陽性対照を完了基準に書く
- **impl**: PROGRESS「次への注意」は「確認済み」と「見込み」を分け、見込みには `未確認:` 接頭辞。所要の数値には単位を書く。
  サブエージェント依頼文に (a) 型パラメータを持つ型はフルに書く、(b) `fmt` は親が統合後に 1 回、(c) scratch は
  `.gsd-lite/logs/<slug>/scratch/turn-NNN-<name>` 固定、を必ず入れる
- **verify**: round 2 以降は「round 1 の格子の再確認 + 差し戻し分の回帰」に限定してよい
- **reflect**: `cost_usd` とサブエージェント本数の相関を確認する（前回 Interesting 1 の推測の検証）

## 10. 用語集

- **結果形式 / result format**: libpq の `resultFormat`（0 = テキスト、1 = バイナリ）。全列一括
- **テキスト形式**: サーバーの出力関数（`*_out`）の文字列。`DateStyle` 等の GUC に依存
- **バイナリ形式**: サーバーの送信関数（`*_send`）のバイト列。ビッグエンディアン
- **拡張型**: Phase 3 で加える自前の値型（`Decimal` / `Date` / `Timestamp` / `TimestampTz` / `Time` / `TimeTz` / `Interval` / `UUID`）
- **zero-copy**: `Result` の内部バッファを指す `StringSlice` / `Span` を `Result` の origin 付きで返すこと
- （Phase 1 / 2 の用語: 低レベル層 `_ffi` / 高レベル層 `pq` / conninfo / `PgError.kind` / params / prepared statement / Transaction / savepoint）
