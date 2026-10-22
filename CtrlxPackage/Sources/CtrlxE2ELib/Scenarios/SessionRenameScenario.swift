import Foundation

/// Open session editors retain their target through discovery and reconstruction.
public enum SessionRenameScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Session Rename",
        tags: ["sessions", "rename", "recovery", "macos-only"]
    ) {
        Shortcut.twoMacPairing
        TestStep.macCloseWindow(titled: "Remote Access")
        TestStep.macCloseWindow(titled: "Remote Hosts", instance: 1)
        TestStep.tmuxCreateSession(name: "e2e-session-rename", width: 80, height: 24)
        TestStep.tmuxCommand(arguments: ["set-option", "-t", "e2e-session-rename", "@ctrlx-description", "Recovery rename target"])
        TestStep.wait(seconds: 3)
        Shortcut.openPanesWindow()
        Shortcut.openPanesWindow(instance: 1)

        for instance in 0...1 {
            let name = instance == 0 ? "e2e-session-rename" : "session-host"
            let newName = instance == 0 ? "session-host" : "session-viewer"
            TestStep.macWaitForElement(titled: name, timeout: 15, instance: instance)
            TestStep.macClickButton(titled: name, instance: instance)
            TestStep.tmuxStoreDisplayMessage(target: name, format: "#{session_name}:#{pane_pid}", storeAs: "session-before")
            TestStep.macContextMenuClick(elementTitle: "Recovery rename target", menuItem: "Rename Session", instance: instance)
            TestStep.macWaitForElement(titled: "Rename Session", timeout: 5, instance: instance)
            TestStep.wait(seconds: 0.5)
            TestStep.macPressKey(.character("a"), modifiers: .command, instance: instance)
            TestStep.macWriteClipboard(text: "StaleSession", instance: instance)
            TestStep.macPaste(instance: instance)
            TestStep.tmuxCommand(arguments: ["set-option", "-t", name, "@ctrlx-recovery-session", UUID().uuidString])
            TestStep.wait(seconds: 6)
            TestStep.macClickButton(titled: "Save", instance: instance)
            TestStep.macWaitForElementQuery(.anyTextMatches("The terminal changed"), timeout: 10, instance: instance)
            TestStep.macScreenshot(label: "retired-session-rename-\(instance)", compare: false, instance: instance)
            TestStep.tmuxStoreDisplayMessage(target: name, format: "#{session_name}:#{pane_pid}", storeAs: "session-after")
            TestStep.assertStoredEqual(key: "session-before", otherKey: "session-after")
            TestStep.macClickButton(titled: "OK", instance: instance)

            TestStep.tmuxStoreDisplayMessage(target: name, format: "#{pane_pid}", storeAs: "process-before")
            TestStep.macContextMenuClick(elementTitle: "Recovery rename target", menuItem: "Rename Session", instance: instance)
            TestStep.macWaitForElement(titled: "Rename Session", timeout: 5, instance: instance)
            TestStep.wait(seconds: 0.5)
            TestStep.macPressKey(.character("a"), modifiers: .command, instance: instance)
            TestStep.macWriteClipboard(text: newName, instance: instance)
            TestStep.macPaste(instance: instance)
            TestStep.macClickButton(titled: "Save", instance: instance)
            TestStep.waitForTmuxDisplayMessage(target: newName, format: "#{session_name}", contains: newName, timeout: 5)
            TestStep.tmuxStoreDisplayMessage(target: newName, format: "#{pane_pid}", storeAs: "process-after")
            TestStep.assertStoredEqual(key: "process-before", otherKey: "process-after")
            TestStep.macWaitForElement(titled: newName, timeout: 10)
            TestStep.macWaitForElement(titled: newName, timeout: 10, instance: 1)
            TestStep.macScreenshot(label: "host-session-renamed-\(instance)", compare: false)
            TestStep.macScreenshot(label: "viewer-session-renamed-\(instance)", compare: false, instance: 1)
        }
    }
}
