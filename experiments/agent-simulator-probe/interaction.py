#!/usr/bin/env python3
"""Actual effects and rejection cases, through a real agent's foreground driver."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path, required=True)
    parser.add_argument("--control", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device-type", default="com.apple.CoreSimulator.SimDeviceType.iPhone-16")
    parser.add_argument("--runtime", default="com.apple.CoreSimulator.SimRuntime.iOS-27-0")
    parser.add_argument("--profiles", default="standard,balanced")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Output must be a new path")
    host = json.loads(args.host.read_text())
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def event(value):
        with args.output.open("a") as file:
            file.write(json.dumps({"at": time.time(), **value}, ensure_ascii=False) + "\n")

    def request(words, expected_error=None):
        started = time.monotonic()
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(260)
            client.connect(str(args.control))
            client.sendall(json.dumps({"arguments": words}).encode() + b"\n")
            with client.makefile("rb") as stream:
                result = json.loads(stream.readline(10 * 1024 * 1024))
        event({"kind": "command", "arguments": words, "wallSeconds": time.monotonic() - started, **result})
        if expected_error is not None:
            assert result["code"] != 0 and expected_error in result["stderr"], result
            return result
        assert result["code"] == 0, result
        return json.loads(result["stdout"])

    assert not request(["devices"])["devices"], "Start without active owned devices"
    bundle = "com.jicezeng.ctrlx.interaction-fixture"
    profiles = args.profiles.split(",")
    assert profiles and all(profile in ("standard", "balanced") for profile in profiles), profiles
    for profile in profiles:
        device = None
        try:
            opened = request(["open", "--profile", profile,
                "--runtime", args.runtime,
                "--device-type", args.device_type])
            device, udid = opened["device"], opened["udid"]

            def call(words, expected_error=None):
                return request(words + ["--device", device], expected_error)

            jobs = [plistlib.loads(path.read_bytes()) for path in
                    (Path(host["root"]) / "state/agent-simulator/jobs").glob("*.plist")]
            workers = [job for job in jobs if job["ProgramArguments"][4:7] == [udid, "worker", str(host["pid"])]]
            assert len(workers) == 1, workers
            worker = workers[0]
            assert worker["ProgramArguments"][2] == host["developerDirectory"], worker
            launch = subprocess.check_output(["/bin/launchctl", "print", f"gui/{os.getuid()}/" + worker["Label"]], text=True)
            pid = re.search(r"^\s*pid = (\d+)\s*$", launch, re.MULTILINE)
            assert pid, launch
            command = subprocess.check_output(["ps", "-p", pid[1], "-o", "args="], text=True).strip()
            assert command == " ".join(worker["ProgramArguments"]), command
            event({"kind": "actual-worker", "profile": profile, "pid": int(pid[1]), "job": worker, "command": command})

            def snapshot():
                return call(["snapshot", "--limit", "1000"])

            def element(tree, identifier):
                nodes = [node for node in tree["nodes"] if node.get("identifier") == identifier]
                assert len(nodes) == 1, nodes
                return nodes[0]

            call(["install", "--app", str(args.fixture.resolve())])
            call(["launch", "--bundle", bundle])
            call(["wait", "--identifier", "fixture.tap", "--timeout-ms", "60000"])
            directory = subprocess.check_output(["/usr/bin/xcrun", "simctl", "--set",
                str(Path(host["root"]) / "state/agent-simulator/devices"), "get_app_container", udid, bundle, "data"], text=True).strip()
            state_file = Path(directory) / "Documents/state.json"
            # Use the same warm-up as the capacity/display benchmarks. Cold AX
            # startup is recorded above, before measuring interaction behavior.
            time.sleep(20)
            ready_by = time.monotonic() + 60
            while True:
                warm = snapshot()
                if not warm["partial"] and any(node.get("identifier") == "fixture.tap" for node in warm["nodes"]):
                    break
                assert time.monotonic() < ready_by, warm
                time.sleep(.5)

            def state_matches(**expected):
                deadline = time.monotonic() + 2
                while True:
                    state = json.loads(state_file.read_text())
                    if all(state[key] == value for key, value in expected.items()):
                        event({"kind": "effect", "profile": profile, "expected": expected, "state": state})
                        return state
                    assert time.monotonic() < deadline, (expected, state)
                    time.sleep(0.02)

            tree = snapshot()
            old_ref = element(tree, "fixture.tap")["ref"]
            call(["tap", "--ref", old_ref]); state_matches(taps=1)
            call(["tap", "--ref", old_ref], "Stale")
            call(["tap", "--label", "Tap counter", "--role", "AXButton"]); state_matches(taps=2)
            call(["tap", "--identifier", "fixture.ambiguous"], "ambiguous"); state_matches(taps=2)
            call(["tap", "--identifier", "fixture.missing"], "disappeared"); state_matches(taps=2)
            call(["tap", "--identifier", "fixture.arm-move"])
            before = element(snapshot(), "fixture.moving")
            time.sleep(1)
            call(["tap", "--ref", before["ref"]]); state_matches(taps=3)
            after = element(snapshot(), "fixture.moving")
            assert after["frame"]["x"] > before["frame"]["x"] + 100, (before, after)
            event({"kind": "revalidated-moving-reference", "profile": profile, "before": before, "after": after})
            call(["long-press", "--identifier", "fixture.gesture", "--duration-ms", "700"])
            state_matches(presses=1, drags=0)
            call(["drag", "--identifier", "fixture.gesture", "--end-x", "280", "--end-y", "240",
                  "--hold-ms", "500", "--duration-ms", "350"])
            dragged = state_matches(drags=1)
            assert abs(dragged["dragEndX"] - 280) < 1 and abs(dragged["dragEndY"] - 240) < 1, dragged
            assert abs(dragged["dragX"] - 280) < 5 and abs(dragged["dragY"] - 240) < 5, dragged
            call(["tap", "--identifier", "fixture.begin"])
            call(["wait", "--identifier", "fixture.loading", "--state", "visible", "--timeout-ms", "500"])
            call(["wait", "--identifier", "fixture.loading", "--state", "absent", "--timeout-ms", "100"], "timed out")
            call(["wait", "--identifier", "fixture.loading", "--state", "absent", "--timeout-ms", "5000"])
            call(["wait", "--identifier", "fixture.ready", "--timeout-ms", "1000"]); state_matches(ready=True)
            call(["wait", "--identifier", "fixture.never", "--state", "absent", "--limit", "1", "--timeout-ms", "200"], "timed out")
            call(["wait", "--identifier", "fixture.never", "--timeout-ms", "20"], "timed out")
            call(["tap", "--identifier", "fixture.tap"]); state_matches(taps=4)
            for rotation_index, orientation in enumerate(("landscape-left", "landscape-right", "portrait-upside-down", "portrait")):
                old = snapshot()
                ref = element(old, "fixture.tap")["ref"]
                rejects_upside = orientation == "portrait-upside-down" and args.device_type == "com.apple.CoreSimulator.SimDeviceType.iPhone-16"
                result = call(["rotate", "--orientation", orientation], "did not rotate" if rejects_upside else None)
                call(["tap", "--x", "164", "--y", "118"])
                state_matches(taps=5 + 2 * rotation_index)
                fresh = snapshot()
                if rejects_upside: assert fresh["geometry"]["orientation"] == old["geometry"]["orientation"], fresh
                call(["tap", "--ref", ref], "Stale")
                call(["tap", "--identifier", "fixture.tap"])
                state_matches(taps=6 + 2 * rotation_index)
                event({"kind": "rotation-effect", "profile": profile, "orientation": orientation,
                       "before": old["geometry"], "after": fresh["geometry"], "result": result})
            state_matches(taps=12)
            rotation_ref = element(snapshot(), "fixture.tap")["ref"]
            call(["rotate", "--orientation", "landscape-left"])
            call(["tap", "--ref", rotation_ref], "Stale")
            state_matches(taps=12)
            event({"kind": "rotation-invalidated-reference", "profile": profile, "ref": rotation_ref})
            call(["rotate", "--orientation", "portrait"])
            tree = snapshot(); ref = element(tree, "fixture.tap")["ref"]
            call(["terminate", "--bundle", bundle]); call(["launch", "--bundle", bundle])
            call(["wait", "--identifier", "fixture.tap", "--timeout-ms", "60000"])
            fresh = snapshot()
            assert fresh["applicationPID"] != tree["applicationPID"], (tree, fresh)
            call(["tap", "--ref", ref], "Stale")
            call(["tap", "--identifier", "fixture.tap"]); state_matches(taps=1)
            event({"kind": "profile-passed", "profile": profile})
            print(profile, "interaction cases passed", flush=True)
        finally:
            if device:
                call(["close"])


if __name__ == "__main__":
    main()
