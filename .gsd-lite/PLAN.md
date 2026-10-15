# PLAN — phase2-params-prepared-tx

- 作成: 2026-10-16 / gsd-lite-plan（turn 2）
- 入力: REQUIREMENTS.md / DECISIONS.md / RESEARCH.md / `.gsd-lite/reflect/20261015-2308-phase1-sync-text-basic.md` /
  `archive/phase1-sync-text-basic/{PLAN,VERIFICATION}.md` / `src/pq/*.mojo` / `tests/*` / `.pixi/envs/default/include/libpq-fe.h`
- 対象リポジトリ: `.`（in-repo 形）。`CLAUDE.md` / `AGENTS.md` は無い（`find . -maxdepth 1 -name 'CLAUDE.md' -o -name 'AGENTS.md'` 空）
- 無人シェルの注意（RESEARCH 冒頭と同じ）: `mojo` / `pixi` は PATH に無い → **`/home/parallels/.pixi/bin/pixi run ...`**。`rg` は無い（`grep`）。
  docker の DB は `tests-pg17-1`（127.0.0.1:54317）/ `tests-pg14-1`（127.0.0.1:54314）が healthy で起動中（plan 時点 `docker ps`）
- **plan 時のプローブ**（`.gsd-lite/logs/phase2-params-prepared-tx/scratch/turn-002-cyc/`。出力 4 行すべて期待どおり、警告なし）:
  (1) パッケージ内の**循環 import**（`a.mojo` が `from .b import Tx, default_handler`、`b.mojo` が `from .a import Conn`）は Mojo 1.1.0 で通る →
  `connection.mojo` ↔ `transaction.mojo` / `prepared.mojo` の相互 import を前提にしてよい。
  (2) `from std.sys import stderr` + `print("...", message, sep="", file=stderr)` が動く（既定ハンドラの実装）。
  (3) `from std.os import setenv, getenv` の往復（`setenv(name, value, True)`）が動く（テスト用フックの観測手段）。
  (4) `Pointer[Int, MutUntrackedOrigin](unsafe_from_address=Int(self._counter.unsafe_ptr()))[] += 1` で不変 `self` からカウンタ更新（`pq_stmt_1` / `pq_stmt_2`）

## 検証コマンド

impl の各ターンがテストに使うコマンド（リポジトリルートで実行。`cd` 不要）:

```bash
/home/parallels/.pixi/bin/pixi run db-up        # 環境の初期化（--wait 付き。起動済みなら即終了）
/home/parallels/.pixi/bin/pixi run test         # tests/run_tests.sh: 54317 → 54314 の順に tests/test_*.mojo を 1 ファイル 1 プロセス。T1 以降 test_leak は build/test_leak（mojo build 済み）で実行
/home/parallels/.pixi/bin/pixi run mojo run -I src tests/test_params.mojo    # 単一ファイル（PQ_TEST_CONNINFO 未設定なら 54317）
/home/parallels/.pixi/bin/pixi run package      # mojo precompile src/pq -o build/pq.mojoc（警告ゼロ確認）
/home/parallels/.pixi/bin/pixi run check        # 最終判定: bash tests/final_check.sh（6 段、exit 0 が合格）
```

- 環境の初期化（テストの前に毎回）: `/home/parallels/.pixi/bin/pixi run db-up`
- 最終判定（クリーンな状態から全検査。verify と T7 が使う）: **`/home/parallels/.pixi/bin/pixi run check`**
  - **T1 完了まで**は 1/6 段が `git diff` 判定なので **`check` はコミット後にだけ回す**（未コミットの整形済み差分で落ちる。reflect 提案 2）。
    T1 で「コピーに `mojo format` → `diff -r`」に変えたあとは作業木のままで回せる
  - T1 以降 `check` の 5/6 段は `PQ_TEST_LEAK_SERVERS=1` で `test_leak` を **PG17（54317）だけ**回す。`pixi run test` は両方で回す（REQ §5.3）
  - 6/6 段は `warning:`（コンパイラ）に加えて **`WARNING:`（libpq の notice processor がサーバー WARNING を stderr に出したもの）も 0 件**を要求する（T1 で追加。P13）
- 所要の目安: Phase 1 末の `check` は 96 s（test_leak 42〜43 s/サーバー）。T1 で 1 サーバー化、T6 で Phase 2 ループ 4 本（各 10,000 回）が乗るので
  `check` は 2〜3 分、`pixi run test` は 4〜6 分を見込む。impl は所要を PROGRESS に書く

## 追従先チェックリスト

| 変更の種類 | 直す場所 | 確かめ方 |
|---|---|---|
| libpq 関数のバインディングを足す（T2: 50 → **53 本**） | `src/pq/_ffi/functions.mojo` のフィールド + `__init__` の `_dl_sym` 行（`# libpq-fe.h:<行>` コメント付き）、`tests/test_ffi.mojo` の `_symbol_names()` と `assert_equal(len(names), 53)`、テスト名 `test_all_fifty_symbols_present` → `test_all_symbols_present`、本 PLAN の「53 本」 | `grep -c '^    var PQ' src/pq/_ffi/functions.mojo` = 53、`grep -cE '^        (String\()?"PQ[A-Za-z]+"\)?,$' tests/test_ffi.mojo` = 53、`grep -c fifty tests/test_ffi.mojo` = 0、`grep -n '50 本' .gsd-lite/PLAN.md .gsd-lite/PROGRESS.md` = 0 件（REQ §4.6 の「現在 50 本」は discuss 時点の記述なので触らない） |
| `PgErrorKind` を足す（T2: `USAGE`） | `src/pq/errors.mojo` の定数 + `write_to` の名前表 + モジュール / struct docstring の「five」、`src/pq/__init__.mojo` の `## PgErrorKind` 一覧（「exactly five」）、`tests/test_errors.mojo` | `grep -rnE 'exactly five|the five failure|five failure' src/pq` = 0 件（`__init__.mojo:8` の「the five `PQTRANS_*`」は別物で残る）、`grep -c 'USAGE' src/pq/errors.mojo` ≥ 3 |
| 公開 struct を足す（`Param` / `PreparedStatement` / `Transaction`） | `src/pq/__init__.mojo` の再エクスポート + モジュール docstring（T3 / T4 / T5 で 1 行ずつ、文書は T7）、docstring 診断 | `grep -nE 'Param|PreparedStatement|Transaction' src/pq/__init__.mojo` が 3 型とも出る、`mojo precompile --diagnose-missing-doc-strings src/pq -o build/pq.mojoc 2>&1 \| grep -v '/_ffi/' \| grep -vE "'(__init__\|__deinit__\|__copyinit__\|__moveinit__)'" \| grep -c 'doc string'` = 0 |
| `Row.get[T]` の対応型を足す | （Phase 2 では足さない） | — |
| `examples/` を足す（T7: `params.mojo`） | `pixi.toml` `[tasks]` に `example-params`、`tests/final_check.sh` 4/6 段に実行行 | `grep -rn 'examples/' pixi.toml tests/final_check.sh` に `examples/params.mojo` が両方出る |
| テストファイルを足す | 無し（`run_tests.sh` は glob）。ただし **`tests/test_leak.mojo` だけ名前で特別扱い**（T1: `build/test_leak` を実行） | `pixi run test` のログに新ファイル名が 2 回出る（leak は `PQ_TEST_LEAK_SERVERS` 未設定なら 2 回） |
| libpq を呼ぶ新しい経路を足す | `char*` は即 `String` にコピー、`PQfreemem` は `connection.mojo` の `escape_literal` / `escape_identifier` 各 1 回のみ（savepoint は `escape_identifier` 経由）、`PQexec` の直呼びは `Connection.execute(sql)`、`Connection.prepare` の describe 失敗時 DEALLOCATE、2 つの `__deinit__`（Transaction の ROLLBACK / PreparedStatement の DEALLOCATE。raise できないので `_take_result` を使えない）の 4 箇所のみ | `grep -rn 'PQfreemem(' src/pq/*.mojo` = 2 行、`grep -rn 'PQexec(' src/pq/*.mojo` = 4 行（connection ×2 / transaction / prepared）、`grep -rc get_function src/pq` 全 0 |
| 埋め込み NUL の経路を足す | `sql` は `_reject_nul(sql, "sql")`（TYPE_MISMATCH、Phase 1 規則）、String パラメータは `params.mojo` で **USAGE**（REQ §4.1。決めた事項 20） | `grep -rn '_reject_nul' src/pq` に `connection.mojo` の `execute(sql, params)` が追加されている |
| テスト環境の環境変数を足す（T1: `PQ_TEST_LEAK_SERVERS`） | `tests/run_tests.sh` 冒頭コメント、`tests/final_check.sh` 5/6 段、本 PLAN「検証コマンド」 | `grep -rn PQ_TEST_LEAK_SERVERS tests/run_tests.sh tests/final_check.sh` ≥ 2 |
| リークループを足す（T6） | `tests/test_leak.mojo` のモジュール docstring（ループ数・所要）、本 PLAN T6 | `grep -c '^def test_' tests/test_leak.mojo` = 12（4 単体 + 4 Phase 1 + 4 Phase 2） |

## Tasks

