#!/usr/bin/env python3
"""Native remote-surface acceptance, isolated app/profile and fixture only.

Exercises the private product frame/input boundary using an acceptance-only
probe. Swift authorization/transport/UI are covered separately, not by this test.
"""
import argparse
import asyncio
import base64
import io
import json
import time
import uuid
from pathlib import Path
from PIL import Image, ImageChops
from managed_engine import Managed
from integration import call


class RemoteBrowser(Managed):
    async def validate(self, _):
        run, other = self.runs
        tab = self.tabs[0]
        await self.control('select-session', 'upstream-beta')
        await asyncio.sleep(.3)

        async def remote(**request):
            return await self.request(run, 'probe.remote', tab=tab, request=request)

        async def frame(maximum_dimension=None):
            request = {} if maximum_dimension is None else {'maximumDimension': maximum_dimension}
            value = await remote(action='frame', **request)
            jpeg = base64.b64decode(value['jpeg'])
            budget = (512 if maximum_dimension is not None else 180) * 1024
            assert len(jpeg) <= budget and value['width'] > 0 and value['height'] > 0
            image = Image.open(io.BytesIO(jpeg)).convert('RGB')
            limit = maximum_dimension or 1024
            assert image.width <= limit and image.height <= limit
            assert len(image.resize((64, 64)).getcolors(4096)) > 10, 'Blank background frame'
            (self.root / 'remote-background.jpg').write_bytes(jpeg)
            return value

        async def evaluate(expression):
            result = await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate',
                params={'expression': expression, 'returnByValue': True})
            return result['result'].get('value')

        async def view(action='status'):
            return await self.request(run, 'probe.remote-view', tab=tab, action=action)

        # Calibrate the observer against the old capture path: changes between
        # request and reply must be counted even when the final size is restored.
        await self.request(run, 'show', tab=tab)
        await asyncio.sleep(.3)
        original = await view('start')
        metrics = await self.request(run, 'probe.cdp', tab=tab, method='Page.getLayoutMetrics')
        viewport = metrics['cssVisualViewport']
        scale = min(1, 1024 / (max(viewport['clientWidth'], viewport['clientHeight']) * max(1, original['pixelRatio'])))
        assert scale < 1, 'Fixture must require screenshot downscaling'
        await self.request(run, 'probe.cdp', tab=tab, method='Page.captureScreenshot', params={
            'format': 'jpeg', 'quality': 50, 'captureBeyondViewport': False,
            'clip': {'x': viewport['pageX'], 'y': viewport['pageY'],
                     'width': viewport['clientWidth'], 'height': viewport['clientHeight'], 'scale': scale}})
        calibration = await view('stop')
        assert calibration['sizeChanges'] > 0, 'Observer missed the old live-surface resize'
        self.passed('old clip/scale capture reproduces transient Host view resizing')

        await evaluate("""document.body.style.minHeight='4000px';window.scrollTo(0,100);
            window.remoteViewportChanges=0;
            window.remoteViewportBaseline=JSON.stringify([innerWidth,innerHeight,scrollX,scrollY,devicePixelRatio]);
            window.remoteViewportMonitor=true;
            (function monitor(){if(!window.remoteViewportMonitor)return;
              if(JSON.stringify([innerWidth,innerHeight,scrollX,scrollY,devicePixelRatio])!==window.remoteViewportBaseline)
                window.remoteViewportChanges++;
              requestAnimationFrame(monitor);})();""")
        geometry = await view('start')
        durations = []
        for index in range(12):
            started = time.monotonic()
            await frame(2560 if index % 2 else 768)
            durations.append(time.monotonic() - started)
            await asyncio.sleep(.18)
        stable = await view('stop')
        assert stable['sizeChanges'] == 0 and stable['width'] == geometry['width'] and stable['height'] == geometry['height'], stable
        assert await evaluate('remoteViewportChanges') == 0
        await evaluate('remoteViewportMonitor=false')
        print('Continuous capture mean/max seconds:', round(sum(durations) / len(durations), 3), round(max(durations), 3), flush=True)
        self.passed('continuous visible capture preserves native bounds, CSS viewport, scroll and pixel ratio')

        geometry = await view('start')
        concurrent = await asyncio.gather(*(remote(action='frame') for _ in range(4)))
        grouped = await view('stop')
        assert grouped['captures'] - geometry['captures'] < 4, grouped
        assert all(value == concurrent[0] for value in concurrent), 'Concurrent Viewers received different capture state'
        assert grouped['sizeChanges'] == 0
        self.passed('concurrent Viewers share bounded frames without resizing the Host')

        geometry = await view('start')
        legacy = await frame()
        sharper = await frame(2560)
        legacy_image = Image.open(io.BytesIO(base64.b64decode(legacy['jpeg'])))
        sharper_image = Image.open(io.BytesIO(base64.b64decode(sharper['jpeg'])))
        assert max(sharper_image.size) > max(legacy_image.size), (legacy_image.size, sharper_image.size)
        assert (legacy['width'], legacy['height'], legacy['generation']) == (sharper['width'], sharper['height'], sharper['generation'])
        (self.root / 'remote-adaptive.jpg').write_bytes(base64.b64decode(sharper['jpeg']))
        (self.root / 'remote-legacy.jpg').write_bytes(base64.b64decode(legacy['jpeg']))
        stable = await view('stop')
        assert stable['sizeChanges'] == 0
        print('Legacy/adaptive image sizes:', legacy_image.size, sharper_image.size, flush=True)
        self.passed('adaptive frame gains real pixels without changing Host viewport or input generation')

        geometry = await view('start')
        sizes = (768, 2560, 768, 2560)
        concurrent = await asyncio.gather(*(remote(action='frame', maximumDimension=size) for size in sizes))
        grouped = await view('stop')
        images = [Image.open(io.BytesIO(base64.b64decode(value['jpeg']))) for value in concurrent]
        assert max(images[0].size) <= 768 and max(images[2].size) <= 768
        assert max(images[1].size) > 1024 and max(images[3].size) > 1024
        assert concurrent[0] == concurrent[2] and concurrent[1] == concurrent[3]
        assert grouped['captures'] - geometry['captures'] < 4 and grouped['sizeChanges'] == 0
        self.passed('mixed-resolution Viewers coalesce within their own size and keep independent image quality')

        await evaluate("""const dense=document.createElement('div');dense.id='remote-dense-text';
          dense.style.cssText='position:fixed;inset:0;background:white;color:#222;z-index:9999;overflow:hidden;columns:2;font:12px/18px sans-serif';
          for(let i=0;i<100;i++){const p=document.createElement('p');p.style.margin='4px 12px';
            p.textContent='中文网页文字清晰度 Browser preview 0123456789 — 目录、搜索结果与滚动测试 '+i;dense.append(p)}
          document.body.append(dense);""")
        dense_legacy = await frame()
        dense_adaptive = await frame(2560)
        legacy_image = Image.open(io.BytesIO(base64.b64decode(dense_legacy['jpeg'])))
        sharper_image = Image.open(io.BytesIO(base64.b64decode(dense_adaptive['jpeg'])))
        assert max(sharper_image.size) > max(legacy_image.size), (legacy_image.size, sharper_image.size)
        (self.root / 'remote-dense-legacy.jpg').write_bytes(base64.b64decode(dense_legacy['jpeg']))
        (self.root / 'remote-dense-adaptive.jpg').write_bytes(base64.b64decode(dense_adaptive['jpeg']))
        print('Dense text legacy/adaptive sizes:', legacy_image.size, sharper_image.size,
              'bytes:', len(base64.b64decode(dense_adaptive['jpeg'])), flush=True)
        await evaluate("document.querySelector('#remote-dense-text').remove()")
        self.passed('dense Chinese/English page retains more pixels within the adaptive frame budget')

        same_size = await asyncio.gather(remote(action='frame'), remote(action='frame', maximumDimension=1024))
        assert len(base64.b64decode(same_size[0]['jpeg'])) <= 180 * 1024
        assert len(base64.b64decode(same_size[1]['jpeg'])) <= 512 * 1024
        assert same_size[0]['jpeg'] != same_size[1]['jpeg']
        self.passed('legacy and adaptive requests at the same size retain separate quality and byte limits')

        for invalid in (255, 2561, 1.5, 'large'):
            denied = await asyncio.to_thread(call, self.endpoint['socket'], dict(run, command='probe.remote', tab=tab,
                request=dict(action='frame', maximumDimension=invalid)), False)
            assert 'Unsupported browser frame size' in denied, denied
        self.passed('native boundary rejects invalid and oversized frame requests')

        await evaluate('window.scrollTo(0,0)')
        await self.control('select-session', 'upstream-beta')
        await asyncio.sleep(.3)

        shot = await frame()
        self.passed('background Host tab produces a bounded, nonblank native frame')
        rect = await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate',
            params={'expression': "JSON.stringify((()=>{const r=document.querySelector('#message').getBoundingClientRect();return {x:r.x+8,y:r.y+8}})())", 'returnByValue': True})
        point = json.loads(rect['result']['value'])
        lease = str(uuid.uuid4())
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
        for action in ('read', 'show', 'close'):
            denied = await asyncio.to_thread(call, self.endpoint['socket'], dict(run, command=action, tab=tab), False)
            assert 'person' in denied
        for event, buttons in [('mousePressed', 1), ('mouseReleased', 0)]:
            await remote(action='mouse', lease=lease, generation=shot['generation'], type=event,
                         button='left', buttons=buttons, clickCount=1, **point)
        await remote(action='text', lease=lease, generation=shot['generation'], text='远程输入 中文 "quotes"')
        # The Agent cannot inspect while human control is active, including JS.
        await self.request(run, 'probe.remote-control', tab=tab)
        result = await self.request(run, 'read', tab=tab)
        assert '远程输入 中文' in json.dumps(result, ensure_ascii=False), result
        actual = await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate',
            params={'expression': "document.querySelector('#message').value", 'returnByValue': True})
        assert actual['result']['value'] == '远程输入 中文 "quotes"', actual
        self.passed('trusted remote click + committed Chinese input; original engine blocked until release')

        # Clipboard transfers use only the addressed page and lease, not the Host pasteboard.
        await evaluate("document.querySelector('#message').focus();document.querySelector('#message').select()")
        clipboard_lease = str(uuid.uuid4())
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=clipboard_lease))['accepted']
        clipboard_frame = await frame()
        async def clipboard_call(action, **payload):
            return await remote(action=action, lease=clipboard_lease, generation=clipboard_frame['generation'], **payload)
        copied = await clipboard_call('copy')
        assert copied['kind'] == 'text' and base64.b64decode(copied['data']).decode() == '远程输入 中文 "quotes"', copied
        replacement = '粘贴 text\n"quotes" `literal`'
        await clipboard_call('paste', kind='text', data=base64.b64encode(replacement.encode()).decode())
        await self.request(run, 'probe.remote-control', tab=tab)
        actual_paste = await evaluate("document.querySelector('#message').value")
        assert actual_paste == replacement.replace('\n', ' '), (actual_paste, replacement)
        await evaluate("const t=document.createElement('textarea');t.id='clipboard-textarea';document.body.append(t);t.focus()")
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=clipboard_lease))['accepted']
        await clipboard_call('paste',kind='text',data=base64.b64encode(replacement.encode()).decode())
        await self.request(run, 'probe.remote-control', tab=tab)
        multiline = await evaluate("document.querySelector('#clipboard-textarea').value")
        assert multiline == replacement, (multiline,replacement)
        await evaluate("document.querySelector('#clipboard-textarea').remove();document.querySelector('#message').focus()")
        # A paste handler receives the real image payload, and can consume it.
        await evaluate("""document.querySelector('#message').onpaste=e=>{
            window.clipboardImage={type:e.clipboardData.files[0]?.type,size:e.clipboardData.files[0]?.size};e.preventDefault()};""")
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=clipboard_lease))['accepted']
        png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQaPjQAMIMMAYARzIIQdQEEEMAAAAASUVORK5CYII=')
        await clipboard_call('paste', kind='png', data=base64.b64encode(png).decode())
        await self.request(run, 'probe.remote-control', tab=tab)
        assert await evaluate('clipboardImage') == {'type':'image/png', 'size':len(png)}
        await evaluate("document.querySelector('#message').onpaste=null;document.querySelector('#message').type='password';document.querySelector('#message').select()")
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=clipboard_lease))['accepted']
        denied = await asyncio.to_thread(call, self.endpoint['socket'], dict(run, command='probe.remote', tab=tab,
            request=dict(action='copy',lease=clipboard_lease,generation=clipboard_frame['generation'])), False)
        assert 'Password' in denied, denied
        await self.request(run, 'probe.remote-control', tab=tab)
        await evaluate("document.querySelector('#message').type='text';document.querySelector('#message').blur();getSelection().removeAllRanges()")
        self.passed('page clipboard copies selection, pastes Unicode and image payloads, and refuses password copies')
        await evaluate("""const rich=document.createElement('div');rich.id='clipboard-rich';rich.contentEditable=true;
            rich.style.cssText='position:fixed;left:100px;top:240px;width:200px;height:100px;background:white';
            document.body.append(rich);rich.focus();""")
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=clipboard_lease))['accepted']
        await clipboard_call('paste', kind='png', data=base64.b64encode(png).decode())
        await self.request(run, 'probe.remote-control', tab=tab)
        image_source = await evaluate("document.querySelector('#clipboard-rich img').src")
        assert image_source.startswith('data:image/png;base64,')
        point_image = await evaluate("""(()=>{const e=document.querySelector('#clipboard-rich img');e.style.width='32px';e.style.height='32px';
            document.querySelector('#clipboard-rich').blur();getSelection().removeAllRanges();const r=e.getBoundingClientRect();return {x:r.x+10,y:r.y+10}})()""")
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=clipboard_lease))['accepted']
        for event, buttons in [('mousePressed',1),('mouseReleased',0)]:
            await remote(action='mouse',lease=clipboard_lease,generation=clipboard_frame['generation'],
                type=event,button='left',buttons=buttons,clickCount=1,**point_image)
        copied_image = await clipboard_call('copy')
        assert copied_image['kind'] == 'png'
        assert Image.open(io.BytesIO(base64.b64decode(copied_image['data']))).size == (2,2)
        await self.request(run, 'probe.remote-control', tab=tab)
        await evaluate("document.querySelector('#clipboard-rich').remove();getSelection().removeAllRanges()")
        self.passed('contenteditable image paste and rendered-image copy return actual image bytes')


        # A lease obtained by the managed engine before handoff must also stop.
        endpoint = await self.request(run, 'engine.attach', tab=tab)
        from websockets.asyncio.client import connect
        async with connect(endpoint['url'], max_size=8*1024*1024) as ws:
            assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
            await ws.send(json.dumps({'id': 71, 'method': 'Runtime.evaluate', 'params': {'expression': "document.title='bad'"}}))
            response = json.loads(await ws.recv())
            assert response['id'] == 71 and 'error' in response
            await self.request(run, 'probe.remote-control', tab=tab)
        self.passed('pre-existing Vercel CDP attachment cannot bypass human control')

        shot = await frame()
        await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate', params={
            'expression': "window.remoteMouseUps=0;document.addEventListener('mouseup',()=>window.remoteMouseUps++)"})
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
        await remote(action='mouse', lease=lease, generation=shot['generation'], type='mousePressed',
                     button='left', buttons=1, clickCount=1, **point)
        await self.request(run, 'probe.remote-control', tab=tab)
        actual = await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate',
            params={'expression': 'window.remoteMouseUps', 'returnByValue': True})
        assert actual['result']['value'] == 1, actual
        self.passed('releasing control ends an unfinished pointer drag')

        await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate',
            params={'expression': 'window.remoteMouseUps=0'})
        shot = await frame()
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
        point = {'x': shot['width'] / 2, 'y': shot['height'] / 2}
        await remote(action='mouse', lease=lease, generation=shot['generation'], type='mousePressed',
                     button='left', buttons=1, clickCount=1, **point)
        state = await self.request(run, 'probe.remote-state', tab=tab)
        assert state['pressed'] is True, state
        await remote(action='fit', lease=lease, generation=shot['generation'],
                     width=int(shot['width']), height=int(shot['height']))
        newer = await frame()
        await remote(action='fit', lease=lease, generation=newer['generation'],
                     width=int(newer['width']), height=int(newer['height']))
        stale = await asyncio.to_thread(call, self.endpoint['socket'], dict(run, command='probe.remote', tab=tab,
            request=dict(action='mouse', lease=lease, generation=newer['generation'], type='mouseReleased',
                         button='left', buttons=0, clickCount=1, **point)), False)
        assert 'changed' in stale, stale
        state = await self.request(run, 'probe.remote-state', tab=tab)
        assert state['pressed'] is False, state
        await self.request(run, 'probe.remote-control', tab=tab)
        actual = await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate',
            params={'expression': 'window.remoteMouseUps', 'returnByValue': True})
        assert actual['result']['value'] == 1, actual
        self.passed('stale pointer release ends the Host pointer gesture without dropping control')

        await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate',
            params={'expression': 'window.remoteMouseUps=0'})
        shot = await frame()
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
        await remote(action='fit', lease=lease, generation=shot['generation'],
                     width=int(shot['width']), height=int(shot['height']))
        newer = await frame()
        point = {'x': newer['width'] / 2, 'y': newer['height'] / 2}
        await remote(action='mouse', lease=lease, generation=newer['generation'], type='mousePressed',
                     button='left', buttons=1, clickCount=1, **point)
        stale = await asyncio.to_thread(call, self.endpoint['socket'], dict(run, command='probe.remote', tab=tab,
            request=dict(action='mouse', lease=lease, generation=shot['generation'], type='mouseReleased',
                         button='left', buttons=0, clickCount=1, **point)), False)
        assert 'changed' in stale, stale
        state = await self.request(run, 'probe.remote-state', tab=tab)
        assert state['pressed'] is True, state
        await remote(action='mouse', lease=lease, generation=newer['generation'], type='mouseReleased',
                     button='left', buttons=0, clickCount=1, **point)
        await self.request(run, 'probe.remote-control', tab=tab)
        actual = await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate',
            params={'expression': 'window.remoteMouseUps', 'returnByValue': True})
        assert actual['result']['value'] == 1, actual
        self.passed('an older stale release cannot end a newer Host pointer gesture')

        await evaluate("window.remoteKeys=[];document.addEventListener('keydown',e=>remoteKeys.push({key:e.key,trusted:e.isTrusted}))")
        shot = await frame()
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
        for modifiers in (0, 8):
            await remote(action='key', lease=lease, generation=shot['generation'], key='Tab', keyCode=9, modifiers=modifiers)
        await remote(action='mouse', lease=lease, generation=shot['generation'], type='mouseWheel',
                     x=shot['width'] / 2, y=shot['height'] / 2, deltaX=0, deltaY=360)
        await self.request(run, 'probe.remote-control', tab=tab)
        async def scrolled():
            return await evaluate('scrollY') > 0
        await self.wait(scrolled, 5)
        keys = await evaluate('remoteKeys')
        assert [key['key'] for key in keys] == ['Tab', 'Tab'] and all(key['trusted'] for key in keys), keys
        await evaluate('scrollTo(0,0)')
        self.passed('remote wheel scrolling and trusted Tab/Shift+Tab keyboard input are unchanged')

        shot = await frame()
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
        await remote(action='fit', lease=lease, generation=shot['generation'], width=390, height=700)
        await asyncio.sleep(.25)
        newer = await frame()
        assert newer['width'] == 390 and newer['height'] == 700 and newer['generation'] != shot['generation']
        await self.request(run, 'probe.remote-control', tab=tab)
        rect = await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate',
            params={'expression': "JSON.stringify((()=>{const r=document.querySelector('#message').getBoundingClientRect();return {x:r.x+8,y:r.y+8}})())", 'returnByValue': True})
        point = json.loads(rect['result']['value'])
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
        for event, buttons in [('mousePressed', 1), ('mouseReleased', 0)]:
            await remote(action='mouse', lease=lease, generation=newer['generation'], type=event,
                         button='left', buttons=buttons, clickCount=1, **point)
        await remote(action='key', lease=lease, generation=newer['generation'], key='a', keyCode=65, modifiers=4)
        await remote(action='text', lease=lease, generation=newer['generation'], text='Fit 中文')
        stale = await asyncio.to_thread(call, self.endpoint['socket'], dict(run, command='probe.remote', tab=tab,
            request=dict(action='text', lease=lease, generation=shot['generation'], text='MUST NOT TYPE')), False)
        assert 'changed' in stale
        await self.request(run, 'probe.remote-control', tab=tab)
        assert await evaluate('document.querySelector("#message").value') == 'Fit 中文'
        stale = await asyncio.to_thread(call, self.endpoint['socket'], dict(run, command='probe.remote', tab=tab,
            request=dict(action='text', lease=lease, generation=newer['generation'], text='MUST NOT TYPE')), False)
        assert 'expired' in stale
        self.passed('explicit fit changes viewport; stale geometry and released control reject input')

        await evaluate("""const style=document.createElement('style');style.textContent=`
          html{overflow:scroll} body{min-width:1400px;min-height:4000px}
          ::-webkit-scrollbar{width:16px;height:16px}
          ::-webkit-scrollbar-thumb{background:#555}
          #remote-click-target{position:fixed;right:24px;bottom:30px;width:16px;height:16px;
            border:0;padding:0;background:rgb(255,0,160)}`;
          document.head.append(style);const target=document.createElement('button');
          target.id='remote-click-target';window.remoteTargetClicks=0;
          target.onclick=e=>{if(e.isTrusted)window.remoteTargetClicks++};document.body.append(target);
          scrollTo(0,0);""")
        cases = ((700, 829, 1, 1), (700, 829, 1.5, 1), (700, 829, 1, 1.5), (390, 700, 1, 1))
        for index, (width, height, zoom, pinch) in enumerate(cases):
            if index:
                await self.request(run, 'probe.zoom', tab=tab, factor=zoom)
                await self.request(run, 'probe.cdp', tab=tab, method='Emulation.setPageScaleFactor',
                                   params={'pageScaleFactor': pinch})
            shot = await frame()
            assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
            await remote(action='fit', lease=lease, generation=shot['generation'], width=width, height=height)
            await self.request(run, 'probe.remote-control', tab=tab)
            await asyncio.sleep(.3)
            metrics = await self.request(run, 'probe.cdp', tab=tab, method='Page.getLayoutMetrics')
            assert metrics['cssVisualViewport']['clientWidth'] < width / zoom / pinch, metrics
            assert metrics['cssVisualViewport']['clientHeight'] < height / zoom / pinch, metrics
            await evaluate("""Object.assign(document.querySelector('#remote-click-target').style,{
                left:(visualViewport.offsetLeft+visualViewport.width-40)+'px',
                top:(visualViewport.offsetTop+visualViewport.height-46)+'px',right:'auto',bottom:'auto'})""")
            shot = await frame(2560 if index % 2 == 0 else 768)
            image = Image.open(io.BytesIO(base64.b64decode(shot['jpeg']))).convert('RGB')
            red, green, blue = image.split()
            mask = ImageChops.multiply(red.point(lambda v: 255 if v > 220 else 0),
                                      green.point(lambda v: 255 if v < 60 else 0))
            mask = ImageChops.multiply(mask, blue.point(lambda v: 255 if v > 130 else 0))
            bounds = mask.getbbox()
            assert bounds is not None, 'Screenshot is missing the click target'
            # Locate only from the JPEG, then follow RemoteBrowserGeometry's
            # imageRect/pagePoint mapping through a letterboxed Viewer canvas.
            scale = min(390 / shot['width'], 700 / shot['height'])
            displayed_width, displayed_height = shot['width'] * scale, shot['height'] * scale
            left, top = (390 - displayed_width) / 2, (700 - displayed_height) / 2
            viewer_x = left + (bounds[0] + bounds[2]) / 2 / image.width * displayed_width
            viewer_y = top + (bounds[1] + bounds[3]) / 2 / image.height * displayed_height
            point = {'x': (viewer_x - left) / scale, 'y': (viewer_y - top) / scale}
            before = await evaluate('remoteTargetClicks')
            assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
            for event, buttons in [('mousePressed', 1), ('mouseReleased', 0)]:
                await remote(action='mouse', lease=lease, generation=shot['generation'], type=event,
                             button='left', buttons=buttons, clickCount=1, **point)
            await self.request(run, 'probe.remote-control', tab=tab)
            assert await evaluate('remoteTargetClicks') == before + 1, (width, height, zoom, pinch, shot['width'], shot['height'], point)
            assert abs(shot['width'] - width / zoom / pinch) < 1 and abs(shot['height'] - height / zoom / pinch) < 1, shot
            self.passed(f'screenshot-position click with both scrollbars: {width}x{height}, zoom={zoom}, pinch={pinch}')
        assert len(await self.request(other, 'tabs')) == 1
        await self.control('ping')


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('engine', type=Path)
    parser.add_argument('identity', type=Path)
    args = parser.parse_args()
    args.app, args.engine, args.identity = (p.resolve() for p in (args.app, args.engine, args.identity))
    test = RemoteBrowser(args)
    await test.run()
    assert test.host.returncode == 0


if __name__ == '__main__':
    asyncio.run(main())
