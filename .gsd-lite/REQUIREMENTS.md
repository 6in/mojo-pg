# REQUIREMENTS — phase5-polish-bench-readme

HANDOFF §9 の Phase 5「仕上げ」。ベンチマーク（text vs binary、psycopg 3 比較）、README、examples の総点検、
Windows コードパスのレビュー、Phase 4 からの持ち越し整理。

## 1. 背景（事実。discuss 時点 2026-10-17）

- Phase 0〜4 は完了（`archive/` と `reflect/` 参照）。公開 API は `src/pq/__init__.mojo` の export 一覧
- README / LICENSE は未作成。`pixi.toml` は `license = "Apache-2.0"`
- git remote なし、CI なし（Phase 1 D7: 受け入れはローカル `pixi run test` / `pixi run check`）
- `examples/`: hello_libpq / basic / params / binary / async_query / listen_notify / bench_formats の 7 本。`pixi run check` の 4/6 段が
  bench 以外を実行する
- `examples/bench_formats.mojo` は 10 万行 × 5 列の text vs binary を測る（warm-up 1 + 3 回、exec / decode を分けて印字）。psycopg 比較は無い
- psycopg 3.3.3 はホストの pyenv python3 にあるが pixi 環境には python が無い
- `tests/docker-compose.yml`: pg17 (54317) / pg14 (54314) / blackhole (54399)。`check` は Phase 4 末で 167〜187 s、`test_leak` 74 s
- Windows: `_platform/poll.mojo` の `comptime if` の `else` に `WSAPoll` 分岐（未コンパイル・未検証、docstring 明記済み）。
  `_ffi/loader.mojo` の探索リストは linux / macos のみで `libpq.dll` の行が無い（HANDOFF §5.1 は Windows: `libpq.dll`）
- Phase 4 VERIFICATION §5 の持ち越し: `fetch_all` が BAD にならない `CONNECTION` エラーで busy-spin し得る（`async_conn.mojo:1453-1461`）／
  `_after_send` で `PQflush` が -1 のとき pq は `IDLE`、libpq は `BUSY`／`tests/test_notify.mojo` の `SQL_ASCII` テストが `pq_test_ascii` DB を残す／
  `test_zero_copy` が 1 テスト 3.4〜3.9 s（接続あたりの固定費。Phase 4 以前から）
- Phase 4 TRACE 末尾のサブエージェント契約外提案 7 件: `AsyncConnection.wait_notifications(n, timeout_ms)`／`notifications()` の `PQstatus == CONNECTION_BAD` 先行チェック／
  `UNLISTEN` 後に来ないことのテスト／LISTEN していないチャンネルの無視／`LISTEN "Mixed Case"`／UTF-8 スキャナ単体に `f4 90 80 80` と `f5 80 80 80` の 4 バイト境界／
  検証失敗に専用の `PgErrorKind.ENCODING`

## 2. スコープ（やること）

1. **ベンチマーク**: `pixi run bench`（既存、text vs binary）に加えて psycopg 3 比較を `pixi run bench-psycopg` として追加し、結果を README に記録する（§4.1）
2. **README**（§4.2）と **LICENSE**（Apache-2.0）
3. **examples の総点検**（§4.3）
4. **Windows コードパスのレビュー**（§4.4）
5. **持ち越し整理**（§4.5）: テスト DB の後始末 / `fetch_all` busy-spin / `PQflush` -1 / `test_zero_copy` の接続固定費の調査
6. **契約外提案 7 件の採否**（§4.6。採否は discuss で決める）
7. **堅牢性**（§5）: examples / bench を含め、どの入力・出力状態でもトレースバックを出さず、既存データを失わない

## 3. スコープ外（やらないこと）

- HANDOFF §3 の対象外（ワイヤプロトコル自前実装、プール、COPY、パイプラインモード、ORM、Mojo `async` 統合）
- 配列型・range・その他 §6 に無い型（Phase 6 候補）
- Windows での実行・コンパイル（ツールチェーン無し。レビューと「未検証」明記まで）
- psycopg との勝敗を受け入れ条件にすること（HANDOFF §8。記録だけ）
- CI（D13。remote 無し。README にはローカルの回し方だけ）
- 新しい型・新しい同期 API の追加。Phase 4 TRACE の契約外提案 7 件（§4.6）以外の API 追加はしない

