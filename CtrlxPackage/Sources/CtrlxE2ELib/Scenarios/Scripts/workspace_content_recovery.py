"""Real Files/Git/editor fixtures, confined to the runner's private workspace."""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import traceback
import uuid

PHASE, ROOT, SOCKET = sys.argv[1], Path(sys.argv[2]).resolve(), sys.argv[3]
assert Path(SOCKET).name.startswith("cx-workspace-content-")
EVIDENCE = ROOT.parent / "evidence"
JOURNAL = ROOT / "Recovery" / "workspace.json"
PROJECT = ROOT / "content-project"
EVIDENCE.mkdir(parents=True, exist_ok=True)
DRAFT = "Unsent recovery prompt: inspect the chosen file, do not execute anything."
MESSAGE = "Unsent commit message for workspace recovery"


def tmux(*args):
    return subprocess.check_output(["tmux", "-f", "/dev/null", "-S", SOCKET, *args], text=True).rstrip("\n")


def git(*args):
    env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
    return subprocess.check_output(["/usr/bin/git", "-C", str(PROJECT), "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", *args], env=env, text=True).strip()


def save(name, value):
    (EVIDENCE / f"{name}.json").write_text(json.dumps(value, indent=2) + "\n")


def snapshot():
    return json.loads(JOURNAL.read_text())


def presentation(value):
    return next(item for scene in value["scenes"] if scene["isMain"] for item in scene["sessions"] if item["sessionName"] == "restore-content")


def await_snapshot(check):
    deadline = time.monotonic() + 20
    while True:
        try:
            value = snapshot()
            check(value)
            return value
        except (AssertionError, FileNotFoundError, KeyError, StopIteration) as error:
            if time.monotonic() >= deadline:
                raise AssertionError(f"{PHASE}: {error}") from error
            time.sleep(0.2)


def assert_repository_unchanged():
    before = json.loads((EVIDENCE / "repository.json").read_text())
    current = {"head": git("rev-parse", "HEAD"), "index": git("write-tree"), "status": git("status", "--porcelain"), "stash": git("rev-parse", "refs/stash")}
    assert current == before, (before, current)
    assert (ROOT / "editor-request.txt").read_text() == "Original prompt must remain unchanged."
    return current


def setup():
    (PROJECT / "docs" / "nested").mkdir(parents=True)
    (PROJECT / "docs" / "chapter.txt").write_text("RECOVERED_FILE_PREVIEW\n" + "\n".join(f"chapter line {n}" for n in range(120)))
    (PROJECT / "docs" / "nested" / "detail.txt").write_text("Nested file retained.\n")
    (PROJECT / "change.txt").write_text("original\n")
    git("init", "-b", "main")
    git("config", "user.name", "Workspace Recovery Fixture")
    git("config", "user.email", "recovery@example.invalid")
    git("add", ".")
    git("commit", "-m", "Recovery initial commit")
    (PROJECT / "change.txt").write_text("committed history value\n")
    git("commit", "-am", "Recovery selected history")
    (PROJECT / "change.txt").write_text("stashed recovery value\n")
    git("stash", "push", "-m", "Recovery selected stash")
    (PROJECT / "change.txt").write_text("uncommitted recovery value\n")
    save("repository", {"head": git("rev-parse", "HEAD"), "index": git("write-tree"), "status": git("status", "--porcelain"), "stash": git("rev-parse", "refs/stash")})
    (ROOT / "editor-request.txt").write_text("Original prompt must remain unchanged.")
    (ROOT / ".workspace-content-fixture").touch()
    tmux("respawn-pane", "-k", "-t", "restore-content:0.0", "-c", str(PROJECT), "/bin/sh")
    tmux("rename-window", "-t", "restore-content:0", "CONTENT")
    tmux("set-window-option", "-t", "restore-content:0", "automatic-rename", "off")
    tmux("new-window", "-d", "-t", "restore-content:1", "-n", "OTHER", "-c", str(PROJECT / "docs"), "/bin/sh")
    tmux("set-window-option", "-t", "restore-content:1", "automatic-rename", "off")
    tmux("select-window", "-t", "restore-content:0")
    return {"directory": str(PROJECT)}


def editor():
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(150)
        client.connect(str(ROOT / "api.sock"))
        request = {"id": str(uuid.uuid4()), "method": "editor.open", "params": {"pane_id": tmux("display-message", "-p", "-t", "restore-content:0.0", "#{pane_id}"), "file_path": str(ROOT / "editor-request.txt")}}
        client.sendall((json.dumps(request) + "\n").encode())
        response = b""
        while b"\n" not in response:
            block = client.recv(4096)
            if not block:
                break
            response += block
        return {"response": response.decode()}


