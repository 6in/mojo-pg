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
