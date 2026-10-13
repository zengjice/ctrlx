#!/usr/bin/env python3
"""Real CLI/socket recovery under native caller fixtures, never a live Host/profile.

Run: python3 CtrlxPackage/AgentBrowser/tests/reconnect.py <built-CtrlxCLI>
"""
import json
import os
from pathlib import Path
import select
import shlex
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import uuid


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        request = json.loads(self.rfile.readline(65537))
        response = self.server.respond(request)
        if response is not None:
            self.wfile.write(json.dumps(response).encode() + b'\n')


class Server:
    def __init__(self, path, respond):
        self.path = path
        self.server = socketserver.UnixStreamServer(str(path), Handler)
        os.chmod(path, 0o600)
        self.server.respond = respond
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={'poll_interval': 0.01})
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.thread.join(timeout=5)
        assert not self.thread.is_alive()
        self.server.server_close()
        # Leave the dead inode, matching the reported stale-socket failure.


class Host:
    def __init__(self, root):
        self.root = root
        self.state = root / 'state' / 'agent-browser'
        self.preparations = 0
        self.reject_prepare = False
        self.api = Server(root / 'api.sock', self.prepare)
        self.browser = None
        self.generation = 0
        self.restart()

    def restart(self):
        if self.browser:
            self.browser.close()
        self.generation += 1
        self.epoch = str(uuid.uuid4())
        self.requests = []
        self.grants = {}
        self.pages = {str(uuid.uuid4()): ''}  # A human page is never adopted.
        self.revoked = set()
        self.reject_register = False
        self.wrong_epoch = False
        self.drop_open_reply = False
        self.browser = Server(self.root / f'browser-{self.generation}.sock', self.respond)
        # Discovery is published lazily through browser.start, like a new Host.
        (self.state / 'endpoint.json').unlink(missing_ok=True)

    def prepare(self, request):
        self.preparations += 1
        if (self.reject_prepare or request['method'] != 'browser.start'
                or Path(request['params']['state']).resolve() != self.state.resolve()):
            return {'id': request['id'], 'ok': False,
                    'error': {'code': 'wrong_host', 'message': 'Wrong Host state'}}
        endpoint = self.state / 'endpoint.json'
        endpoint.write_text(json.dumps({'mode': 'embedded', 'epoch': self.epoch,
                                        'socket': str(self.browser.path)}))
        endpoint.chmod(0o600)
        return {'id': request['id'], 'ok': True, 'result': {}}

    def respond(self, request):
        self.requests.append(request)
        command = request['command']
        if command == 'register':
            if self.reject_register:
                return {'ok': False, 'error': 'Registration refused'}
            self.grants[request['run']] = request['secret']
            return {'ok': True, 'result': {'epoch': 'unexpected' if self.wrong_epoch else self.epoch}}
        owner = request['run']
        if (request['epoch'] != self.epoch or owner in self.revoked
                or self.grants.get(owner) != request['secret']):
            return {'ok': False, 'error': 'Instance not authorized'}
        if command == 'tabs':
            return {'ok': True, 'result': [{'id': tab} for tab, run in self.pages.items() if run == owner]}
        if command == 'open':
            tab = str(uuid.uuid4())
            self.pages[tab] = owner
            return None if self.drop_open_reply else {'ok': True, 'result': {'id': tab}}
        tab = request.get('tab')
        if self.pages.get(tab) != owner:
            return {'ok': False, 'error': 'Tab not owned'}
        if command == 'close':
            del self.pages[tab]
        return {'ok': True, 'result': {}}

    def count(self, command):
        return sum(r['command'] == command for r in self.requests)

    def context(self):
        paths = list((self.state / 'runs').glob('*/context.json'))
        assert len(paths) == 1
        return json.loads(paths[0].read_text())

    def close(self):
        self.api.close()
        self.browser.close()


