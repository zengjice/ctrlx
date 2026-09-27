#!/usr/bin/env python3
"""Public CtrlX page-command acceptance. Actual DOM/event/artifact assertions.

Runs only in the isolated signed app with native fixture identities, not real
Codex or production profiles. Inherits exact-owner and cleanup scaffolding.
"""
import argparse
import asyncio
import json
from pathlib import Path

from managed_engine import Managed
from engine_capabilities import AuditFixture
import upstream_probe


class ExtendedFixture(AuditFixture):
    def do_GET(self):
        if self.path == '/headers':
            body = json.dumps({'header': self.headers.get('X-Proof')}).encode()
        elif self.path == '/basic-auth':
            if self.headers.get('Authorization') != 'Basic Zml4dHVyZTpwcm9vZg==':
                self.send_response(401)
                self.send_header('WWW-Authenticate', 'Basic realm="fixture"')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            body = b'{"authenticated":true}'
        else:
            return super().do_GET()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)


class PageCapabilities(Managed):
    async def command(self, *words, output=None, ok=True, owner=0, tab=None):
        options = ['command', '--tab', tab or self.tab]
        if output is not None:
            options += ['--output', str(output)]
        value = await self.cli_action(owner, *options, '--', *words, ok=ok)
        return value['result'] if ok else value

    async def verify(self, expression):
        value = await self.command('eval', expression)
        assert value.get('result') is True, (expression, value)

    async def validate(self, _):
        self.tab = (await self.cli_action(0, 'action', 'open', '--url', self.url + 'audit'))['result']['id']
        other = (await self.cli_action(1, 'action', 'open', '--url', self.url + 'audit-other'))['result']['id']
        await self.cli_action(0, 'action', 'wait', '--tab', self.tab)
        await self.command('snapshot')
        assert not (await self.engine_stream_status(self.tab))['enabled']
        self.passed('public extended entry attaches the embedded owned page without preview transport')
        await self.command('fill', '#text', '--provider')
        await self.verify("document.querySelector('#text').value==='--provider'")
        await self.command('fill', '#text', '')
        await self.verify("document.querySelector('#text').value===''")
        await self.command('type', '#text', "中文 ' \" $(not-a-shell)\nline")
        await self.command('click', '#apply')
        await self.verify('audit.clicks===1 && audit.trusted')
        self.passed('literal flag-looking text, empty values, Unicode, quotes and trusted input')
        for words, check in [
            (['dblclick', '#apply'], 'audit.doubles===1'),
            (['hover', '#image'], "document.querySelector('#image').matches(':hover')"),
            (['focus', '#text'], "document.activeElement.id==='text'"),
            (['keyboard', 'inserttext', 'XYZ'], "document.querySelector('#text').value.endsWith('XYZ')"),
            (['keyboard', 'type', 'abc'], "document.querySelector('#text').value.endsWith('abc')"),
            (['keydown', 'Shift'], "audit.keys.includes('Shift')"),
            (['keyup', 'Shift'], "audit.released.includes('Shift')"),
            (['press', 'Enter'], "audit.keys.includes('Enter')"),
            (['check', '#check'], "document.querySelector('#check').checked"),
            (['uncheck', '#check'], "!document.querySelector('#check').checked"),
            (['select', '#multiple', 'a', 'b'], "document.querySelector('#multiple').selectedOptions.length===2"),
            (['drag', '#drag', '#drop'], 'audit.dropped'),
            (['find', 'label', 'Message', 'fill', 'Found'], "document.querySelector('#text').value==='Found'"),
        ]:
            await self.command(*words)
            await self.verify(check)
        self.passed('expanded input, semantic find, drag/drop and multiple selection')
        await self.command('scroll', 'down', '100', '--selector', '#box')
        await self.verify("document.querySelector('#box').scrollTop>0")
        await self.command('scrollintoview', '#apply')
        await self.verify("document.querySelector('#apply').getBoundingClientRect().top>=0")
        await self.command('eval', 'audit.moves=0;audit.downs=0;audit.ups=0;true')
        for words in [['mouse', 'move', '10', '10'], ['mouse', 'down'], ['mouse', 'up']]:
            await self.command(*words)
        await self.verify('audit.moves>0 && audit.downs>0 && audit.ups>0')
        await self.command('mouse', 'wheel', '100')
        await self.command('highlight', '#apply')
        await self.command('eval', "setTimeout(()=>document.querySelector('#result').textContent='delayed-proof',100);true")
        await self.command('wait', '--text', 'delayed-proof')
        await self.verify("document.querySelector('#result').textContent==='delayed-proof'")
        assert 'delayed-proof' in json.dumps(await self.command('diff', 'snapshot'))
        self.passed('container scrolling, mouse events, delayed waits and snapshot diff content')
        for words, expected in [
            (['get', 'text', 'h1'], 'Capability fixture'), (['get', 'html', 'article'], '<h2>Overview</h2>'),
            (['get', 'value', '#text'], 'Found'), (['get', 'attr', '#apply', 'title'], 'Apply title'),
            (['get', 'title'], 'Capability fixture'), (['get', 'url'], '/audit'),
            (['get', 'count', 'button'], '1'), (['get', 'box', '#apply'], 'width'),
            (['get', 'styles', '#apply'], 'display'), (['is', 'enabled', '#disabled'], 'false'),
            (['is', 'checked', '#check'], 'false'), (['is', 'visible', '#hidden'], 'false'),
            (['read', '--outline'], 'Overview'),
        ]:
            assert expected in json.dumps(await self.command(*words)), words
        self.passed('all getters, state queries and upstream DOM reading')
        for kind in ['local', 'session']:
            await self.command('storage', kind, 'set', 'proof', 'saved')
            assert 'saved' in json.dumps(await self.command('storage', kind, 'proof'))
            await self.command('storage', kind, 'clear')
            await self.verify(kind + "Storage.getItem('proof')===null")
        self.passed('local/session storage round trips')
        upload = self.root / 'upload-proof.txt'
        upload.write_text('public-upload-proof')
        await self.command('upload', '#file', str(upload))
        await self.verify("document.querySelector('#file').files[0].text().then(t=>t==='public-upload-proof')")
        self.passed('upload actual file contents')
        for words, filename, magic in [
            (['screenshot', '--full', '--annotate'], 'expanded.png', b'\x89PNG'),
            (['pdf'], 'expanded.pdf', b'%PDF'),
            (['download', '#download'], 'download.txt', b'local-download-proof'),
        ]:
            output = self.root / filename
            await self.command(*words, output=output)
            assert output.read_bytes().startswith(magic)
            original = output.read_bytes()
            await self.command(*words, output=output, ok=False)
            assert output.read_bytes() == original
        self.passed('full annotated PNG, PDF and download artifacts; overwrite refusal')
        await self.command('network', 'requests')  # upstream starts tracking here
        await self.command('eval', "console.log('public-console');setTimeout(()=>{throw Error('public-error')},10);fetch('/api').then(()=>true)")
        assert 'public-console' in json.dumps(await self.command('console'))
        assert 'public-error' in json.dumps(await self.command('errors'))
        assert '/api' in json.dumps(await self.command('network', 'requests'))
        self.passed('console/error/network events contain real page activity')
        await self.command('network', 'route', self.url + 'api', '--body', '{"mock":true}')
        await self.verify("fetch('/api').then(r=>r.json()).then(r=>r.mock===true)")
        await self.command('network', 'unroute')
        await self.verify("fetch('/api').then(r=>r.json()).then(r=>r.fixture===true)")
        await self.command('network', 'har', 'start')
        await self.command('eval', "fetch('/api').then(()=>true)")
        har = self.root / 'page.har'
        await self.command('network', 'har', 'stop', output=har)
        assert any('/api' in entry['request']['url'] for entry in json.loads(har.read_text())['log']['entries'])
        self.passed('route/fulfill/unroute changes actual response; HAR contains actual request')
        await self.command('set', 'headers', '{"X-Proof":"header-proof"}')
        await self.verify("fetch('/headers').then(r=>r.json()).then(r=>r.header==='header-proof')")
        await self.command('set', 'headers', '{}')
        await self.verify("fetch('/headers').then(r=>r.json()).then(r=>r.header===null)")
        await self.command('set', 'credentials', 'fixture', 'proof')
        await self.verify("fetch('/basic-auth').then(r=>r.json()).then(r=>r.authenticated===true)")
        self.passed('actual extra headers, reset and HTTP basic authentication')
        await self.command('set', 'viewport', '640', '480')
        await self.verify('innerWidth===640 && innerHeight===480')
        await self.command('set', 'media', 'dark')
        await self.verify("matchMedia('(prefers-color-scheme: dark)').matches")
        await self.command('set', 'device', 'iPhone 14')
        await self.verify("navigator.userAgent.includes('iPhone') && screen.width===390")
        await self.command('set', 'offline', 'on')
        await self.verify("fetch('/api').then(()=>false,()=>true)")
        await self.command('set', 'offline', 'off')
        await self.verify("fetch('/api').then(r=>r.ok)")
        self.passed('viewport/media/device/offline emulation observable in page')
        await self.command('frame', '#frame')
        assert 'Frame button' in json.dumps(await self.command('get', 'text', '#in-frame'))
        await self.command('frame', 'main')
        assert 'Capability fixture' in json.dumps(await self.command('get', 'text', 'h1'))
        self.passed('iframe switch/read/return main frame')
        await self.command('eval', "setTimeout(()=>{window.dialogProof=prompt('Public prompt','seed')},100);true")
        dialog = await self.command('dialog', 'status')
        assert dialog.get('hasDialog') and dialog.get('message') == 'Public prompt', dialog
        await self.command('dialog', 'accept', 'answered')
        await self.verify("window.dialogProof==='answered'")
        await self.command('eval', "setTimeout(()=>{window.dialogProof=confirm('Public confirm')},100);true")
        assert (await self.command('dialog', 'status')).get('hasDialog')
        await self.command('dialog', 'dismiss')
        await self.verify('window.dialogProof===false')
        self.passed('real prompt accept and confirm dismiss without OS interaction')
        await self.command('cookies', 'set', 'public', 'cookie-proof', '--url', self.url)
        assert 'cookie-proof' in json.dumps(await self.command('cookies'))
        await self.command('cookies', 'set', 'foreign', 'blocked', '--url', 'https://example.org/', ok=False)
        await self.cli_action(1, 'action', 'navigate', '--tab', other, '--url', self.url.replace('127.0.0.1', 'localhost')+'audit-other')
        await self.cli_action(1, 'action', 'wait', '--tab', other)
        await self.command('cookies', 'set', 'other-host', 'must-not-leak', owner=1, tab=other)
        assert 'must-not-leak' not in json.dumps(await self.command('cookies'))
        self.passed('page-host cookies round trip and foreign-host write refusal')
        await self.command('pushstate', self.url + 'audit-spa')
        await self.command('back')
        await self.verify("location.pathname==='/audit'")
        await self.command('forward')
        await self.verify("location.pathname==='/audit-spa'")
        await self.command('reload')
        await self.command('wait', '--load', 'load')
        self.passed('history, reload and load wait in the same native tab')
        vitals = await self.command('vitals')
        assert self.url in vitals.get('url', '') and vitals.get('fcp', 0) > 0 and vitals.get('ttfb') is not None, vitals
        accessibility = await self.command('a11y')
        assert isinstance(accessibility.get('violations'), list) and len(accessibility['violations']) > 0, accessibility
        self.passed('vitals measurement and axe accessibility violations from the actual fixture')
        await self.command('get', 'title', owner=1, tab=self.tab, ok=False)
        for words in [['get', 'cdp-url'], ['connect', '9222'], ['plugin', 'run'], ['cookies', 'clear'],
                      ['state', 'save'], ['trace', 'start'], ['record', 'start']]:
            await self.command(*words, ok=False)
        await self.command('get', 'title', owner=1, tab=other)
        assert not (await self.engine_stream_status(self.tab))['enabled']
        self.passed('cross-owner, browser-global and runtime boundaries; other owner remains usable')


if __name__ == '__main__':
    upstream_probe.Fixture = ExtendedFixture
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'engine', 'identity'):
        parser.add_argument(name, type=lambda p: Path(p).resolve())
    asyncio.run(PageCapabilities(parser.parse_args()).run())
