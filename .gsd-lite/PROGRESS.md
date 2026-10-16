# PROGRESS — phase3-binary-all-types

## turn 1 — research — 全型の text / binary 形式を PG17 / PG14 で実測、zero-copy は「消費する移動」の形で成立、RESEARCH.md 産出
- やったこと: libpq プローブ 1 本（約 330 行、出力 130 行、PG17 / PG14 の差 3 行）で REQ §4.2 / §4.3 の全型 + パラメータ送信 + 不正バイナリの sqlstate + GUC を実測。
  Mojo プローブ 10 本（zero-copy ×7、型事実、暦算法、ベンチ baseline）。サブエージェント 1 本で psycopg（ローカル）/ asyncpg / rust-postgres / PG ソース / Mojo OSS を調査。
  RESEARCH.md（§0 結論 8 件、§0.5 落とし穴、§1 OSS、§2 実測、§3 盗める設計 11 件、§4 落とし穴 30 件 + 検証法、§5 REQ 反映、§6 plan 申し送り）。
  D7 により REQ 本文を 5 箇所訂正（interval の PG17 ±infinity、timestamptz の ` BC` 位置、numeric Inf の dscale 32、zero-copy 成立条件の形、持ち越し整理 10 番）
- 想定外:
  (1) **zero-copy の成立条件「`Result` 破棄後の使用がコンパイルエラー」は `_ = res^` の形では起きない**。`_ = res^` の後に slice を使うコードはコンパイルが通り、`Result` の deinit が slice の最後の使用の後まで延びる（安全）。
      コンパイルエラーになるのは `var r2 = res^` / 関数へ `res^` を渡した後の使用（`error: use of uninitialized value 'res'`）。既存の `Row` も同じで、Phase 1 の docstring「コンパイルエラー」は不正確（REQ §6-10 に追加）。
      さらに `ref r = res; _ = res^; r._len()` は通って deinit が先に走る（use-after-free）
  (2) PG17 には interval の ±infinity がある（PG14 には無い）。REQ §4.3 の表に無かった
  (3) numeric の ±Infinity をサーバーが dscale=32 で送ってくる（ヘッダビットの癖）。往復テストをバイト比較で書くと落ちる
  (4) timestamptz のテキストは ` BC` がオフセットの後（`0001-01-01 00:00:00+00 BC`）
  (5) Mojo 1.1.0 に `InlineArray` は無く `Array[UInt8, 16]`。`Span` の生ポインタ ctor は `unsafe_ptr=`。`String(bytes=)` は無く `String(from_utf8=)`（検証あり）
  (6) 自分のプローブで ASAP 破棄を踏んだ: `pp.values()` のアドレスを取った後に `pp` の最後の使用が来て、libpq が解放済みバッファを読み `22P03 invalid sign` になった（`_ = pp^` を後ろに置いて解決）
  (7) 実測値の hex を手で読み違えた（`002c95d4` を 2922196 と誤読。正 2921940）。サブエージェントの報告と突き合わせて気づいた
- やり直し: 4 回（probe-binary 1 回: (6) + date 番兵の off-by-one + `p[i]` の deprecated 警告 / probe-zerocopy 1 回: `Span(ptr=)` → `unsafe_ptr=` / probe-types 1 回: (5) + `s[0:4]` + `rjust` /
  probe-civil 1 回: (7)）。プローブは最初の 1 本（probe-binary）をコンパイルしてから残りを書いた
- 次への注意:
  - 確認済み: RESEARCH §2.2 の hex / 文字列は PG17 / PG14 の実測。そのままテストの期待値に写してよい。PG17 限定は interval infinity のみ
  - 確認済み: zero-copy の陽性対照は `scratch/turn-001-probe-zerocopy-neg6.mojo`（`var r2 = res^` の後に slice 使用）の形。`_ = res^` の形では落ちない
  - 確認済み: `_ = x^` は生存マーカー。plan / impl のテストで「ここで PQclear」を確かめたいときは slice / Row を `_ = x^` より前で使い切る
  - 未確認: `types.mojo` を 3 分割する案（RESEARCH §6）の行数見積もり（1,500 行規模は推測）
  - 未確認: `Interval` の無限値で分解アクセサを呼んだときの kind（`USAGE` 推奨、plan が決める）
  - 所要（単位 ms）: probe-bench の libpq 素の所要は text 41〜45 ms / binary 36〜39 ms（10 万行 × 5 列）。ベンチ task は 1 s 未満で終わる見込み

## turn 2 — plan — 9 タスク（T1 持ち越し + GUC / T2 ResultFormat + decode_binary 8 型 / T3 Decimal + UUID + jsonb / T4 Date 系 3 型 / T5 Time 系 + Interval / T6 サーバー格子 / T7 zero-copy / T8 leak + examples + bench / T9 文書 + 最終判定）
- やったこと: REQ / DECISIONS / RESEARCH / 直近 2 件の reflect / Phase 2 PLAN / `src/pq/*.mojo` / `tests/*` / research のプローブ 5 本を読み、PLAN.md を作成。
  決めた事項 14 件（`ResultFormat` の形、`decode_binary[T](bytes: Span[UInt8], oid)` のシグネチャと長さ・値検査、`TYPE_MISMATCH` の 4 系統のメッセージ、`Decimal` の private フィールド + ctor は `USAGE` / `parse` は `TYPE_MISMATCH`、
  日時 6 型の API（生 ctor 無検査・`from_*` は `USAGE`・無限値のアクセサは `USAGE`）、zero-copy の 2 メソッド（`get_bytes` は形式・OID 不問、`get_text` は文字列系のみ）、GUC の `SET` は `_adopt` 内で `execute` 経由、
  型モジュール 3 分割、`Transaction.execute` への `result_format` passthrough）。RESEARCH §3 の採否表（11 件中 10 採用・1 却下）、§4 の落とし穴 30 件の対応表、reflect 提案の反映表、各タスクのサブエージェント推奨本数（T7 / T9 は 0）を PLAN に載せた
- 想定外:
  (1) REQ §4.5 の `get_bytes` は OID 制限が無く、D9 の「生バイトの逃げ道にしない」と読み方が衝突し得る。REQ の文言どおり「`PQgetvalue` 領域を見る別 API」として形式・OID 不問にし、根拠を決めた事項 9 に書いた（verify が D9 違反と読むなら T7 で bytea 限定に狭める 1 行の変更で済む）
  (2) `Time(86400000001)` の拒否を REQ P11 は ctor `USAGE` と decode `TYPE_MISMATCH` のどちらでもよいとしていた。生 ctor は全型で無検査（PG 内部表現の器）に統一し、`from_hms` で `USAGE`、decode で `TYPE_MISMATCH` に決めた
  (3) `tests/test_leak.mojo:115-134` の `TOLERANCE_PAGES` docstring は既に 83 ページの一段を書いているが、原因の主語が「libpq の lazy first-use allocation」で REQ §6-8 / D4 の「glibc arena の拡張と推測、未特定」と違う。T1 (h) で書き換える
- やり直し: 0 回（PLAN の T2 (e) ⑦ と T6 (a) ⑥ の文面を書いた直後に 1 回ずつ直したが、ファイルの作り直しではない）
- 次への注意:
  - 確認済み: `c_int(0)` の置き換え位置は `connection.mojo:362` / `prepared.mojo:188`。`PQfformat` / `PQgetlength` / `PQserverVersion` は `_ffi/functions.mojo:101-103` / `:108-110` / `:50` にバインド済み。`Connection.server_version()` は `connection.mojo:712-719`
  - 確認済み: docker の PG17 / PG14 は healthy（Up 24 hours）。`mojo` / `pixi` は `/home/parallels/.pixi/bin/pixi run ...`。lean-ctx MCP は未接続
  - 確認済み: research のプローブ（`scratch/turn-001-*`）は雛形として使ってよい（`probe-civil.mojo` の暦算法はそのまま写せる、`probe-zerocopy-neg6.mojo` が陽性対照の形）
  - 未確認: `check` の所要見込み 2〜3 分 / `pixi run test` 7〜8 分（Phase 2 末の 80〜115 s / 5〜6 分 + SET 1 往復 × 10,000 + leak 2 本 + 新テスト 7 本の積み上げ）。T1 で `check` を回したら実測を PLAN「検証コマンド」節に訂正として書く
  - 未確認: `types_datetime.mojo` が T4 + T5 で 1,000 行を超える見込み。超えても分割しない（T5 は追記）
  - 未確認: `String(unsafe_from_utf8=span)` の正確な ctor 名（RESEARCH §0.5 は `String(from_utf8=span)` が検証あり、`String(unsafe_from_utf8=span)` が検証なしと記す。T2 の最初のコンパイルで確定し、違えば決めた事項 3 の末尾を訂正する）

## turn 3 — impl — T1 持ち越し整理 10 件 + 接続時の GUC 固定 + test_connection 3 件
- やったこと: REQ §6 の 10 件（docstring 6 件 + コード 4 件: 6/6 段の grep パターン、`param_type_oid` の 0 パラメータ文言、savepoint 名の `_reject_nul(name, "name")`、
  `_ParamBuffers` の 1 GiB 超 USAGE）と REQ §4.7 の `_SESSION_SETUP_SQL`（`_adopt` が 1 つの `PQexec` で `SET DateStyle` + `SET IntervalStyle`）を実装。
  テストは test_connection 3 件（28 → 31）、test_prepared 1 件（0 パラメータ文の `takes no parameters`）、test_savepoint 1 件（NUL 名の 3 メソッド）を追加。サブエージェントは使わず順に実装（並列サブ作業は A の 1 本だけで、A と親の対象ファイル（connection / transaction）が重なるため）
- 想定外:
  (1) T1 (f) の「NUL テストの期待を直す」は**直す対象が無かった**（`grep -rn 'nul\|NUL' tests/test_savepoint.mojo` が 0 件）。メッセージが `in name` であることを担保するテストが存在しないので新規に 1 件書いた（`test_savepoint_name_with_a_nul_byte_is_rejected`。3 メソッド全部 + `PQTRANS_INTRANS` 不変 + マーカー非エコー）
  (2) T2 の追従先チェックリストの検査コマンド `grep -rn 'is Phase 3' src/pq` は**変更前から 0 件**だった（該当文が `is` と `Phase 3.` の間で行送りされている）。検査にならないので PLAN を訂正した
  (3) `check` / `pixi run test` の所要は見込み（2〜3 分 / 7〜8 分）より短く、Phase 2 末とほぼ同じだった。GUC の SET 1 往復 × connect ループ 10,000 回の +10 s は体感できる差にならなかった
