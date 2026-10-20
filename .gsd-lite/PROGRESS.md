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
