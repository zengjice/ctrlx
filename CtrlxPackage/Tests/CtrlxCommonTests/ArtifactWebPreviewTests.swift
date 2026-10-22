#if os(macOS)
    import AppKit
    import CtrlxNetworking
    import ImageIO
    import SwiftUI
    import Testing
    import WebKit
    @testable import CtrlxCommon

    @Suite(.serialized)
    @MainActor
    struct ArtifactWebPreviewTests {
        @Test
        func rendersBundledDiagramsAndExportsPNGInBothThemes() async throws {
            let renderer = ArtifactWebRenderer()
            let window = mount(renderer)
            defer { renderer.stop()
                window.close()
            }
            for source in [
                "flowchart LR\n A[终端] --> B[预览]\n B --> C[返回]",
                "sequenceDiagram\n participant A as Viewer\n participant B as Host\n A->>B: Read file\n B-->>A: Encrypted bytes",
                "classDiagram\n Animal <|-- Duck\n Animal: +String name",
                "stateDiagram-v2\n [*] --> Loading\n Loading --> Ready",
            ] {
                for dark in [false, true] {
                    renderer.load(content: source, mermaid: true, dark: dark)
                    try await wait(renderer)
                    #expect(renderer.error == nil, "\(source): \(renderer.error ?? "")")
                    let png = try #require(renderer.png)
                    try saveEvidence(png, name: "\(source.components(separatedBy: .newlines)[0].replacingOccurrences(of: " ", with: "-"))-\(dark ? "dark" : "light").png")
                    let image = try #require(NSBitmapImageRep(data: png))
                    #expect(image.pixelsWide > 50 && image.pixelsHigh > 50)
                    #expect(image.pixelsWide <= 4_096 && image.pixelsHigh <= 4_096)
                    let pixel = try #require(image.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
                    #expect(dark ? pixel.redComponent < 0.3 : pixel.redComponent > 0.8)
                }
            }
        }

        @Test
        func sheetLoadsHostBytesIntoTheMountedPreview() async throws {
            _ = NSApplication.shared
            let data = Data("flowchart LR\n A[Agent 回复] --> B[点击引用]\n B --> C[查看图表]".utf8)
            let context = RepositoryFileContext(pluginID: "codex", sessionID: "preview-test", projectDirectory: "/Host/worktree")
            let info = FileBrowserEntry(path: "/Host/worktree/diagram.mmd", name: "diagram.mmd", kind: .text, size: data.count, revision: "1")
            let source = FileBrowserSource(id: "isolated-host", paneID: "%1") { operation in
                switch operation {
                case .repositoryInfo,
                     .info: return .info(info)
                case let .read(path, offset, revision): return .chunk(.init(path: path, revision: revision, offset: offset, data: data))
                default: throw FileBrowserError.message("Preview must not open a Files tab")
                }
            }
            let preview = TerminalArtifactPreview(link: .init(path: "diagram.mmd", paneID: "%1", hostID: "isolated-host"), context: context, source: source, path: info.path)
            let hosting = NSHostingView(rootView: TerminalArtifactPreviewSheet(preview: preview) { Issue.record("Unexpected Open in Files") }.preferredColorScheme(.light))
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            let deadline = ContinuousClock.now + .seconds(25)
            var web: WKWebView?
            while ContinuousClock.now < deadline {
                web = webView(in: hosting)
                if let web, (try? await web.evaluateJavaScript("document.querySelector('#content > svg') !== null")) as? Bool == true {
                    break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            let view = try #require(web)
            let rendered = try await view.evaluateJavaScript("document.querySelector('#content > svg') !== null") as? Bool
            #expect(rendered == true)
            #expect(view.bounds.width > 400 && view.bounds.height > 200)
            let image = try await view.takeSnapshot(configuration: nil)
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try saveEvidence(png, name: "mounted-sheet-content.png")
        }

        private func webView(in view: NSView) -> WKWebView? {
            if let web = view as? WKWebView {
                return web
            }
            return view.subviews.lazy.compactMap { webView(in: $0) }.first
        }

        private func saveEvidence(_ data: Data, name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["CTRLX_PREVIEW_EVIDENCE"] else { return }
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }

        @Test
        func rejectsInvalidMermaidAndCanRenderAgain() async throws {
            let renderer = ArtifactWebRenderer()
            let window = mount(renderer)
            defer { renderer.stop()
                window.close()
            }
            renderer.load(content: "This is not Mermaid", mermaid: true, dark: false)
            try await wait(renderer)
            #expect(renderer.error != nil && renderer.png == nil)
            renderer.load(content: "graph TD; A-->B", mermaid: true, dark: false)
            try await wait(renderer)
            #expect(renderer.isReady && renderer.error == nil)
        }

        @Test
        func sourceCannotExecuteScriptsAndImagesUseTheSameViewer() async throws {
            let renderer = ArtifactWebRenderer()
            let window = mount(renderer)
            defer { renderer.stop()
                window.close()
            }
            renderer.load(content: "graph TD\n A[\"</script><script>window.injected=true</script>\"] --> B[Safe]", mermaid: true, dark: false)
            try await wait(renderer)
            #expect(renderer.isReady, "\(renderer.error ?? "")")
            let injected = try await renderer.webView.evaluateJavaScript("window.injected === true") as? Bool
            #expect(injected == false)
            let png = try #require(renderer.png)
            try renderer.load(content: ArtifactPreviewImage.png(from: png).base64EncodedString(), mermaid: false, dark: true)
            try await wait(renderer)
            #expect(renderer.isReady && renderer.png != nil)
            renderer.webView.setMagnification(2, centeredAt: .zero)
            renderer.fit()
            #expect(renderer.webView.magnification == 1)
        }

        private func wait(_ renderer: ArtifactWebRenderer) async throws {
            let deadline = ContinuousClock.now + .seconds(25)
            while !renderer.isReady && renderer.error == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            try #require(renderer.isReady || renderer.error != nil, "Renderer did not complete")
        }

        private func mount(_ renderer: ArtifactWebRenderer) -> NSWindow {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: CGRect(x: -10_000, y: -10_000, width: 800, height: 600),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = renderer.webView
            window.orderBack(nil)
            return window
        }
    }
#endif
