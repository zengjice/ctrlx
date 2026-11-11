import AppKit
import CtrlxNetworking
import Dependencies
import SwiftUI
import Testing
@testable import CtrlxCommon
@testable import CtrlxServerFeature

@MainActor @Suite(.serialized)
struct FileBrowserUploadRetentionTests {
    @Test("File and pasted-image uploads survive view replacement and keep their original destination", arguments: [false, true])
    func switchingTabs(image: Bool) async throws {
        try await withFixture(image: image) { fixture in
            let (window, state) = fixture.mount()
            if image {
                try await click("file-browser-paste-image", in: window)
            } else {
                fixture.startFiles()
            }
            try await wait("Upload must reach its gated chunk") { fixture.control.blocked }
            let upload = fixture.tab.uploadSession.upload
            let sent = upload.sentBytes
            state.visible = false
            try await wait("Switching away must remove the upload controls") { element("file-upload-cancel", in: window) == nil }
            try await Task.sleep(for: .milliseconds(100))
            #expect(!fixture.control.cancelled)
            #expect(fixture.tab.uploadSession.isRunning)
            fixture.tab.navigate(fixture.otherDirectory.path)
            fixture.tab.previewSession.evict()
            state.visible = true
            try await wait("Returning must restore the upload controls") { element("file-upload-cancel", in: window) != nil }
            #expect(fixture.tab.uploadSession.upload === upload)
            #expect(upload.sentBytes == sent)
            #expect(fixture.tab.uploadSession.directory == fixture.destination.path)
            #expect(fixture.control.begins == 1)
            state.visible = false
            try await wait("The second switch must remove the upload controls") { element("file-upload-cancel", in: window) == nil }
            fixture.control.finish = true
            try await wait("The hidden upload must finish") { !fixture.tab.uploadSession.isRunning }
            let file = try #require(fixture.control.completed.first)
            #expect(try Data(contentsOf: file) == fixture.control.data)
            #expect(file.deletingLastPathComponent() == fixture.destination)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.otherDirectory.path).isEmpty)
            #expect(fixture.tab.refresh > 1)
            #expect(!fixture.control.cancelled && fixture.control.begins == 1)
            if !image {
                #expect(fixture.control.closedReaders == 1)
            }
            state.visible = true
            try await wait("Returning after completion must show the upload summary") { element("file-upload-summary", in: window) != nil }
            #expect(fixture.tab.uploadSession.upload.summary == (image ? "Image saved." : "1 file(s) saved."))
            #expect(fixture.control.begins == 1)
        }
    }

    @Test("Cancel keeps the upload slot until cleanup and a retry starts only once", arguments: [false, true])
    func cancelAndRetry(image: Bool) async throws {
        try await withFixture(image: image) { fixture in
            let (window, _) = fixture.mount()
            if image {
                try await click("file-browser-paste-image", in: window)
            } else {
                fixture.startFiles()
            }
            try await wait { fixture.control.blocked }
            fixture.control.cleanupHeld = true
            try await click("file-upload-cancel", in: window)
            try await wait { fixture.control.cancelled }
            #expect(fixture.tab.uploadSession.isRunning)
            fixture.startFiles()
            #expect(fixture.control.begins == 1)
            fixture.control.cleanupHeld = false
            try await wait { !fixture.tab.uploadSession.isRunning }
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
            #expect(fixture.tab.uploadSession.upload.summary?.contains("cancelled") == true)
            fixture.control.finish = true
            if image {
                try await click("file-browser-paste-image", in: window)
            } else {
                fixture.startFiles()
            }
            try await wait { !fixture.tab.uploadSession.isRunning }
            #expect(fixture.control.completed.count == 1 && fixture.control.begins == 2)
            #expect(try Data(contentsOf: #require(fixture.control.completed.first)) == fixture.control.data)
            if !image {
                #expect(fixture.control.closedReaders == 2)
            }
        }
    }

