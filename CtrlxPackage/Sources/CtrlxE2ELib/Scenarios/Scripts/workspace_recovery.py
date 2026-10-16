"""Signed-App recovery acceptance on the E2E runner's private tmux and state root."""

import json
from pathlib import Path
import subprocess
import sys
import time
import traceback


PHASE, ROOT, SOCKET = sys.argv[1], Path(sys.argv[2]).resolve(), sys.argv[3]
EVIDENCE = ROOT.parent / "evidence"
JOURNAL = ROOT / "Recovery" / "workspace.json"
PROJECT = ROOT / "project"
assert Path(SOCKET).name.startswith("cx-workspace-"), "Use a disposable cx-workspace-* socket"
EVIDENCE.mkdir(parents=True, exist_ok=True)


def tmux(*args):
    return subprocess.check_output(["tmux", "-f", "/dev/null", "-S", SOCKET, *args], text=True).rstrip("\n")


def save(name, data):
    (EVIDENCE / f"{name}.json").write_text(json.dumps(data, indent=2) + "\n")


def snapshot():
    return json.loads(JOURNAL.read_text())


def await_snapshot(check):
    deadline = time.monotonic() + 20
    while True:
        try:
            value = snapshot()
            check(value)
            return value
        except (AssertionError, FileNotFoundError, KeyError) as error:
            if time.monotonic() >= deadline:
                raise AssertionError(f"{PHASE}: {error}") from error
            time.sleep(0.2)


def sessions(value):
    return {session["name"]: session for session in value["sessions"] if session["name"].startswith("restore-")}


def windows(value):
    return {window["id"]: window for session in sessions(value).values() for window in session["windows"]}


def panes(value):
    return {pane["id"]: pane for window in windows(value).values() for pane in window["panes"]}


def live_panes():
    fields = ["session_name", "window_index", "window_id", "pane_id", "pane_pid", "pane_current_path", "pane_current_command", "@ctrlx-recovery-session", "@ctrlx-recovery-window", "@ctrlx-recovery-pane", "@ctrlx-recovery-session-incomplete", "@ctrlx-recovery-window-incomplete", "pane_dead"]
    output = tmux("list-panes", "-a", "-F", "\x1f".join("#{" + field + "}" for field in fields))
    rows = [line.split("\x1f") for line in output.splitlines()]
    assert all(len(row) == len(fields) for row in rows)
    return [dict(zip(fields, row)) for row in rows]


def require_fixture(value):
    found = sessions(value)
    assert set(found) == {"restore-alpha", "restore-beta"}, "Both same-directory sessions must survive"
    assert len(found["restore-alpha"]["windows"]) == 3
    assert len(found["restore-beta"]["windows"]) == 1
    assert len(panes(value)) == 6
    assert not value.get("recovery"), "Recovery has not completed"
    for pane in panes(value).values():
        assert Path(pane["directory"]).is_relative_to(PROJECT)
    alpha = found["restore-alpha"]
    tree = next(window["layout"] for window in alpha["windows"] if window["index"] == 0)
    assert "horizontal" in tree and "vertical" in json.dumps(tree), "The nested pane tree must be retained"


def require_detached(value):
    require_fixture(value)
    detached = [scene for scene in value["scenes"] if not scene["isMain"]]
    assert len(detached) == 1, "Expected one restored native window"
    scene = detached[0]
    assert scene.get("frame"), "The actual App must capture native-window geometry"
    owned = [identity for item in scene["sessions"] for identity in item["ownedWindowIDs"]]
    assert len(owned) == 1 and windows(value)[owned[0]]["index"] == 3
    main_owned = [identity for item in next(item for item in value["scenes"] if item["isMain"])["sessions"] for identity in item["ownedWindowIDs"]]
    assert owned[0] not in main_owned, "A terminal must have one native-window owner"
    main_alpha = next(item for item in next(scene for scene in value["scenes"] if scene["isMain"])["sessions"] if item["sessionName"] == "restore-alpha")
    assert {"window": {"index": 1}} in main_alpha["layout"]["rightSide"], "The workbench split must survive independently of the tmux pane tree"


