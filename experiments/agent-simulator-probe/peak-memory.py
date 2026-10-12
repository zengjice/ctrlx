#!/usr/bin/env python3
"""Sample deduplicated bridge memory during concurrent rotation, AX and PNG load."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import ctypes
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True, type=Path)
    parser.add_argument('--control', required=True, type=Path)
    parser.add_argument('--provision', required=True, type=Path)
    parser.add_argument('--baseline', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--seconds', type=float, default=120)
    args = parser.parse_args()
    assert 60 <= args.seconds <= 1800
    args.output.mkdir(mode=0o700)
    class Timebase(ctypes.Structure):
        _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
    clock = Timebase()
    system = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    system.mach_absolute_time.restype = ctypes.c_uint64
    assert system.mach_timebase_info(ctypes.byref(clock)) == 0
    factor = clock.numer / clock.denom / 1e9

    def uptime():
        return system.mach_absolute_time() * factor

    host = json.loads(args.host.read_text())
    provision = json.loads(args.provision.read_text())
    devices = provision['devices']
    assert host['configuration'] == 'Release' and host['build'] == 'release-22' and len(devices) == 2
    baseline = json.loads(args.baseline.read_text())
    assert baseline['host']['pid'] == host['pid'] and not baseline['devices']
    baseline_bytes = {c['kind']: c['deduplicatedGroupBytes'] for c in baseline['captures']}

    def call(device, words):
        started = uptime()
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(60)
            client.connect(str(args.control))
            client.sendall(json.dumps({'arguments': words + ['--device', device['device']]}).encode() + b'\n')
            reply = json.loads(client.makefile('rb').readline(10 * 1024 * 1024))
        with (args.output / 'commands.jsonl').open('a') as log:
            log.write(json.dumps({'startedAt': started, 'endedAt': uptime(), 'device': device['device'], 'arguments': words, **reply}) + '\n')
        assert reply['code'] == 0, reply
        return json.loads(reply['stdout'])

    initial = [call(d, ['status']) for d in devices]
    assert all(s['view']['visible'] and s['view']['inputReady'] and s['view']['displaySyncEnabled'] for s in initial)
    for device in devices:
        call(device, ['rotate', '--orientation', 'portrait'])
        assert not call(device, ['snapshot', '--limit', '200'])['partial']
    host['deviceUDIDs'] = {d['device']: d['udid'] for d in devices}
    host['agentPID'] = provision['identity']['owner']['pid']
    assert provision['host']['pid'] == host['pid'] and host['agentPID'] == host['realAgentPID']
    spec = importlib.util.spec_from_file_location('capacity', Path(__file__).with_name('capacity.py'))
    capacity = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(capacity)
    helper = (Path(host['app']) / 'Contents/Helpers/CtrlxSimulatorHost').resolve()

    def selected():
        samples = [p for p in capacity.process_samples(host) if p['role'] in ('host', 'host-child', 'simulator-helper')]
        assert any(p['pid'] == host['pid'] for p in samples)
        assert len([p for p in samples if p['helperRole'] == 'worker']) == 2
        assert len([p for p in samples if p['helperRole'] == 'inspector']) == 2
        result = []
        for p in samples:
            path = ctypes.create_string_buffer(4096)
            assert capacity.libproc.proc_pidpath(p['pid'], path, len(path)) > 0
            executable = Path(path.value.decode()).resolve()
            if p['helperRole']:
                assert executable == helper
            result.append({'pid': p['pid'], 'start': p['start'], 'path': str(executable),
                           'role': p['helperRole'] or p['role']})
        return result

    before = selected()
    baseline_host = next(p for p in baseline['captures'][0]['selectedBefore'] if p['pid'] == host['pid'])
    assert next(p for p in before if p['pid'] == host['pid'])['start'] == baseline_host['start']
    frozen = args.output / 'sources'
    frozen.mkdir()
    for source in (Path(__file__), Path(__file__).with_name('capacity.py')):
        shutil.copyfile(source, frozen / source.name)
    (args.output / 'input-sha.json').write_text(json.dumps({str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in [*frozen.iterdir(), args.provision, args.baseline]}, indent=2))
    captures = []
    try:
        for kind, flags in [('pmap', []), ('vm-objects-unmapped', ['--vmObjectDirty', '--unmapped'])]:
            process = subprocess.Popen(['/usr/bin/footprint', '--json', str((args.output / (kind + '.json')).resolve()),
                '--format', 'bytes', '--sample', '.5', '--sample-duration', str(args.seconds + 10),
                *flags, *[str(p['pid']) for p in before]],
                stdout=(args.output / (kind + '.log')).open('w'), stderr=subprocess.STDOUT)
            captures.append((kind, process))
        started = uptime()
        orientations = ('landscape-left', 'landscape-right', 'portrait')

        def workload(device):
            state_path = Path(device['stateFile'])
            expected = json.loads(state_path.read_text())['taps']
            rows = []
            index = 0
            while uptime() - started < args.seconds:
                orientation = orientations[index % len(orientations)]
                call(device, ['rotate', '--orientation', orientation])
                tree = call(device, ['snapshot', '--limit', '200'])
                assert not tree['partial']
                call(device, ['tap', '--identifier', 'fixture.tap'])
                expected += 1
                deadline = uptime() + 2
                while True:
                    state = json.loads(state_path.read_text())
                    if state['taps'] == expected:
                        break
                    assert uptime() < deadline, (expected, state)
                    time.sleep(.01)
                picture = args.output / f"{device['region']}-{index:03}.png"
                call(device, ['screenshot', '--output', str(picture.resolve())])
                assert picture.read_bytes()[:8] == b'\x89PNG\r\n\x1a\n'
                status = call(device, ['status'])
                assert status['view']['visible'] and status['view']['displaySyncEnabled']
                rows.append({'index': index, 'endedAt': uptime(), 'orientation': orientation,
                             'state': state, 'status': status, 'pngBytes': picture.stat().st_size})
                index += 1
            call(device, ['rotate', '--orientation', 'portrait'])
            return {'device': device['device'], 'operations': rows, 'endedAt': uptime()}

        with ThreadPoolExecutor(max_workers=2) as pool:
            effects = list(pool.map(workload, devices))
        (args.output / 'workload.json').write_text(json.dumps({'startedAt': started, 'effects': effects}, indent=2))
        for _, process in captures:
            assert process.wait(timeout=30) == 0
        after = selected()
        assert {(p['pid'], p['start']) for p in before} == {(p['pid'], p['start']) for p in after}
        summaries = []
        for kind, _ in captures:
            raw = json.loads((args.output / (kind + '.json')).read_text())
            samples = raw['samples']
            assert len(samples) >= 30
            assert all(not s['errors'] and not s['warnings'] for s in samples)
            assert all(s['total footprint'] > 0 for s in samples)
            assert all(samples[0]['start_time']['mach_absolute_time_ns'] / 1e9 <= e['endedAt'] <=
                samples[-1]['end_time']['mach_absolute_time_ns'] / 1e9 for e in effects)
            peak = max(samples, key=lambda s: s['total footprint'])
            span = (samples[-1]['start_time']['mach_absolute_time_ns'] - samples[0]['start_time']['mach_absolute_time_ns']) / 1e9
            gaps = [(b['start_time']['mach_absolute_time_ns'] - a['start_time']['mach_absolute_time_ns']) / 1e9 for a, b in zip(samples, samples[1:])]
            summaries.append({'kind': kind, 'samples': len(samples), 'seconds': span,
                'maxSampleGapSeconds': max(gaps), 'baselineBytes': baseline_bytes[kind],
                'observedDeduplicatedPeakBytes': peak['total footprint'],
                'observedPeakIncrementPerDeviceMiB': (peak['total footprint'] - baseline_bytes[kind]) / 1048576 / 2,
                'peakAt': peak['start_time'], 'peakIOSurface': peak['summary'].get('IOSurface')})
        result = {'host': host, 'devices': devices, 'selectedBefore': before, 'selectedAfter': after,
            'identitiesStable': True, 'workloadStartedAt': started, 'effects': effects, 'captures': summaries,
            'observedPeakWithin150MiBPerDevice': all(s['observedPeakIncrementPerDeviceMiB'] <= 150 for s in summaries),
            'groupLifetimePeakQualified': False, 'allPerformanceQualified': False, 'goalComplete': False,
            'scope': 'Both visible, synchronized. Concurrent rotation, complete AX, actual tap counters and PNG load; GUI, children, exact owned workers and Inspectors deduplicated by footprint. Uses the original same-host fresh selected baseline. Reports highest sampled group value and actual sampling gaps, not an exact kernel lifetime maximum. Separate memory workload; no CPU, input latency or FPS qualification from this run.'}
        (args.output / 'summary.json').write_text(json.dumps(result, indent=2))
        print(json.dumps({'captures': summaries, 'operations': [len(e['operations']) for e in effects]}, indent=2))
    finally:
        for _, process in captures:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)


if __name__ == '__main__':
    main()
