#!/usr/bin/env python3
"""Match real window mouse effects to UIKit touch timestamps and captured frames.

This collector never submits input. Operate only the owned test window through
Computer Use after ready.json appears. It does not measure physical panel scanout.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--title', required=True)
    parser.add_argument('--state-file', type=Path, required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seconds', type=int, default=60)
    args = parser.parse_args()
    assert 30 <= args.seconds <= 180
    args.output.mkdir(mode=0o700)
    initial = json.loads(args.state_file.read_text())
    last = initial['taps']
    effects = []
    window_file = args.output / 'window.json'
    with (args.output / 'capture.log').open('w') as log:
        capture = subprocess.Popen([str(args.probe.resolve()), str(args.pid), args.title,
            str(args.seconds), str(window_file.resolve())], stdout=log, stderr=subprocess.STDOUT)
        try:
            time.sleep(4)
            ready = {'pid': args.pid, 'capturePID': capture.pid, 'title': args.title, 'initial': initial,
                'stateFile': str(args.state_file), 'readyAt': time.time()}
            (args.output / 'ready.json').write_text(json.dumps(ready, indent=2))
            print('Ready for owned-window clicks:', args.output, flush=True)
            deadline = time.monotonic() + args.seconds + 15
            while capture.poll() is None:
                assert time.monotonic() < deadline, 'Window capture timed out'
                state = json.loads(args.state_file.read_text())
                if state['taps'] != last:
                    assert state['taps'] == last + 1, (last, state)
                    assert state['inputUpAt'] >= state['inputDownAt'] > 0, state
                    effects.append(state)
                    last = state['taps']
                time.sleep(.01)
            assert capture.returncode == 0, (args.output / 'capture.log').read_text()
        finally:
            if capture.poll() is None:
                capture.terminate()
                capture.wait(timeout=10)
    window = json.loads(window_file.read_text())
    matched, missing = [], []
    for state in effects:
        frames = [frame for frame in window['frames']
            if frame['taps'] == state['taps'] % 256
            and state['inputUpAt'] <= frame['displayAt'] <= state['inputUpAt'] + 2]
        if not frames:
            missing.append(state)
            continue
        shown = min(frame['displayAt'] for frame in frames)
        matched.append({'fixture': state, 'fixtureUpToWindowMs': (shown - state['inputUpAt']) * 1000})
    latencies = sorted(item['fixtureUpToWindowMs'] for item in matched)
    result = {'ready': ready, 'actualInputEffects': effects, 'matched': matched, 'missing': missing,
        'windowFPS': window['uniqueWindowFPS'], 'barcodeRejected': window['barcodeRejected'],
        'imageGeometry': window.get('imageGeometry'), 'barcodeGeometry': window.get('barcodeGeometry'),
        'fixtureUpToWindowP95Ms': latencies[min(len(latencies) - 1, int(len(latencies) * .95))] if latencies else None,
        'boundary': 'UIKit touch up to matching ScreenCaptureKit window composition; excludes Mac dispatch and physical scanout'}
    (args.output / 'summary.json').write_text(json.dumps(result, indent=2))
    assert len(matched) >= 20 and not missing, (len(matched), len(missing))
    print('Matched', len(matched), 'window mouse effects; p95 ms:', result['fixtureUpToWindowP95Ms'], flush=True)


if __name__ == '__main__':
    main()
