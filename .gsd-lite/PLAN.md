# PLAN — phase3-binary-all-types

- 作成: 2026-10-16 / gsd-lite-plan（turn 2）
- 入力: REQUIREMENTS.md / DECISIONS.md / RESEARCH.md / `.gsd-lite/reflect/20261016-0246-phase2-params-prepared-tx.md`（直近）/
  `.gsd-lite/reflect/20261015-2308-phase1-sync-text-basic.md` / `archive/phase2-params-prepared-tx/PLAN.md`（書式の手本）/
  `src/pq/*.mojo` / `tests/*` / `examples/*` / `HANDOFF.md` §4・§6・§8・§10・§11
- 対象リポジトリ: `.`（in-repo 形）。`CLAUDE.md` / `AGENTS.md` は無い（`ls CLAUDE.md AGENTS.md` → 両方 "そのようなファイルやディレクトリはありません"）
- 無人シェルの注意（RESEARCH 冒頭と同じ）: `mojo` / `pixi` は PATH に無い → **`/home/parallels/.pixi/bin/pixi run ...`**。`rg` は無い（`grep`）。
  docker の DB は `tests-pg17-1`（127.0.0.1:54317）/ `tests-pg14-1`（127.0.0.1:54314）が healthy で起動中（plan 時点 `docker ps`、Up 24 hours）。
  Mojo は 1.1.0 (8189361e)（`pixi run mojo --version`）。lean-ctx MCP は未接続（素の Read / Bash で可）
- research のプローブ（`.gsd-lite/logs/phase3-binary-all-types/scratch/turn-001-*`、gitignore 対象）は impl が**雛形として開いてよい**:
  `probe-binary.mojo`（`Params` / `exec_fmt` / hex ダンプ）、`probe-zerocopy-neg6.mojo`（zero-copy の 3 行と陽性対照の形）、
  `probe-civil.mojo`（Hinnant 暦算法、そのまま写せる）、`probe-bench.mojo`（ベンチ SQL と計時）、`probe-binary-pg17.log` / `-pg14.log`（期待値の原本）

## 検証コマンド

impl の各ターンがテストに使うコマンド（リポジトリルートで実行。`cd` 不要）:

```bash
/home/parallels/.pixi/bin/pixi run db-up        # 環境の初期化（--wait 付き。起動済みなら即終了）
/home/parallels/.pixi/bin/pixi run test         # tests/run_tests.sh: 54317 → 54314 の順に tests/test_*.mojo を 1 ファイル 1 プロセス（test_leak は build/test_leak）
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_decode_binary.mojo   # 単一ファイル（サーバー不要のものは PQ_TEST_CONNINFO 無関係）
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_binary.mojo          # 単一ファイル（PQ_TEST_CONNINFO 未設定なら 54317）
/home/parallels/.pixi/bin/pixi run mojo build -I src tests/test_leak.mojo -o build/test_leak   # leak だけ手で回すとき（run_tests.sh と同じ）
/home/parallels/.pixi/bin/pixi run package      # mojo precompile src/pq -o build/pq.mojoc（警告ゼロ確認）
/home/parallels/.pixi/bin/pixi run check        # 最終判定: bash tests/final_check.sh（6 段、exit 0 が合格）
```

- 環境の初期化（テストの前に毎回）: `/home/parallels/.pixi/bin/pixi run db-up`
- 最終判定（クリーンな状態から全検査。verify と T9 が使う）: **`/home/parallels/.pixi/bin/pixi run check`**
  - 1/6 段はコピーに `mojo format` → `diff -r` なので**作業木のまま**回せる（Phase 2 T1 で修正済み。`tests/final_check.sh:57-79`）
  - 5/6 段は `PQ_TEST_LEAK_SERVERS=1` で `test_leak` を PG17 だけ（`final_check.sh:127`）。`pixi run test` は両サーバーで回す
  - 6/6 段は `grep -cE 'warning:|WARNING:'`（`final_check.sh:144`）。T1 で `|implicit ROLLBACK failed` を足す（REQ §6-2）。**見出し行と `say()` にこれらの文字列を含めない**
- 所要の目安（Phase 2 末の実測: `check` 80〜115 s、`pixi run test` 5〜6 分、test_leak 1 サーバー 57〜59 s）。Phase 3 で乗るもの:
  `Connection.open` の SET 1 往復（約 +1 ms × connect ループ 10,000 回 ≒ +10 s）、leak ループ 2 本（約 +5 s）、example 1 本、
  新テストファイル 7 本（各 2〜10 s）。**`check` は 2〜3 分、`pixi run test` は 7〜8 分と見込む**（未確認。impl は所要を PROGRESS に単位付きで書く）
- PG14 / PG17 の差は interval の ±infinity だけ（RESEARCH §2.2.7）。**PG17 限定ケースは `conn.server_version() >= 170000`（`src/pq/connection.mojo:712-719`）で分岐**。他は全テスト両サーバー同一期待値

## 追従先チェックリスト

| 変更の種類 | 直す場所 | 確かめ方 |
|---|---|---|
| `Row.get[T]` の対応型を足す（T3〜T5: 8 型） | `src/pq/decode_text.mojo:156-236` の `comptime if` 分岐 + `:132-155` docstring の型一覧、`src/pq/decode_binary.mojo`（T2 新設）の分岐 + docstring、`src/pq/result.mojo:377-392` の `Row.get` 表、`src/pq/__init__.mojo:13-34` の型マッピング表、`examples/binary.mojo`（T8）、`src/pq/__init__.mojo` の再エクスポート | `grep -c 'elif T ==' src/pq/decode_text.mojo` = 16（現 8）、`grep -c 'elif T ==' src/pq/decode_binary.mojo` = 16、`grep -nE 'Decimal|Date|Timestamp|UUID|Interval' src/pq/__init__.mojo` に 8 型全部、`grep -c 'anything else' src/pq/__init__.mojo` = 1（行は残すが「`String`（text 形式）のみ。binary では `TYPE_MISMATCH`」に書き換え） |
| OID 定数を足す（T3〜T5: 10 個） | `src/pq/decode_text.mojo:18-49`（現 11 個。ここが唯一の置き場。`params.mojo:51-59` / `decode_binary.mojo` はここから import） | `grep -c '^comptime OID_' src/pq/decode_text.mojo` = 21、`grep -rn 'UInt32(1700)\|UInt32(1082)\|UInt32(2950)' src/pq --include='*.mojo' \| grep -v decode_text.mojo` = 0 件（定数を他所に重複定義しない） |
| `Param` の `@implicit` ctor を足す（T3〜T5: 8 型 × 2 = 16 本） | `src/pq/params.mojo:4`「Nineteen `@implicit` constructors」→ **Thirty-five**、`src/pq/params.mojo:87-99` struct docstring、`src/pq/connection.mojo:301-313` の `execute(sql, params)` 表、`src/pq/__init__.mojo:36-63` の Parameters 表、`tests/test_params.mojo:496` `test_param_oids_and_formats` 系に新型の OID / `is_binary()` | `grep -c '@implicit' src/pq/params.mojo` = 35、`grep -c Nineteen src/pq/params.mojo` = 0、`grep -c Thirty-five src/pq/params.mojo` = 1 |
| `encode_binary.mojo` に encoder を足す（T3〜T5: 8 本） | `src/pq/encode_binary.mojo:3`「Holds exactly six encoders」→ **fourteen** + 一覧、`tests/test_encode_binary.mojo:119-125` `test_encoded_widths_are_fixed` に固定長の型（date 4 / timestamp 8 / timestamptz 8 / time 8 / timetz 12 / interval 16 / uuid 16） | `grep -c '^def encode_' src/pq/encode_binary.mojo` = 14、`grep -c 'exactly six' src/pq/encode_binary.mojo` = 0 |
| `decode_binary.mojo` に decoder を足す | 名前は `encode_<pgtype>` / `decode_<pgtype>` で対（`encode_binary.mojo:16-18` の約束） | `grep -c '^def decode_' src/pq/decode_binary.mojo` = 14（bool / int16 / int32 / int64 / float32 / float64 / numeric / date / timestamp / timestamptz / time / timetz / interval / uuid。text 系・bytea・jsonb は `decode_binary[T]` 内で直接扱い、関数は作らない） |
| `execute` に `result_format` 引数を足す（T2） | `src/pq/connection.mojo:286-288` / `:326-327`「Results always come back in text form; a binary `result_format` is Phase 3.」、`src/pq/prepared.mojo:127` / `:138-139`（同文）、`src/pq/transaction.mojo:393`（`execute(sql, params)` の passthrough）、`src/pq/__init__.mojo` に `ResultFormat` の節 | `grep -rn 'is Phase 3' src/pq` = 0 件、`grep -c 'result_format' src/pq/connection.mojo src/pq/prepared.mojo src/pq/transaction.mojo` が各 ≥ 2 |
| 公開 struct を足す（`ResultFormat` / `Decimal` / `Date` / `Timestamp` / `TimestampTz` / `Time` / `TimeTz` / `Interval` / `UUID`） | `src/pq/__init__.mojo:102-116` の再エクスポート + モジュール docstring、docstring 診断（3/6 段） | `mojo precompile --diagnose-missing-doc-strings src/pq -o build/pq.mojoc 2>&1 \| grep -v '/_ffi/' \| grep -vE "'(__init__\|__deinit__\|__copyinit__\|__moveinit__)'" \| grep -c 'doc string'` = 0、`from pq import ResultFormat, Decimal, Date, Timestamp, TimestampTz, Time, TimeTz, Interval, UUID` が `examples/binary.mojo` でコンパイルする |
| `examples/` を足す（T8: `binary.mojo` / `bench_formats.mojo`） | `pixi.toml:17-18` の並びに `example-binary` / `bench`、`tests/final_check.sh:117-123` の 4/6 段に `examples/binary.mojo` の実行行（**`bench_formats.mojo` は足さない**: 合否なし。P29） | `grep -rn 'examples/' pixi.toml tests/final_check.sh` に `examples/binary.mojo` が両方、`bench_formats` は pixi.toml にだけ |
| テストファイルを足す（T2〜T7 で 7 本） | 無し（`run_tests.sh:76` は glob）。サーバー不要のファイルも両サーバーで 2 回回る（`run_tests.sh:15-17` の方針） | `pixi run test` のログに新ファイル名が 2 回出る |
| リークループを足す（T8: 2 本） | `tests/test_leak.mojo:33`「Twelve tests」→ **Fourteen** + 箇条書きに Phase 3 の段、`:47-51` の所要見積もり | `grep -c '^def test_' tests/test_leak.mojo` = 14、`grep -c Twelve tests/test_leak.mojo` = 0 |
| `test_connection` にテストを足す（T1: 3 件） | 無し（件数を書いた文書は無い） | `grep -c '^def test_' tests/test_connection.mojo` = 31（現 28） |
| libpq を呼ぶ新しい経路を足す | T1 の `SET` は `Connection.execute(sql)` 経由（`PQexec` 直呼びは増やさない）。zero-copy は `PQgetvalue` / `PQgetlength` の読み出しのみで解放経路は増えない | `grep -rn 'PQexec(' src/pq/*.mojo` = 4 行のまま（connection ×2 / transaction / prepared）、`grep -rn 'PQfreemem(' src/pq/*.mojo` = 2 行のまま |
| 生存期間の docstring 文言（REQ §6-10） | `src/pq/result.mojo:14-17` / `:340-347`、`src/pq/prepared.mojo:8-11`、`src/pq/transaction.mojo:11-13`、`src/pq/connection.mojo:422-424` / `:759-762` の「outlive ... compile error」 | `grep -rn 'compile error' src/pq/*.mojo` の各行が「消費する移動（`var r2 = res^` / 関数へ `res^`）の後の使用」の文脈になっている（`connection.mojo:6` の `var b = a` は別物で残る）。T7 の陽性対照でその文言が事実であることを示す |
| `ref` を返す公開 API を作らない（P19） | `src/pq/*.mojo` | `grep -rn -- '-> ref' src/pq/*.mojo` = 0 件（T7 で 1 回確かめて PROGRESS に書く。`final_check.sh` には足さない） |

