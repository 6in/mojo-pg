# RESEARCH — phase3-binary-all-types

- 作成: 2026-10-16 / gsd-lite-research（turn 1）
- 入力: REQUIREMENTS.md / DECISIONS.md / HANDOFF.md §6・§8・§10・§11、`archive/phase2-params-prepared-tx/RESEARCH.md`、
  `reflect/20261016-0246-phase2-params-prepared-tx.md`。`state.json.research.targets` = similar_oss / official_docs
- 検証環境: Mojo 1.1.0 (8189361e)、pixi env の `libpq.so.5`、docker `postgres:17`（17.11、port 54317）/ `postgres:14`（14.24、port 54314）、aarch64 Linux
- **プローブ**（`.gsd-lite/logs/phase3-binary-all-types/scratch/`、gitignore 対象。結論は本書に転記済み）:
  - `turn-001-probe-binary.mojo` + `turn-001-probe-binary-pg17.log` / `-pg14.log`: 全型の text / binary 形式・パラメータ送信・不正バイナリの sqlstate（約 130 行の出力。**PG17 と PG14 の差は 3 行だけ**: §2.2.7）
  - `turn-001-probe-zerocopy*.mojo`（7 本）: zero-copy Row の成立判定（§2.3.1）
  - `turn-001-probe-types.mojo`: `comptime if` の自前型分岐・`@implicit`・整数除算・文字列 API（§2.3.2）
  - `turn-001-probe-civil.mojo`: Hinnant の暦算法を PG の実測値 9 件 + timestamp 5 件で照合（§2.2.3）
  - `turn-001-probe-bench.mojo` + ログ: 10 万行 × 5 列の libpq 素の所要（§2.4）
- サブエージェント 1 本（OSS / PG ソースの調査。本書 §1・§2.2 の「出典」行はその報告から。行番号は `REL_17_STABLE`）
- 無人シェルの注意（前回と同じ）: `mojo` / `pixi` は PATH に無い → **`/home/parallels/.pixi/bin/pixi run mojo ...`**。lean-ctx MCP は未接続（素の Read / Bash で可）。
  `rg` 無し。プローブは **最初の 1 本をコンパイルしてから** 残りを書いた（libpq プローブは初回コンパイルで通り、やり直しは §PROGRESS 参照）

## 0. 結論サマリ

1. **作る（BLOCKED にしない）**。要件を満たす既存 OSS は無い。Mojo 製の `lee101/mojo-pg`（2026-10 時点、自前ワイヤ実装、バイナリ decode 無し、Mojo nightly 1.2 依存）と
   `forfudan/decimo`（BigDecimal、base-10^18、PG コーデック無し）はいずれも採用不可だが、暦算法（Hinnant）と numeric の文字列化アルゴリズム
   （asyncpg / PG `get_str_from_var`）は盗める（§3）
2. **ワイヤ形式は全型とも実測で確定し、REQ §4.2 / §4.3 の表と一致**。追加で分かった 3 点を REQ に反映した（D7。§5）:
   (a) **PG17 は interval にも ±infinity がある**（番兵 = micros / days / months が全部 MAX または全部 MIN、テキスト `infinity`）。PG14 には無い（`'infinity'::interval` は 22007）
   (b) **timestamptz のテキストは ` BC` がオフセットの後**（`0001-01-01 00:00:00+00 BC`）
   (c) **numeric の ±Infinity はサーバーが dscale=32 を送ってくる**（`0000 0000 d000 0020`。ヘッダビットの読み出し癖。NaN は 0）。decode は special なら weight / dscale を無視、encode は 0 を送ればよい（サーバーは受理し 32 に正規化して返す → **Inf の往復テストはバイト比較ではなく値比較**）
3. **zero-copy Row は成立（REQ §4.5 の成立条件は「消費する移動」の形で満たす）**: `Row[origin].get_text() -> StringSlice[origin]` / `get_bytes() -> Span[UInt8, origin]` を
   `Pointer[UInt8, origin](unsafe_from_address=...)` + `Span(unsafe_ptr=, length=)` + `StringSlice(unsafe_from_utf8=)` で作れる（コンパイル・実行とも確認）。
   **`var r2 = res^` や `drop(res^)` の後で slice を使うと `error: use of uninitialized value 'res'` でコンパイルが止まる**（陽性対照の形はこれ）。
   一方 **`_ = res^` の後の使用はエラーにならず、`Result` の破棄が slice の最後の使用の後まで延びる**（deinit の print 順で確認。安全だがエラーではない）。
   既存の `Row` も同じ挙動で、`result.mojo` の「`Row` が `Result` より長生きするのはコンパイルエラー」という docstring は正確には「消費する移動がエラー。`_ = res^` は生存延長」（§5 で持ち越し整理に 1 件追加）
4. **`Connection.open` の `SET DateStyle TO 'ISO, YMD'; SET IntervalStyle TO 'postgres'` 1 往復は成立**（cmd tag `SET`、`SHOW DateStyle` = `ISO, YMD`）。
   2 文を 1 つの `PQexec` で送ると暗黙トランザクションなので **片方が失敗すると両方とも適用されない**（22023、接続はそのまま使える）。
   コンテナの既定は `DateStyle = ISO, MDY` / `IntervalStyle = postgres` / `TimeZone = Etc/UTC` / `integer_datetimes = on`
5. **text / binary の非対称（同じ列を両形式で取って差が出たもの）**: timestamptz のテキストは `TimeZone` 依存でバイナリは不変 / jsonb のテキストは正規化（空白・キー順・重複キー除去）されるが入力の `json` はそのまま /
   float8 のテキストは最短表現（`1e+300`、`-0`）/ numeric の Inf は上記 dscale 32 / bpchar は**両形式とも**空白パディング済み（`'ab'::char(5)` → 5 byte）/ `-0::numeric` はテキスト `0`・バイナリ sign 0。
   decode_binary の判定を「テキストと同じ値になる」で書くときは、これらは**値比較**にする
6. **サーバー側のバイナリ検証（パラメータ送信の失敗 sqlstate）**: numeric の digit ≥ 10000 / dscale > 0x3FFF / 不正 sign → `22P03`、長さ不足 → `08P01`、jsonb version ≠ 1 → `XX000`、
   time > 86400000000 → `22008`、timetz の zone ≥ 57600 → `22009`、date / timestamp の範囲外 → `22008`、不正 UTF-8 / NUL 入り text（バイナリ param）→ `22021`。
   **bool のバイト 2 はサーバーが `t` として受理する**（REQ の「0 / 1 以外は TYPE_MISMATCH」はクライアント側の厳格化で、サーバーより厳しい。そのまま採用）
7. **`PQexecParams(resultFormat=1)` は `nParams=0` でも使える**（REQ §4.1 の `execute(sql, [], result_format=BINARY)`）。DDL / INSERT に resultFormat=1 を付けても COMMAND_OK。
   `PQexecPrepared(resultFormat=1)` も同様（R2）。0 行の結果もそのまま。`PQexec` の結果は常に fformat 0
8. **ベンチ（§4.6）の素の libpq 所要は 10 万行 × 5 列で text 41〜45 ms / binary 36〜39 ms**（exec + 全セル touch、PG17 / PG14 同等）。差は Mojo 側の decode で付く。
   `pixi run bench` は 1 秒未満で終わる見込みで、`check` の時間予算に影響しない

## 0.5 Mojo 1.1.0 既知の落とし穴（Phase 1 / 2 からの転記 ★ + 今回の追加 ☆）

- ★ `_ = x^` は**破棄ではなく生存マーカー**。☆ さらに今回: **origin 付きの値（`Row` / `StringSlice[origin]` / `Span[origin]`）が後で使われていると `_ = x^` を越えて x の破棄が延びる**（deinit は slice の最後の使用の後）。
  「ここで PQclear される」を確かめたいテストでは、slice を `_ = x^` より前で使い切る
