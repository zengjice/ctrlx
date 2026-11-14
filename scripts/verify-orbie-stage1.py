#!/usr/bin/env python3
"""Opt-in Orbie native conversation acceptance; private roots and loopback models."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "CtrlxPackage/Sources/CtrlxE2ELib/Scenarios/Scripts"))
from native_agent_model import ModelFixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tmux", type=Path, help="Use this tmux executable for the private server and tests")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="cx-wf-steps-", dir="/tmp")).resolve()
    project = root / "project"
    project.mkdir()
    home = root / "private-home"
    home.mkdir()
    tmux = str(args.tmux.resolve()) if args.tmux else shutil.which("tmux")
    if not tmux:
        raise RuntimeError("tmux is required")
    servers = []
    monitors = []
    stopping = threading.Event()
    agents = []
    report = {"fixture_root": str(root), "provider": "synthetic loopback models; no user credentials", "passed": False}
    print(f"Private fixture: {root}", flush=True)

    def run(*arguments, env=None):
        return subprocess.run(arguments, check=True, text=True, capture_output=True, env=env, timeout=30).stdout

    def mux(*arguments):
        return run(tmux, "-S", str(root / "tmux.sock"), "-f", "/dev/null", *arguments)

    try:
        for plugin, cli_name in [("codex", "codex"), ("claude-code", "claude")]:
            cli = shutil.which(cli_name)
            if not cli:
                raise RuntimeError(f"{cli_name} is required")
            server = ModelFixture(cli_name, "idle", root / f"{plugin}-marker")
            servers.append(server)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            def change_scenario(server=server, plugin=plugin):
                request = root / f"approval-{plugin}"
                while not stopping.wait(0.05):
                    if request.exists():
                        server.scenario = "approval"
                        request.with_suffix(".ready").touch()
                        return
            monitor = threading.Thread(target=change_scenario, daemon=True)
            monitors.append(monitor)
            monitor.start()
            config = root / plugin
            config.mkdir()
            env = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "TERM": "xterm-256color", "HOME": str(home), "TMPDIR": "/tmp"}
            bridge = root / f"{plugin}-hook.py"
            original = REPO / ("plugin/codex/ctrlx-hooks/scripts/hook.py" if plugin == "codex" else "plugin/ctrlx-hooks/scripts/hook.py")
            source = original.read_text()
            source = source.replace('SOCKET_PATH = os.path.expanduser("~/.ctrlx/state/ingress.sock")', f"SOCKET_PATH = {str(root / 'ingress.sock')!r}")
            bridge.write_text(source)
            bridge.chmod(0o700)
            hook = {"hooks": [{"type": "command", "command": shlex.join([sys.executable, str(bridge)]), "timeout": 10}]}
            hooks = {"hooks": {event: [hook] for event in ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"]}}
            conversation = str(uuid.uuid4())
            if plugin == "codex":
                env["CODEX_HOME"] = str(config)
                (config / "config.toml").write_text(f'''model = "gpt-5.4"
model_provider = "fixture"
check_for_update_on_startup = false
cli_auth_credentials_store = "file"
[model_providers.fixture]
name = "Orbie loopback fixture"
base_url = "http://127.0.0.1:{server.server_address[1]}/v1"
wire_api = "responses"
requires_openai_auth = false
request_max_retries = 0
[projects."{project}"]
trust_level = "trusted"
''')
                (config / "hooks.json").write_text(json.dumps(hooks))
                arguments = [cli, "--no-daemon", "--no-alt-screen", "--dangerously-bypass-hook-trust", "-C", str(project)]
                conversation = ""
            else:
                env.update({"CLAUDE_CONFIG_DIR": str(config), "ANTHROPIC_API_KEY": "fixture-only", "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{server.server_address[1]}", "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"})
                (config / ".claude.json").write_text(json.dumps({"hasCompletedOnboarding": True, "theme": "dark", "projects": {str(project): {"hasTrustDialogAccepted": True}}}))
                (config / "settings.json").write_text(json.dumps(hooks))
                arguments = [cli, "--session-id", conversation, "--model", "claude-sonnet-4-5"]
            version = run(cli, "--version", env=env).strip()
            command = 'exec /usr/bin/env -i TMUX_PANE="$TMUX_PANE" ' + shlex.join([f"{key}={value}" for key, value in env.items()] + arguments)
            pane = mux("new-session", "-d", "-P", "-F", "#{pane_id}", "-s", plugin, "-x", "120", "-y", "40", "-c", str(project), "/bin/sleep 300").strip()
            mux("set-option", "-p", "-t", pane, "remain-on-exit", "on")
            mux("respawn-pane", "-k", "-t", pane, command)
            agents.append({"pluginID": plugin, "paneID": pane, "processID": int(mux("display-message", "-p", "-t", pane, "#{pane_pid}").strip()), "conversationID": conversation, "version": version})
            deadline = time.monotonic() + 30
            accepted_folder = accepted_key = False
            while time.monotonic() < deadline:
                text = mux("capture-pane", "-p", "-t", pane)
                if "Ask Codex" in text or (plugin != "codex" and "bypass permissions" in text) or (plugin != "codex" and "for shortcuts" in text):
                    break
                if plugin != "codex" and not accepted_folder and "Yes, I trust this folder" in text:
                    mux("send-keys", "-t", pane, "Down", "Enter")
                    accepted_folder = True
                if plugin != "codex" and not accepted_key and "Do you want to use this API key?" in text:
                    mux("send-keys", "-t", pane, "Up", "Enter")
                    accepted_key = True
                time.sleep(0.2)
            else:
                raise RuntimeError(f"{plugin} did not reach its input prompt: {text}")
            print(f"Ready: {plugin} {version}", flush=True)
        manifest = root / "fixture.json"
        report["tmux_version"] = mux("display-message", "-p", "#{version}").strip()
        manifest.write_text(json.dumps({"root": str(root), "tmux": str(root / "tmux.sock"), "tmuxExecutable": tmux, "agents": agents}))
        environment = dict(os.environ, CTRLX_ORBIE_NATIVE_FIXTURE=str(manifest), CTRLX_WORKFLOW_NATIVE_FRESH="1")
        with (output / "native-tests.log").open("w") as log:
            subprocess.run([str(REPO / "scripts/unit-tests.sh"), "--", "--no-parallel", "--filter", "AgentWorkflowNativeReviewLoopTests.nativeOrbieFirstAndNextMessages"], cwd=REPO, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=600, check=True)
        shutil.copyfile(root / "orbie-native-ledger.json", output / "native-ledger.json")
        report["passed"] = True
    finally:
        stopping.set()
        for monitor in monitors:
            monitor.join(timeout=1)
        report["agents"] = agents
        for agent in agents:
            try:
                (output / f"{agent['pluginID']}-terminal.txt").write_text(mux("capture-pane", "-p", "-S", "-200", "-t", agent["paneID"]))
            except subprocess.SubprocessError:
                pass
        subprocess.run([tmux, "-S", str(root / "tmux.sock"), "kill-server"], capture_output=True, timeout=10)
        for server in servers:
            server.shutdown()
            server.server_close()
        (output / "native-report.json").write_text(json.dumps(report, indent=2))
        print(json.dumps(report), flush=True)


if __name__ == "__main__":
    main()