- [x] T1: 持ち越し整理（REQ §6）+ リーク測定を `mojo build` バイナリに切り替え（§5.3）+ `final_check.sh` の fmt 判定 / WARNING 計数
  - **PLAN 訂正（turn 3 実測）**: (d) の 1/6 段は `mojo format --quiet build/fmtcheck/src ...` と**ディレクトリを渡しては動かない**。
    `mojo format` はディレクトリ走査時に `.gitignore` の除外を尊重し、コピー先の `build/` が除外されるため
    `No Mojo files are present to be formatted` で何も整形せず、`diff -r` が常に一致して**段が常に PASS する無言の no-op**になる。
    `find build/fmtcheck -name '*.mojo' -type f -print0` の**明示的なファイル列**を渡す形に変更した（明示指定されたファイルは除外されない。Mojo 1.1.0 実測）。
    陽性対照で `src/pq/errors.mojo` を崩すと実際の `pixi run check` が 1/6 段だけで FAIL することを確認済み
  - **PLAN 訂正（turn 3 実測）**: (f) の `TOLERANCE_PAGES` は **256 を維持**（16 には下げない）。built binary の 16 系列中 2 系列に +83 ページの一段が出たため（PLAN の分岐どおり）
  - 完了基準:
    - (a) docstring 3 件（REQ §6-1。前回 VERIFICATION round 2 残留リスク）:
      `src/pq/connection.mojo:239-240` の `execute` Raises の `CONNECTION` 説明を「libpq returns no result at all, or the connection was lost while running `sql` **and libpq reported it without an SQLSTATE**（sqlstate 付きの FATAL が先に届いた切断は `SERVER` のまま、次の `execute` で `CONNECTION`）」に；
      `src/pq/result.mojo:423-424` / `:484-485`（`Row.get[T](col: String)` / `get_optional[T](col: String)` の Raises）の「when `col` contains a NUL byte」に「the message names `name`, the argument of `Result.column_index` it delegates to（`embedded NUL byte in name`）」を足す（テストは `name` を assert 済みなので docstring 側を直す）；
      `tests/test_leak.mojo:48-59` `PAYLOAD_BYTES` docstring の「first sample is taken before `ABORT_PAGES` is reached」を「`ABORT_PAGES` は最初のサンプルからの増分なので、サンプル間隔 × `PAYLOAD_BYTES` が `ABORT_PAGES` より十分小さく、リークは数サンプル以内で打ち切られる」に書き直す。
      あわせて `tests/test_leak.mojo:1-28` のモジュール docstring と `:87-101` `TOLERANCE_PAGES` docstring を「`tests/run_tests.sh` が `mojo build` したバイナリで実行する（コンパイラの常駐ヒープが無い。`mojo run` で直接回すと 64 KiB payload のおかげで検出はできるが +83 ページの一段で偽陽性になり得る）」に合わせて書き直す（数値は (f) の決定後に）
    - (b) REQ §6-2（`PQ_MOJO_LIBPQ` 設定時はその 1 本のみ）: コード変更なし。`grep -n 'that one path only' src/pq/_ffi/loader.mojo` が 1 件あることを PROGRESS の追従先チェックリスト ✓ に書く
    - (c) REQ §6-4（`OID_TEXT` 等 4 定数）: T1 ではコード変更なし（T3 の `params.mojo` が `pq.decode_text` の `OID_*` を import して `Param` の型 OID に使い、T4 のテストが `OID_TEXT` を参照する。決めた事項 4）
    - (d) `tests/final_check.sh` 1/6 段（REQ §6-3 / P23）: `rm -rf build/fmtcheck && mkdir -p build/fmtcheck` → `cp -r src tests examples hello.mojo build/fmtcheck/` → `mojo format --quiet build/fmtcheck/src build/fmtcheck/tests build/fmtcheck/examples build/fmtcheck/hello.mojo` →
      `diff -r -q src build/fmtcheck/src`（tests / examples / hello.mojo も同様）。差分があれば差分ファイル名を `say` して `fail "1/6 fmt (diff not empty)"`。`git diff` は使わない（RESEARCH §2.3 の実測手順。`mojo format` に `--check` は無い）。
      **陽性対照**（同じターンで実測、PROGRESS に貼る）: `src/pq/errors.mojo` の 1 行をわざと `   x = 1` のように崩した作業木で 1/6 段の各コマンドを手で順に実行し `diff` が非 0 になること、元に戻して `diff` が 0 になること。
      6/6 段: `grep -c 'warning:'` を `grep -cE 'warning:|WARNING:'` にして **libpq が stderr に出すサーバー WARNING**（`WARNING:  there is already a transaction in progress` 等。RESEARCH F2 / F4）も 0 件を要求する（P13。見出し行にこの文字列を含めない）。
      5/6 段: `run_logged env PQ_TEST_LEAK_SERVERS=1 bash tests/run_tests.sh`（見出しに「test_leak on the first server only」）。4/6 段は T7 で `examples/params.mojo` を足すまで `basic` のみ
    - (e) `tests/run_tests.sh`（REQ §5.3 / P7）: ループの前に `mkdir -p build` → `mojo build -I src tests/test_leak.mojo -o build/test_leak`（`== mojo build tests/test_leak.mojo` を echo、失敗なら `status=1` にして leak は skip 扱いで続行）。
      サーバーごとのループで `tests/test_leak.mojo` のときだけ `build/test_leak` を実行（他は従来の `mojo run -I src "$f"`）。サーバーの通し番号（0 始まり）が `PQ_TEST_LEAK_SERVERS`（既定: 無制限）以上なら
      `-- $label tests/test_leak.mojo skipped (PQ_TEST_LEAK_SERVERS=N)` を出して回さない。冒頭コメントに `PQ_TEST_LEAK_SERVERS` の意味（`check` が 1 を渡す）と「leak はビルド済みバイナリで回す理由（`mojo run` の常駐ヒープ）」を書く。
      `build/test_leak` は `.gitignore` の `build/` 配下（確認: `.gitignore:6`）
    - (f) `TOLERANCE_PAGES` の決定（D4 / P6）: (e) のあと `pixi run test` を **2 回**（= PG17 ×2 + PG14 ×2 の leak 系列 4 組 × 4 ループ）回し、16 系列すべてを PROGRESS に貼る。
      **全系列で `samples[-1] - samples[0] ≤ 8` かつ +83 ページの一段が 1 回も無ければ `TOLERANCE_PAGES = 16`**。一段が 1 回でも出たら 256 のまま維持し、理由（出たループと系列）を PROGRESS に書く（REQ §5.3 のフォールバック）。
      どちらでも `is_leaking` の単体テスト 4 件（tolerance 16 を引数で渡す）は変更しない
    - (g) **陽性対照**（REQ §5.3。同じターン、`.gsd-lite/logs/phase2-params-prepared-tx/scratch/turn-NNN-leaksrc/` に `src/pq` をコピーして `mojo build -I <copy> tests/test_leak.mojo -o <scratch>/turn-NNN-test_leak_<name>`。雛形: `scratch/turn-001-leaksrc/`、RESEARCH §2.3）:
      ① `Result.__deinit__` の `PQclear`（`src/pq/result.mojo:99`）を `pass` に → `test_connect_query_close_does_not_leak` が **FAIL**（研究時: 5 サンプル目で `ABORT_PAGES` 超過）；
      ② `escape_literal` の `PQfreemem`（`connection.mojo:350`）を消す → `test_escape_literal_does_not_leak` が **FAIL**。両方のサンプル列を PROGRESS に貼る（PG17 でよい）。REQ は「いずれか」だが PQclear と PQfreemem の 2 経路で検出力を示す
    - (h) `pixi run test` 両サーバー PASS（ログに `== mojo build` 行、`build/test_leak` が存在、54314 側は leak を回す）。**作業木が未コミットのまま** `pixi run check` が 6/6 PASS（(d) の効果。ログに `skipped (PQ_TEST_LEAK_SERVERS=1)` が 54314 側で出る）。
      `check` と `test` の所要秒数、test_leak の 1 サーバー所要を PROGRESS に書く
  - 対象: `src/pq/connection.mojo`, `src/pq/result.mojo`, `tests/test_leak.mojo`, `tests/run_tests.sh`, `tests/final_check.sh`
  - 依存: なし
  - 並列サブ作業:
    - A: docstring 3 件 + `test_leak.mojo` の docstring 書き換え（数値は親が (f) で確定して最後に直す）（対象: `src/pq/connection.mojo`, `src/pq/result.mojo`, `tests/test_leak.mojo` の docstring 部分のみ。コードは触らない）
    - B: `run_tests.sh` の `mojo build` 分岐 + `PQ_TEST_LEAK_SERVERS` / `final_check.sh` の 1/6・5/6・6/6 段（対象: `tests/run_tests.sh`, `tests/final_check.sh`）
    - 親: (f) の実測と `TOLERANCE_PAGES` の決定、(g) の陽性対照、(d) の fmt 陽性対照、(h)

- [ ] T2: 基盤 — `_ffi` 3 本（53 本）+ `PgErrorKind.USAGE` + `Result.command_tag()` + `Connection._take_result` 抽出 + `encode_binary.mojo`
  - 完了基準:
    - (a) `src/pq/_ffi/functions.mojo` の「result inspection」節に **決めた事項 2 の表**どおり 3 フィールド + `__init__` の `_dl_sym` 3 行（`# libpq-fe.h:600 / 607 / 608`）。
      `tests/test_ffi.mojo`: `_symbol_names()` に `"PQcmdStatus"`, `"PQnparams"`, `"PQparamtype"` を足し `assert_equal(len(names), 53)`、関数名を `test_all_symbols_present` に改名。追従先チェックリスト 1 行目の 3 コマンドが 53 / 53 / 0
    - (b) `src/pq/errors.mojo`: `comptime USAGE = Self(5)`（docstring: 「The caller misused the `pq` API. Detected client-side; nothing was sent to the server, so `sqlstate` and the other diagnostics are empty.」）、`write_to` に `"Usage"`、`errors.mojo:3` / `:13` の「five」→「six」+ 一覧に `USAGE` を追加。
      `src/pq/__init__.mojo:36-47` の `## PgErrorKind` を「exactly six」にして `USAGE` (`Usage`) の箇条書きを足す。
      `tests/test_errors.mojo` に追加: `PgErrorKind.USAGE.value == 5`、`String(PgErrorKind.USAGE) == "Usage"`（`String(PgError(PgErrorKind.USAGE, "m"))` に `kind=Usage` を含む）、`PgErrorKind.USAGE != PgErrorKind.TYPE_MISMATCH`
    - (c) `src/pq/result.mojo`: `command_tag(self) -> String`（`String(unsafe_from_utf8_ptr=self._pq[].PQcmdStatus(self._res))`。NULL にはならない。prepare / describe の結果では空文字。docstring に J5〜J7 の例 `SELECT 1` / `UPDATE 0` / `CREATE TABLE`）。
      `tests/test_result.mojo` に追加: `SELECT 1` → `"SELECT 1"`、`CREATE TEMP TABLE pq_p2_tag(x int)` → `"CREATE TABLE"`、`INSERT INTO pq_p2_tag VALUES (1),(2)` → `"INSERT 0 2"`、`UPDATE pq_p2_tag SET x = 0 WHERE false` → `"UPDATE 0"`
    - (d) `src/pq/connection.mojo`: `_take_result(self, res: PGresultPtr) raises PgError -> Result` に `connection.mojo:251-304`（NULL → CONNECTION、TUPLES_OK / COMMAND_OK → `Result`、EMPTY_QUERY → `PQclear` + `SERVER "empty query"`、それ以外 → 診断コピー → `PQclear` → sqlstate 空 かつ `CONNECTION_BAD` なら CONNECTION）を**そのまま移す**。
      `execute(sql)` は `_reject_nul` → `PQexec` → `_ = sql^` → `return self._take_result(res)` の 4 行。docstring に「`execute(sql, params)` / `PreparedStatement.execute` / `Transaction` の各コマンドも同じ `_take_result` を通る」。挙動変更なし: `tests/test_connection.mojo` の 28 件が無変更で PASS
    - (e) `src/pq/encode_binary.mojo`（決めた事項 8）: `encode_bool(v: Bool) -> List[UInt8]`（1 byte: 1 / 0）、`encode_int16(v: Int16)`（2 byte BE）、`encode_int32(v: Int32)`（4）、`encode_int64(v: Int64)`（8）、
      `encode_float32(v: Float32)`（`bitcast[DType.uint32, 1](v)` → 4 byte BE）、`encode_float64(v: Float64)`（`bitcast[DType.uint64, 1](v)` → 8）。実装はシフト `(v >> (8*(n-1-i))) & 0xFF`（`scratch/turn-001-probe-encode.mojo:15-20` の `be_bytes`。ホストのエンディアン非依存）。
      モジュール docstring に「Phase 3 の `decode_binary` はこの逆。関数名は `encode_<pgtype>` / `decode_<pgtype>` で対にする」
    - (f) `tests/test_encode_binary.mojo`（DB 不要）: RESEARCH §2.2 probe-encode の実測値をそのまま期待値に — `encode_int16(-32768) == [0x80, 0x00]`、`encode_int16(32767) == [0x7f, 0xff]`、`encode_int32(-1)` が 0xff ×4、`encode_int32(2147483647) == [0x7f, 0xff, 0xff, 0xff]`、
      `encode_int64(Int64.MIN) == [0x80, 0, 0, 0, 0, 0, 0, 0]`、`encode_int64(-1)` が 0xff ×8、`encode_int64(42)` が `[0,0,0,0,0,0,0,0x2a]`、`encode_bool(True) == [1]` / `False == [0]`、
      `encode_float32(1.5) == [0x3f, 0xc0, 0, 0]`、`encode_float32(NaN) == [0x7f, 0xc0, 0, 0]`（`Float32(0.0) / Float32(0.0)`）、`+inf == [0x7f, 0x80, 0, 0]`、`-inf == [0xff, 0x80, 0, 0]`、
      `encode_float64(-0.0) == [0x80, 0, 0, 0, 0, 0, 0, 0]`（`-Float64(0.0)`）、`encode_float64(NaN) == [0x7f, 0xf8, 0, 0, 0, 0, 0, 0]`、`encode_float64(1.5) == [0x3f, 0xf8, 0, 0, 0, 0, 0, 0]`。各関数の `len` が 1 / 2 / 4 / 8 / 4 / 8
    - (g) `pixi run test` 両サーバー PASS（test_ffi 53 / test_errors / test_result / test_encode_binary）、`pixi run package` 警告ゼロ、`pixi run check` 6/6（作業木のまま）
  - 対象: `src/pq/_ffi/functions.mojo`, `tests/test_ffi.mojo`, `src/pq/errors.mojo`, `src/pq/__init__.mojo`, `tests/test_errors.mojo`, `src/pq/result.mojo`, `tests/test_result.mojo`, `src/pq/connection.mojo`, `src/pq/encode_binary.mojo`, `tests/test_encode_binary.mojo`
  - 依存: T1（`check` を作業木で回せること）
  - 並列サブ作業:
    - A: `_ffi` 3 本 + `test_ffi.mojo`（対象: `src/pq/_ffi/functions.mojo`, `tests/test_ffi.mojo`。契約: 決めた事項 2 の表の thin 型をそのまま）
    - B: `USAGE` + docstring「five → six」+ `test_errors.mojo`（対象: `src/pq/errors.mojo`, `src/pq/__init__.mojo`, `tests/test_errors.mojo`）
    - C: `encode_binary.mojo` + `test_encode_binary.mojo`（対象: `src/pq/encode_binary.mojo`, `tests/test_encode_binary.mojo`。契約: 決めた事項 8 のシグネチャ、期待値は (f)）
    - D: `Result.command_tag()` + `test_result.mojo` 追記 + `Connection._take_result` 抽出（対象: `src/pq/result.mojo`, `tests/test_result.mojo`, `src/pq/connection.mojo`）

