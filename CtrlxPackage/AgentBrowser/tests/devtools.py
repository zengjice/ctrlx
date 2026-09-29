#!/usr/bin/env python3
"""Human DevTools lifecycle in an isolated signed CEF acceptance app.

Uses the same native runtime method as the SwiftUI button, via a compile-time
test-only probe. It does not automate the toolbar or claim real-Codex acceptance.
Arguments: acceptance app, pinned engine, native codex-named identity fixture.
"""
import argparse
import asyncio
import json
from pathlib import Path

from managed_engine import Managed


class DevTools(Managed):
    async def tools(self, owner, tab, action='status'):
        return await self.request(owner, 'probe.devtools', tab=tab, action=action)

    async def opened(self, owner, tab):
        async def ready():
            state = await self.tools(owner, tab)
            tools = state['tools']
            return (tools[0] if len(tools) == 1 and not state['pending']
                    and not tools[0]['loading'] and tools[0]['visible']
                    and tools[0]['url'].startswith('devtools://') else None)
        return await self.wait(ready)

    async def validate(self, _):
        for run, tab in zip(self.runs, self.tabs):
            await self.request(run, 'close', tab=tab)
        pids = [run['pid'] for run in self.runs]
        self.tabs = []
        for owner in range(2):
            tab = (await self.cli_action(owner, 'action', 'open', '--url', self.url + str(owner)))['result']['id']
            self.tabs.append(tab)
            await self.cli_action(owner, 'action', 'wait', '--tab', tab)
        # Read only this private fixture's own grants; never print credentials.
        contexts = [json.loads(path.read_text()) for path in (self.root / 'agent-browser/runs').glob('*/context.json')]
        self.runs = [next(context for context in contexts if context['pid'] == pid) for pid in pids]
        a, b = self.runs
        first, second = self.tabs
        await self.request(b, 'show', tab=second)
        await self.tools(a, first, 'show')
        opened = await self.opened(a, first)
        assert not (await self.tools(b, second))['tools']
        self.passed('native DevTools frontend loaded for the explicit source despite opposing focus')

        for _ in range(5):
            await self.tools(a, first, 'show')
        assert (await self.opened(a, first))['id'] == opened['id']
        assert (await self.tools(a, first))['total'] == 1
        for owner, tab in zip(self.runs, self.tabs):
            assert [page['id'] for page in await self.request(owner, 'tabs')] == [tab]
        self.passed('repeated show reuses one window; tools are never registered as agent tabs')

        await self.request(a, 'type', tab=first, selector='#message', text='DevTools coexist 中文')
        await self.request(a, 'click', tab=first, selector='#apply')
        async def applied():
            return 'DevTools coexist 中文; trusted=true' in (await self.request(a, 'read', tab=first))['text']
        await self.wait(applied)
        snapshot = await self.cli_action(0, 'action', 'snapshot', '--tab', first)
        assert 'DevTools coexist' in json.dumps(snapshot)
        assert not (await self.engine_stream_status(first))['enabled']
        self.passed('agent trusted input and read continue with DevTools attached')

        await self.tools(a, first, 'close')
        async def tools_closed():
            return not (await self.tools(a, first))['tools']
        await self.wait(tools_closed)
        assert await applied()
        snapshot = await self.cli_action(0, 'action', 'snapshot', '--tab', first)
        assert 'DevTools coexist' in json.dumps(snapshot)
        for words in [('inspect',), ('stream', 'enable'), ('dashboard', 'start')]:
            await self.cli_action(0, 'command', '--tab', first, '--', *words, ok=False)
        await self.control('ping')
        self.passed('tools close preserves DOM and both engines; CLI inspect/stream/dashboard still refused')

        for _ in range(8):
            await self.tools(a, first, 'show')
            await self.opened(a, first)
            await self.tools(a, first, 'close')
            await self.wait(tools_closed)
            assert await applied()
            snapshot = await self.cli_action(0, 'action', 'snapshot', '--tab', first)
            assert 'DevTools coexist' in json.dumps(snapshot)
        self.passed('eight repeated open/close cycles preserve DOM and both automation engines')

        await self.tools(a, first, 'show')
        reopened = await self.opened(a, first)
        assert reopened['id'] != opened['id']
        await self.tools(b, second, 'show')
        await self.opened(b, second)
        assert (await self.tools(b, second))['total'] == 2
        await self.request(a, 'navigate', tab=first, url=self.url + 'navigated')
        await self.request(a, 'wait', tab=first)
        assert (await self.opened(a, first))['id'] == reopened['id']
        self.passed('independent source windows; navigation retains the same inspector')

        await self.request(a, 'close', tab=first)
        async def only_second():
            state = await self.tools(b, second)
            return state['total'] == 1 and not state['pending']
        await self.wait(only_second)
        assert not await self.request(a, 'tabs')
        assert len(await self.request(b, 'tabs')) == 1
        self.passed('closing a source disposes only its own inspector')

        temporary = (await self.request(a, 'open', url=self.url + 'race'))['id']
        await self.request(a, 'wait', tab=temporary)
        await self.tools(a, temporary, 'show')
        await self.request(a, 'close', tab=temporary)
        await self.wait(only_second)
        self.passed('show immediately followed by source close leaves no orphan tools window')
        # The harness quits with the second inspector still open and requires
        # a normal host exit. Production sessions and profiles are untouched.


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('engine', type=Path)
    parser.add_argument('identity', type=Path)
    args = parser.parse_args()
    args.app, args.engine, args.identity = (path.resolve() for path in (args.app, args.engine, args.identity))
    reports = Path.home() / 'Library/Logs/DiagnosticReports'
    before = set(reports.glob('CtrlX*.ips'))
    test = DevTools(args)
    await test.run()
    assert test.host.returncode == 0, 'Host did not exit normally with DevTools open'
    await asyncio.sleep(5)
    for report in set(reports.glob('CtrlX*.ips')) - before:
        data = json.loads(report.read_text().split('\n', 1)[1])
        identifier = data.get('bundleInfo', {}).get('CFBundleIdentifier', '')
        assert identifier != 'com.ctrlx.embedded-acceptance' and not identifier.startswith('com.ctrlx.agent-browser.helper'), report
    test.passed('normal shutdown with inspector open and no new browser crash reports')
    summary = test.root / 'summary.json'
    evidence = json.loads(summary.read_text())
    evidence.update(checks=test.checks, hostExitCode=test.host.returncode)
    summary.write_text(json.dumps(evidence, indent=2))


if __name__ == '__main__':
    asyncio.run(main())
