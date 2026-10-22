"""Measure a signed isolated App without production state or global input."""

import ctypes
import json
import math
import platform
from pathlib import Path
import shlex
import statistics
import subprocess
import sys
import threading
import time
import traceback
import urllib.request


PHASE, ROOT, SOCKET = sys.argv[1], Path(sys.argv[2]).resolve(), sys.argv[3]
assert Path(SOCKET).name.startswith("cx-workspace-performance-")
assert ROOT.parent.name.startswith("cx-workspace-performance-")
EVIDENCE = ROOT.parent / "evidence"
EVIDENCE.mkdir(parents=True, exist_ok=True)
JOURNAL = ROOT / "Recovery/workspace.json"
STORAGE = ROOT / "e2e-storage.json"
SESSION_COUNT, WINDOWS_PER_SESSION, PANES_PER_WINDOW = 12, 4, 2


def tmux(*args):
    return subprocess.check_output(["tmux", "-f", "/dev/null", "-S", SOCKET, *args], text=True).strip()


def save(name, value):
    (EVIDENCE / f"performance-{name}.json").write_text(json.dumps(value, indent=2) + "\n")


def journal():
    return json.loads(JOURNAL.read_text())


def app_pid():
    matches = []
    for line in subprocess.check_output(["ps", "-axww", "-o", "pid=,args="], text=True).splitlines():
        pid, command = line.strip().split(maxsplit=1)
        if "/Contents/MacOS/CtrlX --e2e-test" not in command:
            continue
        args = shlex.split(command)
        if "--ctrlx-state-root" in args and Path(args[args.index("--ctrlx-state-root") + 1]).resolve() == ROOT:
            assert args[args.index("--tmux-socket") + 1] == SOCKET
            matches.append(int(pid))
    assert len(matches) == 1, matches
    return matches[0]


# Darwin rusage_info_v2 CPU counters use Mach absolute-time units.
class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


TIMEBASE = Timebase()
assert ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(TIMEBASE)) == 0
CPU_SECONDS_PER_TICK = TIMEBASE.numer / TIMEBASE.denom / 1e9


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user", "system", "packageWakeups", "interruptWakeups", "pageins",
            "wired", "resident", "footprint", "start", "exit", "childUser",
            "childSystem", "childPackageWakeups", "childInterruptWakeups",
            "childPageins", "childElapsed", "diskRead", "diskWrite",
        )
    ]


def usage(pid):
    result = Usage()
    proc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    proc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    assert proc.proc_pid_rusage(pid, 2, ctypes.byref(result)) == 0, ctypes.get_errno()
    assert result.exit == 0
    return result


def wait_stable(seconds=5):
    deadline, unchanged = time.monotonic() + 20, time.monotonic()
    previous = None
    while time.monotonic() < deadline:
        try:
            data = journal()
            assert len(data["sessions"]) == SESSION_COUNT
            assert sum(len(w["panes"]) for s in data["sessions"] for w in s["windows"]) == 96
            assert not data.get("recovery")
            current = (data["generation"], JOURNAL.stat().st_mtime_ns)
            if current != previous:
                unchanged, previous = time.monotonic(), current
            if time.monotonic() - unchanged >= seconds:
                return data
        except (FileNotFoundError, AssertionError):
            unchanged = time.monotonic()
        time.sleep(.05)
    raise AssertionError("The checkpoint did not settle")


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def measure(pid, seconds, resize=False, checkpoints=True):
    # This existing endpoint dispatches its reply on MainActor. Timings include
    # loopback transport and sampling overhead, not just main-thread execution.
    listeners = subprocess.check_output(["lsof", "-nP", "-iTCP:18081", "-sTCP:LISTEN", "-t"], text=True).split()
    assert set(listeners) == {str(pid)}, listeners
    stop = threading.Event()
    latencies, failures = [], []

    def heartbeat():
        while not stop.is_set():
            started = time.monotonic()
            try:
                with urllib.request.urlopen("http://127.0.0.1:18081/otlp-port", timeout=2) as response:
                    assert response.status == 200 and response.read().strip().isdigit()
                latencies.append((time.monotonic() - started) * 1000)
            except Exception as error:
                failures.append(str(error))
            stop.wait(.05)

    initial = journal()
    initial_mtime = JOURNAL.stat().st_mtime_ns
    before, start = usage(pid), time.monotonic()
    observed = {initial["generation"]}
    requests, last_mutation = 0, None
    worker = threading.Thread(target=heartbeat)
    worker.start()
    try:
        while time.monotonic() - start < seconds:
            if resize:
                width = 45 + requests % 60
                tmux("resize-pane", "-t", "recovery-perf-00:0.0", "-x", str(width))
                requests += 1
                last_mutation = time.monotonic()
            observed.add(journal()["generation"])
            time.sleep(.025)
        drain_started = time.monotonic()
        if resize and checkpoints:
            expected = tmux("display-message", "-p", "-t", "recovery-perf-00:0", "#{window_layout}")
            while True:
                data = journal()
                observed.add(data["generation"])
                actual = next(s for s in data["sessions"] if s["name"] == "recovery-perf-00")["windows"][0]
                # Compare the saved tree's pane widths to the live layout leaves.
                pane_widths = [int(v) for v in tmux("list-panes", "-t", "recovery-perf-00:0", "-F", "#{pane_width}").splitlines()]
                saved_widths = [p["pane"]["width"] for p in actual["layout"]["horizontal"]["_0"]]
                if pane_widths == saved_widths:
                    break
                assert time.monotonic() - drain_started < 5, (expected, actual)
                time.sleep(.025)
        saved_at = time.monotonic()
        final, after = journal(), usage(pid)
        elapsed = time.monotonic() - start
    finally:
        stop.set()
        worker.join(timeout=3)
        assert not worker.is_alive()
    assert not failures, failures
    assert latencies
    writes = final["generation"] - initial["generation"]
    if resize and checkpoints:
        assert 0 < writes <= math.ceil(elapsed / 2) + 1, (requests, writes)
    else:
        assert writes == 0, writes
        assert JOURNAL.stat().st_mtime_ns == initial_mtime
    return {
        "pid": pid, "seconds": elapsed, "resizeRequests": requests,
        "generationDelta": writes, "observedGenerations": sorted(observed),
        "finalLayoutSaveDelayMs": (saved_at - last_mutation) * 1000 if resize and checkpoints else None,
        "cpuSeconds": (after.user + after.system - before.user - before.system) * CPU_SECONDS_PER_TICK,
        "exitedChildCPUSeconds": (after.childUser + after.childSystem - before.childUser - before.childSystem) * CPU_SECONDS_PER_TICK,
        "cpuPercentOfOneCore": (after.user + after.system - before.user - before.system) * CPU_SECONDS_PER_TICK / elapsed * 100,
        "residentBytes": after.resident, "physicalFootprintBytes": after.footprint,
        "processDiskWriteBytes": after.diskWrite - before.diskWrite,
        "journalBytes": JOURNAL.stat().st_size,
        "mainActorRoundTripMs": {
            "samples": len(latencies), "median": statistics.median(latencies),
            "p95": percentile(latencies, .95), "max": max(latencies),
        },
    }


