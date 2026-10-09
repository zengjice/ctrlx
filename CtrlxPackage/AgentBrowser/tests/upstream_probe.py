#!/usr/bin/env python3
"""Isolated upstream binary + native CEF compatibility proof, not a product API.

Requires websockets >= 15, the upstream unmodified binary and a separately
signed acceptance app compiled with CTRLX_UPSTREAM_BROWSER_PROBE. Uses native
fixture identities (not real Codex); never connects to production credentials.
"""
import argparse
import asyncio
from collections import Counter
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import secrets
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

from websockets.asyncio.server import serve
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed
from integration import Fixture, call


def provider():
    request = json.load(sys.stdin)
    assert request['protocol'] == 'agent-browser.plugin.v1'
    settings = json.loads(Path(os.environ['CTRLX_PROBE_PROVIDER']).read_text())
    if request['type'] == 'browser.launch':
        body = {'browser': {'cdpUrl': settings['url'], 'directPage': True}}
    elif request['type'] == 'plugin.manifest':
        body = {'manifest': {'name': 'ctrlx-proof', 'capabilities': ['browser.provider']}}
    else:
        raise ValueError('unsupported fixture provider request')
    print(json.dumps({'protocol': 'agent-browser.plugin.v1', 'success': True, **body}))


class Probe:
    def __init__(self, args):
        self.args = args
        self.root = Path(tempfile.mkdtemp(prefix='cx-upstream-'))
        self.host = None
        self.endpoint = None
        self.bindings = {}
        self.used = {}
        self.commands = []
        self.methods = Counter()
        self.denied = Counter()
        self.checks = []
        self.keep_host = False
        self.api = str(self.root / 'api.sock')
        self.socket = str(self.root / 'tmux.sock')
        self.cli = str(args.app / 'Contents/MacOS/CtrlXCLI')

    async def control(self, *words):
        process = await asyncio.create_subprocess_exec(self.cli, *words, '--socket', self.api, '--json',
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        stdout, stderr = await asyncio.wait_for(process.communicate(), 30)
        assert process.returncode == 0, stderr.decode()
        reply = json.loads(stdout)
        assert reply['ok'], reply
        return reply['result']

    async def request(self, run, command, **params):
        return await asyncio.to_thread(call, self.endpoint['socket'], dict(run, command=command, **params))

    async def wait(self, predicate, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = await predicate()
            if result:
                return result
            await asyncio.sleep(.1)
        raise AssertionError('Fixture deadline exceeded')

    def passed(self, name):
        self.checks.append(name)
        print('PASS:', name, flush=True)

    async def socket_handler(self, connection):
        # The path is a random capability bound to exactly ONE native tab.
        # Never log paths, credentials, request expressions or socket URLs.
        binding = self.bindings.get(connection.request.path)
        if not binding or connection.request.headers.get('Origin'):
            await connection.close(1008, 'Unauthorized')
            return
        run, tab = binding
        send_lock = asyncio.Lock()

        async def send(value):
            async with send_lock:
                await connection.send(json.dumps(value))

        async def events():
            try:
                while True:
                    batch = await self.request(run, 'probe.events', tab=tab)
                    for event in batch:
                        await send(event)
                    await asyncio.sleep(.03)
            except asyncio.CancelledError:
                raise
            except Exception:
                await connection.close(1008, 'Tab grant ended')

        async def dispatch(value):
            message_id = value.get('id')
            method = value.get('method', '')
            self.methods[method] += 1
            try:
                if value.get('sessionId'):
                    raise ValueError('Other CDP sessions are not exposed')
                result = await self.request(run, 'probe.cdp', tab=tab, method=method, params=value.get('params', {}))
                await send({'id': message_id, 'result': result})
            except Exception:
                self.denied[method] += 1
                await send({'id': message_id, 'error': {'code': -32000, 'message': 'Probe operation denied or failed'}})

        poll = asyncio.create_task(events())
        requests = set()
        try:
            async for payload in connection:
                task = asyncio.create_task(dispatch(json.loads(payload)))
                requests.add(task)
                task.add_done_callback(requests.discard)
        except ConnectionClosed:
            pass  # Expected when this test disconnects an engine or closes its tab.
        finally:
            poll.cancel()
            for task in requests:
                task.cancel()
            await asyncio.gather(poll, *requests, return_exceptions=True)

    async def upstream(self, name, *words, ok=True):
        env = {key: value for key, value in os.environ.items() if not key.startswith('AGENT_BROWSER_')}
        env.update(AGENT_BROWSER_SOCKET_DIR=str(self.root / 'engine'),
                   AGENT_BROWSER_CONFIG=str(self.root / 'config.json'),
                   AGENT_BROWSER_PLUGINS=json.dumps([{'name': 'ctrlx-proof', 'command': sys.executable,
                       'args': [str(Path(__file__).resolve()), '--provider'], 'capabilities': ['browser.provider']}]),
                   CTRLX_PROBE_PROVIDER=str(self.root / (name + '-provider.json')),
                   AGENT_BROWSER_IDLE_TIMEOUT_MS='120000', AGENT_BROWSER_NO_AUTO_DIALOG='1',
                   AGENT_BROWSER_SCREENSHOT_DIR=str(self.root), NO_PROXY='127.0.0.1,localhost')
        args = [str(self.args.engine), '--config', str(self.root / 'config.json'), '--session', name,
                '--json']
        if name not in self.used:
            args += ['--provider', 'ctrlx-proof', '--no-webmcp']
        args += list(words)
        self.used[name] = True
        process = await asyncio.create_subprocess_exec(*args, env=env, cwd=self.root,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), 40)
        except asyncio.TimeoutError:
            process.terminate()
            await process.wait()
            raise AssertionError('Upstream command timed out: ' + ' '.join(words))
        value = json.loads(stdout) if stdout.strip() else {'stderr': stderr.decode()}
        self.commands.append({'session': name, 'args': words, 'exit': process.returncode, 'response': value})
        (self.root / 'commands.json').write_text(json.dumps(self.commands, ensure_ascii=False, indent=2))
        if ok:
            assert process.returncode == 0 and value.get('success'), (words, value)
        return value

    async def setup(self):
        if Path(self.api).exists():
            with socket.socket(socket.AF_UNIX) as existing:
                try:
                    existing.connect(self.api)
                except ConnectionRefusedError:
                    pass  # Previous isolated host left its socket inode.
                else:
                    raise AssertionError('Another E2E host is active; do not reuse it')
        info = plistlib.loads((self.args.app / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleIdentifier'] == 'com.ctrlx.embedded-acceptance'
        assert hashlib.sha256(self.args.engine.read_bytes()).hexdigest() == '2e61287259053ea964d39e77002c6a34af0e589e55ccff25e659efae7e892e0d'
        (self.root / 'config.json').write_text('{}')
        (self.root / 'engine').mkdir(mode=0o700)
        log = (self.root / 'host.log').open('wb')
        self.host = subprocess.Popen([str(self.args.app / 'Contents/MacOS/CtrlX'), '--e2e-test',
            '--tmux-socket', self.socket, '--ctrlx-state-root', str(self.root), '--e2e-api-socket', self.api,
            '--zdotdir', str(Path(__file__).resolve().parent / 'shell')],
            stdout=log, stderr=log, start_new_session=True)
        print('Artifacts:', self.root, 'isolated host PID:', self.host.pid, flush=True)
        async def ready():
            assert self.host.poll() is None, 'Test host exited'
            path = self.root / 'agent-browser/endpoint.json'
            return json.loads(path.read_text()) if path.exists() else None
        self.endpoint = await self.wait(ready)
        await self.control('wait-ready', '--timeout', '30')
        self.runs = []
        for name in ('upstream-alpha', 'upstream-beta'):
            await self.control('new-session', '--name', name, '--path', str(self.root))
            async def first_pane():
                panes = (await self.control('list-panes', '--window', name + ':1'))['panes']
                return panes[0]['id'] if panes else None
            pane = await self.wait(first_pane)
            path = self.root / (name + '.json')
            await self.control('send', shlex.quote(str(self.args.identity)) + ' > ' + shlex.quote(str(path)),
                '--pane', pane, '--enter')
            async def identity():
                return json.loads(path.read_text()) if path.exists() and path.stat().st_size else None
            run = await self.wait(identity)
            run.update(run=str(uuid.uuid4()), secret=secrets.token_hex(32), label=name)
            run.update(await self.request(run, 'register'))
            self.runs.append(run)
        await self.control('select-session', 'upstream-beta')
        self.tabs = []
        for index, run in enumerate(self.runs):
            self.tabs.append((await self.request(run, 'open', url=self.url + str(index)))['id'])
        print('Waiting for isolated pages. If Keychain asks, authorization is user-operated.', flush=True)
        async def pages_ready():
            return all([not tab['loading'] for run in self.runs for tab in await self.request(run, 'tabs')])
        try:
            await self.wait(pages_ready, 300)
        except Exception:
            self.keep_host = True
            raise
        for index, run in enumerate(self.runs):
            tabs = await self.request(run, 'tabs')
            assert len(tabs) == 1 and tabs[0]['presentation']['embedded']
            assert tabs[0]['presentation']['session'] == ('upstream-alpha', 'upstream-beta')[index]
        self.passed('native embedded views and source-session routing')

    def bind(self, port, name, run, tab):
        path = '/' + secrets.token_urlsafe(32)
        self.bindings[path] = (run, tab)
        url = f'ws://127.0.0.1:{port}{path}'
        private = self.root / (name + '-provider.json')
        private.write_text(json.dumps({'url': url}))
        private.chmod(0o600)
        return url

    async def validate(self, port):
        a, b = self.runs
        first, second = self.tabs
        urls = []
        for name, run, tab in zip(('alpha', 'beta'), self.runs, self.tabs):
            urls.append(self.bind(port, name, run, tab))
        snapshot = await self.upstream('alpha', 'snapshot', '-i')
        print('Upstream snapshot acquired', flush=True)
        refs = snapshot['data']['refs']
        textbox = next(key for key, value in refs.items() if value['role'] == 'textbox')
        button = next(key for key, value in refs.items() if value.get('name') == 'Apply')
        await self.upstream('alpha', 'stream', 'disable')
        await self.upstream('beta', 'snapshot', '-i')
        await self.upstream('beta', 'stream', 'disable')
        self.passed('unmodified upstream provider, CEF snapshot and element refs')
        await self.request(b, 'show', tab=second)
        await self.upstream('alpha', 'fill', '@' + textbox, 'Upstream 中文 proof')
        await self.upstream('alpha', 'click', '@' + button)
        async def applied():
            return 'Upstream 中文 proof; trusted=true' in (await self.request(a, 'read', tab=first))['text']
        await self.wait(applied)
        self.passed('upstream ref fill/click sends trusted Chinese input to authorized page')
        assert 'Upstream 中文 proof' not in (await self.request(b, 'read', tab=second))['text']
        self.passed('opposing focus does not redirect input to the other instance')
        await self.upstream('alpha', 'find', 'role', 'button', 'click', '--name', 'Fixture login')
        await self.request(b, 'navigate', tab=second, url=self.url + 'shared')
        await self.request(b, 'wait', tab=second)
        text = (await self.request(b, 'read', tab=second))['text']
        assert all(value in text for value in ('storage=persisted', 'persistent=fixture', 'session=fixture'))
        self.passed('shared fixture login and persistent profile across owners')
        await self.upstream('beta', 'snapshot', '-i')
        await self.upstream('beta', 'fill', '#message', 'Beta only')
        await self.upstream('beta', 'click', '#apply')
        self.passed('upstream backend survives CtrlX-managed navigation')
        await self.upstream('alpha', 'click', '#child')
        async def child_ready():
            children = [tab for tab in await self.request(a, 'tabs') if tab['id'] != first]
            return children[0] if len(children) == 1 and not children[0]['loading'] else None
        child = await self.wait(child_ready)
        assert child['presentation']['embedded']
        assert child['presentation']['session'] == 'upstream-alpha'
        self.bind(port, 'alpha-child', a, child['id'])
        await self.upstream('alpha-child', 'snapshot', '-i')
        await self.upstream('alpha-child', 'stream', 'disable')
        await self.upstream('alpha-child', 'fill', '#message', 'Child only')
        await self.upstream('alpha-child', 'click', '#apply')
        async def child_applied():
            return 'Child only; trusted=true' in (await self.request(a, 'read', tab=child['id']))['text']
        await self.wait(child_applied)
        parent_text = (await self.request(a, 'read', tab=first))['text']
        assert 'Upstream 中文 proof' in parent_text and 'Child only' not in parent_text
        assert 'Child only' not in (await self.request(b, 'read', tab=second))['text']
        denied = await asyncio.to_thread(call, self.endpoint['socket'],
            dict(b, command='probe.cdp', tab=child['id'], method='Runtime.evaluate', params={}), False)
        assert denied == 'Probe tab not authorized.'
        await self.upstream('alpha-child', 'close')
        assert len(await self.request(a, 'tabs')) == 2
        await self.request(a, 'close', tab=child['id'])
        self.passed('same-owner child tab inherits routing, has independent upstream state and rejects other owners')
        screenshot = self.root / 'upstream.png'
        await self.upstream('alpha', 'screenshot', str(screenshot))
        assert screenshot.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
        self.passed('upstream screenshot from native embedded page')
        # Bad owner/target is rejected by native grant checks, not just the proxy.
        for method in ('Runtime.evaluate', 'Input.insertText'):
            result = await asyncio.to_thread(call, self.endpoint['socket'],
                dict(b, command='probe.cdp', tab=first, method=method, params={}), False)
            assert result == 'Probe tab not authorized.'
        self.passed('native cross-owner read/input refusal')
        async with connect(urls[0]) as ws:
            for index, method in enumerate(('Target.getTargets', 'Target.attachToTarget', 'Browser.close', 'Storage.getCookies')):
                await ws.send(json.dumps({'id': index + 1, 'method': method, 'params': {'targetId': second}}))
                while True:
                    value = json.loads(await asyncio.wait_for(ws.recv(), 10))
                    if value.get('id') == index + 1:
                        assert 'error' in value
                        break
        self.passed('browser-wide enumeration, attach, cookies and close denied')
        async with connect(f'ws://127.0.0.1:{port}/incorrect-token') as ws:
            try:
                await ws.recv()
                raise AssertionError('Unauthorized socket accepted')
            except Exception as error:
                assert getattr(error, 'rcvd', None).code == 1008
        self.passed('unauthenticated bridge connection refused')
        await self.upstream('alpha', 'close')
        assert len(await self.request(a, 'tabs')) == 1 and len(await self.request(b, 'tabs')) == 1
        await self.control('ping')
        self.passed('upstream disconnect does not close CtrlX or sibling pages')
        await self.request(a, 'close', tab=first)
        assert len(await self.request(b, 'tabs')) == 1
        try:
            await self.request(a, 'probe.cdp', tab=first, method='Runtime.evaluate', params={'expression': '1'})
            raise AssertionError('Closed tab unexpectedly accessible')
        except AssertionError as error:
            assert 'Probe tab not authorized.' in str(error)
        self.passed('closed target has no neighboring-tab fallback')

    async def run(self):
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.url = f'http://127.0.0.1:{server.server_port}/'
        try:
            await self.setup()
            if getattr(self, 'native_gateway', False):
                await self.validate(0)
            else:
                async with serve(self.socket_handler, '127.0.0.1', 0, max_size=262144) as ws:
                    try:
                        await self.validate(ws.sockets[0].getsockname()[1])
                    finally:
                        for name in list(self.used):
                            await self.upstream(name, 'close', ok=False)
            self.passed('compatibility proof complete')
        except Exception:
            # Preserve only fixture pane/PID diagnostics before cleanup. These
            # distinguish a missing owner process from a browser regression.
            panes = subprocess.run(['/opt/homebrew/bin/tmux', '-S', self.socket, 'list-panes', '-a',
                '-F', '#{pane_id} #{pane_pid} #{session_name} #{pane_current_command}'],
                capture_output=True, text=True, timeout=5)
            pids = [str(run['pid']) for run in getattr(self, 'runs', [])]
            pids += [line.split()[1] for line in panes.stdout.splitlines() if len(line.split()) > 1]
            if pids:
                process = subprocess.run(['ps', '-p', ','.join(pids), '-o', 'pid,ppid,comm'],
                    capture_output=True, text=True, timeout=5)
                print('Fixture panes:', panes.stdout, 'Fixture processes:', process.stdout, flush=True)
            raise
        finally:
            # A failed provider attach can leave its CLI daemon alive. Only
            # terminate exact test binaries from this private socket directory.
            for pidfile in (self.root / 'engine').glob('*.pid'):
                pid = int(pidfile.read_text())
                executable = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='], capture_output=True, text=True).stdout.strip()
                if executable == str(self.args.engine):
                    os.kill(pid, signal.SIGTERM)
            server.shutdown()
            if self.host and self.host.poll() is None and not self.keep_host:
                result = await asyncio.create_subprocess_exec('osascript', '-e',
                    'tell application ' + json.dumps(str(self.args.app)) + ' to quit')
                await asyncio.wait_for(result.wait(), 15)
                await asyncio.to_thread(self.host.wait, 20)
                subprocess.run(['/opt/homebrew/bin/tmux', '-S', self.socket, 'kill-server'], capture_output=True)
            summary = {'checks': self.checks, 'methods': dict(self.methods), 'denied': dict(self.denied),
                       'engine': '0.38.1', 'fixture': 'native identities, not real Codex',
                       'hostStopped': self.host is not None and self.host.poll() is not None}
            (self.root / 'summary.json').write_text(json.dumps(summary, indent=2))
            print('Evidence:', self.root / 'summary.json', flush=True)


if __name__ == '__main__':
    if sys.argv[1:] == ['--provider']:
        provider()
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('app', type=lambda p: Path(p).resolve())
        parser.add_argument('engine', type=lambda p: Path(p).resolve())
        parser.add_argument('identity', type=lambda p: Path(p).resolve())
        asyncio.run(Probe(parser.parse_args()).run())
