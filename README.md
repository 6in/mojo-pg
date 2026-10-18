# pq — Mojo の PostgreSQL クライアント

libpq を C FFI 経由で呼ぶ、Mojo 用の PostgreSQL クライアントです。同期接続・
パラメータバインド・トランザクション・バイナリ形式の結果・非同期接続・
`LISTEN` / `NOTIFY` を扱えます。

## 概要と対応環境

| 項目 | 内容 |
|---|---|
| Mojo | 1.1.0 |
| libpq | 14 以上（`PQlibVersion()` で確認。それより古ければ候補として捨てる） |
| OS | Linux / macOS。**Windows は未検証**（コードはあるが実行していません。「Windows の状態」参照） |
| PostgreSQL サーバー | 14 / 17 でテスト |

できること: 同期接続（`Connection`）、`$1` 形式のパラメータバインド（`Param`）、
トランザクションとセーブポイント（`Transaction`）、プリペアドステートメント
（`PreparedStatement`）、テキスト／バイナリ両形式の結果デコード（19 の型）、
ゼロコピー読み出し（`Row.get_text` / `Row.get_bytes`）、非同期接続
（`AsyncConnection`）、`LISTEN` / `NOTIFY`（`notifications` /
`wait_notification` / `wait_notifications`）。

`from pq import Connection, PgError` だけで 1 往復が書けます。パッケージが
再エクスポートしている名前がそのまま公開 API です。

## インストール

