"""Run the production IPA reminder scene in an isolated SwiftUI application."""

import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = ROOT / "CtrlxPackage/Sources/CtrlxServerFeature"


@unittest.skipUnless(sys.platform == "darwin", "requires AppKit")
class IPADefaultPromptUITests(unittest.TestCase):
    def test_nonmodal_window_activation_actions_and_quit(self):
        with tempfile.TemporaryDirectory(prefix="ctrlx-ipa-prompt-ui-") as directory:
            build = pathlib.Path(directory)
            inputs = []
            for source in (
                SOURCES / "Models/IPAFileIntegration.swift",
                SOURCES / "Views/IPAFileIntegrationViews.swift",
            ):
                code = source.read_text()
                for module in ("CtrlxCommon", "Dependencies", "Logging"):
                    code = code.replace(f"import {module}\n", "")
                target = build / source.name
                target.write_text(code)
                inputs.append(str(target))
            main = build / "main.swift"
            main.write_text("import AppKit\n_ = PromptTestApplication.shared\n"
                            "NSApp.setActivationPolicy(.prohibited)\nPromptTestApp.main()\n")
            app = build / "PromptTest.app"
            executable = app / "Contents/MacOS/PromptTest"
            executable.parent.mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": f"com.jicezeng.ctrlx.tests.ipa-prompt.{uuid.uuid4().hex}",
                "CFBundleExecutable": "PromptTest",
                "CFBundlePackageType": "APPL",
                "LSUIElement": True,
            }))
            result = subprocess.run(
                ["xcrun", "swiftc", "-swift-version", "6",
                 "-module-cache-path", str(build / "ModuleCache"), *inputs,
                 str(ROOT / "scripts/tests/fixtures/ipa_default_prompt_ui.swift"),
                 str(main), "-o", str(executable)],
                capture_output=True, text=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=35)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for evidence in (
                "PASS: background deferral and foreground presentation",
                "PASS: nonmodal reminder and usable main window",
                "PASS: Not Now closes once without changing preferences",
                "PASS: success, cancellation and Don't Ask Again",
                "PASS: normal quit while reminder remains open",
            ):
                self.assertIn(evidence, result.stdout)


if __name__ == "__main__":
    unittest.main()
