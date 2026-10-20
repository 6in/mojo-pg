# RESEARCH — phase7-pool-copy-array

- 作成: 2026-10-20 / gsd-lite-research（turn 1）
- 入力: REQUIREMENTS.md / DECISIONS.md（D1〜D20）/ `archive/phase3-binary-all-types/RESEARCH.md`（19 型のワイヤ形式）/ `reflect/20261018-1252-phase6-packaging-ci.md`。
  `state.json.research.targets` = official_docs / similar_oss / local_projects（`~/workspaces`）
- 検証環境: Mojo 1.1.0 / pixi env の **libpq 18.6**（`PQlibVersion` = 180006）/ docker `postgres:17`（17.11、port 54317）と `postgres:14`（14.24、port 54314）/ linux-aarch64
- **プローブ**（`.gsd-lite/logs/phase7-pool-copy-array/scratch/turn-001-*`、gitignore 対象。結論は本書に転記済み）:
  - `probe-copy.mojo` + `.log` / `-pg14.log`: COPY の libpq API 9 ケース + `PQreset`（§2.4 / §2.5）。**PG17 と PG14 の出力は libpq / server 版行以外すべて同一**
  - `probe-pool.mojo` + `.log`: `PooledConnection[origin]` の試作（二重貸し出し / 再利用 / 返却時 ROLLBACK / 切断の検出 / 42P05）（§2.6）
  - `probe-array.mojo` + `.log`: `array_recv` 形式を手組みで送る 24 ケース + バイナリ受信 5 列（§2.3）
  - `probe-lang.mojo` / `probe-listmov.mojo` / `probe-thread.mojo` + `.log`: Mojo 1.1.0 の言語事実（§2.7）。`probe-thread` は期待どおりコンパイル失敗
  - psql（`docker exec tests-pg17-1 psql -U pq -d pq_test -At`）で typarray / 配列リテラル / `array_send` の hex（§2.1 / §2.2）
- 無人シェルの注意: `pixi` は **`/home/parallels/.pixi/bin/pixi run mojo run -I src <file>`**。lean-ctx MCP は未接続（素の Read / Bash で可）。GitHub のファイルは `gh api repos/<o>/<r>/contents/<path> --jq .content | base64 -d`。
  プローブは 1 本目（copy）が初回コンパイルで通り、残り 3 本の修正は §2.7 の言語事実そのもの（各 1〜2 回）

## 0. 結論サマリ（REQ §6 のプローブ 4 件 + 重大発見の有無）

| # | 問い | 結果 | 根拠 |
|---|---|---|---|
| (1) | Mojo 1.1.0 に `std.atomic` 以外の並行プリミティブが無いこと | **再確認**。`from std.threading import Thread` → `unable to locate module 'threading'`。`std.atomic.Atomic[Int]` は使える（型パラメータは `DType` でなく型） | `probe-thread.log`、`probe-lang.log` C |
| (2) | `PQputCopyData` / `PQputCopyEnd` / `PQgetCopyData` のシグネチャ | `libpq-fe.h:547-549`: `int PQputCopyData(PGconn*, const char*, int)` / `int PQputCopyEnd(PGconn*, const char *errormsg)` / `int PQgetCopyData(PGconn*, char **buffer, int async)`。Mojo 側は `def(PGconnPtr, CStr, c_int)` / `def(PGconnPtr, Int)`（NULL は 0）/ `def(PGconnPtr, Pointer[Int, MutUntrackedOrigin], c_int)` で**動作確認済み**（§2.4） | `probe-copy.mojo:55-78` |
| (3) | 配列のバイナリ形式（`array_send` / `array_recv`） | `int32 ndim, int32 flags(has_nulls 0/1), uint32 elemtype, {int32 dim, int32 lbound}×ndim, {int32 len(-1=NULL) + bytes}×n`。**空配列は ndim=0 でヘッダ 12 byte だけ**。サーバーの検査 10 種の sqlstate を実測（§2.3） | `probe-array.log`、`arrayfuncs.c` |
| (4) | 19 型の typarray OID | §2.1 の表。**PG14 と PG17 で同一**、`typdelim` は 21 型すべて `,` | psql |

- **作る（BLOCKED にしない）**。要件を満たす既存 OSS は無い。Mojo 製 `lee101/mojo-pg` は `pool.mojo` を持つが「`acquire(mut self) -> Conn` をムーブで渡し `release(c^)` を手で呼ぶ」形（D16 が却下した形）で、COPY は `"COPY FROM STDIN is not supported"`（`conn.mojo:598,696`）、配列デコードも無い。GitHub code search で `PQputCopyData` / `array_recv` を含む Mojo ファイルは **0 件**（§1.6）
- 設計上の重要発見（REQ の文言に影響。§5 に提案として整理）:
  1. **`Iterator.__next__` は `raises StopIteration` ちょうどでないとコンパイルしない** → `for row in copy_out` から `PgError` を伝播できない。`CopyOut` は `next() -> Optional[List[UInt8]]` + `while` を主 API にし、`Iterator` 適合は「エラーを溜めて `StopIteration` にする」形でしか作れない（§2.7 D、推奨: 作らない）
  2. **`PQreset` 後は `DateStyle` が `ISO, MDY` に戻る**（`IntervalStyle` は既定が `postgres` なので偶然同じ）→ `Connection.reset()` は `PQreset` + `PQstatus` 検査 + `_SESSION_SETUP_SQL` の再送が必須。健全な接続に `PQreset` すると**接続し直す**（backend_pid が変わる）ので BAD のときだけ呼ぶ（§2.5）
  3. **`PQstatus` は切られた直後の未使用接続で `CONNECTION_OK` のまま**。REQ §4.3「貸し出し中に `pg_terminate_backend` された接続を返却 → 捨てられる」は、**返却前にその接続を 1 回使って `CONNECTION` を観測した場合**にだけ成立する。使わずに返すと再利用され、次の利用者の最初の `execute` が `CONNECTION`、その返却で捨てられる（§2.6 H）。往復なしの代替は `PQconsumeInput`（EOF を読んで BAD にする。ただし FATAL メッセージを先に 1 回消費するので 2 回目で検出）（§2.6 H2）
  4. **`PQexec` を COPY 中に呼ぶと libpq が自分で COPY を終わらせる**（COPY IN は `CopyFail` 相当で**書いた行が黙って消える**、COPY OUT は読み捨て）→ REQ §2.2 の `USAGE` 検査は「プロトコルを守るため」でなく「データを失わないため」。`Transaction.__deinit__` の `ROLLBACK` も同じ経路（§2.4 case 5）
  5. **`List[Connection]` は作れる**（`List[T]` の要件は `Movable` だけ。`pop()` で所有権が戻る）→ プールは `Connection` をそのまま保持してよい。ハンドルをばらすと `_stmt_counter` が 0 に戻り、再利用時に `42P05 prepared statement "pq_stmt_1" already exists` を踏む（§2.6 D/E で陽性対照あり）
  6. **ガードから `Transaction[origin_of(self)]` を返すには `Pointer(to=self._conn)` を `origin_of(self)` に rebind する**（`Pointer[Connection, origin_of(self)](unsafe_from_address=Int(Pointer(to=self._conn)))`）。`return self._conn.transaction()` は `cannot implicitly convert 'View[origin_of(self._res)]' value to 'View[origin_of(self)]'` で通らない（§2.7 E）
  7. COPY の所要: **100,000 行 × 5 列 text で COPY IN 63 ms / COPY OUT 34 ms**（両サーバー、4.5 MB）。`check` の時間予算（Phase 6 実測 169〜190 s / 閾値 247 s）に対して無視できる

## 0.5 環境・ハーネス + Mojo 1.1.0 の落とし穴（Phase 3〜6 の転記 ★ + 今回の追加 ☆）

