import Foundation

/// E2E scenario: Close window tab button and smart confirmation
///
/// Verifies that:
/// 1. An idle window can be closed via the X button without confirmation
/// 2. A window with a running process shows a confirmation dialog listing the process
/// 3. Pressing Escape cancels the confirmation and keeps the window open
/// 4. Closing an idle window removes the tab
/// 5. Closing a whole session with running processes via "Close Anyway" works
public enum CloseWindowTabScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Close Window Tab",
        tags: ["tabs", "macos-only"]
    ) {
        // Keep the tmux server alive between closing one session and creating
        // the next; server reconstruction is covered by recovery scenarios.
        TestStep.tmuxCreateSession(name: "close-keeper", width: 80, height: 24)
        // 1. Create a session with two windows
        TestStep.log("Stage 1: Create session with two windows")
        TestStep.tmuxCreateSession(name: "closetest", width: 160, height: 50)
        Shortcut.tmuxClearAndSetPrompt(target: "closetest:0")
        Shortcut.tmuxRunCommand(target: "closetest:0.0", command: "echo '=== WINDOW 0 ==='")
        Shortcut.tmuxRunCommand(target: "closetest:0.0", command: "tmux new-window -t closetest")
        TestStep.wait(seconds: 1)
        Shortcut.tmuxClearAndSetPrompt(target: "closetest:1")
        Shortcut.tmuxRunCommand(target: "closetest:1.0", command: "echo '=== WINDOW 1 ==='")
        TestStep.wait(seconds: 1)

        // 2. Launch app and select the session
        TestStep.log("Stage 2: Launch app and verify two tabs")
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)

        TestStep.macWaitForElement(titled: "closetest", timeout: 5)
        TestStep.macClickButton(titled: "closetest")

        // Sidebar click selects the tmux-active window (window 1, since we just created it)
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("closetest:1"), .valueContains("selected")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-two-tabs-before-close")

        // With three tabs, closing the last selected one must choose the first,
        // even though tmux would normally activate its neighboring tab.
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "closetest", "-n", "last-close-tab"])
        TestStep.macWaitForElement(titled: "last-close-tab", timeout: 10)
        TestStep.macClickButton(titled: "last-close-tab")
        TestStep.macClickButton(titled: "Close tab: last-close-tab")
        TestStep.macWaitForElementQuery(.allOf([.labelContains("closetest:0"), .valueContains("selected")]), timeout: 10)
        TestStep.macScreenshot(label: "mac-first-tab-after-third-close")
        // Mixed right tabs keep Files ahead of two terminals in the visible order.
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "closetest", "-n", "right-A"])
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "closetest", "-n", "right-B"])
        TestStep.macWaitForElement(titled: "right-B", timeout: 10)
        TestStep.macContextMenuClick(elementTitle: "closetest:0", menuItem: "Open Files")
        TestStep.macWaitForElementQuery(.labelContains("File tab:"), timeout: 10)
        TestStep.macDragElement(from: .labelContains("File tab:"), to: .labelContains("closetest:2 right-A"))
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "Open file tab in split:")
        TestStep.macClickButton(titled: "Move terminal to right: right-A")
        TestStep.macClickButton(titled: "Move terminal to right: right-B")
        TestStep.macClickButton(titled: "closetest:2 right-A")
        TestStep.macClickButton(titled: "Close tab: right-A")
        TestStep.macWaitForElementQuery(.allOf([.labelContains("closetest:3 right-B"), .valueContains("selected")]), timeout: 10)
        TestStep.macScreenshot(label: "mac-mixed-right-close-selects-terminal")
        TestStep.macClickButton(titled: "Close tab: right-B")
        TestStep.macWaitForElementQuery(.allOf([.labelContains("File tab:"), .valueContains("selected")]), timeout: 10)
        TestStep.macCGClickElement(query: .labelContains("Close file tab:"))
        TestStep.macClickButton(titled: "closetest:1")

        // 3. Close the selected idle window 1 via the X button (no confirmation expected)
        TestStep.log("Stage 3: Close idle window 1 via X button")
        TestStep.macClickButton(titled: "Close tab")

        // Window 1 should be gone, only window 0 remains
        TestStep.macWaitForElementToDisappear(titled: "closetest:1", timeout: 5)
        TestStep.macScreenshot(label: "mac-after-idle-close")

        // 4. Run a process in the remaining window, then try to close
        TestStep.log("Stage 4: Run a process and try to close — should show confirmation")
        Shortcut.tmuxRunCommand(target: "closetest:0.0", command: "sleep 999")

        // Wait until tmux sees `sleep` as the pane's foreground command before
        // attempting the close. A fixed wait is racy on CI.
        TestStep.waitForTmuxDisplayMessage(
            target: "closetest:0.0",
            format: "#{pane_current_command}",
            contains: "sleep",
            timeout: 10
        )

        TestStep.macClickButton(titled: "Close tab")

        // Confirmation alert should appear with the process name
        TestStep.macWaitForElement(titled: "Close Session?", timeout: 5)
        TestStep.macScreenshot(label: "mac-close-confirmation-alert")

        // 5. Press Escape to cancel — window should remain
        TestStep.log("Stage 5: Press Escape to cancel the confirmation")
        TestStep.macPressKey(.escape)

        // Tab should still be there
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("closetest:0"), .valueContains("selected")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-after-cancel")

        // 6. Kill the process so the window becomes idle, then close via X
        TestStep.log("Stage 6: Kill the process and close idle window")
        TestStep.tmuxSendKeys(target: "closetest:0", keys: "C-c")
        TestStep.wait(seconds: 2)

        // The final tab requires session confirmation even when the shell is idle.
        TestStep.macClickButton(titled: "Close tab")

        TestStep.macWaitForElement(titled: "Close Session?", timeout: 5)
        TestStep.macPressKey(.escape)
        TestStep.waitForTmuxDisplayMessage(target: "closetest:0", format: "#{session_windows}", contains: "1", timeout: 5)
        TestStep.macClickButton(titled: "Close tab")
        TestStep.macWaitForElement(titled: "Close Session", timeout: 5)
        TestStep.macCGClickElement(query: .allOf([.role("AXButton"), .label("Close Session")]))

        // Session should be gone since it was the last window
        TestStep.macWaitForElementToDisappear(titled: "closetest", timeout: 10)
        TestStep.macScreenshot(label: "mac-session-gone")

        // 7. Create a new session with a running process, close the whole session
        //    via context menu "Close Session" and confirm with "Close Anyway"
        TestStep.log("Stage 7: Close session with running process via Close Anyway")
        TestStep.tmuxCreateSession(name: "forceclose", width: 160, height: 50)
        Shortcut.tmuxClearAndSetPrompt(target: "forceclose:0")
        Shortcut.tmuxRunCommand(target: "forceclose:0.0", command: "sleep 999")

        // Wait until tmux sees `sleep` as the pane's foreground command before
        // attempting the close. A fixed wait is racy on CI.
        TestStep.waitForTmuxDisplayMessage(
            target: "forceclose:0.0",
            format: "#{pane_current_command}",
            contains: "sleep",
            timeout: 10
        )

        TestStep.macWaitForElement(titled: "forceclose", timeout: 5)
        TestStep.macClickButton(titled: "forceclose")
        TestStep.wait(seconds: 2)

        // Right-click sidebar → Close Session
        TestStep.macContextMenuClick(elementTitle: "forceclose", menuItem: "Close Session")

        // Confirmation should appear since sleep is running
        TestStep.macWaitForElement(titled: "Close Session?", timeout: 5)
        TestStep.macWaitForElementQuery(.anyTextMatches("Terminal 0: sleep"), timeout: 5)
        TestStep.macScreenshot(label: "mac-close-session-confirmation")

        TestStep.macClickButton(titled: "Close Anyway")

        // Session should be gone despite the running process
        TestStep.macWaitForElementToDisappear(titled: "forceclose", timeout: 10)
        TestStep.macScreenshot(label: "mac-session-force-closed")
    }
}
