import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import ClaudeCodePluginCore

struct ClaudeModelControlsTests {
    @Test("Compatible metadata is accepted across CLI updates", arguments: ["2.1.310", "2.1.311", "2.2.0"])
    func compatibleVersions(version: String) async throws {
        let context = AgentModelContext(invocation: .init(executable: "/removed/claude", arguments: []), environment: [:], directory: "/fixture", discoveryExecutable: "/updated/claude", discoveryVersion: "\(version) (Claude Code)")
        #expect(context.invocation.version == nil)
        #expect(ClaudeCodePluginCore().modelRuntimeIssue(context) == nil)
        try await withDependencies {
            $0[ProcessRunner.self].runWithExactEnvironment = { _, args, _, _, _, _ in
                #expect(args.prefix(3) == ["-C", "/fixture", "/updated/claude"])
                return .init(exitCode: 0, stdout: Data(#"{"type":"control_response","response":{"response":{"models":[{"value":"sonnet","displayName":"Sonnet","supportedEffortLevels":["high"]}]}}}"#.utf8), stderr: Data())
            }
        } operation: {
            let models = try await ClaudeCodePluginCore().modelOptions(context)
            #expect(models.map(\.id) == ["sonnet"])
        }
    }

    @Test(arguments: [
        ["--setting-sources", "project", "--model", "sonnet", "--effort", "high"],
        ["--setting-sources=project", "--model=sonnet", "--effort=high"],
        ["--model=sonnet", "--setting-sources", "project", "--effort=high"],
        ["--setting-sources="],
        ["--setting-sources", ""],
    ])
    func discoveryPreservesConfigurationSelectors(_ selectors: [String]) async throws {
        try await withDependencies {
            $0[ProcessRunner.self].runWithExactEnvironment = { executable, arguments, _, _, _, _ in
                #expect(executable == "/usr/bin/env")
                let start = try #require(arguments.firstIndex(of: "--no-session-persistence")) + 1
                let end = try #require(arguments.firstIndex(of: "--settings"))
                #expect(Array(arguments[start..<end]) == selectors)
                #expect(!arguments.contains("resume-fixture"))
                return ProcessResult(exitCode: 0, stdout: Data(#"{"type":"control_response","response":{"response":{"models":[{"value":"sonnet","displayName":"Sonnet","supportedEffortLevels":["high"]}]}}}"#.utf8), stderr: Data())
            }
        } operation: {
            let context = AgentModelContext(invocation: .init(executable: "/fixture/claude", arguments: selectors + ["--resume", "resume-fixture"], version: "2.1.310 (Claude Code)"), environment: [:], directory: "/fixture/project")
            let models = try await ClaudeCodePluginCore().modelOptions(context)
            #expect(models.map(\.id) == ["sonnet"])
        }
    }

    private let models = [
        AgentModelOption(id: "default", name: "Default (recommended)", efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: nil),
        AgentModelOption(id: "sonnet", name: "Sonnet", efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: nil, screenNames: ["Sonnet", "Sonnet 5.5"]),
    ]

    @Test
    func sdkCatalogCarriesPerModelEffortsWithoutStaticFallback() throws {
        let data = Data(#"{"type":"control_response","response":{"response":{"models":[{"value":"a","displayName":"A","description":"A 2 · model","supportedEffortLevels":["low","high"]},{"value":"b","displayName":"B","description":"B model"}]}}}"#.utf8)
        let catalog = try ClaudeModelCatalog.parse(data)
        #expect(catalog.map(\.id) == ["a", "b"])
        #expect(catalog[0].efforts == ["low", "high"])
        #expect(catalog[1].efforts.isEmpty)
        #expect(catalog[0].defaultEffort == nil)
    }

    @Test(arguments: [("◐ Medium", "medium"), ("● High", "high"), ("◉ xHigh", "xhigh"), ("◈ Max", "max")])
    func nativePickerSeparatesFocusFromCurrent(_ label: String, _ effort: String) throws {
        let menu = try #require(ClaudeModelMenu(lines: [
            "   Select model",
            "   ❯ 1. Default (recommended) ✔  Use the default model",
            "     4. Sonnet                   Sonnet 5.5 · Efficient",
            "   \(label) effort (default) ←/→ to adjust",
            "   Enter to set as default · s to use this session only · Esc to cancel",
        ], models: models))
        #expect(menu.focused == "default")
        #expect(menu.current == "default")
        #expect(menu.effort == effort)
        #expect(menu.positions["sonnet"] == 4)
    }

    @Test
    func aliasesOfTheSameEffectiveModelShareOneButtonAndCurrentIdentity() throws {
        let data = Data(#"{"type":"control_response","response":{"response":{"models":[{"value":"default","resolvedModel":"opus-current","displayName":"Default (recommended)","description":"Opus 5 · Default","supportedEffortLevels":["low","high"]},{"value":"opus","resolvedModel":"opus-current","displayName":"Opus","description":"Opus 5 · Powerful","supportedEffortLevels":["low","high"]}]}}}"#.utf8)
        let catalog = try ClaudeModelCatalog.parse(data)
        #expect(catalog.count == 1)
        #expect(catalog.first?.name == "Opus")
        let menu = try #require(ClaudeModelMenu(lines: [
            "Select model", "❯ 1. Default (recommended) ✔  Default",
            "2. Opus  Powerful", "● High effort ←/→ to adjust", "s to use this session only",
        ], models: catalog))
        #expect(menu.current == "opus-current")
        #expect(menu.focused == menu.current)
        #expect(menu.positions["opus-current"] == 2)
    }

    @Test
    func headerUsesActualEffortAndDoesNotGuessDefault() {
        let core = ClaudeCodePluginCore()
        let header = [" ▐▛███▛█   Claude Code v2.1.310", "▝▜██████▀  Sonnet 5.5 with xhigh effort · API Usage Billing"]
        #expect(core.modelSelection(lines: header, models: models) == .init(model: "sonnet", effort: "xhigh"))
        #expect(core.modelSelection(lines: [header[0], "▝▜██████▀  Sonnet 5.5 · API Usage Billing"], models: models)?.effort == nil)
        #expect(core.modelSelection(lines: ["previous reply used Sonnet 5.5 with high effort"], models: models) == nil)
    }

    @Test
    func changingMenuWithoutSessionOnlyActionIsUnsupported() {
        #expect(ClaudeModelMenu(lines: ["Select model", "❯ 1. Default (recommended) ✔  Default", "Enter to confirm"], models: models) == nil)
    }
}
