"""Qualify one native-frame interval under an explicitly selected display condition."""
import argparse
import json
from pathlib import Path

from display_conditions import require_fixed_display


LATENCY_LIMIT_MS = {'synchronized': 100, 'low-latency': 100}
MINIMUM_FPS = 50


def percentile(values, fraction):
    values = sorted(values)
    position = (len(values) - 1) * fraction
    low = int(position)
    high = min(low + 1, len(values) - 1)
    return values[low] + (values[high] - values[low]) * (position - low)


def qualify_native_interval(initial, final, begin, end, *, display_id, maximum_fps, mode):
    if end - begin < 60:
        raise ValueError('A display qualification interval must span at least 60 seconds')
    if mode not in LATENCY_LIMIT_MS:
        raise ValueError('Unknown display mode')
    condition = require_fixed_display(initial, final, begin, end,
                                      display_id=display_id, maximum_fps=maximum_fps)
    for key in ('device', 'udid', 'runtime', 'profile'):
        if initial[key] != final[key]:
            raise ValueError(f'Device context changed: {key}')
    for status in (initial, final):
        if status['displayMode'] != mode or status['view']['displaySyncEnabled'] != (mode == 'synchronized'):
            raise ValueError('Recorded display mode differs from the requested mode')
        if not all(status['view'][key] for key in ('visible', 'inputReady')):
            raise ValueError('View is not visible and ready at both endpoints')
        if not all(status['renderState'][key] for key in ('appActive', 'windowMain', 'windowKey')):
            raise ValueError('Window is not active at both endpoints')
    if any(initial['view'][key] != final['view'][key] for key in ('width', 'height')):
        raise ValueError('Viewport changed')
    trace = final['sourceFrameTrace']
    if trace['droppedRows']:
        raise ValueError('Source trace is incomplete; reset measurements before sampling')
    source = {row['sequence']: row for row in trace['rows']}
    rows = final['renderLifecycle']['rows']
    submitted = [row for row in rows if begin <= row['submittedAt'] < end]
    if any(row['presentationCallbackAt'] <= 0 or row['gpuStatus'] != 4 for row in submitted):
        raise ValueError('Submitted frame has an unfinished callback or unsuccessful GPU command')
    unique = {}
    for row in sorted(rows, key=lambda row: row['presentedAt']):
        if not begin <= row['presentedAt'] < end:
            continue
        original = source[row['sequence']]
        if original['sourceSequence'] != row['sourceSequence']:
            raise ValueError('Source identity mismatch')
        if not original['wordHex'] or original['wordHex'] != original['copiedWordHex']:
            raise ValueError('Source and copied frame content differ')
        if original['seedBefore'] != original['seedAfter']:
            raise ValueError('Source surface changed while being read')
        if row['gpuStatus'] != 4 or not (
            original['sourceAt'] <= original['copyReadyAt'] <= original['receivedAt']
            <= row['submittedAt'] <= row['gpuStartedAt'] <= row['gpuEndedAt'] <= row['presentedAt']
        ):
            raise ValueError('Native frame chronology is invalid')
        unique.setdefault(original['wordHex'], {'sourceAt': original['sourceAt'], **row})
    if not unique:
        raise ValueError('No corresponding positive native presentations')
    seconds = end - begin
    source_words = {row['wordHex'] for row in trace['rows'] if begin <= row['sourceAt'] < end}
    fps = len(unique) / seconds
    source_fps = len(source_words) / seconds
    latency = percentile([(row['presentedAt'] - row['sourceAt']) * 1000 for row in unique.values()], .95)
    return {
        'displayCondition': condition, 'mode': mode, 'seconds': seconds,
        'positiveUniqueFrames': len(unique), 'positiveNativeFPS': fps, 'sourceUniqueFPS': source_fps,
        'minimumFPS': MINIMUM_FPS,
        'sourceToNativeP95Ms': latency, 'latencyTargetMs': LATENCY_LIMIT_MS[mode],
        'zeroPresentedCallbacks': sum(row['presentedAt'] == 0 for row in submitted),
        'passed': fps >= MINIMUM_FPS and source_fps >= MINIMUM_FPS and latency <= LATENCY_LIMIT_MS[mode],
        'physicalPanelMeasured': False, 'completeDisplayMatrixQualified': False,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--initial', type=Path, required=True)
    parser.add_argument('--final', type=Path, required=True)
    parser.add_argument('--begin', type=float, required=True)
    parser.add_argument('--end', type=float, required=True)
    parser.add_argument('--display-id', type=int, required=True)
    parser.add_argument('--maximum-fps', type=int, required=True)
    parser.add_argument('--mode', choices=LATENCY_LIMIT_MS, required=True)
    args = parser.parse_args()
    try:
        result = qualify_native_interval(json.loads(args.initial.read_text()), json.loads(args.final.read_text()),
                                         args.begin, args.end, display_id=args.display_id,
                                         maximum_fps=args.maximum_fps, mode=args.mode)
    except (KeyError, ValueError) as error:
        parser.error(str(error))
    print(json.dumps(result))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
