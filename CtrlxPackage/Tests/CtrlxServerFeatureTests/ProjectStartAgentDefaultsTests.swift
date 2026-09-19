import CtrlxNetworking
import Testing
@testable import CtrlxServerFeature

struct ProjectStartAgentDefaultsTests {
    @Test("Project API defaults to Codex without changing path or launch arguments")
    func defaultsToCodex() async {
        let router = LiveAPIRequestRouter(onProjectStart: { path, args, pluginID in
            #expect(path == "/Host/project")
            #expect(args == ["--resume"])
            return ["plugin_id": .string(pluginID)]
        })
        let response = await router.handleRequest(JSONRPCRequest(id: "default", method: "project.start", params: [
            "path": .string("/Host/project"), "args": .array([.string("--resume")]),
        ]))
        #expect(response.ok)
        #expect(response.result?["plugin_id"]?.stringValue == "codex")
    }

    @Test("Explicit plugin IDs and the legacy agent selector are honored", arguments: ["plugin_id", "agent"])
    func explicitAgent(key: String) async {
        let router = LiveAPIRequestRouter(onProjectStart: { _, _, pluginID in
            ["plugin_id": .string(pluginID)]
        })
        let response = await router.handleRequest(JSONRPCRequest(id: "explicit", method: "project.start", params: [
            "path": .string("/Host/project"), key: .string("claude-code"),
        ]))
        #expect(response.ok)
        #expect(response.result?["plugin_id"]?.stringValue == "claude-code")
    }

    @Test("Explicit plugin_id retains precedence over the legacy agent alias")
    func explicitPrecedence() async {
        let router = LiveAPIRequestRouter(onProjectStart: { _, _, pluginID in
            ["plugin_id": .string(pluginID)]
        })
        let response = await router.handleRequest(JSONRPCRequest(id: "precedence", method: "project.start", params: [
            "path": .string("/Host/project"), "plugin_id": .string("pi"), "agent": .string("claude-code"),
        ]))
        #expect(response.ok)
        #expect(response.result?["plugin_id"]?.stringValue == "pi")
    }
}