def topology(layout):
    kind, body = next(iter(layout.items()))
    if kind == "pane":
        return kind, body["_0"]
    return kind, [topology(child) for child in body["_0"]]


def require_same_scene(before, after):
    old = {scene["id"]: scene for scene in before["scenes"]}
    new = {scene["id"]: scene for scene in after["scenes"]}
    assert set(old).issubset(new), "Native window IDs changed"
    for identity, scene in old.items():
        restored = new[identity]
        assert scene.get("selectedSessionID") == restored.get("selectedSessionID")
        if scene.get("frame"):
            old_frame = [value for pair in scene["frame"] for value in pair]
            new_frame = [value for pair in restored["frame"] for value in pair]
            assert len(old_frame) == len(new_frame) == 4
            assert all(abs(a - b) <= 2 for a, b in zip(old_frame, new_frame)), (old_frame, new_frame)
        old_presentations = {item["sessionID"]: item for item in scene["sessions"]}
        new_presentations = {item["sessionID"]: item for item in restored["sessions"]}
        for session_id, item in old_presentations.items():
            current = new_presentations[session_id]
            assert item["ownedWindowIDs"] == current["ownedWindowIDs"]
            for key in ["tabOrder", "rightSide", "selectedLeft", "selectedRight"]:
                assert item["layout"].get(key) == current["layout"].get(key), key


def setup():
    for directory in [PROJECT, PROJECT / "left", PROJECT / "lower", PROJECT / "detached"]:
        directory.mkdir(parents=True, exist_ok=True)
    (ROOT / ".workspace-recovery-fixture").touch()
    (PROJECT / "README.md").write_text("Recovery acceptance fixture.\n")
    tmux("respawn-pane", "-k", "-t", "restore-alpha:0.0", "-c", str(PROJECT), "/bin/sh")
    tmux("rename-window", "-t", "restore-alpha:0", "NESTED")
    tmux("set-window-option", "-t", "restore-alpha:0", "automatic-rename", "off")
    tmux("split-window", "-h", "-t", "restore-alpha:0.0", "-c", str(PROJECT / "left"), "/bin/sh")
    tmux("split-window", "-v", "-t", "restore-alpha:0.1", "-c", str(PROJECT / "lower"), "/bin/sh")
    tmux("new-window", "-d", "-t", "restore-alpha:1", "-n", "RIGHT", "-c", str(PROJECT / "left"), "/bin/sh")
    tmux("set-window-option", "-t", "restore-alpha:1", "automatic-rename", "off")
    tmux("new-window", "-d", "-t", "restore-alpha:3", "-n", "DETACHED", "-c", str(PROJECT / "detached"), "/bin/sh")
    tmux("set-window-option", "-t", "restore-alpha:3", "automatic-rename", "off")
    counter = PROJECT / "command-executions.txt"
    command = f"echo executed >> '{counter}'; exec /bin/sleep 2147483647"
    tmux("new-session", "-d", "-s", "restore-beta", "-c", str(PROJECT), "/bin/sh", "-c", command)
    tmux("select-pane", "-t", "restore-alpha:0.1")
    tmux("select-window", "-t", "restore-alpha:0")
    for index, target in enumerate(["restore-alpha:0.0", "restore-alpha:0.1", "restore-alpha:0.2", "restore-alpha:1.0", "restore-alpha:3.0"]):
        tmux("send-keys", "-t", target, "-l", f"printf 'WR_%s\\n' 'boot_{index}'")
        tmux("send-keys", "-t", target, "Enter")
    return {"live": live_panes()}


