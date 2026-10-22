#if os(macOS)
    import CtrlxCommon
    import Darwin
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Agent CLI update and launch repair")
    struct AgentCLIMaintenanceTests {
        private struct Fixture: Sendable {
            let root: URL
            let installation: AgentCLIManagedInstallation

            init(agent: InstallableAgentCLI = .codex, cask: String? = "codex") throws {
                self.root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-maintenance-\(UUID().uuidString)").resolvingSymlinksInPath()
                let binary: URL
                let launcher: URL
                if let cask {
                    binary = root.appendingPathComponent("Caskroom/\(cask)/1/\(agent == .codex ? "bin/codex" : "claude")")
                    launcher = root.appendingPathComponent("bin/\(agent.command)")
                } else {
                    binary = root.appendingPathComponent(agent == .codex ? ".codex/packages/standalone/releases/1/bin/codex" : ".local/share/claude/versions/1")
                    launcher = URL(fileURLWithPath: agent.nativePath(home: root))
                }
                try Self.writeExecutable(binary)
                if agent == .codex {
                    let package = binary.deletingLastPathComponent().deletingLastPathComponent()
                    try Self.writeExecutable(package.appendingPathComponent("bin/codex-code-mode-host"))
                    try Self.writeExecutable(package.appendingPathComponent("codex-path/rg"))
                }
                try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: binary)
                self.installation = try #require(AgentCLIManagedInstallation.discover(agent, launcherPath: launcher.path, home: root, brewPrefixes: [root.path]))
                for path in installation.quarantinePaths {
                    let value = Array("0081;fixture;CtrlX;".utf8)
                    let result = value.withUnsafeBytes { setxattr(path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
                    #expect(result == 0)
                }
            }

            static func writeExecutable(_ path: URL) throws {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("#!/bin/sh\necho fixture-version\n".utf8).write(to: path)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            }

            func remove() {
                try? FileManager.default.removeItem(at: root)
            }
        }

        private actor Commands {
            struct Call: Sendable {
                let executable: String
                let arguments: [String]
                let environment: [String: String]
            }

            var calls: [Call] = []
            let failedSignature: String?
            init(failedSignature: String? = nil) {
                self.failedSignature = failedSignature
            }

            func run(_ executable: String, _ arguments: [String], _ environment: [String: String]) -> Int32 {
                calls.append(Call(executable: executable, arguments: arguments, environment: environment))
                if executable == "/usr/bin/codesign", arguments.last == failedSignature {
                    return 1
                }
                if executable == "/usr/bin/xattr", let path = arguments.last {
                    return removexattr(path, "com.apple.quarantine", 0)
                }
                return 0
            }

            nonisolated var client: AgentCLIProcessClient {
                .init(run: { executable, arguments, environment, _, output in
                    await output("fixture process output\n")
                    return await self.run(executable, arguments, environment)
                })
            }
        }

        @Test("Homebrew source and Claude release channel are preserved", arguments: ["codex", "claude-code", "claude-code@latest"])
        func homebrewUpdate(cask: String) async throws {
            let fixture = try Fixture(agent: cask == "codex" ? .codex : .claudeCode, cask: cask)
            defer { fixture.remove() }
            let commands = Commands()
            let updatedPackage = fixture.root.appendingPathComponent("Caskroom/\(cask)/2")
            try await withDependencies {
                $0[AgentCLIProcessClient.self] = .init(run: { executable, arguments, environment, _, _ in
                    if executable == fixture.root.appendingPathComponent("bin/brew").path {
                        try FileManager.default.copyItem(at: fixture.root.appendingPathComponent("Caskroom/\(cask)/1"), to: updatedPackage)
                        try FileManager.default.removeItem(atPath: fixture.installation.launcherPath)
                        try FileManager.default.createSymbolicLink(atPath: fixture.installation.launcherPath, withDestinationPath: updatedPackage.appendingPathComponent(cask == "codex" ? "bin/codex" : "claude").path)
                    }
                    return await commands.run(executable, arguments, environment)
                })
            } operation: {
                try await AgentCLIMaintenance.perform(.update, installation: fixture.installation, event: { _ in })
            }
            let calls = await commands.calls
            let upgrade = try #require(calls.first)
            #expect(upgrade.executable == fixture.root.appendingPathComponent("bin/brew").path)
            #expect(upgrade.arguments == ["upgrade", "--cask", cask])
            #expect(upgrade.environment["HOMEBREW_NO_INSTALL_CLEANUP"] == "1")
            #expect(!calls.contains { $0.executable == "/usr/bin/curl" })
            let updated = try #require(fixture.installation.reloaded())
            #expect(updated.binaryPath != fixture.installation.binaryPath)
            #expect(getxattr(updated.binaryPath, "com.apple.quarantine", nil, 0, 0, 0) == -1)
            #expect(getxattr(fixture.installation.binaryPath, "com.apple.quarantine", nil, 0, 0, 0) >= 0)
            #expect(calls.filter { $0.executable == "/usr/bin/codesign" }.allSatisfy { $0.arguments.last?.hasPrefix(updatedPackage.path + "/") == true })
        }

        @Test("Native updates use the original home and the official updater", arguments: InstallableAgentCLI.allCases)
        func nativeUpdate(agent: InstallableAgentCLI) async throws {
            let fixture = try Fixture(agent: agent, cask: nil)
            defer { fixture.remove() }
            let commands = Commands()
            try await withDependencies { $0[AgentCLIProcessClient.self] = commands.client } operation: {
                try await AgentCLIMaintenance.perform(.update, installation: fixture.installation, event: { _ in })
            }
            let calls = await commands.calls
            if agent == .codex {
                let installer = try #require(calls.first { $0.executable == "/bin/sh" })
                #expect(installer.environment["CODEX_HOME"] == fixture.root.appendingPathComponent(".codex").path)
                #expect(installer.environment["CODEX_INSTALL_DIR"] == fixture.root.appendingPathComponent(".local/bin").path)
                #expect(installer.environment["CODEX_NON_INTERACTIVE"] == "1")
                #expect(calls.contains { $0.executable == "/usr/bin/curl" && $0.arguments.last == agent.installerURL })
            } else {
                #expect(calls.contains { $0.executable == fixture.installation.binaryPath && $0.arguments == ["update"] })
                #expect(!calls.contains { $0.executable == "/usr/bin/curl" })
            }
        }

        @Test("All signatures precede any quarantine change; unrelated files retain quarantine")
        func repairScope() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let unrelated = fixture.root.appendingPathComponent("unrelated")
            try Fixture.writeExecutable(unrelated)
            #expect(setxattr(unrelated.path, "com.apple.quarantine", "test", 4, 0, 0) == 0)
            let commands = Commands()
            try await withDependencies { $0[AgentCLIProcessClient.self] = commands.client } operation: {
                try await AgentCLIMaintenance.repair(fixture.installation, event: { _ in })
                // Idempotent repair should not attempt to remove an absent attribute.
                try await AgentCLIMaintenance.repair(fixture.installation, event: { _ in })
            }
            let calls = await commands.calls
            #expect(calls.prefix(3).allSatisfy { $0.executable == "/usr/bin/codesign" })
            #expect(calls.prefix(3).allSatisfy { $0.arguments.contains { $0.contains("2DC432GLL2") && $0.contains("identifier") } })
            let cleared = calls.filter { $0.executable == "/usr/bin/xattr" }
            #expect(cleared.compactMap { $0.arguments.last } == fixture.installation.quarantinePaths)
            #expect(cleared.allSatisfy { !$0.arguments.contains("-r") })
            #expect(getxattr(unrelated.path, "com.apple.quarantine", nil, 0, 0, 0) == 4)
        }

        @Test("A rejected helper signature leaves every quarantine attribute intact")
        func failedSignature() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let commands = Commands(failedSignature: fixture.installation.signedTools.last?.path)
            await withDependencies { $0[AgentCLIProcessClient.self] = commands.client } operation: {
                await #expect(throws: AgentCLIError.self) {
                    try await AgentCLIMaintenance.repair(fixture.installation, event: { _ in })
                }
            }
            #expect(await commands.calls.count == 3)
            for path in fixture.installation.quarantinePaths {
                #expect(getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0)
            }
        }

        @Test("System codesign actually rejects an unsigned executable without clearing quarantine")
        func realSignatureRejection() async throws {
            let fixture = try Fixture(agent: .claudeCode, cask: nil)
            defer { fixture.remove() }
            await withDependencies {
                $0[AgentCLIProcessClient.self] = .liveValue
                $0[LoginShellPath.self].resolve = { "/usr/bin:/bin" }
            } operation: {
                await #expect(throws: AgentCLIError.self) {
                    try await AgentCLIMaintenance.repair(fixture.installation, event: { _ in })
                }
            }
            #expect(getxattr(fixture.installation.binaryPath, "com.apple.quarantine", nil, 0, 0, 0) >= 0)
        }

        @Test("Changed launchers and escaped helpers fail before any command executes", arguments: [false, true])
        func changedInstallation(helper: Bool) async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let other = fixture.root.appendingPathComponent("other")
            try Fixture.writeExecutable(other)
            let replaced = helper ? fixture.installation.signedTools[1].path : fixture.installation.launcherPath
            try FileManager.default.removeItem(atPath: replaced)
            try FileManager.default.createSymbolicLink(atPath: replaced, withDestinationPath: other.path)
            let commands = Commands()
            await withDependencies { $0[AgentCLIProcessClient.self] = commands.client } operation: {
                await #expect(throws: AgentCLIError.self) {
                    try await AgentCLIMaintenance.perform(.update, installation: fixture.installation, event: { _ in })
                }
            }
            #expect(await commands.calls.isEmpty)
        }

        @Test("Custom scripts and direct version paths are not treated as managed installations")
        func customInstallation() throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            #expect(AgentCLIManagedInstallation.discover(.codex, launcherPath: fixture.installation.binaryPath, brewPrefixes: [fixture.root.path]) == nil)
            let custom = fixture.root.appendingPathComponent("codex")
            try Fixture.writeExecutable(custom)
            #expect(AgentCLIManagedInstallation.discover(.codex, launcherPath: custom.path, brewPrefixes: [fixture.root.path]) == nil)
        }
    }
#endif
