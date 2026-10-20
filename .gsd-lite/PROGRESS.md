# PROGRESS — phase7-pool-copy-array

## turn 1 — research — REQ §6 のプローブ 4 件 + COPY / プール / 配列の実測で RESEARCH.md を産出（BLOCKED なし）
- やったこと: psql で typarray 21 型・配列リテラル・`array_send` hex を実測、Mojo プローブ 6 本（COPY FFI 9 ケース（PG17 / PG14 同一）、`PooledConnection[origin]` 試作、`array_recv` 24 ケース、言語事実、`List[Movable]`、`std.threading` 不在）、
  libpq COPY docs / `arrayfuncs.c` / `arrays.html` / psycopg（配列・COPY・pool）/ pgx / deadpool / `lee101/mojo-pg` / ローカル 3 件を参照。RESEARCH.md §0〜§6（落とし穴 29 行、REQ への提案 11 件）
- 想定外: (1) `Iterator.__next__` は `raises StopIteration` ちょうどでないと適合しない → `CopyOut` を `Iterator` にできない（REQ §2.2 への提案 1）。(2) `PQreset` 後に `DateStyle` が `ISO, MDY` に戻る（`reset()` に再 `SET` が要る）。
  (3) 切られた直後の未使用接続は `PQstatus` OK のまま再利用される（REQ §4.3 の terminate ケースは「使ってから返す」ときだけ成立）。(4) COPY 中の `PQexec` は libpq が黙って COPY を中止し書いた行が消える（USAGE 検査はデータ保護）。
  (5) `List[Connection]` が作れる（`Movable` で足りる）。ハンドルをばらすと `_stmt_counter` が戻り `42P05`
- やり直し: 3 回（probe-pool ×1 = フィールド経由の origin を `origin_of(self)` に rebind / probe-lang ×2 = `Iterator` の typed raises と `@implicit String` ctor の衝突、名前付き `List` の literal に `^` / probe-array ×1 = `Span` の origin パラメータ。いずれも RESEARCH §0.5 に転記）
- 次への注意: plan は RESEARCH §5 の提案 11 件（特に 1 `Iterator` 外し / 2 terminate ケース 2 件 / 3 `Connection.reset()` / 4 方向違いの drain / 7 `List[String]` = OID 1009）の採否を最初に決め、§4 の 29 行を完了基準に写す。
  `pixi` は絶対パス、プローブ雛形は `scratch/turn-001-probe-copy.mojo`（`get_row` / `CopyFFI`）と `turn-001-probe-pool.mojo`（`_conn_ptr` rebind / `_release`）。未使用変数の warning は `check` 6/6 に乗るので `_ =`。
  `List[String]` を `$1::varchar[]` に送る 1 件だけ未実測（impl の最初に 1 回）

## turn 2 — plan — 9 タスク（T1 土台 / T2〜T5 配列 / T6 COPY / T7 Pool / T8 文書・examples / T9 最終判定）、BLOCKED なし
- やったこと: REQ / DECISIONS / RESEARCH / reflect 2 件 / src 10 ファイル / tests / README / pixi.toml / final_check.sh を読み、PLAN.md（検証コマンド・チェックリスト 77 key・Tasks 9・決めた事項 24・採否表 12 + 11・P1〜P29 対応）を作成。
  チェックリスト `scratch/turn-002-checklist.sh` を 1 回実行して基線 `turn-002-checklist.log` を取得
- 想定外: (1) チェックリストのコメント除外（`^\s*#`）が README の見出しも落とし `readme_h2=0` になった → `.md` は除外しないよう `body()` で分岐（決めた事項 24）。
  (2) REQ §4.3「未完了の `copy_in` を持つガードの drop → 捨てられ `size()` −1」は origin の破棄順序（`CopyIn` が先に死んで中止する）では観測できない → D11 / D15 両立の形（再利用 + 白箱で `ACTIVE` 分岐）に決めた（決めた事項 20）。
  (3) REQ §2.2「`Iterator` としても使える」は Mojo 1.1.0 の `raises StopIteration` 制約で `PgError` を出せないため意図的に外した（決めた事項 7）。
  (4) RESEARCH §3-9 の「`PQconsumeInput` 1 回」は FATAL を消費して 1 を返すだけなので ×2 に（決めた事項 17）。(5) RESEARCH P26 の `grep -c example- pixi.toml ≥ 8` は現在値 5 + 2 = 7 が正
- やり直し: 1 回（チェックリストの `.md` コメント除外。再実行して基線を取り直した）
- 次への注意: `pixi` は絶対パス、`bash <任意パス>` は `pixi run bash <file>` 経由。T1 は `_transaction_parts` 分離で `test_transaction` 13 件の期待値不変を確認。チェックリストは「コメントを書いたらコミット前に 1 回」。
  T4 の最初に `List[String]` → `$1::varchar[]` を実測（P9）。各ターン `check` の所要を TRACE に（閾値 300 s）。PROGRESS 節は 40 行以内

