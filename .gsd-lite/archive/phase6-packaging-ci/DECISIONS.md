# DECISIONS — phase6-packaging-ci

## D1. slug は `phase6-packaging-ci`
- **選択**: HANDOFF の Phase 1〜5 の続番で揃える（archive の並びも phase 順）
- **却下**: `packaging-ci`（番号なし）／`release-0-1-0`（リリースを主目的と位置づける名前）

## D2. 配布物は conda パッケージ（pixi build）+ GitHub Release + ソース利用手順
- **選択**: `pixi.toml` に `[package]` + pixi-build-mojo を足して `.conda` を作る。タグから GitHub Release を作ってソース tarball と `.conda` を添付。
  README の「自分のプロジェクトから使う」を pixi 依存指定で拡充
- **却下**: modular-community への recipe 提出（外部リポジトリへの PR が必要で人間の作業になる。今回は採らない）
- **注意**: pixi-build は preview 機能。Mojo 1.1.0 との相性・`mojo-compiler` の pin 方法は research のプローブで実在を確かめてから plan する
  （Phase 5 reflect の提案「採る前に research のプローブ 1 本で実在を確かめる」）

## D3. CI マトリクスは Linux x86_64 + Linux aarch64 + macOS arm64
- **選択**: pixi.toml の platforms 3 つ全部。公開リポジトリなので `ubuntu-latest` / `ubuntu-24.04-arm` / `macos-latest` はいずれも無料枠
- **却下**: Linux のみ（HANDOFF §2「macOS は CI 必須」に反する）／x86_64 のみ

## D4. 持ち越しは SIGPIPE rc 141 と `_collect_notifications` の `out` 復元を同梱、Windows は採らない
- **選択**: 小規模 2 件を同梱して Phase 5 の残留リスクを消す。Windows はツールチェーンが無いので実機は不可
- **却下**: 「Phase N+1 が引き取る」と書いたまま持ち越す（Phase 5 reflect の指摘）

## D5. macOS ジョブは Homebrew の PostgreSQL 1 本で DB テストまで回す
- **選択**: macOS ランナーに Docker が無いので、`brew` の PostgreSQL（17 系）をジョブ内で起動して `PQ_TEST_CONNINFO` で指す。PG 14 は Linux だけで回す。
  blackhole は `socat` / `nc` で代替、無理なら接続タイムアウトのテストだけ SKIP
- **却下**: DB を使わないステージだけ（macOS の実行が未検証のまま）／速いジョブと DB 付きジョブの 2 本（構成が増える）

## D6. Linux のゲートは `pixi run check` をそのまま 1 ジョブ
- **選択**: ローカルと CI の判定を同じスクリプトに揃える（単一の真実）。PR と main push の両方で走らせる。所要は 1 ジョブ 5〜8 分見込み
- **却下**: lint / テストのジョブ分割（final_check.sh にフラグが要る）／PR は lint のみ（マージ前に DB テストが走らない）
- **付随（discuss の判断）**: CI ジョブで `pixi build` も走らせて `.conda` を artifact に置く。タグを使わずにリリース経路のビルド部分を毎 PR で検証できる

## D7. リリースはワークフロー整備まで。タグは人間が打つ
- **選択**: `v*` タグで動く release ワークフローを置き、動作確認はタグを使わない経路で行う。v0.1.0 のタグと Release はマージ後に人間が行う。
  無人ターンが外向きの公開操作（タグ push / Release 作成）をしない
- **却下**: マイルストーン内で v0.1.0 を切る（失敗時のタグ削除が要る）／Release を作らず artifact だけ（恒久的な配布 URL が無い）

## D8. verify は PR 作成 + PR 上の CI 緑を合格条件にする
- **選択**: リモートがあるので gsd-lite-verify の仕様どおり push + PR。CI がこのマイルストーンの成果物なので、PR 上で緑になることが最終検証。マージは人間
- **却下**: PR 作成まで（CI が赤でも DONE になる）／従来どおりローカルマージ（verify の自動判定を上書きする記述が要る）

## D9. 堅牢性の受け入れ基準を入れる
- **選択**: timeout-minutes / DB 起動待ちの上限 / セットアップのリトライ / secrets 不要（fork PR でも動く）/ permissions 最小。flaky な赤を最初から潰す
- **却下**: 入れない（まず動くことを優先）

## D10. conda パッケージ名は `pq`
- **選択**: import 名と一致させる。research で conda-forge / modular-community の同名を確認し、衝突があれば `mojo-pq` に落とす
- **却下**: `mojo-pg`（リポジトリ名と一致するが import 名と違う）／`mojo-pq`（衝突が無ければ不要な接頭辞）

## D11. README は日本語のまま、英語は概要 + インストール節だけ
- **選択**: 先頭近くに英語の短い概要とインストール（pixi 依存指定）を置く。翻訳コストが小さい
- **却下**: README.en.md 全訳（二重管理）／日本語のみ

## D12. CHANGELOG.md を作り Release 本文に使う
- **選択**: Keep a Changelog 形式。0.1.0 の節に Phase 1〜5 の成果を要約。release ワークフローが該当版の節を本文にする
- **却下**: GitHub の自動生成ノートだけ／両方の連結

## D13. ブランチ保護は手順を書くだけ。設定は人間
- **選択**: リポジトリ設定の変更は外向きの操作なので無人ターンにやらせない。README に `gh api` / 画面での手順を書く
- **却下**: impl が `gh api` で設定（間違えると verify 自身の PR に影響）／やらない

## D14. 実行パターンは現在の設定を維持
- **選択**: 全フェーズ Claude（`engine: claude`, `phase_engines: {}`）。model は research / plan / verify / reflect = claude-fable-5-1、impl = claude-opus-5。
  `reflect: true`。research の対象は official_docs + similar_oss（local_projects は Mojo の前例が薄いので外す）
- **却下**: impl を Codex（sandbox の検証が要る）／impl も fable-5-1（コスト増）

## D15. 無人ターンの外向き操作の線引き
- **選択**: 許可するのはマイルストーンブランチの push と PR の作成・更新のみ。タグ・Release・リポジトリ設定・main push は人間
- **理由**: CI がこのマイルストーンの成果物なので PR 上で動かす必要がある一方、公開状態を変える操作は取り消しが難しい
