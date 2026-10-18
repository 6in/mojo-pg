# RESEARCH — phase5-polish-bench-readme

- 作成: 2026-10-17 / gsd-lite-research（turn 1）
- 入力: REQUIREMENTS.md / DECISIONS.md / HANDOFF.md §5.1・§6・§8・§10、`archive/phase4-async-cancel-notify/{RESEARCH,VERIFICATION,TRACE,PROGRESS}.md`、
  `reflect/20261017-1925-phase4-async-cancel-notify.md`。`state.json.research.targets` = official_docs / similar_oss
- 検証環境: Mojo 1.1.0 (8189361e)、pixi 0.82.0、pixi env の libpq 18.6（`PQlibVersion` = 180006、conda-forge `h4d8aa50_3`）、docker `postgres:17`（**17.11**、54317）/
  `postgres:14`（**14.24**、54314）/ `alpine/socat`（54399）、Ubuntu 24.04.5 LTS、kernel 6.8.0-147、aarch64 4 コア（仮想マシン、archspec `neoverse_n1`）、RAM 15 GiB。
  ホスト python3 3.12.3 + psycopg 3.3.3（`binary` 実装、libpq 180000）はプローブ 1 本（DROP DATABASE）にだけ使った
- **プローブ**（`.gsd-lite/logs/phase5-polish-bench-readme/scratch/`、gitignore 対象。結論は本書に転記済み。`.log` は同名プローブの出力原本）:
  - `turn-001-probe-lang.mojo` + `.log`: `_WsaPollFd` の `size_of`、`comptime if` 連鎖で OS 別候補を返す関数、`ErrNo` の値（§2.3・§2.4）
  - `turn-001-probe-closefd.mojo` + `.log`: `close(PQsocket)` 後の `fetch_all` / `send` / `wait_readable`（§2.7。**busy-spin を再現**）
  - `turn-001-probe-notify-bad.mojo` + `.log`: 切断後（`PQstatus` = BAD）の `notifications()` / `wait_notification()`（§2.8）
  - `turn-001-zerocopy-time.sh` + `.log`: `test_zero_copy` の単体 / `check` 相当 / build→run 分離（§2.5。**単位の読み違いが原因**）
  - `turn-001-examples-robust.sh` + `.log`: examples 7 本 × 誤パスワード / 閉じたポート / libpq 不在（§2.9。**`hello_libpq` だけ未捕捉**）
  - `turn-001-dropdb-race.py` + `.log`: 切断直後の `DROP DATABASE`（FORCE 有無 × PG14 / PG17 × 10 回。§2.6）
  - `turn-001-pixi/`（`pixi.toml` + `pixi.lock` + `examples/bench_psycopg.py`）+ `turn-001-bench.log`: feature `bench` の最小形で psycopg を入れて測った（§2.1・§2.2。
    環境 `.pixi/` は消した。`pixi install -e bench` で再現できる）
- 無人シェルの注意: `mojo` / `pixi` は PATH に無い → `/home/parallels/.pixi/bin/pixi run mojo ...`。`gsd-lite-loop.sh --where` は PATH にある（`.gsd-lite/` には無い）。
  lean-ctx MCP は未接続（素の Read / Bash で可）。`/etc/os-release` は lean-ctx のルート制限で読めない → `lsb_release -ds`。やり直し 0 回（プローブ 6 本すべて 1 回でコンパイル・実行）

## 0. 結論サマリ

1. **作る（BLOCKED にしない）**。要件を覆す発見は無い。「作るか使うか」の判断対象も無い（Phase 5 は仕上げ）。REQ 本文の事実誤りを 2 箇所直した（§5）
2. **psycopg 比較は pixi の feature `bench` で成立**（§2.1）。`[feature.bench.dependencies] python = ">=3.10"; psycopg = ">=3.2"` +
   `[environments] bench = { features = ["bench"], solve-group = "default" }` + `[feature.bench.tasks] bench-psycopg = "python examples/bench_psycopg.py"`。
   `pixi run bench-psycopg` は `-e` 無しで bench 環境を選ぶ。解決結果: **psycopg 3.3.4 + psycopg-c 3.3.4（C 実装）+ python 3.14.8、libpq は default 環境と同じ 18.6 `h4d8aa50_3`**。
   default 環境（`check` が使う）は**変わらない**（python 3.15.0 のまま）。conda-forge に `psycopg-binary` は無く、`psycopg`（noarch）が `psycopg-c` を必須依存にしている
3. **実測値（§2.2、pg17、同一マシン・アイドル時）**: Mojo text `exec 43〜45 / decode 44 / total 88〜89 ms`、Mojo binary `exec 37〜46 / decode 12 / total 49〜59 ms`、
   psycopg text `42 / 44〜46 / 86〜89 ms`、psycopg binary `36 / 35〜36 / 72〜73 ms`。**HANDOFF §8「バイナリがテキストより速い」は decode 列で 3.7 倍（12 vs 44 ms）、合計でも成立**。
   psycopg の binary decode（36 ms）に対して Mojo は 12 ms。exec はサーバー側の仕事なので両者同じ
4. **`test_zero_copy` の「1 テスト 3.4〜3.9 s」は単位の読み違い**（§2.5）。TestSuite の `PASS [ n ]` は**ミリ秒**（`pg_sleep(2)` のテストが `[ 2033.338 ]`、`build/final_check.log:48`）。
   実測: 12 件 49〜56 ms、ビルド済みバイナリの壁時計 52 ms、`mojo run` の壁時計 1.6〜1.8 s はコンパイル。`test_result`（同じ `_connect`）も 1 件 3.7〜4.5 ms で同じ。
   **直すものは無い**。impl は `scratch/turn-001-zerocopy-time.log` を TRACE に転記するだけ（D12 の「テスト側なら直す / src 側なら記録」のどちらでもなく「問題なし」）
5. **`fetch_all` の busy-spin は再現できる**（§2.7、probe-closefd A）: BUSY 中に `close(PQsocket)` → `PQconsumeInput` が 0 を返すが `PQstatus` は OK のまま →
   `fetch_all(1500)` は **1500 ms 回り続けて `TIMEOUT`**（`CONNECTION` ではない）。state は BUSY のまま。修正後は即 `CONNECTION`（< 50 ms）になるのが差分 → テスト 1 件の陽性対照になる
6. **`_after_send` の `PQflush` -1 は到達不能**（§2.7）: PG18 の `PQflush` は `conn->status == CONNECTION_BAD` のとき -1、それ以外は `pqFlush` で、書き込み失敗は
   `write_failed` + 「成功したことにする」（`pqsecure_raw_write`）ので -1 にならない。`PQsendQuery` が成功した直後に status が BAD になる経路は同一スレッドに無い →
   REQ §4.5 の「到達困難なら陽性対照はコードレビュー」を採る。分岐自体（-1 → `BUSY`）は libpq の `PGASYNC_BUSY` と一致するので入れてよい
7. **`notifications()` は BAD でも既に `CONNECTION` を投げる**（空リストは返さない。§2.8）。ただし **libpq の `errorMessage` が呼ぶたびに `connection not open` を 1 行ずつ蓄積する**
   （2 回目 1 行、3 回目 2 行、`wait_notification` 3 行）。先行チェック（REQ §4.6）の観測可能な効果は「文言が固定される」ことで、テストはそこを断定する
8. **Windows 照合（§2.3）**: レイアウト（16 byte）・フラグ値 5 つ・events の制限・timeout・戻り値は**正しい**。**誤り 1 件**: `ret < 0` の後の `get_errno()` は Windows では
   `WSAGetLastError()`（`ws2_32.dll`）でないと取れない（Winsock は errno を設定しない）。加えて **Windows 10 2004 より前は接続失敗が `WSAPoll` に出ない**（公式注記）、
   `WSAStartup` 前提、`external_call["WSAPoll"]` のシンボル解決は未検証のまま