- ☆ **`ref r = res; _ = res^; r._len()` はコンパイルが通り、deinit が `r` の使用より先に走る**（use-after-free）。`ref` 束縛は origin 付き struct と違って生存延長されない。公開 API は `ref` を返さず origin 付き struct / slice を返す
- ☆ **`drop(res^)` / `var r2 = res^` の後で origin 付き値を使うと `error: use of uninitialized value 'res'`**（陽性対照はこの形。エラー位置は slice を使う行）
- ☆ **`Span` の生ポインタ ctor は `Span[T, origin](unsafe_ptr=Pointer[T, origin](...), length=n)`**（`ptr=` ではない）。`StringSlice[origin](unsafe_from_utf8=span)` は UTF-8 を検証しない。`String(from_utf8=span)` は検証して raise、`String(unsafe_from_utf8=span)` は検証なし。`String(bytes=...)` は無い
- ☆ **`InlineArray` は無い → `Array[UInt8, 16](fill=0)`**（`Copyable`、`arr[i]` 読み書き、`.copy()`、`len()` あり）
- ☆ `Pointer[c_char, ...]` の添字は **`p[unsafe_offset=i]`**（`p[i]` は deprecated 警告 → `check` 6/6 段で数えられる）
- ☆ **`Int` / `Int32` / `Int64` の `//` と `%` は Python と同じ床除算**（`-7 // 2 == -4`、`-7 % 2 == 1`）。Hinnant の C 版の `(y >= 0 ? y : y-399)/400` を**そのまま写すと二重に床を取って 0000-03-01 より前で 1 日ずれる**（komira の注記と一致）。Mojo では `y // 400` だけでよい（§2.2.3 で 9 日付を実測照合済み）
- ☆ `-Int64.MIN` は `Int64.MIN` のまま（オーバーフローは黙って wrap）。`Int(UInt32(0xffffffff))` は `-1`（符号付きとして解釈される）。`bitcast[DType.int32, 1](UInt32(0xffff8170))` = `-32400`、`bitcast[DType.int16, 1](UInt16(0xffff))` = `-1`、`bitcast[DType.float64, 1](UInt64)` / `bitcast[DType.float32, 1](UInt32)` が decode に使える
- ☆ `atol` は **先頭の `+`・前後の空白・先頭ゼロを受ける**（`atol(" 5") == 5`）。`'5x'` / `''` / 桁あふれは raise。**日時パーサーは `atol` に頼らず桁位置で読む**（空白や `+` を黙って通すと `TYPE_MISMATCH` にすべき入力が通る）
- ☆ `String` の添字・スライスは `s[byte=i]` / `s[byte=a:b]`。`rjust` は無い（ゼロ埋めは自前）。`split` / `find` / `rfind` / `startswith` / `endswith` / `strip` / `lower` / `upper` はある
- ☆ `Writable` な struct は `print(x)` / `String(x)` / `String.write(x)` のどれでも文字列化できる（`Stringable` を別に書かなくてよい）
- ☆ `comptime if T == <自前 struct>` は `decode_text` と同じ `rebind[T](v).copy()` で通る。`@implicit __init__(out self, d: Date)` と `Optional[Date]` の両方を並べても `[Date(1), opt, 42, Date(2)]` はリスト literal から変換できる
- ★（Phase 2 の 7 件）`mojo format` はディレクトリ走査で `.gitignore` を尊重（明示ファイル列なら無視されない）/ `SIMD.__rshift__` の rhs は `Self` 固定・符号付き右シフトは符号拡張（`bitcast` でゼロ拡張）/ ローカル `List` は `return out^` /
  `String.as_bytes()` は `Span`（`List[UInt8]` が要るならコピー）/ `def main() raises PgError` 不可（`raises` のみ）/ `s += s` は aliasing エラー / `StaticString` は `@implicit` の変換元にならない /
  deref を挟むと origin が入れ子になり struct の origin パラメータは変換不能（`rebind` も不可）/ `std.os.setenv` は raise しない（`Bool` を返す）/ 空 `List[UInt8]` の `unsafe_ptr()` を libpq に渡す経路は `capacity=len+1` で非 NULL を保証
- ★（Phase 1 / 2）`len(String)` 不可 → `byte_length()` / `from std.math import isnan, isinf` / リスト literal は型注釈必須、`List[UInt8](1, 2, 3)` は無い / `::` は単項マイナスより強い / stdlib ソースは pixi env に無い（型名はコンパイルエラーの候補シグネチャで確定）/
  `UnsafePointer` は deprecated で `Pointer` / デストラクタは `__deinit__(deinit self)` / 素の `None` は `@implicit` に変換されない（`Optional[T](None)` で）/ `size_t` 引数は `c_size_t(...)` / libpq の既定 notice processor はサーバー WARNING を stderr に出す /
  `atof("-0")` は -0.0、`NaN == NaN` は False / `List[c_int]` を lengths / formats に（`List[Int]` はストライド 8）
- ☆ **ASAP 破棄 × `_ParamBuffers` 型の構造**: プローブで `pp.values()` のアドレスを取った後に `pp` の最後の使用が来ると `pp` が先に破棄され、libpq が解放済みバッファを読んだ（`22P03 invalid sign`）。
  既存 `_ParamBuffers` は呼び出し後の `_ = buffers^` で守られている。新しい encode 経路を足すときも同じ並びを守る

## 1. 類似 OSS（similar_oss）

### 1.1 psycopg 3（ローカル: `/home/parallels/workspaces/poc-amano/.venv/lib/python3.12/site-packages/psycopg/`）
- 書式: `_struct.py:26-40`（`!h !H !i !I !q !f !d`）、numeric ヘッダ `!HhHH`（`types/numeric.py:309-316`）、timetz `!qi`、interval `!qii`（`types/datetime.py:26,30`。**順序は time, day, month**）
- numeric binary loader（`numeric.py:319-340`）: sign が POS/NEG なら digits を `val = val*10000 + d` で畳み、`shift = dscale - (ndigits - weight - 1)*4` で**小数桁を dscale ちょうどに揃える**（足りなければ 0 を足し、余れば落とす）。special は sign しか見ない
- numeric binary dumper（`:420-476`）: NaN → `(0,0,0xC000,0)`、±Inf → `(0,0,0xD000/0xF000,0)`、0 → `(0,0,POS,dscale)`、`weight = (ndigits_dec + exp)//4 - 1`。範囲検査は無い（int16 あふれは `struct.pack` が落とす）
- 既定は **Decimal も str も Json もテキスト送信**（binary dumper は「30 % 遅い」と注記、`:511-515`）。int / float / date / time / datetime / timedelta / uuid / bytes はバイナリ
- datetime（`datetime.py`）: date `int32 days`、time `int64 µs`（24:00:00 は Python 側で `DataError`）、**timetz は `(µs, -utcoffset_seconds)` と符号反転して秒精度を保つ**（`:125-130, 369-378`）、timestamp(tz) `int64 µs`（tz は接続の `TimeZone` に変換）、interval の months を **30 日 / 365 日で日に畳む（非可逆）**。±infinity は未対応（範囲エラーになる）
- interval テキスト loader は `IntervalStyle=postgres` の正規表現だけ（`:587-596`: `N years? N mons? N days? [-+]HH:MM:SS(.fff)?`）、timestamptz テキストは ISO のみ、オフセットは `[-+]HH(:MM(:SS)?)?`
- uuid: `obj.int.to_bytes(16, "big")` / `UUID(bytes=)`。json: jsonb binary は先頭 `\x01`、loader は `data[0] == 1` を検査（`json.py:240-244, 278-283`）
- **未対応 OID のフォールバック**: テキスト形式 → `TextLoader`（str）、バイナリ形式 → `ByteaBinaryLoader`（生バイト）（`_py_transformer.py:345-355`、`string.py:209,229`）。本プロジェクトは D9 で後者を採らない（生バイトの逃げ道を作らない）
- 結果形式は `cursor.execute(..., binary=)` で**全列一括**、loader は `(oid, PQfformat(0))` で選ぶ（`_cursor_base.py:428-454`、`_py_transformer.py:159-161`）→ `Row.get` が `PQfformat` で自動切替する D8 と同型

