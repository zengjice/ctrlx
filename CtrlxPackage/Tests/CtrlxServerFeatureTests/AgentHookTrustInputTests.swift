import CodexPluginCore
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentHookTrustInputTests {
    @Test("Only an idle empty composer with verified paste mode is allowed", arguments: ["", "0", "1", "draft", "working", "copy"])
    func inputChecks(_ scenario: String) async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            let coordinator = AppCoordinator()
            var session = AgentSession(paneId: "%1", pluginID: "codex")
            if scenario == "working" {
                session.state = .working
            }
            coordinator.windowManager.setPaneStatesForPreview([PaneState(paneId: "%1", agentSession: session)])
            let paste = ["", "0", "1"].contains(scenario) ? scenario : "1"
            let metadata = ["80", "5", "2", "1", "1", paste, scenario == "copy" ? "1" : "0", "codex"].joined(separator: "\u{1f}")
            let body = scenario == "draft" ? "my draft" : "\u{1b}[2mAsk Codex to do anything\u{1b}[0m"
            let screen = try AgentWorkflowTerminalCapture.parse(metadata + "\n\n› \(body)\n\n\n\n")
            let issue = coordinator.hookTrustInputIssue(paneID: "%1", screen: screen, composer: CodexPluginCore().hookTrustComposer)
            #expect((issue == nil) == (scenario == "1"))
        }
    }
}
