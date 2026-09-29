#!/usr/bin/env python3
"""Same-workspace background-page/DevTools lifetime regression.

Public CLI actions run under native codex-named identity fixtures, NOT real
Codex. Inspector operations use the acceptance-only native probe. No personal
profile, production app, reload recovery or mutating request retry is used.
"""
import argparse
import asyncio
import json
from pathlib import Path

from devtools import DevTools


class BackgroundTabs(DevTools):
    async def validate(self, _):
        for run, tab in zip(self.runs, self.tabs):
            await self.request(run, 'close', tab=tab)
        pids = [run['pid'] for run in self.runs]
        pages = []
        for owner, path in ((0, 'alpha'), (0, 'beta'), (1, 'other-workspace')):
            tab = (await self.cli_action(owner, 'action', 'open', '--url', self.url + path))['result']['id']
            await self.cli_action(owner, 'action', 'wait', '--tab', tab)
            pages.append(tab)
        # Only the private fixture's grants; never borrow or log production ones.
        contexts = [json.loads(p.read_text()) for p in (self.root / 'agent-browser/runs').glob('*/context.json')]
        self.runs = [next(c for c in contexts if c['pid'] == pid) for pid in pids]
        owner, other = self.runs
        first, second, sibling = pages
        marker = 'Background preserved 中文'

        async def set_marker(text, engine):
            await self.cli_action(0, 'action', 'fill', '--engine', engine, '--tab', second,
                                  '--selector', '#message', '--text', text)
            await self.cli_action(0, 'action', 'click', '--engine', engine, '--tab', second,
                                  '--selector', '#apply')
            await self.cli_action(0, 'action', 'wait', '--tab', second,
                                  '--selector', '#result', '--text', text + '; trusted=true')
            await self.cli_action(0, 'action', 'show', '--tab', first)

        await set_marker(marker, 'ctrlx')
        await asyncio.sleep(.2)
        tabs = await self.request(owner, 'tabs')
        assert all(p['presentation']['session'] == 'upstream-alpha' for p in tabs)
        assert not next(p for p in tabs if p['id'] == second)['presentation']['visible']
        original_frame = (await self.request(owner, 'probe.cdp', tab=second,
                                            method='Page.getFrameTree'))['frameTree']['frame']['id']

        async def read_pair(label):
            # Sequential first: failure must not be blamed on concurrency.
            for tab in (first, second):
                result = await self.request(owner, 'read', tab=tab)
                if tab == second:
                    assert marker + '; trusted=true' in result['text']
            results = await asyncio.gather(*(self.request(owner, 'read', tab=t) for t in (first, second)))
            assert marker + '; trusted=true' in results[1]['text']
            frame = await self.request(owner, 'probe.cdp', tab=second, method='Page.getFrameTree')
            assert frame['frameTree']['frame']['id'] == original_frame, 'Background document was recreated'
            self.passed(label + ': sequential/concurrent reads retain the original document and DOM')

        async def public_reads(label):
            for engine in ('ctrlx', 'vercel'):
                result = await self.cli_action(0, 'action', 'read', '--engine', engine, '--tab', second)
                assert marker + '; trusted=true' in result['result']['text']
            result = await self.cli_action(0, 'action', 'snapshot', '--tab', second)
            assert marker in json.dumps(result, ensure_ascii=False)
            assert not (await self.engine_stream_status(second))['enabled']
            assert len(await self.request(other, 'tabs')) == 1
            assert marker not in (await self.request(other, 'read', tab=sibling))['text']
            await self.control('ping')
            self.passed(label + ': both public engines, snapshot and other workspace remain functional')

        async def tools_closed():
            return not (await self.tools(owner, first))['tools']

        await read_pair('immediate, no DevTools')
        print(f'Leaving second tab in background for {self.args.idle} seconds', flush=True)
        await asyncio.sleep(self.args.idle)
        await read_pair('idle, no DevTools')
        # Do not attach Vercel to B before the first close. Its protocol domains
        # could keep that renderer alive and hide a broken host lifetime.
        await self.tools(owner, first, 'show')
        await self.opened(owner, first)
        await read_pair('DevTools open on first tab')
        await self.tools(owner, first, 'close')
        await self.wait(tools_closed)
        await read_pair('last DevTools window closed')
        await public_reads('last DevTools window closed')

        for cycle in range(8):
            await self.tools(owner, first, 'show')
            await self.opened(owner, first)
            await self.tools(owner, first, 'close')
            await self.wait(tools_closed)
            await read_pair(f'close cycle {cycle + 1}')
            await public_reads(f'close cycle {cycle + 1}')
            marker = f'Updated after close {cycle + 1} 中文'
            await set_marker(marker, 'vercel' if cycle % 2 else 'ctrlx')
        await read_pair('trusted writes after repeated closes')

        await self.cli_action(0, 'action', 'show', '--tab', second)
        await read_pair('background tab reselected')
        await self.tools(owner, first, 'show')
        await self.opened(owner, first)
        await self.cli_action(0, 'action', 'close', '--tab', first)
        async def source_closed():
            return [p['id'] for p in await self.request(owner, 'tabs')] == [second]
        await self.wait(source_closed)
        await public_reads('source tab closed with its inspector')

        replacement = (await self.cli_action(0, 'action', 'open', '--url', self.url + 'replacement'))['result']['id']
        await self.cli_action(0, 'action', 'wait', '--tab', replacement)
        await public_reads('new tab created after close')
        await self.tools(owner, second, 'show')
        await self.opened(owner, second)
        # Quit with pages and an inspector still open. CefShutdown must occur
        # after CefRunMessageLoop returns, and the harness requires normal exit.


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('engine', type=Path)
    parser.add_argument('identity', type=Path)
    parser.add_argument('--idle', type=int, default=120)
    args = parser.parse_args()
    args.app, args.engine, args.identity = (p.resolve() for p in (args.app, args.engine, args.identity))
    test = BackgroundTabs(args)
    await test.run()
    assert test.host.returncode == 0, 'Host failed to quit normally'
    assert 'Chromium shutdown timed out' not in (test.root / 'host.log').read_text()
    test.passed('native loop unwinds and host quits normally with inspector open')
    summary = test.root / 'summary.json'
    evidence = json.loads(summary.read_text())
    evidence.update(checks=test.checks, hostExitCode=test.host.returncode, idleSeconds=args.idle)
    summary.write_text(json.dumps(evidence, indent=2))


if __name__ == '__main__':
    asyncio.run(main())
