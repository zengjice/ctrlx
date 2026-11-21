"""Replay iOS completion callbacks in a hidden SwiftUI host without a live session."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


def definition(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


@unittest.skipUnless(sys.platform == "darwin", "requires SwiftUI/AppKit")
class IOSCompletionAttentionUITests(unittest.TestCase):
    def test_visibility_late_callbacks_and_completion_only(self):
        view = (ROOT / "CtrlxPackage/Sources/CtrlxFeature/Views/WindowLayoutView.swift").read_text()
        terminal = (ROOT / "CtrlxPackage/Sources/CtrlxFeature/Views/LiveTerminalView.swift").read_text()
        terminal_link = ROOT / "CtrlxPackage/Sources/CtrlxFeature/Models/TerminalLinkPresentation.swift"
        service = (ROOT / "CtrlxPackage/Sources/CtrlxFeature/Services/SessionDetailService.swift").read_text()
        attachments = (ROOT / "CtrlxPackage/Sources/CtrlxFeature/Views/ImageUploadToolbarButton.swift").read_text()
        fixture = (ROOT / "scripts/tests/fixtures/ios_completion_attention_ui.swift").read_text()
        fixture = fixture.replace("// PRODUCTION_STATE_CALLBACK", definition(view, ".onChange(of: activeService?.session?.state)"))
        fixture = fixture.replace("// PRODUCTION_VISIBILITY_CALLBACK", definition(view, ".onChange(of: canAcknowledgeCompletion,"))
        fixture = fixture.replace("// PRODUCTION_VISIBILITY", definition(view, "private var canAcknowledgeCompletion:"))
        fixture = fixture.replace("// PRODUCTION_ACKNOWLEDGEMENT", definition(view, "private func markVisibleTerminalHandled()"))
        fixture = fixture.replace("// PRODUCTION_PREVIEW_DISMISSAL", definition(view, "private func artifactPreviewDidDismiss()"))
        fixture = fixture.replace("// PRODUCTION_WINDOW_ACTION_DISMISSAL",
                                  definition(view, "private func windowActionsDidDismiss()").removeprefix("private "))
        fixture = fixture.replace("// PRODUCTION_SERVICE_METHOD", definition(service, "public func markHandledIfNeeded()"))
        paste_error_callback = definition(terminal, ".onChange(of: coordinator.pasteError != nil)")
        paste_error_callback = paste_error_callback.replace("coordinator.pasteError", "presentation.coordinator.pasteError")
        paste_error_callback = paste_error_callback.replace("publishLinkOrAlertPresentation()", "presentation.publishLinkOrAlertPresentation()")
        fixture = fixture.replace("// PRODUCTION_PASTE_ERROR_CALLBACK", paste_error_callback)
        attachment_callbacks = "\n".join(
            definition(attachments, f"private func {name}(").removeprefix("private ")
            for name in ("choosePhotos", "chooseFiles", "takePhoto", "cameraDidDismiss", "cancelAttachmentSelection",
                         "presentPreview", "setAttachmentSelectionActive", "publishAttachmentPresentation",
                         "setSourceErrorMessage", "presentSourceError", "finishOperation")
        )
        fixture = fixture.replace("// PRODUCTION_ATTACHMENT_CALLBACKS", attachment_callbacks)
        terminal_callbacks = "\n".join(
            definition(terminal, f"private func {name}(").removeprefix("private ")
            for name in ("setFileLinkActions", "setEmptySnapshotAlert", "setPasteError", "publishLinkOrAlertPresentation")
        )
        fixture = fixture.replace("// PRODUCTION_TERMINAL_LINK_AND_ALERT_PRESENTATION",
                                  definition(terminal, "private var isLinkOrAlertPresented:") + "\n" + terminal_callbacks)
        with tempfile.TemporaryDirectory(prefix="ctrlx-ios-attention-ui-") as directory:
            build = Path(directory)
            source = build / "Fixture.swift"
            source.write_text(fixture)
            executable = build / "probe"
            result = subprocess.run(
                ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                 "-module-cache-path", str(build / "ModuleCache"), str(source), str(terminal_link), "-o", str(executable)],
                capture_output=True, text=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            subprocess.run(["codesign", "--force", "--sign", "-", str(executable)], check=True, capture_output=True)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: visibility, delayed callbacks, previews, child panels, attachment pickers, Files, alerts, child errors and read-on-return", result.stdout)


if __name__ == "__main__":
    unittest.main()
