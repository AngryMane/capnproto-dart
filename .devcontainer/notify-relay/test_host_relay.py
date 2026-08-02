#!/usr/bin/env python3
"""Unit tests for host_relay.py and claude_approval_notify.py.

Pure-logic tests only — nothing here calls the real notify-send binary or
opens a socket. Run with:

    python3 -m unittest discover -s .devcontainer/notify-relay -p 'test_*.py' -v
"""

import subprocess
import unittest
from unittest.mock import patch

import claude_approval_notify
import host_relay


class ValidateRequestTests(unittest.TestCase):
    def test_title_and_body_only(self):
        title, body, actions = host_relay.validate_request(
            {"title": "t", "body": "b"}
        )
        self.assertEqual((title, body, actions), ("t", "b", []))

    def test_missing_title_or_body_rejected(self):
        with self.assertRaises(ValueError):
            host_relay.validate_request({"title": "t"})
        with self.assertRaises(ValueError):
            host_relay.validate_request({"body": "b"})

    def test_unknown_field_rejected(self):
        with self.assertRaises(ValueError):
            host_relay.validate_request({"title": "t", "body": "b", "extra": 1})

    def test_empty_or_overlong_title_rejected(self):
        with self.assertRaises(ValueError):
            host_relay.validate_request({"title": "", "body": "b"})
        with self.assertRaises(ValueError):
            host_relay.validate_request(
                {"title": "x" * (host_relay.MAX_TITLE_LENGTH + 1), "body": "b"}
            )

    def test_overlong_body_rejected(self):
        with self.assertRaises(ValueError):
            host_relay.validate_request(
                {"title": "t", "body": "x" * (host_relay.MAX_BODY_LENGTH + 1)}
            )

    def test_single_action(self):
        title, body, actions = host_relay.validate_request(
            {
                "title": "t",
                "body": "b",
                "actions": [{"id": "allow", "label": "Approve"}],
            }
        )
        self.assertEqual(actions, [("allow", "Approve")])

    def test_max_actions_allowed(self):
        actions_in = [
            {"id": f"a{i}", "label": f"L{i}"}
            for i in range(host_relay.MAX_ACTIONS)
        ]
        _, _, actions = host_relay.validate_request(
            {"title": "t", "body": "b", "actions": actions_in}
        )
        self.assertEqual(len(actions), host_relay.MAX_ACTIONS)

    def test_too_many_actions_rejected(self):
        actions_in = [
            {"id": f"a{i}", "label": f"L{i}"}
            for i in range(host_relay.MAX_ACTIONS + 1)
        ]
        with self.assertRaises(ValueError):
            host_relay.validate_request(
                {"title": "t", "body": "b", "actions": actions_in}
            )

    def test_duplicate_action_ids_rejected(self):
        with self.assertRaises(ValueError):
            host_relay.validate_request(
                {
                    "title": "t",
                    "body": "b",
                    "actions": [
                        {"id": "allow", "label": "A"},
                        {"id": "allow", "label": "B"},
                    ],
                }
            )

    def test_action_id_with_bad_characters_rejected(self):
        with self.assertRaises(ValueError):
            host_relay.validate_request(
                {
                    "title": "t",
                    "body": "b",
                    "actions": [{"id": "allow=evil", "label": "A"}],
                }
            )

    def test_action_missing_field_rejected(self):
        with self.assertRaises(ValueError):
            host_relay.validate_request(
                {"title": "t", "body": "b", "actions": [{"id": "allow"}]}
            )

    def test_action_empty_label_rejected(self):
        with self.assertRaises(ValueError):
            host_relay.validate_request(
                {
                    "title": "t",
                    "body": "b",
                    "actions": [{"id": "allow", "label": ""}],
                }
            )

    def test_action_overlong_id_or_label_rejected(self):
        with self.assertRaises(ValueError):
            host_relay.validate_request(
                {
                    "title": "t",
                    "body": "b",
                    "actions": [
                        {
                            "id": "a" * (host_relay.MAX_ACTION_ID_LENGTH + 1),
                            "label": "A",
                        }
                    ],
                }
            )
        with self.assertRaises(ValueError):
            host_relay.validate_request(
                {
                    "title": "t",
                    "body": "b",
                    "actions": [
                        {
                            "id": "allow",
                            "label": "L" * (host_relay.MAX_ACTION_LABEL_LENGTH + 1),
                        }
                    ],
                }
            )


