# TRACE — phase7-pool-copy-array

PLAN.md の「追従先チェックリスト」の**生の値**と `pixi run check` の所要、PLAN の訂正をためる場所。
PROGRESS.md は 1 ターン 40 行以内に収めるため、数字の全文はここに置く（Phase 6 の TRACE と同じ役割）。

- チェックリストのスクリプト: `.gsd-lite/logs/phase7-pool-copy-array/scratch/turn-002-checklist.sh`（**全 77 key**）
- 基線（コミット `e7fdf6c` の木 = plan ターン終了時）: `scratch/turn-002-checklist.log`
- 各ターンの生出力: `scratch/turn-<NNN>-checklist.log`

## チェックリスト（turn 3）

`scratch/turn-003-checklist.log` の全文（**全 77 key**）。T1 の行には期待値を添える。T2〜T8 の key は
すべて基線のまま（未着手）。`absent(...)` はファイル未作成。

```
## T1 FFI 3 関数 + Connection.reset / _transaction_parts + TRACE / 格子
ffi_putcopydata=3                        # 期待 ≥ 2（var 行 + _dl_sym[ + 名前文字列の 3 行）
ffi_putcopyend=3                         # 期待 ≥ 2
ffi_getcopydata=3                        # 期待 ≥ 2
conn_reset_def=1                         # 期待 1
conn_reset_session_setup=5               # 期待 ≥ 4（基線 3 = 定義 + _adopt の 2 箇所、+ reset の docstring / 呼び出し）
conn_transaction_parts_def=1             # 期待 1
conn_transaction_parts_sites=absent(src/pq/pool.mojo)   # T7 まで許容（connection.mojo 側は 2 箇所）
test_connection_tests=33                 # 期待 ≥ 33（基線 31 + reset の 2 件）
trace_exists=exists                      # 期待 exists（このファイル）
trace_checklist_section=1                # 期待 ≥ 1（この節）
grid_script=exists                       # 期待 exists
## T2 配列 OID 表 + テキスト配列リテラル + decode_text 40 分岐
oid_array_consts=0
array_elem_oid_def=0
array_oid_of_def=0
parse_array_literal_def=0
decode_text_array_def=0
decode_text_list_branches=1
decode_text_optional_branches=0
test_decode_array_tests=absent(tests/test_decode_array.mojo)
## T3 バイナリ配列デコーダ + decode_binary 40 分岐
decode_binary_array_def=0
decode_binary_list_branches=1
decode_binary_optional_branches=0
## T4 配列エンコーダ + Param 40 本
encode_array_def=0
params_list_implicit=1
params_optional_list_implicit=0
params_text_array_oid=0
test_encode_binary_tests=26
test_params_tests=33
## T5 test_array.mojo（サーバー格子）
test_array_tests=absent(tests/test_array.mojo)
## T6 copy.mojo + Connection / Transaction / PreparedStatement の結線
copy_mojo=absent
copyin_struct=absent(src/pq/copy.mojo)
copyout_struct=absent(src/pq/copy.mojo)
copy_drain_def=absent(src/pq/copy.mojo)
copy_in_defs=absent(src/pq/pool.mojo)
copy_out_defs=absent(src/pq/pool.mojo)
conn_copy_parts_defs=0
conn_check_not_copying_def=0
check_not_copying_sites=0
conn_docstring_copy_unsupported=1
init_export_copy=0
test_copy_tests=absent(tests/test_copy.mojo)
## T7 pool.mojo + test_pool / test_leak
pool_mojo=absent
pool_struct=absent(src/pq/pool.mojo)
pooled_struct=absent(src/pq/pool.mojo)
pool_release_def=absent(src/pq/pool.mojo)
pool_consume_input=absent(src/pq/pool.mojo)
pool_rollback=absent(src/pq/pool.mojo)
pool_monotonic=absent(src/pq/pool.mojo)
init_export_pool=0
test_pool_tests=absent(tests/test_pool.mojo)
test_leak_tests=20
test_leak_pool=0
## T8 README / CHANGELOG / __init__ docstring / examples / pixi.toml / final_check
readme_array_optional_row=0
readme_array_word=1
readme_copy_example=0
readme_pool_example=0
readme_out_of_scope_line=1
readme_thread_unsafe=0
readme_en_arrays=0
readme_19_types=1                        # 不変（期待 1）
readme_h2=11                             # 不変（期待 11）
changelog_phase7=0
changelog_phase_lines=6
init_docstring_phase7=0
init_docstring_copy_in=0
examples_copy=absent
examples_pool=absent
examples_params_any=0
examples_copy_next=absent(examples/copy.mojo)
pixi_example_tasks=5
final_check_examples=5
## 全体（不変 / 件数）
examples_mojo_count=7                    # 不変（T8 で 9）
test_file_count=24                       # 不変（T7 までに 28）
src_mojo_count=20                        # 不変（T7 までに 22）
src_def_ref_return=0                     # 不変（期待 0。REQ §2.3）
src_iterator_in_copy=absent(src/pq/copy.mojo)   # T6 で exists かつ 0（決めた事項 7）
tests_sh_bash4_only=0                    # 不変（期待 0）
```

