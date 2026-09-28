#!/usr/bin/env python3
"""Bundled skills: size/link budgets, packaging and isolated protocol examples.

Run: python3 scripts/tests/test_agent_skills.py
Optional CLI override: CTRLX_SKILL_TEST_CLI=/path/to/CtrlXCLI
Never connects to a live CtrlX/tmux session or downloads/builds a simulator.
"""

import json
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SKILLS = ROOT / "plugin/ctrlx/skills"
TEMPLATE = SKILLS / "create-agent-plugin/assets/template"
CLI = (os.environ.get("CTRLX_SKILL_TEST_CLI") or shutil.which("ctrlx")
       or "/Applications/CtrlX.app/Contents/MacOS/CtrlXCLI")
SWIFTC = shutil.which("swiftc")


def frame(message):
    body = json.dumps(message, ensure_ascii=False).encode()
    return b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body


def unframe(data):
    messages = []
    while data:
        header, data = data.split(b"\r\n\r\n", 1)
        length = int(header.removeprefix(b"Content-Length: "))
        if len(data) < length:
            raise ValueError("Truncated sidecar response")
        messages.append(json.loads(data[:length]))
        data = data[length:]
    return messages


def json_examples(path):
    """Decode runnable inline/fenced JSON, ignoring tables' schema notation."""
    text = path.read_text()
    blocks = re.findall(r"```json\s*\n(.*?)```", text, flags=re.S)
    inline = re.findall(r"`([^`\n]+)`", re.sub(r"```.*?```", "", text, flags=re.S))
    examples = []
    for value in blocks + inline:
        try:
            examples.append(json.loads(value))
        except json.JSONDecodeError:
            pass  # Command lines and schema placeholders are not JSON examples.
    return examples


class SkillResources(unittest.TestCase):
    def test_entrypoints_stay_small(self):
        skills = list(SKILLS.glob("*/SKILL.md"))
        self.assertEqual({path.parent.name for path in skills},
                         {"agent-browser", "ctrlx-cli", "create-agent-plugin"})
        for path in skills:
            with self.subTest(skill=path.parent.name):
                text = path.read_text()
                self.assertLessEqual(len(text.encode()), 5000)
                self.assertLessEqual(len(text.splitlines()), 90)
                frontmatter = text.split("---", 2)[1]
                fields = dict(line.split(": ", 1) for line in frontmatter.strip().splitlines())
                self.assertEqual(fields["name"], path.parent.name)
                self.assertLessEqual(len(fields["description"]), 200)

    def test_references_are_local_reachable_and_bounded(self):
        for skill in SKILLS.iterdir():
            if not skill.is_dir():
                continue
            pending = [skill / "SKILL.md"]
            visited = set()
            while pending:
                path = pending.pop().resolve()
                if path in visited:
                    continue
                visited.add(path)
                self.assertTrue(path.is_file(), str(path))
                self.assertTrue(path.is_relative_to(skill.resolve()), str(path))
                if path.suffix != ".md":
                    continue
                self.assertLessEqual(path.stat().st_size, 14000, str(path))
                prose = re.sub(r"```.*?```", "", path.read_text(), flags=re.S)
                for link in re.findall(r"\[[^\]]+\]\(([^)]+)\)", prose):
                    if "://" in link or link.startswith("#"):
                        continue
                    target = path.parent / link.split("#", 1)[0]
                    pending.append(target)
            for resource in (skill / "references").glob("*.md"):
                self.assertIn(resource.resolve(), visited, str(resource))

    @unittest.skipUnless(shutil.which("rsync"), "rsync required for bundle sync")
    def test_codex_bundle_mirrors_all_resources_without_editing_source(self):
        with tempfile.TemporaryDirectory(prefix="cx-sk-", dir="/tmp") as tmp:
            plugin = Path(tmp) / "CtrlX.app/Contents/Resources/plugin"
            source = plugin / "ctrlx/skills"
            destination = plugin / "codex/ctrlx/skills"
            shutil.copytree(SKILLS, source)
            destination.mkdir(parents=True)
            (destination / "obsolete.md").write_text("stale built resource")
            before = {p.relative_to(source): p.read_bytes()
                      for p in source.rglob("*") if p.is_file()}
            env = dict(os.environ, BUILT_PRODUCTS_DIR=tmp, PRODUCT_NAME="CtrlX")
            for _ in range(2):
                subprocess.run(["bash", str(ROOT / "scripts/sync-codex-skills.sh")],
                               env=env, check=True, capture_output=True, timeout=15)
                after = {p.relative_to(destination): p.read_bytes()
                         for p in destination.rglob("*") if p.is_file()}
                self.assertEqual(before, after)
            self.assertEqual(before, {p.relative_to(source): p.read_bytes()
                                      for p in source.rglob("*") if p.is_file()})


