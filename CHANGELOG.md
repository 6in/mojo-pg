# 変更履歴

このファイルには、このプロジェクトの注目すべき変更をすべて記録します。

形式は [Keep a Changelog 1.1.0](https://keepachangelog.com/ja/1.1.0/) に従い、
バージョン番号は [Semantic Versioning](https://semver.org/lang/ja/)（セマンティック バージョニング）に従います。

## [Unreleased]

## [0.1.0] - 2026-10-18

### Added

- Phase 1: Mojo 1.1.0 から libpq を実行時ロードする C FFI バインディングと、同期接続 `Connection`。テキスト形式でクエリを実行し、基本型を型安全に取得できる最小のライブラリ `pq`。
- Phase 2: `PQexecParams` による `$1` 形式のパラメータ付き実行（`Param`）、`PQprepare` / `PQexecPrepared` を使うプリペアドステートメント（`PreparedStatement`）、BEGIN / COMMIT / ROLLBACK とセーブポイントを扱う `Transaction`。
- Phase 3: バイナリ結果形式のデコードに対応し、numeric / date / time / timetz / timestamp / timestamptz / interval / uuid / json / jsonb を含む 19 の型をテキスト・バイナリ両形式で `Row.get[T]` から取得できるようにした。同じ型はパラメータとしても送信できる。
- Phase 4: libpq の非ブロッキング API を明示的に進める `AsyncConnection`。非同期接続、クエリ送信と結果受信、キャンセル、`LISTEN` / `NOTIFY` を OS のソケット poll（`_platform/poll`）と同じスレッドで組み合わせられる。Mojo 言語の `async` には依存しない。
- Phase 5: text と binary を比較する `pixi run bench` に加えて psycopg 3 と比較する `pixi run bench-psycopg` を追加し、結果を README に記録。日本語 README（概要と対応環境、インストール、ベンチマーク）、Apache-2.0 の LICENSE、`examples/` 7 本の総点検を行った。

[Unreleased]: https://github.com/6in/mojo-pg/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/6in/mojo-pg/releases/tag/v0.1.0