    @Test("Closing or changing the source cancels hidden uploads and removes partial files", arguments: ["close", "source", "connection", "offline", "capability"])
    func invalidation(reason: String) async throws {
        try await withFixture(image: false) { fixture in
            fixture.startFiles()
            try await wait { fixture.control.blocked }
            switch reason {
            case "close": fixture.tab.releaseResources()
            default:
                let source = FileBrowserSource(
                    id: reason == "source" ? "other-host" : "host",
                    paneID: nil,
                    unavailableReason: reason == "offline" ? "Host offline" : nil,
                    uploadUnavailableReason: reason == "capability" ? "Upload unavailable" : nil,
                    connectionID: reason == "connection" ? UUID() : nil,
                    request: fixture.control.source.request
                )
                await fixture.tab.load(source: source)
            }
            try await wait { !fixture.tab.uploadSession.isRunning }
            #expect(fixture.control.cancelled)
            #expect(fixture.control.closedReaders == 1)
            #expect(fixture.control.completed.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
        }
    }

    @Test("Cancelling a batch keeps completed files and never starts a later file")
    func partialBatch() async throws {
        try await withFixture(image: false) { fixture in
            let small = fixture.root.appendingPathComponent("first.bin")
            try Data([1, 2, 3]).write(to: small)
            fixture.startFiles([small, fixture.file, fixture.file])
            try await wait { fixture.control.blocked }
            fixture.tab.cancelUploads()
            try await wait { !fixture.tab.uploadSession.isRunning }
            #expect(fixture.control.begins == 2 && fixture.control.completed.count == 1)
            #expect(fixture.control.closedReaders == 2)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path) == [small.lastPathComponent])
            #expect(try Data(contentsOf: fixture.destination.appendingPathComponent(small.lastPathComponent)) == Data([1, 2, 3]))
            #expect(fixture.tab.uploadSession.upload.summary == "1 file(s) saved. Upload cancelled.")
        }
    }

    @Test("An already cancelled directory load cannot rebind or cancel a current upload")
    func cancelledLoadCannotChangeTheUploadSource() async throws {
        try await withFixture(image: false) { fixture in
            fixture.startFiles()
            try await wait { fixture.control.blocked }
            let staleSource = FileBrowserSource(id: "old-host", paneID: nil, request: fixture.control.source.request)
            let load = Task { await fixture.tab.load(source: staleSource) }
            load.cancel()
            await load.value
            #expect(fixture.tab.uploadSession.isRunning && !fixture.control.cancelled)
            fixture.control.finish = true
            try await wait { !fixture.tab.uploadSession.isRunning }
            #expect(fixture.control.completed.count == 1)
            #expect(fixture.control.begins == 1)
        }
    }

    @Test("An in-flight upload does not retain a closed Files tab")
    func tabLifetime() async throws {
        try await withFixture(image: false) { fixture in
            var tab: FileBrowserTab? = FileBrowserTab(path: fixture.destination.path)
            weak var releasedTab = tab
            weak var releasedSession = tab?.uploadSession
            tab?.uploadSession.start(.files([fixture.file]), directory: fixture.destination.path, source: fixture.control.source) { [weak tab] in tab?.refresh += 1 }
            try await wait { fixture.control.blocked }
            tab = nil
            try await wait { releasedTab == nil && releasedSession == nil && fixture.control.cancelled && fixture.control.closedReaders == 1 }
            try await wait { (try? FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty) == true }
        }
    }

    @MainActor
    final private class Control {
        let receiver = HostFileUploads()
        let data: Data
        let image: Bool
        let destination: URL
        var finish = false
        var blocked = false
        var cancelled = false
        var cleanupHeld = false
        var begins = 0
        var closedReaders = 0
        var completed: [URL] = []

        init(data: Data, image: Bool, destination: URL) {
            self.data = data
            self.image = image
            self.destination = destination
        }

        var source: FileBrowserSource {
            FileBrowserSource(id: "host", paneID: nil) { [self] operation in
                switch operation {
                case let .list(path, _, _):
                    let directory = path ?? destination.path
                    return .listing(.init(directory: directory, homeDirectory: destination.path, entries: [], nextOffset: nil, revision: "1"))
                case let .upload(request):
                    switch request {
                    case let .begin(_, directory, _, _):
                        #expect(directory == destination.path)
                        begins += 1
                    case let .append(_, offset, _):
                        if offset == (image ? 0 : FileBrowserLimits.chunkBytes), !finish {
                            blocked = true
                            while !finish {
                                try await Task.sleep(for: .milliseconds(10))
                            }
                        }
                    case .cancel:
                        #expect(!Task.isCancelled, "Host cleanup must use an uncancelled task")
                        cancelled = true
                        while cleanupHeld {
                            try await Task.sleep(for: .milliseconds(10))
                        }
                    case .finish: break
                    }
                    let response = try await receiver.request(request)
                    if case let .uploaded(_, path?) = response {
                        completed.append(URL(fileURLWithPath: path))
                    }
                    return response
                default: throw FileBrowserError.message("Unexpected fixture request")
                }
            }
        }
    }

