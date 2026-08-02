#!/usr/bin/env python3
"""Host-side desktop notification relay for the capnproto-dart devcontainer.

Listens on a Unix domain socket and shows a notify-send popup for each
request. This is the only host capability exposed to the container for
notifications — the container never touches the host's D-Bus session bus
directly, only this narrow title/body protocol.
"""

import json
import os
import socket
import subprocess
import sys
from pathlib import Path
from typing import Any

MAX_REQUEST_SIZE = 8 * 1024
MAX_TITLE_LENGTH = 128
MAX_BODY_LENGTH = 2048


def validate_request(value: Any) -> tuple[str, str]:
    if not isinstance(value, dict):
        raise ValueError("request must be an object")

    if set(value) != {"title", "body"}:
        raise ValueError("only title and body are accepted")

    title = value["title"]
    body = value["body"]

    if not isinstance(title, str) or not isinstance(body, str):
        raise ValueError("title and body must be strings")

    if not title or len(title) > MAX_TITLE_LENGTH:
        raise ValueError("invalid title length")

    if len(body) > MAX_BODY_LENGTH:
        raise ValueError("body is too long")

    return title, body


def receive_request(connection: socket.socket) -> bytes:
    chunks: list[bytes] = []
    total = 0

    while True:
        chunk = connection.recv(4096)
        if not chunk:
            break

        total += len(chunk)
        if total > MAX_REQUEST_SIZE:
            raise ValueError("request is too large")

        chunks.append(chunk)

    return b"".join(chunks)


def show_notification(title: str, body: str) -> None:
    subprocess.run(
        [
            "/usr/bin/notify-send",
            "--app-name=Dev Container",
            "--",
            title,
            body,
        ],
        check=False,
        timeout=5,
    )


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} SOCKET_PATH", file=sys.stderr)
        return 2

    socket_path = Path(sys.argv[1])
    socket_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)

    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(socket_path))
    os.chmod(socket_path, 0o600)
    server.listen(8)

    try:
        while True:
            connection, _ = server.accept()

            with connection:
                try:
                    raw = receive_request(connection)
                    request = json.loads(raw.decode("utf-8"))
                    title, body = validate_request(request)
                    show_notification(title, body)
                    connection.sendall(b'{"ok":true}')
                except Exception as error:
                    response = json.dumps(
                        {"ok": False, "error": str(error)}
                    ).encode("utf-8")
                    connection.sendall(response)
    finally:
        server.close()

        try:
            socket_path.unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