## Tasks

- [ ] T1: 持ち越し整理（REQ §6 の 10 件）+ 接続直後の GUC 固定（REQ §4.7）+ `test_connection` 3 件
  - 完了基準:
    - (a) REQ §6-1: `src/pq/prepared.mojo:127-163`（`execute` docstring）に「A prepared statement binds values of the **same width** the server resolved at `PQprepare` time: `$1::int4` wants `Int32`, and passing `Int` (`int8`) is SQLSTATE `22P03`」を 1 文、
      `src/pq/__init__.mojo:36-63`（Parameters 節）に同趣旨を 1 文
    - (b) REQ §6-2: `tests/final_check.sh:144` を `grep -cE 'warning:|WARNING:|implicit ROLLBACK failed'` に（`transaction.mojo:89` の既定ハンドラが `pq: implicit ROLLBACK failed: ` を stderr に出す）。
      見出し行（`:143`）・コメントにこの文字列を書かない（コメントは「the default rollback-failure handler's line」のように言い換える）。陽性対照: `printf 'pq: implicit ROLLBACK failed: x\n' >> build/final_check.log` を手で足した状態で 6/6 段の grep が 1 を返すことを確かめ、ログを消す
    - (c) REQ §6-3: `tests/test_prepared.mojo:543-544` の `find("3")` / `find("1")` を `find("takes 3 parameters, got 1") >= 0` の 1 行に
    - (d) REQ §6-4: `src/pq/connection.mojo:103-113`（`Connection.__init__` docstring）に `_stmt_counter`（per-connection、`prepare` が `pq_stmt_<n>` を採番）と `_rollback_failure_handler`（既定は stderr 1 行。`transaction()` 時にコピーされる）の説明
    - (e) REQ §6-5: `src/pq/prepared.mojo:227-237` の `param_type_oid` を、`len(self._param_types) == 0` なら `parameter index N out of range (statement takes no parameters)`、それ以外は現行のまま。`tests/test_prepared.mojo` に 0 パラメータ文で `"takes no parameters"` を含むことを 1 件
    - (f) REQ §6-6: `src/pq/transaction.mojo:283-309` / `:312-339` / `:342-365`（`savepoint` / `rollback_to` / `release`）の先頭で `_reject_nul(name, "name")`（`escape_identifier` の `_reject_nul(s, "s")`（`connection.mojo:691`）より先）。
      `tests/test_savepoint.mojo` の NUL テストの期待を `"embedded NUL byte in name"` に（現状 `in s` を期待している箇所があれば直す。`grep -n 'in s' tests/test_savepoint.mojo` で確認）
    - (g) REQ §6-7: `src/pq/params.mojo:454-456`（binary 分岐）と `:466-477`（text 分岐）の前に `if len(params[i]._data) > 0x3FFFFFFF: raise PgError(USAGE, "parameter $N is too large (N bytes; libpq takes at most 1073741823)")`。
      テストは不要（1 GiB の確保を避ける）。docstring（`:425-440` Raises）に 1 行
    - (h) REQ §6-8 / D4: `tests/test_leak.mojo:115-134` の `TOLERANCE_PAGES` docstring を「256 を**恒久仕様**とする。+83〜85 ページの一段が 1 回出ることがある（**glibc arena の拡張と推測、未特定**）」に書き換える（現行の「a lazy first-use allocation somewhere under libpq」は推測の主語を glibc arena に改め、未特定である旨を明記）
    - (i) REQ §6-9: `src/pq/transaction.mojo:99-119`（「Use the value on its last line」節）に「Sending `COMMIT` / `ROLLBACK` by hand through `conn.execute` ends the block on the server; the implicit `ROLLBACK` at destruction then draws a server `WARNING: there is no transaction in progress`, and the data stays as the manual command left it」を 1 文
    - (j) REQ §6-10: 追従先チェックリスト「生存期間の docstring 文言」の 6 箇所を「A `Row` is bound to the `Result`'s origin, so using it after the result has been **moved away** (`var r2 = res^`, or passing `res^` to a function) is a compile error (`use of uninitialized value`). `_ = res^` is **not** a destroy: it is a keep-alive marker, and `PQclear` runs after the last use of any `Row` or slice borrowed from the result」の趣旨に（`Transaction` / `PreparedStatement` / `Connection` は主語を替えて同文）。`src/pq/__init__.mojo:65-75` の Transactions 節の `_ = x^` の説明は現行で正しいので触らない
    - (k) REQ §4.7 / D12 / P16 / P17: `src/pq/connection.mojo` に `comptime _SESSION_SETUP_SQL = "SET DateStyle TO 'ISO, YMD'; SET IntervalStyle TO 'postgres'"` を置き、`_adopt`（`:127-156`）の末尾を
      `var connection = Connection(conn, pq); _ = connection.execute(String(_SESSION_SETUP_SQL)); return connection^` にする。失敗時は `execute` が raise し、`connection` の `__deinit__`（`:121-124`）が `PQfinish` する（別途 `PQfinish` を書かない。kind は `_take_result` の分類どおり `SERVER`（22023 等）または `CONNECTION`）。
      `open(String)` / `open(Dict)` の docstring Raises に「`SERVER` when the session setup `SET` is rejected; the connection is closed before raising」を足し、`_adopt` の docstring に 2 文を 1 つの `PQexec` で送る理由（暗黙トランザクションで両方 or 無し。RESEARCH §0-4）と「Phase 4 の非同期接続も同じ SQL を最初のクエリステップとして送る」を書く
    - (l) `tests/test_connection.mojo` に 3 件: `test_open_fixes_datestyle`（`SHOW DateStyle` → `get[String](0) == "ISO, YMD"`）、`test_open_fixes_intervalstyle`（`SHOW IntervalStyle` → `"postgres"`）、`test_client_encoding_is_utf8`（`SHOW client_encoding` → `"UTF8"`。P20）。
      `open(Dict)` 経由でも `SHOW DateStyle` が `ISO, YMD` であることを `test_open_fixes_datestyle` の中で 2 本目の接続として確かめる
    - (m) `pixi run test` 両サーバー PASS（test_connection 31 件、test_prepared / test_savepoint の変更分）、`pixi run check` 6/6 PASS（作業木のまま）。所要を PROGRESS に書く
  - 対象: `src/pq/prepared.mojo`, `src/pq/__init__.mojo`, `src/pq/connection.mojo`, `src/pq/transaction.mojo`, `src/pq/params.mojo`, `src/pq/result.mojo`, `tests/final_check.sh`, `tests/test_prepared.mojo`, `tests/test_savepoint.mojo`, `tests/test_leak.mojo`, `tests/test_connection.mojo`
  - 依存: なし
  - 並列サブ作業（推奨本数: **1**。docstring 編集が散るだけで実行待ちは `test` 1 回）:
    - A: (a)(d)(h)(i)(j) の docstring 編集のみ（対象: `src/pq/prepared.mojo`, `src/pq/__init__.mojo`, `src/pq/connection.mojo` の docstring 部分, `src/pq/transaction.mojo` の docstring 部分, `src/pq/result.mojo`, `tests/test_leak.mojo` の docstring 部分。コードは触らない）
    - 親: (b)(c)(e)(f)(g)(k)(l)(m)

