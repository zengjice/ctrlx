#!/usr/bin/env python3
import json
import os
from pathlib import Path
import socket
import struct
import sys

PLUGIN_ID = "claude-code"
SOCKET_PATH = os.path.expanduser("~/.ctrlx/state/ingress.sock")
MAX_SKILL_BYTES = 5000


def emit_file_link_context(payload):
    if not isinstance(payload, dict) or payload.get("hook_event_name") != "SessionStart":
        return

    # Use the bundled skill as the single source for the output convention.
    skill = Path(__file__).resolve().parent.parent / "skills/file-links/SKILL.md"
    try:
        with skill.open("rb") as source:
            data = source.read(MAX_SKILL_BYTES + 1)
        if len(data) > MAX_SKILL_BYTES:
            return
        text = data.decode("utf-8")
    except (OSError, UnicodeError):
        return  # Optional context must not interrupt lifecycle forwarding.

    header, separator, body = text.partition("\n---\n")
    if not header.startswith("---\n") or not separator or not body.strip():
        return
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "SessionStart", "additionalContext": body.strip(),
    }}))


def main():
    tmux_pane = os.environ.get("TMUX_PANE", "")
    if not tmux_pane:
        return  # Not inside tmux — nothing to mirror.

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return

    context = {"TMUX_PANE": tmux_pane}
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if project_dir:
        context["CLAUDE_PROJECT_DIR"] = project_dir

    body = json.dumps(
        {"plugin_id": PLUGIN_ID, "context": context, "payload": payload}
    ).encode("utf-8")
    frame = struct.pack(">I", len(body)) + body

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)
            sock.connect(SOCKET_PATH)
            sock.sendall(frame)
    except Exception:
        return  # CtrlX not running / socket gone — drop silently.

    emit_file_link_context(payload)


if __name__ == "__main__":
    main()
