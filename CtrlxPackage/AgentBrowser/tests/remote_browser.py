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
import uuid
from pathlib import Path
from PIL import Image
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

        async def frame():
            value = await remote(action='frame')
            jpeg = base64.b64decode(value['jpeg'])
            assert len(jpeg) <= 180 * 1024 and value['width'] > 0 and value['height'] > 0
            image = Image.open(io.BytesIO(jpeg)).convert('RGB')
            assert image.width <= 1024 and image.height <= 1024
            assert len(image.resize((64, 64)).getcolors(4096)) > 10, 'Blank background frame'
            (self.root / 'remote-background.jpg').write_bytes(jpeg)
            return value

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

        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
        await remote(action='fit', lease=lease, generation=shot['generation'], width=390, height=700)
        await asyncio.sleep(.25)
        newer = await frame()
        assert newer['width'] == 390 and newer['height'] == 700 and newer['generation'] != shot['generation']
        stale = await asyncio.to_thread(call, self.endpoint['socket'], dict(run, command='probe.remote', tab=tab,
            request=dict(action='text', lease=lease, generation=shot['generation'], text='MUST NOT TYPE')), False)
        assert 'changed' in stale
        await self.request(run, 'probe.remote-control', tab=tab)
        stale = await asyncio.to_thread(call, self.endpoint['socket'], dict(run, command='probe.remote', tab=tab,
            request=dict(action='text', lease=lease, generation=newer['generation'], text='MUST NOT TYPE')), False)
        assert 'expired' in stale
        self.passed('explicit fit changes viewport; stale geometry and released control reject input')
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