- [ ] T2: `ResultFormat` / `result_format` 引数 / `Result.column_format` + `decode_binary.mojo`（既存 8 型）+ `Row.get` の形式自動切替 + `tests/test_decode_binary.mojo` + `tests/test_binary.mojo`
  - 完了基準:
    - (a) `src/pq/result.mojo`: **決めた事項 1** の `ResultFormat`。`Result.column_format(self, i: Int) raises PgError -> ResultFormat`（範囲検査は `column_type_oid`（`:222-239`）と同形、`PQfformat`（`_ffi/functions.mojo:101-103`）の 0 / 1 を写す）。
      `Row._raw(self, col: Int) -> Span[UInt8, Self.origin]`（private。`PQgetvalue` のアドレスを `Pointer[UInt8, Self.origin](unsafe_from_address=)` に、長さは `PQgetlength`。RESEARCH §3-11 の 3 行。`_check_cell` 済み前提）。
      `Row.get[T]` / `get_optional[T]`（`:368-418` / `:450-479`）は「`_check_cell` → NULL 検査 → **`PQfformat` が 1 なら `decode_binary[T](self._raw(col), oid)`、0 なら従来の `decode_text[T](self._res[]._text(...), oid)`**」の分岐だけにする（REQ §4.2 末尾）。
      `Row.get` docstring の表（`:380-389`）に「binary」列を足し、「`String` は text では任意 OID、binary では文字列系 OID のみ」「`List[UInt8]` は両形式とも bytea のみ」を書く
    - (b) `src/pq/connection.mojo:286-288` を `execute(self, var sql: String, params: List[Param], result_format: ResultFormat = ResultFormat.TEXT)`、`:362` の `c_int(0)` を `c_int(result_format.value)` に。
      `src/pq/prepared.mojo:127` を `execute(self, params: List[Param], result_format: ResultFormat = ResultFormat.TEXT)`、`:188` 同様。`src/pq/transaction.mojo:393` の `execute(sql, params)` に同じ引数を足して `self._conn[].execute(sql^, params, result_format)` に渡す（**決めた事項 2**）。
      3 箇所の「Results always come back in text form; a binary `result_format` is Phase 3.」を「`result_format` selects text (default) or binary results for **every** column; `Row.get` reads `PQfformat` and decodes accordingly, so callers do not change」に。`execute(sql)` 単体は `PQexec` のまま（docstring に「always text; use `execute(sql, [], result_format=ResultFormat.BINARY)` for binary」）。
      `src/pq/__init__.mojo` に `from .result import Result, ResultFormat, Row` と `## Result format` 節（既定 TEXT、全列一括、`column_format(i)`、binary の `String` 制限）
    - (c) `src/pq/decode_binary.mojo`（新設。**決めた事項 3** のシグネチャと分岐、**決めた事項 4** のメッセージ）: `decode_binary[T: Copyable](bytes: Span[UInt8], oid: UInt32) raises PgError -> T` と `decode_bool / decode_int16 / decode_int32 / decode_int64 / decode_float32 / decode_float64`（`encode_binary.mojo` の 6 本の逆。`bitcast[DType.float32, 1](UInt32)` / `bitcast[DType.int16, 1](UInt16)` 等。RESEARCH §0.5）。
      長さ検査は各 decoder の先頭（P21）。`String` は OID 25 / 1043 / 1042 / 19 / 114 / 3802 のみ、3802 は先頭 1 byte が 1 であることを検査して剥がす（P22。長さ 0 の jsonb は `TYPE_MISMATCH`）。`List[UInt8]` は 17 のみ。`Int` は 20 を `Int64` と同じに。
      **binary の `String` は `PQgetlength` の長さで `String(unsafe_from_utf8=span)` にコピーする**（NUL を含み得るので C 文字列扱いしない。REQ §4.2。UTF-8 は検証しない — text 経路 `_text`（`result.mojo:312-337`）と同じ前提。P20 の docstring）
    - (d) `tests/test_decode_binary.mojo`（サーバー不要。雛形は `tests/test_decode_text.mojo:10-82` の `_ok[T]` / `_error_kind[T]` / `_error_message[T]`。`Span[UInt8](list)` で渡す）。期待値は RESEARCH §2.2.1 の hex をそのまま:
      bool `01` / `00` → True / False、`02` → `TYPE_MISMATCH` + `"expected 0 or 1"`（P24）；int2 `8000` / `7fff` → -32768 / 32767；int4 `80000000` / `7fffffff`；int8 `8000000000000000` / `7fffffffffffffff`（`Int64` と `Int` の両方）；
      float4 `7fc00000` → isnan、`7f800000` / `ff800000` → ±inf、`80000000` → -0.0（`1.0 / x` が -inf で判定）、`3fc00000` → 1.5；float8 `7ff8000000000000` → isnan、`8000000000000000` → -0.0、`3fb999999999999a` → 0.1、`7e37e43c8800759c` → 1e300；
      text `68c3a96c6c6f`（oid 25）→ `"héllo"`、長さ 0 → `""`、`68c3a96c6c6f` を oid 1043 / 1042 / 19 / 114 でも `String` に、`01 7b7d`（oid 3802）→ `"{}"`、`02 7b7d`（3802）→ `TYPE_MISMATCH` + `"version byte is 2"`、長さ 0 の 3802 → `TYPE_MISMATCH`；
      `00 68 00`（oid 25）→ `byte_length() == 3`（NUL を含む text）；bytea `00ff00` → `[0, 255, 0]`、長さ 0 → `[]`；
      **長さ不一致**（P21）: bool / int2 / int4 / int8 / float4 / float8 それぞれ「-1 byte」「+1 byte」「0 byte」の 3 ケースが `TYPE_MISMATCH` でメッセージに `"bytes, expected <n>"`（n は 1 / 2 / 4 / 8 / 4 / 8）；
      **OID 不一致**（P23 / D9）: `Int32` を oid 20 で、`String` を oid 23 / 600 / 1007 で、`List[UInt8]` を oid 25 / 600 で要求 → `TYPE_MISMATCH` でメッセージに `"oid <n>"` と `"ResultFormat.TEXT"`。
      `ResultFormat.TEXT.value == 0` / `BINARY.value == 1` / `String(ResultFormat.BINARY) == "Binary"` / `TEXT != BINARY` も 1 件
    - (e) `tests/test_binary.mojo`（サーバー。雛形は `tests/test_result.mojo:56-120` のラッパー群。両サーバー同一期待値）:
      ① `execute(sql, [], result_format=ResultFormat.BINARY)` で RESEARCH A1〜A8 の 8 型を取り、同じ SQL の text 結果と `get[T]` が**値一致**（float は `isnan` / 同符号 inf / `-0.0`、bpchar は両方 `"ab   "`、`1e300` の text は `"1e+300"` だが `Float64` 比較で一致）；
      ② `column_format(i)` が binary 結果で全列 `BINARY`、`execute(sql)` の結果で `TEXT`、`execute(sql, [])`（既定）で `TEXT`、`column_format(ncols)` が `TYPE_MISMATCH`；
      ③ `PreparedStatement.execute([...], result_format=ResultFormat.BINARY)` と `Transaction.execute(sql, [], result_format=BINARY)` でも `column_format(0) == BINARY` で値が読める；
      ④ **未対応 OID の格子**（P23 / RESEARCH X1）: `SELECT ARRAY[1,2]::int4[], point(1,2), 1::oid, 'a'::"char", int4range(1,5), 1.5::money, '08:00:2b:01:02:03'::macaddr` を binary で取り、7 列 × {`String`, `List[UInt8]`, `Int32`} の 21 セルが全部 `TYPE_MISMATCH` でメッセージに `"oid "` と `"ResultFormat.TEXT"`。同じ SQL を text で取ると `get[String]` が 7 列とも通る（Phase 1 規則）；
      ⑤ 0 行の binary 結果（`SELECT 1 WHERE false`）で `row_count() == 0`、binary 付き DDL / INSERT（`CREATE TEMP TABLE` / `INSERT`）が `command_tag()` `CREATE TABLE` / `INSERT 0 1`（RESEARCH X2〜X4）；
      ⑥ NULL 列を binary で `get[Int32]` → `NULL_VALUE`、`get_optional[Int32]` → None、`is_null` → True；
      ⑦ 切断後の binary 実行: `SELECT pg_terminate_backend(pg_backend_pid())` の後の `execute("SELECT 1", [], result_format=BINARY)` が `CONNECTION`（または最初の 1 回だけ `SERVER`。`tests/test_connection.mojo:660` `test_terminated_backend_then_connection_error` と同じ形）で、トレースバックを出さない（REQ §5.2「未接続・切断後」。binary も `_take_result` を通ることの確認）。
      NUL を含む text の binary 読み出しはサーバーが作れない（`chr(0)` は 54000）ので (d) の単体テストだけで担保する
    - (f) `tests/test_result.mojo` / `tests/test_params.mojo` / `tests/test_prepared.mojo` / `tests/test_transaction.mojo` が無変更で PASS（既定 TEXT の後方互換）。`pixi run test` 両サーバー PASS、`pixi run check` 6/6
  - 対象: `src/pq/result.mojo`, `src/pq/connection.mojo`, `src/pq/prepared.mojo`, `src/pq/transaction.mojo`, `src/pq/__init__.mojo`, `src/pq/decode_binary.mojo`, `tests/test_decode_binary.mojo`, `tests/test_binary.mojo`
  - 依存: T1
  - 並列サブ作業（推奨本数: **3**。契約は決めた事項 1〜4）:
    - A: `decode_binary.mojo` + `tests/test_decode_binary.mojo`（対象: その 2 ファイルのみ）
    - B: `ResultFormat` / `column_format` / `Row._raw` / `Row.get` 分岐 / 3 つの `execute` の引数 / `__init__.mojo`（対象: `src/pq/result.mojo`, `src/pq/connection.mojo`, `src/pq/prepared.mojo`, `src/pq/transaction.mojo`, `src/pq/__init__.mojo`）
    - C: `tests/test_binary.mojo`（対象: その 1 ファイル。A / B の API は契約どおりに書き、親が統合後にコンパイルを通す）
    - 親: 統合・`fmt` 1 回・(f)

- [ ] T3: `Decimal`（`types_numeric.mojo`）+ `UUID`（`types_uuid.mojo`）+ json / jsonb の `String` 扱い + 両型の codec / `Param` ctor + 単体テスト
  - 完了基準:
    - (a) `src/pq/types_numeric.mojo`: **決めた事項 5** の `Decimal`。`Decimal(text: String) raises PgError`（`USAGE`）/ `Decimal.parse(text) raises PgError -> Self`（`TYPE_MISMATCH`）/ `Decimal.nan()` / `infinity()` / `negative_infinity()` / `dscale() -> Int` / `is_nan()` / `is_infinite()` / `is_finite()` / `__eq__` / `__ne__` / `write_to` / `_from_parts(sign, weight, dscale, var digits)`（normalize）。
      文字列化は RESEARCH §3-1（`get_str_from_var`）、解釈は §3-2（`set_var_from_str`）。D14: `1e5` / `0x10` / 空 / `.` / `-` / `+` / 空白付きは拒否（P26）。dscale > 16383 は拒否（P6）。weight が Int16 に収まらない桁数は拒否
    - (b) `tests/test_types_numeric.mojo`（サーバー不要）: RESEARCH §4 の P2〜P6 / P26 の検証欄をそのまま:
      `String(Decimal("1.50")) == "1.50"`（`dscale() == 2`）、`"-0.001"`、`"0"`、`"0.00"`、`"0.000001"`、`"12345678.9"`、`"1000000"`、`"123456789012345678901234567890.123456789"`、`"12.3400"`、`"0.0001"`、`"0.5"`、`"-0.5"` が往復一致；`Decimal("+1")` → `"1"`；`Decimal("1.")` → `"1"`；`Decimal(".5")` → `"0.5"`；
      `"1" + "0" × 130` が往復一致（長さ 131。P4）；`Decimal("1.0") == Decimal("1.00")`、`"0" == "0.00"`、`"NaN" == "NaN"`、`"1" != "-1"`、`"Infinity" == "Infinity"`、`"Infinity" != "-Infinity"`、`"NaN" != "Infinity"`（P5）；
      `String(Decimal.nan()) == "NaN"`、`infinity()` → `"Infinity"`、`negative_infinity()` → `"-Infinity"`、`is_infinite()` / `is_nan()` / `is_finite()` の真偽表；
      拒否（P26）: `"1e5"`, `"0x10"`, `""`, `"."`, `"-"`, `" 1"`, `"1 "`, `"1.2.3"`, `"inf"`, `"nan"`, `"1_000"` が ctor で `USAGE`（メッセージに `invalid numeric literal`）、`Decimal.parse` で `TYPE_MISMATCH`（`cannot decode`）；16,384 桁の小数（`"0." + "1" × 16384`）が `USAGE`
    - (c) `src/pq/types_uuid.mojo`: **決めた事項 6** の `UUID`。`UUID(bytes: Array[UInt8, 16])` / `UUID(text: String) raises PgError`（`USAGE`）/ `UUID.parse(text)`（`TYPE_MISMATCH`）/ `write_to`（小文字 `8-4-4-4-12`）/ `__eq__` / `__ne__`。入力は大文字小文字どちらも、`{}` 囲みと ハイフン無しは**拒否**（PG の `uuid_in` より狭い。D14 の流儀）
    - (d) `tests/test_types_uuid.mojo`: `"a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"` 往復、`"A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11"` → 小文字出力で前者と `==`、全ゼロ / 全 `f` の往復、拒否: 35 文字 / 37 文字 / `g` を含む / ハイフン位置違い / `{...}` が ctor `USAGE`（`invalid uuid literal`）・`parse` `TYPE_MISMATCH`
    - (e) codec と結線（親）: `decode_text.mojo` に `OID_NUMERIC = 1700` / `OID_UUID = 2950` / `OID_JSON = 114` / `OID_JSONB = 3802` と `elif T == Decimal: ... Decimal.parse(text)` / `elif T == UUID`（OID 不一致は `_oid_error`）；
      `decode_binary.mojo` に `decode_numeric(bytes) raises -> Decimal`（長さ ≥ 8、`8 + 2*ndigits == len`、sign 5 値、dscale ≤ 0x3FFF、digit 0..9999。special は sign だけ見て dscale 0。P1 / P21）と `decode_uuid`（16 byte）と `T == Decimal` / `T == UUID` 分岐；
      `encode_binary.mojo` に `encode_numeric(d: Decimal)`（special は `0000 0000 <sign> 0000`）/ `encode_uuid(u: UUID)`；`params.mojo` に `Decimal` / `Optional[Decimal]` / `UUID` / `Optional[UUID]` の `@implicit`（OID 1700 / 2950、binary）；`__init__.mojo` に再エクスポート
    - (f) codec の単体テスト: `tests/test_decode_binary.mojo` に RESEARCH §2.2.2 の表 **全 20 行**の hex → `String(Decimal)` 一致（`0000 0000 d000 0020` → `"Infinity"` かつ `dscale() == 0`、`0000 0000 0000 0002` → `"0.00"`、`0001 ffff 0000 0005 0001` → `"0.00010"`、`0001 fffe 0000 0005 03e8` → `"0.00001"`（P2）、`0003 0001 0000 0001 04d2 162e 2328` → `"12345678.9"`（P3）、`0001 0020 0000 0000 0064` → 131 文字（P4）、weight `0x8000` の `0001 8000 0000 0000 0001` が raise せず文字列化できる）、
      不正: 長さ 7 / `0002 0000 0000 0002 0001`（ndigits 2 で 10 byte）/ sign `1234` / digit `2710`（10000）/ dscale `4000`（16384）が `TYPE_MISMATCH`（メッセージ `"cannot decode binary numeric"`）；uuid 15 / 17 byte が `TYPE_MISMATCH`；
      `tests/test_encode_binary.mojo` に `encode_numeric(Decimal("1.50")) == 0002 0000 0000 0002 0001 1388`、`"-0.001"`、`"0.00"`、`nan()` → `0000 0000 c000 0000`、`infinity()` → `0000 0000 d000 0000`、`encode_uuid` 16 byte；表 20 行の **encode → decode 往復**が `==`；
      `tests/test_params.mojo` に `Param(Decimal("1"))`.oid() == 1700 / `is_binary()`、`Param(UUID(...))`.oid() == 2950、`Optional[Decimal](None)` → `is_null()` かつ oid 1700
    - (g) `pixi run test` 両サーバー PASS、`pixi run check` 6/6。追従先チェックリストの OID / `@implicit` / encoder 件数の中間値（OID 15、`@implicit` 23、`encode_` 8）を PROGRESS に書く
  - 対象: `src/pq/types_numeric.mojo`, `src/pq/types_uuid.mojo`, `src/pq/decode_text.mojo`, `src/pq/decode_binary.mojo`, `src/pq/encode_binary.mojo`, `src/pq/params.mojo`, `src/pq/__init__.mojo`, `tests/test_types_numeric.mojo`, `tests/test_types_uuid.mojo`, `tests/test_decode_binary.mojo`, `tests/test_encode_binary.mojo`, `tests/test_params.mojo`
  - 依存: T2
  - 並列サブ作業（推奨本数: **2**。契約は決めた事項 5・6）:
    - A: `types_numeric.mojo` + `tests/test_types_numeric.mojo`
    - B: `types_uuid.mojo` + `tests/test_types_uuid.mojo`
    - 親: (e)(f)(g)。codec モジュールと `params.mojo` は親だけが触る

