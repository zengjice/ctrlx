import Dependencies
import Foundation
import Testing
@testable import GallagerCLI

struct AgentBrowserEngineTests {
    @Test func defaultsToVercelAndPreservesSavedAndExplicitChoices() throws {
        #expect(try AgentBrowserEngine.resolve(nil, saved: nil) == .vercel)
        #expect(try AgentBrowserEngine.resolve(nil, saved: "ctrlx") == .ctrlx)
        #expect(try AgentBrowserEngine.resolve(nil, saved: "vercel") == .vercel)
        #expect(try AgentBrowserEngine.resolve("vercel", saved: "ctrlx") == .vercel)
        #expect(try AgentBrowserEngine.resolve("ctrlx", saved: "vercel") == .ctrlx)
        #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserEngine.resolve("chrome", saved: nil) }
        #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserEngine.resolve(nil, saved: "invalid") }
    }

    @Test func mapsWithoutShellOrGlobalFlagPassthrough() throws {
        let text = "中文 ' \" $(touch /tmp/not-executed)\nsecond line"
        #expect(try AgentBrowserEngine.upstreamArguments(["command": "fill", "selector": "#x", "text": text]) == ["fill", "#x", text])
        #expect(try AgentBrowserEngine.upstreamArguments(["command": "snapshot"]) == ["snapshot", "-i"])
        #expect(try AgentBrowserEngine.upstreamArguments(["command": "click", "selector": "@e2"]) == ["click", "@e2"])
        #expect(try AgentBrowserEngine.upstreamArguments(["command": "check", "selector": "#x", "checked": false]) == ["uncheck", "#x"])
        #expect(try AgentBrowserEngine.upstreamArguments(["command": "select", "selector": "#x", "value": "one"]) == ["select", "#x", "one"])
        #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserEngine.upstreamArguments(["command": "eval", "text": "1"]) }
        #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserEngine.upstreamArguments(["command": "fill", "selector": "#x", "text": String(repeating: "x", count: 16001)]) }
        #expect(try AgentBrowserEngine.upstreamArguments(["command": "fill", "selector": "#x", "text": "--provider"]) == ["fill", "#x", "--provider"])
        #expect(try AgentBrowserEngine.upstreamArguments(["command": "fill", "selector": "#x", "text": ""]) == ["fill", "#x", ""])
    }

    @Test(arguments: ["Meta+C", "Control+V", "Meta+L", "F12", "a", "Meta+Shift+A", "Shift+", "Bad+Tab"])
    func blocksBrowserClipboardAndUnrecognizedKeys(_ key: String) {
        #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserEngine.upstreamArguments(["command": "press", "key": key]) }
    }

    @Test(arguments: ["Enter", "Shift+Tab", "ArrowLeft", "Meta+A"])
    func acceptsPageKeys(_ key: String) throws {
        #expect(try AgentBrowserEngine.upstreamArguments(["command": "press", "key": key]) == ["press", key])
    }

    @Test func explicitCompatibilityBoundaries() {
        #expect(AgentBrowserEngine.shared.contains("read"))
        #expect(AgentBrowserEngine.shared.contains("close"))
        #expect(!AgentBrowserEngine.shared.contains("click"))
        #expect(!AgentBrowserEngine.shared.contains("snapshot"))
        #expect(throws: AgentBrowserTransport.Failure.self) {
            try AgentBrowserEngine.upstreamArguments(["command": "press", "key": "Tab", "selector": "#x"])
        }
    }

    @Test func privateEnvironmentUsesOnlyManagedProviderAndPaths() throws {
        let root = URL(fileURLWithPath: "/tmp/fixture")
        let env = try ManagedAgentBrowser.environment(root: root, provider: root.appendingPathComponent("provider.json"), cli: URL(fileURLWithPath: "/fixture/CtrlXCLI"))
        #expect(env["AGENT_BROWSER_SOCKET_DIR"] == root.path)
        #expect(env["AGENT_BROWSER_CDP"] == nil)
        #expect(env["AGENT_BROWSER_AUTO_CONNECT"] == nil)
        #expect(env["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(env["OPENAI_API_KEY"] == nil)
        let encoded = try #require(env["AGENT_BROWSER_PLUGINS"])
        let decoded = try JSONSerialization.jsonObject(with: Data(encoded.utf8))
        let plugins = try #require(decoded as? [[String: Any]])
        #expect(plugins.count == 1)
        #expect(plugins[0]["command"] as? String == "/fixture/CtrlXCLI")
        #expect(plugins[0]["args"] as? [String] == ["browser", "engine-provider"])
    }

    @Test func everyInvocationPinsTheSameProviderAndLaunchFlags() {
        let base = ManagedAgentBrowser.baseArguments(root: URL(fileURLWithPath: "/fixture"))
        #expect(base == ["--config", "/fixture/config.json", "--session", "page", "--json",
                         "--provider", "ctrlx", "--no-webmcp"])
    }

    @Test func processFailureDoesNotRetryOrLeakUpstreamError() throws {
        let root = URL(fileURLWithPath: "/fixture")
        withDependencies {
            $0[AgentBrowserEngineProcessClient.self].run = { _, _, _, _, _ in
                Data(#"{"success":false,"error":"secret ws://127.0.0.1:1/private-token"}"#.utf8)
            }
        } operation: {
            do {
                _ = try ManagedAgentBrowser.invoke(binary: root, words: ["click", "#x"], env: [:], root: root)
                Issue.record("Expected failure")
            } catch {
                #expect(!String(describing: error).contains("private-token"))
                #expect(String(describing: error).contains("not retried"))
            }
        }
    }

    @Test func pageCatalogAndBoundary() throws {
        for words in [["get", "title"], ["set", "viewport", "640", "480"], ["network", "requests"],
                      ["frame", "#frame"], ["upload", "#file", "/tmp/example"], ["pdf"], ["cookies", "get"]] {
            try AgentBrowserPageCommand.validate(words)
            #expect(try AgentBrowserEngine.upstreamArguments(["command": "upstream", "words": words]) == words)
        }
        for words in [["connect", "9222"], ["get", "cdp-url"], ["cookies", "clear"], ["state", "save"],
                      ["plugin", "run"], ["batch", "close"], ["record", "start"], ["trace", "start"],
                      ["network", "har", "stop", "/existing"], ["pdf", "/existing"], ["screenshot", "/existing"],
                      ["diff", "url"], ["diff", "snapshot", "--baseline", "/file"],
                      ["keydown", "Control+v"], ["keydown", "Meta"], ["press", "Meta+C"]] {
            #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserPageCommand.validate(words) }
        }
    }

    @Test func batchResultAndLiteralArguments() throws {
        let root = URL(fileURLWithPath: "/fixture")
        let arguments = ["fill", "#text", "'\"\n--provider"]
        try withDependencies {
            $0[AgentBrowserEngineProcessClient.self].run = { _, words, _, _, input in
                #expect(words == ["batch"])
                let data = try #require(input)
                #expect(try JSONSerialization.jsonObject(with: data) as? [[String]] == [arguments])
                return Data(#"[{"success":true,"result":{"proof":true}}]"#.utf8)
            }
        } operation: {
            let value = try ManagedAgentBrowser.invoke(binary: root, words: ["batch"], env: [:], root: root,
                input: JSONSerialization.data(withJSONObject: [arguments]))
            #expect(value["proof"] as? Bool == true)
        }
    }
}