- やり直し: 0 回（新規テスト 5 件とも初回のコンパイル・実行で通った）
- PLAN 訂正: 2 件
  - 検証コマンド節に T1 実測（`check` 113 s / `pixi run test` 約 200 s / test_leak 74 s・サーバー）を追記（根拠: turn 3 の実測。見込み欄は残した）
  - 追従先チェックリスト「`execute` に `result_format` 引数を足す（T2）」の検査を `grep -rn 'is Phase 3' src/pq` → `grep -rn 'Phase 3' src/pq --include='*.mojo'` が `encode_binary.mojo:16` の 1 行だけ、に（根拠: 元の grep は変更前でも 0 件で検査にならない）
- 既存テストの期待値を変えた箇所: 1 件のみ
  - `tests/test_prepared.mojo:543-544` の `find("3")` / `find("1")` → `find("takes 3 parameters, got 1") >= 0`（REQ §6-3。`"1"` はメッセージ中の `pq_stmt_1` にも当たるため検査が緩かった。意味は同じで厳しくなった）
  - それ以外は無変更で PASS（test_result / test_params / test_transaction / test_decode_text / test_encode_binary / test_errors / test_ffi / test_leak / test_smoke / test_loader_fail）
- 陽性対照（T1 (b)。実測）: `printf 'pq: implicit ROLLBACK failed: x\n' >> build/final_check.log` の後
  `grep -cE 'warning:|WARNING:|implicit ROLLBACK failed' build/final_check.log` → **1**、
  `grep -cE 'warning:|WARNING:' build/final_check.log` → **0**（旧パターンは取り逃がす）。確認後 `rm -f build/final_check.log`
- 次への注意:
  - 確認済み: `pixi run check` 6/6 PASS = **113 s**（1/6 fmt 1 s・2〜4/6 計 7 s・5/6 tests 105 s・6/6 grep 0 s、`matched lines: 0`）。`pixi run test` 両サーバー 13 ファイル全 PASS = **約 200 s**（test_leak は 12 件 74 s / サーバー）。`pixi run fmt` は差分ゼロ
  - 確認済み: `_adopt` の `SET` は `Connection` を組み立てた後に `_ = connection.execute(String(_SESSION_SETUP_SQL))` → `return connection^` の形で通る（失敗時の `PQfinish` は `__deinit__` 任せ、別に書かない）。`SHOW DateStyle` は `open(String)` / `open(Dict)` の両方で `ISO, YMD`、`SHOW IntervalStyle` は `postgres`、`SHOW client_encoding` は `UTF8`（PG17 / PG14 とも）
  - 確認済み: 追従先チェックリストの T1 関連行 — `grep -c '^def test_' tests/test_connection.mojo` = **31**、`grep -rn 'PQexec(' src/pq --include='*.mojo' | wc -l` = **4**、`grep -rn 'PQfreemem(' src/pq --include='*.mojo' | wc -l` = **2**（GUC の SET は `execute` 経由なので増えていない）
  - 確認済み: `_reject_nul(name, "name")` は `self._check_open()` の**後**・`escape_identifier` の前に置いた（「先頭」を厳密に取ると閉じたブロックでの NUL が USAGE → TYPE_MISMATCH に変わるため、既存の優先順位を保った。REQ §6-6 の目的「メッセージが `in s` でなく `in name`」は満たす）
  - 未確認: T2 で `String(unsafe_from_utf8=span)` の ctor 名（turn 2 の申し送りのまま。最初のコンパイルで確定する）
  - 未確認: `_SESSION_SETUP_SQL` の失敗経路（`SET` が拒否される状況）は再現手段が無く未実測。コードレビューのみ（PLAN「観点の担当」の異常系どおり）

## turn 4 — impl — T2 `ResultFormat` / `result_format` 引数 / `decode_binary`（既存 8 型）/ `Row.get` の形式自動切替
- やったこと: `ResultFormat`（`PgErrorKind` と同形の Int newtype）と `Result.column_format` / `Row._raw` を `result.mojo` に新設、3 つの `execute`（Connection / PreparedStatement / Transaction）に `result_format: ResultFormat = ResultFormat.TEXT` を追加、
  `src/pq/decode_binary.mojo` を新設（既存 8 型、長さ厳密 + bool は 0/1 のみ + jsonb version 1 のみ）、`Row.get` / `get_optional` を `PQfformat` で分岐するだけにした。
  テストは `tests/test_decode_binary.mojo` 44 件（サーバー不要）+ `tests/test_binary.mojo` 14 件（サーバー）。**サブエージェント 3 本を並行**（A: decode_binary + 単体テスト / B: ResultFormat と結線 / C: test_binary.mojo を契約から独立に）。対象ファイルは重ならせず、統合・`fmt` 1 回・全検証は親が実施
- 想定外:
  (1) **`bytes: Span[UInt8]`（origin 無し）はコンパイルできない**（`error: 'Span' failed to infer parameter 'origin'`）。決めた事項 3 のシグネチャは `[origin: ImmOrigin, //, T: Copyable]` + `Span[UInt8, origin]` が**必須**で、`Span` を取る全関数（個別 decoder 6 本 + `_be_bits` / `_check_length`）に同じ前置が要る。呼び出し側は `decode_binary[T](span, oid)` のままなので B / C の書き方には影響しなかった
  (2) **`(-0.0)::float8` では負のゼロにならない**。`-0.0` が numeric リテラルとして解釈され、numeric に符号付きゼロが無いため PG14 / PG17 とも `0` を返す。`'-0'::float8` / `'-0'::float4` と書く必要がある（C が実測して気づき、PLAN を訂正）
  (3) 追従先チェックリストの `grep -c '^def decode_' src/pq/decode_binary.mojo` の期待値 14 は、`decode_binary` 自身の行を数え落としていた（正しくは 15）
  (4) `Row.get` が 1 セルにつき `PQftype` + `PQfformat` の 2 回 FFI を呼ぶ形になった。形式は結果全体で一定なので `Result.__init__` で 1 回キャッシュできるが、契約外なので実装せず T8 の bench への申し送りに回した
- やり直し: 0 回（3 本とも担当範囲は初回で green。親の統合でも修正は不要で、`pixi run fmt` が `result.mojo` / `test_binary.mojo` を整形しただけ）
- PLAN 訂正: 4 件
  - 決めた事項 3 のシグネチャを `[origin: ImmOrigin, //, T: Copyable]` + `Span[UInt8, origin]` に（根拠: 想定外 (1) のコンパイルエラー実測）
  - 追従先チェックリストの `^def decode_` 期待値 14 → **15**（根拠: 想定外 (3)。turn 4 実測は 7 = 6 本 + 自身）
  - T2 (e) ① に「負のゼロは `'-0'::float8` / `'-0'::float4` と書く」を追記（根拠: 想定外 (2) の実測）
  - T2 (d) の長さ不一致ケースは bool だけ 3 → **2**（1 byte 型なので「-1 byte」と「0 byte」が同一入力。根拠: A の報告）
- 既存テストの期待値を変えた箇所: **なし**（T2 (f) のとおり後方互換。`test_result` 15 / `test_params` 31 / `test_prepared` 14 / `test_transaction` 13 / `test_connection` 31 / `test_decode_text` 49 / `test_encode_binary` 14 / `test_errors` 7 / `test_ffi` 7 / `test_leak` 12 / `test_smoke` 4 / `test_loader_fail` 1 が無変更で PASS）
- 次への注意:
  - 確認済み: `pixi run test` 両サーバー 15 ファイル全 PASS（新規 2 本が 54317 / 54314 で各 1 回、計 4 回ログに出る）。`pixi run check` **6/6 PASS = 117 s**（`final_check: PASS`、6/6 段 `matched lines: 0`）。所要は T1 の 113 s からほぼ変わらず、PLAN の「3 分を超えたら書く」には達していない
  - 確認済み（所要・単位 ms。TestSuite の `Summary [ N ]` は ms）: `tests/test_binary.mojo` 14 件 = **60.7 ms**（54314）/ **66 ms** 程度（54317）、`tests/test_decode_binary.mojo` 44 件 = **0.025 ms**（サーバー不要なので実質ゼロ）。`test_leak` は 12 件 73.5 s / サーバーで T1 から変化なし
  - 確認済み: **`String(unsafe_from_utf8=span)` が正しい ctor 名**（UTF-8 検証なし）。turn 2 / turn 3 から持ち越していた未確認事項はこれで解消。検証ありの方は `String(from_utf8=span)`
  - 確認済み: 追従先チェックリストの T2 行 — `grep -rn 'Phase 3' src/pq --include='*.mojo'` = **`encode_binary.mojo:16` の 1 行だけ**、`grep -c 'result_format'` = connection **6** / prepared **4** / transaction **4**（各 ≥ 2）。中間値は `^def decode_` **7**、`elif T ==` が decode_binary **8** / decode_text **8**（最終目標は各 16）。`grep -rn -- '-> ref' src/pq/*.mojo` = **0**（P19。T7 で再確認する）
  - 確認済み: `tests/run_tests.sh:76` は `for f in tests/test_*.mojo` の glob なので、新しいテストファイルは runner への追従が不要（T6 / T7 でも同じ）
  - 未確認: T3 が `decode_text.mojo` に `OID_JSON` / `OID_JSONB` を足したら、`decode_binary.mojo:52-55` の private な `_OID_JSON` / `_OID_JSONB` を import に置き換える（そのためのコメントを 2 行入れてある）。OID の唯一の置き場は `decode_text.mojo` という決めた事項 11 を守るため
  - 未確認: `decode_binary.mojo` の `_be_bits` は `UInt64` を返すので **8 byte までしか読めない**。T3 の numeric（可変長）・uuid（16 byte）、T5 の interval（16 byte）は自前の読み出しが必要（date / time / timestamp / timestamptz は再利用可）。三つのエラービルダー（`_binary_oid_error` / `_binary_length_error` / `_binary_value_error`）と `_check_length` は再利用すること（テストが文面の部分文字列を見ている）
  - 未確認: `String` 分岐は「jsonb を先に early return → 残り 5 OID を `and` 連鎖で判定」の二段構造。T3 で文字列系 OID を足すときは**その連鎖を伸ばす**（`elif T == String` を増やすと新 OID が OID 不一致に落ちる）。`else: comptime assert False` は常に最後に置く
  - 未確認: 0 byte の jsonb のメッセージが `binary jsonb value has 0 bytes, expected 1` で、1 が下限なのに固定幅のような読みになる（kind と拒否は正しい）。T3 で jsonb を触るなら文面を見直す候補
  - 未確認（T6 / T7 の材料。C が契約外として報告）: `column_format(-1)` の負値、0 列結果（binary DDL / INSERT）の `column_format`、明示 `result_format=ResultFormat.TEXT`、複数行の binary 結果（行オフセットのずれを突く）、未対応 OID を `get_optional` で引いたとき。いずれも T2 の完了基準に無いので足していない
  - 未確認: 切断後の binary 実行（T2 (e) ⑦）は、C の実測では **PG14 / PG17 とも 2 回目も `CONNECTION`**（SQLSTATE 空）だった。テストは PLAN の文言どおり `CONNECTION` / `SERVER` のどちらでも通る形にしてある。既存 `tests/test_connection.mojo` は無条件 `CONNECTION` を期待しているので、verify が厳しくしたければ締められる
