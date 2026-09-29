#!/usr/bin/env python3
"""Expansion acceptance through the public CLI, isolated profile and fixture owners.

Args: signed acceptance app, pinned engine, codex fixture, React fixture assets.
The asset directory contains upstream React 18.3.1 development UMD builds as
react.js and react-dom.js. No production sessions/profile or credentials used.
"""
import argparse
import asyncio
import json
from pathlib import Path
import struct
import subprocess

from page_capabilities import PageCapabilities, ExtendedFixture
import upstream_probe


class ExpansionFixture(ExtendedFixture):
    assets = None

    def do_GET(self):
        path = self.path.split('?')[0]
        if path in ('/react.js', '/react-dom.js'):
            body = (self.assets / path[1:]).read_bytes()
            mime = 'text/javascript'
        elif path == '/frames':
            body = f'''<h1>Frame host</h1><iframe id="cross" name="cross" src="http://localhost:{self.server.server_port}/cross"></iframe>'''.encode()
            mime = 'text/html'
        elif path == '/cross':
            body = f'''<h1>Cross-process child</h1><input id="child-input"><button id="child-button" onclick="document.body.dataset.clicked=event.isTrusted?'yes':'untrusted';document.body.dataset.clicks=+(document.body.dataset.clicks||0)+1">Child action</button>
<iframe name="nested" src="http://127.0.0.1:{self.server.server_port}/nested"></iframe>'''.encode()
            mime = 'text/html'
        elif path == '/nested':
            body = b'<input id="nested-input">'
            mime = 'text/html'
        elif path in ('/diff-red', '/diff-blue'):
            color = path.removeprefix('/diff-')
            body = f'<style>body{{background:{color}}}</style><h1>{color} comparison</h1>'.encode()
            mime = 'text/html'
        elif path == '/react-proof':
            body = b'''<div id="root"></div><script src="/react.js"></script><script src="/react-dom.js"></script>
<script>function CounterProof(){const [count,setCount]=React.useState(0);return React.createElement('button',{id:'counter',onClick:()=>setCount(count+1)},'Counter '+count)}
ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(CounterProof));</script>'''
            mime = 'text/html'
        elif path == '/webmcp-proof':
            body = b'''<output id="result">idle</output><script>
document.modelContext.registerTool({name:'set_message',description:'Fixture only',inputSchema:{type:'object',properties:{message:{type:'string'}},required:['message']},execute:async ({message})=>{document.querySelector('#result').textContent=message;return {message}}});
window.waitController=new AbortController();
document.modelContext.registerTool({name:'wait_cancel',description:'Fixture wait',inputSchema:{type:'object',properties:{}},execute:async()=>new Promise(()=>{})},{signal:window.waitController.signal});
</script>'''
            mime = 'text/html'
        else:
            return super().do_GET()
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)


