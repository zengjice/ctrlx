#!/usr/bin/env python3
"""Correlate completed frame-callback work with diagnostic mouse input waits."""
import argparse
import json
import math
from pathlib import Path


STAGES = ('taskStartedAt', 'requestStartedAt', 'transportEnteredAt',
          'clientEnteredAt', 'clientSentAt', 'workerReceivedAt', 'workerStartedAt')


def analyze(path):
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    assert rows, path
    events = []
    callbacks = set()
    previous_up = 0
    for index, row in enumerate(rows):
        assert row['index'] == index and row['writer'] == 'human' and not row['partial']
        assert row['tapCount'] == row['initialCount'] + index + 1
        timing = row['inputMeasurements']
        assert timing['manualDownReceivedAt'] > previous_up
        previous_up = timing['manualUpReceivedAt']
        assert timing['manualDownEnqueuedAt'] <= timing['upSubmittedAt']
        for phase in ('Down', 'Up'):
            stages = timing['manual' + phase + 'Stages']
            stamps = [timing['manual' + phase + 'ReceivedAt']]
            stamps.extend(stages[key] for key in STAGES)
            stamps.extend((timing[phase.lower() + 'SubmittedAt'], timing['manual' + phase + 'EnqueuedAt']))
            assert all(isinstance(t, (int, float)) and math.isfinite(t) for t in stamps)
            assert all(a <= b for a, b in zip(stamps, stamps[1:]))
            total = (stamps[-1] - stamps[0]) * 1000
            assert abs(total - row[phase.lower() + 'ReceiptToEnqueueMs']) < 1e-5
            diagnostics = timing['manual' + phase + 'FrameDiagnostics']
            history = diagnostics['history']
            assert diagnostics['capacity'] == 64 and 0 < len(history) <= 64
            assert math.isfinite(diagnostics['recordedAt'])
            assert all(len(pair) == 2 and all(math.isfinite(t) for t in pair) and pair[0] <= pair[1]
                       for pair in history)
            assert all(a[1] <= b[0] for a, b in zip(history, history[1:]))
            assert history[-1][1] <= diagnostics['recordedAt']
            assert stages['workerReceivedAt'] <= diagnostics['recordedAt']
            callbacks.update(tuple(pair) for pair in history)
            sent, received = stages['clientSentAt'], stages['workerReceivedAt']
            overlap = [(max(start, sent), min(end, received)) for start, end in history
                       if start < received and end > sent]
            overlap_ms = sum(end - start for start, end in overlap) * 1000
            wait_ms = (received - sent) * 1000
            assert 0 <= overlap_ms <= wait_ms + 1e-5
            events.append({'index': index, 'phase': phase.lower(), 'receiptToHIDMs': total,
                           'sentToWorkerMs': wait_ms,
                           'workerQueueMs': (stages['workerStartedAt'] - received) * 1000,
                           'retainedHistoryStartsBeforeSend': history[0][0] <= sent,
                           'completedFrameWorkOverlapMs': overlap_ms,
                           'overlappingCompletedIntervals': overlap})
    durations = sorted((end - start) * 1000 for start, end in callbacks)
    return {'file': str(path.resolve()), 'effects': len(rows), 'events': events,
            'completedCallbackSamples': len(durations),
            'completedCallbackP95Ms': durations[int(len(durations) * .95)],
            'completedCallbackMaxMs': durations[-1],
            'slowestTransportEvents': sorted(events, key=lambda e: e['sentToWorkerMs'], reverse=True)[:10]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rows', type=Path, nargs='+', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    results = [analyze(path) for path in args.rows]
    output = {'files': results, 'actualEffects': sum(r['effects'] for r in results),
              'scope': 'Diagnostic correlation only; excluded from performance acceptance. '
                       'Records completed frame-construction and handler-call work, excluding timing bookkeeping, '
                       'handler return, XPC internal dispatch and callbacks still active at snapshot. '
                       'A short or absent recorded overlap cannot exclude queued handlers or unrecorded active work. '
                       'Overlap alone does not prove causality; no tails removed.',
              'productQualified': False, 'allPerformanceQualified': False, 'goalComplete': False}
    args.output.write_text(json.dumps(output, indent=2) + '\n')
    print(json.dumps([{k: r[k] for k in ('file', 'effects', 'completedCallbackP95Ms',
                                       'completedCallbackMaxMs', 'slowestTransportEvents')}
                      for r in results], indent=2))


if __name__ == '__main__':
    main()
