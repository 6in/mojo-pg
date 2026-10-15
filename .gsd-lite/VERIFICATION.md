# VERIFICATION — phase1-sync-text-basic

## round 1（turn 11, 2026-10-15）— 判定: **差し戻し**（指摘 3 件 → F1 / F2 / F3）

- 対象: `git diff main...HEAD`（28 ファイル, +5,520 / −52）。コードは `src/pq`（9 ファイル）、`tests/`（8 本 + 2 スクリプト）、`examples/`、`pixi.toml`
- 実行エンジン: Claude Code（verify = claude-fable-5-1）。並列レビュー: コードレビュー / セキュリティの 2 サブエージェント（読み取り専用）+ 親の堅牢性プローブと機械判定
- `CLAUDE.md` / `AGENTS.md` は対象リポジトリに無い

### 機械判定（クリーンな木、コミット `a0ec2c7` から）

| 検査 | 結果 |
|---|---|
| `pixi run db-up` → `pixi run check` | **6/6 PASS**（21:52:24 → 21:53:54、90 s） |
| 5/6 テスト | **210 PASS / 0 FAIL**（105 × PG17 / PG14。`test_leak` 40 s / 38 s、他は ≤ 1 s） |
| 3/6 docstring 診断（`_ffi` と合成 dunder 除外） | 0 件 |
| 1/6 fmt | 差分なし（`git status` も clean） |
| 6/6 `warning:` | 0 件 |
| 追従先チェックリスト 7 行 | 全一致: バインディング 50 本（`functions.mojo` 50 / `test_ffi.mojo` 50 / `assert_equal(len(names), 50)` / PLAN「50 本」5 箇所）、`Int16` 4 ファイル、`TYPE_MISMATCH` 3、`examples/` 2 箇所、`get_function` 9 ファイル 0、`PQfreemem` `connection.mojo:317` / `:356` の 2 回、`fn ` 0 件 |
| リークサンプル（check ログ） | PG17 本体 `[37770, 37772 ×6, 37855, 37855]`、PG14 `[37748, 37833 ×8]`。異常系 3 ループは全サーバーで完全に平坦。+83 ページの一段が今回も両サーバーで 1 回ずつ |

### 受け入れ基準の達成状況（REQ §5）

| 項目 | 状況 |
|---|---|
| §5.1 両サーバーで全テスト PASS | ✓ |
| §5.1 警告ゼロ、`fn` 不使用 | ✓ |
| §5.1 誤パスワードで `CONNECTION`、メッセージにパスワード無し | ✓（`test_connection.mojo:384-403`。親プローブでも 9 経路の失敗メッセージに `password=` / `WRONG` は出ない） |
| §5.1 受け入れクエリ 6 列の型取得 | ✓（`test_result.mojo` acceptance 2 本） |
| §5.1 構文エラーで `sqlstate == "42601"` | ✓ |
| §5.1 10,000 回ループでメモリが単調増加しない | テストは PASS するが **テストがリークを検出できない**（下記 指摘 1）。基準の達成はこのラウンドでは未証明 |
| §5.1b docstring / fmt / `examples/basic.mojo` / パッケージビルド | ✓（`.mojopkg` は 1.1.0 で不可能なため `.mojoc`。決めた事項 8 の文書化済み逸脱） |
| §5.2 どの入力でもクラッシュせず `PgError` | ✓（下記 堅牢性プローブ。トレースバック 0 件） |
| §5.2 `PQclear` / `PQfinish` / `PQfreemem` が両経路で呼ばれ二重解放しない | コードレビューで全経路を静的に確認 ✓。動的な証拠（リークテスト）は指摘 1 のとおり無効 |
| §5.2 解放済みポインタへのアクセスが型上起こらない | ✓（`Row[origin]`、scratch の負のコンパイル確認 turn 6 / 7） |

### 観点ごとの確認

