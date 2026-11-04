import CryptoKit
import CtrlxNetworking
import Dependencies
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct AgentWorkflowImage: Sendable {
    static let maximumBytes = 20 * 1_024 * 1_024
    let data: Data
    let name: String
    let mediaType: String
    let sha256: String

    @concurrent
    static func read(_ url: URL) async throws -> Self {
        @Dependency(FileBrowserUploadReader.self) var reader
        let file = try await reader.open(url)
        let data: Data
        do {
            guard file.size <= maximumBytes else { throw AgentWorkflowError("Choose an image up to 20 MiB.") }
            var bytes = Data()
            while bytes.count < file.size {
                try Task.checkCancellation()
                let chunk = try await reader.read(file.id)
                guard !chunk.isEmpty, chunk.count <= file.size - bytes.count else {
                    throw AgentWorkflowError("The image snapshot is incomplete.")
                }
                bytes.append(chunk)
            }
            _ = try await reader.finish(file.id)
            data = bytes
        } catch {
            await reader.close(file.id)
            throw error
        }
        await reader.close(file.id)
        return try await prepare(data, name: file.name)
    }

    @concurrent
    static func prepare(_ data: Data, name: String) async throws -> Self {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maximumBytes else { throw AgentWorkflowError("Choose an image up to 20 MiB.") }
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source),
            UTType(type as String)?.conforms(to: .image) == true,
            let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else {
            throw AgentWorkflowError("Only images can be attached. Reference other files by their workspace paths.")
        }
        let encoded: Data
        if type as String == UTType.png.identifier || type as String == UTType.jpeg.identifier {
            encoded = data
        } else {
            let output = NSMutableData()
            guard
                let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(image.width, image.height),
                ] as CFDictionary),
                let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
                throw AgentWorkflowError("This image could not be converted to PNG.")
            }
            CGImageDestinationAddImage(destination, upright, nil)
            guard CGImageDestinationFinalize(destination) else { throw AgentWorkflowError("This image could not be converted to PNG.") }
            encoded = output as Data
        }
        guard let optimized = RelayImagePreparer.prepare(encoded, maxBytes: SendDroppedFiles.maxRawBytes) else {
            throw AgentWorkflowError("This image could not be prepared for transfer.")
        }
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let filename = (base.isEmpty ? "Image" : base) + "." + optimized.format.fileExtension
        guard SessionDirectoryName.isValid(filename) else { throw AgentWorkflowError("The image filename is invalid.") }
        try Task.checkCancellation()
        return .init(
            data: optimized.data,
            name: filename,
            mediaType: optimized.format == .jpeg ? "image/jpeg" : "image/png",
            sha256: SHA256.hash(data: optimized.data).map { String(format: "%02x", $0) }.joined()
        )
    }
}