- [ ] T4: `Date` / `Timestamp` / `TimestampTz`（`types_datetime.mojo` 前半 + 暦算法）+ codec / `Param` + 単体テスト
  - 完了基準:
    - (a) `src/pq/types_datetime.mojo`（新設。T5 が同じファイルに追記する）: private ヘルパ `_days_from_civil(y, m, d) -> Int` / `_civil_from_days(days) -> (Int, Int, Int)`（RESEARCH §2.2.3 のコードそのまま。`//` は床除算、`(y-399)/400` は書かない）/ `_is_leap(y)` / `_days_in_month(y, m)` /
      `_format_date(y, m, d, mut writer)`（4 桁ゼロ埋め・4 桁超はそのまま・`y <= 0` は `1 - y` + ` BC` を**呼び出し側が付ける**）/ `_format_time_of_day(micros_in_day, mut writer)`（`HH:MM:SS[.f]`、末尾ゼロ削り）/ `_parse_fraction(digits) -> Int`（1〜6 桁、7 桁以上は拒否。P14）/ `_parse_hms(text, start) -> micros`（桁位置で読む。P25）。
      **決めた事項 7** の `Date` / `Timestamp` / `TimestampTz`
    - (b) `tests/test_types_datetime.mojo`（サーバー不要。T5 が追記）: RESEARCH §2.2.3 の実測値をそのまま:
      `Date.from_ymd(2000,1,1).days == 0`、`(1970,1,1)` → -10957、`(2024,2,29)` → 8825、`(1999,12,31)` → -1、`(1,1,1)` → -730119、`(0,1,1)` → -730485（1 BC）、`(-4713,11,24)` → -2451545、`(10000,1,1)` → 2921940、`(5874897,12,31)` → 2145031948；各 `year()/month()/day()` が戻る（9 件）；
      `String(Date(...))`: `"2000-01-01"`、`"0001-01-01 BC"`（-730485）、`"4714-11-24 BC"`、`"10000-01-01"`、`"5874897-12-31"`、`"0001-01-01"`、`Date.infinity()` → `"infinity"`、`negative_infinity()` → `"-infinity"`（P12）；`Date.parse` が上記すべての逆；
      `Date.from_ymd` 拒否（P27）: `(2024,2,30)`, `(2023,2,29)`, `(2024,13,1)`, `(2024,0,1)`, `(2024,1,0)`, `(5874898,1,1)`, `(-4714,1,1)` が `USAGE`（`"invalid date"`）；`(2024,2,29)` と `(0,1,1)` は通る；`Date.infinity().year()` が `USAGE`（`"is infinite"`）；
      `Timestamp`: `from_ymd_hms(2000,1,1,0,0,0).micros == 0`、`(2024,1,2,3,4,5,678901)` → `0x0002b0ec85204f35`、`(1969,12,31,23,59,59,999999)` → -946684800000001、`(0,1,1,0,0,0)` → `-0xE039C2E44EE000`（= `0xff1fc63d1bb12000`）、`(-4712,1,1,0,0,0)` → `-0x2F0804250E82000`、`(294276,12,31,23,59,59,999999)` → `0x7fffff5bb3b29fff`、`(10000,1,1,0,0,0)` → `0x0380e70b913b8000`；分解アクセサ 7 つが元に戻る；
      `String(Timestamp)`: `"2000-01-01 00:00:00"`、`"2024-01-02 03:04:05.678901"`、`"1969-12-31 23:59:59.999999"`、`"0001-01-01 00:00:00 BC"`、`"294276-12-31 23:59:59.999999"`、`Timestamp(5500000)` → `"2000-01-01 00:00:05.5"`、`Timestamp(1)` → `"2000-01-01 00:00:00.000001"`、`infinity()` → `"infinity"`；`parse` が逆（`.5` → 500000、`.000001` → 1、`.123456` → 123456。P14）；
      `from_ymd_hms` 拒否: `(2024,1,1,24,0,0)`, `(2024,1,1,0,60,0)`, `(2024,1,1,0,0,60)`, `(2024,1,1,0,0,0,1000000)`, `(294277,1,1,0,0,0)` が `USAGE`；
      `TimestampTz`（P13）: `parse("2024-01-02 03:04:05.678901+00").micros == 0x0002b0ec85204f35`、`"2024-01-02 12:04:05.678901+09"` / `"2024-01-02 08:34:05.678901+05:30"` / `"2024-01-01 23:34:05.678901-03:30"` / `"2024-01-02 08:57:33.678901+05:53:28"` が全部同じ micros、`"0001-01-01 00:00:00+00 BC"` → `-0xE039C2E44EE000`、`"2024-01-02 06:04:35+00"` と `"2024-01-02 03:04:05-03:00:30"` が同値；`String(TimestampTz(0x0002b0ec85204f35)) == "2024-01-02 03:04:05.678901+00"`、BC は `"0001-01-01 00:00:00+00 BC"`、`infinity()` → `"infinity"`；`from_utc(2024,1,2,3,4,5,678901)` が同値；
      **非 ISO / 不正の拒否**（P25 / P15）: `Date.parse` に `" 2024-01-02"`, `"+2024-01-02"`, `"2024-1-2"`, `"01/02/2024"`, `"02.01.2024"`, `"2024-01-02 "`, `"2024-01-02T00:00:00"`, `""`, `"Infinity"`（大文字）が `TYPE_MISMATCH`（`cannot decode`）；`Timestamp.parse("2024-01-02 03:04:05.1234567")`（7 桁）/ `"2024-01-02"`（時刻無し）/ `"2024-01-02 25:00:00"` が `TYPE_MISMATCH`；`TimestampTz.parse("2024-01-02 03:04:05")`（オフセット無し）/ `"... +16"`（|offset| ≥ 57600 は `TYPE_MISMATCH`）
    - (c) codec と結線（親）: `decode_text.mojo` に `OID_DATE = 1082` / `OID_TIMESTAMP = 1114` / `OID_TIMESTAMPTZ = 1184` と 3 分岐；`decode_binary.mojo` に `decode_date`（4 byte → `Date(Int32)`）/ `decode_timestamp` / `decode_timestamptz`（8 byte → `Int64`。番兵はそのまま。範囲検査なし。P21 の長さ検査のみ）と 3 分岐；`encode_binary.mojo` に `encode_date` / `encode_timestamp` / `encode_timestamptz`（`encode_int32` / `encode_int64` の皮）；`params.mojo` に 3 型 × 2 の `@implicit`（OID 1082 / 1114 / 1184）；`__init__.mojo` に再エクスポート
    - (d) codec の単体テスト: `tests/test_decode_binary.mojo` に RESEARCH D1〜D3 / T1〜T2 の hex（`ffffd533` → -10957、`00002279` → 8825、`fff4da8b` → -730485、`ffda97a7` → -2451545、`7fda970c` → 2145031948、`002c95d4` → 2921940、`7fffffff` → `is_infinite()`、`0002b0ec85204f35` → `"2024-01-02 03:04:05.678901"`、`fffca2fec4c81fff` → `"1969-12-31 23:59:59.999999"`、`ff1fc63d1bb12000` → `"0001-01-01 00:00:00 BC"`、`fd0f7fbdaf17e000` → `"4713-01-01 00:00:00 BC"`、`7fffff5bb3b29fff` → `"294276-12-31 23:59:59.999999"`、`8000000000000000` → `"-infinity"`）と長さ 3 / 5 / 7 / 9 の `TYPE_MISMATCH`；
      `tests/test_encode_binary.mojo` に `encode_date(Date(8825)) == 00002279`、`encode_timestamp(Timestamp(0x0002b0ec85204f35))`、infinity の 8 byte、encode → decode 往復；`tests/test_params.mojo` に 3 型の oid / `is_binary()` / `Optional` NULL
    - (e) `pixi run test` 両サーバー PASS、`pixi run check` 6/6
  - 対象: `src/pq/types_datetime.mojo`, `src/pq/decode_text.mojo`, `src/pq/decode_binary.mojo`, `src/pq/encode_binary.mojo`, `src/pq/params.mojo`, `src/pq/__init__.mojo`, `tests/test_types_datetime.mojo`, `tests/test_decode_binary.mojo`, `tests/test_encode_binary.mojo`, `tests/test_params.mojo`
  - 依存: T3
  - 並列サブ作業（推奨本数: **2**。契約は決めた事項 7）:
    - A: `types_datetime.mojo` の `Date` / `Timestamp` / `TimestampTz` + ヘルパ（対象: `src/pq/types_datetime.mojo`）
    - B: `tests/test_types_datetime.mojo`（対象: その 1 ファイル。A と同時に契約から書く）
    - 親: (c)(d)(e)

