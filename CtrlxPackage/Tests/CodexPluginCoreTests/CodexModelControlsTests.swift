import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CodexPluginCore

struct CodexModelControlsTests {
    @Test("Discovery can use a replacement CLI without assigning its version to the live process")
    func replacementDiscovery() async throws {
        let context = AgentModelContext(invocation: .init(executable: "/removed/codex", arguments: []), environment: [:], directory: "/fixture", discoveryExecutable: "/updated/codex", discoveryVersion: "codex-cli 0.999.0")
        #expect(context.invocation.version == nil)
        #expect(CodexPluginCore().modelRuntimeIssue(context) == nil)
        try await withDependencies {
            $0[ProcessRunner.self].runWithExactEnvironment = { _, args, _, _, _, _ in
                #expect(args.prefix(3) == ["-C", "/fixture", "/updated/codex"])
                return .init(exitCode: 0, stdout: Data(#"{"models":[{"slug":"test-model","display_name":"Test Model","visibility":"list","supported_reasoning_levels":[{"effort":"high"}]}]}"#.utf8), stderr: Data())
            }
        } operation: { _ = try await CodexPluginCore().modelOptions(context) }
    }

    private func context(version: String?) -> AgentModelContext {
        .init(invocation: .init(executable: "/fixture/codex", arguments: [], version: version), environment: [:], directory: "/fixture/project")
    }

    @Test(arguments: ["codex-cli 0.164.0", "codex-cli 0.165.0", "codex-cli 0.166.0", "codex-cli 0.166.0-alpha.1"])
    func compatibleCatalogIsDiscoveredAcrossCLIVersions(_ version: String) async throws {
        let core = CodexPluginCore()
        let context = context(version: version)
        #expect(core.modelRuntimeIssue(context) == nil)
        try await withDependencies {
            $0[ProcessRunner.self].runWithExactEnvironment = { executable, arguments, _, _, _, _ in
                #expect(executable == "/usr/bin/env")
                #expect(arguments == ["-C", "/fixture/project", "/fixture/codex", "debug", "models"])
                return ProcessResult(exitCode: 0, stdout: Data(#"{"models":[{"slug":"test-model","display_name":"Test Model","visibility":"list","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]}]}"#.utf8), stderr: Data())
            }
        } operation: {
            let discovered = try await core.modelOptions(context)
            #expect(discovered == models)
        }
    }

    @Test(arguments: [nil, "", "2.1.310 (Claude Code)", "codex-cli "] as [String?])
    func missingAndUnrecognizedVersionsDoNotStartDiscovery(_ version: String?) async throws {
        let core = CodexPluginCore()
        let context = context(version: version)
        let issue = try #require(core.modelRuntimeIssue(context))
        if let version, !version.isEmpty {
            #expect(issue.contains(version))
        } else {
            #expect(issue.contains("could not be read"))
        }
        await withDependencies {
            $0[ProcessRunner.self].runWithExactEnvironment = { _, _, _, _, _, _ in
                Issue.record("Unverified CLI was invoked")
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        } operation: {
            await #expect(throws: AgentModelError.self) { try await core.modelOptions(context) }
        }
    }

    @Test(arguments: [
        ProcessResult(exitCode: 1, stdout: Data(), stderr: Data()),
        ProcessResult(exitCode: 0, stdout: Data(), stderr: Data(), outputTruncated: true),
        ProcessResult(exitCode: 0, stdout: Data("{\"models\":[]}".utf8), stderr: Data()),
        ProcessResult(exitCode: 0, stdout: Data("different protocol".utf8), stderr: Data()),
    ])
    func unsupportedDiscoveryReportsActualVersion(_ result: ProcessResult) async throws {
        try await withDependencies {
            $0[ProcessRunner.self].runWithExactEnvironment = { _, _, _, _, _, _ in result }
        } operation: {
            do {
                _ = try await CodexPluginCore().modelOptions(context(version: "codex-cli 0.165.0"))
                Issue.record("Unsupported catalog was accepted")
            } catch let error as AgentModelError {
                #expect(error.message.contains("codex-cli 0.165.0"))
                #expect(error.message.contains(result.isSuccess && !result.outputTruncated ? "incompatible model catalog" : "model discovery failed"))
            }
        }
    }

    @Test
    func failedProbeReportsActualVersion() async throws {
        try await withDependencies {
            $0[ProcessRunner.self].runWithExactEnvironment = { _, _, _, _, _, _ in throw ProcessRunnerError.timeout }
        } operation: {
            do {
                _ = try await CodexPluginCore().modelOptions(context(version: "codex-cli 0.165.0"))
                Issue.record("Failed discovery was accepted")
            } catch let error as AgentModelError {
                #expect(error.message.contains("codex-cli 0.165.0"))
                #expect(error.message.contains("model discovery failed"))
            }
        }
    }

    @Test
    func cancelledDiscoveryRemainsCancelled() async {
        await withDependencies {
            $0[ProcessRunner.self].runWithExactEnvironment = { _, _, _, _, _, _ in throw CancellationError() }
        } operation: {
            await #expect(throws: CancellationError.self) {
                try await CodexPluginCore().modelOptions(context(version: "codex-cli 0.165.0"))
            }
        }
    }

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
