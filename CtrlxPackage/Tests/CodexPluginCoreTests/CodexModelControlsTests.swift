import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CodexPluginCore

struct CodexModelControlsTests {
    @Test
    func modelInputRejectsControlCharactersAndOtherCommands() throws {
        #expect(throws: AgentModelError.self) { try AgentModelTerminal.commandBytes("/model a\nrm -rf") }
        #expect(throws: AgentModelError.self) { try AgentModelTerminal.commandBytes("/models") }
        #expect(throws: AgentModelError.self) { try AgentModelTerminal.commandBytes("/model a\u{1b}[201~") }
        #expect(try AgentModelTerminal.commandBytes("/model a --reasoning=high") == Data("\u{1b}[200~/model a --reasoning=high\u{1b}[201~\r".utf8))
    }

    private let models = [AgentModelOption(id: "test-model", name: "Test Model", efforts: ["low", "high"], defaultEffort: "low")]

    @Test
    func catalogUsesCLIVisibilityAndPerModelEfforts() throws {
        let data = Data(#"{"models":[{"slug":"a","display_name":"A","visibility":"list","default_reasoning_level":"high","supported_reasoning_levels":[{"effort":"high"}]},{"slug":"internal","display_name":"Internal","visibility":"hide","supported_reasoning_levels":[]}]}"#.utf8)
        let catalog = try CodexModelCatalog.parse(data)
        #expect(catalog.map(\.id) == ["a"])
        #expect(catalog.first?.efforts == ["high"])
        #expect(catalog.first?.defaultEffort == "high")
    }

    @Test
    func liveFooterWinsOverLastTurnAndCommandHistory() {
        let core = CodexPluginCore()
        #expect(core.modelSelection(lines: ["• Model changed to test-model high", "› Ask Codex to do anything", "  Test Model low fast · ~/project"], models: models) == .init(model: "test-model", effort: "low"))
        #expect(core.modelSelection(lines: ["• Model changed to test-model high"], models: models) == nil)
        #expect(core.modelSelection(lines: ["  Test Model default · ~/project"], models: models)?.effort == "low")
    }

    @Test
    func unsupportedChoiceNeverSendsInput() async throws {
        let core = CodexPluginCore()
        let terminal = AgentModelTerminal(read: { [] }, submit: { _ in Issue.record("Unexpected submission") }, send: { _ in Issue.record("Unexpected terminal input") })
        await #expect(throws: AgentModelError.self) {
            try await core.selectModel(.init(model: "test-model", effort: "ultra"), models: models, terminal: terminal)
        }
    }

    @Test(arguments: [
        ["› Ask Codex to do anything", "  ~/project"],
        ["› Ask Codex to do anything", "  Test Model · ~/project"],
        ["› Ask Codex to do anything", "  Test Model default · ~/project"],
    ])
    func unverifiableStatusLineDisablesSwitchAndNeverSendsInput(_ lines: [String]) async throws {
        let core: any AgentModelProviding = CodexPluginCore()
        let options = [AgentModelOption(id: "test-model", name: "Test Model", efforts: ["low", "high"], defaultEffort: nil)]
        #expect(core.modelSwitchIssue(lines: lines, models: options) != nil)
        let terminal = AgentModelTerminal(read: { lines }, submit: { _ in Issue.record("Unverifiable switch was submitted") }, send: { _ in Issue.record("Unexpected terminal input") })
        await #expect(throws: AgentModelError.self) {
            try await core.selectModel(.init(model: "test-model", effort: "high"), models: options, terminal: terminal)
        }
        #expect(core.modelSwitchIssue(lines: ["  Test Model low · ~/project"], models: options) == nil)
    }

    @Test
    func switchUsesSessionCommandAndReadback() async throws {
        actor Fixture {
            var commands: [String] = []
            func submit(_ value: String) {
                commands.append(value)
            }

            func read() -> [String] {
                ["  Test Model high · ~/project"]
            }
        }
        let fixture = Fixture()
        let core = CodexPluginCore()
        let result = try await core.selectModel(.init(model: "test-model", effort: "high"), models: models, terminal: .init(read: { await fixture.read() }, submit: { await fixture.submit($0) }, send: { _ in Issue.record("Unexpected menu input") }))
        #expect(result == .init(model: "test-model", effort: "high"))
        #expect(await fixture.commands == ["/model test-model --reasoning=high"])
    }
}
