"""Real CEF action regressions, called by integration.py against a private fixture."""
import concurrent.futures
import time

PAGE = '''<!doctype html><meta charset="utf-8"><title>Page actions</title>
<style>#box{height:80px;width:250px;overflow:auto}#inside{height:500px;width:800px}
#long{white-space:pre-wrap}.hidden{display:none}</style>
<section id="form"><input id="text" value="original"><input id="email" type="email" value="old@example.test">
<textarea id="multi">original lines</textarea><input id="password" type="password" value="never-return-password">
<input id="file" type="file"><input type="hidden" value="never-return-hidden">
<input id="readonly" readonly value="read only"><input id="disabled" disabled>
<button id="apply">Apply</button><button class="ambiguous">one</button><button class="ambiguous">two</button>
<input id="check" type="checkbox"><input id="radio" name="radios" type="radio"><input id="radio2" name="radios" type="radio">
<input id="mixed" type="checkbox">
<select id="select"><option value="a">Alpha</option><option value="b">Beta</option>
<option value="no" disabled>Disabled</option><optgroup disabled><option value="group">Disabled group</option></optgroup></select>
<select id="multiple" multiple><option value="a">Alpha</option></select>
<p id="input-events"></p><p id="key-event"></p><p id="check-events">0</p><p id="select-events">0</p>
<button id="schedule">Schedule</button><p id="delayed" class="hidden">pending</p><p id="vanish">present</p>
<button id="enable" disabled>pending</button><button id="navigate">Navigate later</button>
<button id="block">Block renderer briefly</button>
</section>
<div id="box"><div id="inside">scroll me</div></div><section id="many"></section><p id="long"></p>
<script>
if(location.search==='?arrived'){const p=document.createElement('p');p.id='arrived';p.textContent='navigation complete';document.body.append(p)}
document.querySelector('#long').textContent='pagination-proof-'.repeat(1500);
for(let i=0;i<105;i++){const b=document.createElement('button');b.id='many-'+i;b.textContent='Control '+i;document.querySelector('#many').append(b)}
document.querySelector('#mixed').indeterminate=true;
for(const id of ['text','email','multi'])document.getElementById(id).oninput=e=>document.querySelector('#input-events').textContent='trusted='+e.isTrusted;
document.querySelector('#text').onkeydown=e=>document.querySelector('#key-event').textContent=e.key+'; shift='+e.shiftKey+'; trusted='+e.isTrusted;
let checked=0;document.querySelector('#check').onchange=e=>document.querySelector('#check-events').textContent=++checked+'; trusted='+e.isTrusted;
let selected=0;document.querySelector('#select').onchange=e=>document.querySelector('#select-events').textContent=++selected+'; trusted='+e.isTrusted;
document.querySelector('#schedule').onclick=()=>{setTimeout(()=>{
document.querySelector('#delayed').className='';document.querySelector('#delayed').textContent='finished';
document.querySelector('#vanish').remove();document.querySelector('#enable').disabled=false;},450)};
document.querySelector('#navigate').onclick=()=>setTimeout(()=>location.href='/actions?arrived',250);
document.querySelector('#block').onclick=()=>setTimeout(()=>{const end=Date.now()+1500;while(Date.now()<end){}},100);
</script>'''.encode()