**コードレビュー（サブエージェント + 親）**
- FFI 境界: `String` → `const char*` の 6 箇所すべてで所有 `String` を呼び出し後まで生存（`_ = x^`）、`char*` → `String` の全箇所で `PQclear` / `PQfreemem` / `PQfinish` の前にコピー。`open(Dict)` のキー/値配列は NUL 終端、`as_c_string_span()` の再確保後にポインタ採取。バグなし
- 50 本のシグネチャ: `libpq-fe.h` のプロトタイプ・行番号・PLAN 表の 3 者と全一致。`OptCStr` は PLAN の 6 関数に限定、`Oid` → `UInt32`、`size_t` → `c_size_t`
- 範囲検査: 行 / 列 / セルすべて libpq 呼び出し前に拒否。`RowIter` は 0..nrows-1 を正確に 1 回ずつ
- `decode_text`: 境界・OID 完全一致・bytea hex の検査はすべて PLAN どおり。`Float32(atof())` の二重丸めはレビュー側の 2,000 万件プローブで不一致 0

**セキュリティ**
- 秘密情報: ハードコードはテスト既定（`pq/pq@127.0.0.1`）のみ。`src/pq` の全 `raise PgError` を追跡し、conninfo / params / password を埋め込む経路は無い
- インジェクション: `execute` は補間しない。`escape_*` は libpq に委譲。埋め込み NUL でも libpq 自身が NUL で止まるので出力は常に閉じた引用（未終端リテラルにはならない）
- ロード: `PQ_MOJO_LIBPQ` は環境と同じ信頼レベル（setuid 文脈でのみ問題）。`RTLD.GLOBAL` は stdlib 既定で、追加したのは `NODELETE` のみ。バージョンゲートの前に呼ぶ libpq 関数は `PQlibVersion` だけ ✓
- **指摘**: `tests/docker-compose.yml` が `0.0.0.0:54317/54314` で superuser を LAN に公開（Phase 0 からの既存ファイルだが 1 行で直る → F3）

**堅牢性プローブ（round 1 の格子。scratch `turn-011-probe-robust.mojo` / `turn-011-probe-badlib.mojo`）**

| 入力経路 | 試した値 | 結果 |
|---|---|---|
| conninfo String | 空 / 空白のみ / 不明キー / 未終端引用 / `connect_timeout=abc` / NUL 埋め込み / 誤パスワード / URI / 100 KB の `application_name` | 全部 `CONNECTION`（URI と NUL は接続成功）。秘密情報の漏れ 0 |
| Dict params | 空 Dict / 空キー / 空白入りキー / 値に NUL / 値に `=` 空白 引用符 | 全部 `CONNECTION` か成功。漏れ 0 |
| SQL | コメントのみ / `;;;` / `COPY TO STDOUT` / `COPY FROM STDIN` / 1/0 / NOTICE / WARNING / NUL 埋め込み / 1 MiB リテラル / 10 列 / `RAISE ... USING DETAIL, HINT` / 中断トランザクション | `empty query` / `unexpected result status 3, 4`（次の `execute` で回復）/ 22012 / P0001。クラッシュ 0 |
| 列名 | 空 / NUL 埋め込み / `"A"` | `TYPE_MISMATCH` か index（NUL は NUL までの名前で一致 = 無言の切り詰め） |
| escape | 空 / NUL / NUL のみ / マルチバイト+引用符+バックスラッシュ / 1 MiB | 全部成功（` E'日本語''x\\y'` 等）。NUL は NUL までで切り詰め |
| `PQ_MOJO_LIBPQ` | `libc.so.6`（ELF だが libpq でない）/ `/etc/hostname`（非 ELF）/ ディレクトリ | 全部 `LibpqLoad`（`missing symbol PQconnectdb` / `file too short` / `Is a directory`）。2 回目も同じ kind |
| 出力経路（`examples/basic.mojo`） | stdout を `/dev/full` / 先に閉じたパイプ | exit 0（書き込み失敗は無視される。例であり要件外、記録のみ） |

例外クラス: 公開 API は `raises PgError` の型付きなので他の例外は型上漏れない。`atol` / `atof` / `affected_rows` は内部で捕捉済み

