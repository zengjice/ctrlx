#!/usr/bin/env python3
"""Isolated CEF/AppKit and Viewer-input acceptance; never launches personal apps."""
import argparse
import asyncio
import http.server
import json
from pathlib import Path
import threading
import time
from urllib.parse import parse_qs, urlsplit
import uuid
import upstream_probe
from upstream_probe import Probe


class Fixture(http.server.BaseHTTPRequestHandler):
    parent_ready = threading.Event()
    release_image = threading.Event()
    redirect_requested = threading.Event()
    release_redirect = threading.Event()
    served_reload_page = False

    def do_GET(self):
        url = urlsplit(self.path)
        mode = url.path.strip('/')
        if mode in ['pending-image', 'parent-ready']:
            if mode == 'pending-image':
                assert self.release_image.wait(10), 'Parent image was not released'
            else:
                self.parent_ready.set()
            self.send_response(204)
            self.end_headers()
            return
        if mode == 'delayed-redirect' or (mode == 'loading-parent-same-url' and Fixture.served_reload_page):
            case = parse_qs(url.query)['case'][0] if mode == 'delayed-redirect' else mode
            self.redirect_requested.set()
            assert self.release_redirect.wait(10), 'Redirect was not released'
            self.send_response(302)
            self.send_header('Location', 'ctrlx-external-test://open?case=' + case + '&opaque=a%2Bb')
            self.end_headers()
            return
        if mode == 'loading-parent-same-url':
            Fixture.served_reload_page = True
        if mode == 'redirect':
            self.send_response(302)
            self.send_header('Location', 'ctrlx-external-test://open?case=redirect&opaque=a%2Bb')
            self.end_headers()
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        if mode in ['launch-during-load', 'launch-after-load']:
            launch = "location.href='ctrlx-external-test://open?case=" + mode + "&opaque=a%2Bb'"
            if mode == 'launch-during-load':
                body = '<img src="/pending-image"><script>setTimeout(()=>{' + launch + '},100)</script>'
            else:
                body = '<script>onload=()=>setTimeout(()=>{' + launch + '},200)</script>'
            self.wfile.write(('<!doctype html>' + body).encode())
            return
        body = '''<!doctype html><meta charset="utf-8"><title>External app fixture</title>
<button id="open" style="position:fixed;left:20px;top:20px;width:180px;height:60px">Open fixture app</button>
<script>
const mode=MODE, target='ctrlx-external-test://open?case='+mode+'&opaque=a%2Bb';
function launch(){
 if(mode==='iframe'||mode==='duplicate'){for(let i=0;i<(mode==='duplicate'?2:1);i++){
   const f=document.createElement('iframe');f.src=target;document.body.append(f);}}
 else if(mode==='popup')window.open(target);
 else if(mode==='async-popup'){const popup=window.open('about:blank');setTimeout(()=>popup.location.href=target,250);}
 else if(mode==='redirect-button')location.href='/redirect';
 else if(mode==='popup-redirect')window.open('/redirect');
 else if(mode==='loading-parent-popup')window.open('/delayed-redirect?case='+mode);
 else if(mode==='loading-parent-same-tab')location.href='/delayed-redirect?case='+mode;
 else if(mode==='loading-parent-same-url')location.reload();
 else if(mode==='navigate-during-load')location.href='/launch-during-load';
 else if(mode==='navigate-after-load')location.href='/launch-after-load';
 else if(mode==='unsafe')location.href='file:///tmp/ctrlx-must-not-open.app';
 else location.href=target;
}
document.querySelector('#open').onclick=()=>{
 if(mode==='async'||mode==='revoked')setTimeout(launch,250);
 else if(mode==='expired')setTimeout(launch,5200);
 else launch();
};
if(mode==='automatic')setTimeout(launch,100);
if(mode.startsWith('loading-parent-')){
 const image=document.createElement('img');image.src='/pending-image';document.body.append(image);
 document.addEventListener('DOMContentLoaded',()=>fetch('/parent-ready'));
}
</script>'''.replace('MODE', json.dumps(mode))
        self.wfile.write(body.encode())

    def log_message(self, *_):
        pass


