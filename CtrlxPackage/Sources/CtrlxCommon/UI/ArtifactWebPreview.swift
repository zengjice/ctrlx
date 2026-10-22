#if os(macOS) || os(iOS)
    import Foundation
    import ImageIO
    import Observation
    import SwiftUI
    import UniformTypeIdentifiers
    import WebKit

    @MainActor @Observable
    final class ArtifactWebRenderer: NSObject, WKNavigationDelegate {
        private(set) var isReady = false
        private(set) var error: String?
        private(set) var png: Data?
        @ObservationIgnored let webView: WKWebView
        @ObservationIgnored private var navigation: WKNavigation?
        @ObservationIgnored private var renderTask: Task<Void, Never>?
        @ObservationIgnored private var timeoutTask: Task<Void, Never>?
        @ObservationIgnored private var generation = UUID()
        @ObservationIgnored private var payload: (content: String, mermaid: Bool, dark: Bool)?

        override init() {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            self.webView = WKWebView(frame: .zero, configuration: configuration)
            super.init()
            #if os(macOS)
                webView.allowsMagnification = true
            #else
                webView.isOpaque = false
                webView.backgroundColor = .clear
                let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
                doubleTap.numberOfTapsRequired = 2
                doubleTap.delegate = self
                webView.addGestureRecognizer(doubleTap)
            #endif
        }

        func load(content: String, mermaid: Bool, dark: Bool) {
            stop()
            isReady = false
            error = nil
            png = nil
            payload = (content, mermaid, dark)
            #if os(macOS)
                webView.underPageBackgroundColor = dark ? NSColor(white: 0.118, alpha: 1) : .white
            #else
                webView.underPageBackgroundColor = dark ? UIColor(white: 0.118, alpha: 1) : .white
            #endif
            guard let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "ArtifactPreview") else {
                error = "The preview renderer is missing. Reinstall CtrlX."
                return
            }
            webView.navigationDelegate = self
            navigation = webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            let token = generation
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self, self.generation == token, !self.isReady else { return }
                self.stop()
                self.error = "The preview took too long to render. Try a smaller diagram."
            }
        }

        func stop() {
            generation = UUID()
            renderTask?.cancel()
            renderTask = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            webView.stopLoading()
            webView.navigationDelegate = nil
        }

        func fit() {
            #if os(macOS)
                webView.setMagnification(1, centeredAt: .zero)
            #else
                webView.scrollView.setZoomScale(webView.scrollView.minimumZoomScale, animated: true)
                webView.scrollView.setContentOffset(.zero, animated: true)
            #endif
        }

        #if os(iOS)
            @objc
            private func doubleTap(_ recognizer: UITapGestureRecognizer) {
                let scroll = webView.scrollView
                guard scroll.zoomScale <= scroll.minimumZoomScale + 0.01 else {
                    fit()
                    return
                }
                let scale = min(3, scroll.maximumZoomScale)
                let point = recognizer.location(in: scroll)
                let anchor = CGPoint(x: point.x / scroll.zoomScale, y: point.y / scroll.zoomScale)
                scroll.setZoomScale(scale, animated: false)
                scroll.setContentOffset(CGPoint(
                    x: max(0, min(anchor.x * scale - scroll.bounds.width / 2, scroll.contentSize.width - scroll.bounds.width)),
                    y: max(0, min(anchor.y * scale - scroll.bounds.height / 2, scroll.contentSize.height - scroll.bounds.height))
                ), animated: false)
            }
        #endif

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === self.navigation, let payload else { return }
            let token = generation
            renderTask = Task { [weak self] in
                do {
                    let result = try await webView.callAsyncJavaScript(
                        "return await window.renderPreview(content, isMermaid, dark);",
                        arguments: ["content": payload.content, "isMermaid": payload.mermaid, "dark": payload.dark],
                        in: nil, contentWorld: .page
                    )
                    try Task.checkCancellation()
                    guard let self, self.generation == token else { return }
                    guard let base64 = result as? String, let png = Data(base64Encoded: base64) else {
                        throw FileBrowserError.message("The renderer returned no image.")
                    }
                    self.png = png
                    self.isReady = true
                    self.timeoutTask?.cancel()
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                    self.timeoutTask?.cancel()
                }
            }
        }

        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let index = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "ArtifactPreview")
            return action.request.url == index && action.navigationType == .other ? .allow : .cancel
        }

        func webView(_: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            guard navigation === self.navigation else { return }
            self.error = error.localizedDescription
            timeoutTask?.cancel()
        }

        func webViewWebContentProcessDidTerminate(_: WKWebView) {
            stop()
            error = "The preview renderer stopped. Close the preview and try again."
        }
    }

    enum ArtifactPreviewImage {
        nonisolated static func png(from data: Data) throws -> Data {
            guard
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4_096,
                ] as CFDictionary) else { throw FileBrowserError.message("This image cannot be decoded.") }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
                throw FileBrowserError.message("This image cannot be prepared for preview.")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw FileBrowserError.message("This image cannot be prepared for preview.") }
            return output as Data
        }
    }

    #if os(macOS)
        struct ArtifactWebPreview: NSViewRepresentable {
            let renderer: ArtifactWebRenderer
            func makeNSView(context: Context) -> WKWebView {
                renderer.webView
            }

            func updateNSView(_ view: WKWebView, context: Context) { }
        }
    #else
        extension ArtifactWebRenderer: UIGestureRecognizerDelegate {
            func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
                // WebKit's child tap recognizers must not consume the preview's double tap.
                other is UITapGestureRecognizer
            }
        }

        struct ArtifactWebPreview: UIViewRepresentable {
            let renderer: ArtifactWebRenderer
            func makeUIView(context: Context) -> WKWebView {
                renderer.webView
            }

            func updateUIView(_ view: WKWebView, context: Context) { }
        }
    #endif
#endif