**文書の主張**: PLAN / PROGRESS の件数（50 本、105 × 2、`PQfreemem` 2、tolerance 256 / 16）は現状と一致。docstring の過大な主張は F2 / F3 に列挙（「Any byte sequence」「standard_conforming_strings に従う」「conninfo を echo しない」、`test_leak.mojo` の「100 バイト/回でも検出」「CI runs Linux」、`test_connection.mojo:424` の古いコメント）

**期待値の変更**: impl が PROGRESS に書いたとおり、既存テストの期待値変更は turn 4 の `test_smoke.mojo` 2 本（ローダー経由化）のみで妥当

### 指摘（差し戻し理由）

1. **リークテストが偽陰性**（F1）。`src/pq` のコピーから `Result.__deinit__` の `PQclear` を消して `tests/test_leak.mojo` を回しても **8 本 PASS**、本体ループのサンプルは `[37765, 37767 ×8]` で完全に平坦（warm cache、実運用と同じ baseline）。
   `mojo run` の同一プロセス内コンパイラが残す解放済みヒープ（≈100 MB 超、常駐）が 10,000 個の `PGresult` を吸収する。REQ §5.1 の「メモリが単調増加しない」の証拠としてこのテストは機能していない。
   impl の turn 9 申し送り「陽性側は未実証」をそのまま検証した結果。この指摘は「テストが完了基準を実際に検証しているか」の観点で、要件追加ではない
2. **接続断の 1 回目が `SERVER`**（F2a）。REQ §4.3 は接続断を `CONNECTION` に分類する意図だが、libpq は非 NULL の `PGRES_FATAL_ERROR`（sqlstate 空）を返すので 1 回目は `SERVER`。`PgErrorKind.CONNECTION` の docstring「connection is no longer usable」と矛盾する。turn 6 / 8 の申し送りの判断: **CONNECTION に寄せる**（決めた事項 6 に 1 行追加。1 行の規則で E8 / E9 を壊さない）
3. **埋め込み NUL の無言の切り詰め**（F2b）。8 経路すべてで NUL 以降が黙って捨てられる（`execute("SELECT 1\0; SELECT 2")` は `SELECT 1` だけ実行、password の値に NUL があれば以降が消える）。クラッシュも注入も無いが、アプリが検証済みの値が切り詰めて保存される = データ整合性の問題なので差し戻し。docstring「Any byte sequence is accepted」の訂正を含む
4. 軽微（F3 に集約）: docstring 3 件、古いコメント 1 件、`test_libpq_is_a_single_handle` が自明に通る、REQ §4.4 の `detail` / `hint` / `context` を assert するテストが無い、`get[T](name)` の不存在列名 / `get_optional` 列名版のテストが無い、docker-compose の公開先

### 残留リスク（合格扱い。差し戻さない）

- `OID_TEXT` / `OID_VARCHAR` / `OID_BPCHAR` / `OID_NAME` は宣言のみ未使用（`String` は任意 OID。D10 どおり）。消すか Phase 3 で使う
- `PQ_MOJO_LIBPQ` は設定時その 1 本のみでフォールバックしない（REQ §4.1 の「→」の読みと違うが T2 契約 + `test_loader_fail` が依存。loader の docstring に明記済み）。REQ の文言は次の discuss で揃える
- バージョンゲート `< 140000` は runtime 未到達（このマシンに古い libpq が無い）
- `RTLD.GLOBAL`（stdlib 既定）による libssl 等のシンボル干渉は Python 相互運用時の互換リスク。`RTLD.LOCAL` でも動くはず（全シンボルを `dlsym` で引くため）
- `String(unsafe_from_utf8_ptr=)` は検証しないので非 UTF-8 の `client_encoding` では不正な `String` になる（Phase 1 は UTF-8 前提。未記載）
- `Connection.__init__` / `Result.__init__` / `Row.__init__` が公開（NULL は安全、ゴミアドレスは UB。`_ffi` が実質 private なので実害は低い）
- `CONNECTION` 系メッセージは libpq の末尾 `\n` を残し、`SERVER` 系は残さない（表記の不統一）
- +83 ページの一段の出所は未特定（レビューの推測: libpq / OpenSSL のコードページの初回タッチ。RSS はファイル裏付きページも含む）
- `tests/test_ffi.mojo` と `loader.mojo` のパス決定ロジックが二重（turn 4 の申し送り。意図的）
- `examples/basic.mojo` は stdout 書き込み失敗を無視する（例であり要件外）
- `.mojopkg` → `.mojoc`（1.1.0 の制約。決めた事項 8）