class Caller:
    def __init__(self, executable, cli, host):
        self.cli = cli
        env = dict(os.environ, CTRLX_BROWSER_TEST_STATE_ROOT=str(host.root / 'state'),
                   CTRLX_SOCKET=str(host.api.path))
        self.process = subprocess.Popen([str(executable)], env=env, text=True,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE)
        self.identity = json.loads(self.line())

    def line(self):
        assert select.select([self.process.stdout], [], [], 20)[0], 'Caller timed out'
        return self.process.stdout.readline()

    def commands(self, *commands):
        # The native fixture remains the nearest agent ancestor for every CLI.
        script = '''import concurrent.futures,json,subprocess,sys
def run(words):
    p = subprocess.run(words, text=True, capture_output=True, timeout=15)
    return [p.returncode, p.stdout, p.stderr]
with concurrent.futures.ThreadPoolExecutor() as pool:
    print(json.dumps(list(pool.map(run, json.loads(sys.argv[1])))), flush=True)
'''
        words = [[self.cli, 'browser', *c] for c in commands]
        self.process.stdin.write(shlex.join([sys.executable, '-c', f'exec({script!r})', json.dumps(words)]) + '\n')
        self.process.stdin.flush()
        return json.loads(self.line())

    def action(self, *words, error=None):
        code, stdout, stderr = self.commands(['action', *words])[0]
        if error is not None:
            assert code != 0 and error in stderr, (code, stderr)
            return None
        assert code == 0, stderr
        return json.loads(stdout)['result']

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)
        assert self.process.returncode == 0
        stderr = self.process.stderr.read()
        assert not stderr, stderr
        self.process.stdout.close()
        self.process.stderr.close()


def verify(executable, cli, root):
    host = Host(root)
    caller = Caller(executable, cli, host)
    try:
        assert caller.commands(['engine', 'ctrlx'])[0][0] == 0
        assert caller.action('tabs') == []
        initial = host.context()
        assert initial['pid'] == caller.identity['pid']
        first = caller.action('open', '--url', 'https://example.test')['id']
        caller.action('close', '--tab', first)
        assert caller.action('tabs') == []
        old_tab = caller.action('open', '--url', 'https://example.test')['id']
        assert host.context() == initial and host.count('register') == 1

        host.restart()
        before = host.preparations
        caller.action('click', '--tab', old_tab, '--selector', '#button', error='disconnected')
        assert host.preparations == before and not host.requests
        assert host.context() == initial
        # Concurrent entry points rotate/register once under the process lock.
        replies = caller.commands(['action', 'tabs'], ['action', 'tabs'])
        assert all(code == 0 and json.loads(out)['result'] == [] for code, out, _ in replies)
        fresh = host.context()
        assert fresh['run'] != initial['run'] and fresh['secret'] != initial['secret']
        assert fresh['pid'] == initial['pid'] and fresh['engine'] == 'ctrlx'
        assert fresh['epoch'] == host.epoch and host.count('register') == 1
        caller.action('read', '--tab', old_tab, error='Tab not owned')
        human_tab = next(tab for tab, owner in host.pages.items() if owner == '')
        caller.action('read', '--tab', human_tab, error='Tab not owned')
        caller.action('open', '--url', 'https://example.test')
        assert host.count('register') == 1

        # Direct open also reconnects; no need to list tabs first.
        host.restart()
        caller.action('open', '--url', 'https://example.test')
        assert host.count('register') == host.count('open') == 1
        stable = host.context()
        host.revoked.add(stable['run'])
        caller.action('tabs', error='not authorized')
        assert host.count('register') == 1 and host.context() == stable
        host.revoked.clear()

        host.drop_open_reply = True
        before = host.count('open')
        caller.action('open', '--url', 'https://example.test', error='outcome unknown')
        assert host.count('open') == before + 1 and host.context() == stable

        host.restart()
        host.reject_prepare = True
        caller.action('tabs', error='Wrong Host')
        assert not host.requests and host.context() == stable
        host.reject_prepare = False
        host.reject_register = True
        caller.action('open', '--url', 'https://example.test', error='Registration refused')
        assert host.count('register') == 1 and host.count('open') == 0
        assert host.context() == stable
        host.reject_register = False
        host.wrong_epoch = True
        caller.action('tabs', error='Invalid instance registration response')
        assert host.count('tabs') == 0 and host.context() == stable
        host.wrong_epoch = False
        assert caller.action('tabs') == []
        assert host.context()['epoch'] == host.epoch
    finally:
        try:
            caller.close()
        finally:
            host.close()


def main():
    cli = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='cx-reconnect-', dir='/tmp') as tmp:
        root = Path(tmp)
        binary = root / 'caller-fixture'
        subprocess.run(['clang++', '-std=c++20', str(Path(__file__).with_name('engine_identity.cc')),
                        '-o', str(binary)], check=True, capture_output=True, timeout=30)
        for name in ('codex', 'claude'):
            executable = root / name
            shutil.copy2(binary, executable)
            state = root / f'{name}-host'
            state.mkdir(mode=0o700)
            verify(executable, cli, state)
            print(f'PASS: {name}: close/reopen, restart recovery, concurrent registration, ownership, fail-closed and no replay')


if __name__ == '__main__':
    main()
