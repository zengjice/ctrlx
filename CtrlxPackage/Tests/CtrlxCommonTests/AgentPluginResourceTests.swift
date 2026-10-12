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
    }

    @Test("Read the Agent manifest version, reject missing or invalid resources")
    func manifest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("plugin.json")
        try Data(#"{"name":"ctrlx","version":"1.2.3"}"#.utf8).write(to: manifest)
        #expect(try await AgentPluginResourceClient.liveValue.version(manifest) == "1.2.3")
        try Data(#"{"name":"another-plugin","version":"1.2.3"}"#.utf8).write(to: manifest)
        await #expect(throws: (any Error).self) { _ = try await AgentPluginResourceClient.liveValue.version(manifest) }
        await #expect(throws: (any Error).self) { _ = try await AgentPluginResourceClient.liveValue.version(directory.appendingPathComponent("missing.json")) }
    }
}