    @Observable @MainActor
    final class Visibility { var visible = true }

    private struct Surface: View {
        let tab: FileBrowserTab
        let source: FileBrowserSource
        let state: Visibility
        var body: some View {
            if state.visible {
                WorkspaceFileBrowserView(tab: tab, source: source)
            } else {
                Text("Other tab")
            }
        }
    }

    @MainActor
    final private class Fixture {
        let root: URL
        let destination: URL
        let otherDirectory: URL
        let file: URL
        let tab: FileBrowserTab
        let control: Control
        var window: NSWindow?

        init(image: Bool) throws {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-upload-retention-\(UUID())", isDirectory: true)
            self.destination = root.appendingPathComponent("host", isDirectory: true)
            self.otherDirectory = root.appendingPathComponent("other", isDirectory: true)
            self.file = root.appendingPathComponent("source.bin")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
            let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQaPjQAMIMMAYARzIIQdQEEEMAAAAASUVORK5CYII="))
            let data = image ? png : Data(repeating: 65, count: FileBrowserLimits.chunkBytes + 7)
            try data.write(to: file)
            self.control = Control(data: data, image: image, destination: destination)
            self.tab = FileBrowserTab(path: destination.path)
        }

        func startFiles(_ urls: [URL]? = nil) {
            tab.uploadSession.start(.files(urls ?? [file]), directory: destination.path, source: control.source) { [weak tab] in tab?.refresh += 1 }
        }

        func mount() -> (NSWindow, Visibility) {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let state = Visibility()
            let host = NSHostingView(rootView: Surface(tab: tab, source: control.source, state: state))
            host.sizingOptions = []
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 1_000, height: 650), styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            self.window = window
            return (window, state)
        }

        func close() async {
            window?.close()
            tab.releaseResources()
            control.finish = true
            control.cleanupHeld = false
            for _ in 0..<300 where tab.uploadSession.isRunning {
                try? await Task.sleep(for: .milliseconds(10))
            }
            await control.receiver.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func withFixture(image: Bool, operation: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture(image: image)
        let reader = UploadFileReader()
        let control = fixture.control
        do {
            try await withDependencies {
                $0[FileBrowserUploadReader.self] = .init(open: { try await reader.open($0) }, read: { try await reader.read($0) }, finish: { try await reader.finish($0) }, close: { id in
                    await reader.close(id)
                    await MainActor.run { control.closedReaders += 1 }
                })
                let bytes = control.data
                $0[ClipboardClient.self].getImage = { .init(data: bytes, format: .png) }
            } operation: {
                try await operation(fixture)
            }
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private func attribute(_ name: String, from object: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
    }

    private func element(_ id: String, in object: NSObject, label: Bool = false) -> NSObject? {
        if attribute(label ? "accessibilityLabel" : "accessibilityIdentifier", from: object) as? String == id {
            return object
        }
        for child in attribute("accessibilityChildren", from: object) as? [NSObject] ?? [] {
            if let found = element(id, in: child, label: label) {
                return found
            }
        }
        if let view = object as? NSView {
            for child in view.subviews {
                if let found = element(id, in: child, label: label) {
                    return found
                }
            }
        }
        return nil
    }

    private func click(_ id: String, in window: NSWindow) async throws {
        let content = try #require(window.contentView)
        try await wait { element(id, in: content) != nil }
        let button = try #require(element(id, in: content))
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let method = try #require(button.method(for: selector))
        _ = unsafeBitCast(method, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(button, selector)
    }

    private func wait(_ message: String = "Upload did not reach its expected lifecycle state", _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "\(message)")
    }
}
