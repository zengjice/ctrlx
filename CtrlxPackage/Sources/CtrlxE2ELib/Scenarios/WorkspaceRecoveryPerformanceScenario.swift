import Foundation

/// Measures the actual App's checkpoint loop without global mouse/keyboard input.
public enum WorkspaceRecoveryPerformanceScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Workspace Recovery Performance",
        tags: ["workspace-recovery", "macos-only", "isolated-api", "persistent-e2e-storage"]
    ) {
        TestStep.tmuxCreateSession(name: "recovery-perf-00", width: 160, height: 50)
        TestStep.injectScript(name: "workspace_recovery_performance.py")
        fixture("setup")
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        fixture("enabled")
        TestStep.terminateMacApp()
        fixture("disable")
        TestStep.launchMacApp()
        TestStep.macOpenPanesWindow()
        fixture("disabled")
        TestStep.terminateMacApp()
        fixture("report")
    }

    private static func fixture(_ phase: String) -> TestScenario {
        CtrlxE2ELib.scenario("Recovery performance: \(phase)", tags: ["shortcut"]) {
            TestStep.tmuxCommand(arguments: [
                "run-shell", "-b",
                "python3 \"$TMPDIR/workspace_recovery_performance.py\" '\(phase)' '${ctrlxStateRoot}' '${tmuxSocket}'",
            ])
            TestStep.waitForFileContains(
                path: "${ctrlxStateRoot}/../evidence/performance-\(phase).json",
                substring: "\"passed\": true", storeAs: "performance-\(phase)", timeout: 60
            )
        }
    }
}
