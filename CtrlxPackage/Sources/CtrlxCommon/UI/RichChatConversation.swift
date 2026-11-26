#if os(macOS)
    import AppKit
    import SwiftUI
    import WebKit

    @MainActor
    public struct RichChatConversation: View {
        let messages: [RichChatMessage]
        let title: String
        let onAction: (UUID, String) -> Void
        let onReference: (UUID, String) -> Void
        let imageLoader: (UUID, String) async throws -> Data
        let onHeight: (CGFloat) -> Void
        @Environment(\.colorScheme) private var colorScheme
        @State private var renderer = RichChatRenderer()

        public init(
            messages: [RichChatMessage], title: String,
            onAction: @escaping (UUID, String) -> Void,
            onReference: @escaping (UUID, String) -> Void,
            imageLoader: @escaping (UUID, String) async throws -> Data,
            onHeight: @escaping (CGFloat) -> Void = { _ in }
        ) {
            self.messages = messages
            self.title = title
            self.onAction = onAction
            self.onReference = onReference
            self.imageLoader = imageLoader
            self.onHeight = onHeight
        }

        public var body: some View {
            VStack(spacing: 0) {
                if let error = renderer.error {
                    VStack(alignment: .leading) {
                        HStack {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Reload Preview") { renderer.start() }
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                ForEach(messages) { message in
                                    Text(message.text).font(.headline)
                                    Text(message.answer ?? message.issue ?? "Waiting for a verified reply…")
                                        .textSelection(.enabled)
                                    ForEach(message.actions, id: \.id) { action in
                                        Button(action.title) { onAction(message.id, action.id) }
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding()
                } else if let webView = renderer.webView {
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            Button("Original Replies") { renderer.showOriginal() }.font(.caption).buttonStyle(.borderless)
                        }.padding(.horizontal, 12)
                        RichChatWebView(webView: webView)
                            .overlay {
                                if !renderer.ready {
                                    ProgressView("Preparing replies…").controlSize(.small)
                                }
                            }
                    }
                }
            }
            .task {
                renderer.onAction = onAction
                renderer.onReference = onReference
                renderer.imageLoader = imageLoader
                renderer.onHeight = onHeight
                renderer.start()
            }
            .onChange(of: messages, initial: true) {
                renderer.onAction = onAction
                renderer.onReference = onReference
                renderer.imageLoader = imageLoader
                renderer.onHeight = onHeight
                renderer.update(messages: messages, title: title, dark: colorScheme == .dark)
            }
            .onChange(of: colorScheme) { renderer.update(messages: messages, title: title, dark: colorScheme == .dark) }
            .onChange(of: title) { renderer.update(messages: messages, title: title, dark: colorScheme == .dark) }
            .onDisappear { renderer.stop() }
        }
    }

    @MainActor @Observable
    final class RichChatRenderer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private(set) var webView: WKWebView?
        private(set) var error: String?
        private(set) var ready = false
        @ObservationIgnored var onAction: (UUID, String) -> Void = { _, _ in }
        @ObservationIgnored var onReference: (UUID, String) -> Void = { _, _ in }
        @ObservationIgnored var imageLoader: ((UUID, String) async throws -> Data)?
        @ObservationIgnored var onHeight: (CGFloat) -> Void = { _ in }
        @ObservationIgnored private var messages: [RichChatMessage] = []
        @ObservationIgnored private var title = "Orbie"
        @ObservationIgnored private var dark = false
        @ObservationIgnored private var generation = UUID()
        @ObservationIgnored private var updateTask: Task<Void, Never>?
        @ObservationIgnored private var timeoutTask: Task<Void, Never>?
        @ObservationIgnored private var imageTasks: [String: Task<Void, Never>] = [:]
        private static let world = WKContentWorld.world(name: "OrbieNative")
        static let origin = URL(string: "https://orbie.ctrlx.invalid/")

        func start() {
            stop()
            error = nil
            do {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                let controller = configuration.userContentController
                controller.add(self, contentWorld: Self.world, name: "orbie")
                controller.addUserScript(WKUserScript(source: """
                document.addEventListener('orbie-native', event => {
                    if (typeof event.detail === 'string') window.webkit.messageHandlers.orbie.postMessage(event.detail);
                });
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
                for (directory, name) in [
                    ("ArtifactPreview", "marked.umd.js"), ("ArtifactPreview", "purify.min.js"),
                    ("ArtifactPreview", "svg.js"),
                    ("ArtifactPreview", "mermaid.min.js"), ("OrbieChat", "vendor.js"), ("OrbieChat", "chat.js"),
                ] {
                    try controller.addUserScript(WKUserScript(source: Self.resource(name, in: directory), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
                }
                let css = try ["markdown.css", "highlight.css", "chat.css"].map { try Self.resource($0, in: "OrbieChat") }.joined(separator: "\n")
                    + "\n@media(prefers-color-scheme:dark){" + (Self.resource("highlight-dark.css", in: "OrbieChat")) + "}"
                let html = """
                <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
                <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; frame-src about:; connect-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
                <style>\(css)</style></head><body><main id="messages" aria-label="Conversation"></main><button id="latest" hidden>Back to latest ↓</button></body></html>
                """
                let view = WKWebView(frame: .zero, configuration: configuration)
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.navigationDelegate = self
                view.allowsMagnification = true
                webView = view
                // A real document origin is needed for the frame handshake. This loads bytes, never the URL.
                view.loadHTMLString(html, baseURL: Self.origin)
                let token = generation
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    guard let self, generation == token, !ready else { return }
                    fail("The conversation preview did not respond. Your original reply is available below.")
                }
            } catch { fail(error.localizedDescription) }
        }

        private static func resource(_ name: String, in directory: String) throws -> String {
            guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: directory) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }

        func update(messages: [RichChatMessage], title: String, dark: Bool) {
            self.messages = messages
            self.title = title
            self.dark = dark
            publish()
        }

        private func publish() {
            guard ready, let webView else { return }
            webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            updateTask?.cancel()
            let token = generation
            let messages = messages
            let title = title
            let dark = dark
            updateTask = Task { [weak self] in
                do {
                    let encoding = Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        let encoded = try JSONEncoder().encode(messages)
                        let json = String(decoding: encoded, as: UTF8.self)
                        try Task.checkCancellation()
                        return json
                    }
                    let encoded = try await withTaskCancellationHandler {
                        try await encoding.value
                    } onCancel: { encoding.cancel() }
                    guard !Task.isCancelled, let self, generation == token else { return }
                    _ = try await webView.callAsyncJavaScript(
                        "window.orbieChat.update(JSON.parse(messages), title, dark);",
                        arguments: ["messages": encoded, "title": title, "dark": dark],
                        in: nil, contentWorld: .page
                    )
                } catch {
                    guard let self, generation == token, !Task.isCancelled else { return }
                    fail("The conversation preview stopped. Your original reply is available below.")
                }
            }
        }

        func stop() {
            generation = UUID()
            ready = false
            updateTask?.cancel()
            timeoutTask?.cancel()
            for task in imageTasks.values {
                task.cancel()
            }
            imageTasks.removeAll()
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "orbie", contentWorld: Self.world)
            webView?.configuration.userContentController.removeAllUserScripts()
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView?.loadHTMLString("", baseURL: nil)
            webView = nil
        }

        private func fail(_ reason: String) {
            stop()
            error = reason
        }

        func showOriginal() {
            fail("Original replies")
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard
                let webView, message.frameInfo.isMainFrame, message.webView === webView,
                let body = message.body as? String, body.utf8.count <= 16_384,
                let data = body.data(using: .utf8),
                let payload = try? JSONDecoder().decode(Event.self, from: data) else { return }
            if payload.kind == "ready" {
                ready = true
                timeoutTask?.cancel()
                publish()
                return
            }
            if payload.kind == "height", let height = payload.height, height.isFinite {
                onHeight(min(100_000, max(0, height)))
                return
            }
            guard let id = payload.messageID, let model = messages.first(where: { $0.id == id }) else { return }
            if payload.kind == "action", let action = payload.target, model.actions.contains(where: { $0.id == action }) {
                onAction(id, action)
            } else if payload.kind == "reference", let index = payload.reference, model.references.indices.contains(index) {
                onReference(id, model.references[index].path)
            } else if
                payload.kind == "image", let target = payload.target, let key = payload.key,
                target.utf8.count <= 4_096, key.utf8.count <= 100, model.answer != nil {
                loadImage(id: id, target: target, key: key)
            } else if payload.kind == "code", let index = payload.reference, index > 0, index <= 10_000 {
                copyCode(id: id, index: index)
            } else if
                payload.kind == "url", let target = payload.target,
                model.answer != nil, let url = URL(string: target),
                ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        }

        private func copyCode(id: UUID, index: Int) {
            guard let webView else { return }
            let token = generation
            Task { [weak self] in
                do {
                    let result = try await webView.callAsyncJavaScript("return window.orbieChat.code(id, index);", arguments: ["id": id.uuidString, "index": index], in: nil, contentWorld: .page)
                    guard
                        let self, generation == token, let text = result as? String,
                        text.utf8.count <= 512 * 1_024,
                        messages.contains(where: { $0.id == id && $0.answer != nil }) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } catch {
                    guard let self, generation == token else { return }
                    fail("The code could not be copied. Copy the original reply below.")
                }
            }
        }

        private func loadImage(id: UUID, target: String, key: String) {
            guard imageTasks[key] == nil else { return }
            let token = generation
            imageTasks[key] = Task { [weak self] in
                guard let self else { return }
                var base64 = "", failure = "", svg = ""
                do {
                    let path = try TerminalArtifactPreview.workspacePath(for: target)
                    guard let imageLoader else { throw CocoaError(.featureUnsupported) }
                    let bytes = try await imageLoader(id, target)
                    if (path as NSString).pathExtension.lowercased() == "svg" {
                        svg = try TerminalArtifactPreview.svgSource(bytes)
                    } else {
                        let png = try await Task.detached { try ArtifactPreviewImage.png(from: bytes, maximumPixelSize: 1_600) }.value
                        base64 = png.base64EncodedString()
                    }
                } catch is CancellationError { return }
                catch { failure = error.localizedDescription }
                guard generation == token, !Task.isCancelled, let webView else { return }
                imageTasks[key] = nil
                do {
                    _ = try await webView.callAsyncJavaScript("window.orbieChat.image(key, base64, error, svg);", arguments: ["key": key, "base64": base64, "error": failure, "svg": svg], in: nil, contentWorld: .page)
                } catch {
                    guard generation == token else { return }
                    fail("The preview could not load its image. Your original reply is available below.")
                }
            }
        }

        private struct Event: Decodable {
            let kind: String
            var messageID: UUID?
            var target: String?
            var reference: Int?
            var key: String?
            var height: Double?
        }

        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = action.request.url
            if action.targetFrame?.isMainFrame == true {
                return action.navigationType == .other && (url == Self.origin || url?.absoluteString == "about:blank") ? .allow : .cancel
            }
            return action.navigationType == .other && ["about:srcdoc", "about:blank"].contains(url?.absoluteString ?? "") ? .allow : .cancel
        }

        func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
            guard view === webView else { return }
            fail("The conversation preview stopped. Reload it to try again.")
        }
    }

    private struct RichChatWebView: NSViewRepresentable {
        let webView: WKWebView
        func makeNSView(context: Context) -> WKWebView {
            webView
        }

        func updateNSView(_: WKWebView, context: Context) { }
    }
#endif