（以下の節はラウンドの進行に合わせて追記する）

## 4. 機能要件

### 4.1 ベンチマーク

- psycopg 3 比較は **pixi に python と psycopg を足し**、`pixi run bench-psycopg` で実行する（D2）。同じ SQL（`bench_formats.mojo` の `SQL`、10 万行 × 5 列）、
  同じ形式の区別（text = 既定カーソル、binary = `binary=True`）、同じ測り方（warm-up 1 + 3 回、全セルを読む）。スクリプトの置き場所は plan が決める（既定 `examples/bench_psycopg.py`）

- `pixi.toml`: python と psycopg（conda-forge）を足す。常時依存に入れるか feature / 環境に分けるか（`pixi run bench-psycopg` が動く最小の形）は research が確認し plan が決める
- 測定の記録: README に表（形式 × exec / decode / 合計、psycopg は text / binary の各合計）、計測環境（CPU、OS、Mojo 版、libpq 版、PostgreSQL 版、psycopg 版）、日付。
  対象サーバーは pg17（54317）のみ。1 行の要約（「バイナリがテキストより速い」が成り立つか）を数値つきで書く
- HANDOFF §8 の「バイナリ形式がテキスト形式より速いこと」は Phase 3 で確認済みの性質。今回も `pixi run bench` の `decode` 列で成り立つことを受け入れ基準に含める
  （exec を含む合計での勝敗は記録のみ）
- 堅牢性（§5）: bench-psycopg も DB 未起動・認証失敗でトレースバックを出さず、メッセージを表示して終了コード 1

### 4.2 README（日本語。D7）と LICENSE

- `README.md`（日本語）。最低限の節: 概要と対応環境（Mojo 1.1.0 / libpq 14+ / Linux・macOS、Windows は未検証）／インストール（pixi、libpq の探索順と `PQ_MOJO_LIBPQ`）／
  クイックスタート（同期・パラメータ・トランザクション・バイナリ・非同期・LISTEN/NOTIFY の最小例。`examples/` へのリンク）／型マッピング表（HANDOFF §6 の実装どおり）／
  エラー（`PgErrorKind` 一覧）／ベンチマーク結果（§4.1。計測環境・版・日付つき）／テストの回し方（`db-up` / `test` / `check`）／Windows の状態（§4.4）／ライセンス
- `LICENSE`: Apache-2.0 全文。README 末尾に `Copyright 2026 0hya6in`（D11）

### 4.3 examples の総点検

- 7 本すべてが単体で実行でき（`pixi run example-*` / `bench`）、DB 未起動・認証失敗で `PgError` を表示して終了コード 1 で終わる（§5 堅牢性）
- 各ファイル先頭の docstring が「何を見せる例か」「実行方法」「前提（DB）」を持つ。README のクイックスタートと矛盾しない

### 4.4 Windows コードパスのレビュー（D6）

- `_platform/poll.mojo` の `else` 分岐（`WSAPoll`、`WSAPOLLFD` 16 byte、フラグ値、`SOCKET` 幅、タイムアウト -1 の扱い、戻り値 `SOCKET_ERROR`）を
  Microsoft Docs と照合し、指摘を直す。照合表（項目 / 根拠 URL / 判定）を TRACE に残す
- `_ffi/loader.mojo` の探索リストに Windows の行（`libpq.dll`。HANDOFF §5.1）を足す。コンパイル時 OS 判定は poll.mojo と同じ書き方
- README に「Windows 用コードは存在するが未検証（Mojo の Windows ツールチェーン待ち）」を明記

### 4.5 持ち越し整理

