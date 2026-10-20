#!/usr/bin/env python3
"""Protect the Host's Bluetooth declaration required by Chromium WebAuthn."""
from pathlib import Path
import plistlib
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BrowserPrivacyTests(unittest.TestCase):
    def test_host_declares_bluetooth_usage(self):
        # WebAuthn can initialize Bluetooth in the main Host process. A missing
        # purpose string terminates CtrlX through TCC, before any error handler.
        with (ROOT / "CtrlxServer/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        purpose = info.get("NSBluetoothAlwaysUsageDescription")
        self.assertIsInstance(purpose, str)
        self.assertTrue(purpose.strip())


if __name__ == "__main__":
    unittest.main()
