"""Native click acceptance in its own AppKit loop, without microphone or CtrlX state."""

import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "requires AppKit and a Mac desktop session")
class MacVoiceInputPopoverTests(unittest.TestCase):
    def test_native_microphone_clicks(self):
        with tempfile.TemporaryDirectory(prefix="ctrlx-mic-popover-") as directory:
            executable = pathlib.Path(directory) / "probe"
            result = subprocess.run(
                [
                    "xcrun", "swiftc", "-swift-version", "6",
                    str(ROOT / "CtrlxPackage/Sources/CtrlxCommon/Models/VoiceInputPhase.swift"),
                    str(ROOT / "CtrlxPackage/Sources/CtrlxServerFeature/Views/MacVoiceInputPopover.swift"),
                    str(ROOT / "scripts/tests/fixtures/mac_voice_input_popover.swift"),
                    "-o", str(executable),
                ], capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            subprocess.run(["codesign", "--force", "--sign", "-", str(executable)], check=True, capture_output=True)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            # An early AppKit exit is not a passing test.
            self.assertIn("PASS: microphone stop, finalization, preview stop, Escape, outside click", result.stdout)


if __name__ == "__main__":
    unittest.main()
