#!/usr/bin/env python3
"""Opt-in capacity measurement through an already running real-agent driver.

Use a private CtrlX state root. Each device runs the same installed fixture,
AX observation, physical input and screenshot loop. Keep raw per-device and
system samples; process footprints are not estimates of reclaimable RAM.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import ctypes
import hashlib
import json
from pathlib import Path
import re
import socket
import subprocess
import threading
import time


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user", "system", "idle", "interrupt", "pageins", "wired", "resident",
        "footprint", "start", "exit")]


libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
libproc.proc_pid_rusage.restype = ctypes.c_int
libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
libproc.proc_pidpath.restype = ctypes.c_int


def process_samples(host):
    rows = subprocess.check_output(["ps", "-axo", "pid,ppid,%cpu,command"], text=True)
    entries = []
    for line in rows.splitlines()[1:]:
        parts = line.strip().split(None, 3)
        if len(parts) == 4:
            entries.append((int(parts[0]), int(parts[1]), float(parts[2]), parts[3]))
    agent = {host["agentPID"]} if "agentPID" in host else set()
    compiler = {host["compilerPID"]} if "compilerPID" in host else set()
    device_groups = {}
    for device, udid in host.get("deviceUDIDs", {}).items():
        needle = udid + "/data/var/run/launchd_bootstrap"
        device_groups[device] = {pid for pid, _, _, command in entries if needle in command}
    selected = {host["pid"]} | agent | compiler | set().union(*device_groups.values())
    for _ in entries:
        children = {pid for pid, parent, _, _ in entries if parent in selected}
        if children <= selected:
            break
        selected |= children
    for _ in entries:
        children = {pid for pid, parent, _, _ in entries if parent in agent}
        if children <= agent:
            break
        agent |= children
    for _ in entries:
        children = {pid for pid, parent, _, _ in entries if parent in compiler}
        if children <= compiler:
            break
        compiler |= children
    for group in device_groups.values():
        for _ in entries:
            children = {pid for pid, parent, _, _ in entries if parent in group}
            if children <= group:
                break
            group |= children
    result = []
    for pid, parent, cpu, command in entries:
        helper = str(Path(host["root"]) / "state/agent-simulator") in command
        if pid not in selected and not helper:
            continue
        usage = Usage()
        if libproc.proc_pid_rusage(pid, 0, ctypes.byref(usage)) != 0:
            continue  # A short-lived CLI may exit between the two process samples.
        executable = ctypes.create_string_buffer(4096)
        path_bytes = libproc.proc_pidpath(pid, executable, len(executable))
        device = next((key for key, group in device_groups.items() if pid in group), None)
        result.append({"pid": pid, "ppid": parent, "cpuPercent": cpu, "device": device,
                       "helperRole": next((role for role in ("worker", "inspector") if helper and f" {role} " in command), None),
                       "executable": Path(executable.value.decode("utf-8", "replace")).name if path_bytes > 0 else None,
                       "footprintBytes": usage.footprint, "residentBytes": usage.resident,
                       "start": usage.start, "cpuUser": usage.user, "cpuSystem": usage.system,
                       "role": "compiler" if pid in compiler else "simulator" if device else "agent" if pid in agent else "host" if pid == host["pid"] else
                       ("simulator-helper" if helper else "host-child")})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path, required=True)
    parser.add_argument("--control", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--profile", choices=["standard", "balanced"], required=True)
    parser.add_argument("--tiers", default="1,2,4,8,12")
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--driver-usage", action="store_true", help="Use a driver started with the CPU measurement endpoint")
    parser.add_argument("--stability", action="store_true", help="Use InteractionFixture with periodic rotation and tab switching")
    parser.add_argument("--probe", type=Path, help="Capture the foreground fixture's window barcode")
    parser.add_argument("--png-probe", type=Path, help="Verify the last screenshot's fixture counter after each tier")
    parser.add_argument("--continue-after-interaction-limit", action="store_true",
        help="Measure the functional/resource ceiling while retaining failed display targets")
    parser.add_argument("--compiler-identity", type=Path,
        help="Optional owned compiler PID/start identity created during the stability run")
    parser.add_argument("--title", default="sim-capacity")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output = args.output.resolve()
    if args.output.exists():
        parser.error("Output must be a new path")
    tiers = [int(value) for value in args.tiers.split(",")]
    if not tiers or sorted(set(tiers)) != tiers or not 1 <= tiers[0] <= tiers[-1] <= 32:
        parser.error("Tiers must be increasing, unique counts in 1...32")
    if not 10 <= args.seconds <= 1800:
        parser.error("Duration must be 10...1800 seconds")
    if args.probe and args.stability:
        parser.error("Window barcode measurements require the portrait capacity fixture")
    host = json.loads(args.host.read_text())
    fixture_binary = "InteractionFixture" if args.stability else "SimulatorFixture"
    fixture_bundle = "com.jicezeng.ctrlx.interaction-fixture" if args.stability else "com.jicezeng.ctrlx.simulator-fixture"
    host_command = subprocess.check_output(["ps", "-p", str(host["pid"]), "-o", "comm="], text=True).strip()
    if host_command != str(Path(host["app"]) / "Contents/MacOS/CtrlX"):
        parser.error("Host PID no longer identifies this test app")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    images = args.output.parent / (args.output.stem + "-images")
    images.mkdir(mode=0o700)
    event_lock = threading.Lock()
    failed = threading.Event()

    def event(value):
        with event_lock, args.output.open("a") as file:
            file.write(json.dumps({"at": time.time(), **value}, ensure_ascii=False) + "\n")

    def exchange(request):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(260)
            client.connect(str(args.control))
            client.sendall(json.dumps(request).encode() + b"\n")
            with client.makefile("rb") as stream:
                result = json.loads(stream.readline(10 * 1024 * 1024))
        if result["code"]:
            raise RuntimeError(result["stderr"].strip())
        return json.loads(result["stdout"])

    def call(words):
        return exchange({"arguments": words})

    def driver_usage():
        return exchange({"measure": True}) if args.driver_usage else None

    def sample_processes():
        host.pop("compilerPID", None)
        if args.compiler_identity and args.compiler_identity.exists():
            identity = json.loads(args.compiler_identity.read_text())
            usage = Usage()
            if libproc.proc_pid_rusage(identity["pid"], 0, ctypes.byref(usage)) == 0 and usage.start == identity["start"]:
                host["compilerPID"] = identity["pid"]
        return process_samples(host)

    identity = call(["identity"])
    host["agentPID"] = identity["owner"]["pid"]
    if call(["devices"]).get("devices"):
        parser.error("Start with no active devices owned by this agent")
    call(["config", "--max-devices", str(tiers[-1])])
    event({"kind": "environment", "identity": identity, "configuration": host["configuration"],
           "profile": args.profile, "tiers": tiers, "durationSeconds": args.seconds,
           "fixtureSHA256": hashlib.sha256((args.fixture / fixture_binary).read_bytes()).hexdigest(),
           "stability": args.stability,
           "system": call(["resources"]), "processes": sample_processes(), "driverUsage": driver_usage(),
           "coreSimulator": subprocess.check_output(["/usr/libexec/PlistBuddy", "-c",
               "Print :CFBundleVersion", "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/Info.plist"], text=True).strip(),
           "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip()})
    devices = []
    host["deviceUDIDs"] = {}
    counters = {}
    state_files = {}
    capture = None

    def counter_value(snapshot):
        counter = [node for node in snapshot["nodes"] if node.get("identifier") == "fixture.counter"]
        match = re.search(r"Taps:\s*(\d+)", json.dumps(counter))
        if len(counter) != 1 or match is None:
            raise RuntimeError("Fixture counter missing or ambiguous")
        return int(match.group(1)), counter[0]

    def workload(device, deadline):
        count = 0
        failures = 0
        expected = counters[device]
        last_picture = None
        last_counter = None
        while time.monotonic() < deadline and not failed.is_set():
            started = time.monotonic()
            output = images / (device + ".png")
            phase = "tap"
            timings = {}
            try:
                if args.stability and count > 0 and count % 50 == 0:
                    orientation = ("landscape-left", "landscape-right", "portrait")[(count // 50 - 1) % 3]
                    phase = "rotate"
                    call(["rotate", "--device", device, "--orientation", orientation])
                    event({"kind": "rotation", "device": device, "orientation": orientation})
                phase = "tap"
                call(["tap", "--device", device, "--identifier", "fixture.tap"])
                timings["tap"] = (time.monotonic() - started) * 1000
                expected += 1
                phase = "snapshot"
                operation_started = time.monotonic()
                snapshot = call(["snapshot", "--device", device, "--limit", "1000"])
                timings["snapshot"] = (time.monotonic() - operation_started) * 1000
                observed, counter = counter_value(snapshot)
                if observed != expected:
                    raise RuntimeError(f"Tap effect mismatch: expected {expected}, observed {observed}")
                input_state = json.loads(state_files[device].read_text())
                if input_state["taps"] != expected:
                    raise RuntimeError("Fixture state and accessibility counter disagree")
                phase = "swipe"
                operation_started = time.monotonic()
                geometry = snapshot["geometry"]
                landscape = geometry["orientation"] in (3, 4)
                width = (geometry["height"] if landscape else geometry["width"]) / geometry["scale"]
                height = (geometry["width"] if landscape else geometry["height"]) / geometry["scale"]
                coordinates = [str(width / 2), str(height * 0.85), str(width / 2), str(height * 0.8)] if args.stability else ["196", "790", "196", "740"]
                call(["swipe", "--device", device, "--x", coordinates[0], "--y", coordinates[1],
                      "--end-x", coordinates[2], "--end-y", coordinates[3], "--duration-ms", "150"])
                timings["swipe"] = (time.monotonic() - operation_started) * 1000
                phase = "screenshot"
                operation_started = time.monotonic()
                picture = call(["screenshot", "--device", device, "--output", str(output)])
                timings["screenshot"] = (time.monotonic() - operation_started) * 1000
                content = output.read_bytes()
                last_picture, last_counter = content, expected
                event({"kind": "task", "device": device, "seconds": time.monotonic() - started,
                       "timingsMs": timings,
                       "input": {key: input_state[key] for key in ("taps", "inputDownAt", "inputUpAt")},
                       "counter": counter, "screenshotBytes": picture["bytes"],
                       "screenshotSHA256": hashlib.sha256(content).hexdigest()})
            except RuntimeError as error:
                failures += 1
                event({"kind": "task-failed", "device": device, "phase": phase,
                       "seconds": time.monotonic() - started, "error": str(error)})
                failed.set()
                break
            finally:
                output.unlink(missing_ok=True)
            count += 1
        if args.png_probe and last_picture is not None:
            (images / f"{device}-tier-{tier}-last.png").write_bytes(last_picture)
        return {"completed": count, "failed": failures, "lastCounter": last_counter}

    try:
        for tier in tiers:
            previous_count = len(devices)
            capacity_limit = False
            while len(devices) < tier:
                started = time.monotonic()
                try:
                    opened = call(["open", "--profile", args.profile,
                                   "--runtime", "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                                   "--device-type", "com.apple.CoreSimulator.SimDeviceType.iPhone-16"])
                except RuntimeError as error:
                    resource_limit = any(text in str(error) for text in (
                        "Memory pressure is elevated", "Insufficient reclaimable memory",
                        "Insufficient free disk space", "configured simulator"))
                    event({"kind": "admission-limit" if resource_limit else "open-failed", "requestedTier": tier,
                           "openedCount": len(devices), "error": str(error), "system": call(["resources"])})
                    if resource_limit and len(devices) > previous_count:
                        # Validate a partially admitted tier, e.g. three devices
                        # when the fourth is refused. Booting alone is not capacity.
                        capacity_limit = True
                        tier = len(devices)
                        break
                    return
                device = opened["device"]
                devices.append(device)
                host["deviceUDIDs"][device] = opened["udid"]
                event({"kind": "boot", "device": device, "udid": opened["udid"],
                       "seconds": time.monotonic() - started})
                call(["install", "--device", device, "--app", str(args.fixture.resolve())])
                call(["launch", "--device", device, "--bundle", fixture_bundle])
                container = subprocess.check_output(["xcrun", "simctl", "--set",
                    str(Path(host["root"]) / "state/agent-simulator/devices"), "get_app_container",
                    opened["udid"], fixture_bundle, "data"], text=True).strip()
                state_files[device] = Path(container) / "Documents/state.json"
            call(["show", "--device", devices[0]])
            # Equal warm-up before every concurrency tier.
            time.sleep(20)
            for device in devices:
                ready_by = time.monotonic() + 60
                while True:
                    try:
                        warm = call(["snapshot", "--device", device, "--limit", "1000"])
                        if warm["partial"]:
                            raise RuntimeError("The warm-up AX tree is incomplete")
                        counters[device], _ = counter_value(warm)
                        break
                    except RuntimeError as error:
                        event({"kind": "warmup-failed", "device": device, "error": str(error)})
                        if time.monotonic() >= ready_by:
                            raise
                        time.sleep(0.5)
                warm_picture = images / (device + "-warmup.png")
                warm_started = time.monotonic()
                try:
                    picture = call(["screenshot", "--device", device, "--output", str(warm_picture)])
                    event({"kind": "screenshot-warmup", "device": device,
                        "seconds": time.monotonic() - warm_started, "bytes": picture["bytes"]})
                finally:
                    warm_picture.unlink(missing_ok=True)
            slim = call(["metrics", "--device", devices[0]])
            event({"kind": "tier-start", "count": tier, "system": call(["resources"]),
                   "driverUsage": driver_usage(),
                   "foreground": call(["status", "--device", devices[0], "--reset-measurements"]),
                   "simslimMeasurement": slim})
            window_output = args.output.with_name(args.output.stem + f"-window-{tier}.json")
            if args.probe:
                capture = subprocess.Popen([str(args.probe.resolve()), str(host["pid"]), args.title,
                    str(args.seconds), str(window_output)], stdout=subprocess.DEVNULL)
                time.sleep(3)
            started = time.monotonic()
            deadline = started + args.seconds
            next_tab_switch = started + 60
            visible_index = 0
            with ThreadPoolExecutor(max_workers=tier) as pool:
                tasks = [pool.submit(workload, device, deadline) for device in devices]
                while any(not task.done() for task in tasks):
                    if args.stability and tier > 1 and time.monotonic() >= next_tab_switch:
                        visible_index = (visible_index + 1) % tier
                        call(["show", "--device", devices[visible_index]])
                        event({"kind": "tab-switch", "device": devices[visible_index],
                               "statuses": [call(["status", "--device", device]) for device in devices]})
                        next_tab_switch += 60
                    processes = sample_processes()
                    system = call(["resources"])
                    if system["system"]["freeDiskBytes"] < 512 * 1024 * 1024 or system["system"]["pressureLevel"] == 4:
                        event({"kind": "resource-load-limit", "count": tier, "system": system,
                               "seconds": time.monotonic() - started})
                        failed.set()
                        raise RuntimeError("Capacity workload stopped at critical memory pressure or below 512 MiB free disk")
                    measurements = {}
                    for device in devices:
                        tree = [row for row in processes if row["device"] == device]
                        measurements[device] = {"processes": len(tree),
                            "bytes": sum(row["footprintBytes"] for row in tree),
                            "cpuPercent": sum(row["cpuPercent"] for row in tree)}
                    event({"kind": "sample", "count": tier, "system": system,
                           "driverUsage": driver_usage(),
                           "processes": processes, "devices": measurements,
                           "foreground": call(["status", "--device", devices[0]])})
                    time.sleep(5)
                counts = [task.result() for task in tasks]
            elapsed = time.monotonic() - started
            if args.png_probe:
                for device, count in zip(devices, counts):
                    if count["lastCounter"] is None:
                        continue
                    picture = images / f"{device}-tier-{tier}-last.png"
                    result = subprocess.run([str(args.png_probe.resolve()), "--png", str(picture)],
                        capture_output=True, text=True, timeout=15)
                    assert result.returncode == 0, result.stderr or result.stdout
                    decoded = json.loads(result.stdout)
                    assert decoded["taps"] == count["lastCounter"] % 256, (count, decoded)
                    event({"kind": "screenshot-verified", "device": device,
                        "expectedTaps": count["lastCounter"], "decoded": decoded,
                        "path": str(picture)})
            window_summary = None
            if capture:
                capture.wait(timeout=15)
                assert capture.returncode == 0, "Window measurement failed; this tier has no valid display result"
                capture = None
                window = json.loads(window_output.read_text())
                tasks_in_log = [json.loads(line) for line in args.output.read_text().splitlines()]
                up_latencies = []
                for task in tasks_in_log:
                    if task["kind"] != "task" or task["device"] != devices[0]: continue
                    touched = task["input"]
                    matching = [frame["displayAt"] for frame in window["frames"]
                        if frame["taps"] == touched["taps"] % 256
                        and touched["inputUpAt"] <= frame["displayAt"] <= touched["inputUpAt"] + 2]
                    if matching: up_latencies.append((min(matching) - touched["inputUpAt"]) * 1000)
                assert up_latencies, "No input effects matched the measured window"
                up_latencies.sort()
                window_summary = {"fps": window["uniqueWindowFPS"], "rejected": window["barcodeRejected"],
                    "inputSamples": len(up_latencies), "fixtureUpToWindowP95Ms": up_latencies[min(len(up_latencies)-1, int(len(up_latencies)*.95))]}
            event({"kind": "tier-end", "count": tier, "tasks": counts, "seconds": elapsed,
                   "window": window_summary,
                   "driverUsage": driver_usage(),
                   "tasksPerMinute": sum(item["completed"] for item in counts) * 60 / elapsed,
                   "foreground": call(["status", "--device", devices[0]])})
            print(args.profile, tier, "devices:", counts, "in", round(elapsed, 2), "seconds", flush=True)
            if any(item["failed"] for item in counts):
                event({"kind": "workload-limit", "count": tier, "tasks": counts,
                       "system": call(["resources"])})
                return
            if window_summary and (window_summary["fps"] < 58 or window_summary["fixtureUpToWindowP95Ms"] > 100):
                event({"kind": "interaction-limit", "count": tier, "window": window_summary,
                       "system": call(["resources"])})
                if not args.continue_after_interaction_limit:
                    return
            if capacity_limit:
                return
    except Exception as error:
        statuses = []
        for device in devices:
            try:
                statuses.append({"device": device, "status": call(["status", "--device", device])})
            except Exception as status_error:
                statuses.append({"device": device, "error": str(status_error)})
        event({"kind": "run-failed", "error": str(error), "identity": call(["identity"]),
               "system": call(["resources"]), "statuses": statuses})
        raise
    finally:
        if capture is not None and capture.poll() is None:
            capture.terminate(); capture.wait(timeout=10)
        for device in devices:
            try:
                result = call(["close", "--device", device])
                event({"kind": "close", "device": device, "result": result})
            except Exception as error:
                event({"kind": "close-failed", "device": device, "error": str(error)})


if __name__ == "__main__":
    main()
