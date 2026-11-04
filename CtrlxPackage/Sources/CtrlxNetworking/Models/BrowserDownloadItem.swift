import Foundation

/// Display-only state. A completed path always refers to the source Host.
public struct BrowserDownloadItem: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable {
        case downloading
        case saving
        case completed
        case failed
        case cancelled
    }

    public let id: UUID
    public var filename: String
    public var state: State = .downloading
    public var receivedBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var path: String?
    public var error: String?

    public init(id: UUID, filename: String) {
        self.id = id
        self.filename = filename
    }

    public var isActive: Bool {
        state == .downloading || state == .saving
    }
}
