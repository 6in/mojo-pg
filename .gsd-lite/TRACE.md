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

## チェックリスト（turn 8）

`scratch/turn-008-checklist.log` の全文（**全 77 key**）。turn 7 からの差分は 14 行で、
うち 11 行が T6 の到達分（残り 3 行は `trace_checklist_section` と件数 2 本）:

```
trace_checklist_section=3 -> 4
copy_mojo=absent -> exists
copyin_struct / copyout_struct / copy_drain_def=absent(src/pq/copy.mojo) -> 1 / 1 / 1
conn_copy_parts_defs=0 -> 2
conn_check_not_copying_def=0 -> 1
check_not_copying_sites=0 -> 7          # 期待値 >= 7
conn_docstring_copy_unsupported=1 -> 0  # 期待値 0
init_export_copy=0 -> 1
test_copy_tests=absent -> 21            # 期待値 >= 18
src_iterator_in_copy=absent -> 0        # 不変（Iterator / Iterable を付けない）
test_file_count=26 -> 27                # T7 で 28
src_mojo_count=20 -> 21                 # T7 で 22
```

`copy_in_defs` / `copy_out_defs` / `conn_transaction_parts_sites` は `absent(src/pq/pool.mojo)`
のまま（PLAN の「`absent(pool.mojo)` は T7 まで許容」）。`Connection` と `Transaction` の
`def copy_in` はそれぞれ 1 本（`grep -cE 'def copy_in'` で確認）= T6 の期待値 2 / 2。

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
trace_checklist_section=4
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
copy_mojo=exists
copyin_struct=1
copyout_struct=1
copy_drain_def=1
copy_in_defs=absent(src/pq/pool.mojo)
copy_out_defs=absent(src/pq/pool.mojo)
conn_copy_parts_defs=2
conn_check_not_copying_def=1
check_not_copying_sites=7
conn_docstring_copy_unsupported=0
init_export_copy=1
test_copy_tests=21
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
test_file_count=27
src_mojo_count=21
src_def_ref_return=0
src_iterator_in_copy=0
tests_sh_bash4_only=0
```

## PLAN 訂正（turn 8）

- T6 ⑩（COPY IN 途中切断）の「`write` が `CONNECTION`」は**どの `write` かを固定できない**:
  `PQputCopyData` はバッファに積むだけで、実際に flush した呼び出しでしか `-1` を返さない。
  4 byte 行では close 後 5 回の `write` と `PQputCopyEnd` が全部 `1` を返し、約 8.3 KB
  チャンクでは close 直後の 1 本目が `1`、**2 本目**が `-1`（PG14 / PG17 同一）。
  → テストは 1000 行（約 10 KB）チャンクを上限 64 回まで回して**最初に失敗した `write`** を
  `CONNECTION` と断言し、その次の `write` と `finish` を `USAGE` と断言する形にした。
  PLAN 215 行の括弧内「（測定: close 後の最初の `write` がすでに -1 を返す）」は turn 1 の
  プローブが 1000 行チャンクだったときの観測で、チャンクサイズ依存のため契約にしない。
- T6 ⑭（`Transaction` が `CopyIn` より先に死ぬ順序）の handler ≥ 1 は成立するが**理由が違う**:
  `PQexec("ROLLBACK")` は COPY IN 中でも**成功する**（`PGRES_COMMAND_OK`。libpq が自前で
  `CopyFail` を送り `57014` を飲んでから ROLLBACK を走らせる）ので `Transaction.__deinit__` は
  handler に到達しない。handler を呼ぶのは**その後の `CopyIn.__deinit__`**で、その
  `PQputCopyEnd` が `-1`（`no COPY in progress`、sqlstate 無し）を返し `57014` でないため
  報告される。テストの docstring にこの経路を書いた（断言は PLAN どおり handler ≥ 1）。

## `check` の所要（turn 8 / T6 完了時点）

`check` 1 回 = **266 s**（17:13:00 -> 17:17:26、閾値 380 s）。`PASS` 行は **1486**
（turn 7 は 1444。+42 = 21 件 x 2 サーバー）。`tests/test_copy.mojo` の実測は
`final_check.log` の計測行で **54317 で 6 s / 54314 で 5 s**。

turn 7 の 298 s より **32 s 短い**（足したのは新ファイル 1 本だけで増える方向しかない）。
turn 6 の「±50 s の揺れ」の再現で、母数は依然 **260〜370 s** と読む。
T7 の新ファイル 2 本（`src/pq/pool.mojo` / `tests/test_pool.mojo`）を足しても
266 + 20 前後 = 290 s 程度の見込みで、閾値 380 s には余裕がある。

**注意**: サブエージェントの報告にあった「test_copy は 1 サーバー 334 s」は
`TestSuite` の `Summary [ 334 ]` を秒として読んだもの（turn 7 で実測した**ミリ秒**が正しい）。
`final_check.log` の `took 6s` が実測値。

## 陽性対照（turn 8）

`scratch/turn-008-posctl-copying.sh` / `.log`。`src/pq` の**写し**（実行後に削除）で
`Connection._check_not_copying` の本体を `return` に差し替えた（シグネチャと 7 箇所の
呼び出しはそのまま = T6 以前の状態）。

libpq は COPY 中の `PQexec` を拒否せず、**書いた行を黙って捨ててから**新しいコマンドを
成功させる（turn 1 の `probe-copy.log` case 5: `execute during COPY IN returned rows: 1` /
`rows a>=800000: 0`）。なので対照の判定は「USAGE が出なくなる」だけでなく
「その後の `finish()` が 2 行でなく 0 行を数える」でもある:

- `tests/test_copy.mojo`: **`test_every_other_command_during_a_copy_is_usage` 1 件だけ** FAIL（20 passed / 1 failed）
- 対照として `tests/test_transaction.mojo`: 13 件すべて PASS（0 failed）

判別できた（1 件に絞られ、無関係なファイルは無傷）ので差し替えは不要。


## チェックリスト（turn 9）

`scratch/turn-009-checklist.log` の全文（**全 77 key**）。turn 8 からの差分は 14 行で、
全部 T7 の到達分（件数 2 本と `absent(pool.mojo)` の解消を含む）:

```
pool_mojo=absent -> exists
pool_struct / pooled_struct / pool_release_def=absent(src/pq/pool.mojo) -> 1 / 1 / 1
pool_consume_input=absent(src/pq/pool.mojo) -> 5        # 期待値 >= 1
pool_rollback=absent(src/pq/pool.mojo) -> 1             # 期待値 >= 1
pool_monotonic=absent(src/pq/pool.mojo) -> 10           # 期待値 >= 1
init_export_pool=0 -> 1
test_pool_tests=absent -> 18                            # 期待値 >= 14
test_leak_tests=20 -> 22                                # 期待値 >= 22
test_leak_pool=0 -> 7                                   # 期待値 >= 2
conn_transaction_parts_sites=absent(pool.mojo) -> 3     # 期待値 >= 3
copy_in_defs=absent(pool.mojo) -> 3                     # 期待値 3
copy_out_defs=absent(pool.mojo) -> 3                    # 期待値 3
test_file_count=27 -> 28                                # 期待値 28（確定）
src_mojo_count=21 -> 22                                 # 期待値 22（確定）
```

`absent(...)` は T7 の時点で **0 件**になった（残る `absent` は T8 の examples 2 本だけ）。

```
## T1 FFI 3 関数 + Connection.reset / _transaction_parts + TRACE / 格子
ffi_putcopydata=3
ffi_putcopyend=3
ffi_getcopydata=3
conn_reset_def=1
conn_reset_session_setup=5
conn_transaction_parts_def=1
conn_transaction_parts_sites=3
test_connection_tests=33
trace_exists=exists
trace_checklist_section=5
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
copy_mojo=exists
copyin_struct=1
copyout_struct=1
copy_drain_def=1
copy_in_defs=3
copy_out_defs=3
conn_copy_parts_defs=2
conn_check_not_copying_def=1
check_not_copying_sites=7
conn_docstring_copy_unsupported=0
init_export_copy=1
test_copy_tests=21
## T7 pool.mojo + test_pool / test_leak
pool_mojo=exists
pool_struct=1
pooled_struct=1
pool_release_def=1
pool_consume_input=5
pool_rollback=1
pool_monotonic=10
init_export_pool=1
test_pool_tests=18
test_leak_tests=22
test_leak_pool=7
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
test_file_count=28
src_mojo_count=22
src_def_ref_return=0
src_iterator_in_copy=0
tests_sh_bash4_only=0
```

## PLAN 訂正（turn 9）

- T7 (d) の陽性対照「`_release` が**捨てる経路**で `conn._conn = PGconnPtr(0)` してから
  `_ = conn^`」は**判別しない**: `test_leak` の 2 ループはどちらも捨てる経路を通らない
  （ループ 1 = `Pool.open(min_size=2)` の drop は `List[_Slot]` の deinit、ループ 2 =
  `acquire` -> `execute` -> drop は park 経路）。
  → 対照を **park 経路**に差し替えた（`_release` が `_idle.append` する直前に
  `conn._conn = PGconnPtr(0)`）。park した handle の `PQfinish` が走らず、次の `acquire` が
  その接続を捨てて（`PQfinish` なし）新規に開くので 1 反復 1 handle ずつ漏れる。
  結果は下記「陽性対照（turn 9）」のとおり 1 件に絞れた。
- T7 (a) の `Pool.set_rollback_failure_handler` は `for ref slot in self._idle` では
  **コンパイルできない**（`List iteration requires the element to be 'Copyable'`。`_Slot` は
  `Connection` を所有する）→ `for i in range(len(self._idle))` の添字形にした。
- `_Slot` から `Connection` を取り出すのに `slot.conn^` は不可
  （`field '...' destroyed out of the middle of a value`）。`var self` の消費メソッドでも同じ。
  **`def take(deinit self) -> Connection`** だけが通る（`scratch/turn-009-probe-take.mojo` で実測）
  → `_Slot.take()` を足し、`opened_at` は take の前に読む形にした。
- `PooledConnection[origin: ImmOrigin]` の struct docstring には `Parameters:` 節が必要
  （無いと 3/6 段と 6/6 段が `struct takes parameters, but has no 'Parameters' in doc string`
  の warning 1 行で FAIL する）。`CopyIn` / `Transaction` と同じ 1 行を足した。

## `check` の所要（turn 9 / T7 完了時点）

`check` 1 回 = **321 s**（17:53:28 -> 17:58:49、閾値 380 s）。`PASS` 行は **1524**
（turn 8 は 1486。+38 = `test_pool` 18 件 x 2 サーバー + `test_leak` の 2 件 x 1 サーバー）
= **既存テストの期待値変更 0 件**。`FAIL` 行は 0。

内訳の実測（`final_check.log` の計測行）: `tests/test_pool.mojo` は
**54317 で 16 s（コンパイル込み）/ 54314 で 8 s**（`Summary` はミリ秒で 3363 / 3459 =
`pg_sleep` 2.2 s + 切断反映待ち）。`tests/test_leak.mojo` は **94 s**（turn 8 は 83 s。
pool 2 ループで +11 s = 見込み +10 s どおり。1 サーバーのみ）。

turn 8 の 266 s から **+55 s**。内訳は新ファイル 2 本（約 +15 s）と `test_leak` の +10 s で
約 25 s、残り 30 s は turn 6 以降ずっと見えている **±50 s の揺れ**の範囲。母数は **260〜370 s**
のまま。T8 は examples 2 本（各 2 s x 2 サーバー）と文書だけなので閾値 380 s に余裕がある。

## 陽性対照（turn 9）

3 件すべて判別できた（差し替えたのは 1 件目の対象経路だけ。上記 PLAN 訂正）。

1. **park した接続の `PQfinish` が走らない**（`src/pq` の写し、実行後に削除）:
   `_release` の `_idle.append` の直前に `conn._conn = PGconnPtr(0)` を挿入
   → built binary で `tests/test_leak.mojo` が
   **`test_pool_acquire_and_release_does_not_leak` 1 件だけ** FAIL（21 passed / 1 failed）。
   `test_pool_open_and_drop_does_not_leak` は PASS のまま（このループは park 経路を通らない
   = 2 つのループが別の経路を見ている証明にもなった）。
2. **`_stmt_counter` が接続とともに残ること**（同じ写し）: `_release` の park 直前に
   `conn._stmt_counter[0] = 0` を挿入 → `tests/test_pool.mojo` が
   **`test_the_statement_counter_rides_along_with_the_connection` 1 件だけ** FAIL
   （17 passed / 1 failed）。サーバーは `42P05`（`prepared statement "pq_stmt_1" already exists`）。
3. **P21 / T7 ⑰ の origin**（`scratch/turn-009-posctl-origin.mojo`、コンパイルのみ）:
   `var a = pool.acquire(); var p2 = pool^; _ = a.execute("SELECT 1")` が
   `error: use of uninitialized value 'pool'`（`turn-009-posctl-origin.mojo:30:18`）で
   コンパイル失敗 = 貸し出し中のプールは move できない。

## チェックリスト（turn 10）

`scratch/turn-010-checklist.log` の全文は 77 key。turn 9 からの差分は **18 行**で、
全部 T8 の到達分。これで **`absent` は 0 件**（T8 の examples 2 本が最後の absent だった）:

```
readme_array_optional_row=0 -> 3                       # 期待値 >= 2
readme_array_word=1 -> 8                               # 期待値 >= 8
readme_copy_example=0 -> 2                             # 期待値 >= 2
readme_pool_example=0 -> 2                             # 期待値 >= 2
readme_out_of_scope_line=1 -> 0                        # 期待値 0
readme_thread_unsafe=0 -> 5                            # 期待値 >= 2
readme_en_arrays=0 -> 1                                # 期待値 >= 1
changelog_phase7=0 -> 1                                # 期待値 >= 1
changelog_phase_lines=6 -> 7                           # 期待値 7
init_docstring_phase7=0 -> 1                           # 期待値 >= 1
init_docstring_copy_in=0 -> 2                          # 期待値 >= 2
examples_copy=absent -> exists
examples_pool=absent -> exists
examples_params_any=0 -> 1
examples_copy_next=absent(examples/copy.mojo) -> 1
pixi_example_tasks=5 -> 7                              # 期待値 7
final_check_examples=5 -> 7                            # 期待値 7
examples_mojo_count=7 -> 9                             # 期待値 9
```

不変を確認した key（T8 で動かしてはいけないもの）: `readme_19_types`=1（スカラの型数。
配列は別行にしたので真のまま）、`readme_h2`=11（新節は `###`）、`test_file_count`=28、
`src_mojo_count`=22、`src_def_ref_return`=0、`src_iterator_in_copy`=0、`tests_sh_bash4_only`=0。