- [ ] T3: `params.mojo`（`Param` + `_ParamBuffers`）+ `Connection.execute(sql, params)` + `tests/test_params.mojo`
  - 完了基準:
    - (a) `src/pq/params.mojo`: **決めた事項 4** の `Param`（`@implicit` 構築 19 本 + `Param.null()` / `Param.null(oid)`、`oid()` / `is_null()` / `is_binary()`）と **決めた事項 5** の `_ParamBuffers`（`PQexecParams` / `PQexecPrepared` 用の types / values / lengths / formats。
      `lengths` / `formats` は **`List[c_int]`**（P3）、各 List に末尾ダミー 1 要素、テキストは NUL 付きバイト列、String パラメータに NUL があれば **`PgError(USAGE, "embedded NUL byte in parameter $N")`**（N は 1 始まり。P4）。
      `OID_*` は `pq.decode_text` から import（REQ §6-4）
    - (b) `src/pq/connection.mojo`: `execute(self, var sql: String, params: List[Param]) raises PgError -> Result`（決めた事項 6）。docstring に「params が空でも `PQexecParams`。**単一文のみ**（複数文は 42601）。`$1`〜`$n`。送信形式の表（REQ §4.1）。
      `String` は OID 0 なので `SELECT $1` は text、`SELECT $1 + 1` は int4 に推論される（A2 / L12）。`Int` は int8 で int4 列へは assignment cast で入る（B1）。`result_format` は常にテキスト（Phase 3 で引数化）」。
      `src/pq/__init__.mojo` に `from .params import Param` を足す（docstring の表は T7）
    - (c) `tests/test_params.mojo`（PQ_TEST_CONNINFO 必須。`CREATE TEMP TABLE pq_p2_*` で自己完結）に少なくとも:
      1. **全型往復（REQ §5.1）**: `CREATE TEMP TABLE pq_p2_types(b bool, i2 int2, i4 int4, i8 int8, n int8, f4 float4, f8 float8, t text, by bytea, z int4)` →
         `execute("INSERT INTO pq_p2_types VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)", [True, Int16(-32768), Int32(2147483647), Int64.MIN, Int(42), Float32(1.5), Float64(-2.5), "héllo", <List[UInt8] [0,1,0,255]>, Param.null()])` が `affected_rows() == 1` / `command_tag() == "INSERT 0 1"` →
         `SELECT * FROM pq_p2_types` を `get[Bool](0)` … `get[List[UInt8]](8)` で一致、`is_null(9)`、`column_type_oid` が 16/21/23/20/20/700/701/25/17/23
      2. **SQL インジェクション（REQ §5.1 / §5.1a、テキスト経路）**: `CREATE TEMP TABLE pq_p2_inj(t text)` → `execute("INSERT INTO pq_p2_inj VALUES ($1)", ["'; DROP TABLE pq_p2_inj; --"])` → `SELECT count(*) FROM pq_p2_inj` = 1、`SELECT t FROM pq_p2_inj` が原文と一致（テーブルが残っている = 2 つ目の SELECT が通る）
      3. **境界値（REQ §5.1a、`SELECT $1::<type>`）**: Int16 -32768 / 32767 / 0 / -1；Int32 -2147483648 / 2147483647；Int64 `Int64.MIN` / `Int64.MAX`；Int `Int.MIN` / `Int.MAX`（`get[Int]`）；
         Float32 1.5 / NaN（`isnan`）/ +inf / -inf（`isinf` + 符号）/ **-0.0**（`bitcast[DType.uint32, 1](get[Float32]) == 0x80000000`。P17）；Float64 同 4 種（-0.0 は `0x8000000000000000`）；
         空 bytea → `len == 0`；NUL 入り bytea `[0x61, 0, 0x62]` → 3 byte 一致（K2）；空文字 → `""`；**64 KiB の text と 64 KiB の bytea を同じ文で**（`SELECT $1::text, $2::bytea`）→ 長さと内容が一致（P5）
      4. **NULL（D14）**: `Param.null()` を `SELECT $1::int4` → `is_null(0)`；`Param.null(23)` を `SELECT $1` → `column_type_oid(0) == 23`（A4）；`Param.null()` を `SELECT $1` → OID 25（A3。PG14 / 17 で 42P18 にはならない）；
         `var none: Optional[Int] = None` を `SELECT $1` → NULL かつ OID 20；`Optional[Int](7)` → 7；`Optional[String]` の Some / None；`Optional[Bool](None)` → OID 16
      5. **型推論（P22）**: `SELECT $1` に `"hello"` → OID 25 かつ値一致；`SELECT $1 + 1` に `"7"` → `get[Int32] == 8`（L12）；`SELECT $1` に `Int(1)` → OID 20（L10）
      6. **型不一致（P18。REQ §5.1a の題材差し替え、決めた事項 14）**: `CREATE TEMP TABLE pq_p2_i4(x int4)`；`[True]` → `kind == SERVER` かつ `sqlstate != ""`（実測 42804、L1）；`[Int(3000000000)]` → sqlstate `"22003"`（L4）；`[Int(5)]` は **成功**（B1、assignment cast）を正として固定
      7. **個数不一致はサーバー任せ（REQ §4.2）**: `execute("SELECT $1::int4, $2::int4", [1])` → `SERVER`、sqlstate `"08P01"`、直後 `execute("SELECT 1")` が通り `status() == CONNECTION_OK`（C1 / C2）
      8. **空 SQL / 複数文（P8）**: `execute("", [])` → `SERVER`, message `"empty query"`（C5）；`execute("SELECT 1; SELECT 2", [])` → `42601`（C3）；`execute("SELECT 1;", [])` は成功（C4）
      9. **NUL（P4 / 決めた事項 20）**: `execute("SELECT $1", ["ab" + chr(0) + "cd"])` → `kind == USAGE`、message `"embedded NUL byte in parameter $1"`、sqlstate 空、直後 `execute("SELECT 1")` が通る；`execute("SELECT 1" + chr(0) + "x", [])` → `TYPE_MISMATCH` `"embedded NUL byte in sql"`
      10. **12 パラメータ混在（P3、RESEARCH A1 そのまま）**: `SELECT $1,$2,...,$12` に bool / Int16(-32768) / Int32(2147483647) / Int64.MIN / Float32 NaN / Float64 -0.0 / text `'; DROP TABLE x; --` / bytea `[0,1,0,255]` / `Param.null()` を `$9::int4` / 空 bytea / 空 text / Float64 +inf →
          OID 16/21/23/20/700/701/25/17/23/17/25/701 と各値（2 個目以降のバイナリ長がずれていないことの検査）
      11. **aborted tx 内（H3）**: `execute("BEGIN")` → `execute("SELEC")` 失敗 → `execute("SELECT $1", [1])` → `25P02` → `execute("ROLLBACK")`
      12. **`Param` の構築（DB 不要、同ファイル先頭）**: `Param.null().oid() == 0` / `is_null()`、`Param.null(23).oid() == 23`、`Param(Int(1)).oid() == 20` / `is_binary()`、`Param(Int16(1)).oid() == 21`、`Param(Float32(1)).oid() == 700`、`Param("a").oid() == 0` / `not is_binary()` / `not is_null()`、
          `Param(<List[UInt8]>).oid() == 17` / `is_binary()`、`Param(Optional[Int32](None)).oid() == 23` / `is_null()`、`Param(Optional[String](None)).oid() == 0`；リスト literal `var ps: List[Param] = [1, "a", 1.5, True, Param.null()]` が `len == 5` で各 OID 20 / 0 / 701 / 16 / 0
    - (d) `pixi run test` 両サーバー PASS、`pixi run package` 警告ゼロ、`pixi run check` 6/6
  - 対象: `src/pq/params.mojo`, `src/pq/connection.mojo`, `src/pq/__init__.mojo`, `tests/test_params.mojo`
  - 依存: T2
  - 並列サブ作業:
    - A: `params.mojo`（対象: `src/pq/params.mojo`。契約: 決めた事項 4 / 5 を字義どおり。`encode_binary` の関数を使う）
    - B: `Connection.execute(sql, params)` + `__init__.mojo` の 1 行（対象: `src/pq/connection.mojo`, `src/pq/__init__.mojo`。契約: 決めた事項 5 の `_ParamBuffers` アクセサ名と 6 の手順）
    - C: `tests/test_params.mojo` を (c) の箇条書きから独立に書く（対象: `tests/test_params.mojo`。契約: `from pq.params import Param`、エラー kind は上の各項目どおり）

