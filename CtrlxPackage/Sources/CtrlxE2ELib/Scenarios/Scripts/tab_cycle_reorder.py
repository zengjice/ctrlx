"""Open a compatibility Files tab through the isolated Debug Host."""
import json
from pathlib import Path
import socket
import sys


root = Path(sys.argv[1])
pane = sys.argv[2]
request = {
    "id": "tab-cycle-reorder",
    "method": "e2e.openPaneFiles",
    "params": {"session_name": "tabcycle", "pane_id": pane},
}
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(10)
    client.connect(str(root / "api.sock"))
    client.sendall((json.dumps(request) + "\n").encode())
    with client.makefile("rb") as stream:
        response = json.loads(stream.readline())

if response["ok"] and response["result"]["pane_id"] != pane:
    raise RuntimeError("Files tab did not retain its source pane")
(root / "pane-files.json").write_text(json.dumps(response), encoding="utf-8")