## PLAN 訂正（turn 10）

1. **T8 (b) の「パラメータ表（`:141-159`）」は README に存在しない**。`README.md:141-159` は
   「libpq の探索順」で、パラメータの説明は `### パラメータバインド` の散文（`:207-210`）。
   PLAN の行番号は phase 5 時点の写しだった。要件・決定に触れないので**実物を正とし**、
   `List[T]` / `List[Optional[T]]` のバイナリ送信・typarray・`List[String]`=1009・
   名前付き `List` は `[ids^]` / `[ids.copy()]` を**同じ節の散文として**足した（表は作っていない）。
   `src/pq/__init__.mojo` 側の `## Parameters` には表があるので、そちらは PLAN どおり行を追加した。

## `check` の所要（turn 10 / T8 完了時点）

`check` 1 回 = **423 s**（18:14:06 -> 18:21:09）、`final_check: PASS`。テストケースの
`PASS` 行は **1524**（turn 9 と同数 = T8 はテストを増やさないので正しい。`grep -c PASS` の
生値 1525 は末尾の `final_check: PASS` を 1 行拾ったもの）。`FAIL` 行は 0 =
**既存テストの期待値変更 0 件**。6/6 段の警告 0、3/6 段の docstring 欠落 0。

段ごとの実測: 1/6 fmt 1 s、2/6 precompile 4 s、3/6 docstring 3 s、
**4/6 examples 26 s（7 本。copy / pool の 2 本増）**、**5/6 tests 389 s**、6/6 warnings 0 s。
5/6 の内訳は **54317 で 290 s / 54314 で 91 s**（1 サーバー目が 28 本のコンパイルを全部払う）。
`tests/test_leak.mojo` は **97 s**（turn 9 は 94 s。T8 は leak を触っていないので誤差）。

