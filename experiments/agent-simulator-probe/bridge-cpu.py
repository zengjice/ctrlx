#!/usr/bin/env python3
"""Measure kernel CPU deltas without UI, screenshot, AX, footprint or compile load."""
import argparse
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
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--visibility', choices=('idle', 'visible', 'hidden'), required=True)
    parser.add_argument('--seconds', type=float, default=60)
    args = parser.parse_args()
    assert args.seconds >= 60
    args.output.mkdir(mode=0o700)
    host = json.loads(args.host.read_text())
    assert host['configuration'] == 'Release' and host['build'] == 'release-22'
    assert subprocess.check_output(['ps', '-p', str(host['pid']), '-o', 'comm='], text=True).strip() == str(Path(host['app']) / 'Contents/MacOS/CtrlX')

    def call(words):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(30)
            client.connect(str(args.control))
            client.sendall(json.dumps({'arguments': words}).encode() + b'\n')
            reply = json.loads(client.makefile('rb').readline(10 * 1024 * 1024))
        assert reply['code'] == 0, reply
        return json.loads(reply['stdout'])

    identity = call(['identity'])
    host['agentPID'] = identity['owner']['pid']
    devices = call(['devices'])['devices']
    if args.visibility == 'idle':
        assert not devices
    else:
        assert 1 <= len(devices) <= 2
    host['deviceUDIDs'] = {d['device']: d['udid'] for d in devices}
    initial = [call(['status', '--reset-measurements', '--device', d['device']]) for d in devices]
    for status in initial:
        assert status['view']['displaySyncEnabled']
        assert status['view']['visible'] == (args.visibility == 'visible')
        if args.visibility == 'visible':
            assert status['view']['inputReady']
    spec = importlib.util.spec_from_file_location('capacity', Path(__file__).with_name('capacity.py'))
    capacity = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(capacity)
    class Timebase(ctypes.Structure):
        _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
    clock = Timebase()
    assert ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(ctypes.byref(clock)) == 0
    factor = clock.numer / clock.denom / 1e9
    samples = []
    started = time.monotonic()
    while True:
        sample = {'at': time.monotonic(), 'processes': capacity.process_samples(host)}
        samples.append(sample)
        with (args.output / 'processes.jsonl').open('a') as log:
            log.write(json.dumps(sample) + '\n')
        if sample['at'] - started >= args.seconds:
            break
        time.sleep(max(0, min(5, args.seconds - (time.monotonic() - started))))
    final = [call(['status', '--device', d['device']]) for d in devices]
    for before, after in zip(initial, final):
        assert before['view']['visible'] == after['view']['visible']
        assert before['view']['width'] == after['view']['width'] and before['view']['height'] == after['view']['height']
    bridge_roles = ('host', 'host-child', 'simulator-helper')
    first = {(p['pid'], p['start']): p for p in samples[0]['processes'] if p['role'] in bridge_roles}
    last = {(p['pid'], p['start']): p for p in samples[-1]['processes'] if p['role'] in bridge_roles}
    assert first.keys() == last.keys()
    elapsed = samples[-1]['at'] - samples[0]['at']
    assert elapsed >= 60
    cores = {}
    for key, end in last.items():
        begin = first[key]
        role = end['helperRole'] or end['role']
        delta = end['cpuUser'] + end['cpuSystem'] - begin['cpuUser'] - begin['cpuSystem']
        assert delta >= 0
        cores[role] = cores.get(role, 0) + delta * factor / elapsed
    if args.visibility == 'hidden':
        assert all(s['measurements']['presentedFrames'] == 0 for s in final)
    frozen = args.output / 'sources'
    frozen.mkdir()
    for source in (Path(__file__), Path(__file__).with_name('capacity.py')):
        shutil.copyfile(source, frozen / source.name)
    summary = {'host': host, 'identity': identity, 'devices': devices, 'visibility': args.visibility,
        'seconds': elapsed, 'timebase': {'numer': clock.numer, 'denom': clock.denom},
        'CPUCoreByRole': cores, 'totalBridgeCPUCore': sum(cores.values()),
        'initialStatus': initial, 'finalStatus': final, 'identitiesStable': True,
        'allPerformanceQualified': False, 'goalComplete': False,
        'scope': 'Cumulative kernel CPU deltas over at least sixty seconds, one core = 1. GUI, children and exact owned helper roles; simulator-internal and actual-agent CPU excluded. No UI/AX/PNG, screen capture, footprint, profiling or compile during interval. Metal counters are diagnostic and do not independently prove unique visible FPS or source causality.',
        'sha256': {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in [*frozen.iterdir(), args.output / 'processes.jsonl']}}
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps({'visibility': args.visibility, 'seconds': elapsed, 'cores': cores,
        'metalFPS': [s['measurements']['uniqueFPS'] for s in final]}))


if __name__ == '__main__':
    main()
