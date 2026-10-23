#!/usr/bin/env python3
"""Explicit tab creation/navigation regression in a separately signed, private Host.

Uses native Codex-named identity fixtures, not user agents. No installed app,
personal profile, system browser, or inherited control grants are used.
"""
import argparse
import asyncio
from pathlib import Path

from managed_engine import Managed


class TabOpening(Managed):
    mock_keychain = True

    async def validate(self, _):
        for run, original in zip(self.runs, self.tabs):
            second = (await self.request(run, 'open', url=self.url))['id']
            legacy = (await self.request(run, 'open', url=self.url, new=False))['id']
            assert len({original, second, legacy}) == 3
            for tab in (original, second, legacy):
                await self.request(run, 'close', tab=tab)
        self.passed('native opens without new flag or with legacy false still create distinct pages')

        for owner, engine in ((0, 'ctrlx'), (1, 'vercel')):
            async def action(operation, *flags, ok=True):
                return await self.cli_action(owner, 'action', operation, '--engine', engine, *flags, ok=ok)

            address = self.url
            first = (await action('open', '--url', address.rstrip('/')))['result']['id']
            await action('wait', '--tab', first)
            await action('fill', '--tab', first, '--selector', '#message', '--text', 'unchanged')
            await action('click', '--tab', first, '--selector', '#apply')
            await action('wait', '--tab', first, '--selector', '#result', '--text', 'unchanged')
            second = (await action('open', '--url', address))['result']['id']
            extra = (await action('open', '--new', '--url', address + '-extra'))['result']['id']
            next_page = (await action('open', '--url', address + '-next'))['result']['id']
            assert len({first, second, extra, next_page}) == 4
            assert 'unchanged' in (await action('read', '--tab', first))['result']['text']
            self.passed(engine + ': every open, including same URL and legacy --new, creates a new ID without modifying the old DOM')

            await action('navigate', '--tab', second, '--url', address + '-targeted')
            await action('wait', '--tab', second)
            for tab in (extra, next_page):
                await action('wait', '--tab', tab)
            pages = (await action('tabs'))['result']
            assert {page['id'] for page in pages} == {first, second, extra, next_page}
            urls = {page['id']: page['url'] for page in pages}
            assert urls == {first: address, second: address + '-targeted', extra: address + '-extra', next_page: address + '-next'}
            assert 'unchanged' in (await action('read', '--tab', first))['result']['text']
            await self.cli_action(1 - owner, 'action', 'read', '--tab', first, ok=False)
            self.passed(engine + ': tabs lists owned pages only; navigate changes exactly the requested tab; other owner denied')

            await action('close', '--tab', first)
            async def closed():
                return all(page['id'] != first for page in (await action('tabs'))['result'])
            await self.wait(closed)
            await action('read', '--tab', first, ok=False)
            replacement = (await action('open', '--url', address))['result']['id']
            assert replacement not in (first, second, extra, next_page)
            assert len((await action('tabs'))['result']) == 4
            self.passed(engine + ': closing a page leaves siblings intact; later open creates another page')


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'engine', 'identity'):
        parser.add_argument(name, type=lambda path: Path(path).resolve())
    test = TabOpening(parser.parse_args())
    await test.run()
    assert test.host.returncode == 0, 'Isolated Host did not quit normally'


if __name__ == '__main__':
    asyncio.run(main())
