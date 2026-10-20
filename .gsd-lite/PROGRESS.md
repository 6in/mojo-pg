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

## turn 7 — impl — T5 `tests/test_array.mojo`（サーバー格子 26 件）
- やったこと: 17 要素型 × text / binary × `List` / `List[Optional]` を**実サーバー**で検査する `tests/test_array.mojo` を新設（**26 件**、PG17 / PG14 両方 PASS）。
  受信は 17 型それぞれ `SELECT ARRAY[...]::<type>[]` を両形式で取って同じ `List` になることを確認（境界値: int2/int4/int8 の最小・最大、float の NaN/±Infinity/-0/1e300、numeric の NaN/±Infinity/30+10 桁、date・timestamp の infinity と BC、time の 24:00:00、bytea の空要素、bpchar の padding、jsonb の version byte、text 9 要素の引用規則）。
  形は `'{}'` / `ARRAY[1,NULL,3]`（Optional と `NULL_VALUE`）/ 列 NULL と要素 NULL の両立 / `int2[]` を `List[Int32]` で読む `TYPE_MISMATCH` / 多次元拒否 / `[0:1]=` の lbound 落とし / 配列列の `get[String]`（text はリテラル、binary は `TYPE_MISMATCH`）。
  送信は 17 型の `SELECT $1::<type>[]` 往復 + None 混じり + 空 `List` + `= ANY($1)`（`Int32` と、`,` `"` `\` 空 `"NULL"` を含む `String`）。
  `check` 6/6 PASS = **298 s**（閾値 380 s、`PASS` 1444 行 = turn 6 の 1392 + 26×2、**既存テストの期待値変更 0 件**）。チェックリスト T5 の 1 行は期待値どおり（`test_array_tests`=26、期待値 ≥ 14。生値と総数 77 は TRACE「チェックリスト（turn 7）」）
- 想定外: (1) `Row.get_optional[List[Optional[Int32]]]` の戻り値から中身を取るのに `var elements = value.value()` は不可（`List[Optional[Int32]]` が `ImplicitlyCopyable` でない）→ **`ref elements = value.value()`** で借用する。turn 6 の `encode_array` の `ref bytes` と同じ形。
  (2) `Connection.execute` の `params` は**借用**（`params: List[Param]`、`var` ではない）なので、ヘルパ経由で渡すときに `params^` を書くとコンパイルエラー。既存 `test_params.mojo` と同じく借用で渡す。
  (3) **`TestSuite` の `Summary [ N ]` の単位はミリ秒**（`turn-007-time.sh` で実測: サマリ 187 の回の `mojo run` 全体が 5 s、2 回とも同じ）。turn 4 / 5 の PROGRESS が「0.065 s」「0.126 s」と書いているのは秒として読んだもの。新ファイルの `check` 単価は「1 サーバー目 17 s（コンパイル込み）+ 2 サーバー目 4 s = 21 s」で読む。
  (4) `timestamptz` はサーバーの `TimeZone` で表示が変わり `Connection.open` は `TimeZone` を pin しない（`DateStyle` と `IntervalStyle` だけ）→ 有限要素はリテラルで断言できないので **text と binary を互いに比較**し、`infinity` / `-infinity` だけ直接断言した
- やり直し: 1 回（上記 (1) の `ref` 束縛。コンパイルエラーで即判明。(2) は書く前に `execute` のシグネチャを読んで回避した）
- 陽性対照: `src/pq` の**写し**（scratch、実行後に削除）で `encode_array` の空配列 `ndim` を 0 → 常に 1 に変えた（空配列は次元語を持たない唯一のペイロード = 他の配列が全部往復し続ける中で送信経路だけが間違える 1 箇所）。
  `test_array.mojo` は **`test_array_param_empty_array_round_trips` 1 件だけ**が FAIL（25 passed / 1 failed）、対照の `test_encode_binary.mojo` も 1 件だけ。判別できたので差し替え不要（`scratch/turn-007-posctl-encode.{sh,log}`）
- 次への注意: T6 は `src/pq/copy.mojo` 新設 + `connection` / `transaction` / `prepared` / `__init__` の結線 + `tests/test_copy.mojo`（≥ 18 件）。並列サブ作業 1 本（親 = src、B = テスト）が PLAN の推奨。
  `check` の残り余裕は 380 − 298 = **82 s** で、T6 / T7 の新ファイル 2 本は +40 s 程度の見込み（新ファイル単価 21 s）。ただし turn 6 の ±50 s の揺れが残るので 1 回の計測で超過を判断しない。
  `List[Optional[E]]` / `List[E]` を `var` で束縛できない場面は `ref` で借用する（(1)）。`Connection.execute(sql, params, result_format=...)` の `params` は借用（(2)）。`CopyIn` / `CopyOut` のテストで所要を測るときは `Summary` をミリ秒として読む（(3)）

## turn 8 — impl — T6 `src/pq/copy.mojo` + 結線 + `tests/test_copy.mojo`（サブエージェント 1 本で並行）
- やったこと: (a) `src/pq/copy.mojo` 新設 — `CopyIn`（`write` ×2 / `finish` / `abort` / `__deinit__`）、`CopyOut`（`next` / `__deinit__`）、`_drain_results` / `_drain_copy_out` / `_copy_final_result`（sqlstate 無しの SERVER を CONNECTION に倒す。P11）。`Iterator` は付けない。
  (b) `Connection._check_not_copying`（`PQTRANS_ACTIVE` → `USAGE`）を **7 箇所**、`_copy_in_parts` / `_copy_out_parts` + `copy_in` / `copy_out`、`_discard_copy_state`（`execute` が COPY 文を受けたら drain してから raise。決めた事項 23）、docstring 書き換え。
  (c) `Transaction.copy_in` / `copy_out`、`PreparedStatement.execute` の検査、`__init__.mojo` の re-export。(d) テストはサブエージェント B が仕様から独立に: `tests/test_copy.mojo` **21 件**（≥ 18）、PG17 / PG14 両方 PASS。
  `check` 6/6 PASS = **266 s**（閾値 380 s、`PASS` 1486 行 = turn 7 の 1444 + 21×2、**既存テストの期待値変更 0 件**）。チェックリスト T6 の 11 行は全部期待値（`copy_mojo`=exists / `copyin_struct`=1 / `copyout_struct`=1 / `copy_drain_def`=1 / `conn_copy_parts_defs`=2 / `conn_check_not_copying_def`=1 / `check_not_copying_sites`=7 / `conn_docstring_copy_unsupported`=0 / `init_export_copy`=1 / `test_copy_tests`=21 / `src_iterator_in_copy`=0。生値と総数 77 は TRACE「チェックリスト（turn 8）」）
- PLAN 訂正 2 件（詳細は TRACE「PLAN 訂正（turn 8）」）: ⑩ の「close 後の最初の `write` が `-1`」は**チャンクサイズ依存で固定できない**（`PQputCopyData` は flush した呼び出しでしか `-1` を返さない）→ 上限付きループで「最初に失敗した `write`」を断言する形に。⑭ の handler ≥ 1 は成立するが**呼ぶのは `CopyIn.__deinit__`**（`PQexec("ROLLBACK")` は COPY 中でも成功するので `Transaction.__deinit__` は handler に到達しない）。
- 想定外: (1) `_prepare_parts` に検査を置いた（PLAN は `prepare`）。`Transaction.prepare` / 将来の `PooledConnection.prepare` も同じ parts を通るので同じ 7 箇所でカバー範囲が広い。(2) `try` ブロックが `raises PgError` のとき、その中で `raise Error(...)` は**変換できずコンパイルエラー**→ `Error` を投げる判定は `try` の外に出す（`var x: Optional[...]` を宣言して `try` 内で代入する `_prepare_parts` と同じ形）。
  (3) 小さい表（50 行）では COPY OUT の途中切断が**全部バッファに乗って `None` で正常終了する**（`turn-008-probe-api.mojo` case 14）→ `CONNECTION` を断言するには 10 万行規模が必要（`turn-008-probe-bigout.mojo`: close 後 191 行で `Connection`）。(4) サブエージェントがファイルを書き換えている最中に `check` を回してしまい、1 件消えた版で測った（`fmt` 後の再測で解消）。
- やり直し: 2 回（(2) のコンパイルエラー = 即判明 / 6/6 段が `warning: assignment to 'ended' was never used` 1 行で FAIL → その helper を `var row: Optional[...]` 形に書き直して解消）。どちらもテストの赤ではない
- 陽性対照: `_check_not_copying` の本体を `return` に差し替えた `src/pq` の写し（`turn-008-posctl-copying.{sh,log}`、実行後に削除）→ **`test_every_other_command_during_a_copy_is_usage` 1 件だけ** FAIL（20 passed / 1 failed）、対照の `test_transaction.mojo` は 13 件 PASS。この 1 件は USAGE の文言と**その後の `finish()` が 2 行を数えること**の両方を断言しているので、libpq の黙殺によるデータ消失を検出している
- サブエージェント: 1 本（B = `tests/test_copy.mojo`）。契約外の提案 5 件はすべて**未実装のまま報告**（失敗した `finish` / 成功した `finish` / `abort` の後の `_done` 断言、`CopyOut.next` の終了後の `USAGE`、`abort` の NUL 検査）。親が直したのは 1 箇所だけ: 上記 (2) の helper（コンパイルエラーと 6/6 段の warning）
- 次への注意: T7 は `src/pq/pool.mojo` 新設（`Pool` / `PooledConnection` / `_Slot`）+ `tests/test_pool.mojo`（≥ 14 件）+ `test_leak.mojo` に 2 ループ。並列サブ作業 1 本（親 = src、B = テスト）が PLAN の推奨。
  T7 で `copy_in_defs` / `copy_out_defs` / `conn_transaction_parts_sites` の `absent(src/pq/pool.mojo)` が解消し 3 / 3 / ≥ 3 になる。`PooledConnection` の origin 付き 4 本は `_X_parts` + `_conn_ptr()` rebind（決めた事項 19、`probe-pool.mojo:155-161`）で、`_copy_in_parts` / `_copy_out_parts` はこのターンで用意済み。
  **サブエージェントの報告の時間は `Summary [ N ]` を秒と読んでいる可能性がある**（実体はミリ秒）。所要は `final_check.log` の `took Ns` 行で確かめる。`check` は 266 s で余裕 114 s、母数は 260〜370 s の揺れ込みで読む。
  サブエージェントが書き終える前に検証を始めないこと（(4)）。`try` の中から `Error` を投げられない（(2)）。

## turn 9 — impl — T7 `src/pq/pool.mojo` + `tests/test_pool.mojo` + leak 2 ループ（サブエージェント 1 本で並行）
- やったこと: (a) `src/pq/pool.mojo` 新設 — `Pool`（`open` の conninfo / `Dict` 2 オーバーロード、引数検査 3 種は**接続前**に `USAGE`、`acquire` / `_release` / `close` / `size` / `idle` / `borrowed` / `set_rollback_failure_handler`）、
  `PooledConnection[origin]`（`__deinit__` で返却 + 転送 11 本。origin 付き 4 本は `_transaction_parts` / `_prepare_parts` / `_copy_in_parts` / `_copy_out_parts` + `_conn_ptr()` rebind）、`_Slot`。
  返却の判定順は決めた事項 18 どおり（closed → `ROLLBACK` → status/txstatus → 寿命 → `PQconsumeInput` ×2 → park）。内部状態の書き換えは `_mut_idle()` / `_mut_borrowed()` の untracked ポインタ。
  (b) `__init__.mojo` に re-export。(c) テストはサブエージェント B が仕様から独立に: `tests/test_pool.mojo` **18 件**（≥ 14）、`tests/test_leak.mojo` に pool 2 ループ（20 → **22 件**）。PG17 / PG14 両方 PASS。
  `check` 6/6 PASS = **321 s**（閾値 380 s、`PASS` 1524 行 = turn 8 の 1486 + 18×2 + 2、`FAIL` 0 = **既存テストの期待値変更 0 件**）。チェックリスト T7 の 11 行は全部期待値
  （`pool_mojo`=exists / `pool_struct`=1 / `pooled_struct`=1 / `pool_release_def`=1 / `pool_consume_input`=5 / `pool_rollback`=1 / `pool_monotonic`=10 / `init_export_pool`=1 / `test_pool_tests`=18 / `test_leak_tests`=22 / `test_leak_pool`=7）。
  併せて `conn_transaction_parts_sites`=3 / `copy_in_defs`=3 / `copy_out_defs`=3 / `test_file_count`=28 / `src_mojo_count`=22 で **`absent` は T8 の examples 2 本だけ**（生値と総数 77 は TRACE「チェックリスト（turn 9）」）
- PLAN 訂正 4 件（詳細は TRACE「PLAN 訂正（turn 9）」）: ① T7 (d) の陽性対照は「`_release` の**捨てる**経路」では判別しない（leak の 2 ループはどちらも捨てる経路を通らない）→ **park 経路**（`_idle.append` の直前で handle を NULL）に差し替え。
  ② `set_rollback_failure_handler` は `for ref slot in self._idle` ではコンパイル不可（`List iteration requires the element to be 'Copyable'`）→ 添字形。③ `_Slot` から `Connection` を取るのは `take(deinit self)` だけが通る。④ `PooledConnection[origin]` に `Parameters:` 節が必要
- 想定外: (1) `slot.conn^` が `field '...' destroyed out of the middle of a value` で不可。`def take(var self)` でも同じで、**`deinit self` の消費メソッドだけが通る**（`turn-009-probe-take.mojo` で A/B 比較）。
  (2) `libpq_ptr()` は raises なので `__init__` からは呼べない（`__init__` は raises でない）→ `pq` を引数で渡し `open` 側で `libpq_ptr()` を呼ぶ形に。
  (3) `PooledConnection[origin]` の `Parameters:` 節が無いと 3/6 段と 6/6 段が warning 1 行で FAIL する（`check` を 1 回分無駄にした。struct に parameter を付けたら docstring も足す）。
  (4) サブエージェントの報告で **モジュールレベルの `var` は Mojo 1.1.0 に無い**（`global variables are not supported`）→ ⑭ の handler 呼び出し回数は既存 `test_transaction` / `test_copy` と同じ**環境変数**で数えている（依頼文の `List[Int]` 指定は実現不能だった）
- やり直し: 2 回（(2) の `libpq_ptr` と `_mut_cell` の origin 型 = `package` のコンパイルエラーで即判明 / (3) の `Parameters:` 節 = `check` が 3/6・6/6 段で FAIL → 1 行追加で解消）。テストの赤は 0 回
- 陽性対照: 3 件すべて 1 件に絞れた（TRACE「陽性対照（turn 9）」）。① park した handle の `PQfinish` を落とす写し → `test_leak` が `test_pool_acquire_and_release_does_not_leak` **1 件だけ** FAIL（open/drop ループは PASS = 2 ループが別経路を見ている証明）。
  ② `_release` で `_stmt_counter[0] = 0` にする写し → `test_pool` が `test_the_statement_counter_rides_along_with_the_connection` **1 件だけ** FAIL（サーバーは `42P05`）。③ P21（T7 ⑰）: `var p2 = pool^` の後に guard を使うと `use of uninitialized value 'pool'` でコンパイル失敗
- サブエージェント: 1 本（B = `tests/test_pool.mojo` + `test_leak.mojo`）。**親の実装のバグを 1 件見つけた**（上記 PLAN 訂正 ②。B は scratch に patched copy を置くだけで src には触っていない → 親が本体を直した）。
  契約外の提案 6 件はすべて**未実装のまま報告**（leak ループの payload 拡大 / `Pool.max_size()` 等の accessor / 貸し出し中接続への handler 適用 / 追加テスト 4 種 / `server_version` を素の `Connection` と比較 / `Pool.clear()` と明示 `release()`）
- 次への注意: T8 は README / CHANGELOG / `__init__` docstring / examples 2 本（`copy.mojo` / `pool.mojo`）+ `examples/params.mojo` の `= ANY($1)` + `pixi.toml` + `final_check.sh`。並列サブ作業 2 本（A = examples + pixi + final_check、B = README + CHANGELOG、親 = `__init__.mojo` + 照合器）が PLAN の推奨。
  **README のコード片は examples から逐語**で、`python3 .gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-008-readme-excerpts.py` を必ず回す。`examples/pool.mojo` は `Pool.open(conninfo, 2)` → 3 本目の `USAGE` → drop → 同じ pid の再利用まで（`backend_pid` は `SELECT pg_backend_pid()`）。
  `check` は 321 s（余裕 59 s）、母数 260〜370 s の揺れ込み。T8 の増分は examples 2 本（2 s × 2 サーバー）と文書だけ。`pool_*` のキーは全部埋まったので T8 は README 系 12 行と件数 3 行だけが動く。
  **struct に parameter を足したら docstring に `Parameters:` 節**（(3)）。テスト側で数える副作用カウンタは環境変数（(4)）

## turn 10 — impl — T8 README / CHANGELOG / `__init__` docstring / examples 2 本 / pixi / final_check（サブエージェント 2 本で並行）
- やったこと: (a) `examples/copy.mojo` 新設（1,000 行を `copy_in` で書き `finish().affected_rows()`、`copy_out` を `while True: next()` で読み、行数とバイト数の往復一致を検査して不一致は `exit(1)`）、`examples/pool.mojo` 新設（`Pool.open(conninfo, 2)` → `acquire` ×2 → 3 本目が `USAGE`「pool exhausted」→ 1 本 drop → 再 `acquire` が同じ `pg_backend_pid()`、`size/idle/borrowed` を印字）。
  `examples/params.mojo` に `= ANY($1)`（`List[Int32]` を `[ids^]`）と `array_agg` を `List[String]` で読む節を追記（`EXPECTED_ROWS` と既存ロジックは不変）。`pixi.toml` に `example-copy` / `example-pool`、`final_check.sh` の 4/6 段に 2 行（examples 5 → **7 本**）。
  (b) README: 英語要約に `arrays, COPY and a single-threaded connection pool`、型マッピング表に配列行 + 1 次元のみ / 要素 OID 完全一致 / `array element N:` の段落、`### パラメータバインド` に `List` パラメータの散文、クイックスタートに `### COPY` と `### コネクションプール`、「既知の制限」の「配列型・COPY・プールは対象外」1 項目を **9 項目**に差し替え。CHANGELOG の `[Unreleased]` に `- Phase 7:` 1 行。
  (c) 親: `src/pq/__init__.mojo` の docstring（Phase 7 の行 / re-export 列挙に `CopyIn` `CopyOut` `Pool` `PooledConnection` / 型表と `## Parameters` 表に配列行 / 新節 `## COPY` と `## Connection pool`）。`Raises:` の USAGE 句は T6 で済んでいた（7 箇所確認済み）。
  `check` 6/6 PASS = **423 s**。テストケースの `PASS` は **1524 = turn 9 と同数**（T8 はテストを増やさないので正しい）、`FAIL` 0 = **既存テストの期待値変更 0 件**。3/6 段の docstring 欠落 0、6/6 段の警告 0、`fmt` 差分 0。チェックリストは **77 key すべて期待値・`absent` 0 件**（T8 の 18 行が到達。生値は TRACE「チェックリスト（turn 10）」）