**turn 9 の 321 s から +102 s だが、増えた実体は 4/6 の examples 2 本（約 +10 s）だけ**で、
残り約 90 s は 1 サーバー目のコンパイル時間の揺れ。母数は turn 9 までの「260〜370 s」から
**260〜425 s** に広げて読む必要がある。

**T9 への申し送り（判断は T9 が行う）**: PLAN T9 (b) の閾値 **300 s** は、green な
turn 9（321 s）と turn 10（423 s）の 2 回とも超えている。T9 (b) は `db-reset` 後の
クリーン計測なので本番の値はこれよりさらに重くなる見込み。T9 は計測してから
閾値そのものを訂正するか判断すること（1 回の計測で決めない: PROGRESS turn 7 の注意）。

## 堅牢性格子 全セル（turn 11 / T9 (a)）

`scratch/turn-011-robust-grid.sh`（`turn-003-robust-grid.sh` の写し。違いは `BIN` のパスと
冒頭コメントだけ）を `db-reset` 直後に 1 回実行。ログ `scratch/turn-011-robust-grid.log`。

- ビルド: `built: basic params binary async_query listen_notify copy pool` = **7 本**
  （turn 3 では `copy` / `pool` が `absent` だった 2 本が実体になった。`build-failed` 0）
- セル数 **126** = 7 本 ×（入力 6 + 出力 4 × 2 + 依存 4）。**全 126 セルが `unhandled_markers=0`**
  （`traceback` / `exception_ignored` も全セル 0）
