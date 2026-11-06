import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CodexPluginCore

private actor InstallerFixture {
    struct Call: Sendable {
        let executable: String
        let args: [String]
        let environment: [String: String]?
    }

    var versions: [String: String]
    var calls: [Call] = []
    var wrongMarketplace = false
    var failure: String?
    var noOp = false
    var listExit: Int32?
    var malformed = false
    init(_ versions: [String: String] = [:]) {
        self.versions = versions
    }

    func configure(wrongMarketplace: Bool = false, failure: String? = nil, noOp: Bool = false, listExit: Int32? = nil, malformed: Bool = false) {
        self.wrongMarketplace = wrongMarketplace
        self.failure = failure
        self.noOp = noOp
        self.listExit = listExit
        self.malformed = malformed
    }

    func run(_ exe: String, _ args: [String], _ environment: [String: String]?) throws -> ProcessResult {
        calls.append(.init(executable: exe, args: args, environment: environment))
        func success(_ text: String = "") -> ProcessResult {
            .init(exitCode: 0, stdout: Data(text.utf8), stderr: Data())
        }
        func failed(_ code: Int32) -> ProcessResult {
            .init(exitCode: code, stdout: Data(), stderr: Data("fixture failure".utf8))
        }
        if args.contains("marketplace"), args.contains("list") {
            let path = wrongMarketplace ? "/foreign" : "/bundle/plugin"
            return success("{\"marketplaces\":[{\"name\":\"ctrlx\",\"root\":\"\(path)\"}]}")
        }
        if args.dropFirst().starts(with: ["plugin", "list"]) {
            if let listExit {
                return failed(listExit)
            }
            if malformed {
                return success("not a plugin list")
            }
            return success("PLUGIN STATUS VERSION PATH\n" + versions.sorted { $0.key < $1.key }.map { "\($0.key) installed \($0.value) /cache" }.joined(separator: "\n"))
        }
        if args.count >= 4, ["add", "install", "update", "uninstall", "remove"].contains(args[2]), args[3].contains("@ctrlx") {
            let ref = args[3]
            if ref == failure {
                return failed(2)
            }
            if ["uninstall", "remove"].contains(args[2]) {
                versions[ref] = nil
            } else if !noOp {
                versions[ref] = ref == "ctrlx@ctrlx" ? "2.0.0" : "1.0.0"
            }
        }
        return success()
    }
}

@Suite("CodexCLIInstaller")
struct CodexCLIInstallerTests {
    private func run(_ fixture: InstallerFixture, operation: (CodexCLIInstaller) async throws -> Void) async throws {
        try await withDependencies {
            $0[AgentPluginResourceClient.self].version = { url in
                url.path.contains("ctrlx-hooks/") ? "1.0.0" : "2.0.0"
            }
        } operation: {
            let runner = ProcessRunner { exe, args, env, _ in try await fixture.run(exe, args, env) }
            try await operation(.init(processRunner: runner, command: "codex", marketplaceSource: URL(fileURLWithPath: "/bundle/plugin")))
        }
    }

    @Test("Initial install and legacy migration register exactly one separate bridge", arguments: [false, true])
    func migration(_ legacy: Bool) async throws {
        let fixture = InstallerFixture(legacy ? ["ctrlx@ctrlx": "1.0.0"] : [:])
        try await run(fixture) { installer in
            guard case .installed = try await installer.install(configRoot: "/private-config") else { Issue.record("Expected installation")
                return
            }
            #expect(await installer.installStatus(configRoot: "/private-config") == .installed(version: "2.0.0 + hooks 1.0.0"))
            let bundled = try await installer.bundledVersion()
            #expect(bundled == "2.0.0 + hooks 1.0.0")
        }
        let calls = await fixture.calls
        #expect(calls.allSatisfy { $0.executable == "/usr/bin/env" && $0.environment?["CODEX_HOME"] == "/private-config" })
        let changes = calls.filter { $0.args.count >= 4 && ["add", "install", "update"].contains($0.args[2]) && $0.args[3].contains("@ctrlx") }
        #expect(changes.map { $0.args[3] } == ["ctrlx@ctrlx", "ctrlx-hooks@ctrlx"])
        #expect(!calls.contains { $0.args.contains("uninstall") || $0.args.contains("remove") })
    }

