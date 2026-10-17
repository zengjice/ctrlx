import Foundation

/// Real encrypted requests from iOS and Mac Viewers while the local Dashboard is open.
public enum WorkspaceDashboardScenario {
    private static let pairing = TestScenario(
        name: "Dashboard pairing", steps: Shortcut.twoMacPairing.steps.flatMap { step -> [TestStep] in
            if case .macCGClickElement(_, _, _, 1, _) = step {
                return [.macActivate(instance: 1), .macClickButton(titled: "Connect", instance: 1)]
            }
            return [step]
        }
    )

    public static let macScenario = CtrlxE2ELib.scenario("Workspace Dashboard Mac", tags: ["dashboard", "sync", "macos-only", "isolated-api"]) {
        pairing
        TestStep.tmuxCreateSession(name: "overview-session", width: 80, height: 24)
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "overview-session", timeout: 15)
        TestStep.macClickButton(titled: "Dashboard")
        TestStep.macWaitForWindow(titled: "Dashboard", timeout: 10)
        TestStep.macWaitForElementQuery(.anyTextMatches("Memory"), timeout: 15)
        TestStep.macScreenshot(label: "dashboard-local", compare: false)
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macClickButton(titled: "Dashboard", instance: 1)
        TestStep.macWaitForWindow(titled: "Dashboard", timeout: 10, instance: 1)
        TestStep.macWaitForElementQuery(.anyTextMatches("Memory"), timeout: 15, instance: 1)
        TestStep.macScreenshot(label: "dashboard-mac-viewer", compare: false, instance: 1)
    }

    public static let scenario = CtrlxE2ELib.scenario("Workspace Dashboard", tags: ["dashboard", "sync", "isolated-api"]) {
        FreshPairingScenario.scenario
        Shortcut.addMacViewer
        TestStep.tmuxCreateSession(name: "overview-session", width: 80, height: 24)
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "overview-session", timeout: 15)
        TestStep.macClickButton(titled: "Dashboard")
        TestStep.macWaitForWindow(titled: "Dashboard", timeout: 10)
        TestStep.macWaitForElementQuery(.anyTextMatches("Memory"), timeout: 15)
        TestStep.macScreenshot(label: "dashboard-local", compare: false)

        Shortcut.openPanesWindow(instance: 1)
        TestStep.macClickButton(titled: "Dashboard", instance: 1)
        TestStep.macWaitForWindow(titled: "Dashboard", timeout: 10, instance: 1)
        TestStep.macWaitForElementQuery(.anyTextMatches("Memory"), timeout: 15, instance: 1)
        TestStep.macScreenshot(label: "dashboard-mac-viewer", compare: false, instance: 1)

        TestStep.iosTap(.identifier("dashboard-open"))
        TestStep.iosWaitForElement(.labelContains("Memory"), timeout: 20)
        TestStep.iosScreenshot(label: "dashboard-ios", compare: false)
        TestStep.iosTap(.label("Done"))
        TestStep.iosWaitForElement(.labelContains("Sessions"), timeout: 10)
        TestStep.iosWaitForElement(.labelContains("overview-session"), timeout: 10)
        TestStep.macCloseWindow(titled: "Dashboard")
        TestStep.macCloseWindow(titled: "Dashboard", instance: 1)
    }
}