## round 2（turn 15, 2026-10-15）— 判定: **合格**（指摘 0 件。main へ `--no-ff` マージ）

- 対象: `git diff main...HEAD`（30 ファイル, +6,355 / −55、コード側は `src/pq` 9 / `tests/` 8 本 + 2 スクリプト + compose / `examples/` 2 / `pixi.toml`）。
  重点は round 1 の差し戻し F1〜F3 の差分（`a0ec2c7..HEAD`: `src/pq` 3 ファイル +144 / −30、`tests/` 5 ファイル + compose）
- 実行エンジン: Claude Code（verify = claude-fable-5-1）。並列レビュー: F1〜F3 差分のコードレビューを読み取り専用サブエージェント 1 本に独立させ、親は機械判定・回帰プローブ・文書照合
- round 1 の申し送りどおり「round 1 の格子の再確認 + F1〜F3 の回帰」だけを行い、新しいクラスの探索はしていない

### 機械判定（クリーンな木、コミット `e7cabe1` から）

| 検査 | 結果 |
|---|---|
| `pixi run db-up` → `pixi run check` | **6/6 PASS**（23:01:15 → 23:02:51、96 s） |
| 5/6 テスト | **228 PASS / 0 FAIL**（114 × PG17 / PG14。connection 28 / decode_text 49 / errors 3 / ffi 7 / leak 8 / loader_fail 1 / result 14 / smoke 4。`test_leak` 42 s / 43 s） |
| 3/6 docstring 診断（`_ffi` と合成 dunder 除外） | 0 件 |
| 1/6 fmt | 差分なし（20 files unchanged、`git status` clean） |
| 6/6 `warning:` | 0 件 |
| 追従先チェックリスト 7 行 | 全一致（round 1 と同値）: バインディング 50 本（`functions.mojo` 50 / `test_ffi.mojo` 50 / PLAN「50 本」5 箇所）、`Int16` 4 ファイル（3/1/1/4）、`TYPE_MISMATCH` 5（≥ 2）、`examples/` `pixi.toml:17` + `final_check.sh:87`、`get_function` 9 ファイル 0、`PQfreemem` `connection.mojo:350` / `:392` の各 1 回、`fn ` 0 件 |
| リークサンプル（check ログ） | PG17 本体 `[37964, 37966 ×8]`、PG14 `[37851, 37853, 37936 ×7]`（+83 の一段 1 回）。異常系 3 ループは両サーバーで完全に平坦 |

### F1〜F3 の回帰（期待結果表 E1〜E16）