## turn 5 — impl — T3 `Decimal` / `UUID` / json・jsonb の OID + codec と `Param` ctor
- やったこと: `src/pq/types_numeric.mojo`（`Decimal`）と `src/pq/types_uuid.mojo`（`UUID`）を新設し、OID 4 個（114 / 1700 / 2950 / 3802）を `decode_text.mojo` に集約、
  `decode_numeric` / `decode_uuid` / `encode_numeric` / `encode_uuid` と `decode_text` / `decode_binary` の 2 型分岐、`Param` の `@implicit` 4 本（値 + `Optional`）を結線。
  **サブエージェント 2 本を並行**（A: `Decimal` + 単体テスト / B: `UUID` + 単体テスト。対象ファイルは重ならせず、codec・`params.mojo`・docstring 追従・統合検証は親）
- 想定外:
  (1) `@fieldwise_init` が `Decimal` に 4 引数の**公開**位置引数 ctor（`Decimal(_sign, _weight, _dscale, _digits)`）を生む。正規化を飛ばせるので `__eq__` の前提（正規化後の比較）を壊せる。
      Mojo に可視性制御は無く、明示 `__init__` に書き換えても公開面は同じなので**そのままにした**（`_from_parts` / `nan()` / `infinity()` / `negative_infinity()` が内部でこれを通す。パッケージ外から呼ぶ理由は無い）。verify が「契約に無い公開 ctor」として締めたければ候補
  (2) numeric の長さ誤りのメッセージは**値エラー側の文面**にせざるを得なかった（決めた事項 4 は長さ不一致の分類に置いていたが、T3 (f) が不正 5 ケース全部に `"cannot decode binary numeric"` を要求している）。PLAN を訂正
  (3) 追従先チェックリストの `grep -c '@implicit' src/pq/params.mojo` はモジュール docstring の「`@implicit` constructors」行も数える（実 ctor 数 + 1）。元の最終期待値 35 は実 ctor 数で、grep 値ではなかった。PLAN を訂正
  (4) RESEARCH §2.2.2 の表は 30 byte 行（`123456789012345678901234567890.123456789`）の digit 部を `...` で省略していたので、`encode(numeric_send(v), 'hex')` で 23 値の wire を PG17 から取り直して期待値にした。
      §3-2 の式から手計算した `000b000700000009 000c 0d80 1ed2 04d2 162e 2334 0d80 1ed2 04d2 162e 2328` と**実測が完全一致**したので、parse の式の写し取りはこれで裏が取れた
- やり直し: 0 回（親の統合・検証は初回で green。サブエージェント A は自分の担当範囲内で小数点の `write_to` 漏れを 1 回直して報告）
- PLAN 訂正: 4 件
  - 決めた事項 4 に「numeric だけは長さ誤りも `cannot decode binary numeric: ...` の文面」を追記（根拠: 想定外 (2)。T3 (f) の要求と可変長型の性質）
  - 追従先チェックリストの `@implicit` 最終期待値 35 → **36**（grep は docstring 行も数える。ctor だけなら `grep -c '^    @implicit'`。根拠: 想定外 (3) の実測）
  - 同チェックリスト T2 行の `grep -rn 'Phase 3'` 期待値 1 → **2**（`__init__.mojo` の Layout 行に Phase 3 の追加モジュールを書いた。既存の「Phase 1 adds ... Phase 2 adds ...」の続きで placeholder ではない）
  - 同チェックリスト `^def decode_` の turn 5 実測 **9**（6 本 + `decode_numeric` + `decode_uuid` + 自身）を追記
- 既存テストの期待値を変えた箇所: **なし**（既存 13 ファイルは無変更で PASS。追記したのは `test_decode_binary` +14 件 / `test_encode_binary` +4 件 / `test_params` +2 件で、既存ケースの期待値は触っていない）
- 次への注意:
  - 確認済み: `pixi run test` **両サーバー 17 ファイル全 PASS**（0 failed）。`pixi run check` **6/6 PASS = 112 s**（`final_check: PASS`、6/6 段 `matched lines: 0`）。T1 113 s / T2 117 s から変化なし（PLAN の「3 分を超えたら書く」には未達）
  - 確認済み（所要・単位 ms）: `test_types_numeric` 45 件 = **133〜143 ms**、`test_types_uuid` 14 件 = **15 ms**、`test_decode_binary` 58 件 = **52 ms**、`test_encode_binary` 18 件 = **33 ms**（いずれもサーバー不要）。`test_params` 33 件 = **127 s**（サーバー往復込み）
  - 確認済み（追従先チェックリストの中間値、素のシェルで再現可）: `^comptime OID_` = **15**、`^    @implicit` = **23**（grep `'@implicit'` は 24）、`^def encode_` = **8**、`^def decode_` = **9**、`elif T ==` は decode_text **10** / decode_binary **10**（最終目標は各 16）、`UInt32(1700)|UInt32(2950)|UInt32(114)|UInt32(3802)` の decode_text 以外での出現 = **0**、`Nineteen` = 0 / `Twenty-three` = 1、`exactly six` = 0、`anything else` = 1、`-> ref` = **0**（P19）
  - 確認済み: PG の wire を取る一番速い手は **`docker exec -i tests-pg17-1 psql -U pq -d pq_test`** + `encode(<type>_send(v), 'hex')`。T4 / T5 の date / timestamp / time / timetz / interval の期待値もこれで原本を作れる（`date_send` / `timestamp_send` / `timestamptz_send` / `time_send` / `timetz_send` / `interval_send`）。RESEARCH の表で `...` 省略されている行はこれで埋める
  - 未確認: `Decimal._from_parts` は weight が `Int16.MIN` で**かつ**先頭ゼログループがあるとき stripped weight が wrap する（A の報告）。サーバーは先頭ゼログループを送らないので到達しないが、`decode_numeric` のヘッダ検査に足すかは T6（サーバー格子）か verify の判断
  - 未確認: 0 byte の jsonb のメッセージ（`binary jsonb value has 0 bytes, expected 1`）は turn 4 からの持ち越しのまま。T3 は jsonb の OID を `decode_text` に移しただけで分岐の文面は触っていない（既存テストが文面の部分文字列を見ているので、直すなら T9 でテストと同時に）
  - 未確認: `types_numeric.mojo` / `types_uuid.mojo` の `_usage_error` / `_decode_error` は**モジュールごとに同名で重複定義**している（決めた事項 4 の「`decode_text` を import すると循環するため型モジュール側に private ビルダーを置く」どおり）。T4 / T5 の `types_datetime.mojo` も 3 本目の同じ対を持つことになる。共通化したいなら置き場は `errors.mojo`（verify / T9 の判断）
  - 未確認: `Decimal` / `UUID` を**サーバー往復**で見るのは T6（拡張型 8 種の格子）。T3 は単体 + `Param` の OID / 形式までで、`SELECT $1::numeric` の往復はまだ 1 件も通していない
## turn 6 — impl — T4 `Date` / `Timestamp` / `TimestampTz` + codec / `Param` + 単体テスト
- やったこと: `src/pq/types_datetime.mojo` を新設（Hinnant 暦算法の Mojo 床除算版 + `Date` / `Timestamp` / `TimestampTz`、共用ヘルパ `_format_date` / `_format_time_of_day` / `_parse_fraction` / `_parse_hms` は T5 が使う）、
  OID 3 個（1082 / 1114 / 1184）を `decode_text.mojo` に集約し、`decode_date` / `decode_timestamp` / `decode_timestamptz` と `encode_date` / `encode_timestamp` / `encode_timestamptz`、`decode_text` / `decode_binary` の 3 型分岐、`Param` の `@implicit` 6 本を結線。
  テストは `tests/test_types_datetime.mojo` 75 件（サーバー不要）+ `test_decode_binary` +10 件 / `test_encode_binary` +4 件 / `test_params` の OID・NULL 追記。
  **サブエージェント 2 本を並行**（A: `types_datetime.mojo` / B: `tests/test_types_datetime.mojo` を契約から独立に）。codec・`params.mojo`・docstring 追従・統合検証は親
- 想定外:
  (1) 期待値の転記ミスは**ゼロ**だった。親が PG17 の `date_send` / `timestamp_send` で 7 + 10 件を取り直し、B も独自の JDN 計算で 9 + 7 + 6 件を照合し、どちらも PLAN / RESEARCH と完全一致
  (2) A が overflow 対策の門を 2 つ足した（`from_ymd` 系の入口で `|y| > 6000000` を `USAGE`、`Timestamp` は micros を作る前に日数を `-2451545..106751982` で検査）。`_days_from_civil` の `era * 146097` と `days * 86400000000` が値域検査より先に overflow するため。**通る値の集合は契約どおり**（完了基準の 9 + 7 件と拒否 12 件が全部期待どおり）
  (3) A が `Date.parse("0000-01-01")` を拒否にした（PG の `date_in` と同じ。`_format_date` は天文年 0 を `0001-01-01 BC` と書くので往復の一貫性もこちら）。契約に明記が無かった判断なので verify の確認材料に残す
  (4) `_parse_hms` は契約どおり `HH` を 0..24 で通すので `"24:30:00"` も -1 にならない（`Timestamp` 側は 86400000000 以上を弾くので影響なし）。T5 の `Time` が 24 時台をどう扱うかは T5 の判断