- [ ] T5: `Time` / `TimeTz` / `Interval`（`types_datetime.mojo` 後半）+ codec / `Param` + 単体テスト
  - 完了基準:
    - (a) `src/pq/types_datetime.mojo` に **決めた事項 8** の `Time` / `TimeTz` / `Interval` を追記（T4 の `_format_time_of_day` / `_parse_hms` / `_parse_fraction` を共用）。interval の文字列化は RESEARCH §3-5（`interval2itm` + `AddPostgresIntPart`、`is_before` 1 フラグ）、解釈はその逆 + `infinity` / `-infinity`。timetz のオフセットは §3-6（西が正、秒を保つ、`±HH[:MM[:SS]]` の 3 幅）
    - (b) `tests/test_types_datetime.mojo` に追記:
      `Time`: `Time(0)` → `"00:00:00"`、`Time(86400000000)` → `"24:00:00"`（P11）、`Time(86399999999)` → `"23:59:59.999999"`、`Time(0x0000000a8be1bd20)` → `"12:34:56.5"`；`Time.from_hms(12,34,56,500000).micros == 45296500000`、`from_hms(24,0,0)` が通る、`from_hms(24,0,1)` / `(23,60,0)` / `(0,0,60)` / `(0,0,0,1000000)` / `(-1,0,0)` が `USAGE`；`parse` が上記の逆、`"24:00:01"` / `"1:00:00"` / `"12:34"` / `"12:34:56.1234567"` が `TYPE_MISMATCH`；
      `TimeTz`（P10）: `parse("12:34:56+09") == TimeTz(45296000000, -32400)`、`"12:00:00+05:53:28"` → `(43200000000, -21208)`、`"12:00:00-03:30"` → `(43200000000, 12600)`、`"00:00:00+00:00:01"` → `(0, -1)`、`"12:00:00-15:59"` → `(.., 57540)`、`"12:00:00+15:59:59"` → `(.., -57599)`、`"24:00:00+09"` が通る；`String` が逆（`"+09"` / `"+05:53:28"` / `"-03:30"` / `"+00:00:01"` / `"-15:59"` / `"+15:59:59"`、`TimeTz(0, 0)` → `"00:00:00+00"`）；`from_hms(12,0,0,0,57600)` / `(.., -57600)` が `USAGE`、`parse("12:00:00+16")` が `TYPE_MISMATCH`；
      `Interval`（P7 / P8）: `String(Interval(7200000000,-1,0)) == "-1 days +02:00:00"`、`(-1000000,0,0)` → `"-00:00:01"`、`(0,-1,0)` → `"-1 days"`、`(0,1,0)` → `"1 day"`、`(14706789000,3,14)` → `"1 year 2 mons 3 days 04:05:06.789"`、`(0,0,-11)` → `"-11 mons"`、`(0,0,25)` → `"2 years 1 mon"`、`(0,0,0)` → `"00:00:00"`、`(360000000000,0,0)` → `"100:00:00"`、`(-500000,0,0)` → `"-00:00:00.5"`、`(0,1,-12)` → `"-1 years +1 day"`、`(1000000,-1,0)` → `"-1 days +00:00:01"`、`(0,0,1)` → `"1 mon"`、`(0,0,12)` → `"1 year"`、`(43200000000,1,0)` → `"1 day 12:00:00"`、`(0,-1,1)` → `"1 mon -1 days"`、`(-14706789000,-3,-14)` → `"-1 years -2 mons -3 days -04:05:06.789"`、`(9223372036854775807,0,0)` → `"2562047788:00:54.775807"`；`Interval.infinity()` → `"infinity"`、`negative_infinity()` → `"-infinity"`、`is_infinite()` は 3 フィールド全 MAX / 全 MIN のときだけ（`Interval(Int64.MAX, 0, 0)` は有限）；`parse` が上記 18 件すべての逆（`==` で比較）；
      `Interval.parse` 拒否: `""`, `"1 week"`, `"1 day 1 day"`, `"P1D"`, `"1 days 02:00"`, `"+1 day"`（先頭 `+` は前が負のときだけ有効なので単独は拒否）、`"1 year "`（末尾空白）が `TYPE_MISMATCH`
    - (c) codec と結線（親）: `decode_text.mojo` に `OID_TIME = 1083` / `OID_TIMETZ = 1266` / `OID_INTERVAL = 1186` と 3 分岐；`decode_binary.mojo` に `decode_time`（8 byte、0..86400000000 の範囲外は `TYPE_MISMATCH` `"is out of range"`。P11）/ `decode_timetz`（12 byte、`|zone| < 57600` 以外は `TYPE_MISMATCH`）/ `decode_interval`（16 byte、**micros, days, months の順**。P7。範囲検査なし）と 3 分岐；
      `encode_binary.mojo` に `encode_time` / `encode_timetz`（8 + 4）/ `encode_interval`（8 + 4 + 4）；`params.mojo` に 3 型 × 2；`__init__.mojo` に再エクスポート。この時点で追従先チェックリストの最終件数（OID 21、`@implicit` 35、`encode_` 14、`decode_` 14、`elif T ==` 16 × 2）を全部確かめ PROGRESS に書く
    - (d) codec の単体テスト: `tests/test_decode_binary.mojo` に RESEARCH の hex（time `0000000a8be1bd20` → `"12:34:56.5"`、`0000001406f40000`（86400000000）→ `"24:00:00"`、86400000001 の 8 byte → `TYPE_MISMATCH`；timetz `.. ffff8170` → `(.., -32400)`、`.. 00003138` → 12600、`.. ffffad28` → -21208、`.. 0000e0c4` → 57540、`.. ffff1f01` → -57599、`.. ffffffff` → -1、zone 57600 → `TYPE_MISMATCH`；interval `000000036c97ca88 00000003 0000000e` → `(14706789000, 3, 14)`、`00000001ad274800 ffffffff 00000000` → `(7200000000, -1, 0)`、`7fffffffffffffff 7fffffff 7fffffff` → `is_infinite()`、長さ 15 / 17 → `TYPE_MISMATCH`）；
      `tests/test_encode_binary.mojo` に `encode_interval(Interval(0,1,0)) == 00..00 00000001 00000000`、`Interval(0,0,1)` → `.. 00000000 00000001`（P7）、`encode_timetz(TimeTz(45296000000, -32400))` 末尾 `ffff8170`、幅 8 / 12 / 16、往復；`tests/test_params.mojo` に 3 型の oid / `is_binary()` / `Optional`
    - (e) `pixi run test` 両サーバー PASS、`pixi run check` 6/6
  - 対象: `src/pq/types_datetime.mojo`, `src/pq/decode_text.mojo`, `src/pq/decode_binary.mojo`, `src/pq/encode_binary.mojo`, `src/pq/params.mojo`, `src/pq/__init__.mojo`, `tests/test_types_datetime.mojo`, `tests/test_decode_binary.mojo`, `tests/test_encode_binary.mojo`, `tests/test_params.mojo`
  - 依存: T4
  - 並列サブ作業（推奨本数: **2**。契約は決めた事項 8）:
    - A: `types_datetime.mojo` への `Time` / `TimeTz` / `Interval` 追記（対象: `src/pq/types_datetime.mojo`）
    - B: `tests/test_types_datetime.mojo` への追記（対象: その 1 ファイル）
    - 親: (c)(d)(e)

- [ ] T6: サーバー格子 — 拡張型 8 種 + json / jsonb の text / binary 一致・パラメータ往復・PG17 分岐・非 ISO DateStyle（`tests/test_extended_numeric.mojo` / `tests/test_extended_datetime.mojo`）
  - 完了基準:
    - (a) `tests/test_extended_numeric.mojo`（numeric / uuid / json / jsonb。両サーバー同一）:
      ① RESEARCH N1〜N8 の **全値**（`1.50`, `-0.001`, `0`, `0.000001`, `1e130`（SQL は `1e130::numeric`）, `1e-10`, `0.00`, `1000000`, `12345678.9`, `NaN`, `Infinity`, `-Infinity`, `'-0'`, `123456789012345678901234567890.123456789`, `10000`, `9999`, `0.0001`, `1.5::numeric(10,4)`, `100::numeric(10,0)`, `0.5`, `-0.5`, `12.3400`, `+1`）を text / binary で `get[Decimal]` し `==` かつ `String()` 一致、text の `get[String]` とも `String(Decimal)` が一致（**Inf は値比較**。P1）；
      ② `SELECT $1::numeric` に `[Decimal(...)]` を送り text / binary の両結果形式で同じ値（上記全値 + `nan()` / `infinity()` / `negative_infinity()`）。`Infinity` の binary echo が `dscale 32` で来ても `==` が真（P1）；
      ③ `SELECT 1.0::numeric = 1.00::numeric, 'NaN'::numeric = 'NaN'::numeric, 'Infinity'::numeric = 'Infinity'::numeric` の 3 真偽が `Decimal` の `==` と一致（P5）；
      ④ uuid: `'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'`、`'00000000-0000-0000-0000-000000000000'`、`'ffffffff-ffff-ffff-ffff-ffffffffffff'`、`upper(...)` の 4 値を text / binary で `get[UUID]` 一致、`$1::uuid` 往復；
      ⑤ json / jsonb（P22）: `'{"a":1}'::json` は text / binary とも `get[String]` が `{"a":1}`；`'{"b":2,"a":1,"a":3}'::jsonb` は両形式とも `{"a": 3, "b": 2}`（正規化。両形式で同じ）、`'null'::jsonb` → `null`、`'[]'::jsonb` → `[]`、`'"é"'::jsonb` → `"é"`、ネスト `'{"a":{"b":[1,{"c":null}]}}'::jsonb` が両形式一致；`$1::json` / `$1::jsonb` に `String` を送って返る（REQ §4.4）；
      ⑥ 異常系: `'1.5'::numeric` を binary で `get[Int32]` → `TYPE_MISMATCH` + `"oid 1700"`、`'{"a":1}'::jsonb` を binary で `get[List[UInt8]]` → `TYPE_MISMATCH` + `"oid 3802"`、`gen_random_uuid()` を text で `get[UUID]` → 成功かつ binary と `==`。
      不正なバイナリをサーバーに**送る**側のテストは作らない: `Decimal` / `UUID` は構築時の検査（P6）で RESEARCH §2.2.5 の `22P03` / `08P01` を出し得ない（docstring にその旨）
    - (b) `tests/test_extended_datetime.mojo`（6 型）:
      ① date D1〜D3、timestamp T1〜T2（RESEARCH §2.2.3 の SQL と値）、timestamptz Z 系（`'2024-01-02 03:04:05.678901+00'::timestamptz` と `'2024-01-02 12:04:05.678901+09'::timestamptz` が両形式とも同じ micros）、time（`'00:00:00'`, `'24:00:00'`, `'23:59:59.999999'`, `'12:34:56.5'`）、timetz（`'12:34:56+09'`, `'12:00:00+05:53:28'`, `'12:00:00-03:30'`, `'00:00:00+00:00:01'`, `'24:00:00+09'`）、interval（P8 の 11 値 + `'1 day'`, `'1 mon'`, `'1 year'`, `'-1 day 2 hours'`, `'36 hours'`, `'1.5 days'`）を text / binary で `get[T]` し `==`、`String(T)` が text の `get[String]` と一致（timestamptz は `+00` 付きの text と一致: コンテナの TimeZone は `Etc/UTC`。TimeZone が UTC でない環境では `String()` 比較だけ skip して値一致は見る — `SHOW TimeZone` を先に読む）；
      ② `infinity` / `-infinity` の date / timestamp / timestamptz が両形式で `is_infinite()`、`String()` が `infinity` / `-infinity`；
      ③ パラメータ往復: `Date(8825)` → `'2024-02-29'`、`Timestamp(762525296789000)` → `'2024-02-29 12:34:56.789'`、`TimestampTz(同値)` → `'... +00'`（UTC 設定下）、`Time(45296789000)` → `'12:34:56.789'`、`TimeTz(45296000000, -32400)` → `'12:34:56+09'`、`Interval(10800000000, 2, 1)` → `'1 mon 2 days 03:00:00'`（RESEARCH §2.2.4）を `SELECT $1::<type>` で text / binary の両結果形式、`Date.infinity()` / `Timestamp.negative_infinity()` の往復；
      ④ **PG17 分岐**（P9）: `conn.server_version() >= 170000` のとき `'infinity'::interval` / `'-infinity'::interval` を両形式で取り `is_infinite()`、`[Interval.infinity()]` を `$1::interval` で送ると `'infinity'` が返る。**PG14 では** `[Interval.negative_infinity()]` を送ると `PgError(kind=SERVER, sqlstate='22008')`、`'infinity'::interval` の SQL は `22007`；
      ⑤ **非 ISO**（P15）: `conn.execute("SET DateStyle TO 'German'")` 後に `SELECT '2024-01-02'::date` を text で `get[Date]` → `TYPE_MISMATCH`（メッセージに `02.01.2024`）、同じ列を binary で `get[Date]` → 8767 で成功（binary は GUC 非依存）、`SET DateStyle TO 'ISO, YMD'` で戻す。`SET IntervalStyle TO 'iso_8601'` 後の `'1 day'::interval` text も `TYPE_MISMATCH`（`P1D`）；
      ⑥ 境界: `'4714-11-24 BC'::date`、`'5874897-12-31'::date`、`'294276-12-31 23:59:59.999999'::timestamp`、`'4714-11-24 00:00:00 BC'::timestamp` が両形式一致（RESEARCH §2.2.3 の値）
    - (c) 期待メッセージは 2 語以上の部分文字列（REQ §9）。全テストが PG17 / PG14 で PASS（`pixi run test`）、`pixi run check` 6/6。両ファイルの所要（s）を PROGRESS に
  - 対象: `tests/test_extended_numeric.mojo`, `tests/test_extended_datetime.mojo`
  - 依存: T5
  - 並列サブ作業（推奨本数: **2**。対象ファイルが分かれる）:
    - A: `tests/test_extended_numeric.mojo`
    - B: `tests/test_extended_datetime.mojo`
    - 親: 両サーバーで実行・`fmt`・コミット

