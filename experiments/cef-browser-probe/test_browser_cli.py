import base64
import contextlib
import io
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch

import browser_cli


class BrowserCLITests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ctrlx-cli-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.path = self.root / "control.sock"
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(self.server.close)
        self.server.bind(str(self.path))
        self.path.chmod(0o600)

    def test_owner_only_socket_accepted(self):
        browser_cli.validate_socket(self.path)

    def test_shared_socket_rejected(self):
        self.path.chmod(0o666)
        with self.assertRaises(ValueError):
            browser_cli.validate_socket(self.path)

    def test_shared_directory_rejected(self):
        self.root.chmod(0o755)
        with self.assertRaises(ValueError):
            browser_cli.validate_socket(self.path)

    def test_socket_symlink_rejected(self):
        link = self.root / "alias.sock"
        link.symlink_to(self.path)
        with self.assertRaises(ValueError):
            browser_cli.validate_socket(link)

    def test_non_socket_rejected(self):
        with self.assertRaises(ValueError):
            browser_cli.validate_socket(self.root)

    def test_missing_tab_is_not_inferred(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            browser_cli.parser().parse_args(["--socket", str(self.path), "read"])

    def test_unknown_command_not_forwarded(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            browser_cli.parser().parse_args(["--socket", str(self.path), "evaluate"])

    def test_screenshot_new_file_and_permissions(self):
        data = b"\x89PNG\r\n\x1a\nfixture"
        output = self.root / "capture.png"
        result = browser_cli.save_screenshot({"data": base64.b64encode(data).decode()}, output)
        self.assertEqual(output.read_bytes(), data)
        self.assertEqual(result["bytes"], len(data))
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_screenshot_never_overwrites(self):
        output = self.root / "existing"
        output.touch()
        with self.assertRaises(FileExistsError):
            browser_cli.save_screenshot({"data": base64.b64encode(b"\x89PNG\r\n\x1a\n").decode()}, output)
        self.assertEqual(output.stat().st_size, 0)

    def test_screenshot_invalid_data_creates_no_file(self):
        output = self.root / "invalid.png"
        with self.assertRaises(ValueError):
            browser_cli.save_screenshot({"data": "YQ=="}, output)
        self.assertFalse(output.exists())

    def test_input_forwarded_exactly_and_not_submitted(self):
        text = "中文 ' \" \\ line\nsecond"
        with patch.object(browser_cli, "request", return_value={}) as call, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(browser_cli.main(["--socket", str(self.path), "type", "--tab", "A",
                                              "--selector", "#field", "--text", text]), 0)
        self.assertEqual(call.call_args.args[1], {"command": "type", "tab": "A", "selector": "#field", "text": text})

    def test_failure_returns_error_and_does_not_retry(self):
        with patch.object(browser_cli, "request", side_effect=TimeoutError("timeout")) as call:
            with contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertEqual(browser_cli.main(["--socket", str(self.path), "tabs"]), 1)
        self.assertEqual(call.call_count, 1)
        self.assertFalse(json.loads(output.getvalue())["ok"])


if __name__ == "__main__":
    unittest.main()
