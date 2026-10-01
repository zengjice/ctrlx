#!/usr/bin/env python3
"""Offline package/Xcode naming checks; no build or external writes."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "CtrlxPackage"


class InternalNames(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory(prefix="ctrlx-manifest-") as scratch:
            result = subprocess.run(
                ["swift", "package", "--package-path", str(PACKAGE), "--scratch-path", scratch, "dump-package"],
                capture_output=True, text=True, check=True, timeout=60,
            )
        cls.package = json.loads(result.stdout)

    def test_products_and_target_dependencies_use_current_modules(self):
        products = {product["name"]: product["targets"] for product in self.package["products"]}
        targets = {target["name"]: target for target in self.package["targets"]}
        for name in ("CtrlxCLI", "CtrlxEmoji", "CtrlxPluginProtocol"):
            self.assertEqual(products[name], [name])
            self.assertIn(name, targets)
            self.assertIn(name + "Tests", targets)
        self.assertNotIn("Gallager", json.dumps(self.package))

    def test_cli_sources_and_test_directories_resolve(self):
        target = next(target for target in self.package["targets"] if target["name"] == "CtrlxCLI")
        self.assertEqual(target["path"], "Sources/CtrlxCLI")
        self.assertTrue((PACKAGE / target["path"] / "CtrlxCLI.swift").is_file())
        for name in ("CtrlxEmoji", "CtrlxPluginProtocol"):
            self.assertTrue((PACKAGE / "Sources" / name).is_dir())
        for name in ("CtrlxCLI", "CtrlxEmoji", "CtrlxPluginProtocol"):
            self.assertTrue((PACKAGE / "Tests" / (name + "Tests")).is_dir())
        for folder in (PACKAGE / "Sources", PACKAGE / "Tests"):
            self.assertFalse([str(path) for path in folder.rglob("*Gallager*") if path.is_file()])

    def test_xcode_copies_renamed_cli_without_changing_its_installed_name(self):
        result = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", str(ROOT / "Ctrlx.xcodeproj/project.pbxproj")],
            capture_output=True, text=True, check=True, timeout=10,
        )
        objects = json.loads(result.stdout)["objects"].values()
        self.assertIn("CtrlxCLI", [obj.get("productName") for obj in objects])
        phase = next(obj for obj in objects if any(path.endswith("/CtrlXCLI") for path in obj.get("outputPaths", [])))
        self.assertEqual(phase["inputPaths"], ["${BUILD_DIR}/${CONFIGURATION}/CtrlxCLI"])
        self.assertIn("Contents/MacOS/CtrlXCLI", phase["shellScript"])
        self.assertIn("@loader_path/../Frameworks", phase["shellScript"])
        self.assertNotIn("Gallager", json.dumps(list(objects)))

    def test_cli_document_link_is_no_longer_broken(self):
        reference = ROOT / "docs/ctrlx-cli-api.md"
        bundled = PACKAGE / "Sources/CtrlxServerFeature/Resources/ctrlx-cli-api.md"
        self.assertTrue(reference.is_file())
        self.assertTrue(bundled.is_file())
        self.assertIn("../" + str(bundled.relative_to(ROOT)), reference.read_text())


if __name__ == "__main__":
    unittest.main()