- rc の分布: `rc=0` 39 / `rc=1` 73 / `rc=141` 14。**`rc=141` は 14 セルすべて `run_epipe`**
  （7 本 × 入力 GOOD / MALFORMED）= Phase 5 からの既知の SIGPIPE 挙動で許容
- 新 2 本の代表セル: `copy conninfo=GOOD` → `copied in = 1000` / `copied out = 1000 rows` /
  `copied out bytes = 10780`（rc=0）、`pool conninfo=GOOD` → `size = 2` / `idle = 0` /
  `borrowed = 2`（rc=0）、`copy dep=LIBC` → `PgError(kind=LibpqLoad, ...missing symbol PQconnectdb)`、
  `pool dep=BADPW` → `PgError(kind=Connection, ...password authentication failed)`

入力軸の追加分（REQ §2.4。conninfo / 環境変数では与えられないので examples ではなくテスト側が担う）:

| REQ §2.4 の入力 | 所在 | 件数（実測） |
|---|---|---|
| 配列リテラルの不正形（閉じ括弧なし / 引用符の途中終端 / 空要素 / 括弧なし / 空文字 / `{` のみ / `}` のみ / 引用符で終端 / 次元接頭辞に `=` なし） | `tests/test_decode_array.mojo` の `test_malformed_*` | **10**（`grep -c '^def test_malformed_'`。P7 の 9 件 + `dimension_prefix_without_equals`） |
| バイナリ配列ヘッダの不正（flags / elemtype 不一致 / 12 byte 未満 / dim と要素数の不一致 / 要素長の不一致 / 末尾のゴミ） | 同ファイルの `test_binary_array_rejects_*` | **6**（`rejects_*` は全 8 件。残り 2 件は多次元と int2 配列 OID） |
| COPY の途中切断（クライアント側 `close(PQsocket)`） | `tests/test_copy.mojo` ⑩ = `test_copy_in_after_the_socket_is_closed` / `test_copy_out_after_the_socket_is_closed` | **2** |
| プールの枯渇 / 死んだ接続の再利用 | `tests/test_pool.mojo` ① ⑦ ⑧ ⑨ = `test_two_guards_fill_the_pool_then_the_returned_one_is_reused` / `test_a_terminated_borrowed_connection_is_discarded` / `test_the_health_check_catches_a_kill_the_borrower_never_saw` / `test_a_kill_with_no_wait_is_only_seen_by_the_next_borrower` / `test_acquire_resets_a_connection_killed_while_it_was_idle` | **5** |