class ShowNotificationTests(unittest.TestCase):
    def _run(self, actions, returncode=0, stdout="", stderr=""):
        completed = subprocess.CompletedProcess(
            args=["notify-send"], returncode=returncode, stdout=stdout, stderr=stderr
        )
        with patch("host_relay.subprocess.run", return_value=completed) as run:
            result = host_relay.show_notification("title", "body", actions)
        return result, run

    def test_no_actions_never_waits_and_returns_none(self):
        result, run = self._run(actions=[])
        self.assertIsNone(result)
        self.assertNotIn("--wait", run.call_args.args[0])

    def test_action_clicked_is_resolved(self):
        result, _ = self._run(
            actions=[("allow", "Approve"), ("deny", "Deny")], stdout="allow\n"
        )
        self.assertEqual(result, "allow")

    def test_unknown_stdout_resolves_to_none(self):
        result, _ = self._run(
            actions=[("allow", "Approve"), ("deny", "Deny")], stdout="something-else"
        )
        self.assertIsNone(result)

    def test_empty_stdout_dismissed_or_expired_resolves_to_none(self):
        result, _ = self._run(
            actions=[("allow", "Approve"), ("deny", "Deny")], stdout=""
        )
        self.assertIsNone(result)

    def test_nonzero_returncode_raises(self):
        with self.assertRaises(RuntimeError):
            self._run(actions=[], returncode=1, stderr="cannot connect to bus")

    def test_interactive_command_includes_wait_and_actions(self):
        _, run = self._run(actions=[("allow", "Approve"), ("deny", "Deny")])
        command = run.call_args.args[0]
        self.assertIn("--wait", command)
        self.assertIn("--action=allow=Approve", command)
        self.assertIn("--action=deny=Deny", command)


class BuildTitleAndBodyTests(unittest.TestCase):
    def test_bash_command_shown_verbatim_when_short(self):
        title, body, truncated = claude_approval_notify.build_title_and_body(
            {"tool_name": "Bash", "tool_input": {"command": "echo hi"}}
        )
        self.assertFalse(truncated)
        self.assertIn("echo hi", body)

    def test_long_command_is_flagged_truncated(self):
        long_command = "echo " + "x" * 400
        _, body, truncated = claude_approval_notify.build_title_and_body(
            {"tool_name": "Bash", "tool_input": {"command": long_command}}
        )
        self.assertTrue(truncated)
        self.assertLessEqual(
            len(body), len("Bash\n") + claude_approval_notify.MAX_DETAIL_LENGTH + 1
        )

    def test_webfetch_shows_url(self):
        _, body, truncated = claude_approval_notify.build_title_and_body(
            {"tool_name": "WebFetch", "tool_input": {"url": "https://example.com"}}
        )
        self.assertFalse(truncated)
        self.assertIn("https://example.com", body)


class SendNotificationActionAllowlistTests(unittest.TestCase):
    def _client_response(self, payload):
        class FakeClient:
            def __init__(self, response_bytes):
                self._response = response_bytes

            def settimeout(self, _):
                pass

            def connect(self, _):
                pass

            def sendall(self, _):
                pass

            def shutdown(self, _):
                pass

            def recv(self, _):
                response, self._response = self._response, b""
                return response

            def close(self):
                pass

        return FakeClient(payload)

    def test_unexpected_action_from_relay_is_not_trusted(self):
        # Even if the relay ever echoed back something we didn't offer, the
        # hook must not treat it as a decision.
        import json as _json

        fake = self._client_response(
            _json.dumps({"ok": True, "action": "something-unexpected"}).encode()
        )
        with patch("claude_approval_notify.socket.socket", return_value=fake):
            action = claude_approval_notify.send_notification(
                "t", "b", actions=[{"id": "allow", "label": "A"}]
            )
        self.assertIsNone(action)

    def test_relay_failure_resolves_to_none(self):
        import json as _json

        fake = self._client_response(
            _json.dumps({"ok": False, "error": "boom"}).encode()
        )
        with patch("claude_approval_notify.socket.socket", return_value=fake):
            action = claude_approval_notify.send_notification(
                "t", "b", actions=[{"id": "allow", "label": "A"}]
            )
        self.assertIsNone(action)


if __name__ == "__main__":
    unittest.main()
