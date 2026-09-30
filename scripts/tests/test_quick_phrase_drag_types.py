#!/usr/bin/env python3
"""Keep native quick-phrase drag types registered in both app bundles."""
from pathlib import Path
import plistlib
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class QuickPhraseDragTypeTests(unittest.TestCase):
    def declarations(self, relative):
        with (ROOT / relative).open("rb") as file:
            return plistlib.load(file).get("UTExportedTypeDeclarations", [])

    def test_both_apps_export_the_payload_type_as_data(self):
        source = (ROOT / "CtrlxPackage/Sources/CtrlxCommon/UI/QuickPhraseReordering.swift").read_text()
        identifiers = re.findall(r'UTType\(exportedAs:\s*"([^"]+)"', source)
        self.assertEqual(len(identifiers), 1)
        for relative in ("Ctrlx/Info.plist", "CtrlxServer/Info.plist"):
            with self.subTest(plist=relative):
                matches = [item for item in self.declarations(relative)
                           if item.get("UTTypeIdentifier") == identifiers[0]]
                self.assertEqual(len(matches), 1, "Drag payload must be exported exactly once")
                self.assertIn("public.data", matches[0].get("UTTypeConformsTo", []))

    def test_mac_tab_drag_registration_is_preserved(self):
        matches = [item for item in self.declarations("CtrlxServer/Info.plist")
                   if item.get("UTTypeIdentifier") == "com.jicezeng.ctrlx.tab-drag"]
        self.assertEqual(len(matches), 1)
        self.assertIn("public.data", matches[0].get("UTTypeConformsTo", []))


if __name__ == "__main__":
    unittest.main()
