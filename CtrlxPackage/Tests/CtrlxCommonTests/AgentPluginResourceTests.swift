import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@Suite("Agent plugin resource versions")
struct AgentPluginResourceTests {
    @Test("Only known numeric installed versions trigger an update")
    func comparison() {
        #expect(AgentPluginResourceClient.updateAvailable(installed: "1.9.0", bundled: "1.10.0"))
        for installed in [nil, "", "unknown", "1.2-beta", "1.10.0", "2.0.0"] {
            #expect(!AgentPluginResourceClient.updateAvailable(installed: installed, bundled: "1.10.0"))
        }
        #expect(!AgentPluginResourceClient.updateAvailable(installed: "1.0.0", bundled: "unknown"))
        #expect(AgentPluginResourceClient.updateAvailable(installed: "1.10.0", bundled: "1.10.0 + hooks 1.0.0"))
        #expect(AgentPluginResourceClient.updateAvailable(installed: "1.10.0 + hooks 1.0.0", bundled: "1.10.0 + hooks 1.1.0"))
        #expect(AgentPluginResourceClient.updateAvailable(installed: "1.9.0 + hooks 1.1.0", bundled: "1.10.0 + hooks 1.0.0"))
        #expect(!AgentPluginResourceClient.updateAvailable(installed: "1.10.0 + hooks 1.1.0", bundled: "1.10.0 + hooks 1.0.0"))
        #expect(!AgentPluginResourceClient.updateAvailable(installed: "unknown + hooks 1.0.0", bundled: "1.10.0 + hooks 1.1.0"))
        for hooks in ["1.0.0", nil] {
            let partial = AgentPluginResourceClient.hooksOnlyVersion(hooks)
            #expect(AgentPluginResourceClient.hooksVersionIfSkillsMissing(partial) == (hooks ?? "unknown"))
            #expect(AgentPluginResourceClient.updateAvailable(installed: partial, bundled: "1.10.0 + hooks 1.0.0"))
        }
        #expect(!AgentPluginResourceClient.updateAvailable(installed: "missing + hooks invalid", bundled: "1.10.0 + hooks 1.0.0"))
        #expect(AgentPluginResourceClient.hooksVersionIfSkillsMissing("1.10.0 + hooks 1.0.0") == nil)
    }

    @Test("Read the Agent manifest version, reject missing or invalid resources")
    func manifest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("plugin.json")
        try Data(#"{"name":"ctrlx","version":"1.2.3"}"#.utf8).write(to: manifest)
        #expect(try await AgentPluginResourceClient.liveValue.version(manifest) == "1.2.3")
        try Data(#"{"name":"ctrlx-hooks","version":"1.0.0"}"#.utf8).write(to: manifest)
        #expect(try await AgentPluginResourceClient.liveValue.version(manifest) == "1.0.0")
        try Data(#"{"name":"another-plugin","version":"1.2.3"}"#.utf8).write(to: manifest)
        await #expect(throws: (any Error).self) { _ = try await AgentPluginResourceClient.liveValue.version(manifest) }
        await #expect(throws: (any Error).self) { _ = try await AgentPluginResourceClient.liveValue.version(directory.appendingPathComponent("missing.json")) }
    }

    @Test("SessionStart resolves current Host skills without modifying either plugin")
    func sessionSkillsPointer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state")
        for name in ["old bundle", "new bundle"] {
            let skills = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: skills.appendingPathComponent("file-links"), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: skills.appendingPathComponent("file-links/SKILL.md"))
            try await AgentPluginResourceClient.liveValue.publishSessionSkills(skills, state)
            #expect(try String(contentsOf: state.appendingPathComponent("session-skills-root"), encoding: .utf8) == skills.path)
        }
        await #expect(throws: (any Error).self) {
            try await AgentPluginResourceClient.liveValue.publishSessionSkills(directory.appendingPathComponent("missing"), state)
        }
        #expect(try String(contentsOf: state.appendingPathComponent("session-skills-root"), encoding: .utf8) == directory.appendingPathComponent("new bundle").path)
    }
}
