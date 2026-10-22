import Foundation

/// Current session bindings must preserve normal local/remote layout actions.
public enum WorkspaceLayoutActionsScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Workspace Layout Actions",
        tags: ["recovery", "reorder", "shared-layout", "macos-only"]
    ) {
        Shortcut.twoMacPairing
        TestStep.macCloseWindow(titled: "Remote Access")
        TestStep.macCloseWindow(titled: "Remote Hosts", instance: 1)
        TestStep.tmuxCreateSession(name: "layout-actions", width: 100, height: 30)
        TestStep.tmuxCommand(arguments: ["rename-window", "-t", "layout-actions:0", "winA"])
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "layout-actions:", "-n", "winB"])
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "layout-actions:", "-n", "winC"])
        TestStep.tmuxCommand(arguments: ["select-window", "-t", "layout-actions:0"])
        TestStep.tmuxStoreDisplayMessage(target: "layout-actions:winA", format: "#{pane_pid}", storeAs: "originalPID")
        TestStep.wait(seconds: 3)
        for instance in 0...1 {
            Shortcut.openPanesWindow(instance: instance)
            TestStep.macWaitForElement(titled: "layout-actions", timeout: 15, instance: instance)
            TestStep.macClickButton(titled: "layout-actions", instance: instance)
            TestStep.macWaitForElement(titled: "layout-actions:0 winA", timeout: 10, instance: instance)
        }

        TestStep.macDragElement(from: .labelContains("layout-actions:2 winC"), to: .labelContains("layout-actions:0 winA"))
        TestStep.waitForTmuxDisplayMessage(target: "layout-actions", format: "#{W:#{window_name}#,}", contains: "winC,winA,winB,", timeout: 10)
        TestStep.macWaitForElement(titled: "layout-actions:0 winC", timeout: 10, instance: 1)
        TestStep.macClickButton(titled: "layout-actions:0 winC")
        TestStep.macClickButton(titled: "Open terminal in split: winB")
        for instance in 0...1 {
            TestStep.macWaitForElement(titled: "Move terminal to left: winB", timeout: 10, instance: instance)
            TestStep.macScreenshot(label: "host-split-\(instance)", compare: false, instance: instance)
        }
        TestStep.macClickButton(titled: "Move terminal to left: winB", instance: 1)
        for instance in 0...1 {
            TestStep.macWaitForElement(titled: "Open terminal in split: winB", timeout: 10, instance: instance)
        }

        TestStep.macDragElement(from: .labelContains("layout-actions:2 winB"), to: .labelContains("layout-actions:0 winC"), instance: 1)
        TestStep.waitForTmuxDisplayMessage(target: "layout-actions", format: "#{W:#{window_name}#,}", contains: "winB,winC,winA,", timeout: 10)
        TestStep.macWaitForElement(titled: "layout-actions:0 winB", timeout: 10)
        TestStep.macClickButton(titled: "layout-actions:0 winB", instance: 1)
        TestStep.macClickButton(titled: "Open terminal in split: winA", instance: 1)
        for instance in 0...1 {
            TestStep.macWaitForElement(titled: "Move terminal to left: winA", timeout: 10, instance: instance)
            TestStep.macScreenshot(label: "viewer-split-\(instance)", compare: false, instance: instance)
        }
        TestStep.tmuxStoreDisplayMessage(target: "layout-actions:winA", format: "#{pane_pid}", storeAs: "finalPID")
        TestStep.assertStoredEqual(key: "originalPID", otherKey: "finalPID")
    }
}
