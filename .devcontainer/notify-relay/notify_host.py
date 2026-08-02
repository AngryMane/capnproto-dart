#!/usr/bin/env python3
"""Send a desktop notification from inside the devcontainer to the host.

Talks to the relay started on the host by start_host_relay.sh over the
Unix socket bind-mounted read-only at /run/host-notify/notify.sock.
"""

import json
import socket
import sys

SOCKET_PATH = "/run/host-notify/notify.sock"


def main() -> int:
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} TITLE [BODY]", file=sys.stderr)
        return 2

    title = sys.argv[1]
    body = sys.argv[2] if len(sys.argv) >= 3 else ""

    request = json.dumps(
        {"title": title, "body": body},
        ensure_ascii=False,
    ).encode("utf-8")

    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)

    try:
        client.settimeout(5)
        client.connect(SOCKET_PATH)
        client.sendall(request)
        client.shutdown(socket.SHUT_WR)

        response = client.recv(4096)
        result = json.loads(response.decode("utf-8"))

        if not result.get("ok"):
            print(result.get("error", "notification failed"), file=sys.stderr)
            return 1

        return 0
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