| # | 結果 | 根拠 |
|---|---|---|
| E1〜E4 | ✓ **4 本とも自分のループだけ FAIL**、他 3 ループ PASS | 親が `scratch/turn-015-positive-control.sh`（F2 / F3 で動いた行番号を取り直し: `result.mojo:99` / `connection.mojo:129` / `:350` / `:284`）で `src/pq` のコピーから free を 1 つ消して再実測。E1 `[115401, 131411, 147420, 163428, 179500, 196326]` → 6 サンプル目で E6 の早期 fail（grew 80,925 > 65,536）。E2 `[115681, 132074, 148533, 164931]`。E3 `[90418, 93391, 96592, 99794]`。E4 `[97142, 103548, 109954, 116360]`。ログは `scratch/turn-015-positive-E*.log` |
| E5 | ✓ | 無改変で check 1 回（本ターン）+ impl turn 12 の 3 回連続 = 両サーバー 8/8 PASS ×4 |
| E6 | ✓ | E1 で発火を再確認（上記）。E2〜E4 はリーク総量が 256 MiB に届かないので tolerance 側で FAIL する（設計どおり。impl turn 12 の実測と一致） |
| E7 / E8 / E9 | ✓ | `test_terminated_backend_then_connection_error`（1 回目 CONNECTION / sqlstate 空 / message）、`test_syntax_error_fills_diagnostics`（SERVER 42601）、`test_copy_out_stays_a_server_error`（SERVER / `unexpected result status 3` / **`status() == CONNECTION_OK` も assert** = AND の両腕をテストが押さえる）。実装 `connection.mojo:292-294` は `PQclear` の後、`sqlstate == "" and PQstatus == CONNECTION_BAD` の両条件 |
| E10 | ✓ 8 経路 | `_reject_nul` の呼び出しは `open(String)` :155 / `open(Dict)` :188-189（`libpq_ptr()` より前）/ `execute` :245 / `escape_literal` :332 / `escape_identifier` :374 / `column_index` `result.mojo:203`（`Row.get` / `get_optional` の名前版はここに委譲）。テスト 6 本（9 アサート経路）がすべて `TYPE_MISMATCH` / 厳密一致の message / NUL 以降のマーカー不在 / `open` 2 本は password 不在 / `execute`・escape・列名は直後の正常呼び出しで状態不変を assert。`_reject_nul` は `as_bytes()` 全長を走査（NUL で止まらない）し値をメッセージに入れない |
| E11 | ✓ | 既存テストの期待値変更は impl が PROGRESS に列挙した 2 箇所のみ（turn 13 の E7、turn 14 の E14）で、どちらも表の要求そのもの。他 210 本は無変更で PASS |
| E12 / E13 / E14 | ✓ | `test_raise_exception_fills_detail_hint_and_context`（6 フィールド）/ `test_name_lookup_in_get_and_get_optional`（TYPE_MISMATCH ×2 + Some("s") + None）/ `test_libpq_is_a_single_handle` が `Int(libpq_ptr())` のアドレス一致 |
| E15 | ✓ | `docker ps`: `tests-pg14-1 127.0.0.1:54314->5432/tcp` / `tests-pg17-1 127.0.0.1:54317->5432/tcp` のみ |
| E16 | ✓ | 上の機械判定表 |

### round 1 の堅牢性格子の再確認（scratch `turn-011-probe-robust.mojo` / `turn-011-probe-badlib.mojo` を無改変で再実行）

round 1 と同じ結果で、NUL を含む 7 ケース（conninfo / Dict 値 / SQL / 列名 / escape ×3）だけが「無言の切り詰め」→ **`TypeMismatch` `embedded NUL byte in <引数名>`** に変わった。それ以外（空 / 空白 / 不明キー / 未終端引用 / `connect_timeout=abc` / 誤パスワード / URI / 100 KB `application_name` / 空 Dict / 空キー / 空白入りキー / `=` 空白 引用符入り値 / コメントのみ / `COPY TO STDOUT` → 次の `SELECT 1` が成功 / `COPY FROM STDIN`（status 4）→ 次の `SELECT 1` が成功 / 1/0 / NOTICE / WARNING / `;;;` / 中断トランザクション / 1 MiB リテラル / 10 列 / `RAISE ... USING DETAIL, HINT` / 空列名 / `"A"` / 空 escape / マルチバイト / 1 MiB escape）は round 1 と同一。秘密情報の漏れ 0、トレースバック 0。`PQ_MOJO_LIBPQ` に libc / 非 ELF を与えた場合も `LibpqLoad` で 2 回目も同じ kind

### 受け入れ基準の達成状況（REQ §5。round 1 で未証明だった行だけ更新）

| 項目 | 状況 |
|---|---|
| §5.1 10,000 回ループでメモリが単調増加しない | ✓ **証明済み**。無改変で平坦（上表）かつ、4 つの free をそれぞれ消すとそのループだけが FAIL する（E1〜E4）。テストが基準を実際に検証している |
| §5.2 `PQclear` / `PQfinish` / `PQfreemem` が両経路で呼ばれ二重解放しない | ✓ 静的（round 1）+ 動的（E1〜E4 の陽性対照）の両方 |
| §5.2 どの入力でも `PgError`（埋め込み NUL を含む） | ✓ NUL は libpq に渡る前に拒否され、状態は変わらない |
| その他の行 | round 1 のまま ✓ |

