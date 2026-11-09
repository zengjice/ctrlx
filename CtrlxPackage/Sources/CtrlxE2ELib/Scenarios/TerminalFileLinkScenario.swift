import Foundation

/// E2E scenario: Verify that clicking a `file://` link in the terminal opens
/// the file in a new tab next to the file browser, instead of forwarding the
/// URL to the system default browser.
///
/// **Issue:** #402 — Intercept file open clicks and open in new tab.
/// **Issue:** #433 — Closing the tab returns to the originating terminal
/// instead of leaving the user on the file browser tree.
///
/// Flow:
/// 1. Print an OSC 8 hyperlink whose URL is `file:///tmp/hello.txt` (the
///    in-memory fake file system resolves any path ending in `/hello.txt`).
/// 2. Drag-select, double-click and triple-click the hyperlink text; verify
///    each selection auto-copies without opening the link.
/// 3. Single-click the visible hyperlink text — a real CGEvent click, not a
///    tmux-simulated event — and verify a new file tab appears.
/// 4. Close the tab and verify the originating terminal is reselected (issue
///    #433): the link text must be visible again and the file browser tree
///    must NOT be the active view.
/// 5. Toggle the "Open clicked file links in a new tab" setting off.
/// 6. Click again and verify no new tab is created (the previous tab was
///    closed before this phase, so the absence proves the setting works).
///
/// The OSC 8 hyperlink text is wide and right-padded so we have enough
/// horizontal slack to land the click in the link span even with sub-pixel
/// font drift.
public enum TerminalFileLinkScenario {
    /// Screen coordinates of the visible hyperlink text. Computed for window
    /// position (10, 10), size 1_200×700, sidebar width 250.
    ///
    /// The OSC 8 hyperlink occupies an entire row (no prefix) starting at the
    /// terminal's first column on viewport row 1. Title bar + tab bar consume
    /// the first 100 px of the window vertically, and SF Mono 12 cells are
    /// ~14 pt tall. The terminal content area starts ~270 pt from the screen
    /// origin (window left + sidebar width + small inset).
    private static let linkClickX: Double = 400
    private static let linkClickY: Double = 130

    public static let scenario = CtrlxE2ELib.scenario(
        "Terminal File Link Opens In New Tab",
        tags: ["file-browser", "terminal", "links", "macos-only"]
    ) {
        // ── Setup ────────────────────────────────────────────────
        TestStep.log("Setup: Create tmux session and print OSC 8 file link")
        TestStep.tmuxCreateSession(name: "termlink", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "termlink:0")

        // OSC 8 hyperlink format: \e]8;;<URL>\a<text>\e]8;;\a
        // The URL points at /tmp/hello.txt — the in-memory FS resolves any
        // path ending in /hello.txt to the fake hello.txt file. The visible
        // text fills most of the row (no prefix) so the click target is wide.
        Shortcut.tmuxRunCommand(
            target: "termlink:0",
            command: #"printf '\e]8;;file:///tmp/hello.txt\aclick-here-to-open-hello-txt-file\e]8;;\a\n'"#
        )
        TestStep.wait(seconds: 1)

        // ── Launch app ───────────────────────────────────────────
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)

        TestStep.macWaitForElement(titled: "termlink", timeout: 5)
        TestStep.macClickButton(titled: "termlink")