9. **`_ffi/loader.mojo` の Windows 行**（§2.4）: `platform_map` に `windows=` が無いので、`comptime if CompilationTarget.is_linux() / elif is_macos() / else` の連鎖で
   `StaticString` を返す関数に置き換える（プローブでコンパイル・実行済み、Linux で `libpq.so.5,libpq.so`）。Windows は `libpq.dll` の 1 候補
10. **DROP DATABASE**（§2.6）: PG14 / PG17 とも `WITH (FORCE)` 可（PG13 で導入）。切断直後の DROP は FORCE 無しでも 20/20 成功（4〜10 ms）だが、FORCE は無料の保険なので付ける。
    トランザクション内不可（`Connection.execute` の `PQexec` は autocommit なので可）、対象 DB に繋いだ接続からは不可。`IF EXISTS` の不在時は NOTICE（stderr）で `check` 6/6 の
    パターンには当たらない
11. **examples の堅牢性**（§2.9）: 6 本は誤パスワード / 閉じたポート / libpq 不在 / 不正 conninfo のすべてで `failed: PgError(...)` + 終了コード 1。
    **`hello_libpq.mojo` だけ `raise Error` で `Unhandled exception caught during execution` + `stack trace was not collected ...` の 2 行が出る**（REQ §5 違反。1 箇所の書き換え）

## 0.5 Mojo 1.1.0 既知の落とし穴（Phase 1〜3 ★ / Phase 4 ☆ / 今回 ◇）

- ◇ **TestSuite の `PASS [ n ]` / `Summary [ n ]` はミリ秒**。秒と読むと「1 テスト 3.4 s」のような架空の性能問題を作る（Phase 4 turn 9 がこれ）。`pg_sleep(2)` のテストで較正できる
- ◇ **`def main() raises` で `raise Error(...)` すると Mojo ランタイムが `stack trace was not collected ... MODULAR_DEBUG=stack-trace-on-error` と
  `Unhandled exception caught during execution: ...` を出し、`mojo run` が `error: execution exited with a non-zero result: 1` を足す**（3 行、終了コード 1）。
  「トレースバックを出さない」要件は `def main():` + `try / except e: print("failed:", e); exit(1)` の形でしか満たせない（他の 6 example はこの形）
- ◇ **`external_call["close", c_int](c_int(fd))` で libpq の socket を閉じても libpq は気づかない**（`PQstatus` OK、`PQsocket` は同じ番号）。`send` も成功する
  （`pqsecure_raw_write` が EBADF を `write_failed` + 成功扱いにする）。テストで使うなら、閉じてから `PQfinish`（= `__del__`）までの間に新しい fd を開かないこと（fd 番号の再利用で無関係な fd を閉じる）
- ◇ **libpq の `errorMessage` は追記式**: BAD になった接続で `PQconsumeInput` を呼ぶたびに `connection not open` が 1 行ずつ増える。pq の `_connection_error()` はその全文を message にするので、
  「同じ操作を 2 回したら同じメッセージ」は成り立たない。文言を断定するテストは `find(...) >= 0` か、pq 側で先に投げる（REQ §4.6 の先行チェック）
- ◇ **`comptime if` 連鎖（`if / elif / else`）を `def` の本体に書いて各分岐で `return` できる**（`StaticString`）。`platform_map` の代替として使える
- ◇ **`size_of[_WsaPollFd]()` = 16、`size_of[_PollFd]()` = 8**（Linux aarch64 で実測。`var fd: Int` + `Int16` ×2 は C と同じ自然アライメント）
- ◇ pixi: `[feature.X.tasks]` のタスクは `pixi run <task>` で `-e X` 無しに動く。`solve-group = "default"` を付けても default 環境の python（3.15）は bench 環境（3.14）と
  一致させられない形で解決された（default 環境は変わらず、libpq の build だけ一致）。`pixi search --platform linux-aarch64 "psycopg-c==3.3.6"` で依存を確認できる
- ◇ lean-ctx のルート制限: `cat /etc/os-release` は拒否される（`lsb_release -ds` を使う）
- ☆（Phase 4 の 9 件）`PgError` を値で返すとき `return e^` ／ `except e: return e^` の `try` 本体から `Error` を投げるヘルパを呼べない（判定は `try` の外へ）／
  `var x: Optional[T] = None` は `except` が必ず脱出すると「assignment never used」警告／`FileDescriptor(fd).write()` は一時値への mutating 呼び出しで不可（`var` に受ける）／
  `prefix^ + chr(0)` は `^` 演算子と解釈される／`self._field^` でフィールドから move out 不可（`copy()` + `clear()`）／`print("SKIP ...")` は 80 桁を超えると `mojo format` が割る／
  `len(StringSlice)` は `byte_length()`／`__origin_of` は `origin_of`
- ☆（Phase 4 research）`external_call` は同じシンボル名を 1 つの引数型列でしか呼べない（stdlib が使う `write` / `read` も同じ。`close` は衝突しなかった）／`from std.ffi import external_call`
  が必要、`size_of` は `from std.sys import size_of`／OS 判定は `CompilationTarget.is_linux()` / `is_macos()` を `comptime if` で（`is_windows()` 無し、`platform_map` は `linux=` / `macos=` のみ、
  `@parameter if` は構文エラー）／errno は `from std.ffi import get_errno, ErrNo`（`.value` で Int。EBADF 9 / EINVAL 22 / EINTR 4）／単調時計は `std.time.monotonic`／
  文字列スライスの正式名は `StringSpan`（`StringSlice` も通る）／`c_int` 4 / `c_short` 2 / `c_long` 8 等がある／`String.strip()` と `t[byte=a:b]` は `StringSpan`／
  `def f(mut s: String)` に一時値は渡せない／`print(a, b)` の既定 `sep=" "`
- ★（Phase 3）`Span[UInt8, origin]` は `[origin: ImmOrigin, //]` 前置／`(-0.0)::float8` は `'-0'::float8`／`@fieldwise_init` は全フィールド公開 ctor／`ImplicitlyCopyable` でない型は
  `List` 要素を `.copy()`／`List[T](a, b, c)` 不可・`[a, b, c]` リテラルで／実引数の `String(...).as_bytes()` は一時オブジェクト由来／モジュールレベル `var` 不可／`_ = x^` は生存マーカー／
  `ref` 束縛は生存延長されない／`Span(unsafe_ptr=, length=)` / `StringSlice(unsafe_from_utf8=)` は未検証・`String(from_utf8=)` は検証して raise／`//` `%` は床除算／`-Int64.MIN` は wrap／
  `atol` は空白と `+` を通す／`comptime if T == 自前型` は `rebind[T](v).copy()`／ASAP 破棄 × バッファ型は `_ = buffers^` で守る
- ★（Phase 2）`mojo format` はディレクトリ走査で `.gitignore` を尊重（`check` 1/6 はファイル列挙で回避済み）／`SIMD.__rshift__` 符号拡張／ローカル `List` は `return out^`／
  `def main() raises PgError` 不可／`s += s` は aliasing エラー／`StaticString` は `@implicit` 変換元にならない／`std.os.setenv` は `Bool`／空 `List[UInt8]` の `unsafe_ptr()` は `capacity=len+1`
- ★（Phase 1）`len(String)` 不可 → `byte_length()`／`from std.math import isnan, isinf`／リスト literal は型注釈必須／`::` は単項マイナスより強い／stdlib ソースは pixi env に無い（名前は 1 名 1 ファイルの
  `mojo run` で確定）／`UnsafePointer` は deprecated／`__deinit__(deinit self)`／素の `None` は `Optional[T](None)`／`size_t` は `c_size_t(...)`／libpq の既定 notice processor は stderr（`FATAL:` /
  `NOTICE:` 行が出る。`check` 6/6 が数えるのは `warning:` / `WARNING:` / `implicit ROLLBACK failed` だけ）

### 0.5.1 Mojo → C の型幅（縮小変換）