`trace_exists` / `trace_checklist_section` はこのファイルを書いた後の値（`turn-003-checklist.log` は
このファイルを書く前に取ったので `absent` のまま。コミット前の再実行が上の 2 行の根拠で、
生出力は `scratch/turn-003-checklist-after-trace.log`）。

## チェックリスト（turn 4）

`scratch/turn-004-checklist.log` の全文（**全 77 key**）。T2 の 8 行には期待値を添える
（turn 3 からの差分は T2 の 8 行と `test_file_count` の 24 → 25 だけ。`diff` で確認）。

```
## T1 FFI 3 関数 + Connection.reset / _transaction_parts + TRACE / 格子
ffi_putcopydata=3
ffi_putcopyend=3
ffi_getcopydata=3
conn_reset_def=1
conn_reset_session_setup=5
conn_transaction_parts_def=1
conn_transaction_parts_sites=absent(src/pq/pool.mojo)
test_connection_tests=33
trace_exists=exists
trace_checklist_section=1
grid_script=exists
## T2 配列 OID 表 + テキスト配列リテラル + decode_text 40 分岐
oid_array_consts=21
array_elem_oid_def=1
array_oid_of_def=1
parse_array_literal_def=1
decode_text_array_def=1
decode_text_list_branches=35
decode_text_optional_branches=17
test_decode_array_tests=40
## T3 バイナリ配列デコーダ + decode_binary 40 分岐
decode_binary_array_def=0
decode_binary_list_branches=1
decode_binary_optional_branches=0
## T4 配列エンコーダ + Param 40 本
encode_array_def=0
params_list_implicit=1
params_optional_list_implicit=0
params_text_array_oid=0
test_encode_binary_tests=26
test_params_tests=33
## T5 test_array.mojo（サーバー格子）
test_array_tests=absent(tests/test_array.mojo)
## T6 copy.mojo + Connection / Transaction / PreparedStatement の結線
copy_mojo=absent
copyin_struct=absent(src/pq/copy.mojo)
copyout_struct=absent(src/pq/copy.mojo)
copy_drain_def=absent(src/pq/copy.mojo)
copy_in_defs=absent(src/pq/pool.mojo)
copy_out_defs=absent(src/pq/pool.mojo)
conn_copy_parts_defs=0
conn_check_not_copying_def=0
check_not_copying_sites=0
conn_docstring_copy_unsupported=1
init_export_copy=0
test_copy_tests=absent(tests/test_copy.mojo)
## T7 pool.mojo + test_pool / test_leak
pool_mojo=absent
pool_struct=absent(src/pq/pool.mojo)
pooled_struct=absent(src/pq/pool.mojo)
pool_release_def=absent(src/pq/pool.mojo)
pool_consume_input=absent(src/pq/pool.mojo)
pool_rollback=absent(src/pq/pool.mojo)
pool_monotonic=absent(src/pq/pool.mojo)
init_export_pool=0
test_pool_tests=absent(tests/test_pool.mojo)
test_leak_tests=20
test_leak_pool=0
## T8 README / CHANGELOG / __init__ docstring / examples / pixi.toml / final_check
readme_array_optional_row=0
readme_array_word=1
readme_copy_example=0
readme_pool_example=0
readme_out_of_scope_line=1
readme_thread_unsafe=0
readme_en_arrays=0
readme_19_types=1
readme_h2=11
changelog_phase7=0
changelog_phase_lines=6
init_docstring_phase7=0
init_docstring_copy_in=0
examples_copy=absent
examples_pool=absent
examples_params_any=0
examples_copy_next=absent(examples/copy.mojo)
pixi_example_tasks=5
final_check_examples=5
## 全体（不変 / 件数）
examples_mojo_count=7
test_file_count=25
src_mojo_count=20
src_def_ref_return=0
src_iterator_in_copy=absent(src/pq/copy.mojo)
tests_sh_bash4_only=0
```

