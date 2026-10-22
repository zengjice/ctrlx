"""Exercise native double-click routing in an isolated SwiftUI workbench window."""

import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "requires AppKit and a window server")
class WorkbenchTitlebarUITests(unittest.TestCase):
    def test_native_titlebar_behavior(self):
        with tempfile.TemporaryDirectory(prefix="ctrlx-titlebar-ui-") as directory:
            build = pathlib.Path(directory)
            executable = build / "probe"
            inputs = []
            for name in (
                "CtrlxNetworking/Models/UsageOverview.swift",
                "CtrlxNetworking/Models/Dashboard.swift",
                "CtrlxCommon/Models/DashboardOverview.swift",
                "CtrlxCommon/Models/DashboardQuotaAlerts.swift",
                "CtrlxCommon/Models/DashboardToolbarAccount.swift",
                "CtrlxServerFeature/Views/MainViewComponents/DashboardQuotaToolbar.swift",
                "CtrlxServerFeature/Views/MainViewComponents/DashboardQuotaPopover.swift",
            ):
                source = ROOT / "CtrlxPackage/Sources" / name
                code = source.read_text().replace("import CtrlxNetworking\n", "").replace("import CtrlxCommon\n", "")
                code = code.replace('.accessibilityIdentifier("dashboard-quota-\\(item.account.id)")',
                    '.accessibilityIdentifier("dashboard-quota-\\(item.account.id)")\n.background(TitlebarAnchor(id: "quota-\\(item.account.id)"))')
                code = code.replace('.accessibilityIdentifier("dashboard-quota-overflow")',
                    '.accessibilityIdentifier("dashboard-quota-overflow")\n.background(TitlebarAnchor(id: "quota-overflow"))')
                code = code.replace('.accessibilityIdentifier(isSummary ? "dashboard-quota-summary" : "dashboard-quota-detail")',
                    '.accessibilityIdentifier(isSummary ? "dashboard-quota-summary" : "dashboard-quota-detail")\n.background(TitlebarAnchor(id: (isSummary ? "summary-" : "detail-") + item.account.label))')
                code = code.replace('.accessibilityIdentifier("dashboard-quota-list-\\(item.account.id)")',
                    '.accessibilityIdentifier("dashboard-quota-list-\\(item.account.id)")\n.background(TitlebarAnchor(id: "list-\\(item.account.id)"))')
                target = build / source.name
                target.write_text(code)
                inputs.append(str(target))
            result = subprocess.run(
                ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                 "-module-cache-path", str(build / "ModuleCache"),
                 *inputs,
                 str(ROOT / "CtrlxPackage/Sources/CtrlxServerFeature/Views/MainViewComponents/WorkbenchWindowTitle.swift"),
                 str(ROOT / "scripts/tests/fixtures/workbench_titlebar_ui.swift"), "-o", str(executable)],
                capture_output=True, text=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            subprocess.run(["codesign", "--force", "--sign", "-", str(executable)], check=True, capture_output=True)
            for detached, behavior in ((False, "Maximize"), (True, "Maximize"),
                                       (False, "Minimize"), (False, "None")):
                with self.subTest(detached=detached, behavior=behavior):
                    environment = dict(os.environ, CTRLX_TITLEBAR_FIXTURE_DETACHED="1" if detached else "0")
                    result = subprocess.run([str(executable), "-AppleActionOnDoubleClick", behavior],
                                            env=environment, capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("PASS: native titlebar double-click", result.stdout)
                    print(f"detached={detached}, doubleClick={behavior}:\n{result.stdout}")


if __name__ == "__main__":
    unittest.main()
