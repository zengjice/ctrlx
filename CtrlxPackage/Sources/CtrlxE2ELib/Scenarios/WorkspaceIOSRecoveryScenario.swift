import Foundation

/// Real iOS navigation and private content across App and Host restarts.
public enum WorkspaceIOSRecoveryScenario {
    /// Host lifecycle companion for native Agent iOS acceptance. The caller
    /// drives its owned device and acknowledges each checkpoint after validation.
    public static let agentIOSHost = CtrlxE2ELib.scenario(
        "Workspace Agent iOS Host", tags: ["manual", "workspace-recovery", "macos-only", "isolated-api", "live-workspace-content", "persistent-e2e-storage"]
    ) {
        TestStep.tmuxCreateSession(name: "restore-ios", width: 100, height: 35)
        TestStep.injectScript(name: "workspace_ios_recovery.py")
        fixture("setup", needsIOS: false)
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
        checkpoint("captured")
        TestStep.macCloseWindow(titled: "Remote Access")
        TestStep.terminateMacApp()
        TestStep.writeFile(path: "${ctrlxStateRoot}/../host-offline.txt", content: "ready")
        checkpoint("offline")
        TestStep.launchMacApp()
        TestStep.waitForHostConnected(timeout: 20)
        TestStep.writeFile(path: "${ctrlxStateRoot}/../host-restored.txt", content: "ready")
        checkpoint("restored")
        TestStep.terminateMacApp()
        TestStep.writeFile(path: "${ctrlxStateRoot}/../host-rebuild-ready.txt", content: "ready")
        checkpoint("prepare-reboot")
        TestStep.launchMacApp()
        TestStep.waitForHostConnected(timeout: 20)
        TestStep.writeFile(path: "${ctrlxStateRoot}/../host-rebuilt.txt", content: "ready")
        checkpoint("complete")
    }

    private static func checkpoint(_ name: String) -> TestStep {
        .waitForFileContains(
            path: "${ctrlxStateRoot}/../\(name).done", substring: "ready",
            storeAs: "agent-ios-\(name)", timeout: 900
        )
    }

    public static let scenario = CtrlxE2ELib.scenario(
        "Workspace iOS Recovery", tags: ["workspace-recovery", "ios", "isolated-api", "live-workspace-content", "persistent-e2e-storage"]
    ) {
        TestStep.tmuxCreateSession(name: "restore-ios", width: 100, height: 35)
        TestStep.injectScript(name: "workspace_ios_recovery.py")
        fixture("setup", needsIOS: false)
        FreshPairingScenario.scenario
        TestStep.terminateIOSApp
        fixture("configure")
        TestStep.launchIOSApp()
        TestStep.iosWaitForElement(.label("Connected"), timeout: 20)
        TestStep.macCloseWindow(titled: "Remote Access")
        TestStep.tmuxStorePaneId(target: "restore-ios:2.0", storeAs: "iosSourcePane")
        TestStep.macSendHookEvent(
            json: """
            {"hook_event_name":"SessionStart","session_id":"e2e-ios-recovery"}
            """,
            tmuxPane: "${iosSourcePane}", projectPath: "${ctrlxStateRoot}/ios-project"
        )
        Shortcut.iosConnectToSession(sessionName: "restore-ios")
        selectSource
        TestStep.iosWaitForElement(.labelContains("Reply to the agent"), timeout: 15)
        TestStep.iosTap(.labelContains("Reply to the agent"))
        TestStep.iosType(text: "Unsent iOS recovery draft. Keep this text without sending it.")
        TestStep.macSendHookEvent(
            json: """
            {"hook_event_name":"SessionEnd","session_id":"e2e-ios-recovery","reason":"user_quit"}
            """,
            tmuxPane: "${iosSourcePane}", projectPath: "${ctrlxStateRoot}/ios-project"
        )
        TestStep.iosWaitForElement(.label("Recovered draft"), timeout: 10)
        TestStep.iosTap(.identifier("window-tabs-picker"))
        TestStep.iosTap(.label("Actions for SOURCE"))
        TestStep.iosTap(.label("Open Files"))
        TestStep.iosWaitForElement(.label("docs"), timeout: 15)
        TestStep.iosTap(.label("docs"))
        TestStep.iosTap(.label("chapter.txt"))
        TestStep.iosWaitForElement(.labelContains("IOS_PRIVATE_PREVIEW"), timeout: 15)
        fixture("captured")

        TestStep.terminateIOSApp
        TestStep.terminateMacApp()
        TestStep.launchIOSApp()
        TestStep.wait(seconds: 3)
        fixture("offline")
        TestStep.launchMacApp()
        TestStep.waitForHostConnected(timeout: 20)
        fixture("restored")
        restoredContent

        TestStep.terminateMacApp()
        TestStep.wait(seconds: 3)
        fixture("host-offline")
        fixture("prepare-reboot")
        TestStep.tmuxCommand(arguments: ["kill-server"])
        TestStep.tmuxCreateSession(name: "ios-route-collision", width: 100, height: 35)
        TestStep.launchMacApp()
        TestStep.waitForHostConnected(timeout: 20)
        fixture("rebuilt")
        restoredContent
        TestStep.terminateIOSApp
        TestStep.launchIOSApp()
        fixture("relaunch")
        restoredContent
        TestStep.iosScreenshot(label: "ios-recovered-workspace")
    }

