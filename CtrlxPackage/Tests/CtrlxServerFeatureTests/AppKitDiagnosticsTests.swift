import AppKit
import Dependencies
import Synchronization
import Testing
@testable import CtrlxServerFeature

@Suite(.serialized)
@MainActor
struct AppKitDiagnosticsTests {
    @Test
    func snapshotContainsGeometryAndContextWithoutInspectingContentOrRelayout() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let secret = "PRIVATE-TITLE-DRAFT-URL-ERROR"
        window.title = secret
        let view = LayoutCountingView(frame: CGRect(x: 0, y: 0, width: 108, height: 24))
        view.identifier = .init(secret)
        view.toolTip = secret
        view.addSubview(NSTextField(labelWithString: secret))
        let constraint = view.widthAnchor.constraint(greaterThanOrEqualToConstant: 100)
        constraint.identifier = secret
        constraint.isActive = true
        let item = NSToolbarItem(itemIdentifier: .init("ctrlx.toolbar.connection"))
        item.label = secret
        item.view = view
        let delegate = ToolbarFixture(item: item)
        let toolbar = NSToolbar(identifier: "diagnostic-test")
        toolbar.delegate = delegate
        window.toolbar = toolbar
        let recorder = AppKitDiagnostics(windows: { [window] })
        recorder.setContext(.init(kind: .detached, connection: .error(secret), paired: true, remote: true), for: window)
        let before = view.layoutCalls

        let report = recorder.snapshot(exceptionName: "NSGenericException", stack: ["_postWindowNeedsUpdateConstraints"])
        let data = try JSONSerialization.data(withJSONObject: report)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains(secret))
        #expect(view.layoutCalls == before)
        let windows = try #require(report["windows"] as? [[String: Any]])
        let context = try #require(windows.first?["context"] as? NSDictionary)
        #expect(context["kind"] as? String == "detached")
        #expect(context["toolbarConnection"] as? String == "error")
        #expect(context["remoteSelection"] as? Bool == true)
        let items = try #require(windows.first?["items"] as? [[String: Any]])
        #expect(items.first?["identifier"] as? String == "ctrlx.toolbar.connection")
        let views = try #require(items.first?["views"] as? [[String: Any]])
        #expect(views.first?["frame"] as? String == NSStringFromRect(view.frame))
        #expect((views.first?["constraints"] as? [[String: Any]])?.isEmpty == false)

        recorder.setContext(.init(kind: .main, connection: .reconnecting(attempt: 3), paired: false, remote: false), for: window)
        let updated = recorder.snapshot(exceptionName: "test", stack: [])["windows"] as? [[String: Any]]
        #expect((updated?.first?["context"] as? NSDictionary)?["toolbarConnection"] as? String == "reconnecting")
        recorder.setContext(nil, for: window)
        let cleared = recorder.snapshot(exceptionName: "test", stack: [])["windows"] as? [[String: Any]]
        #expect((cleared?.first?["context"] as? NSDictionary)?["kind"] as? String == "other")
    }

    @Test
    func recordsFirstLayoutExceptionSynchronouslyAndIgnoresOtherExceptions() throws {
        let reports = Mutex<[Data]>([])
        try withDependencies {
            $0[AppKitDiagnosticStore.self].write = { data in
                reports.withLock { $0.append(data) }
                return URL(fileURLWithPath: "/private-test/report.json")
            }
        } operation: {
            let recorder = AppKitDiagnostics(windows: { [] })
            recorder.recordAppKitException(NSException(name: .invalidArgumentException, reason: "private", userInfo: nil))
            #expect(reports.withLock { $0.isEmpty })
            recorder.recordAppKitException(LayoutException(name: .genericException, reason: "private", userInfo: nil))
            #expect(reports.withLock { $0.count } == 1)
            recorder.recordAppKitException(LayoutException(name: .genericException, reason: "private", userInfo: nil))
            #expect(reports.withLock { $0.count } == 1)
            let report = try JSONSerialization.jsonObject(with: #require(reports.withLock { $0.first })) as? [String: Any]
            #expect(report?["exceptionName"] as? String == "NSGenericException")
        }
    }

    @Test
    func failedWriteReturnsWithoutRetryingDuringTheSameLayoutLoop() {
        let attempts = Mutex(0)
        withDependencies {
            $0[AppKitDiagnosticStore.self].write = { _ in
                attempts.withLock { $0 += 1 }
                throw CocoaError(.fileWriteNoPermission)
            }
        } operation: {
            let recorder = AppKitDiagnostics(windows: { [] })
            let exception = LayoutException(name: .genericException, reason: nil, userInfo: nil)
            recorder.recordAppKitException(exception)
            recorder.recordAppKitException(exception)
            #expect(attempts.withLock { $0 } == 1)
        }
    }

    @Test
    func privateStorageAndRetentionKeepTheNewestReportAndUnrelatedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-appkit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for index in 0..<8 {
            try Data("old".utf8).write(to: directory.appendingPathComponent("appkit-000\(index)-test.json"))
        }
        let unrelated = directory.appendingPathComponent("keep.json")
        try Data("keep".utf8).write(to: unrelated)
        let folder = directory.appendingPathComponent("appkit-folder.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var latest: URL?
        for _ in 0..<8 {
            latest = try AppKitDiagnosticStore.save(Data("new".utf8), directory: directory)
        }
        let output = try #require(latest)
        #expect(try Data(contentsOf: output) == Data("new".utf8))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 7) // Five reports, the unrelated file, and the unrelated directory.
        #expect(files.map(\.lastPathComponent).contains(unrelated.lastPathComponent))
        #expect(files.map(\.lastPathComponent).contains(folder.lastPathComponent))
        let permissions = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test
    func e2eStorageNeverFallsBackToTheUsersLogs() throws {
        let home = URL(fileURLWithPath: "/home/private")
        #expect(try AppKitDiagnosticStore.directory(arguments: [], home: home).path == "/home/private/Library/Logs/CtrlX/AppKit")
        #expect(try AppKitDiagnosticStore.directory(arguments: ["--e2e-test", "--ctrlx-state-root", "/tmp/fixture"], home: home).path == "/tmp/fixture/appkit-diagnostics")
        #expect(throws: CocoaError.self) {
            try AppKitDiagnosticStore.directory(arguments: ["--e2e-test"], home: home)
        }
    }
}

final private class LayoutException: NSException, @unchecked Sendable {
    override var callStackSymbols: [String] {
        ["AppKit -[NSWindow _postWindowNeedsUpdateConstraints]", "AppKit -[NSToolbarItemViewer layout]"]
    }
}

@MainActor
final private class LayoutCountingView: NSView {
    var layoutCalls = 0
    override func layout() {
        layoutCalls += 1
        super.layout()
    }

    override func updateConstraints() {
        layoutCalls += 1
        super.updateConstraints()
    }

    override var intrinsicContentSize: NSSize {
        layoutCalls += 1
        return super.intrinsicContentSize
    }
}

@MainActor
final private class ToolbarFixture: NSObject, NSToolbarDelegate {
    let item: NSToolbarItem
    init(item: NSToolbarItem) {
        self.item = item
    }

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [item.itemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [item.itemIdentifier]
    }

    func toolbar(_: NSToolbar, itemForItemIdentifier _: NSToolbarItem.Identifier, willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem? {
        item
    }
}
