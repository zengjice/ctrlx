#!/usr/bin/env python3
"""Upstream capability audit against CtrlX's PRODUCT native gateway.

Not a new public API: broader upstream commands run only in this isolated test
profile. A successful raw-engine case does NOT mean CtrlX exposes that command.
No production grants, real accounts, external browser, simulator or cloud service.
Produces capabilities.json after EVERY case, including errors and explicit skips.
"""
import argparse
import asyncio
from collections import Counter
import json
from pathlib import Path
import re
import time

from managed_engine import Managed
import upstream_probe
from integration import Fixture


PAGE = b'''<!doctype html><meta charset="utf-8"><title>Capability fixture</title>
<style>body{margin:20px}#box{overflow:auto;width:200px;height:60px}
#inside{height:900px;width:900px}#drop{width:150px;height:45px;background:#ddd}</style>
<h1>Capability fixture</h1><article><h2>Overview</h2><p>Local audit content.</p></article>
<label for="text">Message</label><input id="text" placeholder="Type message" value="seed">
<button id="apply" title="Apply title" data-testid="apply">Apply</button>
<input id="check" type="checkbox"><label for="check">Check me</label>
<select id="select"><option value="a">Alpha</option><option value="b">Beta</option></select>
<select id="multiple" multiple><option value="a">Alpha</option><option value="b">Beta</option></select>
<input id="file" type="file"><input id="disabled" disabled><p id="hidden" hidden>Hidden</p>
<img id="image" alt="Fixture image" width="10" height="10" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==">
<div id="drag" draggable="true">Drag source</div><div id="drop">Drop destination</div>
<div id="box"><div id="inside">Scrollable content</div></div>
<a id="download" href="/download" download="fixture.txt">Download fixture</a>
<iframe id="frame" src="/frame" title="Local frame"></iframe><p id="result">ready</p>
<script>
window.audit={clicks:0,doubles:0,hover:0,moves:0,downs:0,ups:0,keys:[],released:[],dropped:false};
const $=s=>document.querySelector(s);
$('#apply').onclick=e=>{audit.clicks++;audit.trusted=e.isTrusted;$('#result').textContent=$('#text').value};
$('#apply').ondblclick=()=>audit.doubles++;
$('#apply').onmouseover=()=>audit.hover++;
document.onmousemove=()=>audit.moves++;document.onmousedown=()=>audit.downs++;
document.onmouseup=()=>audit.ups++;document.onkeydown=e=>audit.keys.push(e.key);
document.onkeyup=e=>audit.released.push(e.key);
$('#drag').ondragstart=e=>e.dataTransfer.setData('text/plain','fixture');
$('#drop').ondragover=e=>e.preventDefault();$('#drop').ondrop=e=>{e.preventDefault();audit.dropped=true};
</script>'''


class AuditFixture(Fixture):
    def do_GET(self):
        if self.path.startswith('/audit'):
            body, kind = PAGE, 'text/html; charset=utf-8'
        elif self.path == '/frame':
            body, kind = b'<button id="in-frame">Frame button</button>', 'text/html'
        elif self.path == '/download':
            body, kind = b'local-download-proof', 'application/octet-stream'
        elif self.path in ('/guide', '/guide.md', '/llms.txt', '/llms-full.txt'):
            body, kind = b'# Guide\n\n## Overview\nLocal markdown proof.\n\n## API\n[Guide](/guide.md)\n', 'text/markdown'
        elif self.path == '/api':
            body, kind = b'{"fixture":true}', 'application/json'
        else:
            return super().do_GET()
        self.send_response(200)
        self.send_header('Content-Type', kind)
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)


