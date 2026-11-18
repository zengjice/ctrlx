import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CodexPluginCore

struct CodexModelRefreshTests {
    private static let old = AgentModelOption(id: "gpt-6.1-sol", name: "GPT-6.1-Sol", efforts: ["high"], defaultEffort: "high")
    private static let new = AgentModelOption(id: "gpt-6.2-sol", name: "GPT-6.2-Sol", efforts: ["high"], defaultEffort: "high")
    private static let models = [old, new]
    private static let command = "/model gpt-6.2-sol --reasoning=high"
    private static let rejection = "■ Model 'gpt-6.2-sol' is unavailable. Use /model to see available models."
    private static let idle = ["› Ask Codex to do anything", "  GPT-6.1-Sol high · ~/project"]

    private actor Terminal {
        var commands: [String] = []
        var keys: [TmuxKey] = []
        var menuReads = 0
        var errors = 0
        var menuOpen = false
        let scenario: Scenario

        enum Scenario: Sendable {
            case refreshed
            case rejectedAgain
            case refreshTimeout
            case staleError
            case timeout
            case interrupted
        }

        init(_ scenario: Scenario) {
            self.scenario = scenario
        }

        func submit(_ command: String) {
            commands.append(command)
            if command == "/model" {
                menuOpen = true
            } else if scenario != .timeout, scenario != .staleError {
                errors += 1
            }
        }

        func send(_ keys: [TmuxKey]) throws {
            if scenario == .interrupted {
                throw CancellationError()
            }
            self.keys += keys
            if keys == [.escape] {
                menuOpen = false
            }
        }

        func read() -> [String] {
            if menuOpen {
                menuReads += 1
                let stale = scenario == .refreshTimeout || menuReads < 3
                return ["Select Model and Effort", "› 1. GPT-6.1-Sol (current)  Old model"]
                    + (stale ? [] : ["  2. GPT-6.2-Sol  New model"])
                    + ["enter select · esc back"]
            }
            if commands.count == 3, scenario != .rejectedAgain {
                return ["  GPT-6.2-Sol high · ~/project"]
            }
            let count = scenario == .staleError ? 1 : errors
            return Array(repeating: rejection, count: count) + idle
        }

        func snapshot() -> ([String], [TmuxKey]) {
            (commands, keys)
        }

        nonisolated var client: AgentModelTerminal {
            .init(read: { await self.read() }, submit: { await self.submit($0) }, send: { try await self.send($0) })
        }
    }

    private func select(_ terminal: Terminal) async throws -> AgentModelSelection {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            try await CodexPluginCore().selectModel(.init(model: Self.new.id, effort: "high"), models: Self.models, terminal: terminal.client)
        }
    }

    @Test("An explicitly rejected new model refreshes the native menu and retries once")
    func refreshThenRetry() async throws {
        let terminal = Terminal(.refreshed)
        let result = try await select(terminal)
        #expect(result == .init(model: Self.new.id, effort: "high"))
        let (commands, keys) = await terminal.snapshot()
        #expect(commands == [Self.command, "/model", Self.command])
        #expect(keys == [.escape])
        #expect(await terminal.menuReads == 3)
    }

    @Test("Old transcript errors and unconfirmed commands never trigger automatic input", arguments: [Terminal.Scenario.staleError, .timeout])
    private func noBlindRetry(_ scenario: Terminal.Scenario) async {
        let terminal = Terminal(scenario)
        await #expect(throws: AgentModelError.self) { try await select(terminal) }
        let (commands, keys) = await terminal.snapshot()
        #expect(commands == [Self.command])
        #expect(keys.isEmpty)
    }

    @Test("An absent target after refreshing does not replay the model command")
    func refreshTimeout() async {
        let terminal = Terminal(.refreshTimeout)
        await #expect(throws: AgentModelError.self) { try await select(terminal) }
        let (commands, keys) = await terminal.snapshot()
        #expect(commands == [Self.command, "/model"])
        #expect(keys.isEmpty) // The Host owns cleanup of recognized pickers on failure.
    }

    @Test("A second rejection stops without another refresh")
    func rejectedAgain() async {
        let terminal = Terminal(.rejectedAgain)
        await #expect(throws: AgentModelError.self) { try await select(terminal) }
        #expect(await terminal.snapshot().0 == [Self.command, "/model", Self.command])
    }

    @Test("Human-input or identity cancellation cannot replay the model command")
    func interruption() async {
        let terminal = Terminal(.interrupted)
        await #expect(throws: CancellationError.self) { try await select(terminal) }
        #expect(await terminal.snapshot().0 == [Self.command, "/model"])
    }

    @Test("Refresh requires a model row, not a description, prefix or old transcript")
    func menuRecognition() throws {
        let prefix = ["Select Model and Effort"]
        let suffix = ["enter select · esc back"]
        for row in [
            "  1. GPT-6.2-Sol-Other  A different model",
            "  1. GPT-6.1-Sol  GPT-6.2-Sol",
            "GPT-6.2-Sol is now available",
        ] {
            #expect(CodexModelMenu(lines: prefix + [row] + suffix)?.contains(Self.new) != true)
        }
        #expect(CodexModelMenu(lines: ["  1. GPT-6.2-Sol  Transcript"]) == nil)
        let menu = try #require(CodexModelMenu(lines: prefix + ["› 1. GPT-6.2-Sol (current)  Latest"] + suffix))
        #expect(menu.contains(Self.new))
        #expect(CodexPluginCore().isModelPicker(lines: prefix + ["› 1. GPT-6.1-Sol (current)  Old"] + suffix, models: Self.models))
        #expect(CodexPluginCore().isModelPicker(lines: ["Loading models…"] + suffix, models: Self.models))
    }

    @Test("Only exact native rejections count, including wrapped terminal lines")
    func rejectionRecognition() {
        #expect(CodexModelMenu.unavailableCount(modelID: Self.new.id, lines: [Self.rejection, Self.rejection]) == 2)
        #expect(CodexModelMenu.unavailableCount(modelID: Self.new.id, lines: ["■ Model 'gpt-6.2-sol' is unavailable. Use /model", "to see available models."]) == 1)
        #expect(CodexModelMenu.unavailableCount(modelID: Self.new.id, lines: ["■ Model 'gpt-6.2-", "sol' is unavailab", "le. Use /model to see available models."]) == 1)
        #expect(CodexModelMenu.unavailableCount(modelID: Self.new.id, lines: ["Model 'gpt-6.2-sol' is unavailable. Use /model to see available models."]) == 0)
        #expect(CodexModelMenu.unavailableCount(modelID: Self.old.id, lines: [Self.rejection]) == 0)
    }
}
