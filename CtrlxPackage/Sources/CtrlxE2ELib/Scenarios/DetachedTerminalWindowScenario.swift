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

    public static let session = CtrlxE2ELib.scenario(
        "Detached Session Window", tags: ["tabs", "macos-only", "isolated-api"],
    ) {
        setupWindows
        TestStep.launchMacApp()
        Shortcut.openPanesWindow()
        exerciseSession(instance: 0)
    }

    public static let sessionMacViewer = CtrlxE2ELib.scenario(
        "Detached Session Window Mac Viewer", tags: ["tabs", "macos-only", "isolated-api"],
    ) {
        Shortcut.twoMacPairing
        setupWindows
        Shortcut.openPanesWindow(instance: 1)
        exerciseSession(instance: 1)
    }

    private static func exerciseSession(instance: Int) -> TestScenario {
        CtrlxE2ELib.scenario("Detach whole session and restore", tags: ["shortcut"]) {
            TestStep.macMoveWindow(x: 180, y: 100, instance: instance)
            TestStep.macWaitForElementQuery(.identifier("session-row-detached-test"), timeout: 15, instance: instance)
            TestStep.macDragElementOutsideWindow(.identifier("session-row-detached-test"), instance: instance)
            TestStep.macWaitForWindow(titled: "detached-test — Workspace", timeout: 10, instance: instance)
            TestStep.macWaitForElementQuery(.labelContains("OTHER_WINDOW"), timeout: 10, instance: instance)
            TestStep.macCGClickElement(query: .labelContains("OTHER_WINDOW"), instance: instance)
            TestStep.macWaitForElementQuery(.identifier("terminal-%1"), timeout: 10, instance: instance)
            TestStep.macCGClickElement(query: .identifier("terminal-%1"), instance: instance)
            TestStep.macType(text: "echo SESSION_WINDOW_INPUT", pressReturn: true, instance: instance)
            TestStep.tmuxWaitForPaneContent(target: "detached-test:1.0", contains: "SESSION_WINDOW_INPUT", timeout: 10)
            TestStep.tmuxCapturePaneContent(target: "detached-test:0.0", storeAs: "otherWindow")
            TestStep.assertStoredNotContains(key: "otherWindow", substring: "SESSION_WINDOW_INPUT")
            TestStep.macScreenshot(label: "session-detached", compare: false, instance: instance)
            TestStep.macCloseWindow(titled: "detached-test — Workspace", instance: instance)
            TestStep.macContextMenuClick(elementTitle: "detached-test", menuItem: "Open in New Window", instance: instance)
            TestStep.macWaitForWindow(titled: "detached-test — Workspace", timeout: 10, instance: instance)
            TestStep.macWaitForElementQuery(.labelContains("OTHER_WINDOW"), timeout: 10, instance: instance)
            TestStep.macCloseWindow(titled: "detached-test — Workspace", instance: instance)
            TestStep.tmuxStoreDisplayMessage(target: "detached-test:0", format: "#{window_id}", storeAs: "restoredWindowID")
            TestStep.assertStoredEqual(key: "originalWindowID", otherKey: "restoredWindowID")
        }
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

            // Stay in the detached window throughout: resizing alone must not Fit,
            // but an ordinary content click must use its new viewport.
            TestStep.macResizeWindow(width: 740, height: 500, instance: instance)
            TestStep.macCGClickElement(query: .identifier("terminal-%0"), instance: instance)
            TestStep.wait(seconds: 1)
            TestStep.tmuxStoreDisplayMessage(target: "detached-test:0", format: "#{window_width}x#{window_height}", storeAs: "beforeResize")
            TestStep.tmuxStoreDisplayMessage(target: "detached-test:1", format: "#{window_width}x#{window_height}", storeAs: "otherBeforeResize")
            TestStep.macResizeWindow(width: 1_100, height: 740, instance: instance)
            TestStep.wait(seconds: 1)
            TestStep.tmuxStoreDisplayMessage(target: "detached-test:0", format: "#{window_width}x#{window_height}", storeAs: "afterPassiveResize")
            TestStep.assertStoredEqual(key: "beforeResize", otherKey: "afterPassiveResize")
            TestStep.macCGClickElement(query: .identifier("terminal-%0"), instance: instance)
            TestStep.wait(seconds: 1)
            TestStep.tmuxStoreDisplayMessage(target: "detached-test:0", format: "#{window_width}x#{window_height}", storeAs: "afterClickFit")
            TestStep.assertStoredNotEqual(key: "beforeResize", otherKey: "afterClickFit")
            TestStep.tmuxStoreDisplayMessage(target: "detached-test:1", format: "#{window_width}x#{window_height}", storeAs: "otherAfterResize")
            TestStep.assertStoredEqual(key: "otherBeforeResize", otherKey: "otherAfterResize")

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