このリポジトリは [pixi](https://pixi.sh) で環境を作ります。`mojo` と `libpq`
は conda パッケージとして入るので、システムに libpq を入れる必要はありません。

```bash
pixi install
pixi run hello-libpq   # libpq が読めているかの確認（接続はしない）
```

自分のプロジェクトから使うときは `src/` を import パスに加えます
（`pixi.toml` の各タスクが付けている `-I src` と同じことです）。

```bash
mojo run -I /path/to/pgcon/src your_app.mojo
```

### libpq の探索順

`src/pq/_ffi/loader.mojo` の `_default_candidates()` が OS ごとに候補を順に
試し、最初に読めて `PQlibVersion() >= 14` を満たしたものを使います。

| OS | 候補（この順） |
|---|---|
| Linux | `libpq.so.5`、`libpq.so` |
| macOS | `libpq.5.dylib`、`libpq.dylib`、`/opt/homebrew/opt/libpq/lib/libpq.5.dylib`、`/usr/local/opt/libpq/lib/libpq.5.dylib` |
| Windows | `libpq.dll`（探索順は `LoadLibrary` 自身に任せる: 実行ファイルのディレクトリ → System32 → `PATH`） |

環境変数 **`PQ_MOJO_LIBPQ`** を設定すると候補はそれ 1 つだけになります
（フルパスでも名前でも可）。どれも読めなかったときは
`PgErrorKind.LIBPQ_LOAD` で、試した候補と理由が message に並びます。

## クイックスタート

以下のコード片はすべて `examples/` から抜粋したものです。各例は
`pixi run example-*` でそのまま走ります（接続先は `PQ_TEST_CONNINFO`、未設定なら
ローカルのテストコンテナ）。

### 同期接続と 1 往復 — `examples/basic.mojo`

```mojo
        var conn = Connection.open(_conninfo())
        var res = conn.execute(String(SQL))
        for row in res:
            var n = row.get[Int32]("n")
            var s = row.get[String]("s")
            var z = row.get_optional[String]("z")
            print("n =", n)
            print("s =", s)
            print("z =", z.value() if z else String("NULL"))
        _ = res^
        _ = conn^
```

```bash
pixi run example-basic
```

`get[T]` は列の OID が `T` と**完全に一致**することを要求します（拡張変換は
ありません）。NULL があり得る列は `get_optional[T]` で受けます。
`_ = res^` は「ここまで生かしておく」という印で、`Result` を借りている
`Row` やスライスより後ろに置きます。

### パラメータバインド — `examples/params.mojo`

```mojo
        # One row through the connection itself, bound as $1 and $2.
        var inserted = conn.execute(String(INSERT_SQL), [Int32(1), "one"])
        _ = inserted^

        var res = conn.execute(String(SELECT_SQL), [Int32(1)])
        for row in res:
            print("id =", row.get[Int32]("id"))
            print("label =", row.get[String]("label"))
        _ = res^
```

```bash
pixi run example-params
```

値は SQL に埋め込まれず `$1`..`$n` にバインドされるので、呼び出し側が渡す
データが文そのものを変えることはありません。`Param` は対応する Mojo 型から
暗黙変換されるため、リストリテラルをそのまま渡せます。SQL NULL は
`Param.null()`（型が文から決まるとき）か `Param.null(oid)` です。

### トランザクションとセーブポイント — `examples/params.mojo`

```mojo
        # One row through the block, plus one the savepoint takes back.
        var kept: List[Param] = [Int32(2), "two"]
        var undone: List[Param] = [Int32(3), "three"]
        var tx = conn.transaction()
        var first = tx.execute(String(INSERT_SQL), kept)
        _ = first^
        tx.savepoint("sp")
        var second = tx.execute(String(INSERT_SQL), undone)
        _ = second^
        tx.rollback_to("sp")
        tx.commit()
```

`conn.transaction()` が `BEGIN` を送り、返ってきた `Transaction` は
**それを使う最後の行の直後**に破棄されます（スコープの終わりではありません）。
暗黙の `ROLLBACK` が送られるのはその位置なので、ブロックの最後は `commit()` /
`rollback()` にするか `_ = tx^` を置き、結果を `conn.execute` で確かめるのは
その**後ろ**にします。

### バイナリ形式の結果 — `examples/binary.mojo`

```mojo
        var res = conn.execute(
            String(SQL), [], result_format=ResultFormat.BINARY
        )

        # Every column arrived in binary; `get[T]` is unchanged either way.
        var format = res.column_format(0)
        print("column_format(0) =", format)

        var row = res[0]
        print("b    =", row.get[Bool]("b"))
        print("i2   =", row.get[Int16]("i2"))
        print("num  =", row.get[Decimal]("num"))
        print("ts   =", row.get[Timestamp]("ts"))
```

```bash
pixi run example-binary
```

`result_format` は**結果全体**に効きます（libpq はリクエストごとに
`resultFormat` を 1 つしか取りません）。読み出し側は変わりません:
`Row.get` が `PQfformat` を見てデコーダを選ぶので、同じ
`row.get[Int64](0)` がどちらの形式でも動きます。引数 1 つの
`execute(sql)` は `PQexec` 経由なので常にテキストです。バインドする値が
無くてもバイナリで受けたいときは、上のように `[]` を渡して
`PQexecParams` を通します。

### 非同期接続 — `examples/async_query.mojo`

```mojo
        var conn = AsyncConnection.connect_blocking(_conninfo(), 5000)
        conn.send(String(SQL))
        var polls = 0
        var results = 0
        while True:
            var got = conn.poll_result()
            if got:
                var res = got.take()
                print("n =", res[0].get[Int32]("n"))
                _ = res^
                results += 1
                continue
            if conn.state() == AsyncState.IDLE:
                break
            polls += 1
```

```bash
pixi run example-async
```

コマンドが終わるのは `poll_result` が None を返し、**かつ** `state()` が
`AsyncState.IDLE` に戻ったときです。最初の結果で抜けると、終端の None を
読まないまま接続が `BUSY` のまま残ります。予算切れは
`PgErrorKind.TIMEOUT` だけで、接続は無傷のまま使い続けられます
（`timeout_ms` は `-1` で無制限、`0` で待たずに現在の状態だけ見る）。

### `LISTEN` / `NOTIFY` — `examples/listen_notify.mojo`

```mojo
        var listener = AsyncConnection.connect_blocking(_conninfo(), 5000)
        listener.send(String("LISTEN ") + CHANNEL)
        _ = listener.fetch_all(5000)
        var sender = Connection.open(_conninfo())
        var sent = sender.execute(
            String("NOTIFY ") + CHANNEL + ", 'hello from pq'"
        )
        _ = sent^
        _ = sender^
        var note = listener.wait_notification(2000)
        if note:
            var value = note.take()
            print("channel =", value.channel)
            print("payload =", value.payload)
            print("backend_pid =", value.backend_pid)
```

```bash
pixi run example-notify
```

`LISTEN` は普通の文なので `send` / `fetch_all` で送ります。通知の受け取りは
`notifications()`（届いている分すべて。0 件もあり得る）、
`wait_notification(timeout_ms)`（1 件。予算切れは例外ではなく None）、
`wait_notifications(n, timeout_ms)`（1 つの予算で最大 n 件。予算が尽きたら
集まった分を返す）の 3 つです。1 回の呼び出しで送信済みの通知すべてが
見えるとは**どれも約束しません**。

接続に失敗したときは、例のどれも次の形を 1 レコード印字して終了コード 1 に
なります（libpq 側の文言は環境で変わるので約束しません）。

```
failed: PgError(kind=Connection, ...)
```

## 型マッピング

`Row.get[T]` / `Row.get_optional[T]` は列を `T` にデコードします。列が実際に
届いた形式（`PQfformat`）を見るので、呼び出し側は形式を気にしません。列の OID
は `T` と**完全一致**が必要で、**拡張変換はありません**: `int2` の列を
`Int32` で読むのは `TYPE_MISMATCH` です。

`String` だけは受け付ける OID が形式で変わります。テキストでは**どの OID
でも**受けて中身をそのまま返すワイルドカードですが、バイナリでは下表の
文字列系 6 つの OID だけを受けます。

| PostgreSQL | OID | Mojo 型 | テキスト形式 | バイナリ形式 |
|---|---|---|---|---|
| bool | 16 | `Bool` | `t` / `f` | 1 バイト、0 か 1 |
| int2 | 21 | `Int16` | 10 進 | 2 バイト BE |
| int4 | 23 | `Int32` | 10 進 | 4 バイト BE |
| int8 | 20 | `Int64`（`Int` でも読める） | 10 進 | 8 バイト BE |
| float4 | 700 | `Float32` | 10 進、`NaN` / `Infinity` / `-Infinity` | IEEE 754、4 バイト BE |
| float8 | 701 | `Float64` | 同じ | IEEE 754、8 バイト BE |
| numeric | 1700 | `Decimal` | 位取り記法、`NaN` / `±Infinity` | ndigits、weight、sign、dscale、その後に 10000 進の桁 |
| uuid | 2950 | `UUID` | 小文字の `8-4-4-4-12` | 16 バイト |
| date | 1082 | `Date` | `YYYY-MM-DD`、` BC` 接尾辞、`±infinity` | 2000-01-01 からの日数（int32） |
| timestamp | 1114 | `Timestamp` | `YYYY-MM-DD HH:MM:SS[.f]`、同上 | 2000-01-01 からの µs（int64） |
| timestamptz | 1184 | `TimestampTz` | 同上 + UTC オフセット | 同上、常に UTC |
| time | 1083 | `Time` | `HH:MM:SS[.f]`、`24:00:00` を含む | その日の中の µs（int64） |
| timetz | 1266 | `TimeTz` | 同上 + `±HH[:MM[:SS]]` | int64 µs + int32 のゾーン |
| interval | 1186 | `Interval` | `IntervalStyle` は `postgres` のみ | int64 µs + int32 日 + int32 月 |
| text, varchar, bpchar, name | 25, 1043, 1042, 19 | `String` | そのまま、UTF-8 を検査 | 同じ、`PQgetlength` のバイト数 |
| json | 114 | `String` | そのまま、UTF-8 を検査 | 同じ |
| jsonb | 3802 | `String` | そのまま、UTF-8 を検査 | 同じ、先頭のバージョンバイト（1）を落としてから検査 |
| bytea | 17 | `List[UInt8]` | `\x` の 16 進形式のみ | 生のバイト列 |
| 上記以外 | — | テキストでは `String`、バイナリでは無し | そのまま | `TYPE_MISMATCH`（`ResultFormat.TEXT` を指す） |

`Row.get_bytes` はこの表の外です: OID を一切見ずに届いたバイト列をそのまま
返すので、`bytea` はテキスト形式では `\x00ff00` の 8 バイト、バイナリ形式では
`00 ff 00` の 3 バイトになります。`Row.get_text` は `StringSlice`、
`get_bytes` は `Span[UInt8]` を返し、どちらも `PGresult` の記憶域を直接指す
ゼロコピーです（`PQclear` は借用した最後の使用より後ろで走ります）。

## エラー

`pq` の API はすべて `PgError` を raise し、その `kind` は**ちょうど 8 値**の
いずれかです。括弧内は `PgErrorKind.write_to` が印字する名前です。

| `kind` | 印字 | 意味 |
|---|---|---|
| `LIBPQ_LOAD` | `LibpqLoad` | libpq 自体を読み込めなかった |
| `CONNECTION` | `Connection` | 接続に失敗した、または接続がもう使えない |
| `SERVER` | `Server` | サーバーが文を拒否し診断を返した |
| `NULL_VALUE` | `NullValue` | SQL NULL を非オプショナルで要求した |
| `TYPE_MISMATCH` | `TypeMismatch` | 要求した形が結果と合わない（型・添字・名前） |
| `USAGE` | `Usage` | 呼び出し側の API 誤用。クライアント側で検出し、サーバーには何も送っていないので `sqlstate` などの診断は空 |
| `TIMEOUT` | `Timeout` | 非同期の待ちが時間切れ。接続は無傷でそのまま使える |
| `ENCODING` | `Encoding` | クライアントに届いたテキストが UTF-8 でない（`String` のセル、または通知の channel / payload）。接続も結果も無傷 |

`String` / `StringSlice` になるセルとデコーダに渡すテキストは、すべて先に
UTF-8 として検査されます。不正な並びは `invalid UTF-8 at byte N of column M`
という message の **`ENCODING`** で、セル自身のバイト列は message に入りません。
埋め込み NUL は不正では**ありません**: 長さは常に `PQgetlength` から取り、NUL
を探して決めることはないので、NUL を含む `text` 値も丸ごと届きます。

埋め込み NUL の 2 つのケースは意図的に別の kind です。`sql` テキスト中の NUL
バイトは `TYPE_MISMATCH`（libpq にそもそも渡せない引数の仲間）、`String`
パラメータの値の中の NUL バイトは `USAGE`（文は正しく、添えられたデータだけが
正しくない）です。

非同期メソッドを属さない状態で呼ぶと `USAGE` の
`<method>() called while <State>` になり、libpq に届く前に検出されます。
`timeout_ms` の受け付ける範囲は `-1 .. 2147483647` で、外れた値は黙って
折り返すのではなく `USAGE` です。

## ベンチマーク結果

**バイナリ形式はテキスト形式より decode で約 3.7 倍速い**（42 ms → 11 ms、
100,000 行 × 5 列）。**合計でも約 1.7 倍速い**（83 ms → 50 ms）。
**psycopg 3（C 実装）は** 同じ SQL のバイナリで decode 35 ms 前後なので、
decode だけを見ると Mojo 側が約 3 倍速く、合計（71 ms 前後）でも Mojo の
バイナリ（50 ms 前後）が前に出ます。

同じ SQL・同じ形式・同じ測り方（warm-up 1 回 + 計測 3 回、全セルを読む、
`autocommit`）での比較です。3 回ぶんの値を `a / b / c` で並べます。

| 実装 | 形式 | exec (ms) | decode (ms) | 合計 (ms) |
|---|---|---|---|---|
| Mojo `pq` | text | 40 / 43 / 44 | 42 / 42 / 44 | 83 / 86 / 88 |
| Mojo `pq` | binary | 38 / 39 / 39 | **12 / 11 / 11** | 50 / 50 / 51 |
| psycopg 3 | text | 40 / 42 / 42 | 44 / 45 / 41 | 84 / 87 / 83 |
| psycopg 3 | binary | 35 / 38 / 36 | 35 / 35 / 34 | 71 / 73 / 70 |

計測環境（2026-10-17）:

| 項目 | 値 |
|---|---|
| OS | Ubuntu 24.04.5 LTS |
| kernel | Linux 6.8.0-147-generic aarch64 |
| CPU / RAM | 4 コアの VM / MemTotal 16,337,280 kB |
| Mojo | 1.1.0 (8189361e) |
| libpq | 18.6（conda-forge。Mojo 側と psycopg 側で同一ビルド） |
| PostgreSQL | 17.11（Debian 17.11-1.pgdg13+2、docker） |
| psycopg | 3.3.4 + psycopg-c 3.3.4（`impl=c`）、python 3.14.8 |

再現手順:

```bash
pixi run db-up
pixi run bench            # Mojo 側（examples/bench_formats.mojo）
pixi run bench-psycopg    # psycopg 3 側（examples/bench_psycopg.py）
```

`bench-psycopg` は専用の pixi 環境 `bench` で走ります（`solve-group` が
`default` と同じなので libpq は同一ビルド）。初回だけその環境の作成が入ります。

## テストの回し方

```bash
pixi run db-up      # テスト用の PostgreSQL コンテナを起動（--wait 付き）
pixi run test       # ユニットテスト（両サーバー、リーク検査込み）
pixi run check      # 最終チェック 6 段（fmt / build / test / examples / ...）
pixi run db-reset   # フィクスチャ再適用（db-down → db-up）
pixi run db-down    # コンテナと volume を破棄
```

`tests/docker-compose.yml` が立てるのは 3 つです。

| 用途 | ポート | 中身 |
|---|---|---|
| 主サーバー | 54317 | `postgres:17` |
| 旧版サーバー | 54314 | `postgres:14` |
| blackhole | 54399 | `alpine/socat`（接続を受けたあと何も返さない。接続タイムアウトのテスト用） |

テストやサンプルの接続先は `PQ_TEST_CONNINFO` で差し替えられます。
**テストだけは `key=value ...` 形式のみ**です（`tests/run_tests.sh` が末尾に
` password=...` を付け足して「わざと間違ったパスワード」を作るため、
`postgres://` の URI では壊れた接続文字列になります）。`examples/` は値を
そのまま `PQconnectdb` に渡すので URI でも動きます。
フィクスチャが汚れたとき（テストが作った一時データベースが残っているなど）は
`pixi run db-reset` でまるごと作り直します。

## Windows の状態

**`WSAPoll` と `libpq.dll` のコードは存在しますが未検証です**（Mojo の Windows
ツールチェーン待ち）。型検査と、Linux 上でのシンボル解決を伴わないビルドは
通していますが、実機での実行は一度もしていません。

- `src/pq/_platform/poll.mojo` の `WSAPoll` 経路と `WSAGetLastError` による
  エラー分類（10009 / 10022 / 10038 → `USAGE`、他は `CONNECTION`）は、
  Microsoft のドキュメントとの照合までしか終わっていません。
- **Windows 10 2004 より前**では、TCP 接続の失敗が `WSAPoll` に通知されません
  （既知の仕様差）。非同期接続は書き込み可能を待つので、古い Windows では
  接続失敗が予算切れ（`TIMEOUT`）まで分かりません。
- `src/pq/_ffi/loader.mojo` が使う `OwnedDLHandle` の Windows 実装も未検証です。
- libpq の探索順は `LoadLibrary` に任せています（上の「libpq の探索順」参照）。

## 既知の制限

- **`client_encoding` を設定しません。** libpq の既定（データベースの
  `server_encoding`、または `PGCLIENTENCODING`）のままです。UTF-8 でない
  データベースに対しては、壊れたスライスが返るのではなく UTF-8 検査が
  `ENCODING` で失敗します。
- **`cancel` は `PQcancel` を使います。** 2 本目の短命な接続でキャンセルを
  依頼するため TLS で保護されません。キャンセルされたコマンド自身は
  `PgErrorKind.SERVER` の SQLSTATE `57014` として回収する必要があります。
- **配列型・`COPY`・コネクションプールは対象外です。** 型マッピング表に無い
  OID は、テキスト形式なら `String` として受け取れますが、バイナリ形式では
  `TYPE_MISMATCH` になります。
- `PreparedStatement.execute(params)` は `Connection.execute(sql, params)`
  より幅に厳しく、`param_type_oid(i)` が報告する幅と**同じ**値を要求します
  （`$1::int4` に `Int`（`int8`）を渡すと SQLSTATE `22P03`）。
- `pq` が `ref` を返すことはありません。オリジンはスライスと一緒に運ばれます。
- **出力先（パイプ）が先に閉じると終了コードは 141 です。** `examples/` や
  `bench` の出力を `head` などに繋いだまま読み手が閉じた場合、Mojo の `print`
  は SIGPIPE の既定動作のまま書き込むため、プロセスはシグナルで終了します
  （`cat` / `grep` と同じ Unix 標準の挙動で、`pq` 側では抑止しません）。
- `examples/bench_psycopg.py` だけは Python 公式手順（`signal` モジュールが
  "Note on SIGPIPE" で示す形。`OSError`（`BrokenPipeError`）を捕まえて fd 1 を
  `/dev/null` に向け直す）で検知するため、同じ状況で終了コード 1 を返します。
  この非対称は意図的で、それぞれの言語の既定に合わせています。

## ライセンス

Apache License 2.0。全文は [`LICENSE`](LICENSE) を参照してください。

Copyright 2026 0hya6in