- [ ] T4: `prepared.mojo`（`PreparedStatement[origin]`）+ `Connection.prepare` + 接続ごとの連番 + `tests/test_prepared.mojo`
  - 完了基準:
    - (a) `src/pq/prepared.mojo` と `Connection.prepare(ref self, var sql: String, param_types: List[UInt32] = List[UInt32]()) raises PgError -> PreparedStatement[origin_of(self)]` を **決めた事項 9 / 10** どおり。
      `Connection` に `var _stmt_counter: List[Int]`（`__init__` で `[0]`）と `_next_stmt_name(self) -> String`（`pq_stmt_N`。不変 `self` からの更新は `MutUntrackedOrigin` キャスト、plan プローブ (4)）。
      `src/pq/__init__.mojo` に `from .prepared import PreparedStatement`
    - (b) `tests/test_prepared.mojo` に少なくとも:
      1. `prepare("SELECT $1::int4 + $2::int4, $3")` → `name() == "pq_stmt_1"`、`param_count() == 3`、`param_type_oid(0) == 23` / `(1) == 23` / `(2) == OID_TEXT`（`from pq.decode_text import OID_TEXT`。D2 の実測 25）、`param_type_oid(3)` / `(-1)` → `TYPE_MISMATCH`（message `parameter index 3 out of range (0..2)`。P20）；
         `execute([1, 2, "x"])` → `get[Int32](0) == 3`、`get[String](1) == "x"`（D7）；同じ接続で 2 本目を `prepare` → `"pq_stmt_2"`；**別の `Connection` を開くと最初が `"pq_stmt_1"`**（接続ごとのカウンタ。P9）
      2. **個数不一致はローカル検査（D15）**: `execute([1])` → `kind == USAGE`、message に `3` と `1` を含む、sqlstate 空。`execute("BEGIN")` の中で同じことをしても `transaction_status() == PQTRANS_INTRANS` のまま（サーバーに届けば 08P01 で abort する。C1 と対照）→ `ROLLBACK`
      3. **`__deinit__` の DEALLOCATE と ASAP（P2）**: `var stmt = prepare(...)`; `var name = stmt.name()`; `execute("SELECT count(*) FROM pg_prepared_statements WHERE name = $1", [name])` が **1**（この行より後に `stmt` を使う行を置く）→ `_ = stmt^` → 同じ count が **0**
      4. **26000 経路（P19 / 決めた事項 14）**: `prepare` → `conn.execute("DEALLOCATE " + stmt.name())` → `stmt.execute([...])` → `kind == SERVER`, sqlstate `"26000"` → `_ = stmt^` が静かに終わる（テスト PASS、トレースバック無し）→ `conn.execute("SELECT 1")` が通る
      5. **ROLLBACK しても prepared は残る（E1〜E4 / 決めた事項 14）**: `conn.execute("BEGIN")` → `prepare` → `conn.execute("ROLLBACK")` → `stmt.execute(...)` が**成功**
      6. **aborted tx 内の `__deinit__`（P11）**: `BEGIN` → `prepare` → `conn.execute("SELEC")` 失敗 → `_ = stmt^`（DEALLOCATE は 25P02 で失敗、無視）→ `conn.execute("ROLLBACK")` が通る → `pg_prepared_statements` に名前が **残っている（count 1。E14）** → 手動 `DEALLOCATE` で片付ける
      7. **prepare の失敗**: `prepare("SELEC 1")` → `42601`；`prepare("SELECT 1; SELECT 2")` → `42601`（D10）；失敗後に `prepare("SELECT 1")` が通る
      8. **`param_types`（D9）**: `CREATE TEMP TABLE pq_p2_prep(x int4)` → `prepare("INSERT INTO pq_p2_prep VALUES ($1)", [20])` が成功 → `execute([Int(5)])` → `affected_rows() == 1`、`column_count() == 0`（D11 / D12）；`prepare("SELECT $1", [23])` → `param_type_oid(0) == 23` → `execute([Param.null()])` → `is_null(0)`
      9. **型推論**: `prepare("SELECT $1")` → `param_type_oid(0) == 25` → `execute(["x"])` → `"x"`
      10. **NUL**: `execute(["a" + chr(0)])` → `USAGE`（個数検査 → NUL 検査の順）
      11. **100 回の prepare → execute → 破棄**ループ後に `SELECT count(*) FROM pg_prepared_statements` が 0（DEALLOCATE の網羅。10,000 回は T6）
      12. **接続断（I1〜I5）**: `prepare` → `conn.execute("SELECT pg_terminate_backend(pg_backend_pid())")` が raise → `stmt.execute([...])` → `kind == CONNECTION` → `_ = stmt^` が静かに終わる
    - (c) `pixi run test` 両サーバー PASS、`pixi run package` 警告ゼロ、`pixi run check` 6/6
  - 対象: `src/pq/prepared.mojo`, `src/pq/connection.mojo`, `src/pq/__init__.mojo`, `tests/test_prepared.mojo`
  - 依存: T3
  - 並列サブ作業:
    - A: `prepared.mojo` + `Connection.prepare` / `_stmt_counter` / `_next_stmt_name` + `__init__.mojo` の 1 行（対象: `src/pq/prepared.mojo`, `src/pq/connection.mojo`, `src/pq/__init__.mojo`）
    - B: `tests/test_prepared.mojo` を (b) から独立に書く（対象: `tests/test_prepared.mojo`。契約: `from pq.prepared import PreparedStatement`、`PreparedStatement[origin]` と型パラメータをフルに書く、メソッド名と kind は決めた事項 9）

- [ ] T5: `transaction.mojo`（`Transaction[origin]`）+ `Connection.transaction` / `set_rollback_failure_handler` + `tests/test_transaction.mojo` / `tests/test_savepoint.mojo`
  - 完了基準:
    - (a) `src/pq/transaction.mojo` と `Connection` 側の追加を **決めた事項 11 / 12** どおり（`transaction(ref self)`、`set_rollback_failure_handler(mut self, handler: def(PgError) thin)`、`var _rollback_failure_handler: def(PgError) thin` を `__init__` で既定にする）。
      `src/pq/__init__.mojo` に `from .transaction import Transaction`。`Transaction` の docstring に **P1 の規約**（「`Transaction` は最後に使われた文の直後に破棄され、その時点で ROLLBACK が走る。`commit()` / `rollback()` / `_ = tx^` を tx の最後の行に置く。
      `var tx = conn.transaction(); tx.execute(a); conn.execute(b)` の b は tx の外で実行される」）を負の例つきで書く
    - (b) `tests/test_transaction.mojo` に少なくとも（`CREATE TEMP TABLE pq_p2_tx(x int)` を各テストで作る）:
      1. **commit**: `var tx = conn.transaction()` → `transaction_status() == PQTRANS_INTRANS` → `tx.execute("INSERT INTO pq_p2_tx VALUES (1)")` → `tx.commit()` → `IDLE`、count 1 → `tx.commit()` 2 回目 → `USAGE`
      2. **rollback**: INSERT → `tx.rollback()` → count 0 → `tx.rollback()` 2 回目 → `USAGE`；commit 後の `rollback()` も `USAGE`
      3. **commit せずに破棄 → ROLLBACK（REQ §5.1 / §5.1a、P1）**: `var tx = conn.transaction(); tx.execute(INSERT); _ = tx^` → `transaction_status() == PQTRANS_IDLE`、count 0
      4. **ASAP 破棄の固定（P1）**: `var tx = conn.transaction(); tx.execute(INSERT)` の次の行で `conn.execute("SELECT count(*) FROM pq_p2_tx")` が **0** かつ `IDLE`（tx は前の行で破棄済み）。コメントに「Mojo の ASAP 破棄の仕様。docstring の負の例と同じ」
      5. **委譲（D12）**: `tx.execute("INSERT INTO pq_p2_tx VALUES ($1)", [Int32(2)])` → `tx.prepare("SELECT $1::int4")` が `PreparedStatement[...]` を返し `execute([3])` が 3 → `tx.commit()` → count 1；tx 生存中に `conn.execute("SELECT 1")` も通り `INTRANS` のまま
      6. **ネスト禁止（D11 / P13）**: tx 生存中に `conn.transaction()` → `USAGE`（stderr に `WARNING:` が出ないことは `check` 6/6 で判定）；`conn.execute("BEGIN")` → `conn.execute("SELEC")` で INERROR にしてから `conn.transaction()` → `USAGE` → `conn.execute("ROLLBACK")`
      7. **終了後の操作は全部 USAGE**: commit 後に `tx.execute(sql)` / `tx.execute(sql, params)` / `tx.prepare(sql)` / `tx.savepoint("a")` / `tx.rollback_to("a")` / `tx.release("a")` の 6 つ
      8. **aborted 状態の `commit()`（D10 / P12 / REQ §5.1a）**: INSERT → `tx.execute("SELECT 1/0")` が `22012` → `INERROR` → `tx.commit()` → `kind == SERVER`、`sqlstate == ""`、message に `ROLLBACK` を含む → `IDLE` → `conn.execute("SELECT count(*) ...")` が 0 → `tx.rollback()` → `USAGE`（終了済み）
      9. **接続断中の破棄でハンドラが呼ばれる（REQ §5.1a-1 / P15 / 決めた事項 13）**: `setenv("PQ_TEST_ROLLBACK_FAILURE", "", True)` → `conn.set_rollback_failure_handler(_record_rollback_failure)` → `var tx = conn.transaction()` → `conn.execute("SELECT pg_terminate_backend(pg_backend_pid())")` が `CONNECTION` で raise → `_ = tx^` →
         `getenv("PQ_TEST_ROLLBACK_FAILURE")` が `"Connection|"` で始まり `|` の後が非空（I3: `no connection to the server`）
      10. **ハンドラは生成時コピー（D9）**: `set_rollback_failure_handler(_record_as_first)` → `var tx = conn.transaction()` → `set_rollback_failure_handler(_record_as_second)` → terminate → `_ = tx^` → 環境変数が `"first|Connection|..."` で始まる（2 本目のハンドラは呼ばれない）。ハンドラは非キャプチャの `def(PgError)` 2 本で接頭辞だけ違う
      11. **接続断後の `transaction()`（P14 / 決めた事項 14-3）**: terminate 後に `conn.transaction()` → `kind == CONNECTION`（`USAGE` ではない）
      12. 既定ハンドラ: 差し替えない接続で tx を正常に commit / rollback / 破棄しても stderr に何も出ない（`check` 6/6 の `WARNING:` 計数と、`pq: implicit ROLLBACK failed` が `build/final_check.log` に無いこと: `grep -c 'implicit ROLLBACK failed' build/final_check.log` = 0 を T7 で確認）
    - (c) `tests/test_savepoint.mojo` に少なくとも:
      1. **部分取り消し（REQ §5.1）**: INSERT 1 → `tx.savepoint("a")` → INSERT 2 → `tx.rollback_to("a")` → `tx.commit()` → count 1
      2. **識別子エスケープ（G3〜G9）**: `tx.savepoint("sp \"1\"")` → `tx.rollback_to("sp \"1\"")` → `tx.release("sp \"1\"")` が全部通る；大文字混じり `"Sp"` も通る（`escape_identifier` で `"Sp"` が保たれる）
      3. **aborted からの回復（G15〜G18）**: `tx.savepoint("s1")` → `tx.execute("SELECT 1/0")` が `22012` → `INERROR` → `tx.rollback_to("s1")` → `INTRANS` → `tx.execute("SELECT 1")` が通る → `tx.commit()`
      4. **存在しない savepoint（G10 / G11 / P16）**: `tx.rollback_to("nope")` → `SERVER` `3B001` → `INERROR` → `tx.execute("SELECT 1")` → `25P02` → `tx.rollback()` が通る → `IDLE`。`release("nope")` も `3B001`
      5. **空文字（D13）**: `savepoint("")` / `rollback_to("")` / `release("")` → `USAGE`、サーバー状態は `INTRANS` のまま
      6. `release` 後に同名へ `rollback_to` → `3B001`（RELEASE で消える）
    - (d) `pixi run test` 両サーバー PASS、`pixi run package` 警告ゼロ、`pixi run check` 6/6（`WARNING:` 0 件 = ネスト BEGIN / 二重 COMMIT がサーバーに届いていない証拠）
  - 対象: `src/pq/transaction.mojo`, `src/pq/connection.mojo`, `src/pq/__init__.mojo`, `tests/test_transaction.mojo`, `tests/test_savepoint.mojo`
  - 依存: T4
  - 並列サブ作業:
    - A: `transaction.mojo` + `Connection.transaction` / `set_rollback_failure_handler` / 既定ハンドラ + `__init__.mojo` の 1 行（対象: `src/pq/transaction.mojo`, `src/pq/connection.mojo`, `src/pq/__init__.mojo`。契約: 決めた事項 11 / 12）
    - B: `tests/test_transaction.mojo` を (b) から独立に書く（対象: `tests/test_transaction.mojo`。契約: `from pq.transaction import Transaction`、`Transaction[origin]` をフルに書く、ハンドラは非キャプチャ `def(e: PgError)` で `setenv`）
    - C: `tests/test_savepoint.mojo` を (c) から独立に書く（対象: `tests/test_savepoint.mojo`）

