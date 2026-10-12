#!/usr/bin/env python3
"""Validate actual mouse effects and full input timings during another device's AX timeout."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


SEGMENTS = [('receiptToTask', 'ReceivedAt', 'taskStartedAt'),
            ('priorTaskAndRouting', 'taskStartedAt', 'requestStartedAt'),
            ('requestToWorker', 'requestStartedAt', 'workerReceivedAt'),
            ('workerQueue', 'workerReceivedAt', 'workerStartedAt'),
            ('workerProcessing', 'workerStartedAt', 'SubmittedAt'),
            ('nativeSend', 'SubmittedAt', 'EnqueuedAt')]


def quantiles(values):
    ordered = sorted(values)
    assert ordered
    return {'samples': len(ordered), 'p50Ms': ordered[len(ordered) // 2],
            'p95Ms': ordered[int(len(ordered) * .95)], 'p99Ms': ordered[int(len(ordered) * .99)],
            'minMs': ordered[0], 'maxMs': ordered[-1]}


def analyze(directory):
    ready = json.loads((directory / 'ready.json').read_text())
    completion = json.loads((directory / 'completion.json').read_text())
    cleanup = json.loads((directory / 'cleanup.json').read_text())
    assert cleanup['activeDevices'] == cleanup['jobs'] == 0
    assert ready['A']['device'] != ready['B']['device']
    assert not ready['A']['view']['visible']
    profile = ready['B']['profile']
    rows = []
    for number, trial in enumerate(completion['trials'], 1):
        assert trial['trial'] == number and trial['validFaultOverlap']
        fault = trial['fault']
        assert fault['code'] != 0 and 'timed out' in fault['stderr']
        view = trial['beforeStatus']['view']
        assert view['visible'] and view['inputReady'] and view['displaySyncEnabled']
        assert view['width'] == 401 and view['height'] == 930
        path = Path(trial['inputRows']).resolve()
        assert path.is_relative_to(directory.resolve())
        batch = [json.loads(line) for line in path.read_text().splitlines()]
        assert len(batch) == 3
        for index, row in enumerate(batch):
            timing = row['inputMeasurements']
            assert row['device'] == ready['B']['device'] and row['profile'] == profile
            assert not row['partial'] and row['index'] == index and row['round'] == number
            assert row['tapCount'] == row['initialCount'] + index + 1
            assert fault['startedAt'] <= timing['manualDownReceivedAt'] <= timing['manualUpEnqueuedAt'] <= fault['endedAt']
        rows.extend(batch)
    assert len(completion['trials']) == ready['trials']
    phases = {}
    for phase in ('Down', 'Up'):
        transport_keys = ('transportEnteredAt', 'clientEnteredAt', 'clientSentAt')
        transport_present = [all(key in row['inputMeasurements']['manual' + phase + 'Stages'] for key in transport_keys) for row in rows]
        assert not any(transport_present) or all(transport_present)
        if ready['host']['build'] == 'release-22':
            assert all(transport_present), 'Release-22 must retain all transport diagnostics'
        segments = SEGMENTS
        if all(transport_present):
            segments = SEGMENTS[:2] + [
                ('requestToTransport', 'requestStartedAt', 'transportEnteredAt'),
                ('transportToClient', 'transportEnteredAt', 'clientEnteredAt'),
                ('clientPreparation', 'clientEnteredAt', 'clientSentAt'),
                ('sentToWorkerReceipt', 'clientSentAt', 'workerReceivedAt')] + SEGMENTS[3:]
        collected = {name: [] for name, _, _ in segments}
        for row in rows:
            timing = row['inputMeasurements']

            def value(key):
                return timing.get('manual' + phase + key,
                    timing.get(phase.lower() + key, timing['manual' + phase + 'Stages'].get(key)))

            durations = [(value(end) - value(start)) * 1000 for _, start, end in segments]
            assert all(duration >= 0 for duration in durations)
            assert abs(sum(durations) - row[phase.lower() + 'ReceiptToEnqueueMs']) < 1e-5
            for (name, _, _), duration in zip(segments, durations):
                collected[name].append(duration)
        phases[phase.lower()] = {name: quantiles(values) for name, values in collected.items()}
        phases[phase.lower()]['receiptToEnqueue'] = quantiles([r[phase.lower() + 'ReceiptToEnqueueMs'] for r in rows])
    return {'profile': profile, 'build': ready['host']['build'], 'trials': len(completion['trials']),
            'warmClicks': len(rows), 'allCountersMatched': True, 'allEventsOverlapFault': True,
            'segmentSumCheckedPerEvent': True, 'segments': phases,
            'faultDuration': quantiles([(t['fault']['endedAt'] - t['fault']['startedAt']) * 1000 for t in completion['trials']]),
            'inputSubmissionP95Within10Ms': all(phases[p]['receiptToEnqueue']['p95Ms'] <= 10 for p in ('down', 'up')),
            'metalMetadata': [{'trial': t['trial'], **t['afterStatus']['measurements']} for t in completion['trials']],
            'sourceDirectory': str(directory.resolve())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--standard', type=Path, required=True)
    parser.add_argument('--balanced', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    profiles = {name: analyze(getattr(args, name)) for name in ('standard', 'balanced')}
    assert all(value['profile'] == key and value['trials'] == 10 for key, value in profiles.items())
    assert len({value['build'] for value in profiles.values()}) == 1
    frozen = args.output.with_suffix('.sources')
    frozen.mkdir()
    files = []
    for source in (Path(__file__), Path(__file__).with_name('timeout-isolation.py')):
        target = frozen / source.name
        shutil.copyfile(source, target)
        files.append(target)
    for directory in (args.standard, args.balanced):
        files.extend(path for path in directory.rglob('*') if path.is_file())
    summary = {'profiles': profiles, 'allPerformanceQualified': False, 'goalComplete': False,
               'boundary': 'Only A Inspector is suspended with PID/start/path guards. A hidden, B synchronized visible 401x930. Each profile has ten independent timeouts and thirty actual mouse clicks, with a separate initial warm click. Complete AX effects and fault overlap checked for every click. No continuous capture or profiling. Full NSView receipt-to-native-HID-enqueue is measured; earlier OS dispatch, visible response, physical dragging and simultaneous visible devices are excluded. Metal metadata is diagnostic and does not prove actual unique visible FPS or matching source causality.',
               'sha256': {str(path.resolve()): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(set(files))}}
    args.output.write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({key: {'clicks': value['warmClicks'], 'downP95Ms': value['segments']['down']['receiptToEnqueue']['p95Ms'],
                          'upP95Ms': value['segments']['up']['receiptToEnqueue']['p95Ms']}
                      for key, value in profiles.items()}, indent=2))


if __name__ == '__main__':
    main()
