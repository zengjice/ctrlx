#!/usr/bin/env python3
"""Real CEF/CLI acceptance. Only the fixed local fixture, never user browser tabs."""
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from urllib.parse import parse_qs, urlsplit

import browser_cli

ROOT = Path(__file__).resolve().parent
FIXTURE = "http://127.0.0.1:8769/index.html"


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def cli(endpoint, command, *arguments, success=True):
    result = subprocess.run([sys.executable, str(ROOT / "browser_cli.py"), "--socket", str(endpoint),
                             command, *arguments], capture_output=True, text=True, timeout=18)
    if success:
        check(result.returncode == 0, f"{command} failed: {result.stderr}")
        return json.loads(result.stdout)["result"]
    check(result.returncode == 1, f"{command} unexpectedly succeeded: {result.stdout}")
    check(json.loads(result.stderr)["ok"] is False, "Missing error response")


def rejected_frame(endpoint, data):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(endpoint))
        connection.sendall(data)
        result = bytearray()
        while b"\n" not in result:
            chunk = connection.recv(4096)
            check(chunk, "Missing rejection response")
            result.extend(chunk)
        check(json.loads(result)["ok"] is False, "Malformed/oversized request accepted")


def run_once(executable, artifacts, iteration, stale_tab=None):
    log_path = artifacts / f"run-{iteration}.log"
    endpoint = None
    with log_path.open("wb") as log:
        process = subprocess.Popen([str(executable), "--probe-automation"], stdout=log, stderr=log,
                                   start_new_session=True)
        try:
            deadline = time.monotonic() + 30
            tabs = []
            while time.monotonic() < deadline:
                check(process.poll() is None, "Probe exited before readiness; see " + str(log_path))
                content = log_path.read_text(errors="replace")
                match = re.search(r"automation-socket=(\S+)", content)
                if match:
                    endpoint = Path(match.group(1))
                    tabs = cli(endpoint, "tabs")
                    if len(tabs) == 2 and all(not tab["loading"] for tab in tabs):
                        # OnLoadingStateChange can precede the first document.
                        if all("CTRLX-CEF-EMBEDDED-2026" in cli(endpoint, "read", "--tab", tab["id"])["text"]
                               for tab in tabs):
                            break
                time.sleep(0.1)
            else:
                raise AssertionError("Startup timed out; check visible keychain prompt and " + str(log_path))
            check(content.count("automation-tab embedded-parent=verified") == 2, "Expected two native Alloy views")
            parts = [urlsplit(t["url"]) for t in tabs]
            check(all(p.scheme == "http" and p.netloc == "127.0.0.1:8769" and p.path == "/index.html"
                      and parse_qs(p.query).get("run") for p in parts), "Unexpected target URLs")
            check(parse_qs(parts[0].query)["run"] == parse_qs(parts[1].query)["run"], "Mixed launch targets")
            check(all(t["runtime"] == "alloy" for t in tabs), "Not embedded Alloy")
            first = next(t["id"] for t in tabs if "tab" not in parse_qs(urlsplit(t["url"]).query))
            second = next(t["id"] for t in tabs if parse_qs(urlsplit(t["url"]).query).get("tab") == ["B"])
            if stale_tab:
                cli(endpoint, "click", "--tab", stale_tab, "--selector", "#increment", success=False)
            before = cli(endpoint, "read", "--tab", second)
            snapshot = cli(endpoint, "read", "--tab", first)
            check("Last click: none" in snapshot["text"], "Browser loaded a stale fixture")
            check({c["selector"] for c in snapshot["controls"]} >= {"#message", "#apply", "#increment"},
                  "Snapshot missing actionable selectors")
            message = f"CDP {iteration} 中文 'quoted' \\ proof"
            cli(endpoint, "type", "--tab", first, "--selector", "#message", "--text", message)
            cli(endpoint, "click", "--tab", first, "--selector", "#apply")
            cli(endpoint, "click", "--tab", first, "--selector", "#increment")
            after = cli(endpoint, "read", "--tab", first)
            check("Applied: " + message in after["text"], "Text/click did not reach the fixture")
            check("Count: 1" in after["text"], "Click did not increment exactly once")
            check("Last click: trusted" in after["text"],
                  "Unexpected click evidence: " + repr(after["text"]))
            check(cli(endpoint, "read", "--tab", second) == before, "Action on A modified B")
            for tab, selector in (("nonexistent", "#increment"), (first, "#missing"), (first, "button")):
                cli(endpoint, "click", "--tab", tab, "--selector", selector, success=False)
            cli(endpoint, "type", "--tab", first, "--selector", "#apply", "--text", "wrong", success=False)
            check(cli(endpoint, "read", "--tab", first) == after, "Rejected action changed page")
            image_path = artifacts / f"tab-A-{iteration}.png"
            capture = cli(endpoint, "screenshot", "--tab", first, "--output", str(image_path))
            check(capture["bytes"] > 1000 and image_path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"),
                  "Screenshot missing/invalid")
            try:
                browser_cli.request(endpoint, {"command": "Runtime.evaluate", "tab": first, "expression": "1+1"})
            except ValueError:
                pass
            else:
                raise AssertionError("Raw CDP was accepted")
            for data in (b"[]\n", b'{}\n', b'{"command":123}\n', b" " * 65537 + b"\n"):
                rejected_frame(endpoint, data)
            # A partial socket client must not block other clients / Chromium UI.
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as partial:
                partial.connect(str(endpoint))
                partial.sendall(b'{"command":')
                check(len(cli(endpoint, "tabs")) == 2, "Partial request blocked the bridge")
            listeners = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(process.pid),
                                        "-iTCP", "-sTCP:LISTEN"], capture_output=True, text=True, timeout=5)
            check(listeners.returncode == 1 and not listeners.stdout, "Probe exposed a TCP listener")
            cli(endpoint, "quit")
            check(process.wait(timeout=12) == 0, "Probe did not shut down cleanly")
            check(not endpoint.exists() and not endpoint.parent.exists(), "Socket directory leaked")
            print(f"PASS run {iteration}: read/type/click/screenshot, target isolation, rejection, no TCP, clean shutdown",
                  flush=True)
            return first
        finally:
            if process.poll() is None:
                if endpoint and endpoint.exists():
                    try:
                        cli(endpoint, "quit")
                        process.wait(timeout=5)
                    except (Exception, KeyboardInterrupt):
                        print("Graceful test cleanup failed; stopping only the owned probe process group.", file=sys.stderr)
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)


def main():
    if len(sys.argv) != 2:
        raise ValueError("Usage: test_cdp_integration.py <probe executable>")
    with urllib.request.urlopen(FIXTURE, timeout=5) as response:
        check(response.read() == (ROOT / "fixture/index.html").read_bytes(), "Unexpected local fixture")
    artifacts = Path(tempfile.mkdtemp(prefix="ctrlx-cdp-proof-"))
    print(f"Proof artifacts: {artifacts}", flush=True)
    first = run_once(Path(sys.argv[1]), artifacts, 1)
    run_once(Path(sys.argv[1]), artifacts, 2, stale_tab=first)
    print("CDP acceptance PASS (independent prototype; NOT an official ChatGPT extension test)", flush=True)


if __name__ == "__main__":
    main()
