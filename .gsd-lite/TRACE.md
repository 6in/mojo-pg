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

turn 4（T2）は 310 s。足したのは `tests/test_decode_array.mojo` 40 件だけで、サーバーに触らないため
実行は 0.065 s × 2 サーバー。差の ≈ 47 s はこのファイルの**コンパイル**（1 サーバーあたり ≈ 23 s。
`check` は 1 ファイル 1 プロセスで両サーバー分コンパイルし直す）で、サーバーテストを持たない
テストファイルでも 1 本 ≈ 47 s 増えるという値になる。閾値 380 s まで残り 70 s。

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
