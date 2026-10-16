# RESEARCH — phase2-params-prepared-tx

- 作成: 2026-10-15 / gsd-lite-research（turn 1）
- 入力: REQUIREMENTS.md / DECISIONS.md / HANDOFF.md §5.3・§6・§9・§10、前回 `archive/phase1-sync-text-basic/RESEARCH.md`、
  `reflect/20261015-2308-phase1-sync-text-basic.md`。`state.json.research.targets` = similar_oss / official_docs / local_projects
- 検証環境: Mojo 1.1.0 (8189361e)、libpq 18.6（pixi env `libpq.so.5`）、docker `postgres:17`（17.11、port 54317）/ `postgres:14`（14.24、port 54314）、
  aarch64 Linux。**libpq プローブは PG17 と PG14 で出力が 1 行も違わなかった**（`diff` exit 0。version 行のみマスク）
- **プローブ**: `.gsd-lite/logs/phase2-params-prepared-tx/scratch/turn-001-probe-*.mojo` と `turn-001-probe-libpq-pg17.log` / `-pg14.log`、
  リーク実測 `turn-001-leak-*.log`（gitignore 対象。結論は本書に転記済み。plan / impl は本書の「検証済み」を事実として使ってよい）
- 無人シェルの注意（前回と同じ）: `mojo` / `pixi` は PATH に無い → **`/home/parallels/.pixi/bin/pixi run mojo ...`**。`rg` は無い（`grep` を使う）。
  lean-ctx の MCP ツールは無人ターンでは未接続だった（素の Read / Bash で問題なく進む）

## 0. 結論サマリ

1. **作る（BLOCKED にしない）**。要件を満たす既存 OSS は無い（Phase 1 の評価が有効。§1）。盗む設計は rust-postgres の
   `Drop` → ROLLBACK（結果は捨てる）と `done` フラグ、psycopg 3 の `_pg3_N` 連番名・savepoint 名の識別子エスケープ・
   「外側 tx か」を `PQtransactionStatus == IDLE` で判定、tokio-postgres の `sp_{depth}`（§3）
2. **REQUIREMENTS の受け入れ基準 2 件が実測と食い違う**（要件本文は変えていない。§5 に提案）:
   - (a) **prepared statement は非トランザクショナル**。tx 内で `PQprepare` → `ROLLBACK` しても文は残り `PQexecPrepared` が成功する（E4、PG14/17 同一）。
     逆に tx 内の `DEALLOCATE` は ROLLBACK しても取り消されない（E16〜E18）。REQ §4.3 末尾と §5.1a 4 項目目（26000 を期待）は成立しない
   - (b) **int4 列に int8（OID 20）パラメータを INSERT しても 42804 にならず成功する**（B1、assignment cast）。42804 になる組は
     bool(OID 16)→int4 列 / text(OID 25 明示)→int4 列（L1, L2）。int8 の範囲外値→int4 列は 22003（L4）。REQ §4.2 / §5.1a 3 項目目の例は差し替えが必要
3. **D4（`mojo build` したバイナリでリーク測定）は成立する**。ベースライン RSS 4,084 ページ（≈16 MiB。`mojo run` 時の約 37,700 ページの 1/9）、
   4 ループとも ±2 ページで平坦。**陽性対照**（`Result.__deinit__` の `PQclear` を消したコピー）は 5 サンプル目で abort
   （37741 → 54584 → 71426 → 88268 → 105108）。`TOLERANCE_PAGES = 16` に下げられる。ビルドは cold 3.6 s / cached 0.9 s（§2.3）
4. **最大の API 落とし穴 = ASAP 破棄**: `Transaction` は**最後に使われた文の直後**に破棄され、その時点で ROLLBACK が走る
   （probe-tx: `tx2.execute("INSERT 2")` の直後、次の `print` より前に deinit）。`var tx = conn.transaction(); tx.execute(a); conn.execute(b)` と
   書くと **b は tx の外**で実行される。テスト・example・docstring は「`commit()` / `rollback()` / `_ = tx^` を最後に置く」を規約にする（P1）
5. **Mojo 1.1.0 で確認した設計要素**: `Param` の `@implicit` 群（Bool / Int16 / Int32 / Int64 / Int / Float32 / Float64 / String /
   StringLiteral / List[UInt8] / Optional[T]）を**全部並べても** `[1, "a", 1.5, True, Param.null()]` は曖昧にならず `List[Param]` に変換できる
   （`1` → Int、`1.5` → Float64、`True` → Bool）。ただし**素の `None` リテラルは変換できない**（`@implicit __init__(v: NoneType)` があっても）。
   `def(PgError) thin` フィールド + 生成時コピーは期待どおり。ビッグエンディアンはシフト + `bitcast` で足りる（§2.2）
6. **`mojo format` に `--check` は無い**。§6-3 は「コピーに `mojo format --quiet` → `diff -r -q`」で実現（手順を実測、exit 0 / 差分なし。§2.3）

## 0.5 Mojo 1.1.0 既知の落とし穴（前回 reflect からの転記 + 今回の追加）

前回 reflect「次回への提案」3 項目目の転記（★）と、本ターンで新たに踏んだもの（☆）:

- ★ `_ = x^` は**破棄ではなく生存マーカー**（その行まで x を生かし、その行で deinit が走る）。`var tx = ...; _ = tx^` が「ここで ROLLBACK」の書き方
- ★ `mojo run` はコンパイラを同一プロセスで動かし、解放済みヒープ約 100 MiB が常駐してリークを吸収する。**リーク測定は `mojo build` したバイナリで**（§2.3 で実測）
- ★ `--diagnose-missing-doc-strings` は合成 dunder（`__init__` / `__deinit__` / `__copyinit__` / `__moveinit__`）を struct 宣言行に報告する（`final_check.sh` 3/6 段は除外済み）
- ★ `len(String)` 不可 → `byte_length()`。☆ `s[i]` も不可 → `s[byte=i]` / `s[codepoint=i]`、または `s.as_bytes()[i]`
- ★ `from std.math import isnan`（`isinf` も同じ）。`std.sys.info.is_big_endian()` あり
- ★ リスト literal は `List[Int]` 注釈必須。☆ **`List[UInt8](1, 2, 3)` の位置引数コンストラクタは無い**（`var b: List[UInt8] = [1, 2, 3]` と書く）
- ★ `platform_map` は `List` を返せない。★ `with` 内の `var` は外から見えない。★ `::` は単項マイナスより強い（`-1::int4` は `-(1::int4)`）
- ★ `rg` 無し。`pixi` はフルパス `/home/parallels/.pixi/bin/pixi`
- ☆ **stdlib のソースは pixi env に無い**（`lib/mojo/std.mojoc` のみ、`strings` でも読めない）。型名・シグネチャの確定は
  (1) https://mojolang.org/docs/std/ の該当ページ、(2) コンパイルエラーの note（`Mojo/stdlib/std/collections/list.mojo:494: def __init__(out self, var *values: T, *, __list_literal__: NoneType)` のように**候補シグネチャが出る**）で行う
