"""Exercise production SwiftUI voice controls with fake speech, in an isolated AppKit loop."""

import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = ROOT / "CtrlxPackage/Sources"


@unittest.skipUnless(sys.platform == "darwin", "requires AppKit and a Mac desktop session")
class MacVoiceInputInlineTests(unittest.TestCase):
    def test_native_microphone_and_inline_preview(self):
        with tempfile.TemporaryDirectory(prefix="ctrlx-mic-inline-") as directory:
            build = pathlib.Path(directory)
            sources = [
                SOURCES / "CtrlxCommon/Models/VoiceInputPhase.swift",
                SOURCES / "CtrlxCommon/Models/VoiceInputStage.swift",
                SOURCES / "CtrlxCommon/UI/VoiceInputPreview.swift",
                SOURCES / "CtrlxServerFeature/Views/MacVoiceInputButton.swift",
                SOURCES / "CtrlxServerFeature/Views/MacVoiceInputPress.swift",
                SOURCES / "CtrlxServerFeature/Views/MacVoiceInputOverlay.swift",
                SOURCES / "CtrlxServerFeature/Views/MacVoiceInputCancellation.swift",
            ]
            # Keep the real view bodies; supply inert dependencies and hit-test-
            # transparent geometry probes, without enabling system Accessibility.
            inputs = []
            for source in sources:
                target = build / source.name
                code = source.read_text().replace("import CtrlxCommon\n", "")
                for identifier in ("voice-input-preview", "voice-preview-cancel"):
                    marker = f'.accessibilityIdentifier("{identifier}")'
                    code = code.replace(marker, marker + f'\n.background {{ ProbeAnchor(id: "{identifier}") }}')
                target.write_text(code)
                inputs.append(str(target))
            executable = build / "probe"
            result = subprocess.run(
                [
                    "xcrun", "swiftc", "-swift-version", "6", "-package-name", "CtrlxPackage",
                    *inputs, str(ROOT / "scripts/tests/fixtures/mac_voice_input_inline.swift"),
                    "-o", str(executable),
                ], capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            subprocess.run(["codesign", "--force", "--sign", "-", str(executable)], check=True, capture_output=True)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=25)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: inline preview, stable viewport/focus, microphone stop, cancel, scoped Escape", result.stdout)
            self.assertIn("PASS: native hold/release, pending permission, changed target", result.stdout)
            self.assertIn("PASS: stale native window cannot start audio after preparation", result.stdout)
            self.assertIn("PASS: uncorrected notice survives delivery, preserves focus/Escape, dismisses without resending", result.stdout)


if __name__ == "__main__":
    unittest.main()
