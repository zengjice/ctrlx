import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation

/// One persistent list per Host, independent of sessions, panes and Chromium.
actor BrowserBookmarkStore {
    static let preferenceKey = "browserBookmarks"
    static let maximumCount = 256
    static let maximumBytes = 128 * 1_024
    private let preferences: PreferencesService

    init() {
        @Dependency(PreferencesService.self) var preferences
        self.preferences = preferences
    }

    func perform(_ operation: BrowserBookmarkOperation, url: String, title: String) throws -> [BrowserBookmark] {
        try Task.checkCancellation()
        let data = preferences.data(Self.preferenceKey)
        var bookmarks = try data.map { try JSONDecoder().decode([BrowserBookmark].self, from: $0) } ?? []
        switch operation {
        case .list: return bookmarks
        case .saveCurrentPage:
            guard let address = BrowserBookmark.normalizedURL(url) else {
                throw RemoteBrowserError.message("Only HTTP and HTTPS pages can be bookmarked.")
            }
            guard !bookmarks.contains(where: { $0.url == address }) else { return bookmarks }
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            bookmarks.insert(BrowserBookmark(title: String((name.isEmpty ? address : name).prefix(256)), url: address), at: 0)
        case let .remove(id):
            bookmarks.removeAll { $0.id == id }
        }
        let updated = try JSONEncoder().encode(bookmarks)
        guard bookmarks.count <= Self.maximumCount, updated.count <= Self.maximumBytes else {
            throw RemoteBrowserError.message("The bookmark list is full. Remove a bookmark before saving another.")
        }
        preferences.setData(updated, Self.preferenceKey)
        return bookmarks
    }
}
