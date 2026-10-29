#!/usr/bin/env python3
"""Conversation ownership through the public CLI in an isolated signed Host.

Uses codex-named native fixtures with writable rollout files, not real Codex.
No identity overrides, production profiles or live user panes.
Arguments: app engine identity (engine_identity.cc compiled as codex).
"""
import argparse
import asyncio
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import threading
import uuid

from managed_engine import Managed
from integration import Fixture, PAGE, call
import upstream_probe


class ResumeFixture(Fixture):
    ready = threading.Event()
    child_seen = threading.Event()

    def do_GET(self):
        if self.path == '/popup-ready':
            content = b'1' if self.ready.is_set() else b'0'
        elif self.path == '/resume':
            content = PAGE + b'''<button id="schedule-child">Schedule child</button><script>
            document.querySelector('#schedule-child').onclick = () => {
              const poll = setInterval(async () => {
                if (await (await fetch('/popup-ready')).text() === '1') {
                  clearInterval(poll); window.open('/late-child', '_blank');
                }
              }, 100);
            };</script>'''
        else:
            if self.path == '/late-child':
                self.child_seen.set()
            return super().do_GET()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(content)


upstream_probe.Fixture = ResumeFixture


class ResourceResume(Managed):
    mock_keychain = True

    def rollout(self, conversation):
        path = self.root / f'rollout-fixture-{conversation}.jsonl'
        if not path.exists():
            path.write_text(json.dumps({'type': 'session_meta', 'payload': {
                'id': conversation, 'source': 'cli'}}) + '\n')
        return path

    async def restart(self, number, conversation):
        old = self.runs[number]
        command = subprocess.check_output(['ps', '-p', str(old['pid']), '-o', 'comm='], text=True).strip()
        assert command == str(self.args.identity), command
        os.kill(old['pid'], signal.SIGTERM)
        async def exited():
            result = subprocess.run(['ps', '-p', str(old['pid']), '-o', 'comm='], capture_output=True, text=True)
            return not result.stdout.strip()
        await self.wait(exited)
        session = ('upstream-alpha', 'upstream-beta')[number]
        pane = (await self.control('list-panes', '--window', session + ':1'))['panes'][0]['id']
        output = self.root / (str(uuid.uuid4()) + '.identity.json')
        command = shlex.join([str(self.args.identity), '--rollout', str(self.rollout(conversation))])
        await self.control('send', command + ' > ' + shlex.quote(str(output)), '--pane', pane, '--enter')
        async def ready():
            return json.loads(output.read_text()) if output.exists() and output.stat().st_size else None
        self.runs[number] = await self.wait(ready)
        return pane

    async def validate(self, _):
        for run, tab in zip(self.runs, self.tabs):
            await self.request(run, 'close', tab=tab)
        conversation = str(uuid.uuid4())
        pane = await self.restart(0, conversation)
        tab = (await self.cli_action(0, 'action', 'open', '--engine', 'ctrlx', '--url', self.url + 'resume'))['result']['id']
        await self.cli_action(0, 'action', 'wait', '--engine', 'ctrlx', '--tab', tab)
        await self.cli_action(0, 'action', 'fill', '--engine', 'ctrlx', '--tab', tab, '--selector', '#message', '--text', 'Keep this document')
        await self.cli_action(0, 'action', 'click', '--engine', 'ctrlx', '--tab', tab, '--selector', '#apply')
        contexts = [json.loads(path.read_text()) for path in (self.root / 'agent-browser/runs').glob('*/context.json')]
        old = next(context for context in contexts if context['pid'] == self.runs[0]['pid'])
        assert await self.restart(0, conversation) == pane
        tabs = (await self.cli_action(0, 'action', 'tabs', '--engine', 'ctrlx'))['result']
        assert [row['id'] for row in tabs] == [tab], tabs
        for engine in ('ctrlx', 'vercel'):
            text = (await self.cli_action(0, 'action', 'read', '--engine', engine, '--tab', tab))['result']['text']
            assert 'Keep this document' in text
        self.passed('fresh process recovers original tab and DOM with both engines')
        await asyncio.to_thread(call, self.endpoint['socket'], dict(old, command='tabs'), ok=False)
        self.passed('old credentials remain revoked')

        await self.restart(0, str(uuid.uuid4()))
        assert (await self.cli_action(0, 'action', 'tabs'))['result'] == []
        await self.cli_action(0, 'action', 'read', '--engine', 'ctrlx', '--tab', tab, ok=False)
        await self.restart(1, conversation)
        assert (await self.cli_action(1, 'action', 'tabs'))['result'] == []
        await self.cli_action(1, 'action', 'read', '--engine', 'ctrlx', '--tab', tab, ok=False)
        self.passed('Fork and another pane cannot inherit resources')

        await self.restart(0, conversation)
        assert [row['id'] for row in (await self.cli_action(0, 'action', 'tabs'))['result']] == [tab]
        await self.cli_action(0, 'action', 'click', '--engine', 'ctrlx', '--tab', tab, '--selector', '#schedule-child')
        changed = self.rollout(str(uuid.uuid4()))
        await self.control('send', ':rollout ' + str(changed), '--pane', pane, '--enter')
        assert (await self.cli_action(0, 'action', 'tabs'))['result'] == []
        await self.cli_action(0, 'action', 'read', '--engine', 'ctrlx', '--tab', tab, ok=False)
        ResumeFixture.ready.set()
        async def child_opened():
            return ResumeFixture.child_seen.is_set()
        await self.wait(child_opened)
        assert (await self.cli_action(0, 'action', 'tabs'))['result'] == []
        await self.control('send', ':rollout ' + str(self.rollout(conversation)), '--pane', pane, '--enter')
        tabs = (await self.cli_action(0, 'action', 'tabs'))['result']
        assert len(tabs) == 2 and tab in [row['id'] for row in tabs], tabs
        for row in tabs:
            await self.cli_action(0, 'action', 'close', '--tab', row['id'])
        self.passed('delayed child inherits its parent conversation while native identity is unavailable')
        self.passed('same-process conversation changes cannot use a cached native identity')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'engine', 'identity'):
        parser.add_argument(name, type=lambda value: Path(value).resolve())
    asyncio.run(ResourceResume(parser.parse_args()).run())