### 1.2 asyncpg / py-pgproto — https://github.com/MagicStack/py-pgproto（`codecs/*.pyx`）
- numeric encode（`numeric.pyx:33-133`）は PG の `set_var_from_str` と同じ式: `dweight = ndigits_dec + exponent - 1`、`weight = (dweight+4)//4 - 1`（dweight ≥ 0）/ `-((-dweight-1)//4 + 1)`、`padding = (weight+1)*4 - (dweight+1)`、`ndigits = (ndigits_dec + padding + 3)//4`
- numeric decode（`:141-298`）は **bignum を使わず文字列を組み立てる**: 符号 → 整数部（先頭グループだけ先頭ゼロ抑制、以降 4 桁ゼロ埋め）→ `.` → 小数部を `dscale - (ndigits-weight-1)*4` で埋める / 切る。`numeric_out` とバイト一致。**本プロジェクトの `String(Decimal)` はこれを写す**
- datetime: 番兵 `0x7fff...` / `0x8000...` を `datetime.max/min` に写す（`datetime.pyx:29-59`）。**timetz decode が zone を 60 で割って秒を落とすバグ**（`:342-344`）→ 本プロジェクトは秒を保つ（REQ どおり `offset_secs: Int32`）
- interval は `(months, days, micros)` のタプル codec が忠実版（`:413-423`）。既定 codec は 30 / 365 日で畳む（非可逆）

### 1.3 rust-postgres / rust_decimal — https://github.com/sfackler/rust-postgres、https://github.com/paupino/rust-decimal
- `postgres-protocol/src/types/mod.rs`: `timestamp_from_sql` は `read_i64` の後に**残りバイトがあればエラー**（`:382-388` "not drained"）、`uuid_from_sql` は `len == 16` 必須（`:455-462`）→ REQ §4.2 の「固定長不一致は TYPE_MISMATCH」と同じ流儀
- `postgres-types/src/chrono_04.rs`: 2000-01-01 基点、`checked_add_signed` で範囲外は `"value too large to decode"`。±infinity 未対応
- `rust_decimal/src/postgres/common.rs`: `from_sql` は **NaN / ±Inf をエラーにする**（本プロジェクトは値として持つ、D10）。テストが固定する 2 つの罠: `weight = i16::MIN` で `-weight` が panic しない（`:131-141`）、`weight=11`（1e44）で `None`（`:143-157`）

### 1.4 Mojo 製（GitHub code search、2026-10-16 時点）
- `lee101/mojo-pg`（MIT、0 star、Mojo nightly `1.2.0.dev2026100805` 固定）: 自前ワイヤ実装。`src/pg/conv.mojo:232-252` に Hinnant、`:280-345` に date / timestamp(tz) テキストパーサー（BC・±infinity・秒精度オフセット対応）。**バイナリ decode・interval・uuid・numeric（Float64 化）は無い**。参照のみ（コードは写さない: ライセンスは MIT で写せるが nightly 構文差が大きい）
- `komira-ai/komira`（Apache-2.0）`src/komira_datetime/civil.mojo:22-26, 60-88`: Hinnant を Mojo の床除算で書いた最も素直な版（`y // 400`）。`is_leap_year` / `days_in_month` / `weekday_from_days = (days+4) % 7`
- `mojoto/morrow.mojo`（Apache-2.0、126 star）: CPython の ordinal 方式（`_calendar.mojo`）。Hinnant より重い
- `forfudan/decimo`（Apache-2.0、33 star、`pixi add decimo`）: `BigDecimal`（base-10^18）/ `Decimal128`。PG base-10000 コーデック無し。「`String` 相互変換と比較だけ」（HANDOFF §11）には過剰
- → **採用する依存は無し**。写すのは算法（Hinnant、`get_str_from_var`）だけ

### 1.5 PostgreSQL 公式（挙動の裏付け。§2.2 の出典）
- `src/backend/utils/adt/numeric.c`（`numeric_send :1161-1180` / `numeric_recv :1076-1155` / `get_str_from_var :7548-7676` / `set_var_from_str :7149-7217` / `make_result_opt_error :7836-7936`）
- `timestamp.c`（`interval_send :1031-1041` / `interval_recv :1006-1025` / `interval2itm :2051-2071`）、`timestamp.h`（番兵 `:150-157`、`MIN_TIMESTAMP` / `END_TIMESTAMP :256-267`、`IS_VALID_DATE :262-264`、interval の infinity `:175-195`）
- `date.c`（`time_recv :1533-1536`、`timetz_recv :2349-2360`、`TZDISP_LIMIT = 57600`）、`datetime.c`（`EncodeTimezone :4189-4221`、`EncodeDateTime :4356-4373, 4498-4502`、`EncodeInterval :4712-4734`、`AddPostgresIntPart :4523-4542`、`AppendSeconds :448-501`、`DecodeTimezone :3057-3061`）
- `uuid.c`（`uuid_send :156-164`、`uuid_out :53-86`）、`jsonb.c`（`jsonb_send :124-139`、`jsonb_recv :89-102`）、`json.c`（`json_send :136-144`）
- libpq: https://www.postgresql.org/docs/current/libpq-exec.html（§2.1 に引用）

## 2. 公式ドキュメント + 検証結果（official_docs）

### 2.1 libpq（ドキュメント引用 + probe-binary）

| 項目 | 事実 | 根拠 |
|---|---|---|
| `resultFormat` | 0 = text / 1 = binary、**全列一括**（「列ごとの形式指定の手段は現状無い」）。`PQexecPrepared` も同じ | docs、R2 / R3 |
| `PQfformat(res, i)` | 0 / 1。`PQexec` の結果は常に 0、`PQexecParams(..., 1)` の結果は全列 1 | X5 / A1 B |
| `PQgetvalue` バイナリ | 「typsend の表現。**末尾に 0 byte が 1 つ付くが NUL を含み得るので役に立たない**」。ポインタは `PGresult` の一部で **`PQclear` まで有効**、変更・free 禁止 | docs |
| `PQgetlength` | 「実データ長。text では `strlen` と同じ、binary では必須」。NULL なら 0 | docs、A8 B（`len 0` で p は非 NULL） |
| `PQbinaryTuples` | deprecated（COPY 以外）。`PQfformat` を使う | docs |
| 0 行 / DDL / INSERT に resultFormat=1 | TUPLES_OK rows 0 / COMMAND_OK `CREATE TABLE` / `INSERT 0 1`（エラーにならない） | X2 / X3 / X4 |
| 未対応 OID の binary | バイト列がそのまま来る（int4[] 36 byte、point 16、oid 4、"char" 1、int4range 17、money 8、macaddr 6）。**クライアントが OID で弾くしかない**（D9） | X1 B |
| bpchar binary | `'ab'::char(5)` は text / binary とも `6162202020`（空白パディング込み 5 byte） | A7 |
| 多文 `PQexec` の `SET` | 暗黙トランザクション: 2 文目が 22023 なら 1 文目も戻る（`SHOW DateStyle` が直前の値のまま） | S4 / S5 |
| `PQexecParams` nParams=0 | ダミー 1 要素の配列を渡せば動く（既存 `_ParamBuffers` と同じ） | X1 〜 X4 |

### 2.2 PostgreSQL ワイヤ形式・テキスト形式（PG17 / PG14 で実測。差分は §2.2.7）

#### 2.2.1 既存 8 型（REQ §4.2 の表はそのまま正）
bool `01` / `00`、int2 `8000` / `7fff`、int4 `80000000` / `7fffffff`、int8 `8000000000000000` / `7fffffffffffffff`、float4 NaN `7fc00000`・+Inf `7f800000`・-Inf `ff800000`・-0 `80000000`・1.5 `3fc00000`、
float8 NaN `7ff8000000000000`・-0 `8000000000000000`・0.1 `3fb999999999999a`・1e300 `7e37e43c8800759c`（テキストは `1e+300`）、text `héllo` = `68c3a96c6c6f`（6 byte、`PQgetlength` = バイト長）、空 text len 0、varchar / name も生 UTF-8、bytea `\x00ff00` = `00ff00`（3 byte）、空 bytea len 0