class SidecarTemplate(unittest.TestCase):
    def test_framing_context_states_and_ignored_child_completion(self):
        requests = [{"id": "init", "method": "initialize", "params": {"settings": {}}}]
        for event in ("turn_start", "Stop", "SubagentStop", "unknown"):
            requests.append({"id": event, "method": "translate_event", "params": {
                "pluginID": "sample-agent", "context": {"TMUX_PANE": "%999"},
                "payload": {"session_id": "session-1", "event": event,
                            "summary": "完成", "cwd": "/tmp/project"}}})
        requests.append({"id": "unsupported", "method": "not_a_method", "params": {}})
        result = subprocess.run([sys.executable, str(TEMPLATE / "sidecar.py")],
                                input=b"".join(map(frame, requests)),
                                capture_output=True, check=True, timeout=5)
        messages = {m["id"]: m for m in unframe(result.stdout) if "id" in m}
        self.assertEqual(messages["init"]["result"], {})
        for name, state in (("turn_start", {"working": {}}),
                            ("Stop", {"doneWorking": {"summary": "完成"}})):
            event = messages[name]["result"]
            self.assertEqual(event, {"pluginID": "sample-agent", "sessionID": "session-1",
                                     "state": state, "appActions": [], "tmuxPane": "%999",
                                     "projectPath": "/tmp/project"})
        self.assertIsNone(messages["SubagentStop"]["result"])
        self.assertIsNone(messages["unknown"]["result"])
        self.assertEqual(messages["unsupported"]["error"]["code"], "method_not_found")
        self.assertEqual(result.stderr, b"")

    def test_eof_mid_frame_exits_cleanly(self):
        result = subprocess.run([sys.executable, str(TEMPLATE / "sidecar.py")],
                                input=b"Content-Length: 50\r\n\r\n{}",
                                capture_output=True, check=True, timeout=5)
        self.assertEqual(result.stdout, b"")

    def test_hook_uses_ingress_framing_and_snake_case(self):
        with tempfile.TemporaryDirectory(prefix="cx-sk-", dir="/tmp") as tmp:
            path = str(Path(tmp) / "ingress.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(path)
                listener.listen(1)
                listener.settimeout(5)
                env = dict(os.environ, CTRLX_INGRESS_SOCK=path,
                           CTRLX_PLUGIN_ID="sample-agent", TMUX_PANE="%999")
                payload = {"event": "turn_start", "text": "中文"}
                subprocess.run([sys.executable, str(TEMPLATE / "hook.py")],
                               input=json.dumps(payload).encode(), env=env,
                               capture_output=True, check=True, timeout=5)
                connection, _ = listener.accept()
                with connection, connection.makefile("rb") as stream:
                    length = struct.unpack(">I", stream.read(4))[0]
                    message = json.loads(stream.read(length))
                    self.assertEqual(stream.read(), b"")
                self.assertEqual(message["plugin_id"], "sample-agent")
                self.assertEqual(message["context"]["TMUX_PANE"], "%999")
                self.assertEqual(message["payload"], payload)


@unittest.skipUnless(SWIFTC, "Swift compiler required for source contract check")
class WireContractExamples(unittest.TestCase):
    def test_documented_json_matches_real_swift_models(self):
        models = ROOT / "CtrlxPackage/Sources/CtrlxNetworking/Models"
        sources = [models / name for name in (
            "JSONRPC.swift", "APIModels.swift", "Plugin/AgentProject.swift",
            "Plugin/AgentResponse.swift")]
        with tempfile.TemporaryDirectory(prefix="cx-sk-", dir="/tmp") as tmp:
            executable = Path(tmp) / "wire-examples"
            # Compile only Foundation-based model files, not the app/package or SDK downloads.
            subprocess.run([SWIFTC, "-module-cache-path", str(Path(tmp) / "cache"),
                            *map(str, sources),
                            str(ROOT / "scripts/tests/fixtures/agent_skill_wire.swift"),
                            "-o", str(executable)],
                           check=True, capture_output=True, timeout=60)
            result = subprocess.run([str(executable)], check=True, capture_output=True, timeout=5)
        actual = json.loads(result.stdout)
        api = json_examples(SKILLS / "ctrlx-cli/references/api-reference.md")
        forms = json_examples(SKILLS / "create-agent-plugin/references/forms-and-input.md")
        self.assertIn(actual["identify"], api)
        self.assertIn(actual["ack"]["result"], api)
        for decision in actual["permission_decisions"] + actual["plan_decisions"]:
            self.assertIn(decision, forms)


@unittest.skipUnless(Path(CLI).is_file(), "Set CTRLX_SKILL_TEST_CLI to a built CLI")
class CLIExamples(unittest.TestCase):
    def request(self, args, result, stdin=None):
        """Serve exactly one fake API request, never the running app's socket."""
        with tempfile.TemporaryDirectory(prefix="cx-sk-", dir="/tmp") as tmp:
            path = str(Path(tmp) / "api.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(path)
                listener.listen(1)
                listener.settimeout(5)
                env = dict(os.environ, TMUX_PANE="%999", CTRLX_SOCKET=path)
                with subprocess.Popen([CLI, *args, "--socket", path, "--json"],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, env=env) as process:
                    try:
                        if stdin is not None:
                            process.stdin.write(stdin)
                        process.stdin.close()
                        process.stdin = None
                        connection, _ = listener.accept()
                        with connection, connection.makefile("rb") as stream:
                            request = json.loads(stream.readline())
                            response = {"id": request["id"], "ok": True, "result": result}
                            connection.sendall(json.dumps(response).encode() + b"\n")
                        stdout, stderr = process.communicate(timeout=5)
                    finally:
                        if process.poll() is None:
                            process.kill()
                            process.wait()
                    self.assertEqual(process.returncode, 0, stderr)
                    return request, json.loads(stdout)

    def test_capture_json_content_and_explicit_target(self):
        request, response = self.request(["capture-pane", "--pane", "%17"], {"content": "hello\n"})
        self.assertEqual(request["method"], "pane.capture")
        self.assertEqual(request["params"], {"pane_id": "%17"})
        self.assertEqual(response["result"]["content"], "hello\n")

    def test_caller_context_is_not_current_session(self):
        request, _ = self.request(["identify"], {"session": None, "window": None, "pane": None})
        self.assertEqual(request["params"], {"pane_id": "%999"})
        request, _ = self.request(["current-session"], {"id": "attached", "name": "attached"})
        self.assertEqual(request["params"], {})

    def test_labels_use_session_not_shared_pane_option(self):
        request, _ = self.request(["set-title", "Build", "--session", "work"], {"ok": True})
        self.assertEqual(request["params"], {"title": "Build", "session_id": "work"})
        request, _ = self.request(["set-title", "Build", "--pane", "%17"], {"ok": True})
        self.assertEqual(request["params"]["pane_id"], "%999")

    def test_send_requires_explicit_enter(self):
        request, _ = self.request(["send", "make test", "--pane", "%17"], {"ok": True})
        self.assertEqual(request["params"], {"text": "make test", "pane_id": "%17"})
        request, _ = self.request(["send", "make test", "--pane", "%17", "--enter"], {"ok": True})
        self.assertIs(request["params"]["enter"], True)

    def test_idempotent_create_exposes_created_false(self):
        request, response = self.request(["new-session", "--name", "work", "--if-missing"],
                                         {"id": "work", "created": False})
        self.assertEqual(request["params"], {"name": "work", "if_missing": True})
        self.assertIs(response["result"]["created"], False)

    def test_plugin_json_trust_preview_does_not_confirm_install(self):
        request, response = self.request(["plugin", "install", "https://example.com/plugin.json"],
                                         {"status": "needs_trust", "trust": {}})
        self.assertIs(request["params"]["trustConfirmed"], False)
        self.assertEqual(response["result"]["status"], "needs_trust")

    def test_layout_dry_run_never_requests_rebuild(self):
        config = {"session_name": "work", "windows": [{"window_name": "build", "panes": [{}]}]}
        request, _ = self.request(["apply", "-", "--dry-run"],
                                 {"planned_actions": [], "created": False}, json.dumps(config).encode())
        self.assertEqual(request["method"], "layout.apply")
        self.assertIs(request["params"]["dry_run"], True)
        self.assertIs(request["params"]["rebuild"], False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
