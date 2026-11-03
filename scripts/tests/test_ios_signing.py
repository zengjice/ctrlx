"""iOS profiles authorize concrete claims; they are not signing entitlements."""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ios_signing import signing_entitlements


class IOSSigningTests(unittest.TestCase):
    def setUp(self):
        self.team = 'NEWTEAM123'
        self.bundle_id = 'com.example.ctrlx'
        self.profile = {
            'TeamIdentifier': [self.team], 'ApplicationIdentifierPrefix': ['LEGACYPREFIX'],
            'Entitlements': {
                'application-identifier': 'LEGACYPREFIX.' + self.bundle_id,
                'com.apple.developer.team-identifier': self.team, 'get-task-allow': True,
                'keychain-access-groups': ['LEGACYPREFIX.*', 'com.apple.token'],
                'com.apple.security.application-groups': ['group.com.example.ctrlx'],
                'aps-environment': 'development',
                'unrequested-service': True,
            },
        }
        self.requested = {
            'keychain-access-groups': ['$(AppIdentifierPrefix)com.example.ctrlx.shared'],
            'com.apple.security.application-groups': ['group.com.example.ctrlx'],
            'aps-environment': 'development',
        }

    def sign(self, profile=None, requested=None, bundle_id=None, team=None):
        return signing_entitlements(profile or self.profile, requested or self.requested,
                                    bundle_id or self.bundle_id, team or self.team)

    def test_claims_are_concrete_and_do_not_inherit_unused_profile_permissions(self):
        result = self.sign()
        self.assertEqual(result['keychain-access-groups'], ['LEGACYPREFIX.com.example.ctrlx.shared'])
        self.assertEqual(result['application-identifier'], 'LEGACYPREFIX.com.example.ctrlx')
        self.assertEqual(result['com.apple.developer.team-identifier'], self.team)
        self.assertTrue(result['get-task-allow'])
        self.assertNotIn('unrequested-service', result)

    def test_app_and_extension_use_the_same_concrete_default_keychain_group(self):
        extension = copy.deepcopy(self.profile)
        extension['Entitlements']['application-identifier'] += '.notification-service'
        requested = dict(self.requested)
        requested.pop('aps-environment')
        result = self.sign(profile=extension, requested=requested, bundle_id=self.bundle_id + '.notification-service')
        self.assertEqual(result['keychain-access-groups'], self.sign()['keychain-access-groups'])
        self.assertNotIn('aps-environment', result)

    def test_other_team_and_other_bundle_are_rejected(self):
        for overrides in ({'team': 'OTHERTEAM1'}, {'bundle_id': 'com.example.other'}):
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                self.sign(**overrides)

    def test_missing_push_or_sharing_permissions_are_rejected(self):
        for key in self.requested:
            profile = copy.deepcopy(self.profile)
            del profile['Entitlements'][key]
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.sign(profile=profile)

    def test_unauthorized_environment_and_groups_are_rejected(self):
        for key, value in [('aps-environment', 'production'),
                           ('keychain-access-groups', ['OTHERTEAM1.com.example.ctrlx.shared']),
                           ('com.apple.security.application-groups', ['group.com.example.other'])]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.sign(requested=dict(self.requested, **{key: value}))

    def test_wildcards_and_unresolved_build_settings_are_rejected(self):
        for group in ['$(AppIdentifierPrefix)*', '$(UNKNOWN)com.example.ctrlx.shared']:
            with self.subTest(group=group), self.assertRaises(ValueError):
                self.sign(requested={'keychain-access-groups': [group]})

    def test_ad_hoc_resolves_production_push_without_copying_other_profile_permissions(self):
        profile = copy.deepcopy(self.profile)
        profile['Entitlements'].update({'aps-environment': 'production', 'get-task-allow': False})
        result = signing_entitlements(profile, self.requested, self.bundle_id, self.team, 'ad-hoc')
        self.assertEqual(result['aps-environment'], 'production')
        self.assertFalse(result['get-task-allow'])
        self.assertNotIn('unrequested-service', result)

    def test_ad_hoc_does_not_accept_a_development_push_profile(self):
        with self.assertRaisesRegex(ValueError, 'aps-environment'):
            signing_entitlements(self.profile, self.requested, self.bundle_id, self.team, 'ad-hoc')


if __name__ == '__main__':
    unittest.main()
