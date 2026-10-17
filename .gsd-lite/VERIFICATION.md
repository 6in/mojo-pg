# VERIFICATION — phase5-polish-bench-readme

- round 2: 2026-10-18 / turn 12 / Claude Code（claude-fable-5-1）。判定 **指摘あり（F2 の 1 タスク。文書のみ 6 行）→ impl に差し戻し**。F1 は合格（§5）
- round 1: 2026-10-18 / turn 10 / Claude Code（claude-fable-5-1）。判定 **指摘あり（F1 の 1 タスク）→ impl に差し戻し**
- 対象: `git diff main...HEAD`（コード 20 ファイル: `src/pq` 7 / `tests` 4 / `examples` 8 / `pixi.toml` / `pixi.lock` / `README.md` / `LICENSE`）。
  `CLAUDE.md` / `AGENTS.md` は無し。サブエージェント 0 本（親が全部。差分が 1 画面に収まる規模）
- 生ログ: `.gsd-lite/logs/phase5-polish-bench-readme/scratch/turn-010-{check,checklist,robust-grid}.log`、スクリプト `turn-010-robust-grid.sh`

## 1. 観点と確認したこと

### 1.1 コードレビュー（`src/pq`）

| 変更 | 確認 |
|---|---|
| `fetch_all` の打ち切り `e.kind == CONNECTION or PQstatus == BAD`（T1） | raise される値は `first_error` 経由で不変。テスト `test_fetch_all_stops_draining_on_a_closed_socket` は `close(2)` → `_fetch_all_error` → `kind == CONNECTION` かつ `< 500 ms` を断定し、修正前は 2003 ms `TIMEOUT` で FAIL（PROGRESS turn 3 の陽性対照）。close 後に fd を開かない形（末尾 `_ = conn^` のみ） |
| `_after_send` の -1 → `BUSY`（T1） | 到達不能の根拠（`PQflush` は `CONNECTION_BAD` のときだけ -1 / `pqSendSome` は 0 / `pqsecure_raw_write` は `n = len`）が TRACE に 3 行。分岐のコードは存在（`async_after_send_PGASYNC_BUSY` = 1）。レビューで妥当 |
| `_reject_lost(method)`（T2） | `notifications` 直接 1 + `_collect_notifications` 1 の 2 入口 + def = 3（PLAN 訂正 turn 5 のとおり）。`wait_notification` / `wait_notifications` は `method` 経由で自分の名前。テストは完全一致で 3 回同一 message + `wait_notification()` の文言を断定 |
| `PgErrorKind.ENCODING = 7` / `write_to` `"Encoding"`（T2） | raise 4 箇所（`decode_binary.mojo` 2 / `async_conn.mojo` 2）で文言は不変。`tests_TYPE_MISMATCH` 97 → 91（−7 + `test_errors` の 1 行）、`src_utf8_and_type_mismatch_same_line` = 0。`grep -rn 'invalid UTF-8' tests/` は全件 `ENCODING` |
| `_collect_notifications` / `wait_notifications`（T3） | 入口順 `_reject_bad_timeout` → `n < 1` → `_reject_connecting` → `_reject_lost`。予算切れは `out^` を返し例外にしない（D8）。`notifications()` の raise 時に `out + _pending` の順で復元（古い順を保つ）。余りは `_pending` に append。`n = Int.MAX` は `len(out) < n` の比較だけで C に渡らない。`timeout_ms = -1` の `deadline` は負になるが `timeout_ms >= 0` の分岐でしか読まない |
| `poll.mojo` の `(ret, flags, err)` 化（T4） | errno / `WSAGetLastError` は失敗した直後に `_poll_once` 内で読む（次の呼び出しで上書きされる前）。POSIX 側の挙動は不変（`EINTR` 再試行 / `EBADF` `EINVAL` → `USAGE`）。message を `poll failed: errno N` に変えたが `tests/test_poll.mojo` に文言断定は無い（`test_poll` 11 件 PASS） |
| `loader.mojo` の `_default_candidates()`（T4） | `comptime if` 連鎖。Linux / macOS の候補は旧 `platform_map` と同一文字列。`PQ_MOJO_LIBPQ` の扱い不変 |
| `examples/bench_psycopg.py`（T5） | SQL は定数、入力は環境変数 1 つ、`autocommit=True`、全セルを読む。**例外処理の取りこぼし 2 クラス → F1**（§3） |

