import Foundation

/// Uses actual disposable files, Git history and editor requests, never mock providers.
public enum WorkspaceContentRecoveryScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Workspace Content Recovery", tags: ["workspace-recovery", "macos-only", "isolated-api", "live-workspace-content"]
    ) {
        TestStep.tmuxCreateSession(name: "restore-content", width: 120, height: 40)
        TestStep.injectScript(name: "workspace_content_recovery.py")
        fixture("setup")
        TestStep.launchMacApp()
        Shortcut.openPanesWindow()
        TestStep.macResizeWindow(width: 1_200, height: 750)
        TestStep.macWaitForElement(titled: "restore-content", timeout: 15)
        TestStep.macClickButton(titled: "restore-content")
        TestStep.macContextMenuClick(elementTitle: "restore-content:0", menuItem: "Open Files")
        TestStep.macWaitForElementQuery(.allOf([.role("AXTextField"), .valueContains("content-project")]), timeout: 10)
        TestStep.macCGClickElement(query: .allOf([.role("AXButton"), .label("docs")]))
        TestStep.macClickButton(titled: "Expand nested")
        TestStep.macWaitForElement(titled: "detail.txt", timeout: 10)
        TestStep.macClickButton(titled: "chapter.txt")
        TestStep.macWaitForElementQuery(.anyTextMatches("RECOVERED_FILE_PREVIEW"), timeout: 10)
        TestStep.macScreenshot(label: "files-before-restart", compare: false)

        TestStep.macClickButton(titled: "Git")
        TestStep.macWaitForElement(titled: "change.txt", timeout: 10)
        TestStep.macCGClick(titled: "Message (")
        TestStep.macSetFocusedText("Unsent commit message for workspace recovery")
        TestStep.macCGClick(titled: "History")
        TestStep.macWaitForElementQuery(.anyTextMatches("Recovery selected history"), timeout: 10)
        TestStep.macCGClick(titled: "Recovery selected history")
        TestStep.macCGClick(titled: "change.txt")
        TestStep.macScreenshot(label: "git-before-restart", compare: false)

        TestStep.macClickButton(titled: "restore-content:0")
        TestStep.tmuxCommand(arguments: [
            "run-shell", "-b",
            "python3 \"$TMPDIR/workspace_content_recovery.py\" 'editor' '${ctrlxStateRoot}' '${tmuxSocket}'",
        ])
        TestStep.macWaitForElement(titled: "Edit Prompt", timeout: 10)
        TestStep.macFocusElement(titled: "Original prompt must remain unchanged.")
        TestStep.macSetFocusedText("Unsent recovery prompt: inspect the chosen file, do not execute anything.")
        TestStep.macScreenshot(label: "prompt-before-restart", compare: false)
        fixture("captured")
        TestStep.terminateMacApp()
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        fixture("restored")
        restoredContent

        TestStep.terminateMacApp()
        fixture("prepare-reboot")
        TestStep.tmuxCommand(arguments: ["kill-server"])
        TestStep.tmuxCreateSession(name: "content-collision", width: 120, height: 40)
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        fixture("rebuilt")
        restoredContent

        TestStep.macClickButton(titled: "Git")
        TestStep.macCGClick(titled: "Stashes")
        TestStep.macWaitForElementQuery(.anyTextMatches("Recovery selected stash"), timeout: 10)
        TestStep.macCGClick(titled: "Recovery selected stash")
        TestStep.macCGClick(titled: "change.txt")
        fixture("stash-captured")
        TestStep.terminateMacApp()
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForElementQuery(.anyTextMatches("Recovery selected stash"), timeout: 15)
        TestStep.macWaitForElementQuery(.anyTextMatches("stashed recovery value"), timeout: 10)
        fixture("stash-restored")
        TestStep.macScreenshot(label: "stash-after-restart", compare: false)

        TestStep.macCGClickElement(query: .labelContains("File tab:"))
        TestStep.macWaitForElementQuery(.anyTextMatches("RECOVERED_FILE_PREVIEW"), timeout: 10)
        TestStep.terminateMacApp()
        fixture("remove-file")
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForElementQuery(.anyTextMatches("No such file or directory"), timeout: 15)
        TestStep.macWaitForElementQuery(.anyTextMatches("chapter.txt"), timeout: 5)
        fixture("missing-file")
        TestStep.macScreenshot(label: "missing-file-retains-selection", compare: false)
        fixture("return-file")
        TestStep.macClickButton(titled: "Refresh")
        TestStep.macWaitForElementQuery(.anyTextMatches("RECOVERED_FILE_PREVIEW"), timeout: 10)
        TestStep.macWaitForElementQueryToDisappear(.anyTextMatches("No such file or directory"), timeout: 5)
        fixture("file-returned")
        TestStep.macScreenshot(label: "returned-file-preview", compare: false)
    }

    private static let restoredContent = CtrlxE2ELib.scenario("Restored workspace content", tags: ["shortcut"]) {
        TestStep.macWaitForElement(titled: "Recovered draft", timeout: 15)
        TestStep.macWaitForElementToDisappear(titled: "Edit Prompt", timeout: 5)
        fixture("metadata")
        TestStep.macWaitForElement(titled: "Recovered draft", timeout: 10)
        // Real tmux navigation must still update the main workbench, whereas
        // unchanged active-window metadata must retain its recovered selection.
        fixture("select-source")
        TestStep.tmuxCommand(arguments: ["select-window", "-t", "restore-content:1"])
        TestStep.macWaitForElementToDisappear(titled: "Recovered draft", timeout: 10)
        TestStep.tmuxCommand(arguments: ["select-window", "-t", "restore-content:0"])
        TestStep.macWaitForElement(titled: "Recovered draft", timeout: 10)
        TestStep.macClickButton(titled: "Recovered draft")
        TestStep.macClickButton(titled: "Draft 1")
        TestStep.macWaitForElementQuery(.allOf([.role("AXTextArea"), .valueContains("Unsent recovery prompt:")]), timeout: 5)
        TestStep.macClickButton(titled: "Copy")
        TestStep.readFile(path: NSTemporaryDirectory() + "ctrlx-e2e-clipboard-0.txt", storeAs: "copiedDraft")
        TestStep.assertStoredContains(key: "copiedDraft", substring: "Unsent recovery prompt: inspect the chosen file, do not execute anything.")
        TestStep.macScreenshot(label: "recovered-draft", compare: false)
        TestStep.macClickButton(titled: "Done")
        TestStep.macCGClickElement(query: .labelContains("File tab:"))
        TestStep.macWaitForElementQuery(.anyTextMatches("RECOVERED_FILE_PREVIEW"), timeout: 10)
        TestStep.macWaitForElement(titled: "detail.txt", timeout: 10)
        TestStep.macScreenshot(label: "files-after-restart", compare: false)
        TestStep.macClickButton(titled: "Git")
        TestStep.macWaitForElementQuery(.anyTextMatches("Recovery selected history"), timeout: 10)
        TestStep.macWaitForElementQuery(.anyTextMatches("committed history value"), timeout: 10)
        TestStep.macScreenshot(label: "history-after-restart", compare: false)
        // A Git click after selecting OTHER deliberately retargets its cwd. Check
        // recovery first, then verify the draft cannot appear on that other pane.
        TestStep.macClickButton(titled: "restore-content:1")
        TestStep.macWaitForElementToDisappear(titled: "Recovered draft", timeout: 5)
        // Return to the source terminal so the next launch opens its recovered draft.
        TestStep.macClickButton(titled: "restore-content:0")
    }

    private static func fixture(_ phase: String) -> TestScenario {
        CtrlxE2ELib.scenario("Content recovery fixture: \(phase)", tags: ["shortcut"]) {
            TestStep.tmuxCommand(arguments: [
                "run-shell",
                "python3 \"$TMPDIR/workspace_content_recovery.py\" '\(phase)' '${ctrlxStateRoot}' '${tmuxSocket}'",
            ])
            TestStep.waitForFileContains(
                path: "${ctrlxStateRoot}/../evidence/\(phase).json",
                substring: "\"passed\": true", storeAs: "content-recovery-\(phase)", timeout: 5
            )
        }
    }
}
