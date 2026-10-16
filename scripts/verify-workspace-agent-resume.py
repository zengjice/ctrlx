#!/usr/bin/env python3
"""Opt-in native CLI resume evidence with synthetic local model replies.

Uses disposable configuration roots, an empty project and a private tmux socket.
No user history, API credentials, live tmux sessions or CtrlX App are used.
Artifacts remain at --output; temporary fixture paths are included in the report.
"""
import argparse
import ctypes
import json
import pathlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "CtrlxPackage/Sources/CtrlxE2ELib/Scenarios/Scripts"))
from native_agent_model import ModelFixture


def verify_process_root(pid, name, root):
    """Inspect only this fixture's child; never write its environment to artifacts."""
    libc = ctypes.CDLL("/usr/lib/libc.dylib")
    mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
    size = ctypes.c_size_t()
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or not 4 < size.value <= 2 * 1024 * 1024:
        return False
    data = (ctypes.c_ubyte * size.value)()
    if libc.sysctl(mib, 3, data, ctypes.byref(size), None, 0) != 0:
        return False
    return (name + "=" + str(root) + "\0").encode() in bytes(data[:size.value])



def verify(agent, scenario, output, tmux_path):
    cli = shutil.which(agent)
    if not cli:
        raise RuntimeError(f"{agent} is not installed")
    version = subprocess.run([cli, "--version"], capture_output=True, text=True, check=True, timeout=10).stdout.strip()
    root = pathlib.Path(tempfile.mkdtemp(prefix=f"ctrlx-resume-{agent}-", dir="/tmp"))
    config, repo, marker = root / "config", root / "repo", root / "approval-executed.txt"
    config.mkdir(); repo.mkdir()
    socket = str(root / "tmux.sock")
    server = ModelFixture(agent, scenario, marker)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "TERM": "xterm-256color"}
    session_id = str(uuid.uuid4())
    if agent == "codex":
        env["CODEX_HOME"] = str(config)
        (config / "config.toml").write_text(f'''model = "gpt-5.4"
model_provider = "fixture"
[model_providers.fixture]
name = "Fixture"
base_url = "http://127.0.0.1:{server.server_address[1]}/v1"
wire_api = "responses"
requires_openai_auth = false
request_max_retries = 0
[projects."{repo}"]
trust_level = "trusted"
''')
        options = ["--no-daemon", "--no-alt-screen", "-C", str(repo), "-a", "on-request", "-s", "workspace-write"]
        initial = [cli] + options + ["Say fixture ready."]
    else:
        env.update({"CLAUDE_CONFIG_DIR": str(config), "ANTHROPIC_API_KEY": "fixture-only", "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{server.server_address[1]}", "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"})
        (config / ".claude.json").write_text(json.dumps({"hasCompletedOnboarding": True, "theme": "dark", "projects": {str(repo.resolve()): {"hasTrustDialogAccepted": True}}}))
        options = ["--model", "claude-sonnet-4-5", "--permission-mode", "default"]
        initial = [cli, "--session-id", session_id] + options + ["Say fixture ready."]

    def tmux(*arguments, check=True):
        return subprocess.run([tmux_path, "-S", socket, "-f", "/dev/null", *arguments], text=True, capture_output=True, check=check, timeout=10)

    def start(arguments):
        command = "exec /usr/bin/env -i " + shlex.join([f"{key}={value}" for key, value in env.items()] + arguments)
        tmux("new-session", "-d", "-s", "fixture", "-x", "120", "-y", "40", "-c", str(repo), "/bin/sleep 60")
        tmux("set-option", "-p", "-t", "fixture:", "remain-on-exit", "on")
        tmux("respawn-pane", "-k", "-t", "fixture:", command)

    def screen():
        return tmux("capture-pane", "-p", "-S", "-200", "-t", "fixture:").stdout

    prefix = output / f"{agent}-{scenario}"
    report = {"agent": agent, "scenario": scenario, "version": version, "fixture_root": str(root), "automatic_resume_safe": False}
    try:
        start(initial)
        accepted_key = accepted_folder = False
        deadline = time.monotonic() + 45
        established = False
        while time.monotonic() < deadline:
            text = screen()
            if not accepted_folder and "Yes, I trust this folder" in text:
                tmux("send-keys", "-t", "fixture:", "Down", "Enter"); accepted_folder = True
            if not accepted_key and "Do you want to use this API key?" in text:
                tmux("send-keys", "-t", "fixture:", "Up", "Enter"); accepted_key = True
            if scenario == "idle":
                established = "RECOVERY_IDLE_FIXTURE" in text
            elif scenario == "approval":
                established = "Would you like to run" in text or "Do you want to proceed" in text or "Allow this" in text
            else:
                established = any(request["has_tools"] for request in server.requests)
            if established:
                break
            time.sleep(0.25)
        time.sleep(1)
        prefix.with_suffix(".before.txt").write_text(screen())
        if not established:
            raise RuntimeError("The requested initial state was not reached; inspect the before screen")
        if marker.exists():
            raise RuntimeError("The approval fixture executed before receiving permission")
        pid = int(tmux("display-message", "-p", "-t", "fixture:", "#{pane_pid}").stdout)
        root_key = "CODEX_HOME" if agent == "codex" else "CLAUDE_CONFIG_DIR"
        report["process_configuration_root_verified"] = verify_process_root(pid, root_key, config)
        if not report["process_configuration_root_verified"]:
            raise RuntimeError("The native process configuration root could not be verified")
        if agent == "codex":
            histories = list(config.rglob("rollout-*.jsonl"))
            if len(histories) != 1:
                raise RuntimeError("Expected one original native conversation")
            session_id = json.loads(histories[0].read_text().splitlines()[0])["payload"]["id"]
            resumed = [cli, "resume", session_id] + options
        else:
            histories = list(config.rglob(session_id + ".jsonl"))
            if len(histories) != 1:
                raise RuntimeError("The native conversation was not persisted")
            resumed = [cli, "--resume", session_id] + options
        report["session_id"] = session_id
        report["initial_arguments"] = initial[1:]
        report["resume_arguments"] = resumed[1:]
        tmux("kill-session", "-t", "fixture")
        requests_before = len(server.requests)
        start(resumed)
        # Observe real native startup, including delayed background continuation.
        time.sleep(8)
        text = screen()
        prefix.with_suffix(".after.txt").write_text(text)
        alive = tmux("display-message", "-p", "-t", "fixture:", "#{pane_dead}").stdout.strip() == "0"
        same_history = list(config.rglob("rollout-*.jsonl" if agent == "codex" else session_id + ".jsonl")) == histories
        new_requests = len(server.requests) - requests_before
        report.update({"new_requests_on_resume": new_requests, "approval_executed": marker.exists(), "same_history": same_history, "alive": alive})
        recovered_text = "RECOVERY_IDLE_FIXTURE" in text if scenario == "idle" else "Say fixture ready." in text
        report["automatic_resume_safe"] = alive and same_history and recovered_text and not marker.exists() and new_requests == 0
    except Exception as error:
        report["error"] = str(error)
    finally:
        tmux("kill-server", check=False)
        server.release.set(); server.shutdown(); server.server_close()
        report["requests"] = server.requests
        prefix.with_suffix(".json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"{agent} {version} {scenario}: {'PASS' if report['automatic_resume_safe'] else 'UNVERIFIED'}", flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", choices=["codex", "claude", "all"], default="all")
    parser.add_argument("--scenario", choices=["idle", "interrupted", "approval", "all"], default="all")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    tmux = shutil.which("tmux")
    if not tmux:
        parser.error("tmux is required")
    reports = [verify(agent, scenario, args.output, tmux)
               for agent in (["codex", "claude"] if args.agent == "all" else [args.agent])
               for scenario in (["idle", "interrupted", "approval"] if args.scenario == "all" else [args.scenario])]
    (args.output / "report.json").write_text(json.dumps(reports, indent=2) + "\n")
    return 0 if all(report["automatic_resume_safe"] for report in reports) else 1


if __name__ == "__main__":
    raise SystemExit(main())
