#!/usr/bin/env python3
"""Embedded-host acceptance. Own tmux server/profile; never restarts installed CtrlX.

Pass a signed test copy of CtrlX.app with a distinct bundle identifier. The host
and fixture remain running after the checks for native UI inspection; quit that
test app normally to finish. Any first-use Keychain prompt is user-operated.
"""
import argparse
import base64
import http.server
import json
import os
import plistlib
from pathlib import Path
import shlex
import subprocess
import tempfile
import threading
import time
import uuid
from urllib.parse import urlsplit
from integration import Fixture, call, wait_for
import page_actions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('identity', type=Path)
    parser.add_argument('--interactive-setup', action='store_true')
    parser.add_argument('--resume', type=Path, help='Resume this isolated host after initial authorization, without relaunching it')
    parser.add_argument('--restart-check', action='store_true', help='Check graceful restart, profile persistence and stale grants, then quit the isolated host')
    args = parser.parse_args()
    root = args.resume.resolve() if args.resume else Path(tempfile.mkdtemp(prefix='ctrlx-embedded-test-'))
    app = args.app.resolve()
    with (app / 'Contents/Info.plist').open('rb') as source:
        bundle_id = plistlib.load(source)['CFBundleIdentifier']
    assert bundle_id == 'com.ctrlx.embedded-acceptance', 'Use a separately signed acceptance copy, never the production app'
    prior = json.loads((root / 'fixture.json').read_text()) if args.resume else None
    if prior:
        assert Path(prior['app']).resolve() == app, 'Resume must target the same test app'
        command = subprocess.check_output(['ps', '-p', str(prior['pid']), '-o', 'command='], text=True).strip()
        words = shlex.split(command)
        assert words[0] == str(app / 'Contents/MacOS/CtrlX') and '--e2e-test' in words
        assert Path(words[words.index('--ctrlx-state-root') + 1]).resolve() == root, 'Not this isolated host'
        assert not (root / 'actions-started').exists(), 'Do not replay partially executed mutations; run a fresh fixture'
    print('Test state:', root, flush=True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', urlsplit(prior['url']).port if prior else 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}/'
    cli = app / 'Contents/MacOS/CtrlXCLI'
    tmux_socket = str(root / 'tmux.sock')
    shell_config = str(Path(__file__).resolve().parent / 'shell')
    api_socket = str(Path(tempfile.gettempdir()) / 'ctrlx-e2e.sock')
    # This socket belongs only to the repository's E2E app, never the normal app.
    class ExistingHost:
        def __init__(self, pid): self.pid = pid
        def poll(self):
            try: os.kill(self.pid, 0)
            except ProcessLookupError: return 0
            return None
        def wait(self):
            while self.poll() is None: time.sleep(.5)

    if prior:
        host = ExistingHost(prior['pid'])
    else:
        log = (root / 'host.log').open('wb')
        host = subprocess.Popen([str(app / 'Contents/MacOS/CtrlX'), '--e2e-test',
            '--tmux-socket', tmux_socket, '--ctrlx-state-root', str(root),
            '--zdotdir', shell_config], stdout=log, stderr=log,
            start_new_session=True)
    print('Test host PID:', host.pid, flush=True)
    (root / 'fixture.json').write_text(json.dumps({'pid': host.pid, 'url': url, 'app': str(app)}))

    def control(*words):
        result = subprocess.run([str(cli), *words, '--socket', api_socket, '--json'], capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, result.stderr
        value = json.loads(result.stdout)
        assert value['ok'], value
        return value['result']

    def endpoint_ready():
        assert host.poll() is None, 'Test host exited; inspect host.log'
        path = root / 'agent-browser/endpoint.json'
        return json.loads(path.read_text()) if path.exists() else None

    reports = Path.home() / 'Library/Logs/DiagnosticReports'
    known_reports = set(reports.glob('CtrlX*.ips'))

    def stop_host():
        subprocess.run(['osascript', '-e', 'with timeout of 8 seconds', '-e',
            f'tell application id "{bundle_id}" to quit', '-e', 'end timeout'], check=True, timeout=12)
        wait_for(lambda: host.poll() is not None, 20)
        assert not (root / 'agent-browser/endpoint.json').exists(), 'Control endpoint leaked on shutdown'
        # ReportCrash can write a Helper failure after a successful main exit.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            for report in set(reports.glob('CtrlX*.ips')) - known_reports:
                try: data = json.loads(report.read_text().split('\n', 1)[1])
                except (OSError, ValueError): continue
                identifier = data.get('bundleInfo', {}).get('CFBundleIdentifier', '')
                assert identifier != bundle_id and not identifier.startswith('com.ctrlx.agent-browser.helper'), f'New browser crash: {report.name}'
            time.sleep(.1)

    try:
        endpoint = wait_for(endpoint_ready, 30)
        print('Embedded endpoint ready', flush=True)
        subprocess.run([str(cli), 'wait-ready', '--socket', api_socket, '--timeout', '30'], check=True, capture_output=True)
        private = root / 'fixture-grants.json'
        saved = json.loads(private.read_text()) if prior and private.exists() else None
        runs = []
        for label in ['embedded-alpha', 'embedded-beta']:
            if not prior:
                result = control('new-session', '--name', label, '--path', str(root))
                print('Created test session:', result, flush=True)
            panes = control('list-panes', '--window', label + ':1')
            # Native tmux pane IDs are captured, never inferred from UI focus.
            pane = panes['panes'][0]['id']
            record = root / (label + '.json')
            if not prior:
                control('send', shlex.quote(str(args.identity.resolve())) + ' > ' + shlex.quote(str(record)), '--pane', pane, '--enter')
            run = wait_for(lambda: json.loads(record.read_text()) if record.exists() and record.stat().st_size else None)
            executable = subprocess.check_output(['ps', '-p', str(run['pid']), '-o', 'comm='], text=True).strip()
            assert executable == str(args.identity.resolve()), 'Test identity ended or PID was reused'
            if saved:
                run = saved['a' if label == 'embedded-alpha' else 'b']
                assert saved['endpoint'] == endpoint, 'Browser restarted; do not reuse old grants'
            else:
                run.update(run=str(uuid.uuid4()), secret=uuid.uuid4().hex + uuid.uuid4().hex, label=label)
                run.update(call(endpoint['socket'], dict(run, command='register')))
            runs.append(run)

        def request(run, command, ok=True, **params):
            return call(endpoint['socket'], dict(run, command=command, **params), ok)
        a, b = runs
        # Focus Beta first; Alpha's open must still be routed back to Alpha.
        control('select-session', 'embedded-beta')
        first = saved['first'] if saved else request(a, 'open', url=url + 'alpha')['id']
        second = saved['second'] if saved else request(b, 'open', url=url + 'beta')['id']
        if saved:
            # The fixture server stopped during the authorization pause.
            request(a, 'navigate', tab=first, url=url + 'alpha')
            request(b, 'navigate', tab=second, url=url + 'beta')
        # Preserve this private fixture's credentials BEFORE a possible system
        # authorization pause. Never print them or read production contexts.
        private.write_text(json.dumps({'endpoint': endpoint, 'a': a, 'b': b, 'first': first, 'second': second}))
        private.chmod(0o600)
        assert request(a, 'tabs')[0]['presentation']['session'] == 'embedded-alpha'
        assert request(b, 'tabs')[0]['presentation']['session'] == 'embedded-beta'
        for run in runs:
            for tab in request(run, 'tabs'):
                request(run, 'show', tab=tab['id'])
                wait_for(lambda: any(t['id'] == tab['id'] and t['presentation']['visible']
                                     for t in request(run, 'tabs')))
        print('Tabs opened. Any Keychain prompt must be handled by the user, not this test.', flush=True)
        ready = lambda: all(not tab['loading'] for run in runs for tab in request(run, 'tabs'))
        wait_for(ready, None if args.interactive_setup else 40)
        (root / 'actions-started').touch()
        request(b, 'read', ok=False, tab=first)
        request(a, 'type', tab=first, selector='#message', text='Embedded 中文')
        request(a, 'click', tab=first, selector='#apply')
        wait_for(lambda: 'Embedded 中文; trusted=true' in request(a, 'read', tab=first)['text'])
        request(a, 'click', tab=first, selector='#login')
        request(b, 'navigate', tab=second, url=url + 'shared')
        persisted_values = ['storage=persisted', 'persistent=fixture', 'session=fixture']
        wait_for(lambda: all(value in request(b, 'read', tab=second)['text'] for value in persisted_values))
        request(a, 'click', tab=first, selector='#child')
        wait_for(lambda: len(request(a, 'tabs')) == 2)
        assert len(request(b, 'tabs')) == 1
        picture = request(a, 'screenshot', tab=first)
        (root / 'page.png').write_bytes(base64.b64decode(picture['data']))
        page_actions.verify(request, a, b, url)
        wait_for(lambda: len(request(a, 'tabs')) == 2)
        child = next(tab for tab in request(a, 'tabs') if tab['id'] != first)
        assert child['presentation']['session'] == 'embedded-alpha'
        request(a, 'close', tab=child['id'])
        wait_for(lambda: len(request(a, 'tabs')) == 1)
        request(a, 'show', tab=first)
        wait_for(lambda: request(a, 'tabs')[0]['presentation']['visible'])
        assert 'Embedded 中文; trusted=true' in request(a, 'read', tab=first)['text']
        request(a, 'close', tab=first)
        wait_for(lambda: not request(a, 'tabs'))
        assert len(request(b, 'tabs')) == 1
        control('ping')
        checks = ['embedded-open', 'multi-session-routing', 'trusted-input', 'cross-run-denial',
                  'shared-profile', 'child-inheritance', 'bounded-page-actions', 'tab-close', 'reattach-keeps-DOM']
        if args.restart_check:
            stop_host()
            old_endpoint = endpoint
            log = (root / 'restart.log').open('wb')
            host = subprocess.Popen([str(app / 'Contents/MacOS/CtrlX'), '--e2e-test',
                '--tmux-socket', tmux_socket, '--ctrlx-state-root', str(root),
                '--zdotdir', shell_config], stdout=log, stderr=log,
                start_new_session=True)
            (root / 'fixture.json').write_text(json.dumps({'pid': host.pid, 'url': url, 'app': str(app)}))
            print('Restarted isolated host:', host.pid, flush=True)
            endpoint = wait_for(endpoint_ready, 30)
            assert endpoint['epoch'] != old_endpoint['epoch']
            request(b, 'tabs', ok=False)
            # Native protocol regression only: register a NEW test grant while
            # retaining the existing test identity process. Never edit CLI grants.
            fresh = dict(b, run=str(uuid.uuid4()), secret=uuid.uuid4().hex + uuid.uuid4().hex)
            fresh.pop('epoch')
            fresh.update(call(endpoint['socket'], dict(fresh, command='register')))
            subprocess.run([str(cli), 'wait-ready', '--socket', api_socket, '--timeout', '30'], check=True, capture_output=True)
            control('select-session', 'embedded-beta')
            persisted = request(fresh, 'open', url=url + 'shared')['id']
            request(fresh, 'wait', tab=persisted)
            contents = request(fresh, 'read', tab=persisted)['text']
            assert all(value in contents for value in persisted_values), contents
            request(fresh, 'close', tab=persisted)
            wait_for(lambda: not request(fresh, 'tabs'))
            stop_host()
            checks += ['graceful-restart', 'profile-persistence', 'stale-grant-rejection', 'no-new-crash-reports']
        (root / 'acceptance.json').write_text(json.dumps({'passed': True, 'hostPID': host.pid,
            'checks': checks}))
        if not args.restart_check:
            print('PASS. Test host remains open for UI/tab/split/close verification. Quit the test app to finish.', flush=True)
            host.wait()
        else:
            print('PASS: embedded actions, graceful restart/quit, profile persistence, stale grants and no new crash reports', flush=True)
    finally:
        # Never kill the installed app or default tmux server. If a first-use
        # prompt is pending, keep this exact process alive for operator review.
        if host.poll() is None:
            print('Test stopped before completion. Test host kept alive for diagnosis:', host.pid, flush=True)
        else:
            subprocess.run(['/opt/homebrew/bin/tmux', '-S', tmux_socket, 'kill-server'], capture_output=True)
        server.shutdown()


if __name__ == '__main__':
    main()
