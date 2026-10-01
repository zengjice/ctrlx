import Dependencies
import Foundation
import Testing
@testable import CtrlxCLI

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

    @Test func everyInvocationPinsTheSameProviderAndLaunchFlags() throws {
        let base = try ManagedAgentBrowser.baseArguments(root: URL(fileURLWithPath: "/fixture"))
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
                      ["inspect"], ["stream", "enable"], ["dashboard", "start"],
                      ["network", "har", "stop", "/existing"], ["pdf", "/existing"], ["screenshot", "/existing"],
                      ["diff", "url"], ["diff", "snapshot", "--baseline"],
                      ["keydown", "Control+v"], ["keydown", "Meta"], ["press", "Meta+C"]] {
            #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserPageCommand.validate(words) }
        }
    }

    @Test func screenshotOptionsAreParsedWithoutUpstreamPathHeuristics() throws {
        let plan = try AgentBrowserPageCommand.screenshotPlan(["screenshot", "--selector", "div[data-x='/']", "--format", "jpeg", "--quality", "80", "--if-changed"])
        #expect(plan.arguments == ["screenshot", "div[data-x='/']", "--if-changed"])
        #expect(plan.flags == ["--screenshot-format", "jpeg", "--screenshot-quality", "80"])
        #expect(AgentBrowserPageCommand.artifactExtension(["screenshot", "--selector", "jpeg"]) == "png")
        for words in [["screenshot", "--format", "gif"], ["screenshot", "--threshold", "nan"],
                      ["screenshot", "--quality", "101"], ["screenshot", "--quality", "10"],
                      ["screenshot", "--selector"], ["screenshot", "--format", "--provider"],
                      ["screenshot", "--format", "png", "--format", "jpeg"]] {
            #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserPageCommand.validate(words) }
        }
    }

    @Test func boundedBatchAndNewCapabilities() throws {
        try AgentBrowserPageCommand.validateBatch([["fill", "#text", "--provider"], ["get", "title"]])
        for steps in [[], [["get", "title"], ["close"]], [["screenshot"]], Array(repeating: ["get", "title"], count: 33)] {
            #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserPageCommand.validateBatch(steps) }
        }
        for words in [["diff", "snapshot", "--baseline", "/tmp/fixture"], ["diff", "screenshot", "--baseline", "/tmp/b.png"],
                      ["diff", "url", "https://a.test", "https://b.test"], ["react", "inspect", "1"],
                      ["react", "renders", "start"], ["webmcp", "invoke", "tool", "--params", "{}"]] {
            try AgentBrowserPageCommand.validate(words)
        }
        for words in [["diff", "url", "file:///private", "https://b.test"], ["diff", "screenshot"],
                      ["diff", "snapshot", "--output", "/file"], ["webmcp", "invoke", "tool", "--params", "@/file"]] {
            #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserPageCommand.validate(words) }
        }
    }

    @Test func baselineReadsAreBoundedRegularFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("text")
        try Data("baseline".utf8).write(to: file)
        #expect(try ManagedAgentBrowser.readBaseline(file.path, image: false) == Data("baseline".utf8))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        for path in [root.path, link.path] {
            #expect(throws: AgentBrowserTransport.Failure.self) { try ManagedAgentBrowser.readBaseline(path, image: false) }
        }
        #expect(throws: AgentBrowserTransport.Failure.self) { try ManagedAgentBrowser.readBaseline(file.path, image: true) }
        try Data().write(to: file)
        #expect(try ManagedAgentBrowser.readBaseline(file.path, image: false).isEmpty)
        var header = Data([137, 80, 78, 71, 13, 10, 26, 10] + Array(repeating: UInt8(0), count: 8))
        header.append(contentsOf: [0, 1, 0, 0, 0, 1, 0, 0])
        try header.write(to: file)
        #expect(throws: AgentBrowserTransport.Failure.self) { try ManagedAgentBrowser.readBaseline(file.path, image: true) }
    }

    @Test func requestDetailAndHARContentModes() throws {
        try AgentBrowserPageCommand.validate(["network", "request", "123.4"])
        for mode in ["all", "text", "none"] {
            let words = ["network", "har", "start", "--content", mode]
            try AgentBrowserPageCommand.validate(words)
            #expect(AgentBrowserPageCommand.artifactExtension(words) == nil)
        }
        for words in [["network", "request"], ["network", "request", ""],
                      ["network", "request", "123", "extra"],
                      ["network", "har", "start", "--content"],
                      ["network", "har", "start", "--content", "bad"],
                      ["network", "har", "stop", "--content", "all"],
                      ["network", "har", "start", "--content", "all", "--content", "none"]] {
            #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserPageCommand.validate(words) }
        }
    }

    @Test func boundedLiteralCommandInput() throws {
        let script = "window.proof = '中文';\n'--provider'"
        #expect(try AgentBrowserPageCommand.withInput(["eval"], data: Data(script.utf8)) == ["eval", script])
        let params = #"{"message":"--provider"}"#
        #expect(try AgentBrowserPageCommand.withInput(["webmcp", "invoke", "tool", "--detach"], data: Data(params.utf8)) == ["webmcp", "invoke", "tool", "--detach", "--params", params])
        for words in [["eval", "1"], ["get", "title"], ["webmcp", "invoke", "tool", "--params", "{}"]] {
            #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserPageCommand.withInput(words, data: Data("{}".utf8)) }
        }
        for data in [Data([0xff]), Data(repeating: 65, count: 48001), Data([0])] {
            #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserPageCommand.withInput(["eval"], data: data) }
        }
        for params in ["[]", "null", "not json"] {
            #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserPageCommand.withInput(["webmcp", "invoke", "tool"], data: Data(params.utf8)) }
        }
    }

    @Test func urlScreenshotDiffOptionsAndArtifactContract() throws {
        let words = ["diff", "url", "https://a.test", "https://b.test", "--screenshot", "--selector", "#box", "--full", "--depth", "3", "--wait-until", "domcontentloaded"]
        try AgentBrowserPageCommand.validate(words)
        let plan = try AgentBrowserPageCommand.urlScreenshotPlan(words)
        #expect(plan.wait == "domcontentloaded")
        #expect(plan.snapshot == ["snapshot", "--selector", "#box", "--depth", "3"])
        #expect(plan.screenshot == ["screenshot", "--selector", "#box", "--full"])
        #expect(AgentBrowserPageCommand.artifactExtension(words) == "png")
        for suffix in [["--wait-until", "invalid"], ["--selector"], ["--depth", "-1"], ["--provider", "other"], ["--screenshot"]] {
            #expect(throws: AgentBrowserTransport.Failure.self) {
                try AgentBrowserPageCommand.validate(Array(words.prefix(5)) + suffix)
            }
        }
        #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserPageCommand.validateBatch([words]) }
    }

    @Test func recordingFormatsAndRatesAreValidatedBeforeEngineUse() throws {
        for format in ["webm", "mp4"] {
            for fps in [1, 10, 60] { try AgentBrowserPageCommand.validateRecording(format: format, fps: fps) }
        }
        for fps in [0, -1, 61] {
            #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserPageCommand.validateRecording(format: "mp4", fps: fps) }
        }
        #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserPageCommand.validateRecording(format: "../escape", fps: 10) }
        let webm = Data([0x1A, 0x45, 0xDF, 0xA3])
        let mp4 = Data([0, 0, 0, 24]) + Data("ftypisom".utf8)
        #expect(AgentBrowserPageCommand.isRecording(webm, format: "webm"))
        #expect(AgentBrowserPageCommand.isRecording(mp4, format: "mp4"))
        #expect(!AgentBrowserPageCommand.isRecording(webm, format: "mp4"))
        #expect(!AgentBrowserPageCommand.isRecording(mp4, format: "webm"))
        #expect(!AgentBrowserPageCommand.isRecording(Data(), format: "mp4"))
    }

    @Test func setupFlagsAreExplicitAndPathsStayInsidePrivateRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let script = UUID().uuidString + ".js"
        let setup = root.appendingPathComponent("setup.json")
        try AgentBrowserTransport.writePrivateJSON(["react": true, "scripts": [script]], to: setup)
        let arguments = try ManagedAgentBrowser.baseArguments(root: root)
        #expect(arguments.suffix(4) == ["--enable", "react-devtools", "--init-script", root.appendingPathComponent(script).path])
        try AgentBrowserTransport.writePrivateJSON(["scripts": ["../escape.js"]], to: setup)
        #expect(throws: AgentBrowserTransport.Failure.self) { try ManagedAgentBrowser.baseArguments(root: root) }
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
