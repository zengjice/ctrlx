#!/usr/bin/env python3
"""Kill only this isolated app's verified helpers; observe recovery and isolation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path, required=True)
    parser.add_argument("--control", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Output must be a new path")
    host = json.loads(args.host.read_text())
    assert subprocess.check_output(["ps", "-p", str(host["pid"]), "-o", "comm="], text=True).strip() == str(Path(host["app"]) / "Contents/MacOS/CtrlX")
    root = Path(host["root"]) / "state/agent-simulator"
    helper = str(Path(host["app"]) / "Contents/Helpers/CtrlxSimulatorHost")
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def event(value):
        with args.output.open("a") as file:
            file.write(json.dumps({"at": time.time(), **value}, ensure_ascii=False) + "\n")

    def request(words, must_succeed=True):
        started = time.monotonic()
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(260); client.connect(str(args.control))
            client.sendall(json.dumps({"arguments": words}).encode() + b"\n")
            with client.makefile("rb") as stream:
                result = json.loads(stream.readline(10 * 1024 * 1024))
        event({"kind": "command", "arguments": words, "wallSeconds": time.monotonic() - started, **result})
        if must_succeed:
            assert result["code"] == 0, result
            return json.loads(result["stdout"])
        return result

    def helper_pid(udid, role):
        jobs = []
        for file in (root / "jobs").glob("*.plist"):
            job = plistlib.loads(file.read_bytes()); words = job["ProgramArguments"]
            if words[0] == helper and words[4:7] == [udid, role, str(host["pid"])]:
                jobs.append(job)
        assert len(jobs) == 1, jobs
        job = jobs[0]
        text = subprocess.check_output(["/bin/launchctl", "print", f"gui/{os.getuid()}/" + job["Label"]], text=True)
        matches = re.findall(r"^\s*pid = (\d+)\s*$", text, re.MULTILINE)
        assert len(matches) == 1, text
        pid = int(matches[0])
        assert subprocess.check_output(["ps", "-p", str(pid), "-o", "comm="], text=True).strip() == helper
        return pid

    assert not request(["devices"])["devices"], "Start without active owned devices"
    request(["config", "--max-devices", "2"])
    active = []
    bundle = "com.jicezeng.ctrlx.simulator-fixture"
    files = {}
    try:
        for _ in range(2):
            opened = request(["open", "--profile", "balanced", "--runtime", "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                "--device-type", "com.apple.CoreSimulator.SimDeviceType.iPhone-16"])
            active.append(opened)
            device, udid = opened["device"], opened["udid"]
            request(["install", "--device", device, "--app", str(args.fixture.resolve())])
            request(["launch", "--device", device, "--bundle", bundle])
            request(["wait", "--device", device, "--identifier", "fixture.tap", "--timeout-ms", "60000"])
            directory = subprocess.check_output(["/usr/bin/xcrun", "simctl", "--set", str(root / "devices"),
                "get_app_container", udid, bundle, "data"], text=True).strip()
            files[udid] = Path(directory) / "Documents/state.json"
        first, second = active
        time.sleep(20)
        for item in active:
            deadline = time.monotonic() + 60
            while True:
                tree = request(["snapshot", "--device", item["device"], "--limit", "1000"])
                if not tree["partial"] and any(node.get("identifier") == "fixture.tap" for node in tree["nodes"]):
                    break
                assert time.monotonic() < deadline, tree
                time.sleep(.5)

        def counter(item, expected):
            deadline = time.monotonic() + 2
            while True:
                value = json.loads(files[item["udid"]].read_text())
                if value["taps"] == expected:
                    event({"kind": "effect", "device": item["device"], "state": value}); return
                assert time.monotonic() < deadline, (expected, value)
                time.sleep(0.02)

        worker = helper_pid(first["udid"], "worker")
        inspector = helper_pid(first["udid"], "inspector")
        event({"kind": "fault", "role": "inspector", "pid": inspector, "signal": "SIGKILL"})
        os.kill(inspector, signal.SIGKILL)
        deadline = time.monotonic() + 12
        while True:
            result = request(["snapshot", "--device", first["device"], "--limit", "1000"], False)
            if result["code"] == 0 and not json.loads(result["stdout"])["partial"]: break
            assert time.monotonic() < deadline, result
            time.sleep(0.1)  # Retry a read; never replay an uncertain input.
        replacement = helper_pid(first["udid"], "inspector")
        assert replacement != inspector and helper_pid(first["udid"], "worker") == worker
        request(["tap", "--device", first["device"], "--identifier", "fixture.tap"]); counter(first,1)
        event({"kind": "inspector-recovered", "oldPID": inspector, "newPID": replacement, "workerPID": worker})
        event({"kind": "fault", "role": "worker", "pid": worker, "signal": "SIGKILL"})
        os.kill(worker,signal.SIGKILL)
        result = request(["tap", "--device", first["device"], "--identifier", "fixture.tap"], False)
        assert result["code"] != 0, result
        request(["tap", "--device", second["device"], "--identifier", "fixture.tap"]); counter(second,1); counter(first,1)
        content = files[first["udid"]].read_bytes()
        request(["close", "--device", first["device"]]); active.remove(first)
        reopened = request(["open", "--profile", "balanced", "--runtime", "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            "--device-type", "com.apple.CoreSimulator.SimDeviceType.iPhone-16"])
        active.append(reopened)
        assert reopened["device"] != first["device"], (first,reopened)
        assert files[first["udid"]].read_bytes() == content
        if reopened["udid"] not in files:
            directory = subprocess.check_output(["/usr/bin/xcrun", "simctl", "--set", str(root / "devices"),
                "get_app_container", reopened["udid"], bundle, "data"], text=True).strip()
            files[reopened["udid"]] = Path(directory) / "Documents/state.json"
        request(["launch", "--device", reopened["device"], "--bundle", bundle])
        request(["wait", "--device", reopened["device"], "--identifier", "fixture.tap", "--timeout-ms", "60000"])
        request(["tap", "--device", reopened["device"], "--identifier", "fixture.tap"]); counter(reopened,1); counter(second,1)
        event({"kind": "worker-recovered", "oldDevice": first["device"], "newDevice": reopened["device"],
               "oldUDID": first["udid"], "newUDID": reopened["udid"],
               "retainedStateSHA256": hashlib.sha256(content).hexdigest(), "unaffectedDevice": second["device"]})
    finally:
        for item in active:
            request(["close", "--device", item["device"]])
    assert not request(["devices"])["devices"]
    assert not list((root / "jobs").glob("*.plist")), "Helpers remain registered after closing"
    event({"kind": "passed"})
    print("Inspector recovery, worker close/reopen, data retention and second-device isolation passed", flush=True)


if __name__ == "__main__":
    main()