### 1.2 テストの妥当性

- 新テストは完了基準を実際に検証している: ④ `n ∈ {0, -1}` の文言 `got 0` / `got -1`、⑤ `timeout_ms ∈ {-2, 2147483648, 4294967296, Int.MAX}` の 4 値 + `0` 即時 + `-1` 保留あり、⑥ `Int.MAX` が予算で止まる、⑦ 余りが次の呼び出しに `< 50 ms`、⑧⑨ `out` 保全（⑨ は restore 無しで FAIL することを impl が実測。`turn-005-notify-norestore2.log`）、UNLISTEN / 未 LISTEN / `"Mixed Case"` の契約外 3 件
- 既存テストの期待値変更は PROGRESS turn 4 の **7 行だけ**（`test_decode_binary.mojo` 5 + `test_notify.mojo` 2）で、全部 UTF-8 不正の kind 変更。OID / 幅 / jsonb 版数の `TYPE_MISMATCH` は不変（diff で確認）
- `_drop_ascii_database()` は `pq_test` 側の同期接続から `WITH (FORCE)`、失敗は `Bool` で握って raise しない。`_ascii_conninfo` の `42P04` 容認は消えている

### 1.3 セキュリティ

- 入力検証: `n` / `timeout_ms` は Mojo 側で範囲検査し C に縮小変換しない。conninfo は libpq にそのまま渡す（libpq 側の検証に委ねる。設計どおり）
- 秘密情報: `password=pq` はテストコンテナの既定で、examples 7 本と `run_tests.sh` が元から持つもの（新規流出なし）
- インジェクション: `bench_psycopg.py` の SQL は f-string だが埋め込むのは定数 `ROWS` のみ。テストの `DROP DATABASE` は固定名
- 依存: `psycopg >=3.2` を別 feature に閉じ、default 環境は不変（`pixi list -e default` の python / libpq のビルドが同一。PROGRESS turn 7）

### 1.4 文書の主張

- README のベンチ表 12 セル × 4 行を `scratch/turn-007-bench.log` の pass 1 と 1 つずつ照合 → **一致**。1 行要約「decode 約 3.7 倍（42 → 11）」「合計約 1.7 倍（83 → 50）」はログと整合
- README のコード片 6 本は `turn-008-readme-excerpts.py` を再実行して `blocks=6 missing_total=0`。型表は `turn-008-typetable.py` で OID 19 行・Mojo 型列が `__init__.mojo` と一致（差分 4 件は日本語化した散文のみ）
- README の `PgErrorKind` 8 行は `errors.mojo` の宣言順・印字名と一致。examples の実行行 7 本は `pixi.toml:16-23` のタスク名と一致（`example-async` / `example-notify` の 2 本もファイル名でなくタスク名）
- TRACE「Windows 照合表」12 行を Microsoft Learn の [F] / [E] と突き合わせ: `events` に置けるのは `POLLPRI / POLLRDBAND / POLLRDNORM / POLLWRNORM` のみで他は `SOCKET_ERROR` + `WSAEINVAL`（#3）、timeout の 3 値（#4）、`SOCKET_ERROR` → `WSAGetLastError`（#5 / #6）、`WSAEINTR` 10004 / `WSAEBADF` 10009 / `WSAEINVAL` 10022 / `WSAENOTSOCK` 10038 / `WSANOTINITIALISED` 10093（#6 / #11）、「As of Windows 10 version 2004 … `(POLLHUP | POLLERR | POLLWRNORM)`」（#8）、Vista 以降・`Ws2_32.dll`（#9）、負の `fd` は `POLLNVAL`（#7）→ **すべて一致**
- 追従先チェックリスト（`turn-002-checklist.sh`）を再実行 → `turn-009-checklist.log` と **完全一致**（82 key すべて期待値内。例: `tests_TYPE_MISMATCH` 91 / `src_TYPE_MISMATCH` 106 / `test_notify_tests` 24 / `test_async_tests` 31 / `license_lines` 202 / `examples_pixi_run` 7）
- 言い切り過ぎ 1 件: README §7「`postgres://` の URI は受けません」は examples には当たらない（`basic` に URI を渡すと exit 0）。テストの制約（`run_tests.sh:11-12`）→ **F1 (c)** に同梱

