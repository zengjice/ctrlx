#!/usr/bin/env python3
"""Human download acceptance in a signed, isolated Host with probe-enabled native library.

Uses the existing in-process AppKit click fixture, private profile and download
folder. Agent input remains the production gateway; no personal tabs or files.
"""
import argparse
import asyncio
import http.server
from pathlib import Path
import time
from urllib.parse import urlsplit

import upstream_probe
from managed_engine import Managed


class Fixture(http.server.BaseHTTPRequestHandler):
    payload = b'ctrlx-download-proof\n' * (400 * 1024)

    def do_POST(self):
        self.do_GET()

    def do_GET(self):
        path = urlsplit(self.path).path
        if path in ['/big', '/post', '/slow', '/small']:
            payload = b'agent-download-proof' if path == '/small' else self.payload
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="proof.bin"')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            try:
                for offset in range(0, len(payload), 65536):
                    self.wfile.write(payload[offset:offset + 65536])
                    self.wfile.flush()
                    if path == '/slow':
                        time.sleep(.08)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        mode = path.strip('/')
        if mode == 'blob':
            action = '''const a=document.createElement('a');a.href=window.URL.createObjectURL(new Blob(['blob-proof']));a.download='blob.txt';document.body.appendChild(a);a.click()'''
        elif mode == 'form':
            action = "document.querySelector('form').submit()"
        elif mode == 'popup':
            action = "window.open('/big')"
        elif mode == 'cancel':
            action = "location.href='/slow'"
        else:
            action = "location.href='/big'"
        page = f'''<!doctype html><title>Download fixture</title><form method="POST" action="/post"></form><a id="small" href="/small" download>Small Agent download</a>
<button id="download" style="position:fixed;left:20px;top:20px;width:180px;height:60px" onclick="window.clicked=(window.clicked||0)+1;try{{{action}}}catch(e){{window.failure=String(e)}}">Download</button>'''.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(page)))
        self.end_headers()
        self.wfile.write(page)

    def log_message(self, *_):
        pass


class HumanDownloads(Managed):
    mock_keychain = True

    async def setup(self):
        self.downloads = self.root / 'human-downloads'
        self.extra_host_arguments = ['--downloads-dir', str(self.downloads)]
        await super().setup()

    async def validate(self, _):
        run = self.runs[0]
        tab = self.tabs[0]

        async def page(mode):
            await self.request(run, 'navigate', tab=tab, url=self.url + mode)
            async def loaded():
                return next((t for t in await self.request(run, 'tabs') if t['id'] == tab and not t['loading']), None)
            await self.wait(loaded)
            await self.request(run, 'show', tab=tab)
            await asyncio.sleep(.2)

        async def click():
            await self.request(run, 'probe.external-app', tab=tab, action='click', x=80, y=45)

        async def saved(name):
            async def exists():
                path = self.downloads / name
                return path if path.exists() else None
            try:
                return await self.wait(exists)
            except AssertionError:
                print('Navigation events:', await self.request(run, 'probe.external-app', tab=tab, action='events'), flush=True)
                print('Download page state:', await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate', params={
                    'expression': "JSON.stringify({url:location.href,clicked:window.clicked,error:window.failure,html:document.body.innerHTML})", 'returnByValue': True}), flush=True)
                raise

        await page('direct')
        await self.request(self.runs[1], 'close', tab=self.tabs[1])
        agent_tab = (await self.cli_action(1, 'action', 'open', '--url', self.url + 'direct'))['result']['id']
        await self.cli_action(1, 'action', 'wait', '--tab', agent_tab)
        output = self.root / 'agent-small.bin'
        await self.cli_action(1, 'command', '--tab', agent_tab, '--output', str(output), '--', 'download', '#small')
        assert output.read_bytes() == b'agent-download-proof'
        oversized = self.root / 'agent-large.bin'
        await self.cli_action(1, 'command', '--tab', agent_tab, '--output', str(oversized), '--', 'download', '#download', ok=False)
        assert not oversized.exists()
        assert not list(self.downloads.glob('proof*'))
        self.passed('Agent download remains scoped to its output and rejects files over 6 MiB')
        await page('direct')
        await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate', params={
            'expression': "document.querySelector('#download').click()", 'userGesture': True})
        await asyncio.sleep(1)
        assert not list(self.downloads.glob('proof*'))
        self.passed('Agent click cannot use the human download path')

        for mode, name in [('direct', 'proof.bin'), ('direct', 'proof-2.bin'), ('form', 'proof-3.bin'), ('popup', 'proof-4.bin')]:
            await page(mode)
            await click()
            output = await saved(name)
            assert output.read_bytes() == Fixture.payload
            assert len(Fixture.payload) > 6 * 1024 * 1024
            self.passed(f'AppKit {mode}: full >6 MiB payload saved without overwriting as {name}')

        await page('blob')
        await self.request(run, 'probe.external-app', tab=tab, action='start')
        await click()
        assert (await saved('blob.txt')).read_bytes() == b'blob-proof'
        self.passed('Blob/download-attribute export saves its actual bytes')

        await page('cancel')
        await click()
        async def partial():
            return next((p for p in self.downloads.glob('.ctrlx-download-*/*') if p.is_file() and p.stat().st_size), None)
        await self.wait(partial)
        await self.request(run, 'close', tab=tab)
        async def cleaned():
            return not list(self.downloads.glob('.ctrlx-download-*'))
        await self.wait(cleaned)
        assert len(list(self.downloads.glob('proof*'))) == 4
        self.passed('Closing the source tab cancels an active transfer and removes partial files')


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=lambda p: Path(p).resolve())
    parser.add_argument('engine', type=lambda p: Path(p).resolve())
    parser.add_argument('identity', type=lambda p: Path(p).resolve())
    upstream_probe.Fixture = Fixture
    await HumanDownloads(parser.parse_args()).run()


if __name__ == '__main__':
    asyncio.run(main())
