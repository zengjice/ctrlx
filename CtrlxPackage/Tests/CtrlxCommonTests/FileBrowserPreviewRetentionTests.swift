#if os(macOS)
    import AppKit
    import AVKit
    import CtrlxNetworking
    import PDFKit
    import SwiftUI
    import Testing
    @testable import CtrlxCommon

    @MainActor
    @Suite(.serialized)
    struct FileBrowserPreviewRetentionTests {
        @Test("Repeated tab switches retain the preview container and reading position without rereading contents", arguments: [false, true])
        func warmSwitchAndEviction(remote: Bool) async throws {
            let fixture = Fixture(remote: remote)
            defer { fixture.close() }
            try await wait { fixture.tab.previewData == fixture.data && fixture.tab.previewSession.owner != nil }
            let scroll = try #require(fixture.previewScroll)
            scroll.contentView.scroll(to: .init(x: 0, y: 350))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await wait { fixture.tab.previewSession.position.scroll.y >= 349 }
            let reads = fixture.reads.value
            let container = try #require(retainedContainer(in: fixture.host))

            for _ in 0..<8 {
                fixture.state.visible = false
                try await wait { fixture.tab.previewSession.owner == nil }
                #expect(fixture.tab.previewSession.hasContent)
                fixture.state.visible = true
                try await wait { fixture.tab.previewSession.owner != nil && fixture.previewScroll != nil }
                #expect(retainedContainer(in: fixture.host) === container)
                try await wait { abs((fixture.previewScroll?.contentView.bounds.minY ?? 0) - 350) < 2 }
                #expect(fixture.reads.value == reads)
            }

            fixture.state.visible = false
            try await wait { fixture.tab.previewSession.owner == nil }
            fixture.tab.previewSession.evict()
            #expect(fixture.tab.previewData == nil)
            #expect(!fixture.tab.previewSession.hasContent)
            fixture.state.visible = true
            try await wait { fixture.tab.previewData == fixture.data && fixture.previewScroll != nil }
            try await wait { abs((fixture.previewScroll?.contentView.bounds.minY ?? 0) - 350) < 2 }
            #expect(fixture.reads.value == reads + 1)
        }

        @Test("Local media waits for its URL and keeps the same paused player across tab switches")
        func localMedia() async throws {
            _ = NSApplication.shared
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let url = package.appendingPathComponent("Sources/CtrlxE2ELib/Scenarios/SampleFiles/test_video.mp4")
            let tab = FileBrowserTab(path: "/fixture")
            let state = State()
            let info = FileBrowserEntry(path: "/fixture/movie.mp4", name: "movie.mp4", kind: .unsupported, size: 1, revision: "1")
            let source = FileBrowserSource(id: "local", paneID: nil, localFileURL: { _ in
                try await Task.sleep(for: .milliseconds(100))
                return url
            }) { operation in
                switch operation {
                case .list: .listing(.init(directory: "/fixture", homeDirectory: "/fixture", entries: [info], nextOffset: nil, revision: "1"))
                case .info: .info(info)
                default: throw FileBrowserError.message("Local media must not read file chunks")
                }
            }
            tab.selectedFile = info.path
            let host = NSHostingView(rootView: Surface(tab: tab, source: source, state: state))
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 1_000, height: 650), styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer { window.close()
                tab.releasePreview()
            }
            func video(in view: NSView) -> AVPlayerView? {
                if let player = view as? AVPlayerView {
                    return player
                }
                return view.subviews.lazy.compactMap { video(in: $0) }.first
            }
            try await wait { video(in: host)?.player?.currentItem?.status == .readyToPlay }
            let original = try #require(video(in: host))
            let container = try #require(retainedContainer(in: host))
            let player = try #require(original.player)
            await player.seek(to: CMTime(seconds: 1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            state.visible = false
            try await wait { tab.previewSession.owner == nil }
            #expect(player.rate == 0)
            state.visible = true
            try await wait { tab.previewSession.owner != nil && video(in: host) != nil }
            #expect(retainedContainer(in: host) === container)
            #expect(video(in: host)?.player === player)
            #expect(abs(player.currentTime().seconds - 1) < 0.1)
        }

        @Test("PDF page and point survive warm switches and hidden-preview eviction")
        func pdfReadingPosition() async throws {
            let bytes = try #require(CFDataCreateMutable(nil, 0))
            let consumer = try #require(CGDataConsumer(data: bytes))
            var box = CGRect(x: 0, y: 0, width: 300, height: 500)
            let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
            for shade in [0.8, 0.9, 1.0] {
                context.beginPDFPage(nil)
                context.setFillColor(CGColor(gray: shade, alpha: 1))
                context.fill(box)
                context.endPDFPage()
            }
            context.closePDF()
            let fixture = Fixture(remote: true, pdfData: bytes as Data)
            defer { fixture.close() }
            func pdf(in view: NSView) -> PDFView? {
                if let pdf = view as? PDFView {
                    return pdf
                }
                return view.subviews.lazy.compactMap { pdf(in: $0) }.first
            }
            try await wait { pdf(in: fixture.host)?.document != nil }
            let original = try #require(pdf(in: fixture.host))
            try original.go(to: #require(original.document?.page(at: 2)))
            try await wait { original.currentPage.map { original.document?.index(for: $0) == 2 } == true }
            fixture.state.visible = false
            try await wait { fixture.tab.previewSession.owner == nil }
            #expect(fixture.tab.previewSession.position.pdfPage == 2)
            fixture.state.visible = true
            try await wait { pdf(in: fixture.host) != nil }
            try await wait {
                guard let pdf = pdf(in: fixture.host), let page = pdf.currentPage else { return false }
                return pdf.document?.index(for: page) == 2
            }
            fixture.state.visible = false
            try await wait { fixture.tab.previewSession.owner == nil }
            fixture.tab.previewSession.evict()
            fixture.state.visible = true
            try await wait {
                guard let pdf = pdf(in: fixture.host), let page = pdf.currentPage else { return false }
                return pdf.document?.index(for: page) == 2
            }
        }

        @Test("Retained link callbacks reach the newly mounted Files header", arguments: [false, true])
        func linkAfterSwitch(remote: Bool) async throws {
            let fixture = Fixture(remote: remote)
            defer { fixture.close() }
            try await wait { fixture.tab.previewSession.owner != nil }
            let actions = fixture.tab.previewSession.actions
            fixture.state.visible = false
            try await wait { fixture.tab.previewSession.owner == nil }
            fixture.state.visible = true
            try await wait { fixture.tab.previewSession.owner != nil }
            actions.link = .init(url: URL(fileURLWithPath: "/fixture/target.md"), documentPath: "/fixture/readme.md")
            try await wait { fixture.tab.selectedFile == "/fixture/target.md" && fixture.tab.previewData == Data("# Target".utf8) }
        }

        @Observable @MainActor
        final class State { var visible = true }
        @MainActor
        final private class Reads { var value = 0 }

        private struct Surface: View {
            let tab: FileBrowserTab
            let source: FileBrowserSource
            @Bindable var state: State
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
            let state = State()
            let reads = Reads()
            let data: Data
            let window: NSWindow
            let host: NSHostingView<Surface>

            init(remote: Bool, pdfData: Data? = nil) {
                _ = NSApplication.shared
                self.data = pdfData ?? Data(("# Document\n\n" + (0..<250).map { "Paragraph \($0): keep this reading position.\n\n" }.joined()).utf8)
                let data = data
                let reads = reads
                let info = FileBrowserEntry(path: pdfData == nil ? "/fixture/readme.md" : "/fixture/document.pdf", name: "document", kind: pdfData == nil ? .markdown : .pdf, size: data.count, revision: "v1")
                let files = [info.path: data, "/fixture/target.md": Data("# Target".utf8)]
                let local: @MainActor @Sendable (FileBrowserEntry) async throws -> Data = { info in reads.value += 1
                    return try #require(files[info.path])
                }
                let source = FileBrowserSource(id: remote ? "remote" : "local", paneID: nil, localPreview: remote ? nil : local) { operation in
                    switch operation {
                    case .list: return .listing(.init(directory: "/fixture", homeDirectory: "/fixture", entries: [info], nextOffset: nil, revision: "1"))
                    case let .info(path):
                        let content = try #require(files[path])
                        return .info(.init(path: path, name: "document", kind: info.kind, size: content.count, revision: info.revision))
                    case let .read(path, offset, _):
                        reads.value += 1
                        let content = try #require(files[path])
                        return .chunk(.init(path: path, revision: info.revision, offset: offset, data: Data(content.dropFirst(offset))))
                    default: throw FileBrowserError.message("Unexpected operation")
                    }
                }
                tab.selectedFile = info.path
                self.host = NSHostingView(rootView: Surface(tab: tab, source: source, state: state))
                host.sizingOptions = []
                self.window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 1_000, height: 650), styleMask: .titled, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderBack(nil)
            }

            var previewScroll: NSScrollView? {
                scrolls(in: host).filter { $0.documentView?.bounds.height ?? 0 > 1_000 }
                    .max { $0.convert(.zero, to: host).x < $1.convert(.zero, to: host).x }
            }

            private func scrolls(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls(in: $0) }
            }

            func close() {
                window.close()
                tab.releasePreview()
            }
        }

        private func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<300 {
                if condition() {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(condition(), "Preview did not reach the expected lifecycle state")
        }

        private func retainedContainer(in view: NSView) -> NSView? {
            if String(describing: type(of: view)) == "NSHostingView<FileBrowserRetainedContent>" {
                return view
            }
            return view.subviews.lazy.compactMap { retainedContainer(in: $0) }.first
        }
    }
#endif
