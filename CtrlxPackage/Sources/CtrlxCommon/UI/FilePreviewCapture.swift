#if os(macOS) || os(iOS)
import CoreText
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One provider for the currently mounted preview. Never captures another window
/// or resolves the Host's file path against the Viewer's filesystem.
@MainActor
final class FilePreviewCapture {
    struct Snapshot: Sendable {
        let image: CGImage
        var detail: String? = nil
        var requiresVisibleContent = false
    }

    private var owner: UUID?
    private var provider: (@MainActor () async throws -> Snapshot)?

    func bind(owner: UUID, capture: @escaping @MainActor () async throws -> Snapshot) {
        self.owner = owner
        provider = capture
    }

    func unbind(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        provider = nil
    }

    func capture(filename: String) async throws -> Data {
        guard let provider, let owner else { throw FileBrowserError.message("Wait for the file preview to load, then try again.") }
        let snapshot = try await provider()
        try Task.checkCancellation()
        guard self.owner == owner else { throw CancellationError() }
        let data = try await Self.encode(snapshot, filename: filename)
        try Task.checkCancellation()
        guard self.owner == owner else { throw CancellationError() }
        return data
    }

    nonisolated static func caption(filename: String, detail: String?) -> String {
        [(filename as NSString).lastPathComponent, detail].compactMap { $0 }.joined(separator: " · ")
    }

    @concurrent static func encode(_ snapshot: Snapshot, filename: String) async throws -> Data {
        let image = snapshot.image
        // Quick Look assigns its preview item before drawing the document and
        // exposes no render-completion callback. Check the actual pixels before
        // adding a footer; a footer must not make an empty capture look valid.
        if snapshot.requiresVisibleContent, !hasVisibleContent(image) {
            throw FileBrowserError.message("The Office screenshot is blank. Wait for visible document content, then try again.")
        }
        let scale = min(1, 2560 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let imageHeight = max(1, Int(CGFloat(image.height) * scale))
        let footer = 44
        guard let context = CGContext(data: nil, width: width, height: imageHeight + footer,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FileBrowserError.message("Could not prepare the file screenshot.")
        }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: imageHeight + footer))
        context.draw(image, in: CGRect(x: 0, y: footer, width: width, height: imageHeight))
        // Only the basename is shared; never reveal a Host home or cache path.
        let caption = caption(filename: filename, detail: snapshot.detail)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: caption, attributes: attributes))
        context.textPosition = CGPoint(x: 12, y: 15)
        context.saveGState()
        context.clip(to: CGRect(x: 12, y: 0, width: max(1, width - 24), height: footer))
        CTLineDraw(line, context)
        context.restoreGState()
        let bytes = NSMutableData()
        guard let rendered = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw FileBrowserError.message("Could not encode the file screenshot.")
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { throw FileBrowserError.message("Could not encode the file screenshot.") }
        return bytes as Data
    }

    nonisolated private static func hasVisibleContent(_ image: CGImage) -> Bool {
        let scale = min(1, 512 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var reference: (Int, Int, Int)?
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            // Ignore transparent margins, including antialiased page edges.
            guard pixels[offset + 3] >= 250 else { continue }
            let color = (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
            if let reference {
                if abs(color.0 - reference.0) > 12 || abs(color.1 - reference.1) > 12 || abs(color.2 - reference.2) > 12 {
                    return true
                }
            } else {
                reference = color
            }
        }
        return false
    }

    #if os(macOS)
    static func snapshot(_ view: NSView) throws -> CGImage {
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor,
              view.bounds.width > 0, view.bounds.height > 0 else {
            throw FileBrowserError.message("The file preview is not visible.")
        }
        let scale = min(view.window?.backingScaleFactor ?? 1, 2560 / max(view.bounds.width, view.bounds.height))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(view.bounds.width * scale)), pixelsHigh: max(1, Int(view.bounds.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw FileBrowserError.message("Could not capture the file preview.")
        }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw FileBrowserError.message("Could not capture the file preview.") }
        return image
    }
    #else
    static func snapshot(_ view: UIView) throws -> CGImage {
        guard let window = view.window, !view.isHidden, view.bounds.width > 0, view.bounds.height > 0 else {
            throw FileBrowserError.message("The file preview is not visible.")
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(window.screen.scale, 2560 / max(view.bounds.width, view.bounds.height))
        format.opaque = true
        var complete = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            complete = view.drawHierarchy(in: CGRect(origin: .zero, size: view.bounds.size), afterScreenUpdates: true)
        }
        guard complete, let image = image.cgImage else {
            throw FileBrowserError.message("The system could not capture the complete preview. Wait for it to load and try again.")
        }
        return image
    }
    #endif
}

/// A hosting boundary gives text/Markdown and image previews an exact capture
/// area, excluding surrounding directories, toolbars and annotation controls.
struct FilePreviewHostedContent<Content: View>: View {
    let content: Content
    let environment: EnvironmentValues
    var body: some View { content.environment(\.self, environment) }
}

#if os(macOS)
struct FilePreviewSnapshotView<Content: View>: NSViewRepresentable {
    let capture: FilePreviewCapture
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> NSHostingView<FilePreviewHostedContent<Content>> {
        let view = NSHostingView(rootView: FilePreviewHostedContent(content: content, environment: context.environment))
        view.sizingOptions = []
        capture.bind(owner: context.coordinator) { [weak view] in
            guard let view else { throw CancellationError() }
            return .init(image: try FilePreviewCapture.snapshot(view))
        }
        return view
    }

    func updateNSView(_ view: NSHostingView<FilePreviewHostedContent<Content>>, context: Context) {
        view.rootView = .init(content: content, environment: context.environment)
    }
    func makeCoordinator() -> UUID { UUID() }
}
#else
struct FilePreviewSnapshotView<Content: View>: UIViewControllerRepresentable {
    let capture: FilePreviewCapture
    @ViewBuilder let content: Content

    func makeUIViewController(context: Context) -> UIHostingController<FilePreviewHostedContent<Content>> {
        let controller = UIHostingController(rootView: FilePreviewHostedContent(content: content, environment: context.environment))
        capture.bind(owner: context.coordinator) { [weak controller] in
            guard let view = controller?.view else { throw CancellationError() }
            return .init(image: try FilePreviewCapture.snapshot(view))
        }
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<FilePreviewHostedContent<Content>>, context: Context) {
        controller.rootView = .init(content: content, environment: context.environment)
    }
    func makeCoordinator() -> UUID { UUID() }
}
#endif
#endif