- **`c_int(x)` / `Int32(x)` / `Int16(x)` / `UInt32(x)` は範囲外の `Int` を黙って wrap する**（Phase 4 round 1 の実測: `wait_readable(2**32 + 50)` が 50 ms 待った。F1 で `TIMEOUT_MS_MAX` を置いて解決）。
  C に渡す引数はすべて「渡す前に `Int` のまま範囲検査」が原則。現在の検査点: `_reject_bad_timeout`（`c_int(timeout_ms)` の 6 入口）、`c_int(256)`（定数）、`_PollFd(Int32(fd), ...)`（fd は
  実用上 2^31 未満。未検査）、`_WsaPollFd(fd, ...)`（`Int` のまま。`SOCKET` = `UINT_PTR` で幅一致）
- 今回の新規引数 `wait_notifications(n, timeout_ms)`: `timeout_ms` は既存の `_reject_bad_timeout` を通す。`n` は C に渡さない（ループ上限と `List` の件数）ので縮小変換は無いが、
  `n < 1` を `USAGE`、`n = Int.MAX` は「予算切れまで集める」の意味で受け入れる（`List` の確保は到着分だけ）。plan の境界値行: `n ∈ {0, -1, 1, 2, Int.MAX}` × `timeout_ms ∈ {-1, 0, 200, TIMEOUT_MS_MAX, TIMEOUT_MS_MAX+1, 2**32}`
- `psycopg` 側（Python）には縮小変換が無い。bench の `int` 合計は多倍長なので溢れない。Mojo 側 `bench_formats.mojo` の `ints += Int(row.get[Int32](0))` は Int64 累積で溢れない（和 ≈ 5×10^9）

## 1. 類似 OSS（similar_oss）

### 1.1 psycopg 3 — https://www.psycopg.org/psycopg3/docs/

- **バイナリ結果**: `Connection.cursor(binary=True)` または `execute(..., binary=True)`。結果の全列が同じ形式（列ごとには選べない）。バイナリ要求時は 1 クエリ 1 文のみ
  （https://www.psycopg.org/psycopg3/docs/basic/params.html「Binary parameters and results」/ https://www.psycopg.org/psycopg3/docs/api/cursors.html）
- **実装の見分け**: `psycopg.pq.__impl__` が `"c"` / `"binary"` / `"python"`。conda-forge 版は `"c"`（実測）。`psycopg.pq.version()` = ロードされた libpq（実測 180006 = default 環境と同じ）
  （https://www.psycopg.org/psycopg3/docs/api/pq.html）
- **公式の conda 立場**: 「Conda は未テスト・非サポート」（https://www.psycopg.org/psycopg3/docs/basic/install.html）。README には「conda-forge の psycopg-c 3.3.4 を使った」と版を書けば足りる
- **盗める測り方**: `cursor.execute()` = ラウンドトリップ + サーバー整形 + クライアント側 `PGresult` への着地（Mojo の `exec` と同じ境界）、`fetchall()` = 行オブジェクト化（Mojo の `decode`）。
  `autocommit=True` で暗黙 BEGIN のラウンドトリップを消す（Mojo の `PQexec` は autocommit）。`timestamp` は `datetime` で返るので `(ts - datetime(2000,1,1))` を µs にして合計（Mojo の `Timestamp.micros` と同じ量）
- psycopg 3 の generator 状態機械（Phase 4 §1.1）は今回使わない

### 1.2 conda-forge のパッケージ（`pixi search --channel conda-forge --platform linux-aarch64`、2026-10-17）

| パッケージ | 版 | 依存 | 備考 |
|---|---|---|---|
| `psycopg` | 3.3.4 `pyh848bd53_0`（noarch） | `libpq`, `psycopg-c >=3.3.4,<3.3.5`, `python >=3.10`, `typing-extensions` | noarch の最新は 3.3.4（`psycopg-c` は 3.3.6 まであるが `psycopg` が追いついていない） |
| `psycopg-c` | 3.3.4 `py313h330e198_0` ほか +5 build（実際に解決されたのは `py314h3076274_0`） | `libpq >=18.3,<19`, `python 3.13.*` 等（build ごとに python を固定） | 3.3.6 は `libpq >=18.6,<19`, py314。py315 build は無い |
| `psycopg-binary` | **無い** | — | PyPI 専用（https://www.pypi.org/project/psycopg-binary） |

- 3 プラットフォーム（`linux-aarch64` / `linux-64` / `osx-arm64`）とも `psycopg-c` の build がある（`pixi install -e bench` が 3 つぶんのロックを作って成功した）
- `python >=3.10` の制約で solver は **python 3.14.8** を選ぶ（`psycopg-c` 3.3.4 に py315 build が無い）。default 環境の python 3.15（mojo → mblack / jupyter_client の依存）は別物のまま

### 1.3 README のベンチ表記（他の PostgreSQL ドライバ）

- asyncpg の README はベンチを「psycopg3 比 5x（幾何平均、2023-06、toolbench）」の 1 行 + 外部チャートで出し、環境はチャート側に置く（https://github.com/MagicStack/asyncpg）。
  本プロジェクトは HANDOFF §8 が「勝敗は条件にしない。結果を記録する」なので、**数値の表 + 計測環境 + 日付 + 1 行要約**（REQ §4.1）が正しい形。グラフは作らない
- 「同じ SQL・同じ形式・同じ測り方」を README に書く（psycopg 側の境界は §1.1）。psycopg が `"c"` 実装であることも 1 行で書く（`"python"` 実装だと桁が変わる）

### 1.4 Apache-2.0

- 全文: https://www.apache.org/licenses/LICENSE-2.0.txt（約 200 行、末尾に APPENDIX「How to apply the Apache License to your work」、ひな形 `Copyright [yyyy] [name of copyright owner]`）。
  `LICENSE` には全文をそのまま置き（APPENDIX 含む。改変しない）、README 末尾に `Copyright 2026 0hya6in` + `Apache License 2.0` と書く（D11）。`curl -o LICENSE` は無人ターンでは
  allowlist 外の可能性 → impl は `WebFetch` 相当で本文を取るか、plan が取得コマンドを明示する

## 2. 公式ドキュメント + 検証結果（official_docs）

### 2.1 pixi に psycopg を足す最小の形（実測。`scratch/turn-001-pixi/pixi.toml`）

```toml
[feature.bench.dependencies]
python = ">=3.10"
psycopg = ">=3.2"

[feature.bench.tasks]
bench-psycopg = "python examples/bench_psycopg.py"

[environments]
bench = { features = ["bench"], solve-group = "default" }
```

- `pixi install -e bench` → 「The bench environment has been installed.」（ロック解決 + ダウンロード 1 分未満。python 3.14.8 と psycopg-c ≈ 35 MB）
- `pixi run bench-psycopg` → `Pixi task (bench-psycopg in bench): python examples/bench_psycopg.py`（**`-e bench` 不要**）。`pixi run check` は default 環境のまま
- 却下した形: (a) `[dependencies]` に常時追加 → default 環境の python が 3.14 に下がり `check` の環境が変わる（mblack 等は動くはずだが検証コストがある）。(b) feature を作って
  `[environments]` を書かない → タスクが環境に紐づかず `pixi run bench-psycopg` が解決できない
- `pixi.lock` は bench 環境ぶん増える（3 プラットフォーム）。**コミット対象**（既存 lock も追跡済み）。plan のチェックリスト: `grep -c "psycopg-c" pixi.lock` が 0 → ≥ 3
- README の手順: `pixi run db-up` → `pixi run bench`（Mojo）→ `pixi run bench-psycopg`（psycopg。初回は環境作成で待つ）

### 2.2 ベンチの測り方と実測（`scratch/turn-001-bench.log`）

- **psycopg スクリプト**（`scratch/turn-001-pixi/examples/bench_psycopg.py`。そのまま `examples/bench_psycopg.py` に置ける）: `SQL` / `ROWS` / `RUNS` を `bench_formats.mojo` と同じ値で持ち、
  `psycopg.connect(conninfo, autocommit=True)` → warm-up text / binary 1 回ずつ → text / binary 交互 3 回。`exec` = `cur.execute(SQL)` の前後、`decode` = `fetchall()` + 5 列全部を読むループ
  （int 合計 / int 合計 / float 合計 / `len(str)` / `(ts - 2000-01-01)` の µs 合計）。`rows != ROWS` や合計 0 で終了コード 1。`psycopg.Error` は `failed: <型名> <message>` + 終了コード 1
  （誤パスワードで実測、トレースバックなし）