    @Test("A skills update never replaces an unchanged or newer hook plugin", arguments: ["1.0.0", "1.1.0"])
    func skillsOnly(_ hooks: String) async throws {
        let fixture = InstallerFixture(["ctrlx@ctrlx": "1.0.0", "ctrlx-hooks@ctrlx": hooks])
        try await run(fixture) { installer in
            let updated = try await installer.reinstall(configRoot: nil)
            #expect(updated == .installed(version: "2.0.0 + hooks \(hooks)"))
            guard case .alreadyInstalled = try await installer.install(configRoot: nil) else { Issue.record("Expected unchanged components")
                return
            }
        }
        let calls = await fixture.calls
        #expect(calls.allSatisfy { $0.environment == nil })
        #expect(!calls.contains { $0.args.count >= 4 && $0.args[3] == "ctrlx-hooks@ctrlx" })
    }

    @Test("A hooks-only update preserves the skills installation")
    func hooksOnly() async throws {
        let fixture = InstallerFixture(["ctrlx@ctrlx": "2.0.0", "ctrlx-hooks@ctrlx": "0.9.0"])
        try await run(fixture) { installer in
            let updated = try await installer.reinstall(configRoot: nil)
            #expect(updated == .installed(version: "2.0.0 + hooks 1.0.0"))
        }
        let calls = await fixture.calls
        #expect(!calls.contains { $0.args.count >= 4 && $0.args[3] == "ctrlx@ctrlx" })
    }

    @Test("A partial migration is explicit and a retry repairs it")
    func partialFailure() async throws {
        let fixture = InstallerFixture(["ctrlx@ctrlx": "1.0.0"])
        await fixture.configure(failure: "ctrlx-hooks@ctrlx")
        try await run(fixture) { installer in
            await #expect(throws: (any Error).self) { _ = try await installer.install(configRoot: nil) }
            #expect(await installer.installStatus(configRoot: nil) == .installed(version: "2.0.0"))
            let bundled = try await installer.bundledVersion()
            #expect(AgentPluginResourceClient.updateAvailable(installed: "2.0.0", bundled: bundled))
            await fixture.configure()
            _ = try await installer.install(configRoot: nil)
            #expect(await installer.installStatus(configRoot: nil) == .installed(version: "2.0.0 + hooks 1.0.0"))
        }
        let calls = await fixture.calls
        #expect(calls.filter { $0.args.count >= 4 && $0.args[3] == "ctrlx@ctrlx" }.count == 1)
    }

    @Test("A foreign marketplace or an optimistic CLI response cannot report successful installation", arguments: ["foreign", "no-op", "malformed"])
    func failures(_ scenario: String) async throws {
        let fixture = InstallerFixture()
        await fixture.configure(wrongMarketplace: scenario == "foreign", noOp: scenario == "no-op", malformed: scenario == "malformed")
        try await run(fixture) { installer in
            await #expect(throws: (any Error).self) { _ = try await installer.install(configRoot: nil) }
        }
        if scenario != "no-op" {
            let calls = await fixture.calls
            #expect(!calls.contains { $0.args.count >= 4 && $0.args[3].contains("@ctrlx") })
        }
    }

    @Test("CLI unavailable and list failures remain distinct", arguments: [Int32(127), 2])
    func listFailure(_ code: Int32) async throws {
        let fixture = InstallerFixture()
        await fixture.configure(listExit: code)
        try await run(fixture) { installer in
            let status = await installer.installStatus(configRoot: "/nonexistent-config")
            if code == 127 {
                #expect(status == .agentUnavailable)
            } else {
                guard case .checkFailed = status else { Issue.record("Expected check failure")
                    return
                }
            }
        }
    }

    @Test("Uninstall removes only the two user-owned components, tolerating an absent component", arguments: [false, true])
    func uninstall(_ both: Bool) async throws {
        let fixture = InstallerFixture(both ? ["ctrlx@ctrlx": "2.0.0", "ctrlx-hooks@ctrlx": "1.0.0"] : ["ctrlx@ctrlx": "1.0.0"])
        try await run(fixture) { installer in
            try await installer.uninstall(configRoot: "/private-config")
            #expect(await installer.installStatus(configRoot: "/private-config") == .notInstalled)
        }
        let calls = await fixture.calls
        let removed = calls.filter { $0.args.count >= 4 && ["remove", "uninstall"].contains($0.args[2]) }
        #expect(removed.map { $0.args[3] } == ["ctrlx-hooks@ctrlx", "ctrlx@ctrlx"])
        #expect(removed.allSatisfy { $0.environment?["CODEX_HOME"] == "/private-config" })
    }