- ★ `pixi` は絶対パス / `rg` 無し → `grep` / `curl` 無し → `gh api` / `/tmp` 不可 → `.gsd-lite/logs/<slug>/scratch/`
- ☆ **`Iterator.__next__` の型は `def(mut self) raises StopIteration -> Element` ちょうど**。`raises`（無型）にすると `'Lines' does not implement all requirements for 'Iterator'` / `error type of the first type is 'StopIteration' but the second type is 'Error'`。さらに **`Iterator` 単体は `for` に使えない**（`does not implement the '__iter__' method`）: `for` には `Iterable`（`Result` の `IteratorType[iterable_mut, //, iterable_origin]` + `__iter__(ref self)` の形）が要る
- ☆ **名前付きの `List` 値をリスト literal に並べると `cannot be implicitly copied, it does not conform to 'ImplicitlyCopyable'`** → `[ids^, ...]` か `[ids.copy(), ...]`（既存テストは `Param(blob.copy())`、`tests/test_params.mojo:528`）。`PgError` / `Optional[PgError]` も同じ（`.copy()`）
- ☆ **フィールド経由の origin は `origin_of(self)` に暗黙変換されない**: `Pointer(to=self._conn)` は `Pointer[Connection, origin_of(self._conn)]`。struct のパラメータに入れるには `Pointer[Connection, origin_of(self)](unsafe_from_address=Int(Pointer(to=self._conn)))`（`Int(Pointer(to=x))` は通る）。`Transaction.prepare` が `_prepare_parts` に分けている理由と同じ現象
- ☆ **`List[T]` は `T: Movable` で足りる**（literal ctor の `where conforms_to(T, Movable)`、copy ctor だけ `Copyable`）。`List[Connection]` / `List[Res(Movable)]` が compile し `pop()` で所有が戻る、deinit は要素ごとに走る（`probe-listmov.log`）
- ☆ 不変借用 `ref self` のまま List フィールドを書き換える escape hatch: `Pointer[List[Int], MutUntrackedOrigin](unsafe_from_address=Int(Pointer(to=self._idle)))[].append(x)`（`_next_stmt_name` の一般化。§2.7 E / §2.6 A で動作）
- ☆ `__deinit__(deinit self)` の中で `self._conn^` とフィールドをムーブして関数に渡せる（ガードの自動返却の形）
- ☆ `@implicit __init__(out self, var v: String)` と `__init__(out self, var tag: String)` は同じシグネチャで衝突 → 片方を keyword-only（`*, tag`）に
- ☆ `Atomic[Int]`（`Atomic[T: Deinitable & Movable]`、`DType` は不可）。`std.time.monotonic()` は ns の `Int`（秒は `// 1_000_000_000`）
- ☆ nullable な `const char*` 引数は `def(PGconnPtr, Int) thin abi("C")` にして `0` を渡せばよい（`PQputCopyEnd`）。`char **` 出力引数は 1 要素の `List[Int]` セルの `unsafe_ptr()` を `Pointer[Int, MutUntrackedOrigin]` にして渡し、戻ったアドレスを `Pointer[UInt8, ImmUntrackedOrigin](unsafe_from_address=)` で読んでから `PQfreemem(MutRawPtr(...))`
- ☆ **`PQerrorMessage(conn)` は失敗した libpq 呼び出しごとに追記される**（libpq 14+ の仕様。閉じた fd に `PQputCopyData` を 40 回呼ぶと同じ行が 125 回並んだ）→ `-1` を見たら**二度と呼ばない**。さらに最後のサーバーエラー（`ERROR: missing data for column "c"` + `CONTEXT`）は次のコマンドまで残る
- ☆ `var st = start(...)` のように使わない変数は `warning: assignment to 'st' was never used` → `check` 6/6 段で数えられる。`_ =` に
- ☆ WebFetch の raw.githubusercontent は rust-postgres の `types.rs` が 404（パス移動）。postgres 本体の `arrayfuncs.c` は取れる（18 万字、先頭 10 万字で `array_recv` / `array_send` まで読めた）

## 1. 類似 OSS（similar_oss）

### 1.1 psycopg 3 配列（ローカル: `/home/parallels/workspaces/poc-amano/.venv/lib/python3.12/site-packages/psycopg/types/array.py`）
- テキストの tokenizer は正規表現 1 本（`:425-434`）: `[{}]` | `"(?:[^"\\]|\\.)*"` | `[^"{}<delim>\\]+` を `,?` 付きで `finditer`。`[...]=` 接頭辞は `=` まで捨てる（`:386-392`）。`NULL`（引用符なし）だけ None、引用符付きは `\\(.)` → `\1` で unescape してから要素 loader（`:411-416`）。ネストは stack（本プロジェクトは `{` のネストで `TYPE_MISMATCH`）
- バイナリ load（`:437-461`）: `!III`（ndims, hasnull, oid）→ ndims=0 なら `[]` → dims を読み `prod(dims)` 個、各要素 `int32 size`、-1 なら None。**hasnull は読むだけで使わない**（サーバーと同じ: NULL は -1 で判定）
- バイナリ dump（`:241-287`）: 空 list は `_pack_head(0, 0, sub_oid)`（**ndim 0、dims 無し**）、`hasnull` は NULL があれば 1、lbound は常に 1。テキスト dump の引用判定 regexp（`:195-209`）: 空文字 / `["{}<delim>\\\s]` / `^null$`（大小無視）
- 要素 OID → 配列 OID は `TypeInfo.array_oid`（= `pg_type.typarray`）。不明なら `TEXT_ARRAY_OID`（1009）にフォールバック（`:146,237`）。`List[String]` を 1009 で送る根拠
- → **盗む**: tokenizer の 3 分岐、`[..]=` の捨て方、NULL 判定規則、空配列 = ndim 0、hasnull を見ない

### 1.2 psycopg 3 COPY（同 `psycopg/_copy.py` / `_copy_base.py` / `generators.py`）
- `__exit__` → `finish(exc)`（`:72-78, 205-222`）: 例外があれば `put_copy_end(b"error from Python: ...")`、**その結果の `QueryCanceled`（57014）だけ握りつぶし、メッセージ無しのときの 57014 は raise**。REQ D11「`aborted by pq`」と同型
- `read()` は空バイト列で終端、`__iter__` は `while data := self.read()`（`:82-93`）。`write()` は `MAX_BUFFER_SIZE` で分割（`:196-203`、libpq のメモリエラー回避 #255）。`copy_end` / `copy_to` ジェネレータは `put_copy_end` / `put_copy_data` が 0 を返す間 write-ready を待つ（非同期用。同期では 0 は来ない: §2.4）
- → **盗む**: abort で 57014 だけ飲む・それ以外は上げる、終端後の `PQgetResult` を結果として保持

### 1.3 psycopg_pool（https://github.com/psycopg/psycopg `psycopg_pool/psycopg_pool/pool.py`、docs https://www.psycopg.org/psycopg3/docs/api/pool.html）
- 返却 `_return_connection` → `_reset_connection`: `transaction_status` が **IDLE: 何もしない / INTRANS・INERROR: `rollback()`（失敗なら close）/ ACTIVE: close（途中で返された）/ UNKNOWN: close して補充**。期限 `_expire_at <= monotonic()` なら close。= **D15 そのもの**
- `max_lifetime` 既定 3600 s（+ 乱数で分散）、`min_size` 既定 4 を open 時に**先に**開く（`_start_initial_tasks`）、枯渇時は `timeout`（既定 30 s）まで待って `PoolTimeout`（本プロジェクトは D13 で即 `USAGE`）、`check_connection` は `execute("")`（1 往復。D14 で却下）
- ローカル利用例: `copilot-langgraph/config/db_pools.yaml`（`min_size: 1 / max_size: 5 / max_idle: 300 / reconnect_timeout: 30`）— 利用側が触りたいノブの実例

### 1.4 pgx v5 `pgxpool/conn.go` `Release()`（https://raw.githubusercontent.com/jackc/pgx/master/pgxpool/conn.go）
- `if conn.IsClosed() || conn.PgConn().IsBusy() || conn.PgConn().TxStatus() != 'I' { destroy }` → **トランザクション中の返却は ROLLBACK せず捨てる**（psycopg は ROLLBACK）。寿命超過（`isExpired`）も destroy。`AfterRelease` フックが false なら destroy
- → 本プロジェクトは psycopg 流（D15）。pgx の「busy は捨てる」= REQ の「ACTIVE は捨てる」

### 1.5 deadpool-postgres `RecyclingMethod`（https://docs.rs/deadpool-postgres/latest/deadpool_postgres/enum.RecyclingMethod.html）
- 既定 **Fast** = `is_closed()` だけ（= D14「往復しない」）/ Verified = + テストクエリ / Clean = Verified + `CLOSE ALL; SET SESSION AUTHORIZATION DEFAULT; RESET ALL; UNLISTEN *; SELECT pg_advisory_unlock_all(); DISCARD TEMP; DISCARD SEQUENCES;`（`DISCARD ALL` から `DEALLOCATE ALL` / `DISCARD PLAN` を抜いた形）
- → README「既知の制限」の文言に使える: 残るのは GUC / prepared / 一時テーブル / LISTEN / advisory lock

### 1.6 Mojo 製（`lee101/mojo-pg`、2026-10-20 時点）
- `src/pg/pool.mojo`: `struct Pool(Movable)` / `open(dsn, size)` / **`acquire(mut self) raises -> Conn`（ムーブで渡す）/ `release(mut self, var c: Conn)`（中で `ROLLBACK`）**、`query(mut self, ...)` が acquire→exec→release を包む。`mut self` なので貸し出し中にプールを触れない。返し忘れの保護無し = D16 の却下案
- `src/pg/conn.mojo:598,696`: `"COPY FROM STDIN is not supported"`。`conv.mojo` に配列無し
- GitHub code search `PQputCopyData language:Mojo` / `array_recv OR typarray language:Mojo` → **0 件**。採用する依存は無し

### 1.7 PostgreSQL 公式（§2 の出典）
- `src/backend/utils/adt/arrayfuncs.c`（REL_17_STABLE）`array_recv` / `ReadArrayBinary` / `array_send`（§2.3）、docs `arrays.html` §8.15.6（§2.2）、`libpq-copy.html`（§2.4）

