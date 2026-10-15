#!/usr/bin/env python3
"""Pane default/extra-page regression in a separately signed, private Host.

Uses native Codex-named identity fixtures, not user agents. No installed app,
personal profile, system browser, or inherited control grants are used.
"""
import argparse
import asyncio
from pathlib import Path

from managed_engine import Managed


class PaneDefaults(Managed):
    mock_keychain = True

    async def validate(self, _):
        for run, tab in zip(self.runs, self.tabs):
            await self.request(run, 'close', tab=tab)
        for owner, engine in ((0, 'ctrlx'), (1, 'vercel')):
            async def action(operation, *flags, ok=True):
                return await self.cli_action(owner, 'action', operation, '--engine', engine, *flags, ok=ok)

            address = self.url
            primary = (await action('open', '--url', address.rstrip('/')))['result']['id']
            await action('wait', '--tab', primary)
            await action('fill', '--tab', primary, '--selector', '#message', '--text', 'unchanged')
            await action('click', '--tab', primary, '--selector', '#apply')
            await action('wait', '--tab', primary, '--selector', '#result', '--text', 'unchanged')
            same = (await action('open', '--url', address))['result']['id']
            assert same == primary
            assert 'unchanged' in (await action('read', '--tab', primary))['result']['text']
            self.passed(engine + ': same-URL open preserves identity and DOM')

            extra = (await action('open', '--new', '--url', address + '-extra'))['result']['id']
            assert extra != primary
            again = (await action('open', '--url', address + '-next'))['result']['id']
            assert again == primary
            await action('wait', '--tab', primary)
            pages = (await action('tabs'))['result']
            assert {page['id'] for page in pages} == {primary, extra}
            assert next(page for page in pages if page['id'] == extra)['url'] == address + '-extra'
            self.passed(engine + ': explicit extra never replaces default or gets navigated by reuse')

            await action('close', '--tab', primary)
            async def closed():
                return all(page['id'] != primary for page in (await action('tabs'))['result'])
            await self.wait(closed)
            replacement = (await action('open', '--url', address))['result']['id']
            assert replacement not in (primary, extra)
            assert (await action('open', '--url', address))['result']['id'] == replacement
            assert len((await action('tabs'))['result']) == 2
            self.passed(engine + ': closing default creates a replacement without promoting an extra')


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'engine', 'identity'):
        parser.add_argument(name, type=lambda path: Path(path).resolve())
    test = PaneDefaults(parser.parse_args())
    await test.run()
    assert test.host.returncode == 0, 'Isolated Host did not quit normally'


if __name__ == '__main__':
    asyncio.run(main())
