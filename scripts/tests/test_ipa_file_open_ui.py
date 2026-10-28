"""Cold and warm Finder-style IPA delivery, without changing the default handler."""

import pathlib
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = ROOT / "CtrlxPackage/Sources/CtrlxServerFeature"


@unittest.skipUnless(sys.platform == "darwin", "requires AppKit")
class IPAFileOpenUITests(unittest.TestCase):
    def test_external_files_reach_separate_installer_windows(self):
        with tempfile.TemporaryDirectory(prefix="ctrlx-ipa-open-") as directory:
            root = pathlib.Path(directory)
            app = root / "IPA Routing Probe.app"
            executable = app / "Contents/MacOS/Probe"
            executable.parent.mkdir(parents=True)
            log = root / "events.log"
            log.touch()
            info = plistlib.loads((ROOT / "CtrlxServer/Info.plist").read_bytes())
            info = {key: info[key] for key in ("CFBundleDocumentTypes", "UTImportedTypeDeclarations")}
            self.assertEqual(info["CFBundleDocumentTypes"][0]["LSHandlerRank"], "Alternate")
            info.update(CFBundleExecutable="Probe", CFBundleIdentifier="com.ctrlx.ipa-probe." + uuid.uuid4().hex,
                        CFBundleName="IPA Routing Probe", CFBundlePackageType="APPL", LSUIElement=True,
                        CtrlXProbeLog=str(log))
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            production = []
            for relative in ["Models/IPAFileIntegration.swift", "Views/IPAFileIntegrationViews.swift"]:
                source = (SOURCES / relative).read_text()
                for module in ["CtrlxCommon", "Dependencies", "Logging"]:
                    source = source.replace(f"import {module}", "")
                path = root / pathlib.Path(relative).name
                path.write_text(source)
                production.append(str(path))
            scene = (SOURCES / "Views/IPAInstallerView.swift").read_text()
            scene = scene[scene.index("    public struct IPAInstallerScene:"):scene.index("    public struct IPAInstallerCommands:")]
            scene_path = root / "IPAInstallerScene.swift"
            scene_path.write_text("import SwiftUI\n" + scene)
            delegate = (SOURCES / "Coordinators/AppShutdownDelegate.swift").read_text()
            start = delegate.index("        public var onOpenFiles:")
            end = delegate.index("        /// Async cleanup", start)
            fixture = (ROOT / "scripts/tests/fixtures/ipa_file_open.swift").read_text().replace("/// PRODUCTION_DELEGATE", delegate[start:end])
            main = root / "Probe.swift"
            main.write_text(fixture)
            result = subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                                     "-module-cache-path", str(root / "ModuleCache"), *production,
                                     str(scene_path), str(main), "-o", str(executable)],
                                    capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
            files = [root / "First File.ipa", root / "第二个.IPA"]
            for file in files:
                file.write_bytes(b"inert routing fixture, never installed")
            process_id = None
            try:
                subprocess.run(["open", "-n", "-a", str(app), str(files[0])], check=True, capture_output=True, timeout=15)
                self.wait_for(log, "pid\t")
                process_id = int(next(line.split("\t")[1] for line in log.read_text().splitlines() if line.startswith("pid\t")))
                self.wait_for(log, "opened\t" + str(files[0]))
                subprocess.run(["open", "-a", str(app), str(files[1])], check=True, capture_output=True, timeout=15)
                self.wait_for(log, "opened\t" + str(files[1]))
                subprocess.run(["open", "-a", str(app), str(files[0])], check=True, capture_output=True, timeout=15)
                time.sleep(0.5)
                opened = [line for line in log.read_text().splitlines() if line.startswith("opened\t")]
                self.assertEqual(opened, ["opened\t" + str(file) for file in files])
            finally:
                if process_id:
                    # This PID belongs to this test's isolated, device-free fixture.
                    subprocess.run(["kill", "-TERM", str(process_id)], check=False, capture_output=True)

    def wait_for(self, path, text):
        for _ in range(150):
            if text in path.read_text():
                return
            time.sleep(0.1)
        self.fail(f"Timed out waiting for {text}: {path.read_text()}")


if __name__ == "__main__":
    unittest.main()