class Capabilities(Managed):
    def save(self):
        report = {'version': '0.38.1', 'date': time.strftime('%Y-%m-%d'),
                  'scope': 'isolated CEF product gateway; native fixture identities, NOT real Codex',
                  'counts': dict(Counter(row['result'] for row in self.results)), 'cases': self.results}
        (self.root / 'capabilities.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))

    def note(self, name, result, detail='', exposed=False):
        self.results.append(dict(name=name, result=result, detail=detail, publicCtrlX=exposed))
        self.save()
        print(result.upper() + ': ' + name + (': ' + detail[:140] if detail else ''), flush=True)

    async def raw(self, *words):
        if not (self.directory / 'page.sock').exists():
            return {'success': False, 'error': 'Fixture daemon stopped; refusing implicit browser launch'}
        process = await asyncio.create_subprocess_exec(str(self.args.engine), '--config', str(self.directory / 'config.json'),
            '--session', 'page', '--json', '--provider', 'ctrlx', '--no-webmcp', *words, cwd=self.directory, env=self.env,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try:
            out, err = await asyncio.wait_for(process.communicate(), 12)
        except asyncio.TimeoutError:
            process.kill()
            await process.communicate()
            return {'success': False, 'error': '12s test deadline; outcome unknown, no retry'}
        try:
            value = json.loads(out)
        except ValueError:
            value = {'success': False, 'error': (err or out).decode(errors='replace')[:500]}
        if isinstance(value, list):
            value = {'success': process.returncode == 0, 'data': value}
        elif 'success' not in value:
            # Plugin administration uses a different JSON envelope.
            value = {'success': process.returncode == 0 and 'error' not in value, 'data': value}
        # get cdp-url/error output can contain private capabilities. Never persist them.
        encoded = re.sub(r'wss?://[^\s"\\]+', '<redacted-websocket>', json.dumps(value))
        return json.loads(encoded)

    async def case(self, name, words, *, verify=None, contains=None, file=None, magic=None, exposed=False):
        value = await self.raw(*words)
        detail = json.dumps(value, ensure_ascii=False)
        if not value.get('success'):
            self.note(name, 'error', detail[:600], exposed)
            return value
        if verify is not None:
            observed = await self.raw('eval', verify)
            if not observed.get('success') or (observed.get('data') or {}).get('result') is not True:
                self.note(name, 'semantic-mismatch', json.dumps(observed, ensure_ascii=False)[:600], exposed)
                return value
        if contains and contains not in detail:
            self.note(name, 'semantic-mismatch', detail[:600], exposed)
            return value
        if file and (not file.exists() or not file.stat().st_size or (magic and not file.read_bytes().startswith(magic))):
            self.note(name, 'semantic-mismatch', 'Expected artifact missing/invalid', exposed)
            return value
        self.note(name, 'verified' if (verify is not None or contains or file) else 'response-only', detail[:600], exposed)
        return value

    async def validate(self, _):
        self.results = []
        upstream_probe.Fixture = AuditFixture
        assert (await self.cli_action(0, 'engine'))['engine'] == 'vercel'
        self.tab = (await self.cli_action(0, 'action', 'open', '--url', self.url + 'audit'))['result']['id']
        await self.cli_action(0, 'action', 'wait', '--tab', self.tab)
        await self.cli_action(0, 'action', 'snapshot', '--tab', self.tab)
        assert not (await self.engine_stream_status(self.tab))['enabled']
        config = next((self.root / 'agent-browser/runs').glob('*/' + self.tab + '.engine.json'))
        self.directory = Path(json.loads(config.read_text())['directory'])
        self.env = {'PATH': '/usr/bin:/bin', 'HOME': str(self.directory), 'TMPDIR': str(self.directory),
                    'AGENT_BROWSER_SOCKET_DIR': str(self.directory), 'AGENT_BROWSER_DEFAULT_TIMEOUT': '2000',
                    'AGENT_BROWSER_CONFIG': str(self.directory / 'config.json'),
                    'AGENT_BROWSER_NO_AUTO_DIALOG': '1', 'NO_PROXY': '127.0.0.1,localhost',
                    'LANG': 'en_US.UTF-8', 'AGENT_BROWSER_IDLE_TIMEOUT_MS': '300000',
                    'AGENT_BROWSER_AUTOSAVE_INTERVAL_MS': '0'}
        self.env['CTRLX_ENGINE_PROVIDER_FILE'] = str(self.directory / 'provider.json')
        self.env['AGENT_BROWSER_PLUGINS'] = json.dumps([{'name': 'ctrlx', 'command': self.cli,
            'args': ['browser', 'engine-provider'], 'capabilities': ['browser.provider']}])
        # Fail fast if a harness/config change attaches anywhere else. Do not
        # report a long list of false failures against a different blank page.
        page = await self.raw('get', 'url')
        assert page.get('success') and page.get('data', {}).get('url') == self.url + 'audit', 'Audit must stay on its owned embedded fixture'
        # The product CLI already attached the official binary. No new provider,
        # browser, target, or authority is introduced by this audit.
        await self.case('snapshot interactive', ['snapshot', '-i'], contains='Apply', exposed=True)
        for flags in ([], ['-c'], ['-d', '2'], ['-s', 'article']):
            await self.case('snapshot ' + ' '.join(flags or ['full']), ['snapshot', *flags], contains='Overview' if '-s' in flags else 'Capability fixture')
        for name, words, check in [
            ('fill', ['fill', '#text', 'Full 中文'], "document.querySelector('#text').value==='Full 中文'"),
            ('type', ['type', '#text', ' appended'], "document.querySelector('#text').value==='Full 中文 appended'"),
            ('click', ['click', '#apply'], 'audit.clicks===1 && audit.trusted'),
            ('double click', ['dblclick', '#apply'], 'audit.doubles===1'),
            ('focus', ['focus', '#text'], "document.activeElement.id==='text'"),
            ('keyboard type', ['keyboard', 'type', 'abc'], "document.querySelector('#text').value.endsWith('abc')"),
            ('keyboard inserttext', ['keyboard', 'inserttext', '中文'], "document.querySelector('#text').value.endsWith('中文')"),
            ('press', ['press', 'Enter'], "audit.keys.includes('Enter')"),
            ('keydown', ['keydown', 'Shift'], "audit.keys.includes('Shift')"),
            ('keyup', ['keyup', 'Shift'], "audit.released.includes('Shift')"),
            ('hover', ['hover', '#apply'], 'audit.hover>0'),
            ('check', ['check', '#check'], "document.querySelector('#check').checked"),
            ('uncheck', ['uncheck', '#check'], "!document.querySelector('#check').checked"),
            ('select value', ['select', '#select', 'b'], "document.querySelector('#select').value==='b'"),
            ('select label', ['select', '#select', 'Alpha'], "document.querySelector('#select').value==='a'"),
            ('select multiple', ['select', '#multiple', 'a', 'b'], "document.querySelector('#multiple').selectedOptions.length===2"),
            ('drag drop', ['drag', '#drag', '#drop'], 'audit.dropped'),
            ('scroll container', ['scroll', 'down', '100', '--selector', '#box'], "document.querySelector('#box').scrollTop>0"),
            ('scroll into view', ['scrollintoview', '#download'], "document.querySelector('#download').getBoundingClientRect().top<innerHeight"),
            ('mouse move', ['mouse', 'move', '40', '40'], 'audit.moves>0'),
            ('mouse down', ['mouse', 'down', 'left'], 'audit.downs>0'),
            ('mouse up', ['mouse', 'up', 'left'], 'audit.ups>0'),
        ]:
            if name in ('mouse move', 'mouse down', 'mouse up'):
                await self.raw('eval', 'audit.moves=0;audit.downs=0;audit.ups=0;true')
            await self.case(name, words, verify=check, exposed=name in ('fill', 'type', 'click', 'press', 'check', 'uncheck', 'select value'))
        await self.case('mouse wheel', ['mouse', 'wheel', '100'])
        await self.case('eval', ['eval', '21*2'], contains='42')
        for what, args, expected in [
            ('text', ['h1'], 'Capability fixture'), ('html', ['article'], '<h2>Overview</h2>'),
            ('value', ['#text'], 'Full'), ('attr', ['#apply', 'title'], 'Apply title'),
            ('title', [], 'Capability fixture'), ('url', [], '/audit'), ('count', ['button'], '1'),
            ('box', ['#apply'], 'width'), ('styles', ['#apply'], 'display'), ('cdp-url', [], '<redacted-websocket>')]:
            await self.case('get ' + what, ['get', what, *args], contains=expected)
        for what, selector, expected in [('visible', '#apply', 'true'), ('visible', '#hidden', 'false'),
                                         ('enabled', '#disabled', 'false'), ('checked', '#check', 'false')]:
            await self.case('is ' + what + ' ' + selector, ['is', what, selector], contains=expected)
        for name, args in [
            ('role', ['role', 'button', 'text', '--name', 'Apply']), ('text', ['text', 'Apply', 'text', '--exact']),
            ('label', ['label', 'Message', 'fill', 'By label']), ('placeholder', ['placeholder', 'Type message', 'fill', 'By placeholder']),
            ('alt', ['alt', 'Fixture image', 'hover']), ('title', ['title', 'Apply title', 'text']),
            ('testid', ['testid', 'apply', 'text']), ('first', ['first', 'button', 'text']),
            ('last', ['last', 'button', 'text']), ('nth', ['nth', '0', 'button', 'text'])]:
            await self.case('find ' + name, ['find', *args], contains='Apply' if 'text' in args and name!='alt' else None,
                            verify="document.querySelector('#text').value==='" + args[-1] + "'" if 'fill' in args else None)
        for args in (['#apply'], ['20'], ['--text', 'Overview'], ['--url', '**/audit'], ['--fn', 'true'],
                     ['--load', 'load'], ['--load', 'domcontentloaded'], ['--load', 'networkidle'], ['#hidden', '--state', 'hidden']):
            await self.case('wait ' + ' '.join(args), ['wait', *args])
        for args in ([], ['--filter', 'Overview'], ['--outline']):
            await self.case('read DOM ' + ' '.join(args), ['read', *args], contains='Overview')
        for args in ([], ['--raw'], ['--require-md'], ['--llms', 'index'], ['--llms', 'full']):
            await self.case('read fetch ' + ' '.join(args), ['read', self.url + 'guide', *args], contains='Guide')
        baseline = self.root / 'capability.png'
        await self.case('screenshot', ['screenshot', str(baseline)], file=baseline, magic=b'\x89PNG', exposed=True)
        for label, flags in [('full', ['--full']), ('annotate', ['--annotate']), ('jpeg', ['--screenshot-format', 'jpeg', '--screenshot-quality', '70'])]:
            path = self.root / ('screen-' + label + ('.jpg' if label == 'jpeg' else '.png'))
            await self.case('screenshot ' + label, ['screenshot', str(path), *flags], file=path, magic=b'\xff\xd8' if label=='jpeg' else b'\x89PNG')
        await self.case('screenshot if-changed', ['screenshot', str(self.root/'changed.png'), '--if-changed'])
        await self.case('diff snapshot', ['diff', 'snapshot'])
        await self.case('diff screenshot', ['diff', 'screenshot', '--baseline', str(baseline)])
        await self.case('batch', ['batch', 'get title', 'get url'], contains='Capability fixture')
        await self.case('highlight', ['highlight', '#apply'])
        # Positive + negative waits against a real delayed DOM transition.
        await self.raw('eval', "document.querySelector('#result').textContent='pending';setTimeout(()=>document.querySelector('#result').textContent='wait-finished',200);true")
        await self.case('wait delayed text', ['wait', '--text', 'wait-finished'], verify="document.querySelector('#result').textContent==='wait-finished'")
        await self.case('wait negative timeout (expected)', ['wait', '#absent-fixture', '--timeout', '100'])
        for kind in ('local', 'session'):
            await self.case('storage ' + kind + ' set', ['storage', kind, 'set', 'audit', 'fixture'], verify=kind+"Storage.getItem('audit')==='fixture'")
            await self.case('storage ' + kind + ' get', ['storage', kind, 'audit'], contains='fixture')
            await self.case('storage ' + kind + ' list', ['storage', kind], contains='fixture')
            await self.case('storage ' + kind + ' clear', ['storage', kind, 'clear'], verify=kind+"Storage.getItem('audit')===null")
        # These broader features are expected to reveal gateway limitations.
        # Success responses alone are deliberately NOT called verification.
        upload = self.root / 'upload.txt'; upload.write_text('local-upload-proof')
        await self.case('upload', ['upload', '#file', str(upload)], verify="document.querySelector('#file').files.length===1")
        await self.case('download', ['download', '#download', str(self.root/'download.txt')], file=self.root/'download.txt', magic=b'local-download-proof')
        await self.case('pdf', ['pdf', str(self.root/'page.pdf')], file=self.root/'page.pdf', magic=b'%PDF')
        await self.raw('eval', "console.log('audit-console');setTimeout(()=>{throw Error('audit-error')},20);fetch('/api');true")
        await asyncio.sleep(.1)
        await self.case('console', ['console'], contains='audit-console')
        await self.case('errors', ['errors'], contains='audit-error')
        await self.case('network requests', ['network', 'requests'], contains='/api')
        for name, words in [
            ('cookies get', ['cookies']), ('cookies set', ['cookies', 'set', 'audit', 'fixture', '--url', self.url]),
            ('cookies clear', ['cookies', 'clear']),
            ('set viewport', ['set', 'viewport', '640', '480']), ('set device', ['set', 'device', 'iPhone 14']),
            ('set geo', ['set', 'geo', '0', '0']), ('set media', ['set', 'media', 'dark']),
            ('set headers', ['set', 'headers', '{"X-Audit":"fixture"}']), ('set headers reset', ['set', 'headers', '{}']),
            ('set credentials', ['set', 'credentials', 'fixture', 'not-a-real-password']),
            ('set offline', ['set', 'offline', 'on']), ('set online', ['set', 'offline', 'off']),
            ('network route', ['network', 'route', self.url+'api', '--body', '{"mock":true}']),
            ('network unroute', ['network', 'unroute']), ('network har start', ['network', 'har', 'start']),
            ('network har stop', ['network', 'har', 'stop', str(self.root/'page.har')]),
            ('trace start', ['trace', 'start']), ('trace stop', ['trace', 'stop', str(self.root/'trace.json')]),
            ('profiler start', ['profiler', 'start']), ('profiler stop', ['profiler', 'stop', str(self.root/'profile.json')]),
            ('record start', ['record', 'start', str(self.root/'video.webm')]), ('record stop', ['record', 'stop']),
            ('frame select', ['frame', '#frame']), ('frame main', ['frame', 'main']),
            ('dialog status', ['dialog', 'status']), ('dialog accept', ['dialog', 'accept']), ('dialog dismiss', ['dialog', 'dismiss']),
            ('webmcp list', ['webmcp', 'list']), ('webmcp invoke', ['webmcp', 'invoke', 'nonexistent-fixture']),
            ('webmcp result', ['webmcp', 'result', 'nonexistent-fixture']), ('webmcp cancel', ['webmcp', 'cancel', 'nonexistent-fixture']),
            ('react tree', ['react', 'tree']), ('react inspect', ['react', 'inspect', '1']),
            ('react renders start', ['react', 'renders', 'start']), ('react renders stop', ['react', 'renders', 'stop']),
            ('react suspense', ['react', 'suspense']), ('vitals', ['vitals']), ('a11y', ['a11y']),
            ('remove init script', ['removeinitscript', 'nonexistent-fixture']),
            ('add init script', ['addinitscript', 'window.auditInit=true']),
            ('state save', ['state', 'save', str(self.root/'state.json')]), ('state list', ['state', 'list']),
            ('tab list', ['tab', 'list']), ('tab switch', ['tab', 't1']), ('tab new', ['tab', 'new', self.url+'audit-child']),
            ('window new', ['window', 'new']), ('back', ['back']), ('forward', ['forward']), ('reload', ['reload']),
            ('open/navigation', ['open', self.url+'audit-new']), ('diff url', ['diff', 'url', self.url+'audit', self.url+'audit-two']),
        ]:
            await self.case(name, words)
            if name == 'network har start':
                await self.raw('eval', "fetch('/api').then(()=>true)")
            elif name == 'network har stop':
                har = self.root / 'page.har'
                try:
                    entries = json.loads(har.read_text())['log']['entries']
                    captured = any('/api' in row['request']['url'] for row in entries)
                except (OSError, ValueError, KeyError):
                    captured = False
                self.note('HAR captures actual fixture request', 'verified' if captured else 'semantic-mismatch', 'Checked exported HAR entries, not just command success')
            elif name == 'frame select':
                await self.case('frame content read', ['get', 'text', '#in-frame'], contains='Frame button')
            elif name == 'record stop':
                # Recording can initialize its preview transport even if ffmpeg
                # is missing. Do not leave that test-created listener running.
                await self.raw('stream', 'disable')
        await self.case('pushstate', ['pushstate', self.url+'audit-spa'], verify="location.pathname==='/audit-spa'")
        await self.case('back with history', ['back'], verify="location.pathname==='/audit'")
        await self.case('forward with history', ['forward'], verify="location.pathname==='/audit-spa'")
        for words in (['session'], ['session', 'list'], ['session', 'info'], ['session', 'id'],
                      ['stream', 'status'], ['plugin', 'list'], ['plugin', 'show', 'ctrlx'],
                      ['skills', 'list'], ['skills', 'get', 'core'], ['skills', 'path', 'core'],
                      ['auth', 'list'], ['confirm', 'nonexistent-fixture'], ['deny', 'nonexistent-fixture']):
            await self.case(' '.join(words), words)
        assert not (await self.engine_stream_status(self.tab))['enabled']
        # Explicitly inventory non-page modes instead of claiming full support.
        for name, reason in {
            'clipboard read/write/copy/paste': 'Uses OS-wide clipboard; not touched in this integration audit.',
            'inspect': 'Launches external DevTools; intentionally outside embedded-page acceptance.',
            'connect / auto-connect / profiles': 'External browsers and personal profiles are outside CtrlX ownership.',
            'stream enable / dashboard': 'Not exposed by product. Recording may initialize a preview; audit explicitly disables it afterwards.',
            'install / upgrade / doctor --fix': 'Would change installed browsers/toolchain; pinned binary must remain unchanged.',
            'auth save/login/show/delete, credential-provider': 'No account/credential workflow authorized; vault not integrated.',
            'state load/show/rename/clear/clean/restore': 'Export prerequisite blocked; persistent state remains CEF-owned.',
            'plugin add/run': 'Executes third-party software; only bundled provider is allowed.',
            'MCP / AI chat': 'Separate products/protocols, not CtrlX CLI integration; no paid provider calls.',
            'iOS/Appium, cloud providers, Lightpanda': 'Different runtimes; no simulator/cloud environment provisioned.',
            'launch flags, extensions, init scripts, proxy, TLS, profile': 'CEF host owns launch settings; upstream does not launch Chrome.',
            'security policy/confirmation configuration': 'Upstream policy mode not configured; product has its own boundary.',
        }.items():
            self.note(name, 'not-tested', reason)
        # Verify unsupported public commands are really rejected by CtrlX, not
        # merely omitted from help. No test-only raw entry point is shipped.
        unsupported = ['dblclick','focus','hover','keyboard','keydown','keyup','drag','upload','download','pdf','eval',
                       'back','forward','reload','get','is','find','mouse','set','network','cookies','storage','tab','window',
                       'frame','dialog','diff','trace','profiler','record','console','errors','highlight','inspect','clipboard',
                       'stream','webmcp','react','vitals','a11y','pushstate','addinitscript','removeinitscript','batch','auth','plugin',
                       'confirm','deny','session','state','mcp','chat','dashboard','install','upgrade','doctor','profiles','skills','connect']
        for name in unsupported:
            error = await self.cli_action(0, 'action', name, ok=False)
            assert 'Unsupported browser operation' in error, (name, error)
        self.note('public CLI unsupported command boundary', 'verified', str(len(unsupported))+' upstream command names refused, no passthrough')
        await self.raw('close')
        await self.control('ping')
        self.passed('upstream inventory audited without replacing production app')


if __name__ == '__main__':
    upstream_probe.Fixture = AuditFixture
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('app', 'engine', 'identity'):
        parser.add_argument(key, type=lambda p: Path(p).resolve())
    asyncio.run(Capabilities(parser.parse_args()).run())
