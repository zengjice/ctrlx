import CryptoKit
import CtrlxEncryption
import CtrlxNetworking
import Foundation
import ImageIO
import Testing
@testable import CtrlxCommon

#if os(macOS)
    import AppKit
#endif

@MainActor
struct WorkspaceClipboardTests {
    /// A complete 2×2 PNG, not a magic-header-only fixture.
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQaPjQAMIMMAYARzIIQdQEEEMAAAAASUVORK5CYII=")!

    @Test
    func validSlashHeavyPNGIsPreparedForBothDirections() throws {
        let original = Self.slashHeavyPNG()
        #expect(original.count == 384_593)
        let source = try #require(CGImageSourceCreateWithData(original as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 400 && decoded.height == 240)
        let oversized = WorkspaceClipboardContent(kind: .png, data: original)
        #expect(!oversized.isValid)
        #expect(try JSONEncoder().encode(oversized).count > 768 * 1_024)
        // Viewer paste and Host copy responses share preparation.
        for content in try [WorkspaceClipboard.image(original), WorkspaceClipboard.prepare(oversized)] {
            #expect(content.isValid && content.data != original)
            let preparedSource = try #require(CGImageSourceCreateWithData(content.data as CFData, nil))
            let prepared = try #require(CGImageSourceCreateImageAtIndex(preparedSource, 0, nil))
            #expect(prepared.width == decoded.width && prepared.height == decoded.height)
            let simulator = ControlSimulator(sessionName: "work", tabID: UUID(), surfaceID: UUID(), controlID: UUID(), generation: 1, operation: .paste(content))
            let browser = BrowseBrowser(sessionName: "work", tabID: UUID(), surfaceID: UUID(), controlID: UUID(), operation: .paste(content))
            let messages: [WebSocketMessage] = [
                .command(.init(paneId: "%1", command: simulator.commandType)),
                .command(.init(paneId: "%1", command: browser.commandType)),
                .commandResponse(.init(commandId: UUID(), success: true, browser: .init(controlID: UUID(), clipboard: content))),
                .commandResponse(.init(commandId: UUID(), success: true, simulatorControl: .init(controlID: UUID(), generation: 1, clipboard: content))),
            ]
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let native: [String: JSONValue] = ["command": .string("clipboard-write"), "content": .object([
                "kind": .string(content.kind.rawValue), "data": .string(content.data.base64EncodedString()),
            ])]
            #expect(try encoder.encode(native).count < 768 * 1_024)
            for message in messages {
                let sealed = try ChaChaPoly.seal(encoder.encode(message), using: SymmetricKey(size: .bits256))
                let envelope = WebSocketMessage.encrypted(.init(payload: EncryptedPayload(ciphertext: sealed.combined, senderKeyId: UUID().uuidString)))
                #expect(try encoder.encode(envelope).count < RelayPayloadLimits.maxWebSocketFrameBytes)
            }
        }
    }

    /// Valid RGBA PNG with stored DEFLATE blocks: white pixels create slash-heavy Base64.
    private static func slashHeavyPNG() -> Data {
        func be32(_ value: UInt32) -> Data {
            Data([
                UInt8(truncatingIfNeeded: value >> 24),
                UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8),
                UInt8(truncatingIfNeeded: value),
            ])
        }
        func chunk(_ name: String, _ bytes: Data) -> Data {
            let body = Data(name.utf8) + bytes
            var crc: UInt32 = 0xFFFFFFFF
            for byte in body {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0)
                }
            }
            return be32(UInt32(bytes.count)) + body + be32(crc ^ 0xFFFFFFFF)
        }
        var pixels = Data()
        for _ in 0..<240 {
            pixels += Data([0]) + Data(repeating: 0xFF, count: 400 * 4)
        }
        var compressed = Data([0x78, 0x01])
        var offset = 0
        while offset < pixels.count {
            let size = min(65_535, pixels.count - offset), complement = 65_535 - size
            compressed += Data([
                offset + size == pixels.count ? 1 : 0,
                UInt8(truncatingIfNeeded: size),
                UInt8(truncatingIfNeeded: size >> 8),
                UInt8(truncatingIfNeeded: complement),
                UInt8(truncatingIfNeeded: complement >> 8),
            ])
            compressed += pixels.subdata(in: offset..<(offset + size))
            offset += size
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in pixels {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        compressed += be32((b << 16) | a)
        var result = Data([137, 80, 78, 71, 13, 10, 26, 10])
        result += chunk("IHDR", be32(400) + be32(240) + Data([8, 6, 0, 0, 0]))
        result += chunk("IDAT", compressed)
        result += chunk("npAD", Data(repeating: 0xFF, count: 384_593 - result.count - 24))
        return result + chunk("IEND", Data())
    }

    #if os(macOS)
        @Test(arguments: [false, true])
        func macJPEGPreservesOriginalBytesAndDimensions(withTIFF: Bool) throws {
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 3_000, pixelsHigh: 2_000,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
            ))
            try memset(#require(bitmap.bitmapData), 120, bitmap.bytesPerRow * bitmap.pixelsHigh)
            let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
            #expect(jpeg.count < 384 * 1_024)
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.setData(jpeg, forType: .init("public.jpeg"))
            if withTIFF {
                try pasteboard.setData(#require(bitmap.representation(using: .tiff, properties: [:])), forType: .tiff)
            }
            let image = try #require(ClipboardClient.readImage(from: pasteboard))
            #expect(image.format == .jpeg && image.data == jpeg)
            let content = try WorkspaceClipboard.image(image.data)
            #expect(content.kind == .jpeg && content.data == jpeg)
            let source = try #require(CGImageSourceCreateWithData(content.data as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 3_000)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == 2_000)
        }
    #endif

    @Test
    func imageAndTextReplaceEachOtherInLocalClipboard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ClipboardClient.fileBacked(path: directory.appendingPathComponent("clipboard").path)
        let image = try WorkspaceClipboard.image(png)
        #expect(image.data == png)
        try client.setWorkspaceContent(image)
        #expect(client.getString() == nil && client.getImage()?.data == png)
        try client.setWorkspaceContent(.init(text: "copy text"))
        #expect(client.getImage() == nil && client.getString() == "copy text")
        #expect(try client.workspaceContent() == .init(text: "copy text"))
        #expect(throws: (any Error).self) { try client.setWorkspaceContent(.init(kind: .png, data: Data([137, 80, 78, 71, 13, 10, 26, 10]))) }
        #expect(client.getString() == "copy text")
    }

    @Test
    func imageUploadCapturesDestinationAndVerifiesBytes() async {
        var bytes = Data(), saved = 0, name = ""
        let source = FileBrowserSource(id: "Host-A", paneID: "%1") { operation in
            guard case let .upload(request) = operation else { throw FileBrowserError.message("Expected upload") }
            switch request {
            case let .begin(_, directory, filename, size):
                #expect(directory == "/host/project" && size == png.count)
                name = filename
                return .uploaded(offset: 0, path: nil)
            case let .append(_, offset, data):
                #expect(offset == bytes.count)
                bytes.append(data)
                return .uploaded(offset: bytes.count, path: nil)
            case let .finish(_, hash):
                #expect(hash == SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined())
                return .uploaded(offset: bytes.count, path: "/host/project/\(name)")
            case .cancel: Issue.record("Unexpected cancellation")
                return .uploaded(offset: 0, path: nil)
            }
        }
        let upload = FileBrowserUpload()
        await upload.run(image: .init(kind: .png, data: png), directory: "/host/project", source: source) { saved += 1 }
        #expect(saved == 1 && bytes == png && upload.summary == "Image saved.")
    }
}
