"""Synthetic local model responses shared by native CLI and signed-App recovery tests."""

import http.server
import json
import shlex
import threading


class ModelFixture(http.server.ThreadingHTTPServer):
    def __init__(self, agent, scenario, marker):
        self.agent, self.scenario, self.marker = agent, scenario, marker
        self.requests = []
        self.release = threading.Event()
        super().__init__(("127.0.0.1", 0), Handler)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/requests":
            self.send_json({"requests": self.server.requests})
            return
        self.send_json({"data": [{"id": "gpt-5.4", "object": "model"}]})

    def send_json(self, value):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(value).encode())

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        self.server.requests.append({"path": self.path, "model": body.get("model"), "has_tools": bool(body.get("tools"))})
        if "count_tokens" in self.path:
            self.send_json({"input_tokens": 5})
            return
        main = bool(body.get("tools"))
        if main and self.server.scenario == "interrupted":
            self.server.release.wait(60)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        approval = main and self.server.scenario == "approval"
        marker_command = "printf RECOVERY_APPROVAL_FIXTURE > " + shlex.quote(str(self.server.marker))
        if self.server.agent == "codex":
            item = {"id": "msg_fixture", "type": "message", "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": "RECOVERY_IDLE_FIXTURE", "annotations": []}]}
            if approval:
                item = {"id": "fc_fixture", "type": "function_call", "name": "exec_command", "call_id": "call_fixture", "arguments": json.dumps({"cmd": marker_command, "sandbox_permissions": "require_escalated", "justification": "Isolated recovery fixture; do not approve."})}
            events = [
                {"type": "response.created", "response": {"id": "resp_fixture", "status": "in_progress", "output": []}},
                {"type": "response.output_item.done", "output_index": 0, "item": item},
                {"type": "response.completed", "response": {"id": "resp_fixture", "model": "gpt-5.4", "status": "completed", "output": [item], "usage": {"input_tokens": 5, "output_tokens": 5, "total_tokens": 10}}},
            ]
        else:
            block = {"type": "text", "text": ""}
            delta = {"type": "text_delta", "text": "RECOVERY_IDLE_FIXTURE"}
            if approval:
                block = {"type": "tool_use", "id": "toolu_fixture", "name": "Bash", "input": {}}
                delta = {"type": "input_json_delta", "partial_json": json.dumps({"command": marker_command, "description": "Create isolated recovery test marker"})}
            events = [
                {"type": "message_start", "message": {"id": "msg_fixture", "type": "message", "role": "assistant", "content": [], "model": "claude-sonnet-4-5", "stop_reason": None, "usage": {"input_tokens": 5, "output_tokens": 0}}},
                {"type": "content_block_start", "index": 0, "content_block": block},
                {"type": "content_block_delta", "index": 0, "delta": delta},
                {"type": "content_block_stop", "index": 0},
                {"type": "message_delta", "delta": {"stop_reason": "tool_use" if approval else "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 5}},
                {"type": "message_stop"},
            ]
        try:
            for event in events:
                self.wfile.write(("event: " + event["type"] + "\ndata: " + json.dumps(event) + "\n\n").encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass  # The tested CLI may be deliberately interrupted during a reply.
