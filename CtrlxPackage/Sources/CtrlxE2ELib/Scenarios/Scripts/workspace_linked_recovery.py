"""Shared physical tmux windows retain per-session native-window ownership."""

import json
from pathlib import Path
import subprocess
import sys
import time
import traceback

PHASE, ROOT, SOCKET = sys.argv[1], Path(sys.argv[2]).resolve(), sys.argv[3]
assert Path(SOCKET).name.startswith("cx-workspace-linked-")
EVIDENCE = ROOT.parent / "evidence"
JOURNAL = ROOT / "Recovery/workspace.json"
EVIDENCE.mkdir(parents=True, exist_ok=True)


def tmux(*args):
    return subprocess.check_output(["tmux", "-S", SOCKET, *args], text=True, timeout=10).rstrip("\n")


def save(name, value):
    path = EVIDENCE / f"{name}.json"
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def live():
    fields = ["session_name", "window_index", "window_id", "pane_id", "pane_pid", "@ctrlx-recovery-window", "@ctrlx-recovery-pane"]
    rows = tmux("list-panes", "-a", "-F", "\x1f".join("#{" + field + "}" for field in fields))
    return [dict(zip(fields, row.split("\x1f"))) for row in rows.splitlines() if row.startswith("linked-a\x1f") or row.startswith("linked-b\x1f")]


def require(value):
    assert not value.get("recovery"), "Recovery is still pending"
    sessions = {s["name"]: s for s in value["sessions"]}
    a, b = sessions["linked-a"], sessions["linked-b"]
    aw = {w["index"]: w for w in a["windows"]}
    bw = {w["index"]: w for w in b["windows"]}
    assert set(aw) == {0, 1} and set(bw) == {0, 7}
    shared = aw[0]["id"]
    assert shared == bw[7]["id"]
    assert {p["id"] for p in aw[0]["panes"]} == {p["id"] for p in bw[7]["panes"]}
    assert len(aw[0]["panes"]) == 2
    detached = [s for s in value["scenes"] if not s["isMain"]]
    assert len(detached) == 1
    detached = detached[0]
    main = next(s for s in value["scenes"] if s["isMain"])
    assert detached["selectedSessionID"] == a["id"]
    assert main["selectedSessionID"] == b["id"]
    da = next(s for s in detached["sessions"] if s["sessionID"] == a["id"])
    ma = next(s for s in main["sessions"] if s["sessionID"] == a["id"])
    mb = next(s for s in main["sessions"] if s["sessionID"] == b["id"])
    assert da["ownedWindowIDs"] == [shared]
    # Native ownership is physical-window scoped; tmux retains both links.
    assert shared not in ma["ownedWindowIDs"] and shared not in mb["ownedWindowIDs"]
    assert da["selectedWindowID"] == shared
    assert mb["selectedWindowID"] == bw[0]["id"]
    assert da["layout"]["selectedLeft"] == {"window": {"index": 0}}
    assert mb["layout"]["selectedLeft"] == {"window": {"index": 0}}
    rows = live()
    assert len(rows) == 6 and len({p["pane_id"] for p in rows}) == 4
    ar = {p["pane_id"] for p in rows if p["session_name"] == "linked-a" and p["window_index"] == "0"}
    br = {p["pane_id"] for p in rows if p["session_name"] == "linked-b" and p["window_index"] == "7"}
    assert ar == br and len(ar) == 2
    return value


def settled():
    deadline = time.monotonic() + 20
    while True:
        try:
            return require(json.loads(JOURNAL.read_text()))
        except (AssertionError, KeyError, FileNotFoundError, StopIteration) as error:
            if time.monotonic() >= deadline:
                raise AssertionError(f"{PHASE}: {error}") from error
            time.sleep(0.2)


def run():
    if PHASE == "setup":
        project = ROOT / "project"
        project.mkdir(parents=True)
        tmux("respawn-pane", "-k", "-t", "linked-a:0", "-c", str(project), "/bin/sh")
        tmux("rename-window", "-t", "linked-a:0", "SHARED")
        tmux("set-window-option", "-t", "linked-a:0", "automatic-rename", "off")
        tmux("split-window", "-h", "-t", "linked-a:0", "-c", str(project), "/bin/sh")
        tmux("new-window", "-d", "-t", "linked-a:1", "-n", "A_PRIVATE", "-c", str(project), "/bin/sh")
        tmux("new-session", "-d", "-s", "linked-b", "-n", "B_PRIVATE", "-c", str(project), "/bin/sh")
        tmux("link-window", "-s", "linked-a:0", "-t", "linked-b:7")
        return {"live": live()}
    value = settled()
    rows = live()
    if PHASE == "captured":
        save("baseline", {"snapshot": value, "live": rows})
    else:
        before = json.loads((EVIDENCE / "baseline.json").read_text())
        original = before["snapshot"]
        assert {s["id"] for s in original["scenes"]} == {s["id"] for s in value["scenes"]}
        assert {p["@ctrlx-recovery-pane"] for p in before["live"]} == {p["@ctrlx-recovery-pane"] for p in rows}
        if PHASE == "survived":
            assert {p["pane_pid"] for p in before["live"]} == {p["pane_pid"] for p in rows}
        elif PHASE == "prepare-reboot":
            value["bootID"] = "linked-window-simulated-previous-boot"
            JOURNAL.write_text(json.dumps(value))
        elif PHASE == "rebuilt":
            assert original["hostID"] == value["hostID"] and original["serverID"] != value["serverID"]
            assert not {p["pane_pid"] for p in before["live"]} & {p["pane_pid"] for p in rows}
        else:
            raise ValueError(PHASE)
    return {"snapshot": value, "live": rows}


try:
    save(PHASE, {"passed": True, **run()})
except Exception:
    save(PHASE, {"passed": False, "error": traceback.format_exc()})
    raise
