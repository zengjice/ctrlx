import Foundation

/// E2E scenario: the Host-only Chromium settings entry opens the password
/// manager in a reusable native window. Closing and reopening also verifies
/// that the native window handle is cleared instead of retaining a dead page.
public enum BrowserSettingsScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Browser Settings",
        tags: ["browser", "settings", "macos-only"]
    ) {
        TestStep.tmuxCreateSession(name: "settingsession", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "settingsession:0")
        TestStep.wait(seconds: 1)

        TestStep.launchMacApp(browserMockKeychain: true)
        TestStep.wait(seconds: 3)
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "CtrlX", timeout: 5)
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElement(titled: "settingsession", timeout: 5)
        TestStep.macClickButton(titled: "settingsession")
        TestStep.macWaitForElement(titled: "settingsession:0", timeout: 5)
        TestStep.macContextMenuClick(elementTitle: "settingsession:0", menuItem: "Open Browser")
        TestStep.macWaitForElement(titled: "Browser Settings", timeout: 10)

        TestStep.macClickMenuItem(menuButtonTitle: "Browser Settings", itemTitle: "Password Manager")
        TestStep.macWaitForWindow(titled: "Password Manager", timeout: 20)
        TestStep.macScreenshot(label: "mac-password-manager")

        TestStep.macCloseWindow(titled: "Password Manager")
        TestStep.wait(seconds: 1)
        TestStep.macClickMenuItem(menuButtonTitle: "Browser Settings", itemTitle: "Password Manager")
        TestStep.macWaitForWindow(titled: "Password Manager", timeout: 20)
    }
}