- ☆ `UnsafePointer` は **deprecated**（`warning: 'UnsafePointer' is deprecated, use 'Pointer' instead`）かつ origin 必須。`Pointer` に `alloc` / `free` は無い（ヒープは `std.memory.alloc` の `alloc(Layout[T](count=n))` / `dealloc`。未検証）
- ☆ デストラクタは `__deinit__(deinit self)`（REQ の `__del__` はこの意味で読む）
- ☆ 素の `None` リテラルは `@implicit __init__(out self, v: NoneType)` を持つ struct にも `Variant[..., NoneType]` にも変換されない（`NoneType(None)` なら可）。
  REQ §4.1 の「`Optional[T]`（None は NULL）」は `Optional[Int](None)` / `var x: Optional[Int] = None` の経路で満たす
- ☆ `PQescapeIdentifier` 等の `size_t` 引数は `c_size_t(s.byte_length())`（`len(...)` の `Int` は変換されない）
- ☆ libpq の既定 notice processor は**サーバーの WARNING / NOTICE を stderr に印字する**（`WARNING:  there is already a transaction in progress` が F2 で出た）。
  `PQsetNoticeProcessor` は未バインド。USAGE 検査でネスト BEGIN / 二重 COMMIT を送らないことが「stderr を汚さない」ことにも効く
- ☆ `atof("-0")` は **-0.0 を返す**（符号ビット 0x8000...、`== 0.0` は True）。`-0.0` の往復は `bitcast[DType.uint64, 1](v) == 0x8000000000000000` で判定する。`NaN == NaN` は False（`isnan` で判定）

## 1. 類似 OSS（similar_oss）

### 1.1 magmalake/postgres.mojo — https://github.com/magmalake/postgres.mojo
Phase 1 RESEARCH §1.1 の評価（エラーは文字列、OID 照合なし、`abort`）がそのまま有効で、Phase 2 でも「作らなくてよい」判定にはならない。
params / Transaction（savepoint 含む）を持つが、今回は再調査せず Phase 1 の結論を引き継ぐ

### 1.2 rust-postgres / tokio-postgres（sfackler）— https://github.com/sfackler/rust-postgres
- `postgres/src/transaction.rs`: `impl Drop for Transaction { fn drop(&mut self) { if let Some(t) = self.transaction.take() { let _ = self.connection.block_on(t.rollback()); } } }`
  → **破棄時 ROLLBACK、エラーは捨てる**。`commit(self)` / `rollback(self)` は所有権を消費（二重 commit は型で防ぐ）
- `tokio-postgres/src/transaction.rs`: `done: bool` フラグ、`Drop` は `if self.done { return; }`、`commit()` は **コマンドタグを見ない**（`COMMIT` を投げて終わり）、
  ネスト tx は savepoint `sp_{depth}`、**savepoint 名はエスケープせず埋め込む**（本プロジェクトは `escape_identifier` を通す。G3〜G9 で `"sp ""1"""` が動作）
- 既知の問題 #635: async の Drop から送った ROLLBACK が poll されない。同期 API の本プロジェクトには無関係だが「`__deinit__` の ROLLBACK は同期で完了まで待つ」ことの裏付け
- 盗む: `done` フラグ、Drop = ROLLBACK + 結果無視（本プロジェクトはフック通知で改良）、commit 後は `done`。
  **D10（COMMIT → ROLLBACK タグなら PgError）は rust-postgres より厳しい**（彼らは成功扱い）

### 1.3 psycopg 3（ローカル: `/home/parallels/workspaces/poc-amano/.venv/lib/python3.12/site-packages/psycopg/`）
- `transaction.py`: `Status` 列挙（NOT_STARTED / ACTIVE / COMMITTED / FAILED / ROLLED_BACK_*）、`_exit_gen` で ROLLBACK 失敗は
  `logger.warning("error ignored in rollback of %s: %s")` に落とす（≒ D8 のフック既定 stderr）、`SAVEPOINT {}` / `RELEASE {}` / `ROLLBACK TO {n}` は
  `sql.Identifier` で**エスケープ**、`_push_savepoint` は `pgconn.transaction_status == IDLE` で「外側 tx か」を決める（≒ D11）
- `_preparing.py:75`: 自動 prepared の名前は **`_pg3_{self._prepared_idx}`（接続ごとの連番）**。`clear()` で名前表を空にし `maintain_gen` が
  `DEALLOCATE`（`None` なら `DEALLOCATE ALL`）を**後で**送る。`transaction.py:160`: **ROLLBACK のたびに prepared キャッシュを捨てる**
  — PREPARE 自体は非トランザクショナルだが、tx 内 DDL が巻き戻ると文が壊れるため（§2.1 E 系と整合）
- `pq/pq_ctypes.py:400,481`: `PQexecParams` / `PQexecPrepared` の lengths / formats は `(c_int * nparams)` 配列、`PQprepare` の types は `(Oid * n)`。
  `PQcmdStatus.restype = c_char_p`、`PQnparams.restype = c_int`、`PQparamtype.restype = Oid`（本書 §7 の `_ffi` 追加 3 本の照合元）