### 1.8 ローカルプロジェクト（local_projects、`~/workspaces`）
- **`pgbkrs`（Go / pgx）**: `internal/export/csv.go:29-48` `COPY "s"."t" TO STDOUT WITH (FORMAT CSV)` を `PgConn().CopyTo(ctx, w, sql)` で `io.Writer` に流し、**行数は CommandTag から**（= `finish().affected_rows()` の発想）。`internal/restore/orchestrator.go:355-392` `COPY ... (cols) FROM STDIN WITH (FORMAT CSV)` を `CopyFrom(ctx, f, sql)` でファイルから。`backup/orchestrator.go:65-66` は REPEATABLE READ トランザクションの中で COPY TO（= REQ「トランザクション内 COPY」の実需）
- **`poc-amano/scripts/03_load_raw.py:57-107`**（psycopg）: `cur.copy("COPY raw.t (cols) FROM STDIN WITH (FORMAT text, HEADER, NULL '\\N')")` に `copy.write(block)` でブロック書き込み / `copy.write_row([...])`。本プロジェクトは `write` 相当だけ（D10）
- `copilot-langgraph/config/db_pools.yaml`: §1.3
- Phase 5 の堅牢性格子の雛形: `.gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-010-robust-grid.sh`（入力クラス × 出力先（`/dev/full` / closed / broken pipe）× 成功/失敗。`report()` が rc / 行数 / `traceback|unhandled|abort|segfault|...` の件数を出す）

## 2. 公式ドキュメント + 検証結果（official_docs）

### 2.1 typarray OID（`SELECT oid, typname, typarray, typdelim FROM pg_type`、PG17 = PG14）

| 要素 | OID | 配列 OID | 要素 | OID | 配列 OID |
|---|---|---|---|---|---|
| bool | 16 | **1000** | bpchar | 1042 | **1014** |
| bytea | 17 | **1001** | varchar | 1043 | **1015** |
| name | 19 | **1003** | date | 1082 | **1182** |
| int8 | 20 | **1016** | time | 1083 | **1183** |
| int2 | 21 | **1005** | timestamp | 1114 | **1115** |
| int4 | 23 | **1007** | timestamptz | 1184 | **1185** |
| text | 25 | **1009** | interval | 1186 | **1187** |
| json | 114 | **199** | timetz | 1266 | **1270** |
| float4 | 700 | **1021** | numeric | 1700 | **1231** |
| float8 | 701 | **1022** | uuid | 2950 | **2951** |
| | | | jsonb | 3802 | **3807** |

- `typdelim` は 21 型すべて `,`。`pg_typeof(ARRAY['a'::varchar])` = `character varying[]`（1015）、`ARRAY['a'::name]` = `name[]`（1003）、`'{a}'::text[]` = 1009 → **`List[String]` は 6 つの配列 OID（1009 / 1015 / 1014 / 1003 / 199 / 3807）を受ける**（スカラの `String` と同じ 6 つ）
- `ARRAY[]::text[]` のバイナリは `00000000 00000000 00000019`（ndim 0、elemtype 25）で `PQftype` = 1009。`'{}'::int4[]` も ndim 0 / 1007

### 2.2 配列のテキスト形式（docs §8.15.6 + psql 実測、`DateStyle = ISO, YMD` / `IntervalStyle = postgres` 下）

docs の規則（引用）: 「The array output routine will put double quotes around element values if they are **empty strings, contain curly braces, delimiter characters, double quotes, backslashes, or white space, or match the word NULL**」「Double quotes and backslashes embedded in element values will be backslash-escaped」「If the value written for an element is NULL (in any case variant), the element is taken to be NULL. The presence of any quotes or backslashes disables this」「The array output routine will include explicit dimensions in its result only when there are one or more lower bounds different from one」「You can add whitespace before a left brace or after a right brace. You can also add whitespace before or after any individual item string」

| 入力 | テキスト出力（実測） | 読み |
|---|---|---|
| `ARRAY['a','b,c','d"e','f\g','', 'NULL', 'null', ' x ','{y}']::text[]` | `{a,"b,c","d\"e","f\\g","","NULL","null"," x ","{y}"}` | 引用の 7 条件すべて。`\"` / `\\` の escape |
| `ARRAY['a',NULL,'b']::text[]` | `{a,NULL,b}` | NULL 要素は引用なし大文字 |
| `'[0:1]={7,8}'::int4[]` | `[0:1]={7,8}` | lbound ≠ 1 の接頭辞（`array_lower` = 0、`= ARRAY[7,8]` は偽） |
| `ARRAY[[1,2],[3,4]]` | `{{1,2},{3,4}}` | 多次元 = `{` のネスト |
| `'{}'::int4[]` / `ARRAY[]::text[]` / **`'{{}}'::int4[]`** | `{}` / `{}` / **`{}`** | 空の多次元も `{}`（`array_ndims('{}')` は NULL） |
| `ARRAY['\x00ff'::bytea, ''::bytea]` | `{"\\x00ff","\\x"}` | **bytea の `\x` は `\\x` に escape される** → unescape 後に `parse_bytea_hex` |
| `ARRAY['2024-01-02 03:04:05'::timestamp,'infinity','-infinity']` | `{"2024-01-02 03:04:05",infinity,-infinity}` | 空白で引用。`infinity` は引用なし |
| `ARRAY['2024-01-02 03:04:05+09'::timestamptz]` | `{"2024-01-01 18:04:05+00"}` | |
| `ARRAY['1 year 2 mons 3 days 04:05:06'::interval,'-1 days']` | `{"1 year 2 mons 3 days 04:05:06","-1 days"}` | |
| `ARRAY['NaN'::numeric,'Infinity','-Infinity',1.50]` | `{NaN,Infinity,-Infinity,1.50}` | NaN は `NULL` に一致しないので引用なし |
| `ARRAY['NaN'::float8,'Infinity','-Infinity',-0,1e300]` | `{NaN,Infinity,-Infinity,0,1e+300}` | `-0` は整数 0（float の `-0` は Phase 3 のとおり） |
| `ARRAY['ab'::char(5),'cde']::bpchar[]` | `{"ab   ",cde}` | **padding 込み**で空白→引用 |
| `ARRAY['{"a": 1}'::jsonb,'[]']`, `ARRAY['{"a":1}'::json]` | `{"{\"a\": 1}",[]}`, `{"{\"a\":1}"}` | jsonb は正規化 + 引用 escape |
| `ARRAY['a0eebc99-...'::uuid]` / `ARRAY[true,false]` / `ARRAY['12:34:56+09'::timetz]` / `ARRAY['24:00:00'::time]` / `ARRAY['2024-02-29'::date,'0001-01-01 BC']` | `{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11}` / `{t,f}` / `{12:34:56+09}` / `{24:00:00}` / `{2024-02-29,"0001-01-01 BC"}` | ` BC` の空白で引用 |
| `ARRAY['tab\there','nl\nhere','é']::text[]`（`\t` はリテラルの backslash-t） | `{"tab\\there","nl\\nhere",é}` | 非 ASCII は引用なし |
| `'{ 1 , 2 }'::int4[]` / `'{"1","2"}'::int4[]` / `'{1,2}'::int2[]` | `{1,2}` × 3 | 入力の空白・引用は出力で消える |

- サーバーが弾く不正リテラル（`SELECT '<lit>'::int4[]`、全て `22P02`）: `{1,2` → `malformed array literal ... Unexpected end of input` / `{"abc}` → 同 / `{1,,2}` → `Unexpected "," character` / `{1,2}}` → `Junk after closing right brace` / `{a}` → `invalid input syntax for type integer`。**これらは `PQgetvalue` には来ない**（サーバー出力は常に正規形）ので、本プロジェクトのパーサーの不正形テストは単体テストだけで足り、期待 kind は `TYPE_MISMATCH`
- `SELECT 3 = ANY('{1,2,3}'::int4[])` → `t`。`ARRAY[1,2] = ANY(ARRAY[ARRAY[1,2]])` は `operator does not exist`（多次元を `= ANY` で使う形は無い）

### 2.3 配列のバイナリ形式（`array_send` / `array_recv` + probe-array 24 ケース、PG17。要素型の中身は Phase 3 RESEARCH §2.2 のまま）

`array_send` が書く順（`arrayfuncs.c`）: `int32 ndim` / `int32 flags`（NULL があれば 1）/ `Oid elemtype` / `{int32 dim, int32 lbound} × ndim` / 要素ごとに `int32 len`（NULL は -1、本体なし）+ typsend の payload（bytea ヘッダ無し）。**ndim = 0 なら 12 byte で終わり**。

