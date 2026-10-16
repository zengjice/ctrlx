import Foundation

/// Exercises the production journal and startup coordinator in a signed, isolated App.
/// A changed boot ID in this fixture simulates reboot; it is not OS-reboot acceptance.
public enum WorkspaceRecoveryScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Workspace Recovery", tags: ["workspace-recovery", "macos-only", "isolated-api"]
    ) {
        TestStep.tmuxCreateSession(name: "restore-alpha", width: 120, height: 40)
        TestStep.injectScript(name: "workspace_recovery.py")
        fixture("setup")
        TestStep.launchMacApp()
        Shortcut.openPanesWindow()
        TestStep.macMoveWindow(x: 180, y: 100)
        TestStep.macWaitForElement(titled: "restore-alpha", timeout: 15)
        TestStep.macClickButton(titled: "restore-alpha")
        TestStep.macWaitForElementQuery(.identifier("terminal-%0"), timeout: 15)
        TestStep.macClickButton(titled: "Open terminal in split: RIGHT")
        TestStep.macWaitForElement(titled: "Move terminal to left: RIGHT", timeout: 5)
        TestStep.macScreenshot(label: "nested-and-workbench-split", compare: false)
        TestStep.macDragElementOutsideWindow(.labelContains("restore-alpha:3"))
        TestStep.macWaitForWindow(titled: "restore-alpha — Workspace", timeout: 10)
        TestStep.macMoveWindow(x: 300, y: 140)
        TestStep.macResizeWindow(width: 850, height: 560)
        bootstrapContent
        TestStep.macScreenshot(label: "detached-before-restart", compare: false)
        TestStep.wait(seconds: 3)
        fixture("captured")

        TestStep.log("App restart with live tmux must keep every process and native-window ownership")
        TestStep.terminateMacApp()
        fixture("stopped")
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "restore-alpha — Workspace", timeout: 15)
        TestStep.wait(seconds: 3)
        fixture("survived")
        bootstrapContent
        TestStep.macScreenshot(label: "live-tmux-restored", compare: false)

        TestStep.log("Simulated boot change rebuilds persistent identities without replaying the interrupted command")
        TestStep.terminateMacApp()
        fixture("prepare-reboot")
        TestStep.tmuxCommand(arguments: ["kill-server"])
        TestStep.tmuxCreateSession(name: "id-collision", width: 120, height: 40)
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        TestStep.wait(seconds: 3)
        fixture("rebuilt")
        TestStep.macWaitForWindow(titled: "restore-alpha — Workspace", timeout: 20)
        TestStep.macScreenshot(label: "rebuilt-workspace", compare: false)
        fixture("unchanged")
        restoredInput

        TestStep.log("Unavailable directories keep every pane in place until an explicit retry")
        TestStep.terminateMacApp()
        fixture("prepare-missing")
        TestStep.tmuxCommand(arguments: ["kill-server"])
        // Start with the runner's isolated config; the earlier collision session
        // is now in the saved workspace, so use a different bootstrap name.
        TestStep.tmuxCreateSession(name: "remount-collision", width: 120, height: 40)
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "restore-alpha — Workspace", timeout: 20)
        fixture("missing")
        missingDirectoryControls
        TestStep.macScreenshot(label: "missing-directory-detached", compare: false)
        TestStep.macCGClickElement(query: .identifier("panes"), pointInRect: {
            CGPoint(x: $0.midX, y: $0.minY + 20)
        })
        TestStep.macScreenshot(label: "missing-directory-main", compare: false)
        TestStep.terminateMacApp()
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "restore-alpha — Workspace", timeout: 20)
        fixture("missing-relaunch")
        missingDirectoryControls
        fixture("remount")
        TestStep.macCGClickElement(query: .identifier("workspace-recovery-retry-${restoredIdentity}"))
        fixture("remounted-one")
        TestStep.macCGClickElement(query: .identifier("panes"), pointInRect: {
            CGPoint(x: $0.midX, y: $0.minY + 20)
        })
        TestStep.macCGClickElement(query: .identifier("workspace-recovery-retry-all"))
        fixture("remounted")
        TestStep.terminateMacApp()
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "restore-alpha — Workspace", timeout: 20)
        fixture("remounted-relaunch")
        restoredInput

        TestStep.log("Closing the native window returns its tab; a later App restart must not recreate the old native window")
        TestStep.macCloseWindow(titled: "restore-alpha — Workspace")
        TestStep.macClickButton(titled: "restore-alpha")
        TestStep.macWaitForElementQuery(.labelContains("restore-alpha:3"), timeout: 10)
        TestStep.wait(seconds: 3)
        fixture("returned")
        TestStep.terminateMacApp()
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForElement(titled: "restore-alpha", timeout: 15)
        TestStep.macWaitForElementQuery(.labelContains("restore-alpha:3"), timeout: 15)
        TestStep.wait(seconds: 3)
        fixture("returned-relaunch")
        TestStep.macScreenshot(label: "returned-after-relaunch", compare: false)
    }

    private static let terminals = [
        "restore-alpha:0.0", "restore-alpha:0.1", "restore-alpha:0.2",
        "restore-alpha:1.0", "restore-alpha:3.0",
    ]

    private static let missingDirectoryControls = CtrlxE2ELib.scenario("Missing-directory recovery controls", tags: ["shortcut"]) {
        for target in terminals {
            TestStep.tmuxStoreDisplayMessage(target: target, format: "#{@ctrlx-recovery-pane}", storeAs: "restoredIdentity")
            TestStep.macWaitForElementQuery(.identifier("workspace-recovery-retry-${restoredIdentity}"), timeout: 10)
        }
        TestStep.macWaitForElementQuery(.valueContains("The original working directory is unavailable:"), timeout: 10)
    }

    private static let bootstrapContent = CtrlxE2ELib.scenario("Restored terminal content", tags: ["shortcut"]) {
        for (index, target) in terminals.enumerated() {
            TestStep.tmuxStoreDisplayMessage(target: target, format: "#{pane_id}", storeAs: "restoredPane")
            TestStep.macWaitForElementQuery(.allOf([
                terminalQuery(index), .valueContains("WR_boot_\(index)"),
            ]), timeout: 10)
        }
    }

    private static let restoredInput = CtrlxE2ELib.scenario("Input after terminal reconstruction", tags: ["shortcut"]) {
        // The detached window is initially in front; bring main forward before
        // clicking its panes so an overlapping native window cannot intercept.
        for index in [4, 0, 1, 2, 3] {
            let target = terminals[index]
            if index == 0 {
                TestStep.macCGClickElement(query: .identifier("panes"), pointInRect: {
                    CGPoint(x: $0.midX, y: $0.minY + 20)
                })
            }
            TestStep.tmuxStoreDisplayMessage(target: target, format: "#{pane_id}", storeAs: "restoredPane")
            TestStep.macCGClickElement(query: terminalQuery(index))
            // Content-click Fit waits for the double-click interval. Typing or
            // paste before it fires intentionally cancels that action.
            TestStep.wait(seconds: 1)
            // Use the isolated clipboard so the user's active IME cannot compose
            // this fixture command. The echo does not contain the expected output.
            TestStep.writeFile(
                path: NSTemporaryDirectory() + "ctrlx-e2e-clipboard-0.txt",
                content: "printf 'WR_%s\\n' 'input_\(index)'"
            )
            TestStep.macPaste()
            TestStep.macPressKey(.return)
            TestStep.tmuxWaitForPaneContent(target: target, contains: "WR_input_\(index)", timeout: 10)
            TestStep.macWaitForElementQuery(.allOf([
                terminalQuery(index), .valueContains("WR_input_\(index)"),
            ]), timeout: 10)
            for other in terminals where other != target {
                TestStep.tmuxCapturePaneContent(target: other, storeAs: "otherTerminal")
                TestStep.assertStoredNotContains(key: "otherTerminal", substring: "WR_input_\(index)")
            }
            if index == 4 {
                TestStep.macScreenshot(label: "detached-input-after-reconstruction", compare: false)
            }
        }
        fixture("input")
        TestStep.macScreenshot(label: "terminal-input-after-reconstruction", compare: false)
    }

    private static func terminalQuery(_ index: Int) -> ElementQuery {
        // SwiftUI's split wrapper overrides the single-pane terminal's AX ID.
        .identifier(index == 3 ? "split-right-pane" : "terminal-${restoredPane}")
    }

    private static func fixture(_ phase: String) -> TestScenario {
        CtrlxE2ELib.scenario("Recovery fixture: \(phase)", tags: ["shortcut"]) {
            TestStep.tmuxCommand(arguments: [
                "run-shell",
                "python3 \"$TMPDIR/workspace_recovery.py\" '\(phase)' '${ctrlxStateRoot}' '${tmuxSocket}'",
            ])
            TestStep.waitForFileContains(
                path: "${ctrlxStateRoot}/../evidence/\(phase).json",
                substring: "\"passed\": true", storeAs: "recovery-\(phase)", timeout: 5
            )
        }
    }
}
