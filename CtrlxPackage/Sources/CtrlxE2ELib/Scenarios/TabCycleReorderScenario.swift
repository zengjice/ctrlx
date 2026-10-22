import Foundation

/// Terminal cycling skips pane-linked content; child boundaries return to their
/// source even when the child is displayed in the other split column.
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

        TestStep.log("A child cannot be interleaved into the terminal strip")
        TestStep.macDragElement(from: .labelContains("File tab:"), to: .labelContains("tabcycle:1 winB"))
        TestStep.macClickButton(titled: "tabcycle:0 winA")
        TestStep.macPressKey(.rightArrow, modifiers: [.command, .option])
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabcycle:1 winB"), .valueContains("selected")]), timeout: 5
        )
        TestStep.macPressKey(.leftArrow, modifiers: [.command, .option])
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabcycle:0 winA"), .valueContains("selected")]), timeout: 5
        )

        TestStep.log("Either boundary of a one-child group returns to its exact source")
        TestStep.macContextMenuClick(elementTitle: "tabcycle:0", menuItem: "Open Files")
        TestStep.macWaitForElementQuery(.allOf([.labelContains("File tab:"), .valueContains("selected")]), timeout: 5)
        TestStep.macPressKey(.rightArrow, modifiers: [.command, .option])
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabcycle:0 winA"), .valueContains("selected")]), timeout: 5)
        TestStep.macContextMenuClick(elementTitle: "tabcycle:0", menuItem: "Open Files")
        TestStep.macWaitForElementQuery(.allOf([.labelContains("File tab:"), .valueContains("selected")]), timeout: 5)
        TestStep.macPressKey(.leftArrow, modifiers: [.command, .option])
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabcycle:0 winA"), .valueContains("selected")]), timeout: 5)

        // Direct numbered selection still addresses the visible strip.
        TestStep.macPressKey(.character("2"), modifiers: .command)
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabcycle:1 winB"), .valueContains("selected")]), timeout: 5)
        TestStep.macPressKey(.character("1"), modifiers: .command)
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabcycle:0 winA"), .valueContains("selected")]), timeout: 5)

        TestStep.log("A single child on the right can return to its source on the left")
        TestStep.macClickButton(titled: "Open file tab in split: Files")
        TestStep.macCGClickElement(query: .labelContains("File tab:"))
        TestStep.macPressKey(.rightArrow, modifiers: [.command, .option])
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabcycle:0 winA"), .valueContains("selected")]), timeout: 5)
        TestStep.macScreenshot(label: "mac-tabcycle-group-boundary-source")

        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "tabcycle"])
        TestStep.wait(seconds: 2)
    }
}