- PLAN 訂正 1 件（詳細は TRACE「PLAN 訂正（turn 10）」）: T8 (b) の「パラメータ表（`:141-159`）」は **README に存在しない**（`:141-159` は libpq の探索順で、パラメータの説明は `### パラメータバインド` の散文 `:207-210`。PLAN の行番号が phase 5 時点の写しだった）→ 実物を正とし同じ節の**散文**として追記、PLAN.md の該当行も訂正。`__init__.mojo` 側の `## Parameters` は表があるので PLAN どおり行追加
- 想定外: (1) 並列 2 本のうち B（README）は A（examples）のコードを逐語で写す必要があり本来は直列依存 → **親が抜粋 19 + 11 + 4 行を先に確定し、同じ固定文言を両方の依頼文に書く**ことで並列化した。結果、照合器は 1 回目から全 9 ブロック missing 0（親の手直し 0 箇所）。
  (2) `len(String)` は Mojo 1.1.0 で不可（`a single length is ambiguous`）→ A は `_row_text(i).byte_length()` を使った。抜粋の `len(payload)` は `payload` が `List[UInt8]` なので無関係。
  (3) 照合器の `missing_total=1` は**変更前からの既存**（インストール節の ```mojo に `###` 見出しが無く `NO-SOURCE` になる）。`git show HEAD:README.md` を別ディレクトリに出して baseline を実測し、回帰でないことを確認した。
  (4) `check` が turn 9 の 321 s から **+102 s（423 s）**。増えた実体は 4/6 の examples 2 本（約 +10 s）だけで、残り約 90 s は 1 サーバー目のコンパイル時間の揺れ（5/6 の内訳は 54317 で 290 s / 54314 で 91 s、`test_leak` は 97 s = turn 9 の 94 s と誤差）
