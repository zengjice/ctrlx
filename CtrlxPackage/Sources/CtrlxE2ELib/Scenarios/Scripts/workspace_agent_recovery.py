"""Native Agent recovery in the signed App, confined to a disposable tmux/root."""

import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import sys
import threading
import time
import traceback
import urllib.request

from native_agent_model import ModelFixture

PHASE, ROOT, SOCKET = sys.argv[1], Path(sys.argv[2]).resolve(), sys.argv[3]
APP = Path(sys.argv[4]).resolve() if len(sys.argv) > 4 else None
assert Path(SOCKET).name.startswith("cx-workspace-agent-")
EVIDENCE = ROOT.parent / "evidence"
JOURNAL = ROOT / "Recovery" / "workspace.json"
PROJECT = ROOT / "agent-project"
EVIDENCE.mkdir(parents=True, exist_ok=True)
AGENTS = [("codex-a", "codex", "restore-agents:0.0"), ("claude-a", "claude", "restore-agents:0.1"), ("codex-b", "codex", "restore-agents:1.0"), ("claude-b", "claude", "restore-agents:3.0")]


def tmux(*args):
    return subprocess.check_output(["tmux", "-f", "/dev/null", "-S", SOCKET, *args], text=True, timeout=10).rstrip("\n")


def save(name, value):
    destination = EVIDENCE / f"{name}.json"
    temporary = destination.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(destination)


def wait(check, timeout=60):
    deadline = time.monotonic() + timeout
    while True:
        try:
            return check()
        except (AssertionError, FileNotFoundError, KeyError, StopIteration, json.JSONDecodeError) as error:
            if time.monotonic() >= deadline:
                raise AssertionError(f"{PHASE}: {error}") from error
            time.sleep(0.2)


def snapshot():
    return json.loads(JOURNAL.read_text())


def saved_panes(value):
    return {pane["id"]: pane for session in value["sessions"] if session["name"] == "restore-agents" for window in session["windows"] for pane in window["panes"]}


def live_panes():
    fields = ["pane_id", "pane_pid", "pane_dead", "pane_current_command", "@ctrlx-recovery-pane", "@ctrlx-recovery-agent-launch"]
    processes = [line.split(None, 2) for line in subprocess.check_output(["ps", "-axo", "pid=,ppid=,comm="], text=True).splitlines()]
    result = {}
    for name, agent, target in AGENTS:
        row = tmux("display-message", "-p", "-t", target, "\x1f".join("#{" + field + "}" for field in fields)).split("\x1f")
        assert len(row) == len(fields), row
        result[name] = dict(zip(fields, row))
        descendants = {row[1]}
        while True:
            children = {pid for pid, parent, _ in processes if parent in descendants} - descendants
            if not children:
                break
            descendants.update(children)
        native = [(pid, executable) for pid, _, executable in processes if pid in descendants and Path(executable).name == agent]
        assert len(native) == 1, (name, native)
        result[name].update(nativePID=native[0][0], nativeExecutable=str(Path(native[0][1]).resolve()))
    return result


def requests():
    endpoints = json.loads((EVIDENCE / "model-endpoints.json").read_text())
    return {name: json.load(urllib.request.urlopen(url + "/requests", timeout=5))["requests"] for name, url in endpoints.items()}


def serve():
    servers = {name: ModelFixture(agent, "idle", ROOT / (name + "-executed.txt")) for name, agent, _ in AGENTS}
    for server in servers.values():
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
    save("model-endpoints", {name: f"http://127.0.0.1:{server.server_address[1]}" for name, server in servers.items()})
    try:
        deadline = time.monotonic() + 600
        while ROOT.exists() and not (ROOT / "stop-models").exists() and time.monotonic() < deadline:
            time.sleep(0.2)
    finally:
        for server in servers.values():
            server.release.set(); server.shutdown(); server.server_close()
    return {"stopped": True}