- 行の読み方の差: Mojo は `row.get[String](3).byte_length()`（O(1)）、psycopg は `len(s)`（文字数。ASCII なので同数）。README に「全セルを読む」とだけ書き、この差は書かなくてよい
- **実測（pg17 54317、アイドル時、同一マシン）**:

| 実装 | 形式 | exec (ms) | decode (ms) | total (ms) |
|---|---|---|---|---|
| Mojo `pq`（`pixi run bench`） | text | 45 / 43 / 43 | 44 / 44 / 44 | 89 / 88 / 88 |
| Mojo `pq` | binary | 46 / 37 / 39 | 12 / 12 / 12 | 59 / 49 / 52 |
| psycopg 3.3.4 (c, py3.14.8) | text | 42 / 42 / 42 | 46 / 44 / 45 | 89 / 86 / 87 |
| psycopg 3.3.4 (c) | binary | 36 / 36 / 36 | 36 / 35 / 36 | 72 / 72 / 73 |

- 1 行要約の候補: 「バイナリ形式はテキスト形式より decode で 3.7 倍速い（12 ms vs 44 ms、10 万行 × 5 列）。合計でも 49〜59 ms vs 88〜89 ms。psycopg 3（C 実装）は text 86〜89 ms / binary 72〜73 ms」
- 揺れ: 3 回の幅は exec で ±5 ms、decode で ±1 ms。README の表は impl の実測ログ（`scratch/turn-NNN-bench.log`）から転記し、3 回の値をそのまま並べるか中央値を書く（plan が決める。上の表は 3 回並記）
- 受け入れ（REQ §4.1）「`pixi run bench` の decode 列で binary < text」は現状 12 < 44 で成立。verify は再実行して同じ関係を確認する

### 2.3 `WSAPoll` 照合表（poll.mojo の `else` 分岐。TRACE にこのまま写せる）

一次資料: [F] https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsapoll（WSAPoll function）、
[S] https://learn.microsoft.com/en-us/windows/win32/api/winsock2/ns-winsock2-wsapollfd（WSAPOLLFD structure）、
[E] https://learn.microsoft.com/en-us/windows/win32/winsock/windows-sockets-error-codes-2（Windows Sockets Error Codes）、
[H] https://raw.githubusercontent.com/mirror/mingw-w64/master/mingw-w64-headers/include/winsock2.h（フラグの数値。MS Learn には数値が無い）

| # | 項目 | poll.mojo の現状 | 根拠 | 判定 |
|---|---|---|---|---|
| 1 | `WSAPOLLFD` = `{ SOCKET fd; SHORT events; SHORT revents; }`、`SOCKET` = `UINT_PTR`（x64 で 8 byte）→ 16 byte | `_WsaPollFd(fd: Int, events: Int16, revents: Int16)`、`size_of` = 16（実測） | [S] 構造体定義、[H] typedef、`probe-lang.log` | **一致** |
| 2 | `POLLRDNORM 0x0100`、`POLLRDBAND 0x0200`、`POLLIN = RDNORM\|RDBAND = 0x0300`、`POLLWRNORM 0x0010 = POLLOUT`、`POLLERR 0x0001`、`POLLHUP 0x0002`、`POLLNVAL 0x0004` | `_WSA_POLLIN 0x0300`、`_WSA_POLLOUT 0x0010`、`_WSA_POLLERR 0x0001`、`_WSA_POLLHUP 0x0002`、`_WSA_POLLNVAL 0x0004` | [H] `#define` 行、[S]「POLLIN は RDNORM と RDBAND の組」 | **一致** |
| 3 | `events` に置けるのは `POLLPRI` / `POLLRDBAND` / `POLLRDNORM` / `POLLWRNORM` のみ。他の値は `SOCKET_ERROR` + `WSAEINVAL`。`POLLPRI` は MS プロバイダで失敗 | ERR / HUP / NVAL を `events` に入れない（docstring 明記）、`POLLPRI` を使わない | [F] Remarks、[S] events | **一致**（`POLLRDBAND` を要求するのは許容範囲。`0x0100` だけにする案は任意） |
| 4 | `timeout`（INT）: > 0 は ms、0 は即時、< 0 は無期限 | `c_int(timeout_ms)`、-1 で無期限 | [F] Parameters / Remarks | **一致** |
| 5 | 戻り値: 0 = タイムアウト、> 0 = `revents` 非 0 の要素数、`SOCKET_ERROR`(-1) = 失敗 | `ret == 0` → timeout、`ret < 0` → エラー、それ以外は flags | [F] Return value | **一致** |
| 6 | **失敗理由は `WSAGetLastError()`**（`ws2_32.dll`）。Winsock は errno を設定しない。`WSAEINVAL` 10022 / `WSAENOTSOCK` 10038 / `WSAEBADF` 10009 / `WSAEFAULT` 10014 / `WSAENETDOWN` 10050 / `WSAENOBUFS` 10055 / `WSANOTINITIALISED` 10093 / `WSAEINTR` 10004（`WSACancelBlockingCall` 時のみ） | `poll_socket` が `get_errno()` → `ErrNo.EINTR` / `EBADF` / `EINVAL` を見る（POSIX の値 4 / 9 / 22） | [E] 冒頭「WSAGetLastError を直後に呼ぶ」+ 一覧、[F] Return value「Call the WSAGetLastError function」 | **不一致 → 直す**。`_poll_once` の `else` 分岐で `external_call["WSAGetLastError", c_int]()` を読み、10022 / 10038 / 10009 → `USAGE`、それ以外 → `CONNECTION`、`EINTR` 再試行はしない（§3-2 の形） |
| 7 | `revents` の `POLLNVAL` = 無効なソケット。`fd` が負の要素は無視され `revents` は [F] では `POLLNVAL`、[S] では「クリア」（**公式同士で食い違い**） | `POLLNVAL` → `USAGE`（`poll: fd N is not open`） | [F] Remarks 末尾、[S] Remarks | **一致**（`PQsocket` = -1 のときは [F] なら `USAGE`、[S] なら要素 0 個扱いで `WSAEINVAL`「none of the sockets valid」→ #6 修正後は同じ `USAGE`） |
| 8 | **Windows 10 2004 以降**、TCP 接続失敗は `POLLHUP \| POLLERR \| POLLWRNORM` で通知。それ以前は通知されない（既知の仕様差） | 非同期接続は `wait_writable` で待つ → 古い Windows では接続失敗が予算切れ（`TIMEOUT`）まで分からない | [F] Remarks の Note | **README に明記**（コード変更なし。「Windows 10 2004 より前は接続失敗の検出がタイムアウト頼み」） |
| 9 | `WSAPoll` は Vista 以降、`Ws2_32.dll`、`WSAAPI` = `WINAPI`（x64 では既定の呼出規約と同一） | `external_call["WSAPoll", c_int](Pointer, Int(1), c_int)` | [F] Requirements、[H] `#define WSAAPI WINAPI` | **一致**（x64 前提。シンボル解決は未検証のまま） |
| 10 | `nfds` は `ULONG`（32 bit） | `Int(1)`（64 bit） | [F] Syntax | **許容**（x64 ABI は下位 32 bit を使う。POSIX 側の `nfds_t` も 64 bit で同じ書き方） |
| 11 | `WSAStartup` 未実行だと `WSANOTINITIALISED` 10093 | `poll_socket` は libpq の `PQsocket` にしか使わない。libpq は接続開始時に `WSAStartup` を呼ぶ（fe-connect.c、`#ifdef WIN32`。未取得） | [E] 10093 | **一致の見込み**（docstring に「libpq の socket 以外に使う場合は WSAStartup が要る」を 1 行） |
| 12 | `SOCKET` は符号なし、`PQsocket` は `int` | `fd: Int` | libpq の `PQsocket` は `int` を返す（全 OS） | **一致** |

