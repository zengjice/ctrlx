#!/usr/bin/env python3
"""Verify actual runtime/toolchain input and an optional profile rejection."""
import argparse
import json
from pathlib import Path
import plistlib
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runtime', required=True)
    parser.add_argument('--profile', choices=['standard', 'balanced'], required=True)
    parser.add_argument('--developer', type=Path, required=True)
    parser.add_argument('--reject-balanced', action='store_true')
    args = parser.parse_args()
    assert not args.output.exists()
    host = json.loads(args.host.read_text())
    root = Path(host['root']) / 'state/agent-simulator'

    def event(value):
        with args.output.open('a') as file:
            file.write(json.dumps({'at': time.time(), **value}) + '\n')

    def request(words, success=True):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(260)
            client.connect(str(args.control))
            client.sendall(json.dumps({'arguments': words}).encode() + b'\n')
            result = json.loads(client.makefile('rb').readline(10 * 1024 * 1024))
        event({'kind': 'command', 'arguments': words, **result})
        if not success:
            return result
        assert result['code'] == 0, result
        return json.loads(result['stdout'])

    selected = subprocess.check_output(['xcode-select', '-p'], text=True).strip()
    event({'kind': 'environment', 'host': host, 'globalDeveloperDirectory': selected,
           'expectedHelperDeveloperDirectory': str(args.developer)})
    assert not request(['devices'])['devices']
    opened = request(['open', '--profile', args.profile, '--runtime', args.runtime,
        '--device-type', 'com.apple.CoreSimulator.SimDeviceType.iPhone-16'])
    device, udid = opened['device'], opened['udid']
    bundle = 'com.jicezeng.ctrlx.interaction-fixture'
    try:
        jobs = [plistlib.loads(file.read_bytes()) for file in (root / 'jobs').glob('*.plist')]
        worker = [job for job in jobs if job['ProgramArguments'][4:7] == [udid, 'worker', str(host['pid'])]]
        assert len(worker) == 1 and worker[0]['ProgramArguments'][2] == str(args.developer), worker
        event({'kind': 'actual-worker-job', 'job': worker[0]})
        request(['install', '--device', device, '--app', str(args.fixture.resolve())])
        request(['launch', '--device', device, '--bundle', bundle])
        request(['wait', '--device', device, '--identifier', 'fixture.tap', '--timeout-ms', '60000'])
        directory = subprocess.check_output(['xcrun', 'simctl', '--set', str(root / 'devices'),
            'get_app_container', udid, bundle, 'data'], text=True).strip()
        state_file = Path(directory) / 'Documents/state.json'
        time.sleep(20)
        request(['tap', '--device', device, '--x', '164', '--y', '118'])
        deadline = time.monotonic() + 2
        while True:
            state = json.loads(state_file.read_text())
            if state['taps'] == 1:
                break
            assert time.monotonic() < deadline, state
            time.sleep(.02)
        event({'kind': 'actual-input-effect', 'opened': opened, 'state': state})
        picture = args.output.with_suffix('.png').resolve()
        request(['screenshot', '--device', device, '--output', str(picture)])
        assert picture.stat().st_size > 1000
    finally:
        request(['close', '--device', device])
    if args.reject_balanced:
        result = request(['open', '--profile', 'balanced', '--runtime', args.runtime,
            '--device-type', 'com.apple.CoreSimulator.SimDeviceType.iPhone-16'], success=False)
        if result['code'] == 0:
            request(['close', '--device', json.loads(result['stdout'])['device']])
            raise AssertionError('Balanced unexpectedly accepted the unsupported runtime')
        assert result['code'] != 0 and 'simslim requires iOS 18.5 or newer' in result['stderr'], result
        assert not request(['devices'])['devices']
        assert not list((root / 'jobs').glob('*.plist'))
        event({'kind': 'balanced-runtime-rejection-passed'})
    assert subprocess.check_output(['xcode-select', '-p'], text=True).strip() == selected
    event({'kind': 'passed', 'runtime': args.runtime, 'profile': args.profile})
    print('Actual input, screenshot, helper toolchain and profile boundary passed', flush=True)


if __name__ == '__main__':
    main()