- [ ] T7: zero-copy `Row.get_text` / `get_bytes`（REQ §4.5）+ `tests/test_zero_copy.mojo` + コンパイルエラーの陽性対照
  - 完了基準:
    - (a) `src/pq/result.mojo` に **決めた事項 9** の `Row.get_text(self, col: Int) raises PgError -> StringSlice[Self.origin]` / `Row.get_bytes(self, col: Int) raises PgError -> Span[UInt8, Self.origin]`（T2 の `_raw` を使う。NULL は `NULL_VALUE`、範囲外は `TYPE_MISMATCH`。`get_text` は text 形式なら任意 OID、binary 形式なら文字列系 6 OID のみで jsonb は version byte を 1 つ飛ばす、それ以外は決めた事項 4 の OID 不一致メッセージ）。
      docstring に (1) `Result` の `PQgetvalue` 領域を指し `PQclear` まで有効、(2) **消費する移動（`var r2 = res^` / 関数へ `res^`）の後の使用はコンパイルエラー `use of uninitialized value`、`_ = res^` は生存延長で安全**（P18）、(3) UTF-8 は検証しない（client_encoding UTF8 前提。P20）、(4) `ref` は返さない（P19）
    - (b) `tests/test_zero_copy.mojo`（サーバー）: `get_text(i)` の `String()` が `get[String](i)` と一致（text 形式: int4 / text / bpchar / numeric の 4 列。binary 形式: text / varchar / bpchar / name / json / jsonb の 6 列）、`get_bytes(i)` が binary bytea の `get[List[UInt8]]` と一致（`'\x00ff00'::bytea` と `''::bytea`）、text 形式 bytea の `get_bytes` は `\x00ff00` の 8 byte（生の text バイト）、`byte_length()` が `PQgetlength` と同じ（`'héllo'` → 6、NUL を含むなら長さどおり）、NULL → `NULL_VALUE`、binary の int4 列 `get_text` → `TYPE_MISMATCH` + `"ResultFormat.TEXT"`、範囲外 → `TYPE_MISMATCH`；
      `var s = res[0].get_text(0); _ = res^; assert s == ...` が**コンパイルも実行も通る**こと（生存延長の正例）を 1 件（docstring の主張の裏付け）
    - (c) **陽性対照**（REQ §4.5 / §5.1 / P18。同じターンで実測し PROGRESS にエラーメッセージを貼る）: `.gsd-lite/logs/phase3-binary-all-types/scratch/turn-NNN-zerocopy-neg.mojo` に実物の `pq.Result` で `var s = res[0].get_text(0); var r2 = res^; print(s)` を書き、`pixi run mojo run -I src <file>` が `error: use of uninitialized value 'res'` で止まることを確認。`get_bytes` 版と、既存 `Row`（`var row = res[0]; var r2 = res^; row.get[Int32](0)`）版の計 3 本。
      あわせて `grep -rn -- '-> ref' src/pq/*.mojo` = 0 件を PROGRESS に（P19）
    - (d) `src/pq/__init__.mojo` に `## Zero-copy access` 節（2 メソッド、生存規則、UTF8 前提）。`pixi run test` 両サーバー PASS、`pixi run check` 6/6
  - 対象: `src/pq/result.mojo`, `src/pq/__init__.mojo`, `tests/test_zero_copy.mojo`
  - 依存: T6
  - 並列サブ作業: なし（推奨本数: **0**。1 ファイル中心で実行待ちが支配）

- [ ] T8: `test_leak` に Phase 3 ループ 2 本 + 陽性対照、`examples/binary.mojo`、`examples/bench_formats.mojo`、`pixi.toml` / `final_check.sh` の追従
  - 完了基準:
    - (a) `tests/test_leak.mojo`（P28）: `test_binary_execute_does_not_leak`（`MAIN_ITERATIONS` 回、1 接続を使い回し、
      `SELECT repeat('x', 65536)::text, 1.5::numeric, '2024-01-02'::date, '2024-01-02 03:04:05.678901'::timestamp, '2024-01-02 03:04:05+09'::timestamptz, '12:34:56'::time, '12:34:56+09'::timetz, '1 year 2 mons 3 days 04:05:06.789'::interval, gen_random_uuid(), '{"a":1}'::jsonb` を
      `execute(sql, [Decimal("1.50"), Date(8825)], result_format=BINARY)`（`WHERE $1 = 1.5 AND $2 = '2024-02-29'` を付けて拡張型パラメータの encode 経路も通す）し、10 列全部を `get[T]` で読む）と
      `test_zero_copy_does_not_leak`（同 SQL を text で、各行 `get_text(0).byte_length()` を足すだけ）。`_assert_stable` で判定（`TOLERANCE_PAGES` 256 のまま）。
      docstring `:33`「Twelve tests」→「Fourteen tests」+ Phase 3 の段 2 行、`:47-51` の所要見積もりに実測を足す
    - (b) **陽性対照**（REQ §5.3。`archive/phase2-params-prepared-tx/PLAN.md` T1 (g) と同じ手順）: `.gsd-lite/logs/phase3-binary-all-types/scratch/turn-NNN-leaksrc/` に `src/pq` をコピーし `Result.__deinit__` の `PQclear`（`result.mojo:98-99`）を `pass` にして `mojo build -I <copy> tests/test_leak.mojo -o <scratch>/turn-NNN-test_leak_noclear` → `test_binary_execute_does_not_leak` が **FAIL**（`ABORT_PAGES` 超過か `is_leaking`）。サンプル列を PROGRESS に貼る（PG17 でよい）
    - (c) `examples/binary.mojo`（REQ §5.4）: `from pq import Connection, PgError, ResultFormat, Decimal, Date, Timestamp, TimestampTz, Time, TimeTz, Interval, UUID` だけで、接続 → `execute(SQL, [], result_format=ResultFormat.BINARY)`（17 型: bool / int2 / int4 / int8 / float4 / float8 / text / bytea / numeric / date / timestamp / timestamptz / time / timetz / interval / uuid / jsonb を 1 行）→ 各列を `get[T]` して `print` → `column_format(0) == BINARY` を確かめ、違えば `exit(1)`。
      `examples/basic.mojo` と同じ `_conninfo()` / `try` / `exit(1)` の形。`pixi.toml:18` の次に `example-binary = "mojo run -I src examples/binary.mojo"`、`tests/final_check.sh:120` の次に `run_logged mojo run -I src examples/binary.mojo || examples_failed=1`（4/6 段のコメント「Both examples」→「All examples」。P29）
    - (d) `examples/bench_formats.mojo`（REQ §4.6 / P30）: `probe-bench.mojo` の SQL（`SELECT i::int4, i::int8, i::float8 / 3, 'row ' || i::text, timestamp '2000-01-01' + i * interval '1 second' FROM generate_series(1, 100000) AS g(i)`）を text / binary で `execute(sql, [], result_format=)` し、全行 `get[Int32](0)` / `get[Int64](1)` / `get[Float64](2)` / `get[String](3)` / `get[Timestamp](4)` を読む。
      `std.time.perf_counter_ns()` で exec と decode を分けて計り、ウォームアップ 1 回 + 計測 3 回、`text  : exec N ms, decode N ms, total N ms` / `binary: ...` の形で 6 行出す。**合否判定はしない**。`pixi.toml` に `bench = "mojo run -I src examples/bench_formats.mojo"`（`final_check.sh` には足さない）。
      `pixi run bench` を PG17 で 1 回回し 6 行を PROGRESS に貼る（単位 ms）
    - (e) `pixi run test` 両サーバー PASS（test_leak 14 件、54314 側も leak を回す）、`pixi run check` 6/6（ログに `examples/binary.mojo` の行、`skipped (PQ_TEST_LEAK_SERVERS=1)` が 54314 側）。`check` / `test` / test_leak 1 サーバーの所要（s）を PROGRESS に
  - 対象: `tests/test_leak.mojo`, `examples/binary.mojo`, `examples/bench_formats.mojo`, `pixi.toml`, `tests/final_check.sh`
  - 依存: T7
  - 並列サブ作業（推奨本数: **1**。leak の実行待ちが支配するので example / bench を 1 本に出す）:
    - A: `examples/binary.mojo` + `examples/bench_formats.mojo` + `pixi.toml` + `final_check.sh` 4/6（対象: その 4 ファイル）
    - 親: (a)(b)(e)

- [ ] T9: 文書の最終整備（`__init__.mojo` 型マッピング / Parameters 表）+ 受け入れ基準の総点検 + 最終判定
  - 完了基準:
    - (a) `src/pq/__init__.mojo:13-34` の型マッピング表を REQ §4.2 / §4.3 の 17 行（+ json / jsonb）に拡張し「text form」「binary form」の 2 列、「anything else」行を「`String` in text format only; `TYPE_MISMATCH` in binary」に。`:36-63` の Parameters 表に 8 型（OID / binary / 幅）。`:3-4` の「Phase 2 adds ...」に「Phase 3 adds `decode_binary`, `types_numeric`, `types_datetime`, `types_uuid`」。
      `## Result format` / `## Zero-copy access` 節（T2 / T7）の内容と矛盾が無いことを読み合わせる
    - (b) 追従先チェックリストの**全行**のコマンドを実行し、結果を PROGRESS の「追従先チェックリスト ✓」に素のシェルで再現できる形で書く（Phase 1 reflect 提案）
    - (c) REQ §5.1 / §5.2 / §5.4 の各項目に対応するテスト名（ファイル名 + 関数名）を PROGRESS に 1 行ずつ対応づける（verify が格子を作る材料）。対応先の無い項目が残っていれば**このタスクでテストを足す**
    - (d) `pixi run check` 6/6 PASS、`pixi run test` 両サーバー PASS、`pixi run package` 警告ゼロ、`pixi run example-binary` / `pixi run bench` が単体で動く。所要（s）を PROGRESS に
  - 対象: `src/pq/__init__.mojo`（+ (c) で足すテスト）
  - 依存: T8
  - 並列サブ作業: なし（推奨本数: **0**）

## 決めた事項

1. **`ResultFormat`**（REQ §4.1 / D14）: `src/pq/result.mojo` に `@fieldwise_init struct ResultFormat(Equatable, TrivialRegisterPassable, Writable)`、`var value: Int`、`comptime TEXT = Self(0)` / `comptime BINARY = Self(1)`、`__eq__` / `__ne__` / `write_to`（`"Text"` / `"Binary"`）。`PgErrorKind`（`src/pq/errors.mojo:9-86`）と同形。`pq` 直下で再エクスポート。
   `Result.column_format(i) raises PgError -> ResultFormat` は `ResultFormat(Int(PQfformat(res, i)))`（`_ffi/functions.mojo:101-103`）。追加の `_ffi` バインドは無し（REQ §4.8。`PQfformat` / `PQgetlength` / `PQftype` は `functions.mojo:98-111` に済み）
2. **`result_format` キーワード引数**: `Connection.execute(self, var sql: String, params: List[Param], result_format: ResultFormat = ResultFormat.TEXT)`（`connection.mojo:286-288`、`:362` の `c_int(0)` → `c_int(result_format.value)`）、`PreparedStatement.execute(self, params: List[Param], result_format: ResultFormat = ResultFormat.TEXT)`（`prepared.mojo:127`、`:188`）。
   **`Transaction.execute(sql, params)`（`transaction.mojo:393`）にも同じ引数を足して passthrough する**（REQ §4.1 には無いが、`Transaction.execute` は `Connection.execute` の委譲で 1 引数足すだけ。無いとブロック内で binary を使う経路が `conn.execute` 直呼びに限られる）。`execute(sql)` 単体は `PQexec` でテキスト固定のまま