- やり直し: 0 回（A / B とも担当範囲は初回で green。親の統合も修正なしで、`pixi run fmt` が 2 ファイルを整形しただけ）
- PLAN 訂正: なし（T4 の完了基準・期待値はすべて実物と一致した）
- 既存テストの期待値を変えた箇所: **なし**（既存 15 ファイルは無変更で PASS。追記したのは `test_decode_binary` +10 件 / `test_encode_binary` +4 件 / `test_params` の既存 2 関数への追加 assert のみで、既存ケースの期待値は触っていない）
- 次への注意:
  - 確認済み: `pixi run test` **両サーバー 18 ファイル全 PASS**（36/36 が `0 failed`。per-file 合計 215 s）。`pixi run check` **6/6 PASS = 118 s**（`final_check: PASS`、6/6 段 `matched lines: 0`）。T1 113 s / T2 117 s / T3 112 s から変化なし（「3 分を超えたら書く」には未達）
  - 確認済み（所要・単位 ms）: `test_types_datetime` 75 件 = **25〜37 ms**、`test_decode_binary` 68 件 = **66〜77 ms**、`test_encode_binary` 22 件 = **41 ms**（いずれもサーバー不要）。`test_params` 33 件 = **116〜124 s**（サーバー往復込み）。`test_leak` 12 件 = **66〜68 s / サーバー**（T3 の 73.5 s から微減）
  - 確認済み（追従先チェックリストの中間値、素のシェルで再現可）: `^comptime OID_` = **18**、`^    @implicit` = **29**（grep `'@implicit'` は 30）、`^def encode_` = **11**、`^def decode_` = **12**、`elif T ==` は decode_text **13** / decode_binary **13**（最終目標は各 16）、`Twenty-nine` = 1、`UInt32(1082)|UInt32(1114)|UInt32(1184)` の decode_text 以外での出現 = **0**、`-> ref` = **0**（P19）
  - 確認済み: PG17 から取り直した原本（`docker exec -i tests-pg17-1 psql -U pq -d pq_test -At -c "... encode(date_send(v), 'hex') ..."`）— date: `2000-01-01`=00000000 / `1970-01-01`=ffffd533 / `2024-02-29`=00002279 / `0001-01-01 BC`=fff4da8b / `4714-11-24 BC`=ffda97a7 / `5874897-12-31`=7fda970c / `10000-01-01`=002c95d4 / `0001-01-01`=fff4dbf9 / `infinity`=7fffffff / `-infinity`=80000000。timestamp 7 件も RESEARCH と一致。T5 の time / timetz / interval も同じ手で原本を作れる
  - 未確認（T5 への申し送り）: `types_datetime.mojo` は 1079 行 → fmt 後も 1 ファイル。T5 は**同じファイルに追記**し、`_format_time_of_day` / `_parse_hms` / `_parse_fraction` / `_pad2` / `_usage_error` / `_decode_error` を**再利用**する（同名の対を作らない）。`_infinite_error(pg_type, accessor)` も既にある
  - 未確認（B が契約外として報告。T6 / verify の材料）: `TimestampTz` の分解アクセサ 7 本と `from_utc` の拒否（`"invalid timestamptz"` の文面）はどのテストも通っていない（契約には在る）。`Timestamp` / `TimestampTz` の `is_infinite()` でのアクセサ raise も Date だけで確かめている。T6 (b) ③ の往復で `from_utc` は通るが、拒否側は空白のまま
  - 未確認: `Date` / `Timestamp` の**テキスト**経路は DateStyle `ISO, YMD` 前提（T1 の GUC 固定が効いている）。非 ISO で `TYPE_MISMATCH` になることの確認は T6 (b) ⑤ が担う。この前提は `result.mojo` の `Row.get` 表には書いていない（T9 の文書整備で 1 行足す候補）
  - 未確認: A の契約外提案 3 件 — `Date` / `Timestamp` の順序比較（`__lt__` 等。内部整数の比較でそのまま正しい）、`Date` ↔ `Timestamp` 変換、`TimestampTz.parse` のコロン無しオフセット `[+-]HHMM`。いずれも実装していない（現契約では `+HHMM` は拒否が正）
## turn 7 — impl — T5 `Time` / `TimeTz` / `Interval` + codec / `Param` + 単体テスト
- やったこと: `src/pq/types_datetime.mojo` に `Time` / `TimeTz` / `Interval` を追記（private ヘルパ `_write_fraction` / `_format_interval_time` / `_write_interval_part` を新設、T4 の `_format_time_of_day` / `_parse_hms` / `_parse_fraction` / `_pad2` / `_usage_error` / `_decode_error` は再利用）、
  OID 3 個（1083 / 1186 / 1266）を `decode_text.mojo` に集約し、`decode_time` / `decode_timetz` / `decode_interval` と `encode_time` / `encode_timetz` / `encode_interval`、`decode_text` / `decode_binary` の 3 型分岐、`Param` の `@implicit` 6 本を結線。
  テストは `tests/test_types_datetime.mojo` +57 件（75 → 132）/ `test_decode_binary` +9 件（68 → 77）/ `test_encode_binary` +4 件（22 → 26）/ `test_params` の既存 2 関数に 6 型分の assert 追記。
  **サブエージェント 2 本を並行**（A: `types_datetime.mojo` / B: `tests/test_types_datetime.mojo` を契約から独立に）。codec・`params.mojo`・docstring 追従・統合検証は親
- 想定外:
  (1) **PLAN の期待値に 1 件誤りがあった**（T5 (d) の time `24:00:00` の hex）。`0000001406f40000` は 86015737856 で 86400000000 ではない（正: `000000141dd76000` = `0x141DD76000`）。
      親が PG17 の `time_send` / `timetz_send` / `interval_send` で 33 値の原本を取り直して発見。PLAN を訂正。**他の 32 値（timetz 6 ゾーン・interval 18 件・time 4 件）は PLAN / RESEARCH と完全一致**
  (2) interval テキストの `+` 規則は「それまでに負が 1 つでもあったか」ではなく **「直前に出した成分の符号」**（PG `AddPostgresIntPart` が毎回 `is_before = (value < 0)` を上書きする）。
      `-1 years -2 mons +3 days` が成立するのはこのため。契約文に明記して A に渡したので実装は初回から正しかった
  (3) `Interval` は `Copyable` だが `ImplicitlyCopyable` ではないので、`List[Interval]` の要素を `var x = list[i]` で受けるとコンパイルエラー（`.copy()` が必要）。親のテストで 1 回踏んだ
  (4) A が `Interval.parse` に overflow の門を 4 つ足した（桁数 > 10、hour > 2562047788、時刻部の大きさが `Int64` 超、`months` / `days` が `Int32` 超）。
      いずれも入力検査なので契約外の"保険"ではないと判断してそのまま採用。`Interval(Int64.MIN, 0, 0)` は番兵でない有限値なので、時刻部の絶対値は `UInt64` で求めて wrap を避けている（`-2562047788:00:54.775808` と往復する）
- やり直し: 1 回（想定外 (3) の `.copy()`。A / B は担当範囲とも初回で green）
- PLAN 訂正: 1 件
  - T5 (d) の time `24:00:00` の hex `0000001406f40000` → **`000000141dd76000`**、86400000001 は `000000141dd76001`（根拠: 想定外 (1) の PG17 `time_send` 実測）
- 既存テストの期待値を変えた箇所: **なし**（既存 18 ファイルは無変更で PASS。追記したのは上記 4 ファイルで、`test_params` は既存 2 関数への assert 追加のみ。既存ケースの期待値は触っていない）
- 次への注意:
  - 確認済み: `pixi run test` **両サーバー 18 ファイル全 PASS**（36/36 が `0 failed`）。`pixi run check` **6/6 PASS = 125 s**（`final_check: PASS`、6/6 段 `matched lines: 0`）。T1 113 s / T2 117 s / T3 112 s / T4 118 s から微増だが「3 分を超えたら書く」には未達
  - 確認済み（所要・単位 ms）: `test_types_datetime` 132 件 = **40〜46 ms**、`test_decode_binary` 77 件 = **82〜85 ms**、`test_encode_binary` 26 件 = **51〜58 ms**（いずれもサーバー不要）。`test_params` 33 件 = **115 s**、`test_binary` 14 件 = **59 s**、`test_leak` 12 件 = **66.9 s / サーバー**（T4 と同じ）
  - 確認済み（追従先チェックリストの**最終件数**。全部目標値に一致、素のシェルで再現可）: `^comptime OID_` = **21**、`^    @implicit` = **35**（grep `'@implicit'` は 36）、`^def encode_` = **14**、`^def decode_` = **15**（14 本 + `decode_binary` 自身）、`elif T ==` は decode_text **16** / decode_binary **16**、`Thirty-five` = 1 / `Twenty-nine` = 0、`fourteen encoders` = 1、`-> ref` = **0**（P19）、`UInt32(1083)|UInt32(1186)|UInt32(1266)` の decode_text 以外での出現 = **0**
  - 確認済み: interval テキスト 18 件は B の転記だけでなく **PG17 の `::text` 出力そのもの**とも一致する（親が `docker exec -i tests-pg17-1 psql -At -c "... v::text, encode(interval_send(v),'hex') ..."` で 20 件の原本を取得。`-1 days +02:00:00` / `-1 years -2 mons -3 days -04:05:06.789` / `1 mon -1 days` / `-00:00:00.5` / `100:00:00` / `2 years 1 mon` / `-11 mons` / `-1 years +1 day` が一致）。原本 SQL は `.gsd-lite/logs/phase3-binary-all-types/scratch/turn-007-wire.sql`
  - 未確認（T6 への申し送り）: **`Time` / `TimeTz` / `Interval` のサーバー往復はまだ 1 件も通していない**。T5 は単体 + `Param` の OID / 形式までで、`SELECT $1::interval` の往復と text / binary の一致は T6 (b) が担う。特に PG14 の interval ±infinity（22008 / 22007）は未着手
  - 未確認（A が契約外として報告）: `Interval.parse("+02:00:00")`（時刻部だけで先頭 `+`）は**拒否**になっている。`EncodeInterval` は単独の時刻部に `+` を付けないので「出力文法の逆」としては正しいが、契約文の `[+-]?H+:MM:SS` の literal な読みより狭い。T6 / verify の判断材料
  - 未確認（A が契約外として報告）: `TimeTz.write_to` に生 ctor で範囲外の `offset_secs` を入れると時の桁が 3 桁以上で出る（`_pad2` は切り詰めない）。`decode_timetz` と `from_hms` が両方弾くので到達経路は無い
  - 未確認: `_write_fraction` は `_format_time_of_day` 内のインライン実装と約 10 行重複している（A が append-only 指示を守った結果）。共通化は T9 の文書・整理フェーズの候補
  - 未確認: `types_datetime.mojo` は **1892 行**になった（T4 末 1151 行）。T6 以降はこのファイルに足すものが無いので分割の必要は無い見込み
