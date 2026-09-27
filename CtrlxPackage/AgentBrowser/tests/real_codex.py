#!/usr/bin/env python3
"""Opt-in acceptance using actual Codex, the packaged CLI/skill and local pages.

Consumes Codex quota. Leaves logs/screenshots in a private temporary directory.
Uses the normal CtrlX Agent Browser profile (never the system Chrome profile).
Does not install plugins, change Codex config, or read any authentication files.
"""
import argparse
import http.server
import json
import os
import re
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path, help='Signed complete CtrlX.app')
    parser.add_argument('--codex', default='codex')
    parser.add_argument('--manual-ui', action='store_true', help='Pause A for native manual-tab assignment')
    options = parser.parse_args()
    app = options.app.resolve()
    cli = app / 'Contents/MacOS/CtrlXCLI'
    skill = app / 'Contents/Resources/plugin/codex/ctrlx/skills/agent-browser'
    assert cli.is_file() and (skill / 'SKILL.md').is_file()
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    codex = shutil.which(options.codex)
    assert codex
    root = Path(tempfile.mkdtemp(prefix='ctrlx-real-codex-'))
    nonce = uuid.uuid4().hex[:12]
    records = []
    lock = threading.Lock()
    print(f'Artifacts: {root}', flush=True)

    class Fixture(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/favicon.ico':
                self.send_error(404)
                return
            role = self.path.split('?')[0].strip('/') or 'Manual'
            if role not in ('A', 'B', 'child', 'Manual'):
                self.send_error(404)
                return
            cookie_key = 'ctrlx_acceptance_' + nonce
            page = '''<!doctype html><meta charset="utf-8">
<style>body{font:20px system-ui;padding:32px;background:#f6f8ff;color:#152749}
button,input{font:inherit;padding:12px;margin:8px}p{padding:12px;background:white}</style>
<title>Real Codex ROLE</title><h1>Real Codex ROLE</h1><p>Fixture NONCE</p>
<input id="message" aria-label="Message" value="draft to replace"><button id="apply">Apply</button>
<input id="check" type="checkbox" aria-label="Enable proof">
<select id="choice" aria-label="Choice"><option value="a">Alpha</option><option value="b">Beta</option></select>
<div id="scroll-box" style="height:60px;overflow:auto"><div style="height:400px">Scroll proof</div></div>
<button id="login">Fixture login</button><a id="child" href="/child" target="_blank">Open child</a>
<p id="result">Not submitted</p><p id="state"></p>
<script>
const key='COOKIE_KEY';let inputTrusted=false;
function state(){document.querySelector('#state').textContent='Shared login: '+
 (document.cookie.includes(key+'=signed-in')&&localStorage.getItem(key)==='signed-in'?'signed-in':'none')}
function record(data){fetch('/record',{method:'POST',body:JSON.stringify({role:'ROLE',...data})})}
state();record({kind:'load',shared:document.querySelector('#state').textContent});
document.querySelector('#message').oninput=e=>{inputTrusted=e.isTrusted};
document.querySelector('#message').onkeydown=e=>record({kind:'key',key:e.key,trusted:e.isTrusted});
document.querySelector('#check').onchange=e=>record({kind:'check',checked:e.target.checked,trusted:e.isTrusted});
document.querySelector('#choice').onchange=e=>record({kind:'select',value:e.target.value,trusted:e.isTrusted});
document.querySelector('#scroll-box').onscroll=e=>record({kind:'scroll',y:e.target.scrollTop});
document.querySelector('#apply').onclick=e=>{const value=document.querySelector('#message').value;
 const result=value+'; clickTrusted='+e.isTrusted+'; inputTrusted='+inputTrusted;
 setTimeout(()=>document.querySelector('#result').textContent=result,250);
 record({kind:'apply',value,clickTrusted:e.isTrusted,inputTrusted})};
document.querySelector('#login').onclick=e=>{document.cookie=key+'=signed-in; Path=/; Max-Age=3600';
 localStorage.setItem(key,'signed-in');state();record({kind:'login',trusted:e.isTrusted})};
</script>'''.replace('ROLE', role).replace('NONCE', nonce).replace('COOKIE_KEY', cookie_key)
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(page.encode())

        def do_POST(self):
            if self.path != '/record':
                self.send_error(404)
                return
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 4096:
                self.send_error(400)
                return
            data = json.loads(self.rfile.read(length))
            with lock:
                records.append(data)
                with (root / 'fixture-events.jsonl').open('a') as output:
                    output.write(json.dumps(data, ensure_ascii=False) + '\n')
            self.send_response(204)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    print('Manual fixture:', base + '/Manual', flush=True)
    (root / 'manual-url.txt').write_text(base + '/Manual')
    processes = []

    def start(role, extra):
        directory = root / role
        directory.mkdir()
        shutil.copytree(skill, directory / '.agents/skills/agent-browser')
        prompt = f'''Use the $agent-browser skill at .agents/skills/agent-browser/SKILL.md.
You are actual Codex acceptance instance {role}. Use ONLY the CtrlX Agent Browser
through the packaged CLI {cli} browser action. Do not use system Chrome, MCP,
Playwright, raw CDP, HTTP clients, JavaScript evaluation or other browser tools.
The pages at {base} are our own harmless test fixture, including its fake login.
Read the skill first. Use the full quoted CLI path, not any installed older ctrlx.
Do not change app code, settings or profiles. Never print environment/context secrets.
Open {base}/{role}, wait until ready, read the page. Use fill to REPLACE the
Message draft with "temporary draft", press Meta+A on that field, then type
"真实 Codex {role} {nonce}". Click Apply, use wait on Result text to await the
asynchronous update, read back and verify clickTrusted=true and inputTrusted=true.
Use selectors returned by read. Read the checkbox and select state. Use check to
set the checkbox true TWICE (second call must return changed=false); use select
to choose Beta by its observed option value. Use scroll on the Scroll proof
container to scroll down 120 pixels; confirm the returned y is 120. Use read
with a selector to recheck checkbox/selection, and read with --text-limit 30
then --text-offset from nextTextOffset to demonstrate pagination.
Use selectors returned in read.controls, including its readable regions and
scroll containers. Do not guess selectors or use arbitrary evaluation.
Take a screenshot of your submitted page to {directory}/proof.png.
{extra}
Capture the actual CLI tabs JSON to {directory}/tabs.json; leave your tabs open.
Capture `{cli} browser identity` JSON to {directory}/identity.json.
This is an ordinary Codex launch without a browser wrapper or context env var.
Write {directory}/ready only when the above operations have genuinely succeeded.
Then run a bounded wait for {directory}/finish (up to 900 seconds); do not finish
your turn until it exists. Do not modify this gate yourself.
After the gate opens, capture tabs again to {directory}/final-tabs.json and report
what succeeded, any errors, and the exact tab IDs. Do not claim unobserved success.
'''
        (directory / 'prompt.txt').write_text(prompt)
        env = dict(os.environ)
        for key in ('CTRLX_BROWSER_CONTEXT', 'CODEX_THREAD_ID', 'CODEX_TURN_ID', 'TMUX', 'TMUX_PANE'):
            env.pop(key, None)
        process = subprocess.Popen([
            codex,
            'exec', '--ephemeral', '--skip-git-repo-check', '--json', '--color', 'never',
            '--sandbox', 'danger-full-access', '-c', 'model_reasoning_effort="low"',
            '-C', str(directory), '-o', str(directory / 'result.md'), prompt,
        ], env=env, stdin=subprocess.DEVNULL,
            stdout=(directory / 'events.jsonl').open('wb'), stderr=(directory / 'stderr.log').open('wb'))
        processes.append(process)
        print(f'Codex {role}: PID {process.pid}', flush=True)
        return process, directory

    def wait_ready(process, directory):
        deadline = time.monotonic() + 420
        last_report = 0
        while time.monotonic() < deadline:
            assert process.poll() is None, f'{directory.name} exited early; inspect {directory}/result.md'
            if (directory / 'ready').exists():
                return json.loads((directory / 'tabs.json').read_text())['result']
            if time.monotonic() - last_report > 30:
                print(f'Waiting for Codex {directory.name}; fixture events={len(records)}', flush=True)
                last_report = time.monotonic()
            time.sleep(.5)
        raise AssertionError(f'Codex {directory.name} did not finish browser operations in 7 minutes')

    try:
        a, ad = start('A', 'Also click Fixture login, then Open child, and verify tabs lists both your pages.')
        tabs_a = wait_ready(a, ad)
        identity_a = json.loads((ad / 'identity.json').read_text())
        assert identity_a['pid'] == a.pid, identity_a
        assert len(tabs_a) == 2, tabs_a
        first = next(tab['id'] for tab in tabs_a if tab['url'] == base + '/A')
        b, bd = start('B', f'''Before changing the fixture login, verify this page already says
Shared login: signed-in from instance A. Save the CLI read response to shared.json.
As an authorized read-only negative ownership test, try reading A's tab {first}.
It must fail (do not repeat or try other identities); save stderr to refused.txt
and its nonzero exit status to refused-status.txt. Do not edit contexts.
Your tabs list must contain only your single B page, not A or Manual.''')
        tabs_b = wait_ready(b, bd)
        identity_b = json.loads((bd / 'identity.json').read_text())
        assert identity_b['pid'] == b.pid and identity_a['runtime'] != identity_b['runtime'], identity_b
        assert len(tabs_b) == 1 and tabs_b[0]['url'] == base + '/B', tabs_b
        assert int((bd / 'refused-status.txt').read_text().strip()) != 0
        assert 'signed-in' in (bd / 'shared.json').read_text()
        assert not {tab['id'] for tab in tabs_a} & {tab['id'] for tab in tabs_b}
        for role in ('A', 'B'):
            events = [json.loads(line) for line in (root / role / 'events.jsonl').read_text().splitlines()]
            commands = [e['item'].get('command', '') for e in events if e.get('type') == 'item.completed'
                        and e.get('item', {}).get('type') == 'command_execution' and e['item'].get('exit_code') == 0]
            for operation in ('open', 'wait', 'read', 'fill', 'press', 'type', 'click', 'check', 'select', 'scroll', 'screenshot', 'tabs'):
                assert any(re.search(r'\bbrowser action ' + operation + r'\b', command) for command in commands), (role, operation)
            assert any('browser action wait' in command and '--text' in command for command in commands), role
            assert any('browser action read' in command and '--selector' in command for command in commands), role
            assert any('browser action read' in command and '--text-offset' in command for command in commands), role
            expected = f'真实 Codex {role} {nonce}'
            submissions = [event for event in records if event.get('role') == role and event.get('kind') == 'apply']
            assert len(submissions) == 1 and submissions[0] == dict(
                role=role, kind='apply', value=expected, clickTrusted=True, inputTrusted=True), submissions
            assert (root / role / 'proof.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
            changes = [e for e in records if e.get('role') == role and e.get('kind') == 'check']
            assert changes == [dict(role=role, kind='check', checked=True, trusted=True)], changes
            choices = [e for e in records if e.get('role') == role and e.get('kind') == 'select']
            assert choices == [dict(role=role, kind='select', value='b', trusted=False)], choices
            assert any(e.get('role') == role and e.get('kind') == 'key' and e.get('key') == 'a' and e.get('trusted') for e in records)
            assert any(e.get('role') == role and e.get('kind') == 'scroll' and e.get('y') == 120 for e in records)
        assert any(e.get('role') == 'B' and e.get('kind') == 'load' and e.get('shared') == 'Shared login: signed-in' for e in records)
        (bd / 'finish').touch()
        assert b.wait(timeout=120) == 0
        if options.manual_ui:
            print(f'UI GATE: create {base}/Manual in a Manual tab; assign it to A / Codex.', flush=True)
            print(f'Then create {root}/ui-done to continue.', flush=True)
            deadline = time.monotonic() + 300
            while not (root / 'ui-done').exists() and time.monotonic() < deadline:
                assert a.poll() is None, 'Codex A ended before UI assignment'
                time.sleep(.5)
            assert (root / 'ui-done').exists(), 'UI gate timed out'
        (ad / 'finish').touch()
        assert a.wait(timeout=120) == 0
        if options.manual_ui:
            final_tabs = json.loads((ad / 'final-tabs.json').read_text())['result']
            assert any(tab['url'] == base + '/Manual' for tab in final_tabs), final_tabs
        for directory in (ad, bd):
            # CLI ignores env credentials now. Test native revocation directly,
            # without accidentally binding the harness's own Codex ancestor.
            identity = json.loads((directory / 'identity.json').read_text())
            path = Path.home() / '.ctrlx/agent-browser/runs' / identity['runtime'] / 'context.json'
            context = json.loads(path.read_text())
            request = {key: context[key] for key in ('run', 'secret', 'epoch')}
            request['command'] = 'tabs'
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(15)
                connection.connect(context['socket'])
                connection.sendall(json.dumps(request).encode() + b'\n')
                response = connection.makefile('rb').readline(65536)
            result = json.loads(response)
            assert not result['ok'] and 'not authorized' in result.get('error', '').lower(), result
            (directory / 'expired-identity.txt').write_text(result['error'])
        proof = dict(result='PASS', codex=subprocess.check_output([codex, '--version'], text=True).strip(),
                     app=str(app), nonce=nonce, aTabs=tabs_a, bTabs=tabs_b, nativeAssignment=options.manual_ui,
                     checks=['bare codex launch', 'kernel caller identity', 'packaged skill', 'lazy launch', 'real trusted input', 'fill', 'press', 'wait',
                             'idempotent check', 'select', 'scroll', 'scoped/paginated read', 'child inheritance',
                             'concurrent instance isolation', 'shared fixture login', 'screenshots', 'exit revocation'])
        (root / 'acceptance.json').write_text(json.dumps(proof, indent=2, ensure_ascii=False))
        print('PASS: real Codex acceptance', flush=True)
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        server.shutdown()


if __name__ == '__main__':
    main()