- やり直し: 0 回（親・サブエージェントとも検証は 1 回で green。`pixi run package` と docstring 診断は `__init__.mojo` 編集直後に単体で先に通して、`check` を無駄にしないようにした）
- サブエージェント: 2 本（A = examples 3 本 + `pixi.toml` + `final_check.sh` / B = README + CHANGELOG）。**どちらも固定文言の抜粋を 1 行も変えずに通した**ので親の統合修正は 0 箇所。契約外の提案 8 件はすべて**未実装のまま報告**（A: `CopyIn.abort` / CSV・binary COPY / `min_size`・`max_lifetime_s`・`close`・handler のデモ / `labels == [...]` の断言 / `example-all` タスク。B: トランザクション内 COPY の例 / `Pool.open` と `Connection.reset()` の API 節 / 配列リテラルの引用規則の詳細 / `List[UInt8]` と `List[T]` の区別の注記）
- 次への注意: T9 は最終判定（堅牢性格子の全セル + `db-reset` からの `check` + 受け入れ基準対応表 + branch push）。`scratch/turn-003-robust-grid.sh` を `turn-011-robust-grid.sh` に写し `copy.mojo` / `pool.mojo` / `params.mojo` の行を有効化する。
  **PLAN T9 (b) の閾値 300 s は green な 2 回（turn 9 = 321 s、turn 10 = 423 s）とも超えている**。T9 は `db-reset` 後に計測してから、閾値そのものを訂正するか判断すること（1 回の計測で決めない）。母数は **260〜425 s** で読む。
  `absent` は 0 件になったので、T9 で動くチェックリストの key は無い（全 77 key が期待値のまま維持されることの確認だけ）。PROGRESS の最新節 ≤ 40 行の検査が T9 (c) にあるので注意