## turn 8 — impl — T6 サーバー格子（拡張型 8 種 + json / jsonb の text / binary 一致）
- やったこと: `tests/test_extended_numeric.mojo`（10 件 / 929 行。numeric / uuid / json / jsonb）と `tests/test_extended_datetime.mojo`（19 件 / 1016 行。date / timestamp / timestamptz / time / timetz / interval）を新設し、
  Phase 3 で足した 8 型を**実サーバー往復**で検査する格子を通した。text / binary の値一致、`String(T)` と text の `get[String]` の一致、`SELECT $1::<type>` のパラメータ往復（両結果形式）、PG17 分岐、非 ISO DateStyle / IntervalStyle、境界値。
  **サブエージェント 2 本を並行**（A: numeric 側 / B: datetime 側。対象ファイルは 1 本ずつで重ならせず、`fmt`・両サーバー検証・コミットは親）
- 想定外:
  (1) **`gen_random_uuid()` を 2 回呼ぶ完了基準は原理的に満たせない**（毎回別値）。`CREATE TEMP TABLE pq_t6_uuid AS SELECT gen_random_uuid() AS u` で 1 値を固定してから text / binary で 2 回読む形にした。PLAN を訂正
  (2) `1e130::numeric` のテキストは**指数表記にならない**（`1` + ゼロ 130 個 = 131 文字）。`Decimal` は指数リテラルを受けないので、パラメータ往復はサーバーが返した位置表記を `Decimal(text)` に食わせる形にした（RESEARCH §2.2.2 の記述どおりで、PLAN の誤りではない）
  (3) `'4714-11-24 00:00:00 BC'::timestamp` の値は RESEARCH に無かった（あるのは `4713-01-01 00:00:00 BC` = `fd0f7fbdaf17e000`）。PG17 の `timestamp_send` で実測して `fd0f7cc1411fa000` = **-211813488000000000**（= timestamp の下限）を期待値にした
  (4) `'36 hours'::interval` / `'1.5 days'::interval` はサーバーが正規化するのでテキストが入力リテラルと違う（`36:00:00` / `1 day 12:00:00`）。テストは text の `get[String]` と突き合わせる作りなのでそのまま通る
  (5) `TestSuite` に skip API が無いので、PG17 / PG14 分岐の 2 件は非該当バージョンでは早期 return して **PASS と表示される**（「走っていないのに緑」）。テスト名で `_on_pg17_and_later` / `_before_pg17` と区別できるようにしてある
- やり直し: 0 回（A / B とも担当範囲は初回で green。親の統合も修正なしで、`pixi run fmt` が 2 ファイルを整形しただけ）
- PLAN 訂正: 1 件
  - T6 (a) ⑥ の `gen_random_uuid()` を「TEMP TABLE で 1 値を固定してから両形式で読む」に（根拠: 想定外 (1)。2 クエリでは比較不能）
- 既存テストの期待値を変えた箇所: **なし**（既存 18 ファイルは無変更。新規 2 ファイルを足しただけで、`src/` は 1 行も触っていない）
- 次への注意:
  - 確認済み: `pixi run test` **両サーバー 20 ファイル全 PASS**（40/40 の summary が `0 failed`。ログ `.gsd-lite/logs/phase3-binary-all-types/scratch/turn-008-test.log`、再現は `grep 'tests run' <log> | grep -vc ' 0 failed'` が 0）。`pixi run check` **6/6 PASS = 118 s**（`final_check: PASS`、6/6 段 `matched lines: 0`）。T1 113 s / T2 117 s / T3 112 s / T4 118 s / T5 125 s と同水準
  - 確認済み（所要・単位 s / ms）: `test_extended_numeric` 10 件 = **1〜2 s**（単体 49 ms + 接続）、`test_extended_datetime` 19 件 = **1〜2 s**（単体 94 ms + 接続）、`test_leak` 12 件 = **61 s（PG17）/ 63 s（PG14）**
  - 確認済み: 期待メッセージはすべて 2 語以上の部分文字列（`"oid 1700"` / `"oid 3802"` / `"ResultFormat.TEXT"` / `"02.01.2024" as date` / `"P1D" as interval`）。PG14 の interval ±infinity は `SERVER` + sqlstate `22007`（SQL）/ `22008`（パラメータ）を**実測で確認**
  - 確認済み: binary が GUC 非依存であること（`SET DateStyle TO 'German'` 下で text の `get[Date]` が `TYPE_MISMATCH`、同じ列の binary が `Date(8767)`）。GUC を触る 2 テストは専用接続で行い、最後に GUC を戻して同じ SQL が通ることまで見ている
  - 未確認（B が契約外として報告）: timetz の最大西 / 最大東（`-15:59` → 57540、`+15:59:59` → -57599）はサーバー往復に入れていない（PLAN ① のリストに無い）。`Int32` の符号反転を一番きわどく突くケースなので verify が足したければ候補
  - 未確認（B が契約外として報告）: `test_timestamp_params_round_trip` の**非 UTC 分岐は CI で一度も走らない**（コンテナが `Etc/UTC` 固定で `_is_utc()` が常に真）。`options='-c TimeZone=Asia/Tokyo'` 付きの接続で 1 ケース回せば分岐自体を検証できる
  - 未確認（A が契約外として報告）: NULL の binary（`SELECT NULL::numeric / ::uuid / ::jsonb` の `NULL_VALUE` / `get_optional` / `is_null`）と、`PreparedStatement` / `Transaction` 経由の binary を**拡張型で**は見ていない（既存 8 型は `test_binary.mojo` が押さえている）
  - 未確認: T7（zero-copy）の `get_text` / `get_bytes` はまだ無い。T7 (c) の陽性対照は `.gsd-lite/logs/phase3-binary-all-types/scratch/turn-NNN-zerocopy-neg.mojo` に置き、`grep -rn -- '-> ref' src/pq/*.mojo` = 0 を PROGRESS に書くところまでが T7 の仕事
## turn 9 — impl — T7 zero-copy `Row.get_text` / `get_bytes` + `tests/test_zero_copy.mojo` + 陽性対照
- やったこと: `src/pq/result.mojo` に `Row.get_text(col) -> StringSlice[Self.origin]` と `Row.get_bytes(col) -> Span[UInt8, Self.origin]` を追加（T2 の `_raw` をそのまま使い、`get_text` は binary のとき 6 OID 検査 + jsonb version byte 剥がしを `decode_binary` の `_binary_oid_error` / `_binary_length_error` / `_binary_value_error` を import して共用。メッセージが `get[String]` と同一になる）、
  `src/pq/__init__.mojo` に `## Zero-copy access` 節、`tests/test_zero_copy.mojo` 11 件（サーバー）を新設。陽性対照 3 本を scratch で実測。サブエージェントは使わず（PLAN の推奨本数 0）
- 想定外:
  (1) `_ = result^` の生存延長は**実測で確認できた**（`.gsd-lite/logs/phase3-binary-all-types/scratch/turn-009-probe-keepalive.mojo` → `slice after keep-alive: héllo 6 6`）。`_ = row^; _ = result^` を slice 取得の後に置き、assert をその後に書く順序で問題なく動く
  (2) テスト内の `List[Int](-1, a, b)` / `List[UInt8](0, 255, 0)` は Mojo 1.1.0 ではコンパイルできない（可変長 ctor が `__list_literal__` を要求する）。角括弧リテラル（`var expected: List[UInt8] = [0, 255, 0]`、`for col in [-1, ncols, ncols + 7]`）に直した。`List` 同士の `assert_equal` も避け、`_assert_same_bytes(Span, Span)` ヘルパで比較（`test_decode_binary.mojo:124` の `_assert_bytes` と同じ流儀）
  (3) `String("...").as_bytes()` を関数呼び出しの実引数に直接書くと一時オブジェクト由来の span になるので、期待値は `var hex_text = String(...)` に束ねてから渡した（コンパイルは通るが寿命が読みにくいため）
- やり直し: 1 回（想定外 (2) のリスト構築。`src/` 側は初回で precompile まで警告ゼロ）
- PLAN 訂正: なし
- 既存テストの期待値を変えた箇所: **なし**（既存 20 ファイルは無変更で PASS。新規 1 ファイルと `src/pq/result.mojo` / `__init__.mojo` への追加のみで、既存の関数・docstring の主張は書き換えていない）
- 次への注意:
  - 確認済み: `pixi run test` **両サーバー 21 ファイル全 PASS**（42/42 の summary が `0 failed`。ログ `.gsd-lite/logs/phase3-binary-all-types/scratch/turn-009-test.log`、再現は `grep 'tests run' <log> | grep -vc ' 0 failed'` が 0）。`pixi run check` **6/6 PASS = 126 s**（`final_check: PASS`、6/6 段 `matched lines: 0`。ログ `turn-009-check.log`）。T1 113 / T2 117 / T3 112 / T4 118 / T5 125 / T6 118 s と同水準
  - 確認済み（所要）: `test_zero_copy` 11 件 = **42〜44 s**（1 テスト 1 接続で 3.4〜7.0 s / 件。接続あたりのコストが支配的で、`test_binary` 14 件 = 59 s と同じ比率）。PG14 側も同じ
  - 確認済み（T7 (c) 陽性対照。3 本すべて `error: use of uninitialized value 'result'` で停止。`pixi run mojo run -I src <file>` で再現可）:
    - `turn-009-zerocopy-neg.mojo`（`get_text` の slice を `var moved = result^` の後で使用）→ `turn-009-zerocopy-neg.mojo:21:14: error: use of uninitialized value 'result'` + `note: 'result' declared here`
    - `turn-009-zerocopy-neg2.mojo`（`get_bytes` の span 版）→ `:21:42: error: use of uninitialized value 'result'`
    - `turn-009-zerocopy-neg3.mojo`（既存 `Row` の `get[Int32]` 版）→ `:21:52: error: use of uninitialized value 'result'`
    - いずれも最後に `mojo: error: failed to run the pass manager`。**コンパイルエラーなのでテストスイートには置けない**ため、生存規則の静的な半分は scratch の 3 本が唯一の証跡（verify はここを見る）
  - 確認済み（P19）: `grep -rn -- '-> ref' src/pq/*.mojo` = **0 件**
  - 未確認: T7 (b) の「NUL を含むなら長さどおり」は**サーバーで作れない**（`chr(0)` が 54000）ため `test_zero_copy` には入れていない。`_raw` が `PQgetlength` を使う（NUL 走査しない）ことは `test_decode_binary` の NUL 入り text ケースが単体で担保している
  - 未確認: `get_bytes` は OID も形式も問わない仕様（決めた事項 9）なので、text 形式の `bytea` は `\x00ff00` の 8 byte を返す。これは `get[List[UInt8]]` の hex デコードと**意図的に違う**。T9 の `__init__.mojo` 型マッピング表に 1 行欲しい（`## Zero-copy access` 節には書いた）
  - 未確認: T8 の `test_zero_copy_does_not_leak` は `get_text(0).byte_length()` を足すだけのループで、`src/pq` 側に新しい解放経路は無い（`_raw` は読み出しのみ）。陽性対照（`PQclear` を `pass` に）は T8 (b) の手順どおり
