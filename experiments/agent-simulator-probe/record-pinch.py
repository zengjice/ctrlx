#!/usr/bin/env python3
"""Bounded recording/pinch effects in a signed isolated app, using test agent identities.

Uses the native codex-named fixture, not a real Codex/model acceptance. Creates
one private iOS 27 guest, then shuts down/deletes only that guest and test root.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import socket
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    app, fixture, output = args.app.resolve(), args.fixture.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parents[2]
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    bundle = info["CFBundleIdentifier"]
    assert bundle == "com.jicezeng.ctrlx.simulator.acceptance", "Use the signed simulator acceptance app"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    root = Path(tempfile.mkdtemp(prefix="cx-media-", dir="/tmp"))
    temporary, state = root / "tmp", root / "state"
    temporary.mkdir(); state.mkdir()
    shell = root / "shell"; shell.mkdir()
    (shell / ".zshrc").write_text("unset HISTFILE\nSAVEHIST=0\n")
    api, tmux = str(Path(tempfile.gettempdir()) / "ctrlx-e2e.sock"), str(root / "tmux.sock")
    if Path(api).exists():
        with socket.socket(socket.AF_UNIX) as existing:
            try: existing.connect(api)
            except ConnectionRefusedError: pass
            else: raise RuntimeError("Another E2E host owns the socket; do not reuse it")
    cli = str(app / "Contents/MacOS/CtrlXCLI")
    identity = root / "codex"
    subprocess.run(["xcrun", "clang++", "-std=c++17", str(repo / "CtrlxPackage/AgentBrowser/tests/engine_identity.cc"),
                    "-o", str(identity)], check=True)
    env = dict(os.environ, TMPDIR=str(temporary) + "/", LOG_LEVEL="info")
    log = (output / "host.log").open("w")
    host = subprocess.Popen([str(app / "Contents/MacOS/CtrlX"), "--e2e-test", "--e2e-browser-mock-keychain",
        "--tmux-socket", tmux, "--ctrlx-state-root", str(state), "--zdotdir", str(shell)],
        env=env, stdout=log, stderr=subprocess.STDOUT)
    checks, counter, udid = [], 0, None
    diagnostic_stop = threading.Event()

    def recorder_diagnostics():
        while not diagnostic_stop.wait(.1):
            for path in output.glob(".ctrlx-recording-*/stderr"):
                try:
                    with path.open("rb") as file: data = file.read(16384)
                    (output / (path.parent.name + ".log")).write_bytes(data)
                except FileNotFoundError: pass

    diagnostic_thread = threading.Thread(target=recorder_diagnostics, daemon=True)
    diagnostic_thread.start()
    (output / "host.json").write_text(json.dumps({"pid": host.pid, "root": str(root), "app": str(app), "api": api,
        "bundle": bundle, "build": info.get("CtrlXBuildStamp"), "identity": "native test fixture, not real Codex"}, indent=2))

    def wait(predicate, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value: return value
            time.sleep(.1)
        raise AssertionError("Timed out waiting for test state")

    def control(*words):
        result = subprocess.run([cli, *words, "--socket", api, "--json"], capture_output=True, text=True, timeout=40)
        assert result.returncode == 0, (words, result.stderr)
        response = json.loads(result.stdout)
        assert response["ok"], response
        return response["result"]

    def send(number, command):
        control("send", command, "--pane", panes[number], "--enter")

    def run(number, words, ok=True):
        nonlocal counter
        counter += 1
        prefix = output / f"command-{counter:03d}"
        command = shlex.join([cli, "ios", *words, "--socket", api])
        started = time.monotonic()
        send(number, command + f" > {shlex.quote(str(prefix)+'.out')} 2> {shlex.quote(str(prefix)+'.err')}; echo $? > {shlex.quote(str(prefix)+'.exit')}")
        code = int(wait(lambda: Path(str(prefix) + ".exit").read_text().strip()
                        if Path(str(prefix) + ".exit").exists() else None, 250))
        stdout, stderr = Path(str(prefix) + ".out").read_text(), Path(str(prefix) + ".err").read_text()
        with (output / "commands.jsonl").open("a") as file:
            file.write(json.dumps({"argv": words, "owner": number, "code": code, "stdout": stdout,
                "stderr": stderr, "seconds": round(time.monotonic() - started, 3)}) + "\n")
        if ok is None: return {"code": code, "stdout": stdout, "stderr": stderr}
        assert (code == 0) == ok, (words, code, stderr)
        return json.loads(stdout) if ok else stderr

    def passed(name):
        checks.append(name)
        (output / "checks.json").write_text(json.dumps(checks, indent=2))
        print("PASS:", name, flush=True)

    def quit_host():
        subprocess.run(["osascript", "-e", f'tell application id "{bundle}" to quit'], check=True, timeout=15)
        host.wait(timeout=35)
        assert host.returncode == 0, host.returncode

    try:
        ready = subprocess.run([cli, "wait-ready", "--socket", api, "--timeout", "30"], capture_output=True, text=True, timeout=40)
        (output / "readiness.json").write_text(json.dumps({"code": ready.returncode, "stdout": ready.stdout, "stderr": ready.stderr}))
        assert ready.returncode == 0, ready.stderr
        panes = []
        for number in range(2):
            name = f"media-{number}"
            control("new-session", "--name", name, "--path", str(root))
            windows = control("list-windows", "--session", name)["windows"]
            window = windows[0]["id"]
            pane = control("list-panes", "--window", window)["panes"][0]["id"]
            panes.append(pane)
            record = root / f"identity-{number}.json"
            send(number, shlex.join([str(identity)]) + " > " + shlex.quote(str(record)))
            wait(lambda: record.exists() and record.stat().st_size > 0)
            process = json.loads(record.read_text())
            assert run(number, ["identity"])["owner"]["pid"] == process["pid"]
        control("select-session", "media-0")
        opened = run(0, ["open", "--runtime", "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                         "--device-type", "com.apple.CoreSimulator.SimDeviceType.iPhone-16"])
        device, udid = opened["device"], opened["udid"]
        def action(*words, ok=True): return run(0, [*words, "--device", device], ok=ok)
        device_set = state / "agent-simulator/devices"
        def simctl(*words):
            return subprocess.check_output(["xcrun", "simctl", "--set", str(device_set), *words], text=True, timeout=60).strip()
        action("install", "--app", str(fixture))
        action("launch", "--bundle", "com.jicezeng.ctrlx.interaction-fixture")
        action("wait", "--identifier", "fixture.tap", "--timeout-ms", "60000")
        container = Path(simctl("get_app_container", udid, "com.jicezeng.ctrlx.interaction-fixture", "data"))
        datafile = container / "Documents/state.json"
        def effect(): return json.loads(datafile.read_text())
        movie = output / "pinch.mp4"
        assert action("record-start", "--output", str(movie), "--seconds", "60")["state"] == "recording"
        for operation in ("record-status", "record-stop"):
            run(1, [operation, "--device", device], ok=False)
        assert "does not belong" in run(1, ["pinch", "--device", device, "--x", "180", "--y", "400", "--scale", "2"], ok=False)
        assert "active recording" in action("record-start", "--output", str(output / "duplicate.mp4"), ok=False)
        assert not (output / "duplicate.mp4").exists()
        count = 0
        for orientation in ("portrait", "landscape-left"):
            if orientation != "portrait": action("rotate", "--orientation", orientation)
            geometry = action("status")["geometry"]
            width, height = geometry["width"], geometry["height"]
            if geometry["orientation"] in (3, 4): width, height = height, width
            x, y = width / geometry["scale"] / 2, min(610, height / geometry["scale"] - 120) + 50
            for scale in (2, .5):
                action("pinch", "--x", str(x), "--y", str(y), "--scale", str(scale), "--duration-ms", "500")
                count += 1
                value = wait(lambda: (value if value["pinches"] == count else None) if (value := effect()) else None)
                assert value["pinchTouches"] == 2 and (value["pinchScale"] > 1 if scale > 1 else value["pinchScale"] < 1), value
                (output / f"effect-{orientation}-{scale}.json").write_text(json.dumps(value, indent=2))
            action("screenshot", "--output", str(output / f"{orientation}.png"))
        stopped = run(0, ["record-stop", "--device", device], ok=None)
        recording_failures = []
        if stopped["code"]:
            recording_failures.append(stopped)
            print("RECORDING FAILURE:", stopped["stderr"], flush=True)
        else:
            assert json.loads(stopped["stdout"])["state"] == "completed"
            assert action("record-stop")["state"] == "completed"
            action("record-start", "--output", str(movie), ok=False)
        passed("two simultaneous contacts scale both directions in portrait and landscape; ownership and duplicate start enforced")
        auto = output / "automatic.mp4"
        action("record-start", "--output", str(auto), "--seconds", "1")
        terminal = wait(lambda: result if (result := action("record-status"))["state"] in ("completed", "failed") else None, 20)
        if terminal["state"] == "failed": recording_failures.append(terminal)
        else: passed("duration limit finalizes without stop")
        closing = output / "close.mp4"
        action("record-start", "--output", str(closing))
        action("close")
        if not closing.exists(): recording_failures.append({"error": "close did not publish a movie"})
        else: passed("closing a device finalizes recording before guest shutdown")
        opened = run(0, ["open", "--udid", udid])
        device = opened["device"]
        exit_movie = output / "exit.mp4"
        action("record-start", "--output", str(exit_movie))
        quit_host()
        if not exit_movie.exists(): recording_failures.append({"error": "host exit did not publish a movie"})
        rows = [d for group in json.loads(simctl("list", "devices", "--json"))["devices"].values() for d in group]
        assert len(rows) == 1 and rows[0]["state"] == "Shutdown", rows
        if exit_movie.exists(): passed("normal host exit finalizes recording and shuts down the private guest")
        for path in output.glob("*.mp4"):
            probe = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
                capture_output=True, text=True, check=True)
            media = json.loads(probe.stdout)
            assert media["streams"][0]["codec_name"] == "h264" and float(media["format"]["duration"]) > 0
            (output / (path.stem + "-probe.json")).write_text(probe.stdout)
            # Preserve the source time base so variable-rate frames do not collide in the null muxer.
            subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-err_detect", "explode", "-i", str(path),
                "-fps_mode", "passthrough", "-enc_time_base", "demux", "-f", "null", "-"], check=True, timeout=60)
        passed("all MP4 outputs contain H.264 video and fully decode")
        (output / "recording-failures.json").write_text(json.dumps(recording_failures, indent=2))
        assert not recording_failures, recording_failures
    finally:
        if host.poll() is None: quit_host()
        diagnostic_stop.set(); diagnostic_thread.join(timeout=2)
        log.close()
        if udid:
            subprocess.run(["xcrun", "simctl", "--set", str(state / "agent-simulator/devices"), "delete", udid], check=True, timeout=60)
        subprocess.run(["/opt/homebrew/bin/tmux", "-S", tmux, "kill-server"], capture_output=True, timeout=10)
        shutil.rmtree(root)
        (output / "cleanup.json").write_text(json.dumps({"hostExitCode": host.returncode, "privateRootRemoved": not root.exists()}))


if __name__ == "__main__":
    main()
