#!/usr/bin/env python3
"""Measure one hidden tab's actual presentation and input readiness after show."""
import argparse
import ctypes
import json
from pathlib import Path
import socket
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path, required=True)
    parser.add_argument("--control", type=Path, required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    host = json.loads(args.host.read_text())
    assert host["configuration"] == "Release", host["configuration"]

    class Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

    clock = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    clock.mach_absolute_time.restype = ctypes.c_uint64
    timebase = Timebase()
    assert clock.mach_timebase_info(ctypes.byref(timebase)) == 0

    def uptime():
        return clock.mach_absolute_time() * timebase.numer / timebase.denom / 1e9

    def call(words):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(30)
            client.connect(str(args.control))
            client.sendall(json.dumps({"arguments": words + ["--device", args.device]}).encode() + b"\n")
            with client.makefile("rb") as stream:
                result = json.loads(stream.readline(10 * 1024 * 1024))
        assert result["code"] == 0, result
        return json.loads(result["stdout"])

    before = call(["status", "--reset-measurements"])
    assert not before["view"]["visible"] and not before["view"]["inputReady"], before["view"]
    requested_at = uptime()
    shown = call(["show"])
    deadline = requested_at + 2
    while True:
        after = call(["status"])
        if after["view"]["inputReady"]:
            break
        assert uptime() < deadline, after
        time.sleep(.005)

    confirmed_at = uptime()
    view = after["view"]
    measurement = after["measurements"]
    record = {
        "build": host["build"], "device": args.device, "profile": after["profile"],
        "requestedAt": requested_at, "confirmedAt": confirmed_at,
        "requestThroughInputReadyMs": (view["inputReadyAt"] - requested_at) * 1000,
        "requestThroughActualPresentationMs": (measurement["firstPresentedAt"] - requested_at) * 1000,
        "visibleThroughInputReadyMs": (view["inputReadyAt"] - view["visibilityChangedAt"]) * 1000,
        "before": before, "shown": shown, "after": after,
        "boundary": "show request before bounded real-agent driver to positive Metal presentation and geometry-matching MainActor readiness; hidden metrics reset excludes source callbacks before reset; no screenshot or AX during interval; not physical scanout or full source-content causality qualification",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("a") as file:
        file.write(json.dumps(record) + "\n")
    assert view["visible"] and view["attached"] and view["inputReady"], view
    assert requested_at <= view["visibilityChangedAt"] <= measurement["firstPresentedAt"] <= view["inputReadyAt"] <= confirmed_at, record
    assert measurement["presentedFrames"] > 0, measurement
    assert measurement["sourceSequence"] > before["measurements"]["sourceSequence"], record
    assert before["geometry"] == after["geometry"], record
    print(json.dumps({key: record[key] for key in (
        "build", "device", "profile", "requestThroughInputReadyMs",
        "requestThroughActualPresentationMs", "visibleThroughInputReadyMs",
    )}), flush=True)


if __name__ == "__main__":
    main()
