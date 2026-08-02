#!/usr/bin/env python3
"""Send a desktop notification to the host from inside the devcontainer.

Talks to the relay started by start_host_relay.sh over the Unix socket
bind-mounted read-only at /run/host-notify/notify.sock (see host_relay.py
for the protocol: a single {"title": ..., "body": ...} JSON object).

Usage: notify-host TITLE BODY
"""

import json
import socket
import sys

NOTIFY_SOCKET_PATH = "/run/host-notify/notify.sock"


def send_notification(title: str, body: str) -> None:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(5)
    client.connect(NOTIFY_SOCKET_PATH)
    client.sendall(json.dumps({"title": title, "body": body}).encode("utf-8"))
    client.shutdown(socket.SHUT_WR)

    response = json.loads(client.recv(4096).decode("utf-8"))
    client.close()

    if not response.get("ok"):
        raise RuntimeError(response.get("error", "relay rejected the request"))


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} TITLE BODY", file=sys.stderr)
        return 2

    _, title, body = sys.argv

    try:
        send_notification(title, body)
    except OSError as error:
        print(f"could not reach the host notification relay: {error}", file=sys.stderr)
        return 1
    except RuntimeError as error:
        print(f"host notification relay rejected the request: {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
