import Foundation

/// Exercises session switching through Command-P and terminal font shortcuts.
/// Font changes remain presentation-only until the explicit fit action.
public enum SessionAndFontHotkeysScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Session And Font Hotkeys",
        tags: ["hotkeys", "session", "font", "macos-only"]
    ) {
        // ── Setup: two single-window local sessions ──────────────────
        // Stable `@ctrlx-description`s keep the sidebar labels (and thus the
        // screenshots) from falling back to the working-directory path, which
        // varies by checkout folder. A fixed prompt + a distinct marker per
        // session makes the two terminals visually different in the shots.
        TestStep.log("Setup: two tmux sessions hkalpha and hkbeta")
        TestStep.tmuxCreateSession(name: "hkalpha", width: 100, height: 30)
        TestStep.tmuxCommand(arguments: ["set-option", "-t", "=hkalpha:", "@ctrlx-description", "Alpha"])
        Shortcut.tmuxClearAndSetPrompt(target: "hkalpha:0")
        // Fill hkalpha (the font-demo session) with many deterministic lines so a
        // font-size change repaints a large fraction of the pane — see the type
        // doc. Fixed line count + fixed text keeps the output stable across runs.
        Shortcut.tmuxRunCommand(
            target: "hkalpha:0",
            command: #"for i in $(seq 1 15); do echo "SESSION-ALPHA line $i: the quick brown fox jumps over"; done"#
        )

        TestStep.tmuxCreateSession(name: "hkbeta", width: 100, height: 30)
        TestStep.tmuxCommand(arguments: ["set-option", "-t", "=hkbeta:", "@ctrlx-description", "Beta"])
        Shortcut.tmuxClearAndSetPrompt(target: "hkbeta:0")
        Shortcut.tmuxRunCommand(target: "hkbeta:0", command: "echo SESSION-BETA")

        // ── Launch app ───────────────────────────────────────────────
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_300, height: 700)
        // Re-pin the sidebar after the resize so its width is deterministic
        // across runs (matches the tab-cycle scenarios).
        TestStep.macSetSidebarWidth(250)

        TestStep.macWaitForElement(titled: "hkalpha", timeout: 10)
        TestStep.macWaitForElement(titled: "hkbeta", timeout: 10)

        // ── Select hkalpha; its window tab is the selected one ────────
        TestStep.macClickButton(titled: "hkalpha")
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("hkalpha:0"), .valueContains("selected")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "mac-hotkeys-alpha-selected")

        for target in ["hkbeta", "hkalpha", "hkbeta", "hkalpha"] {
            TestStep.macPressKey(.character("p"), modifiers: .command)
            TestStep.macWaitForElementQuery(.identifier("session-switcher-search"), timeout: 5)
            TestStep.macPressKey(.downArrow)
            TestStep.macPressKey(.return)
            TestStep.macWaitForElementQuery(
                .allOf([.labelContains("\(target):0"), .valueContains("selected")]), timeout: 10
            )
        }
        // With one workbench, the system's window shortcut must not cycle sessions.
        TestStep.macPressKey(.character("`"), modifiers: .command)
        TestStep.macWaitForElementQuery(.allOf([.labelContains("hkalpha:0"), .valueContains("selected")]), timeout: 5)

        // ── ⌘+ / ⌘- change the terminal font size ────────────────────
        // Font changes are presentation-only until the explicit fit button is
        // clicked. This pins the same manual-only contract as window geometry.
        TestStep.log("Fit hkalpha at the default font")
        TestStep.macClickButton(titled: "Resize visible terminals to fit this Mac")
        TestStep.wait(seconds: 1)
        TestStep.tmuxStorePaneDimensions(
            target: "hkalpha:0",
            widthKey: "fontDefaultWidth",
            heightKey: "fontDefaultHeight"
        )
        TestStep.log("Dimensions at default font: ${fontDefaultWidth}x${fontDefaultHeight}")
        // Status bar shows "WxH" — confirms the UI caught up with the resize.
        TestStep.macWaitForElement(titled: "${fontDefaultWidth}x${fontDefaultHeight}", timeout: 5)
        TestStep.macScreenshot(label: "mac-hotkeys-font-default")

        TestStep.log("Cmd-+ enlarges the terminal font (physically Cmd-Shift-=)")
        for _ in 0..<6 {
            TestStep.macPressKey(.character("="), modifiers: [.command, .shift])
        }
        TestStep.wait(seconds: 1)
        TestStep.tmuxStorePaneDimensions(
            target: "hkalpha:0",
            widthKey: "beforeIncreasedFontFitWidth",
            heightKey: "beforeIncreasedFontFitHeight"
        )
        TestStep.assertStoredEqual(key: "beforeIncreasedFontFitWidth", otherKey: "fontDefaultWidth")
        TestStep.assertStoredEqual(key: "beforeIncreasedFontFitHeight", otherKey: "fontDefaultHeight")

        TestStep.macClickButton(titled: "Resize visible terminals to fit this Mac")
        TestStep.waitForTmuxDisplayMessageNotEqual(
            target: "hkalpha:0",
            format: "#{pane_width}",
            notEqualTo: "${fontDefaultWidth}",
            timeout: 10
        )
        TestStep.tmuxStorePaneDimensions(
            target: "hkalpha:0",
            widthKey: "fontIncreasedWidth",
            heightKey: "fontIncreasedHeight"
        )
        TestStep.log("Dimensions at increased font: ${fontIncreasedWidth}x${fontIncreasedHeight}")
        TestStep.assertStoredNotEqual(key: "fontIncreasedWidth", otherKey: "fontDefaultWidth")
        TestStep.assertStoredNotEqual(key: "fontIncreasedHeight", otherKey: "fontDefaultHeight")
        TestStep.macWaitForElement(titled: "${fontIncreasedWidth}x${fontIncreasedHeight}", timeout: 5)
        TestStep.macScreenshot(label: "mac-hotkeys-font-increased")

        TestStep.log("Cmd-- shrinks the terminal font; Cmd-0 restores its default")
        for _ in 0..<6 {
            TestStep.macPressKey(.character("-"), modifiers: .command)
        }
        TestStep.macPressKey(.character("="), modifiers: [.command, .shift])
        TestStep.macPressKey(.character("0"), modifiers: .command)
        TestStep.wait(seconds: 1)
        TestStep.tmuxStorePaneDimensions(
            target: "hkalpha:0",
            widthKey: "beforeRestoredFontFitWidth",
            heightKey: "beforeRestoredFontFitHeight"
        )
        TestStep.assertStoredEqual(key: "beforeRestoredFontFitWidth", otherKey: "fontIncreasedWidth")
        TestStep.assertStoredEqual(key: "beforeRestoredFontFitHeight", otherKey: "fontIncreasedHeight")

        TestStep.macClickButton(titled: "Resize visible terminals to fit this Mac")
        TestStep.waitForTmuxDisplayMessageNotEqual(
            target: "hkalpha:0",
            format: "#{pane_width}",
            notEqualTo: "${fontIncreasedWidth}",
            timeout: 10
        )
        TestStep.tmuxStorePaneDimensions(
            target: "hkalpha:0",
            widthKey: "fontRestoredWidth",
            heightKey: "fontRestoredHeight"
        )
        TestStep.log("Dimensions after restore: ${fontRestoredWidth}x${fontRestoredHeight}")
        TestStep.assertStoredEqual(key: "fontRestoredWidth", otherKey: "fontDefaultWidth")
        TestStep.assertStoredEqual(key: "fontRestoredHeight", otherKey: "fontDefaultHeight")
        TestStep.macScreenshot(label: "mac-hotkeys-font-restored")

        // ── Tear down ────────────────────────────────────────────────
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "hkalpha"])
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "hkbeta"])
        TestStep.wait(seconds: 2)
    }
}
