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
    @Test("Native completion bypasses only stale Working, never other input checks", arguments: ["complete", "active", "busy-footer", "draft", "question", "copy"])
    func staleWorking(_ scenario: String) throws {
        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            let coordinator = AppCoordinator()
            let state: AgentState = scenario == "question" ? .awaitingReplies(.init(questions: []), requestID: "fixture") : .working
            coordinator.windowManager.setPaneStatesForPreview([.init(paneId: "%1", agentSession: .init(paneId: "%1", pluginID: "codex", state: state))])
            let metadata = ["80", "5", "2", "1", "1", "1", scenario == "copy" ? "1" : "0", "codex"].joined(separator: "\u{1f}")
            let body = scenario == "draft" ? "unsent draft" : "\u{1b}[2mAsk Codex to do anything\u{1b}[0m"
            let footer = scenario == "busy-footer" ? "esc to interrupt" : ""
            let screen = try AgentWorkflowTerminalCapture.parse(metadata + "\n\n› \(body)\n\(footer)\n\n\n")
            let issue = coordinator.hookTrustInputIssue(paneID: "%1", screen: screen, composer: CodexPluginCore().hookTrustComposer, nativeTurnCompleted: scenario != "active")
            #expect((issue == nil) == (scenario == "complete"))
            #expect(coordinator.windowManager.paneStates["%1"]?.agentSession?.state == state)
        }
    }

    @Test("Legacy paste metadata does not bypass composer or Agent state checks", arguments: ["", "0", "1"], ["empty", "draft", "working", "copy", "question", "busy-footer", "unknown-screen"])
    func inputChecks(paste: String, scenario: String) async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            let coordinator = AppCoordinator()
            var session = AgentSession(paneId: "%1", pluginID: "codex")
            if scenario == "working" {
                session.state = .working
            } else if scenario == "question" {
                session.state = .awaitingReplies(.init(questions: []), requestID: "fixture")
            }
            coordinator.windowManager.setPaneStatesForPreview([PaneState(paneId: "%1", agentSession: session)])
            let metadata = ["80", "5", "2", "1", "1", paste, scenario == "copy" ? "1" : "0", "codex"].joined(separator: "\u{1f}")
            let body = scenario == "draft" ? "my draft" : "\u{1b}[2mAsk Codex to do anything\u{1b}[0m"
            let prompt = scenario == "unknown-screen" ? "$ " : "› "
            let footer = scenario == "busy-footer" ? "esc to interrupt" : ""
            let screen = try AgentWorkflowTerminalCapture.parse(metadata + "\n\n\(prompt)\(body)\n\(footer)\n\n\n")
            let issue = coordinator.hookTrustInputIssue(paneID: "%1", screen: screen, composer: CodexPluginCore().hookTrustComposer)
            #expect((issue == nil) == (scenario == "empty" && paste != "0"))
        }
    }
}
