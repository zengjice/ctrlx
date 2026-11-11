#if os(macOS)
    import AppKit
    import CtrlxNetworking
    import Dependencies
    import SwiftUI
    import Testing
    @testable import CtrlxCommon

    @MainActor @Suite(.serialized)
    struct FileBrowserDownloadRetentionTests {
        @Test("An explicit download survives unmounting, re-entry and preview eviction", arguments: [false, true])
        func switchTabs(reveal: Bool) async throws {
            try await withFixture { fixture in
                let (window, state) = fixture.mount()
                defer { window.close() }
                try await wait { fixture.tab.previewSession.owner != nil }
                try await click(reveal ? "file-show-in-finder" : "file-download-open", in: window)
                try await fixture.waitForProgress()
                let transfer = fixture.tab.openSession.transfer

                state.visible = false
                try await wait { fixture.tab.previewSession.owner == nil }
                try await Task.sleep(for: .milliseconds(100))
                #expect(fixture.tab.openSession.isRunning)
                state.visible = true
                try await wait { fixture.tab.previewSession.owner != nil }
                #expect(fixture.tab.openSession.transfer === transfer)
                #expect(transfer.receivedBytes == FileBrowserLimits.chunkBytes)
                #expect(fixture.control.downloadOffsets == [0, FileBrowserLimits.chunkBytes])
                try await wait { element("file-download-cancel", in: window) != nil }

                state.visible = false
                try await wait { fixture.tab.previewSession.owner == nil }
                fixture.tab.previewSession.evict()
                fixture.control.finish = true
                try await wait { !fixture.tab.openSession.isRunning }
                let url = try #require(fixture.control.deliveries.first?.url)
                #expect(try Data(contentsOf: url) == fixture.control.data)
                #expect(fixture.control.deliveries.count == 1)
                #expect(fixture.control.deliveries.first?.reveal == reveal)
                state.visible = true
                try await wait { fixture.tab.previewSession.owner != nil }
                #expect(fixture.control.deliveries.count == 1)
                #expect(fixture.control.downloadOffsets == [0, FileBrowserLimits.chunkBytes])
            }
        }

        @Test("Cancel still discards the partial copy and allows a fresh download")
        func cancelAndRetry() async throws {
            try await withFixture { fixture in
                let (window, _) = fixture.mount()
                defer { window.close() }
                try await click("file-download-open", in: window)
                try await fixture.waitForProgress()
                try await click("file-download-cancel", in: window)
                try await wait { fixture.control.cancelled && fixture.cacheIsEmpty }
                #expect(fixture.control.deliveries.isEmpty)
                #expect(fixture.tab.openSession.error == nil)
                fixture.control.finish = true
                try await click("file-show-in-finder", in: window)
                try await wait { fixture.control.deliveries.count == 1 }
                #expect(fixture.control.deliveries.first?.reveal == true)
            }
        }

        @Test("Changing the file or source and closing the tab cancel explicit downloads", arguments: ["selection", "refresh", "close", "connection", "host", "offline"])
        func invalidation(reason: String) async throws {
            try await withFixture { fixture in
                fixture.tab.openSession.start(.open, path: Control.path, source: fixture.source)
                try await fixture.waitForProgress()
                switch reason {
                case "selection": fixture.tab.selectedFile = "/fixture/other.txt"
                case "refresh": fixture.tab.refresh += 1
                case "close": fixture.tab.releasePreview()
                default:
                    let source = FileBrowserSource(
                        id: reason == "host" ? "other-host" : "host",
                        paneID: nil,
                        unavailableReason: reason == "offline" ? "Host offline" : nil,
                        connectionID: reason == "connection" ? UUID() : nil,
                        request: fixture.source.request
                    )
                    await fixture.tab.loadPreview(source: source)
                }
                try await wait { fixture.control.cancelled && fixture.cacheIsEmpty }
                #expect(!fixture.tab.openSession.isRunning)
                #expect(fixture.control.deliveries.isEmpty)
                #expect(fixture.tab.openSession.error == nil)
            }
        }

        @Test("A failed background download removes its copy and preserves the error for re-entry")
        func failedDownload() async throws {
            try await withFixture { fixture in
                fixture.tab.openSession.start(.open, path: Control.path, source: fixture.source)
                try await fixture.waitForProgress()
                fixture.control.failure = true
                fixture.control.finish = true
                try await wait { !fixture.tab.openSession.isRunning }
                #expect(fixture.tab.openSession.error == "Host offline")
                #expect(fixture.cacheIsEmpty)
                #expect(fixture.control.deliveries.isEmpty)
                await fixture.tab.loadPreview(source: fixture.source)
                #expect(fixture.tab.openSession.error == "Host offline")
            }
        }

        @Test("An in-flight download does not keep its Files tab alive")
        func tabLifetime() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-download-lifetime-\(UUID())", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await withDependencies {
                $0[FileBrowserDownloadClient.self] = .live(root: root)
            } operation: {
                let control = Control()
                var tab: FileBrowserTab? = FileBrowserTab(path: "/fixture")
                weak var releasedTab = tab
                weak var releasedSession = tab?.openSession
                tab?.openSession.start(.open, path: Control.path, source: control.source)
                try await wait { control.downloadOffsets.count == 2 }
                tab = nil
                try await wait { releasedTab == nil && releasedSession == nil && control.cancelled }
                try await wait { (try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) == true }
                #expect(control.deliveries.isEmpty)
            }
        }

        @MainActor
        final private class Control {
            static let path = "/fixture/document.txt"
            let data = Data(repeating: 65, count: FileBrowserLimits.chunkBytes + 7)
            var downloadOffsets: [Int] = []
            var finish = false
            var failure = false
            var cancelled = false
            var deliveries: [(url: URL, reveal: Bool)] = []

            var source: FileBrowserSource {
                FileBrowserSource(id: "host", paneID: nil) { [self] operation in
                    let info = FileBrowserEntry(path: Self.path, name: "document.txt", kind: .text, size: data.count, revision: "1")
                    switch operation {
                    case .list: return .listing(.init(directory: "/fixture", homeDirectory: "/fixture", entries: [info], nextOffset: nil, revision: "1"))
                    case .info: return .info(info)
                    case let .read(path, offset, revision):
                        return .chunk(.init(path: path, revision: revision, offset: offset, data: data.subdata(in: offset..<min(offset + FileBrowserLimits.chunkBytes, data.count))))
                    case let .download(path, offset, revision):
                        downloadOffsets.append(offset)
                        if offset > 0 {
                            do {
                                while !finish {
                                    try await Task.sleep(for: .milliseconds(10))
                                }
                                try Task.checkCancellation()
                            } catch {
                                cancelled = true
                                throw error
                            }
                            if failure {
                                throw FileBrowserError.message("Host offline")
                            }
                        }
                        return .chunk(.init(path: path, revision: revision, offset: offset, data: data.subdata(in: offset..<min(offset + FileBrowserLimits.chunkBytes, data.count))))
                    default: throw FileBrowserError.message("Unexpected operation")
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
            let tab = FileBrowserTab(path: "/fixture")
            let control: Control
            let root: URL
            var source: FileBrowserSource {
                control.source
            }

            var cacheIsEmpty: Bool {
                (try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) == true
            }

            init(control: Control, root: URL) {
                self.control = control
                self.root = root
                tab.selectedFile = Control.path
            }

            func mount() -> (NSWindow, Visibility) {
                _ = NSApplication.shared
                NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
                let state = Visibility()
                let host = NSHostingView(rootView: Surface(tab: tab, source: source, state: state))
                host.sizingOptions = []
                let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 1_000, height: 650), styleMask: .titled, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderBack(nil)
                return (window, state)
            }

            func waitForProgress() async throws {
                try await FileBrowserDownloadRetentionTests().wait {
                    self.tab.openSession.transfer.receivedBytes == FileBrowserLimits.chunkBytes && self.control.downloadOffsets.count == 2
                }
            }
        }

        private func withFixture(_ operation: (Fixture) async throws -> Void) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-download-retention-\(UUID())", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let control = Control()
            try await withDependencies {
                $0[FileBrowserDownloadClient.self] = .live(root: root)
                $0[FileBrowserOpener.self] = .init(open: { control.deliveries.append(($0, false)) }, showInFinder: { control.deliveries.append(($0, true)) })
            } operation: {
                let fixture = Fixture(control: control, root: root)
                defer { fixture.tab.releasePreview() }
                try await operation(fixture)
            }
        }

        private func attribute(_ name: String, from object: NSObject) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }

        private func element(_ id: String, in object: NSObject) -> NSObject? {
            if attribute("accessibilityIdentifier", from: object) as? String == id {
                return object
            }
            let children = attribute("accessibilityChildren", from: object) as? [NSObject] ?? []
            for child in children {
                if let found = element(id, in: child) {
                    return found
                }
            }
            if let view = object as? NSView {
                for child in view.subviews {
                    if let found = element(id, in: child) {
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

        private func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<300 {
                if condition() {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(condition(), "Download did not reach its expected lifecycle state")
        }
    }
#endif
