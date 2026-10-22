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
                    renderer.load(content: source, kind: .mermaid, dark: dark)
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
            let hosting = NSHostingView(rootView: TerminalArtifactPreviewSheet(preview: preview) { _ in Issue.record("Unexpected Open in Files") }.preferredColorScheme(.light))
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
            renderer.load(content: "This is not Mermaid", kind: .mermaid, dark: false)
            try await wait(renderer)
            #expect(renderer.error != nil && renderer.png == nil)
            renderer.load(content: "graph TD; A-->B", kind: .mermaid, dark: false)
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
            renderer.load(content: "graph TD\n A[\"</script><script>window.injected=true</script>\"] --> B[Safe]", kind: .mermaid, dark: false)
            try await wait(renderer)
            #expect(renderer.isReady, "\(renderer.error ?? "")")
            let injected = try await renderer.webView.evaluateJavaScript("window.injected === true") as? Bool
            #expect(injected == false)
            let png = try #require(renderer.png)
            try renderer.load(content: ArtifactPreviewImage.png(from: png).base64EncodedString(), kind: .image, dark: true)
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

        @Test
        func markdownRendersTextDiagramsImagesAndKeepsFailedDiagramSource() async throws {
            let renderer = ArtifactWebRenderer()
            let window = mount(renderer)
            defer { renderer.stop()
                window.close()
            }
            renderer.load(content: "graph LR; A-->B", kind: .mermaid, dark: false)
            try await wait(renderer)
            let image = try #require(renderer.png)
            let source = """
            # 完整阅读
            **Bold** and [section](#完整阅读).

            | 项目 | 状态 |
            | --- | --- |
            | Markdown | Ready |

            - [x] Task

            ![本地图](images/test.png)
            ![矢量图](images/test.svg)
            ![缺失图](missing.png)

            ```mermaid
            flowchart LR
              A[正文] --> B[图表]
            ```

            ```mermaid
            not a diagram
            ```

            ```swift
            print("hello")
            ```
            """
            for dark in [false, true] {
                renderer.load(content: source, kind: .markdown, dark: dark, imageLoader: { reference in
                    if reference == "images/test.svg" {
                        return Data("""
                        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="50">
                          <script>window.injected=true</script>
                          <foreignObject><div>Unsafe</div></foreignObject>
                          <use href="https://example.com/external.svg#icon"/>
                          <rect width="200" height="50" fill="teal"/>
                          <text x="10" y="30" fill="white">SVG 图片</text>
                        </svg>
                        """.utf8)
                    }
                    guard reference == "images/test.png" else { throw FileBrowserError.message("Image missing") }
                    return image
                })
                try await wait(renderer)
                let deadline = ContinuousClock.now + .seconds(10)
                while ContinuousClock.now < deadline {
                    if try (await renderer.webView.evaluateJavaScript("document.querySelector('.markdown-image img[src]') !== null && document.body.textContent.includes('Image missing')")) as? Bool == true {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
                let state = try await renderer.webView.evaluateJavaScript("""
                ({ heading: document.querySelector('h1').textContent,
                   table: !!document.querySelector('table'),
                   diagram: !!document.querySelector('.markdown-diagram svg'),
                   source: document.body.textContent.includes('not a diagram'),
                   code: !!document.querySelector('code.language-swift'),
                   image: !!document.querySelector('img[src^="data:image/png"]'),
                   svg: !!document.querySelector('img[src^="data:image/svg+xml"]'),
                   safeSVG: !/script|foreignObject|https:/.test(atob(document.querySelector('img[src^="data:image/svg+xml"]').src.split(',')[1])),
                   failure: document.body.textContent.includes('Image missing'),
                   task: document.querySelector('input[type="checkbox"]').disabled,
                   dark: document.body.classList.contains('dark') })
                """) as? [String: Any]
                #expect(state?["heading"] as? String == "完整阅读")
                for key in ["table", "diagram", "source", "code", "image", "svg", "safeSVG", "failure", "task"] {
                    #expect(state?[key] as? Bool == true, "\(key)")
                }
                #expect(state?["dark"] as? Bool == dark)
                #expect(renderer.png == nil)
                let snapshot = try await renderer.webView.takeSnapshot(configuration: nil)
                let tiff = try #require(snapshot.tiffRepresentation)
                try saveEvidence(#require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])), name: dark ? "markdown-dark.png" : "markdown-light.png")
            }
        }

        @Test
        func markdownSanitizesHTMLAndNeverFetchesImagesFromWebKit() async throws {
            let renderer = ArtifactWebRenderer()
            let window = mount(renderer)
            defer { renderer.stop()
                window.close()
            }
            renderer.load(content: """
            # Safe
            <script>window.injected=true</script>
            <iframe src="https://example.com"></iframe>
            <img src="https://example.com/image.png" onerror="window.injected=true" srcset="https://example.com/other.png 2x">
            ![Remote](https://example.com/remote.png)
            [Danger](javascript:alert(1))
            [File](../README.md)
            [Web](https://example.com)
            <style>body { display:none }</style>
            """, kind: .markdown, dark: false)
            try await wait(renderer)
            let state = try await renderer.webView.evaluateJavaScript("""
            ({ script: window.injected === true,
               unsafe: !!document.querySelector('#content script, #content iframe, #content style, img[onerror], img[srcset]'),
               remote: !!document.querySelector('img[src^="https:"], a[href^="javascript:"]'),
               links: Array.from(document.querySelectorAll('a[href]')).every(a => a.getAttribute('href').startsWith('ctrlx-preview://link?')) })
            """) as? [String: Bool]
            #expect(state?["script"] == false && state?["unsafe"] == false && state?["remote"] == false)
            #expect(state?["links"] == true)
        }

        @Test
        func markdownIsReadableDuringImageLoadingAndRejectsLateResults() async throws {
            let renderer = ArtifactWebRenderer()
            let window = mount(renderer)
            defer { renderer.stop()
                window.close()
            }
            var pending: CheckedContinuation<Data, Never>?
            let source = "# Old document\n" + (0..<30).map { "![Image](\($0).png)" }.joined(separator: "\n")
            renderer.load(content: source, kind: .markdown, dark: false, imageLoader: { _ in
                await withCheckedContinuation { pending = $0 }
            })
            try await wait(renderer)
            #expect(pending != nil)
            #expect(try await renderer.webView.evaluateJavaScript("document.querySelector('h1').textContent") as? String == "Old document")
            #expect(try await renderer.webView.evaluateJavaScript("Array.from(document.querySelectorAll('.markdown-error')).filter(e => e.textContent.includes('at most 24')).length") as? Int == 6)
            renderer.load(content: "# New document", kind: .markdown, dark: true)
            pending?.resume(returning: Data())
            pending = nil
            try await wait(renderer)
            #expect(renderer.error == nil)
            #expect(try await renderer.webView.evaluateJavaScript("document.querySelector('h1').textContent") as? String == "New document")
            #expect(try await renderer.webView.evaluateJavaScript("document.querySelector('img') === null") as? Bool == true)
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