### 1.5 最終判定コマンド

- `pixi run check`（クリーンな木、00:22:25 → 00:25:29 = **184 s**。閾値 247 s）→ **6/6 PASS**（`final_check: PASS`、`0 failed` のサマリ 47 件、`FAIL` 0 行、6/6 段の `matched lines` 0）
- `docker exec … pg_database` は pg17 / pg14 とも **0 行**（`pq_test_ascii` が残らない）

## 2. 堅牢性の格子（round 1。round 2 以降はこの再確認 + F1 の回帰だけ）

impl の 17 本（`turn-009-examples-robust.sh`: DB 未起動 / 認証失敗 / libpq 不在 / `port=abc`）に無かった面を一括で試した。
`turn-010-robust-grid.sh`（**37 レコード**。ビルド済みバイナリ `basic` / `hello_libpq` / `listen_notify` と bench 環境の `python` を pixi のバナー無しで直接呼ぶ）。

| 軸 | 試した値 | Mojo examples / loader | `bench_psycopg.py` |
|---|---|---|---|
| `PQ_TEST_CONNINFO` | 空 / `postgresql://` URI / 非 UTF-8（`\xff\xfe\xc3\x28`）/ 制御文字（`\n` `\t` `\x01`）/ 100 KB / 引用符不整合 / 存在しない DB / 空白のみ | 全部 `failed: PgError(kind=Connection, …)` + exit 1 か正常 exit 0。非 UTF-8 は libpq の message に U+FFFD で入り、`String(unsafe_from_utf8_ptr=…)` → `print` で落ちない | **非 UTF-8 → `UnicodeEncodeError` の Traceback**（F1）。他は `failed: ProgrammingError / OperationalError` + exit 1 |
| `PQ_MOJO_LIBPQ` | `libc.so.6`（読めるが PQ シンボル無し）/ ディレクトリ / 空ファイル / `/dev/null` / 非 UTF-8 パス | 全部 `failed: PgError(kind=LibpqLoad, …)` + exit 1（`missing symbol PQconnectdb` / `dlopen failed` / `file too short`） | — |
| stdout | `/dev/full`（正常・badpw）/ 閉じた fd（正常・badpw・nolib）/ パイプ閉鎖（`\| head -c 1`） | 出力なしで exit 0 / 1（Mojo の `print` は書き込み失敗を無視）。パイプ閉鎖は exit 0（3 行とも書けた） | **`/dev/full` → `Exception ignored while flushing sys.stdout: OSError` + exit 120**（F1）。閉じた fd / パイプ閉鎖は exit 0 / 1 でトレースバック無し |
| stdin | 閉じた fd | 正常 exit 0 | — |
| 1 MB の環境変数 | — | `env` 自体が E2BIG（ハーネスの限界。プログラムの問題ではない） | 同左 |

## 3. 指摘（→ PLAN F1）

1. **`bench_psycopg.py`: `UnicodeEncodeError`（`ValueError` の子）が Traceback になる**（REQ §5 D4「どの入力…状態でもトレースバックを出さず」。`except psycopg.Error` だけでは psycopg の conninfo パーサが投げる `ValueError` 系を取り逃す）
2. **`bench_psycopg.py`: stdout が書けないと終了時 flush の `OSError` が `Exception ignored` + exit 120**（REQ §5 D4「終了コード 1」。正常経路・badpw 経路とも）。Python 公式の SIGPIPE 手順（fd 1 を `/dev/null` に dup2）で消える
3. README §7 の URI の言い切り（文書のみ。F1 (c)）