- [ ] T6: `tests/test_leak.mojo` に Phase 2 の 4 ループ（params / prepared / tx commit / tx 破棄 ROLLBACK）+ 陽性対照 3 本
  - 完了基準:
    - (a) 各 10,000 回、`MAIN_WARMUP` 1,000、9 サンプル、tolerance は T1 で決めた `TOLERANCE_PAGES`、接続は 1 本を使い回す（connect ループは Phase 1 が持つ）:
      `test_execute_params_does_not_leak`: `conn.execute("SELECT $1::bytea, $2::text", [<64 KiB bytea>, <64 KiB text>])` → 結果を破棄（`_ParamBuffers` と `PGresult` の両方が毎回解放されることを RSS で）；
      `test_prepared_does_not_leak`: `prepare("SELECT repeat('x', 65536) WHERE $1 = 1")` → `execute([Int32(1)])` → 結果と stmt を破棄（prepare / describe / execPrepared / DEALLOCATE の 4 結果）；
      `test_transaction_commit_does_not_leak`: `conn.transaction()` → `tx.execute("SELECT repeat('x', 65536)")` → `tx.commit()`；
      `test_transaction_drop_does_not_leak`: `conn.transaction()` → `tx.execute("SELECT repeat('x', 65536)")` → `_ = tx^`（`__deinit__` の ROLLBACK 経路 = 生の `PQexec` + `PQclear`）
    - (b) 4 ループは成功時もサンプル列を `print`（Phase 1 と同じ `_assert_stable`）。モジュール docstring にループ一覧（12 テスト）と所要の目安を書く
    - (c) **陽性対照**（同じターン、`scratch/turn-NNN-leaksrc-<name>/` に `src/pq` をコピー → `mojo build -I <copy>`。サンプル列を PROGRESS に貼る。PG17 でよい）:
      ① `Result.__deinit__` の `PQclear` を消す → `test_execute_params_does_not_leak` が **FAIL**（connect ループも FAIL するが問わない）；
      ② `PreparedStatement.__deinit__` の DEALLOCATE 結果の `PQclear` を消す → `test_prepared_does_not_leak` が **FAIL**（1 結果 ≈ 数百 B × 10,000 ≈ 数 MB。built binary なら見える）；
      ③ `Transaction.__deinit__` の ROLLBACK 結果の `PQclear` を消す → `test_transaction_drop_does_not_leak` が **FAIL**。
      ②③が tolerance 内に収まって FAIL しない場合は、そのループの payload を `repeat('x', 65536)` から増やすのではなく**反復回数はそのまま**で原因（RSS に出ない量）を PROGRESS に書き、verify に申し送る（「未実証」の申し送りは禁止。実測の数値を貼る）
    - (d) `pixi run test` 両サーバー PASS（test_leak 12 本）、`pixi run check` 6/6。test_leak の所要（1 サーバー）を PROGRESS に書く
  - 対象: `tests/test_leak.mojo`
  - 依存: T5
  - 並列サブ作業: なし（1 ファイル。陽性対照の 3 ビルドは親が順に回す。各ビルド cached 0.9 s）

- [ ] T7: `examples/params.mojo` + `pixi.toml` / `final_check.sh` 4/6 + `src/pq/__init__.mojo` の文書 + 品質仕上げ（docstring 診断 0 / fmt 差分 0 / 警告 0 / `fn` 0 / `check` 6/6 / 追従先チェックリスト照合）
  - 完了基準:
    - (a) `examples/params.mojo`: `from pq import Connection, Param, PgError` のみ（`Transaction` / `PreparedStatement` は `conn.transaction()` / `conn.prepare()` の戻りとして使う。型名を書くなら `from pq import Transaction` を足してよい）。
      `PQ_TEST_CONNINFO`（無ければ 54317 既定）で接続 → `CREATE TEMP TABLE` → `conn.execute(INSERT, [Int32(1), "one"])` → `conn.execute("SELECT ... WHERE id = $1", [Int32(1)])` を `for row in res` で表示 →
      `var tx = conn.transaction()` → `tx.execute(INSERT, params)` → `tx.savepoint("sp")` → `tx.execute(INSERT, params)` → `tx.rollback_to("sp")` → `tx.commit()` → 件数表示（1 行だけ増えている）。
      **P1 の規約どおり tx の最後の行が `tx.commit()`**。`PgError` を `except e` で `print` し `exit(1)`。`pixi.toml` に `example-params = "mojo run -I src examples/params.mojo"`、`tests/final_check.sh` 4/6 段を `examples/basic.mojo` と `examples/params.mojo` の 2 本に（見出し `4/6 examples`）
    - (b) `src/pq/__init__.mojo` docstring: 「Phase 2 adds `params`, `prepared`, `transaction`」、再エクスポート一覧に `Param` / `PreparedStatement` / `Transaction`、`## Parameters` 節に REQ §4.1 の送信形式表（Mojo 型 / 送信形式 / OID / 備考）と `conn.execute(sql, [1, "a", Param.null()])` の例、
      `## Transactions` 節に P1 の規約 1 段落、`## PgErrorKind` に `USAGE`。`pixi run package` 警告ゼロ
    - (c) 文書照合（`grep` で確認して PROGRESS に書く）: `Transaction` docstring に「last use」または「ASAP」と負の例（`grep -c 'conn.execute(b)' src/pq/transaction.mojo` ≥ 1 相当）、`execute(sql, params)` docstring に「single statement」（D13）、`set_rollback_failure_handler` docstring に「copied when `transaction()`」（D9）、
      `PreparedStatement` docstring に「ROLLBACK しても文は残るが、tx 内 DDL の巻き戻し後の `execute` はサーバーエラーになり得る」（RESEARCH §3-8）、`commit()` docstring に「`ROLLBACK` command tag → `PgError`」（D10）、`__deinit__` の docstring に `__deinit__` と書き `__del__` と書かない（`grep -rn '__del__' src/pq` = 0）
    - (d) 品質（Phase 1 T8 と同じ）: docstring 診断 0（追従先チェックリスト 3 行目のコマンド）、`pixi run fmt` 後に差分なし（T1 の 1/6 段が判定）、`grep -rnE '^[[:space:]]*fn ' src tests examples hello.mojo` が 0 件、`grep -c 'implicit ROLLBACK failed' build/final_check.log` = 0、
      `pixi run check` 6/6 PASS（`warning:` / `WARNING:` 0 件）。各段の所要を PROGRESS に
    - (e) 追従先チェックリストの全行を素のシェルで実行し、コマンドと結果を PROGRESS に書く（53 本 / `five` 0 件 / 再エクスポート 3 型 / examples 2 本 / `PQfreemem` 2 行・`PQexec(` 4 行 / `_reject_nul` / `PQ_TEST_LEAK_SERVERS` / leak 12 本）
    - (f) `HANDOFF.md` と REQUIREMENTS / DECISIONS / RESEARCH は触らない（PLAN 訂正は本 PLAN の該当タスクに「PLAN 訂正（turn N 実測）」で追記する。Phase 1 の流儀）
  - 対象: `examples/params.mojo`, `pixi.toml`, `tests/final_check.sh`, `src/pq/__init__.mojo`、docstring のみの修正は `src/pq/*.mojo` 任意（挙動変更なし）
  - 依存: T6
  - 並列サブ作業:
    - A: `examples/params.mojo` + `pixi.toml` + `final_check.sh` 4/6（対象: `examples/params.mojo`, `pixi.toml`, `tests/final_check.sh`）
    - B: `src/pq/__init__.mojo` の docstring + (c) の docstring 照合と不足分の追記（対象: `src/pq/__init__.mojo`, 必要なら `src/pq/{transaction,prepared,connection}.mojo` の docstring 行のみ）
    - 親: (d) / (e) の機械判定（`fmt` は親が統合後に 1 回だけ）

## 決めた事項

1. **ファイル構成**（REQ §2、HANDOFF.md:96-108 の `params.mojo`）: 新規 `src/pq/{encode_binary,params,prepared,transaction}.mojo`、変更 `src/pq/{connection,result,errors,__init__}.mojo` と `src/pq/_ffi/functions.mojo`。
   `Connection.transaction()` / `prepare()` は `connection.mojo` 内（Mojo 1.1.0 に `extension` は無く、他ファイルからメソッドを足せない — Phase 1 PLAN 決めた事項 5）。`transaction.mojo` / `prepared.mojo` は `from .connection import Connection` し、`connection.mojo` は
   `from .transaction import Transaction, _default_rollback_failure_handler` / `from .prepared import PreparedStatement` する**循環 import**（plan プローブ (1) で動作確認。`scratch/turn-002-cyc/`）。
   テスト新規 `tests/{test_encode_binary,test_params,test_prepared,test_transaction,test_savepoint}.mojo`、変更 `tests/{test_ffi,test_errors,test_result,test_leak}.mojo`、`tests/{run_tests,final_check}.sh`、`examples/params.mojo`、`pixi.toml`
2. **`_ffi` 追加 3 本**（REQ §4.6、RESEARCH §7。ヘッダ `.pixi/envs/default/include/libpq-fe.h` の行は plan 時に `grep -n` で再確認: 600 / 607 / 608）。`functions.mojo` の「result inspection」節（`:80-115`）に追加、`_dl_sym` も同節の末尾（`PQclear` の後）:

   | 関数 | C プロトタイプ（libpq-fe.h 行） | Mojo thin 型 | 備考 |
   |---|---|---|---|
   | `PQcmdStatus` | `char *PQcmdStatus(PGresult *res);`（600） | `def(PGresultPtr) thin abi("C") -> CStr` | NULL にならない（`PQcmdTuples` と同じ扱い）。空文字はあり得る（prepare / describe の結果、D1） |
   | `PQnparams` | `int PQnparams(const PGresult *res);`（607） | `def(PGresultPtr) thin abi("C") -> c_int` | `PQdescribePrepared` の結果以外では 0（P20） |
   | `PQparamtype` | `Oid PQparamtype(const PGresult *res, int param_num);`（608） | `def(PGresultPtr, c_int) thin abi("C") -> UInt32` | `PQftype` と同じ `UInt32` 戻り |

   合計 **53 本**（`grep -c '^    var PQ' src/pq/_ffi/functions.mojo` が plan 時 50）。`tests/test_ffi.mojo:97-102` の関数名を `test_all_symbols_present` に
3. **`PgErrorKind.USAGE = Self(5)`**（REQ §4.5、D11。`errors.mojo:20-37` の並びの末尾）。`write_to` は `"Usage"`。使う場所（この一覧以外で USAGE を投げない。サーバーに**送る前**に検出し、`sqlstate` 等は空）:
   `_ParamBuffers`（String パラメータの埋め込み NUL）/ `PreparedStatement.execute`（個数不一致）/ `Connection.transaction()`（`PQTRANS_IDLE` 以外。ただし 14-3 の例外）/ `Transaction` の終了後の全操作（`commit` / `rollback` / `savepoint` / `rollback_to` / `release` / `execute` ×2 / `prepare`）/ 空の savepoint 名