- **直すのは #6 の 1 件**。#8 と #11 は README / docstring の明記。`comptime if` の非選択側なので Linux / macOS の `check` には影響しない（REQ §5「Linux / macOS の挙動は変わらない」は `check` PASS で担保）
- 検証方法（Windows 無し）: (a) `comptime if` の `else` は Linux でコンパイルされないので、**`else` 分岐の構文・型は Linux の `mojo build` では検証できない**。impl は `else` 側の
  コードを一時的に `if True:` 側へ複製した scratch ファイルで `mojo build` だけ通す（`WSAPoll` / `WSAGetLastError` のシンボルは Linux に無いのでリンクせず、`mojo build -o` ではなく
  `mojo build` の型検査段階まで。`external_call` は実行時解決なのでビルドは通る見込み。通らなければ TRACE に書く）。(b) 照合表の 12 行を TRACE に写し、verify が URL と行番号を突き合わせる

### 2.4 `_ffi/loader.mojo` の Windows 行（実測 `probe-lang`）

- 現状: `comptime _DEFAULT_CANDIDATES = platform_map["libpq_candidates", linux=..., macos=...]()`。`windows=` は `unexpected keyword parameter`（Phase 4 §0.5）
- 置き換え（プローブでコンパイル・実行済み。Linux で `libpq.so.5,libpq.so` を返した）:

```mojo
def _default_candidates() -> StaticString:
    comptime if CompilationTarget.is_linux():
        return "libpq.so.5,libpq.so"
    elif CompilationTarget.is_macos():
        return "libpq.5.dylib,libpq.dylib,/opt/homebrew/opt/libpq/lib/libpq.5.dylib,/usr/local/opt/libpq/lib/libpq.5.dylib"
    else:
        return "libpq.dll"
```

- `_candidates()` は `String(_default_candidates())` を `split(",")` する（既存のまま）。`from std.sys.info import CompilationTarget` を足し、`platform_map` の import を消す
- `libpq.dll` の探索は `LoadLibrary` の既定順（実行ファイルのディレクトリ → System32 → PATH）。`PQ_MOJO_LIBPQ` はフルパスでそのまま。`OwnedDLHandle` の Windows 実装は未検証（README の「未検証」に含める）
- 検証: `pixi run hello-libpq` と `tests/test_loader_fail.mojo`（候補が全部失敗する経路）が変わらないこと。チェックリスト: `grep -c "libpq.dll" src/pq/_ffi/loader.mojo` 0 → 1、`grep -c platform_map src/pq/_ffi/loader.mojo` 2 → 0

### 2.5 `test_zero_copy` の所要（実測 `scratch/turn-001-zerocopy-time.log`）

| 計測 | 結果 |
|---|---|
| `mojo run tests/test_zero_copy.mojo`（`PQ_TEST_CONNINFO` 未設定） | TestSuite `Summary [ 56.293 ]`（12 件、1 件 4.0〜7.6）、壁時計 **1,835 ms** |
| 同、`PQ_TEST_CONNINFO` 設定（`run_tests.sh` と同条件） | `Summary [ 48.866 ]`、壁時計 1,625 ms |
| `mojo run tests/test_result.mojo`（同じ `_connect`、対照） | `Summary [ 65.512 ]`（15 件、1 件 3.7〜7.4）、壁時計 1,871 ms |
| `mojo build` → バイナリ実行 | build 3,140 ms、**実行 52 ms**（`Summary [ 48.829 ]`） |
| 同、`test_result` | build 4,145 ms、実行 76 ms（`Summary [ 71.727 ]`） |

- **TestSuite の `[ n ]` はミリ秒**。較正: `build/final_check.log:48` の `PASS [ 2033.338 ] test_poll_result_counts_while_sleeping`（`pg_sleep(2)` を含む）、`:416` の leak テスト `[ 37376.787 ]`（= 37 s、`run_tests.sh` の「took 74s」の半分弱）
- 1 テスト 3.4〜3.9 **ms** は接続 1 本（`Connection.open` = `PQconnectdb` + `SET DateStyle ...`）の固定費で、`test_result` と同じ。`check` 内「took 2s」はコンパイル込み
- Phase 4 reflect の「`test_zero_copy` 46 s が `check` を支配」も同じ読み違い（46 ms）。`check` を支配しているのは leak 74 s + コンパイル（47 ファイル × 1.5〜4 s）
- **REQ §4.5 の前提（「接続あたりの固定費」「テスト側なら直す」）は空振り**。impl の作業は TRACE に上の表を写すこと（§5 で REQ を訂正済み）

### 2.6 `DROP DATABASE`（docs + 実測 `scratch/turn-001-dropdb-race.log`）

- 構文: `DROP DATABASE [ IF EXISTS ] name [ [ WITH ] ( FORCE ) ]`（PG14 docs https://www.postgresql.org/docs/14/sql-dropdatabase.html。FORCE は PG13 で導入、
  https://www.postgresql.org/docs/13/sql-dropdatabase.html）。PG17 も同じ（https://www.postgresql.org/docs/current/sql-dropdatabase.html）
- 制約（docs 原文の要旨）: 「対象 DB に接続した状態では実行できない（`postgres` など他の DB に接続して発行する）」「トランザクションブロック内では実行できない」
  「FORCE は既存接続の終了を試みる。prepared transaction / 論理レプリケーションスロット / サブスクリプションがあると終了しない。接続が残る場合は失敗する」
- 実測（PG17 17.11 / PG14 14.24、`CREATE` → 接続 → `SELECT 1` → `close()` → 直後に `DROP`、各 10 回）: **FORCE 無し 10/10 成功、FORCE 有り 10/10 成功、所要 4〜10 ms**。
  `PQfinish` 後の backend 終了は DROP より速い（psycopg でも libpq の `PQfinish` なので Mojo と同じ経路）
- `IF EXISTS` で不在のとき: サーバーは NOTICE `database "..." does not exist, skipping` を返す。pq は notice processor を設定していないので libpq の既定が **stderr に `NOTICE:` 行**を出す。
  `check` 6/6 のパターン（`warning:|WARNING:|implicit ROLLBACK failed`）には当たらない。ログを汚したくなければ `SELECT 1 FROM pg_database WHERE datname = 'pq_test_ascii'` で先に見る（任意）
- 推奨形（REQ §4.7）: 2 テストとも `_ascii_conninfo()` の先頭で `DROP DATABASE IF EXISTS pq_test_ascii WITH (FORCE)` → `CREATE DATABASE ...`、末尾で `_ = listener^` / `_ = sender^` の後に
  `DROP DATABASE pq_test_ascii WITH (FORCE)`。末尾の DROP は `try / except` で握り、元の結果（assert の失敗）を隠さない（`raises` の後に DROP を置くと assert 失敗で DROP が飛ばされる →
  先頭の `IF EXISTS` がそれを回収する設計）。発行は `pq_test` に繋いだ `Connection`（`_open(_conninfo())`）から。**`conn.transaction()` の中では発行しない**
- 検証: `psql -l` 相当 = `SELECT datname FROM pg_database WHERE datname LIKE 'pq_test_%'` を `pixi run test` 後に両サーバーで実行して 0 行（verify の申し送りどおり）。
  陽性対照: 末尾の DROP をコメントアウトした scratch 版で 1 行残ることを 1 回見る
- `db-reset`: `db-reset = { depends-on = ["db-down", "db-up"] }`（pixi は `depends-on` を列挙順に実行）。`db-down` の `-v` でボリュームが消え、fixtures（`schema.sql`）が再適用される

### 2.7 `fetch_all` の busy-spin と `_after_send` の `PQflush` -1（libpq ソース + 実測 `scratch/turn-001-probe-closefd.log`）

libpq（REL_18_STABLE）の事実:

