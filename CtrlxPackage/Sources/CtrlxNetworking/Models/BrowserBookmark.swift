import Foundation

public struct BrowserBookmark: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let url: String

    public init(id: UUID = UUID(), title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }

    public static func normalizedURL(_ address: String) -> String? {
        guard let url = URL(string: address) else { return nil }
        return BrowserWebURL.normalized(url)?.absoluteString
    }
}

public enum BrowserBookmarkOperation: Codable, Sendable, Equatable {
    case list
    /// The Host supplies the actual page title and URL, not address-field edits.
    case saveCurrentPage
    case remove(UUID)
}