def setup():
    assert APP is not None and APP.is_dir()
    PROJECT.mkdir(parents=True)
    (ROOT / "private-home").mkdir()
    (ROOT / ".workspace-agent-fixture").touch()
    with (EVIDENCE / "model-server.log").open("w") as log:
        worker = subprocess.Popen([sys.executable, __file__, "serve", str(ROOT), SOCKET], stdin=subprocess.DEVNULL, stdout=log, stderr=log, close_fds=True, start_new_session=True)
    endpoints = wait(lambda: json.loads((EVIDENCE / "model-endpoints.json").read_text()))
    # Forward real native lifecycle payloads to this App's private socket. A gate
    # can delay one SessionStart to exercise exit before identity reconciliation.
    original = APP / "Contents/Resources/plugin/ctrlx/scripts/hook.py"
    bridge = ROOT / "claude-hook.py"
    source = original.read_text()
    old = 'SOCKET_PATH = os.path.expanduser("~/.ctrlx/state/ingress.sock")'
    assert source.count(old) == 1
    source = source.replace(old, "SOCKET_PATH = " + repr(str(ROOT / "ingress.sock")))
    anchor = '    context = {"TMUX_PANE": tmux_pane}'
    assert source.count(anchor) == 1
    gate = f'''
    gate = Path({str(ROOT / "hold-native-start")!r})
    if payload.get("hook_event_name") == "SessionStart" and Path(os.environ.get("CLAUDE_CONFIG_DIR", "")).resolve() == Path({str(ROOT / "claude-a")!r}) and gate.exists():
        import time
        evidence = Path({str(EVIDENCE / "held-native-hook.json")!r})
        evidence.write_text(json.dumps({{"paneID": tmux_pane, "sessionID": payload.get("session_id"), "source": payload.get("source"), "hookPID": os.getpid()}}))
        deadline = time.monotonic() + 120
        while gate.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        if gate.exists():
            raise RuntimeError("Native recovery fixture gate was not released")

'''
    bridge.write_text(source.replace(anchor, gate + anchor))
    commands = {}
    for name, agent, target in AGENTS:
        config = ROOT / name
        config.mkdir()
        cli = shutil.which(agent)
        assert cli, agent
        env = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "TERM": "xterm-256color", "HOME": str(ROOT / "private-home")}
        if agent == "codex":
            env["CODEX_HOME"] = str(config)
            (config / "config.toml").write_text(f'''model = "gpt-5.4"
model_provider = "fixture"
check_for_update_on_startup = false
[model_providers.fixture]
name = "Fixture"
base_url = "{endpoints[name]}/v1"
wire_api = "responses"
requires_openai_auth = false
request_max_retries = 0
[projects."{PROJECT}"]
trust_level = "trusted"
''')
            args = [cli, "--no-daemon", "--no-alt-screen", "-C", str(PROJECT), "-a", "on-request", "-s", "workspace-write", "Say fixture ready."]
        else:
            env["CLAUDE_CONFIG_DIR"] = str(config)
            (config / ".claude.json").write_text(json.dumps({"hasCompletedOnboarding": True, "theme": "dark", "projects": {str(PROJECT): {"hasTrustDialogAccepted": True}}}))
            hook = {"hooks": [{"type": "command", "command": shlex.join([sys.executable, str(bridge)]), "timeout": 130}]}
            (config / "settings.json").write_text(json.dumps({"env": {"ANTHROPIC_API_KEY": "fixture-only", "ANTHROPIC_BASE_URL": endpoints[name], "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"}, "hooks": {event: [hook] for event in ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"]}}))
            args = [cli, "--model", "claude-sonnet-4-5", "--permission-mode", "default", "Say fixture ready."]
        # A runtime pane ID is added immediately before exec; never inherit the
        # calling Codex's own TMUX_PANE into a fixture Agent.
        commands[name] = {"target": target, "environment": env, "arguments": args}
    for plugin, native in [("codex", "codex"), ("claude-code", "claude")]:
        directory = ROOT / "plugins" / plugin
        directory.mkdir(parents=True)
        (directory / "settings.json").write_text(json.dumps({"command_path": shutil.which(native), "auto_run": False, "additional_config_folders": [str(ROOT / name) for name, agent, _ in AGENTS if agent == native], "export_telemetry": False}))
    save("commands", commands)
    tmux("respawn-pane", "-k", "-t", "restore-agents:0.0", "-c", str(PROJECT), "/bin/sh")
    tmux("rename-window", "-t", "restore-agents:0", "PAIR")
    tmux("set-window-option", "-t", "restore-agents:0", "automatic-rename", "off")
    tmux("split-window", "-h", "-t", "restore-agents:0.0", "-c", str(PROJECT), "/bin/sh")
    for index, name in [(1, "CODEX"), (3, "CLAUDE")]:
        tmux("new-window", "-d", "-t", f"restore-agents:{index}", "-n", name, "-c", str(PROJECT), "/bin/sh")
        tmux("set-window-option", "-t", f"restore-agents:{index}", "automatic-rename", "off")
    tmux("select-window", "-t", "restore-agents:0")
    return {"modelServerPID": worker.pid}


def start():
    commands = json.loads((EVIDENCE / "commands.json").read_text())
    for name, _, target in AGENTS:
        command = commands[name]
        env = dict(command["environment"], TMUX_PANE=tmux("display-message", "-p", "-t", target, "#{pane_id}"))
        line = "exec /usr/bin/env -i " + shlex.join([f"{key}={value}" for key, value in env.items()] + command["arguments"])
        tmux("respawn-pane", "-k", "-t", target, "-c", str(PROJECT), line)
    accepted = set()
    def ready():
        all_ready = True
        for name, agent, target in AGENTS:
            screen = tmux("capture-pane", "-p", "-S", "-150", "-t", target)
            (EVIDENCE / (name + "-initial.txt")).write_text(screen)
            if "Yes, I trust this folder" in screen and (name, "trust") not in accepted:
                tmux("send-keys", "-t", target, "Down", "Enter"); accepted.add((name, "trust"))
            if "Do you want to use this API key?" in screen and (name, "key") not in accepted:
                tmux("send-keys", "-t", target, "Up", "Enter"); accepted.add((name, "key"))
            all_ready &= "RECOVERY_IDLE_FIXTURE" in screen
        assert all_ready, "Native Agents have not all reached the idle fixture response"
    wait(ready)
    time.sleep(1)
    expected = {}
    for name, agent, _ in AGENTS:
        config = ROOT / name
        histories = list(config.rglob("rollout-*.jsonl" if agent == "codex" else "projects/*/*.jsonl"))
        assert len(histories) == 1, (name, histories)
        session_id = json.loads(histories[0].read_text().splitlines()[0])["payload"]["id"] if agent == "codex" else histories[0].stem
        expected[name] = {"sessionID": session_id, "configurationRoot": str(config), "history": str(histories[0]), "pluginID": "codex" if agent == "codex" else "claude-code"}
    save("expected", expected)
    save("initial-requests", requests())
    return {"conversations": expected, "live": live_panes()}


def require_agents(value, allow_pending=False):
    panes = saved_panes(value)
    assert len(panes) == 4, panes
    expected = json.loads((EVIDENCE / "expected.json").read_text())
    live = live_panes()
    for name, _, _ in AGENTS:
        identity = live[name]["@ctrlx-recovery-pane"]
        assert identity in panes, live[name]
        pane = panes[identity]
        assert pane.get("agent"), pane
        descriptor = pane["agent"]
        for key in ["sessionID", "pluginID"]:
            assert descriptor[key] == expected[name][key], (name, key, descriptor)
        assert Path(descriptor["configurationRoot"]).resolve() == Path(expected[name]["configurationRoot"]).resolve(), descriptor
        assert descriptor["projectPath"] == str(PROJECT), descriptor
        assert descriptor["executable"] == live[name]["nativeExecutable"], descriptor
        assert descriptor.get("automaticResumeUnavailableReason") is None, descriptor
        assert not pane.get("unavailableAgentReason"), pane
        assert live[name]["pane_dead"] == "0", live[name]
    if not allow_pending:
        assert not value.get("recovery"), value.get("recovery")
    assert "Say fixture ready." not in json.dumps(value)
    assert "fixture-only" not in json.dumps(value)
    return value


def require_pending():
    value = require_agents(snapshot(), allow_pending=True)
    live = live_panes()
    held = json.loads((EVIDENCE / "held-native-hook.json").read_text())
    expected = json.loads((EVIDENCE / "expected.json").read_text())["claude-a"]
    pane = live["claude-a"]
    assert held["paneID"] == pane["pane_id"] and held["sessionID"] == expected["sessionID"], held
    assert held["source"] == "resume", held
    recovery = value.get("recovery")
    assert recovery and set(recovery["pendingAgentPaneIDs"]) == {pane["@ctrlx-recovery-pane"]}, recovery
    # Swift encodes a UUID-keyed dictionary as alternating key/value elements.
    launches = recovery["agentLaunches"]
    launches = dict(zip(launches[::2], launches[1::2])) if isinstance(launches, list) else launches
    launch = launches[pane["@ctrlx-recovery-pane"]]
    assert launch["runtimePaneID"] == pane["pane_id"] and launch["id"] == pane["@ctrlx-recovery-agent-launch"], launch
    return {"snapshot": value, "live": live, "heldHook": held, "launch": launch}


def verify_native():
    expected = json.loads((EVIDENCE / "expected.json").read_text())
    assert requests() == json.loads((EVIDENCE / "initial-requests.json").read_text()), "Resume made new model requests"
    for name, agent, target in AGENTS:
        histories = list((ROOT / name).rglob("rollout-*.jsonl" if agent == "codex" else "projects/*/*.jsonl"))
        assert [str(path) for path in histories] == [expected[name]["history"]], histories
        screen = tmux("capture-pane", "-p", "-S", "-150", "-t", target)
        assert "RECOVERY_IDLE_FIXTURE" in screen, (name, screen)
        (EVIDENCE / (name + "-" + PHASE + ".txt")).write_text(screen)
    return live_panes()


def fork_setup():
    result = setup()
    storage = ROOT / "e2e-storage.json"
    assert not storage.exists()
    storage.write_text(json.dumps({
        "preferences": {"autoConnectToServer": {"bool": {"_0": True}}},
        "sessionKeys": {}, "secrets": {},
    }))
    storage.chmod(0o600)
    commands = json.loads((EVIDENCE / "commands.json").read_text())
    wrapper = ROOT / "fork-codex"
    cli = commands["codex-a"]["arguments"][0]
    wrapper.write_text("#!/bin/sh\nexec /usr/bin/env -i " + shlex.join([
        "PATH=/opt/homebrew/bin:/usr/bin:/bin", "TERM=xterm-256color", "HOME=" + str(ROOT / "private-home")
    ]) + ' TMUX_PANE="$TMUX_PANE" CODEX_HOME="$CODEX_HOME" ' + shlex.quote(cli)
        + ' --no-daemon --no-alt-screen "$@"\n')
    wrapper.chmod(0o700)
    path = ROOT / "plugins/codex/settings.json"
    settings = json.loads(path.read_text())
    settings["command_path"] = str(wrapper)
    path.write_text(json.dumps(settings))
    return result


def verify_forks(count):
    baseline = json.loads((EVIDENCE / "fork-ready.json").read_text())
    current = live_panes()
    for name, _, _ in AGENTS:
        assert current[name]["nativePID"] == baseline["live"][name]["nativePID"], (name, current[name])
    expected = json.loads((EVIDENCE / "expected.json").read_text())
    histories = list((ROOT / "codex-a").rglob("rollout-*.jsonl"))
    assert len(histories) == count + 1, histories
    ids = [json.loads(path.read_text().splitlines()[0])["payload"]["id"] for path in histories]
    assert len(set(ids)) == len(ids) and expected["codex-a"]["sessionID"] in ids, ids
    assert requests() == json.loads((EVIDENCE / "initial-requests.json").read_text()), "Fork sent an automatic prompt"
    return {"nativeIDs": ids, "originalProcesses": current, "newPrompts": 0}


def run():
    if PHASE == "serve": return serve()
    if PHASE == "setup": return setup()
    if PHASE == "fork-setup": return fork_setup()
    assert (ROOT / ".workspace-agent-fixture").exists()
    if PHASE == "start": return start()
    if PHASE == "mode-layout":
        def layout_only():
            value = snapshot()
            panes = saved_panes(value)
            assert len(panes) == 4
            assert set(value["recovery"]["pendingAgentPaneIDs"]) == set(panes)
            for _, _, target in AGENTS:
                assert tmux("display-message", "-p", "-t", target, "#{pane_dead}") == "1"
            assert requests() == json.loads((EVIDENCE / "initial-requests.json").read_text())
            settings = json.loads((ROOT / "e2e-storage.json").read_text())["preferences"]
            assert settings["workspaceRecoveryMode"] == {"string": {"_0": "layoutOnly"}}
            return {"snapshot": value, "nativeAgentsLaunched": 0}
        return wait(layout_only)
    if PHASE == "mode-prepare-off":
        value = require_agents(snapshot())
        settings = json.loads((ROOT / "e2e-storage.json").read_text())["preferences"]
        assert settings["workspaceRecoveryMode"] == {"string": {"_0": "disabled"}}
        value["bootID"] = "disabled-recovery-simulated-previous-boot"
        JOURNAL.write_text(json.dumps(value))
        (EVIDENCE / "disabled-journal.txt").write_bytes(JOURNAL.read_bytes())
        return {"saved": True}
    if PHASE == "mode-disabled":
        assert tmux("list-sessions", "-F", "#{session_name}") == "mode-keeper"
        assert JOURNAL.read_bytes() == (EVIDENCE / "disabled-journal.txt").read_bytes()
        assert requests() == json.loads((EVIDENCE / "initial-requests.json").read_text())
        (ROOT / "stop-models").touch()
        return {"restoredSessions": 0, "journalUnchanged": True, "liveSession": "mode-keeper"}
    if PHASE == "fork-ready":
        wait(lambda: require_agents(snapshot()))
        return {"live": live_panes()}
    if PHASE in ["fork-hide-history", "fork-restore-history"]:
        preferences = json.loads((ROOT / "e2e-storage.json").read_text())["preferences"]
        assert preferences.get("autoConnectToServer") == {"bool": {"_0": True}}, "Fixture auto-connect is disabled"
        expected = json.loads((EVIDENCE / "expected.json").read_text())["claude-a"]
        history = Path(expected["history"])
        history.relative_to(ROOT)
        hidden = ROOT / "hidden-claude-history.jsonl"
        source, destination = (history, hidden) if PHASE == "fork-hide-history" else (hidden, history)
        assert source.is_file() and not destination.exists(), (source, destination)
        source.rename(destination)
        return {"history": str(history), "hidden": str(hidden)}
    if PHASE == "fork-history-unavailable":
        def unavailable():
            identity = live_panes()["claude-a"]["@ctrlx-recovery-pane"]
            pane = saved_panes(snapshot())[identity]
            assert not pane.get("agent") and "history" in pane.get("unavailableAgentReason", ""), pane
            return {"pane": pane}
        return wait(unavailable)
    if PHASE == "fork-history-restored":
        wait(lambda: require_agents(snapshot()))
        return verify_forks(0)
    if PHASE in ["fork-check-local", "fork-check-remote"]:
        return wait(lambda: verify_forks(1 if PHASE == "fork-check-local" else 2))
    if PHASE == "fork-finish":
        result = verify_forks(2)
        (ROOT / "stop-models").touch()
        return result
    if PHASE in ["captured", "survived", "rebuilt", "relaunch", "released"]:
        value = wait(lambda: require_agents(snapshot()))
        live = verify_native()
        if PHASE == "captured":
            save("baseline", value); save("baseline-processes", live)
        elif PHASE == "survived":
            assert live == json.loads((EVIDENCE / "baseline-processes.json").read_text()), "App restart replaced a live process"
        elif PHASE == "rebuilt":
            before = json.loads((EVIDENCE / "baseline.json").read_text())
            assert saved_panes(before).keys() == saved_panes(value).keys()
            assert {p["runtimeID"] for p in saved_panes(before).values()} != {p["runtimeID"] for p in saved_panes(value).values()}
            save("rebuilt-processes", live)
        elif PHASE == "relaunch":
            assert live == json.loads((EVIDENCE / "rebuilt-processes.json").read_text()), "Relaunch repeated a native resume"
        elif PHASE == "released":
            assert live == json.loads((EVIDENCE / "pending.json").read_text())["live"], "Reconciliation repeated a native resume"
        return {"snapshot": value, "live": live, "requests": requests()}
    if PHASE in ["prepare-reboot", "prepare-interruption"]:
        value = snapshot(); require_agents(value)
        value["bootID"] = "workspace-agent-simulated-boot-" + PHASE
        JOURNAL.write_text(json.dumps(value))
        if PHASE == "prepare-interruption":
            (ROOT / "hold-native-start").touch()
        return {"simulatedBootChange": True}
    if PHASE in ["pending", "pending-relaunch"]:
        pending = wait(require_pending)
        assert requests() == json.loads((EVIDENCE / "initial-requests.json").read_text())
        if PHASE == "pending-relaunch":
            previous = json.loads((EVIDENCE / "pending.json").read_text())
            assert pending["live"] == previous["live"], "Pending relaunch replaced native processes"
            assert pending["heldHook"] == previous["heldHook"] and pending["launch"] == previous["launch"], "Pending relaunch repeated a native resume"
            (ROOT / "hold-native-start").unlink()
        return pending
    if PHASE == "finish":
        verify_native(); (ROOT / "stop-models").touch()
        return {"complete": True}
    raise ValueError(PHASE)


try:
    result = run()
    save(PHASE, {"passed": True, **result})
except Exception:
    save(PHASE, {"passed": False, "error": traceback.format_exc()})
    raise
