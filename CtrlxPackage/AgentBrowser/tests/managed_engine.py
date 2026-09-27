#!/usr/bin/env python3
"""Both product engines through the public CLI in an isolated CEF app.

Uses native `codex`-named fixture processes, NOT real Codex. No probe macro,
Python CDP gateway or borrowed production grants. Arguments: app engine identity.
Compile engine_identity.cc as `codex` for the identity argument.
"""
import asyncio
import json
import os
import signal
from pathlib import Path
import shlex
import subprocess
import sys
import uuid
from websockets.asyncio.client import connect
from upstream_probe import Probe


class Managed(Probe):
    native_gateway = True
    async def run(self):
        try:
            await super().run()
        finally:
            # Only private fixture engines. A failed assertion must not leave
            # a daemon until its idle timeout; do not inspect production state.
            for config in (self.root / 'agent-browser/runs').glob('*/*.engine.json'):
                directory = Path(json.loads(config.read_text())['directory'])
                pidfile = directory / 'page.pid'
                if not pidfile.exists():
                    continue
                pid = int(pidfile.read_text())
                executable = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='], capture_output=True, text=True).stdout.strip()
                if executable == str(self.args.engine):
                    os.kill(pid, signal.SIGTERM)

    async def setup(self):
        os.environ['CTRLX_BROWSER_TEST_STATE_ROOT'] = str(self.root)
        await super().setup()

    async def cli_action(self, number, *args, ok=True):
        prefix = self.root / str(uuid.uuid4())
        command = shlex.join([self.cli, 'browser', *args])
        if '\n' in command:
            # The native identity fixture reads one command per line. Preserve
            # literal newlines in argv without splitting its input protocol.
            command = shlex.join(['/usr/bin/python3', '-c',
                'import json,subprocess,sys;sys.exit(subprocess.run(json.loads(sys.argv[1])).returncode)',
                json.dumps([self.cli, 'browser', *args])])
        command += f' > {prefix}.out 2> {prefix}.err; echo $? > {prefix}.exit'
        name = ('upstream-alpha', 'upstream-beta')[number]
        pane = (await self.control('list-panes', '--window', name + ':1'))['panes'][0]['id']
        await self.control('send', command, '--pane', pane, '--enter')
        async def done():
            path = Path(str(prefix) + '.exit')
            return path.read_text().strip() if path.exists() else None
        code = int(await self.wait(done, 100))
        error = Path(str(prefix) + '.err').read_text()
        assert (code == 0) == ok, (args, error)
        if not ok:
            return error
        return json.loads(Path(str(prefix) + '.out').read_text())

    async def engine_stream_status(self, tab):
        # Read the test daemon's own IPC without changing its launch flags/env.
        # Running the upstream CLI with different flags could restart it and
        # would test that new process instead of the product-created daemon.
        config = next((self.root / 'agent-browser/runs').glob('*/' + tab + '.engine.json'))
        directory = Path(json.loads(config.read_text())['directory'])
        reader, writer = await asyncio.open_unix_connection(str(directory / 'page.sock'))
        try:
            writer.write(json.dumps({'id': str(uuid.uuid4()), 'action': 'stream_status'}).encode() + b'\n')
            await writer.drain()
            response = json.loads(await asyncio.wait_for(reader.readline(), 5))
            assert response['success']
            return response['data']
        finally:
            writer.close()
            await writer.wait_closed()

    async def validate(self, _):
        # Close the setup-only pages. The public CLI creates its own credentials
        # and opens new native tabs in the same two fixture process instances.
        for run, tab in zip(self.runs, self.tabs):
            await self.request(run, 'close', tab=tab)
        self.passed('setup credentials not reused by public CLI')
        assert (await self.cli_action(0, 'engine'))['engine'] == 'vercel'
        assert (await self.cli_action(1, 'engine'))['engine'] == 'vercel'
        assert (await self.cli_action(1, 'engine', 'ctrlx'))['engine'] == 'ctrlx'
        assert (await self.cli_action(1, 'engine'))['engine'] == 'ctrlx'
        a = (await self.cli_action(0, 'action', 'open', '--url', self.url + 'alpha'))['result']['id']
        b = (await self.cli_action(1, 'action', 'open', '--url', self.url + 'beta'))['result']['id']
        for owner, tab in ((0, a), (1, b)):
            await self.cli_action(owner, 'action', 'wait', '--tab', tab)
        self.passed('vercel default, saved original-engine choice and per-instance embedded opening')
        snapshot = (await self.cli_action(0, 'action', 'snapshot', '--tab', a))['result']
        assert not (await self.engine_stream_status(a))['enabled'], 'Product engine preview streaming unexpectedly enabled'
        self.passed('product-created engine preview streaming remains disabled after attachment')
        textbox = next(key for key, value in snapshot['refs'].items() if value['role'] == 'textbox')
        await self.cli_action(1, 'action', 'show', '--tab', b)
        await self.cli_action(0, 'action', 'fill', '--tab', a, '--selector', '@' + textbox, '--text', 'Managed 中文')
        await self.cli_action(0, 'action', 'click', '--tab', a, '--selector', '#apply')
        text = (await self.cli_action(0, 'action', 'read', '--tab', a))['result']['text']
        assert 'Managed 中文; trusted=true' in text
        assert 'Managed 中文' not in (await self.cli_action(1, 'action', 'read', '--tab', b))['result']['text']
        self.passed('public CLI invokes bundled upstream, refs and trusted input target the exact page')
        await self.cli_action(0, 'action', 'fill', '--engine', 'ctrlx', '--tab', a, '--selector', '#message', '--text', 'Original engine')
        await self.cli_action(0, 'action', 'click', '--engine', 'ctrlx', '--tab', a, '--selector', '#apply')
        assert 'Original engine; trusted=true' in (await self.cli_action(0, 'action', 'read', '--tab', a))['result']['text']
        self.passed('original engine still works on the same page without replacing it')
        await self.cli_action(0, 'action', 'click', '--tab', a, '--selector', '#login')
        await self.cli_action(1, 'action', 'navigate', '--tab', b, '--url', self.url + 'shared')
        await self.cli_action(1, 'action', 'wait', '--tab', b)
        text = (await self.cli_action(1, 'action', 'read', '--tab', b))['result']['text']
        assert all(s in text for s in ('storage=persisted', 'persistent=fixture', 'session=fixture'))
        self.passed('both engines share the existing profile/login')
        await self.cli_action(0, 'action', 'click', '--tab', a, '--selector', '#child')
        tabs = (await self.cli_action(0, 'action', 'tabs'))['result']
        assert len(tabs) == 2 and all(t['presentation']['session'] == 'upstream-alpha' for t in tabs)
        child = next(t['id'] for t in tabs if t['id'] != a)
        await self.cli_action(0, 'action', 'wait', '--tab', child)
        await self.cli_action(0, 'action', 'snapshot', '--tab', child)
        await self.cli_action(0, 'action', 'fill', '--tab', child, '--selector', '#message', '--text', 'Child only')
        await self.cli_action(0, 'action', 'click', '--tab', child, '--selector', '#apply')
        assert 'Child only' not in (await self.cli_action(0, 'action', 'read', '--tab', a))['result']['text']
        await self.cli_action(1, 'action', 'snapshot', '--engine', 'vercel', '--tab', child, ok=False)
        self.passed('child routing, per-tab engine state and cross-owner refusal')
        await self.cli_action(0, 'action', 'screenshot', '--tab', a, '--output', str(self.root / 'managed.png'))
        assert (self.root / 'managed.png').read_bytes().startswith(b'\x89PNG')
        self.passed('managed screenshot uses existing no-overwrite CLI contract')
        await self.cli_action(0, 'action', 'navigate', '--tab', a, '--url', self.url + 'navigate')
        await self.cli_action(0, 'action', 'wait', '--tab', a)
        await self.cli_action(0, 'action', 'snapshot', '--tab', a)
        self.passed('upstream snapshot after host-managed navigation')
        await self.cli_action(0, 'action', 'navigate', '--tab', a, '--url', self.url + 'actions')
        await self.cli_action(0, 'action', 'wait', '--tab', a)
        await self.cli_action(0, 'action', 'snapshot', '--tab', a)
        await self.cli_action(0, 'action', 'fill', '--tab', a, '--selector', '#text', '--text', '')
        await self.cli_action(0, 'action', 'type', '--tab', a, '--selector', '#text', '--text', 'hello')
        await self.cli_action(0, 'action', 'press', '--tab', a, '--key', 'Enter')
        text = (await self.cli_action(0, 'action', 'read', '--tab', a, '--selector', '#key-event'))['result']['text']
        assert 'Enter' in text and 'trusted=true' in text
        await self.cli_action(0, 'action', 'check', '--tab', a, '--selector', '#check', '--checked', 'true')
        await self.cli_action(0, 'action', 'check', '--tab', a, '--selector', '#check', '--checked', 'true')
        checked = (await self.cli_action(0, 'action', 'read', '--tab', a, '--selector', '#check-events'))['result']['text']
        assert checked.startswith('1;')
        await self.cli_action(0, 'action', 'select', '--tab', a, '--selector', '#select', '--value', 'b')
        selected = (await self.cli_action(0, 'action', 'read', '--tab', a, '--selector', '#select'))['result']['controls'][0]['value']
        assert selected == 'b'
        await self.cli_action(0, 'action', 'fill', '--tab', a, '--selector', '#text', '--text=--provider')
        value = (await self.cli_action(0, 'action', 'read', '--tab', a, '--selector', '#text'))['result']['controls'][0]['value']
        assert value == '--provider'
        self.passed('upstream type/press/select/idempotent check and literal flag-like input')
        # Read ONLY fixture context, never print tokens. Verify native gateway
        # denies origin-bearing requests and browser-wide method access.
        context_paths = list((self.root / 'agent-browser/runs').glob('*/context.json'))
        context = next(json.loads(p.read_text()) for p in context_paths
                       if json.loads(p.read_text()).get('pid') == self.runs[0]['pid'])
        from integration import call
        attach = await asyncio.to_thread(call, context['socket'], dict(context, command='engine.attach', tab=b), False)
        assert 'not owned' in attach
        self.passed('native gateway refuses another instance target')
        # End fixture daemons via their own private sockets before tab close;
        # this must not close CEF or the parent CtrlX window.
        parent_url = None
        for config in (self.root / 'agent-browser/runs').glob('*/*.engine.json'):
            directory = Path(json.loads(config.read_text())['directory'])
            provider = directory / 'provider.json'
            if not provider.exists():
                continue  # An ownership-refused action must never start an engine.
            url = json.loads(provider.read_text())['url']
            if config.name == a + '.engine.json':
                parent_url = url
            env = {'PATH': '/usr/bin:/bin', 'HOME': str(directory), 'AGENT_BROWSER_SOCKET_DIR': str(directory)}
            process = await asyncio.create_subprocess_exec(str(self.args.engine), '--config', str(directory / 'config.json'),
                '--session', 'page', 'close', env=env, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
            await asyncio.wait_for(process.wait(), 15)
            async with connect(url) as ws:
                for index, method in enumerate(('Target.getTargets', 'Target.attachToTarget', 'Storage.getCookies', 'Browser.close', 'Page.navigate', 'Network.clearBrowserCookies')):
                    await ws.send(json.dumps({'id': index, 'method': method, 'params': {}}))
                    while True:
                        reply = json.loads(await asyncio.wait_for(ws.recv(), 10))
                        if reply.get('id') == index:
                            break
                    assert 'error' in reply
            try:
                async with connect(url, origin='https://untrusted.example'): pass
                raise AssertionError('Origin accepted')
            except Exception as error:
                assert not isinstance(error, AssertionError)
        self.passed('browser-wide control and web-origin connections denied; disconnect preserves native views')
        error = await self.cli_action(0, 'action', 'fill', '--tab', a, '--selector', '@e1', '--text', 'must not insert', ok=False)
        assert 'reference state expired' in error
        self.passed('expired refs cannot silently bind to a newly bootstrapped snapshot')
        await self.cli_action(0, 'action', 'close', '--tab', child)
        await self.cli_action(0, 'action', 'snapshot', '--tab', child, ok=False)
        await self.cli_action(0, 'engine', 'ctrlx')
        assert len((await self.cli_action(0, 'action', 'tabs'))['result']) == 1
        await self.control('ping')
        self.passed('closing one target and switching engine preserves other tabs and app')
        assert parent_url
        async with connect(parent_url) as ws:
            os.kill(self.runs[0]['pid'], signal.SIGTERM)
            try:
                await asyncio.wait_for(ws.recv(), 5)
                raise AssertionError('Dead owner retained its connection')
            except Exception as error:
                assert not isinstance(error, (AssertionError, asyncio.TimeoutError))
        try:
            async with connect(parent_url): pass
            raise AssertionError('Dead owner could reconnect')
        except Exception as error:
            assert not isinstance(error, AssertionError)
        assert len((await self.cli_action(1, 'action', 'tabs'))['result']) == 1
        self.passed('owner exit revokes gateway without affecting the other owner')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'engine', 'identity'):
        parser.add_argument(name, type=lambda p: Path(p).resolve())
    asyncio.run(Managed(parser.parse_args()).run())