class ExternalApplications(Probe):
    native_gateway = True
    mock_keychain = True

    async def validate(self, _):
        run, other = self.runs
        tab, other_tab = self.tabs
        await self.request(run, 'probe.external-app', tab=tab, action='start')

        async def events():
            return (await self.request(run, 'probe.external-app', tab=tab, action='events'))['events']

        async def loads():
            return (await self.request(run, 'probe.external-app', tab=tab, action='events'))['loads']

        async def page(mode):
            await self.request(run, 'navigate', tab=tab, url=self.url + mode)
            async def ready():
                tabs = await self.request(run, 'tabs')
                return next((t for t in tabs if t['id'] == tab and not t['loading']), None)
            await self.wait(ready)
            await asyncio.sleep(.15)
            return len(await events())

        async def local():
            await self.request(run, 'show', tab=tab)
            await asyncio.sleep(.15)
            await self.request(run, 'probe.external-app', tab=tab, action='click', x=80, y=45)

        async def expect_count(count):
            async def matched():
                return len(await events()) == count
            await self.wait(matched, 5)
            await asyncio.sleep(.25)
            assert len(await events()) == count

        # Hold the old document's image and the new navigation's response.
        # Assert actual CEF callback order before releasing the redirect.
        for mode in ['loading-parent-same-tab', 'loading-parent-same-url', 'loading-parent-popup']:
            for gate in [Fixture.parent_ready, Fixture.release_image,
                         Fixture.redirect_requested, Fixture.release_redirect]:
                gate.clear()
            Fixture.served_reload_page = False
            before = len(await events())
            source_url = self.url + mode
            destination = source_url if mode == 'loading-parent-same-url' else self.url + 'delayed-redirect?case=' + mode
            try:
                await self.request(run, 'navigate', tab=tab, url=source_url)
                assert await asyncio.to_thread(Fixture.parent_ready.wait, 5)
                assert next(t for t in await self.request(run, 'tabs') if t['id'] == tab)['loading']
                source = next(e for e in reversed(await loads())
                              if e['event'] == 'load-start' and e['url'] == source_url)
                trace_start = len(await loads())
                clicked = time.monotonic()
                await local()
                assert await asyncio.to_thread(Fixture.redirect_requested.wait, 3)
                Fixture.release_image.set()

                async def old_document_ended():
                    return next((e for e in (await loads())[trace_start:]
                                 if e['event'] == 'load-end' and e['browser'] == source['browser']), None)

                await self.wait(old_document_ended, 3)
                trace = (await loads())[trace_start:]
                (self.root / (mode + '-loads.json')).write_text(json.dumps(trace, indent=2))
                navigation_index = next(i for i, e in enumerate(trace)
                                        if e['event'] == 'before-browse' and e['url'] == destination)
                completion_index = next(i for i, e in enumerate(trace)
                                        if e['event'] == 'load-end' and e['browser'] == source['browser'])
                assert navigation_index < completion_index, trace
                target = trace[navigation_index]
                assert (target['browser'] != source['browser']) == (mode == 'loading-parent-popup'), trace
                assert not any(e['event'] == 'load-start' and e['browser'] == target['browser']
                               for e in trace[navigation_index:]), trace
                assert time.monotonic() - clicked < 4, 'Fixture must finish within activation lifetime'
                Fixture.release_redirect.set()
                await expect_count(before + 1)
                event = (await events())[-1]
                assert event['source'] == tab and event['control'] == '', event
                assert event['url'] == 'ctrlx-external-test://open?case=' + mode + '&opaque=a%2Bb', event
                self.passed('old document completion preserves activation: ' + mode)
            finally:
                Fixture.release_image.set()
                Fixture.release_redirect.set()

        for mode in ['direct', 'iframe', 'async', 'popup', 'async-popup', 'duplicate', 'redirect-button', 'popup-redirect']:
            before = await page(mode)
            await local()
            await expect_count(before + 1)
            event = (await events())[-1]
            assert event['source'] == tab and event['control'] == '', event
            assert event['url'].endswith('opaque=a%2Bb'), event
            self.passed('Host AppKit click: ' + mode + ', exact URL and one launch')

        for mode in ['during-load', 'after-load']:
            before = await page('navigate-' + mode)
            trace_start = len(await loads())
            Fixture.release_image.clear()
            try:
                await local()
                if mode == 'during-load':
                    await expect_count(before + 1)
                else:
                    async def destination_loaded():
                        return next((e for e in (await loads())[trace_start:]
                                     if e['event'] == 'load-end' and e['url'] == self.url + 'launch-' + mode), None)
                    await self.wait(destination_loaded)
                    await asyncio.sleep(.5)
                    assert len(await events()) == before
            finally:
                Fixture.release_image.set()
            trace = (await loads())[trace_start:]
            commit = next(i for i, e in enumerate(trace)
                          if e['event'] == 'load-start' and e['url'] == self.url + 'launch-' + mode)
            external = next(i for i, e in enumerate(trace)
                            if e['event'] == 'before-browse' and e['url'].startswith('ctrlx-external-test:'))
            assert commit < external, trace
            if mode == 'after-load':
                completion = next(i for i, e in enumerate(trace)
                                  if e['event'] == 'load-end' and e['url'] == self.url + 'launch-' + mode)
                assert completion < external, trace
            else:
                assert not any(e['event'] == 'load-end' and e['url'] == self.url + 'launch-' + mode
                               for e in trace[:external]), trace
            self.passed('committed destination launch policy: ' + mode)

        for mode in ['automatic', 'unsafe', 'expired']:
            before = await page(mode)
            if mode != 'automatic':
                await local()
            await asyncio.sleep(5.5 if mode == 'expired' else .4)
            assert len(await events()) == before
            self.passed('no launch: ' + mode)

        before = await page('direct')
        await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate', params={
            'expression': "document.querySelector('#open').click()", 'userGesture': True})
        await asyncio.sleep(.4)
        assert len(await events()) == before
        self.passed('Agent-supplied userGesture cannot authorize OS launches')

        before = await page('direct')
        lease = str(uuid.uuid4())
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']

        async def click_remote():
            frame = await self.request(run, 'probe.remote', tab=tab, request={'action': 'frame'})
            for kind, buttons in [('mousePressed', 1), ('mouseReleased', 0)]:
                await self.request(run, 'probe.remote', tab=tab, request={
                    'action': 'mouse', 'type': kind, 'button': 'left', 'buttons': buttons,
                    'clickCount': 1, 'x': 80, 'y': 45, 'lease': lease, 'generation': frame['generation']})

        await click_remote()
        await expect_count(before + 1)
        assert (await events())[-1]['control'] == lease
        self.passed('validated Viewer pointer input opens on the original Host page')
        await self.request(run, 'probe.remote-control', tab=tab, lease=None)

        before = await page('revoked')
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
        await click_remote()
        await self.request(run, 'probe.remote-control', tab=tab, lease=None)
        await asyncio.sleep(.6)
        assert len(await events()) == before
        self.passed('release control invalidates the delayed launch')

        # Every test-created popup belongs to this fixture and is explicitly closed.
        for owner in self.runs:
            for item in await self.request(owner, 'tabs'):
                await self.request(owner, 'close', tab=item['id'])


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('engine', type=Path)
    parser.add_argument('identity', type=Path)
    args = parser.parse_args()
    args.app, args.engine, args.identity = (p.resolve() for p in (args.app, args.engine, args.identity))
    upstream_probe.Fixture = Fixture
    test = ExternalApplications(args)
    await test.run()
    assert test.host.returncode == 0


if __name__ == '__main__':
    asyncio.run(main())
