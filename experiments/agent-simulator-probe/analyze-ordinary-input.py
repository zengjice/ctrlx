#!/usr/bin/env python3
"""Validate consecutive real mouse effects and receipt-to-HID timing rounds."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


STAGES = ('taskStartedAt', 'requestStartedAt', 'transportEnteredAt',
          'clientEnteredAt', 'clientSentAt', 'workerReceivedAt', 'workerStartedAt')
SEGMENTS = ('receiptToTask', 'priorTaskAndRouting', 'requestToTransport',
            'transportToClient', 'clientPreparation', 'sentToWorkerReceipt',
            'workerQueue', 'workerProcessing', 'nativeSend')


def quantiles(values):
    values = sorted(values)
    assert values
    return {'samples': len(values), 'p50Ms': values[len(values) // 2],
            'p95Ms': values[int(len(values) * .95)],
            'p99Ms': values[int(len(values) * .99)], 'maxMs': values[-1]}


def analyze(directory, profile, number):
    metadata = json.loads((directory / 'round.json').read_text())
    rows = [json.loads(line) for line in (directory / 'input-rows.jsonl').read_text().splitlines()]
    assert metadata['profile'] == profile and metadata['round'] == number
    assert metadata['durationMs'] >= 60000 and len(rows) >= 30
    assert metadata['samples'] == len(rows)
    for status in (metadata['beginStatus'], metadata['endStatus']):
        view = status['view']
        assert view['visible'] and view['inputReady'] and view['displaySyncEnabled']
        assert view['width'] == 401 and view['height'] == 930
        assert status['device'] == metadata['device'] and status['profile'] == profile
    previous = metadata['beginStatus']['inputMeasurements']['manualUpReceivedAt']
    for index, row in enumerate(rows):
        assert row['index'] == index and row['round'] == number and row['profile'] == profile
        assert row['device'] == metadata['device'] and row['writer'] == 'human'
        assert not row['partial'] and row['initialCount'] == metadata['initialCount']
        assert row['tapCount'] == metadata['initialCount'] + index + 1
        timing = row['inputMeasurements']
        assert timing['manualDownReceivedAt'] > previous
        assert timing['manualUpReceivedAt'] >= timing['manualDownReceivedAt']
        previous = timing['manualUpReceivedAt']
    assert metadata['finalCount'] == metadata['initialCount'] + len(rows)
    assert metadata['endStatus']['inputMeasurements']['manualUpReceivedAt'] == previous
    phases = {}
    for phase in ('Down', 'Up'):
        collected = {name: [] for name in SEGMENTS}
        totals = []
        for row in rows:
            timing = row['inputMeasurements']
            stamps = [timing['manual' + phase + 'ReceivedAt']]
            stamps.extend(timing['manual' + phase + 'Stages'][key] for key in STAGES)
            stamps.extend((timing[phase.lower() + 'SubmittedAt'], timing['manual' + phase + 'EnqueuedAt']))
            durations = [(end - start) * 1000 for start, end in zip(stamps, stamps[1:])]
            assert all(duration >= 0 for duration in durations)
            total = row[phase.lower() + 'ReceiptToEnqueueMs']
            assert abs(sum(durations) - total) < 1e-5
            for name, duration in zip(SEGMENTS, durations):
                collected[name].append(duration)
            totals.append(total)
        phases[phase.lower()] = {name: quantiles(values) for name, values in collected.items()}
        phases[phase.lower()]['receiptToEnqueue'] = quantiles(totals)
    return {'profile': profile, 'round': number, 'device': metadata['device'],
            'seconds': metadata['durationMs'] / 1000, 'clicks': len(rows),
            'initialCount': metadata['initialCount'], 'finalCount': metadata['finalCount'],
            'allCountersMatched': True, 'segmentSumCheckedPerEvent': True,
            'segments': phases, 'inputSubmissionP95Within10Ms': all(
                phases[p]['receiptToEnqueue']['p95Ms'] <= 10 for p in ('down', 'up'))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    assert not args.output.exists()
    profiles = {}
    for profile in ('standard', 'balanced'):
        first_rows = [json.loads(line) for line in
            (args.directory / (profile + '-first') / (profile + '-manual-input-rows.jsonl')).read_text().splitlines()]
        assert len(first_rows) == 1
        first = first_rows[0]
        assert first['round'] == 0 and first['profile'] == profile and not first['partial']
        assert first['tapCount'] == first['initialCount'] + 1
        rounds = [analyze(args.directory / f'{profile}-round-{number}', profile, number)
                  for number in (1, 2, 3)]
        assert all(r['device'] == first['device'] for r in rounds)
        assert rounds[0]['initialCount'] == first['tapCount']
        assert all(a['finalCount'] == b['initialCount'] for a, b in zip(rounds, rounds[1:]))
        profiles[profile] = {'firstClick': first, 'rounds': rounds,
                             'allThreeRoundsWithin10Ms': all(r['inputSubmissionP95Within10Ms'] for r in rounds)}
    frozen = args.output.with_suffix('.sources')
    frozen.mkdir()
    shutil.copyfile(__file__, frozen / Path(__file__).name)
    files = [path for path in args.directory.rglob('*') if path.is_file()]
    files.append(frozen / Path(__file__).name)
    result = {'build': 'release-22', 'profiles': profiles,
              'ordinarySingleInputSubmissionQualified': all(p['allThreeRoundsWithin10Ms'] for p in profiles.values()),
              'allPerformanceQualified': False, 'goalComplete': False,
              'scope': 'Two profiles, three rounds each of at least sixty seconds and thirty actual mouse clicks. First clicks kept separate. Every effect checked through complete AX and human writer. All nine event timing segments checked without tail removal. Computer Use takes a state image after each click; no continuous window/display capture, profiling, compilation or simulator screenshot API calls. Measures NSView event receipt through native HID enqueue; excludes earlier OS dispatch, actual visible response, frame causality, simultaneous devices and physical dragging.',
              'sha256': {str(path.resolve()): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(files)}}
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({profile: [{'round': r['round'], 'clicks': r['clicks'],
        'downP95Ms': r['segments']['down']['receiptToEnqueue']['p95Ms'],
        'upP95Ms': r['segments']['up']['receiptToEnqueue']['p95Ms']}
        for r in p['rounds']] for profile, p in profiles.items()}, indent=2))


if __name__ == '__main__':
    main()
