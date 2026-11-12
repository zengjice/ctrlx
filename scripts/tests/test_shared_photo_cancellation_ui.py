"""Exercise shared-photo cancellation with real SwiftUI state and inbox files."""

import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = ROOT / "CtrlxPackage/Sources"


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    for end in range(opening + 1, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return textwrap.dedent(source[start:end + 1])
    raise ValueError("Unclosed declaration: " + marker)


@unittest.skipUnless(sys.platform == "darwin", "requires SwiftUI and AppKit")
class SharedPhotoCancellationUITests(unittest.TestCase):
    def test_late_cancel_preserves_the_new_import_and_current_cancel_still_releases(self):
        source = (SOURCES / "CtrlxFeature/Views/ImageUploadToolbarButton.swift").read_text()
        members = "\n\n".join(declaration(source, marker) for marker in (
            "private func receiveSharedPhotos()", "private func beginOperation()",
            "private func finishOperation(", "private func cancelOperation()",
            "private func finishSharedImport()",
        ))
        reservation = "@MainActor\n" + declaration(source, "final private class SharedPhotoImport")
        context = (SOURCES / "CtrlxCommon/Models/TerminalPhraseContext.swift").read_text()
        context = context.split("package struct TerminalPhraseRequest", 1)[0]
        context = context.replace("import CtrlxNetworking\n", "").replace("package ", "")
        store = (SOURCES / "CtrlxShare/ShareInboxStore.swift").read_text().replace(
            "import CtrlxEncryption", 'let sharedAppGroupIdentifier = "group.com.gravtice.ctrlx"'
        )
        inbox = (SOURCES / "CtrlxFeature/Models/IOSShareInbox.swift").read_text()
        inbox = inbox.replace("import CtrlxCommon\n", "").replace("import CtrlxShare\n", "")
        fixture = (ROOT / "scripts/tests/fixtures/shared_photo_cancellation.swift").read_text()
        fixture = fixture.replace("/* PRODUCTION_MEMBERS */", members)

        with tempfile.TemporaryDirectory(prefix="ctrlx-share-cancel-ui-") as directory:
            build = pathlib.Path(directory)
            probe = build / "Probe.swift"
            probe.write_text("\n\n".join([context, store, inbox, reservation, fixture]))
            executable = build / "probe"
            result = subprocess.run(
                ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                 "-module-cache-path", str(build / "ModuleCache"), str(probe), "-o", str(executable)],
                capture_output=True, text=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            subprocess.run(["codesign", "--force", "--sign", "-", str(executable)], check=True, capture_output=True)
            result = subprocess.run([str(executable), str(build / "inbox-fixture")],
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: late cancellation preserves the new import", result.stdout)
            self.assertIn("PASS: current cancellation releases the reservation and retains the copy", result.stdout)


if __name__ == "__main__":
    unittest.main()
