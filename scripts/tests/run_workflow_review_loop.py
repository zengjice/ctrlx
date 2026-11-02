"""Run the review/repair template with two private native CLIs and a loopback model.

Requires installed codex, claude and tmux. Uses no account credentials or external
model calls. The Swift opt-in test owns the production runner, ingress and API.
"""

import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import zlib


REPO = Path(__file__).resolve().parents[2]
OUTPUT = REPO / ".build-local/workflow-steps"


def text_values(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from text_values(item)
    elif isinstance(value, dict):
        for key, item in value.items():
            if key not in ("image_url", "data"):
                yield from text_values(item)


def result_json(value):
    for text in text_values(value):
        for match in re.finditer(r"\{", text):
            try:
                result, _ = json.JSONDecoder().raw_decode(text[match.start():])
            except ValueError:
                continue
            if isinstance(result, dict) and "ok" in result:
                assert result["ok"], result
                return result["result"]
    raise AssertionError("Native command returned no successful CLI result")


def image_hashes(value):
    if isinstance(value, list):
        for item in value:
            yield from image_hashes(item)
    elif isinstance(value, dict):
        uri = value.get("image_url", "")
        if value.get("type") == "input_image" and isinstance(uri, str) and uri.startswith("data:"):
            yield hashlib.sha256(base64.b64decode(uri.split(",", 1)[1])).hexdigest()
        for key, item in value.items():
            if key not in ("image_url", "data"):
                yield from image_hashes(item)


class Model(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, agent, root):
        self.agent, self.root = agent, root
        self.states, self.requests = {}, []
        super().__init__(("127.0.0.1", 0), Handler)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"data":[{"id":"gpt-5.4","object":"model"}]}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        server = self.server
        server.requests.append(body)
        (server.root / f"{server.agent}-requests.json").write_text(json.dumps(server.requests, ensure_ascii=False))
        if "count_tokens" in self.path:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"input_tokens":5}')
            return
        codex = server.agent == "codex"
        messages = body.get("input", body.get("messages", []))
        prompt, start = "", 0
        for index, message in enumerate(messages):
            if message.get("role") == "user":
                value = "\n".join(text_values(message.get("content", [])))
                if "[CtrlX workflow invocation:" in value:
                    prompt, start = value, index
        refs = re.findall(r"\[CtrlX workflow invocation: ([A-Fa-f0-9-]{36})\]", prompt)
        # Claude also sends title-generation requests containing the same task.
        invocation = refs[-1] if refs and body.get("tools") else None
        call, reply = None, "WORKFLOW_READY"
        state = server.states.setdefault(invocation, {"phase": 0}) if invocation else None
        try:
            previous = None
            if state and state.get("call"):
                for message in messages[start + 1:]:
                    if message.get("type") == "function_call_output" and message.get("call_id") == state["call"]:
                        previous = message.get("output")
                    for block in message.get("content", []) if isinstance(message.get("content"), list) else []:
                        if block.get("type") == "tool_result" and block.get("tool_use_id") == state["call"]:
                            assert not block.get("is_error"), block
                            previous = block.get("content")
                assert previous is not None, "Missing native tool response"
            phase = state["phase"] if state else 0
            if invocation and "USER_IMAGE_TASK" in prompt:
                assert codex
                if phase == 0:
                    call = ("exec_command", {"cmd": f"ctrlx workflow attachments --invocation {invocation} --json", "login": False})
                elif phase == 1:
                    attachments = result_json(previous)["attachments"]
                    assert len(attachments) == 1
                    state["image"] = attachments[0]
                    call = ("view_image", {"path": attachments[0]["path"]})
                elif phase == 2:
                    assert state["image"]["sha256"] in list(image_hashes(messages[start + 1:])), "Image did not reach native model input"
                    state["imageRead"] = True
                    command = "printf '%s\\n' 'def safe_divide(numerator, denominator):' '    return numerator / denominator' > sample.py"
                    call = ("exec_command", {"cmd": command, "login": False})
                else:
                    assert (server.root / "project/sample.py").is_file()
                    reply = "DEVELOPMENT_DONE: implemented safe_divide in sample.py."
            elif invocation and "Only judge the findings" in prompt:
                assert codex and "P2 REVIEW_FINDING" in prompt
                reply = "Accepted: REVIEW_FINDING — add an explicit zero-denominator guard. Rejected: none. No repair performed yet."
            elif invocation and "Fix the Accepted findings" in prompt:
                assert codex and "Accepted: REVIEW_FINDING" in "\n".join(text_values(messages)), "Developer lost its judgment context"
                assert "Accepted: REVIEW_FINDING" not in prompt, "Completion-only edge forwarded a judgment"
                if phase == 0:
                    source = "def safe_divide(numerator, denominator):\n    if denominator == 0:\n        raise ValueError('denominator must not be zero')\n    return numerator / denominator\n"
                    code = "from pathlib import Path; Path('sample.py').write_text(" + repr(source) + ")"
                    call = ("exec_command", {"cmd": "python3 -c " + shlex.quote(code), "login": False})
                elif phase == 1:
                    check = "from sample import safe_divide; assert safe_divide(6, 2) == 3\ntry:\n safe_divide(1, 0)\nexcept ValueError:\n pass\nelse:\n raise AssertionError('missing guard')"
                    call = ("exec_command", {"cmd": "python3 -c " + shlex.quote(check), "login": False})
                else:
                    reply = "REPAIR_DONE: added the Accepted guard and verified normal and zero inputs."
            elif invocation and "Review the current implementation" in prompt:
                assert not codex
                assert "Initial task:" not in prompt and "Answer from" not in prompt and "Content from" not in prompt
                if phase == 0:
                    call = ("Bash", {"command": "cat sample.py", "description": "Review the shared fixture implementation"})
                else:
                    source = (server.root / "project/sample.py").read_text()
                    if phase == 1:
                        assert source.strip() in "\n".join(text_values(previous)), "Reviewer did not read the shared file"
                    if "if denominator == 0:" not in source:
                        reply = "P2 REVIEW_FINDING: sample.py:2 needs an explicit zero-denominator guard."
                    elif phase == 1:
                        call = ("Bash", {"command": f'ctrlx workflow finish --invocation {invocation} --reason "No P0-P3 findings" --json', "description": "End the authorized review-loop fixture"})
                    else:
                        result_json(previous)
                        state["finishConfirmed"] = True
                        reply = "No P0–P3 findings. Workflow complete."
            if state:
                state["phase"] += 1
        except Exception as error:
            if state:
                state["error"] = type(error).__name__ + ": " + str(error)
            call, reply = None, "FIXTURE_ERROR: " + str(error)
        unique = uuid.uuid4().hex
        if call:
            state["call"] = ("call_" if codex else "toolu_") + unique
        (server.root / f"{server.agent}-model-evidence.json").write_text(json.dumps(server.states, indent=2))
        if codex:
            item = {"id": "fc_" + unique, "type": "function_call", "call_id": state["call"], "name": call[0], "arguments": json.dumps(call[1]), "status": "completed"} if call else {"id": "msg_" + unique, "type": "message", "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": reply, "annotations": []}]}
            events = [{"type": "response.created", "response": {"id": "resp_" + unique, "status": "in_progress", "output": []}}, {"type": "response.output_item.done", "output_index": 0, "item": item}, {"type": "response.completed", "response": {"id": "resp_" + unique, "model": "gpt-5.4", "status": "completed", "output": [item], "usage": {"input_tokens": 5, "output_tokens": 5, "total_tokens": 10}}}]
        else:
            block = {"type": "tool_use", "id": state["call"], "name": call[0], "input": {}} if call else {"type": "text", "text": ""}
            delta = {"type": "input_json_delta", "partial_json": json.dumps(call[1])} if call else {"type": "text_delta", "text": reply}
            events = [{"type": "message_start", "message": {"id": "msg_" + unique, "type": "message", "role": "assistant", "content": [], "model": "claude-sonnet-4-5", "stop_reason": None, "usage": {"input_tokens": 5, "output_tokens": 0}}}, {"type": "content_block_start", "index": 0, "content_block": block}, {"type": "content_block_delta", "index": 0, "delta": delta}, {"type": "content_block_stop", "index": 0}, {"type": "message_delta", "delta": {"stop_reason": "tool_use" if call else "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 5}}, {"type": "message_stop"}]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        try:
            for event in events:
                self.wfile.write(("event: " + event["type"] + "\ndata: " + json.dumps(event) + "\n\n").encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\0" + bytes([32, 96, 192]) * 64 for _ in range(32))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 32, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def run():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="cx-wf-steps-"))
    socket = root / "tmux.sock"
    project = root / "project"
    project.mkdir()
    (root / "task.png").write_bytes(png())
    (root / "bin").mkdir()
    # Use the current package's CLI, never the installed App's older binary.
    binary = REPO / "CtrlxPackage/.build/out/Products/Debug/CtrlxCLI"
    if not binary.exists():
        binary = REPO / "CtrlxPackage/.build/out/Products/Debug/CtrlXCLI"
    assert binary.is_file(), "Run focused package tests first to build the current CLI"
    (root / "bin/ctrlx").symlink_to(binary)
    def tmux(*arguments):
        return subprocess.check_output(["/opt/homebrew/bin/tmux", "-f", "/dev/null", "-S", str(socket), *arguments], text=True, timeout=10).strip()
    models = [Model(agent, root) for agent in ("codex", "claude")]
    for model in models:
        threading.Thread(target=model.serve_forever, daemon=True).start()
    manifest = {"root": str(root), "tmux": str(socket), "agents": []}
    try:
        for index, model in enumerate(models):
            agent = model.agent
            config = root / agent
            config.mkdir()
            private_home = root / (agent + "-home")
            private_home.mkdir()
            env = {"HOME": str(private_home), "PATH": f"{root}/bin:/opt/homebrew/bin:/usr/bin:/bin", "TERM": "xterm-256color", "CTRLX_SOCKET": str(root / "api.sock")}
            bridge = root / (agent + "-hook.py")
            source = (REPO / ("plugin/codex/ctrlx/scripts/hook.py" if agent == "codex" else "plugin/ctrlx/scripts/hook.py")).read_text()
            source = source.replace('SOCKET_PATH = os.path.expanduser("~/.ctrlx/state/ingress.sock")', "SOCKET_PATH = " + repr(str(root / "ingress.sock")))
            anchor = '    body = json.dumps(\n'
            assert source.count(anchor) == 1
            source = source.replace(anchor, '    with open(' + repr(str(root / (agent + "-hooks.jsonl"))) + ', "a") as log:\n        log.write(json.dumps(payload) + "\\n")\n\n' + anchor)
            bridge.write_text(source)
            endpoint = f"http://127.0.0.1:{model.server_address[1]}"
            if agent == "codex":
                env["CODEX_HOME"] = str(config)
                (config / "config.toml").write_text(f'model = "gpt-5.4"\nmodel_provider = "fixture"\ncheck_for_update_on_startup = false\n[model_providers.fixture]\nname = "Fixture"\nbase_url = "{endpoint}/v1"\nwire_api = "responses"\nrequires_openai_auth = false\n[projects."{project}"]\ntrust_level = "trusted"\n')
                marketplace = root / "marketplace"
                shutil.copytree(REPO / "plugin/codex", marketplace)
                shutil.copyfile(bridge, marketplace / "ctrlx/scripts/hook.py")
                for args in (["plugin", "marketplace", "add", str(marketplace)], ["plugin", "add", "ctrlx@ctrlx"]):
                    subprocess.run(["/opt/homebrew/bin/codex", *args], env=env, check=True, capture_output=True, timeout=30)
                args = ["/opt/homebrew/bin/codex", "--no-daemon", "--no-alt-screen", "--dangerously-bypass-hook-trust", "-C", str(project), "-a", "never", "-s", "danger-full-access", "Say fixture ready."]
            else:
                env["CLAUDE_CONFIG_DIR"] = str(config)
                (config / ".claude.json").write_text(json.dumps({"hasCompletedOnboarding": True, "projects": {str(project): {"hasTrustDialogAccepted": True}}}))
                hook = {"hooks": [{"type": "command", "command": shlex.join([sys.executable, str(bridge)]), "timeout": 30}]}
                (config / "settings.json").write_text(json.dumps({"env": {"ANTHROPIC_API_KEY": "ctrlx-loopback-fixture", "ANTHROPIC_BASE_URL": endpoint, "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"}, "permissions": {"allow": ["Bash(cat sample.py)", "Bash(ctrlx workflow finish:*)"]}, "hooks": {event: [hook] for event in ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd", "PreToolUse", "PostToolUse"]}}))
                args = ["/opt/homebrew/bin/claude", "--model", "claude-sonnet-4-5", "Say fixture ready."]
            target = f"review-loop:{index}"
            pane = tmux(*(["new-session", "-d", "-s", "review-loop", "-x", "140", "-y", "42", "-P", "-F", "#{pane_id}"] if index == 0 else ["new-window", "-d", "-t", target, "-P", "-F", "#{pane_id}"]), "-c", str(project), "/bin/sh")
            env["TMUX_PANE"] = pane
            command = "exec /usr/bin/env -i " + shlex.join([f"{key}={value}" for key, value in env.items()] + args)
            tmux("respawn-pane", "-k", "-t", pane, "-c", str(project), command)
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                hooks = root / (agent + "-hooks.jsonl")
                records = [json.loads(line) for line in hooks.read_text().splitlines()] if hooks.exists() else []
                session = next((item["session_id"] for item in records if item.get("session_id")), None)
                screen = tmux("capture-pane", "-p", "-t", pane)
                if "Yes, I trust this folder" in screen and "❯ No, exit" in screen:
                    assert str(project) in screen or str(project.resolve()) in screen
                    tmux("send-keys", "-t", pane, "Down", "Enter")
                if "Detected a custom API key" in screen and "Do you want to use this API key?" in screen:
                    # This profile contains only the dummy key for this loopback server.
                    tmux("send-keys", "-t", pane, "Up", "Enter")
                if session and "WORKFLOW_READY" in screen:
                    break
                time.sleep(.2)
            else:
                raise RuntimeError("Native startup failed: " + tmux("capture-pane", "-p", "-t", pane))
            version = subprocess.check_output(["/opt/homebrew/bin/" + agent, "--version"], text=True, timeout=10).strip()
            manifest["agents"].append({"pluginID": "codex" if agent == "codex" else "claude-code", "paneID": pane, "processID": int(tmux("display-message", "-p", "-t", pane, "#{pane_pid}")), "conversationID": session, "version": version})
            print("Native fixture ready:", agent, flush=True)
        path = root / "fixture.json"
        path.write_text(json.dumps(manifest, indent=2))
        environment = dict(os.environ, CTRLX_WORKFLOW_NATIVE_FIXTURE=str(path))
        log_path = OUTPUT / "native-tests.log"
        with log_path.open("w") as log:
            result = subprocess.run([str(REPO / "scripts/unit-tests.sh"), "--", "--jobs", "2", "--skip-update", "--force-resolved-versions", "--filter", "AgentWorkflowNativeReviewLoopTests"], cwd=REPO, env=environment, stdout=log, stderr=log, timeout=360)
        print(log_path.read_text()[-6000:])
        assert result.returncode == 0, "Native sample failed; see " + str(log_path)
        evidence = {"fixture": str(root), "agents": manifest["agents"], "model": "deterministic loopback fixture; native Codex and Claude Code", "run": json.loads((root / "native-run.json").read_text())}
        assert evidence["run"]["status"] == "completed"
        states = {model.agent: model.states for model in models}
        assert not any(state.get("error") for model in models for state in model.states.values())
        assert any(state.get("imageRead") for state in models[0].states.values())
        assert any(state.get("finishConfirmed") for state in models[1].states.values())
        evidence["modelEvidence"] = states
        (OUTPUT / "native-evidence.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2))
        print("PASS: two native Agent instances, image read, review, judgment, repair, repeated review and authorized finish")
    finally:
        if socket.exists():
            for index in range(len(manifest["agents"])):
                try:
                    (root / f"terminal-{index}.txt").write_text(tmux("capture-pane", "-e", "-p", "-t", f"review-loop:{index}"))
                except subprocess.SubprocessError:
                    pass
            subprocess.run(["/opt/homebrew/bin/tmux", "-S", str(socket), "kill-server"], capture_output=True, timeout=10)
        for model in models:
            model.shutdown()
            model.server_close()
        (OUTPUT / "native-fixture-path.txt").write_text(str(root) + "\n")


if __name__ == "__main__":
    run()
