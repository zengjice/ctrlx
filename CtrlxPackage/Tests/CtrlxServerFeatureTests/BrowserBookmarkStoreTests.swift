import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

struct BrowserBookmarkStoreTests {
    @Test
    func persistsDeduplicatesAndPreservesCompleteURLs() async throws {
        let preferences = PreferencesService.inMemory()
        try await withDependencies { $0[PreferencesService.self] = preferences } operation: {
            let store = BrowserBookmarkStore()
            let address = "https://example.com/Docs?a=1&a=2#section"
            let first = try await store.perform(.saveCurrentPage, url: "HTTPS://EXAMPLE.COM:443/Docs?a=1&a=2#section", title: " First ")
            #expect(first.count == 1 && first[0].url == address && first[0].title == "First")
            #expect(try await store.perform(.saveCurrentPage, url: address, title: "Renamed") == first)
            let second = try await store.perform(.saveCurrentPage, url: "http://localhost:3000/#other", title: "Second")
            #expect(second.map(\.title) == ["Second", "First"])
            let reopened = BrowserBookmarkStore()
            #expect(try await reopened.perform(.list, url: "", title: "") == second)
            let removed = try await reopened.perform(.remove(first[0].id), url: "", title: "")
            #expect(removed == [second[0]])
            #expect(try await store.perform(.list, url: "", title: "") == removed)
            #expect(try await store.perform(.remove(first[0].id), url: "", title: "") == removed)
        }
    }

    @Test
    func separateHostsHaveSeparateLists() async throws {
        let first = withDependencies { $0[PreferencesService.self] = .inMemory() } operation: { BrowserBookmarkStore() }
        let second = withDependencies { $0[PreferencesService.self] = .inMemory() } operation: { BrowserBookmarkStore() }
        _ = try await first.perform(.saveCurrentPage, url: "https://example.com", title: "")
        #expect(try await second.perform(.list, url: "", title: "").isEmpty)
    }

    @Test
    func concurrentSavesDoNotLoseEntries() async throws {
        let store = withDependencies { $0[PreferencesService.self] = .inMemory() } operation: { BrowserBookmarkStore() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = try await store.perform(.saveCurrentPage, url: "https://example.com/\(index % 10)", title: "Page")
                }
            }
            try await group.waitForAll()
        }
        #expect(try await store.perform(.list, url: "", title: "").count == 10)
    }

    @Test(arguments: ["about:blank", "chrome://settings", "file:///tmp/a", "javascript:alert(1)", "https://user:password@example.com"])
    func invalidURLsNeverOverwriteSavedData(_ url: String) async throws {
        let preferences = PreferencesService.inMemory()
        try await withDependencies { $0[PreferencesService.self] = preferences } operation: {
            let store = BrowserBookmarkStore()
            _ = try await store.perform(.saveCurrentPage, url: "https://example.com", title: "Page")
            let saved = preferences.data(BrowserBookmarkStore.preferenceKey)
            await #expect(throws: (any Error).self) { try await store.perform(.saveCurrentPage, url: url, title: "Bad") }
            #expect(preferences.data(BrowserBookmarkStore.preferenceKey) == saved)
        }
    }

    @Test
    func corruptStorageIsReportedAndPreserved() async {
        let preferences = PreferencesService.inMemory()
        let corrupt = Data("not JSON".utf8)
        preferences.setData(corrupt, BrowserBookmarkStore.preferenceKey)
        await withDependencies { $0[PreferencesService.self] = preferences } operation: {
            let store = BrowserBookmarkStore()
            await #expect(throws: (any Error).self) { try await store.perform(.saveCurrentPage, url: "https://example.com", title: "Page") }
            #expect(preferences.data(BrowserBookmarkStore.preferenceKey) == corrupt)
        }
    }

    @Test(arguments: [false, true])
    func countAndEncodedSizeLimitsPreserveExistingBookmarks(largeURLs: Bool) async throws {
        let preferences = PreferencesService.inMemory()
        try await withDependencies { $0[PreferencesService.self] = preferences } operation: {
            let store = BrowserBookmarkStore()
            let count = largeURLs ? 15 : BrowserBookmarkStore.maximumCount
            let suffix = largeURLs ? String(repeating: "a", count: 8_000) : ""
            for index in 0..<count {
                _ = try await store.perform(.saveCurrentPage, url: "https://example.com/\(index)\(suffix)", title: "Page")
            }
            if largeURLs {
                _ = try await store.perform(.saveCurrentPage, url: "https://example.com/extra\(suffix)", title: "Page")
            }
            let saved = try #require(preferences.data(BrowserBookmarkStore.preferenceKey))
            #expect(saved.count <= BrowserBookmarkStore.maximumBytes)
            await #expect(throws: (any Error).self) {
                try await store.perform(.saveCurrentPage, url: "https://example.com/overflow\(suffix)", title: "Page")
            }
            #expect(preferences.data(BrowserBookmarkStore.preferenceKey) == saved)
        }
    }
}
