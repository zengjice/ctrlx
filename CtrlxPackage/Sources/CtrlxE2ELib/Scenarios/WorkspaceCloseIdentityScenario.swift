import Foundation

/// Keeps native confirmation dialogs open across an identity replacement.
/// The real-tmux tests separately cover server restart with reused UUIDs.
public enum WorkspaceCloseIdentityScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Workspace Close Identity", tags: ["workspace-recovery", "macos-only", "isolated-api"]
    ) {
        TestStep.tmuxCreateSession(name: "close-keeper", width: 100, height: 35)
        createTargets
        Shortcut.twoMacPairing
        TestStep.macCloseWindow(titled: "Remote Access")
        TestStep.macCloseWindow(titled: "Remote Hosts", instance: 1)
        for instance in 0...1 {
            Shortcut.openPanesWindow(instance: instance)
            for kind in ["window", "session"] {
                close(kind: kind, instance: instance)
            }
        }
    }

    public static let disabledRecovery = CtrlxE2ELib.scenario(
        "Workspace Identity With Recovery Off", tags: ["workspace-recovery", "macos-only", "isolated-api"]
    ) {
        TestStep.tmuxCreateSession(name: "close-keeper", width: 100, height: 35)
        Shortcut.twoMacPairing
        TestStep.macCloseWindow(titled: "Remote Hosts", instance: 1)
        TestStep.macSelectSettingsTab("General")
        TestStep.macClickMenuItem(menuButtonTitle: "Layout, terminals and Agent conversations", itemTitle: "Off")
        TestStep.macWaitForElementQuery(.allOf([.role("AXPopUpButton"), .valueContains("Off")]), timeout: 5)
        TestStep.macScreenshot(label: "recovery-off", compare: false)
        TestStep.macCloseWindow(titled: "General")
        TestStep.wait(seconds: 3)
        TestStep.readFile(path: "${ctrlxStateRoot}/Recovery/workspace.json", storeAs: "disabled-journal")
        createTargets
        for instance in 0...1 {
            Shortcut.openPanesWindow(instance: instance)
            for kind in ["window", "session"] {
                close(kind: kind, instance: instance)
            }
        }
        TestStep.readFile(path: "${ctrlxStateRoot}/Recovery/workspace.json", storeAs: "after-disabled-closes")
        TestStep.assertStoredEqual(key: "disabled-journal", otherKey: "after-disabled-closes")
    }

    private static var createTargets: TestScenario {
        CtrlxE2ELib.scenario("Create close targets", tags: ["shortcut"]) {
            for instance in 0...1 {
                for kind in ["window", "session"] {
                    let name = "close-\(instance)-\(kind)"
                    TestStep.tmuxCreateSession(name: name, width: 100, height: 35)
                    TestStep.tmuxCommand(arguments: ["respawn-pane", "-k", "-t", "\(name):0.0", "/bin/cat"])
                    TestStep.tmuxCommand(arguments: ["rename-window", "-t", "\(name):0", name])
                }
            }
        }
    }

    private static func close(kind: String, instance: Int) -> TestScenario {
        let name = "close-\(instance)-\(kind)"
        return CtrlxE2ELib.scenario("Close \(kind) from Mac \(instance)", tags: ["shortcut"]) {
            TestStep.macWaitForElement(titled: name, timeout: 15, instance: instance)
            TestStep.macClickButton(titled: name, instance: instance)
            TestStep.tmuxStoreDisplayMessage(target: "\(name):0", format: "#{pane_pid}", storeAs: "close-original-pid")
            TestStep.tmuxStoreDisplayMessage(target: "close-keeper", format: "#{S:#{session_name}|}", storeAs: "close-original-sessions")
            requestClose(name: name, kind: kind, instance: instance)
            TestStep.macWaitForElement(titled: "Close Anyway", timeout: 10, instance: instance)
            TestStep.tmuxCommand(arguments: ["set-option"] + (kind == "window" ? ["-w"] : []) + [
                "-t", "\(name):0", "@ctrlx-recovery-\(kind)", UUID().uuidString,
            ])
            // Let discovery publish the replacement while the dialog stays open.
            TestStep.wait(seconds: 6)
            TestStep.macClickButton(titled: "Close Anyway", instance: instance)
            TestStep.macWaitForElementQuery(.anyTextMatches("The terminal changed"), timeout: 10, instance: instance)
            TestStep.macScreenshot(label: "retired-\(instance)-\(kind)-close", compare: false, instance: instance)
            TestStep.tmuxStoreDisplayMessage(target: "\(name):0", format: "#{pane_pid}", storeAs: "close-surviving-pid")
            TestStep.assertStoredEqual(key: "close-original-pid", otherKey: "close-surviving-pid")
            TestStep.macClickButton(titled: "OK", instance: instance)
            requestClose(name: name, kind: kind, instance: instance)
            TestStep.macWaitForElement(titled: "Close Anyway", timeout: 10, instance: instance)
            TestStep.macClickButton(titled: "Close Anyway", instance: instance)
            TestStep.waitForTmuxDisplayMessageNotEqual(
                target: "close-keeper", format: "#{S:#{session_name}|}",
                notEqualTo: "${close-original-sessions}", timeout: 10
            )
            TestStep.tmuxStoreDisplayMessage(target: "close-keeper", format: "#{S:#{session_name}|}", storeAs: "close-remaining-sessions")
            TestStep.assertStoredNotContains(key: "close-remaining-sessions", substring: name)
        }
    }

    private static func requestClose(name: String, kind: String, instance: Int) -> TestScenario {
        CtrlxE2ELib.scenario("Request \(kind) close", tags: ["shortcut"]) {
            if kind == "window" {
                TestStep.macClickButton(titled: "Close window: \(name)", instance: instance)
            } else {
                // Keep the native window title distinct from the sidebar target.
                TestStep.macClickButton(titled: "close-keeper", instance: instance)
                TestStep.macContextMenuClick(elementTitle: name, menuItem: "Close Session", instance: instance)
            }
        }
    }
}
