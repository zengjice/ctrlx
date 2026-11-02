"""Developer ID signing and verification for CtrlX and its embedded native code."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess


ROOT = Path(__file__).resolve().parent.parent
MACHO = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
         b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
         b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
JIT_HELPERS = {'CtrlX Agent Browser Helper (Renderer).app', 'CtrlX Agent Browser Helper (GPU).app'}
ENGINE_SHA256 = '2e61287259053ea964d39e77002c6a34af0e589e55ccff25e659efae7e892e0d'
ENGINE_IDENTIFIER = 'com.ctrlx.agent-browser-engine.' + ENGINE_SHA256


def is_engine(path):
    return path.name == 'agent-browser' and path.parent.name == 'AgentBrowserEngine'


def run(*args):
    result = subprocess.run(list(map(str, args)), capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors='replace').strip() or f'{args[0]} failed ({result.returncode})')
    return result


def is_macho(path):
    with path.open('rb') as stream:
        return stream.read(4) in MACHO


def bundle_executable(bundle):
    framework = bundle.suffix == '.framework'
    info = bundle / ('Resources/Info.plist' if framework else 'Contents/Info.plist')
    if not info.is_file():
        return None
    name = plistlib.loads(info.read_bytes()).get('CFBundleExecutable')
    if not name or Path(name).name != name:
        return None
    executable = bundle / name if framework else bundle / 'Contents/MacOS' / name
    return executable.resolve() if executable.is_file() and is_macho(executable) else None


def signing_plan(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Expected a real staged code directory.')
    files, bundles = [], {}
    for directory, names, filenames in os.walk(root, followlinks=False):
        path = Path(directory)
        if path.suffix in {'.app', '.framework', '.xpc', '.bundle'}:
            executable = bundle_executable(path)
            if executable:
                executable.relative_to(root.resolve())
                bundles[path] = executable
        for name in sorted(filenames):
            file = path / name
            if not file.is_symlink() and is_macho(file):
                files.append(file)
    primary = set(bundles.values())
    plan = [(file, 'executable' in run('/usr/bin/file', '-b', file).stdout.decode(), {})
            for file in sorted(files) if file.resolve() not in primary]
    for bundle in sorted(bundles, key=lambda p: (-len(p.parts), str(p))):
        entitlements = {}
        if bundle == root and bundle.suffix == '.app':
            entitlements = plistlib.loads((ROOT / 'Config/CtrlxServer.entitlements').read_bytes())
        elif bundle.name in JIT_HELPERS:
            entitlements = {'com.apple.security.cs.allow-jit': True}
        plan.append((bundle, bundle.suffix != '.framework', entitlements))
    if not plan:
        raise ValueError('No native code found to sign or verify.')
    return plan


def verify_component(path, executable, entitlements, team):
    run('/usr/bin/codesign', '--verify', '--strict', path)
    details = run('/usr/bin/codesign', '--display', '--verbose=4', path).stderr.decode()
    for required in ['Authority=Developer ID Application:', 'TeamIdentifier=' + team, 'Timestamp=']:
        if not any(line.startswith(required) for line in details.splitlines()):
            raise ValueError(f'{path}: missing {required}')
    if executable and not re.search(r'flags=.*\(.*\bruntime\b.*\)', details):
        raise ValueError(f'{path}: Hardened Runtime is missing.')
    if is_engine(path) and 'Identifier=' + ENGINE_IDENTIFIER not in details.splitlines():
        raise ValueError(f'{path}: pinned engine signing identifier is missing.')
    raw = run('/usr/bin/codesign', '--display', '--entitlements', ':-', path).stdout
    actual = plistlib.loads(raw) if raw.strip() else {}
    if actual != entitlements:
        raise ValueError(f'{path}: unexpected release entitlements: {sorted(actual)}')


def process(root, team, identity=None):
    import tempfile
    plan = signing_plan(root)
    with tempfile.TemporaryDirectory(prefix='ctrlx-entitlements-') as directory:
        for index, (path, executable, entitlements) in enumerate(plan):
            if identity:
                command = ['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp']
                if is_engine(path):
                    # Only attest verified upstream bytes or our intact prior signature.
                    if hashlib.sha256(path.read_bytes()).hexdigest() != ENGINE_SHA256:
                        verify_component(path, True, {}, team)
                    command += ['--identifier', ENGINE_IDENTIFIER]
                if executable:
                    command += ['--options', 'runtime']
                # An explicit empty dictionary also removes old debug entitlements.
                file = Path(directory) / f'{index}.plist'
                file.write_bytes(plistlib.dumps(entitlements))
                run(*command, '--entitlements', file, path)
            verify_component(path, executable, entitlements, team)
    if root.suffix == '.app':
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', root)
    print(f'Verified {len(plan)} Developer ID components for team {team}.', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['sign', 'verify'])
    parser.add_argument('root', type=Path)
    parser.add_argument('--team', required=True)
    parser.add_argument('--identity')
    args = parser.parse_args()
    if args.operation == 'sign' and not args.identity:
        parser.error('sign requires --identity')
    process(args.root.absolute(), args.team, args.identity if args.operation == 'sign' else None)


if __name__ == '__main__':
    main()