| 列 | hex（`array_send`） | 読み |
|---|---|---|
| `ARRAY[1,2,3]::int4[]` | `00000001 00000000 00000017 00000003 00000001 00000004 00000001 00000004 00000002 00000004 00000003` | ndim 1, flags 0, 23, dim 3, lb 1 |
| `'{}'::int4[]` | `00000000 00000000 00000017` | **12 byte** |
| `ARRAY[1,NULL,3]` | `00000001 00000001 00000017 00000003 00000001 00000004 00000001 ffffffff 00000004 00000003` | flags 1、NULL は `ffffffff` |
| `'[0:1]={7,8}'` | `00000001 00000000 00000017 00000002 00000000 ...` | lb 0 |
| `ARRAY[[1,2],[3,4]]` | `00000002 00000000 00000017 00000002 00000001 00000002 00000001 ...4 要素` | ndim 2（行優先で平坦） |
| `ARRAY['a','b,c','d"e','f\g','','NULL','null',' x ','{y}']::text[]` | `00000001 00000000 00000019 00000009 00000001 00000001 61 00000003 622c63 00000003 642265 00000003 665c67 00000000 00000004 4e554c4c ...` | 空文字は len 0、escape 無し |
| `ARRAY['tab\there','é',NULL]::text[]` | `... 00000009 7461625c74686572 00000002 c3a9 ffffffff` | |
| `ARRAY[1.5]::numeric[]` | `... 000006a4 00000001 00000001 0000000c 0002 0000 0000 0001 0001 1388` | 要素 = `numeric_send` 12 byte |
| `ARRAY['ab'::char(5)]::bpchar[]` | `... 00000412 ... 00000005 6162202020` | padding 込み 5 byte |
| `ARRAY['{"a":1}'::jsonb]` | `... 00000eda ... 00000009 01 7b2261223a20317d` | **要素ごとに version byte `01`** → 要素を `decode_binary[String](bytes, 3802)` に渡せば剥がれる |
| `ARRAY['1 day'::interval]` | `... 000004a2 ... 00000010 0000000000000000 00000001 00000000` | 16 byte |
| `ARRAY[true]` / `ARRAY['\x00ff'::bytea]` | `... 00000010 ... 00000001 01` / `... 00000011 ... 00000002 00ff` | |

**`array_recv` の検査と sqlstate（手組みの payload を `Param(oid, binary=True)` で送って実測。`SELECT $1::int4[]`）**:

| ケース | 結果 |
|---|---|
| ndim 1 / lb 1 / {1,2,3}（oid 1007） | `{1,2,3}`、`SELECT 2 = ANY($1::int4[])` → `t` |
| ndim 0（flags 0 / 1 とも） | `{}` |
| NULL 要素（len -1）、**flags 0 でも 1 でも** | `{1,NULL,3}`（NULL 判定は -1 のみ。flags は 0/1 の検査だけ） |
| flags 2 | **`22P03` invalid array flags** |
| elemtype 21 / 0 を oid 1007 で | **`42804` binary data has array element type 21 (smallint) instead of expected 23 (integer)**（0 は `0 (-)`） |
| ndim 2（2×2） | `{{1,2},{3,4}}`（受理。本プロジェクトは送らない） |
| lbound 0 | `[0:2]={1,2,3}`（受理・保持） |
| dim 3 で要素 2 個 | **`08P01` insufficient data left in message** |
| 要素 len 5（int4） | **`22P03` improper binary format in array element 1** |
| 要素 len 2（int4） | `08P01 insufficient data left in message` |
| ndim -1 | `22P03 invalid number of dimensions: -1` |
| ndim 7 | **`54000` number of array dimensions (7) exceeds the maximum allowed (6)** |
| ndim 1 / dim 0 | `{}` |
| dim -1 | `54000 array size exceeds the maximum allowed (134217727)` |
| int4 の payload を oid 1005（int2[]）で | `42804 ... element type 23 (integer) instead of expected 21 (smallint)` |
| oid 1007 を **型指定なしの `$1`** に | `{1,2,3}`、結果 OID 1007（`paramTypes` が効く） |
| oid 1007 を `$1::int8[]` に | `{1,2,3}`、結果 OID 1016（配列の assignment cast は通る） |
| text[]（oid 1009、elemtype 25）7 要素 | `{a,"b,c","","NULL","d\"e","f\\g",é}`、`'b,c' = ANY($1::text[])` → `t` |
| elemtype 25 を oid 1015（varchar[]）で | `42804 ... element type 25 (text) instead of expected 1043 (character varying)` → **`List[String]` は 1009 + 25 で送る**（`$1::varchar[]` へのキャストは `1007 → int8[]` と同じ経路で通る見込み。impl で 1 回確かめる） |

- バイナリ受信（`get_bytes` で確認）: `ARRAY[1,NULL,3]::int4[]` = `00000001 00000001 00000017 00000003 00000001 00000004 00000001 ffffffff 00000004 00000003`（`PQftype` 1007）。`get[String]` は現行どおり `TYPE_MISMATCH`（`column is oid 1007 but String was requested in binary format; ...`）、テキスト形式では `{1,NULL,3}` / `[0:1]={7,8}` がそのまま `String` で返る（REQ §4.1 の既存規則）
- 本プロジェクトのデコーダが**同じ検査をクライアント側で**行う（§4 P1〜P5）。plan はこの表の hex を単体テストの期待値に写す

### 2.4 libpq COPY（docs 引用 + probe-copy 9 ケース。PG17 / PG14 同一、libpq 18.6）

docs（`libpq-copy.html`）の契約: `PQputCopyData` 「1 if the data was queued, zero if it was not queued because of full buffers (**this will only happen in nonblocking mode**), or -1 if an error occurred」/ `PQputCopyEnd` 「Ends the COPY_IN operation successfully if errormsg is NULL. If errormsg is not NULL then the COPY is forced to fail, with the string pointed to by errormsg used as the error message ... After successfully calling PQputCopyEnd, call PQgetResult to obtain the final result status」/ `PQgetCopyData` 「the return value is the number of data bytes in the row (this will always be greater than zero) ... zero ... only possible when async is true ... -1 indicates that the COPY is done ... -2 indicates that an error occurred ... A non-NULL result buffer should be freed using PQfreemem ... After PQgetCopyData returns -1, call PQgetResult」/ 「It is not possible to execute other SQL commands using the same connection while the COPY operation is in progress」/ 多文: 「the application must continue fetching results via PQgetResult after completing the COPY sequence. Only when PQgetResult returns NULL is it certain that the PQexec command string is done」。最終結果は `PGRES_COMMAND_OK` か `PGRES_FATAL_ERROR`。

| # | ケース | 実測 |
|---|---|---|
| 1 | `PQexec("COPY t FROM STDIN")` → 100 行 × 100 チャンク `PQputCopyData` → `PQputCopyEnd(NULL)` → `PQgetResult` ×2 | status **4**（COPY_IN）。**COPY 中の `PQtransactionStatus` = 1（ACTIVE）**。put は全部 **1**、end **1**、1 つ目 `status=1 cmdTuples=100000`、2 つ目 **NULL**。**63 ms**。`count(*)` 100000、txstatus 0 |
| 2 | `COPY t TO STDOUT` → `PQgetCopyData(async=0)` ループ | status **3**。100000 行 / 4,522,225 byte、各行は**末尾 `\n` 込み**（`0\t0\t1.5\trow0\t2024-01-02 03:04:05\n` = 33 byte）、終端 **-1**、`PQgetResult` = `status=1 cmdTuples=100000`、次は NULL。**34 ms** |
| 3 | 1 行書いて `PQputCopyEnd("aborted by probe")` | end 1、`PQgetResult` = **`status=7 sqlstate=57014 msg=COPY from stdin failed: aborted by probe`**、次 NULL、txstatus 0 / status 0、行は入らない |
| 4 | 不正行 `1\t2\n` → さらに 100,000 行 | **不正行の後も put は全部 1 のまま**（8 ms。サーバーのエラーは put では見えない）、end 1、`PQgetResult` = **`status=7 sqlstate=22P04 msg=missing data for column "c"`**、次 NULL、`count` 不変。`PQerrorMessage` に `ERROR: ... CONTEXT: COPY pq_copy_probe, line 1: "1\t2"` が残る |
| 5 | COPY IN 中に `conn.execute("SELECT 1")` | **成功する**（1 行返る）。txstatus 0、`PQgetResult` NULL、**書いた 2 行は入っていない**（libpq が COPY を中止した）。COPY OUT 中の `execute("SELECT 2")` も成功（読み捨て）、次の execute も通る |
| 6a | COPY IN 中に `close(PQsocket)` | 以後の put は **-1**（40 回とも）、`PQerrorMessage` = `could not receive data from server: Bad file descriptor`（呼ぶたび追記）、end **-1**、**`PQstatus` は OK のまま**（Phase 5 の EBADF 経路と同じ）、`PQgetResult` = `status=7 sqlstate=` → txstatus 0、次の `execute` は `CONNECTION`（sqlstate 無し + ... libpq の文言） |
| 6b | COPY OUT で 1 行読んでから `close(PQsocket)` | **次の 2 回も 33 byte の行が返る**（libpq のバッファに既に届いていた分）。`PQstatus` OK、`PQgetResult` は `status=3`（COPY_OUT のまま）で txstatus 1、次の `execute` は **`SERVER`**（sqlstate 無し・`PQstatus` OK なので `adopt_result` が SERVER に分類）: `could not receive data from server: Bad file descriptor` |
| 7 | `conn.transaction()` の中で COPY IN 3 行 → end → `tx.rollback()` | COPY 中 txstatus 1、終了後 **2**（INTRANS）、tx 内 `count` 3、rollback 後 0 |
| 9 | `PQexec("COPY t FROM STDIN; SELECT 42")` | status 4、end 後 `PQgetResult` = `status=1 cmdTuples=1`、**2 つ目 `status=2`（SELECT 42）**、3 つ目 NULL |