なぜ impl の格子で拾えなかったか: T7 (b) の格子は RESEARCH の 15 本を踏襲し「DB 側の失敗」だけを面にしていた（出力経路と入力のエンコードのクラスが無かった）。
round 2 は上表の再確認と F1 の回帰（表の 6 行）だけを行い、新しいクラスは探さない。

## 4. 残留リスク（合格側に残すもの）

- Windows 実機は未検証（REQ §3 スコープ外。TRACE 照合表 + README §8 + `loader.mojo` docstring で開示済み）。`_is_usage_error` の 3 コードの分類は文書照合のみ
- Mojo の `print` は stdout の書き込み失敗（`/dev/full`、閉じた fd）を無視して exit 0 で終わる — トレースバックは出ないので D4 は満たすが、「出力が失われた」ことは利用者に伝わらない（stdlib の挙動。pq の対象外）
- `wait_notifications` の `_collect_notifications` は `notifications()` が raise した往復で届いた良い通知を `notifications()` 自身の `_pending` 経由で保全する（⑨ で確認）が、`wait_readable` の `CONNECTION` で抜ける経路では `out` を復元しない（`_pending` に戻さず raise）。切断後は `notifications()` が `_reject_lost` で拒否するので取り出す手段が無く、復元しても届かない — 実害なし
- `check` の所要は 169〜215 s で揺れる（同時実行ノイズ）。閾値 247 s 以内

## 5. round 2（turn 12）— F1 の回帰 + round 1 格子の再確認。新クラスの探索はしていない

- 対象差分: round 1 以降の変更は `examples/bench_psycopg.py`（+44 / -14）と `README.md` §7（+5 / -2）だけ（`git diff --stat 77c997f...HEAD`。`src/` / `tests/` は不変）
- 生ログ: `scratch/turn-012-{check,checklist,robust-regress,bench}.log`、スクリプト `turn-012-robust-regress.sh`

### 5.1 F1 の回帰（PLAN F1 の表 6 行）— すべて期待どおり

| 条件 | 実測（`turn-012-robust-regress.log`） |
|---|---|
| 非 UTF-8 conninfo | rc 1、stdout `failed: UnicodeEncodeError 'utf-8' codec can't encode characters in position 53-55 ...` 1 レコード、`Traceback` 0 |
| `/dev/full`（正常 / badpw） | rc 1 / 1、stderr `failed: OSError [Errno 28] No space left on device` 1 行、`Exception ignored` 0 |
| stdout のパイプ閉鎖（**本物の EPIPE**。§5.3） | 正常 / badpw とも rc 1、stderr `failed: BrokenPipeError [Errno 32] Broken pipe` 1 行、`Exception ignored` 0（表の「0 か 1」の範囲） |
| badpw / badport | rc 1、`failed: OperationalError ...` 1 レコード（badport は libpq のヒント行で物理 2 行） |
| 正常 | rc 0、1 行目 `psycopg 3.3.4 impl=c libpq=180006 server=170011 python=3.14.8` |

- コードレビュー（`bench_psycopg.py:79-109`）: 例外は親クラス 2 段（`psycopg.Error` / `ValueError`）+ 外側 `OSError`。`status` を持ち回って `sys.exit` は末尾 1 回（内側で exit すると明示 flush を飛ばす — impl の説明どおり）。
  `sys.stdout is None`（fd 1 閉鎖）を守っている。`_discard_stdout()` は Python 公式の SIGPIPE 手順そのもの。F1 (a) の規則（親クラス / `_run` の `sys.exit(1)` 不変）に合致
- README §7 の言い換え: `tests/run_tests.sh:10-13` の注記（末尾に ` password=...` を付け足す）と一致。examples が URI で動くことは格子の `basic conninfo URI` / `py conninfo URI`（rc 0）で裏取り

