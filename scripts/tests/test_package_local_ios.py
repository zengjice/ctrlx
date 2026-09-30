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
