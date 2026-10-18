#!/usr/bin/env python3
"""CHANGELOG.md から 1 バージョン分の節を抜き出して stdout に出す。

    python3 .github/scripts/release-notes.py <version>

`## [<version>]` 見出しの次の行から、次の `## [` 見出しまたは
`[x.y.z]: <url>` 形式のリンク定義行の手前までが対象（前後の空行は落とす）。
GitHub Release の本文（`gh release create --notes-file`）に使う。

節が見つからない / 本文が空なら stderr にメッセージを出して rc 1。
標準ライブラリのみ（re / sys / pathlib）。
"""

import re
import sys
from pathlib import Path

CHANGELOG = Path(__file__).resolve().parents[2] / "CHANGELOG.md"

# ファイル末尾のリンク定義行（`[0.1.0]: https://...`）。節の終端のひとつ。
LINK_DEF = re.compile(r"^\[[^\]]+\]:\s")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: release-notes.py <version>", file=sys.stderr)
        return 1
    version = sys.argv[1]

    if not CHANGELOG.is_file():
        print("release-notes.py: %s not found" % CHANGELOG, file=sys.stderr)
        return 1

    lines = CHANGELOG.read_text(encoding="utf-8").splitlines()
    heading = "## [%s]" % version

    start = None
    for i, line in enumerate(lines):
        if line.startswith(heading):
            start = i + 1
            break
    if start is None:
        print(
            "release-notes.py: no %s section in %s" % (heading, CHANGELOG.name),
            file=sys.stderr,
        )
        return 1

    body = []
    for line in lines[start:]:
        if line.startswith("## [") or LINK_DEF.match(line):
            break
        body.append(line)

    # 見出し直後と節末の空行を落とす（先頭が `### Added` から始まるように）。
    while body and not body[0].strip():
        body.pop(0)
    while body and not body[-1].strip():
        body.pop()

    if not body:
        print(
            "release-notes.py: %s section in %s is empty"
            % (heading, CHANGELOG.name),
            file=sys.stderr,
        )
        return 1

    print("\n".join(body))
    return 0


if __name__ == "__main__":
    sys.exit(main())
