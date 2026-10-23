#!/usr/bin/env python3
"""Real public-to-loopback CEF requests in a signed, disposable Host/profile."""
import argparse
import asyncio
import http.server
import json
from pathlib import Path
import socket
import threading
from urllib.parse import urlsplit
import urllib.request
import uuid

import upstream_probe
from upstream_probe import Probe


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.end_headers()
        self.wfile.write(b'<title>Device authorization fixture</title><h1>Device authorization fixture</h1>')

    def log_message(self, *_):
        pass


class LocalService(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(b'device-authorized')

    def log_message(self, *_):
        pass


class NetworkPermissions(Probe):
    native_gateway = True
    mock_keychain = True

    async def setup(self):
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            self.debug_port = reservation.getsockname()[1]
        self.extra_host_arguments = ['--test-accessibility-port', str(self.debug_port),
                                     '--ctrlx-probe-public-port', str(urlsplit(self.url).port)]
        await super().setup()

    async def toggle_debug(self, enabled):
        def update():
            request = urllib.request.Request(
                f'http://127.0.0.1:{self.debug_port}/set-debug-mode?enabled={str(enabled).lower()}', method='POST')
            with urllib.request.urlopen(request, timeout=5) as response:
                assert response.read() == b'ok'
        await asyncio.to_thread(update)

    def reports(self):
        path = self.root / 'browser-diagnostics/browser-current.jsonl'
        return [json.loads(line)['browser'] for line in path.read_text().splitlines()] if path.exists() else []

    async def validate(self, _):
        run = self.runs[0]
        tab = self.tabs[0]
        local = http.server.ThreadingHTTPServer(('127.0.0.1', 0), LocalService)
        threading.Thread(target=local.serve_forever, daemon=True).start()

        async def evaluate(expression):
            value = await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate',
                                       params={'expression': expression, 'returnByValue': True, 'userGesture': True})
            return value.get('result', {}).get('value')

        async def begin(site):
            url = self.url.replace('127.0.0.1', site + '.localhost') + 'auth?token=fixture-secret#private'
            await self.request(run, 'navigate', tab=tab, url=url)
            await self.request(run, 'wait', tab=tab)
            await self.request(run, 'show', tab=tab)
            await evaluate(f"window.result='pending';fetch('http://127.0.0.1:{local.server_port}/device?secret=local-secret')"
                           ".then(r=>r.text()).then(v=>window.result=v).catch(e=>window.result='denied')")
            async def pending():
                return await self.request(run, 'probe.network-permission', tab=tab)
            prompt = await self.wait(pending, 10)
            assert prompt['origin'] == f'http://{site}.localhost:{urlsplit(self.url).port}', prompt
            return prompt['id']

        async def respond(id, allow, lease=None, rejected=False):
            try:
                await self.request(run, 'probe.network-permission', tab=tab, action='respond',
                                   id=id, allow=allow, **({'lease': lease} if lease else {}))
            except AssertionError:
                if rejected:
                    return
                raise
            assert not rejected, 'Stale or foreign permission response was accepted'

        async def result(expected, timeout=10):
            async def ready():
                return await evaluate('window.result') == expected
            await self.wait(ready, timeout)

        try:
            id = await begin('denied')
            if self.args.ui:
                print('UI: click Don’t Allow in the isolated Host card', flush=True)
                await result('denied', 180)
            else:
                await respond(id, False)
                await result('denied')
            assert not self.reports()
            self.passed('real loopback fetch denied; Debug Mode off creates no diagnostic file')

            await self.toggle_debug(True)
            id = await begin('allowed')
            await respond(str(uuid.uuid4()), True, rejected=True)
            if self.args.ui:
                print('UI: click Allow in the isolated Host card', flush=True)
                await result('device-authorized', 180)
            else:
                await respond(id, True)
                await result('device-authorized')
            await respond(id, True, rejected=True)
            self.passed('real permission grant completes the local service request; wrong ID and replay rejected')

            id = await begin('navigated')
            await self.request(run, 'navigate', tab=tab, url=self.url + 'done')
            await self.request(run, 'wait', tab=tab)
            assert not await self.request(run, 'probe.network-permission', tab=tab)
            await respond(id, True, rejected=True)
            self.passed('navigation cancels the pending request; old permission cannot apply to the new page')

            id = await begin('viewer')
            lease = str(uuid.uuid4())
            assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
            await respond(id, True, rejected=True)
            await respond(id, True, lease=str(uuid.uuid4()), rejected=True)
            await self.request(run, 'probe.remote-control', tab=tab, lease=None)
            await respond(id, True, lease=lease, rejected=True)
            assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
            await respond(id, True, lease=lease)
            await self.request(run, 'probe.remote-control', tab=tab, lease=None)
            await result('device-authorized')
            self.passed('native Host/Viewer control checks reject old and foreign grants; current Viewer can allow')

            await evaluate("console.error('CORS local network token=console-secret https://private.example/path?token=secret')")
            reports = self.reports()
            assert {'network-permission-request', 'network-permission-result', 'network-console-error'} <= {r['event'] for r in reports}
            raw = json.dumps(reports)
            assert all(secret not in raw for secret in ['fixture-secret', 'local-secret', 'console-secret', '/auth', 'private.example'])
            await self.toggle_debug(False)
            before = self.reports()
            id = await begin('disabled')
            await respond(id, False)
            await result('denied')
            assert self.reports() == before
            self.passed('Debug Mode captures permission/results/error category, redacts paths and tokens, stops immediately when off')
        finally:
            local.shutdown()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=lambda p: Path(p).resolve())
    parser.add_argument('engine', type=lambda p: Path(p).resolve())
    parser.add_argument('identity', type=lambda p: Path(p).resolve())
    parser.add_argument('--ui', action='store_true', help='Wait for actual Host permission buttons in the first two cases')
    upstream_probe.Fixture = Page
    asyncio.run(NetworkPermissions(parser.parse_args()).run())
