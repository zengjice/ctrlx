"""Observe the private Host's MainActor API while four native Agents resume."""

import json
import math
from pathlib import Path
import platform
import socket
import statistics
import subprocess
import sys
import time
import traceback
import uuid

ROOT, SOCKET = Path(sys.argv[1]).resolve(), sys.argv[2]
assert Path(SOCKET).name.startswith("cx-workspace-agent-")
EVIDENCE = ROOT.parent / "evidence"


def save(name, value):
    path = EVIDENCE / f"{name}.json"
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def run():
    save("heartbeat-ready", {"ready": True})
    start = time.monotonic()
    samples, failures, journal_states = [], [], []
    first_response = None
    while time.monotonic() - start < 90:
        began = time.monotonic()
        try:
            # session.list dispatches on MainActor; no tmux I/O or mutation.
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(2)
                client.connect(str(ROOT / "api.sock"))
                client.sendall((json.dumps({"id": str(uuid.uuid4()), "method": "session.list", "params": {}}) + "\n").encode())
                data = b""
                while b"\n" not in data:
                    chunk = client.recv(65536)
                    assert chunk, "API closed before replying"
                    data += chunk
            response = json.loads(data.split(b"\n")[0])
            assert not response.get("error"), response
            first_response = first_response or time.monotonic()
            samples.append({"elapsedSeconds": time.monotonic() - start, "milliseconds": (time.monotonic() - began) * 1000})
            journal = json.loads((ROOT / "Recovery/workspace.json").read_text())
            pending = len(journal.get("recovery", {}).get("pendingAgentPaneIDs", []))
            if not journal_states or journal_states[-1]["pending"] != pending:
                journal_states.append({"elapsedSeconds": time.monotonic() - start, "pending": pending})
        except (FileNotFoundError, ConnectionRefusedError):
            if first_response is not None:
                raise
        except Exception as error:
            failures.append(str(error))
        if (EVIDENCE / "rebuilt.json").exists():
            break
        time.sleep(.05)
    assert (EVIDENCE / "rebuilt.json").exists(), "Native recovery did not complete"
    rebuilt = json.loads((EVIDENCE / "rebuilt.json").read_text())
    assert rebuilt["passed"] and len(rebuilt["live"]) == 4
    assert not failures, failures
    assert len(samples) >= 10, len(samples)
    assert any(state["pending"] > 0 for state in journal_states), "Observer missed native recovery"
    assert journal_states[-1]["pending"] == 0, journal_states
    values = sorted(sample["milliseconds"] for sample in samples)
    assert max(values) < 1000, "MainActor API was unresponsive for at least one second"
    return {
        "passed": True, "platform": platform.platform(),
        "hardware": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        "agents": "2 Codex + 2 Claude, exact native histories in four private configuration roots",
        "seconds": time.monotonic() - start,
        "firstResponseSeconds": first_response - start,
        "mainActorRoundTripMs": {"samples": len(values), "median": statistics.median(values), "p95": values[math.ceil(len(values) * .95) - 1], "max": max(values)},
        "pendingTransitions": journal_states, "samples": samples,
        "scope": "Signed Debug App; private Unix-socket round trips include transport/serialization overhead; background machine load uncontrolled. Not frame timing or a real OS reboot.",
    }


try:
    save("agent-responsiveness", run())
except Exception:
    save("agent-responsiveness", {"passed": False, "error": traceback.format_exc()})
    raise