class Expanded(PageCapabilities):
    async def validate(self, port):
        if self.args.expansion_only:
            self.tab = (await self.cli_action(0, 'action', 'open', '--url', self.url + 'audit'))['result']['id']
        else:
            await super().validate(port)
        # Previous regression intentionally leaves phone emulation active.
        # Desktop OOPIF input is tested independently of mobile hit-testing.
        await self.command('set', 'viewport', '900', '700')
        await self.cli_action(0, 'action', 'navigate', '--tab', self.tab, '--url', self.url + 'audit')
        await self.command('wait', '--load', 'load')
        await self.command('eval', 'document.activeElement.blur();true')
        script_input = self.root / 'eval-input.js'
        script_input.write_text("document.querySelector('#text').value='file 中文 --provider';true")
        await self.cli_action(0, 'command', '--tab', self.tab, '--input-file', str(script_input), '--', 'eval')
        await self.verify("document.querySelector('#text').value==='file 中文 --provider'")
        await self.cli_action(0, 'command', '--tab', self.tab, '--input-file', str(script_input), '--', 'eval', '1', ok=False)
        self.passed('bounded JS file input executes literal source; conflicting inline input refused')
        await self.command('network', 'requests')
        await self.command('eval', "fetch('/api').then(r=>r.text())")
        requests = (await self.command('network', 'requests', '--filter', '/api'))['requests']
        detail = await self.command('network', 'request', requests[-1]['requestId'])
        assert json.loads(detail['responseBody'])['fixture'] is True, detail
        await self.command('network', 'request', requests[-1]['requestId'], owner=1, tab=self.tab, ok=False)
        for mode in ('all', 'text', 'none'):
            await self.command('network', 'har', 'start', '--content', mode)
            await self.command('eval', "fetch('/api').then(r=>r.text())")
            har = self.root / f'content-{mode}.har'
            await self.command('network', 'har', 'stop', output=har)
            entries = json.loads(har.read_text())['log']['entries']
            entry = next(e for e in entries if e['request']['url'].endswith('/api'))
            content = entry['response']['content']
            if mode == 'none':
                assert not content.get('text'), content
            else:
                assert json.loads(content['text'])['fixture'] is True, content
        self.passed('request details include actual response body; all/text/none HAR modes and ownership boundary')
        url_diff = self.root / 'url-diff.png'
        result = await self.command('diff', 'url', self.url + 'diff-red', self.url + 'diff-blue', '--screenshot', output=url_diff)
        assert url_diff.read_bytes().startswith(b'\x89PNG') and result['screenshotDiff']['differentPixels'] > 0, result
        assert result['snapshotDiff']['changed'] is True, result
        await self.verify("location.pathname==='/diff-blue'")
        same_diff = self.root / 'url-same.png'
        result = await self.command('diff', 'url', self.url + 'diff-blue', self.url + 'diff-blue', '--screenshot', output=same_diff)
        assert result['artifactSkipped'] and not same_diff.exists() and result['snapshotDiff']['changed'] is False, result
        await self.cli_action(0, 'action', 'navigate', '--tab', self.tab, '--url', self.url + 'audit')
        await self.command('wait', '--load', 'load')
        self.passed('URL screenshot diff compares actual pixels/text, skips identical output and stays on second URL')
        jpeg = self.root / 'element.jpeg'
        await self.command('screenshot', '--selector', '#apply', '--format', 'jpeg', '--quality', '70', output=jpeg)
        assert jpeg.read_bytes().startswith(b'\xff\xd8\xff')
        png = self.root / 'element.png'
        await self.command('screenshot', '--selector', '#apply', output=png)
        width, height = struct.unpack('>II', png.read_bytes()[16:24])
        assert 0 < width < 400 and 0 < height < 150, (width, height)
        self.passed('JPEG bytes and actual element-sized PNG clipping')

        # Native button text can repaint with slightly different antialiasing.
        # Test exact unchanged pixels against a deterministic, text-free region.
        await self.command('eval', "const swatch=document.createElement('div');swatch.id='capture-proof';swatch.style.cssText='width:96px;height:64px;background:rgb(128,128,128)';document.body.prepend(swatch);true")
        first, second = self.root / 'first.png', self.root / 'unchanged.png'
        assert (await self.command('screenshot', '--selector', '#capture-proof', '--if-changed', output=first))['changed']
        result = await self.command('screenshot', '--selector', '#capture-proof', '--if-changed', output=second)
        assert result['changed'] is False and not second.exists(), result
        await self.command('eval', "document.querySelector('#capture-proof').style.background='red';true")
        assert (await self.command('screenshot', '--selector', '#capture-proof', '--if-changed', output=second))['changed']
        diff = self.root / 'diff.png'
        result = await self.command('diff', 'screenshot', '--baseline', str(first), '--selector', '#capture-proof', output=diff)
        assert diff.read_bytes().startswith(b'\x89PNG'), result
        assert result.get('differentPixels', 0) > 0, result
        identical = self.root / 'no-diff.png'
        result = await self.command('diff', 'screenshot', '--baseline', str(second), '--selector', '#capture-proof', output=identical)
        assert result['match'] and result['artifactSkipped'] and not identical.exists(), result
        mismatched = self.root / 'size-diff.png'
        result = await self.command('diff', 'screenshot', '--baseline', str(second), output=mismatched)
        assert result['dimensionMismatch'] and result['artifactSkipped'] and not mismatched.exists(), result
        baseline = self.root / 'snapshot.txt'
        snapshot = await self.command('snapshot')
        baseline.write_text(snapshot['snapshot'])
        assert (await self.command('diff', 'snapshot', '--baseline', str(baseline)))['changed'] is False
        await self.command('eval', "document.querySelector('h1').textContent='Different proof';true")
        assert (await self.command('diff', 'snapshot', '--baseline', str(baseline)))['changed']
        self.passed('conditional screenshot no-file contract and file-based image/text differences')

        steps = [['fill', '#text', 'Batch literal --provider'], ['get', 'value', '#text']]
        result = await self.cli_action(0, 'batch', '--tab', self.tab, '--commands-json', json.dumps(steps))
        assert 'Batch literal --provider' in json.dumps(result)
        await self.cli_action(0, 'batch', '--tab', self.tab, '--commands-json', json.dumps([['fill', '#text', 'BAD'], ['close']]), ok=False)
        await self.verify("document.querySelector('#text').value==='Batch literal --provider'")
        await self.cli_action(0, 'batch', '--tab', self.tab, '--commands-json', json.dumps([['eval', 'window.sequence=1'], ['eval', "throw new Error('fixture')"], ['eval', 'window.sequence=2']]), ok=False)
        await self.verify('window.sequence===1')
        await self.cli_action(1, 'batch', '--tab', self.tab, '--commands-json', json.dumps([['get', 'title']]), ok=False)
        result = await self.command('diff', 'url', self.url + 'audit', self.url + 'frames')
        assert 'Frame host' in json.dumps(result), result
        self.passed('batch prevalidation, ordering, stop-on-failure, cross-owner denial and URL diff')
        continued = await self.cli_action(0, 'batch', '--tab', self.tab, '--continue-on-error', '--commands-json', json.dumps([
            ['eval', 'window.sequence=10'], ['eval', "throw new Error('fixture')"], ['eval', 'window.sequence=20'],
        ]), ok=False, failure_json=True)
        assert not continued['ok'] and [row['success'] for row in continued['result']] == [True, False, True], continued
        await self.verify('window.sequence===20')
        image, doc = self.root / 'batch.png', self.root / 'batch.pdf'
        artifacts = await self.cli_action(0, 'batch', '--tab', self.tab, '--commands-json', json.dumps([
            {'command': ['screenshot'], 'output': str(image)}, {'command': ['pdf'], 'output': str(doc)},
        ]))
        assert image.read_bytes().startswith(b'\x89PNG') and doc.read_bytes().startswith(b'%PDF')
        assert all(row['success'] and 'data' not in row['result'] for row in artifacts['result'])
        await self.cli_action(0, 'batch', '--tab', self.tab, '--commands-json', json.dumps([
            {'command': ['eval', 'window.sequence=30']}, {'command': ['screenshot'], 'output': str(image)},
        ]), ok=False)
        await self.verify('window.sequence===20')
        self.passed('batch continue preserves ordered results and failure exit; PNG/PDF export and full-plan no-overwrite validation')

        await self.command('wait', '--load', 'load')
        await self.command('frame', '#cross')
        await self.command('fill', '#child-input', 'OOPIF proof')
        await self.command('click', '#child-button')
        assert 'OOPIF proof' in json.dumps(await self.command('get', 'value', '#child-input'))
        assert 'yes' in json.dumps(await self.command('get', 'attr', 'body', 'data-clicked'))
        await self.command('set', 'device', 'iPhone 14')
        await self.command('click', '#child-button', ok=False)
        assert (await self.command('get', 'attr', 'body', 'data-clicks'))['value'] == '1'
        await self.command('set', 'viewport', '900', '700')
        await self.command('click', '#child-button')
        assert (await self.command('get', 'attr', 'body', 'data-clicks'))['value'] == '2'
        await self.command('frame', '--url', '/nested')
        await self.command('fill', '#nested-input', 'Nested proof')
        assert 'Nested proof' in json.dumps(await self.command('get', 'value', '#nested-input'))
        await self.command('frame', 'main')
        await self.verify("document.querySelector('h1').textContent==='Frame host'")
        self.passed('nested OOPIF selection/fill/trusted click/readback; mobile pointer refusal and desktop recovery')

        video = self.root / 'clip.webm'
        await self.cli_action(0, 'record', '--tab', self.tab, '--seconds', '2', '--output', str(video), '--commands-json', json.dumps([
            ['eval', "window.flash=setInterval(()=>document.body.style.background=document.body.style.background==='red'?'blue':'red',200);true"]]))
        assert video.read_bytes().startswith(b'\x1aE\xdf\xa3')
        probe = json.loads(subprocess.check_output(['/opt/homebrew/bin/ffprobe', '-v', 'error', '-count_frames', '-show_entries', 'stream=nb_read_frames,width,height', '-of', 'json', str(video)]))
        assert int(probe['streams'][0]['nb_read_frames']) >= 10, probe
        hashes = subprocess.check_output(['/opt/homebrew/bin/ffmpeg', '-v', 'error', '-i', str(video), '-f', 'framemd5', '-']).decode()
        assert len({line.rsplit(',', 1)[-1] for line in hashes.splitlines() if not line.startswith('#')}) > 1
        await self.command('eval', 'clearInterval(window.flash);true')
        self.passed('bounded upstream video contains multiple decoded, changing frames; owned-page actions recorded')
        mp4 = self.root / 'clip.mp4'
        sheet = self.root / 'clip-sheet.png'
        result = await self.cli_action(0, 'record', '--tab', self.tab, '--seconds', '2', '--format', 'mp4', '--fps', '12', '--cursor', '--output', str(mp4),
                             '--contact-sheet', str(sheet), '--contact-sheet-threshold', '0.01',
                             '--commands-json', json.dumps([['mouse', 'move', '100', '100']]))
        assert mp4.read_bytes()[4:8] == b'ftyp'
        assert sheet.read_bytes().startswith(b'\x89PNG') and result['result']['contactSheetFrames'] >= 1, result
        probe = json.loads(subprocess.check_output(['/opt/homebrew/bin/ffprobe', '-v', 'error', '-count_frames', '-show_entries', 'stream=codec_name,nb_read_frames,r_frame_rate', '-of', 'json', str(mp4)]))
        assert probe['streams'][0]['codec_name'] == 'h264' and probe['streams'][0]['r_frame_rate'] == '12/1', probe
        assert int(probe['streams'][0]['nb_read_frames']) >= 12, probe
        await self.cli_action(0, 'record', '--tab', self.tab, '--seconds', '1', '--format', 'mp4', '--output', str(mp4), ok=False)
        self.passed('MP4 contains H.264 at requested fps, cursor-enabled capture, PNG contact sheet and no-overwrite refusal')

        script = self.root / 'init.js'
        script.write_text('window.ctrlxInitProof = "before-page";')
        await self.cli_action(0, 'setup', '--tab', self.tab, '--react', '--init-script', str(script))
        await self.command('reload')
        await self.command('wait', '--load', 'load')
        await self.verify('window.ctrlxInitProof === "before-page"')
        await self.cli_action(0, 'action', 'navigate', '--tab', self.tab, '--url', self.url + 'react-proof')
        await self.command('wait', '#counter')
        tree = await self.command('react', 'tree', '--raw-json')
        assert 'CounterProof' in json.dumps(tree), tree
        fiber = next(node['id'] for node in tree['nodes'] if node['name'] == 'CounterProof')
        assert 'CounterProof' in json.dumps(await self.command('react', 'inspect', str(fiber), '--raw-json'))
        await self.command('react', 'renders', 'start')
        await self.command('click', '#counter')
        await self.verify("document.querySelector('#counter').textContent==='Counter 1'")
        renders = await self.command('react', 'renders', 'stop', '--raw-json')
        assert 'CounterProof' in json.dumps(renders), renders
        await self.command('react', 'suspense')
        self.passed('init script survives navigation; upstream hook observes real React tree and renders')
        dynamic = self.root / 'dynamic-init.js'
        dynamic.write_text('window.dynamicInitProof="dynamic";')
        added = (await self.cli_action(0, 'command', '--tab', self.tab, '--input-file', str(dynamic), '--', 'init', 'add'))['result']
        script_id = added['identifier']
        second_id = (await self.command('init', 'add', 'window.secondInitProof=2'))['identifier']
        assert script_id in (await self.command('init', 'list'))['scripts']
        await self.verify('typeof window.dynamicInitProof==="undefined"')
        await self.command('reload')
        await self.command('wait', '--load', 'load')
        await self.verify('window.dynamicInitProof==="dynamic" && window.secondInitProof===2')
        await self.command('init', 'remove', script_id, owner=1, ok=False)
        await self.command('init', 'remove', script_id)
        await self.command('reload')
        await self.command('wait', '--load', 'load')
        await self.verify('typeof window.dynamicInitProof==="undefined" && window.secondInitProof===2 && window.ctrlxInitProof==="before-page"')
        await self.command('init', 'remove', script_id, ok=False)
        self.passed('opaque init IDs add/list/remove independently across navigation without changing setup hooks; cross-owner removal denied')

        await self.cli_action(0, 'action', 'navigate', '--tab', self.tab, '--url', self.url + 'webmcp-proof')
        notices = [await self.command('wait', '--load', 'load'), await self.command('get', 'title')]
        assert any('set_message' in json.dumps(row.get('webmcp', {})) for row in notices), notices
        assert 'webmcp' not in await self.command('get', 'title')
        changed = await self.command('eval', 'window.waitController.abort();true')
        assert changed['webmcp']['toolCount'] == 1, changed
        await self.command('eval', "document.modelContext.registerTool({name:'wait_cancel',description:'Fixture wait',inputSchema:{type:'object',properties:{}},execute:async()=>new Promise(()=>{})});true")
        self.passed('WebMCP catalog is advertised after ordinary actions, deduplicated and refreshed after tool changes')
        tools = await self.command('webmcp', 'list')
        assert 'set_message' in json.dumps(tools), tools
        await self.command('webmcp', 'invoke', 'set_message', '--params', '{"message":"tool-proof"}')
        await self.verify("document.querySelector('#result').textContent==='tool-proof'")
        params_input = self.root / 'tool-params.json'
        params_input.write_text('{"message":"file-params-proof"}')
        await self.cli_action(0, 'command', '--tab', self.tab, '--input-file', str(params_input), '--', 'webmcp', 'invoke', 'set_message')
        await self.verify("document.querySelector('#result').textContent==='file-params-proof'")
        pending = await self.command('webmcp', 'invoke', 'wait_cancel', '--detach')
        invocation = pending['invocationId']
        await self.command('webmcp', 'cancel', invocation)
        result = await self.command('webmcp', 'result', invocation)
        assert 'cancel' in json.dumps(result).lower(), result
        assert not (await self.engine_stream_status(self.tab))['enabled']
        self.passed('WebMCP explicit discovery, file params, invocation, cancellation/result; preview disabled')
        await self.cli_action(0, 'setup', '--tab', self.tab)
        assert not (await self.command('init', 'list'))['scripts']
        await self.command('init', 'remove', second_id, ok=False)
        await self.command('reload')
        await self.command('wait', '--load', 'load')
        await self.verify("typeof window.ctrlxInitProof==='undefined' && typeof window.__REACT_DEVTOOLS_GLOBAL_HOOK__==='undefined'")
        self.passed('clearing setup removes future init hooks without closing or replacing the tab')
        await self.cli_action(0, 'action', 'navigate', '--tab', self.tab, '--url', self.url + 'audit')
        cleared = [await self.command('wait', '--load', 'load'), await self.command('get', 'title')]
        assert any(row.get('webmcp', {}).get('available') is False for row in cleared), cleared
        self.passed('navigation clears advertised WebMCP tools; setup invalidates dynamic script handles without aliasing')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'engine', 'identity', 'react_assets'):
        parser.add_argument(name, type=lambda p: Path(p).resolve())
    parser.add_argument('--expansion-only', action='store_true', help='Focused development run; default includes the previous capability suite')
    args = parser.parse_args()
    ExpansionFixture.assets = args.react_assets
    upstream_probe.Fixture = ExpansionFixture
    asyncio.run(Expanded(args).run())
