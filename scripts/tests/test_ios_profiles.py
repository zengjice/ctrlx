"""Signing preflight rejects mismatched distribution profiles before a build."""
import copy
import datetime
import hashlib
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ios_profiles import select_profiles


class IOSProfilesTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.datetime(2026, 11, 3, tzinfo=datetime.timezone.utc)
        self.team = 'TEAM123456'
        self.bundles = {'app': 'com.example.ctrlx', 'extension': 'com.example.ctrlx.notification-service'}
        self.requested = {role: {'keychain-access-groups': ['$(AppIdentifierPrefix)com.example.shared'],
                                'com.apple.security.application-groups': ['group.com.example.ctrlx']}
                          for role in self.bundles}
        self.requested['app']['aps-environment'] = 'development'
        self.cert = b'fixture-distribution-certificate'
        self.digest = hashlib.sha1(self.cert).hexdigest().upper()
        self.identities = '1) ' + self.digest + ' "Apple Distribution: Fixture"'
        self.profiles = [(Path(role + '.mobileprovision'), {
            'Name': role, 'UUID': role, 'TeamIdentifier': [self.team],
            'ApplicationIdentifierPrefix': [self.team], 'DeveloperCertificates': [self.cert],
            'ProvisionedDevices': ['IPHONE'], 'ExpirationDate': datetime.datetime(2027, 11, 3),
            'Entitlements': {'application-identifier': self.team + '.' + bundle,
                             'com.apple.developer.team-identifier': self.team, 'get-task-allow': False,
                             'keychain-access-groups': [self.team + '.*'],
                             'com.apple.security.application-groups': ['group.com.example.ctrlx'],
                             **({'aps-environment': 'production'} if role == 'app' else {})},
        }) for role, bundle in self.bundles.items()]

    def select(self, profiles=None, identities=None, mode='ad-hoc'):
        return select_profiles(self.profiles if profiles is None else profiles,
                               identities if identities is not None else self.identities,
                               self.team, self.bundles, self.requested, mode, self.now)

    def test_ad_hoc_selects_common_installed_identity_and_concrete_production_claims(self):
        profiles, identity = self.select()
        self.assertEqual(identity, self.digest)
        self.assertEqual(profiles['app'][3]['aps-environment'], 'production')
        self.assertFalse(profiles['app'][3]['get-task-allow'])
        self.assertNotIn('aps-environment', profiles['extension'][3])

    def test_development_still_works_but_is_not_selected_for_ad_hoc(self):
        profiles = copy.deepcopy(self.profiles)
        for _, profile in profiles:
            profile['Entitlements']['get-task-allow'] = True
        profiles[0][1]['Entitlements']['aps-environment'] = 'development'
        identities = self.identities.replace('Apple Distribution:', 'Apple Development:')
        self.assertEqual(self.select(profiles, identities, mode='development')[1], self.digest)
        with self.assertRaises(ValueError):
            self.select(profiles)
        with self.assertRaisesRegex(ValueError, 'No installed signing identity'):
            self.select(identities=identities)

    def test_profiles_without_private_key_or_a_common_certificate_are_rejected(self):
        profiles = copy.deepcopy(self.profiles)
        profiles[1][1]['DeveloperCertificates'] = [b'other-certificate']
        other = hashlib.sha1(b'other-certificate').hexdigest().upper()
        for identities in (self.identities, self.identities + '\n2) ' + other + ' "Apple Distribution: Other"'):
            with self.subTest(identities=identities), self.assertRaises(ValueError):
                self.select(profiles, identities)

    def test_expired_other_team_wrong_environment_and_wrong_bundle_are_rejected(self):
        for key, value in [('ExpirationDate', datetime.datetime(2020, 1, 1)),
                           ('TeamIdentifier', ['OTHERTEAM'])]:
            profiles = copy.deepcopy(self.profiles)
            profiles[0][1][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.select(profiles)
        for key, value in [('aps-environment', 'development'), ('application-identifier', self.team + '.wrong')]:
            profiles = copy.deepcopy(self.profiles)
            profiles[0][1]['Entitlements'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.select(profiles)

    def test_store_enterprise_and_disjoint_device_profiles_are_rejected(self):
        for change in ('store', 'enterprise', 'other-device'):
            profiles = copy.deepcopy(self.profiles)
            if change == 'store':
                del profiles[1][1]['ProvisionedDevices']
            elif change == 'enterprise':
                profiles[1][1]['ProvisionsAllDevices'] = True
            else:
                profiles[1][1]['ProvisionedDevices'] = ['OTHER']
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.select(profiles)

    def test_app_and_extension_must_resolve_to_the_same_keychain_group(self):
        profiles = copy.deepcopy(self.profiles)
        profile = profiles[1][1]
        profile['ApplicationIdentifierPrefix'] = ['OTHERPREFIX']
        profile['Entitlements']['application-identifier'] = 'OTHERPREFIX.' + self.bundles['extension']
        profile['Entitlements']['keychain-access-groups'] = ['OTHERPREFIX.*']
        with self.assertRaises(ValueError):
            self.select(profiles)

    def test_latest_valid_profiles_win_over_expired_or_older_matches(self):
        older = copy.deepcopy(self.profiles)
        for _, profile in older:
            profile['ExpirationDate'] = datetime.datetime(2027, 1, 1)
        profiles, _ = self.select(older + self.profiles)
        self.assertEqual(profiles['app'][2]['ExpirationDate'], datetime.datetime(2027, 11, 3))

    def add_share_profile(self):
        self.bundles['share'] = 'com.example.ctrlx.share'
        self.requested['share'] = copy.deepcopy(self.requested['extension'])
        profile = copy.deepcopy(self.profiles[1][1])
        profile['Name'] = profile['UUID'] = 'share'
        profile['Entitlements']['application-identifier'] = self.team + '.' + self.bundles['share']
        self.profiles.append((Path('share.mobileprovision'), profile))

    def test_share_extension_joins_the_same_identity_groups_and_devices(self):
        self.add_share_profile()
        profiles, identity = self.select()
        self.assertEqual(set(profiles), {'app', 'extension', 'share'})
        self.assertEqual(identity, self.digest)
        self.assertNotIn('aps-environment', profiles['share'][3])

    def test_missing_share_profile_or_disjoint_device_cannot_create_partial_package(self):
        self.add_share_profile()
        with self.assertRaises(ValueError):
            self.select(self.profiles[:2])
        self.profiles[2][1]['ProvisionedDevices'] = ['OTHER']
        with self.assertRaises(ValueError):
            self.select()


if __name__ == '__main__':
    unittest.main()
