import AppKit
import ApplicationServices
import CtrlxE2ELib
import CtrlxNetworking
import Foundation
import Testing

/// Opt-in real App acceptance against an operator-created isolated Relay. The
/// private config contains paths/topology, never production credentials.
@Suite(
    "Relay quota App acceptance",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["CTRLX_QUOTA_ACCEPTANCE_CONFIG"] != nil)
)
struct RelayQuotaAppAcceptanceTests {
    private struct Configuration: Decodable {
        let hostApp: String
        let viewerApp: String
        let relayURL: String
        let sshHost: String
        let container: String
        let output: String
        let waitForIOS: Bool?
    }

    private struct Account: Decodable {
        let accountID: String
        let key: String
    }

    @Test("Host and Mac Viewer pair, retain credentials, hit quota and recover against the isolated cloud Relay")
    func applications() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["CTRLX_QUOTA_ACCEPTANCE_CONFIG"])
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try #require(config.container.hasPrefix("ctrlx-relay-quota-"))
        try #require(config.container.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) })
        for app in [config.hostApp, config.viewerApp] {
            try #require(Bundle(path: app)?.bundleIdentifier?.hasPrefix("com.ctrlx.quota-acceptance.") == true)
        }
        let root = URL(fileURLWithPath: "/tmp/cx-rq-" + UUID().uuidString.prefix(8))
        let output = URL(fileURLWithPath: config.output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in ["ios-ready.json", "ios-pairing-code.txt", "ios.done"] {
            let file = output.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
        let host = MacOSDriver(testAccessibilityPort: 28_391, otlpPort: 28_431)
        let viewer = MacOSDriver(testAccessibilityPort: 28_392, otlpPort: 28_432)
        let process = CtrlxE2ELib.ProcessRunner()
        let accountName = "acceptance-" + UUID().uuidString.lowercased()
        let account = try JSONDecoder().decode(Account.self, from: await admin(config, process, ["account", "create", "--name", accountName, "--monthly-quota", "4MiB"]))
        let socket = root.appendingPathComponent("tmux.sock").path
        let viewerSocket = root.appendingPathComponent("viewer.sock").path
        let session = "quota-acceptance"
        var checks: [String] = []

        func tmux(_ args: [String]) async throws -> ProcessResult {
            try await process.runOrThrow("tmux", arguments: ["-S", socket] + args)
        }
        func launch(_ driver: MacOSDriver, app: String, name: String, port: Int, otlp: Int) async throws {
            let state = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try await driver.launchApp(path: app, arguments: [
                "--e2e-test", "--e2e-persistent-storage", "--server-url", config.relayURL,
                "--tmux-socket", name == "host" ? socket : viewerSocket, "--ctrlx-state-root", state.path,
                "--test-accessibility-port", String(port), "--otlp-port", String(otlp),
                "--clipboard-file", state.appendingPathComponent("clipboard").path,
            ])
            let readiness = try #require(URL(string: "http://127.0.0.1:\(port)/otlp-port"))
            try await Polling.waitUntil(description: "isolated App main loop and receiver ready", timeout: 30, pollInterval: 0.25) {
                var request = URLRequest(url: readiness)
                request.timeoutInterval = 1
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    return (response as? HTTPURLResponse)?.statusCode == 200
                } catch {
                    return false
                }
            }
        }
        func settings(_ driver: MacOSDriver, tab: String) async throws {
            try await driver.openSettings()
            try await driver.activate()
            try await driver.cgClick(titled: tab)
        }
        func cleanup() async throws {
            try await viewer.terminateApp()
            try await host.terminateApp()
            _ = try await process.run("tmux", arguments: ["-S", socket, "kill-server"])
            _ = try await process.run("tmux", arguments: ["-S", viewerSocket, "kill-server"])
            _ = try await admin(config, process, ["account", "disable", "--account", account.accountID])
        }

        do {
            _ = try await tmux(["new-session", "-d", "-s", session, "-x", "100", "-y", "28", "/bin/zsh -f"])
            _ = try await process.runOrThrow("tmux", arguments: ["-S", viewerSocket, "new-session", "-d", "-s", "viewer-local-fixture", "/bin/zsh -f"])
            try await launch(host, app: config.hostApp, name: "host", port: 28_391, otlp: 28_431)
            try await settings(host, tab: "Remote Access")
            try await host.cgClick(matching: .identifier("relay-access-key"))
            try await host.setFocusedText(account.key)
            try await host.clickButton(titled: "Save Access Key")
            _ = try await host.waitForElement(matching: .anyTextMatches(accountName), timeout: 15)
            try await host.screenshot(output: output.appendingPathComponent("host-allowance.png").path)
            checks.append("Host saved a verified account key through the native settings UI")

            // A failed edit must leave the previous working credential intact.
            try await host.cgClick(matching: .identifier("relay-access-key"))
            try await host.setFocusedText("invalid-acceptance-key")
            try await host.clickButton(titled: "Save Access Key")
            _ = try await host.waitForElement(matching: .anyTextMatches("Relay credential expired or was revoked"), timeout: 15)
            let storageURL = root.appendingPathComponent("host/e2e-storage.json")
            let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: storageURL)) as? [String: Any])
            let secrets = try #require(saved["secrets"] as? [String: String])
            #expect(secrets.values.contains(account.key))
            #expect(!secrets.values.contains("invalid-acceptance-key"))
            try await host.clickButton(titled: "Check and Reconnect")
            checks.append("Invalid draft key did not replace the saved key")

            try await host.clickButton(titled: "Generate Pairing Code")
            try await host.waitForElement(titled: "Copy Code", timeout: 10)
            try await host.clickButton(titled: "Copy Code")
            let code = try String(contentsOf: root.appendingPathComponent("host/clipboard"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(code.count == 6)
            try await launch(viewer, app: config.viewerApp, name: "viewer", port: 28_392, otlp: 28_432)
            try await settings(viewer, tab: "Remote Hosts")
            try await viewer.clickButton(titled: "Add Host")
            try await viewer.focusElement(titled: "Pairing Code")
            try await viewer.setFocusedText(code)
            try await viewer.cgClick(matching: .allOf([.role("AXButton"), .label("Connect")]))
            try await viewer.waitForElementToDisappear(titled: "Pairing Code", timeout: 20)
            try await host.waitForElement(titled: "Viewer connected", timeout: 20)
            try await viewer.waitForElement(titled: "Host connected", timeout: 20)
            checks.append("Both real Mac apps completed pairing and E2EE over the cloud Relay")

            try await viewer.closeWindow(titled: "Remote Hosts")
            try await viewer.openPanesWindow()
            try await viewer.activate()
            try await viewer.waitForElement(titled: session, timeout: 20)
            try await viewer.clickButton(titled: session)
            _ = try await viewer.waitForElement(matching: .identifier("terminal-%0"), timeout: 20)
            try await viewer.cgClick(matching: .identifier("terminal-%0"))
            try await viewer.type(text: "echo QUOTA_NATIVE_BEFORE", pressReturn: true)
            _ = try await viewer.waitForElement(matching: .allOf([.identifier("terminal-%0"), .valueContains("QUOTA_NATIVE_BEFORE")]), timeout: 20)
            let before = try await tmux(["capture-pane", "-p", "-t", session])
            #expect(before.stdoutString.contains("QUOTA_NATIVE_BEFORE"))
            checks.append("Viewer terminal input reached the private Host tmux session")

            _ = try await tmux(["send-keys", "-t", session, "-l", "python3 -c 'print(\"QUOTA_FILL_1234567890\" * 800000)' "])
            _ = try await tmux(["send-keys", "-t", session, "Enter"])
            try await settings(viewer, tab: "Remote Hosts")
            _ = try await viewer.waitForElement(matching: .anyTextMatches("Add quota"), timeout: 60)
            try await viewer.screenshot(output: output.appendingPathComponent("viewer-quota-limited.png").path)
            checks.append("Native Viewer retained its pairing and displayed the quota restriction")

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let quota = try decoder.decode(RelayQuotaStatus.self, from: await admin(config, process, ["usage", "show", "--account", account.accountID]))
            let topUp = [
                "quota",
                "add",
                "--account",
                account.accountID,
                "--month",
                quota.period,
                "--amount",
                "8MiB",
                "--request-id",
                accountName + "-topup",
                "--reason",
                "acceptance",
            ]
            _ = try await admin(config, process, topUp)
            let after = try decoder.decode(RelayQuotaStatus.self, from: await admin(config, process, topUp))
            #expect(after.extraBytes == 8 * 1_024 * 1_024)
            try await viewer.waitForElement(titled: "Host connected", timeout: 65)
            try await host.waitForElement(titled: "Viewer connected", timeout: 65)
            checks.append("One idempotent cloud top-up automatically restored the real App connections")

            try await viewer.closeWindow(titled: "Remote Hosts")
            try await viewer.openPanesWindow()
            try await viewer.activate()
            try await viewer.clickButton(titled: session)
            _ = try await viewer.waitForElement(matching: .identifier("terminal-%0"), timeout: 20)
            try await viewer.cgClick(matching: .identifier("terminal-%0"))
            try await viewer.type(text: "echo QUOTA_NATIVE_AFTER", pressReturn: true)
            _ = try await viewer.waitForElement(matching: .allOf([.identifier("terminal-%0"), .valueContains("QUOTA_NATIVE_AFTER")]), timeout: 20)
            try await viewer.screenshot(output: output.appendingPathComponent("viewer-recovered-terminal.png").path)
            checks.append("Viewer resubscribed to the terminal snapshot and accepted fresh input after recovery")

            if config.waitForIOS == true {
                try await settings(host, tab: "Remote Access")
                try await host.clickButton(titled: "Add Viewer")
                try await host.waitForElement(titled: "Copy Code", timeout: 10)
                try await host.clickButton(titled: "Copy Code")
                let codeFile = output.appendingPathComponent("ios-pairing-code.txt")
                try Data(contentsOf: root.appendingPathComponent("host/clipboard")).write(to: codeFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: codeFile.path)
                try JSONSerialization.data(withJSONObject: ["accountID": account.accountID, "runtimeRoot": root.path, "tmuxSocket": socket], options: .prettyPrinted)
                    .write(to: output.appendingPathComponent("ios-ready.json"), options: .atomic)
                let done = output.appendingPathComponent("ios.done")
                let deadline = ContinuousClock.now + .seconds(600)
                while !FileManager.default.fileExists(atPath: done.path), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(250))
                }
                try #require(try String(contentsOf: done, encoding: .utf8) == "ready")
                checks.append("Operator completed the companion iOS UI checks against this same isolated Host and account")
            }

            try await cleanup()
            try JSONSerialization.data(withJSONObject: ["checks": checks, "runtimeRoot": root.path, "accountID": account.accountID], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("summary.json"), options: .atomic)
        } catch {
            let diagnostics = await MainActor.run {
                let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.hasPrefix("com.ctrlx.quota-acceptance.") == true }
                var lines = running.map { "\($0.bundleIdentifier ?? "") pid=\($0.processIdentifier) active=\($0.isActive) hidden=\($0.isHidden) policy=\($0.activationPolicy.rawValue)" }
                if let front = NSWorkspace.shared.frontmostApplication {
                    lines.append("frontmost=\(front.bundleIdentifier ?? "") pid=\(front.processIdentifier)")
                }
                var focus: CFTypeRef?
                if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &focus) == .success, let focus {
                    var pid: pid_t = 0
                    AXUIElementGetPid(focus as! AXUIElement, &pid)
                    lines.append("AX focused PID=\(pid)")
                }
                return lines.joined(separator: "\n")
            }
            try diagnostics.write(to: output.appendingPathComponent("activation-diagnostics.txt"), atomically: true, encoding: .utf8)
            if let window = try? await viewer.waitForElement(matching: .role("AXWindow"), timeout: 1) {
                try window.description.write(to: output.appendingPathComponent("viewer-window.txt"), atomically: true, encoding: .utf8)
            }
            try? await host.screenshot(output: output.appendingPathComponent("failure-host.png").path)
            try? await viewer.screenshot(output: output.appendingPathComponent("failure-viewer.png").path)
            try await cleanup()
            throw error
        }
    }

    private func admin(_ config: Configuration, _ process: CtrlxE2ELib.ProcessRunner, _ arguments: [String]) async throws -> Data {
        let result = try await process.runOrThrow("/usr/bin/ssh", arguments: [
            "-o", "BatchMode=yes", config.sshHost, "docker", "exec", config.container,
            "./CtrlxExternalServer", "relay-admin",
        ] + arguments, timeout: 30)
        return result.stdout
    }
}
