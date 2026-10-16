import Foundation

/// Real native processes/history in disposable roots; model replies stay on loopback.
public enum WorkspaceAgentRecoveryScenario {
    public static let modes = CtrlxE2ELib.scenario(
        "Workspace Recovery Modes", tags: ["workspace-recovery", "native-agents", "macos-only", "isolated-api", "persistent-e2e-storage"]
    ) {
        TestStep.tmuxCreateSession(name: "restore-agents", width: 160, height: 45)
        TestStep.injectScript(name: "native_agent_model.py")
        TestStep.injectScript(name: "workspace_agent_recovery.py")
        TestStep.injectScript(name: "workspace_agent_responsiveness.py")
        fixture("setup")
        TestStep.launchMacApp()
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "restore-agents", timeout: 15)
        TestStep.macClickButton(titled: "restore-agents")
        fixture("start")
        fixture("captured")
        setMode(from: "Layout, terminals and Agent conversations", to: "Layout and terminals only")
        TestStep.terminateMacApp()
        fixture("prepare-reboot")
        TestStep.tmuxCommand(arguments: ["kill-server"])
        TestStep.tmuxCreateSession(name: "agent-collision", width: 160, height: 45)
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        fixture("mode-layout")
        TestStep.macWaitForElement(titled: "Resume", timeout: 15)
        TestStep.macScreenshot(label: "layout-only-waits-for-resume", compare: false)
        setMode(from: "Layout and terminals only", to: "Layout, terminals and Agent conversations")
        TestStep.terminateMacApp()
        TestStep.tmuxCommand(arguments: ["run-shell", "-b", "python3 \"$TMPDIR/workspace_agent_responsiveness.py\" '${ctrlxStateRoot}' '${tmuxSocket}'"])
        TestStep.waitForFileContains(path: "${ctrlxStateRoot}/../evidence/heartbeat-ready.json", substring: "ready", storeAs: "heartbeat-ready", timeout: 5)
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        fixture("rebuilt")
        TestStep.waitForFileContains(path: "${ctrlxStateRoot}/../evidence/agent-responsiveness.json", substring: "\"passed\":", storeAs: "agent-responsiveness", timeout: 15)
        TestStep.assertStoredContains(key: "agent-responsiveness", substring: "\"passed\": true")
        TestStep.macScreenshot(label: "agents-resumed", compare: false)
        setMode(from: "Layout, terminals and Agent conversations", to: "Off")
        TestStep.terminateMacApp()
        fixture("mode-prepare-off")
        TestStep.tmuxCommand(arguments: ["kill-server"])
        TestStep.tmuxCreateSession(name: "mode-keeper", width: 120, height: 40)
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForElement(titled: "mode-keeper", timeout: 15)
        TestStep.macClickButton(titled: "mode-keeper")
        fixture("mode-disabled")
        TestStep.tmuxSendKeys(target: "mode-keeper:0", keys: "printf 'MODE_%s\\n' 'OFF_LIVE'", literal: true)
        TestStep.tmuxSendKeys(target: "mode-keeper:0", keys: "Enter")
        TestStep.tmuxStoreDisplayMessage(target: "mode-keeper:0", format: "#{pane_id}", storeAs: "keeperPane")
        TestStep.macWaitForElementQuery(.allOf([.identifier("terminal-${keeperPane}"), .valueContains("MODE_OFF_LIVE")]), timeout: 10)
        TestStep.macScreenshot(label: "off-keeps-live-connection", compare: false)
    }

    private static func setMode(from old: String, to new: String) -> TestScenario {
        CtrlxE2ELib.scenario("Set recovery mode: \(new)", tags: ["shortcut"]) {
            TestStep.macOpenSettings()
            TestStep.macSelectSettingsTab("General")
            TestStep.macClickMenuItem(menuButtonTitle: old, itemTitle: new)
            TestStep.macWaitForElementQuery(.allOf([.role("AXPopUpButton"), .valueContains(new)]), timeout: 5)
            TestStep.macCloseWindow(titled: "General")
        }
    }

    public static let scenario = CtrlxE2ELib.scenario(
        "Workspace Agent Recovery", tags: ["workspace-recovery", "native-agents", "macos-only", "isolated-api"]
    ) {
        TestStep.tmuxCreateSession(name: "restore-agents", width: 160, height: 45)
        TestStep.injectScript(name: "native_agent_model.py")
        TestStep.injectScript(name: "workspace_agent_recovery.py")
        fixture("setup")
        TestStep.launchMacApp()
        Shortcut.openPanesWindow()
        TestStep.macResizeWindow(width: 1_300, height: 800)
        TestStep.macWaitForElement(titled: "restore-agents", timeout: 15)
        TestStep.macClickButton(titled: "restore-agents")
        fixture("start")
        TestStep.macClickButton(titled: "restore-agents:0")
        TestStep.macMoveWindow(x: 100, y: 80)
        TestStep.macDragElementOutsideWindow(.labelContains("restore-agents:3"))
        TestStep.macWaitForWindow(titled: "restore-agents — Workspace", timeout: 15)
        fixture("captured")
        TestStep.macScreenshot(label: "native-agents-before-restart", compare: false)

        TestStep.terminateMacApp()
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        fixture("survived")
        TestStep.macWaitForWindow(titled: "restore-agents — Workspace", timeout: 15)

        TestStep.terminateMacApp()
        fixture("prepare-reboot")
        TestStep.tmuxCommand(arguments: ["kill-server"])
        TestStep.tmuxCreateSession(name: "agent-collision", width: 160, height: 45)
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        fixture("rebuilt")
        TestStep.macWaitForWindow(titled: "restore-agents — Workspace", timeout: 15)
        restoredContent
        TestStep.macScreenshot(label: "native-agents-after-reconstruction", compare: false)

        TestStep.terminateMacApp()
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        fixture("relaunch")
        restoredContent

        TestStep.terminateMacApp()
        fixture("prepare-interruption")
        TestStep.tmuxCommand(arguments: ["kill-server"])
        TestStep.tmuxCreateSession(name: "agent-collision-two", width: 160, height: 45)
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        fixture("pending")
        TestStep.macScreenshot(label: "native-agent-awaiting-identity", compare: false)
        TestStep.terminateMacApp()
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        fixture("pending-relaunch")
        fixture("released")
        restoredContent
        TestStep.macScreenshot(label: "native-agent-reconciled-after-relaunch", compare: false)
        fixture("finish")
    }

    private static let restoredContent = CtrlxE2ELib.scenario("Restored native Agent content", tags: ["shortcut"]) {
        for target in ["restore-agents:0.0", "restore-agents:0.1", "restore-agents:3.0"] {
            TestStep.tmuxStoreDisplayMessage(target: target, format: "#{pane_id}", storeAs: "restoredAgentPane")
            TestStep.macWaitForElementQuery(.allOf([
                .identifier("terminal-${restoredAgentPane}"), .valueContains("RECOVERY_IDLE_FIXTURE"),
            ]), timeout: 15)
        }
    }

    private static func fixture(_ phase: String) -> TestScenario {
        CtrlxE2ELib.scenario("Native recovery fixture: \(phase)", tags: ["shortcut"]) {
            TestStep.tmuxCommand(arguments: [
                "run-shell", "-b",
                "python3 \"$TMPDIR/workspace_agent_recovery.py\" '\(phase)' '${ctrlxStateRoot}' '${tmuxSocket}' '${macOSAppPath}'",
            ])
            TestStep.waitForFileContains(
                path: "${ctrlxStateRoot}/../evidence/\(phase).json",
                substring: "\"passed\":", storeAs: "agent-recovery-\(phase)", timeout: 90
            )
            TestStep.assertStoredContains(key: "agent-recovery-\(phase)", substring: "\"passed\": true")
        }
    }
}
