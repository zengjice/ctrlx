#!/usr/bin/env python3
"""CLI test driver launched by a real agent's shell tool; it never fakes identity."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import socket
import subprocess
import resource
import threading

parser = argparse.ArgumentParser()
parser.add_argument("--cli", required=True)
parser.add_argument("--api", required=True)
parser.add_argument("--control", required=True)
parser.add_argument("--workers", type=int, default=1)
args = parser.parse_args()
if not 1 <= args.workers <= 32:
    parser.error("--workers must be 1...32")
path = Path(args.control)
if path.exists():
    raise SystemExit("Control path exists; do not reuse an active driver")
allowed = {"inventory", "config", "resources", "identity", "devices", "open", "status", "metrics", "show", "display-mode", "snapshot", "wait", "tap", "swipe", "long-press", "drag", "rotate", "key", "button", "paste", "install", "launch", "terminate", "open-url", "screenshot", "claim", "close"}
completed = 0
counter_lock = threading.Lock()

def usage():
    own = resource.getrusage(resource.RUSAGE_SELF)
    children = resource.getrusage(resource.RUSAGE_CHILDREN)
    with counter_lock:
        count = completed
    return {"completedCLICommands": count, "driverCPUSeconds": own.ru_utime + own.ru_stime,
            "reapedCLICPUSeconds": children.ru_utime + children.ru_stime,
            "largestChildMaxRSSBytes": children.ru_maxrss}

def execute(client, request):
    global completed
    with client:
        if request == {"measure": True}:
            result = {"code": 0, "stdout": json.dumps(usage()), "stderr": ""}
        else:
            words = request["arguments"]
            if not isinstance(words, list) or not words or words[0] not in allowed or not all(isinstance(word, str) for word in words):
                result = {"code": 2, "stdout": "", "stderr": "Expected bounded simulator command argv; no CLI was launched"}
            else:
                try:
                    process = subprocess.run([args.cli, "simulator", *words, "--socket", args.api], capture_output=True, text=True, timeout=250)
                    result = {"code": process.returncode, "stdout": process.stdout, "stderr": process.stderr}
                except subprocess.TimeoutExpired:
                    result = {"code": 124, "stdout": "", "stderr": "CLI timed out; physical operation outcome may be unknown"}
            with counter_lock:
                completed += 1
        client.sendall(json.dumps(result).encode() + b"\n")

server = socket.socket(socket.AF_UNIX)
try:
    server.bind(str(path))
    os.chmod(path, 0o600)
    server.listen(args.workers)
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        while True:
            client, _ = server.accept()
            with client.makefile("rb") as stream:
                request = json.loads(stream.readline(65537))
            if request == {"stop": True}:
                with client:
                    client.sendall(b'{"code": 0}\n')
                break
            pool.submit(execute, client, request)
finally:
    server.close()
    path.unlink(missing_ok=True)
