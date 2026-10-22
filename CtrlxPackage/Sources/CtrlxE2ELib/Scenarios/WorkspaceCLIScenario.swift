import Foundation

public enum WorkspaceCLIScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Workspace CLI Continuations", tags: ["recovery", "macos-only", "isolated-api"]
    ) {
        TestStep.tmuxCreateSession(name: "original", width: 120, height: 40)
        TestStep.launchMacApp()
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "original", timeout: 15)
        TestStep.injectScript(name: "workspace_cli_recovery.py")
        TestStep.tmuxCommand(arguments: [
            "run-shell",
            "python3 \"$TMPDIR/workspace_cli_recovery.py\" '${ctrlxStateRoot}' '${tmuxSocket}'",
        ])
        TestStep.waitForFileContains(path: "${ctrlxStateRoot}/../evidence/cli.json", substring: "\"passed\": true", storeAs: "cli-evidence", timeout: 15)
        TestStep.macWaitForElementQuery(.allOf([.labelContains("cli-layout:7 main"), .valueContains("selected")]), timeout: 15)
        TestStep.tmuxStoreDisplayMessage(target: "cli-layout:7.4", format: "#{pane_id}", storeAs: "cliPane")
        TestStep.macWaitForElementQuery(.allOf([.identifier("terminal-${cliPane}"), .valueContains("CLI_LAYOUT_CURRENT")]), timeout: 15)
        TestStep.macScreenshot(label: "cli-layout-current", compare: false)
        TestStep.tmuxCommand(arguments: ["run-shell", "-b", "python3 \"$TMPDIR/workspace_cli_recovery.py\" '${ctrlxStateRoot}' '${tmuxSocket}' stale-editor"])
        TestStep.macWaitForElement(titled: "Edit Prompt", timeout: 10)
        TestStep.macFocusElement(titled: "EDITOR_STALE_ORIGINAL")
        TestStep.macSetFocusedText("EDITOR_UNSENT_RETAINED")
        TestStep.tmuxCommand(arguments: ["set-option", "-p", "-t", "original:0", "@ctrlx-recovery-pane", "A1000000-0000-0000-0000-000000000001"])
        TestStep.macWaitForElementToDisappear(titled: "Edit Prompt", timeout: 10)
        TestStep.waitForFileContains(path: "${ctrlxStateRoot}/../evidence/stale-editor-response.json", substring: "\"done\": true", storeAs: "stale-editor-response", timeout: 10)
        TestStep.macScreenshot(label: "old-editor-retired", compare: false)
        TestStep.tmuxCommand(arguments: ["run-shell", "-b", "python3 \"$TMPDIR/workspace_cli_recovery.py\" '${ctrlxStateRoot}' '${tmuxSocket}' fresh-editor"])
        TestStep.macWaitForElement(titled: "Edit Prompt", timeout: 10)
        TestStep.macFocusElement(titled: "EDITOR_FRESH_ORIGINAL")
        TestStep.macSetFocusedText("EDITOR_FRESH_SUBMITTED")
        TestStep.macClickButton(titled: "Submit")
        TestStep.waitForFileContains(path: "${ctrlxStateRoot}/../evidence/fresh-editor-response.json", substring: "\"done\": true", storeAs: "fresh-editor-response", timeout: 10)
        TestStep.tmuxCommand(arguments: ["run-shell", "python3 \"$TMPDIR/workspace_cli_recovery.py\" '${ctrlxStateRoot}' '${tmuxSocket}' editor-verify"])
        TestStep.waitForFileContains(path: "${ctrlxStateRoot}/../evidence/editor-verify.json", substring: "\"passed\": true", storeAs: "editor-verified", timeout: 15)
    }
}