#### 2.2.2 numeric（OID 1700）— `int16 ndigits, int16 weight, uint16 sign, uint16 dscale, int16 digits[ndigits]`（base-10000、BE）
| 値 | hex（実測） | 読み |
|---|---|---|
| `1.50` | `0002 0000 0000 0002 0001 1388` | digits [1, 5000], weight 0, dscale 2 |
| `-0.001` | `0001 ffff 4000 0003 000a` | [10], weight -1, NEG, dscale 3 |
| `0` / `0.00` | `0000 0000 0000 0000` / `0000 0000 0000 0002` | ndigits 0。weight 0。dscale だけ違う |
| `0.000001` | `0001 fffe 0000 0006 0064` | [100], weight -2 |
| `1e130` | `0001 0020 0000 0000 0064` | [100], weight 32。テキストは `1` + ゼロ 130 個（**指数表記は出ない**） |
| `1e-10` | `0001 fffd 0000 000a 0064` | テキスト `0.0000000001` |
| `1000000` / `10000` / `9999` | `0001 0001 0000 0000 0064` / `0001 0001 0000 0000 0001` / `0001 0000 0000 0000 270f` | 末尾ゼログループは落ちる |
| `12345678.9` | `0003 0001 0000 0001 04d2 162e 2328` | [1234, 5678, 9000] |
| `123456789012345678901234567890.123456789` | `000b 0007 0000 0009 ...`（30 byte） | 11 グループ、weight 7 |
| `12.3400` / `0.0001` / `0.5` / `-0.5` / `+1` | `0002 0000 0000 0004 000c 0d48` / `0001 ffff 0000 0004 0001` / `0001 ffff 0000 0001 1388` / `0001 ffff 4000 0001 1388` / `0001 0000 0000 0000 0001`（テキスト `1`） | |
| `NaN` / `Infinity` / `-Infinity` | `0000 0000 c000 0000` / `0000 0000 d000 0020` / `0000 0000 f000 0020` | **Inf の dscale 32 はヘッダビットの癖**（短形式判定 `0xD000 & 0x8000 != 0` → `(0xD000 & 0x3F80) >> 7 = 32`） |
| `'-0'` | `0000 0000 0000 0000` | テキスト `0`、sign POS |
| `1.5::numeric(10,4)` / `100::numeric(10,0)` | `0002 0000 0000 0004 0001 1388` / `0001 0000 0000 0000 0064` | typmod は dscale に出る |

- `numeric_eq`（N7、両サーバー）: `1.0 = 1.00` 真、`NaN = NaN` 真、`Inf = Inf` 真、`NaN > Inf` 真（NaN は最大として整列）。REQ §4.3 の `==` 仕様と一致
- サーバーの `numeric_recv` 検査（E 系、§0-6）: sign は 5 値のみ、dscale は 14 bit、digit は 0..9999、**dscale を超える桁は黙って切り捨て**（`[1, 5000]` を dscale 0 で送ると `1`）。weight は int16 なら何でも通る（`ndigits 0, weight 32767` → `0`）
- テキスト出力 `numeric_out`（`get_str_from_var`）: 位置表記のみ。`weight < 0` なら整数部 `0`。小数部は **dscale ちょうど**（digits が足りなければ 0 埋め、余れば切る）。`Infinity` / `-Infinity` / `NaN`
- テキスト入力（`numeric_in`、本プロジェクトの `Decimal(String)` が受ける範囲は REQ D14 でこれより狭い）: `[+-]`、`NaN`、`[+-]Infinity` / `inf`、`1e5` 形式、`0x` 等も受けるが **`Decimal("1e5")` は受けない**（D14）

#### 2.2.3 日時（date 1082 / timestamp 1114 / timestamptz 1184 / time 1083 / timetz 1266 / interval 1186）
- 定数: PG epoch 2000-01-01 = unix day 10957（`'1970-01-01'::date` → `ffffd533` = -10957）。`USECS_PER_DAY = 86400000000`。date の有効範囲 `-2451545`（4714-11-24 BC）〜 `2145031948`（5874897-12-31）、timestamp `-211813488000000000`（4714-11-24 00:00:00 BC）〜 `9223371331199999999`（294276-12-31 23:59:59.999999）。番兵 date `7fffffff` / `80000000`、timestamp `7fffffffffffffff` / `8000000000000000`（`P3`: 番兵をパラメータで送ると `infinity` / `-infinity` のテキストで返る。番兵の 1 つ内側 `Int64.MAX - 1` は `22008`）
- **date 実測**: 2000-01-01 → 0、1999-12-31 → -1、2024-02-29 → 8825、0001-01-01 → -730119、0001-01-01 BC → -730485、4714-11-24 BC → -2451545、10000-01-01 → 2921940、5874897-12-31 → 2145031948。
  テキスト: `YYYY-MM-DD`、年は **4 桁ゼロ埋め・4 桁超はそのまま**（`10000-01-01`、`5874897-12-31`）、紀元前は ` BC` 後置（`0001-01-01 BC`、天文年 y ≤ 0 を `1 - y` で表示）
- **Hinnant の暦算法を Mojo 床除算で書いて上記 9 日付が往復一致**（probe-civil: `days_from_civil` / `civil_from_days` とも 9/9 OK）。timestamp は `days = us // 86400000000`（床）、`rem = us - days*86400000000` で 1969-12-31 23:59:59.999999（`-946684800000001`）/ 0001-01-01 BC / 4713-01-01 BC / 294276-12-31 23:59:59.999999 の 4 件が一致。
  アルゴリズム（plan が完了基準に写す）:
  ```
  days_from_civil(y, m, d):           # y は天文年（1 BC = 0）、戻りは PG 日数
      yy = y - 1 if m <= 2 else y
      era = yy // 400                   # 床除算。C 版の (y-399)/400 は使わない
      yoe = yy - era*400
      mp = m - 3 if m > 2 else m + 9
      doy = (153*mp + 2)//5 + d - 1
      doe = yoe*365 + yoe//4 - yoe//100 + doy
      return era*146097 + doe - 719468 - 10957
  civil_from_days(pg_days):
      z = pg_days + 10957 + 719468
      era = z // 146097; doe = z - era*146097
      yoe = (doe - doe//1460 + doe//36524 - doe//146096) // 365
      y = yoe + era*400; doy = doe - (365*yoe + yoe//4 - yoe//100)
      mp = (5*doy + 2)//153; d = doy - (153*mp + 2)//5 + 1
      m = mp + 3 if mp < 10 else mp - 9
      return (y + 1 if m <= 2 else y, m, d)
  ```
- **timestamp 実測**: 2000-01-01 00:00:00 → 0、2024-01-02 03:04:05.678901 → `0002b0ec85204f35`、1969-12-31 23:59:59.999999 → `fffca2fec4c81fff`、0001-01-01 00:00:00 BC → `ff1fc63d1bb12000`、4713-01-01 00:00:00 BC → `fd0f7fbdaf17e000`、294276-12-31 23:59:59.999999 → `7fffff5bb3b29fff`、10000-01-01 → `0380e70b913b8000`。
  テキスト: `YYYY-MM-DD HH:MM:SS[.f{1,6}]`、**小数は末尾ゼロを削る**（`03:04:05`、`03:04:05.5`、`03:04:05.000001`）、BC は ` BC` 後置（`0001-01-01 00:00:00 BC`）