T2 の期待値との対応:

| key | 現在値 | 期待値 | 判定 |
|---|---|---|---|
| `oid_array_consts` | 21 | 21 | ○ |
| `array_elem_oid_def` | 1 | 1 | ○ |
| `array_oid_of_def` | 1 | 1 | ○ |
| `parse_array_literal_def` | 1 | 1 | ○ |
| `decode_text_array_def` | 1 | 1 | ○ |
| `decode_text_list_branches` | 35 | **35**（PLAN 41 を turn 4 に訂正） | ○ |
| `decode_text_optional_branches` | 17 | **17**（PLAN 20 を turn 4 に訂正） | ○ |
| `test_decode_array_tests` | 40 | ≥ 18 | ○ |

## PLAN 訂正（turn 4）

- 配列分岐の本数: **要素型は 20 ではなく 17**。`decode_text` のスカラ分岐は
  `Bool` / `Int16` / `Int32` / `Int64` / `Int` / `Float32` / `Float64` / `String` / `List[UInt8]` /
  `Decimal` / `UUID` / `Date` / `Timestamp` / `TimestampTz` / `Time` / `TimeTz` / `Interval` の
  **17 本**で（`decode_text.mojo` の `comptime if` を数えた）、`String` が 6 つの配列 OID を、
  `Int` / `Int64` が同じ 1016 を受けるため 21 の配列 OID を 17 型で覆う。REQ §2.1 が挙げる型名も
  この 17（`Int64`/`Int` を 2 と数えて）で、要件には触れない。直した箇所:
  チェックリスト `decode_text_list_branches` 41 → **35**（= 既存 `List[UInt8]` 1 + 17 + 17）/
  `decode_text_optional_branches` 20 → **17**、同じ算術で `decode_binary_*` を 1 / 35 / 17、
  `params_list_implicit` / `params_optional_list_implicit` を 35 / 17、
  本文の「40 分岐」→ 34 分岐・「`@implicit` 40 本」→ 34 本・「20 要素型」→ 17 要素型
  （T2 (d) / T3 (b) / T4 (b)(c) / T5 (a)(e) / 決めた事項 9 / 採否表 5 / 申し送り）

## `check` の所要

| turn | タスク | コマンド | 時刻 | 所要 | 結果 |
|---|---|---|---|---|---|
| 3 | T1 | `pixi run db-reset` → `pixi run check` | 2026-10-20T15:17:43+09:00 → 2026-10-20T15:22:06+09:00 | **263 s** | PASS 6/6（rc 0 / `final_check: PASS`、6/6 段 `matched lines: 0`、PASS 1252 件） |
| 4 | T2 | `pixi run db-up` → `pixi run check` | 2026-10-20T15:38:44+09:00 → 2026-10-20T15:43:54+09:00 | **310 s** | PASS 6/6（rc 0 / `final_check: PASS`、6/6 段 `matched lines: 0`、PASS 1332 件） |
| 5 | T3 | `pixi run check` | （PROGRESS turn 5 の実測。表への転記漏れ） | **368 s** | PASS 6/6 |
| 6 | T4 | `pixi run db-up` → `pixi run check` | 2026-10-20T16:18:01+09:00 → 2026-10-20T16:23:19+09:00 | **318 s** | PASS 6/6（rc 0 / `final_check: PASS`、6/6 段 `matched lines: 0`、PASS 1392 件） |