    private static let selectSource = CtrlxE2ELib.scenario("Select iOS source", tags: ["shortcut"]) {
        TestStep.iosTap(.identifier("window-tabs-picker"))
        TestStep.iosTap(.label("SOURCE"))
        TestStep.iosWaitForElement(.labelContains("restore-ios:2"), timeout: 15)
    }

    private static let restoredContent = CtrlxE2ELib.scenario("Recovered iOS content", tags: ["shortcut"]) {
        // Recovery itself must navigate to this preview, without selecting the session again.
        TestStep.iosWaitForElement(.labelContains("IOS_PRIVATE_PREVIEW"), timeout: 20)
        selectSource
        TestStep.iosWaitForElement(.label("Recovered draft"), timeout: 10)
        TestStep.iosTap(.label("Recovered draft"))
        TestStep.iosTap(.label("Draft 1"))
        TestStep.iosWaitForElement(.valueContains("Unsent iOS recovery draft."), timeout: 10)
        TestStep.iosTap(.label("Copy"))
        TestStep.iosReadClipboard(storeAs: "iosRecoveredDraft")
        TestStep.assertStoredContains(key: "iosRecoveredDraft", substring: "Unsent iOS recovery draft. Keep this text without sending it.")
        TestStep.iosTap(.label("Done"))
        TestStep.iosTap(.identifier("window-tabs-picker"))
        TestStep.iosTap(.label("Files · docs"))
        TestStep.iosWaitForElement(.labelContains("IOS_PRIVATE_PREVIEW"), timeout: 15)
        TestStep.wait(seconds: 3)
    }

    private static func fixture(_ phase: String, needsIOS: Bool = true) -> TestScenario {
        let iosRoot = needsIOS ? "${iosStateRoot}" : "-"
        return CtrlxE2ELib.scenario("iOS recovery fixture: \(phase)", tags: ["shortcut"]) {
            TestStep.tmuxCommand(arguments: [
                "run-shell", "-b",
                "python3 \"$TMPDIR/workspace_ios_recovery.py\" '\(phase)' '${ctrlxStateRoot}' '\(iosRoot)' '${tmuxSocket}'",
            ])
            TestStep.waitForFileContains(
                path: "${ctrlxStateRoot}/../evidence/\(phase).json", substring: "\"passed\":",
                storeAs: "ios-recovery-\(phase)", timeout: 45
            )
            TestStep.assertStoredContains(key: "ios-recovery-\(phase)", substring: "\"passed\": true")
        }
    }
}
