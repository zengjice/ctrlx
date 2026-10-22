"""Private simulator/Host recovery fixture; never operates the installed App."""

import json
from pathlib import Path
import subprocess
import sys
import time
import traceback
import uuid

PHASE, HOST, IOS, SOCKET = sys.argv[1], Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve(), sys.argv[4]
assert Path(SOCKET).name.startswith("cx-workspace-ios-")
EVIDENCE = HOST.parent / "evidence"
PROJECT = HOST / "ios-project"
DRAFT = "Unsent iOS recovery draft. Keep this text without sending it."
EVIDENCE.mkdir(parents=True, exist_ok=True)


def tmux(*args):
    return subprocess.check_output(["tmux", "-f", "/dev/null", "-S", SOCKET, *args], text=True, timeout=10).rstrip("\n")


def save(name, value):
    path = EVIDENCE / (name + ".json")
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def read(path):
    return json.loads(path.read_text())


def wait(check):
    deadline = time.monotonic() + 35
    while True:
        try:
            return check()
        except (AssertionError, FileNotFoundError, KeyError, StopIteration, json.JSONDecodeError, subprocess.CalledProcessError) as error:
            if time.monotonic() >= deadline:
                raise AssertionError(f"{PHASE}: {error}") from error
            time.sleep(0.2)


def live():
    return tmux("list-panes", "-s", "-t", "restore-ios", "-F", "#{window_index}|#{pane_id}|#{pane_pid}|#{@ctrlx-recovery-pane}")


def content():
    host = read(HOST / "Recovery/workspace.json")
    ios = read(IOS / "Recovery/ios-workspace.json")
    session = next(s for s in host["sessions"] if s["name"] == "restore-ios")
    source = next(w for w in session["windows"] if w["index"] == 2)
    saved = next(s for s in ios["sessions"] if s["reference"]["sessionID"] == session["id"])
    reference = saved["reference"]
    assert reference["hostID"] == host["hostID"]
    assert ios["selectedSession"] == reference
    assert saved["selectedWindowID"] == source["id"], saved
    assert saved["selectedPaneID"] == source["panes"][0]["id"], saved
    assert len(saved["files"]) == 1, saved
    tab = saved["files"][0]
    assert saved["selectedFileID"] == tab["snapshot"]["id"]
    assert Path(tab["snapshot"]["path"]).resolve() == PROJECT / "docs"
    assert Path(tab["snapshot"]["selectedFile"]).resolve() == PROJECT / "docs/chapter.txt"
    assert tab["snapshot"]["id"] in {f["id"] for f in host["fileTabs"]}
    pane = dict(reference, windowID=source["id"], paneID=source["panes"][0]["id"])
    assert tab["source"] == pane
    drafts = [d for d in ios["drafts"] if d["text"] == DRAFT]
    assert len(drafts) == 1 and drafts[0]["pane"] == pane, ios["drafts"]
    assert DRAFT not in tmux("capture-pane", "-p", "-t", "restore-ios:2", "-S", "-200"), "Unsent draft reached the terminal"
    for scene in host["scenes"]:
        for item in scene["sessions"]:
            for file in item["layout"]["fileTabs"]:
                assert file.get("browser", {}).get("selectedFile") != tab["snapshot"]["selectedFile"]
    return {"host": host, "ios": ios, "live": live(), "draft": drafts[0]}


def run():
    if PHASE == "setup":
        HOST.mkdir(parents=True, exist_ok=True, mode=0o700)
        storage = HOST / "e2e-storage.json"
        assert not storage.exists()
        storage.write_text(json.dumps({"preferences": {"autoConnectToServer": {"bool": {"_0": True}}}, "sessionKeys": {}, "secrets": {}}))
        storage.chmod(0o600)
        (PROJECT / "docs").mkdir(parents=True)
        (PROJECT / "docs/chapter.txt").write_text("IOS_PRIVATE_PREVIEW\n")
        (HOST / ".workspace-ios-fixture").touch()
        tmux("respawn-pane", "-k", "-t", "restore-ios:0", "-c", str(PROJECT), "/bin/sh")
        tmux("rename-window", "-t", "restore-ios:0", "OTHER")
        tmux("new-window", "-d", "-t", "restore-ios:2", "-n", "SOURCE", "-c", str(PROJECT), "/bin/sh")
        for index in [0, 2]:
            tmux("set-window-option", "-t", f"restore-ios:{index}", "automatic-rename", "off")
        return {"project": str(PROJECT)}
    assert (HOST / ".workspace-ios-fixture").exists()
    assert IOS.name.startswith("ctrlx-recovery-") and "/data/Containers/Data/Application/" in str(IOS)
    if PHASE == "configure":
        file = IOS / "e2e-storage.json"
        storage = read(file)
        storage["preferences"]["agentQuickInputEnabled"] = {"bool": {"_0": True}}
        file.write_text(json.dumps(storage))
        return {"quickInputEnabled": True}
    if PHASE == "offline":
        baseline = read(EVIDENCE / "baseline.json")
        assert read(IOS / "Recovery/ios-workspace.json") == baseline["ios"]
        return {"offlineJournalRetained": True}
    if PHASE == "prepare-reboot":
        file = HOST / "Recovery/workspace.json"
        value = read(file)
        assert not value.get("recovery"), "Host recovery still pending"
        value["bootID"] = "e2e-ios-previous-boot-" + str(uuid.uuid4())
        file.write_text(json.dumps(value))
        return {"simulatedPreviousBoot": True}
    result = wait(content)
    if PHASE == "captured":
        save("baseline", result)
    else:
        before = read(EVIDENCE / "baseline.json")
        current = dict(result["ios"])
        collision = [s for s in current["sessions"] if s["name"] == "ios-route-collision"]
        current["sessions"] = [s for s in current["sessions"] if s["name"] != "ios-route-collision"]
        assert current == before["ios"], "Private iOS state changed"
        assert all(not s["files"] and not s.get("selectedWindowID") and not s.get("selectedPaneID") for s in collision), "Collision inherited private state"
        if PHASE in ["restored", "host-offline"]:
            assert result["live"] == before["live"], "App restart changed Host processes"
        elif PHASE == "rebuilt":
            assert result["live"] != before["live"], "Host was not rebuilt"
            assert not result["host"].get("recovery")
        elif PHASE == "relaunch":
            assert result["live"] == read(EVIDENCE / "rebuilt.json")["result"]["live"], "iOS restart recreated Host processes"
    return result


try:
    result = run()
    save(PHASE, {"passed": True, "result": result})
except Exception as error:
    for name, file in [("host", HOST / "Recovery/workspace.json"), ("ios", IOS / "Recovery/ios-workspace.json")]:
        if file.exists():
            save(PHASE + "-" + name + "-journal", read(file))
    save(PHASE, {"passed": False, "error": str(error), "traceback": traceback.format_exc()})
    raise
