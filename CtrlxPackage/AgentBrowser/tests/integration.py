#!/usr/bin/env python3
"""Own fixture, fresh private test profile, no personal browser or credentials."""
import http.server
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import page_actions
import concurrent.futures

PAGE = b'''<!doctype html><meta charset="utf-8"><title>CtrlX Agent Browser fixture</title>
<h1>Isolated browser acceptance</h1><input id="message"><button id="apply">Apply</button>
<p id="result">empty</p><p id="input-event">no input event</p><button id="login">Fixture login</button>
<a id="child" target="_blank" href="/child">Open child</a><p id="state"></p>
<script>function state(){document.querySelector('#state').textContent =
 'storage='+(localStorage.getItem('fixture')||'none')+'; cookies='+document.cookie;}
state();document.querySelector('#message').oninput=e=>{document.querySelector('#input-event').textContent=
'input='+e.target.value+'; trusted='+e.isTrusted};
document.querySelector('#apply').onclick=e=>{const result=
document.querySelector('#message').value+'; trusted='+e.isTrusted;
setTimeout(()=>{document.querySelector('#result').textContent=result},50)};
document.querySelector('#login').onclick=()=>{localStorage.setItem('fixture','persisted');
document.cookie='persistent=fixture; Max-Age=86400; Path=/';
document.cookie='session=fixture; Path=/';state()};</script>'''

class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        print('fixture GET', self.path, flush=True)
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(page_actions.PAGE if self.path.startswith('/actions') else PAGE)
    def log_message(self, *_):
        pass

def call(endpoint, data, ok=True):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(15)
        stream.connect(endpoint)
        stream.sendall(json.dumps(data).encode() + b'\n')
        response = b''
        while b'\n' not in response:
            chunk = stream.recv(16384)
            assert chunk, 'Lost browser response'
            response += chunk
        value = json.loads(response)
        assert value['ok'] == ok, value
        return value.get('result', value.get('error'))