    @Test("Hooks-only installations retain their component version, update notice and uninstall state")
    func hooksRemain() async throws {
        let fixture = InstallerFixture(["ctrlx-hooks@ctrlx": "1.0.0"])
        try await run(fixture) { installer in
            let status = await installer.installStatus(configRoot: "/private-config")
            guard case let .installed(version) = status else { Issue.record("The remaining hook plugin must be uninstallable")
                return
            }
            #expect(version == "missing + hooks 1.0.0")
            #expect(AgentPluginResourceClient.hooksVersionIfSkillsMissing(version) == "1.0.0")
            #expect(AgentPluginResourceClient.updateAvailable(installed: version, bundled: "2.0.0 + hooks 1.0.0"))
            try await installer.uninstall(configRoot: "/private-config")
            #expect(await installer.installStatus(configRoot: "/private-config") == .notInstalled)
        }
    }

    @Test("Uninstall does not list a missing marketplace and still tries both IDs after an error", arguments: [false, true])
    func uninstallWithoutSource(_ failure: Bool) async throws {
        let fixture = InstallerFixture(["ctrlx@ctrlx": "2.0.0", "ctrlx-hooks@ctrlx": "1.0.0"])
        await fixture.configure(failure: failure ? "ctrlx-hooks@ctrlx" : nil, listExit: 2)
        try await run(fixture) { installer in
            if failure {
                await #expect(throws: AgentPluginInstallError.self) { try await installer.uninstall(configRoot: "/private-config") }
            } else {
                try await installer.uninstall(configRoot: "/private-config")
            }
        }
        let calls = await fixture.calls
        #expect(calls.map { $0.args } == [["codex", "plugin", "remove", "ctrlx-hooks@ctrlx"], ["codex", "plugin", "remove", "ctrlx@ctrlx"]])
        #expect(calls.allSatisfy { $0.environment?["CODEX_HOME"] == "/private-config" })
        let remaining = await fixture.versions
        #expect(remaining["ctrlx@ctrlx"] == nil)
        #expect((remaining["ctrlx-hooks@ctrlx"] != nil) == failure)
    }

    @Test("When native listing fails, a hooks-only configuration retains the uninstall entry")
    func configuredHooksOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.toml")
        let fixture = InstallerFixture()
        await fixture.configure(listExit: 2)
        try await run(fixture) { installer in
            try "[plugins.\"ctrlx-hooks@ctrlx\"]\nenabled = true\n".write(to: config, atomically: true, encoding: .utf8)
            #expect(await installer.installStatus(configRoot: root.path) == .installed(version: "missing + hooks unknown"))
            try "unrelated invalid configuration".write(to: config, atomically: true, encoding: .utf8)
            guard case .checkFailed = await installer.installStatus(configRoot: root.path) else { Issue.record("Unknown configuration must preserve the list error")
                return
            }
        }
        #expect(CodexCLIInstaller.parseConfiguredStatus(from: "[plugins.\"ctrlx-hooks@other\"]\nenabled = true\n") == .notInstalled)
    }

    @Test("Status parsing requires the exact marketplace and user scope")
    func parser() {
        #expect(CodexCLIInstaller.parseStatus(from: "PLUGIN STATUS VERSION PATH\nctrlx@other installed 9.0.0 /cache") == .notInstalled)
        #expect(CodexCLIInstaller.parseStatus(from: "PLUGIN STATUS VERSION PATH\nctrlx@ctrlx not installed /cache") == .notInstalled)
        #expect(CodexCLIInstaller.parseStatus(from: "PLUGIN STATUS VERSION PATH\nctrlx-hooks@ctrlx installed 1.0.0 /cache", pluginRef: CodexCLIInstaller.hooksRef) == .installed(version: "1.0.0"))
    }
}
