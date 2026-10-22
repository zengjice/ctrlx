"""Run the iOS navigation callbacks in an offscreen SwiftUI state harness."""

import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "requires SwiftUI and AppKit")
class DashboardNotificationNavigationTests(unittest.TestCase):
    def test_dashboard_switch_does_not_suppress_previous_session_notification(self):
        source = (ROOT / "CtrlxPackage/Sources/CtrlxFeature/ContentView.swift").read_text()
        # Execute production callbacks, rather than a second implementation of routing.
        dismiss_marker = ".sheet(isPresented: $showingDashboard, onDismiss: {"
        observer_marker = ".onChange(of: sessionsNavigationPath.count) { _, count in"
        link_marker = "private func handleDeepLink("
        for marker in (dismiss_marker, observer_marker, link_marker):
            self.assertEqual(source.count(marker), 1)
        dismiss = source.split(dismiss_marker, 1)[1].split("}) {", 1)[0]
        observer = source.split(observer_marker, 1)[1].split(".onAppear", 1)[0].rsplit("}", 1)[0]
        deep_link = link_marker + source.split(link_marker, 1)[1].split("private func connectIfNeeded", 1)[0]
        fixture = (ROOT / "scripts/tests/fixtures/dashboard_notification_navigation.swift").read_text()
        fixture = fixture.replace("/* DASHBOARD_DISMISS */", dismiss)
        fixture = fixture.replace("/* PATH_OBSERVER */", observer)
        fixture = fixture.replace("/* DEEP_LINK */", deep_link)

        with tempfile.TemporaryDirectory(prefix="ctrlx-dashboard-navigation-") as directory:
            build = pathlib.Path(directory)
            probe = build / "Probe.swift"
            probe.write_text(fixture)
            executable = build / "probe"
            result = subprocess.run(
                ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                 "-module-cache-path", str(build / "ModuleCache"), str(probe), "-o", str(executable)],
                capture_output=True, text=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            subprocess.run(["codesign", "--force", "--sign", "-", str(executable)], check=True, capture_output=True)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: notification A, Dashboard B, notification A", result.stdout)


if __name__ == "__main__":
    unittest.main()
