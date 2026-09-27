#!/usr/bin/env python3
"""Bound the native CEF lifecycle test; never count relaunch/exit-0 as success."""
import os
from pathlib import Path
import signal
import subprocess
import sys


def run(executable: Path, timeout: float = 35, chrome_control: bool = False) -> int:
    arguments = [str(executable), "--probe-smoke-test"]
    if chrome_control:
        arguments.append("--probe-chrome-control")
    process = subprocess.Popen(
        arguments,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        # Only this test's newly-created process group, never a name-based kill.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            # The process may finish between timeout and signal delivery.
            pass
        output, _ = process.communicate()
        sys.stdout.buffer.write(output)
        print("Native smoke failed/interrupted; its process group was stopped.", file=sys.stderr)
        return 1
    sys.stdout.buffer.write(output)
    marker = b"[probe] chrome-control-smoke=PASS" if chrome_control else b"[probe] native-smoke=PASS"
    if process.returncode != 0 or marker not in output:
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != "--chrome-control"):
        sys.exit("Usage: smoke.py <probe executable> [--chrome-control]")
    sys.exit(run(Path(sys.argv[1]), chrome_control=len(sys.argv) == 3))
