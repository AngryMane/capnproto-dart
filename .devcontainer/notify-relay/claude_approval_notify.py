#!/usr/bin/env python3
"""Claude Code PermissionRequest hook that offers Approve/Deny directly from
a host desktop notification, via the relay in this directory.

Wire it up in your own (personal, gitignored) .claude/settings.json:

    {
      "hooks": {
        "PermissionRequest": [
          {
            "matcher": ".*",
            "hooks": [
              {
                "type": "command",
                "command": "\"${CLAUDE_PROJECT_DIR}/.devcontainer/notify-relay/claude_approval_notify.py\"",
                "timeout": 120
              }
            ]
          }
        ]
      }
    }

See CONTRIBUTING.md for the full explanation.
"""

import json
import socket
import sys

NOTIFY_SOCKET_PATH = "/run/host-notify/notify.sock"

# The notification body only shows this many characters of the tool detail
# (command/URL/query). If the real detail is longer than that, the
# notification can't show the whole thing — including something dangerous
# past the cut — so we skip the one-click actions entirely rather than
# risk an Approve on a command the user didn't fully see. Claude Code's own
# in-app prompt (which shows the full detail) is the fallback in that case.
MAX_DETAIL_LENGTH = 300

# Must stay under the relay's own wait budget (WAIT_EXPIRE_MS / 1000 +
# WAIT_SUBPROCESS_TIMEOUT in host_relay.py) so we hear back before giving up,
# and under this hook's "timeout" in .claude/settings.json so Claude Code
# doesn't kill us first. A plain (no-actions) notification never waits this
# long — the relay resolves those immediately — but we use one timeout for
# both since the socket round-trip either way is what we're bounding.
SOCKET_TIMEOUT_SECONDS = 110

ALLOW_ACTION = "allow"
DENY_ACTION = "deny"


def send_notification(
    title: str, body: str, actions: list[dict[str, str]]
) -> str | None:
    """Show a notification on the host. If actions were given, return which
    one was clicked ("allow"/"deny"), or None if it was dismissed, timed
    out, or the relay is unreachable — in every None case the caller should
    fall back to Claude Code's normal permission prompt rather than decide
    anything itself."""
    request: dict[str, object] = {"title": title, "body": body}
    if actions:
        request["actions"] = actions

    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(SOCKET_TIMEOUT_SECONDS)
        client.connect(NOTIFY_SOCKET_PATH)
        client.sendall(json.dumps(request).encode("utf-8"))
        client.shutdown(socket.SHUT_WR)

        chunks = []
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
        client.close()

        result = json.loads(b"".join(chunks).decode("utf-8"))
        if not result.get("ok"):
            return None

        action = result.get("action")
        # Explicit allowlist: only ever treat a click as a decision if it's
        # exactly one of the ids we offered. Anything else (including a
        # relay bug that echoes back something unexpected) falls through to
        # the normal prompt instead of being trusted.
        return action if action in (ALLOW_ACTION, DENY_ACTION) else None
    except OSError:
        return None


def build_title_and_body(request: dict) -> tuple[str, str, bool]:
    """Returns (title, body, truncated) for a PermissionRequest hook input."""
    tool_name = request.get("tool_name", "Unknown")
    tool_input = request.get("tool_input", {})

    if tool_name == "WebFetch":
        detail = tool_input.get("url", "")
    elif tool_name == "WebSearch":
        detail = tool_input.get("query", "")
    elif tool_name == "Bash":
        detail = tool_input.get("command", "")
    else:
        detail = json.dumps(tool_input, ensure_ascii=False)

    flattened = " ".join(detail.splitlines())
    truncated = len(flattened) > MAX_DETAIL_LENGTH
    detail = flattened[:MAX_DETAIL_LENGTH] + ("…" if truncated else "")

    title = "Claude Code: 承認が必要です"
    body = f"{tool_name}\n{detail}"
    return title, body, truncated


def main() -> int:
    request = json.load(sys.stdin)

    # PermissionRequest hook: tool_name/tool_input, same shape as PreToolUse.
    # (The Notification hook's documented permission_prompt matcher didn't
    # actually fire for permission prompts raised through the Claude Code
    # VS Code extension — PermissionRequest does.)
    title, body, truncated = build_title_and_body(request)

    if truncated:
        # Can't show the full command/target, so don't offer a one-click
        # Approve for it — just alert, and let Claude Code's own prompt
        # (which shows the untruncated detail) handle the actual decision.
        send_notification(title, body, actions=[])
        return 0

    action = send_notification(
        title,
        body,
        actions=[
            {"id": ALLOW_ACTION, "label": "承認"},
            {"id": DENY_ACTION, "label": "拒否"},
        ],
    )

    if action == ALLOW_ACTION:
        print(
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow"},
                    }
                }
            )
        )
    elif action == DENY_ACTION:
        print(
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "deny",
                            "message": "Denied via desktop notification",
                        },
                    }
                }
            )
        )
    # else: no decision — Claude Code falls back to its normal permission
    # prompt, exactly as if this hook didn't exist.

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
