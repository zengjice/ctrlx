"""Submit or resume a notarization; retain its identity before waiting."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def command(*args):
    result = subprocess.run(['/usr/bin/xcrun', 'notarytool', *map(str, args),
                             '--output-format', 'json'], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return json.loads(result.stdout)


def notarize(artifact, profile, report):
    digest = hashlib.sha256()
    with artifact.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    checksum = digest.hexdigest()
    if report.exists():
        state = json.loads(report.read_text())
        if state['sha256'] != checksum or state['profile'] != profile:
            raise ValueError('Notarization report belongs to another artifact/profile; use a new report path.')
    else:
        submitted = command('submit', artifact, '--keychain-profile', profile)
        state = {'artifact': str(artifact.resolve()), 'sha256': checksum, 'profile': profile,
                 'id': submitted['id'], 'status': 'Submitted'}
        report.parent.mkdir(parents=True, exist_ok=True)
        report.write_text(json.dumps(state, indent=2) + '\n')
    print('Notarization submission: ' + state['id'], flush=True)
    response = command('info', state['id'], '--keychain-profile', profile)
    if response['status'] == 'In Progress':
        # A wait timeout keeps the submission ID; rerunning resumes the same job.
        response = command('wait', state['id'], '--keychain-profile', profile, '--timeout', '10m')
    state['status'] = response['status']
    report.write_text(json.dumps(state, indent=2) + '\n')
    if state['status'] != 'Accepted':
        log = report.with_suffix('.log.json')
        subprocess.run(['/usr/bin/xcrun', 'notarytool', 'log', state['id'],
                        '--keychain-profile', profile, str(log)], check=True)
        raise ValueError(f'Notarization {state["status"]}; inspect {log}')
    print('Notarization Accepted: ' + str(artifact), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    parser.add_argument('--profile', required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    notarize(args.artifact, args.profile, args.report)


if __name__ == '__main__':
    main()