## 受け入れ基準対応表（turn 11 / T9 (d)）

REQ §4.1〜§4.4 の各行 → それを判定しているテスト名 / PLAN の完了基準番号。
テスト名は `tests/` 配下の `def test_*`（`grep -n '^def test_' tests/<file>` で引ける）。

### REQ §4.1 配列型

| REQ §4.1 の行 | 検証した場所（テスト名） | 完了基準 |
|---|---|---|
| 19 型それぞれ text / binary で一致 + Phase 3 の境界値が要素としても往復 | `tests/test_array.mojo` の 15 件（`test_array_bool_matches_text_and_binary` 〜 `test_array_interval_matches_text_and_binary`、`test_array_int8_reads_as_int_and_int64`、`test_array_six_text_oids_decode_as_string_list`）+ 単体の境界値 `tests/test_decode_array.mojo` の `test_text_array_{numeric,float8}_specials` / `test_text_array_timestamp_infinities` / `test_binary_array_{numeric,interval,bool_and_bytea}_element*` | T5 (a) / T2 (e) / T3 (c) |
| 空配列 `'{}'::int4[]` が空の `List` | `test_array_empty_is_empty_list_in_both_formats`、単体 `test_text_array_empty_is_empty_list` / `test_binary_array_*`（ndim 0）、送信側 `test_array_param_empty_array_round_trips` | T5 (b)(e) / T2 (e) / T3 (c) |
| 配列 OID と `T` の不一致（`int2[]` を `List[Int32]`）は `TYPE_MISMATCH` | `test_array_element_oid_mismatch_in_both_formats`、単体 `test_text_array_rejects_int2_array_for_int32` / `test_binary_array_rejects_the_int2_array_oid_for_int32` / `test_binary_array_rejects_a_foreign_element_type` | T5 (c) / T2 (e) / T3 (c) |
| 配列列を `String` で読むとテキスト形式ではリテラルがそのまま | `test_array_column_as_string_is_the_literal_in_text_only`、単体 `test_text_array_column_read_as_string_is_the_literal` / `test_binary_array_column_read_as_string_is_still_rejected` | T5 (d) |

### REQ §4.2 COPY

| REQ §4.2 の行 | 検証した場所（テスト名） | 完了基準 |
|---|---|---|
| text 10 万行 → `affected_rows() == 100000` + `count(*)` 一致 / CSV / binary 各 1 件 | `test_text_copy_in_takes_every_row` / `test_csv_copy_in_stores_quoted_fields` / `test_binary_copy_in_stores_both_rows` | T6 (d) ① ② ③ |
| `copy_out` の行数と内容が `copy_in` のバイト列と一致 | `test_copy_out_returns_every_row_then_none` | T6 (d) ④ |
| `abort()` / `finish()` なしの破棄で行が残らず、その後の `execute` が通る | `test_abort_discards_the_rows_without_raising` / `test_dropping_an_unfinished_copy_in_cancels_it_quietly` | T6 (d) ⑤ ⑥ |
| `copy_out` を途中で破棄した後の `execute` が通る | `test_dropping_a_copy_out_mid_stream_leaves_the_connection_usable` | T6 (d) ⑦ |
| COPY 中の `execute` / `transaction` / 2 つ目の `copy_*` は `USAGE`、サーバーには何も送られない | `test_every_other_command_during_a_copy_is_usage`（7 件の格子 + `finish()` が 2 行を数える）。陽性対照は TRACE「陽性対照（turn 8）」 | T6 (d) ⑧ |
| 不正データは `finish()` が `22P04` 等の `SERVER`、接続はアイドルに戻る | `test_malformed_row_surfaces_from_finish` | T6 (d) ⑨ |
| 途中切断で `write` / `next` / `finish` が `CONNECTION`、トレースバック無し | `test_copy_in_after_the_socket_is_closed` / `test_copy_out_after_the_socket_is_closed` | T6 (d) ⑩ |
| `Transaction` 内の `copy_in` を `rollback()` すると行が残らない | `test_transaction_copy_in_rollback_loses_the_rows`（対照 `test_transaction_copy_in_commit_keeps_the_rows`、破棄順序 `test_transaction_destroyed_before_its_copy_in`） | T6 (d) ⑬ ⑭ |

