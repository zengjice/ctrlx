"""Measure the product renderer in an AppKit window without SwiftUI or CEF."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import uuid

binary, helper, developer, device_set, udid, output = sys.argv[1:]
uuid.UUID(udid)
assert Path(device_set).is_absolute() and (Path(device_set) / udid).is_dir(), "Expected an absolute device set containing this UDID"
root = Path(tempfile.mkdtemp(prefix="display-", dir=Path(output).resolve()))
service = "com.jicezeng.ctrlx.simulator.baseline." + str(uuid.uuid4())
domain = f"gui/{os.getuid()}"
# Instruments records the target environment in trace metadata.
target_environment = {
    key: value for key, value in os.environ.items()
    if key in {"PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_CTYPE", "DEVELOPER_DIR"}
    or key.startswith("CTRLX_BASELINE_")
}
process = subprocess.Popen([binary, str(root), service, "--e2e-test"],
                           stdout=(root / "stdout.log").open("w"), stderr=(root / "stderr.log").open("w"),
                           env=target_environment)
capture = None
try:
    deadline = time.monotonic() + 15
    while not (root / "parent.json").exists():
        if process.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError("Baseline window did not start: " + str(root))
        time.sleep(.1)
    parent = json.loads((root / "parent.json").read_text())
    job = {"Label": service, "MachServices": {service: True}, "RunAtLoad": True,
           "ProgramArguments": [helper, service, developer, device_set, udid, "worker",
                                str(parent["pid"]), str(parent["seconds"]), str(parent["micros"])],
           "StandardErrorPath": str(root / "worker.log")}
    process_type = os.environ.get("CTRLX_BASELINE_PROCESS_TYPE", "Standard")
    assert process_type in ("Standard", "Adaptive", "Interactive"), process_type
    job["ProcessType"] = process_type
    plist = root / "worker.plist"
    plist.write_bytes(plistlib.dumps(job))
    subprocess.run(["/bin/launchctl", "bootstrap", domain, str(plist)], check=True)
    policy = subprocess.check_output(["/bin/launchctl", "print", domain + "/" + service], text=True)
    (root / "actual-launchd-policy.txt").write_text(policy)
    (root / "ready").touch()
    print("Window ready:", root, flush=True)
    if probe := os.environ.get("CTRLX_BASELINE_PROBE"):
        duration = float(os.environ.get("CTRLX_BASELINE_SECONDS", "20")) - 10
        assert 10 <= duration <= 1800
        capture_mode = os.environ.get("CTRLX_BASELINE_CAPTURE_MODE", "window")
        assert capture_mode in ("window", "display"), capture_mode
        arguments = [probe, str(parent["pid"]), "CtrlX Simulator \u2014 AppKit baseline",
                     str(duration), str(root / "window.json")]
        if capture_mode == "display":
            arguments.append("display")
        capture = subprocess.Popen(arguments, stdout=(root / "capture.log").open("w"), stderr=subprocess.STDOUT,
                                   env=target_environment)
    process.wait(timeout=float(os.environ.get("CTRLX_BASELINE_SECONDS", "20")) + 20)
    if capture:
        capture.wait(timeout=10)
        assert capture.returncode == 0, (root / "capture.log").read_text()
    error = root / "error.txt"
    if error.exists():
        raise RuntimeError(error.read_text())
    if not (root / "metrics.json").exists():
        raise RuntimeError(f"Baseline exited {process.returncode} without measurements: {root}")
    print(root)
    print((root / "metrics.json").read_text())
finally:
    if capture is not None and capture.poll() is None:
        capture.terminate(); capture.wait(timeout=10)
    if process.poll() is None:
        process.terminate()
        process.wait(timeout=10)
    subprocess.run(["/bin/launchctl", "bootout", domain + "/" + service], capture_output=True)
