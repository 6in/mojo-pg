# DECISIONS — phase7-pool-copy-array

## D1. slug は `phase7-pool-copy-array`、3 件を 1 マイルストーンで扱う

- 採用: HANDOFF §3 の対象外 3 件（プール / COPY / 配列型）をまとめて 1 マイルストーンにする。Phase 3（19 型）と同規模。
- 却下: 「配列型 + COPY を先に、プールは次」「配列型だけ先に」。ユーザーは一度の discuss で全部の仕様を詰めることを選んだ。
- 付随: 規模が大きいので `verify_round_max` は 4 にする（Phase 6 reflect の提案を適用）。

## D2. 堅牢性の受け入れ基準を入れる

- 採用: Phase 5 / 6 と同じ「どの入力・出力状態でもトレースバックを出さず、既存データを失わない」を受け入れ基準に含める。
  plan が堅牢性格子を初回タスクに含め、verify が該当指摘で差し戻せる。
- 却下: 入れない（verify が残留リスクに留める）。COPY の途中切断やプールの死んだ接続など、異常系が主題の機能なので薄くできない。

## D3. 配列の要素型は既存 19 型すべて

- 採用: `List[T]` の `T` に型マッピング表の 19 型すべてを許す。要素デコーダは既存の `decode_text` / `decode_binary` を再利用し、
  新規に書くのはテキストの配列リテラルパーサとバイナリの配列ヘッダ（ndim / flags / elemtype / dims / lbound）だけ。
- 却下: 「基本型だけ」「基本型 + uuid / numeric / 日時（bytea / json / jsonb を除く）」。引用符内エスケープの扱いは要素型によらず
  リテラル層で 1 回書けば済むので、型を絞る利点が小さい。

## D4. 配列は Mojo 標準の `List[T]`（1 次元）

- 採用: `row.get[List[Int32]](col)`。既存の `List[UInt8]`（bytea）と同じ書き味で、公開型を増やさない。
- 却下: 自前 `PgArray[T]`（dims / lower bound 保持）。多次元と非 1 始まりの添字を保持できるが、新しい公開型が増え、
  利用側が `.elements` 等で取り出す手間が増える。多次元の扱いは D5 以降で決める。

## D5. NULL 要素は `List[Optional[T]]` で受ける

- 採用: `get[List[T]]` は NULL 要素で `NULL_VALUE`、`get[List[Optional[T]]]` は `None` を要素に入れて返す。列 NULL の `get_optional` と同じ二段構え。
- 却下: `List[T]` だけ（NULL を含む配列は `String` でしか読めない）。ディスパッチ分岐は倍になるが、NULL 混じりの配列は実務で普通にある。

## D6. 多次元は `TYPE_MISMATCH`、非 1 始まりの添字は無視

- 採用: ndim ≥ 2 はテキスト / バイナリとも `TYPE_MISMATCH`。下限添字は読み飛ばして要素だけ返す。
- 却下: 平坦化（形状が失われる）、添字も `TYPE_MISMATCH`（実害が小さいのに読めなくなる）。

## D7. 配列の送信は 19 型の `List[T]` / `List[Optional[T]]` をバイナリで

- 採用: 既存の単体型と同じくバイナリ送信。`String` 要素の配列も配列ヘッダが要るのでバイナリ。
- 却下: テキストリテラルで送る（要素の引用エスケープとサーバ側パースが要る）、受信のみ（`= ANY($1)` が使えない）。

## D8. 配列の受信はテキストとバイナリの両方

- 採用: 既存 19 型と同じ規則（届いた形式でデコーダを選ぶ）。`execute(sql)`（PQexec、テキスト）の結果でも型付きで取れる。
- 却下: バイナリだけ（テキスト形式の配列列は `String` でしか読めない）。

## D9. COPY は FROM STDIN と TO STDOUT の両方、同期 `Connection` だけ

- 採用: `PQputCopyData` / `PQputCopyEnd` / `PQgetCopyData` を足し、両方向を同期接続で扱う。
- 却下: 片方向だけ（用途が半分になる）、`AsyncConnection` の COPY（`PQputCopyData` の 0 戻りと `PQgetCopyData(async=1)` の状態機械で
  工数が倍になる。プールも同期なので揃える。次の候補として §3 に残す）。

## D10. COPY のデータはバイト列の素通し

- 採用: 利用側が text / CSV / binary の行バイト列を渡し、ライブラリは転送・終端・エラー回収だけ。全形式を最小のコードでカバーする。
- 却下: 型付き行エンコーダ（`write_row(List[Param])` で PGCOPY binary を組み立てる）、さらに型付き行デコーダ。
  既存のバイナリエンコーダを再利用できるが別系統のタスクになる。要望があれば次以降。