def wait_for(predicate, timeout=15):
    deadline = None if timeout is None else time.monotonic() + timeout
    while deadline is None or time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.1)
    raise AssertionError('Timed out waiting for browser state')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('identity', type=Path)
    parser.add_argument('--interactive-setup', action='store_true',
                        help='Keep the first browser alive while the user handles macOS authorization; Ctrl+C cancels.')
    options = parser.parse_args()
    executable = options.executable.resolve()
    identity = options.identity.resolve()
    root = Path(tempfile.mkdtemp(prefix='ctrlx-agent-browser-test-'))
    print('Artifacts:', root, flush=True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}/'
    processes = []
    browser = None
    reports = Path.home() / 'Library/Logs/DiagnosticReports'
    existing_reports = set(reports.glob('CtrlX Agent Browser*.ips'))
    def check_crashes():
        # Helpers can outlive the browser and crash after a successful CEF exit.
        # ReportCrash writes asynchronously; page assertions alone miss this.
        for report in set(reports.glob('CtrlX Agent Browser*.ips')) - existing_reports:
            try:
                value = json.loads(report.read_text().split('\n', 1)[1])
            except (ValueError, OSError):
                continue # ReportCrash may still be writing; check again below.
            # macOS may redact the user/build-directory prefix as /Users/USER/*.
            bundle = '/' + executable.parents[2].name + '/Contents/'
            if bundle in value.get('procPath', ''):
                raise AssertionError(f'Browser/helper crashed: {report.name}, pid={value.get("pid")}')
    def instance():
        process = subprocess.Popen([str(identity)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        processes.append(process)
        run = json.loads(process.stdout.readline())
        run.update(run=str(uuid.uuid4()), secret=uuid.uuid4().hex + uuid.uuid4().hex, label='same pane / Codex')
        return process, run
    def launch(number):
        nonlocal browser
        log = (root / f'launch-{number}.log').open('wb')
        browser = subprocess.Popen([str(executable), '--test-directory=' + str(root)], stdout=log, stderr=log)
        print(f'Browser launch {number}: PID {browser.pid}', flush=True)
        def endpoint():
            assert browser.poll() is None, 'Browser exited; inspect log'
            path = root / 'State/endpoint.json'
            return json.loads(path.read_text()) if path.exists() else None
        return wait_for(endpoint, 30)
    def stop():
        # Companion routes SIGTERM through the UI loop for graceful CEF shutdown.
        browser.terminate()
        browser.wait(timeout=20)
        assert browser.returncode == 0
        assert not (root / 'State/endpoint.json').exists()
        for _ in range(50):
            check_crashes()
            time.sleep(.1)
    try:
        endpoint = launch(1)
        pa, a = instance()
        pb, b = instance()
        for run in (a, b):
            run.update(call(endpoint['socket'], dict(run, command='register')))
        def request(run, command, ok=True, **params):
            return call(endpoint['socket'], dict(run, command=command, **params), ok)
        assert request(a, 'tabs') == [] # manual startup tab is not exposed
        first = request(a, 'open', url=url)['id']
        second = request(b, 'open', url=url)['id']
        def initial_pages_ready():
            assert browser.poll() is None, 'Browser exited during initial setup'
            return all(not t['loading'] for r in (a, b) for t in request(r, 'tabs'))
        if options.interactive_setup:
            print('Interactive first-use setup: no load deadline. Handle any macOS prompt locally; '
                  'never enter a password in this terminal. Do not rebuild or relaunch this app. '
                  'Tests resume when both fixture pages load. Ctrl+C cancels.', flush=True)
        wait_for(initial_pages_ready, None if options.interactive_setup else
                 int(os.environ.get('CTRLX_TEST_LOAD_TIMEOUT', '30')))
        assert [t['id'] for t in request(a, 'tabs')] == [first]
        assert [t['id'] for t in request(b, 'tabs')] == [second]
        for operation in ('read', 'click', 'type', 'navigate', 'show', 'close', 'screenshot'):
            request(b, operation, ok=False, tab=first, selector='#apply', text='wrong', url=url)
        request(a, 'read', ok=False, tab='stale')
        request(a, 'Runtime.evaluate', ok=False, tab=first)
        request(a, 'open', ok=False, url='file:///etc/passwd')
        request(b, 'show', tab=second)
        request(a, 'type', tab=first, selector='#message', text='Unicode 中文 proof')
        request(b, 'show', tab=second)
        request(a, 'click', tab=first, selector='#apply')
        # CDP input acknowledgement is not an application-render completion
        # signal. Poll read-only state, never repeat the potentially mutating click.
        try:
            wait_for(lambda: 'Unicode 中文 proof; trusted=true' in request(a, 'read', tab=first)['text'])
        except AssertionError:
            print('Input fixture state:', request(a, 'read', tab=first), flush=True)
            raise
        assert 'Unicode 中文 proof' not in request(b, 'read', tab=second)['text']
        request(a, 'click', tab=first, selector='#login')
        request(b, 'navigate', tab=second, url=url + 'shared')
        wait_for(lambda: not request(b, 'tabs')[0]['loading'])
        shared = request(b, 'read', tab=second)['text']
        assert all(item in shared for item in ('storage=persisted', 'persistent=fixture', 'session=fixture')), shared
        request(a, 'click', tab=first, selector='#child')
        wait_for(lambda: len(request(a, 'tabs')) == 2)
        assert len(request(b, 'tabs')) == 1
        picture = request(a, 'screenshot', tab=first)
        import base64
        (root / 'page.png').write_bytes(base64.b64decode(picture['data']))
        page_actions.verify(request, a, b, url)
        with concurrent.futures.ThreadPoolExecutor() as pool:
            pending = pool.submit(request, a, 'wait', ok=False, tab=first, selector='#never-created', timeoutMs=5000)
            time.sleep(.2)
            pa.stdin.close()
            pa.wait(timeout=5)
            error = pending.result()
            assert any(reason in error.lower() for reason in ('revoked', 'authorized', 'ended', 'cancelled')), error
        request(a, 'read', ok=False, tab=first) # immediate PID-bound revocation
        request(a, 'register', ok=False) # cannot resurrect a dead agent
        old_epoch = endpoint['epoch']
        stop()
        endpoint = launch(2)
        assert endpoint['epoch'] != old_epoch
        request(b, 'tabs', ok=False) # still-live agent's OLD grant is invalid
        pc, c = instance()
        c.update(call(endpoint['socket'], dict(c, command='register')))
        restored = request(c, 'open', url=url + 'restart')['id']
        wait_for(lambda: not request(c, 'tabs')[0]['loading'])
        state = request(c, 'read', tab=restored)['text']
        assert all(item in state for item in ('storage=persisted', 'persistent=fixture', 'session=fixture')), state
        stop()
        print('PASS: ownership, trusted input, child inheritance, shared profile, restart persistence, process revocation, stale grants, no browser/helper crash reports', flush=True)
    finally:
        for process in processes:
            if process.poll() is None:
                process.stdin.close()
                process.wait(timeout=5)
        if browser and browser.poll() is None:
            browser.terminate()
            try:
                browser.wait(timeout=10)
            except subprocess.TimeoutExpired:
                browser.kill() # only our own isolated fixture process
                browser.wait(timeout=5)
        server.shutdown()

if __name__ == '__main__':
    main()