### REQ §4.3 プール

| REQ §4.3 の行 | 検証した場所（テスト名） | 完了基準 |
|---|---|---|
| `max_size=2` で 2 回成功・3 回目 `USAGE`・`pg_stat_activity` = 2、drop 後の `acquire` が同じ `backend_pid` | `test_two_guards_fill_the_pool_then_the_returned_one_is_reused` | T7 (c) ① |
| `min_size=2` で `open` 直後に `idle() == 2` / `size() == 2` / サーバーにも 2 本 | `test_min_size_opens_its_connections_before_open_returns` | T7 (c) ② |
| commit せずガードを drop → 返却時に ROLLBACK、次の利用者が IDLE で変更も残らない | `test_a_dropped_transaction_block_is_rolled_back_before_reuse`（`Transaction` 側が先に ROLLBACK）/ `test_release_rolls_back_a_raw_begin_and_keeps_the_connection`（プールの `_release` の `INTRANS` 経路） | T7 (c) ③ ④ |
| 未完了の `copy_in` を持つガードの drop | `test_an_unfinished_copy_in_is_cancelled_and_the_connection_kept`（**決めた事項 20 で文言を読み替え**: Mojo の破棄順では接続は捨てられず再利用される）+ 白箱 `test_a_connection_left_active_is_discarded_on_return`（`ACTIVE` なら捨てる分岐の証明） | T7 (c) ⑤ ⑥ |
| 貸し出し中に `pg_terminate_backend` された接続を返却 → 捨てられ次の `acquire` は新規 | `test_a_terminated_borrowed_connection_is_discarded` / `test_the_health_check_catches_a_kill_the_borrower_never_saw` / `test_a_kill_with_no_wait_is_only_seen_by_the_next_borrower` / `test_acquire_resets_a_connection_killed_while_it_was_idle` | T7 (c) ⑦ ⑧ ⑨ |
| `max_lifetime_s=1` の接続は返却時に閉じられ、次の `backend_pid` が変わる | `test_max_lifetime_retires_a_connection_on_return`（対照 `test_the_default_lifetime_never_retires_anything`） | T7 (c) ⑩ |
| `close()` 後の `acquire` は `USAGE`、`Pool` の破棄で空き接続が `PQfinish` される | `test_close_drops_the_idle_connections_and_refuses_to_lend` + `tests/test_leak.mojo` の `test_pool_open_and_drop_does_not_leak` / `test_pool_acquire_and_release_does_not_leak`（RSS 判定 2 ループ） | T7 (c) ⑪ / T7 (d) |
| `max_size <= 0` / `min_size > max_size` は `USAGE` でサーバーに接続しない | `test_bad_sizes_are_usage_errors_before_anything_is_dialled`（4 ケース + `pg_stat_activity` 不変） | T7 (c) ⑫ |

### REQ §4.4 共通

| REQ §4.4 の行 | 検証した場所 | 完了基準 |
|---|---|---|
| `pixi run check` 6/6 PASS（PG 14 / 17 両方）、`mojo build` 警告ゼロ | `scratch/turn-011-check.log`（`final_check: PASS`、5/6 段が 54317 → 54314 の 2 周）、`pixi run package` 警告ゼロ、6/6 段 `matched lines: 0` | T9 (b) |
| CI 3 OS 緑 | **未実施**（`ci.yml` の `on:` は `pull_request` / `push(main)` → T9 の branch push では走らない）。PR 作成は verify の仕事 = P29 の申し送り | T9 (e) + verify |
| README の型マッピング表・クイックスタート 2 節・「既知の制限」の書き換え、CHANGELOG `[Unreleased]` | チェックリスト key `readme_array_optional_row` / `readme_array_word` / `readme_copy_example` / `readme_pool_example` / `readme_thread_unsafe` / `readme_en_arrays` / `readme_out_of_scope_line`=0 / `changelog_phase7` / `changelog_phase_lines`=7 + 抜粋照合器（turn 10） | T8 (b)(c) |
| `examples/copy.mojo` / `pool.mojo` 新設 + `pixi.toml` の `example-*`、配列は `params.mojo` に `= ANY($1)`、全 examples が単体で実行できる | `examples_copy`=exists / `examples_pool`=exists / `examples_params_any` / `pixi_example_tasks`=7 / `final_check_examples`=7 / `examples_mojo_count`=9。単体実行は `check` 4/6 段 7 本 + 堅牢性格子 126 セル | T8 (a) / T9 (a)(b) |
| `Connection.execute` docstring の「COPY は未対応」を `copy_in` / `copy_out` の案内に | チェックリスト key `conn_docstring_copy_unsupported`=0、`check_not_copying_sites` ≥ 7 | T6 (c) |
| state の `verify_round_max` は 4 | `.gsd-lite/state.json`（`verify_round_max: 4`） | T1 |
| §2.4 の堅牢性 | `scratch/turn-011-robust-grid.log`（126 セル全部 `unhandled_markers=0`）+ 入力軸の追加分はテスト側（下表） | T9 (a) |

