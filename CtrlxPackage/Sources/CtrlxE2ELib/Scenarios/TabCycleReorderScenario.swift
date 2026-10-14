import Foundation

/// E2E scenario: Cmd-Option-Left / Cmd-Option-Right follow the *reordered* tab strip
/// across tab kinds (issue #566).
///
/// The existing `TabReorderScenario` only cycles between terminal windows,
/// which are all the same kind — so its keyboard phase stayed correct even
/// while #566 was live. The bug only surfaces when a *different* kind of tab
/// (a file tab or a browser tab) is dragged to sit *between* two terminals:
/// the keyboard handler built the strip in a fixed kind-grouped order
/// (windows → file explorer → file tabs → browser tabs) and so cycled in the
/// original layout instead of the one on screen.
///
/// This scenario reproduces that: open a file tab, drag it between two
/// terminals, then press Cmd-Option-Right. Before the fix, the shortcut jumps from
/// `winA` straight to `winB` (skipping the interleaved file tab). After the
/// fix it lands on the file tab, matching the visible order. A file tab is
/// used instead of a browser tab so the proof needs no network / browser —
/// the underlying ordering logic is kind-agnostic and unit-tested for both.
public enum TabCycleReorderScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Tab Cycle Reorder",
        tags: ["tabs", "reorder", "macos-only"]
    ) {
        // ── Setup: one session, two terminal windows ─────────────────
        TestStep.log("Setup: tmux session with winA and winB")
        TestStep.tmuxCreateSession(name: "tabcycle", width: 100, height: 30)
        TestStep.tmuxCommand(arguments: ["rename-window", "-t", "tabcycle:0", "winA"])
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "tabcycle", "-n", "winB"])
        // `new-window` inherits the tmux server's cwd (the e2e checkout dir),
        // which would leak into winB's prompt and flake the screenshots. Reset
        // to $HOME so the captured prompt is stable regardless of where the
        // suite runs. winA was pinned to $HOME by `new-session -c`.
        Shortcut.tmuxRunCommand(target: "tabcycle:winB", command: "cd; clear")
        TestStep.tmuxCommand(arguments: ["select-window", "-t", "tabcycle:0"])
        // Stable session title so the window/sidebar labels don't fall back to
        // the working-directory path (which varies by checkout folder).
        TestStep.tmuxCommand(arguments: ["set-option", "-t", "=tabcycle:", "@ctrlx-description", "Tab Cycle"])

        // ── Launch app and select the session ────────────────────────
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_300, height: 700)
        // Re-pin the sidebar after the resize: `.balanced` NavigationSplitView
        // reflows column widths on resize, so without this the sidebar width
        // is non-deterministic across runs and the screenshots flake.
        TestStep.macSetSidebarWidth(250)

        TestStep.macWaitForElement(titled: "tabcycle", timeout: 10)
        TestStep.macClickButton(titled: "tabcycle")
        TestStep.macWaitForElement(titled: "tabcycle:0 winA", timeout: 10)
        TestStep.macWaitForElement(titled: "tabcycle:1 winB", timeout: 10)

        // ── Open a file tab (a non-window tab kind) ──────────────────
        TestStep.log("Open Files in a new tab so the strip has a non-window kind")
        TestStep.macContextMenuClick(elementTitle: "tabcycle:0", menuItem: "Open Files")
        TestStep.macWaitForElementQuery(.labelContains("File tab:"), timeout: 5)
        // Default layout now reads: winA · winB · Git · Files.
        TestStep.macScreenshot(label: "mac-tabcycle-default-order")

        // ── Drag the file tab to sit between winA and winB ───────────
        TestStep.log("Drag Files onto winB so it lands between winA and winB")
        TestStep.macDragElement(
            from: .labelContains("File tab:"),
            to: .labelContains("tabcycle:1 winB")
        )
        // Settle wait for the reorder + AX tree to catch up after the drag.
        TestStep.wait(seconds: 3)

        // ── Cmd-Option-Right cycles in the *reordered* order ──────────────
        TestStep.log("From winA, Cmd-Option-Right must land on the interleaved file tab — not winB")
        // Anchor on winA (clearing the file-tab selection from the drag). The
        // screenshot captures the reordered strip (winA · Files · winB ·
        // Git) with winA's terminal showing — the starting point for the
        // keyboard step, and visually distinct from the file-tab shot below.
        TestStep.macClickButton(titled: "tabcycle:0 winA")
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabcycle:0 winA"), .valueContains("selected")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-tabcycle-after-drag-winA-selected")

        // The regression assertion: next tab is Files (its new visual
        // slot), proving keyboard cycling follows the drag-reordered strip.
        // Before the #566 fix this selected winB instead, skipping the file
        // tab — so this step would fail and the file content below would
        // instead show winB's terminal.
        TestStep.macPressKey(.rightArrow, modifiers: [.command, .option])
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("File tab:"), .valueContains("selected")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-tabcycle-next-lands-on-file-tab")

        // One more step forward reaches winB (the tab the buggy order would
        // have jumped to first).
        TestStep.macPressKey(.rightArrow, modifiers: [.command, .option])
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabcycle:1 winB"), .valueContains("selected")]),
            timeout: 5
        )

        // ── Cmd-Option-Left walks back through the same order ────────────
        TestStep.log("Cmd-Option-Left steps back winB → Files → winA")
        TestStep.macPressKey(.leftArrow, modifiers: [.command, .option])
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("File tab:"), .valueContains("selected")]),
            timeout: 5
        )
        TestStep.macPressKey(.leftArrow, modifiers: [.command, .option])
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabcycle:0 winA"), .valueContains("selected")]),
            timeout: 5
        )

        // Numbers share the same mixed, reordered strip as the arrow shortcuts.
        TestStep.macPressKey(.character("2"), modifiers: .command)
        TestStep.macWaitForElementQuery(.allOf([.labelContains("File tab:"), .valueContains("selected")]), timeout: 5)
        TestStep.macPressKey(.character("3"), modifiers: .command)
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabcycle:1 winB"), .valueContains("selected")]), timeout: 5)

        // On the right, Files precedes winB in the same persisted order.
        TestStep.macClickButton(titled: "Open terminal in split: winB")
        TestStep.macClickButton(titled: "Move file tab to right: Files")
        TestStep.macCGClickElement(query: .labelContains("File tab:"))
        TestStep.macPressKey(.character("2"), modifiers: .command)
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabcycle:1 winB"), .valueContains("selected")]), timeout: 5)
        TestStep.macPressKey(.leftArrow, modifiers: [.command, .option])
        TestStep.macWaitForElementQuery(.allOf([.labelContains("File tab:"), .valueContains("selected")]), timeout: 5)
        TestStep.macPressKey(.character("1"), modifiers: .command)
        TestStep.macWaitForElementQuery(.allOf([.labelContains("File tab:"), .valueContains("selected")]), timeout: 5)

        // ── Tear down ────────────────────────────────────────────────
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "tabcycle"])
        TestStep.wait(seconds: 2)
    }
}