- `fetch_all`: `kind == CONNECTION` なら `PQstatus` に関わらず drain を打ち切る（1 分岐 + テスト 1 件）
- `_after_send`: `PQflush` が -1 のとき状態を `BUSY` に置く（1 分岐 + テスト 1 件。到達困難なら陽性対照はコードレビュー）
- `test_zero_copy` の接続固定費（D12）: 原因を特定して TRACE に記録する（計測: `mojo run` 単体の所要と、`check` 内の所要 2 s との差も説明する）。
  原因がテスト側（`_connect` の作り、1 テストごとの接続数、フィクスチャ）なら直す。src 側なら直さず README の既知の制限か VERIFICATION 残留リスクに書く

### 4.6 契約外提案 7 件（D5。すべて採用）

- `notifications()`: 先頭で `PQstatus == CONNECTION_BAD` なら `CONNECTION` を投げる（空リストを返さない）。テスト 1 件
- `AsyncConnection.wait_notifications(n: Int, timeout_ms: Int) raises PgError -> List[Notification]`: 詳細は §4.6.1
- `PgErrorKind.ENCODING` 新設: 詳細は §4.6.2
- テスト 4 件: UTF-8 スキャナ単体に `f4 90 80 80`（U+110000、不正）と `f5 80 80 80`（不正先頭バイト）／`UNLISTEN` 後に `NOTIFY` しても `wait_notification` が None／
  LISTEN していないチャンネルへの `NOTIFY` は届かない／`LISTEN "Mixed Case"` の `Notification.channel` が `Mixed Case` のまま

#### 4.6.1 `wait_notifications(n, timeout_ms)`（D8）

- `n >= 1`、`timeout_ms` は `wait_notification` と同じ範囲（`-1 .. TIMEOUT_MS_MAX`、それ以外は `USAGE`）。`n < 1` は `USAGE`
- n 件集まるか予算が尽きるまで待ち、集まった分（0〜n 件）を返す。予算切れはエラーにしない。`wait_notification` と同じ保留バッファを共有する
  （1 往復で余った通知は次の呼び出しが待たずに返す）
- `Connecting` 中の呼び出しは `USAGE`、切断は `CONNECTION`、UTF-8 でない通知は `ENCODING`（§4.6.2）
- テスト: n 件ちょうど／予算切れで部分／`n=1` が `wait_notification` と同じ結果／`n < 1` が `USAGE`／上限 `c_int` 境界は既存 `wait_notification` の格子を流用

#### 4.6.2 `PgErrorKind.ENCODING`（D9）

- 新しい値（既存 6 値の次。番号は plan）。`result.mojo` / `decode_binary.mojo` の `_validated_utf8` と `async_conn.mojo` の `_reject_bad_notification_text` の
  失敗がすべて `ENCODING` になる。メッセージ文言は変えない
- 既存テストの期待値 `TYPE_MISMATCH` を `ENCODING` に直す（該当箇所は plan が `grep -rn 'invalid UTF-8'` で列挙）。`TYPE_MISMATCH` が残るのは OID と型の不一致・パース失敗だけ
- docstring の `Raises:` と README のエラー一覧を更新

### 4.7 テスト DB の後始末（D10）

- `tests/test_notify.mojo` の `SQL_ASCII` テストは先頭で `DROP DATABASE IF EXISTS pq_test_ascii`、末尾（成功・失敗とも）で `DROP DATABASE`。
  末尾の DROP が失敗しても元のテスト結果を隠さない
- `pixi.toml` に `db-reset`（`db-down` → `db-up`。フィクスチャ再適用）を足し、README のテストの節に書く。`check` は変えない

## 5. 受け入れ基準

- HANDOFF §10 Phase 5: ベンチマーク結果が README にある／`examples/` が全部実行できる／Windows 用コード（`WSAPoll`、DLL 名）が存在し、未検証であることが README に明記されている
- 共通: `pixi run check` が PASS（fmt / precompile / docstring / examples / tests 両サーバー / 警告ゼロ）
- 堅牢性（D4）: `src/pq` と `examples/` と bench スクリプトは、どの入力・出力状態（DB 未起動、認証失敗、切断、不正な引数）でもトレースバックを出さず、
  既存データを失わない。examples / bench は `PgError` を表示して終了コード 1 で終わる