3. **`decode_binary` のシグネチャ**: `def decode_binary[T: Copyable](bytes: Span[UInt8], oid: UInt32) raises PgError -> T`（`src/pq/decode_binary.mojo`）。生ポインタ + 長さではなく **`Span`** を取る（単体テストが `Span[UInt8](list)` で呼べる。`Row._raw(col) -> Span[UInt8, Self.origin]` が `PQgetvalue` / `PQgetlength` から作る）。
   `T` の対応（REQ §4.2 / §4.3 の表のとおり厳密）: `Bool`→16 / `Int16`→21 / `Int32`→23 / `Int64`・`Int`→20 / `Float32`→700 / `Float64`→701 / `String`→25・1043・1042・19・114・3802（3802 は先頭 1 byte = 1 を剥がす）/ `List[UInt8]`→17 / `Decimal`→1700 / `Date`→1082 / `Timestamp`→1114 / `TimestampTz`→1184 / `Time`→1083 / `TimeTz`→1266 / `Interval`→1186 / `UUID`→2950。他の `T` は `comptime assert False`。
   個別関数は `decode_bool / decode_int16 / decode_int32 / decode_int64 / decode_float32 / decode_float64 / decode_numeric / decode_date / decode_timestamp / decode_timestamptz / decode_time / decode_timetz / decode_interval / decode_uuid`（`encode_binary.mojo:16-18` の対の約束。text 系 / bytea / jsonb は `decode_binary[T]` の分岐内で直接）。
   長さ検査（P21）: bool 1 / int2 2 / int4 4 / int8 8 / float4 4 / float8 8 / numeric `8 + 2*ndigits`（かつ ≥ 8）/ date 4 / timestamp・timestamptz・time 8 / timetz 12 / interval 16 / uuid 16 / jsonb ≥ 1。
   値検査: bool は 0 / 1 のみ（P24。サーバーは 2 を受理するがクライアントは厳格）、numeric は sign ∈ {0x0000, 0x4000, 0xC000, 0xD000, 0xF000}・dscale ≤ 0x3FFF・digit ≤ 9999（special は sign だけ見て weight / dscale を捨てる。P1）、time は 0..86400000000（上限含む。P11）、timetz は |zone| < 57600、jsonb version = 1。date / timestamp / timestamptz / interval は範囲検査しない（番兵を含めサーバーが出す値は全部有効。rust-postgres の "not drained" 相当は長さ検査で担保）。
   読み出しは `bitcast[DType.int16, 1](UInt16)` / `bitcast[DType.int32, 1](UInt32)` / `bitcast[DType.float32, 1](UInt32)` / `bitcast[DType.float64, 1](UInt64)`（RESEARCH §0.5）。binary の `String` は `String(unsafe_from_utf8=span)`（UTF-8 検証なし。text 経路 `result.mojo:331-333` と同じ前提。P20）
4. **binary の `TYPE_MISMATCH` メッセージ**（テストは 2 語以上の部分文字列で確かめる）:
   - OID 不一致（`get[String]` の非文字列 OID と未対応 OID を含む。REQ §4.1 / D9）: `column is oid <oid> but <T の名前> was requested in binary format; request a matching type or re-run with ResultFormat.TEXT`（`<T の名前>` は `String` / `List[UInt8]` / `Int32` のような Mojo 型名。期待部分文字列 `"oid <n>"` と `"ResultFormat.TEXT"`）
   - 長さ不一致: `binary <pgtype> value has <actual> bytes, expected <expected>`（numeric は `expected 8 + 2*ndigits = <n>`。期待部分文字列 `"bytes, expected <n>"`）
   - 値の不正: `cannot decode binary <pgtype>: <reason>`（bool `byte is 2, expected 0 or 1`／jsonb `version byte is 2, expected 1`／numeric `invalid sign 0x1234`・`digit 10000 out of range`・`dscale 16384 out of range`／time `86400000001 is out of range`／timetz `zone 57600 is out of range`）
   - text 形式の parse 失敗は既存の `_decode_error`（`decode_text.mojo:76-81`）と同形 `cannot decode "<text>" as <pgtype>`（型モジュール側に同じ文面の private ビルダーを置く。`decode_text` を import すると循環するため）
5. **`Decimal`**（`src/pq/types_numeric.mojo`。D10）: `struct Decimal(Copyable, Movable, Equatable, Writable)`、フィールドは **private**（`_sign: UInt16` / `_weight: Int16` / `_dscale: UInt16` / `_digits: List[Int16]`。sign 定数 `_SIGN_POS = 0x0000` / `_SIGN_NEG = 0x4000` / `_SIGN_NAN = 0xC000` / `_SIGN_PINF = 0xD000` / `_SIGN_NINF = 0xF000`）。
   公開: `__init__(out self, text: String) raises PgError`（失敗は **`USAGE`** `invalid numeric literal "<text>"`）/ `@staticmethod parse(text: String) raises PgError -> Self`（失敗は **`TYPE_MISMATCH`** `cannot decode "<text>" as numeric`。`decode_text` が呼ぶ）/ `nan()` / `infinity()` / `negative_infinity()` / `dscale() -> Int` / `is_nan()` / `is_infinite()` / `is_finite()` / `__eq__` / `__ne__` / `write_to`。
   package 内部用 `_from_parts(sign: UInt16, weight: Int16, dscale: UInt16, var digits: List[Int16]) -> Self`（`decode_numeric` が呼ぶ。**正規化**: 先頭・末尾のゼログループを落として weight を調整、全ゼロは `ndigits 0, weight 0, sign POS`、special は weight 0 / dscale 0 / digits 空。PG `make_result`）。parse も同じ正規化を通す。
   `__eq__` は `(_sign, _weight, _digits)` の一致（dscale は見ない → `1.0 == 1.00`。NaN == NaN、Inf == Inf。PG `numeric_eq` と同じ。P5）。文字列化は RESEARCH §3-1、解釈は §3-2。受ける文法は `[+-]?(\d+(\.\d*)?|\.\d+)` と `NaN` / `[+-]?Infinity`（これ以外は拒否。D14 / P26）。dscale ≤ 16383、weight は Int16 に収まること（P6）。`Param` ctor は OID 1700 の binary（`encode_numeric`。special は `0000 0000 <sign> 0000`）
6. **`UUID`**（`src/pq/types_uuid.mojo`）: `struct UUID(Copyable, Movable, Equatable, Writable)`、`var bytes: Array[UInt8, 16]`（公開。`InlineArray` は無い。RESEARCH §0.5）。`__init__(out self, bytes: Array[UInt8, 16])` / `__init__(out self, text: String) raises PgError`（`USAGE` `invalid uuid literal "<text>"`）/ `parse(text)`（`TYPE_MISMATCH`）/ `write_to`（小文字 `8-4-4-4-12`）/ `__eq__` / `__ne__`。受ける文法は 36 文字の `8-4-4-4-12`（16 進は大文字小文字どちらも）だけ。`Param` ctor は OID 2950 の 16 byte
7. **`Date` / `Timestamp` / `TimestampTz`**（`src/pq/types_datetime.mojo`。D11）: いずれも `@fieldwise_init struct X(Copyable, Movable, Equatable, Writable)` で生フィールド公開（`Date.days: Int32`、`Timestamp.micros: Int64`、`TimestampTz.micros: Int64`（UTC））。生 ctor は**検査しない**（PG 内部表現をそのまま持つ）。
   共通: `@staticmethod infinity() -> Self` / `negative_infinity() -> Self`（`Int32.MAX` / `Int32.MIN` / `Int64.MAX` / `Int64.MIN`。struct 型の `comptime` 定数は使わない）、`is_infinite()` / `is_finite()`、`@staticmethod parse(text: String) raises PgError -> Self`（`TYPE_MISMATCH`）、`write_to`（PG の text 形式と同じ。`infinity` / `-infinity`）、`__eq__` / `__ne__`（内部整数の比較）。
   検査付き構築子（REQ §4.3。失敗は **`USAGE`** `invalid <pgtype>: <成分>`）: `Date.from_ymd(y, m, d)`（天文年: 1 BC = 0。`1 <= m <= 12`、`1 <= d <= days_in_month`、結果が `-2451545..2145031948`）、`Timestamp.from_ymd_hms(y, m, d, h, mi, s, us = 0)`（`0 <= h <= 23`、`0 <= mi, s <= 59`、`0 <= us <= 999999`、結果が `-211813488000000000..9223371331199999999`）、`TimestampTz.from_utc(...)`（同じ検査。UTC として解釈）。
   分解アクセサ `year() / month() / day()`（Date）、`+ hour() / minute() / second() / microsecond()`（Timestamp / TimestampTz は UTC で）は **`raises PgError`** で、無限値では `USAGE` `<pgtype> is infinite; <accessor>() is undefined`（RESEARCH §3-7 の推奨どおり番兵値を返さない）。
   text: `Date` は `YYYY-MM-DD( BC)?`（年は 4 桁ゼロ埋め・4 桁超はそのまま。`y <= 0` は `1 - y` + ` BC`）、`Timestamp` は `YYYY-MM-DD HH:MM:SS(.f{1,6})?( BC)?`、`TimestampTz` は `YYYY-MM-DD HH:MM:SS(.f{1,6})?[+-]HH(:MM(:SS)?)?( BC)?`（**` BC` はオフセットの後**。P13。解釈は末尾 ` BC` を剥がしてから時刻部の後ろで `[+-]` を探す。`utc = local - offset`。|offset| ≥ 57600 は拒否）。`String(TimestampTz)` は UTC で `+00` 付き（コンテナの TimeZone が `Etc/UTC` なので往復テストは文字列一致になる）。
   `atol` は使わず桁位置で読む（P25。先頭 `+` / 空白 / 桁数違いを拒否）。小数秒は読んだ桁数 n で `10^(6-n)` 倍、7 桁以上は拒否（P14）。暦算法は RESEARCH §2.2.3 のコード（Hinnant、Mojo 床除算、`y // 400`）
8. **`Time` / `TimeTz` / `Interval`**（同じ `types_datetime.mojo`）: `Time(micros: Int64)`（0..86400000000。生 ctor 無検査）、`TimeTz(micros: Int64, offset_secs: Int32)`（**PG と同じ西が正**: `+09` は -32400。P10）、`Interval(micros: Int64, days: Int32, months: Int32)`（フィールド順もこの順。P7。正規化しない: `months / days / micros` をそのまま保持）。
   `Time.from_hms(h, mi, s, us = 0)` / `TimeTz.from_hms(h, mi, s, us, offset_secs)`（`USAGE`。`h == 24` は `mi = s = us = 0` のときだけ可。`|offset_secs| < 57600`）、アクセサ `hour() / minute() / second() / microsecond()`（無限値が無いので `raises` しない）、`TimeTz.offset_secs` はフィールドをそのまま読む。
   `Interval` は `infinity()` / `negative_infinity()`（3 フィールド全 MAX / 全 MIN。PG17 の番兵）と `is_infinite()`（**3 つ全部**が MAX か全部 MIN のときだけ）/ `is_finite()`。分解アクセサは作らない（フィールド直読み）。
   text: `Time` は `HH:MM:SS(.f{1,6})?`（HH は 2 桁、`24:00:00` 可）、`TimeTz` は `+ [+-]HH(:MM(:SS)?)?`（出力は `-offset_secs` を `EncodeTimezone` の規則で: 分・秒が 0 なら省略。`offset_secs <= 0` → `+`）、`Interval` は IntervalStyle `postgres` の出力文法（RESEARCH §2.2.3: `year = months // 12`（**C の切り捨て除算**。Mojo の `//` は床なので負値は `-(abs // 12)` で書く）、`mon = months % 12`（同じく符号は months に合わせる）、複数形は値 ≠ 1、`+` 接頭辞は「前に出した成分が負で、この成分が正」、時刻部は `[-]H+:MM:SS(.f)?` で H は 2 桁以上上限なし、全部 0 は `00:00:00`、`infinity` / `-infinity`）。解釈はその逆のみ（`1 week` / ISO 8601 / `1.5 days` 等サーバー入力専用の形は拒否）
