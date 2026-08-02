#!/usr/bin/env python3
"""Host-side desktop notification relay for the capnproto-dart devcontainer.

Listens on a Unix domain socket and shows a notify-send popup for each
request. This is the only host capability exposed to the container for
notifications — the container never touches the host's D-Bus session bus
directly, only this narrow title/body protocol.
"""

import json
import os
import re
import socket
import subprocess
import sys
import threading
from pathlib import Path
from typing import Any

MAX_REQUEST_SIZE = 8 * 1024
MAX_TITLE_LENGTH = 128
MAX_BODY_LENGTH = 2048
MAX_ACTIONS = 4
MAX_ACTION_ID_LENGTH = 32
MAX_ACTION_LABEL_LENGTH = 32
ACTION_ID_RE = re.compile(r"^[A-Za-z0-9_-]+$")

# How long an interactive (actions=[...]) notification stays on screen and
# waits for a click, in milliseconds/seconds respectively. A plain
# title/body notification (no actions) never waits and ignores these.
WAIT_EXPIRE_MS = 100_000
WAIT_SUBPROCESS_TIMEOUT = 105

# Each connection is handled on its own thread (a plain notification
# shouldn't queue up behind an interactive one that's waiting on a click),
# capped so a burst of requests can't spawn unbounded notify-send processes.
MAX_CONCURRENT_NOTIFICATIONS = 4


def validate_action(value: Any) -> tuple[str, str]:
    if not isinstance(value, dict) or set(value) != {"id", "label"}:
        raise ValueError("each action needs exactly id and label")

    action_id = value["id"]
    label = value["label"]

    if not isinstance(action_id, str) or not ACTION_ID_RE.fullmatch(action_id):
        raise ValueError("action id must match [A-Za-z0-9_-]+")

    if len(action_id) > MAX_ACTION_ID_LENGTH:
        raise ValueError("action id is too long")

    if not isinstance(label, str) or not label or len(label) > MAX_ACTION_LABEL_LENGTH:
        raise ValueError("invalid action label")

    return action_id, label


def validate_request(value: Any) -> tuple[str, str, list[tuple[str, str]]]:
    if not isinstance(value, dict):
        raise ValueError("request must be an object")

    if not {"title", "body"} <= set(value) or set(value) - {"title", "body", "actions"}:
        raise ValueError("only title, body, and optionally actions are accepted")

    title = value["title"]
    body = value["body"]

    if not isinstance(title, str) or not isinstance(body, str):
        raise ValueError("title and body must be strings")

    if not title or len(title) > MAX_TITLE_LENGTH:
        raise ValueError("invalid title length")

    if len(body) > MAX_BODY_LENGTH:
        raise ValueError("body is too long")

    raw_actions = value.get("actions", [])
    if not isinstance(raw_actions, list) or len(raw_actions) > MAX_ACTIONS:
        raise ValueError(f"actions must be a list of at most {MAX_ACTIONS} items")

    actions = [validate_action(action) for action in raw_actions]
    if len({action_id for action_id, _ in actions}) != len(actions):
        raise ValueError("action ids must be unique")

    return title, body, actions


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


def show_notification(
    title: str, body: str, actions: list[tuple[str, str]]
) -> str | None:
    """Show a notification, returning the id of the action clicked, or None
    if there were no actions, or it was dismissed/expired without one."""
    command = ["/usr/bin/notify-send", "--app-name=Dev Container"]

    if actions:
        command += ["--wait", f"--expire-time={WAIT_EXPIRE_MS}"]
        command += [f"--action={action_id}={label}" for action_id, label in actions]

    command += ["--", title, body]

    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=WAIT_SUBPROCESS_TIMEOUT if actions else 5,
    )

    # A returncode is a real failure (can't reach the notification daemon, a
    # bad notify-send invocation, etc.) — not the same thing as the user
    # simply not choosing an action, which still exits 0 with empty stdout.
    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip() or f"notify-send exited with {result.returncode}"
        )

    if not actions:
        return None

    clicked = result.stdout.strip()
    valid_ids = {action_id for action_id, _ in actions}
    resolved = clicked if clicked in valid_ids else None

    # Log shape, not content: title/body/action labels can carry shell
    # commands, file paths, or other request-specific detail that shouldn't
    # sit in the systemd journal indefinitely.
    print(
        f"[notify] actions={len(actions)} resolved_action={resolved!r}",
        file=sys.stderr,
    )

    return resolved


def handle_connection(
    connection: socket.socket, notification_slots: threading.Semaphore
) -> None:
    with connection:
        connection.settimeout(5)
        try:
            raw = receive_request(connection)
            request = json.loads(raw.decode("utf-8"))
            title, body, actions = validate_request(request)

            with notification_slots:
                clicked = show_notification(title, body, actions)

            response = json.dumps({"ok": True, "action": clicked}).encode("utf-8")
        except Exception as error:
            response = json.dumps({"ok": False, "error": str(error)}).encode("utf-8")

        try:
            connection.sendall(response)
        except OSError:
            # Client already disconnected (e.g. hit its own timeout) —
            # nothing to do, and no need to let this take down the relay.
            pass


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

    # A connection waiting on an interactive notification's click shouldn't
    # block a concurrent plain notification (or another interactive one) —
    # each connection runs on its own thread, capped by this semaphore.
    notification_slots = threading.Semaphore(MAX_CONCURRENT_NOTIFICATIONS)

    try:
        while True:
            connection, _ = server.accept()
            thread = threading.Thread(
                target=handle_connection,
                args=(connection, notification_slots),
                daemon=True,
            )
            thread.start()
    finally:
        server.close()

        try:
            socket_path.unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