- **timestamptz**: バイナリは **TimeZone に依らず同一**（Z1 / Z3 / Z5 / Z7 で `0002b0ec85204f35` が 4 回）。テキストは TimeZone 依存で、オフセットは **`+00` / `+09` / `+05:30` / `-03:30` / `+05:53:28` / `+00:19:32` の 3 幅**（分・秒が 0 なら省略）、**` BC` はオフセットの後**（`0001-01-01 00:00:00+00 BC`）。入力に `-03:00:30` のような秒付きも受ける（Z11: `06:04:35+00`）。バイナリ param で送った値はサーバーが UTC として解釈（P3c: Tokyo 設定下で `21:34:56.789+09`）。番兵は `infinity` / `-infinity`
- **time**: `00:00:00` → 0、**`24:00:00` → 86400000000（有効値）**、`23:59:59.999999` → 86399999999、`12:34:56.5` → `0000000a8be1bd20`。範囲外（86400000001）は `22008`。テキストは `HH:MM:SS[.f{1,6}]`（末尾ゼロ削り）
- **timetz** `int64 time, int32 zone`: zone は **UTC の西が正**（`+09` → `ffff8170` = -32400、`-03:30` → `00003138` = 12600、`+05:53:28` → `ffffad28` = -21208、`-15:59` → `0000e0c4`、`+15:59:59` → `ffff1f01`、`+00:00:01` → `ffffffff`）。範囲 |zone| < 57600（`+16:00` 入力は `22009`、zone -60000 param も `22009`）。`24:00:00+09` は有効。テキストは `HH:MM:SS[.f]±HH[:MM[:SS]]`
- **interval** `int64 micros, int32 days, int32 months`（この順）: `1 year 2 mons 3 days 04:05:06.789` → `000000036c97ca88 00000003 0000000e`（micros 14706789000、days 3、months 14）、`1 day` → `0 / 1 / 0`、`1 mon` → `0 / 0 / 1`、`1 year` → `0 / 0 / 12`、`-1 day 2 hours` → `00000001ad274800 ffffffff 0`。
  **テキスト（IntervalStyle postgres）の文法**（実測 25 例 + `EncodeInterval` / `AddPostgresIntPart`）:
  - `year = months // 12`（C の切り捨て除算 = 符号は months と同じ）、`mon = months % 12`、`day = days`、時刻部は micros を h / m / s / µs に切り捨て分解（**時刻部の符号は 1 つ**）
  - 非ゼロの year / mon / day を `<値> <単位>[s]` で空白区切り。複数形は **値 ≠ 1 のとき**（`-1 years` / `-1 mons` / `-1 days` / `2 years` / `1 mon`）
  - `+` 接頭辞は「**それより前に出した成分が負で、この成分が正**」のとき（`-1 years -2 mons +3 days -04:05:06`、`-1 days +02:00:00`、`-1 days +00:00:01`、`1 year -1 days +00:00:01`）。前が正なら `+` 無し（`1 day 12:00:00`、`1 mon -1 days`）
  - 時刻部は「他が全部 0」または「時刻部 ≠ 0」のとき出す: `[-]HH:MM:SS[.f{1,6}]`、**HH は 2 桁以上で上限なし**（`36:00:00`、`100 days 36:00:00`、`2562047788:00:54.775807`）、小数は末尾ゼロ削り（`.789`、`.5`、`.000001`）。全部 0 → `00:00:00`
  - 入力側の正規化（`1 year 13 mons` → `2 years 1 mon`、`1.5 days` → `1 day 12:00:00`、`36 hours` はそのまま `36:00:00`）はサーバーの仕事。本プロジェクトは出力文法だけ解釈する
  - **PG17**: `infinity` / `-infinity`（バイナリ `7fffffffffffffff 7fffffff 7fffffff` / `8000000000000000 80000000 80000000`）。PG14 は `'infinity'::interval` が 22007、全 MIN のバイナリ param は `22008 interval out of range`
- **uuid**: 16 byte 生。テキスト出力は小文字 `8-4-4-4-12`（入力は大文字も `{}` も可）。8 byte param は `08P01`
- **json / jsonb**: json は生テキスト（入力どおり `{"a":1}` 保持）。jsonb は **`01` + 正規化テキスト**（`{"a": 1}` 形式、キーはソート、重複キーは後勝ち、`"é"` は UTF-8 のまま `0122c3a922`、`null` → `016e756c6c`、`[]` → `015b5d`）。version 2 の param は `XX000`

#### 2.2.4 パラメータ送信（P1 / P2 / P4: 拡張型 8 種をバイナリで `$1`〜 に送り `SELECT $1, ...`）
numeric `1.50` → テキスト `1.50`・バイナリ同一 / date 8825 → `2024-02-29` / timestamp 762525296789000 → `2024-02-29 12:34:56.789` / timestamptz 同値 → `... +00`（UTC 設定下）/ time 45296789000 → `12:34:56.789` /
timetz (45296000000, -32400) → `12:34:56+09` / interval (10800000000, 2, 1) → `1 mon 2 days 03:00:00` / uuid 16 byte → `a0eebc99-...` / jsonb `01{"a":1}` → `{"a": 1}` / json `{"a":1}` → `{"a":1}` /
テキスト `{"a": 1}` を `$11::json` / `$12::jsonb` に → 通る（REQ §4.4 の「json / jsonb は String で送る」は成立）。
numeric NaN / ±Inf / `-0.001` / `0.00`（dscale 2）もバイナリで送って同じテキストが返る。**±Inf だけはバイナリ echo が `...0020` になる**（§0-2c）

#### 2.2.5 サーバー側の不正バイナリ検出（E1〜E16、PG14 / 17 同一）
`22P03`（numeric digit 10000 / dscale 20000 / sign 0x1234）、`08P01`（numeric 長さ不足・ndigits 0xFFFF・uuid 8 byte・int4 2 byte）、`XX000`（jsonb version 2）、`22008`（time > 24h・date / timestamp 範囲外）、`22009`（timetz zone）、`22021`（text バイナリに不正 UTF-8 / NUL）、**bool byte 2 → `t`（受理）**。
本プロジェクトの encoder は自前型の不変条件で上記を出さない（§4 P6）。テストで「サーバーが弾く」ことを題材にするなら上の sqlstate を期待値にできる

#### 2.2.6 GUC（S 系）
既定 `ISO, MDY` / `postgres` / `Etc/UTC` / `integer_datetimes = on`。`SET DateStyle TO 'ISO, YMD'; SET IntervalStyle TO 'postgres'` → COMMAND_OK、cmd tag `SET`、`SHOW DateStyle` → `ISO, YMD`、`SHOW IntervalStyle` → `postgres`。
不正値は `22023`、接続はそのまま使える。`TimeZone` を変えてもバイナリは不変（Z 系）

#### 2.2.7 PG14 と PG17 の差（probe-binary の diff は version 行を除き 3 行）
1. interval の `±infinity`（PG17 のみ。§2.2.3）
2. `'9223372036854775807 microseconds'::interval` のテキスト入力が PG14 では `22015`（PG17 は `2562047788:00:54.775807`）— 本プロジェクトには影響なし（テキスト入力をサーバーに送らない）
3. 全 MIN の interval バイナリ param が PG14 では `22008`、PG17 では `-infinity`
numeric の NaN / ±Infinity、jsonb、timetz、date / timestamp の番兵は **両サーバーで同一**

### 2.3 Mojo 1.1.0 言語（probe-zerocopy ×7 / probe-types / probe-civil）

#### 2.3.1 zero-copy Row（REQ §4.5 の成立判定）
| 形 | 結果 |
|---|---|
| `Row[origin].get_bytes() -> Span[UInt8, Self.origin]`: `Pointer[UInt8, Self.origin](unsafe_from_address=addr)` → `Span[UInt8, Self.origin](unsafe_ptr=p, length=n)` | **コンパイル・実行 OK**（`héllo world` 12 byte、`b[0] = 104`） |
| `get_text() -> StringSlice[Self.origin]`: `StringSlice[Self.origin](unsafe_from_utf8=self.get_bytes())` | OK。`print(s)`、`String(s)`、`s.byte_length()`、`def f(s: StringSlice)` への受け渡しが通る |
| `var s = res[0].get_text(); _ = res^; print(s)` | **コンパイルが通り動く。deinit は `print(s)` の後**（生存延長。安全） |
| `var row = res[0]; _ = res^; row.get_text()` | 同上（既存 `Row` と同じ挙動） |
| `var s = res[0].get_text(); consume(res^); print(s)` | **`error: use of uninitialized value 'res'`**（`print(s)` の行、note は `var res` の宣言行） |
| `var s = res[0].get_text(); var r2 = res^; print(s)` | 同じエラー |
| `ref r = res; _ = res^; r._len()` | コンパイルが通り **deinit が先に走る**（use-after-free。`ref` は生存延長されない） |
| 実物 `pq.Result`: `var row = res[0]; _ = res^; row.get[Int32](0)` | コンパイルが通り `42 abc` が読める（`PQclear` は row の最後の使用の後）。**Phase 1 docstring の「コンパイルエラー」は不正確**（§5-4） |