turn 4（T2）は 310 s。足したのは `tests/test_decode_array.mojo` 40 件だけで、サーバーに触らないため
実行は 0.065 s × 2 サーバー。差の ≈ 47 s はこのファイルの**コンパイル**（1 サーバーあたり ≈ 23 s。
`check` は 1 ファイル 1 プロセスで両サーバー分コンパイルし直す）で、サーバーテストを持たない
テストファイルでも 1 本 ≈ 47 s 増えるという値になる。閾値 380 s まで残り 70 s。

turn 6（T4）は **318 s** で、turn 5 の 368 s より **50 s 短い**。足したのは新規ファイルではなく既存
2 ファイルへの追記（`test_encode_binary` +3 件 = 0.006 s、`test_params` +4 件 = うち 3 件がサーバーで
≈ 14 s × 2 サーバー）なので、単調に増えるはずの値が下がった = **この環境の `check` には ±50 s の
揺れがある**。turn 5 の「残り 12 s」という読みは揺れの上側を母数にしたもので、実際の母数は
310〜370 s とみるのが正しい。閾値 380 s は据え置き（T5〜T7 で超えたら PROGRESS に実測と内訳を書いて
進める、という PLAN 55 行の扱いも据え置き）。

**これが Phase 7 の見積もりの母数**（PLAN「検証コマンド」の所要見積もりの `前回末実測`）。

内訳の確認: T1 が足したテストは 3 件。`test_connection.mojo` の 2 件（`test_reset_revives_…` 11.9 s /
`test_reset_of_a_healthy_connection_…` 9.5 s）が**両サーバーで**走るので ≈ 43 s、`test_ffi.mojo` の
`test_copy_symbols_resolve` は 0.005 s × 2。この環境では 1 接続の `open` が ≈ 3.5 s かかり（どのテストも
最低 3.6 s）、reset のテストは 1 件で 3 接続を開くためこの値になる。Phase 6 末の 170〜190 s + 43 s =
213〜233 s に対して実測 263 s なので、残り 30〜50 s は同時に走らせた docker / ビルドの揺れとみる
（Phase 6 の記録でも 170〜190 s の 20 s 幅があった）。

## PLAN 訂正（turn 3）

- `check` の所要見積もり: 母数「Phase 6 末実測 169〜190 s」→ **turn 3 実測 263 s**、見積もり
  「230〜275 s」→ **323〜348 s**、閾値「300 s」→ **380 s**。根拠: (1) T1 の `reset` テスト 2 件が
  両サーバーで ≈ 43 s を足し、この分は PLAN の `+60〜85 s`（新テストファイル 4 本 + examples 2 本 +
  leak 2 ループ）に入っていなかった。(2) この環境は 1 接続 `open` ≈ 3.5 s で、新規サーバーテストの
  単価が PLAN の見積もり（`test_array` ≈ 3 s など）より高く出る余地がある。380 s は
  263 + 85 = 348 s に 1 割の余裕。**超えたら PROGRESS に理由を書く**という扱いは変えない

## チェックリスト（turn 6）

`scratch/turn-006-checklist.log` の全文（**全 77 key**）。T4 の 6 行には期待値を添える
（turn 4 からの差分は T3 の 3 行 + `test_decode_array_tests` 40 → 63（turn 5 の分）と、
T4 の 6 行だけ。`diff turn-004-checklist-after-trace.log turn-006-checklist.log` で確認）。
turn 5 のログは取り直していないので差分は 2 ターン分をまとめて載せる。

