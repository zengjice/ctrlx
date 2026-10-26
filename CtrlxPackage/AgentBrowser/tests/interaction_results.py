#!/usr/bin/env python3
"""Navigation click ACKs and cold screenshots through the public CLI.

Uses a separately signed Host, private profile and native Codex-named fixtures.
The installed application and its browser grants are never used.
"""
import argparse
import asyncio
import http.server
from pathlib import Path
import threading
import time

from managed_engine import Managed


class Fixture(http.server.BaseHTTPRequestHandler):
    navigations = []

    def do_GET(self):
        if self.path.startswith('/canvas'):
            self.navigations.append(self.path)
        body = '''<!doctype html><meta charset="utf-8"><title>Click result fixture</title>
<a id="navigate" href="/canvas">Open canvas</a>
<a id="early" onmousedown="location.href='/canvas-early'" href="/unused">Early navigation</a>
<button id="modal" onclick="document.querySelector('#result').textContent='opened'">Open modal</button>
<p id="result">ready</p>'''
        if self.path.startswith('/canvas'):
            body += '<h1>Canvas opened</h1><canvas width="600" height="400"></canvas>'
        if self.path.startswith('/large'):
            body += ''.join(f'<button>Accessible button {i}</button>' for i in range(10000))
        if self.path == '/frame':
            body += '<iframe name="fixturechild" src="/child-frame"></iframe>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *_):
        pass


class InteractionResults(Managed):
    mock_keychain = True

    async def validate(self, _):
        for run, tab in zip(self.runs, self.tabs):
            await self.request(run, 'close', tab=tab)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        url = f'http://127.0.0.1:{server.server_port}'
        try:
            for engine in ('ctrlx', 'vercel'):
                for attempt in range(2):
                    tab = (await self.cli_action(0, 'action', 'open', '--url', url + '/click'))['result']['id']
                    await self.cli_action(0, 'action', 'wait', '--tab', tab)
                    read = (await self.cli_action(0, 'action', 'read', '--tab', tab))['result']
                    selector = next(c['selector'] for c in read['controls'] if c['text'] == 'Open canvas')
                    before = len(Fixture.navigations)
                    await self.cli_action(0, 'action', 'click', '--engine', engine, '--tab', tab, '--selector', selector)
                    await self.cli_action(0, 'action', 'wait', '--tab', tab)
                    assert len(Fixture.navigations) == before + 1
                    read = (await self.cli_action(0, 'action', 'read', '--tab', tab))['result']
                    assert read['url'] == url + '/canvas' and 'Canvas opened' in read['text']
                    await self.cli_action(1, 'action', 'click', '--engine', engine, '--tab', tab, '--selector', selector, ok=False)
                    await self.cli_action(0, 'action', 'close', '--tab', tab)
                self.passed(engine + ': navigation click confirms delivery once; foreign owner still denied')

            for engine in ('ctrlx', 'vercel'):
                tab = (await self.cli_action(0, 'action', 'open', '--url', url + '/early'))['result']['id']
                await self.cli_action(0, 'action', 'wait', '--tab', tab)
                read = (await self.cli_action(0, 'action', 'read', '--tab', tab))['result']
                selector = next(c['selector'] for c in read['controls'] if c['text'] == 'Early navigation')
                error = await self.cli_action(0, 'action', 'click', '--engine', engine, '--tab', tab, '--selector', selector, ok=False)
                assert 'not retried' in error.lower()
                await self.cli_action(0, 'action', 'wait', '--tab', tab)
                assert 'Canvas opened' in (await self.cli_action(0, 'action', 'read', '--tab', tab))['result']['text']
                await self.cli_action(0, 'action', 'close', '--tab', tab)
                self.passed(engine + ': navigation before final input remains uncertain and is not replayed')

            for mode in ('action', 'command'):
                tab = (await self.cli_action(0, 'action', 'open', '--url', url + '/large'))['result']['id']
                await self.cli_action(0, 'action', 'wait', '--tab', tab)
                await self.cli_action(0, 'action', 'read', '--tab', tab)
                path = self.root / (mode + '-cold.png')
                started = time.monotonic()
                if mode == 'action':
                    await self.cli_action(0, 'action', 'screenshot', '--engine', 'vercel', '--tab', tab, '--output', str(path))
                else:
                    await self.cli_action(0, 'command', '--tab', tab, '--output', str(path), '--', 'screenshot')
                elapsed = time.monotonic() - started
                assert path.read_bytes().startswith(b'\x89PNG')
                assert elapsed < 15, elapsed
                assert not (await self.engine_stream_status(tab))['enabled']
                await self.cli_action(0, 'action', 'close', '--tab', tab)
                self.passed(f'{mode}: cold screenshot of 10000 controls succeeds in {elapsed:.2f}s without interactive snapshot')

            tab = (await self.cli_action(0, 'action', 'open', '--url', url + '/refs'))['result']['id']
            await self.cli_action(0, 'action', 'wait', '--tab', tab)
            await self.cli_action(0, 'action', 'click', '--tab', tab, '--selector', '@e1', ok=False)
            snapshot = (await self.cli_action(0, 'action', 'snapshot', '--tab', tab))['result']
            ref = next(key for key, value in snapshot['refs'].items() if value.get('name') == 'Open modal')
            await self.cli_action(0, 'action', 'click', '--tab', tab, '--selector', '@' + ref)
            await self.cli_action(0, 'action', 'wait', '--tab', tab, '--selector', '#result', '--text', 'opened')
            path = self.root / 'annotated.png'
            await self.cli_action(0, 'command', '--tab', tab, '--output', str(path), '--', 'screenshot', '--annotate')
            assert path.read_bytes().startswith(b'\x89PNG')
            await self.cli_action(0, 'action', 'close', '--tab', tab)
            self.passed('cold stale refs refused; explicit snapshot refs, modal click and annotated screenshot remain usable')

            # These typed IPC adapters also used to depend on the hidden snapshot
            # initializing the page. They must work as the first engine command.
            tab = (await self.cli_action(0, 'action', 'open', '--url', url + '/init'))['result']['id']
            await self.cli_action(0, 'action', 'wait', '--tab', tab)
            added = (await self.cli_action(0, 'command', '--tab', tab, '--', 'init', 'add', 'window.fixtureInit = true'))['result']
            await self.cli_action(0, 'command', '--tab', tab, '--', 'reload')
            await self.cli_action(0, 'action', 'wait', '--tab', tab)
            proof = (await self.cli_action(0, 'command', '--tab', tab, '--', 'eval', 'window.fixtureInit === true'))['result']
            assert proof['result'] is True
            await self.cli_action(0, 'command', '--tab', tab, '--', 'init', 'remove', added['identifier'])
            await self.cli_action(0, 'action', 'close', '--tab', tab)
            tab = (await self.cli_action(0, 'action', 'open', '--url', url + '/frame'))['result']['id']
            await self.cli_action(0, 'action', 'wait', '--tab', tab)
            await self.cli_action(0, 'command', '--tab', tab, '--', 'frame', '--name', 'fixturechild')
            await self.cli_action(0, 'command', '--tab', tab, '--', 'frame', 'main')
            await self.cli_action(0, 'action', 'close', '--tab', tab)
            self.passed('cold init-script and named-frame adapters initialize without a bootstrap snapshot')
        finally:
            server.shutdown()
            server.server_close()


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'engine', 'identity'):
        parser.add_argument(name, type=lambda path: Path(path).resolve())
    test = InteractionResults(parser.parse_args())
    await test.run()
    assert test.host.returncode == 0, 'Isolated Host did not quit normally'


if __name__ == '__main__':
    asyncio.run(main())