→ **成立**。成立条件（REQ §4.5「`Result` を破棄した後にその slice を使うコードがコンパイルエラー」）は「`Result` を**消費する移動**（`var r2 = res^` / 関数へ `res^`）の後の使用」で満たし、`_ = res^` は破棄にならないことを docstring とテストに書く。
陽性対照（PROGRESS に貼る）は `scratch/turn-001-probe-zerocopy-neg4.mojo` / `-neg6.mojo` の形。unsafe な代替は不要

#### 2.3.2 型・API の事実（probe-types）
§0.5 の ☆ 項目のとおり。加えて: `decode[T]` の `comptime if T == Date / UUID / Int` が `rebind[T](v).copy()` で通る / `Date(Copyable, Movable, Equatable, Writable)` は `__eq__` + `__ne__` + `write_to` で満たせる（`@fieldwise_init` 可）/
`Array[UInt8, 16]` フィールドを持つ struct は `Copyable` にできる / `Int32.MAX` 等の定数あり / `Int64.MIN // 1000000 == -9223372036855`、`% == 224192`（床） / `Optional[Date]` の `@implicit` が `Date` の `@implicit` と共存し、`var opt: Optional[Date] = None` を渡せる

#### 2.3.3 Phase 2 からの変更無し
`_ParamBuffers`（`params.mojo:394-531`）は `formats` / `lengths` / `types` を既に持つので、拡張型の `Param` ctor は `encode_*` を足すだけ。`PQexecParams` / `PQexecPrepared` の最後の `c_int(0)` を `c_int(result_format.value)` に替えるだけで結果形式が切り替わる（`connection.mojo:362`、`prepared.mojo:188`）。`_ffi` の追加バインドは不要（`PQfformat` / `PQgetlength` / `PQftype` は `functions.mojo:98-110` に済み）

### 2.4 ベンチ baseline（probe-bench、3 回ずつ）
| サーバー | text（exec + 全セル `PQgetvalue`/`PQgetlength`） | binary |
|---|---|---|
| PG17 | 41〜43 ms + 1 ms | 36〜38 ms + 1 ms |
| PG14 | 42〜45 ms + 1 ms | 39 ms + 1 ms |
`PQclear` は 0 ms。`std.time.perf_counter_ns()` が使える。**REQ §4.6 のベンチは Mojo 側の decode 込みでも数百 ms** の見込み。「バイナリが速い」の合否判定は Phase 5（HANDOFF §8）

## 3. 盗める設計 / 使えるライブラリ（plan が採否表にする）

1. **`Decimal` のテキスト化 = asyncpg `numeric.pyx:141-298` / PG `get_str_from_var`**: sign → 整数部（weight < 0 なら `0`、そうでなければ digits[0] を先頭ゼロ抑制、digits[1..weight] を 4 桁ゼロ埋め、足りないグループは `0000`）→ dscale > 0 なら `.` + 小数部（digits[weight+1..] を 4 桁ゼロ埋めで並べ、**dscale ちょうどに切る / 0 埋め**）。special は `NaN` / `Infinity` / `-Infinity`。bignum 不要
2. **`Decimal` のテキスト解釈 = PG `set_var_from_str :7212-7217` の式**（asyncpg encode と同じ）: `dweight = 整数部桁数 - 1`（先頭ゼロを除く。整数部が 0 なら小数部の先頭ゼロ数で負に）、`weight = (dweight+4)//4 - 1`（dweight ≥ 0）/ `-((-dweight-1)//4 + 1)`、`padding = (weight+1)*4 - (dweight+1)`、`ndigits = (桁数 + padding + 3)//4`、`dscale = 小数部桁数`。
   先頭・末尾のゼログループは落とし、0 は `ndigits 0, weight 0, sign POS` に正規化（PG `make_result`）。**`Decimal.__eq__` は正規化後の (sign, weight, digits) の一致**（dscale は見ない）で `numeric_eq` と同じ
3. **暦算法 = Hinnant（§2.2.3 のコード。komira の床除算版）**。`Date.from_ymd` の範囲検査は `1 <= m <= 12`、`1 <= d <= days_in_month(y, m)`、結果が `-2451545..2145031948` に収まること（REQ「範囲外は USAGE」）
4. **timestamp の分解**: `days = us // 86400000000`、`rem = us - days*86400000000`（0 ≤ rem < 1 日）、`civil_from_days(days)`、`rem` を h / m / s / µs に。negative micros は床除算で自然に前日に落ちる（1969-12-31 23:59:59.999999 で実測）
5. **interval のテキスト化 = `interval2itm` + `AddPostgresIntPart`**（§2.2.3 の文法。`is_before` フラグ 1 つで `+` を決める）。テキスト解釈はその文法の逆（`N unit` の繰り返し + 任意の `[+-]H+:MM:SS[.f]` + PG17 の `infinity`）。**months は日に畳まない**（psycopg / asyncpg 既定の非可逆化を避ける）
6. **timetz のオフセット**: 送受とも符号反転（`offset_secs = -utcoffset`）、**秒を保つ**（psycopg `datetime.py:130,376`。asyncpg の `/60` は踏まない）。テキストは `±HH[:MM[:SS]]` の 3 幅を `EncodeTimezone` の規則（分・秒が 0 なら省略）で
7. **番兵を第一級の値に**（asyncpg `datetime.pyx:29-59`）: `Date(Int32.MAX)` / `Timestamp(Int64.MAX)` / PG17 `Interval(MAX, MAX, MAX)`。`is_infinite()` が真なら分解アクセサは使わない（REQ: `year()` 等は有限値用。plan が「無限で呼んだら USAGE か番兵値か」を決める。推奨 USAGE）
8. **固定長の厳密検査**（rust-postgres "not drained"、uuid 16 byte）: `decode_binary` は `PQgetlength` と型の固定長を比較し、不一致は `TYPE_MISMATCH`（期待長と実長入り）。numeric は `8 + 2*ndigits` と一致、timetz 12、interval 16、jsonb ≥ 1
9. **未対応 OID の扱い**: psycopg はバイナリで生バイトにフォールバックするが、本プロジェクトは D9 で `TYPE_MISMATCH`（OID と「text 形式で取り直せ」を含む）。X1 の 7 型がテストの題材
10. **`_ParamBuffers` / `exec_fmt` の雛形**: probe-binary の `Params` / `exec_fmt`（`resultFormat` 引数付き）がそのまま。`ResultFormat` は `PgErrorKind` と同じ `@fieldwise_init struct ResultFormat(Equatable, TrivialRegisterPassable, Writable)` + `comptime TEXT = Self(0)` / `BINARY = Self(1)`
11. **zero-copy の 3 行**（§2.3.1）: `Pointer[UInt8, Self.origin](unsafe_from_address=Int(PQgetvalue ptr))` → `Span(unsafe_ptr=, length=PQgetlength)` → `StringSlice(unsafe_from_utf8=)`。`get_text` はテキスト形式または文字列系 OID（jsonb は version byte を 1 つ飛ばす）のみ、それ以外は `TYPE_MISMATCH`

## 4. 落とし穴と検証方法（plan は完了基準に写す）