- `PQflush`（fe-exec.c）: `if (!conn || conn->status == CONNECTION_BAD) return -1; return pqFlush(conn);`。`pqFlush` は `outCount > 0` なら `pqSendSome`、でなければ 0
- `pqSendSome`（fe-misc.c）: `sock == PGINVALID_SOCKET` → `write_failed = true` + 「connection not open」+ `outCount = 0` + **return 0**。送信エラーは `pqsecure_raw_write`（fe-secure.c）が
  `EPIPE` / `ECONNRESET` / **default（EBADF 含む）** のすべてで `write_failed = true` + `write_err_msg` 保存 + **`n = len`（成功したことにする）**（理由コメント: 「サーバーからエラー文を読める可能性がある間は
  書き込み失敗を報告しない」）。-1 を返すのは `pqReadData` が失敗したときと、ブロッキングモードの `pqWait` 失敗だけ
- `pqReadData`（fe-misc.c）: `recv` の errno が接続断系（`ECONNRESET` 等）なら `pqDropConnection` + **`status = CONNECTION_BAD`** + -1。**それ以外（EBADF 等）は -1 を返すが status は変えない**。
  EOF は「server closed the connection unexpectedly」+ BAD
- `PQconsumeInput`: 非ブロッキングなら `pqFlush` が < 0 で 0、`pqReadData` が < 0 で 0、他は 1
- `PQsendQueryStart`: `status != CONNECTION_OK` → 「no connection to the server」で 0。成功後は `pqAppendCmdQueueEntry` で `PGASYNC_BUSY`

実測（probe-closefd、pg17）:

| ケース | 観測 |
|---|---|
| A: BUSY 中に `close(PQsocket)` → `fetch_all(1500)` | `PQstatus` は OK のまま。**1500 ms 後に `TIMEOUT`（`fetch_all timed out after 1500 ms`）**。state は BUSY のまま、`PQflush` = 0 |
| B: IDLE で `close(PQsocket)` → `send("SELECT 1")` | **成功**（state BUSY、`PQflush` = 0、status OK）。16 MB の 2 回目は `USAGE`（BUSY 中） |
| C: `close(PQsocket)` → `wait_readable(100)` | `USAGE` `poll: fd 7 is not open (POLLNVAL)`（`poll_socket` の既存経路） |

- **A が REQ §4.5 の busy-spin そのもの**: `poll_result` → `PQconsumeInput` = 0 → `_connection_error()`（`CONNECTION`）→ `PQstatus != BAD` → `continue` → 待たずに再試行 → 予算切れまで CPU を回す。
  `timeout_ms = -1` なら無限。修正（`kind == CONNECTION` なら status を見ずに break）後は **1 回目の `CONNECTION` を即 raise**（経過 < 50 ms、message は libpq の
  `could not receive data from server: Bad file descriptor`）。state は BUSY のまま（既存の「切断時に BUSY のまま返る」残留リスクと同じ。次の `poll_result` で IDLE）
- **テストの形**（test_async に 1 件）: `connect_blocking` → `send("SELECT pg_sleep(0.3)")` → `external_call["close", c_int](c_int(conn.socket()))` → `monotonic()` を挟んで `fetch_all(2000)` →
  `kind == CONNECTION` かつ経過 < 500 ms。注意: close 後〜`__del__`（`PQfinish`）の間に fd を開かない（同じ番号を再利用して無関係な fd を閉じるのを避ける）。`PQfinish` が閉じた fd を再度 close するのは
  EBADF で無害。`external_call["close"]` は `test_poll.mojo:55` と同じ 1 シグネチャ（stdlib と衝突しない。Phase 4 §0.5）。**この 1 件は PG14 / PG17 で同じ**（libpq 側の挙動）
- **`_after_send` の `PQflush` -1 は到達不能**: `PQsendQuery` が成功 = status OK かつ送信エラーは「成功扱い」→ 直後の `PQflush` は 0 か 1。-1 は status BAD のときだけで、同一スレッドで
  `PQsendQuery` と `PQflush` の間に status が変わる経路は無い（実測 B でも 0）。REQ §4.5 の「到達困難なら陽性対照はコードレビュー」を採る。分岐は入れる（-1 → `BUSY`、docstring に
  「libpq は `PGASYNC_BUSY` なので次の `send` は libpq の `another command is already in progress` になる。`BUSY` にしておけば pq の `USAGE` が先に出る」）
- Phase 4 RESEARCH §0-7「切断後の `PQflush` = -1」は `status == CONNECTION_BAD` の分岐（上の `PQflush` 先頭）で説明がつく。矛盾なし

### 2.8 `notifications()` / `wait_notification()` on BAD（実測 `scratch/turn-001-probe-notify-bad.log`）

- `pg_terminate_backend` 後、2 回目の `notifications()` で `CONNECTION`（1 回目は EOF 未到達で成功 = `test_notifications_reports_a_lost_connection` のとおり）。`PQstatus` = BAD、`PQsocket` = -1
- **BAD 後の呼び出しは毎回 `CONNECTION` を投げる（空リストは返さない）**。ただし message が `server closed the connection unexpectedly ...` + `connection not open` × (呼び出し回数 − 1) と**伸びる**
  （`PQconsumeInput` → `pqReadData` が「connection not open」を `errorMessage` に追記するため）。`wait_notification` も同じ（3 行）
- REQ §4.6 の先行チェックの効果 = **文言の固定**: `if PQstatus == CONNECTION_BAD: raise PgError(CONNECTION, "notifications() on a lost connection")`（文言は plan）。テスト: BAD にした後
  `notifications()` を 3 回呼び、3 回とも `kind == CONNECTION` かつ **message が同一**（または pq の固定文言で始まる）。陽性対照: 先行チェックを外すと 3 回目の message が 2 回目より長い（上のログ）
- `wait_notification` / 新 `wait_notifications` は `notifications()` を呼ぶので同じ経路で `CONNECTION` になる（先行チェックは 1 箇所で足りる）

### 2.9 examples の堅牢性（実測 `scratch/turn-001-examples-robust.log`）

| example | 誤パスワード | 閉じたポート（54390） | libpq 不在 / 不正 conninfo |
|---|---|---|---|
| basic / params / binary / bench_formats | `failed: PgError(kind=Connection, message=connection to server at "127.0.0.1", port 54317 failed: FATAL: password authentication failed ...)` rc=1 | `... Connection refused / Is the server running ...` rc=1 | `failed: PgError(kind=LibpqLoad, ...)` rc=1 / `invalid integer value "abc" for connection option "port"` rc=1 |
| async_query / listen_notify | `failed: PgError(kind=Connection, message=FATAL: password authentication failed ...)` rc=1（**`connection to server at` の前置きが無い**: 非同期接続の libpq 文言） | `... Connection refused ...` rc=1 | — |
| **hello_libpq** | — | — | **`stack trace was not collected. Enable ... MODULAR_DEBUG=stack-trace-on-error` + `Unhandled exception caught during execution: PgError(kind=LibpqLoad, ...)` + mojo の `error: execution exited with a non-zero result: 1`**（rc=1 だが 3 行の未捕捉出力） |

- 直すのは `hello_libpq.mojo` の `main`（`raise Error(String(e))` → `print("failed:", e); exit(1)`、`def main():` に）。他 6 本は REQ §5 を満たす
- 検証: 上のスクリプトを impl が再実行して `unhandled_markers=0` が 15/15（現状 14/15）。verify はこのスクリプトを「格子」として流用できる（`scratch/turn-001-examples-robust.sh`。
  所要 ≈ 15 本 × 4 s = 60 s）
- README のクイックスタートは `failed: PgError(kind=Connection, ...)` の形だけを約束し、libpq 文言（前置きの有無）は約束しない
- docstring の総点検（REQ §4.3）: 7 本とも先頭 docstring に「何を見せるか」「`PQ_TEST_CONNINFO` / 既定の接続先」「`PgError` は印字して非 0」が**既にある**（`hello_libpq` は「実行方法」が無い）。
  `pixi run hello-libpq` / `example-*` / `bench` の名前を各 docstring に 1 行足せば REQ §4.3 の「実行方法」が揃う

### 2.10 `PgErrorKind.ENCODING` の影響範囲（grep。plan のチェックリスト用の基線）

