#!/usr/bin/env python3
"""Offline configuration tests; no Xcode build, signing, or device access."""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "package-local-ios.sh"
CONFIG_DIR = SCRIPT.parent.parent / "Config"


class LocalIOSPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        self.script = scripts / SCRIPT.name
        shutil.copyfile(SCRIPT, self.script)
        (self.root / "Config").mkdir()
        (self.root / "Config" / "Local.xcconfig").touch()
        # Stop at the first build log, after the real argument/path preparation.
        # All writes stay inside the disposable fixture; Xcode is never invoked.
        (scripts / "common.sh").write_text("""
log_error() { printf '%s\\n' "$1" >&2; exit 1; }
assert_git_worktree() { :; }
get_version() { printf '3.0.40'; }
get_build_stamp() { printf 'test-stamp'; }
get_source_revision() { printf 'test-revision'; }
log_info() {
    printf '%s\\n' "$CONFIGURATION" "$APP_PATH" "$EXTENSION_PATH" "$IPA_PATH"
    exit 0
}
""")

    def run_script(self, *arguments):
        return subprocess.run(["bash", str(self.script), *arguments],
                              capture_output=True, text=True, timeout=5)

    def assert_configuration(self, arguments, configuration, ipa_name):
        result = self.run_script(*arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.root / ".build-local" / "DerivedData" / "iOS" / "Build" / "Products" / f"{configuration}-iphoneos" / "CtrlX.app"
        self.assertEqual(result.stdout.splitlines(), [configuration, str(app),
                         str(app / "PlugIns" / "CtrlxNotificationExtension.appex"),
                         str(self.root / "dist" / ipa_name)])

    def test_default_is_release(self):
        self.assert_configuration([], "Release", "CtrlX-3.0.40.ipa")

    def test_explicit_release(self):
        self.assert_configuration(["--configuration", "Release"], "Release", "CtrlX-3.0.40.ipa")

    def test_debug_does_not_overwrite_release_artifact(self):
        self.assert_configuration(["--configuration", "Debug"], "Debug", "CtrlX-3.0.40-Debug.ipa")

    def test_invalid_configuration_fails_before_build(self):
        result = self.run_script("--configuration", "Profile")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Release or Debug", result.stderr)
        self.assertFalse((self.root / ".build-local").exists())

    def test_missing_configuration_fails(self):
        result = self.run_script("--configuration")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires Release or Debug", result.stderr)

    def test_unknown_argument_fails(self):
        result = self.run_script("--release")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown argument", result.stderr)

    def test_help_needs_no_signing_config(self):
        (self.root / "Config" / "Local.xcconfig").unlink()
        result = self.run_script("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Default: Release", result.stdout)
        self.assertFalse((self.root / ".build-local").exists())

    def test_build_and_app_path_use_the_same_configuration(self):
        source = SCRIPT.read_text()
        self.assertIn('-configuration "$CONFIGURATION"', source)
        self.assertNotIn('-configuration Debug', source)
        self.assertIn('/Build/Products/$CONFIGURATION-iphoneos/CtrlX.app', source)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcodebuild"),
                     "Requires Xcode to evaluate xcconfig inheritance")
class IOSIdentityConfigTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        config = self.root / "Config"
        config.mkdir()
        for name in ("Shared-Base", "Shared", "Debug", "Release"):
            shutil.copyfile(CONFIG_DIR / f"{name}.xcconfig", config / f"{name}.xcconfig")
        self.make_workspace()

    def make_workspace(self):
        # Resolve the real configs in a package-free workspace, never replacing
        # the developer's Local.xcconfig or touching provisioning profiles.
        objects = {}

        def add(isa, **attributes):
            identifier = f"{len(objects) + 1:024X}"
            objects[identifier] = {"isa": isa, **attributes}
            return identifier

        configs = {name: add("PBXFileReference", lastKnownFileType="text.xcconfig",
                             path=f"Config/{name}.xcconfig", sourceTree="<group>")
                   for name in ("Debug", "Release")}
        targets = []
        products = []
        entries = []
        for name, identity, product_type, suffix in (
            ("Ctrlx", "CTRLX_IOS_APP_BUNDLE_IDENTIFIER", "application", "app"),
            ("CtrlxNotificationExtension", "CTRLX_IOS_NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER",
             "app-extension", "appex"),
        ):
            build_configs = [add("XCBuildConfiguration", name=configuration,
                                 baseConfigurationReference=reference,
                                 buildSettings={
                                     "PRODUCT_BUNDLE_IDENTIFIER": f"$({identity})",
                                     "DEVELOPMENT_TEAM": "$(CTRLX_IOS_DEVELOPMENT_TEAM)",
                                     "SDKROOT": "iphoneos",
                                 }) for configuration, reference in configs.items()]
            config_list = add("XCConfigurationList", buildConfigurations=build_configs,
                              defaultConfigurationIsVisible="0", defaultConfigurationName="Release")
            product = add("PBXFileReference", explicitFileType=f"wrapper.{product_type}",
                          path=f"{name}.{suffix}", sourceTree="BUILT_PRODUCTS_DIR")
            products.append(product)
            target = add("PBXNativeTarget", name=name, productName=name, productReference=product,
                         productType=f"com.apple.product-type.{product_type}",
                         buildConfigurationList=config_list, buildPhases=[], buildRules=[], dependencies=[])
            targets.append(target)
            entries.append(f'''<BuildActionEntry buildForRunning="YES" buildForTesting="YES"
                buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
                <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}"
                    BuildableName="{name}.{suffix}" BlueprintName="{name}"
                    ReferencedContainer="container:ConfigProbe.xcodeproj"/>
                </BuildActionEntry>''')
        product_group = add("PBXGroup", children=products, name="Products", sourceTree="<group>")
        main_group = add("PBXGroup", children=[*configs.values(), product_group], sourceTree="<group>")
        project_configs = [add("XCBuildConfiguration", name=name, buildSettings={}) for name in configs]
        project_config_list = add("XCConfigurationList", buildConfigurations=project_configs,
                                  defaultConfigurationIsVisible="0", defaultConfigurationName="Release")
        project_id = add("PBXProject", buildConfigurationList=project_config_list,
                         compatibilityVersion="Xcode 14.0", mainGroup=main_group,
                         productRefGroup=product_group, projectDirPath="", projectRoot="", targets=targets)
        project = self.root / "ConfigProbe.xcodeproj"
        project.mkdir()
        (project / "project.pbxproj").write_bytes(plistlib.dumps({
            "archiveVersion": "1", "classes": {}, "objectVersion": "56",
            "objects": objects, "rootObject": project_id,
        }))
        schemes = project / "xcshareddata" / "xcschemes"
        schemes.mkdir(parents=True)
        (schemes / "Ctrlx.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
            <Scheme version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
            <BuildActionEntries>{''.join(entries)}</BuildActionEntries></BuildAction></Scheme>''')
        self.workspace = self.root / "Ctrlx.xcworkspace"
        self.workspace.mkdir()
        (self.workspace / "contents.xcworkspacedata").write_text('''<?xml version="1.0" encoding="UTF-8"?>
            <Workspace version="1.0"><FileRef location="group:ConfigProbe.xcodeproj"/></Workspace>''')

    def build_settings(self, configuration):
        result = subprocess.run([
            "xcodebuild", "-workspace", str(self.workspace), "-scheme", "Ctrlx",
            "-configuration", configuration, "-destination", "generic/platform=iOS",
            "-derivedDataPath", str(self.root / "DerivedData"),
            "-showBuildSettings", "-json", "CODE_SIGNING_ALLOWED=NO",
        ], cwd=self.root, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return {item["target"]: item["buildSettings"] for item in json.loads(result.stdout)}

    def test_local_identity_overrides_shared_defaults_in_both_configurations(self):
        (self.root / "Config" / "Local.xcconfig").write_text("""
CTRLX_IOS_DEVELOPMENT_TEAM = TESTTEAM01
CTRLX_IOS_APP_BUNDLE_IDENTIFIER = com.example.ctrlx.local
CTRLX_IOS_NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER = com.example.ctrlx.local.notification-service
""")
        for configuration in ("Debug", "Release"):
            with self.subTest(configuration=configuration):
                settings = self.build_settings(configuration)
                for target, expected_id in (
                    ("Ctrlx", "com.example.ctrlx.local"),
                    ("CtrlxNotificationExtension", "com.example.ctrlx.local.notification-service"),
                ):
                    self.assertEqual(settings[target]["PRODUCT_BUNDLE_IDENTIFIER"], expected_id)
                    self.assertEqual(settings[target]["DEVELOPMENT_TEAM"], "TESTTEAM01")

    def test_local_config_is_optional_for_unsigned_build_settings(self):
        for configuration in ("Debug", "Release"):
            with self.subTest(configuration=configuration):
                settings = self.build_settings(configuration)
                self.assertEqual(settings["Ctrlx"]["PRODUCT_BUNDLE_IDENTIFIER"], "com.jicezeng.ctrlx")
                self.assertEqual(settings["CtrlxNotificationExtension"]["PRODUCT_BUNDLE_IDENTIFIER"],
                                 "com.jicezeng.ctrlx.notification-service")
                for target in settings.values():
                    self.assertEqual(target.get("DEVELOPMENT_TEAM", ""), "")


if __name__ == "__main__":
    unittest.main()