def verify(request, a, b, url):
    tab = request(a, 'open', url=url + 'actions')['id']
    def action(command, ok=True, **params):
        return request(a, command, ok=ok, tab=tab, **params)
    def read(selector, **params):
        return action('read', selector=selector, **params)
    def value(selector):
        return read(selector)['controls'][0]['value']
    action('wait')
    assert action('wait', timeoutMs=100)['matched'] # already-ready page must work at minimum timeout
    targets = action('read')['controls']
    assert next(c for c in targets if c['selector'] == '#vanish')['kind'] == 'region'
    assert next(c for c in targets if c['selector'] == '#box')['scroll']['maxY'] == 420
    # Every new verb obeys the same ownership gate, even before validation.
    for op in ('fill', 'press', 'scroll', 'wait', 'select', 'check'):
        error = request(b, op, ok=False, tab=tab)
        assert 'another instance' in error, (op, error)
    for selector, text in (('#text', 'replacement 中文'), ('#email', 'new@example.test'), ('#multi', 'line one\n第二行')):
        action('fill', selector=selector, text=text)
        assert value(selector) == text, (selector, value(selector))
        assert 'trusted=true' in read('#input-events')['text']
        action('fill', selector=selector, text='')
        assert value(selector) == '', (selector, value(selector))
    action('type', selector='#text', text='insert')
    action('type', selector='#text', text=' more')
    assert value('#text') == 'insert more'
    action('press', selector='#text', key='Enter')
    assert read('#key-event')['text'] == 'Enter; shift=false; trusted=true'
    action('press', selector='#text', key='Tab')
    assert read('#email')['controls'][0]['focused']
    action('press', key='Shift+Tab')
    assert read('#text')['controls'][0]['focused']
    action('press', key='Meta+A')
    action('type', selector='#text', text='abc')
    assert value('#text') == 'abc'
    action('press', key='ArrowLeft')
    action('press', key='Backspace')
    assert value('#text') == 'ac', value('#text')
    for key in ('Meta+V', 'Meta+Q', 'A', 'Ctrl+Control+A'):
        action('press', ok=False, key=key)
    for selector in ('#password', '#file', '#readonly', '#disabled', '.ambiguous', '#absent'):
        action('fill', ok=False, selector=selector, text='do not insert')
    form = read('#form')
    assert 'never-return' not in str(form)
    assert all('value' not in c for c in form['controls'] if c['type'] in ('password', 'file', 'hidden'))
    assert read('#readonly')['controls'][0]['readOnly']
    assert read('#disabled')['controls'][0]['disabled']
    assert action('check', selector='#check', checked=True) == dict(checked=True, changed=True)
    assert action('check', selector='#check', checked=True) == dict(checked=True, changed=False)
    assert read('#check-events')['text'] == '1; trusted=true'
    assert read('#check')['controls'][0]['checked']
    action('check', selector='#check', checked=False)
    assert read('#check-events')['text'] == '2; trusted=true'
    action('check', selector='#radio', checked=True)
    action('check', selector='#radio', checked=False, ok=False)
    action('check', selector='#radio2', checked=True)
    assert not read('#radio')['controls'][0]['checked']
    action('check', selector='#mixed', checked=False, ok=False)
    action('check', selector='#mixed', checked=True)
    action('check', selector='#check', checked=1, ok=False)
    action('check', selector='#text', checked=True, ok=False)
    assert action('select', selector='#select', value='b') == dict(value='b', changed=True)
    assert action('select', selector='#select', value='b') == dict(value='b', changed=False)
    assert read('#select-events')['text'] == '1; trusted=false'
    options = read('#select')['controls'][0]
    assert options['value'] == 'b' and options['options'][1]['selected']
    assert options['options'][2]['disabled'] and options['options'][3]['disabled']
    for option in ('no', 'group', 'absent'):
        action('select', selector='#select', value=option, ok=False)
    action('select', selector='#multiple', value='a', ok=False)
    page1 = read('#long')
    page2 = read('#long', textOffset=page1['nextTextOffset'])
    assert page1['text'] + page2['text'] == 'pagination-proof-' * 1500
    assert page2['nextTextOffset'] is None
    controls1 = read('#many')
    controls2 = read('#many', controlOffset=controls1['nextControlOffset'])
    assert len(controls1['controls']) == 100 and len(controls2['controls']) == 6 # root region + 105 buttons
    assert controls2['controls'][-1]['selector'] == '#many-104' and controls2['nextControlOffset'] is None
    for params in (dict(textLimit=0), dict(textOffset=-1), dict(controlLimit=101), dict(textLimit=True), dict(textLimit=1.5)):
        action('read', ok=False, **params)
    scroll = action('scroll', selector='#box', deltaY=120, deltaX=80)
    assert scroll['changed'] and scroll['x'] == 80 and scroll['y'] == 120, scroll
    scroll = action('scroll', selector='#box', deltaY=-120, deltaX=-80)
    assert scroll['x'] == scroll['y'] == 0
    action('scroll', deltaY=-10000)
    assert action('scroll', deltaY=100)['y'] == 100
    action('scroll', deltaY=0, ok=False)
    action('scroll', deltaY=10001, ok=False)
    action('wait', selector='#delayed', state='attached')
    action('wait', selector='#delayed', state='hidden')
    action('wait', selector='#absent', state='hidden')
    action('wait', selector='#delayed', timeoutMs=150, ok=False)
    action('wait', selector='[broken', ok=False)
    action('wait', selector='.ambiguous', ok=False)
    for params in (dict(timeoutMs=10001), dict(state='unknown'), dict(state='enabled'),
                   dict(state='ready', selector='#text'), dict(state='hidden', selector='#text', text='no')):
        action('wait', ok=False, **params)
    action('click', selector='#schedule')
    assert action('wait', selector='#delayed', text='finished')['matched']
    action('wait', selector='#vanish', state='hidden')
    action('wait', selector='#enable', state='enabled')
    # A pending wait is nonblocking for other tabs, but serializes its own tab.
    with concurrent.futures.ThreadPoolExecutor() as pool:
        pending = pool.submit(action, 'wait', selector='#absent', timeoutMs=800, ok=False)
        time.sleep(.15)
        assert 'busy' in action('read', ok=False)
        assert request(b, 'tabs')
        assert 'timed out' in pending.result()
    action('click', selector='#block')
    began = time.monotonic()
    assert 'timed out' in action('wait', selector='#absent', timeoutMs=300, ok=False)
    assert time.monotonic() - began < 1, 'Renderer must not prevent the native wait deadline'
    assert request(b, 'tabs')
    action('wait') # renderer becomes responsive again; old pending results must be ignored
    action('click', selector='#navigate')
    # Follow navigation of the same owned tab, never accept a stale DOM result.
    action('wait', selector='#arrived', text='navigation complete', timeoutMs=3000)
    action('wait')
    assert '?arrived' in action('read')['url']
    action('close')
    print('PASS: fill/clear/insert, page keys, read pagination/redaction, idempotent forms, scroll, waits/navigation, ownership/bounds', flush=True)
