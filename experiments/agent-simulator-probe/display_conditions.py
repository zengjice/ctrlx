"""Require one explicit display condition throughout a native-frame interval."""
import argparse
import json
from pathlib import Path


FIELDS = ('screenDisplayID', 'screenMaximumFPS', 'contentsScale', 'drawableWidth', 'drawableHeight')


def signature(record):
    values = tuple(record.get(key) for key in FIELDS)
    if any(value is None or value <= 0 for value in values):
        raise ValueError('Missing or invalid display identity, maximum FPS, scale, or drawable size')
    return values


def require_fixed_display(initial, final, begin, end, *, display_id, maximum_fps):
    if not begin < end:
        raise ValueError('Display interval must have a positive duration')
    expected = signature(initial['renderState'])
    if expected[:2] != (display_id, maximum_fps):
        raise ValueError(f'Initial display differs from the requested condition: {expected}')
    if signature(final['renderState']) != expected:
        raise ValueError('Display condition changed between interval endpoints')
    lifecycle = final['renderLifecycle']
    if lifecycle['schemaVersion'] != 3:
        raise ValueError('Native lifecycle schema 3 is required for per-frame display qualification')
    rows = lifecycle['rows']
    if not rows or rows[0]['submittedAt'] >= begin or rows[-1]['submittedAt'] < end:
        raise ValueError('Retained native lifecycle does not cover the complete interval')
    submitted = [row for row in rows if begin <= row['submittedAt'] < end]
    if not submitted:
        raise ValueError('No native submissions in the requested interval')
    ids = [row['id'] for row in submitted]
    if ids != list(range(ids[0], ids[-1] + 1)):
        raise ValueError('Native lifecycle has missing or unordered submissions')
    contributing = [row for row in rows if begin <= row['submittedAt'] < end
                    or begin <= row.get('presentedAt', 0) < end]
    for row in contributing:
        if signature(row) != expected:
            raise ValueError(f'Display condition changed at native submission {row["id"]}')
    return {**dict(zip(FIELDS, expected)), 'begin': begin, 'end': end,
            'submissionsChecked': len(submitted), 'fixedDisplayAtEverySubmission': True,
            'contributingNativeFramesChecked': len(contributing),
            'maximumFPSIsNotMeasuredRefreshCadence': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--initial', type=Path, required=True)
    parser.add_argument('--final', type=Path, required=True)
    parser.add_argument('--begin', type=float, required=True)
    parser.add_argument('--end', type=float, required=True)
    parser.add_argument('--display-id', type=int, required=True)
    parser.add_argument('--maximum-fps', type=int, required=True)
    args = parser.parse_args()
    result = require_fixed_display(json.loads(args.initial.read_text()), json.loads(args.final.read_text()),
                                   args.begin, args.end, display_id=args.display_id, maximum_fps=args.maximum_fps)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