```
## T1 FFI 3 関数 + Connection.reset / _transaction_parts + TRACE / 格子
ffi_putcopydata=3
ffi_putcopyend=3
ffi_getcopydata=3
conn_reset_def=1
conn_reset_session_setup=5
conn_transaction_parts_def=1
conn_transaction_parts_sites=absent(src/pq/pool.mojo)
test_connection_tests=33
trace_exists=exists
trace_checklist_section=2
grid_script=exists
## T2 配列 OID 表 + テキスト配列リテラル + decode_text 40 分岐
oid_array_consts=21
array_elem_oid_def=1
array_oid_of_def=1
parse_array_literal_def=1
decode_text_array_def=1
decode_text_list_branches=35
decode_text_optional_branches=17
test_decode_array_tests=63
## T3 バイナリ配列デコーダ + decode_binary 40 分岐
decode_binary_array_def=1
decode_binary_list_branches=35
decode_binary_optional_branches=17
## T4 配列エンコーダ + Param 40 本
encode_array_def=1
params_list_implicit=35
params_optional_list_implicit=17
params_text_array_oid=3
test_encode_binary_tests=29
test_params_tests=37
## T5 test_array.mojo（サーバー格子）
test_array_tests=absent(tests/test_array.mojo)
## T6 copy.mojo + Connection / Transaction / PreparedStatement の結線
copy_mojo=absent
copyin_struct=absent(src/pq/copy.mojo)
copyout_struct=absent(src/pq/copy.mojo)
copy_drain_def=absent(src/pq/copy.mojo)
copy_in_defs=absent(src/pq/pool.mojo)
copy_out_defs=absent(src/pq/pool.mojo)
conn_copy_parts_defs=0
conn_check_not_copying_def=0
check_not_copying_sites=0
conn_docstring_copy_unsupported=1
init_export_copy=0
test_copy_tests=absent(tests/test_copy.mojo)
## T7 pool.mojo + test_pool / test_leak
pool_mojo=absent
pool_struct=absent(src/pq/pool.mojo)
pooled_struct=absent(src/pq/pool.mojo)
pool_release_def=absent(src/pq/pool.mojo)
pool_consume_input=absent(src/pq/pool.mojo)
pool_rollback=absent(src/pq/pool.mojo)
pool_monotonic=absent(src/pq/pool.mojo)
init_export_pool=0
test_pool_tests=absent(tests/test_pool.mojo)
test_leak_tests=20
test_leak_pool=0
## T8 README / CHANGELOG / __init__ docstring / examples / pixi.toml / final_check
readme_array_optional_row=0
readme_array_word=1
readme_copy_example=0
readme_pool_example=0
readme_out_of_scope_line=1
readme_thread_unsafe=0
readme_en_arrays=0
readme_19_types=1
readme_h2=11
changelog_phase7=0
changelog_phase_lines=6
init_docstring_phase7=0
init_docstring_copy_in=0
examples_copy=absent
examples_pool=absent
examples_params_any=0
examples_copy_next=absent(examples/copy.mojo)
pixi_example_tasks=5
final_check_examples=5
## 全体（不変 / 件数）
examples_mojo_count=7
test_file_count=25
src_mojo_count=20
src_def_ref_return=0
src_iterator_in_copy=absent(src/pq/copy.mojo)
tests_sh_bash4_only=0
```

T4 の 6 行の期待値（PLAN 表 76-77 行）と実測:

| key | 期待値 | 実測 |
|---|---|---|
| `encode_array_def` | 1 | **1** |
| `params_list_implicit` | 35 | **35**（既存 `var v: List[UInt8]` 1 + 新規 34） |
| `params_optional_list_implicit` | 17 | **17** |
| `params_text_array_oid` | ≥ 1 | **3**（import 1 + `List[String]` / `List[Optional[String]]` の 2 本） |
| `test_encode_binary_tests` | ≥ 29 | **29**（26 + 3） |
| `test_params_tests` | ≥ 37 | **37**（33 + 4。既存 33 件の期待値変更 0） |

他の 71 key は turn 5 のまま（`src_mojo_count` / `test_file_count` は新規ファイルを作らないので不変）。

## P9 実測（turn 6）

`List[String]` を OID 1009（`text[]`）で送って 1015 / 3807 の位置に届くかは RESEARCH で未実測の
1 件だった（決めた事項 9 / PLAN T4 (c)）。プローブ `scratch/turn-006-probe-p9.mojo`
（ログ `turn-006-probe-p9.log`、PG17）の実測:

