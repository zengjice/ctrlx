#!/usr/bin/env python3
"""Three Release window measurements with actual fixture input effects."""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import time


def percentile(values, fraction):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * fraction))] if values else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path, required=True)
    parser.add_argument("--control", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--profile", choices=["standard", "balanced"], default="standard")
    parser.add_argument("--display-mode", choices=["synchronized", "low-latency"])
    parser.add_argument("--capture-mode", choices=["window", "display"], default="window")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(mode=0o700)  # A fresh evidence directory is required.
    host = json.loads(args.host.read_text())
    assert host["configuration"] == "Release"

    def call(words):
        started = time.monotonic()
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(260); client.connect(str(args.control))
            client.sendall(json.dumps({"arguments": words}).encode() + b"\n")
            with client.makefile("rb") as stream:
                result = json.loads(stream.readline(10 * 1024 * 1024))
        with (args.output / "commands.jsonl").open("a") as log:
            log.write(json.dumps({"at": time.time(), "arguments": words, "seconds": time.monotonic() - started, **result}) + "\n")
        assert result["code"] == 0, result
        return json.loads(result["stdout"])

    assert not call(["devices"])["devices"]
    opened = call(["open", "--profile", args.profile, "--runtime", "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                   "--device-type", "com.apple.CoreSimulator.SimDeviceType.iPhone-16"])
    device = opened["device"]
    capture = None
    try:
        def action(words):
            return call(words + ["--device", device])
        action(["install", "--app", str(args.fixture.resolve())])
        action(["launch", "--bundle", "com.jicezeng.ctrlx.interaction-fixture"])
        action(["wait", "--identifier", "fixture.tap", "--timeout-ms", "60000"])
        action(["show"])
        if args.display_mode:
            action(["display-mode", "--mode", args.display_mode])
        container = subprocess.check_output(["/usr/bin/xcrun", "simctl", "--set",
            str(Path(host["root"]) / "state/agent-simulator/devices"), "get_app_container", opened["udid"],
            "com.jicezeng.ctrlx.interaction-fixture", "data"], text=True).strip()
        state_file = Path(container) / "Documents/state.json"
        time.sleep(20)
        completed = 0
        for index in range(1, 4):
            initial = action(["status", "--reset-measurements"])
            assert initial["view"]["visible"] and initial["view"]["attached"], initial
            if args.display_mode:
                assert initial["displayMode"] == args.display_mode, initial
                assert initial["view"]["displaySyncEnabled"] == (args.display_mode == "synchronized"), initial
            output = args.output / f"window-{index}.json"
            capture_arguments = [str(args.probe.resolve()), str(host["pid"]), args.title, "60", str(output.resolve())]
            if args.capture_mode == "display":
                capture_arguments.append("display")
            capture = subprocess.Popen(capture_arguments,
                stdout=(args.output / f"capture-{index}.log").open("w"), stderr=subprocess.STDOUT)
            time.sleep(5)
            inputs = []
            for _ in range(30):
                action(["tap", "--x", "164", "--y", "118", "--duration-ms", "20"])
                completed += 1
                deadline = time.monotonic() + 2
                while True:
                    state = json.loads(state_file.read_text())
                    if state["taps"] == completed: break
                    assert time.monotonic() < deadline, (completed, state)
                    time.sleep(0.01)
                diagnostic = action(["status"])["inputMeasurements"]
                inputs.append({"fixture": state, "native": diagnostic})
                time.sleep(1)
            capture.wait(timeout=60)
            assert capture.returncode == 0, (args.output / f"capture-{index}.log").read_text()
            capture = None
            window = json.loads(output.read_text())
            if args.capture_mode == "display":
                assert window["captureMode"] == "display-selected-window", window
            for sample in inputs:
                native, fixture = sample["native"], sample["fixture"]
                assert abs(native["upSubmittedAt"] - fixture["inputUpAt"]) < 0.1, sample
                matching = [frame for frame in window["frames"] if frame["taps"] == fixture["taps"] % 256
                            and frame["displayAt"] >= native["upSubmittedAt"]]
                assert matching, sample
                displayed = min(frame["displayAt"] for frame in matching)
                sample["upToWindowMs"] = (displayed - native["upSubmittedAt"]) * 1000
                sample["downToWindowMs"] = (displayed - native["downSubmittedAt"]) * 1000
                sample["fixtureUpToWindowMs"] = (displayed - fixture["inputUpAt"]) * 1000
            stats = action(["status"])
            intervals = [(b["displayAt"] - a["displayAt"]) * 1000 for a, b in zip(window["frames"], window["frames"][1:])]
            summary = {"host": host, "opened": opened, "round": index, "captureMode": args.capture_mode, "measurements": stats,
                "windowFPS": window["uniqueWindowFPS"], "windowIntervalP95Ms": percentile(intervals, 0.95),
                "windowIntervalP99Ms": percentile(intervals, 0.99), "inputs": inputs,
                "downToWindowP95Ms": percentile([row["downToWindowMs"] for row in inputs], 0.95),
                "upToWindowP95Ms": percentile([row["upToWindowMs"] for row in inputs], 0.95)}
            (args.output / f"summary-{index}.json").write_text(json.dumps(summary, indent=2))
            print(index, "window FPS", round(summary["windowFPS"], 2), "input p95 ms",
                  round(summary["downToWindowP95Ms"], 2), flush=True)
    finally:
        if capture is not None and capture.poll() is None:
            capture.terminate(); capture.wait(timeout=10)
        call(["close", "--device", device])


if __name__ == "__main__":
    main()