- 持ち越し（§4.5）: `fetch_all` の新テストが `kind == CONNECTION` で打ち切ること／`PQflush` -1 の分岐がコードにあること（到達困難ならレビューで担保し TRACE に記載）／
  `test_notify` 実行後に `pq_test_ascii` が残らない（`psql -l` 相当で確認）／`test_zero_copy` の原因が TRACE に記録されている
- 契約外提案（§4.6）: 新テストがすべて PASS、`ENCODING` への期待値変更で `TYPE_MISMATCH` の既存テストに取りこぼしが無い（`grep -rn 'invalid UTF-8' tests/` の全件が `ENCODING`）
- Windows（§4.4）: 照合表が TRACE にあり、`loader.mojo` に `libpq.dll` の行がある。Linux / macOS の挙動は変わらない（`check` PASS で担保）
- README（§4.2）: コード片は `examples/` から抜粋し、`examples/` の実行で検証済みであること。型マッピング表と `PgErrorKind` 一覧が実装と一致（verify が照合）
- 所要: `check` が Phase 4 末（167〜187 s）+ 60 s を超えない（超えるなら PROGRESS に理由を書く）

## 6. 用語集

- **check**: `pixi run check`（`tests/final_check.sh`、6 段）
- **bench**: `pixi run bench`（Mojo、text vs binary）。**bench-psycopg**: 同じ測定を psycopg 3 で行う新タスク
- **持ち越し**: 前フェーズの VERIFICATION §5 / reflect が「Phase 5 が引き取る」と書いた項目

## 7. research への「要実測」

- pixi で python + psycopg を足す最小の形（常時依存 / feature / 別環境）と、conda-forge の psycopg 3 のパッケージ名（`psycopg` と `psycopg-c` / `psycopg-binary`）
- psycopg 3 でバイナリ形式の結果を取る書き方（`cursor(binary=True)` / `row_factory`）と、Mojo 側 `bench_formats.mojo` と同じ「全セルを読む」測り方
- `WSAPoll` の仕様（`WSAPOLLFD` レイアウト、`POLLRDNORM` 等の値、timeout -1、`SOCKET_ERROR`、`POLLERR`/`POLLHUP`/`POLLNVAL` を events に指定したときの `WSAEINVAL`）の一次資料 URL
- `_ffi/loader.mojo` の `platform_map` 相当に Windows の行を足す書き方（Mojo 1.1.0 に `is_windows()` が無い前提。poll.mojo の `else` と同じ判定）
- `test_zero_copy` の所要の計測手順（`mojo run` 単体 vs `check` 内、`_connect` 回数、`perf_counter_ns` での内訳）
- `DROP DATABASE` を発行する接続が対象 DB に繋いでいないこと（`pq_test` 側から発行）と、PG14 / PG17 での `DROP DATABASE ... WITH (FORCE)` の可否
- Apache-2.0 全文の取得元（https://www.apache.org/licenses/LICENSE-2.0.txt）

## 8. 用語の補足

- **ENCODING**: `PgErrorKind.ENCODING`。UTF-8 検証失敗（列の text / 通知の channel・payload）
- **契約外提案**: Phase 4 のサブエージェントが挙げ、Phase 4 では実装しなかった 7 件（§4.6）

## 9. 後続フェーズへの申し送り（Phase 4 reflect より。スキル本文は変えないのでここに書く）

- **research**:
  - RESEARCH §0.5「Mojo 1.1.0 既知の落とし穴」に Phase 1〜3 分に加えて Phase 4 の 9 件を足す: `PgError` を値で返すとき `return e^`／`except e: return e^` の `try` 本体から
    `Error` を投げるヘルパを呼べない（判定は `try` の外へ）／`var x: Optional[T] = None` は `except` が必ず脱出すると「assignment never used」警告／
    `FileDescriptor(fd).write()` は一時値への mutating 呼び出しで不可（`var` に受ける）／`prefix^ + chr(0)` は `^` 演算子と解釈される／`self._field^` でフィールドから
    move out 不可（`copy()` + `clear()`）／`print("SKIP ...")` は 80 桁を超えると `mojo format` が割る／`len(StringSlice)` は `byte_length()`／`__origin_of` は `origin_of`。
    加えて「Mojo → C の型幅」（`c_int(x)` / `Int32(x)` の縮小変換）の節を 1 つ設ける
  - 期待値表は `...` で桁を省略しない。原本を取った SQL と出力ログのパス（`scratch/turn-001-*.log`）を同じ行に書く
  - §7 の「要実測」はすべて最初のプローブ対象。矛盾を見つけたら REQ 本文を直してよい