## turn 3 — impl — T1 土台（COPY FFI 3 関数 / `Connection.reset()` / `_transaction_parts` 分離 / TRACE.md / 堅牢性格子）
- やったこと: (a) `_ffi/functions.mojo` に `PQputCopyData` / `PQputCopyEnd` / `PQgetCopyData` + `_dl_sym`、`test_ffi` に 3 シンボルの解決 1 件（8 件 PASS）。
  (b) `Connection.reset()`（`PQreset` → `PQstatus` → `_SESSION_SETUP_SQL` 再送）+ `test_connection` に 2 件（31 → 33 件 PASS）。(c) `_transaction_parts()` を切り出し `test_transaction` 13 件 PASS（期待値変更 0）。
  (d) `.gsd-lite/TRACE.md` 新設（全 77 key / `check` の所要 / PLAN 訂正）。(e) `scratch/turn-003-robust-grid.sh`（入力 6 × 出力 4 × 依存 4、3 軸は配列変数で列挙）を 1 回実行 → **90 行すべて `unhandled_markers=0`**（rc 141 は EPIPE の 10 行のみ、Phase 5 の既知）。
  (f) `db-reset` → `check` 6/6 PASS = **263 s**。チェックリスト T1 の 11 行は全部期待値（`ffi_*`=3 / `conn_reset_def`=1 / `conn_reset_session_setup`=5 / `conn_transaction_parts_def`=1 / `test_connection_tests`=33 / `trace_*`=exists,1 / `grid_script`=exists、`conn_transaction_parts_sites` は `absent(pool.mojo)` で T7 まで許容）。生値と総数 77 は TRACE.md「チェックリスト（turn 3）」
- 想定外: (1) **`check` の母数が PLAN と違った**: 実測 263 s に対し PLAN の母数は「Phase 6 末 169〜190 s」。T1 の reset テスト 2 件が両サーバーで ≈ 43 s を足し（この環境は 1 接続 `open` ≈ 3.5 s、reset テストは 1 件で 3 接続）、
  その分は PLAN の `+60〜85 s` に入っていなかった → PLAN 訂正（下記）。(2) `test_ffi.mojo` の `_symbol_names()` は `assert_equal(len(names), 55)` を持つので、3 シンボルをそこに足すと既存の期待値を変えてしまう → 別テスト `test_copy_symbols_resolve`（`LibpqFFI` のフィールドが非 0）にして**期待値変更 0 件**を守った。
  (3) `Date.from_ymd` は `raises PgError` でテストから直接呼べない → `Date(8767)`（既存 `test_extended_datetime.mojo:936` と同じ書き方）に。(4) `tee` / `date` は allowlist に通った（PLAN の注意は `bash <任意パス>` のみ該当）
- やり直し: 1 回（`Date(2024, 1, 2)` が fieldwise ctor（`days: Int32`）に合わずコンパイルエラー → `Date(8767)` に直して再実行）
- PLAN 訂正: `check` の母数「Phase 6 末実測 169〜190 s」→ **turn 3 実測 263 s**、見積もり「230〜275 s」→ **323〜348 s**、閾値「300 s」→ **380 s**（根拠は TRACE.md「PLAN 訂正（turn 3）」）
- 陽性対照: `scratch/turn-003-posctl-reset.mojo`（`reset()` から `_SESSION_SETUP_SQL` 再送を外した形 = 生の `PQreset`）→ `DateStyle` が `ISO, MDY` で、テストの `assert_equal(…, "ISO, YMD")` が赤になることを実測（`turn-003-posctl-reset.log`）
- 次への注意: `check` の閾値は **380 s**（300 s ではない。TRACE の訂正節）。新しいサーバーテストは 1 件 ≈ 3.6 s × 2 サーバーで積み上がるので、T5 / T6 / T7 のテスト件数は所要に直結する。
  T2 は `decode_text.mojo` 単独（`parse_array_literal` + 40 分岐）で `test_decode_array.mojo` はサーバー不要 → `pixi run mojo run -I src tests/test_decode_array.mojo` だけで回せる。T4 の最初に `List[String]` → `$1::varchar[]` を実測（P9）。
  `conn_transaction_parts_sites` と `copy_in_defs` / `copy_out_defs` は `pool.mojo` を見るので T7 まで `absent`。コメントを書いたらコミット前にチェックリストを 1 回（turn 3 は TRACE の 2 key 以外の差分なしを `diff` で確認した）