        // Wait for the link text to appear in the terminal's accessibility value
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("click-here-to-open-hello-txt-file")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "mac-terminal-with-file-link")

        // ── Phase 0: Selection gestures copy but never open ──────
        TestStep.log("Phase 0: Drag-select the link without activating it")
        TestStep.macClearClipboard()
        TestStep.macDrag(fromX: 330, fromY: linkClickY, toX: 520, toY: linkClickY)
        TestStep.wait(seconds: 1)
        TestStep.macReadClipboard(storeAs: "dragSelectedLinkText")
        TestStep.assertStoredContains(key: "dragSelectedLinkText", substring: "here-to-open")
        TestStep.macWaitForElementToDisappear(titled: "File tab: hello.txt", timeout: 1)

        TestStep.log("Phase 0.1: Double-click selects a word without activating the first click")
        TestStep.macClearClipboard()
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY, clickCount: 2)
        TestStep.wait(seconds: 1)
        TestStep.macReadClipboard(storeAs: "doubleClickedLinkText")
        TestStep.assertStoredContains(key: "doubleClickedLinkText", substring: "click")
        TestStep.macWaitForElementToDisappear(titled: "File tab: hello.txt", timeout: 1)

        TestStep.log("Phase 0.2: Triple-click selects the row without activating the first click")
        TestStep.macClearClipboard()
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY, clickCount: 3)
        TestStep.wait(seconds: 1)
        TestStep.macReadClipboard(storeAs: "tripleClickedLinkText")
        TestStep.assertStoredContains(
            key: "tripleClickedLinkText",
            substring: "click-here-to-open-hello-txt-file"
        )
        TestStep.macWaitForElementToDisappear(titled: "File tab: hello.txt", timeout: 1)

        // ── Phase 1: Click the link → file tab opens ─────────────
        TestStep.log("Phase 1: Click the file link in the terminal")
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY)

        // The new tab carries the file name in its accessibility label.
        TestStep.macWaitForElement(titled: "File tab: hello.txt", timeout: 5)
        // The file's content (from the in-memory fake) should be visible.
        TestStep.macWaitForElementQuery(
            .anyTextMatches("Hello, world!"),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-file-tab-opened-from-terminal-click")

        // ── Phase 1.5: Close the tab → return to originating terminal ─
        // Regression guard for issue #433: closing a file tab opened via a
        // terminal click must return the user to the originating terminal,
        // not the file browser tree.
        TestStep.log("Phase 1.5: Close the file tab and verify the originating terminal is reselected")
        TestStep.macClickButton(titled: "Close file tab: hello.txt")
        TestStep.macWaitForElementToDisappear(titled: "File tab: hello.txt", timeout: 5)

        // The terminal must be the active view again. The terminal-%0 element
        // is only mounted when the terminal pane is visible (FileBrowserView
        // and the pane layout are mutually exclusive in MainView), so finding
        // the link text under that identifier proves we landed on the
        // terminal rather than on the file browser tree.
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("click-here-to-open-hello-txt-file")]),
            timeout: 5
        )
        // Negative assertion: the file browser tree's search field is gone.
        // Only the tree renders this label, so its absence rules out the
        // pre-#433 fallback that left the tree visible after closing the tab.
        TestStep.macWaitForElementToDisappear(titled: "Search files", timeout: 5)
        TestStep.macScreenshot(label: "mac-terminal-after-file-tab-closed")

        // ── Phase 2: Disable setting → click does NOT open a tab ─
        TestStep.log("Phase 2: Disable setting and verify clicks no longer open tabs")
        TestStep.macOpenSettings()
        TestStep.macSelectSettingsTab("Files & Editors")
        TestStep.macWaitForWindow(titled: "Files & Editors", timeout: 5)
        TestStep.macCGClickElement(query: .identifier("settings-open-clicked-file-in-new-tab"))
        TestStep.wait(seconds: 1)
        TestStep.macCloseWindow(titled: "Files & Editors")
        TestStep.wait(seconds: 1)

        // Re-select the pane after Settings closes so the terminal regains focus.
        TestStep.macClickButton(titled: "termlink:0")
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("click-here-to-open-hello-txt-file")]),
            timeout: 10
        )

        // Click the link again. With the setting off, `onOpenURL` returns false
        // and `NSWorkspace.shared.open` is invoked on a non-existent path,
        // which silently no-ops — no new tab should appear.
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY)
        TestStep.macWaitForElementToDisappear(titled: "File tab: hello.txt", timeout: 3)
        TestStep.macScreenshot(label: "mac-file-link-click-with-setting-off")

        // Tear down so we don't carry state into the next scenario.
        Shortcut.tmuxRunCommand(target: "termlink:0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
