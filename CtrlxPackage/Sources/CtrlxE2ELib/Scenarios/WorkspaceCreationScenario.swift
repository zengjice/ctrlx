import Foundation

/// New terminal windows keep their source session and remain usable on both Macs.
public enum WorkspaceCreationScenario {
    public static let newSessions = CtrlxE2ELib.scenario(
        "Workspace New Sessions", tags: ["recovery", "creation", "macos-only"]
    ) {
        Shortcut.twoMacPairing
        TestStep.macCloseWindow(titled: "Remote Access")
        TestStep.macCloseWindow(titled: "Remote Hosts", instance: 1)
        TestStep.tmuxCreateSession(name: "original", width: 100, height: 30)
        TestStep.tmuxStoreDisplayMessage(target: "original:0", format: "#{pane_pid}", storeAs: "originalPID")
        for instance in 0...1 {
            Shortcut.openPanesWindow(instance: instance)
            TestStep.macWaitForElement(titled: "original", timeout: 15, instance: instance)
            TestStep.macClickButton(titled: "original", instance: instance)
            let session = instance == 0 ? "terminal" : "terminal-2"
            if instance == 0 {
                TestStep.macPressKey(.character("n"), modifiers: .command)
            } else {
                TestStep.macCGClickElement(query: .help("Create new session"), instance: instance)
            }
            TestStep.macWaitForElement(titled: "New Terminal", timeout: 5, instance: instance)
            TestStep.macClickButton(titled: "New Terminal", instance: instance)
            TestStep.macWaitForElementQuery(
                .allOf([.labelContains("\(session):0 terminal 1"), .valueContains("selected")]),
                timeout: 15, instance: instance
            )
            TestStep.tmuxStoreDisplayMessage(target: "\(session):0", format: "#{pane_id}", storeAs: "createdPane")
            Shortcut.tmuxRunCommand(target: "\(session):0", command: "printf 'CREATED_SESSION_\(instance)\\n'")
            TestStep.macWaitForElementQuery(
                .allOf([.identifier("terminal-${createdPane}"), .valueContains("CREATED_SESSION_\(instance)")]),
                timeout: 15, instance: instance
            )
            TestStep.macScreenshot(label: "created-session-\(instance)", compare: false, instance: instance)
        }
        TestStep.tmuxStoreDisplayMessage(target: "original:0", format: "#{pane_pid}", storeAs: "finalPID")
        TestStep.assertStoredEqual(key: "originalPID", otherKey: "finalPID")
    }

    public static let agentIOSNewSessionHost = CtrlxE2ELib.scenario(
        "Workspace New Session Agent iOS Host", tags: ["manual", "recovery", "creation", "macos-only", "isolated-api"]
    ) {
        TestStep.tmuxCreateSession(name: "original", width: 100, height: 30)
        TestStep.tmuxStoreDisplayMessage(target: "original:0", format: "#{pane_pid}", storeAs: "originalPID")
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
        TestStep.waitForFileContains(path: "${ctrlxStateRoot}/../complete.done", substring: "ready", storeAs: "created-ios", timeout: 900)
        TestStep.tmuxStoreDisplayMessage(target: "original:0", format: "#{pane_pid}", storeAs: "finalPID")
        TestStep.assertStoredEqual(key: "originalPID", otherKey: "finalPID")
    }

    public static let scenario = CtrlxE2ELib.scenario(
        "Workspace Creation",
        tags: ["recovery", "creation", "macos-only"]
    ) {
        Shortcut.twoMacPairing
        TestStep.macCloseWindow(titled: "Remote Access")
        TestStep.macCloseWindow(titled: "Remote Hosts", instance: 1)
        TestStep.tmuxCreateSession(name: "creation", width: 100, height: 30)
        TestStep.tmuxCommand(arguments: ["rename-window", "-t", "creation:0", "original"])
        TestStep.tmuxStoreDisplayMessage(target: "creation:original", format: "#{pane_pid}", storeAs: "originalPID")
        TestStep.wait(seconds: 3)
        for instance in 0...1 {
            Shortcut.openPanesWindow(instance: instance)
            TestStep.macWaitForElement(titled: "creation", timeout: 15, instance: instance)
            TestStep.macClickButton(titled: "creation", instance: instance)
            TestStep.macWaitForElement(titled: "creation:0 original", timeout: 10, instance: instance)
        }
        for instance in 0...1 {
            let index = instance + 1
            TestStep.macActivate(instance: instance)
            TestStep.macPressKey(.character("t"), modifiers: .command, instance: instance)
            TestStep.macWaitForElementQuery(
                .allOf([.labelContains("creation:\(index) terminal \(index)"), .valueContains("selected")]),
                timeout: 15, instance: instance
            )
            TestStep.macWaitForElementQuery(.identifier("terminal-%\(index)"), timeout: 10, instance: instance)
            TestStep.wait(seconds: 2)
            Shortcut.tmuxRunCommand(target: "creation:\(index)", command: "printf 'CREATED_WINDOW_\(index)\\n'")
            TestStep.macWaitForElementQuery(
                .allOf([.identifier("terminal-%\(index)"), .valueContains("CREATED_WINDOW_\(index)")]),
                timeout: 15, instance: instance
            )
            TestStep.macScreenshot(label: "created-\(instance)", compare: false, instance: instance)
        }
        TestStep.tmuxStoreDisplayMessage(target: "creation:original", format: "#{pane_pid}", storeAs: "finalPID")
        TestStep.assertStoredEqual(key: "originalPID", otherKey: "finalPID")
    }
}
