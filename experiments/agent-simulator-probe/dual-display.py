#!/usr/bin/env python3
"""Measure two visible owned simulators through one display-selected-window stream."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import shutil
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--title', required=True)
    parser.add_argument('--profile', choices=('standard', 'balanced'), required=True)
    parser.add_argument('--expected-build', default='release-22')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--keep-open', action='store_true')
    parser.add_argument('--setup-timeout', type=float, default=180)
    args = parser.parse_args()
    args.output.mkdir(mode=0o700)
    host = json.loads(args.host.read_text())
    assert host['configuration'] == 'Release' and host['build'] == args.expected_build
    assert subprocess.check_output(['ps', '-p', str(host['pid']), '-o', 'comm='], text=True).strip() == str(Path(host['app']) / 'Contents/MacOS/CtrlX')
    frozen = args.output / 'sources'
    frozen.mkdir()
    for source in (Path(__file__), Path(__file__).with_name('WindowFrameProbe.m'),
                   Path(__file__).with_name('WindowFrameProbeDecoderTests.m')):
        shutil.copyfile(source, frozen / source.name)
    source_files = list(frozen.iterdir()) + [args.probe, args.fixture / 'InteractionFixture']
    (args.output / 'source-sha.json').write_text(json.dumps({str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files}, indent=2))

    def call(words):
        started = time.monotonic()
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(260)
            client.connect(str(args.control))
            client.sendall(json.dumps({'arguments': words}).encode() + b'\n')
            reply = json.loads(client.makefile('rb').readline(10 * 1024 * 1024))
        with (args.output / 'commands.jsonl').open('a') as log:
            log.write(json.dumps({'arguments': words, 'seconds': time.monotonic() - started, **reply}) + '\n')
        assert reply['code'] == 0, reply
        return json.loads(reply['stdout'])

    def action(device, words):
        return call(words + ['--device', device['device']])

    devices = []
    capture = None
    success = False
    try:
        identity = call(['identity'])
        assert not call(['devices'])['devices']
        for region in ('left', 'right'):
            opened = call(['open', '--profile', args.profile, '--runtime', 'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
                           '--device-type', 'com.apple.CoreSimulator.SimDeviceType.iPhone-16'])
            devices.append(opened)
            action(opened, ['install', '--app', str(args.fixture.resolve())])
            action(opened, ['launch', '--bundle', 'com.jicezeng.ctrlx.interaction-fixture'])
            action(opened, ['wait', '--identifier', 'fixture.tap', '--timeout-ms', '60000'])
            action(opened, ['show'])
            container = subprocess.check_output(['/usr/bin/xcrun', 'simctl', '--set',
                str(Path(host['root']) / 'state/agent-simulator/devices'), 'get_app_container', opened['udid'],
                'com.jicezeng.ctrlx.interaction-fixture', 'data'], text=True).strip()
            opened['stateFile'] = str(Path(container) / 'Documents/state.json')
            opened['region'] = region
            print('Provisioned', region, opened['device'], flush=True)
        (args.output / 'ready.json').write_text(json.dumps({'host': host, 'identity': identity, 'devices': devices}, indent=2))
        print('Waiting for both tabs to be visible and start file', flush=True)
        deadline = time.monotonic() + args.setup_timeout
        while not (args.output / 'start').exists():
            assert time.monotonic() < deadline, 'Layout setup timed out'
            time.sleep(.1)
        before = [action(d, ['status']) for d in devices]
        assert all(s['view']['visible'] and s['view']['inputReady'] and s['view']['displaySyncEnabled'] for s in before)
        (args.output / 'layout.json').write_text(json.dumps(before, indent=2))
        time.sleep(10)
        rounds = []
        for number in (1, 2, 3):
            initial = [action(d, ['status', '--reset-measurements']) for d in devices]
            assert all(s['view']['visible'] and s['view']['inputReady'] for s in initial)
            output = args.output / f'display-{number}.json'
            capture = subprocess.Popen([str(args.probe.resolve()), str(host['pid']), args.title, '60',
                str(output.resolve()), 'display-both'], stdout=(args.output / f'capture-{number}.log').open('w'), stderr=subprocess.STDOUT)
            time.sleep(5)

            def inputs(device):
                state_file = Path(device['stateFile'])
                initial_count = json.loads(state_file.read_text())['taps']
                rows = []
                for index in range(30):
                    action(device, ['tap', '--x', '164', '--y', '118', '--duration-ms', '20'])
                    deadline = time.monotonic() + 2
                    while True:
                        state = json.loads(state_file.read_text())
                        if state['taps'] == initial_count + index + 1:
                            break
                        assert time.monotonic() < deadline, (initial_count + index + 1, state)
                        time.sleep(.01)
                    native = action(device, ['status'])['inputMeasurements']
                    assert abs(native['upSubmittedAt'] - state['inputUpAt']) < .1
                    rows.append({'fixture': state, 'native': native})
                    time.sleep(.8)
                (args.output / f"inputs-{number}-{device['region']}.json").write_text(json.dumps(rows, indent=2))
                return rows

            with ThreadPoolExecutor(max_workers=2) as pool:
                effects = list(pool.map(inputs, devices))
            capture.wait(timeout=70)
            assert capture.returncode == 0, (args.output / f'capture-{number}.log').read_text()
            capture = None
            observed = json.loads(output.read_text())
            final = [action(d, ['status']) for d in devices]
            summaries = []
            for device, rows, status in zip(devices, effects, final):
                window = observed[device['region']]
                assert window['captureMode'] == 'display-selected-window' and window['region'] == device['region']
                assert window['elapsedSeconds'] >= 60
                assert status['view']['visible'] and status['view']['inputReady']
                for row in rows:
                    matching = [f['displayAt'] for f in window['frames'] if f['taps'] == row['fixture']['taps'] % 256
                        and row['native']['upSubmittedAt'] <= f['displayAt'] <= row['native']['upSubmittedAt'] + 2]
                    assert matching, row
                    row['HIDUpToDisplayMs'] = (min(matching) - row['native']['upSubmittedAt']) * 1000
                    row['fixtureUpToDisplayMs'] = (min(matching) - row['fixture']['inputUpAt']) * 1000
                latencies = sorted(r['HIDUpToDisplayMs'] for r in rows)
                summaries.append({'device': device['device'], 'region': device['region'], 'effects': rows,
                    'displayFPS': window['uniqueWindowFPS'], 'barcodeRejected': window['barcodeRejected'],
                    'HIDUpToDisplayP95Ms': latencies[int(len(latencies) * .95)],
                    'HIDUpToDisplayP99Ms': latencies[int(len(latencies) * .99)], 'finalStatus': status})
            round_result = {'round': number, 'devices': summaries}
            rounds.append(round_result)
            (args.output / f'summary-{number}.json').write_text(json.dumps(round_result, indent=2))
            print(json.dumps({'round': number, 'devices': [{k: s[k] for k in ('region', 'displayFPS', 'HIDUpToDisplayP95Ms', 'barcodeRejected')} for s in summaries]}), flush=True)
        (args.output / 'summary.json').write_text(json.dumps({'host': host, 'profile': args.profile, 'rounds': rounds,
            'displayFPSQualified': all(d['displayFPS'] >= 58 for r in rounds for d in r['devices']),
            'allPerformanceQualified': False, 'sourceCausalityQualified': False, 'goalComplete': False,
            'scope': 'Two synchronized visible views, one display-selected-window stream, three sixty-second rounds with thirty actual concurrent agent tap effects per device. Every effect matched by fixture counter and checksummed visible barcode. HID-up latency excludes Mac mouse routing. Metal source metadata is diagnostic; source-ready content causality and relative native visible response are not qualified. No AX/PNG, UI state capture, profiling, compilation or footprint during display rounds.'}, indent=2))
        success = True
    finally:
        if capture is not None and capture.poll() is None:
            capture.terminate()
            capture.wait(timeout=10)
        if not (success and args.keep_open):
            for device in devices:
                action(device, ['close'])
        (args.output / 'completion.json').write_text(json.dumps({'success': success, 'devicesKeptOpen': success and args.keep_open,
            'currentDevices': call(['devices'])}, indent=2))


if __name__ == '__main__':
    main()