### 5.2 round 1 の格子の再確認（`turn-012-robust-regress.sh`、**42 レコード**。Mojo 3 本は HEAD `0ed5ae9` から再ビルド）

- 全 42 レコードで `unhandled_markers=0 traceback=0 exception_ignored=0`。入力クラス（空 / URI / 非 UTF-8 / 制御文字 / 100 KB / 引用符不整合 / 存在しない DB / 空白のみ / `libc.so.6` / ディレクトリ / 空ファイル / `/dev/null` / 非 UTF-8 パス）は
  すべて `failed: PgError(...)` + rc 1 か正常 rc 0。出力クラス（`/dev/full` / 閉じた fd / stdin 閉鎖）は round 1 と同じ rc
- `pixi run check`（`db-reset` 直後のクリーンな木）→ **6/6 PASS**（`final_check: PASS`、`0 failed` のサマリ 47 件、`FAIL` / `Traceback` 0 行、6/6 段 `matched lines` 0）。所要は約 **165 s**（ログの mtime からの概算。閾値 247 s）
- `docker exec … pg_database` は pg17 / pg14 とも **0 行**
- チェックリスト（82 key）は `turn-011-checklist.log` と **完全一致**（`diff` 空）
- `pixi run bench`（アイドル時、`check` の後に 1 回）: decode **binary 13 / 13 / 13 ms < text 42 / 42 / 42 ms**（README の 12/11/11 vs 42/42/44 と同じ桁。受け入れ基準の性質は再現）
- README コード片 6 本 `blocks=6 missing_total=0`、型表 `src rows=20 readme rows=20` で差分 4 件は round 1 と同じ日本語化の散文のみ

### 5.3 指摘（→ PLAN F2。文書のみ）と、round 1 の格子の欠陥 1 件

1. **examples 6 本の docstring が「`key=value ...` form only, never a `postgres://` URI」のまま**で、F1 (c) で直した README §7「`examples/` は URI でも動く」と矛盾する
   （REQ §4.3「docstring が README と矛盾しない」。`basic.mojo:7` / `params.mojo:13` / `binary.mojo:13` / `async_query.mojo:12` / `listen_notify.mojo:14` / `bench_formats.mojo:16`）。
   **なぜ前ラウンドで拾えなかったか**: round 1 は格子で README の言い切りに気づいたあと README だけを F1 に入れ、同じ文をリポジトリ全体で `grep -rn` しなかった（REQ §9 verify の規則の不履行）
2. 格子の欠陥（指摘ではなく verify 側の訂正）: round 1 / F1 (b) の `run_pipe`（`2>&1 1>&3 | head -c 1`）は **stderr をパイプに、stdout を捕捉側に**つないでいて、stdout の EPIPE を一度も試していなかった。
   round 2 は `> >(exit 0)`（読み手が先に消えたパイプ）に置き換えて本物の EPIPE を試した: `bench_psycopg.py` は上表のとおり合格、Mojo の `basic` / `hello_libpq` は **rc 141（SIGPIPE で終了）**。
   トレースバックは出ず、`head` に繋いだときの Unix の標準挙動なので D4 の違反とは見なさない（§5.4 に残す）

### 5.4 残留リスク（round 2 で追加。合格側に残すもの）

- Mojo の examples は stdout の読み手が先に消えると SIGPIPE で rc 141 になる（stdlib の `print` は SIGPIPE を無視しない）。トレースバックは出ない。パイプで `head` に繋ぐ用途の標準挙動
- `bench_psycopg.py` の `_run` 内 `sys.exit(1)`（件数不一致）は `SystemExit` で明示 flush を飛ばすので、**「サーバーが件数を間違える」と「stdout が書けない」が同時に起きた場合だけ** `Exception ignored` + rc 120 に戻る。PLAN F1 (a) が「`_run` の `sys.exit(1)` は変えない」と定めた経路で、実害は無い
- `_discard_stdout()` の `os.open(os.devnull)` が失敗する（fd 枯渇）と `OSError` が素通りして Traceback になる。stdout が書けない状況との二重故障のみ
