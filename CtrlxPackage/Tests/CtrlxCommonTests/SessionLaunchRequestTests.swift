import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

struct SessionLaunchRequestTests {
    @Test("A custom launch needs no project history and preserves the Host path")
    func customDirectory() {
        let request = SessionLaunchRequest.directory(path: "~/Projects/new project", pluginID: "codex")
        #expect(request.requiresAgentLaunch)
        #expect(request.project?.path == "~/Projects/new project")
        #expect(request.project?.name == "new project")
        #expect(request.project?.pluginID == "codex")
    }

    @Test("Existing project configuration and Terminal semantics are preserved")
    func existingChoices() {
        let project = AgentProject(name: "Test", path: "/Host/Test", configDir: "/config", pluginID: "claude-code")
        #expect(SessionLaunchRequest.project(project).project == project)
        #expect(!SessionLaunchRequest.project(project).requiresAgentLaunch)
        #expect(SessionLaunchRequest.terminal.project == nil)
        #expect(!SessionLaunchRequest.terminal.requiresAgentLaunch)
    }

    @Test("Root and home paths have usable session names", arguments: ["/", "~", "~/"])
    func rootNames(path: String) {
        #expect(SessionLaunchRequest.directory(path: path, pluginID: "codex").project?.name == "session")
    }

    @Test("Invalid input is rejected", arguments: ["", "relative", "~someone/repo", " /repo", "/x\ny", "/x\ry", "/x\u{0}", "/x\ty"])
    func invalidPaths(path: String) {
        #expect(!SessionDirectoryPath.isValid(path))
        #expect(SessionDirectoryPath.expanded(path, hostHome: "/Users/host") == nil)
    }

    @Test("Tilde expansion uses the Host home and preserves literal shell characters")
    func hostExpansion() {
        #expect(SessionDirectoryPath.expanded("~", hostHome: "/Users/host") == "/Users/host")
        #expect(SessionDirectoryPath.expanded("~/Projects/../Other", hostHome: "/Users/host") == "/Users/host/Other")
        #expect(SessionDirectoryPath.expanded("/tmp/a 'b' $(echo x) ", hostHome: "/Users/host") == "/tmp/a 'b' $(echo x) ")
    }
}

@MainActor
struct SessionLaunchAgentTests {
    private func presentation(_ id: String, name: String) -> PluginPresentation {
        PluginPresentation(id: id, version: "1", displayName: name, shortName: name, color: "#ffffff")
    }

    @Test("Agent choices are isolated per target Host, replaced and cleared")
    func hostIsolation() {
        let store = SessionStore()
        store.handlePluginPresentations(.init(pairId: "office", presentations: [presentation("codex", name: "Codex")]))
        store.handlePluginPresentations(.init(pairId: "home", presentations: [presentation("claude-code", name: "Claude Code")]))
        #expect(store.launchAgents(for: "office") == [.init(id: "codex", name: "Codex")])
        #expect(store.launchAgents(for: "home") == [.init(id: "claude-code", name: "Claude Code")])
        #expect(store.launchAgents(for: "unknown").isEmpty)

        store.handlePluginPresentations(.init(pairId: "office", presentations: []))
        #expect(store.launchAgents(for: "office").isEmpty)
        #expect(store.launchAgents(for: "home").count == 1)
        store.clearSessions(for: "home")
        #expect(store.launchAgents(for: "home").isEmpty)
    }

    @Test("Duplicate presentation IDs cannot produce ambiguous Picker rows")
    func deduplicates() {
        let store = SessionStore()
        store.handlePluginPresentations(.init(pairId: "office", presentations: [
            presentation("codex", name: "Old"), presentation("codex", name: "Codex"),
            presentation("claude-code", name: "Claude Code"),
        ]))
        #expect(store.launchAgents(for: "office") == [
            .init(id: "claude-code", name: "Claude Code"), .init(id: "codex", name: "Codex"),
        ])
    }
}