### 文書の主張

- PLAN: T7 の所要「43〜47 s/サーバー」は実測 42 / 43 s で一致。決めた事項 6 の表に F2 の行、決めた事項 12 に F1 の追記あり。T4 の実装メモの message は F3 (c) に追従済み（`libpq returned NULL`）。「50 本」5 箇所は実物と一致
- PROGRESS: turn 12〜14 の件数（210 → 224 → 228、114/サーバー）と期待値変更の列挙（2 箇所）は diff と一致
- 差し戻した docstring 6 件（round 1 指摘 4）はすべて訂正済み: `standard_conforming_strings` は「参照されない」に、「Any byte sequence」は「NUL を除く」に、「CI runs Linux」削除、`T5` コメント削除、conninfo echo の注意書き、COPY 未対応の段落
- `tests/test_leak.mojo` の「100 B/回でも検出」は実測どおりの説明（プールが吸収する / payload で押し切る）に置き換わっている

### 残留リスク（合格扱い。差し戻さない。round 1 の一覧に追加する分）

- **`execute` docstring の `CONNECTION` の説明がやや広い**（`connection.mojo:238-240`「the connection was lost while running `sql`」）。規則は「sqlstate 空 **かつ** `CONNECTION_BAD`」なので、sqlstate 付きの FATAL（例: `idle_session_timeout` の 57P05 が届いた場合）が先に来る切断は `SERVER` のまま次の `execute` で `CONNECTION` になる。決めた事項 6 の表は正確。docstring に「sqlstate を伴わない切断」と 1 語足せば閉じる
- `Row.get[T](name)` / `get_optional[T](name)` の docstring は「`col` contains a NUL byte」と書くが、message は委譲先の `column_index` の `"embedded NUL byte in name"`（E10 の `<引数名>` と引数名が 1 段ずれる）。テストはこの `name` を assert しているので挙動は固定
- `tests/test_leak.mojo` の `PAYLOAD_BYTES` docstring の「first sample is taken before `ABORT_PAGES` is reached」は不正確（`ABORT_PAGES` は `samples[0]` からの増分なので初回サンプル前の成長は数えない）。判定には影響しない
- `ABORT_PAGES` の早期 fail が実際に発火するのは本体ループだけ（異常系 3 ループは総量が 256 MiB 未満）。impl turn 12 の記録どおりで、異常系は tolerance 側で確実に FAIL する
- `COPY ... FROM STDIN`（status 4）と「次の `execute` で回復」はテストでなく verify のプローブで確認（round 1 / round 2 とも `after_copy_in` の `SELECT 1` が成功）。`test_copy_out_stays_a_server_error` は TO STDOUT 側のみ
- `_reject_nul` が `errors.mojo` に同居（impl turn 13 の提案 (2)）。`escape_*` は `PQescapeLiteral` に長さを渡すので NUL を通せる可能性があるが、E10 どおり 8 経路一律で拒否（提案 (1)）
- `tests/docker-compose.yml` の superuser `pq/pq` は 127.0.0.1 バインドで LAN からは届かないが、同一ホストの他ユーザーからは届く（テスト専用）
- round 1 の残留リスク一覧（`OID_TEXT` 等の未使用定数 / `PQ_MOJO_LIBPQ` 設定時のフォールバック無し / バージョンゲート未到達 / `RTLD.GLOBAL` / 非 UTF-8 `client_encoding` / `__init__` の公開 / `\n` の不統一 / +83 ページの出所 / `test_ffi.mojo` と `loader.mojo` のパス決定の二重 / `examples/basic.mojo` の stdout）はそのまま持ち越し

### マージ

- リモート無し（`git remote get-url origin` → `No such remote 'origin'`）→ (a) `main` へ `git merge --no-ff gsd-lite/phase1-sync-text-basic`。ブランチは残す。`reflect: true` なので次は `/gsd-lite-reflect`