## verify への申し送り（turn 11 / T9 (d)）

落とし穴 P1〜P29（RESEARCH）を「どこで検証したか」に対応づけた表。測り方は
`scratch/turn-011-pitfalls.sh`（`grep -cE <パターン> <ファイル>` を素のファイルに当てる。
チェックリストと違いコメント行を除外しないので、`test_leak_pool`=7 と P24=12 のように
同じ語でも値が違う）。出力は `scratch/turn-011-pitfalls.log`。

| P | grep パターン（`grep -cE`） | 件数 | ファイル |
|---|---|---|---|
| P1 | `rejects_invalid_flags\|null_and_multibyte\|null_element_is_none_when_optional` | 3 | `tests/test_decode_array.mojo` |
| P2 | `header_shorter_than_twelve_bytes\|foreign_element_type` | 2 | `tests/test_decode_array.mojo` |
| P3 | `dimension_the_cell_cannot_fill\|element_of_the_wrong_width\|bytes_after_the_last_element` | 3 | `tests/test_decode_array.mojo` |
| P4 | `multidimensional\|dimension_prefix\|lower_bound_is_dropped` | 12 | `tests/test_decode_array.mojo` + `tests/test_array.mojo` |
| P5 | `int2_array\|element_oid_mismatch\|six_text_oids\|six_array_oids` | 6 | 同上 |
| P6 | `nine_elements_unescaped\|bpchar_keeps_padding\|bytea_elements_decode_to_bytes\|lowercase_null_word` | 4 | `tests/test_decode_array.mojo` |
| P7 | `^def test_malformed_` | 10 | `tests/test_decode_array.mojo` |
| P8 | `array element ` | 8 | `src/pq/decode_text.mojo` + `src/pq/decode_binary.mojo` |
| P9 | `varchar\[\]\|jsonb\[\]` | 2 | `tests/test_array.mojo` |
| P10 | `^def test_`（既存の期待値変更 0 件の母数） | 51 | `tests/test_params.mojo` + `tests/test_binary.mojo` |
| P11 | `after_the_socket_is_closed` | 2 | `tests/test_copy.mojo` |
| P12 | `malformed_row_surfaces_from_finish` | 1 | `tests/test_copy.mojo` |
| P13 | `every_other_command_during_a_copy_is_usage` | 1 | `tests/test_copy.mojo` |
| P14 | `rejects_a_copy_to_stdout\|rejects_a_copy_from_stdin\|rejects_a_plain_select` | 3 | `tests/test_copy.mojo` |
| P15 | `drains_the_statement_behind_it` | 1 | `tests/test_copy.mojo` |
| P16 | `transaction_destroyed_before_its_copy_in\|transaction_copy_in_(commit\|rollback)` | 3 | `tests/test_copy.mojo` |
| P17 | `dropping_a_copy_out_mid_stream\|dropping_an_unfinished_copy_in` | 2 | `tests/test_copy.mojo` |
| P18 | `\.next\(\)`（`while` 形の例。`src_iterator_in_copy`=0 と対） | 1 | `examples/copy.mojo` |
| P19 | `reset\(\)` | 5 | `tests/test_connection.mojo` |
| P20 | `terminated_borrowed_connection_is_discarded\|health_check_catches_a_kill\|kill_with_no_wait` | 3 | `tests/test_pool.mojo` |
| P21 | `two_guards_fill_the_pool\|every_forwarded_method_reaches`（陽性対照は TRACE「陽性対照（turn 9）」3） | 2 | `tests/test_pool.mojo` |
| P22 | `statement_counter_rides_along` | 1 | `tests/test_pool.mojo` |
| P23 | `max_lifetime_retires\|default_lifetime_never_retires` | 2 | `tests/test_pool.mojo` |
| P24 | `Pool`（2 ループ + ヘルパ） | 12 | `tests/test_leak.mojo` |
| P25 | `failed_implicit_rollback_reaches_the_handler_once` | 1 | `tests/test_pool.mojo` |
| P26 | `examples/(copy\|pool)\.mojo` | 2 | `tests/final_check.sh` |
| P27 | `unhandled_markers=0` | 126 | `scratch/turn-011-robust-grid.log` |
| P28 | `warning:\|WARNING:\|implicit ROLLBACK failed` | **0** | `build/final_check.log` |
| P29 | `P29`（この申し送り自体。CI 3 OS は未実施） | 0 → ≥ 1 | `.gsd-lite/TRACE.md` |