→ plan への含意: (a) `write` は `-1` で即 `CONNECTION`（`PQerrorMessage`）にして**以後 libpq を呼ばない**（`PQstatus` は当てにならない: 6a）。(b) `finish` は `PQputCopyEnd` → `PQgetResult` を `adopt_result` に通す（COMMAND_OK → `affected_rows()` が COPY 行数 = `cmdTuples`、22P04 等は SERVER）→ **NULL まで `PQgetResult` を回して残りを捨てる**（9）。(c) COPY 中の検出は **`PQtransactionStatus == PQTRANS_ACTIVE`** で足りる（同期 `Connection` が ACTIVE になるのは COPY 中だけ。フラグを別に持たなくてよい）。(d) 途中切断後の `finish` の `PQgetResult` は FATAL + sqlstate 無し + `PQstatus` OK なので `adopt_result` では SERVER になる → COPY 側で「sqlstate 無しの FATAL は CONNECTION」に倒す（COPY の最終結果に sqlstate 無しの正当な FATAL は無い）。(e) COPY OUT の切断は `-2` が出るまでバッファ分が返る（`__del__` の読み捨てループはそのまま `-2` で止まる）

### 2.5 `PQreset` / `pg_terminate_backend`（probe-copy case 8、probe-pool F〜H2）

| 観測 | 値 |
|---|---|
| 切られた直後、未使用 | **`PQstatus` 0（OK）、`PQtransactionStatus` 0（IDLE）** |
| その接続で `execute` | `CONNECTION`（sqlstate 空）`server closed the connection unexpectedly ...`。以後 `PQstatus` **1（BAD）**、`PQtransactionStatus` **4（UNKNOWN）**、次の `execute` は `no connection to the server` |
| `PQreset` | `PQstatus` 0 / txstatus 0、backend_pid 変化、**`SHOW DateStyle` = `ISO, MDY`（`Connection.open` の `SET` が消える）**、`IntervalStyle` = `postgres`（既定値と同じなので見かけ上不変） |
| 健全な接続に `PQreset` | **backend_pid が変わる**（接続し直す）→ BAD のときだけ呼ぶ |
| 切られた直後の未使用接続に `PQconsumeInput` | **1 回目: 戻り 1、status OK**（FATAL メッセージを消費）→ **2 回目: 戻り 0、status BAD、txstatus UNKNOWN、`server closed the connection unexpectedly`**。往復なし・非ブロッキング |
| 健全な新規接続に `PQconsumeInput` | 1、status OK、`PQisBusy` 0 |

### 2.6 `PooledConnection[origin]` 試作（probe-pool、全ケース期待どおり）

- A: 1 つの `PoolProto` から `acquire(ref self)` を 2 回 → ガード 2 本が同時に生存し backend_pid が異なる。内部状態は `Pointer[List[Int], MutUntrackedOrigin](unsafe_from_address=Int(Pointer(to=self._idle)))` で書く
- B: 1 本目の最後の使用の後（ASAP 破棄）`idle` が 1 → 次の `acquire` の backend_pid が同じ（再利用）
- C: `BEGIN` を送ったまま drop → `_release` が `PQtransactionStatus` 2 を見て `ROLLBACK` → 次の利用者は txstatus 0、`CREATE TEMP TABLE` は `42P01`（消えている）
- I: ガードから `Transaction[origin_of(self)]` / `PreparedStatement[origin_of(self)]` を `_conn_ptr()`（§0.5 の rebind）で構築 → `tx.execute` / `st.execute([Int(7)])` が通る
- F/G: 貸し出し中に `pg_terminate_backend` → `execute` が `CONNECTION`、`PQstatus` 1 / txstatus 4 → `_release` が捨てる（idle +0）→ 次の `acquire` は新規 pid
- H: 貸し出し中に切られたが**使わずに**返す → `PQstatus` 0 のまま idle に入る → 次の `acquire` で再利用され最初の `execute` が `CONNECTION` → その返却で捨てられる（§0 発見 3）
- D/E（42P05 の陽性対照）: `BEGIN` → `prepare`（`pq_stmt_1`）→ `SELECT 1/0`（22012、INERROR）→ stmt drop（`DEALLOCATE` は 25P02 で失敗、黙殺）→ drop（`ROLLBACK`、**PREPARE は非トランザクショナルなので `pq_stmt_1` が残る**）→ 再 acquire → `prepare`: **`_stmt_counter` を引き継げば `pq_stmt_2` で成功、引き継がないと `42P05 prepared statement "pq_stmt_1" already exists`**。`List[Connection]` で丸ごと保持すればカウンタは自然に残る（§0 発見 5）
- `PoolProto.__deinit__` で idle を `PQfinish`（`pool deinit: finishing N idle connections`）

### 2.7 Mojo 1.1.0 言語（probe-lang A〜E / listmov / thread。全部 §0.5 に転記済み）

- A: `comptime if T == List[Int32] / List[Optional[Int32]] / List[Optional[String]] / List[UInt8]` が `decode[T: Copyable]` の中で `rebind[T](out).copy()` で通る（`List[Optional[Int32]]` は `Copyable`）
- B: `@implicit __init__(out self, var v: List[Int32])` 等 4 本 + `String` / `Int` を 1 struct に並べて `[i32^, u8^, opt^, strs^, String("x"), 5]` が `List[P]` literal になる（`^` 必須）
- D: `Iterable` + `Iterator`（`raises StopIteration`）でエラーを溜める形は動く（`error after loop: True`）が、`for` の中で `PgError` は出せない。`next() -> Optional` + `while` は素直に `raised boom`
- E: ガード 2 本同時 / 3 本目で `USAGE` / `__deinit__` から `self._res^` を `_release` に渡す / `view()` の rebind。陽性対照 `return self._res.view_direct()` は `cannot implicitly convert 'View[origin_of(self._res)]' value to 'View[origin_of(self)]'`

## 3. 盗める設計 / 使えるライブラリ（plan が採否表にする）

1. **配列テキストの tokenizer = psycopg `_load_text`**（§1.1）: `[..]=` を `=` まで捨てる → `{` → 要素（`"…"` は `\x` → `x` の unescape、裸は前後空白 trim、`NULL`（大小無視）は NULL）→ `,` / `}`。`{` のネスト = `TYPE_MISMATCH`（D6）。`}` の後に文字が残れば `TYPE_MISMATCH`。要素文字列は既存 `decode_text[E](elem, elem_oid)` へ（bytea は unescape 後 `\x00ff` になり `parse_bytea_hex` がそのまま使える）
2. **配列バイナリのデコーダ = psycopg `_load_binary` + `array_recv` の検査**（§1.1 / §2.3）: 12 byte 未満 → `TYPE_MISMATCH`; ndim 0 → 空（flags / elemtype は検査する）; ndim 1 → dim / lbound（lbound は捨てる）; ndim < 0 or ≥ 2 → `TYPE_MISMATCH`; flags ∉ {0,1} → `TYPE_MISMATCH`; elemtype ≠ 期待 → `TYPE_MISMATCH`（メッセージに両 OID）; dim < 0 → `TYPE_MISMATCH`; 要素 `len` が -1 → NULL（`List[T]` なら `NULL_VALUE`、`List[Optional[T]]` なら None）; `len` > 残り → `TYPE_MISMATCH`; 要素は `decode_binary[E](span[p:p+len], elem_oid, column)`（固定長検査・jsonb version byte は既存が行う）; 全要素の後に残りバイト → `TYPE_MISMATCH`（rust-postgres の "not drained" 流儀、Phase 3 P21 と同じ）
3. **配列バイナリのエンコーダ = psycopg `ListBinaryDumper.dump` + `array_send`**: 空なら `ndim 0, flags 0, elemtype`（12 byte）、それ以外 `ndim 1, flags = any NULL, elemtype, dim = len, lbound 1`、要素は既存 `encode_*` の戻り（`List[UInt8]`）に `int32 len` を前置、NULL は `ffffffff`。`String` 要素は UTF-8 バイト（NUL を含むなら `USAGE`、サーバーは 22021）、`List[UInt8]` 要素は生バイト。OID は §2.1 の表（`List[String]` → 1009 / 25、`List[Int]` → 1016 / 20）
4. **配列 OID 表 = `pg_type.typarray`**（§2.1）を `decode_text.mojo` の `OID_*` の隣に `OID_INT4_ARRAY = 1007` … と置き、`_array_elem_oid(array_oid) -> UInt32`（未知は 0）と `_array_oid_of(elem_oid)` の 2 関数。`List[String]` だけ 6 OID を受ける
5. **`comptime if` の分岐は 1 行ずつ**: `elif T == List[Int32]: return rebind[T](_decode_text_array[Int32](text, oid, OID_INT4)).copy()` の形で 20 要素型（`Int` を含む）× `List` / `List[Optional]` = 40 行 × text / binary。`Param` の `@implicit` も 40 本（`var v: List[T]` / `var v: List[Optional[T]]`）。NULL 要素の `NULL_VALUE` は `List[T]` 側の helper が投げる
6. **COPY の終了処理 = psycopg `finish(exc)`**（§1.2）: `abort(msg)` は `PQputCopyEnd(msg)` → `PQgetResult` → **57014 だけ飲み、それ以外の SERVER / CONNECTION は上げる**（サーバーが先に 22P04 で落としていた事実を隠さない）。`finish()` は `PQputCopyEnd(NULL)` → `adopt_result` → NULL まで drain
7. **COPY 中の検出 = `PQtransactionStatus == PQTRANS_ACTIVE`**（§2.4 (c)）: `Connection.execute` ×2 / `prepare` / `transaction` / `copy_in` / `copy_out` の先頭で `USAGE`（`"a COPY is in progress on this connection"`）。`transaction()` の既存検査（`!= IDLE` → USAGE）は文言だけ合わせる。状態フィールドを足さないので `__del__` の消し忘れが無い
8. **返却時の後始末 = psycopg `_reset_connection`**（§1.3）+ **`_stmt_counter` の保持 = `List[Connection]` 丸ごと**（§2.6）: `INTRANS` / `INERROR` → `ROLLBACK`（失敗は handler へ + 捨てる）→ `PQstatus != OK` or txstatus ∉ {IDLE} → 捨てる → 寿命超過 → 捨てる → idle へ `append(conn^)`
9. **健全性 = deadpool Fast + `PQreset`**（§1.5 / §2.5）: 貸し出し前に `PQstatus != OK` なら `Connection.reset()`（`PQreset` → `PQstatus` → `_SESSION_SETUP_SQL` 再送、失敗は `CONNECTION`）→ 駄目なら捨てて `Connection.open`。任意で `PQconsumeInput` を 1 回（0 なら BAD）。REQ の「往復しない」は守る
10. **ガード = `Transaction` / `PreparedStatement` と同じ origin パターン + `_conn_ptr()` rebind**（§2.6 / §2.7 E）: `PooledConnection[origin: ImmOrigin](Movable)` が `Connection` を**値で**持ち、`__deinit__` で `self._pool[]._release(self._conn^, self._opened_at)`。転送メソッドのうち origin 付きの戻り（`transaction` / `prepare` / `copy_in` / `copy_out`）は `Connection` 側を `_transaction_parts` / `_prepare_parts` / `_copy_in_parts` / `_copy_out_parts`（検査 + libpq 呼び出しまで）に分け、`Transaction` と `PooledConnection` の両方が `X[origin_of(self)](self._conn_ptr(), ...)` で組む（`Transaction.prepare` の前例）
11. **`PQgetCopyData` のバッファ受け取り**（§0.5）: `var cell: List[Int] = [0, 0]` → `Pointer[Int, MutUntrackedOrigin](unsafe_from_address=Int(cell.unsafe_ptr()))` → 戻り > 0 なら `Pointer[UInt8, ImmUntrackedOrigin](unsafe_from_address=cell[0])` から `rc` byte を `List[UInt8]` にコピー → `PQfreemem`。probe-copy `get_row()` がそのまま雛形
12. **堅牢性格子の雛形** = `archive` ではなく `logs/phase5-polish-bench-readme/scratch/turn-010-robust-grid.sh`（§1.8）。`examples/copy.mojo` / `pool.mojo` を足して同じ `report()` で回す