- `grep -rn 'invalid UTF-8'` のファイル: `src/pq/decode_binary.mojo`（`_validated_utf8` の raise 2 箇所 `:343` / `:347` + docstring `:41` / `:329`）、`src/pq/async_conn.mojo`
  （`_reject_bad_notification_text` の raise 2 箇所 `:295` / `:299` + docstring `:267` / `:281` / `:1362` / `:1373` / `:1562`）、`src/pq/__init__.mojo`（`:35` / `:122` / `:254` / `:285` / `:286`）、
  `src/pq/result.mojo`（docstring `:543` / `:848` / `:854`）、`tests/test_notify.mojo`（`:492` / `:534` の `TYPE_MISMATCH` 断定 2 件）、`tests/test_decode_binary.mojo`（`:466`〜`:537` の UTF-8 系 8 件。
  kind を断定している行は plan が `grep -n "TYPE_MISMATCH" tests/test_decode_binary.mojo` で選ぶ。OID 不一致・長さ不一致の `TYPE_MISMATCH` は残す）、`tests/test_zero_copy.mojo:487`（正常側のみ、kind 断定なし）
- `grep -c TYPE_MISMATCH` の基線（陽性対照に使う。全ファイル合計）: **tests 97、src 125**（ファイル別は `scratch` には無い → plan が `turn-002-checklist.sh` で取り直す）
- `errors.mojo`: docstring「exactly seven constants」→ eight、`write_to` に `Encoding` 分岐、`comptime ENCODING = Self(7)`。`tests/test_errors.mojo` が名前一覧を断定していれば追加
- `__init__.mojo` の `## PgErrorKind` 節と API 表（`notifications()` / `wait_notification` の `TYPE_MISMATCH (channel or payload is not UTF-8)` → `ENCODING`）、README のエラー一覧に反映
- UTF-8 スキャナの 4 バイト境界（REQ §4.6 テスト）: `_utf8_first_invalid` の単体は `test_decode_binary.mojo:510` `test_utf8_first_invalid_finds_each_malformed_input` に格子がある → `f4 90 80 80`
  （U+110000、不正）と `f5 80 80 80`（不正先頭バイト）の 2 行を**同じ格子に足す**（期待オフセットはどちらも 0。`f4 8f bf bf` = U+10FFFF が正常側の対照）

### 2.11 Apache-2.0 の取得

- https://www.apache.org/licenses/LICENSE-2.0.txt（§1.4）。impl は本文を `LICENSE` に書く。検証: `head -3 LICENSE` が `Apache License` / `Version 2.0, January 2004` / `http://www.apache.org/licenses/`、
  `grep -c "APPENDIX" LICENSE` = 1、`wc -l LICENSE` ≈ 200（公式は 202 行）

## 3. 盗める設計 / 使えるライブラリ（plan が採否表にする）

1. **psycopg bench の境界**（§1.1）: `execute` = exec、`fetchall` + 全セル読み = decode。`autocommit=True`。`examples/bench_psycopg.py` はプローブ版をそのまま採用できる
2. **`WSAGetLastError` の読み方**: `_poll_once` の `else` で `var err = external_call["WSAGetLastError", c_int]()` を読んで `(ret, flags, Int(err))` の 3 要素で返す、または Windows 側で
   `ret < 0` のとき `flags` の代わりに負のエラーコードを返す。推奨は **3 要素タプル**（POSIX 側は `get_errno().value` を同じ位置に入れる）。`poll_socket` 側は `err` を OS 別定数と比べる:
   POSIX `EINTR` 再試行 / `EBADF` `EINVAL` → `USAGE`、Windows `10022` `10038` `10009` → `USAGE`、他 → `CONNECTION`。`ErrNo` は Windows で意味が無いので `comptime if` の中でだけ使う
3. **`comptime if` 連鎖の候補関数**（§2.4）: `platform_map` を消す
4. **`DROP DATABASE IF EXISTS ... WITH (FORCE)`** を先頭と末尾に（§2.6）。末尾は try で握る
5. **`fetch_all` の `kind == CONNECTION` で break**（§2.7）。`first_error` に入れてから break するので raise される値は変わらない
6. **`notifications()` の先行チェック**（§2.8）: `self._reject_connecting(...)` の直後に `PQstatus` を見る
7. **`wait_notifications(n, timeout_ms)`**: `wait_notification` の本体を「n 件集まるまで」に一般化し、`wait_notification` は `wait_notifications(1, timeout_ms)` の先頭要素（`Optional`）にする、
   または 2 本を別に書く。推奨は**一般化 + 薄い `wait_notification`**（`_pending` の扱いが 1 箇所になる。既存 `test_notify` 11 件が回帰）。`found` を `_pending` に戻す順序は現状と同じ
   （余りは先頭から `_pending.append`）
8. **README の節立て**（REQ §4.2 の順）+ 型表は `__init__.mojo:42-62` を日本語見出しで転記（verify が照合）。`PgErrorKind` 一覧は `errors.mojo` の 8 値 + `__init__.mojo` の `## PgErrorKind` 節
9. **examples 堅牢性スクリプト**（§2.9）を `tests/` に入れるか: 入れない（`check` の所要 +60 s。verify の格子として scratch に残す）

## 4. 落とし穴と検証方法（plan は完了基準に写す）

