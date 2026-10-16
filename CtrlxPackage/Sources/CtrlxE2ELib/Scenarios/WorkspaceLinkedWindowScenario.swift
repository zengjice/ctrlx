import Foundation

public enum WorkspaceLinkedWindowScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Workspace Linked Windows", tags: ["workspace-recovery", "macos-only", "isolated-api"]
    ) {
        TestStep.tmuxCreateSession(name: "linked-a", width: 120, height: 40)
        TestStep.injectScript(name: "workspace_linked_recovery.py")
        fixture("setup")
        TestStep.launchMacApp()
        Shortcut.openPanesWindow()
        TestStep.macMoveWindow(x: 80, y: 80)
        TestStep.macWaitForElement(titled: "linked-a", timeout: 15)
        TestStep.macClickButton(titled: "linked-a")
        TestStep.macWaitForElementQuery(.labelContains("linked-a:0"), timeout: 10)
        TestStep.macDragElementOutsideWindow(.labelContains("linked-a:0"))
        TestStep.macWaitForWindow(titled: "linked-a — Workspace", timeout: 10)
        TestStep.macMoveWindow(x: 300, y: 150)
        TestStep.macResizeWindow(width: 800, height: 550)
        showMain
        TestStep.macClickButton(titled: "linked-b")
        TestStep.macWaitForElementQuery(.labelContains("linked-b:0 B_PRIVATE"), timeout: 10)
        fixture("captured")
        TestStep.macScreenshot(label: "linked-before-restart", compare: false)

        TestStep.terminateMacApp()
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        restoredPresentation
        fixture("survived")
        TestStep.macScreenshot(label: "linked-live-restart", compare: false)

        TestStep.terminateMacApp()
        fixture("prepare-reboot")
        TestStep.tmuxCommand(arguments: ["kill-server"])
        TestStep.tmuxCreateSession(name: "linked-collision", width: 120, height: 40)
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        restoredPresentation
        fixture("rebuilt")
        TestStep.tmuxSendKeys(target: "linked-a:0.0", keys: "printf 'LINKED_%s\\n' 'REBUILT'", literal: true)
        TestStep.tmuxSendKeys(target: "linked-a:0.0", keys: "Enter")
        TestStep.tmuxWaitForPaneContent(target: "linked-b:7.0", contains: "LINKED_REBUILT", timeout: 10)
        TestStep.tmuxStoreDisplayMessage(target: "linked-b:7.0", format: "#{pane_id}", storeAs: "sharedPane")
        TestStep.macWaitForElementQuery(.allOf([.identifier("terminal-${sharedPane}"), .valueContains("LINKED_REBUILT")]), timeout: 10)
        TestStep.macScreenshot(label: "linked-rebuilt", compare: false)
    }

    private static let showMain = CtrlxE2ELib.scenario("Show linked main window", tags: ["shortcut"]) {
        TestStep.macCGClickElement(query: .identifier("panes"), pointInRect: {
            CGPoint(x: $0.midX, y: $0.minY + 20)
        })
    }

    private static let restoredPresentation = CtrlxE2ELib.scenario("Linked window presentation", tags: ["shortcut"]) {
        TestStep.macWaitForWindow(titled: "linked-a — Workspace", timeout: 20)
        TestStep.macWaitForElementQuery(.allOf([.labelContains("linked-a:0 SHARED"), .valueContains("selected")]), timeout: 10)
        showMain
        TestStep.macWaitForElementQuery(.allOf([.labelContains("linked-b:0 B_PRIVATE"), .valueContains("selected")]), timeout: 10)
    }

    private static func fixture(_ phase: String) -> TestScenario {
        CtrlxE2ELib.scenario("Linked recovery fixture: \(phase)", tags: ["shortcut"]) {
            TestStep.tmuxCommand(arguments: [
                "run-shell", "-b",
                "python3 \"$TMPDIR/workspace_linked_recovery.py\" '\(phase)' '${ctrlxStateRoot}' '${tmuxSocket}'",
            ])
            TestStep.waitForFileContains(path: "${ctrlxStateRoot}/../evidence/\(phase).json", substring: "\"passed\":", storeAs: "linked-\(phase)", timeout: 30)
            TestStep.assertStoredContains(key: "linked-\(phase)", substring: "\"passed\": true")
        }
    }
}
