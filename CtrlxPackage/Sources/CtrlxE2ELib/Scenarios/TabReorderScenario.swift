import Foundation

/// E2E scenario: Tab reordering, the "+" menu, and the unified drag model
/// for terminals / Files tabs / browsers (issue #510).
///
/// Covers the tab-bar affordances:
/// - `+` button moved to the leading edge with a popup that creates either
///   a new tmux window ("New Terminal") or a new in-app browser tab
///   ("New Browser", which focuses the address bar).
/// - Drag-to-reorder for terminals — the new order is persisted via
///   `tmux move-window` so it survives an app restart. Also tested via a
///   session switch so the SwiftUI side preserves the new layout.
/// - Cmd-Option-Left / Cmd-Option-Right menu shortcuts that cycle the active tab in
///   the current session.
/// - "Drag past the last tab" via the trailing drop zone.
/// - Cross-divider drags: terminals, Files tabs, and
///   browser tabs can all be flipped between the two split panes via drag.
/// - Auto-collapse of the split when every entry winds up on the right.
/// - The right pane self-heals when the only right-side terminal exits.
///
/// The scenario uses the explicit `macDragElement` step rather than fixed
/// screen coordinates so the source and target stay anchored to the live
/// tab strip even if the window resizes.
public enum TabReorderScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Tab Reorder",
        tags: ["tabs", "reorder", "macos-only"]
    ) {
        // ── Setup: two tmux sessions, three windows in the primary ─────
        TestStep.log("Setup: Create tmux sessions for the reorder test")
        TestStep.tmuxCreateSession(name: "tabreorder", width: 100, height: 30)
        TestStep.tmuxCommand(arguments: ["rename-window", "-t", "tabreorder:0", "winA"])
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "tabreorder", "-n", "winB"])
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "tabreorder", "-n", "winC"])
        // `new-session` pins winA to $HOME (`-c`), but `new-window` inherits the
        // tmux *server's* working directory — the e2e binary's checkout/worktree
        // dir on CI, the repo root locally. That folder name would otherwise leak
        // into winB/winC's terminal prompt, the file-browser breadcrumb (Phase 8),
        // and the sidebar current-path line, making the screenshots differ between
        // checkout locations. Reset both to $HOME so every cwd the app surfaces is
        // stable regardless of where the suite runs. (The app-created "terminal 1"
        // already inherits winA's $HOME, so it needs no reset.)
        Shortcut.tmuxRunCommand(target: "tabreorder:winB", command: "cd; clear")
        Shortcut.tmuxRunCommand(target: "tabreorder:winC", command: "cd; clear")
        // Re-select winA so the sidebar click lands on a known tab.
        TestStep.tmuxCommand(arguments: ["select-window", "-t", "tabreorder:0"])
        TestStep.wait(seconds: 1)

        // Secondary session used by Phase 4 to round-trip away and back so
        // we can prove the reordered layout survives a session switch.
        TestStep.tmuxCreateSession(name: "tabreorder-other", width: 100, height: 30)
        TestStep.wait(seconds: 1)

        // Give both sessions a stable custom title — same mechanism the CLI uses
        // (`ctrlx set-title` / `new-session --title`), persisted as the
        // `@ctrlx-description` tmux user option. This drives the window title
        // bar and the sidebar primary label, so neither falls back to the
        // working-directory path (which varies by checkout folder). Set before
        // the app launches so the first session read already sees the titles.
        TestStep.tmuxCommand(arguments: ["set-option", "-t", "=tabreorder:", "@ctrlx-description", "Tab Reorder"])
        TestStep.tmuxCommand(arguments: ["set-option", "-t", "=tabreorder-other:", "@ctrlx-description", "Tab Reorder Other"])

        // ── Launch app ────────────────────────────────────────────────
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_300, height: 700)
        // Re-pin the sidebar after this second resize: `.balanced` NavigationSplitView
        // reflows column widths on resize, so without this the sidebar width is
        // non-deterministic across runs and the screenshots flake.
        TestStep.macSetSidebarWidth(250)

        TestStep.macWaitForElement(titled: "tabreorder", timeout: 10)
        TestStep.macClickButton(titled: "tabreorder")

        TestStep.macWaitForElement(titled: "winA", timeout: 10)
        TestStep.macWaitForElement(titled: "winB", timeout: 10)
        TestStep.macWaitForElement(titled: "winC", timeout: 10)
        TestStep.macScreenshot(label: "mac-tabreorder-initial")

        // ── Phase 1: Pure-terminal drag persists to tmux ──────────
        // This must run before opening a Browser/File tab: those features
        // materialise SessionFileTabsState and previously masked the bug.
        TestStep.log("Phase 1: Drag winC to the leading edge of winA")
        TestStep.macDragElement(
            from: .labelContains("tabreorder:2 winC"),
            to: .labelContains("tabreorder:0 winA"),
            leadingEdge: true
        )
        TestStep.wait(seconds: 3)

        // Assert through tmux, not just the SwiftUI tab strip, so an optimistic
        // visual move without a backend reorder still fails the scenario.
        TestStep.tmuxStoreDisplayMessage(
            target: "tabreorder",
            format: "#{W:#{window_name}#,}",
            storeAs: "tmuxOrderAfterDrag"
        )
        TestStep.assertStoredContains(
            key: "tmuxOrderAfterDrag",
            substring: "winC,winA,winB,"
        )
        TestStep.macWaitForElement(titled: "tabreorder:0 winC", timeout: 5)
        TestStep.macWaitForElement(titled: "tabreorder:1 winA", timeout: 5)
        TestStep.macWaitForElement(titled: "tabreorder:2 winB", timeout: 5)

        // The center of a tab combines the two tabs. These two windows
        // are already adjacent in the requested order.
        TestStep.macDragElement(
            from: .labelContains("tabreorder:2 winB"),
            to: .labelContains("tabreorder:1 winA")
        )
        TestStep.macWaitForElementQuery(.label("winA, 2 tabs"), timeout: 5)
        TestStep.macCGClickElement(query: .label("winA, 2 tabs"))
        TestStep.macWaitForElementQuery(.labelContains("tabreorder:2 winB"), timeout: 5)
        TestStep.macPressKey(.escape)
        TestStep.macContextMenuClick(elementTitle: "winA, 2 tabs", menuItem: "Ungroup Tabs")
        TestStep.macWaitForElementQueryToDisappear(.label("winA, 2 tabs"), timeout: 5)

        // ── Phase 2: "+" menu offers New Terminal and New Browser ─────
        //
        // The "+" button is a SwiftUI Menu; AXPress on it doesn't reliably
        // open the popup on every macOS build (the menu briefly shows then
        // auto-dismisses), so we open it via a CGEvent click and then click
        // the inner menu item once it's accessible.
        TestStep.log("Phase 2: + button opens a menu with New Terminal and New Browser")
        TestStep.macCGClickElement(query: .label("New Tab"))
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "New Terminal")

        // The new terminal is created after the existing windows, named
        // "terminal 1" because the existing windows used non-numbered names.
        TestStep.macWaitForElement(titled: "terminal 1", timeout: 10)
        TestStep.macScreenshot(label: "mac-tabreorder-after-new-terminal")

        // ── Phase 3: "New Browser" creates a browser tab, focuses URL ─
        TestStep.log("Phase 3: New Browser menu item creates a browser tab with focused URL field")
        TestStep.macCGClickElement(query: .label("New Tab"))
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "New Browser")

        // The new browser tab labels with "about:blank" until the user types
        // a real URL. The address bar should have focus — typing here goes
        // straight into the URL field rather than dropping characters.
        TestStep.macWaitForElement(titled: "URL", timeout: 5)
        TestStep.macType(text: "example.com", pressReturn: false)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-tabreorder-new-browser-typed-into-url")
        // The visible tab label changes based on the loaded page, but the
        // closeable browser tab is enough proof — clean up immediately so
        // later phases work against the same tab set.
        TestStep.macCGClickElement(query: .labelContains("Close browser tab:"))
        TestStep.macWaitForElementQueryToDisappear(.labelContains("Close browser tab:"), timeout: 5)
        // Preserve the existing screenshot sequence and baseline name. The
        // reorder itself was already asserted against tmux in Phase 1.
        TestStep.macScreenshot(label: "mac-tabreorder-after-drag")

        // ── Phase 4: Session round-trip preserves the new order ───────
        TestStep.log("Phase 4: Switch to the other session and back — order survives")
        TestStep.macClickButton(titled: "tabreorder-other")
        TestStep.macWaitForElementToDisappear(titled: "tabreorder:0 winC", timeout: 5)

        TestStep.macClickButton(titled: "tabreorder")
        TestStep.macWaitForElement(titled: "tabreorder:0 winC", timeout: 5)
        TestStep.macWaitForElement(titled: "tabreorder:1 winA", timeout: 5)
        TestStep.macWaitForElement(titled: "tabreorder:2 winB", timeout: 5)
        TestStep.macScreenshot(label: "mac-tabreorder-after-session-roundtrip")

        // ── Phase 5: Cmd-Option-Right / Cmd-Option-Left keyboard navigation ────
        TestStep.log("Phase 5: Cmd-Option-Right cycles to the next tab; Cmd-Option-Left cycles back")
        // Start on winC (the leftmost tab after the reorder).
        TestStep.macClickButton(titled: "tabreorder:0 winC")
        TestStep.waitForTmuxDisplayMessage(
            target: "tabreorder",
            format: "#{window_name}",
            contains: "winC",
            timeout: 5
        )
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabreorder:0 winC"), .valueContains("selected")]),
            timeout: 5
        )

        // Cmd-Option-Right → next visible tab (winA).
        TestStep.macPressKey(.rightArrow, modifiers: [.command, .option])
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabreorder:1 winA"), .valueContains("selected")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-tabreorder-after-next-shortcut")

        // Cmd-Option-Left → previous visible tab (winC again).
        TestStep.macPressKey(.leftArrow, modifiers: [.command, .option])
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabreorder:0 winC"), .valueContains("selected")]),
            timeout: 5
        )

        // ── Phase 6: Close a window — neighbours collapse left ────────
        TestStep.log("Phase 6: Close winA via tmux — winB shifts left and indices follow")
        // The tab's context menu only carries Rename; the close affordance is
        // the dedicated X button (shown on hover/selection). Drive the close
        // from tmux directly to avoid coordinating with the X-visibility
        // gating and the close-confirmation alert — this is a reconcile
        // smoke test, not a UI-flow test.
        TestStep.tmuxCommand(arguments: ["kill-window", "-t", "tabreorder:winA"])
        TestStep.macWaitForElementToDisappear(titled: "tabreorder:1 winA", timeout: 5)

        // After the close, the remaining windows shift down: winB takes the
        // index winA vacated, terminal 1 follows. We re-check the tmux side
        // to make sure we didn't accidentally re-sort on close.
        TestStep.tmuxStoreDisplayMessage(
            target: "tabreorder",
            // `#,` escapes the comma so tmux emits it literally — otherwise
            // the bare `,` inside `#{W:...}` is parsed as the active/inactive
            // format separator and no commas appear in the output.
            format: "#{W:#{window_name}#,}",
            storeAs: "tmuxOrderAfterClose"
        )
        TestStep.assertStoredContains(
            key: "tmuxOrderAfterClose",
            substring: "winC,winB,terminal 1,"
        )
        TestStep.macScreenshot(label: "mac-tabreorder-after-close-winA")

        // ── Phase 7: Trailing drop zone — drag past the last tab ─────
        //
        // The new trailing drop zone fills the rest of the bar to the right
        // of the last visible tab so users can drop "past the end". It's a
        // `Color.clear` view in production; we add an AX identifier on it
        // (`tab-trailing-drop-single`) so the test can drag onto it through
        // the same AX path as every other tab. The post-drag tmux order is
        // checked via `display-message` to confirm `syncSubsequences` ran.
        TestStep.log("Phase 7: Drag winC to the trailing drop zone — moves to end")
        TestStep.macDragElement(
            from: .labelContains("tabreorder:0 winC"),
            to: .identifier("tab-trailing-drop-single")
        )
        TestStep.wait(seconds: 3)
        TestStep.tmuxStoreDisplayMessage(
            target: "tabreorder",
            // `#,` escapes the comma so tmux emits it literally — otherwise
            // the bare `,` inside `#{W:...}` is parsed as the active/inactive
            // format separator and no commas appear in the output.
            format: "#{W:#{window_name}#,}",
            storeAs: "tmuxOrderAfterEndDrop"
        )
        TestStep.assertStoredContains(
            key: "tmuxOrderAfterEndDrop",
            substring: "winB,terminal 1,winC,"
        )
        TestStep.macWaitForElement(titled: "tabreorder:0 winB", timeout: 5)
        TestStep.macWaitForElement(titled: "tabreorder:1 terminal 1", timeout: 5)
        TestStep.macWaitForElement(titled: "tabreorder:2 winC", timeout: 5)
        TestStep.macScreenshot(label: "mac-tabreorder-after-trailing-drop")

        // ── Phase 8: Move a terminal across the split ────────────────
        TestStep.log("Phase 8: Open a Files tab, split it, then drag a terminal to the right")
        TestStep.macCGClickElement(query: .label("New Tab"))
        TestStep.macClickButton(titled: "New Files")
        TestStep.macWaitForElementQuery(.labelContains("Open file tab in split:"), timeout: 10)
        TestStep.macCGClickElement(query: .labelContains("Open file tab in split:"))
        TestStep.macWaitForElementQuery(.labelContains("Move file tab to left:"), timeout: 5)
        TestStep.macWaitForElementQuery(.labelContains("Move terminal to right:"), timeout: 5)
        TestStep.macScreenshot(label: "mac-tabreorder-split-opened-with-file")

        TestStep.macDragElement(
            from: .labelContains("tabreorder:0 winB"),
            to: .identifier("tab-trailing-drop-right")
        )
        TestStep.macWaitForElementQuery(.label("Move terminal to left: winB"), timeout: 5)
        TestStep.macScreenshot(label: "mac-tabreorder-terminal-on-right")

        // ── Phase 9: Move a Files tab across the split ────────────────
        TestStep.log("Phase 9: Open a second Files tab and drag it to the right")
        TestStep.macCGClickElement(query: .label("New Tab"))
        TestStep.macClickButton(titled: "New Files")
        TestStep.macWaitForElementQuery(.labelContains("Move file tab to right:"), timeout: 5)
        TestStep.macDragElement(
            from: .allOf([.labelContains("File tab:"), .valueContains("selected")]),
            to: .identifier("tab-trailing-drop-right")
        )
        TestStep.macWaitForElementQueryToDisappear(.labelContains("Move file tab to right:"), timeout: 5)
        TestStep.macWaitForElementQuery(.labelContains("Move file tab to left:"), timeout: 5)
        TestStep.macScreenshot(label: "mac-tabreorder-explorer-on-right")

        // ── Phase 10: Auto-collapse when the left section is empty ─────
        //
        // Move every remaining left-side terminal to the right via its
        // split arrow. Once nothing is left of the divider, the split
        // collapses automatically and the strip flips back to single-pane
        // icons. Verifies the `leftEmpty` branch in
        // `reconcileRightPaneSelection`.
        TestStep.log("Phase 10: Move remaining left terminals to right → split collapses")
        // Click each remaining "Move terminal to right:" arrow on the left
        // pane until none remain. We don't know the specific window names
        // because the ID-stability caveat shuffled them — but tapping the
        // arrow on whichever terminal is currently leftmost works the same
        // way regardless of name.
        TestStep.macCGClickElement(query: .labelContains("Move terminal to right:"))
        TestStep.wait(seconds: 1)
        TestStep.macCGClickElement(query: .labelContains("Move terminal to right:"))
        // Settle wait for the split-collapse layout transition — the AX
        // tree can lag the reconcile briefly after the last terminal
        // moves right, so give the collapse animation room before polling.
        TestStep.wait(seconds: 2)
        // Every "Move *" arrow should be gone; "Open … in split" icons return.
        TestStep.macWaitForElementQueryToDisappear(
            .labelContains("Move terminal to left:"),
            timeout: 10
        )
        TestStep.macWaitForElementQueryToDisappear(
            .labelContains("Move file tab to left:"),
            timeout: 5
        )
        TestStep.macWaitForElementQuery(.labelContains("Open file tab in split:"), timeout: 5)
        TestStep.macScreenshot(label: "mac-tabreorder-collapsed-from-left-empty")

        // ── Phase 11: Right-side terminal exits → split collapses ─────
        //
        // Open a split with a terminal on the right via its single-mode
        // split toggle, then kill that window from tmux. The pane-state
        // observer prunes the dangling right-side payload and the split
        // collapses without leaving the "No Tab Selected" placeholder
        // visible — covers the regression where an exited right-side
        // terminal kept the empty split alive.
        TestStep.log("Phase 11: Kill the right-side terminal via tmux → split collapses")
        TestStep.macCGClickElement(query: .label("Open terminal in split: winC"))
        TestStep.macWaitForElementQuery(.label("Move terminal to left: winC"), timeout: 5)
        TestStep.macScreenshot(label: "mac-tabreorder-split-only-terminal-right")

        // tmux kill-window with a window-name target works regardless of
        // its current index after the prior reorders.
        TestStep.tmuxCommand(arguments: ["kill-window", "-t", "tabreorder:winC"])
        TestStep.macWaitForElementQueryToDisappear(
            .labelContains("Move terminal to left:"),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-tabreorder-after-right-terminal-killed")

        // ── Tear down ────────────────────────────────────────────────
        // Use kill-session so every window in both sessions is cleaned up
        // unconditionally. `exit`-on-pane only closes its own window and
        // would leave the other windows (winB, terminal 1) and the second
        // session running if the scenario aborted mid-flight.
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "tabreorder"])
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "tabreorder-other"])
        TestStep.wait(seconds: 2)
    }
}
