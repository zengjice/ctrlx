#!/usr/bin/env python3
"""CLI updates with running Agent fixtures in an isolated signed Host.

Arguments: app engine identity (engine_identity.cc compiled as codex).
Only a private copy of the identity fixture is unlinked; no real Agent is used.
"""
import argparse
import asyncio
import json
from pathlib import Path
import shlex
import shutil
import uuid

from resource_resume import ResourceResume


class ResourceCLIUpdate(ResourceResume):
    async def setup(self):
        installation = self.root / 'private-cli-install'
        installation.mkdir()
        binary = installation / 'codex'
        shutil.copyfile(self.args.identity, binary)
        binary.chmod(0o700)
        self.args.identity = binary
        await super().setup()

    async def ios_identity(self, number):
        output = self.root / (str(uuid.uuid4()) + '.ios.json')
        words = ['/usr/bin/env', 'CTRLX_SOCKET=' + self.api,
                 self.cli, 'ios', 'identity', '--socket', self.api]
        command = shlex.join(words) + ' > ' + shlex.quote(str(output))
        session = ('upstream-alpha', 'upstream-beta')[number]
        pane = (await self.control('list-panes', '--window', session + ':1'))['panes'][0]['id']
        await self.control('send', command, '--pane', pane, '--enter')

        async def ready():
            return json.loads(output.read_text()) if output.exists() and output.stat().st_size else None
        return await self.wait(ready)

    async def validate(self, _):
        for run, tab in zip(self.runs, self.tabs):
            await self.request(run, 'close', tab=tab)
        for number in (0, 1):
            await self.restart(number, str(uuid.uuid4()))
        tab = (await self.cli_action(0, 'action', 'open', '--engine', 'ctrlx', '--url', self.url + 'resume'))['result']['id']
        await self.cli_action(0, 'action', 'wait', '--engine', 'ctrlx', '--tab', tab)
        await self.cli_action(0, 'action', 'fill', '--engine', 'ctrlx', '--tab', tab,
                              '--selector', '#message', '--text', 'Keep this running conversation')
        await self.cli_action(0, 'action', 'click', '--engine', 'ctrlx', '--tab', tab, '--selector', '#apply')
        before = await self.ios_identity(0)
        contexts = list((self.root / 'agent-browser/runs').glob('*/context.json'))
        context_path = next(path for path in contexts if json.loads(path.read_text())['pid'] == self.runs[0]['pid'])
        context = json.loads(context_path.read_text())
        self.args.identity.unlink()

        fresh = (await self.cli_action(1, 'action', 'open', '--engine', 'ctrlx',
                                      '--url', self.url + 'first-call-after-update'))['result']['id']
        await self.cli_action(1, 'action', 'wait', '--engine', 'ctrlx', '--tab', fresh)
        self.passed('first browser call after CLI unlink succeeds without a cached executable path')

        for engine in ('ctrlx', 'vercel'):
            text = (await self.cli_action(0, 'action', 'read', '--engine', engine, '--tab', tab))['result']['text']
            assert 'Keep this running conversation' in text, text
            opened = (await self.cli_action(0, 'action', 'open', '--engine', engine,
                                            '--url', self.url + 'after-update-' + engine))['result']['id']
            assert opened != tab
            await self.cli_action(0, 'action', 'wait', '--engine', engine, '--tab', opened)
            denied = await self.cli_action(1, 'action', 'read', '--engine', engine, '--tab', opened, ok=False)
            assert 'another instance' in denied or 'not owned' in denied, denied
            self.passed(engine + ' reads existing and opens new pages after CLI unlink; other Agent denied')
        current = json.loads(context_path.read_text())
        assert current['run'] == context['run'] and current['secret'] == context['secret']
        assert (await self.ios_identity(0))['owner'] == before['owner']
        self.passed('browser credentials and simulator caller identity survive CLI unlink without resume')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'engine', 'identity'):
        parser.add_argument(name, type=lambda value: Path(value).resolve())
    asyncio.run(ResourceCLIUpdate(parser.parse_args()).run())