### 1.4 PostgreSQL 公式・ML（挙動の裏付け）
- COMMIT in aborted tx: 公式 COMMIT ページ（v19 / pgedge ミラー）「in an aborted transaction, a COMMIT command returns a command tag of the form ROLLBACK」、
  BUG #1118 スレッド（Tom Lane: 失敗 tx を終える COMMIT は ROLLBACK と報告すべき）。本書 E12 / F10 で実測一致
- PREPARE は非トランザクショナル: pgsql-hackers 2004「PREPARE and transactions」（Alvaro Herrera の実験、Tom Lane「prepare.c should have provisions for rolling back ... but it doesn't」）、
  pgsql-general 2005「both PREPARE and DEALLOCATE are nontransactional」。プロトコル文書「a named prepared-statement object lasts till the end of the current session, unless explicitly destroyed」。
  本書 E4 / E16〜E18 で PG14 / PG17 とも実測一致

## 2. 公式ドキュメント + 検証結果（official_docs）

参照: https://www.postgresql.org/docs/current/libpq-exec.html 、https://www.postgresql.org/docs/current/protocol-flow.html 、
https://www.postgresql.org/docs/current/sql-prepare.html 、https://mojolang.org/docs/std/utils/variant/Variant/ 、https://mojolang.org/docs/std/memory/pointer/Pointer/

### 2.1 libpq の挙動（probe-libpq、PG17 / PG14 で**同一出力**）

公式仕様の要点（libpq-exec）: `paramTypes` が NULL または要素 0 なら型はサーバー推論。`paramValues` の NULL ポインタ = SQL NULL。
`paramLengths` はバイナリのみ参照（テキストは NUL 終端）。`paramFormats` NULL なら全テキスト。`PQexecParams` / `PQprepare` は**単一文のみ**。
`PQnparams` / `PQparamtype` は `PQdescribePrepared` の結果にだけ意味があり他では 0。`PQcmdStatus` の `char*` は `PQclear` まで有効。
バイナリは network byte order（BE）。

