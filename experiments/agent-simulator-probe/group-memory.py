#!/usr/bin/env python3
"""Collect deduplicated bridge memory and individual lifetime peaks from an isolated host."""
import argparse
import ctypes
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import time


class UsageV4(ctypes.Structure):
    # Field order is rusage_info_v4 in the macOS SDK's sys/resource.h.
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        'user', 'system', 'idle', 'interrupt', 'pageins', 'wired', 'resident', 'footprint', 'start', 'exit',
        'childUser', 'childSystem', 'childIdle', 'childInterrupt', 'childPageins', 'childElapsed',
        'diskRead', 'diskWrite', 'qosDefault', 'qosMaintenance', 'qosBackground', 'qosUtility',
        'qosLegacy', 'qosInitiated', 'qosInteractive', 'billedSystem', 'servicedSystem', 'logicalWrites',
        'lifetimePeak', 'instructions', 'cycles', 'billedEnergy', 'servicedEnergy', 'intervalPeak', 'runnable')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists(), 'Use a fresh output directory'
    host = json.loads(args.host.read_text())
    app = Path(host['app'])
    assert subprocess.check_output(['ps', '-p', str(host['pid']), '-o', 'comm='], text=True).strip() == str(app / 'Contents/MacOS/CtrlX')

    def request(words):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(30)
            client.connect(str(args.control))
            client.sendall(json.dumps({'arguments': words}).encode() + b'\n')
            reply = json.loads(client.makefile('rb').readline(10 * 1024 * 1024))
        assert reply['code'] == 0, reply
        return json.loads(reply['stdout'])

    host['agentPID'] = request(['identity'])['owner']['pid']
    devices = request(['devices'])['devices']
    host['deviceUDIDs'] = {item['device']: item['udid'] for item in devices}
    spec = importlib.util.spec_from_file_location('capacity', Path(__file__).with_name('capacity.py'))
    capacity = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(capacity)
    roles = {'host', 'host-child', 'simulator-helper'}
    helper = (app / 'Contents/Helpers/CtrlxSimulatorHost').resolve()

    def selected():
        samples = [item for item in capacity.process_samples(host) if item['role'] in roles]
        assert any(item['pid'] == host['pid'] for item in samples)
        records = []
        for item in samples:
            path = ctypes.create_string_buffer(4096)
            assert capacity.libproc.proc_pidpath(item['pid'], path, len(path)) > 0
            executable = Path(path.value.decode()).resolve()
            if item['helperRole']:
                assert executable == helper
            usage = UsageV4()
            assert capacity.libproc.proc_pid_rusage(item['pid'], 4, ctypes.byref(usage)) == 0
            assert usage.start == item['start']
            records.append({'pid': item['pid'], 'start': usage.start, 'path': str(executable),
                            'role': item['helperRole'] or item['role'],
                            'physicalFootprintBytes': usage.footprint,
                            'individualLifetimePeakBytes': usage.lifetimePeak})
        assert devices or not any(item['role'] in ('worker', 'inspector') for item in records)
        return records

    args.output.mkdir(parents=True, mode=0o700)
    results = []
    for kind, flags in [('pmap', []), ('vm-objects-unmapped', ['--vmObjectDirty', '--unmapped'])]:
        before = selected()
        output = args.output / (kind + '.json')
        started = time.time()
        words = ['/usr/bin/footprint', '--json', str(output), '--format', 'bytes', *flags,
                 *[str(item['pid']) for item in before]]
        with (args.output / (kind + '.log')).open('w') as log:
            result = subprocess.run(words, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        after = selected()
        assert result.returncode == 0
        assert {(item['pid'], item['start']) for item in before} == {(item['pid'], item['start']) for item in after}
        raw = json.loads(output.read_text())
        assert not raw['errors'] and not raw['warnings']
        results.append({'kind': kind, 'startedAt': started, 'endedAt': time.time(),
                        'selectedBefore': before, 'selectedAfter': after, 'identitiesStable': True,
                        'deduplicatedGroupBytes': raw['total footprint'],
                        'IOSurface': raw['summary'].get('IOSurface'), 'rawJSON': str(output.resolve())})
    record = {'host': host, 'devices': devices, 'captures': results,
              'boundary': 'GUI, its children and exact owned worker/Inspector. iOS processes and actual agent excluded. footprint deduplicates multiply mapped VM objects. Individual rusage_info_v4 lifetime peaks belong to separate processes and are neither simultaneous nor deduplicated; do not sum them as group peak. Each group capture is a snapshot, not a continuous lifetime maximum.',
              'groupLifetimePeakQualified': False, 'goalComplete': False}
    (args.output / 'capture.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({capture['kind']: capture['deduplicatedGroupBytes'] for capture in results}))


if __name__ == '__main__':
    main()
