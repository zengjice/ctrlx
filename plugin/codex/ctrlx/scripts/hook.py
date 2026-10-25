#!/usr/bin/env python3
import json
import os
from pathlib import Path
import socket
import struct
import sys

PLUGIN_ID = "codex"
SOCKET_PATH = os.path.expanduser("~/.ctrlx/state/ingress.sock")
MAX_SKILL_BYTES = 5000


def read_skill_body(skill):
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
    return body.strip()


def emit_session_context(payload):
    if not isinstance(payload, dict) or payload.get("hook_event_name") != "SessionStart":
        return

    # Bundled entrypoints remain the single source for these early instructions.
    skills = Path(__file__).resolve().parent.parent / "skills"
    contexts = []
    for name in ("file-links", "agent-ios", "agent-browser"):
        skill = skills / name / "SKILL.md"
        body = read_skill_body(skill)
        if body:
            if name != "file-links":
                body = (f"Skill source: `{skill}`. Resolve relative references from this file.\n\n"
                        + body)
            contexts.append(body)
    if not contexts:
        return
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "SessionStart", "additionalContext": "\n\n".join(contexts),
    }}))


def main():
    tmux_pane = os.environ.get("TMUX_PANE", "")
    if not tmux_pane:
        return

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return

    body = json.dumps(
        {"plugin_id": PLUGIN_ID,
         "context": {"TMUX_PANE": tmux_pane, "CTRLX_INGRESS_ACK": "1", "CTRLX_WORKFLOW_VERSION": "1"},
         "payload": payload}
    ).encode("utf-8")
    frame = struct.pack(">I", len(body)) + body

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)
            sock.connect(SOCKET_PATH)
            sock.sendall(frame)
            # Keep this process alive until the Host captures socket ancestry.
            # Older Hosts close on EOF without a reply, so no upgrade handshake
            # or extra timeout is needed for backward compatibility.
            sock.shutdown(socket.SHUT_WR)
            sock.recv(1)
    except Exception:
        return

    emit_session_context(payload)


if __name__ == "__main__":
    main()
