"""Exercise the signed Host API only through the runner's private socket."""
import concurrent.futures
import json
from pathlib import Path
import socket
import subprocess
import sys
import time
import traceback
import uuid

ROOT, SOCKET = Path(sys.argv[1]).resolve(), sys.argv[2]
assert Path(SOCKET).name.startswith("cx-workspace-cli-")
EVIDENCE = ROOT.parent / "evidence"
EVIDENCE.mkdir(parents=True, exist_ok=True)
CALLS = []


def tmux(*args):
    return subprocess.check_output(["tmux", "-f", "/dev/null", "-S", SOCKET, *args], text=True, stderr=subprocess.DEVNULL).rstrip("\n")


def request(method, **params):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(30)
        client.connect(str(ROOT / "api.sock"))
        client.sendall((json.dumps({"id": str(uuid.uuid4()), "method": method, "params": params}) + "\n").encode())
        data = b""
        while b"\n" not in data:
            chunk = client.recv(65536)
            assert chunk, "Host closed API connection without a response"
            data += chunk
    value = json.loads(data.split(b"\n")[0])
    CALLS.append({"method": method, "response": value})
    return value


def api(method, **params):
    value = request(method, **params)
    assert not value.get("error"), value
    return value["result"]


def eventually(check):
    deadline = time.monotonic() + 15
    while True:
        try:
            return check()
        except (AssertionError, subprocess.CalledProcessError, FileNotFoundError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.1)


def assert_output(target, text):
    value = tmux("capture-pane", "-p", "-t", target)
    assert text in value, value
    return value


def run():
    original = tmux("display-message", "-p", "-t", "original:0", "#{pane_pid}")
    tmux("set-option", "-g", "base-index", "7")
    tmux("set-option", "-gw", "pane-base-index", "4")
    created = api("session.create", name="cli-live", path=str(ROOT), title="CLI retained identity", color="blue")
    assert created["created"] is True, created
    pane = tmux("display-message", "-p", "-t", "cli-live:7", "#{pane_id}")
    api("session.set_title", session_id="cli-live", title="CLI current")
    api("session.set_color", session_id="cli-live", color="green")
    api("session.set_emoji", session_id="cli-live", emoji="🧪")
    api("session.set_state", pane_id=pane, state="idle")
    api("pane.set_progress", pane_id=pane, value="25")
    api("system.set_env", session_id="cli-live", vars={"CTRLX_CLI_KEEP": "yes", "CTRLX_CLI_UNSET": "temporary"})
    api("system.set_env", session_id="cli-live", vars={"CTRLX_CLI_UNSET": None})
    assert tmux("show-environment", "-t", "cli-live", "CTRLX_CLI_KEEP") == "CTRLX_CLI_KEEP=yes"
    window = api("window.create", session_id="cli-live", path=str(ROOT), name="extra")
    api("window.set_name", window_id=window["id"], name="renamed")
    api("window.select", window_id=window["id"])
    split = api("pane.split", pane_id=pane, direction="right", path=str(ROOT), shell="/bin/cat")
    api("input.send_text", pane_id=split["id"], text="CLI_SPLIT_CURRENT", enter=True)
    api("input.send_key", pane_id=split["id"], key="Enter")
    eventually(lambda: assert_output(split["id"], "CLI_SPLIT_CURRENT"))
    api("pane.set_layout", target="cli-live:7", layout="even-horizontal")
    api("pane.select", pane_id=pane)
    api("session.select", session_id="cli-live")
    missing = request("input.send_text", pane_id="%999999", text="MUST_NOT_REDIRECT", enter=True)
    assert missing.get("error"), missing
    api("window.close", window_id=window["id"])

    config = {
        "session_name": "cli-layout", "start_directory": str(ROOT),
        "description": "CLI layout current", "color": "blue",
        "environment": {"CTRLX_LAYOUT_LIVE": "yes"}, "options": {"@cli-layout": "session"},
        "windows": [
            {"window_name": "main", "focus": True, "layout": "even-horizontal", "options": {"@cli-window": "live"},
             "panes": [{"shell_command": "printf 'CLI_LAYOUT_CURRENT\\n'", "focus": True, "progress": 20},
                       {"shell_command": "printf 'CLI_LAYOUT_SECOND\\n'"}]},
            {"window_name": "extra", "panes": [{"shell_command": "printf 'CLI_LAYOUT_EXTRA\\n'"}]},
        ],
    }
    assert api("layout.apply", config=config)["created"] is True
    layout_pid = tmux("display-message", "-p", "-t", "cli-layout:7.4", "#{pane_pid}")
    assert api("layout.apply", config=config)["created"] is False
    assert tmux("display-message", "-p", "-t", "cli-layout:7.4", "#{pane_pid}") == layout_pid
    assert tmux("display-message", "-p", "-t", "cli-layout:", "#{window_index}:#{pane_index}:#{window_panes}") == "7:4:2"
    eventually(lambda: assert_output("cli-layout:7.4", "CLI_LAYOUT_CURRENT"))

    marker = "CLI_STALE_LAYOUT_MUST_NOT_RUN"
    delayed = {"session_name": "cli-delayed", "description": "CLI_DELAY_BOUND", "start_directory": str(ROOT), "windows": [
        {"window_name": "delayed", "panes": [{"sleep_before": 3, "shell_command": marker, "enter": False}]}]}
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(request, "layout.apply", config=delayed)
        def ready():
            assert tmux("show-option", "-v", "-t", "cli-delayed", "@ctrlx-description") == "CLI_DELAY_BOUND"
            value = tmux("display-message", "-p", "-t", "cli-delayed:7", "#{pane_id}|#{@ctrlx-recovery-pane}")
            target, identity = value.split("|", 1)
            assert identity, value
            return target
        target = eventually(ready)
        pid = tmux("display-message", "-p", "-t", target, "#{pane_pid}")
        tmux("set-option", "-p", "-t", target, "@ctrlx-recovery-pane", str(uuid.uuid4()).upper())
        rejection = pending.result(timeout=20)
    assert rejection.get("error") and "terminal changed" in rejection["error"]["message"].lower(), rejection
    assert marker not in tmux("capture-pane", "-p", "-t", target)
    assert tmux("display-message", "-p", "-t", target, "#{pane_pid}") == pid
    api("input.send_text", pane_id=target, text="printf 'CLI_FRESH_AFTER_REJECTION\\n'", enter=True)
    eventually(lambda: assert_output(target, "CLI_FRESH_AFTER_REJECTION"))
    api("session.close", session_id="cli-delayed")
    api("session.select", session_id="cli-layout")
    assert tmux("display-message", "-p", "-t", "original:0", "#{pane_pid}") == original
    return {"passed": True, "original_pid": original, "layout_pid": layout_pid, "rejection": rejection, "api_calls": CALLS}