## 4. 落とし穴と検証方法（plan は完了基準に写す。種類: 単体 = サーバー不要 / サーバー / 陽性対照 / レビュー）

| # | 落とし穴 | 回避策 | どう検証すれば踏んでいないと分かるか |
|---|---|---|---|
| P1 | 配列バイナリの flags で NULL を判定する（flags 0 でも `-1` 要素は来る: §2.3 c） | NULL は `len == -1` だけで判定。flags は 0/1 の検査のみ | 単体: `00000001 00000000 00000017 00000003 00000001 00000004 00000001 ffffffff 00000004 00000003`（flags 0 + NULL）を `List[Optional[Int32]]` で `[1, None, 3]`、`List[Int32]` で `NULL_VALUE`。flags 2 → `TYPE_MISMATCH` |
| P2 | ndim 0 のとき 12 byte で終わる（dims を読みに行くと範囲外） | ndim 0 は flags / elemtype を検査して空 `List` | 単体: `000000000000000000000017` → 空、`000000000000000000000019` を `List[Int32]` で `TYPE_MISMATCH`（elemtype 25 ≠ 23）、11 byte → `TYPE_MISMATCH` |
| P3 | 要素長が残りを超える / 全要素の後にゴミ / dim と要素数の不一致（§2.3 h, i） | len > 残り → `TYPE_MISMATCH`、末尾残り → `TYPE_MISMATCH` | 単体: dim 3 で要素 2 個（`08P01` 相当）/ 要素 len 5 の int4（`22P03` 相当）/ 末尾に 1 byte 追加 の 3 件が `TYPE_MISMATCH`。サーバー: 同じ payload を `Param` で送ると `08P01` / `22P03`（§2.3 の表） |
| P4 | 多次元・lbound: `{{1,2},{3,4}}` / ndim 2 を要素として読んでしまう、`[0:1]=` 接頭辞で落ちる | テキストはネストの `{` で `TYPE_MISMATCH`、`[` 始まりは `=` まで捨てる。バイナリは ndim ≥ 2 → `TYPE_MISMATCH`、lbound は読み飛ばす | サーバー: `ARRAY[[1,2],[3,4]]` を text / binary とも `get[List[Int32]]` → `TYPE_MISMATCH`（メッセージに `ndim`）、`'[0:1]={7,8}'::int4[]` → `[7, 8]`（両形式） |
| P5 | 配列 OID と `T` の不一致を要素 OID で見てしまう（`int2[]` を `List[Int32]`） | 列 OID → 期待する配列 OID の完全一致（§2.1）。バイナリはさらに elemtype も検査 | サーバー: `'{1,2}'::int2[]` を `List[Int32]` → `TYPE_MISMATCH`（両形式）、`int8[]` を `List[Int]` と `List[Int64]` の両方で読める、`varchar[]` / `name[]` / `bpchar[]` / `json[]` / `jsonb[]` を `List[String]` で読める（6 OID） |
| P6 | テキストの unescape 漏れ: bytea の `"\\x00ff"`、`"d\"e"`、`"f\\g"`、空文字 `""`、`"NULL"`（文字列）vs `NULL`（NULL）、bpchar の `"ab   "` | §3-1 の tokenizer。引用符内は `\` の次の 1 文字をそのまま | 単体: §2.2 の text[] 9 要素のリテラルを `List[String]` で `["a","b,c","d\"e","f\\g","","NULL","null"," x ","{y}"]`、`{a,NULL,b}` を `List[Optional[String]]` で `[a, None, b]` と `List[String]` で `NULL_VALUE`、`{"\\x00ff","\\x"}` を `List[List[UInt8]]` で `[[0,255],[]]`、`{"ab   ",cde}` で padding 保持 |
| P7 | 不正リテラルでトレースバック / 無限ループ（閉じ括弧なし / 引用符の途中終端 / `{1,,2}` / `{1,2}}` / `{` 無し / 空文字） | tokenizer の各状態で終端を検査 | 単体（REQ §2.4 の入力軸）: `{1,2` / `{"abc}` / `{1,,2}` / `{1,2}}` / `1,2` / `` / `{` / `}` / `{"a` の 9 件が全部 `TYPE_MISMATCH` で raise（`cannot decode ... as int4[]` 等）。`'{ 1 , 2 }'` は `[1, 2]`（空白許容） |
| P8 | 要素のデコード失敗のメッセージに列が出ない / 要素番号が出ない | 要素 decode の `TYPE_MISMATCH` を捕まえて `array element N: <元メッセージ>` で包む（plan 判断） | 単体: `{1,a,3}`（oid 1007）のメッセージに `element 1`（0 始まりか 1 始まりかを決めて固定） |
| P9 | `List[String]` 送信の OID: スカラ `String` は OID 0（テキスト）だが配列は 1009 固定（§2.3 p）。`varchar[]` / `jsonb[]` 列への INSERT はサーバーのキャスト頼み | 1009 / elemtype 25。docstring に「`text[]` として送る。`$1::varchar[]` 等はサーバーの配列キャスト」 | サーバー: `SELECT $1::varchar[]` と `INSERT INTO t(v varchar[]) VALUES ($1)` が通る（**未実測**: impl で先に 1 回）、`$1::jsonb[]` も同様。`List[String]` に NUL を含む要素 → `USAGE`（サーバーに送らない） |
| P10 | `Param` の 40 本の `@implicit` を足すと `[1, "a", Param.null()]` の推論が曖昧になる / 名前付き `List` を literal に書くと `ImplicitlyCopyable` エラー（§0.5） | probe-lang B の形（`[ids^, ...]`）を README / docstring に。既存テスト `test_params` の全件が不変 | 既存 `test_params` 33 件 / `test_binary` 14 件が変更なしで PASS（期待値変更 0 件）。README の配列の例は `[ids^]` か `[Param(ids.copy())]` |
| P11 | `PQputCopyData` の -1 の後も呼び続けて `PQerrorMessage` が肥大（§0.5）/ `PQstatus` が OK のままで CONNECTION に分類されない（§2.4 6a） | `write` の -1 → `CONNECTION`（`PQerrorMessage`）+ `_done`。`finish` / `abort` の `PQgetResult` が FATAL + sqlstate 無しなら `CONNECTION` | サーバー: COPY IN 中に `close(PQsocket)`（Phase 5 `probe-closefd.mojo` の `external_call["close"]`）→ `write` が `CONNECTION`、2 回目の `write` / `finish` は `USAGE`（終了済み）か `CONNECTION`（plan が決める）、トレースバック無し。COPY OUT 中に close → `next()` がバッファ分の後 `CONNECTION`（§2.4 6b: すぐには来ない） |
| P12 | 不正データのエラーが `write` で見えない（§2.4 case 4）→ 利用者が 10 万行書いてから 22P04 | 仕様として docstring に明記（libpq の性質）。`finish()` が `SERVER` 22P04 を上げる | サーバー: 列数不足の行 1 つ + 正常行 → `finish()` が `SERVER` / sqlstate `22P04` / `affected_rows` 無し、`count(*)` 不変、接続は IDLE、次の `execute` が通る |
| P13 | COPY 中に `execute` / `transaction` / 2 つ目の `copy_*` が通ってしまい libpq が COPY を黙って中止（§2.4 case 5、**データ消失**） | §3-7 の `PQTRANS_ACTIVE` 検査 | サーバー: COPY IN で 2 行書いた後 `conn.execute("SELECT 1")` → `USAGE`（`a COPY is in progress`）、その後 `finish()` が **2 行を数える**（USAGE は何も送らなかった証明）。`transaction()` / `prepare()` / `copy_in()` / `copy_out()` も同じ格子 4 件。**陽性対照**: 検査を外したコピーで `finish()` の行数が 0 になる（probe-copy case 5 の再現） |
| P14 | `copy_in("COPY ... TO STDOUT")`（方向違い）で `USAGE` を投げた後、接続が COPY OUT 状態のまま残る（逆も同じ） | 方向違いを検出したら**その場で drain**（OUT: `PQgetCopyData` を -1 まで + `PQgetResult` を NULL まで。IN: `PQputCopyEnd("wrong direction")` + drain）してから `USAGE` | サーバー: `copy_in("COPY t TO STDOUT")` → `USAGE`、直後の `execute("SELECT 1")` が通る。`copy_out("COPY t FROM STDIN")` → `USAGE`、同じ。`copy_in("SELECT 1")` → `USAGE`（通常結果は PQclear） |
| P15 | 多文 SQL（`COPY ...; SELECT 42`）で `finish()` 後に結果が残り、次の `execute` が「another command is already in progress」になる（§2.4 case 9） | `finish` / `abort` / `__del__` は `PQgetResult` が NULL になるまで回す。docstring「COPY 文は 1 文。残りの結果は捨てる」 | サーバー: `copy_in("COPY t FROM STDIN; SELECT 42")` → `finish().affected_rows() == 1`、次の `execute` が通る |
| P16 | `CopyIn` / `CopyOut` の `__del__` と `Transaction.__del__` の順序: tx が先に死ぬと `ROLLBACK` の `PQexec` が COPY を中止する（§2.4 case 5 と同じ経路） | docstring: 「`finish()` / `abort()` を tx の最後の使用より前に」。`Transaction.copy_in` は `CopyIn[Self.origin]` を返す（`Transaction.prepare` と同型）| サーバー: `var tx = conn.transaction(); var c = tx.copy_in(...); c.write(...); _ = c.finish(); tx.commit()` で行が残る / `tx.rollback()` で残らない（REQ §4.2 最後）。レビュー: `__del__` が `PQexec` を呼ばない（COPY API だけ） |
| P17 | `CopyOut.__del__` の読み捨てが大きいテーブルで長い | 仕様（docstring に「残りを全部読む」）。REQ どおり | サーバー: 10 万行の `copy_out` を 1 行で捨てる → 次の `execute` が通る（所要を PROGRESS に。probe では 34 ms/10 万行） |
| P18 | `Iterator` にできない（§0 発見 1） | `next()` + `while`。`Iterator` を付けるなら error-stash 方式（§2.7 D）を**明記** | 単体 / レビュー: `copy_out` の docstring の例が `while True: var row = out.next(); if not row: break`。例 `examples/copy.mojo` も同じ形 |
| P19 | `PQreset` 後に `DateStyle` が戻り、`get[Date]` のテキストが `TYPE_MISMATCH` になる（§2.5） | `Connection.reset()` = `PQreset` → `PQstatus` 検査 → `execute(_SESSION_SETUP_SQL)` | サーバー: `pg_terminate_backend` → `execute` 失敗 → `reset()` → `SHOW DateStyle` = `ISO, YMD`、`backend_pid` が変わる、`get[Date]`（text）が通る。健全な接続に `reset()` を呼んでも `backend_pid` が変わる（docstring に明記） |
| P20 | 切られた直後の未使用接続は `PQstatus` OK（§0 発見 3） | 仕様（D14）。受け入れテストは返却前に 1 回使う。任意: `PQconsumeInput` 1 回 | サーバー: (a) 貸し出し中に terminate → `execute` で `CONNECTION` → drop → `size()` が 1 減る → 次の `acquire` は新 pid で `execute` が通る。(b) 使わずに drop → `idle()` に残る → 次の `acquire` の最初の `execute` が `CONNECTION` → その drop で捨てられる。(b) は README「既知の制限」に 1 行 |
| P21 | `acquire` が `mut self` だとガード 2 本を同時に持てない / `ref self` で内部状態を書けない | `ref self` + `MutUntrackedOrigin` ポインタ（§2.6 A）。`Pool[...]` は origin パラメータ無し、ガードが `origin_of(self)` | コンパイル: `var a = pool.acquire(); var b = pool.acquire()` が通り、`var p2 = pool^` の後の `a.execute` が `use of uninitialized value`（陽性対照、Phase 3 P18 と同じ手順） |
| P22 | `_stmt_counter` が再利用で 0 に戻り `42P05`（§2.6 D/E） | `List[Connection]` で丸ごと保持（§3-8） | サーバー（§2.6 D/E の再現）: `BEGIN` → `prepare` → `SELECT 1/0` → stmt drop → guard drop → 再 acquire → `prepare` が `pq_stmt_2` で成功。**陽性対照**: カウンタを 0 に戻すコピーで `42P05` |
| P23 | `max_lifetime_s` の時計: `monotonic()` は ns（§0.5）、`max_lifetime_s = 0` は無期限 | `opened_at = monotonic()`、`elapsed // 1_000_000_000 >= max_lifetime_s` | サーバー: `max_lifetime_s=1` で `pg_sleep(1.1)` を貸し出し中に実行 → drop → `idle()` 0 → 次の pid が変わる。`max_lifetime_s=0` で 2 秒後も同じ pid |
| P24 | `min_size > 0` の open が途中で失敗したとき開いた分が漏れる | `List[Connection]` を局所で組み、失敗は raise（deinit が `PQfinish`）| サーバー + leak: `min_size=2` で 2 本目を `max_connections` 超過（`pg_stat_activity` を埋めるのは重い）→ 代わりに陽性対照不要、`test_leak` に `Pool.open(min_size=2)` → drop を 1,000 回（RSS 判定）。`min_size > max_size` / `max_size <= 0` は `USAGE` で `pg_stat_activity` 不変 |
| P25 | 返却時の `ROLLBACK` 失敗（接続が死んでいる）で handler が呼ばれず黙る | `_release` の `ROLLBACK` 失敗 → `_rollback_failure_handler`（その `Connection` の）→ 捨てる | サーバー: `BEGIN` 後に terminate → 使わずに drop → `ROLLBACK` が `CONNECTION` → handler に 1 回（`set_rollback_failure_handler` で数える）→ `size()` −1。`check` 6/6 の `implicit ROLLBACK failed` が 0 のまま（既定 handler を使わない） |
| P26 | `examples/copy.mojo` / `pool.mojo` が `check` 4/6 と `pixi.toml` に無い（Phase 3 P29） | `final_check.sh` 4/6 に 2 行、`pixi.toml` に `example-copy` / `example-pool` | `pixi run check` のログに `examples/copy.mojo` / `examples/pool.mojo` の行、`grep -c example- pixi.toml` ≥ 8 |
| P27 | 堅牢性格子（REQ §2.4）の出力軸 / 依存軸を新 examples で回さない | `turn-010-robust-grid.sh` を `turn-NNN-robust-grid.sh` に写し `copy` / `pool` を足す | 格子: 入力（上記 P7 / P3 / P11 / P20）× 出力（`/dev/full` / closed / broken pipe）× 依存（`PQ_MOJO_LIBPQ=libc.so.6` / サーバー無し port / badpw）で `unhandled_markers=0`、ログを scratch に |
| P28 | 未使用変数 / `print` の WARNING が `check` 6/6 に乗る（§0.5） | `_ =`、サーバー NOTICE を出す SQL（`DROP TABLE IF EXISTS` の NOTICE は WARNING 判定に入らない）| `check` 6/6 `matched lines: 0` |
| P29 | macOS CI: `close(PQsocket)` の EBADF 経路・`pg_stat_activity`・`pg_terminate_backend` の権限 | いずれも Linux 開発機で通る前提のまま CI で確認（Phase 6 の教訓: OS 差は verify の差し戻しで直す。`verify_round_max` 4 は D1 で確保済み） | CI 3 OS 緑。macOS の `final-check-log-macos-latest` artifact に `test_copy` / `test_pool` の PASS 行 |

## 5. 要件への影響（REQ 本文は変えていない。提案として plan が採否を決める）

1. **§2.2 `CopyOut` の「`Iterator` としても使える」を外す**（§0 発見 1）。代替は `next() -> Optional[List[UInt8]]` + `while`。どうしても `for` が欲しければ error-stash 方式（`__next__` は `StopIteration`、ループ後に `copy_out.error()`）だが、エラーを隠す形なので非推奨
2. **§4.3 の terminate ケースを 2 件に**（§0 発見 3 / P20）: (a) 貸し出し中に切られ**使ってから**返す → 捨てられる、(b) 使わずに返す → 再利用され最初の `execute` が `CONNECTION`、その返却で捨てられる。README「既知の制限」に (b) を 1 行
3. **§2.3 健全性: `Connection.reset()` を公開メソッドとして足す**（`PQreset` + `PQstatus` + `_SESSION_SETUP_SQL` 再送、§2.5）。健全な接続に呼ぶと再接続する旨を docstring に
4. **§2.2 方向違い / 非 COPY 文の `USAGE` に「その場で drain して接続をアイドルに戻す」を足し、§4.2 に「`copy_in("COPY ... TO STDOUT")` → `USAGE`、直後の `execute` が通る（逆も）」**（P14）
5. **§2.2 の「COPY 中の `execute` ... は `USAGE` で、サーバーには何も送られない」に根拠を足す**: libpq は COPY 中の `PQexec` を黙って中止する（COPY IN の行が消える）ので、`USAGE` 後の `finish()` が全行を数えることをテストにする（P13）。検出は `PQtransactionStatus == PQTRANS_ACTIVE`
6. **§2.2 `finish()` は多文の残り結果を捨てる**（P15）。`abort()` は 57014 だけ飲み、他は上げる（§3-6）。`write` の -1 と「sqlstate 無しの FATAL」は `CONNECTION`（`PQstatus` は当てにならない。P11）
7. **§2.1 送信: `List[String]` は OID 1009（text[]）/ 要素 25 で送る**（スカラ `String` の OID 0 とは違う。P9）。NUL 入り要素は `USAGE`。`List[Int]` も `List[Int64]` と並べて 20 要素型にする
8. **§4.1 の境界値に追加**: `{"\\x00ff","\\x"}`（bytea の二重 backslash）、`"ab   "`（bpchar padding）、jsonb[] のバイナリ要素が version byte 付き、`'{{}}'::int4[]` が `{}`、`'[0:1]={7,8}'` 両形式、`ARRAY[[1,2],[3,4]]` 両形式が `TYPE_MISMATCH`、不正リテラル 9 件（P7）、バイナリ不正 6 件（P1〜P3）
9. **§4.3 `max_lifetime_s=1`**: 貸し出し中に `pg_sleep(1.1)`（`time.sleep` は使わない）で経過させる（P23）
10. **§4.4 `test_leak` の追加 1 ケース**は「`Pool.open(min_size=2)` → drop」のループと「`acquire` → drop」のループの 2 つが自然（P24）。所要見込み +10 s 以内（接続 2 本 × 1,000 回 ≈ 既存の connect ループと同程度）
11. §6「(2) シグネチャ確認」は済み。**`PQputCopyEnd` の errormsg は `Int`（0 = NULL）で束縛**する（`OptCStr` を作る手段が無い。§0.5）

## 6. plan への申し送り

- **モジュール配置案**（既存の流儀どおり 1 機能 1 ファイル）:
  - `src/pq/_ffi/functions.mojo`: 3 フィールド + 3 `_dl_sym`（§0 (2) の型。`libpq-fe.h:547-549` のコメント付き）
  - `src/pq/decode_text.mojo`: 配列 OID 定数 21 個 + `_array_elem_oid` / `_array_oid_of` + `parse_array_literal(text) -> List[Optional[String]]`（tokenizer、ndim / 不正形は `TYPE_MISMATCH`）+ `_decode_text_array[E](text, oid, expect_array_oid)` + 40 分岐
  - `src/pq/decode_binary.mojo`: `_decode_binary_array[E](bytes, oid, expect_array_oid, expect_elem_oid, column)` + 40 分岐（jsonb は要素 OID 3802 を渡す）
  - `src/pq/encode_binary.mojo`: `encode_array(elems: List[List[UInt8]], nulls: List[Bool], elem_oid)`（要素は既存 `encode_*` 済みのバイト列）か `_encode_array[E]` の comptime 版（plan 判断。前者はジェネリック無しで単体テストしやすい）
  - `src/pq/params.mojo`: 40 本の `@implicit`（`List[T]` / `List[Optional[T]]`）。`String` 要素の NUL 検査は `_ParamBuffers` と同じ `USAGE` 文言
  - `src/pq/copy.mojo`（新規）: `CopyIn[origin]` / `CopyOut[origin]` + `_drain_results(pq, conn)` + `_classify_copy_result`。`Connection` に `copy_in` / `copy_out` / `_copy_in_parts` / `_copy_out_parts` / `_check_not_copying`、`Transaction` に `copy_in` / `copy_out`
  - `src/pq/pool.mojo`（新規）: `Pool(Movable)` + `PooledConnection[origin]` + `_Slot(Movable)`（`conn: Connection`, `opened_at: Int`）。`Connection` に `reset()` と `_transaction_parts`（`transaction()` の検査 + `BEGIN` を分離。`PooledConnection.transaction` が使う）
  - `src/pq/__init__.mojo`: re-export + 型マッピング表に配列行 + COPY / Pool の節
  - `src/pq/connection.mojo:266-269` の docstring を `copy_in` / `copy_out` への案内に（REQ §4.4）
- **テストファイル案**: `test_decode_array.mojo`（サーバー不要: tokenizer 不正形 9 件 + バイナリ不正 6 件 + §2.3 の hex 12 列。雛形 `tests/test_decode_binary.mojo` / `test_decode_text.mojo:10-80` の `_ok[T]` / `_error_kind[T]`）、`test_array.mojo`（サーバー: 20 型 × text/binary × `List` / `List[Optional]` の格子、Phase 3 の境界値を要素に、送信往復 20 型、`= ANY($1)`、OID 不一致、多次元、lbound、`'{}'`、`String` ワイルドカード）、
  `test_copy.mojo`（サーバー: text 10 万行 / CSV / binary（PGCOPY ヘッダ `PGCOPY\n\377\r\n\0` + int32 flags 0 + int32 ext 0 + 行 + `ffff` トレーラ）各 1 往復、abort、drop、USAGE 格子 4 件 + 陽性対照、22P04、close(fd)、多文、tx + rollback、方向違い 2 件）、`test_pool.mojo`（サーバー: REQ §4.3 の 9 項目 + P20 (b) + P22 + P25。`pg_stat_activity` は `WHERE datname = current_database() AND backend_type = 'client backend'` で数え、他テストの接続が混ざらないよう **`application_name` を conninfo に足して絞る**）、
  `test_leak.mojo` に 2 ループ（P24）。既存ファイルの期待値変更は **0 件**を目標（`test_params` の OID 表テストに配列行を足すのは追加のみ）
- **期待値の出典**: §2.2 / §2.3 の文字列と hex、§2.4 の sqlstate（57014 / 22P04）、§2.5 の文言（`server closed the connection unexpectedly`）をそのまま写す。メッセージは 2 語以上の部分文字列で
- **サブエージェント推奨本数**: 配列（decode_text / decode_binary / encode / params / 2 テスト）は 1 本に閉じる（ファイル 5 + テスト 2、推定 +1,100 行）か decode と encode+params の 2 本。COPY（`copy.mojo` + `connection` / `transaction` の結線 + `test_copy`、推定 +600 行）と Pool（`pool.mojo` + `reset` + `test_pool`、推定 +550 行）は各 1 本か親が直接。README / CHANGELOG / examples / `final_check.sh` / `pixi.toml` / 格子は 0 本。依頼文の規則は Phase 6 reflect のとおり（親の待ち合わせファイル名を書かない / `scratch/turn-NNN-` / `fmt` は親が統合後）
- **順序**: 配列 → COPY → Pool（Pool は `copy_in` の転送と「ACTIVE は捨てる」のテストに COPY が要る）。各タスクの完了基準に §4 の該当行と「`check` 6/6 PASS」を置く。チェックリストの `= N` 行は現在値を grep してから（Phase 6 Minus 6）。現在のテスト数: `test_params` 33 / `test_binary` 14 / `test_leak` 20 / `test_transaction` 13 / `test_connection` 31（`grep -c "^def test_"`）
- **陽性対照を完了基準に**: P13（USAGE 検査を外すと行が消える）、P22（カウンタを戻すと 42P05）、P21（`pool^` の後の使用がコンパイルエラー）、leak（`Pool.__deinit__` の `PQfinish` を消したコピーで FAIL）
- **所要の目安**: probe-copy は 10 万行 ×（IN + OUT + 不正行 10 万行）で 1 秒未満。`test_copy` は 3 形式 × 10 万行でも < 2 s。`test_pool` は接続 10 本程度 < 2 s。`check` 全体は +10〜20 s（leak 2 ループ込み）で 247 s 以内
- **PG 版差**: 無し（§2.4 両サーバー同一、typarray 同一）。`server_version()` 分岐は不要
- **verify への申し送り**: round 1 で §4 の格子 29 行を表で照合（grep パターン / 件数 / ファイルの 3 列）。CI は PR 作成後 `gh pr checks --watch`（REQ §6）。差し戻し round は差し戻し分 + 回帰のみ
