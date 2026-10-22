import Foundation

/// One explicit copy/paste operation. Images are bounded below the encrypted Relay envelope limit.
public struct WorkspaceClipboardContent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case text, png, jpeg }
    public static let maximumBytes = 384 * 1_024
    // Count Base64 and JSON slash escaping, leaving room for request metadata and
    // the encrypted Relay envelope (including its second Base64 encoding).
    public static let maximumEncodedBytes = 576 * 1_024
    public let kind: Kind
    public let data: Data

    public init(kind: Kind, data: Data) {
        self.kind = kind
        self.data = data
    }

    public init(text: String) {
        self.init(kind: .text, data: Data(text.utf8))
    }

    public var isValid: Bool {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { return false }
        guard let encoded = try? JSONEncoder().encode(self), encoded.count <= Self.maximumEncodedBytes else { return false }
        switch kind {
        case .text: return String(data: data, encoding: .utf8) != nil
        case .png: return data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        case .jpeg: return data.starts(with: [255, 216, 255])
        }
    }

    public var mimeType: String {
        switch kind {
        case .text: "text/plain"
        case .png: "image/png"
        case .jpeg: "image/jpeg"
        }
    }
}
