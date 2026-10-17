"""Verify exception capture/forwarding in a disposable signed CtrlX app.

Run through clean-build.py use-artifact with prepare_upstream_probe.sh's app.
Creates private state and tmux sockets; never replaces the installed app.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def run(app):
    app = Path(app).resolve()
    with (app / "Contents/Info.plist").open("rb") as stream:
        assert plistlib.load(stream)["CFBundleIdentifier"] == "com.ctrlx.embedded-acceptance"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    evidence = app.parent / "appkit-diagnostics-evidence"
    evidence.mkdir(exist_ok=True)
    source = Path(__file__).with_suffix(".m").resolve()
    library = evidence / "AppKitDiagnosticProbe.dylib"
    subprocess.run(["xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-O0", "-g",
                    "-framework", "AppKit", str(source), "-o", str(library)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(library)], check=True)
    for failure in (False, True):
        root = Path(tempfile.mkdtemp(prefix="cx-ak-", dir="/tmp"))
        case = evidence / ("delegate-failure" if failure else "capture-before-crash")
        case.mkdir(exist_ok=True)
        api, tmux = root / "api.sock", root / "tmux.sock"
        env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(library), CTRLX_APPKIT_PROBE_ROOT=str(root))
        if failure:
            env["CTRLX_APPKIT_PROBE_FAIL_DELEGATE"] = "1"
        command = [str(app / "Contents/MacOS/CtrlX"), "--e2e-test", "--tmux-socket", str(tmux),
                   "--ctrlx-state-root", str(root), "--e2e-api-socket", str(api),
                   "--zdotdir", str(source.parent / "shell"), "--e2e-browser-mock-keychain",
                   "-NSApplicationCrashOnExceptions", "YES"]
        with (case / "host.log").open("w") as log:
            process = subprocess.Popen(command, env=env, stdout=log, stderr=log, start_new_session=True)
            try:
                ready = subprocess.run([str(app / "Contents/MacOS/CtrlXCLI"), "wait-ready", "--timeout", "30",
                                        "--socket", str(api), "--json"], capture_output=True, text=True, timeout=35)
                assert ready.returncode == 0, ready.stderr
                assert json.loads(ready.stdout)["ok"], ready.stdout
                session = subprocess.run([str(app / "Contents/MacOS/CtrlXCLI"), "new-session", "--name", "diagnostics",
                                          "--path", str(root), "--socket", str(api), "--json"],
                                         capture_output=True, text=True, timeout=15)
                assert session.returncode == 0 and json.loads(session.stdout)["ok"], session.stdout + session.stderr
                selected = subprocess.run([str(app / "Contents/MacOS/CtrlXCLI"), "select-session", "diagnostics",
                                           "--socket", str(api), "--json"], capture_output=True, text=True, timeout=15)
                assert selected.returncode == 0 and json.loads(selected.stdout)["ok"], selected.stdout + selected.stderr
                # The injected timer also waits for the real SwiftUI toolbar.
                (root / "go").touch()
                if failure:
                    deadline = time.monotonic() + 10
                    while not (root / "forwarded").exists() and time.monotonic() < deadline:
                        assert process.poll() is None, "diagnostic exception escaped"
                        time.sleep(0.1)
                    assert (root / "forwarded").read_text() == "forwarded"
                    assert not list((root / "appkit-diagnostics").glob("*.json"))
                    assert "CtrlX could not capture AppKit diagnostics (NSInternalInconsistencyException)" in (case / "host.log").read_text()
                else:
                    code = process.wait(timeout=15)
                    assert code in (-signal.SIGTRAP, -signal.SIGABRT), code
                    reports = list((root / "appkit-diagnostics").glob("*.json"))
                    assert len(reports) == 1, reports
                    report = json.loads(reports[0].read_text())
                    assert report["processID"] == process.pid
                    assert report["exceptionName"] == "NSGenericException"
                    main = next(w for w in report["windows"] if w["context"]["kind"] == "main")
                    identifiers = {i["identifier"] for i in main["items"]}
                    assert "ctrlx.toolbar.connection" in identifiers, identifiers
                    assert "ctrlx.toolbar.title" in identifiers, identifiers
                    assert any(v["object"]["class"] == "NSToolbarItemViewer"
                               for i in main["items"] for v in i["views"])
                    assert "PRIVATE-APPKIT-PROBE-CONTENT" not in reports[0].read_text()
                    shutil.copy2(reports[0], case / "snapshot.json")
                    assert not (root / "unexpected-return").exists()
                (case / "result.json").write_text(json.dumps({"passed": True, "pid": process.pid,
                                                             "exit": process.poll()}, indent=2))
                print(case.name + ": passed", flush=True)
            finally:
                if process.poll() is None:
                    subprocess.run(["osascript", "-e", "tell application " + json.dumps(str(app)) + " to quit"],
                                   capture_output=True, timeout=15)
                    process.wait(timeout=25)
                subprocess.run(["/opt/homebrew/bin/tmux", "-S", str(tmux), "kill-server"], capture_output=True)
                if (root / "appkit-diagnostics").is_dir():
                    shutil.copytree(root / "appkit-diagnostics", case / "reports", dirs_exist_ok=True)
                shutil.rmtree(root)
    print("Evidence: " + str(evidence), flush=True)


if __name__ == "__main__":
    run(sys.argv[1])
