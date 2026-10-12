#!/usr/bin/env python3
"""Verify post-boot admission safely with one owned device and a high reserve."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    host = json.loads(args.host.read_text())
    device_set = str(Path(host['root']) / 'state/agent-simulator/devices')

    def event(value):
        with args.output.open('a') as file:
            file.write(json.dumps({'at': time.time(), **value}) + '\n')

    def request(words):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(260)
            client.connect(str(args.control))
            client.sendall(json.dumps({'arguments': words}).encode() + b'\n')
            result = json.loads(client.makefile('rb').readline(10 * 1024 * 1024))
        event({'kind': 'command', 'arguments': words, **result})
        return result

    def call(words):
        result = request(words)
        assert result['code'] == 0, result
        return json.loads(result['stdout'])

    assert not call(['devices'])['devices']
    original = call(['config'])
    event({'kind': 'original-configuration', 'value': original})
    configuration = original.get('configuration', original)
    before = call(['resources'])['system']
    reserve = before['reclaimableBytes'] // (1024 * 1024) - 1024
    assert before['pressureLevel'] == 1 and 512 <= reserve <= 65536, before
    booted = set()
    try:
        call(['config', '--memory-reserve-mi-b', str(reserve)])
        event({'kind': 'test-reserve', 'reserveMiB': reserve, 'before': before})
        with ThreadPoolExecutor(max_workers=1) as pool:
            opening = pool.submit(request, ['open', '--profile', 'balanced',
                '--runtime', 'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
                '--device-type', 'com.apple.CoreSimulator.SimDeviceType.iPhone-16'])
            while not opening.done():
                inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', '--set', device_set,
                    'list', 'devices', '--json'], text=True, timeout=15))
                devices = [d for values in inventory['devices'].values() for d in values
                           if d['name'] == 'CtrlX · iPhone 16']
                active = [d for d in devices if d['state'] == 'Booted']
                booted.update(d['udid'] for d in active)
                event({'kind': 'device-state', 'booted': [d['udid'] for d in active]})
                time.sleep(.5)
            result = opening.result()
        if result['code'] == 0:
            device = json.loads(result['stdout'])['device']
            call(['close', '--device', device])
            raise AssertionError('The chosen reserve was not exceeded; this is not post-boot rejection evidence')
        assert booted, ('Rejected before boot, not a post-boot acceptance', result)
        assert 'Insufficient reclaimable memory' in result['stderr'] or 'Memory pressure is elevated' in result['stderr'], result
        assert not call(['devices'])['devices']
        inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', '--set', device_set,
            'list', 'devices', '--json'], text=True, timeout=15))
        states = {d['udid']: d['state'] for values in inventory['devices'].values() for d in values}
        assert all(states[udid] == 'Shutdown' for udid in booted), states
        assert not list((Path(host['root']) / 'state/agent-simulator/jobs').glob('*.plist'))
        event({'kind': 'post-boot-rejection-passed', 'bootedUDIDs': sorted(booted), 'states': {u: states[u] for u in booted}, 'resources': call(['resources'])})
        print('Actual device booted, exceeded configured reserve, was rejected and shut down before worker startup', flush=True)
    finally:
        call(['config', '--memory-reserve-mi-b', str(configuration['memoryReserveMiB'])])


if __name__ == '__main__':
    main()