def require_content(value, view="history"):
    item = presentation(value)
    tabs = item["layout"]["fileTabs"]
    assert len(tabs) == 1, tabs
    browser = tabs[0]["browser"]
    assert Path(browser["path"]).resolve() == PROJECT / "docs", browser
    assert Path(browser["selectedFile"]).resolve() == PROJECT / "docs" / "chapter.txt", browser
    assert PROJECT / "docs" / "nested" in {Path(path).resolve() for path in browser["expanded"]}, browser
    assert len(value["fileTabs"]) == 1
    state = item["gitState"]
    assert state["directory"] == str(PROJECT), state
    assert state["view"] == view, state
    assert state["commitMessage"] == MESSAGE, state
    if view == "history":
        assert state["commitID"] == git("rev-parse", "HEAD"), state
        assert state["commitFile"] == "change.txt", state
    elif view == "stashes":
        assert state["stashID"] == git("rev-parse", "refs/stash"), state
        assert state["stashFile"] == "change.txt", state
    drafts = value["drafts"]
    assert len(drafts) == 1 and drafts[0]["text"] == DRAFT, drafts
    pane = next(pane for session in value["sessions"] if session["name"] == "restore-content" for window in session["windows"] if window["index"] == 0 for pane in window["panes"])
    assert drafts[0]["paneID"] == pane["id"]
    assert not value.get("recovery"), value.get("recovery")


def run():
    if PHASE == "setup":
        return setup()
    assert (ROOT / ".workspace-content-fixture").exists()
    if PHASE == "editor":
        return editor()
    if PHASE == "select-source":
        tmux("select-window", "-t", "restore-content:0")
        def selected_source(value):
            session = next(session for session in value["sessions"] if session["name"] == "restore-content")
            source = next(window for window in session["windows"] if window["index"] == 0)
            assert session["selectedWindowID"] == source["id"], session
        return {"snapshot": await_snapshot(selected_source)}
    if PHASE == "metadata":
        previous = tmux("display-message", "-p", "-t", "restore-content:1", "#{window_name}")
        name = "OTHER-REFRESHED" if previous == "OTHER" else "OTHER"
        tmux("rename-window", "-t", "restore-content:1", name)
        def refreshed(value):
            session = next(session for session in value["sessions"] if session["name"] == "restore-content")
            other = next(window for window in session["windows"] if window["index"] == 1)
            assert other["name"] == name, other
        return {"snapshot": await_snapshot(refreshed)}
    if PHASE == "remove-file":
        require_content(snapshot(), "stashes")
        (PROJECT / "docs" / "chapter.txt").rename(ROOT / "offline-chapter.txt")
        return {"fileUnavailable": True}
    if PHASE == "missing-file":
        value = await_snapshot(lambda value: require_content(value, "stashes"))
        item = presentation(value)
        identity = item["layout"]["fileTabs"][0]["id"]
        assert item["layout"]["selectedLeft"] == {"file": {"id": identity}}, item["layout"]
        assert not (PROJECT / "docs" / "chapter.txt").exists()
        return {"snapshot": value}
    if PHASE == "return-file":
        (ROOT / "offline-chapter.txt").rename(PROJECT / "docs" / "chapter.txt")
        return {"fileAvailable": True}
    if PHASE == "file-returned":
        value = await_snapshot(lambda value: require_content(value, "stashes"))
        return {"snapshot": value, "repository": assert_repository_unchanged()}
    if PHASE in ("captured", "restored", "rebuilt", "stash-captured", "stash-restored"):
        value = await_snapshot(lambda value: require_content(value, "stashes" if PHASE.startswith("stash") else "history"))
        if PHASE == "captured":
            save("baseline", value)
        else:
            before = json.loads((EVIDENCE / "baseline.json").read_text())
            assert value["fileTabs"] == before["fileTabs"]
            assert value["drafts"] == before["drafts"]
        return {"snapshot": value, "repository": assert_repository_unchanged()}
    if PHASE == "prepare-reboot":
        value = snapshot()
        require_content(value)
        # Closing the App immediately after a tab click can capture its private
        # selection before the queued tmux select-window finishes. Preserve this
        # real divergence deterministically: later metadata must not steal focus.
        item = presentation(value)
        session = next(session for session in value["sessions"] if session["name"] == "restore-content")
        source = next(window for window in session["windows"] if window["index"] == 0)
        other = next(window for window in session["windows"] if window["index"] == 1)
        assert item["selectedWindowID"] == source["id"], item
        session["selectedWindowID"] = other["id"]
        value["bootID"] = "workspace-content-simulated-boot"
        JOURNAL.write_text(json.dumps(value))
        return {"simulatedBootChange": True, "selectedWindowID": source["id"], "tmuxActiveWindowID": other["id"]}
    raise ValueError(PHASE)


try:
    result = run()
    save(PHASE, {"passed": True, **result})
except Exception:
    save(PHASE, {"passed": False, "error": traceback.format_exc()})
    raise
