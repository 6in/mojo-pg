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

## turn 4 — impl — T2 配列 OID 表 + テキスト配列リテラル + `decode_text` の 34 分岐
- やったこと: (a) `decode_text.mojo` に `OID_*_ARRAY` 21 個 + `_array_elem_oid` / `_array_oid_of`。(b) `parse_array_literal`（`[0:1]=` 捨て / 引用の `\` unescape / 裸の trim と `NULL` / 入れ子 `{` は `multidimensional`）。
  (c) `_decode_text_array[E]` + `_decode_text_string_array`（text 系 6 OID）+ `_require_no_nulls`（`array element N is NULL`）、要素失敗は `array element N: <元>`。(d) `List[E]` 17 + `List[Optional[E]]` 17 の分岐（既存のスカラ `List[UInt8]` と `String` wildcard は不変）。
  (e) `tests/test_decode_array.mojo` 新設 **40 件 PASS**（サーバー不要、0.065 s）。チェックリスト T2 の 8 行は全部期待値（`oid_array_consts`=21 / `*_def`=1 ×4 / 35 / 17 / `test_decode_array_tests`=40。生値と総数 77 は TRACE「チェックリスト（turn 4）」）。
  `db-up` → `check` 6/6 PASS = **310 s**（閾値 380 s。既存テストの期待値変更 0 件）
- 想定外: (1) **要素型は 20 ではなく 17**（`decode_text` のスカラ分岐を数えた。`String` が 6 配列 OID、`Int`/`Int64` が同じ 1016 を受けるので 21 OID を 17 型で覆う）→ PLAN 訂正（下記）。
  (2) `E: Copyable` だけでは `List[Optional[E]]` が `abandoned without being explicitly destroyed` で通らず **`Copyable & Deinitable`** が必要（`mojo run` の probe で判別。`turn-004-probe-str.mojo`）。
  (3) `List[UInt8](0, 255)` の位置引数 ctor は無く `var x: List[UInt8] = [0, 255]` の形だけ（既存 `test_decode_text.mojo:309` と同じ）。(4) `{{}}` は PLAN (e) では「空」と並記だが、サーバー出力は `{}` のみなので入れ子 `{` の規則どおり `TYPE_MISMATCH`（`multidimensional`）にし、その理由をテストにコメントで書いた
- やり直し: 2 回（(2) の Deinitable、(3) の `List` literal。どちらも PLAN の雛形に無い形で、コンパイルエラーで即分かった）
- PLAN 訂正: 要素型 20 → **17**。checklist `decode_text_list_branches` 41 → **35** / `decode_text_optional_branches` 20 → **17**、同じ算術で `decode_binary_*` 1/35/17・`params_*_implicit` 35/17、本文の「40 分岐」→ 34・「40 本」→ 34・「20 要素型」→ 17（根拠は TRACE「PLAN 訂正（turn 4）」）
- 陽性対照: `OID_TIMESTAMP_ARRAY` を 1115 → 1114 にすると `test_array_oid_constants_are_the_observed_typarray_values` だけが FAIL（`turn-004-posctl-oid.log`）。**両方向マップの 2 件は通ってしまった**ので、転記ミスを捕まえているのは literal で数値を固定したこの 1 件（PLAN (a) の「両方向 21 行」だけでは循環で検査にならない）→ 1 件足して 40 件
- 次への注意: T3 は同じ 17 型で `decode_binary` に 34 分岐（期待値 1 / 35 / 17）。`_decode_binary_array` も `E: Copyable & Deinitable` が必要になる。`tests/test_decode_array.mojo` にバイナリ側を**追記**するので `test_decode_array_tests` は 40 → ≥ 54（PLAN の「≥ 32」は基線が 18 件想定。実際は 40 件あるので超過で問題なし）。
  サーバー不要のテストファイルでも `check` は 1 本 ≈ 47 s 増える（両サーバー分のコンパイル）。残り 70 s なので T5〜T7 のサーバーテストは所要に注意。T4 の最初に `List[String]` → `$1::varchar[]` を実測（P9）

## turn 5 — impl — T3 バイナリ配列デコーダ + `decode_binary` の 34 分岐
- やったこと: (a) `_decode_binary_array[E]`（`array_recv` と同じ検査順: 列 OID → 12 byte ヘッダ → `flags ∈ {0,1}` → `elemtype` 一致（両 OID をメッセージに）→ ndim 0 は dims を読まず空 / 負・2 以上は拒否 → dim → 要素長 -1 で NULL（flags は見ない。P1）→ 要素は `decode_binary[E]`、失敗は `array element N: <元>` → 末尾残り拒否。P3）+ `_decode_binary_string_array`（6 配列 OID）+ `_binary_array_oid_error`。`_require_no_nulls` は `decode_text` から import して text 側と同じ `NULL_VALUE` にする。
  (b) `decode_binary[T]` に `List[E]` 17 + `List[Optional[E]]` 17（生成スクリプト `turn-005-gen-branches.py` で機械生成。既存 `String` / `List[UInt8]` は不変）。(c) `tests/test_decode_array.mojo` にバイナリ 23 件を追記 → **63 件 PASS**（0.126 s）。payload は `turn-005-gen-tests.py` が RESEARCH §2.3 の hex を組み直したもの（`_P_*` の comptime 定数 32 個）。
  チェックリスト T3 の 3 行は期待値どおり（`decode_binary_array_def`=1 / `decode_binary_list_branches`=35 / `decode_binary_optional_branches`=17）。`check` 6/6 PASS（既存テストの期待値変更 0 件）
- 想定外: (1) PLAN (a) は「`len > 残り` → `TYPE_MISMATCH`」しか書いていないが、**要素の長さ語 4 byte 自体の境界検査**が別に要る（`dim` が実要素数より多いと `bytes[pos:pos+4]` が範囲外になる）。同じ `TYPE_MISMATCH` を返す検査を 2 つ足した: 長さ語が読めない場合と、`dim > 残りバイト // 4` の事前検査（後者が無いと壊れた `dim` が巨大な `List` を予約しうる。どちらも PLAN の P3 と同じ結果で、早く落ちるだけ）。
  (2) `check` が **368 s**（閾値 380 s、turn 4 は 310 s）。`test_decode_array` 単体で 14 s + 4 s = 18 s（34 分岐の instantiation がコンパイル時間になる）。残り 12 s しかないので T5〜T7 の新ファイル 3 本で**閾値を超える**見込み
- やり直し: 0 回
- 陽性対照: NULL 判定を `elem_len == -1 and flags == 1`（= P1 の罠）に変えると `test_binary_array_null_element_with_flags_zero` **だけ**が FAIL（`turn-005-posctl-flags.log`）。63 件中 1 件に効いている
- 次への注意: T4 は `encode_binary.encode_array` と `params.mojo` の `@implicit` 34 本（期待値 1 / 35 / 17）。最初に `List[String]` → `$1::varchar[]` をサーバーで 1 回実測する（P9。未実測のまま OID 1009 固定にしている）。
  `check` の所要が閾値に迫っている（368 / 380 s）。T5〜T7 で超えたら PLAN 53-55 行の見積もり（新ファイル 4 本で +60〜85 s）が低すぎたのが理由 — 実測は `test_decode_array` 1 本で +18 s なので、**超過は BLOCKED にせず PROGRESS に実測値と内訳を書いて進める**（PLAN 55 行の指示どおり）

## turn 6 — impl — T4 配列エンコーダ + `Param` の `@implicit` 34 本（サブエージェント 1 本で並行）
- やったこと: (a) `encode_binary.encode_array(elems, elem_oid)`（空 = 12 byte ヘッダ / それ以外は ndim 1・flags = None の有無・dim・lbound 1 + 要素ごと `int32 len + bytes`、None は `ffffffff`）。`ARRAY[1,2,3]::int4[]` の実測 44 byte と一致。
  (b) `params.Param` に `List[E]` 17 + `List[Optional[E]]` 17 の `@implicit`（生成スクリプト `turn-006-gen-params.py` の 1 表から機械生成 → `turn-006-splice-params.py` で挿入 → `mojo format`）。(c) **P9 を最初に実測**（下記）。
  (d) テストはサブエージェント B が仕様表から独立に: `test_encode_binary` +3 件（29）/ `test_params` +4 件（37、既存 33 件の期待値変更 0 件）。親が統合して検証。
  `check` 6/6 PASS = **318 s**（閾値 380 s、PASS 1392 件）。チェックリスト T4 の 6 行は全部期待値（`encode_array_def`=1 / `params_list_implicit`=35 / `params_optional_list_implicit`=17 / `params_text_array_oid`=3 / 29 / 37。生値と総数 77 は TRACE「チェックリスト（turn 6）」）
- P9 実測（`turn-006-probe-p9.log`、PG17）: `$1::varchar[]` / `$1::jsonb[]` / `varchar[]` 列への INSERT は **すべて通る** → 決めた事項 9（`List[String]` = 1009 固定 + サーバーの配列キャスト）をそのまま採用、代替案に切り替えず **PLAN 訂正なし**。
  NUL 入り要素は sqlstate **`22021`**（PG14 / PG17 同一）= 決めた事項 10 の「22021 想定」が確定。併せて `= ANY($1)` と `{1,NULL,3}`（T5 (b)(e) の先取り）も通ることを確認
- 想定外: (1) **`def (E) -> List[UInt8]` を値で渡す汎用ヘルパは Mojo 1.1.0 で作れない**（thin 関数が `def(E)` 型に適合しない。`turn-006-probe-fnparam.mojo`）→ 34 本それぞれが自分のループを持つ形（生成スクリプトで量産）に。
  (2) `List[Optional[Int32]] = [1, None, 3]` の literal は**通らない**（`IntLiteral` → `Optional[Int32]` の 2 段変換が無い）。`[Optional[Int32](1), None, Optional[Int32](3)]` と書く必要がある。ただし `List[Optional[String]] = ["a", None]` は通る（`String` の `@implicit` が 1 段で当たる）。
  (3) `encode_array` の中で `elems[i].value()` を `var` に束縛すると `List[UInt8]` が `ImplicitlyCopyable` でないとエラー → `ref bytes = elems[i].value()` で借用して 1 byte ずつ append（コピーも起きない）。
  (4) `check` が **318 s** で turn 5 の 368 s より 50 s 短い（足したのは既存ファイルへの追記だけで増える方向しかないのに下がった）→ **この環境の `check` には ±50 s の揺れがある**。turn 5 の「残り 12 s」は揺れの上側を母数にした読みで、実際の母数は 310〜370 s（TRACE に追記）
- やり直し: 2 回（(1) の汎用ヘルパ = probe で没、(3) の `ref` 束縛 = コンパイルエラーで即判明）。どちらもプローブ / コンパイル段階で、テストの赤ではない
- 陽性対照: OID 表の `timetz[]` 1 行だけを 1270 → 1266 に変えた写し（`turn-006-posctl-oid.log`）→ **`test_param_oids_of_the_array_types` 1 件だけが FAIL**（`reason: timetz[]: oid`）。turn 4 の教訓どおり表は `_array_oid_of` を呼ばず数値を直書きしている
- サブエージェント: 1 本（B = テスト 2 ファイル）。契約外の提案 5 件はすべて**未実装のまま報告**（`Span` を取る `_assert_bytes` 追補 / `text[]` の実測バイト列 / 全要素 None / jsonb の正規化 / キャスト無しの失敗方向）。親が直したのは 1 箇所だけ: NUL の sqlstate を未実測前提の `!= ""` + `print` から **`== "22021"` の断言 + マーカー不在**に（実測が済んだため。テスト内の `print` はこのリポジトリに前例が無い）
- 次への注意: T5 は `tests/test_array.mojo` 新設（≥ 14 件、17 型 × text/binary × `List`/`List[Optional]`）。送信側は `List[Param] = [x^]` の形で、**名前付き `List` には `^` が必須**。`List[Optional[E]]` の literal は `Optional[E](...)` を明示（上記 (2)）。
  text/binary 両形式の比較は `execute(sql)` と `execute(sql, [], result_format=BINARY)`。`check` は 310〜370 s の揺れがあるので、1 回の計測で閾値超過を判断しない（db-up 済みで 2 回測る余地があるならそうする）