4. **`Param`**（D5 / D6 / D14、REQ §4.1。雛形 `scratch/turn-001-probe-implicit.mojo:10-120`）: `struct Param(Copyable, Movable)`（`List[Param]` の要素に必要。冗長警告が出るなら `(Copyable)` に落として PROGRESS に書く）。
   値は構築時にエンコード済みで持つ: `var _oid: UInt32`, `var _binary: Bool`, `var _null: Bool`, `var _data: List[UInt8]`（テキストは NUL 無しの生バイト、バイナリは BE バイト列、NULL は空）。
   - `@implicit def __init__(out self, v: Bool)` → OID 16 / `encode_bool`；`Int16` → 21 / `encode_int16`；`Int32` → 23 / `encode_int32`；`Int64` → 20 / `encode_int64`；`Int` → 20 / `encode_int64(Int64(v))`；
     `Float32` → 700 / `encode_float32`；`Float64` → 701 / `encode_float64`；`var v: String` → OID **0**、テキスト、`v.as_bytes()` のコピー；`v: StringLiteral` → 同（`String(v)` 経由）；`var v: List[UInt8]` → 17 / バイナリそのまま（空・NUL 含み可）
   - `@implicit def __init__(out self, v: Optional[T])` を T = Bool / Int16 / Int32 / Int64 / Int / Float32 / Float64 / String / List[UInt8] の **9 本**: Some なら上の経路、None なら `Param.null(<T の OID>)`（String は 0、List[UInt8] は 17）。
     素の `None` リテラルは変換されない（RESEARCH §0.5）ので `Optional[Int](None)` / `var x: Optional[Int] = None` を docstring の例にする。合計 `@implicit` **19 本**（probe は 14 本まで曖昧なしを確認。残り 6 本の Optional は未プローブ — メモ参照）
   - `@staticmethod def null() -> Param`（OID 0）/ `@staticmethod def null(oid: UInt32) -> Param`（型付き NULL）
   - 公開アクセサ: `oid(self) -> UInt32` / `is_null(self) -> Bool` / `is_binary(self) -> Bool`（テストと docstring 用。値を返すアクセサは作らない — 資格情報が入り得る値を外に出さない）
   - OID 定数は `from pq.decode_text import OID_BOOL, OID_BYTEA, OID_INT8, OID_INT2, OID_INT4, OID_FLOAT4, OID_FLOAT8` を使う（REQ §6-4。`OID_TEXT` は T4 テスト、`OID_VARCHAR` / `OID_BPCHAR` / `OID_NAME` は宣言のまま残す — 「削除しない」が §6-4 の主旨で、verify は未使用を差し戻さない）
5. **`_ParamBuffers(Movable)`**（RESEARCH §3-6、雛形 `scratch/turn-001-probe-libpq.mojo:142-223` の `Params` / `exec_params`）: `def __init__(out self, params: List[Param]) raises PgError` で
   `types: List[UInt32]`（OID）、`bufs: List[List[UInt8]]`（テキストは **末尾に NUL を 1 byte 足したコピー**、バイナリはそのまま、NULL は空）、`lengths: List[c_int]`（バイナリは byte 長、テキスト / NULL は 0）、`formats: List[c_int]`（1 / 0）、
   最後に `values: List[Int]`（`bufs[i].unsafe_ptr()` のアドレス、NULL は 0。**bufs を全部作り終えてから**取る — 再確保でアドレスが変わらないように）。各 List に**末尾ダミー 1 要素**（空 params でも非 NULL の有効ポインタ。RESEARCH §2.2）。
   String パラメータの `_data` に 0 があれば `PgError(USAGE, "embedded NUL byte in parameter $N")`（N は 1 始まり、値は入れない。P4 / K1）。
   アクセサ: `count() -> Int`、`types_ptr() -> OidPtr`、`values_ptr() -> CStrArray`、`lengths_ptr() -> IntPtr`、`formats_ptr() -> IntPtr`（`unsafe_from_address=Int(list.unsafe_ptr())`。`_ffi/types.mojo:10-16` のエイリアス）。
   呼び出し側は libpq 呼び出しの**後**に `_ = buffers^` を置く（P5。Phase 1 PLAN 決めた事項 13 と同じ流儀）
6. **`Connection.execute(self, var sql: String, params: List[Param]) raises PgError -> Result`**（REQ §4.2、D13）: `_reject_nul(sql, "sql")`（TYPE_MISMATCH。Phase 1 E10 の規則）→ `var buffers = _ParamBuffers(params)`（USAGE はここ）→
   `PQexecParams(self._conn, CStr(sql), c_int(buffers.count()), buffers.types_ptr(), buffers.values_ptr(), buffers.lengths_ptr(), buffers.formats_ptr(), c_int(0))` → `_ = buffers^` → `_ = sql^` → `return self._take_result(res)`。`resultFormat` は定数 0（REQ §4.1）
7. **`Connection._take_result(self, res: PGresultPtr) raises PgError -> Result`**（REQ §4.2「経路を共有」、P8）: 現 `connection.mojo:251-304` を無変更で移す（Phase 1 PLAN 決めた事項 6 の表がそのまま仕様）。
   呼ぶ場所: `execute(sql)` / `execute(sql, params)` / `prepare`（PQprepare と PQdescribePrepared の 2 結果）/ `PreparedStatement.execute` / `Transaction` の BEGIN・COMMIT・ROLLBACK・SAVEPOINT 系（すべて `conn.execute(sql)` 経由）。
   **`Result.command_tag(self) -> String`** を公開メソッドとして追加（`PQcmdStatus` を `String(unsafe_from_utf8_ptr=...)` で即コピー。`affected_rows` の隣。`Transaction.commit()` の判定に使う。REQ にない公開 API だが `affected_rows()` と対で自然、D10 の実装に必要）
8. **`encode_binary.mojo`**（REQ §4.1 末尾、D6 付随、RESEARCH §3-7）: `encode_bool(v: Bool) -> List[UInt8]` / `encode_int16(v: Int16)` / `encode_int32(v: Int32)` / `encode_int64(v: Int64)` / `encode_float32(v: Float32)` / `encode_float64(v: Float64)`、すべて `-> List[UInt8]`（長さ 1 / 2 / 4 / 8 / 4 / 8、network byte order）。
   `Int` 用は作らない（`Param` が `Int64(v)` にして `encode_int64`）。`bitcast` は `from std.memory import bitcast`（probe-encode:9）
9. **`PreparedStatement[origin: ImmOrigin](Movable)`**（REQ §4.3、D7 / D15、雛形 `probe-libpq.mojo:225-287` の `exec_prepared` / `prepare` / `describe`）:
   フィールド `_conn: Pointer[Connection, Self.origin]`, `_name: String`, `_param_types: List[UInt32]`。`Copyable` にしない（`__deinit__` の DEALLOCATE が二重に走る）。
   - `Connection.prepare(ref self, var sql: String, param_types: List[UInt32] = List[UInt32]()) raises PgError -> PreparedStatement[origin_of(self)]`:
     `_reject_nul(sql, "sql")` → `var name = self._next_stmt_name()` → `PQprepare(conn, CStr(name), CStr(sql), c_int(len(param_types)), OidPtr(types のコピー + 末尾ダミー))` → `_ = self._take_result(res)`（失敗はそのまま raise。この時点で文はサーバーに無い）→
     `PQdescribePrepared(conn, CStr(name))` → `var desc = self._take_result(res2)`（**失敗したら `DEALLOCATE <name>` を生の `PQexec` で試み、結果は `PQclear` して無視し、元のエラーを raise**。P10）→ `PQnparams(desc._res)` / `PQparamtype(desc._res, c_int(i))` を `List[UInt32]` に読む → `desc` は `Result` なので自動 `PQclear`
   - `_next_stmt_name(self) -> String`: `var _stmt_counter: List[Int]`（`Connection.__init__` で `[0]`）を `Pointer[Int, MutUntrackedOrigin](unsafe_from_address=Int(self._stmt_counter.unsafe_ptr()))[] += 1` で進めて `String("pq_stmt_", n)`（P9 案 A、plan プローブ (4)。`loader.libpq_ptr` と同じキャスト。規約外の書き込みなのでコメントに理由を書く）。
     失敗した `prepare` でも番号は消費する（単純。名前の再利用で 42P05 を踏まない）
   - `execute(self, params: List[Param]) raises PgError -> Result`: `len(params) != len(self._param_types)` → `PgError(USAGE, 'prepared statement "pq_stmt_N" takes K parameters, got M')` → `_ParamBuffers(params)`（NUL は USAGE）→
     `PQexecPrepared(conn, CStr(name), c_int(n), values, lengths, formats, c_int(0))` → `_ = buffers^` → `self._conn[]._take_result(res)`
   - `param_count(self) -> Int` / `param_type_oid(self, i: Int) raises PgError -> UInt32`（範囲外は `PgError(TYPE_MISMATCH, "parameter index i out of range (0..n-1)")`。`result.mojo:31-44` の `_row_range_error` と同じ文体）/ `name(self) -> String`
   - `__deinit__(deinit self)`: `var sql = "DEALLOCATE " + self._name`（名前は `[a-z0-9_]` のみなのでエスケープ不要）→ 生の `self._conn[]._pq[].PQexec` → 非 NULL なら `PQclear`。状態も結果も見ない（25P02 / 26000 / 接続断すべて無視。D13。フックは呼ばない）。
     `_conn[]._pq` / `_conn[]._conn` を読むため `Connection` のフィールドはパッケージ内から見える前提（Phase 1 の `Row` が `Result._res` を読むのと同じ）
10. **`Transaction[origin: ImmOrigin](Movable)`**（REQ §4.4、D8〜D12、雛形 `scratch/turn-001-probe-tx.mojo:59-84` と plan プローブ `turn-002-cyc/cycpkg/b.mojo`）: フィールド `_conn: Pointer[Connection, Self.origin]`, `_done: Bool`, `_handler: def(PgError) thin`
    - `Connection.transaction(ref self) raises PgError -> Transaction[origin_of(self)]`: ① `PQstatus(conn) == CONNECTION_BAD` → `PgError(CONNECTION, PQerrorMessage)`（14-3）；② `PQtransactionStatus(conn) != PQTRANS_IDLE` → `PgError(USAGE, "transaction() requires an idle connection (transaction status N)")`；
      ③ `_ = self.execute("BEGIN")` → `Transaction[origin_of(self)](Pointer(to=self), self._rollback_failure_handler)`
    - `_check_open(self) raises PgError`: `_done` なら `PgError(USAGE, "transaction already ended")`。`commit` / `rollback` / savepoint 系 / `execute` ×2 / `prepare` の先頭で呼ぶ
    - `commit(mut self) raises PgError`: `_check_open()` → **`self._done = True` を先に**（送信失敗でも二重送信しない。RESEARCH §3-1）→ `var res = self._conn[].execute("COMMIT")` → `res.command_tag() == "ROLLBACK"` なら `PgError(SERVER, "COMMIT resulted in ROLLBACK: the transaction was aborted", sqlstate="")`（D10 / P12 / E12）
    - `rollback(mut self) raises PgError`: `_check_open()` → `_done = True` → `_ = self._conn[].execute("ROLLBACK")`
    - `savepoint(self, var name: String)` / `rollback_to(self, var name: String)` / `release(self, var name: String)`（すべて `raises PgError`）: `_check_open()` → `name == ""` → `PgError(USAGE, "savepoint name must not be empty")` → `var ident = self._conn[].escape_identifier(name^)`（NUL は TYPE_MISMATCH のまま）→
      `"SAVEPOINT " + ident` / `"ROLLBACK TO SAVEPOINT " + ident` / `"RELEASE SAVEPOINT " + ident` を `self._conn[].execute(...)`。cmd tag は見ない（P24）。存在しない名前の 3B001 はサーバー任せ（P16。docstring に「以降は `rollback()` だけが通る」）
    - `execute(self, var sql: String) raises PgError -> Result` / `execute(self, var sql: String, params: List[Param]) raises PgError -> Result` / `prepare(self, var sql: String, param_types: List[UInt32] = List[UInt32]()) raises PgError -> PreparedStatement[Self.origin]`: `_check_open()` → `self._conn[]` へ委譲（D12）
    - `__deinit__(deinit self)`: `_done` なら何もしない。そうでなければ生の `PQexec(conn, "ROLLBACK")`: NULL → `PgError(CONNECTION, PQerrorMessage(conn))`；`PQresultStatus != PGRES_COMMAND_OK` → 診断を `_error_field` でコピー（`connection.mojo:46-64`）→ `PQclear` → `sqlstate == ""` かつ `CONNECTION_BAD` なら CONNECTION、それ以外 SERVER；COMMAND_OK → `PQclear` のみ。
      エラーがあれば `self._handler(err)`。**`__deinit__` から投げない**（P15、I3）
