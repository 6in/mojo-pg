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
