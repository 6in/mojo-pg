#!/usr/bin/env python3
"""accept した接続を閉じずに保持し続けるだけのサーバ（接続タイムアウト試験用）。

    python3 .github/scripts/blackhole.py <port>

accept したソケットは `held` に積んで保持し続ける。閉じると相手側が EOF を
受け取ってしまい、タイムアウト試験にならない。応答は一切書かない。
標準ライブラリのみ（socket / sys）。
"""

import socket
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: blackhole.py <port>", file=sys.stderr)
        return 1
    try:
        port = int(sys.argv[1])
    except ValueError:
        print("blackhole.py: port must be a number: %s" % sys.argv[1], file=sys.stderr)
        return 1

    held = []

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", port))
    server.listen(16)
    print("blackhole: listening on 127.0.0.1:%d" % port, file=sys.stderr, flush=True)

    while True:
        conn, addr = server.accept()
        # 閉じない / 何も書かない。参照を held に持ち続けるだけ。
        held.append(conn)
        print(
            "blackhole: holding %d connection(s), last from %s" % (len(held), addr),
            file=sys.stderr,
            flush=True,
        )


if __name__ == "__main__":
    sys.exit(main())
