import CtrlxNetworking
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum WorkspaceClipboardError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case let .message(message): message }
    }
}

public extension ClipboardClient {
    func workspaceContent() throws -> WorkspaceClipboardContent {
        if let image = getImage() {
            return try WorkspaceClipboard.image(image.data)
        }
        guard let text = getString(), !text.isEmpty else {
            throw WorkspaceClipboardError.message("Copy text or an image first.")
        }
        return try WorkspaceClipboard.prepare(.init(text: text))
    }

    func setWorkspaceContent(_ content: WorkspaceClipboardContent) throws {
        guard content.isValid else { throw WorkspaceClipboardError.message("Invalid clipboard content.") }
        switch content.kind {
        case .text: setString(String(decoding: content.data, as: UTF8.self))
        case .png,
             .jpeg:
            guard
                let source = CGImageSourceCreateWithData(content.data as CFData, nil),
                CGImageSourceGetCount(source) > 0 else {
                throw WorkspaceClipboardError.message("Cannot decode the copied image.")
            }
            setImage(ClipboardImage(data: content.data, format: content.kind == .png ? .png : .jpeg))
        }
    }
}

public enum WorkspaceClipboard {
    public static func prepare(_ content: WorkspaceClipboardContent) throws -> WorkspaceClipboardContent {
        if content.kind != .text {
            return try image(content.data)
        }
        guard content.isValid else {
            throw WorkspaceClipboardError.message("Clipboard text exceeds the transfer size limit or is invalid.")
        }
        return content
    }

    public static func image(_ data: Data) throws -> WorkspaceClipboardContent {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw WorkspaceClipboardError.message("Cannot decode the clipboard image.")
        }
        if data.count <= WorkspaceClipboardContent.maximumBytes {
            for kind in [WorkspaceClipboardContent.Kind.png, .jpeg] {
                let content = WorkspaceClipboardContent(kind: kind, data: data)
                if content.isValid {
                    return content
                }
            }
        }
        // Avoid upscaling small images while re-encoding inefficient PNGs.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let largestDimension = max(
            properties?[kCGImagePropertyPixelWidth] as? Int ?? 0,
            properties?[kCGImagePropertyPixelHeight] as? Int ?? 0,
        )
        // Keep transparency and use a bounded preview when the encoded payload is too large.
        for dimension in [1_920, 1_280, 960, 640, 320] {
            guard
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: min(dimension, max(1, largestDimension)),
                ] as CFDictionary) else { break }
            let encoded = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(output, image, nil)
            if CGImageDestinationFinalize(output) {
                let content = WorkspaceClipboardContent(kind: .png, data: encoded as Data)
                if content.isValid {
                    return content
                }
            }
        }
        throw WorkspaceClipboardError.message("The clipboard image cannot fit within the transfer size limit.")
    }
}
