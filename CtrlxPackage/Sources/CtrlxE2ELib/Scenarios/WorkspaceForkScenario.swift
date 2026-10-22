import Foundation

/// Real native history, private config roots and loopback-only model responses.
public enum WorkspaceForkScenario {
    /// The caller drives an owned native Agent iOS device, then acknowledges
    /// rejection and successful creation before the fixture checks native state.
    public static let agentIOSHost = CtrlxE2ELib.scenario(
        "Workspace Fork Agent iOS Host", tags: ["manual", "recovery", "fork", "macos-only", "isolated-api", "persistent-e2e-storage"]
    ) {
        TestStep.tmuxCreateSession(name: "restore-agents", width: 160, height: 45)
        TestStep.injectScript(name: "native_agent_model.py")
        TestStep.injectScript(name: "workspace_agent_recovery.py")
        fixture("fork-setup")
        TestStep.startServer
        TestStep.verifyServerHealth
        TestStep.launchMacApp()
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 10)
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.macClickButton(titled: "Generate Pairing Code")
        TestStep.macWaitForElement(titled: "Copy Code", timeout: 10)
        TestStep.macClickButton(titled: "Copy Code")
        TestStep.macReadClipboard(storeAs: "pairingCode")
        TestStep.writeFile(path: "${ctrlxStateRoot}/../pairing-code.txt", content: "${pairingCode}")
        TestStep.macCloseWindow(titled: "Remote Access")
        fixture("start")
        fixture("fork-ready")
        TestStep.waitForFileContains(
            path: "${ctrlxStateRoot}/../complete.done", substring: "ready",
            storeAs: "fork-agent-ios", timeout: 900
        )
        fixture("fork-check-local")
    }

    public static let scenario = CtrlxE2ELib.scenario(
        "Workspace Fork", tags: ["recovery", "fork", "native-agents", "macos-only", "isolated-api", "persistent-e2e-storage"]
    ) {
        TestStep.tmuxCreateSession(name: "restore-agents", width: 160, height: 45)
        TestStep.injectScript(name: "native_agent_model.py")
        TestStep.injectScript(name: "workspace_agent_recovery.py")
        fixture("fork-setup")
        Shortcut.twoMacPairing
        TestStep.macCloseWindow(titled: "Remote Access")
        TestStep.macCloseWindow(titled: "Remote Hosts", instance: 1)
        fixture("start")
        fixture("fork-ready")
        fixture("fork-hide-history")
        TestStep.terminateMacApp()
        TestStep.launchMacApp()
        TestStep.waitForHostConnected(timeout: 20)
        fixture("fork-history-unavailable")
        fixture("fork-restore-history")
        fixture("fork-history-restored")
        TestStep.tmuxCommand(arguments: ["select-pane", "-t", "restore-agents:0.0"])
        for instance in 0...1 {
            Shortcut.openPanesWindow(instance: instance)
            TestStep.macResizeWindow(width: 1_300, height: 800, instance: instance)
            TestStep.macWaitForElement(titled: "restore-agents", timeout: 15, instance: instance)
            TestStep.macClickButton(titled: "restore-agents", instance: instance)
            TestStep.macClickButton(titled: "restore-agents:0", instance: instance)
            TestStep.macWaitForElementQuery(.identifier("terminal-%0"), timeout: 15, instance: instance)
            TestStep.macCGClickElement(query: .identifier("terminal-%0"), instance: instance)
            openFork(instance: instance)
            TestStep.tmuxCommand(arguments: ["set-option", "-t", "restore-agents", "@ctrlx-recovery-session", UUID().uuidString])
            TestStep.wait(seconds: 3)
            TestStep.macCGClickElement(query: .allOf([.role("AXButton"), .label("Fork")]), instance: instance)
            TestStep.macWaitForElementQuery(.valueContains("changed"), timeout: 15, instance: instance)
            TestStep.macScreenshot(label: "rejected-\(instance)", compare: false, instance: instance)
            TestStep.macClickButton(titled: "Cancel", instance: instance)
            TestStep.macClickButton(titled: "restore-agents", instance: instance)
            TestStep.macWaitForElement(titled: "restore-agents:0", timeout: 15, instance: instance)
            TestStep.macClickButton(titled: "restore-agents:0", instance: instance)
            TestStep.macWaitForElementQuery(.identifier("terminal-%0"), timeout: 15, instance: instance)
            TestStep.macCGClickElement(query: .identifier("terminal-%0"), instance: instance)
            openFork(instance: instance)
            TestStep.macFocusElement(titled: "Fork Name", instance: instance)
            TestStep.macSetFocusedText(instance == 0 ? "fork-local" : "fork-remote", instance: instance)
            TestStep.macCGClickElement(query: .allOf([.role("AXButton"), .label("Fork")]), instance: instance)
            let name = instance == 0 ? "fork-local" : "fork-remote"
            TestStep.macWaitForElementQuery(.allOf([.labelContains(name), .valueContains("selected")]), timeout: 30, instance: instance)
            TestStep.tmuxStoreDisplayMessage(target: "restore-agents:\(name)", format: "#{pane_id}", storeAs: "forkPane")
            TestStep.macWaitForElementQuery(.allOf([.identifier("terminal-${forkPane}"), .valueContains("RECOVERY_IDLE_FIXTURE")]), timeout: 30, instance: instance)
            fixture(instance == 0 ? "fork-check-local" : "fork-check-remote")
            TestStep.macScreenshot(label: "created-\(instance)", compare: false, instance: instance)
        }
        fixture("fork-finish")
    }

    private static func openFork(instance: Int) -> TestScenario {
        CtrlxE2ELib.scenario("Open Fork", tags: ["shortcut"]) {
            TestStep.macContextSubmenuClick(elementTitle: "restore-agents:0", parentMenuItem: "Fork", submenuItem: "In Current Directory", instance: instance)
            TestStep.macWaitForElementQuery(.identifier("agentFork.panel"), timeout: 10, instance: instance)
        }
    }

    private static func fixture(_ phase: String) -> TestScenario {
        CtrlxE2ELib.scenario("Fork fixture: \(phase)", tags: ["shortcut"]) {
            TestStep.tmuxCommand(arguments: [
                "run-shell", "-b",
                "python3 \"$TMPDIR/workspace_agent_recovery.py\" '\(phase)' '${ctrlxStateRoot}' '${tmuxSocket}' '${macOSAppPath}'",
            ])
            TestStep.waitForFileContains(path: "${ctrlxStateRoot}/../evidence/\(phase).json", substring: "\"passed\":", storeAs: "fork-\(phase)", timeout: 90)
            TestStep.assertStoredContains(key: "fork-\(phase)", substring: "\"passed\": true")
        }
    }
}
