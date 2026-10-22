"""Exercise the production clipboard bridge with delayed device snapshots."""
import pathlib
import platform
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


@unittest.skipUnless(platform.system() == "Darwin", "AppKit required")
class SimulatorClipboardTests(unittest.TestCase):
    def test_clipboard_reads_and_write_confirmation(self):
        with tempfile.TemporaryDirectory(prefix="ctrlx-clipboard-test-") as directory:
            binary = pathlib.Path(directory) / "clipboard-test"
            subprocess.run(
                [
                    "xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "AppKit",
                    "-I", str(ROOT / "CtrlxPackage/Sources/CtrlxSimulatorBridge"),
                    str(ROOT / "scripts/tests/fixtures/simulator_clipboard.m"),
                    "-o", str(binary),
                ],
                check=True, capture_output=True, text=True,
            )
            for scenario in (
                "empty", "old-text", "large-old-image", "timeout", "disconnect",
                "copy-old-text", "copy-old-image",
            ):
                with self.subTest(scenario=scenario):
                    result = subprocess.run(
                        [str(binary), scenario], capture_output=True, text=True, timeout=8,
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("PASS:", result.stdout)
                    print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