## turn 10 — impl — T8 leak ループ 2 本 + 陽性対照 + `examples/binary.mojo` / `bench_formats.mojo`
- やったこと: `tests/test_leak.mojo` に `test_binary_execute_does_not_leak`（`PHASE3_SQL` を binary で取り 10 列全部を `get[T]`。`[Decimal("1.50"), Date(8825)]` を `WHERE $1 = 1.5 AND $2 = '2024-02-29'` に束ねて binary encode 経路も通す）と
  `test_zero_copy_does_not_leak`（同じ文を text で `get_text(0).byte_length()` だけ）を追加（12 → 14 件）。`examples/binary.mojo`（17 型を 1 行で binary 取得 + `column_format(0)` 検査）と `examples/bench_formats.mojo`（100,000 行 × 5 列、exec / decode 分離計時、合否なし）を新設し、
  `pixi.toml` に `example-binary` / `bench`、`final_check.sh` 4/6 段に `examples/binary.mojo` を結線。サブエージェントは使わず（PLAN の推奨本数 1 = 並列サブ作業が 1 つなので自分で順に実装）
- 想定外:
  (1) **なし**（例・ベンチ・leak ループとも初回でコンパイルと実行が通った）。`fmt` が `test_leak.mojo` を 1 回整形しただけ
- やり直し: 0 回
- PLAN 訂正: なし
- 既存テストの期待値を変えた箇所: **なし**（`test_leak.mojo` はモジュール docstring の件数「Twelve tests」→「Fourteen tests」と所要見積もりの行を実測に更新し、テストを 2 本足しただけ。既存 12 件の判定・`TOLERANCE_PAGES` 256・サンプリング定数はいずれも無変更。`final_check.sh` は 4/6 段に 1 行追加 + コメントの「Both examples」→「All examples」のみで、判定条件は変えていない）
- 次への注意:
  - 確認済み: `pixi run test` **両サーバー 21 ファイル全 PASS**（42/42 の summary が `0 failed`。ログ `.gsd-lite/logs/phase3-binary-all-types/scratch/turn-010-test.log`、再現は `grep 'tests run' <log> | grep -vc ' 0 failed'` が 0）。`pixi run check` **6/6 PASS = 130 s**（`final_check: PASS`、6/6 段 `matched lines: 0`。ログ `turn-010-check.log`。4/6 段に `examples/binary.mojo` の 17 行、5/6 段の 54314 側は `skipped (PQ_TEST_LEAK_SERVERS=1)`）。T1 113 / T2 117 / T3 112 / T4 118 / T5 125 / T6 118 / T7 126 s と同水準で、**3 分には達していない**
  - 確認済み（所要）: `test_leak` 14 件 = **65 s（PG17）/ 66 s（PG14）**（12 件のときは 61〜67 s）。新しい 2 本の内訳は `binary-execute` **2.97 s** / `zero-copy` **2.74 s**（10,000 回ずつ、1 接続使い回し）。docstring の見積もりを「2 本で ~6 s、合計 ~65 s」に実測で書き換えた
  - 確認済み（T8 (a) の RSS。両サーバーとも 9 サンプル全部が同値 = 完全にフラット）: PG17 `binary-execute [4722 × 9]` / `zero-copy [4722 × 9]`、PG14 は `[4670 × 9]`
  - 確認済み（T8 (b) 陽性対照。`.gsd-lite/logs/phase3-binary-all-types/scratch/turn-010-leaksrc/pq/result.mojo:176-177` の `PQclear` を `pass` にしたコピーを `-I .../turn-010-leaksrc` でビルド → `turn-010-test_leak_noclear`。**新しい 2 本とも FAIL**）:
    - `FAIL test_binary_execute_does_not_leak` — `binary-execute RSS pages: [642306, 659126, 675947, 692767, 709587] — grew 67281 pages past the first sample, over the 65536 allowed; aborting the loop (leaking)`
    - `FAIL test_zero_copy_does_not_leak` — `zero-copy RSS pages: [743228, 760048, 776869, 793689, 810509] — grew 67281 pages past the first sample, over the 65536 allowed; aborting the loop (leaking)`
    - 同じ実行で既存の 5 本（connect / execute(params) / prepared / transaction×2）も FAIL、`is_leaking` 単体 4 件と `PGresult` を持たない 3 本（failed-open / escape_literal / failed-execute）は PASS = 計 7 passed / 7 failed。**サンプル 1 区間あたり約 16,800 ページ（≒ 65 MiB = `PAYLOAD_BYTES` × 1,000 回）** の増加で、ループは `ABORT_PAGES` 超過により途中で打ち切られている
  - 確認済み（T8 (d) ベンチ。`pixi run bench` を PG17 で 1 回、ウォームアップ 1 + 計測 3 回。単位 ms）:
    - `text   : exec 42 ms, decode 33 ms, total 76 ms` / `binary : exec 38 ms, decode 8 ms, total 47 ms`
    - `text   : exec 42 ms, decode 35 ms, total 77 ms` / `binary : exec 38 ms, decode 9 ms, total 47 ms`
    - `text   : exec 43 ms, decode 34 ms, total 77 ms` / `binary : exec 39 ms, decode 8 ms, total 47 ms`
    - 読み: **decode が 4 倍速い**（33〜35 → 8〜9 ms）のが binary の効き所で、exec はほぼ同じ（38〜43 ms）。合計で 1.6 倍。turn 1 の生 libpq プローブ（`turn-001-probe-bench-pg17.log`）と同傾向
  - 確認済み（追従先チェックリストのうち T8 の行）: `grep -c '^def test_' tests/test_leak.mojo` = **14**、`grep -c 'Twelve' tests/test_leak.mojo` = **0**、`grep -rn 'examples/' pixi.toml tests/final_check.sh` で `examples/binary.mojo` が**両方**に・`bench_formats` が **pixi.toml にだけ**（P29）
  - 確認済み: `pixi run example-binary` / `pixi run bench` はどちらも単体で動く（T9 (d) の前倒し確認）
  - 未確認（T9 への申し送り）: T9 (a) の `__init__.mojo:13-34` 型マッピング表はまだ Phase 1 の 8 型のまま。turn 9 で挙げた「`get_bytes` は text 形式の bytea で `\x00ff00` の 8 byte を返す（`get[List[UInt8]]` の hex デコードとは意図的に違う）」の 1 行もこの表に欲しい
  - 未確認（T9 への申し送り）: T9 (b) の追従先チェックリスト**全行**の再実行はまだ。turn 5（`@implicit` の grep が実 ctor 数 + 1）・turn 4（`decode_` が `decode_binary` 自身を数える）・turn 3（`is Phase 3` は行送りで 0 件）の 3 件は**期待値そのものを PLAN で訂正済み**なので、訂正後の値で照合すること
  - 未確認: `examples/bench_formats.mojo` の出力は `print` の区切り空白のため `text   : exec ...`（PLAN の `text  : exec ...` より空白 1 個多い）。合否判定が無いので直していない
## turn 11 — impl — T9 文書の最終整備 + 受け入れ基準の総点検 + 最終判定
- やったこと: `src/pq/__init__.mojo` の型マッピング表に **binary form 列**を足して 19 行に拡張（json / jsonb を別行に分け、`anything else` を「text では `String`、binary では `TYPE_MISMATCH` + `ResultFormat.TEXT` の案内」に）、Layout 行に Phase 3 の追加モジュール名 4 つを明記、表の下に `Row.get_bytes` が OID を見ない例外であることを 1 文（turn 9 / 10 の申し送り）。
  追従先チェックリスト全行を**実行可能なスクリプト**に落として 32 件すべて green（T9 (b)）、REQ §5.1 / §5.2 / §5.4 の全項目にテスト名を対応づけ（T9 (c)）、`check` / `test` / `package` / `example-binary` / `bench` を実測（T9 (d)）。サブエージェントは使わず（PLAN の推奨本数 0）
- 想定外:
  (1) **REQ §5.2 の「範囲外 weight」だけテストが無かった**（T9 (c) の「対応先の無い項目はこのタスクで足す」に該当）。`types_numeric.mojo:209` の `weight > 32767 or weight < -32768` は**整数部 131,073 桁**でしか踏めず、既存の拒否テストは dscale 側（16,384 桁の小数）だけだった。`tests/test_types_numeric.mojo` に `test_rejects_weight_over_limit` を 1 件追加（ctor `USAGE` / `parse` `TYPE_MISMATCH` の両方。1.336 s。文字列構築が所要の大半）
  (2) `bench_formats` の追従先チェックリスト行（「`bench_formats` は pixi.toml にだけ」）が**素の grep では FAIL する**。`final_check.sh:118` に「`examples/bench_formats.mojo` is deliberately absent: ...」という**意図を述べたコメントが 1 行ある**ためで、実行行（`run_logged`）は無く P29 は満たしている。コメントは残す価値があるので、検査側を `grep -c '^[^#]*bench_formats'` = 0 + `grep -c '^#.*bench_formats'` = 1 の 2 行に分けた。PLAN を訂正
  (3) 型マッピング表は Phase 1 の 8 型のままだと思っていたが、T2〜T5 の各ターンが**行自体は 17 型まで足していた**（足りなかったのは binary 列と json / jsonb の分離、`get_bytes` の例外、Layout 行のモジュール名）。turn 10 の「まだ Phase 1 の 8 型のまま」という申し送りは実物と違っていた