| # | 落とし穴 | 回避策 | どう検証すれば踏んでいないと分かるか |
|---|---|---|---|
| P1 | numeric ±Inf のバイナリに dscale 32 が入っている（§0-2c） | special は sign だけ見る。encode は dscale 0 | 単体: `0000 0000 d000 0020` → `Decimal` の `is_infinite()`、`String` = `Infinity`、`dscale() == 0`。往復: `[Decimal("Infinity")]` を `$1::numeric` で送り text / binary とも `Infinity`。**バイト比較ではなく値比較** |
| P2 | dscale と格納桁が一致しない（`0001 ffff 0000 0005 0001` = 0.0001 を dscale 5 で `0.00010`） | 文字列化で dscale ちょうどに埋める / 切る | 単体: 上記 → `0.00010`、`0000 0000 0000 0002` → `0.00`、`0001 fffe 0000 0005 03e8` → `0.00001`、`Decimal("1.50")` → dscale 2 digits [1, 5000] |
| P3 | 先頭グループ以外の 4 桁ゼロ埋め忘れ | §3-1 のとおり | 単体: `0003 0001 0000 0001 04d2 162e 2328` → `12345678.9`（`5678` の位置）、`1000000` の往復（末尾ゼログループ） |
| P4 | weight 32 / 32767 で中間 Int があふれる・`-weight` で panic | 桁は文字列で組み立てる（Int に畳まない）。weight は Int16 のまま保持 | 単体: `0001 0020 0000 0000 0064` → `1` + ゼロ 130 個（長さ 131）、weight `0x8000` の decode が raise せず文字列化できる（極端に長い出力は許容） |
| P5 | `Decimal.__eq__` が dscale を比較して `1.0 != 1.00` になる | 正規化後の (sign, weight, digits) 比較。NaN == NaN 真 | 単体: `Decimal("1.0") == Decimal("1.00")`、`Decimal("0") == Decimal("0.00")`、`Decimal("NaN") == Decimal("NaN")`、`Decimal("1") != Decimal("-1")`。サーバー: `SELECT 1.0::numeric = 1.00::numeric` と同じ真偽 |
| P6 | encoder が digit ≥ 10000 / dscale > 0x3FFF / 不正 sign を出す（サーバー 22P03） | `Decimal(String)` の parse で digit は 0..9999 に限られる。dscale > 16383 は parse で `USAGE`（PG の上限） | 単体: 16384 桁の小数文字列が `USAGE`。往復: §2.2.2 の表の全値を `$1::numeric` で送って同じテキスト |
| P7 | interval のワイヤ順を month 先頭と誤る | `micros, days, months` の順（§2.2.3） | 単体: `Interval(0, 1, 0)` → `00..00 00000001 00000000`、`Interval(0, 0, 1)` → `.. 00000000 00000001`。往復: `'1 day'` / `'1 mon'` を text / binary で `get[Interval]` して一致 |
| P8 | interval テキストの符号・複数形・`+` 規則 | §2.2.3 の文法 | 単体（11 ケース）: `(7200000000,-1,0)` → `-1 days +02:00:00`、`(-1000000,0,0)` → `-00:00:01`、`(0,-1,0)` → `-1 days`、`(0,1,0)` → `1 day`、`(14706789000,3,14)` → `1 year 2 mons 3 days 04:05:06.789`、`(0,0,-11)` → `-11 mons`、`(0,0,25)` → `2 years 1 mon`、`(0,0,0)` → `00:00:00`、`(360000000000,0,0)` → `100:00:00`、`(-500000,0,0)` → `-00:00:00.5`、`(0,1,-12)` → `-1 years +1 day`。サーバー: 同じ 11 値を `SELECT $1::interval` で text 取得し `String(Interval)` と一致 |
| P9 | interval の ±infinity が PG17 だけ（§2.2.7） | `Interval.is_infinite()` + テキスト `infinity` を受ける。PG14 テストは infinity を送らない | サーバー: `'infinity'::interval` を text / binary で取り `is_infinite()`、**`server_version() >= 170000` のときだけ**実行。PG14 では `Interval(Int64.MAX, Int32.MAX, Int32.MAX)` を送ると `22008`（kind=Server）を期待 |
| P10 | timetz の zone 符号（西が正）と秒の切り捨て | 符号反転 + 秒保持（§3-6） | 単体: `'12:34:56+09'` ↔ `(45296000000, -32400)`、`'12:00:00+05:53:28'` ↔ `(43200000000, -21208)`。サーバー: 両形式で一致 |
| P11 | time の 24:00:00 を範囲外にする | 上限は **含む**（0..86400000000） | 単体: `Time(86400000000)` の `String` = `24:00:00`、`Time(86400000001)` は ctor で `USAGE`（または decode で `TYPE_MISMATCH`） |
| P12 | date の BC・5 桁年・番兵 | `year <= 0` を `1 - year` + ` BC`、4 桁ゼロ埋め・上限なし | 単体: `-730485` → `0001-01-01 BC`、`-2451545` → `4714-11-24 BC`、`2921940` → `10000-01-01`、`2145031948` → `5874897-12-31`、`Int32.MAX` → `infinity`。parse はその逆 |
| P13 | timestamptz テキストの ` BC` がオフセットの後、オフセットが 3 幅 | parse: 末尾 ` BC` を先に剥がす → `[+-]` を `rfind` で探す（日付の `-` と区別するため**時刻部から**探す） | 単体: `0001-01-01 00:00:00+00 BC`、`2024-01-02 08:34:05.678901+05:30`、`1850-01-01 05:53:28+05:53:28`、`2024-01-01 23:34:05.678901-03:30` が全部 UTC micros に正規化され、Z 系の binary と一致 |
| P14 | 小数秒の桁数可変（`.5` = 500000 µs） | 読んだ桁数で `10^(6-n)` 倍 | 単体: `.5` → 500000、`.000001` → 1、`.123456` → 123456、7 桁は `TYPE_MISMATCH` |
| P15 | 非 ISO の DateStyle 文字列が来る（`SET` に失敗 / 利用者が後から変えた） | 接続直後の `SET` と、parse は ISO 文法以外を `TYPE_MISMATCH`（REQ §4.3） | サーバー: `conn.execute("SET DateStyle TO 'German'")` 後の `get[Date]` が `TYPE_MISMATCH`（メッセージに入力文字列）。`SHOW DateStyle` のテスト（REQ §4.7） |
| P16 | `Connection.open` の `SET` 失敗時の `PQfinish` 漏れ | `_adopt` の後、`SET` 失敗なら `PQfinish` して raise（REQ §4.7） | 再現は難しい（`SET` は普通失敗しない）。`test_leak` の connect ループが `SET` 込みになることで正常系の PQclear は保証。失敗経路はコードレビュー + 陽性対照は不要 |
| P17 | 多文 `SET` の片方だけ適用される想定 | 1 つの `PQexec` で 2 文（暗黙 tx で両方 or 無し。S4） | サーバー: `SHOW IntervalStyle` も `postgres` であることを `test_connection` に 1 件 |
| P18 | zero-copy の `_ = res^` が「ここで PQclear」にならない（§2.3.1） | docstring: `_ = res^` は生存マーカー、消費する移動がコンパイルエラー | 陽性対照: `var s = row.get_text(); var r2 = res^; print(s)` のコピーが `use of uninitialized value` で落ちる（PROGRESS に貼る）。正例: `get_text` の値が `get[String]` と一致 |
| P19 | `ref` 束縛の use-after-free（§0.5） | 公開 API は `ref` を返さない | コードレビュー: `src/pq` に `-> ref` が無い（`grep -c "-> ref" = 0` を `final_check.sh` に足すのは過剰。plan 判断） |
| P20 | `get_text` が不正 UTF-8 を `StringSlice` にする（client_encoding ≠ UTF8） | Phase 1 と同じ前提（`String(unsafe_from_utf8_ptr=)` も検証していない）。docstring に「client_encoding は UTF8 前提」 | `PQparameterStatus(conn, "client_encoding")` が `UTF8` であることを `test_connection` に 1 件（バインド済み）。それ以上は Phase 5 |
| P21 | `decode_binary` の長さ検査漏れ（numeric `8 + 2*ndigits`、timetz 12、interval 16、uuid 16、jsonb ≥ 1、固定長 1/2/4/8） | 各 decode の先頭で検査、メッセージに期待長と実長 | 単体: 各型で「長さ -1」「+1」「0」の 3 ケースが `TYPE_MISMATCH`。numeric は ndigits と実長の不整合（`0002 0000 0000 0002 0001`）も |
| P22 | jsonb の `get[String]` が version byte を残す / json に version byte を付ける | OID 3802 だけ先頭 1 byte（= 1 以外は `TYPE_MISMATCH`）を剥がす。param 送信は `String` のまま（テキスト）なので付けない | サーバー: `'{"a":1}'::jsonb` を binary で `get[String]` → `{"a": 1}`（正規化後）。`'{"a":1}'::json` → `{"a":1}`。単体: `02 7b7d` → `TYPE_MISMATCH` |
| P23 | 未対応 OID をバイナリで `get[String]` / `get[List[UInt8]]` が通ってしまう | OID 表で厳密に（D9） | サーバー（格子）: X1 の 7 型 × {`String`, `List[UInt8]`, `Int32`} が全部 `TYPE_MISMATCH` でメッセージに OID と `text` の文言。text 形式では `get[String]` が通る（Phase 1 規則） |
| P24 | bool のバイト 0 / 1 以外（サーバーは受理） | REQ どおり `TYPE_MISMATCH` | 単体: `02` → `TYPE_MISMATCH`（サーバーからは来ない値なので単体のみ） |
| P25 | テキストの `atol` が空白・`+` を黙って通す（§0.5） | 日時 / uuid / numeric の parse は桁位置で読む | 単体: `" 2024-01-02"`、`"+2024-01-02"`、`"2024-1-2"` が `TYPE_MISMATCH` |
| P26 | `Decimal(String)` が `1e5` / `0x10` / 空文字 / `.` / `-` を通す | D14 どおり拒否 | 単体: 5 ケース全部 `TYPE_MISMATCH`（decode 経由）/ `USAGE`（ctor 経由。plan が kind を決める。推奨: `Decimal(String)` ctor は `USAGE`、decode は `TYPE_MISMATCH`） |
| P27 | `Date.from_ymd(2024, 2, 30)` 等の範囲外を通す | `days_in_month` 検査 + 結果範囲検査 | 単体: `(2024,2,30)`、`(2023,2,29)`、`(2024,13,1)`、`(2024,0,1)`、`(5874898,1,1)` が `USAGE`。`(2024,2,29)` と `(0,1,1)`（1 BC）は通る |
| P28 | リークテストに Phase 3 の経路が無い | `test_leak` に「バイナリ execute（拡張型 7 列）」10,000 回 + zero-copy の `get_text` 経路を 1 ループ | 陽性対照: `Result.__deinit__` の `PQclear` を消したコピーで FAIL（Phase 2 と同じ手順。`scratch/turn-003-b-leakbranch.sh` が雛形） |
| P29 | `check` 4/6 段が新 example を回さない | `final_check.sh` の 4/6 に `examples/binary.mojo` を足す（`bench_formats.mojo` は足さない: 合否なし） | `pixi run check` のログに `examples/binary.mojo` の行 |
| P30 | ベンチの `generate_series` 列型（REQ: int4, int8, float8, text, timestamp） | probe-bench の SQL（`i::int4, i::int8, i::float8 / 3, 'row ' \|\| i::text, timestamp '2000-01-01' + i * interval '1 second'`） | `pixi run bench` が text / binary の ms を 1 行ずつ出す（PROGRESS に数値、単位 ms） |

