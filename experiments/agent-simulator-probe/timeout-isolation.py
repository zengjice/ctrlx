#!/usr/bin/env python3
"""Measure device B while only this isolated app's device A Inspector is stopped.

The collector never generates mouse input. Computer Use supplies three verified
mouse clicks for each trial using the start/ready/done handshake in output.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import subprocess
import time


class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in
        ('user', 'system', 'idle', 'interrupt', 'pageins', 'wired', 'resident', 'footprint', 'start', 'exit')]


class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--profile', choices=('standard', 'balanced'), required=True)
    parser.add_argument('--trials', type=int, default=10)
    parser.add_argument('--memory-output', type=Path)
    args = parser.parse_args()
    assert 1 <= args.trials <= 10
    assert not args.output.exists(), 'Use a fresh output directory'
    host = json.loads(args.host.read_text())
    root = Path(host['root']) / 'state/agent-simulator'
    helper = (Path(host['app']) / 'Contents/Helpers/CtrlxSimulatorHost').resolve()
    assert subprocess.check_output(['ps', '-p', str(host['pid']), '-o', 'comm='], text=True).strip() == str(Path(host['app']) / 'Contents/MacOS/CtrlX')
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    system = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    system.mach_absolute_time.restype = ctypes.c_uint64
    timebase = Timebase()
    assert system.mach_timebase_info(ctypes.byref(timebase)) == 0
    factor = timebase.numer / timebase.denom / 1e9
    args.output.mkdir(parents=True, mode=0o700)

    def now():
        return system.mach_absolute_time() * factor

    def write(name, value):
        temporary = args.output / (name + '.tmp')
        temporary.write_text(json.dumps(value, indent=2) + '\n')
        temporary.replace(args.output / name)

    def request(words, success=True):
        started = now()
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(260)
            client.connect(str(args.control))
            client.sendall(json.dumps({'arguments': words}).encode() + b'\n')
            reply = json.loads(client.makefile('rb').readline(10 * 1024 * 1024))
        ended = now()
        with (args.output / 'commands.jsonl').open('a') as log:
            log.write(json.dumps({'startedAt': started, 'endedAt': ended, 'arguments': words, **reply}) + '\n')
        if success:
            assert reply['code'] == 0, reply
            return json.loads(reply['stdout'])
        return {'startedAt': started, 'endedAt': ended, **reply}

    def inspect(pid):
        usage = Usage()
        path = ctypes.create_string_buffer(4096)
        if libproc.proc_pid_rusage(pid, 0, ctypes.byref(usage)) != 0 or libproc.proc_pidpath(pid, path, len(path)) <= 0:
            return None
        return {'pid': pid, 'start': usage.start, 'path': str(Path(path.value.decode()).resolve())}

    def inspector_identity(item):
        jobs = []
        for path in (root / 'jobs').glob('*.plist'):
            job = plistlib.loads(path.read_bytes())
            words = job['ProgramArguments']
            if Path(words[0]).resolve() == helper and words[4:7] == [item['udid'], 'inspector', str(host['pid'])]:
                jobs.append(job)
        assert len(jobs) == 1, 'Expected exactly one owned Inspector job'
        policy = subprocess.check_output(['/bin/launchctl', 'print', f'gui/{os.getuid()}/' + jobs[0]['Label']], text=True)
        pids = re.findall(r'^\s*pid = (\d+)\s*$', policy, re.MULTILINE)
        assert len(pids) == 1
        identity = inspect(int(pids[0]))
        assert identity and identity['path'] == str(helper)
        return identity

    def wait_file(name, seconds):
        deadline = time.monotonic() + seconds
        path = args.output / name
        while not path.exists():
            assert time.monotonic() < deadline, f'Controller handshake timed out: {name}'
            time.sleep(.02)
        return json.loads(path.read_text())

    assert not request(['devices'])['devices']
    identity = request(['identity'])
    active = []
    suspended = None
    pool = ThreadPoolExecutor(max_workers=1)
    trials = []
    try:
        for index, profile in enumerate(('balanced', args.profile), 1):
            item = request(['open', '--profile', profile, '--runtime', 'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
                '--device-type', 'com.apple.CoreSimulator.SimDeviceType.iPhone-16'])
            active.append(item)
            request(['install', '--device', item['device'], '--app', str(args.fixture.resolve())])
            request(['launch', '--device', item['device'], '--bundle', 'com.jicezeng.ctrlx.interaction-fixture'])
            request(['wait', '--device', item['device'], '--identifier', 'fixture.tap', '--timeout-ms', '60000'])
            if args.memory_output:
                request(['screenshot', '--device', item['device'], '--output', str((args.output / f'warm-{index}.png').resolve())])
                request(['show', '--device', item['device']])
                for opened in active:
                    request(['snapshot', '--device', opened['device'], '--limit', '200'])
                subprocess.run(['python3', str(Path(__file__).with_name('group-memory.py')), '--host', str(args.host),
                    '--control', str(args.control), '--output', str(args.memory_output / f'{index}-devices-warm')], check=True)
        first, second = active
        shown = request(['show', '--device', second['device']])
        assert shown['view']['visible'] and shown['view']['inputReady']
        assert shown['view']['displaySyncEnabled'] and shown['view']['width'] == 401 and shown['view']['height'] == 930
        write('ready.json', {'host': host, 'realAgent': identity, 'A': first, 'B': second, 'shown': shown,
            'trials': args.trials, 'fixtureSHA256': hashlib.sha256((args.fixture / 'InteractionFixture').read_bytes()).hexdigest(),
            'timebase': {'numer': timebase.numer, 'denom': timebase.denom},
            'scope': 'A hidden, only its Inspector suspended; B visible synchronized product view. Mouse input comes from Computer Use.'})
        print('Ready for timeout-isolation mouse controller', flush=True)
        for number in range(1, args.trials + 1):
            start = wait_file(f'{number}-start.json', 120)
            assert start['trial'] == number and start['device'] == second['device']
            tree = request(['snapshot', '--device', first['device'], '--limit', '200'])
            assert not tree['partial']
            suspended = inspector_identity(first)
            before = request(['status', '--device', second['device'], '--reset-measurements'])
            assert before['view']['visible'] and before['view']['inputReady']
            assert inspect(suspended['pid']) == suspended
            os.kill(suspended['pid'], signal.SIGSTOP)
            stopped_at = now()
            future = pool.submit(request, ['snapshot', '--device', first['device'], '--limit', '200'], False)
            write(f'{number}-ready.json', {'trial': number, 'device': second['device'], 'inspector': suspended,
                'stoppedAt': stopped_at, 'readyAt': now()})
            done = wait_file(f'{number}-done.json', 30)
            fault = future.result(timeout=20)
            assert fault['code'] != 0 and 'timed out' in fault['stderr'], fault
            if inspect(suspended['pid']) == suspended:
                os.kill(suspended['pid'], signal.SIGCONT)
            after = request(['status', '--device', second['device']])
            rows_path = Path(done['rows'])
            assert rows_path.resolve().is_relative_to(args.output.resolve())
            rows = [json.loads(line) for line in rows_path.read_text().splitlines()]
            assert len(rows) == 3 and all(row['device'] == second['device'] and not row['partial'] for row in rows)
            assert all(row['tapCount'] == row['initialCount'] + row['index'] + 1 for row in rows)
            overlap = [fault['startedAt'] <= row['inputMeasurements']['manualDownReceivedAt']
                <= row['inputMeasurements']['manualUpEnqueuedAt'] <= fault['endedAt'] for row in rows]
            record = {'trial': number, 'inspector': suspended, 'stoppedAt': stopped_at, 'fault': fault,
                'inputRows': str(rows_path), 'inputEventOverlap': overlap, 'beforeStatus': before, 'afterStatus': after,
                'allCountersMatched': True, 'validFaultOverlap': all(overlap)}
            trials.append(record)
            write(f'{number}-result.json', record)
            write('progress.json', {'completedTrials': len(trials), 'validOverlapTrials': sum(t['validFaultOverlap'] for t in trials)})
            print('Timeout-isolation trial complete:', number, 'overlap:', all(overlap), flush=True)
            suspended = None
        write('completion.json', {'trials': trials, 'allPerformanceQualified': False, 'goalComplete': False})
    finally:
        if suspended and inspect(suspended['pid']) == suspended:
            os.kill(suspended['pid'], signal.SIGCONT)
        pool.shutdown(wait=True)
        for item in reversed(active):
            request(['close', '--device', item['device']])
        assert not request(['devices'])['devices']
        assert not list((root / 'jobs').glob('*.plist'))
        write('cleanup.json', {'activeDevices': 0, 'jobs': 0, 'goalComplete': False})
        if args.memory_output:
            subprocess.run(['python3', str(Path(__file__).with_name('group-memory.py')), '--host', str(args.host),
                '--control', str(args.control), '--output', str(args.memory_output / 'after-close')], check=True)


if __name__ == '__main__':
    main()
