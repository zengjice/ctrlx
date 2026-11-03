"""Prepare matching iOS development or Ad Hoc signing inputs before compilation."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

from ios_signing import signing_entitlements


def select_profiles(profiles, identities, team, bundles, requested, mode, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    certificate_names = ('Apple Development:', 'iPhone Developer:') if mode == 'development' else (
        'Apple Distribution:', 'iPhone Distribution:')
    available = {
        digest.upper() for digest, name in re.findall(r'([A-Fa-f0-9]{40}) "([^"]+)"', identities)
        if name.startswith(certificate_names)
    }
    if not available:
        raise ValueError('No installed signing identity with a private key for ' + mode + '.')
    candidates = {role: [] for role in bundles}
    for path, profile in profiles:
        expiry = profile['ExpirationDate'].replace(tzinfo=datetime.timezone.utc)
        if (expiry <= now or not profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices')
                or profile['Entitlements'].get('get-task-allow') is not (mode == 'development')):
            continue
        certificates = {hashlib.sha1(value).hexdigest().upper() for value in profile['DeveloperCertificates']}
        certificates &= available
        if not certificates:
            continue
        for role, bundle in bundles.items():
            try:
                claims = signing_entitlements(profile, requested[role], bundle, team, mode)
            except ValueError:
                continue
            candidates[role].append((expiry, str(path), profile, claims, certificates))
    for app in sorted(candidates['app'], key=lambda x: (x[0], x[1]), reverse=True):
        for extension in sorted(candidates['extension'], key=lambda x: (x[0], x[1]), reverse=True):
            common = app[4] & extension[4]
            if (common and app[3]['keychain-access-groups'] == extension[3]['keychain-access-groups']
                    and app[3]['com.apple.security.application-groups'] == extension[3]['com.apple.security.application-groups']
                    and set(app[2]['ProvisionedDevices']) & set(extension[2]['ProvisionedDevices'])):
                return {'app': app, 'extension': extension}, sorted(common)[0]
    raise ValueError('No matching ' + mode + ' app/extension profiles with an installed shared signing identity, '
                     'valid expiry, registered devices, push and sharing capabilities for team ' + team + '.')


def installed_profiles(directories):
    for directory in directories:
        for path in sorted(directory.glob('*.mobileprovision')):
            result = subprocess.run(['/usr/bin/security', 'cms', '-D', '-i', str(path)], capture_output=True)
            if result.returncode == 0:
                yield path, plistlib.loads(result.stdout)


def prepare(args):
    directories = [Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles',
                   Path.home() / 'Library/MobileDevice/Provisioning Profiles']
    identities = subprocess.run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'],
                                check=True, capture_output=True, text=True).stdout
    bundles = {'app': args.app_bundle_id, 'extension': args.extension_bundle_id}
    requested = {role: plistlib.loads(path.read_bytes()) for role, path in (
        ('app', args.app_entitlements), ('extension', args.extension_entitlements))}
    profiles, identity = select_profiles(installed_profiles(directories), identities, args.team, bundles,
                                        requested, args.signing_mode)
    metadata = {'mode': args.signing_mode, 'team': args.team, 'identity': identity, 'profiles': {}}
    for role, (_, path, profile, claims, _) in profiles.items():
        shutil.copyfile(path, args.output_directory / (role + '.mobileprovision'))
        (args.output_directory / (role + '-entitlements.plist')).write_bytes(plistlib.dumps(claims))
        metadata['profiles'][role] = {'name': profile['Name'], 'uuid': profile['UUID'],
                                      'expires': profile['ExpirationDate'].isoformat(),
                                      'devices': profile['ProvisionedDevices']}
    (args.output_directory / 'signing.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print('Signing: ' + args.signing_mode + ' · team ' + args.team)
    for role, profile in metadata['profiles'].items():
        print(role + ' profile: ' + profile['name'] + ' · expires ' + profile['expires'])


def verify(args):
    for role, app in (('app', args.app), ('extension', args.app / 'PlugIns/CtrlxNotificationExtension.appex')):
        expected = plistlib.loads((args.output_directory / (role + '-entitlements.plist')).read_bytes())
        result = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)],
                                check=True, capture_output=True)
        if plistlib.loads(result.stdout) != expected:
            raise ValueError('Signed ' + role + ' entitlements do not match the prepared signing claims.')
    print('Verified signed app/extension entitlements, including APNs environment.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    command = commands.add_parser('prepare')
    command.add_argument('--team', required=True)
    command.add_argument('--signing-mode', choices=('development', 'ad-hoc'), required=True)
    command.add_argument('--app-bundle-id', required=True)
    command.add_argument('--extension-bundle-id', required=True)
    command.add_argument('--app-entitlements', type=Path, required=True)
    command.add_argument('--extension-entitlements', type=Path, required=True)
    command = commands.add_parser('verify')
    command.add_argument('--app', type=Path, required=True)
    for command in commands.choices.values():
        command.add_argument('--output-directory', type=Path, required=True)
    args = parser.parse_args()
    try:
        (prepare if args.command == 'prepare' else verify)(args)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, 'ERROR: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