11. **ハンドラ**（D8 / D9、REQ §4.4 末尾）: 型 `def(PgError) thin`。既定 `_default_rollback_failure_handler(e: PgError)` は `transaction.mojo` のモジュール関数で `print("pq: implicit ROLLBACK failed: ", e.message, sep="", file=stderr)`（`from std.sys import stderr`。plan プローブ (2)）。
    `Connection` に `var _rollback_failure_handler: def(PgError) thin`（`__init__` で既定を代入）と `set_rollback_failure_handler(mut self, handler: def(PgError) thin)`（docstring: 「`transaction()` 生成時にコピーされる。生成後の差し替えは既存の `Transaction` に反映されない」）
12. **テストがハンドラ呼び出しを観測する手段**（P15、RESEARCH §5-4）: 非キャプチャ `def _record_rollback_failure(e: PgError)` が `_ = setenv("PQ_TEST_ROLLBACK_FAILURE", String(e.kind) + "|" + e.message, True)` を実行（`from std.os import setenv, getenv`。`tests/test_loader_fail.mojo:14,59` と plan プローブ (3) で動作確認）。
    テストは事前に空文字を `setenv` し、破棄後に `getenv` を読む。`_Global` セルは使わない（1 行で済む `setenv` を優先。子プロセスは無いので漏れない）
13. **ASAP 破棄の規約**（P1 / P2、RESEARCH §0 結論 4）: `Transaction` / `PreparedStatement` を使うテスト・example・docstring は「最後に使う行」を明示する — `commit()` / `rollback()` / `_ = tx^` / `_ = stmt^` を最後に置き、その**後**に `conn.execute` で状態を確認する。
    `_ = x^` は破棄ではなく「ここまで生かす」マーカー（RESEARCH §0.5）。T5 (b)-4 がこの挙動自体をテストで固定する
14. **REQ の読み替え（RESEARCH §5。REQ 本文は変更しない。verify はこの項を正として判定する）**:
    - 14-1 **prepared × ROLLBACK**（REQ §4.3 末尾 / §5.1a 4 項目目）: PG14 / PG17 とも PREPARE は非トランザクショナルで、tx 内で `prepare` して `ROLLBACK` しても文は残り `execute` は**成功する**（E1〜E4、公式 ML）。
      テストはこの成功を固定し（T4 (b)-5）、REQ が求める「26000 → `kind=Server`、破棄時の DEALLOCATE 失敗は無視されトレースバックを出さない」は**ユーザーが `DEALLOCATE <stmt.name()>` を手で送った後の `stmt.execute()`**で固定する（T4 (b)-4）。D16 の意図（その状況での堅牢性）はこれで満たす
    - 14-2 **型不一致の題材**（REQ §4.2 / §5.1a 3 項目目）: 「int4 列に `Int`（int8）→ 42804 等」は不成立（B1: assignment cast で成功）。題材を **`Bool` → int4 列（42804、L1）** と **`Int(3000000000)` → int4 列（22003、L4）** に差し替え、`Int(5)` → int4 列の成功も固定する（T3 (c)-6）。「sqlstate 非空を assert」の方針は維持
    - 14-3 **接続断中の `transaction()`**（REQ §4.4「IDLE でなければ USAGE」）: `PQstatus == CONNECTION_BAD`（`PQtransactionStatus` は `PQTRANS_UNKNOWN`）を先に見て `kind=CONNECTION` にする（P14、I5）。REQ §4.5 の `USAGE` は「クライアント側で検出した **API 誤用**」であり、死んだ接続は誤用ではないので定義に沿った解釈。それ以外の非 IDLE（INTRANS / INERROR / ACTIVE）は USAGE
    - 14-4 **`__del__`** は Mojo 1.1.0 の `__deinit__(deinit self)` と読む。docstring では `__deinit__` と書く
    - 14-5 **型付き NULL が要る文脈**: `SELECT $1` は OID 0 の NULL でも通る（A3）。`Param.null(oid)` の docstring の例は `SELECT $1 + 1` / `INSERT ... VALUES ($1)` ではなく `SELECT $1::int4` との OID 一致（A4）で示す
15. **リーク測定**（D4、REQ §5.3、RESEARCH §2.3）: `tests/run_tests.sh` が `mojo build -I src tests/test_leak.mojo -o build/test_leak` を 1 回行い、各サーバーで `build/test_leak` を実行。環境変数 **`PQ_TEST_LEAK_SERVERS`**（leak を回すサーバー数。未設定 = 全部、`final_check.sh` は `1` = 54317 のみ）。
    `TOLERANCE_PAGES` は T1 (f) の手順で 16 か 256 に確定（研究時の built binary は 4 ループとも ±2 ページ、ベースライン 4,084 ページ）。陽性対照は T1 (g)（PQclear / PQfreemem）と T6 (c)（Phase 2 の 3 経路）
16. **fmt 判定**（REQ §6-3、P23）: `build/fmtcheck/` にコピー → `mojo format --quiet` → `diff -r -q`。`git` を使わないので作業木の状態に依存しない。`build/` は gitignore 済み
17. **`final_check.sh` 6/6 は `warning:` と `WARNING:` の両方を数える**（P13）。libpq の既定 notice processor はサーバーの WARNING / NOTICE を stderr に印字するので、USAGE 検査が効いていれば 0 件になる。`PQsetNoticeProcessor` はバインドしない（Phase 2 対象外）
18. **テスト用テーブル**（REQ §7）: すべて `CREATE TEMP TABLE pq_p2_<name>`（セッション限定、両サーバー・並行プロセスで衝突しない）。`tests/fixtures/schema.sql` は変更しない。prepared 名は自動（`pq_stmt_N`）で接続ごとなので衝突しない
19. **メッセージ文言**（USAGE 系。テストが `find` で部分一致を見るので固定）: `embedded NUL byte in parameter $N` / `prepared statement "pq_stmt_N" takes K parameters, got M` / `transaction() requires an idle connection (transaction status N)` / `transaction already ended` / `savepoint name must not be empty` / `COMMIT resulted in ROLLBACK: the transaction was aborted` / `parameter index i out of range (0..n-1)`
20. **NUL の非対称**: `sql` 引数は Phase 1 どおり `_reject_nul(sql, "sql")` → `TYPE_MISMATCH`（E10 の規則を変えない）。`String` パラメータの NUL は REQ §4.1 どおり `USAGE`（「libpq に渡せない引数」ではなく「値として送れないものを送ろうとした API 誤用」）。両方を `__init__.mojo` の `## PgErrorKind` に書く
21. **`List[c_int]`**（P3）: `lengths` / `formats` は `List[c_int]`、`types` は `List[UInt32]`、`values` は `List[Int]`（アドレス）。`List[Int]` を `IntPtr` に渡すと 8 byte ストライドで壊れる
22. **T4 (b)-6 の期待値**（P11 で plan が決めるとされた点）: aborted tx 内で破棄された `PreparedStatement` の文は**サーバーに残る**（DEALLOCATE が 25P02 で無視される。E10 / E14）。テストは `pg_prepared_statements` で count 1 を確認し、手動 `DEALLOCATE` で片付ける
23. **`Connection` の新フィールド**: `_stmt_counter: List[Int]`（9）と `_rollback_failure_handler: def(PgError) thin`（11）。`Connection(Movable)` のまま。`__init__(out self, conn, pq)` の docstring に両方を書く

## メモ

### reflect（`.gsd-lite/reflect/20261015-2308-phase1-sync-text-basic.md`「次回への提案」）の反映

| # | 提案 | 反映 | どこで / 理由 |
|---|---|---|---|
| 1 | 検出力を主張するテストの完了基準に陽性対照を最初から書く | **採用** | T1 (g)、T6 (c)。「未実証」の申し送りを禁止と明記 |
| 2 | `final_check.sh` 1/6 を `git diff` からフォーマッタ自身の差分判定に | **採用** | T1 (d)。直すまで「`check` はコミット後」を検証コマンド節に書いた |
| 3 | RESEARCH 冒頭に Mojo 1.1.0 既知の落とし穴 | 採用済み（research） | RESEARCH §0.5。plan はそこから `List[UInt8](1,2,3)` 不可・`s[i]` 不可・`UnsafePointer` 非推奨を impl 申し送りに転記 |
| 4 | research スキルに stdlib シンボル確定手順 | 対象外（D18） | スキル側の変更は今回しない。代替として plan が循環 import / stderr / setenv を**実測**してから PLAN に書いた |
| 5 | impl のサブエージェント依頼文テンプレ 3 行 | **採用（申し送り）** | 下の「impl への申し送り」に (a)(b)(c) を固定で書いた（D18 によりスキルは変えない） |
| 6 | PROGRESS の追従先チェックリスト ✓ は素のシェルで再現できる形で | **採用** | 追従先チェックリストの「確かめ方」を全部 `grep` 系で書き、T7 (e) で実行結果を書くことを完了基準にした |
| 7 | リーク測定を `mojo build` バイナリに切り替えるか discuss で聞く | 採用済み（D4） | T1 (e)(f) |
| 8 | `check` の待ち時間削減（leak を 1 サーバー） | **採用** | T1 (e)、`PQ_TEST_LEAK_SERVERS=1` |
| 9 | verify round 2 を「格子の再確認 + 回帰のみ」に | 対象外（verify の運用。REQ §9 で申し送り済み） | — |
| 10 | 冒頭 1 コミットで小物（docstring 3 件 / REQ 文言 / OID 定数） | **採用** | T1 (a)(b)(c)。REQ §6 と同じ 1 タスク |
| 11 | `gsd-lite-loop.sh` の `ended_at` / research 対象に compose | 対象外（ツール側）/ 採用済み（research） | — |

### RESEARCH §3「盗める点」の採否

