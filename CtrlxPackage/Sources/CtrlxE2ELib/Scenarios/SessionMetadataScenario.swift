import Foundation

/// Editors must retain their original session across a Host identity refresh.
public enum SessionMetadataScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Session Metadata Identity",
        tags: ["sessions", "metadata", "recovery", "macos-only"]
    ) {
        Shortcut.twoMacPairing
        TestStep.macCloseWindow(titled: "Remote Access")
        TestStep.macCloseWindow(titled: "Remote Hosts", instance: 1)
        TestStep.tmuxCreateSession(name: "e2e-metadata", width: 80, height: 24)
        TestStep.tmuxCommand(arguments: ["set-option", "-t", "e2e-metadata", "@ctrlx-description", "original"])
        TestStep.wait(seconds: 3)
        Shortcut.openPanesWindow()
        Shortcut.openPanesWindow(instance: 1)

        for instance in 0...1 {
            TestStep.macWaitForElement(titled: "e2e-metadata", timeout: 15, instance: instance)
            TestStep.macClickButton(titled: "e2e-metadata", instance: instance)
            for field in ["description", "emoji"] {
                let isEmoji = field == "emoji"
                let glyph = instance == 0 ? "🚀" : "🐛"
                let value = isEmoji ? glyph : "fresh-description-\(instance)"
                let search = instance == 0 ? "rocket" : "bug"
                for stale in [true, false] {
                    TestStep.tmuxStoreDisplayMessage(target: "e2e-metadata", format: "#{@ctrlx-description}:#{@ctrlx-emoji}:#{pane_pid}", storeAs: "metadata-before")
                    let menu = isEmoji ? (instance == 0 ? "Set Emoji" : "Emoji: 🚀") : "Edit Description"
                    TestStep.macContextMenuClick(elementTitle: "e2e-metadata", menuItem: menu, instance: instance)
                    TestStep.macWaitForElement(titled: isEmoji ? "Search" : "Session Description", timeout: 5, instance: instance)
                    if isEmoji {
                        TestStep.macFocusElement(titled: "Search", instance: instance)
                    }
                    TestStep.macPressKey(.character("a"), modifiers: .command, instance: instance)
                    TestStep.macWriteClipboard(text: isEmoji ? search : value, instance: instance)
                    TestStep.macPaste(instance: instance)
                    if stale {
                        TestStep.tmuxCommand(arguments: ["set-option", "-t", "e2e-metadata", "@ctrlx-recovery-session", UUID().uuidString])
                        TestStep.wait(seconds: 6)
                    }
                    TestStep.macClickButton(titled: isEmoji ? glyph : "Save", instance: instance)
                    if stale {
                        TestStep.macWaitForElementQuery(.anyTextMatches("The terminal changed"), timeout: 10, instance: instance)
                        TestStep.macScreenshot(label: "retired-\(field)-\(instance)", compare: false, instance: instance)
                        TestStep.tmuxStoreDisplayMessage(target: "e2e-metadata", format: "#{@ctrlx-description}:#{@ctrlx-emoji}:#{pane_pid}", storeAs: "metadata-after")
                        TestStep.assertStoredEqual(key: "metadata-before", otherKey: "metadata-after")
                        TestStep.macClickButton(titled: "OK", instance: instance)
                    } else {
                        TestStep.waitForTmuxDisplayMessage(target: "e2e-metadata", format: "#{@ctrlx-\(field)}", contains: value, timeout: 5)
                        TestStep.macWaitForElement(titled: isEmoji ? "emoji \(glyph)" : value, timeout: 10)
                        TestStep.macWaitForElement(titled: isEmoji ? "emoji \(glyph)" : value, timeout: 10, instance: 1)
                        TestStep.macScreenshot(label: "fresh-\(field)-\(instance)", compare: false, instance: instance)
                    }
                }
            }
        }
    }
}
