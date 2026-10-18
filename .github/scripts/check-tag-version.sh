#!/usr/bin/env bash
# check-tag-version.sh — リリースタグが pixi.toml の version と一致するか検査する。
#
#   bash .github/scripts/check-tag-version.sh <tag>
#
# <tag> は `v` + バージョン（例 `v0.1.0`）。`v` を剥がした文字列が
# `pixi workspace version get` の出力と一致すれば rc 0、しなければ stderr に
# 理由を出して rc 1。`v` が無いタグは不一致として扱う（`on.push.tags: ["v*"]`
# なのでワークフローには届かないが、境界値として明示的に落とす）。
#
# version の出所は pixi.toml の `[workspace] version` 1 行だけ
# （`[package]` 側は `version = { workspace = true }` で継承している）。
#
# bash 3.2 互換（macOS ランナーの bash は 3.2.57）。
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: check-tag-version.sh <tag>" >&2
  exit 2
fi

tag="$1"

case "$tag" in
  v*) ;;
  *)
    echo "tag $tag must start with \"v\" (expected form: v<version>)" >&2
    exit 1
    ;;
esac

version="$(pixi workspace version get)"
tag_version="${tag#v}"

if [ "$tag_version" != "$version" ]; then
  echo "tag $tag != pixi.toml version $version" >&2
  exit 1
fi

echo "tag $tag matches pixi.toml version $version"