| # | 項目 | 採否 | 理由 / どこで |
|---|---|---|---|
| 1 | `done` フラグ + 破棄時 ROLLBACK + 結果無視（rust-postgres） | 採用（改良） | 決めた事項 10。結果は無視せず `def(PgError) thin` フックへ（D8）。`commit` / `rollback` は `done = True` を先に |
| 2 | COMMIT のコマンドタグ検査（PG 公式 E12 / F10） | 採用 | 決めた事項 10 `commit()`。`Result.command_tag()` を足す（決めた事項 7）。rust-postgres / psycopg より厳しい本プロジェクト独自 |
| 3 | prepared 名 `pq_stmt_N`（psycopg `_pg3_N`）+ describe で型保持 | 採用 | 決めた事項 9。describe 失敗時は DEALLOCATE を試みてから raise（P10） |
| 4 | savepoint 名は `escape_identifier`（psycopg `sql.Identifier`）、空文字は先に弾く | 採用 | 決めた事項 10。G3〜G9 で `"sp ""1"""` が動作確認済み |
| 5 | 外側 tx 判定は `PQtransactionStatus == IDLE`、UNKNOWN（接続断）は CONNECTION | 採用 | 決めた事項 10 / 14-3 |
| 6 | `PQexecParams` のバッファ組み立て（probe-libpq `Params`） | 採用 | 決めた事項 5 `_ParamBuffers`。末尾ダミー・`List[c_int]`・`_ = x^` の並び |
| 7 | `encode_binary.mojo` を `decode_binary` の逆として同名規則で | 採用 | 決めた事項 8、T2 (e) |
| 8 | psycopg「ROLLBACK で prepared キャッシュを捨てる」 | 却下 | `PreparedStatement` はユーザー所有で ROLLBACK 後も有効（E4）。tx 内 DDL 巻き戻し後のサーバーエラーは docstring に書く（T7 (c)） |
| 9 | `_ffi` 追加 3 本の照合元（psycopg `_pq_ctypes.py:417-431`、ヘッダ 600 / 607 / 608） | 採用 | 決めた事項 2 |
| — | `std.utils.Variant` で `Param` を作る | 却下 | RESEARCH §2.2: `v[T]` に mut が要り Copyable / Writable の条件付き準拠が面倒。手書き variant（構築時エンコード）で足りる |
| — | `Params` ビルダー / ヘテロ可変長引数 | 却下（D5） | — |

### 落とし穴（RESEARCH §4）→ タスク対応

P1→T5 (a)(b)-3,4 / T7 (a)(c)、P2→T4 (b)-3、P3→T3 (c)-10 / 決めた事項 21、P4→T3 (c)-9 / T4 (b)-10、P5→T3 (c)-3（64 KiB ×2）/ T6 (a)、P6→T1 (f)(g)、P7→T1 (e)(h)、P8→T2 (d) / T3 (c)-8、P9→T4 (b)-1 / 決めた事項 9、P10→決めた事項 9（コードレビュー。T6 の prepared ループで `PQclear` 漏れ）、
P11→T4 (b)-6 / 決めた事項 22、P12→T5 (b)-8、P13→T1 (d) 6/6 段 / T5 (b)-6,12、P14→T5 (b)-11 / 決めた事項 14-3、P15→T5 (b)-9 / 決めた事項 12、P16→T5 (c)-4、P17→T3 (c)-3、P18→T3 (c)-6 / 決めた事項 14-2、P19→T4 (b)-4,5 / 決めた事項 14-1、
P20→T4 (b)-1、P21→決めた事項 9（名前は常に `pq_stmt_N`。レビュー: `grep -n '""' src/pq/prepared.mojo` に無名文を渡す経路が無い）、P22→T3 (c)-5、P23→T1 (d)、P24→T5 (c)-2。
**対応先の無い落とし穴: なし**。

観点の担当: **並行性** — libpq 接続はスレッド非安全、`Connection` / `Transaction` / `PreparedStatement` はすべて `Movable` のみで origin により `Connection` より長生きしない（REQ §5.2。T4 / T5 の struct 宣言。負のコンパイル確認は Phase 1 T5 で `Row[origin]` の同型を実測済みなので再実測は任意）。
複数プロセスからの同時テストは TEMP テーブル + 接続ごとの prepared 名で衝突しない（決めた事項 18）。**境界値** — T2 (f)（エンコード単体）/ T3 (c)-3,10（DB 往復）。**異常系** — T3 (c)-6〜9,11 / T4 (b)-2,4,6,7,12 / T5 (b)-6〜11, (c)-4,5 / T6（リーク）。

### REQ §5.2 の各項目 → 担当

| REQ §5.2 | 担当 |
|---|---|
| 未接続 / 接続失敗後 / サーバー停止後でもクラッシュしない | T4 (b)-12、T5 (b)-9,11（`pg_terminate_backend`）。「未接続」は `Connection` が構築できない（Phase 1 `_adopt`）ので対象外 |
| 空 SQL / NULL パラメータ / 個数不一致 / 存在しない prepared 名 | T3 (c)-4,7,8、T4 (b)-2,4 |
| 二重 commit / rollback、破棄後の savepoint | T5 (b)-1,2,7 |
| `PQclear` / `PQfinish` / `PQfreemem` が正常・異常の両方で呼ばれ二重解放しない | T6（RSS）+ 型（`Result` / `Connection` が Movable のみ）+ 陽性対照 T1 (g) / T6 (c) |
| バッファが呼び出し中生存し呼び出し後に解放 | 決めた事項 5 / 6（`_ = buffers^` の位置）、T3 (c)-3 の 64 KiB ×2、T6 (a) params ループ |
| 解放済みポインタへのアクセスが型・所有権で起こらない | `PreparedStatement[origin]` / `Transaction[origin]` の `Pointer[Connection, origin]`（Phase 1 `Row` と同型） |
| 10,000 回ループで RSS 単調増加しない | T6 (a) 4 ループ |

### impl への申し送り

- **1 ターン 1 タスク**（T1〜T7）。サブエージェントを使う場合、依頼文に次の 3 行を**必ず**入れる（REQ §9 / reflect 提案 5）:
  (a) 型パラメータを持つ型は `Transaction[origin]` / `PreparedStatement[origin]` / `Row[origin]` のようにフルに書く（`Transaction` だけ書くと別の型に読まれる）；
  (b) `mojo format`（`pixi run fmt`）は**親が統合後に 1 回だけ**。サブエージェントは実行禁止（他方の編集中ファイルを書き換える）；
  (c) scratch ファイルは `.gsd-lite/logs/phase2-params-prepared-tx/scratch/turn-NNN-<name>` 固定（`/tmp` は権限拒否。前ターンのファイルを使い回さない）
- 無人シェル: `/home/parallels/.pixi/bin/pixi run ...` フルパス。1 Bash 1 コマンド、`&&` / `;` / `$(...)` / 先頭変数代入を使わない（`pixi.toml` / `*.sh` の中では使ってよい）。コミットは `git commit -F <scratch>/turn-NNN-commit-msg.txt`
- `check` は T1 完了までコミット後にだけ回す。T1 以降は作業木のままで回せる（1/6 段が `build/fmtcheck/` 比較）
- **Mojo 1.1.0 の罠**（RESEARCH §0.5 から。プローブ・実装で踏まないこと）: `List[UInt8](1, 2, 3)` の位置引数 ctor は無い → `var b: List[UInt8] = [1, 2, 3]`；`s[i]` 不可 → `s.as_bytes()[i]` / `s[byte=i]`；`len(String)` 不可 → `byte_length()`；`UnsafePointer` は非推奨 → `Pointer[T, origin]`；
  `size_t` 引数は `c_size_t(s.byte_length())`；`from std.math import isnan, isinf`；`from std.memory import bitcast`；`from std.sys import stderr`；`from std.os import setenv, getenv`；素の `None` は `Param` / `Variant` に変換されない；`_ = x^` は生存マーカー（破棄ではない）；
  `::` は単項マイナスより強い（`(-1)::int4`）；`with` 内の `var` は外から見えない；デストラクタは `__deinit__(deinit self)`；`def(T) thin` でないと関数型をフィールドに置けない；`T: Copyable & Movable` は冗長警告
- **型名の確定手順**（REQ §9。stdlib ソースは pixi env に無い）: (1) https://mojolang.org/docs/std/ 、(2) コンパイルエラーの note に出る候補シグネチャ。記憶で書かない
- `PQexecParams` / `PQexecPrepared` / `PQprepare` / `PQdescribePrepared` の呼び方は `scratch/turn-001-probe-libpq.mojo:189-287` をそのまま流用できる（`OidPtr` / `CStrArray` / `IntPtr` の `unsafe_from_address` キャスト、末尾ダミー、`_ = x^` の並び）
- 警告ゼロは `tests/` と `examples/` も対象。未使用変数は `_ = x`。`raises PgError` の中で `raises Error` の関数（`setenv` 等）を呼ぶなら `try/except` で包む
- テストの `raises PgError` → `raises` 変換ヘルパーは `tests/test_connection.mojo:141-510` の `_connect` / `_execute` / `_execute_error` の流儀（成功は `Error` に変換、失敗は `PgError` を返す）
- PROGRESS の「追従先チェックリスト ✓」は実行した `grep` コマンドと出力をそのまま書く（MCP 検索の結果を `rg` として書かない）
- PLAN の訂正は該当タスクに「**PLAN 訂正（turn N 実測）**」で追記し、REQ / DECISIONS / RESEARCH は触らない（Phase 1 の流儀）

### 未プローブ（impl が最初に踏む。コンパイルが通らなければ代替へ）

- `Param` の `@implicit __init__` 19 本（probe は 14 本: Optional は Int / String / Bool の 3 本）。**残り 6 本の `Optional[Int16/Int32/Int64/Float32/Float64/List[UInt8]]`** を足してもリスト literal `[1, "a", 1.5, True, Param.null()]` が曖昧にならないかは未確認。曖昧になれば Optional 群を `Param.of[T](v: Optional[T])` 的な静的関数に落とし PROGRESS に書く（REQ §4.1 の `@implicit` 要件からの逸脱なので PLAN 訂正に理由）
- `Transaction.prepare` の戻り `PreparedStatement[Self.origin]` と `self._conn[].prepare(...)` の戻り `PreparedStatement[origin_of(self._conn[])]` の origin 一致。合わなければ `rebind` か `Transaction.prepare` を `-> PreparedStatement[origin_of(self._conn[])]` に
- `param_types: List[UInt32] = List[UInt32]()` の既定引数（Mojo 1.1.0 で非 trivial 型の既定値が通るか）。通らなければ `prepare(sql)` と `prepare(sql, param_types)` の 2 オーバーロード
- `conn.execute("...", [1, "a"])` で 2 引数オーバーロードのリスト literal が `List[Param]` に解決されるか（probe は単独関数 `use(params: List[Param])`）
- PG14 側の built binary のリーク系列（PG17 のみ実測）→ T1 (f) で決める
- `Transaction.__deinit__` 内で `_error_field`（`connection.mojo:46`）を呼ぶための import 循環は plan プローブで同型（関数 import）を確認済み

### タスク数について

7 タスク（目安 8〜15 の下限未満）。REQ の機能単位（基盤 / params / prepared / transaction）にテストを同梱し、持ち越し整理（T1）と仕上げ（T7）を前後に置いた形で、各タスクは並列サブ作業 2〜4 本で 1 ターンに収まる見込み。
T5 が最大（struct 1 本 + テスト 2 ファイル 18 ケース）で、サブエージェントが使えない場合は A → B → C を同一ターン内で直列に進める。T6 は実行待ち（10,000 回 × 4 ループ × 2 サーバー + 陽性対照 3 ビルド）が支配的で、実装量は小さい。
