import Foundation

public enum DetachedTerminalWindowScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Detached Terminal Window", tags: ["tabs", "macos-only", "isolated-api"]
    ) {
        setupWindows
        TestStep.launchMacApp()
        Shortcut.openPanesWindow()
        exercise(instance: 0)
    }

    public static let macViewer = CtrlxE2ELib.scenario(
        "Detached Terminal Window Mac Viewer", tags: ["tabs", "macos-only", "isolated-api"]
    ) {
        Shortcut.twoMacPairing
        setupWindows
        Shortcut.openPanesWindow(instance: 1)
        exercise(instance: 1)
    }

    private static let setupWindows = CtrlxE2ELib.scenario("Detached fixtures", tags: ["shortcut"]) {
        TestStep.tmuxCreateSession(name: "detached-test", width: 120, height: 40)
        TestStep.tmuxCommand(arguments: ["rename-window", "-t", "detached-test:0", "DETACHED_SOURCE"])
        TestStep.tmuxCommand(arguments: ["set-window-option", "-t", "detached-test:0", "automatic-rename", "off"])
        TestStep.tmuxCommand(arguments: ["new-window", "-d", "-t", "detached-test", "-n", "OTHER_WINDOW"])
        TestStep.tmuxStoreDisplayMessage(target: "detached-test:0", format: "#{window_id}", storeAs: "originalWindowID")
    }

    private static func exercise(instance: Int) -> TestScenario {
        CtrlxE2ELib.scenario("Detach and restore", tags: ["shortcut"]) {
            TestStep.macMoveWindow(x: 180, y: 100, instance: instance)
            TestStep.macWaitForElement(titled: "detached-test", timeout: 15, instance: instance)
            TestStep.macClickButton(titled: "detached-test", instance: instance)
            TestStep.macWaitForElementQuery(.identifier("terminal-%0"), timeout: 15, instance: instance)
            TestStep.macDragElementOutsideWindow(.labelContains("detached-test:0"), instance: instance)
            TestStep.macWaitForWindow(titled: "detached-test — Workspace", timeout: 10, instance: instance)
            TestStep.macWaitForElementQuery(.identifier("terminal-%0"), timeout: 10, instance: instance)
            TestStep.macScreenshot(label: "detached", compare: false, instance: instance)

            TestStep.macCGClickElement(query: .identifier("terminal-%0"), instance: instance)
            TestStep.macType(text: "echo DETACHED_INPUT_ONLY", pressReturn: true, instance: instance)
            TestStep.tmuxWaitForPaneContent(target: "detached-test:0.0", contains: "DETACHED_INPUT_ONLY", timeout: 10)
            TestStep.tmuxCapturePaneContent(target: "detached-test:1.0", storeAs: "otherWindow")
            TestStep.assertStoredNotContains(key: "otherWindow", substring: "DETACHED_INPUT_ONLY")

            TestStep.macCloseWindow(titled: "detached-test — Workspace", instance: instance)
            TestStep.macWaitForElementQuery(.labelContains("detached-test:0"), timeout: 10, instance: instance)
            TestStep.macCGClickElement(query: .labelContains("detached-test:0"), instance: instance)
            TestStep.macWaitForElementQuery(.identifier("terminal-%0"), timeout: 10, instance: instance)
            TestStep.tmuxStoreDisplayMessage(target: "detached-test:0", format: "#{window_id}", storeAs: "restoredWindowID")
            TestStep.assertStoredEqual(key: "originalWindowID", otherKey: "restoredWindowID")
            TestStep.macScreenshot(label: "restored", compare: false, instance: instance)
        }
    }
}
