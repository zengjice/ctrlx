import Foundation

/// Viewer presentation and drafts remain private while Host identities remap.
public enum WorkspaceViewerRecoveryScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Workspace Viewer Recovery", tags: ["workspace-recovery", "macos-only", "isolated-api", "live-workspace-content", "persistent-e2e-storage"]
    ) {
        TestStep.tmuxCreateSession(name: "restore-viewer", width: 120, height: 40)
        TestStep.injectScript(name: "workspace_viewer_recovery.py")
        fixture("setup")
        Shortcut.twoMacPairing
        fixture("autoconnect")
        TestStep.macCloseWindow(titled: "Remote Access")
        TestStep.macCloseWindow(titled: "Remote Hosts", instance: 1)
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "restore-viewer", timeout: 15)
        TestStep.macClickButton(titled: "restore-viewer")
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macResizeWindow(width: 1_200, height: 750, instance: 1)
        TestStep.macMoveWindow(x: 100, y: 80, instance: 1)
        TestStep.macWaitForElement(titled: "restore-viewer", timeout: 20, instance: 1)
        TestStep.macClickButton(titled: "restore-viewer", instance: 1)
        TestStep.macDragElementOutsideWindow(.labelContains("restore-viewer:2"), instance: 1)
        TestStep.macWaitForWindow(titled: "restore-viewer — Workspace", timeout: 15, instance: 1)
        raiseMain
        TestStep.macContextMenuClick(elementTitle: "restore-viewer:0", menuItem: "Open Files", instance: 1)
        TestStep.macWaitForElementQuery(.allOf([.role("AXTextField"), .valueContains("viewer-project")]), timeout: 15, instance: 1)
        TestStep.macCGClickElement(query: .allOf([.role("AXButton"), .label("docs")]), instance: 1)
        TestStep.macClickButton(titled: "Expand nested", instance: 1)
        TestStep.macWaitForElement(titled: "detail.txt", timeout: 10, instance: 1)
        TestStep.macClickButton(titled: "chapter.txt", instance: 1)
        TestStep.macWaitForElementQuery(.anyTextMatches("VIEWER_PRIVATE_PREVIEW"), timeout: 15, instance: 1)
        TestStep.macScreenshot(label: "viewer-private-files", compare: false, instance: 1)
        TestStep.macClickButton(titled: "restore-viewer:0", instance: 1)
        TestStep.tmuxCommand(arguments: [
            "run-shell", "-b",
            "python3 \"$TMPDIR/workspace_viewer_recovery.py\" 'editor' '${ctrlxStateRoot}' '${ctrlxStateRoot1}' '${tmuxSocket}'",
        ])
        TestStep.macWaitForElement(titled: "Edit Prompt", timeout: 15, instance: 1)
        TestStep.macFocusElement(titled: "Original remote prompt must remain unchanged.", instance: 1)
        TestStep.macSetFocusedText("Unsent Viewer recovery prompt: inspect the remote file, do not execute anything.", instance: 1)
        fixture("captured")

        TestStep.terminateMacApp(instance: 1)
        TestStep.terminateMacApp()
        TestStep.launchMacApp(instance: 1)
        TestStep.macOpenPanesWindow(instance: 1)
        fixture("offline")
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        TestStep.waitForHostConnected(timeout: 20)
        TestStep.waitForViewerConnected(timeout: 20)
        fixture("restored")
        restoredContent

        TestStep.terminateMacApp()
        TestStep.wait(seconds: 3)
        fixture("host-offline")
        fixture("prepare-reboot")
        TestStep.tmuxCommand(arguments: ["kill-server"])
        TestStep.tmuxCreateSession(name: "viewer-route-collision", width: 120, height: 40)
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        TestStep.waitForHostConnected(timeout: 20)
        fixture("rebuilt")
        restoredContent
        TestStep.tmuxStoreDisplayMessage(target: "restore-viewer:0", format: "#{pane_id}", storeAs: "viewerSourcePane")
        TestStep.macCGClickElement(query: .identifier("terminal-${viewerSourcePane}"), instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.writeFile(
            path: NSTemporaryDirectory() + "ctrlx-e2e-clipboard-1.txt",
            content: "printf 'VIEWER_%s\\n' 'RECOVERY_INPUT'"
        )
        TestStep.macPaste(instance: 1)
        TestStep.macPressKey(.return, instance: 1)
        TestStep.tmuxWaitForPaneContent(target: "restore-viewer:0", contains: "VIEWER_RECOVERY_INPUT", timeout: 10)
        fixture("input")
        TestStep.terminateMacApp(instance: 1)
        TestStep.launchMacApp(instance: 1)
        TestStep.macOpenPanesWindow(instance: 1)
        TestStep.waitForViewerConnected(timeout: 20)
        fixture("relaunch")
        restoredContent
    }

    private static let raiseMain = CtrlxE2ELib.scenario("Raise Viewer main", tags: ["shortcut"]) {
        TestStep.macCGClickElement(query: .identifier("panes"), pointInRect: {
            CGPoint(x: $0.midX, y: $0.minY + 20)
        }, instance: 1)
    }

    private static let restoredContent = CtrlxE2ELib.scenario("Recovered Viewer content", tags: ["shortcut"]) {
        TestStep.macWaitForWindow(titled: "restore-viewer — Workspace", timeout: 20, instance: 1)
        raiseMain
        TestStep.macWaitForElement(titled: "Recovered draft", timeout: 20, instance: 1)
        TestStep.macWaitForElementToDisappear(titled: "Edit Prompt", timeout: 5, instance: 1)
        TestStep.macClickButton(titled: "Recovered draft", instance: 1)
        TestStep.macClickButton(titled: "Draft 1", instance: 1)
        TestStep.macWaitForElementQuery(.allOf([.role("AXTextArea"), .valueContains("Unsent Viewer recovery prompt:")]), timeout: 5, instance: 1)
        TestStep.macClickButton(titled: "Copy", instance: 1)
        TestStep.macReadClipboard(storeAs: "viewerCopiedDraft", instance: 1)
        TestStep.assertStoredContains(key: "viewerCopiedDraft", substring: "Unsent Viewer recovery prompt: inspect the remote file, do not execute anything.")
        TestStep.macClickButton(titled: "Done", instance: 1)
        TestStep.macCGClickElement(query: .allOf([.role("AXButton"), .label("Files · docs")]), instance: 1)
        TestStep.macWaitForElementQuery(.anyTextMatches("VIEWER_PRIVATE_PREVIEW"), timeout: 15, instance: 1)
        TestStep.macWaitForElement(titled: "detail.txt", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-recovered-content", compare: false, instance: 1)
        TestStep.macClickButton(titled: "restore-viewer:0", instance: 1)
    }

    private static func fixture(_ phase: String) -> TestScenario {
        CtrlxE2ELib.scenario("Viewer recovery fixture: \(phase)", tags: ["shortcut"]) {
            TestStep.tmuxCommand(arguments: [
                "run-shell", "-b",
                "python3 \"$TMPDIR/workspace_viewer_recovery.py\" '\(phase)' '${ctrlxStateRoot}' '${ctrlxStateRoot1}' '${tmuxSocket}'",
            ])
            TestStep.waitForFileContains(
                path: "${ctrlxStateRoot}/../evidence/\(phase).json", substring: "\"passed\":",
                storeAs: "viewer-recovery-\(phase)", timeout: 45
            )
            TestStep.assertStoredContains(key: "viewer-recovery-\(phase)", substring: "\"passed\": true")
        }
    }
}