## D11. COPY は RAII オブジェクト、未完了の drop は中止して接続を戻す

- 採用: `CopyIn[origin]` / `CopyOut[origin]`。`finish` なしに `__del__` されたら `PQputCopyEnd(error)` / 残り行の読み捨てで接続をアイドルに戻す。
  失敗は `Transaction` の自動 ROLLBACK と同じフック（`set_rollback_failure_handler`）へ。
- 却下: コールバック 1 発（ストリーム的な利用が関数内に閉じる）、drop で何もしない（接続が COPY 状態のまま残り、次の `execute` が落ちる）。

## D12. プールは単一スレッド前提、ロックなし

- 事実（discuss のプローブ）: Mojo 1.1.0 の標準ライブラリに `std.threading` / `std.sync` / `parallelize` は無く、`std.atomic.Atomic[T]` だけがある。
  スレッドは libc の pthread を `external_call` するしかない。
- 採用: `Connection` と同じく Movable のみ、スレッド安全でないと明記。目的は接続の再利用と上限管理。言語にスレッドが来たらロックを足す。
- 却下: pthread mutex を FFI で呼ぶ（テストに `pthread_create` の FFI も要り、Mojo オブジェクトの跨スレッド安全性を言語が保証しない。Windows は別実装）。

## D13. 枯渇時の `acquire()` は即座に `USAGE`

- 採用: `max_size` に達していれば待たずにエラー。単一スレッドでは返却を待つとデッドロックする。
- 却下: 上限を超えて開く（上限の意味が変わる）、上限なし（サーバの `max_connections` で初めてエラー）。

## D14. 健全性は `PQstatus` → `PQreset` → 捨てて新規

- 採用: 往復なしで安い。サーバ側から切られた接続は次の `execute` で CONNECTION エラーになり、返却時の `PQstatus` で捨てられる。
- 却下: 貸し出しごとに `SELECT 1`（毎回 1 往復）、確認しない（切れた接続を何度も貸す）。

## D15. 返却時はトランザクション中なら ROLLBACK、COPY 中などは捨てる

- 採用: `PQtransactionStatus` が INTRANS / INERROR なら `ROLLBACK`。ACTIVE / UNKNOWN は捨てる。GUC / prepared / 一時テーブルは残す（README に明記）。
- 却下: 毎回 `DISCARD ALL`（1 往復、`DateStyle` / `IntervalStyle` の再設定も要る）、何もしない（開いたトランザクションが次の利用者に渡る）。

## D16. 貸し出しは RAII ガード `PooledConnection[origin]`、drop で自動返却

- 採用: `Connection` の公開メソッドを同じシグネチャで転送するガード。スコープを出たら後始末込みで自動返却し、スロットが漏れない。
  `Transaction` / `CopyIn` と同じ origin パターン。「`pq` は `ref` を返さない」規則を維持。
- 却下: `Connection` をムーブで渡し `release(conn^)` で明示返却（転送層は不要だが、返し忘れで貸し出し数が戻らず `max_size` に達する）。

## D17. プールのオプションは統計 + `min_size` + `max_lifetime_s` の 3 つ

- 採用: `size()` / `idle()` / `borrowed()`、`min_size`（事前接続）、`max_lifetime_s`（返却時に寿命超過を閉じる）。すべて `Pool.open` のキーワード引数と単純なカウンタで足せる。
- 既定値: `min_size=0`、`max_lifetime_s=0`（無期限）。単位は秒で `Int`（`Optional` は使わない）。

## D18. 受け入れ基準の観測手段は `backend_pid` と `pg_stat_activity`

- 採用: 再利用の証明は `SELECT pg_backend_pid()` の一致、接続本数は `pg_stat_activity` の件数で測る。サーバ側切断は `pg_terminate_backend`。
  verify が同じコマンドで再現できる。

## D19. `.gsd-lite/` はこのまま追跡する

- 採用: 6 フェーズ分の記録をリポジトリに残す運用を変えない（Phase 6 reflect の持ち越し (e) を閉じる）。
- 却下: PR を squash マージ（人間の運用変更が要る）、gitignore にして追跡をやめる（git 復元で state が戻らず、ループのコミット運用と相性が悪い）。

## D20. 実行パターンは現在の設定を維持

- 採用: engine=claude / phase_engines={} / model: research・plan・verify・reflect = claude-fable-5-1, impl = claude-opus-5 / subagents=auto / reflect=true。
  Phase 3〜6 と同じ。`GSD_LITE_ENGINE` は未設定、`gsd-lite-loop.sh --check` 合格（trust 済み）。
- 却下: impl も fable-5-1（単価増）、impl だけ Codex（sandbox の準備確認が要る）、subagents=off。
- research の調査対象は official_docs / similar_oss / local_projects の 3 つすべて。