def run():
    if PHASE == "setup":
        return setup()
    assert (ROOT / ".workspace-recovery-fixture").exists()
    if PHASE == "captured":
        value = await_snapshot(require_detached)
        save("baseline", value)
        live = live_panes()
        save("baseline-processes", live)
        return {"live": live, "snapshot": value}
    before = json.loads((EVIDENCE / "baseline.json").read_text())
    if PHASE == "prepare-missing":
        value = snapshot()
        require_detached(value)
        save("before-missing", value)
        value["bootID"] = "workspace-acceptance-unmounted-boot"
        JOURNAL.write_text(json.dumps(value))
        PROJECT.rename(ROOT / "offline-project")
        return {"simulated_boot_change": True, "project_unavailable": True}
    if PHASE in ["missing", "missing-relaunch"]:
        original = json.loads((EVIDENCE / "before-missing.json").read_text())
        def missing(value):
            assert set(value.get("recovery", {}).get("pendingAgentPaneIDs", [])) == panes(original).keys()
            assert panes(value).keys() == panes(original).keys()
            assert windows(value).keys() == windows(original).keys()
            require_same_scene(original, value)
            for identity, pane in panes(value).items():
                assert pane["directory"] == panes(original)[identity]["directory"]
            for identity, window in windows(value).items():
                assert topology(window["layout"]) == topology(windows(original)[identity]["layout"])
            live = [pane for pane in live_panes() if pane["session_name"].startswith("restore-")]
            assert len(live) == 6 and all(pane["pane_dead"] == "1" for pane in live)
        value = await_snapshot(missing)
        live = [pane for pane in live_panes() if pane["session_name"].startswith("restore-")]
        if PHASE == "missing":
            save("missing-processes", live)
        else:
            original_live = json.loads((EVIDENCE / "missing-processes.json").read_text())
            assert {(p["pane_id"], p["pane_pid"]) for p in original_live} == {(p["pane_id"], p["pane_pid"]) for p in live}
        return {"snapshot": value, "live": live}
    if PHASE == "remount":
        (ROOT / "offline-project").rename(PROJECT)
        return {"directory_available": PROJECT.is_dir()}
    if PHASE == "remounted-one":
        original = json.loads((EVIDENCE / "before-missing.json").read_text())
        identity = next(pane["id"] for window in windows(original).values() if window["index"] == 3 for pane in window["panes"])
        def one(value):
            assert set(value.get("recovery", {}).get("pendingAgentPaneIDs", [])) == panes(original).keys() - {identity}
            live = [pane for pane in live_panes() if pane["session_name"].startswith("restore-")]
            assert len(live) == 6
            assert all(pane["pane_dead"] == ("0" if pane["@ctrlx-recovery-pane"] == identity else "1") for pane in live)
        value = await_snapshot(one)
        return {"snapshot": value, "resumed_only": identity}
    if PHASE in ["remounted", "remounted-relaunch"]:
        original = json.loads((EVIDENCE / "before-missing.json").read_text())
        original_live = json.loads((EVIDENCE / "missing-processes.json").read_text())
        live = []
        def remounted(value):
            nonlocal live
            require_detached(value)
            require_same_scene(original, value)
            live = [pane for pane in live_panes() if pane["session_name"].startswith("restore-")]
            assert {p["pane_id"] for p in original_live} == {p["pane_id"] for p in live}
            for pane in live:
                expected = panes(original)[pane["@ctrlx-recovery-pane"]]
                assert pane["pane_dead"] == "0"
                assert pane["pane_current_path"] == expected["directory"], pane
                # A normal login shell can run short initialization commands
                # before reaching its prompt. Observe readiness, not just spawn.
                assert pane["pane_current_command"] in ["sh", "zsh", "bash", "fish"], pane
        value = await_snapshot(remounted)
        assert (PROJECT / "command-executions.txt").read_text().splitlines() == ["executed"]
        if PHASE == "remounted":
            save("remounted-processes", live)
        else:
            started = json.loads((EVIDENCE / "remounted-processes.json").read_text())
            assert {(p["pane_id"], p["pane_pid"]) for p in started} == {(p["pane_id"], p["pane_pid"]) for p in live}
        return {"snapshot": value, "live": live, "interrupted_command_replayed": False}
    if PHASE in ["stopped", "survived"]:
        value = await_snapshot(require_detached)
        require_same_scene(before, value)
        original = json.loads((EVIDENCE / "baseline-processes.json").read_text())
        assert {p["pane_pid"] for p in original} == {p["pane_pid"] for p in live_panes()}, "App restart replaced a live process"
        assert panes(before).keys() == panes(value).keys()
        return {"snapshot": value}
    if PHASE == "prepare-reboot":
        value = snapshot()
        require_detached(value)
        save("pre-reboot", value)
        value["bootID"] = "workspace-acceptance-previous-boot"
        JOURNAL.write_text(json.dumps(value))
        return {"simulated_boot_change": True}
    if PHASE == "rebuilt":
        value = await_snapshot(require_detached)
        assert before["hostID"] == value["hostID"] and before["serverID"] != value["serverID"]
        assert panes(before).keys() == panes(value).keys()
        assert windows(before).keys() == windows(value).keys()
        for identity, old in windows(before).items():
            current = windows(value)[identity]
            assert old["index"] == current["index"]
            assert topology(old["layout"]) == topology(current["layout"])
            assert old.get("selectedPaneID") == current.get("selectedPaneID")
        require_same_scene(before, value)
        live = [pane for pane in live_panes() if pane["session_name"].startswith("restore-")]
        assert len(live) == 6
        for pane in live:
            expected = panes(value)[pane["@ctrlx-recovery-pane"]]
            assert expected["runtimeID"] == pane["pane_id"]
            assert expected["directory"] == pane["pane_current_path"]
            assert pane["pane_current_command"] in ["sh", "zsh", "bash", "fish"], pane
        assert (PROJECT / "command-executions.txt").read_text().splitlines() == ["executed"]
        return {"snapshot": value, "live": live, "interrupted_command_replayed": False}
    if PHASE == "input":
        dimensions = {}
        for target in ["restore-alpha:0", "restore-alpha:1"]:
            dimensions[target] = [int(value) for value in tmux("display-message", "-p", "-t", target, "#{window_width} #{window_height}").split()]
        left, right = dimensions.values()
        assert abs(left[0] - right[0]) <= 1 and left[1] == right[1], "Both equal-width workbench sides must Fit after content clicks"
        return {"window_dimensions": dimensions}
    if PHASE == "unchanged":
        first = snapshot()
        stat = JOURNAL.stat()
        start = time.monotonic()
        stable_since = start
        while True:
            time.sleep(0.2)
            second = snapshot()
            current_stat = JOURNAL.stat()
            now = time.monotonic()
            if first != second or current_stat.st_mtime_ns != stat.st_mtime_ns:
                first, stat, stable_since = second, current_stat, now
            if now - stable_since >= 5:
                return {"observed_seconds": now - stable_since, "settled_after_seconds": stable_since - start, "journal_bytes": stat.st_size, "generation": first["generation"]}
            assert now - start < 20, "Workbench checkpoint never became stable after startup"
    if PHASE in ["returned", "returned-relaunch"]:
        def returned(value):
            require_fixture(value)
            assert all(scene["isMain"] for scene in value["scenes"]), "Closed native window was recreated"
            alpha = next(item for scene in value["scenes"] for item in scene["sessions"] if item["sessionName"] == "restore-alpha")
            assert len(alpha["ownedWindowIDs"]) == 3
        value = await_snapshot(returned)
        return {"snapshot": value}
    raise ValueError(PHASE)


try:
    result = {"passed": True, **run()}
except Exception:
    result = {"passed": False, "error": traceback.format_exc()}
    try:
        if JOURNAL.exists():
            result["snapshot"] = snapshot()
        result["live"] = live_panes()
    except Exception as error:
        result["inspection_error"] = repr(error)
save(PHASE, result)
if not result["passed"]:
    print(result["error"], file=sys.stderr)
    sys.exit(1)