- やり直し: 0 回（`fmt` は 44 ファイル無変更、`package` は初回で警告ゼロ）
- PLAN 訂正: 1 件
  - 追従先チェックリスト「`examples/` を足す（T8）」行の確かめ方を、`grep -rn 'examples/' pixi.toml tests/final_check.sh` から **`bench_formats` は実行行が無いこと（`^[^#]*bench_formats` = 0）+ 不在を述べたコメントが 1 行あること（`^#.*bench_formats` = 1）** に（根拠: 想定外 (2)。素の grep はコメント行を拾って FAIL する）
- 既存テストの期待値を変えた箇所: **なし**（`tests/test_types_numeric.mojo` はテストを 1 件足しただけで既存 45 件は無変更。`src/pq/__init__.mojo` はモジュール docstring のみで、コードは 1 行も触っていない）
- 追従先チェックリスト ✓（T9 (b)。**再現は `bash .gsd-lite/logs/phase3-binary-all-types/scratch/turn-011-checklist.sh`**、ログ `turn-011-checklist.log`。32 件すべて OK = 「不一致: 0 件」で exit 0）:
  | # | 行 | 期待 = 実測 |
  |---|---|---|
  | 1 | `Row.get[T]` の対応型 | `grep -c 'elif T ==' src/pq/decode_text.mojo` = **16**、`decode_binary.mojo` = **16**、`__init__.mojo` の拡張型 8 行 = **8**、`grep -c 'anything else' src/pq/__init__.mojo` = **1** |
  | 2 | OID 定数 | `grep -c '^comptime OID_' src/pq/decode_text.mojo` = **21**、`UInt32(1700)\|UInt32(1082)\|UInt32(2950)` の decode_text 以外の重複 = **0** |
  | 3 | `Param` の `@implicit` | `grep -c '@implicit' src/pq/params.mojo` = **36**（turn 5 訂正どおり実 ctor 数 + 1）、`grep -c '^    @implicit'` = **35**、`Nineteen` = **0**、`Thirty-five` = **1** |
  | 4 | encoder | `grep -c '^def encode_' src/pq/encode_binary.mojo` = **14**、`exactly six` = **0** |
  | 5 | decoder | `grep -c '^def decode_' src/pq/decode_binary.mojo` = **15**（14 本 + `decode_binary` 自身。turn 4 訂正どおり） |
  | 6 | `result_format` | `grep -rc 'Phase 3' src/pq --include='*.mojo'` の合計 = **2**（turn 5 訂正どおり `encode_binary.mojo` の名前の対 + `__init__.mojo` の Layout 行。placeholder は残っていない）、`result_format` が connection / prepared / transaction の各 ≥ 2 = **yes / yes / yes** |
  | 7 | 公開 struct | 再エクスポート 9 型 = **9**、docstring 診断（`_ffi` と dunder を除く）の `doc string` 行 = **0** |
  | 8 | `examples/` | `examples/binary.mojo` が pixi.toml = **1** / final_check.sh = **1**、`bench_formats` が pixi.toml = **1** / final_check.sh の**実行行** = **0** / 同コメント = **1**（PLAN 訂正後の形） |
  | 9 | テストファイル | `pixi run test` のログに新ファイル名が 2 回（**21 ファイル × 2 サーバー = 42 の summary**。下の「確認済み」参照） |
  | 10 | リークループ | `grep -c '^def test_' tests/test_leak.mojo` = **14**、`Twelve` = **0** |
  | 11 | `test_connection` | `grep -c '^def test_' tests/test_connection.mojo` = **31** |
  | 12 | libpq の経路 | `grep -rc 'PQexec(' src/pq/*.mojo` の合計 = **4**（connection ×2 / transaction / prepared）、`PQfreemem(` = **2** |
  | 13 | 生存期間の docstring | `grep -rn 'compile error' src/pq/*.mojo` = **8 行**。うち `connection.mojo:6` は `var b = a`（別物・残す）で、残り 7 行（`result.mojo:18` / `:449` / `:708`、`prepared.mojo:12`、`transaction.mojo:14`、`connection.mojo:491`、`__init__.mojo:106`）はすべて**消費する移動の後の使用**の文脈。T7 (c) の陽性対照 3 本（turn 9）がこの文言を実測で裏づけている |
  | 14 | `-> ref` | `grep -rc -- '-> ref' src/pq/*.mojo` の合計 = **0**（P19） |
- 受け入れ基準 → テスト対応（T9 (c)。verify はこの格子を使う。`ファイル:関数` 形式）:
  - §5.1「§6 の全型（+ time / timetz / interval）の text / binary 一致」: `test_binary.mojo:test_binary_scalars_match_text`（既存 8 型 + varchar / bpchar / name / 空 bytea）、`test_extended_numeric.mojo:test_numeric_binary_matches_text` / `:test_uuid_binary_matches_text` / `:test_json_and_jsonb_binary_match_text`、`test_extended_datetime.mojo:test_date_values_match_in_both_formats` / `:test_timestamp_values_match_in_both_formats` / `:test_timestamptz_same_instant_from_two_offsets` / `:test_time_values_match_in_both_formats` / `:test_timetz_zone_sign_follows_postgres` / `:test_interval_p8_values_match_in_both_formats` / `:test_interval_literals_match_in_both_formats`
  - §5.1 境界値「整数の最小 / 最大 / 0 / 負」: `test_binary.mojo:test_binary_integer_boundaries_match_text` + 単体 `test_decode_binary.mojo:test_int16_min`〜`:test_int_max`（8 件）
  - §5.1 境界値「float の NaN / ±Infinity / -0.0」: `test_binary.mojo:test_binary_float_special_values_match_text` + `test_decode_binary.mojo:test_float32_nan` / `:test_float32_positive_infinity` / `:test_float32_negative_infinity` / `:test_float32_negative_zero` / `:test_float64_nan` / `:test_float64_negative_zero`
  - §5.1 境界値「`infinity` / `-infinity` の日時」: `test_extended_datetime.mojo:test_infinite_dates_match_in_both_formats` / `:test_infinite_timestamps_match_in_both_formats` / `:test_infinite_timestamptz_match_in_both_formats` / `:test_interval_infinity_on_pg17_and_later` + 単体 `test_decode_binary.mojo:test_date_sentinels_decode_as_infinite` / `:test_timestamp_sentinels_decode_as_infinite` / `:test_interval_sentinels_decode_as_infinite`
  - §5.1 境界値「numeric の大きな桁 / 小数 / 負 / 0 / NaN」: `test_extended_numeric.mojo:test_numeric_binary_matches_text`（`1e130` 含む 23 値）/ `:test_numeric_special_values_in_both_formats` + 単体 `test_types_numeric.mojo`（46 件）/ `test_decode_binary.mojo:test_numeric_table_decodes_to_printed_text`（表 20 行）
  - §5.1 境界値「uuid の全ゼロ / 全 F」: `test_extended_numeric.mojo:test_uuid_binary_matches_text` + `test_types_uuid.mojo:test_all_zero_round_trip` / `:test_all_f_round_trip`
  - §5.1 境界値「空文字列」: `test_binary.mojo:test_binary_scalars_match_text`（列 8 で `""` かつ `is_null` が偽）+ `test_decode_binary.mojo:test_text_empty`
  - §5.1 境界値「NUL を含む bytea」: `test_binary.mojo:test_binary_scalars_match_text`（列 12 = `[0, 255, 0]` を両形式で）+ `test_decode_binary.mojo:test_bytea_three_bytes` / `:test_text_keeps_embedded_nul`
  - §5.1 境界値「jsonb のネスト」: `test_extended_numeric.mojo:test_json_and_jsonb_binary_match_text`（`{"a":{"b":[1,{"c":null}]}}` 含む）
  - §5.1「未対応 OID をバイナリで要求 → `TypeMismatch`、トレースバックを出さない」: `test_binary.mojo:test_binary_unsupported_oids_are_type_mismatch`（7 列 × 3 型 = 21 セル）+ 対照 `:test_text_reads_every_unsupported_oid_as_string`
  - §5.1「バイナリ列の `get[String]`（非文字列 OID）/ `get[List[UInt8]]`（非 bytea）」: `test_decode_binary.mojo:test_string_rejects_int4_column` / `:test_string_rejects_point_column` / `:test_string_rejects_int4_array_column` / `:test_bytea_rejects_text_column` / `:test_bytea_rejects_point_column` + サーバー側 `test_extended_numeric.mojo:test_binary_refuses_mismatched_numeric_and_jsonb`
  - §5.1「`column_format(i)` が BINARY / `execute(sql)` は TEXT」: `test_binary.mojo:test_column_format_is_binary_for_every_column` / `:test_column_format_defaults_to_text` / `:test_result_format_constants_and_equality`
  - §5.1「拡張型 8 種を `$1` で送り同じ値が返る（両形式）」: `test_extended_numeric.mojo:test_numeric_param_roundtrip_in_both_formats` / `:test_uuid_param_roundtrip_in_both_formats` / `:test_json_and_jsonb_param_roundtrip_in_both_formats`、`test_extended_datetime.mojo:test_date_and_time_params_round_trip` / `:test_timestamp_params_round_trip` / `:test_interval_param_round_trips` / `:test_infinite_params_round_trip`
  - §5.1「`SHOW DateStyle` が `ISO, YMD`」: `test_connection.mojo:test_open_fixes_datestyle`（+ `:test_open_fixes_intervalstyle` / `:test_client_encoding_is_utf8`）
  - §5.1「`bench_formats.mojo` が実行でき所要を表示」: テストではなく `pixi run bench`（下の実測。`final_check.sh` には入れない = P29）
  - §5.1「zero-copy の値一致 + 消費する移動の後はコンパイルエラー」: `test_zero_copy.mojo` 11 件（値一致は `:test_get_text_matches_get_string_in_text_format` / `:..._in_binary_format` / `:test_get_bytes_matches_get_list_in_binary_format`、生存延長の正例は `:test_slice_survives_a_keep_alive_marker`）+ **コンパイルエラー側は turn 9 の scratch 3 本**（`turn-009-zerocopy-neg{,2,3}.mojo`。テストスイートに置けないため唯一の証跡）
  - §5.2「長さ不足のバイナリ列」: `test_decode_binary.mojo:test_bool_rejects_wrong_length` / `:test_int16_...` / `:test_int32_...` / `:test_int64_...` / `:test_float32_...` / `:test_float64_rejects_wrong_length`、`:test_date_rejects_wrong_length` / `:test_timestamp_rejects_wrong_length` / `:test_timestamptz_rejects_wrong_length_and_oid` / `:test_time_rejects_wrong_length_and_oid` / `:test_timetz_rejects_wrong_length_and_oid` / `:test_interval_rejects_wrong_length_and_oid`
  - §5.2「不正な uuid 長」: `test_decode_binary.mojo:test_uuid_rejects_wrong_length`（15 / 17 byte）
  - §5.2「numeric の不正 ndigits」: `test_decode_binary.mojo:test_numeric_rejects_length_disagreeing_with_ndigits` / `:test_numeric_rejects_short_header` / `:test_numeric_rejects_invalid_sign` / `:test_numeric_rejects_digit_out_of_range` / `:test_numeric_rejects_dscale_out_of_range`
  - §5.2「範囲外 weight」: **`test_types_numeric.mojo:test_rejects_weight_over_limit`（このターンで追加）**。decode 側は weight が Int16 の生フィールドなので範囲外が作れず（決めた事項 3 で範囲検査なしと決定）、正の対照が `test_decode_binary.mojo:test_numeric_large_weight_stays_in_position_notation` / `:test_numeric_minimum_weight_decodes`（`0x8000` でも raise しない）
  - §5.2「jsonb の未知バージョンバイト」: `test_decode_binary.mojo:test_jsonb_rejects_version_two` / `:test_jsonb_rejects_empty`
  - §5.2「テキスト形式の非 ISO 日時文字列」: `test_extended_datetime.mojo:test_binary_date_is_independent_of_datestyle`（`DateStyle=German` 下で text が `TYPE_MISMATCH`・binary が成功）/ `:test_binary_interval_is_independent_of_intervalstyle`（`iso_8601`）+ 単体 `test_types_datetime.mojo` の `parse` 拒否群
  - §5.2「NULL」: `test_binary.mojo:test_binary_null_column`（`NULL_VALUE` / `get_optional` → None / `is_null`）、`test_zero_copy.mojo:test_null_cell_raises_null_value`
  - §5.2「空結果」: `test_binary.mojo:test_binary_zero_row_result`（+ `:test_binary_format_is_accepted_by_ddl_and_insert` が DDL / INSERT の `command_tag`）
  - §5.2「未接続・切断後」: `test_binary.mojo:test_terminated_backend_then_binary_connection_error`
  - §5.2「`PQclear` / `PQfinish` / `PQfreemem` が正常系・異常系で呼ばれ二重解放しない」: `test_leak.mojo` 14 件（陽性対照は turn 10 の `PQclear` 除去コピーで新 2 本とも FAIL）+ checklist #12（`PQexec(` 4 行 / `PQfreemem(` 2 行から増えていない）
  - §5.2「解放済みポインタへのアクセスが型・所有権の上で起こらない」: turn 9 の scratch 3 本（コンパイルエラー）+ checklist #14（`-> ref` = 0）
  - §5.2「10,000 回のバイナリ execute でメモリが単調増加しない」: `test_leak.mojo:test_binary_execute_does_not_leak` / `:test_zero_copy_does_not_leak`（turn 10 実測で RSS 9 サンプル全部同値）
  - §5.4「公開 struct / メソッドに docstring」: `final_check.sh` 3/6 段 = checklist #7（`doc string` 行 0）
  - §5.4「`pixi run fmt` で差分なし」: `final_check.sh` 1/6 段（下の実測で PASS。`fmt` 単体でも 44 ファイル無変更）
  - §5.4「`examples/binary.mojo` が単体で実行できる」: `pixi run example-binary`（下の実測）+ `final_check.sh` 4/6 段
  - §5.4「`pixi run package` が通る」: `final_check.sh` 2/6 段 + 単体実行（下の実測）
  - §5.4「`pixi run check` が 6/6 PASS」: 下の実測