| # | 操作 | 結果（status / cmd tag / sqlstate / 備考） |
|---|---|---|
| A1 | `PQexecParams` バイナリ 12 個: bool / int2 -32768 / int4 2147483647 / int8 MIN / float4 NaN / float8 -0.0 / text OID 0 `'; DROP TABLE x; --` / bytea `\x000100ff` / NULL OID 0 / 空 bytea / 空 text / float8 +inf | TUPLES_OK。列 OID 16/21/23/20/700/701/**25**/17/**23**(`$9::int4` の NULL)/17/25/701。値 `t` / `-32768` / `2147483647` / `-9223372036854775808` / `NaN` / **`-0`** / 原文どおり / `\x000100ff` / NULL / `\x` / `` / `Infinity` |
| A2 | `SELECT $1` に text OID 0 `hello` | 列 OID 25（untyped literal は text 推論） |
| A3 | `SELECT $1` に NULL OID 0 | **成功**、列 OID 25（42P18 にはならない。D14 の「推論できない文脈」は PG14/17 では `SELECT $1` に当たらない。`SELECT $1 + 1` 等で要る） |
| A4 | `SELECT $1` に NULL OID 23 | 列 OID 23 |
| A5 | text OID 0 `hello` を `$1::varchar(2)` | `he`（明示キャストは切り詰め） |
| B1 | **int8 OID 20 バイナリ → `INSERT INTO p2(x int4)`** | **`INSERT 0 1` 成功**（assignment cast）。REQ §5.1a 3 項目目の前提が不成立 |
| B2/B3/B4 | int4 → int4、text `'; DROP TABLE p2; --` → text 列、`SELECT count(*)` | 成功。テーブル残存（count 3）、注入文字列は値として格納 |
| C1 | `SELECT $1::int4, $2::int4` にパラメータ 1 個 | FATAL_ERROR **08P01** `bind message supplies 1 parameters, but prepared statement "" requires 2`。**接続は正常のまま**（C2 `SELECT 1` 成功、PQstatus 0、txstatus 0） |
| C3 | `PQexecParams("SELECT 1; SELECT 2", 0 params)` | **42601** `cannot insert multiple commands into a prepared statement` |
| C4 | `SELECT 1;`（末尾 `;`） | 成功（空の 2 文目は許容） |
| C5 | 空 SQL `""` 0 params | **PGRES_EMPTY_QUERY (0)**。Phase 1 `execute` の「empty query」経路を共有すれば `kind=Server` になる |
| C6 | `INSERT ...` via `PQexecParams` | cmd `INSERT 0 1` |
| D1/D2 | `PQprepare("pq_stmt_1", "SELECT $1::int4 + $2::int4, $3", 0 types)` → `PQdescribePrepared` | prepare: COMMAND_OK、**cmd tag は空文字**。describe: COMMAND_OK、`PQnparams` 3、`PQparamtype` 23 23 **25**（`$3` 未指定は text 推論）、`PQnfields` 2、`PQftype` 23 25 |
| D3 | 同名で再 prepare | **42P05** `prepared statement "pq_stmt_1" already exists` |
| D4 / D8 | 存在しない名前を describe / execPrepared | **26000** `prepared statement "no_such_stmt" does not exist` |
| D5 | `PQexecPrepared` に 3 個中 1 個 | **08P01** `bind message supplies 1 parameters, but prepared statement "pq_stmt_1" requires 3`。**接続は正常**（D6 成功）。D15 の「接続状態が不安定」は不成立だが、tx 内なら tx が abort するのでローカル検査の価値はある |
| D7 | 3 個で実行 | `3` / `t` |
| D9 | `PQprepare(..., types=[20])` で `INSERT INTO p2(x int4) VALUES ($1)` | **成功**（prepare 時も assignment cast） |
| D10 | `PQprepare` に 2 文 | 42601 |
| D11/D12 | INSERT を prepare → describe | nparams 2 (23, 25)、**nfields 0** |
| E1〜E4 | `BEGIN` → prepare `pq_stmt_2` → `ROLLBACK` → `PQexecPrepared` | **成功（42）**。prepared は ROLLBACK で消えない |
| E5 | `pg_prepared_statements` | 残っている文が列挙される（count 4） |
| E6/E7 | `DEALLOCATE pq_stmt_2` ×2 | 1 回目 COMMAND_OK cmd `DEALLOCATE`、2 回目 **26000** |
| E8〜E11 | aborted tx 内の `DEALLOCATE` / `PQexecPrepared` | **25P02** `current transaction is aborted, commands ignored until end of transaction block`（txstatus 3 のまま） |
| E12 | aborted tx で `COMMIT` | **COMMAND_OK、cmd tag `ROLLBACK`**、txstatus → 0（D10 の前提どおり） |
| E14 | 失敗した DEALLOCATE の後 | 文は残っている（describe 成功） |
| E15〜E18 | `BEGIN` → `DEALLOCATE pq_stmt_1` → `ROLLBACK` → describe | **26000**: DEALLOCATE も ROLLBACK で取り消されない |
| F2 | `BEGIN` 内で `BEGIN` | COMMAND_OK cmd `BEGIN`、**stderr に `WARNING:  there is already a transaction in progress`**（libpq 既定 notice processor）。D11 の前提どおり |
| F4/F5 | tx 外で `COMMIT` / `ROLLBACK` | COMMAND_OK、stderr に `WARNING:  there is no transaction in progress` |
| F6〜F11 | INSERT → abort → INSERT(25P02) → `COMMIT`(cmd `ROLLBACK`) → count | **0 行**（aborted tx の COMMIT は何も書かない） |
| G1 | tx 外で `SAVEPOINT a` | **25P01** `SAVEPOINT can only be used in transaction blocks` |
| G3〜G9 | `PQescapeIdentifier("sp \"1\"")` = `"sp ""1"""` で `SAVEPOINT` / `ROLLBACK TO` / `RELEASE` | 全部 COMMAND_OK。cmd tag は `SAVEPOINT` / **`ROLLBACK`**（ROLLBACK TO も `ROLLBACK`）/ `RELEASE`。ROLLBACK TO 後 count 1（部分取り消し） |
| G10 / G11 | 存在しない savepoint を `RELEASE` / `ROLLBACK TO` | **3B001** `savepoint "nope" does not exist`、**tx は aborted（txstatus 3）になる** |
| G15〜G18 | `SAVEPOINT s1` → `SELECT 1/0`(22012) → `ROLLBACK TO s1` → `SELECT 1` | **aborted tx が回復する**（txstatus 3 → 2、SELECT 成功）。savepoint の実用例 |
| H3 | aborted tx 内の `PQexecParams` | 25P02 |
| I1〜I5 | `BEGIN` → `pg_terminate_backend(pg_backend_pid())` → `ROLLBACK` / `DEALLOCATE` | terminate: FATAL_ERROR sqlstate 空、PQstatus **1 (BAD)**、txstatus **4 (UNKNOWN)**。その後の `PQexec` は **NULL**、`PQerrorMessage` = `no connection to the server`。`Transaction.__deinit__` と `PreparedStatement.__deinit__` の接続断経路はこれ |
| J1〜J4 | 無名文 `""` の prepare / describe、単純クエリ後 | 単純クエリで無名文は消える（26000 `unnamed prepared statement does not exist`）。本プロジェクトは無名文を使わない |
| J5〜J7 | cmd tag | `SELECT 1`（行数付き）/ `UPDATE 0` / `CREATE TABLE` |
| K1 | text パラメータに NUL (`ab\0cd`) | **`ab`（長さ 2）に黙って切れる** → REQ の送信前 USAGE 拒否が必要（D13） |
| K2 | bytea バイナリに NUL (`a\0b`) | 長さ 3、`\x610062` で往復 |
| L1 | bool OID 16 → int4 列 | **42804** `column "x" is of type integer but expression is of type boolean` |
| L2 | text OID 25 明示 `abc` → int4 列 | **42804** `... but expression is of type text` |
| L3 | text OID 0 `abc` → int4 列 | **22P02** `invalid input syntax for type integer: "abc"` |
| L4 | int8 3,000,000,000 → int4 列 | **22003** `integer out of range` |
| L5 | `WHERE x = $1` に int8 | 成功（int4 = int8 演算子あり） |
| L6 | float8 1.5 → int4 列 | **成功**（assignment cast で丸め） |
| L7 / L9 | text OID 25 → text / varchar / name / char(3) 列 | 全部成功（D6 の「OID 25 を付けると varchar/name でキャストが要る」懸念は INSERT では当たらないが、OID 0 推論の方が安全なので D6 は維持） |
| L10 | `SELECT $1` に int8 バイナリ | 列 OID 20 |
| L11 / L12 | `SELECT $1 + 1` に int4 バイナリ / text OID 0 `7` | どちらも `8`（OID 23）。untyped text は演算子から型推論される |

### 2.2 Mojo 1.1.0 言語（probe-implicit / probe-tx / probe-encode / probe-variant / probe-negzero）

| 項目 | 事実 | 根拠 |
|---|---|---|
| `Param` の `@implicit` 群 | Bool / Int16 / Int32 / Int64 / Int / Float32 / Float64 / `var String` / StringLiteral / `var List[UInt8]` / `Optional[Int]` / `Optional[String]` / `Optional[Bool]` / NoneType の **14 本を並べても** `use([1, "a", 1.5, True, Param.null(), Param.null(23)])` が `List[Param]` に変換される。`1` → Int(OID 20)、`1.5` → Float64(701)、`True` → Bool(16)、`"a"` → StringLiteral 経路 | probe-implicit 出力 |
| 素の `None` | `use([None])` は `cannot be converted from list literal to 'List[Param]'`（NoneType overload があっても）。`var x: Optional[Int] = None` を渡せば NULL(OID 20) になる | 同上 |
| `Optional[T]` overload | `Optional[Int](7)` → Int 経路、`None` の Optional → `Param.null(oid)` 相当。`Optional[String]` は `var` 引数で `take()` できる | 同上 |
| 型付き値 | `Int16(-32768)` / `Int32(2147483647)` / `Int64(-1)` / `Float32(1.5)` がそれぞれの overload に落ちる（Int に吸われない） | 同上 |
| `def(Err) thin` フィールド | struct フィールドに置けて、非キャプチャ `def` を代入・呼び出し可。`transaction()` 生成時にコピーしたハンドラは、その後 `conn.set_handler()` を差し替えても**変わらない**（tx2 は default、tx3 は TEST） | probe-tx |
| 汎用 `Tx[origin: ImmOrigin](Movable)` + `__deinit__` | `Pointer[Conn, origin]` を持つ Movable-only struct に `__deinit__` を書けて、`conn.transaction(ref self) -> Tx[origin_of(self)]` が `var conn` から呼べる。tx 生存中に `conn.execute` も `conn.set_handler(mut self)` も**コンパイルが通り動く**（排他借用エラーにならない） | probe-tx |
| **ASAP 破棄** | `tx2.execute("INSERT 2")` の直後（次の `print` より前）に `Tx deinit: implicit ROLLBACK` が出る。`tx.commit()`（`mut self`）後は `done` で deinit は何もしない。`_ = tx3^` でその行に deinit | probe-tx |
| 不変 `self` からのカウンタ更新 | `var _counter: List[Int]` + `Pointer[Int, MutUntrackedOrigin](unsafe_from_address=Int(self._counter.unsafe_ptr()))[] += 1` が警告なしで動く（`loader.libpq_ptr` と同じキャスト）。`prepare(self)` の `pq_stmt_N` 採番に使える（規約外の書き込みなので代替案は §4 P9） | probe-tx `pq_stmt_1 pq_stmt_2` |
| BE エンコード | `(v >> (8*(n-1-i))) & 0xFF` のシフトで int2/int4/int8/bool、`bitcast[DType.uint32, 1](Float32)` / `bitcast[DType.uint64, 1](Float64)` で浮動小数。結果: int2 -32768 `8000`、int4 2^31-1 `7fffffff`、int8 MIN `8000000000000000`、f32 1.5 `3fc00000`、f32 NaN `7fc00000`、f32 ±inf `7f800000` / `ff800000`、f64 -0.0 `8000000000000000`、f64 NaN `7ff8000000000000`。`is_big_endian()` = False（ホストは LE。シフト方式はエンディアン非依存） | probe-encode |
| `List[c_int]` | `IntPtr = Pointer[c_int, ImmUntrackedOrigin]` に渡す lengths / formats は **`List[c_int]`**（`List[Int]` だと 8 byte ストライドで壊れる）。`List[UInt32]` が `OidPtr`。空 `List[Int]().unsafe_ptr()` は 8（非 NULL のセンチネル）だが、probe では末尾ダミー 1 要素を足して安全側にした | probe-encode / probe-libpq |
| `std.utils.Variant` | 存在する（`Variant[*Ts: AnyType]`、`isa[T]`、`v[T]`（**mut が必要**）、`unwrap[T]`、`@implicit __init__[T: Movable](var value: T)`）。`var d: V = None` は `Type does not exist in Variant`（`NoneType(None)` なら可）。**D5 の手書き variant 構造体で足りるので採用不要**（`Variant` は `v[T]` に mut が要り、Copyable/Writable の条件付き準拠が面倒） | probe-variant |
| `-0` / NaN テキスト | `atof("-0")` → -0.0（bits 0x8000000000000000、`== 0.0` True）。`Float32(atof("-0"))` bits 0x80000000。`NaN == NaN` False | probe-negzero |

### 2.3 ツールチェーン（検証済み）

| 項目 | 事実 |
|---|---|
| `mojo build -I src tests/test_leak.mojo -o <bin>` | 成功、289 KB。**cold 3.6 s / cached 0.9 s**（`run_tests.sh` の追加コストは無視できる） |
| ビルド済みバイナリの RSS | `connect/query/close` [4084, 4086 ×8]、`failed-open` [4465 ×4]、`escape_literal` [4573 ×4]、`failed-execute` [4573 ×4]（PG17）。ベースライン ≈ 16 MiB、**+83 ページの一段は出なかった**（1 回の実測）。8 tests PASS、本体ループ 45.0 s |
| 陽性対照（`result.mojo` `__deinit__` の `PQclear` → `pass`、`-I <copy>` でビルド） | `connect/query/close` [37741, 54584, 71426, 88268, 105108] で **ABORT_PAGES 超過 → FAIL**（27.9 s で打ち切り）。他 3 ループは PASS（PQclear 以外は消していないので正しい）。ログ: `scratch/turn-001-leak-noclear-pg17.log` |
| → D4 判定 | `TOLERANCE_PAGES = 16` に下げてよい見込み（平坦 ±2）。impl は PG14 側と 2〜3 回の再実行で +83 の再来を確認してから確定する（P6） |
| `mojo format` | オプションは `--line-length` / `--quiet` のみ。**`--check` / `--diff` は無い**。§6-3 の実装: `cp -r src tests examples hello.mojo <tmp>/` → `mojo format --quiet <tmp>/...` → `diff -r -q src <tmp>/src` 等（実測: format exit 0、diff exit 0）。`<tmp>` は `build/fmtcheck/`（gitignore 済みの `build/`）が妥当 |
| `mojo run` の probe 所要 | probe-libpq（約 480 行）はコンパイル含め数秒。impl のプローブは気軽に回せる |

## 3. 盗める設計 / 使えるライブラリ（plan が採否表にする）

1. **`done` フラグ + 破棄時 ROLLBACK**（rust-postgres）。本プロジェクトは失敗を `def(PgError) thin` フックへ（D8）。`commit()` / `rollback()` は `mut self` で `done = True` にしてから SQL を送る（送信失敗でも二重送信しない）
2. **COMMIT のコマンドタグ検査**（PG 公式 + E12/F10）: `PQcmdStatus(res) == "ROLLBACK"` → `PgError(kind=Server, sqlstate="", message="COMMIT resulted in ROLLBACK: transaction was aborted")`。rust-postgres / psycopg は検査しないので本プロジェクト独自
3. **prepared 名 `pq_stmt_N`**（psycopg の `_pg3_N` と同型）。`PQprepare` 成功 → `PQdescribePrepared` → `PQnparams` / `PQparamtype` を保持（D15）。失敗時は `PQclear` のみ（describe 失敗時は `DEALLOCATE` を試みてから raise）
4. **savepoint 名は `escape_identifier`**（psycopg `sql.Identifier`。G3〜G9 で動作確認）。空文字は USAGE（`PQescapeIdentifier("")` は `""` を返し SQL エラーになるので先に弾く）
5. **外側 tx 判定は `PQtransactionStatus == PQTRANS_IDLE`**（psycopg `_push_savepoint`、D11）。`PQTRANS_UNKNOWN`（接続断）は USAGE ではなく `kind=Connection` にする方が親切（I5 で txstatus 4 + PQstatus BAD を確認）
6. **`PQexecParams` のバッファ組み立て**（probe-libpq の `Params` struct がそのまま雛形）: `types: List[UInt32]`、`bufs: List[List[UInt8]]`（テキストは NUL 付きバイト列、バイナリは BE バイト列）、`is_null: List[Bool]`、`lengths: List[c_int]`、`formats: List[c_int]`、直前に `values: List[Int]`（アドレス、NULL は 0）を作り、呼び出し後に `_ = x^` で全部を生かす。psycopg `pq_ctypes.py:400` と同じ形
7. **エンコード関数の置き場**: `encode_binary.mojo`（`encode_bool / encode_int16 / encode_int32 / encode_int64 / encode_float32 / encode_float64 -> List[UInt8]`）。Phase 3 の `decode_binary` の逆として同名規則で並べる
8. **psycopg の「ROLLBACK で prepared キャッシュを捨てる」**は本プロジェクトでは不要（`PreparedStatement` はユーザー所有で、ROLLBACK 後も有効と実測）。ただし tx 内 DDL を巻き戻した後の `execute` はサーバーエラーになり得ることを docstring に書く
9. `_ffi` 追加 3 本の照合元: psycopg `_pq_ctypes.py:417-431`（`PQnparams: [PGresult_ptr] -> c_int`、`PQparamtype: [PGresult_ptr, c_int] -> Oid`、`PQcmdStatus: [PGresult_ptr] -> c_char_p`）、ヘッダ行 `libpq-fe.h:600 / 607 / 608`

## 4. 落とし穴と検証方法（plan は完了基準に写す）

| # | 落とし穴 | 回避策 | どう検証すれば踏んでいないと分かるか |
|---|---|---|---|
| P1 | **ASAP 破棄で `Transaction` が最後の使用直後に ROLLBACK される**（§2.2）。`conn.execute` を tx の後に書くと tx の外で走る | `Transaction` の docstring と `examples/params.mojo` で「`commit()` / `rollback()` / `_ = tx^` を最後に置く」を規約化。テストは tx を使い終える行を明示 | テスト「`var tx = conn.transaction(); tx.execute(INSERT); _ = tx^; conn.transaction_status() == PQTRANS_IDLE; SELECT count = 0`」で破棄タイミングを固定。負の例を docstring に載せる（コンパイルテストは不要） |
| P2 | `PreparedStatement.__deinit__` も ASAP: 最後の `stmt.execute()` 直後に `DEALLOCATE` が走る | 同上。`pg_prepared_statements` を読むテストは `_ = stmt^` の後に | `prepare → execute → _ = stmt^ → SELECT count(*) FROM pg_prepared_statements WHERE name = <name>` が 0。`_ = stmt^` の前は 1 |
| P3 | `List[Int]` を lengths / formats に渡すとストライドが 8 byte で壊れる | `List[c_int]`（§2.2）。types は `List[UInt32]` | A1 相当の 12 パラメータ往復（lengths / formats が 2 個目以降もずれない）。特に **2 個目以降のバイナリ長**が正しいことは複数バイナリ param のテストでしか分からない |
| P4 | テキスト param の NUL が黙って切れる（K1） | `_reject_nul` 相当を `kind=USAGE` で（REQ）。`String` param のみ。bytea はバイナリなので検査しない | `execute("SELECT $1", ["ab\0cd"])` が USAGE で、サーバーに届かない（`pg_stat_activity` は見なくてよい。raise が先） |
| P5 | `PQexecParams` のバッファ寿命: `values` の中のアドレスが指す `List[UInt8]` / `String` が呼び出し前に死ぬ | `Params` 相当の struct に全部を所有させ、呼び出し後に `_ = p^`（§3-6） | 64 KiB の bytea と 64 KiB の text を同時に送る往復テスト + `test_leak` の params ループ（10,000 回 × 64 KiB payload）で RSS 平坦 |
| P6 | リーク判定の tolerance を下げすぎて +83 ページの一段で偽陽性 | ビルド済みバイナリで実測（§2.3）。impl は PG14 / PG17 各 2 回以上回してから `TOLERANCE_PAGES` を決める。下げられなければ現状維持で理由を PROGRESS に | 陽性対照（`PQclear` / `PQfinish` / `PQfreemem` のいずれかを消したコピーで FAIL）を**同じターンで**回しサンプル列を PROGRESS に貼る（REQ §5.3。本書 §2.3 に初回実測あり） |
| P7 | `run_tests.sh` の `mojo build` 生成物の置き場と削除 | `build/test_leak`（gitignore 済み）。ビルド失敗なら status=1 | `pixi run test` 後に `build/test_leak` が存在し、ログに `mojo build` の行がある。`PQ_TEST_LEAK_SERVERS=1`（名前は plan）で `check` が片側だけ回る |
| P8 | `Connection.execute(sql, params)` が空 SQL で `PGRES_EMPTY_QUERY` を返す（C5） | Phase 1 `execute` の結果処理（status 判定 / 診断コピー / PQclear）を共通関数に抽出して両方から呼ぶ（REQ §4.2） | `execute("", [])` が `PgError(kind=Server, message="empty query")`。`execute("SELECT 1; SELECT 2", [])` が 42601 |
| P9 | `prepare(self)` でカウンタを増やせない（`self` 不変） | 案 A: `var _stmt_counter: List[Int]` + `MutUntrackedOrigin` キャスト（動作確認済み。§2.2）/ 案 B: `prepare(mut self)`（`conn.set_handler(mut self)` が tx 生存中に通ったので型上は可。ただし `PreparedStatement[origin]` の origin は `origin_of(self)` の扱いを要確認）/ 案 C: `_Global` の プロセス共通カウンタ（未検証）。推奨 A | `prepare` を 2 回呼んで `name()` が `pq_stmt_1` / `pq_stmt_2`。Connection を 2 本開いて両方 `pq_stmt_1` から始まる（接続ごと） |
| P10 | `PQprepare` 成功後の `PQdescribePrepared` 失敗で文がサーバーに残る | describe 失敗時は `DEALLOCATE <name>` を試みて（失敗は無視）raise | 再現が難しい（describe は普通失敗しない）。コードレビューで経路を確認。`PQclear` 漏れがないことを `test_leak` の prepare/execute/deallocate 10,000 回で |
| P11 | aborted tx 内で `PreparedStatement.__deinit__` の `DEALLOCATE` が 25P02 で失敗する（E10） | 無視（REQ D13）。`PQexec` の結果が NULL / COMMAND_OK 以外でも `PQclear` して終わる | tx 内で prepare → `SELECT 1/0` → `_ = stmt^` → `tx.rollback()` が通り、stderr にトレースバック無し。その後 `DEALLOCATE <name>` を手動で送ると **COMMAND_OK**（文が残っている。E14）か 26000 かは実装次第なので plan が期待値を決める |
| P12 | `commit()` の判定を `PQresultStatus` だけで行うと aborted tx の COMMIT を成功扱いにする | `PQcmdStatus(res) == "ROLLBACK"` を見る（E12 / F10）。`PQcmdStatus` は `PQclear` 前にコピー | `BEGIN → INSERT → SELECT 1/0 → commit()` が `PgError(kind=Server, sqlstate="")` で message に `ROLLBACK` を含み、`transaction_status() == IDLE`、INSERT 行が無い |
| P13 | 二重 `commit` / `rollback`、終了後の `savepoint` 等がサーバーに届くと WARNING が stderr に出る（F4 / F5） | `done` フラグで USAGE（D11） | 二重 commit が USAGE で、**stderr に `WARNING:` が出ない**（`check` 6/6 段の `warning:` 判定は小文字なので別途 `grep -c 'WARNING:'` をテストログに） |
| P14 | ネスト `transaction()` を `PQTRANS_IDLE` 以外で弾くと、接続断（`PQTRANS_UNKNOWN`）も USAGE になる | `PQstatus == CONNECTION_BAD` を先に見て `kind=Connection` | `pg_terminate_backend` 後に `conn.transaction()` → `kind=Connection`（USAGE ではない） |
| P15 | `Transaction.__deinit__` の ROLLBACK が接続断で NULL を返す（I3） | NULL → `PgError(kind=Connection, message=PQerrorMessage)` をハンドラへ。COMMAND_OK 以外 → `kind=Server` | §5.1a 1 項目目: テスト用ハンドラ（非キャプチャ `def`）が受け取った `PgError` を**グローバルに記録できない**（モジュール `var` 不可）→ ハンドラは `print` して、テストは stdout を見られないので… **代替**: ハンドラが `_Global` に書く、または `set_rollback_failure_handler` に渡す def が特定の環境変数を `setenv` する。plan が決める（`_Global["pq_test_hook", init]` が最も素直。Phase 1 RESEARCH §2.2 で `_Global` 使用法は確認済み） |
| P16 | `ROLLBACK TO` / `RELEASE` の存在しない名前で tx が aborted になる（G10 / G11） | サーバー任せ（`kind=Server`, 3B001）。docstring に「以降は `rollback()` しか通らない」と書く | `rollback_to("nope")` が 3B001、その後 `tx.execute` が 25P02、`tx.rollback()` が通る |
| P17 | `Row.get[Float64]` で `-0.0` の往復を `==` で判定すると +0.0 でも通る | テストは `bitcast[DType.uint64, 1](v) == 0x8000000000000000`（§0.5） | 同左。NaN は `isnan` |
| P18 | **型不一致テストの題材**: int8 → int4 列は成功する（B1）。REQ §5.1a の例が成立しない | 題材を bool → int4 列（42804）または int8 範囲外 → int4 列（22003）に差し替え（§5 提案 2） | `execute("INSERT INTO t(x int4) VALUES ($1)", [True])` が `kind=Server` で sqlstate 非空（42804）。`[Int(3000000000)]` が 22003 |
| P19 | **prepared が ROLLBACK で消えない**（E4）。REQ §4.3 / §5.1a の 26000 期待が成立しない | §5 提案 1 の読み替え。26000 経路は「ユーザーが `conn.execute("DEALLOCATE " + stmt.name())` した後の `stmt.execute`」で作れる | `BEGIN → prepare → ROLLBACK → stmt.execute()` が**成功**。別テストで手動 DEALLOCATE 後の `stmt.execute()` が 26000、`_ = stmt^` が静かに終わる |
| P20 | `PQnparams` / `PQparamtype` を describe 以外の結果に使うと 0 が返る（仕様） | `PreparedStatement` は describe 結果からだけ読む | `param_count()` が D2 の 3、`param_type_oid(2)` が 25、`param_type_oid(3)` が範囲エラー |
| P21 | 無名文 `""` は単純クエリで消える（J3 / J4） | 使わない（名前は常に `pq_stmt_N`） | `prepare` の実装に `""` を渡す経路が無いことをレビュー |
| P22 | `PQexecParams` の `paramTypes` に 0 を混ぜたとき `$n` の型はサーバー推論（A2 / L12）。`Param(String)` は OID 0 なので `SELECT $1` は text、`SELECT $1 + 1` は int4 になる | 仕様どおり。docstring に例 | A2 / L12 と同じ 2 ケースをテストに |
| P23 | `check` の fmt 1/6 段を git diff で判定している（§6-3） | コピー + `mojo format` + `diff -r`（§2.3） | 未コミットの整形済み差分がある作業木で `check` 1/6 が PASS、わざと 1 行崩したコピーで FAIL（陽性対照） |
| P24 | `escape_identifier` 由来の `"..."` を `SAVEPOINT` に入れると cmd tag が `SAVEPOINT`、`ROLLBACK TO` の cmd tag は `ROLLBACK`（G7） | `rollback_to()` では cmd tag を見ない（`commit()` 専用の判定） | `savepoint("a"); rollback_to("a")` が成功し `PgError` にならない |

## 5. 要件への影響（提案。REQUIREMENTS.md 本文は変更していない）

1. **§4.3 末尾 + §5.1a 4 項目目（prepared と ROLLBACK）**: 「rollback された tx 内で prepare された文はサーバー側で消える → 26000」は PG14 / PG17 で**不成立**（E4）。
   読み替え案: 「tx 内で prepare した文は ROLLBACK 後も有効（テストで `execute` 成功を固定）。26000 の経路は、ユーザーが `conn.execute("DEALLOCATE " + stmt.name())` で
   先に消した後の `stmt.execute()` で固定し、その `__deinit__` の DEALLOCATE 失敗（26000）が無視されトレースバックを出さないことを確認する」。
   `name()` を公開する D15 がここで効く
2. **§4.2 / §5.1a 3 項目目（型不一致）**: 「int4 列に `Int`（int8）→ 42804 等」は**不成立**（B1 成功、D9 の prepare も成功）。
   差し替え案: `Bool` → int4 列（42804、L1）を主例に、`Int(3000000000)` → int4 列（22003、L4）を追加。「sqlstate 非空を assert」の方針は維持
3. **§4.4 `transaction()` の前提**: `PQTRANS_IDLE` 以外は USAGE、に「ただし `PQstatus == CONNECTION_BAD` なら `kind=Connection`」を足す提案（I5 で txstatus 4）
4. **§5.1a 1 項目目（接続断中の tx 破棄でハンドラが呼ばれる）**: 検証可能だが、ハンドラは非キャプチャ `def` なのでテストが受信を観測する手段が要る
   （`_Global` セル or `setenv`。P15）。plan で手段を決める
5. **§5.3 リーク測定**: D4 のフォールバック条件は不要になる見込み（§2.3）。`TOLERANCE_PAGES` は impl が PG14 / PG17 × 2 回で決定
6. **§5.1a 境界値往復**: `-0.0` の一致判定はビット比較に（P17）。`Float32` NaN はバイナリ `7fc00000` で送り `NaN` テキストで戻る（A1）
7. **§6-3 fmt 判定**: `mojo format --check` は無いので「コピーに適用して比較」で確定（§2.3 の手順）。一時ディレクトリは `build/fmtcheck/`
8. **用語**: REQ の `__del__` は Mojo 1.1.0 の `__deinit__(deinit self)`。docstring では `__deinit__` と書く

## 6. ローカルプロジェクト（local_projects: `~/workspaces`）

- Mojo のソースは本リポジトリ以外に無い（前回と同じ）。`PQexecParams` / `Variant[` を使う Mojo コードは無い
- **psycopg 3**（`poc-amano` / `bizcore-factory` の `.venv`）が唯一の同型実装。参照したファイル:
  - `psycopg/transaction.py:60-220`（Status 列挙、`_exit_gen`、`_get_enter/commit/rollback_commands`、`_push_savepoint`）
  - `psycopg/_preparing.py:75,174-198`（`_pg3_N`、`clear` / `maintain_gen` の DEALLOCATE）
  - `psycopg/pq/_pq_ctypes.py:290-321,417-431`、`psycopg/pq/pq_ctypes.py:383-520`（argtypes、`(c_int * nparams)` の lengths / formats）
- Phase 1 の scratch（`.gsd-lite/logs/phase1-sync-text-basic/scratch/`）: `turn-015-positive-control.sh` が陽性対照の雛形（`sed -i "${line}s/.*/pass/"` でコピーの free を消す）。
  今回は `mojo build -I <copy>` 版を `turn-001-leaksrc/` で実施

