#!/usr/bin/env python3
"""Native select-menu acceptance in the isolated signed probe app only."""
import argparse
import asyncio
import base64
from pathlib import Path
import uuid

from integration import call
from managed_engine import Managed


class SelectMenus(Managed):
    mock_keychain = True

    async def validate(self, _):
        run, other = self.runs
        tab = self.tabs[0]

        async def evaluate(script):
            result = await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate',
                                        params={'expression': script, 'returnByValue': True})
            assert not result.get('exceptionDetails'), result
            return result['result'].get('value')

        async def remote(ok=True, **request):
            if ok:
                return await self.request(run, 'probe.remote', tab=tab, request=request)
            return await asyncio.to_thread(call, self.endpoint['socket'],
                                           dict(run, command='probe.remote', tab=tab, request=request), False)

        await evaluate("""document.body.innerHTML='<h1>Remote select fixture</h1>'+
          '<select id="jump" aria-label="跳到条目"></select><button id="ordinary">Ordinary</button>';
          for(let i=0;i<8;i++){const o=new Option('第 '+(i+1)+' 条',String(i));o.disabled=i===2;jump.append(o);}
          jump.style.cssText='width:240px;height:40px';
          window.selectEvents=[];window.normalClicks=0;
          document.addEventListener('input',e=>{if(e.target.id==='jump')selectEvents.push([e.type,e.isTrusted]);});
          document.addEventListener('change',e=>{if(e.target.id==='jump')selectEvents.push([e.type,e.isTrusted]);});
          ordinary.onclick=e=>{normalClicks++;window.normalTrusted=e.isTrusted};""")
        lease = None

        async def acquire():
            nonlocal lease
            lease = str(uuid.uuid4())
            assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']

        async def release():
            nonlocal lease
            await self.request(run, 'probe.remote-control', tab=tab)
            lease = None

        async def coordinates(selector):
            assert lease is None, 'Fixture scripting must not bypass human control'
            return await evaluate(f"(()=>{{const r=document.querySelector({selector!r}).getBoundingClientRect();return {{x:r.x+8,y:r.y+8}}}})()")

        async def pointer(point, kind, opt_in=True):
            shot = await remote(action='frame')
            request = dict(action='mouse', lease=lease, generation=shot['generation'], type=kind,
                           button='left', buttons=1 if kind == 'mousePressed' else 0, clickCount=1, **point)
            if opt_in:
                request['selectMenus'] = True
            return await remote(**request)

        async def open_menu(mutation=None, release_pointer=True):
            assert lease is None
            await evaluate('jump.blur()')
            if mutation:
                # Mutate at the microtask checkpoint after the Host captured
                # its snapshot, without relying on background timer scheduling.
                await evaluate("jump.focus=function(options){delete this.focus;HTMLElement.prototype.focus.call(this,options);queueMicrotask(()=>{" + mutation + "})}")
            point = await coordinates('#jump')
            await acquire()
            result = await pointer(point, 'mousePressed')
            menu = result['selectMenu']
            if release_pointer:
                await pointer(point, 'mouseReleased')
            assert len(menu['options']) == 8 and menu['title'] == '跳到条目', menu
            assert menu['options'][2]['disabled'] and menu['options'][7]['text'] == '第 8 条', menu
            return menu

        async def choose(menu, index=None, ok=True, **overrides):
            request = dict(action='select', lease=lease, generation=menu['generation'], menuID=menu['id'])
            if index is not None:
                request['index'] = index
            request.update(overrides)
            return await remote(ok=ok, **request)

        menu = await open_menu(release_pointer=False)
        assert menu['options'][0]['selected']
        await choose(menu, 7)
        assert 'expired' in await choose(menu, 0, ok=False)
        await release()
        assert await evaluate('jump.value') == '7'
        assert await evaluate('selectEvents') == [['input', False], ['change', False]]
        assert await evaluate('selectEvents.length') == 2
        self.passed('eight native options, select eighth, input/change once, replay refused')

        menu = await open_menu()
        await choose(menu)
        assert 'expired' in await choose(menu, 0, ok=False)
        await release()
        assert await evaluate('jump.value') == '7'
        self.passed('cancel leaves value unchanged and consumes the menu')

        menu = await open_menu()
        assert 'unavailable' in await choose(menu, 2, ok=False)
        await release()
        assert await evaluate('jump.value') == '7'
        self.passed('disabled option cannot be applied')

        menu = await open_menu('const original=jump,replacement=original.cloneNode(true);replacement.value=original.value;original.replaceWith(replacement)')
        assert 'changed' in await choose(menu, 0, ok=False)
        await release()
        assert await evaluate('jump.value') == '7'
        self.passed('same-ID replacement control never receives an old menu selection')

        menu = await open_menu("jump.options[0].value='changed'")
        assert 'changed' in await choose(menu, 0, ok=False)
        await release()
        assert await evaluate('jump.value') == '7'
        self.passed('changed options invalidate the captured list')

        menu = await open_menu("jump.style.display='none'")
        assert 'changed' in await choose(menu, 0, ok=False)
        await release()
        assert await evaluate('jump.value') == '7'
        await evaluate("jump.style.display='inline-block'")
        self.passed('a hidden control cannot receive an old menu selection')

        menu = await open_menu()
        assert 'Page changed' in await choose(menu, 0, ok=False, generation=menu['generation'] - 1)
        await choose(menu)
        await release()
        self.passed('stale geometry cannot submit a menu selection')

        menu = await open_menu()
        old_lease = lease
        await release()
        lease = old_lease
        assert 'Control expired' in await choose(menu, 0, ok=False)
        await acquire()
        error = await choose(menu, 0, ok=False)
        assert 'expired' in error or 'Page changed' in error, error
        await release()
        self.passed('release and reacquisition cannot reuse the previous menu')

        point = await coordinates('#ordinary')
        await acquire()
        for opt_in in (False, True):
            await pointer(point, 'mousePressed', opt_in)
            await pointer(point, 'mouseReleased', opt_in)
        await release()
        assert await evaluate('normalClicks') == 2
        assert await evaluate('normalTrusted') is True
        self.passed('ordinary clicks remain trusted and single with and without select opt-in')

        await evaluate("""const label=document.createElement('label');label.htmlFor='jump';
          label.innerHTML='<span id="label-text">Choose</span> <a id="label-help" href="#help"><span id="label-help-text">Help</span></a> <button id="label-button" type="button"><span id="label-button-text">Details</span></button> ';
          const details=document.createElement('details');details.open=true;
          jump.before(details);details.append(label);
          window.labelClicks=[];
          for(const id of ['label-help','label-button'])document.getElementById(id).onclick=e=>{
            e.preventDefault();labelClicks.push([id,e.isTrusted]);};""")
        for selector in ('#label-help-text', '#label-button-text'):
            point = await coordinates(selector)
            await acquire()
            result = await pointer(point, 'mousePressed')
            assert 'selectMenu' not in result, result
            await pointer(point, 'mouseReleased')
            await release()
        assert await evaluate('labelClicks') == [['label-help', True], ['label-button', True]]
        point = await coordinates('#label-text')
        await acquire()
        result = await pointer(point, 'mousePressed')
        assert len(result['selectMenu']['options']) == 8
        await pointer(point, 'mouseReleased')
        await choose(result['selectMenu'])
        await release()
        assert await evaluate('jump.value') == '7'
        self.passed('label links/buttons keep trusted clicks; plain label text still opens its select')

        await evaluate("""const shadow=document.createElement('div');shadow.id='shadow-host';
          shadow.attachShadow({mode:'open'}).innerHTML='<select aria-label="Shadow choice"><option value="a">A</option><option value="b">B</option></select>';
          shadow.shadowRoot.addEventListener('change',e=>window.shadowChoice=e.target.value);
          document.addEventListener('input',e=>{if(e.target.id==='shadow-host')window.shadowInput=true});
          document.body.append(shadow);""")
        async def shadow_menu(mutation=None):
            assert lease is None
            await evaluate("document.querySelector('#shadow-host').shadowRoot.querySelector('select').blur()")
            if mutation:
                await evaluate("document.querySelector('#shadow-host').shadowRoot.querySelector('select').focus=function(options){delete this.focus;HTMLElement.prototype.focus.call(this,options);queueMicrotask(()=>{" + mutation + "})}")
            point = await evaluate("(()=>{const r=document.querySelector('#shadow-host').shadowRoot.querySelector('select').getBoundingClientRect();return {x:r.x+8,y:r.y+8}})()")
            await acquire()
            shot = await remote(action='frame')
            request = dict(action='mouse', lease=lease, generation=shot['generation'], button='left',
                           clickCount=1, selectMenus=True, **point)
            opened = await remote(type='mousePressed', buttons=1, **request)
            await remote(type='mouseReleased', buttons=0, **request)
            return opened['selectMenu']
        menu = await shadow_menu()
        await choose(menu, 1)
        await release()
        assert await evaluate('shadowChoice') == 'b' and await evaluate('shadowInput') is True
        menu = await shadow_menu("document.querySelector('#shadow-host').inert=true")
        assert 'changed' in await choose(menu, 0, ok=False)
        await release()
        assert await evaluate("document.querySelector('#shadow-host').shadowRoot.querySelector('select').value") == 'b'
        self.passed('open shadow select works; inert shadow host invalidates its menu')
        shot = await remote(action='frame')
        (self.root / 'select-eighth.jpg').write_bytes(base64.b64decode(shot['jpeg']))
        assert len(await self.request(other, 'tabs')) == 1
        await self.control('ping')


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('engine', type=Path)
    parser.add_argument('identity', type=Path)
    args = parser.parse_args()
    args.app, args.engine, args.identity = (p.resolve() for p in (args.app, args.engine, args.identity))
    test = SelectMenus(args)
    await test.run()
    assert test.host.returncode == 0


if __name__ == '__main__':
    asyncio.run(main())
