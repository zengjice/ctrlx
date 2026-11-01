import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

struct AgentResumeExecutableTests {
    #if os(macOS)
        @Test("A removed CLI resolves from Homebrew when login-shell PATH fails and the GUI PATH is minimal", arguments: [nil, ""] as [String?])
        func minimalGUIPath(resolvedPath: String?) async throws {
            try await withDependencies {
                $0[LoginShellPath.self].resolve = { resolvedPath }
            } operation: {
                let client = AgentResumeExecutableClient.live(inheritedPath: "/usr/bin:/bin:/usr/sbin:/sbin", isExecutable: {
                    $0 == "/opt/homebrew/bin/codex"
                })
                let resolved = try await client.resolve("/removed/version/codex", "codex")
                #expect(resolved == "/opt/homebrew/bin/codex")
                await #expect(throws: ProcessRunnerError.self) { try await client.resolve("/removed/version/codex", "missing-agent") }
            }
        }
    #endif

    @Test("Removed versioned binaries fall back only to the configured executable")
    func replacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old-agent")
        let replacement = directory.appendingPathComponent("agent")
        for file in [old, replacement] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let client = AgentResumeExecutableClient.liveValue
        #expect(try await client.resolve(old.path, replacement.path) == old.path)
        try FileManager.default.removeItem(at: old)
        #expect(try await client.resolve(old.path, replacement.path) == replacement.path)
        #if os(macOS)
            try await withDependencies {
                $0[LoginShellPath.self].resolve = { directory.path }
            } operation: {
                let resolved = try await client.resolve(old.path, "agent")
                #expect(resolved == replacement.path)
                await #expect(throws: ProcessRunnerError.self) { try await client.resolve(old.path, "missing") }
            }
        #endif
        await #expect(throws: ProcessRunnerError.self) { try await client.resolve(old.path, directory.appendingPathComponent("missing").path) }
    }
}
