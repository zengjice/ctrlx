import AppKit
import CtrlxCommon
import Dependencies
import Synchronization
import Testing
@testable import CtrlxServerFeature

@Suite(.serialized)
@MainActor
struct BrowserDiagnosticsTests {
    @Test
    func settingDefaultsOffPersistsAndControlsCollectionImmediately() throws {
        let preferences = PreferencesService.inMemory()
        let reports = Mutex<[Data]>([])
        try withDependencies {
            $0[PreferencesService.self] = preferences
            $0[BrowserDiagnosticStore.self].append = { data in reports.withLock { $0.append(data) } }
            $0[BrowserDiagnosticStore.self].memory = { [:] }
        } operation: {
            let settings = AppSettings()
            let recorder = AppKitDiagnostics(windows: { [] })
            recorder.bind(to: settings)
            #expect(!settings.debugModeEnabled)
            #expect(HostPerformanceMetrics.shared.begin() == nil)
            recorder.recordBrowserDiagnostic(["event": "recording-start"])
            #expect(reports.withLock { $0.isEmpty })

            settings.debugModeEnabled = true
            #expect(HostPerformanceMetrics.shared.begin() != nil)
            recorder.recordBrowserDiagnostic(["event": "recording-progress"])
            #expect(AppSettings().debugModeEnabled)
            settings.debugModeEnabled = false
            #expect(HostPerformanceMetrics.shared.begin() == nil)
            let count = reports.withLock { $0.count }
            recorder.recordBrowserDiagnostic(["event": "recording-finished"])
            #expect(reports.withLock { $0.count } == count)
            #expect(!AppSettings().debugModeEnabled)
            let events = try reports.withLock { $0 }.map { data in
                let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                return (report["browser"] as? [String: Any])?["event"] as? String
            }
            #expect(events == ["debug-enabled", "recording-progress", "debug-disabled"])

            settings.debugModeEnabled = true
            let reloaded = AppSettings()
            let fresh = AppKitDiagnostics(windows: { [] })
            fresh.bind(to: reloaded)
            #expect(reports.withLock { $0.count } == count + 2)
            fresh.setDebugMode(false)
            recorder.setDebugMode(false)
        }
    }

    @Test
    func failedWritesStopUntilTheUserTogglesAgain() {
        let attempts = Mutex(0)
        withDependencies {
            $0[BrowserDiagnosticStore.self].memory = { [:] }
            $0[BrowserDiagnosticStore.self].append = { _ in
                attempts.withLock { $0 += 1 }
                throw CocoaError(.fileWriteNoPermission)
            }
        } operation: {
            let recorder = AppKitDiagnostics(windows: { [] })
            recorder.setDebugMode(true)
            for _ in 0..<10 {
                recorder.recordBrowserDiagnostic(["event": "recording-progress"])
            }
            recorder.setDebugMode(true)
            #expect(attempts.withLock { $0 } == 1)
            recorder.setDebugMode(false)
            recorder.setDebugMode(true)
            #expect(attempts.withLock { $0 } == 2)
            recorder.setDebugMode(false)
        }
    }

    @Test
    func boundedLogRotationPreservesCompleteLinesAndPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-browser-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        // A later invocation appends to the same file; there is no in-memory buffer to lose on a trap.
        for value in 0..<8 {
            try BrowserDiagnosticStore.append(Data("{\"n\":\(value)}".utf8), directory: directory, maximumBytes: 16)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 3)
        for (name, value) in [("current", 6), ("previous", 4), ("older", 2)] {
            let url = directory.appendingPathComponent("browser-\(name).jsonl")
            #expect(try String(contentsOf: url, encoding: .utf8) == "{\"n\":\(value)}\n{\"n\":\(value + 1)}\n")
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        }
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
    }

    @Test
    func storageIsIsolatedAndMemorySampleIsAvailable() throws {
        let home = URL(fileURLWithPath: "/private/test-home")
        #expect(try BrowserDiagnosticStore.directory(arguments: [], home: home).path == "/private/test-home/Library/Logs/CtrlX/Browser")
        #expect(throws: CocoaError.self) {
            try BrowserDiagnosticStore.directory(arguments: ["--e2e-test"], home: home)
        }
        #expect(try BrowserDiagnosticStore.directory(arguments: ["--e2e-test", "--ctrlx-state-root", "/private/fixture"], home: home).path == "/private/fixture/browser-diagnostics")
        #expect((BrowserDiagnosticStore.liveValue.memory()["residentBytes"] ?? 0) > 0)
    }

    @Test
    func periodicSnapshotContainsCachedContextButNoWindowContent() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let secret = "PRIVATE-TITLE-DRAFT-URL"
        window.title = secret
        window.contentView = NSTextField(labelWithString: secret)
        let reports = Mutex<[Data]>([])
        try withDependencies {
            $0[BrowserDiagnosticStore.self].append = { data in reports.withLock { $0.append(data) } }
            $0[BrowserDiagnosticStore.self].memory = { ["residentBytes": 123] }
        } operation: {
            let recorder = AppKitDiagnostics(windows: { [window] })
            recorder.setContext(.init(
                kind: .main,
                connection: .error(secret),
                paired: true,
                remote: false,
                split: true,
                browserSelected: false,
                orderedTabCount: 4,
                browserTabCount: 1
            ), for: window)
            recorder.setDebugMode(true)
            recorder.recordBrowserDiagnostic(["event": "recording-progress", "frames": 23])
            let data = try #require(reports.withLock { $0.last })
            #expect(!String(decoding: data, as: UTF8.self).contains(secret))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((json["memory"] as? [String: Int])?["residentBytes"] == 123)
            let windows = try #require(json["windows"] as? [[String: Any]])
            let context = try #require(windows.first?["context"] as? [String: Any])
            #expect(context["orderedTabCount"] as? Int == 4)
            #expect(context["browserSelected"] as? Bool == false)
            recorder.setDebugMode(false)
        }
    }
}