```
select varchar[] OK -> {a,"b,c","d\"e"}
select jsonb[] OK -> {"{\"k\": 1}","[1, 2]"}
insert varchar[] OK -> {x,y}
nul inside element FAILED -> 22021 / invalid byte sequence for encoding "UTF8": 0x00
empty varchar[] OK -> {}
int4[] with NULL OK -> {1,NULL,3}
= ANY(int4[]) OK -> true
```

- **`$1::varchar[]` / `$1::jsonb[]` / `varchar[]` 列への INSERT はすべて通る** → 決めた事項 9
  （1009 固定 + サーバーの配列キャスト）をそのまま採用。PLAN の代替案（`Param` に `oid` 引数付き
  ctor を足して 1015 で送る）には**切り替えない**。PLAN 訂正なし
- **NUL 入り要素の sqlstate は `22021`**（`character_not_in_repertoire`、PG14 / PG17 同一）。
  決めた事項 10 の「22021 想定」が実測で確定したので、`test_params.mojo` の
  `test_nul_in_a_string_array_element_is_the_servers_call` は `kind == SERVER` だけでなく
  `sqlstate == "22021"` も断言する（このファイルの方針「SQLSTATE / OID / 値だけを断言する」に沿う。
  サブエージェントは未実測を前提に `!= ""` + `print` で書いていたのを親が差し替えた）
- 併せて `= ANY($1)`（T5 (e)）と `List[Optional[Int32]]` の `{1,NULL,3}`（T5 (b)）も通ることを確認。
  T5 はこの 2 つを本番のテストとして書く

## 陽性対照（turn 6）

`tests/test_params.mojo` の OID 表から `timetz[]` の 1 行だけを 1270 → 1266 に変えた写し
（`scratch/turn-006-posctl-oid.mojo`、ログ `turn-006-posctl-oid.log`）を走らせると
**`test_param_oids_of_the_array_types` 1 件だけが FAIL**（`reason: timetz[]: oid`、36 passed / 1 failed）。
34 行の表が literal で固定されていて、転記ミスが検査されていることの証明（PLAN T4 (d)）。
turn 4 の教訓（両方向マップだけでは循環で検査にならない）に従い、この表は `_array_oid_of` を呼ばずに
数値を直書きしている。

## チェックリスト（turn 7）

`scratch/turn-007-checklist.log` の全文（**全 77 key**）。turn 6 からの差分は 3 行だけで、
うち 2 行が T5 の到達分:

```
trace_checklist_section=2 -> 3   # turn 6 で追記した節の分（この節を足すと 4 になる）
test_array_tests=absent(tests/test_array.mojo) -> 26   # T5 の期待値 >= 14
test_file_count=25 -> 26         # tests は T7 で 28 になる見込み
```

T5 の行は 1 本だけ（`test_array_tests`）で、期待値 **>= 14** に対し **26**。

