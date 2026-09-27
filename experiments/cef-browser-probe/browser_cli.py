#!/usr/bin/env python3
"""Experimental CtrlX browser CLI. No browser discovery, TCP, extensions or MCP."""
import argparse
import base64
import json
import os
from pathlib import Path
import socket
import stat
import sys

MAX_REQUEST = 65536
MAX_RESPONSE = 8 * 1024 * 1024 + 4096


def validate_socket(path: Path) -> None:
    # Refuse symlinks and endpoints not explicitly owned by this user. A socket
    # path is a local capability, not protection against malicious same-UID apps.
    directory = path.parent.lstat()
    endpoint = path.lstat()
    if (not stat.S_ISDIR(directory.st_mode) or directory.st_uid != os.getuid()
            or directory.st_mode & 0o077
            or not stat.S_ISSOCK(endpoint.st_mode) or endpoint.st_uid != os.getuid()
            or endpoint.st_mode & 0o077):
        raise ValueError("Expected an owner-only directory and Unix socket from the probe.")


def request(path: Path, payload: dict, timeout: float = 15) -> object:
    validate_socket(path)
    message = json.dumps(payload, ensure_ascii=False).encode() + b"\n"
    if len(message) > MAX_REQUEST:
        raise ValueError("Request too large.")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(str(path))
        connection.sendall(message)
        chunks = bytearray()
        while b"\n" not in chunks:
            part = connection.recv(65536)
            if not part:
                raise ValueError("Connection closed without a response; outcome unknown, not retried.")
            chunks.extend(part)
            if len(chunks) > MAX_RESPONSE:
                raise ValueError("Response too large.")
    reply = json.loads(chunks)
    if not isinstance(reply, dict) or reply.get("ok") is not True:
        raise ValueError(reply.get("error", "Invalid response") if isinstance(reply, dict) else "Invalid response")
    return reply["result"]


def save_screenshot(result: dict, output: Path) -> dict:
    data = base64.b64decode(result["data"], validate=True)
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Browser did not return PNG data.")
    # Never overwrite an existing file or follow an output symlink.
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
    return {"path": str(output.absolute()), "bytes": len(data)}


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--socket", type=Path, required=True, help="Exact automation-socket printed by the probe")
    commands = result.add_subparsers(dest="command", required=True)
    commands.add_parser("tabs", help="List only explicitly exposed embedded tabs")
    commands.add_parser("quit", help="Close this experimental probe, not production CtrlX/Chrome")
    for name in ("read", "click", "type", "screenshot"):
        command = commands.add_parser(name)
        command.add_argument("--tab", required=True, help="Exact ID returned by tabs; never an active-tab fallback")
        if name in ("click", "type"):
            command.add_argument("--selector", required=True, help="Unique CSS selector observed in read output")
        if name == "type":
            command.add_argument("--text", required=True, help="Insert text at the target field's caret; does not submit")
        if name == "screenshot":
            command.add_argument("--output", type=Path, required=True, help="New PNG path; existing files are refused")
    return result


def main(argv=None) -> int:
    arguments = parser().parse_args(argv)
    payload = {key: value for key, value in vars(arguments).items() if key not in ("socket", "output")}
    try:
        value = request(arguments.socket, payload)
        if arguments.command == "screenshot":
            value = save_screenshot(value, arguments.output)
        print(json.dumps({"ok": True, "result": value}, ensure_ascii=False))
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