| # | 落とし穴 | 回避 | どう検証すれば踏んでいないと分かるか |
|---|---|---|---|
| P1 | `fetch_all` の busy-spin（§2.7 A） | `except e:` で `kind == CONNECTION` なら break | test_async 1 件: `close(socket)` 後の `fetch_all(2000)` が `CONNECTION` かつ経過 < 500 ms。陽性対照: 修正前は 2000 ms 後 `TIMEOUT`（`probe-closefd.log` A） |
| P2 | 閉じた fd の再利用（P1 のテスト） | close 〜 `__del__` の間に fd を開かない。テスト末尾で `_ = conn^` を最後に | コードレビュー（テスト本文に接続・ファイル open が無い） |
| P3 | `_after_send` の -1 分岐が到達不能 | 分岐は入れ、陽性対照はコードレビュー（REQ §4.5） | TRACE に §2.7 の libpq 根拠（`PQflush` 先頭、`pqsecure_raw_write` の「成功扱い」）を書く。`grep -c "flushed == -1\|else:" ` 等で分岐の存在 |
| P4 | `notifications()` の文言が呼ぶたびに伸びる（§2.8） | `PQstatus == CONNECTION_BAD` を先に見て pq 文言で raise | test_notify 1 件: BAD 後 3 回とも同一 message。陽性対照: 先行チェック無しだと 3 回目 > 2 回目（`probe-notify-bad.log`） |
| P5 | `DROP DATABASE` を対象 DB への接続から / tx 内から発行 | `pq_test` の `Connection.execute`（autocommit） | SQLSTATE `55006` / `25001` が出ないこと（テスト PASS）。`pg_database` に `pq_test_ascii` が残らない（両サーバー） |
| P6 | 末尾の DROP が assert 失敗で飛ぶ → DB が残る | 先頭の `IF EXISTS` で回収 + 末尾は try で握る | 陽性対照: assert を一時的に失敗させた scratch 版で 2 回目の実行が PASS する |
| P7 | `IF EXISTS` の NOTICE が stderr に出る | 許容（`check` 6/6 のパターン外） | `check` 6/6 `matched lines: 0` |
| P8 | `ENCODING` の取りこぼし（UTF-8 の raise が `TYPE_MISMATCH` のまま残る） | §2.10 の 4 raise 箇所 + docstring | `grep -rn "invalid UTF-8" src tests` の全行に `TYPE_MISMATCH` が無い。`grep -c TYPE_MISMATCH` が tests 97 → 97 − (期待値変更数)、src 125 → 125 − (raise 4 + docstring N) |
| P9 | `wait_notifications` の `n` / `timeout_ms` 境界 | `n < 1` → `USAGE`、`timeout_ms` は `_reject_bad_timeout` | 格子: `n ∈ {0, -1, 1, 2, Int.MAX}`、`timeout_ms ∈ {-2, -1, 0, 200, TIMEOUT_MS_MAX, TIMEOUT_MS_MAX+1, 2**32}`。`n = Int.MAX, timeout_ms = 200` は 200 ms で部分返却 |
| P10 | `wait_notifications` の `_pending` 順序（1 往復で余った通知が次回に先に出る） | `found` の余りを `_pending` に append（現状の順序） | test_notify 1 件: 2 件 NOTIFY → `wait_notifications(1)` → `wait_notification` が 2 件目を待たずに返す（既存 `test_second_wait_notification_answers_without_waiting` の n 版） |
| P11 | Windows の `get_errno()`（§2.3 #6） | `WSAGetLastError` | 照合表 #6 の行が TRACE にあり、`grep -c WSAGetLastError src/pq/_platform/poll.mojo` = 1。Linux の `test_poll` 11 件が不変 |
| P12 | `else` 分岐は Linux で型検査されない | scratch で `if True:` 側に複製して `mojo build` | TRACE に「複製ビルドの結果」1 行（通らなければその旨） |
| P13 | `platform_map` の削除で macOS の候補を落とす | 4 候補を `elif` に全部移す | `grep -c "/opt/homebrew/opt/libpq" src/pq/_ffi/loader.mojo` = 1 のまま |
| P14 | bench の揺れ（exec ±5 ms） | README は 3 回の値を並べる or 中央値。計測は `check` 直後ではなくアイドル時 | verify が再実行して decode の binary < text だけを断定 |
| P15 | `pixi run bench-psycopg` の初回が環境作成で遅い / オフラインで失敗 | README に「初回は `pixi install -e bench` 相当で 1 分」 | `pixi list -e bench` に `psycopg-c` がある |
| P16 | `pixi.lock` の差分が大きい（3 プラットフォーム × bench） | 1 コミットにまとめる | `git diff --stat pixi.lock` を PROGRESS に 1 行 |
| P17 | `hello_libpq` の `raise Error`（§2.9） | 他 6 本と同じ `try / except / exit(1)` | `turn-001-examples-robust.sh` 再実行で `unhandled_markers=0` 15/15 |
| P18 | README のコード片が examples と乖離 | 抜粋元ファイル名を各コード片に書く | verify が `examples/` の該当行と照合（REQ §5） |
| P19 | `check` の所要 | 新テスト: test_async +1（≤ 0.5 s）、test_notify +5〜6（DROP/CREATE 2 回 ≈ 0.3 s、通知待ち ≤ 1 s）、test_decode_binary +2（0 s）、test_errors +1 | 見込み `check` = 167〜187 + ≤ 10 s。超えたら PROGRESS |
| P20 | TestSuite の単位（ms）の再読み違い | PROGRESS / TRACE に時間を書くとき単位を明記 | reflect が確認 |

## 5. 要件への影響

- **REQ 本文を 2 箇所訂正した**（REQ §9「矛盾を見つけたら REQ 本文を直してよい」）:
  1. §1「pixi 環境には python が無い」→ python 3.15.0 は mojo の依存で入っている（psycopg が無いだけ）。D2 の結論（feature で足す）は変わらない
  2. §1 / §4.5「`test_zero_copy` が 1 テスト 3.4〜3.9 s（接続固定費）」→ **ms**。§4.5 は「原因特定済み。TRACE に転記のみ」に書き換えた。D12 の分岐（テスト側 / src 側）はどちらにも入らず「問題なし」
- 提案（REQUIREMENTS には書かない。plan が採否）:
  - §4.4 に「`WSAGetLastError` への置き換え」を照合結果として明記（§2.3 #6）。README の Windows 節に「Windows 10 2004 より前は非同期接続の失敗がタイムアウトまで分からない」（#8）
  - §4.6 `notifications()` 先行チェックのテストは「message が呼ぶたびに伸びない」を断定する（§2.8。これが唯一の差分）
  - §4.5 `fetch_all` のテストは `close(PQsocket)` 方式（§2.7）。`pg_terminate_backend` 方式は status が BAD になるので旧分岐でも止まり、差分が出ない
  - §4.7 の DROP は `WITH (FORCE)` 付き（§2.6）
  - §4.3 の「実行方法」は docstring に `pixi run <task>` を 1 行（§2.9）
  - §4.1 README の表: psycopg の実装（`c`）・python 版も環境欄に（§1.1）
- BLOCKED にする発見: なし

## 6. plan への申し送り

- **タスク分割の提案**（REQ §9「持ち越し整理は T1 に 1 コミット」を踏まえて）:
  T1 持ち越し + 後始末（`fetch_all` break / `_after_send` -1 / test_notify の DROP / `db-reset` / `hello_libpq` 修正 / zero_copy の TRACE 転記）、
  T2 `ENCODING` + 契約外 7 件（errors.mojo / 4 raise / docstring / `notifications()` 先行チェック / `wait_notifications` / テスト 4 + 境界格子）、
  T3 Windows（poll.mojo #6 / loader.mojo / 照合表 TRACE / 複製ビルド）、
  T4 bench（pixi feature / `examples/bench_psycopg.py` / 実測ログ）、
  T5 README + LICENSE + examples docstring、
  T6 統合（`check` / examples 格子 / `pg_database` 確認 / 未確認行の処分表）
- **サブエージェント**: T2 は「src 2 ファイル + tests 3 ファイル」なので 1 本（テスト側）を既定、他は 0 本（親が全部）。T5 の README は親が書く（verify が実装と照合するので転記元を把握している親が有利）
- **チェックリスト（`turn-002-checklist.sh` の key 候補と期待値）**: `loader_libpq_dll=1`、`loader_platform_map=0`、`poll_WSAGetLastError=1`、`poll_external_call_symbols=3`（`poll` / `WSAPoll` / `WSAGetLastError`）、
  `errors_kind_count=8`、`src_invalid_utf8_type_mismatch=0`、`tests_invalid_utf8_type_mismatch=0`、`lock_psycopg_c≥3`、`pixi_tasks_bench_psycopg=1`、`pixi_tasks_db_reset=1`、`notify_drop_database=2`、
  `examples_raise_error=0`（`grep -c "raise Error" examples/*.mojo`）、`readme_sections≥10`、`license_head=Apache License`、`test_async_tests=31`（30 + P1）、
  `test_notify_tests=11 + 新規件数`（plan が §4.6 の件数で確定。先行チェック 1 + `wait_notifications` 4〜5 + UNLISTEN / 未 LISTEN / Mixed Case 3）、`test_decode_binary_tests=90`（88 + 2）
- **所要見積もり**: `check` 167〜187 + ≤ 10 s（P19）。bench 2 本 ≈ 20 s + bench 環境作成 1 分（初回）。examples 格子 60 s。`test_zero_copy` 対応は 0 s（転記のみ）
- **陽性対照を完了基準に**: P1（`probe-closefd.log` A の `TIMEOUT` → `CONNECTION`）、P4（message 長）、P6（DROP を外した scratch）、P8（`grep -c TYPE_MISMATCH` の増減）、P17（格子 15/15）
- **README の計測環境欄（そのまま使える）**: Ubuntu 24.04.5 LTS (kernel 6.8.0-147, aarch64, 4 コア仮想マシン, 15 GiB) / Mojo 1.1.0 (8189361e) / libpq 18.6 (conda-forge) / PostgreSQL 17.11 (docker `postgres:17`) /
  psycopg 3.3.4 + psycopg-c 3.3.4 (conda-forge, python 3.14.8) / 2026-10-NN（impl の実測日）
- **impl への注意**: bench は `check` の直後に測らない（コンパイルの残熱で exec が 5〜10 ms 振れる）。README の数値は `scratch/turn-NNN-bench.log` から転記し、PROGRESS にパスを書く
- **verify への注意**: Windows 照合表は URL の 12 行を TRACE と突き合わせる。`pg_database` の確認は両サーバー。README の型表は `__init__.mojo:42-62` と、`PgErrorKind` は `errors.mojo` と