def editor_start(fresh):
    name = "fresh" if fresh else "stale"
    file = ROOT / f"{name}-editor.txt"
    file.write_text(f"EDITOR_{name.upper()}_ORIGINAL")
    pane = tmux("display-message", "-p", "-t", "original:0", "#{pane_id}")
    identity = tmux("show-option", "-pv", "-t", pane, "@ctrlx-recovery-pane")
    (EVIDENCE / f"{name}-editor-before.json").write_text(json.dumps({"pane": pane, "identity": identity}))
    api("session.select", session_id="original")
    response = request("editor.open", pane_id=pane, file_path=str(file))
    (EVIDENCE / f"{name}-editor-response.json").write_text(json.dumps({"done": True, "response": response}))
    return {"passed": True, "response": response}


def editor_verify():
    before = json.loads((EVIDENCE / "stale-editor-before.json").read_text())
    response = json.loads((EVIDENCE / "stale-editor-response.json").read_text())["response"]
    assert response.get("error"), response
    assert (ROOT / "stale-editor.txt").read_text() == "EDITOR_STALE_ORIGINAL"
    def saved():
        journal = json.loads((ROOT / "Recovery" / "workspace.json").read_text())
        matches = [d for d in journal["drafts"] if d["text"] == "EDITOR_UNSENT_RETAINED"]
        assert len(matches) == 1, journal.get("drafts")
        assert matches[0]["paneID"].lower() == before["identity"].lower(), matches
        return matches[0]
    draft = eventually(saved)
    fresh = json.loads((EVIDENCE / "fresh-editor-response.json").read_text())["response"]
    assert not fresh.get("error"), fresh
    assert (ROOT / "fresh-editor.txt").read_text() == "EDITOR_FRESH_SUBMITTED"
    return {"passed": True, "retained_draft": draft, "stale_response": response, "fresh_response": fresh}


phase = sys.argv[3] if len(sys.argv) > 3 else "cli"
try:
    if phase == "stale-editor":
        result = editor_start(False)
    elif phase == "fresh-editor":
        result = editor_start(True)
    elif phase == "editor-verify":
        result = editor_verify()
    else:
        result = run()
except Exception:
    (EVIDENCE / f"{phase}-failure.txt").write_text(traceback.format_exc())
    (EVIDENCE / f"{phase}-calls.json").write_text(json.dumps(CALLS, indent=2))
    raise
(EVIDENCE / f"{phase}.json").write_text(json.dumps(result, indent=2) + "\n")