```
## T1 FFI 3 関数 + Connection.reset / _transaction_parts + TRACE / 格子
ffi_putcopydata=3
ffi_putcopyend=3
ffi_getcopydata=3
conn_reset_def=1
conn_reset_session_setup=5
conn_transaction_parts_def=1
conn_transaction_parts_sites=absent(src/pq/pool.mojo)
test_connection_tests=33
trace_exists=exists
trace_checklist_section=3
grid_script=exists
## T2 配列 OID 表 + テキスト配列リテラル + decode_text 40 分岐
oid_array_consts=21
array_elem_oid_def=1
array_oid_of_def=1
parse_array_literal_def=1
decode_text_array_def=1
decode_text_list_branches=35
decode_text_optional_branches=17
test_decode_array_tests=63
## T3 バイナリ配列デコーダ + decode_binary 40 分岐
decode_binary_array_def=1
decode_binary_list_branches=35
decode_binary_optional_branches=17
## T4 配列エンコーダ + Param 40 本
encode_array_def=1
params_list_implicit=35
params_optional_list_implicit=17
params_text_array_oid=3
test_encode_binary_tests=29
test_params_tests=37
## T5 test_array.mojo（サーバー格子）
test_array_tests=26
## T6 copy.mojo + Connection / Transaction / PreparedStatement の結線
copy_mojo=absent
copyin_struct=absent(src/pq/copy.mojo)
copyout_struct=absent(src/pq/copy.mojo)
copy_drain_def=absent(src/pq/copy.mojo)
copy_in_defs=absent(src/pq/pool.mojo)
copy_out_defs=absent(src/pq/pool.mojo)
conn_copy_parts_defs=0
conn_check_not_copying_def=0
check_not_copying_sites=0
conn_docstring_copy_unsupported=1
init_export_copy=0
test_copy_tests=absent(tests/test_copy.mojo)
## T7 pool.mojo + test_pool / test_leak
pool_mojo=absent
pool_struct=absent(src/pq/pool.mojo)
pooled_struct=absent(src/pq/pool.mojo)
pool_release_def=absent(src/pq/pool.mojo)
pool_consume_input=absent(src/pq/pool.mojo)
pool_rollback=absent(src/pq/pool.mojo)
pool_monotonic=absent(src/pq/pool.mojo)
init_export_pool=0
test_pool_tests=absent(tests/test_pool.mojo)
test_leak_tests=20
test_leak_pool=0
## T8 README / CHANGELOG / __init__ docstring / examples / pixi.toml / final_check
readme_array_optional_row=0
readme_array_word=1
readme_copy_example=0
readme_pool_example=0
readme_out_of_scope_line=1
readme_thread_unsafe=0
readme_en_arrays=0
readme_19_types=1
readme_h2=11
changelog_phase7=0
changelog_phase_lines=6
init_docstring_phase7=0
init_docstring_copy_in=0
examples_copy=absent
examples_pool=absent
examples_params_any=0
examples_copy_next=absent(examples/copy.mojo)
pixi_example_tasks=5
final_check_examples=5
## 全体（不変 / 件数）
examples_mojo_count=7
test_file_count=26
src_mojo_count=20
src_def_ref_return=0
src_iterator_in_copy=absent(src/pq/copy.mojo)
tests_sh_bash4_only=0
```

## `check` の所要（turn 7 / T5 完了時点）

`check` 1 回 = **298 s**（16:36:41 -> 16:41:39、閾値 380 s）。`PASS` 行は **1444**
（turn 6 は 1392。+52 = 26 件 x 2 サーバー）。新ファイル `tests/test_array.mojo` の実測は
**54317 で 17 s / 54314 で 4 s = 計 21 s**（1 本目はコンパイルを含む）。

PLAN 53-55 行の見積もり（`test_array` ≈ 3 s）は実行時間としては当たっているが、
**1 サーバー目のコンパイル込みで 17 s** なので、新規テストファイルの単価は
「コンパイル 13 s + 実行 4 s」で読むのが正しい。turn 6 の「±50 s の揺れ」も残るので、
残る T6 / T7 の新ファイル 2 本は +40 s 程度を見込む（298 + 40 = 338 s < 380 s）。

`TestSuite` の `Summary [ N ]` の単位は**ミリ秒**（`turn-007-time.sh` で実測:
サマリ 187 の回の `mojo run` 全体が 5 s、2 回とも同じ）。PROGRESS の turn 4 / 5 が
「0.065 s」「0.126 s」と書いているのは秒として読んだもので、ターンの判断には影響しない。

## 陽性対照（turn 7）

`scratch/turn-007-posctl-encode.sh` / `.log`。`src/pq` の**写し**（`.gsd-lite/logs/.../scratch/`、
実行後に削除）で `encode_array` の `ndim` を「空なら 0」から常に 1 に変えた。
空配列は次元語を持たない唯一のペイロードなので、これは**他のどの配列も往復し続ける中で
送信経路だけが間違える**1 箇所:

- `tests/test_array.mojo`: **`test_array_param_empty_array_round_trips` 1 件だけ** FAIL（25 passed / 1 failed）
- 対照として `tests/test_encode_binary.mojo`: `test_array_of_no_elements_is_three_int32s` 1 件だけ FAIL

判別できた（どちらのファイルも 1 件に絞られる）ので差し替えは不要。