9. **zero-copy**（REQ §4.5 / RESEARCH §2.3.1）: `Row.get_text(self, col: Int) raises PgError -> StringSlice[Self.origin]` と `Row.get_bytes(self, col: Int) raises PgError -> Span[UInt8, Self.origin]`。`Int` 添字のみ（名前版は作らない。YAGNI）。
   `get_bytes` は **形式・OID を問わず** `PQgetvalue` 領域の `PQgetlength` バイト（REQ §4.5 の文言どおり。text 形式なら text のバイト列、binary なら wire バイト列。これは `get[List[UInt8]]` の OID 規則とは別の「生の領域を見る」API で、D9 が却下したのは `get[T]` の例外である）。
   `get_text` は text 形式なら任意 OID、binary 形式なら文字列系 6 OID のみ（jsonb は version byte を 1 つ飛ばす）、他は決めた事項 4 の OID 不一致。NULL は `NULL_VALUE`。実装は `Pointer[UInt8, Self.origin](unsafe_from_address=Int(ptr))` → `Span[UInt8, Self.origin](unsafe_ptr=p, length=n)` → `StringSlice[Self.origin](unsafe_from_utf8=span)`（`Span(ptr=)` ではない）。`ref` は返さない（P19）
10. **接続直後の GUC 固定**（REQ §4.7 / D12）: `comptime _SESSION_SETUP_SQL = "SET DateStyle TO 'ISO, YMD'; SET IntervalStyle TO 'postgres'"`（`connection.mojo`）。`_adopt` が `Connection` を組み立てた直後に `execute(sql)` で 1 回送る。失敗時の `PQfinish` は `Connection.__deinit__`（`:121-124`）に任せ、kind は `_take_result` の分類（`SERVER` / `CONNECTION`）。`TimeZone` は触らない。`client_encoding` も触らない（`SHOW client_encoding` が `UTF8` であることをテストで確かめるだけ）
11. **モジュール配置**: `src/pq/types_numeric.mojo` / `src/pq/types_datetime.mojo` / `src/pq/types_uuid.mojo` の 3 ファイル（HANDOFF §4 の案は `value.mojo` 1 本だが、RESEARCH §6 の 1,500 行見積もりとサブエージェント並列の単位を優先して分けた）。OID 定数は従来どおり `decode_text.mojo:18-49` が唯一の置き場（`decode_binary.mojo` / `params.mojo` はそこから import）。
   import の向き: `types_*` → `errors` のみ；`decode_text` / `decode_binary` / `encode_binary` → `types_*`；`params` → `encode_binary` + `decode_text`（OID）；`result` → `decode_text` + `decode_binary`。循環なし
12. **テストファイル**: サーバー不要 — `tests/test_decode_binary.mojo`（T2〜T5）、`tests/test_types_numeric.mojo`（T3）、`tests/test_types_uuid.mojo`（T3）、`tests/test_types_datetime.mojo`（T4〜T5）、既存 `test_encode_binary.mojo` / `test_params.mojo` への追記；サーバー — `tests/test_binary.mojo`（T2）、`tests/test_extended_numeric.mojo` / `tests/test_extended_datetime.mojo`（T6）、`tests/test_zero_copy.mojo`（T7）、`test_connection.mojo`（T1）/ `test_leak.mojo`（T8）への追記。
   期待値は RESEARCH §2.2 の hex / 文字列を**そのまま**写す（PG17 / PG14 実測）。期待メッセージは 2 語以上の部分文字列
13. **`Param` の拡張型 ctor**（REQ §4.4 / D14）: 8 型 × （値 / `Optional`）= 16 本の `@implicit`、すべて binary で OID は決めた事項 3 の値。json / jsonb は専用型を作らず `String`（OID 0、text）のまま。`_ParamBuffers` は変更なし（`_ = buffers^` の並びも変えない。RESEARCH §0.5 末尾）
14. **ベンチ**（REQ §4.6）: `examples/bench_formats.mojo`、SQL は probe-bench のもの（決めた事項 — T8 (d)）、`pixi run bench`。`final_check.sh` には入れない。数値は PROGRESS / VERIFICATION に単位付きで記録、合否なし

## メモ

### RESEARCH §3「盗める点」の採否

| # | 内容 | 採否 | 理由 |
|---|---|---|---|
| 1 | `Decimal` の文字列化 = asyncpg / `get_str_from_var`（bignum 不要） | 採用 | T3。P2〜P4 の検証がそのまま付く |
| 2 | 解釈 = `set_var_from_str` の式 + `make_result` 正規化、`==` は正規化後の比較 | 採用 | T3 / 決めた事項 5 |
| 3 | Hinnant 暦算法（komira の床除算版） | 採用 | T4。probe-civil で 9 日付 + 5 timestamp 照合済み |
| 4 | timestamp の分解は `days = us // 86400000000` + 余り | 採用 | T4 |
| 5 | interval 文字列化 = `interval2itm` + `AddPostgresIntPart`、months を日に畳まない | 採用 | T5。psycopg / asyncpg の非可逆化は踏まない |
| 6 | timetz は符号反転 + 秒保持 | 採用 | T5 / 決めた事項 8 |
| 7 | 番兵を第一級の値に、無限値でのアクセサは `USAGE` | 採用 | T4 / 決めた事項 7 |
| 8 | 固定長の厳密検査（"not drained"） | 採用 | T2 / 決めた事項 3 |
| 9 | 未対応 OID を binary で生バイトにフォールバック（psycopg） | **却下** | D9。`TYPE_MISMATCH` + `ResultFormat.TEXT` の案内 |
| 10 | `_ParamBuffers` / `exec_fmt` の雛形、`ResultFormat` は `PgErrorKind` と同形 | 採用 | T2 / 決めた事項 1 |
| 11 | zero-copy の 3 行 | 採用 | T7 / 決めた事項 9 |

### RESEARCH §4「落とし穴」とタスクの対応

P1〜P6 → T3（単体）+ T6 (a)（サーバー）／P7〜P11 → T5（単体）+ T6 (b)／P12〜P14 → T4（単体）+ T6 (b)／P15 → T6 (b) ⑤（+ T1 の SET）／P16・P17 → T1 (k)(l)／P18〜P20 → T7／P21〜P24 → T2 (d)(e)（numeric / jsonb / time / timetz の長さ・値は T3〜T5 で追加）／P25 → T4 (b)・T5 (b)・T3 (b)／P26 → T3 (b)／P27 → T4 (b)／P28 → T8 (a)(b)／P29 → T8 (c)／P30 → T8 (d)。対応先の無い落とし穴は無い

### 観点の担当

- 境界値: T3〜T5 の単体（RESEARCH の実測値）+ T6 のサーバー格子（REQ §5.1 の列挙 + RESEARCH §5-7 の追加 4 件: `24:00:00`、`+05:53:28`、`-1 years +1 day`、`0.00`）
- 異常系: T2 (d)(e)（長さ・OID 格子）、T3〜T5 の拒否ケース、T6 (b) ④⑤（PG14 の 22008、非 ISO）、T1 (k)（SET 失敗は所有権で `PQfinish`。再現困難なのでコードレビュー）
- 並行性: 同期クライアントなので無い。代わりに「10,000 回連続 execute」の資源回収を T8 の leak ループが担う
- 陽性対照（必ず同じターンで実測して PROGRESS に貼る）: T1 (b)（6/6 段の grep）、T7 (c)（コンパイルエラー 3 本）、T8 (b)（`PQclear` 除去で leak FAIL）

### reflect 提案の反映（直近 2 件）

- Phase 2 reflect: 持ち越し整理を T1 に（反映）／REQ §5.1a の訂正は discuss が REQ §7 で実施（済）／「要実測」印は research が実施（済）／`grep -c X = 0` の機械化 → `|implicit ROLLBACK failed` を T1 で 6/6 段に（反映）。「`is Phase 3`」「`-> ref`」の grep は 1 回きりなので機械化しない（P19 の plan 判断）／期待メッセージ 2 語以上（全タスクに反映）／PROGRESS「確認済み / 未確認」の分離（下の impl への申し送りに）／RESEARCH §0.5 の転記（research が実施）／非対称を突くプローブ（research が実施）／**サブエージェント推奨本数を各タスクに明記**（反映。T7 / T9 は 0 本）／最初の 1 本をコンパイルしてから（impl にも適用: 型モジュールは `Decimal` 1 struct をコンパイルしてから残りを書く）／ツール側（ユーザー）／+83 ページは D4 で (a) に決定 → T1 (h)（反映）
- Phase 1 reflect: 陽性対照を plan が最初から書く（反映: T1 / T7 / T8）／1/6 段の fmt 判定（Phase 2 で済）／`check` の待ち時間（済）／verify round 2 の限定運用（REQ §9 に記載済み）／「追従先チェックリスト ✓」は素のシェルで再現できる形（T9 (b) に反映）

### impl への申し送り

- **型モジュールの書き始め**: `Decimal` または `Date` の struct 1 つ + `write_to` + テスト 1 件をまずコンパイルして通し（`pixi run mojo run -I src tests/test_types_*.mojo`）、それから残りを書く（Phase 2 reflect Minus 3）。`comptime if T == Decimal` の分岐は `rebind[T](v).copy()` で通る（RESEARCH §2.3.2）
- **サブエージェント依頼文に必ず入れる 3 行**（REQ §9）: (a) 型パラメータを持つ型は `Row[origin]` / `Span[UInt8, origin]` / `StringSlice[origin]` のようにフルに書く、(b) `fmt` は親が統合後に 1 回だけ（サブエージェントは `mojo format` を走らせない）、(c) scratch は `.gsd-lite/logs/phase3-binary-all-types/scratch/turn-NNN-<name>` 固定（`/tmp` は権限拒否）。加えて本 PLAN の該当「決めた事項」の番号を貼る（契約）
- **PROGRESS「次への注意」は「確認済み:」と「未確認:」を分けて書く**。所要の数値には単位（ms / s）を書き、TestSuite の `Summary [ N ]` は **ms**
- Mojo 1.1.0 の落とし穴は RESEARCH §0.5 を最初に読む。特に: `_ = x^` は生存マーカー／`Span(unsafe_ptr=, length=)`／`Array[UInt8, 16](fill=0)`／`//` と `%` は床（interval の `year = months // 12` は**符号を合わせて自前で切り捨てる**）／`atol` は `+` と空白を通すので日時・uuid・numeric の parse には使わない／`String.as_bytes()` は `Span`／ローカル `List` は `return out^`／`-Int64.MIN` は wrap する（`Interval` 文字列化で `abs(micros)` を取るとき `Int64.MIN` は番兵なので先に `is_infinite()` で分岐し、有限値の時刻部は `Int64.MIN + 1` 以上）
- **ASAP 破棄**: `_ParamBuffers` の `_ = buffers^` は呼び出しの**後**（`params.mojo:34-46`）。新しい encode 経路を足しても並びを変えない。zero-copy の slice を返す関数内で `Result` を動かさない
- `Decimal` の private フィールドはアンダースコア慣習（Mojo に可視性制御は無い）。`decode_numeric` / `encode_numeric` は同じパッケージ内なので `_from_parts` / `_digits` に触ってよいが、テストからは公開 API（`parse` / `String()` / `==` / `dscale()`）だけで検証する
- T6 の timestamptz 文字列比較はコンテナの `TimeZone = Etc/UTC` 前提。`SHOW TimeZone` を最初に読み、`UTC` / `Etc/UTC` 以外なら `String()` 比較だけを skip してログに 1 行出す（値一致は常に見る）
- `check` の時間が 3 分を超えたら PROGRESS に書く（verify の計画に使う）。超える要因は test_leak の +15 s と新テスト 7 本 × 2 サーバーの見込み