def main():
    if PHASE == "setup":
        assert not STORAGE.exists() and not JOURNAL.exists()
        ROOT.mkdir(parents=True, exist_ok=True)
        STORAGE.write_text(json.dumps({"preferences": {"workspaceRecoveryMode": {"string": {"_0": "layoutAndAgents"}}}, "sessionKeys": {}, "secrets": {}}))
        tmux("respawn-pane", "-k", "-t", "recovery-perf-00:0.0", "-c", str(ROOT), "/bin/cat")
        for session in range(SESSION_COUNT):
            name = f"recovery-perf-{session:02}"
            if session:
                tmux("new-session", "-d", "-s", name, "-x", "160", "-y", "50", "-c", str(ROOT), "/bin/cat")
            for window in range(WINDOWS_PER_SESSION):
                if window:
                    tmux("new-window", "-d", "-t", name, "-c", str(ROOT), "/bin/cat")
                tmux("split-window", "-d", "-h", "-t", f"{name}:{window}", "-c", str(ROOT), "/bin/cat")
        save(PHASE, {"passed": True, "sessions": SESSION_COUNT, "windows": 48, "panes": 96})
    elif PHASE == "enabled":
        wait_stable()
        pid = app_pid()
        idle = measure(pid, 10)
        changes = measure(pid, 8, resize=True)
        wait_stable()
        save(PHASE, {"passed": True, "idle": idle, "changes": changes})
    elif PHASE == "disable":
        value = json.loads(STORAGE.read_text())
        value["preferences"]["workspaceRecoveryMode"] = {"string": {"_0": "disabled"}}
        STORAGE.write_text(json.dumps(value))
        save(PHASE, {"passed": True, "generation": journal()["generation"]})
    elif PHASE == "disabled":
        time.sleep(5)
        result = measure(app_pid(), 10)
        changes = measure(app_pid(), 8, resize=True, checkpoints=False)
        baseline = json.loads((EVIDENCE / "performance-disable.json").read_text())
        assert journal()["generation"] == baseline["generation"]
        save(PHASE, {"passed": True, "idle": result, "changes": changes})
    elif PHASE == "report":
        save(PHASE, {
            "passed": True, "platform": platform.platform(),
            "hardware": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
            "cpuTimebase": {"numer": TIMEBASE.numer, "denom": TIMEBASE.denom},
            "enabled": json.loads((EVIDENCE / "performance-enabled.json").read_text()),
            "disabled": json.loads((EVIDENCE / "performance-disabled.json").read_text()),
            "scope": "Debug signed App, 12 sessions / 48 windows / 96 idle cat panes; main window open; loopback heartbeat; background machine workload uncontrolled. No native Agent launch or physical display-removal measurement.",
        })
    else:
        raise AssertionError(PHASE)


try:
    main()
except BaseException:
    save(PHASE, {"passed": False, "error": traceback.format_exc()})
    raise
