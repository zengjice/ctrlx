"""Resolve the project's iOS entitlement claims against a provisioning profile."""
import argparse
import fnmatch
from pathlib import Path
import plistlib


def signing_entitlements(profile, requested, bundle_id, team, signing_mode=None):
    if profile['TeamIdentifier'] != [team]:
        raise ValueError('Provisioning profile belongs to another team.')
    prefix = profile['ApplicationIdentifierPrefix'][0] + '.'
    granted = profile['Entitlements']
    if granted['application-identifier'] != prefix + bundle_id:
        raise ValueError('Provisioning profile does not match the bundle ID.')

    def resolve(value):
        if isinstance(value, str):
            value = value.replace('$(AppIdentifierPrefix)', prefix)
            value = value.replace('$(TeamIdentifierPrefix)', team + '.')
            if '$(' in value or '*' in value:
                raise ValueError('App entitlement must be concrete: ' + value)
        elif isinstance(value, list):
            value = [resolve(item) for item in value]
        return value

    def authorized(claim, allowance):
        if isinstance(claim, list):
            return isinstance(allowance, list) and all(
                any(authorized(item, candidate) for candidate in allowance) for item in claim
            )
        if isinstance(claim, str) and isinstance(allowance, str):
            return fnmatch.fnmatchcase(claim, allowance)
        return claim == allowance

    result = {key: resolve(value) for key, value in requested.items()}
    if signing_mode is not None:
        environment = {'development': 'development', 'ad-hoc': 'production'}[signing_mode]
        if 'aps-environment' in result:
            result['aps-environment'] = environment
    for key, value in result.items():
        if key not in granted or not authorized(value, granted[key]):
            raise ValueError('Provisioning profile does not authorize entitlement: ' + key)
    for key in ('application-identifier', 'com.apple.developer.team-identifier', 'get-task-allow'):
        result[key] = granted[key]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--requested', type=Path, required=True)
    parser.add_argument('--bundle-id', required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = signing_entitlements(plistlib.loads(args.profile.read_bytes()),
                                  plistlib.loads(args.requested.read_bytes()), args.bundle_id, args.team)
    args.output.write_bytes(plistlib.dumps(result))


if __name__ == '__main__':
    main()