- **plan**:
  - 追従先チェックリストは最初から実行可能なスクリプト（`.gsd-lite/logs/<slug>/scratch/turn-002-checklist.sh`）。表は「key / 直す場所 / 期待値」の 3 列だけ、
    現在値は `scratch/turn-002-checklist.log` へ。impl の PLAN 訂正は `TRACE.md` の「PLAN 訂正（turn N）」節に 1 件 1 行
  - 「境界値」の観点に縮小変換の行を常設: `c_int(x)` / `Int32(x)` / `Int16(x)` / `UInt32(x)` と書いた引数は上限ちょうど・上限 +1・`Int.MAX`・`-1` を完了基準のテストに列挙
    （今回は `wait_notifications` の `n` と `timeout_ms`）
  - 所要見積もり: `check` = Phase 4 末実測 167〜187 s + 新テストファイル数 × 5 s + 新テストの明示的な `pg_sleep` / タイムアウト秒の合計 + bench は `check` 外。
    接続は 1 本 0.3 s。`check` が前回末 +60 s を超えるなら書く
  - 「サブエージェント N 本（親を除く）」と書き、サブ作業が 1 本だけのタスクは「0 本（親が全部）」。テストのみ 2 ファイル型は 1 本を既定
  - 陽性対照を完了基準に書く（`ENCODING` の期待値変更は `grep -c TYPE_MISMATCH` の増減で、`DROP DATABASE` は `psql -l` で）
  - 持ち越し整理（§4.5 / §4.7）は T1 に 1 コミットでまとめる
- **impl**:
  - PROGRESS 1 ターン 40 行上限。「検証（所要つき）」は 2 行、チェックリストは 1 行、生の値は TRACE へ
  - PROGRESS「未確認」で「誤った値が黙って返る経路」「状態機械が壊れる経路」を述べる行は、同ターンでテスト 1 件にするか PLAN の該当タスクに「(x) この行を処分する」を追記
  - 最終タスクの完了基準に「PROGRESS の全『未確認』行を テスト追加 / 契約外と明記 / verify 申し送り のいずれか 1 つに振り分けた表」
  - PROGRESS「やったこと」に「推奨 N 本 / 実 M 本」
  - サブエージェント依頼文に (a) 型パラメータを持つ型はフルに書く、(b) `fmt` は親が統合後に 1 回、(c) scratch は `.gsd-lite/logs/<slug>/scratch/turn-NNN-<name>` 固定
  - README のベンチ結果は実測の生ログ（`scratch/turn-NNN-bench.log`）から転記し、ログのパスを PROGRESS に書く
- **verify**:
  - 字句の指摘はクラスで名指しする（`grep -rn` でリポジトリ全体を列挙して F 項目に同梱）
  - 差し戻しの「期待される変化」は集計値を「どの数がいくつからいくつへ」で書く。round 2 以降は round 1 の格子の再確認 + 差し戻し分の回帰に限定してよい
  - サブエージェントの完了は出力ファイルの mtime で待たず、`sleep <見込み秒>` の Bash 1 本（または完了通知）で待つ
  - 「読み取り専用」はテスト DB も含む。検証のために DB を作るなら名前を `pq_verify_<turn>` にして同ターンで消し、PROGRESS に書く
  - 差し戻しに「ついで」を同梱するときは F 項目に「見込み行数 / 新しいテスト資源の有無」を 1 行書く
  - README の型マッピング表・`PgErrorKind` 一覧・examples の実行手順を実装と照合する（本マイルストーン固有）
- **reflect**: 「テスト 2 ファイル型を 1 本」の USD を Phase 3 T6（2 本・USD 10.77）/ Phase 4 T5 と比べる
