import Foundation

/// Terminal cycling skips pane-linked content; child boundaries return to their
/// source even when the child is displayed in the other split column.
public enum TabCycleReorderScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Tab Cycle Reorder",
        tags: ["tabs", "reorder", "macos-only", "isolated-api"]
    ) {
        // ── Setup: one session, two terminal windows ─────────────────
        TestStep.log("Setup: tmux session with winA and winB")
        TestStep.tmuxCreateSession(name: "tabcycle", width: 100, height: 30)
        TestStep.tmuxCommand(arguments: ["rename-window", "-t", "tabcycle:0", "winA"])
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "tabcycle", "-n", "winB"])
        TestStep.writeFile(path: "${ctrlxStateRoot}/pane-files/pane-files-fixture.txt", content: "Pane-linked Files")
        Shortcut.tmuxRunCommand(target: "tabcycle:winA", command: "cd '${ctrlxStateRoot}/pane-files'; clear")
        // `new-window` inherits the tmux server's cwd (the e2e checkout dir),
        // which would leak into winB's prompt and flake the screenshots. Reset
        // to $HOME so the captured prompt is stable regardless of where the
        // suite runs.
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

        TestStep.log("Open a compatibility Files tab bound to winA's pane")
        TestStep.tmuxStoreDisplayMessage(target: "tabcycle:winA", format: "#{pane_id}", storeAs: "sourcePane")
        TestStep.injectScript(name: "tab_cycle_reorder.py")
        TestStep.tmuxCommand(arguments: [
            "run-shell",
            "python3 \"$TMPDIR/tab_cycle_reorder.py\" '${ctrlxStateRoot}' '${sourcePane}'",
        ])
        TestStep.waitForFileContains(path: "${ctrlxStateRoot}/pane-files.json", substring: "\"ok\":", storeAs: "openedPaneFiles", timeout: 10)
        TestStep.assertStoredContains(key: "openedPaneFiles", substring: "\"ok\": true")
        TestStep.macWaitForElementQuery(sourceGroup, timeout: 5)
        TestStep.macScreenshot(label: "mac-tabcycle-default-order", compare: false)

        TestStep.log("A child cannot be interleaved into the terminal strip")
        TestStep.macCGClickElement(query: sourceGroup)
        TestStep.macWaitForElementQuery(filesTab, timeout: 5)
        TestStep.macDragElement(from: filesTab, to: .labelContains("tabcycle:1 winB"), leadingEdge: true)
        TestStep.macPressKey(.escape)
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
        selectFiles
        TestStep.macPressKey(.rightArrow, modifiers: [.command, .option])
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabcycle:0 winA"), .valueContains("selected")]), timeout: 5)
        selectFiles
        TestStep.macPressKey(.leftArrow, modifiers: [.command, .option])
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabcycle:0 winA"), .valueContains("selected")]), timeout: 5)

        // Direct numbered selection still addresses the visible strip.
        TestStep.macPressKey(.character("2"), modifiers: .command)
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabcycle:1 winB"), .valueContains("selected")]), timeout: 5)
        TestStep.macPressKey(.character("1"), modifiers: .command)
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabcycle:0 winA"), .valueContains("selected")]), timeout: 5)

        TestStep.log("A single child on the right returns to winA while left-side cycling would select winC")
        TestStep.tmuxCommand(arguments: ["new-window", "-d", "-t", "tabcycle:", "-n", "winC"])
        TestStep.macWaitForElement(titled: "tabcycle:2 winC", timeout: 10)
        TestStep.macCGClickElement(query: sourceGroup)
        TestStep.macCGClickElement(query: .label("Open file tab in split: Files"))
        TestStep.macClickButton(titled: "tabcycle:1 winB")
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabcycle:1 winB"), .valueContains("selected")]), timeout: 5)
        selectFiles
        TestStep.macPressKey(.rightArrow, modifiers: [.command, .option])
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabcycle:0 winA"), .valueContains("selected")]), timeout: 5)
        TestStep.macScreenshot(label: "mac-tabcycle-group-boundary-source", compare: false)

        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "tabcycle"])
        TestStep.wait(seconds: 2)
    }

    private static let sourceGroup: ElementQuery = .label("winA, 1 tab")
    private static let filesTab: ElementQuery = .label("File tab: Files")
    private static let selectFiles = CtrlxE2ELib.scenario("Select the pane-linked Files tab", tags: ["shortcut"]) {
        TestStep.macCGClickElement(query: sourceGroup)
        TestStep.macCGClickElement(query: filesTab)
        TestStep.macWaitForElement(titled: "pane-files-fixture.txt", timeout: 5)
    }
}