## 7. plan への申し送り

- **`_ffi` 追加 3 本**（REQ §4.6。ヘッダは `.pixi/envs/default/include/libpq-fe.h`）:

  | 関数 | C プロトタイプ（行） | Mojo thin 型 |
  |---|---|---|
  | `PQcmdStatus` | `char *PQcmdStatus(PGresult *res);`（600） | `def(PGresultPtr) thin abi("C") -> CStr`（NULL にならない。空文字はあり得る: prepare / describe の結果） |
  | `PQnparams` | `int PQnparams(const PGresult *res);`（607） | `def(PGresultPtr) thin abi("C") -> c_int` |
  | `PQparamtype` | `Oid PQparamtype(const PGresult *res, int param_num);`（608） | `def(PGresultPtr, c_int) thin abi("C") -> UInt32` |

  `functions.mojo` の「result inspection」節に追加、`test_ffi.mojo` の `_symbol_names()` に 3 名を足し `assert_equal(len(names), 53)`、関数名 `test_all_fifty_symbols_present` は改名
  （PLAN / PROGRESS の「50 本」表記も 53 に）。probe-libpq の `Extra` struct がそのまま雛形
- **`PQexecParams` / `PQexecPrepared` の Mojo 側呼び出し**は probe-libpq の `exec_params` / `exec_prepared` / `prepare` / `describe` をそのまま流用できる
  （`OidPtr` / `CStrArray` / `IntPtr` の `unsafe_from_address` キャスト、末尾ダミー要素、`_ = x^` の並び）
- **テスト設計の固定事項**: tx / stmt の最後の使用を明示（P1 / P2）、lengths / formats は `List[c_int]`（P3）、型不一致の題材（P18）、prepared × ROLLBACK（P19）、
  `-0.0` はビット比較（P17）、WARNING が stderr に出ないことの確認（P13）
- **リーク**: `run_tests.sh` の `mojo build` 分岐、`TOLERANCE_PAGES` 決定、陽性対照を同ターンで（P6 / P7）。陽性対照の雛形は本書 §2.3 と `scratch/turn-001-leaksrc/`
- **検証コマンド**: `check` の fmt 段を直すまでは「コミット後に回す」。直したら作業木のままで回せる（P23）
- **未検証のまま残すもの**（plan は「未プローブ」と明記）: `prepare(mut self)` 案 B の origin 整合、`_Global` でのテスト用フック観測（P15）、
  `std.memory.alloc` の API、PG14 側のビルド済みバイナリのリーク系列（PG17 のみ実測）
