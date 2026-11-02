"""Release signing policy and notarization failures without Apple credentials."""
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


signing = module('macos_signing')
notary = module('notarize_macos')


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def code(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'\xcf\xfa\xed\xfe' + b'fixture')
        return path

    def bundle(self, path):
        code = self.code(path / 'Contents/MacOS/fixture')
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': code.name}))
        return code

    def test_nested_libraries_and_resource_engine_precede_containing_bundles(self):
        app = self.root / 'CtrlX.app'
        self.bundle(app)
        library = self.code(app / 'Contents/Frameworks/test.dylib')
        engine = self.code(app / 'Contents/Resources/AgentBrowserEngine/agent-browser')
        renderer = app / 'Contents/Frameworks/CtrlX Agent Browser Helper (Renderer).app'
        self.bundle(renderer)
        with mock.patch.object(signing, 'run', return_value=mock.Mock(stdout=b'Mach-O 64-bit executable arm64')):
            plan = signing.signing_plan(app)
        paths = [item[0] for item in plan]
        self.assertLess(paths.index(library), paths.index(app))
        self.assertLess(paths.index(engine), paths.index(app))
        self.assertLess(paths.index(renderer), paths.index(app))
        self.assertEqual(next(e for p, _, e in plan if p == renderer), {'com.apple.security.cs.allow-jit': True})
        self.assertNotIn('com.apple.security.cs.allow-jit', plan[-1][2])
        self.assertNotIn('com.apple.security.cs.disable-library-validation', plan[-1][2])

    def test_versioned_framework_does_not_sign_its_symlinks_or_primary_twice(self):
        framework = self.root / 'Test.framework'
        binary = self.code(framework / 'Versions/A/Test')
        resources = framework / 'Versions/A/Resources'
        resources.mkdir()
        (resources / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Test'}))
        (framework / 'Versions/Current').symlink_to('A')
        (framework / 'Test').symlink_to('Versions/Current/Test')
        (framework / 'Resources').symlink_to('Versions/Current/Resources')
        self.assertEqual(signing.signing_plan(framework), [(framework, False, {})])
        self.assertTrue(binary.exists())

    def verify(self, details, entitlements=None, executable=True):
        with mock.patch.object(signing, 'run', side_effect=[mock.Mock(), mock.Mock(stderr=details.encode()),
                                                          mock.Mock(stdout=plistlib.dumps(entitlements or {}))]):
            signing.verify_component(self.root, executable, {}, 'TEAM')

    def test_verification_requires_distribution_authority_team_timestamp_and_runtime(self):
        valid = 'Authority=Developer ID Application: Fixture\nTeamIdentifier=TEAM\nTimestamp=today\nCodeDirectory flags=0x10000(runtime)\n'
        self.verify(valid)
        for bad in [valid.replace('Developer ID Application:', 'Apple Development:'),
                    valid.replace('TEAM', 'OTHER'), valid.replace('Timestamp=', 'Signed Time='),
                    valid.replace('(runtime)', '(adhoc)')]:
            with self.subTest(details=bad), self.assertRaises(ValueError):
                self.verify(bad)
        with self.assertRaisesRegex(ValueError, 'entitlements'):
            self.verify(valid, {'com.apple.security.get-task-allow': True})

    def test_signing_is_inside_out_uses_timestamps_and_no_deep_sign(self):
        plan = [(self.root / 'lib.dylib', False, {}), (self.root / 'helper', True, {'com.apple.security.cs.allow-jit': True})]
        with mock.patch.object(signing, 'signing_plan', return_value=plan), \
                mock.patch.object(signing, 'run') as run, mock.patch.object(signing, 'verify_component') as verify:
            signing.process(self.root, 'TEAM', 'IDENTITY')
        self.assertEqual(verify.call_count, 2)
        for call in run.call_args_list:
            self.assertIn('--timestamp', call.args)
            self.assertNotIn('--deep', call.args)
        self.assertNotIn('--options', run.call_args_list[0].args)
        self.assertIn('runtime', run.call_args_list[1].args)

    def test_notary_invalid_is_failure_and_keeps_submission_and_log(self):
        artifact = self.root / 'test.zip'
        artifact.write_bytes(b'archive')
        report = self.root / 'report.json'
        with mock.patch.object(notary, 'command', side_effect=[{'id': 'JOB'}, {'status': 'Invalid'}]), \
                mock.patch.object(notary.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'Invalid'):
                notary.notarize(artifact, 'profile', report)
        self.assertEqual(json.loads(report.read_text())['id'], 'JOB')
        self.assertIn('log', run.call_args.args[0])

    def test_notary_timeout_resumes_existing_job_without_submitting_again(self):
        artifact = self.root / 'test.zip'
        artifact.write_bytes(b'archive')
        report = self.root / 'report.json'
        with mock.patch.object(notary, 'command', side_effect=[{'id': 'JOB'}, {'status': 'In Progress'}, RuntimeError('timeout')]):
            with self.assertRaisesRegex(RuntimeError, 'timeout'):
                notary.notarize(artifact, 'profile', report)
        with mock.patch.object(notary, 'command', return_value={'status': 'Accepted'}) as command:
            notary.notarize(artifact, 'profile', report)
        self.assertEqual(command.call_args.args[:2], ('info', 'JOB'))
        self.assertEqual(command.call_count, 1)

    def test_notary_resume_rejects_different_bytes_or_profile(self):
        artifact = self.root / 'test.zip'
        artifact.write_bytes(b'archive')
        report = self.root / 'report.json'
        with mock.patch.object(notary, 'command', side_effect=[{'id': 'JOB'}, {'status': 'Accepted'}]):
            notary.notarize(artifact, 'profile', report)
        for profile in ['different', 'profile']:
            if profile == 'profile':
                artifact.write_bytes(b'changed')
            with mock.patch.object(notary, 'command') as command, self.assertRaises(ValueError):
                notary.notarize(artifact, profile, report)
            command.assert_not_called()

    def test_archive_blocks_development_mode_and_failed_native_verification(self):
        import os
        embedded = self.root / '.build-local/agent-browser/Embedded'
        embedded.mkdir(parents=True)
        env = dict(os.environ, SRCROOT=str(self.root), TARGET_BUILD_DIR=str(self.root / 'target'),
                   CONTENTS_FOLDER_PATH='CtrlX.app/Contents', ACTION='install', DEVELOPMENT_TEAM='TEAM')
        env.pop('CTRLX_MAC_DISTRIBUTION', None)
        command = ['bash', str(SCRIPTS / 'embed-agent-browser.sh')]
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Developer ID', result.stderr)
        (self.root / 'scripts').mkdir()
        (self.root / 'scripts/macos_signing.py').write_text('raise SystemExit(19)\n')
        env['CTRLX_MAC_DISTRIBUTION'] = 'developer-id'
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 19)
        self.assertFalse((self.root / 'target').exists())

    def test_signer_cannot_attest_changed_unsigned_engine_bytes(self):
        engine = self.code(self.root / 'Resources/AgentBrowserEngine/agent-browser')
        plan = [(engine, True, {})]
        with mock.patch.object(signing, 'signing_plan', return_value=plan), \
                mock.patch.object(signing, 'verify_component', side_effect=ValueError('invalid signature')), \
                mock.patch.object(signing, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'invalid signature'):
                signing.process(self.root, 'TEAM', 'IDENTITY')
        run.assert_not_called()

    def test_release_resume_requires_original_source_team_and_stamp(self):
        state = self.root / 'release-state.json'
        state.write_text(json.dumps({'revision': 'commit', 'team': 'TEAM', 'stamp': '20261103-001122'}))
        self.assertEqual(notary.resume_stamp(state, 'commit', 'TEAM'), '20261103-001122')
        for revision, team in [('changed', 'TEAM'), ('commit', 'OTHER')]:
            with self.assertRaises(ValueError):
                notary.resume_stamp(state, revision, team)
        state.write_text(json.dumps({'revision': 'commit', 'team': 'TEAM', 'stamp': 'invalid'}))
        with self.assertRaises(ValueError):
            notary.resume_stamp(state, 'commit', 'TEAM')


if __name__ == '__main__':
    unittest.main()