- 次への注意:
  - 確認済み: `pixi run test` **両サーバー 21 ファイル全 PASS**（42/42 の summary が `0 failed`。ログ `.gsd-lite/logs/phase3-binary-all-types/scratch/turn-011-test.log`、再現は `grep 'tests run' <log> | grep -vc ' 0 failed'` が 0）
  - 確認済み: `pixi run check` **6/6 PASS = 134 s**（`final_check: PASS`、6/6 段 `matched lines: 0`。ログ `turn-011-check.log`。段別の時刻は 1/6 fmt 1 s・2/6 precompile 1 s・3/6 docstring 1 s・4/6 examples 8 s・5/6 tests 123 s・6/6 grep 0 s）。T1 113 / T2 117 / T3 112 / T4 118 / T5 125 / T6 118 / T7 126 / T8 130 s からの増分は新テスト 1 件（+1.3 s）相当で、**3 分には達していない**
  - 確認済み（T9 (d) の単体実行）: `pixi run package` **警告ゼロ**（出力はタスク行のみ）、`pixi run example-binary` が 17 型 + `column_format(0) = Binary` の 18 行を出して exit 0、`pixi run bench` が 6 行を出して exit 0
  - 確認済み（T9 (d) ベンチ再測。PG17、ウォームアップ 1 + 計測 3 回。単位 ms）: `text : exec 41 / 45 / 43、decode 33 / 34 / 33、total 75 / 80 / 76` / `binary : exec 39 / 40 / 39、decode 8 / 8 / 8、total 47 / 48 / 47`。turn 10 の実測（text total 76〜77 / binary 47）と**ばらつきの範囲で一致**し、decode が約 4 倍速い点も同じ
  - 確認済み: 追従先チェックリスト 32 件すべて green（上の表。スクリプトは exit 0 = 不一致 0 件）。turn 3 / 4 / 5 で PLAN を訂正した 3 件（`is Phase 3` の行送り / `decode_` が自身を数える / `@implicit` が実 ctor 数 + 1）は**訂正後の期待値で照合して一致**
  - 未確認（verify への申し送り。いずれも「テストが無い」のではなく「この格子に載っていない」もの）: turn 8 で挙げた 3 件がそのまま残っている — timetz の最大西 / 最大東（`-15:59` / `+15:59:59`）のサーバー往復、`test_timestamp_params_round_trip` の非 UTC 分岐（コンテナが `Etc/UTC` 固定で一度も走らない）、拡張型の NULL binary と `PreparedStatement` / `Transaction` 経由の binary。**REQ §5.1 / §5.2 の項目としては上の格子で全部に対応先がある**ので T9 (c) の「足す」対象には含めなかった
  - 未確認: `test_leak` は今回 `check`（5/6 段、PG17 のみ）と `pixi run test`（両サーバー）で通っているが、turn 10 以降 `test_leak.mojo` は無変更なので RSS のサンプル列は turn 10 の記録が最新
  - 未確認: PLAN の全 9 タスクが `- [x]` になった。次は `/gsd-lite-verify`（`phase: "verify"`）
## turn 12 — verify — round 1: 指摘 1 件（F1、numeric の正規化後 weight が wrap）+ 字句 3 件 → impl へ差し戻し。マージ無し
- やったこと: サブエージェント 2 本（コードレビュー / セキュリティ、読み取り専用）を並行させ、親はクリーンな `pixi run check`（6/6 PASS）、堅牢性の格子プローブ
  （`scratch/turn-012-fuzz.mojo`: テキスト parser 8 種 × 22,788 入力 + バイナリ decoder 22 組 × 2,050 パターン + crafted numeric 3,027 + 生 ctor 極値 ≒ 230,000 呼び出し、クラッシュ 0）、
  追従先チェックリスト 32 件の再実行（不一致 0）、T7 陽性対照の再実行（現 HEAD でもコンパイルエラー）、文書照合、timetz 極値の wire 実測を実施。VERIFICATION.md を round 1 の結果で作成し、F1 を PLAN に追記
- 想定外:
  (1) ファズの「`parse(String(v)) == v`」は **dscale が実桁より小さい非正規化 numeric** で偽になる（71 件）。実装の誤りではなくプローブ側の性質の立て方の問題（`String()` は一致）。
      本物の指摘（weight wrap）は crafted ケースの `0002 8000 0000 0000 0000 0001` で別に出た
  (2) Mojo 1.1.0 はモジュールレベル `var` を許さない（`error: global variables are not supported`）。集計と LCG 状態を `struct State` に入れて `mut` で渡した
  (3) 指摘 1 は impl が turn 5「未確認」で挙げていたものと同一。impl 側の申し送りを verify が最初に読んで格子に入れたので、独立 3 経路（ファズ / レビュー / セキュリティ）で一致した
- やり直し: 1 回（ファズ probe のコンパイル: 想定外 (2) のグローバル変数）
- 次への注意:
  - 確認済み: `pixi run check` 6/6 PASS = 約 140 s（ログ `turn-012-check.log`）。両サーバー 21 ファイル全 PASS
  - 確認済み: F1 の期待結果は PLAN の表が唯一の正。`0002 8001 ...`（stripped -32768）は**成功**しなければならない（境界を含めて弾くと `test_numeric_minimum_weight_decodes` と矛盾する）
  - 確認済み: F1 の検査位置は `decode_numeric` 側（`_from_parts` は raise しないシグネチャ。`_parse_opt` は先頭ゼロ群を作らないので対象外）
  - 確認済み: round 2 は「round 1 の格子の再確認 + F1 差分の回帰」だけ。ファズは `scratch/turn-012-fuzz` を再ビルドして回せば `BAD bin decimal text roundtrip` の 71 件（dscale クラス）が残り、weight クラスの行が消えるのが期待
  - 未確認: F1 (c) の文言は趣旨だけ PLAN に書いた。impl が英文にするときは「`pq` は `client_encoding` を設定しない」「UTF-8 を検証しない」の 2 点を落とさない
