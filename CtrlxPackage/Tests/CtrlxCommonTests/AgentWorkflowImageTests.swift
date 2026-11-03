import ConcurrencyExtras
import CoreGraphics
import CryptoKit
import CtrlxNetworking
import Dependencies
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CtrlxCommon

@MainActor
struct AgentWorkflowImageTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQaPjQAMIMMAYARzIIQdQEEEMAAAAASUVORK5CYII=")!

    private func encoded(_ type: UTType) throws -> Data {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        try #require(CGImageDestinationFinalize(output))
        return data as Data
    }

    @Test(arguments: ["png", "jpeg"])
    func efficientFormatsKeepOriginalBytesAndDimensions(format: String) async throws {
        let data = try format == "png" ? png : encoded(.jpeg)
        let image = try await AgentWorkflowImage.prepare(data, name: "Capture.\(format)")
        #expect(image.data == data)
        #expect(image.mediaType == "image/\(format)")
        #expect(image.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        #expect(image.name == (format == "png" ? "Capture.png" : "Capture.jpg"))
    }

    @Test
    func tiffClipboardImageConvertsWithoutResizing() async throws {
        let image = try await AgentWorkflowImage.prepare(encoded(.tiff), name: "Clipboard.tiff")
        #expect(image.mediaType == "image/png" && image.name == "Clipboard.png")
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 2 && decoded.height == 2)
    }

    @Test
    func convertedImageBakesInItsOrientation() async throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 3, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let pixels = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, [kCGImagePropertyOrientation: 6] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        let image = try await AgentWorkflowImage.prepare(data as Data, name: "Portrait.tiff")
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 3 && decoded.height == 2)
    }

    @Test(arguments: [Data(), Data("# Report\nNot an image".utf8), Data(repeating: 1, count: AgentWorkflowImage.maximumBytes + 1)])
    func nonImagesAndOversizedInputsAreRejected(data: Data) async {
        await #expect(throws: AgentWorkflowError.self) { try await AgentWorkflowImage.prepare(data, name: "pretend.png") }
    }

    @Test
    func imageProviderPrefersOriginalJPEGOverConvertedTIFF() async throws {
        let jpeg = try encoded(.jpeg)
        let tiff = try encoded(.tiff)
        let loaded = LockIsolated<[String]>([])
        let provider = NSItemProvider()
        provider.suggestedName = "Screenshot.jpeg"
        for (type, data) in [(UTType.tiff, tiff), (.jpeg, jpeg)] {
            provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
                loaded.withValue { $0.append(type.identifier) }
                completion(data, nil)
                return nil
            }
        }
        let image = try await AgentWorkflowImageSource.provider(provider).load()
        #expect(image.data == jpeg && image.mediaType == "image/jpeg")
        #expect(loaded.value == [UTType.jpeg.identifier])
    }

    @Test
    func draggedFileURLUsesSnapshotReaderAndClosesIt() async throws {
        let url = URL(fileURLWithPath: "/workspace/Images/需求.png")
        let bytes = png
        let id = UUID(), closed = LockIsolated(false)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(url.dataRepresentation, nil)
            return nil
        }
        let image = try await withDependencies {
            $0[FileBrowserUploadReader.self] = .init(
                open: {
                    #expect($0 == url)
                    return .init(id: id, name: url.lastPathComponent, size: bytes.count)
                }, read: { _ in bytes }, finish: { _ in "verified" }, close: { _ in closed.setValue(true) }
            )
        } operation: { try await AgentWorkflowImageSource.provider(provider).load() }
        #expect(image.data == png && image.name == "需求.png" && closed.value)
    }

    @Test
    func oversizedFileIsClosedBeforeReadingAnyBytes() async {
        let closed = LockIsolated(false)
        await withDependencies {
            $0[FileBrowserUploadReader.self] = .init(
                open: { _ in .init(id: UUID(), name: "huge.png", size: AgentWorkflowImage.maximumBytes + 1) },
                read: { _ in Issue.record("Oversized image was read")
                    return Data()
                },
                finish: { _ in Issue.record("Oversized image was hashed")
                    return ""
                },
                close: { _ in closed.setValue(true) }
            )
        } operation: {
            await #expect(throws: AgentWorkflowError.self) { try await AgentWorkflowImage.read(URL(fileURLWithPath: "/workspace/huge.png")) }
        }
        #expect(closed.value)
    }

    @Test(arguments: ["success", "badReceipt", "cancel"])
    func pastedImageUsesVerifiedUploadAndCleansFailedImports(outcome: String) async throws {
        let image = try await AgentWorkflowImage.prepare(png, name: "Clipboard")
        let hostID = UUID()
        var id: UUID?, received = Data(), cancelled = false, discarded = false
        let endpoint = AgentWorkflowEndpoint(id: "viewer", name: "Remote", connected: { true }, supported: { true }) { request in
            #expect(request.expectedHostID == hostID)
            var response = AgentWorkflowResponse(hostID: hostID)
            switch request.operation {
            case let .uploadAttachment(.begin(uploadID, name, mediaType, size)):
                id = uploadID
                #expect(name == image.name && mediaType == image.mediaType && size == image.data.count)
                response.uploadedOffset = 0
            case let .uploadAttachment(.append(uploadID, offset, bytes)):
                #expect(uploadID == id && offset == received.count)
                received.append(bytes)
                response.uploadedOffset = received.count
            case let .uploadAttachment(.finish(uploadID, sha256)):
                #expect(sha256 == image.sha256)
                response.uploadedOffset = received.count
                response.attachments = [.init(id: uploadID, name: image.name, mediaType: image.mediaType, byteCount: Int64(received.count), sha256: outcome == "badReceipt" ? "wrong" : sha256)]
                if outcome == "cancel" {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            case let .uploadAttachment(.cancel(uploadID)):
                #expect(uploadID == id)
                cancelled = true
                response.uploadedOffset = 0
            case let .discardAttachments(ids):
                #expect(ids == id.map { [$0] })
                discarded = true
            default: Issue.record("Unexpected operation")
            }
            return response
        }
        let upload = Task { try await endpoint.importImage(image, hostID: hostID) }
        if outcome == "success" {
            let attachment = try await upload.value
            #expect(attachment.id == id && attachment.sha256 == image.sha256)
            #expect(!cancelled && !discarded && received == png)
        } else {
            await #expect(throws: (any Error).self) { try await upload.value }
            #expect(cancelled && discarded)
        }
    }
}