## 5. 要件への影響（D7 により REQ 本文を直した箇所と、提案に留めた箇所）

**直した（REQUIREMENTS.md に `（research turn 1 訂正）` 印）**:
1. §4.3 interval 行: PG17 の ±infinity（番兵 = 3 フィールド全 MAX / 全 MIN、テキスト `infinity`、`is_infinite()`）を追加。PG14 には無い旨
2. §4.3 の「日時系の ±infinity」に interval（PG17）を含める旨と、timestamptz テキストの ` BC` がオフセットの後である旨
3. §4.3 Decimal 行: バイナリの ±Infinity は dscale=32 で来る（無視する）、encode は 0 を送る、往復テストは値比較
4. §4.5 / §5.1 / §5.2: zero-copy の成立条件を「`Result` を**消費する移動**（`var r2 = res^` / 関数へ `res^`）後の使用がコンパイルエラー」に明確化し、`_ = res^` は生存延長で安全（エラーではない）と注記
5. §6 持ち越し整理に 10 番を追加: `result.mojo` / `Row` / `PreparedStatement` / `Transaction` の docstring の「`Result`（`Connection`）より長生きするのはコンパイルエラー」を「消費する移動がコンパイルエラー。`_ = x^` は生存延長」に

**提案（REQ は変えていない。plan が採否を決める）**:
6. §4.3 `Decimal(String)` の拒否 kind: ctor 経由は `USAGE`、decode 経由は `TYPE_MISMATCH`（P26）。無限値での分解アクセサ呼び出しは `USAGE`（§3-7）
7. §5.1 の境界値に **time `24:00:00`**、**timetz `+05:53:28`**、**interval の `-1 years +1 day`（複数形 + `+` 規則）**、**numeric `0.00`（ndigits 0, dscale 2）** を足す（P8 / P10 / P11 / P2）
8. §4.7 `test_connection` に `SHOW IntervalStyle` = `postgres` と `client_encoding` = `UTF8` を各 1 件（P17 / P20）
9. §5.1 の「拡張型 8 種を `$1` で送り同じ値が返る」の interval infinity は PG17 限定（`server_version()` で分岐。P9）
10. §4.6 ベンチの SQL は probe-bench のものを採用（P30）

## 6. plan への申し送り

- **モジュール配置案**: `types.mojo`（`Decimal` / `Date` / `Timestamp` / `TimestampTz` / `Time` / `TimeTz` / `Interval` / `UUID` + 共通の暦算法 `_civil.mojo` か同ファイル内 private）、`decode_binary.mojo`（`decode_binary[T](ptr: CStr, length: Int, oid: UInt32)` + 型別 `decode_<pgtype>`）、
  `decode_text.mojo` に拡張型の分岐を追加（`Decimal(String)` 等の parse は types 側に置き decode_text は呼ぶだけ）、`encode_binary.mojo` に `encode_numeric / encode_date / ... / encode_uuid`、`result.mojo` に `ResultFormat` / `column_format` / `Row.get_text` / `get_bytes`、
  `params.mojo` に 8 型 × 2 の `@implicit`。`types.mojo` は 8 struct + parse / format で **1,500 行規模**になるので、plan は `types_numeric.mojo` / `types_datetime.mojo` / `types_uuid.mojo` の 3 分割を検討（サブエージェント並列化の単位になる）
- **テストファイル案**: `test_types.mojo`（サーバー不要: parse / format / `==` / 構築子の境界。P2〜P14、P25〜P27）、`test_decode_binary.mojo`（サーバー不要: バイト列 → 値、長さ検査 P21〜P24）、`test_encode_binary.mojo` に拡張型の往復（encode → decode）、
  `test_binary.mojo`（サーバー: text / binary 一致の格子・`column_format`・未対応 OID の格子 P23・パラメータ往復・PG17 分岐 P9）、`test_zero_copy.mojo`（サーバー: `get_text` / `get_bytes` 一致 + NULL + 非文字列 OID の `TYPE_MISMATCH`）、`test_connection` に GUC 2 件 + client_encoding、`test_leak` に 2 ループ（P28）。
  **サーバー不要のテストは `_ok[T]` / `_error_kind[T]` の雛形が `test_decode_text.mojo:10-80` にある**
- **期待値の出典**: 本書 §2.2 の hex と文字列を**そのまま**テストの期待値に写す（全部 PG17 / PG14 の実測）。テスト仕様の期待メッセージは 2 語以上の部分文字列で（REQ §9）
- **サブエージェント推奨本数**（REQ §9 の申し送り）: types の 3 分割 + decode_binary は並列 3〜4 本が自然。`result.mojo` / `connection.mojo` / `prepared.mojo` の結線（`result_format` 引数・`column_format`・`Row.get` の分岐）は 1 ファイル完結ではないが小さいので親が直接（0 本）。
  example / bench / docstring 整備は 0 本。依頼文には (a) 型パラメータをフルに書く、(b) `fmt` は親が統合後に 1 回、(c) scratch は `.gsd-lite/logs/phase3-binary-all-types/scratch/turn-NNN-<name>` を必ず入れる
- **陽性対照を完了基準に**: zero-copy（P18、`scratch/turn-001-probe-zerocopy-neg6.mojo` の形）、leak（P28）、fmt（Phase 2 と同じ）。verify は「消費する移動の後の使用」がコンパイルエラーになるコピーをその場で作って確かめる
- **PG17 限定ケースは `server_version() >= 170000` で分岐**（interval infinity のみ）。他は全て両サーバー同一
- **所要の目安**: probe-binary（約 330 行）の `mojo run` はコンパイル込み数秒。`test_leak` に 2 ループ足しても +5 s 程度（接続 1 本の使い回し）。ベンチは < 1 s
- **REQ §9 の verify 申し送り**: round 2 以降は round 1 の格子の再確認 + 差し戻し分の回帰に限定してよい