verify への申し送り（上の表に乗らないもの）:

1. **P29 / CI は未実施**。`ci.yml` の `on:` は `pull_request`（base main）と `push`（main）だけで、
   T9 の branch push では run が起動しない（REQ §6: PR を作るのは verify）。OS 固有の経路は
   `close(PQsocket)` の EBADF（`test_copy` ⑩）と `pg_stat_activity` / `pg_terminate_backend` の
   権限（`test_pool` 全件）。macOS で赤くなったら `final-check-log-macos-latest` artifact の
   `test_copy` / `test_pool` の PASS 行を見ること。`verify_round_max` は 4（D1）
2. **REQ §4.3 の「未完了 `copy_in` のガードを drop → その接続は捨てられ `size()` が 1 減る」は
   決めた事項 20 で読み替えた**（Mojo の破棄順では `CopyIn.__deinit__` が先に COPY を中止するので
   接続は IDLE に戻り再利用される）。白箱の `test_a_connection_left_active_is_discarded_on_return` が
   `ACTIVE` 分岐側を押さえている。README「既知の制限」に 1 行。**この項は差し戻し対象にしない**
3. **`CopyOut` は `Iterator` ではない**（決めた事項 7。REQ §2.2 からの意図的な逸脱。
   Mojo 1.1.0 の `Iterator.__next__` は `raises StopIteration` ちょうどでないと適合しない）。
   README「既知の制限」に明記済み。**この項も差し戻し対象にしない**
4. F 項目（見込みと実測の差）は `+/-` 単位で読む（Phase 5 reflect 提案 6）。`check` の母数は
   **260〜425 s**（turn 9 321 s / turn 10 423 s / turn 11 298 s）
5. 既存テストの期待値変更は **全ターンで 0 件**（T1〜T9。`check` の `FAIL` 行 0 が毎ターンの証拠）

## `check` の所要（turn 11 / T9 完了時点・クリーン状態）

`db-reset` → `check` を 1 回。**298 s**（`21:15:26` -> `21:20:24`、`scratch/turn-011-check-start.txt`
/ `-check-end.txt`）、`final_check: PASS`。**PLAN T9 (b) の閾値 300 s を下回ったので訂正は不要**
（turn 10 の申し送りは「超えるなら訂正を判断」だった。turn 10 の 423 s との差 125 s は
1 サーバー目のコンパイル時間の揺れで、turn 11 は grid のビルドでキャッシュが暖まっていた分だけ速い）。

- 段ごと: 1/6 fmt 1 s（差分 0）/ 2/6 precompile 4 s / 3/6 docstring 3 s（欠落 0）/
  **4/6 examples 20 s（7 本）** / **5/6 tests 264 s** / 6/6 warnings 0 s（`matched lines: 0`）
- 5/6 の内訳: **54317 で 176 s（`test_leak` 89 s を含む）/ 54314 で 83 s**、ファイル実行 55 回
  （28 本 + 27 本。`test_leak` は 1 サーバー目のみ）
- テストケースの `PASS` 行 **1524**（turn 9 / turn 10 と同数 = T9 はテストを増やさない）、
  `FAIL` 行 **0** = 既存テストの期待値変更 0 件。`SKIP` は PG14 側の既知分のみ

## チェックリスト（turn 11）

`scratch/turn-011-checklist.log`、**全 77 key**。turn 10 からの差分は
**`trace_checklist_section` の 6 → 7 の 1 行だけ**（turn 10 の TRACE 節が増えた分。期待値 ≥ 1）。
`absent` **0 件**、他の 76 key は turn 10 と完全一致（`diff turn-010-checklist.log turn-011-checklist.log`）。
この節を足した後は 8 になる（同じ key の `≥ 1` を維持）。

## PLAN 訂正（turn 11）

1. **T9 (a) の「配列リテラル不正 9 件」は実測 10 件**。`grep -c '^def test_malformed_' tests/test_decode_array.mojo` = 10 で、
   RESEARCH P7 が挙げた 9 件（`{1,2` / `{"abc}` / `{1,,2}` / `{1,2}}` / `1,2` / 空文字 / `{` / `}` / `{"a`）に
   T2 が `test_malformed_dimension_prefix_without_equals` を 1 件足していた（P4 の `[..]=` 接頭辞の異常系）。
   要件・決定に触れないので**実物と実測を正とし**、PLAN T9 (a) の件数を 10 に直した。
2. **T9 (b) の閾値 300 s は訂正しない**。turn 10 の申し送りは「超えるなら訂正を判断」だったが、
   クリーン状態の実測は **298 s** で閾値内に収まった（`scratch/turn-011-check-start.txt` / `-check-end.txt`）。
   母数の揺れ（260〜425 s）は「`check` の所要（turn 11 / T9 完了時点・クリーン状態）」節に記録した。
