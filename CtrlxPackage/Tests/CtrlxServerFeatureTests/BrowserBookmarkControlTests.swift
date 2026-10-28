import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct BrowserBookmarkControlTests {
    @Test
    func hostAndViewersShareBookmarksWithoutChangingPageControl() async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let (service, runtime, tab) = try await RemoteBrowserControlTests().fixture()
            let state = try #require(service.tabs[tab.id.uuidString])
            state.url = "https://example.com/path?key=value#section"
            state.title = "Host Page"
            let surface = UUID()
            func request(_ operation: RemoteBrowserOperation, control: UUID? = nil, session: String = "test") -> BrowseBrowser {
                .init(sessionName: session, tabID: tab.id, surfaceID: surface, controlID: control, generation: 4, operation: operation)
            }
            let saved = try await service.handleBrowser(request(.bookmarks(.saveCurrentPage)), viewerID: "viewer-a")
            let entry = try #require(saved.bookmarks?.first)
            #expect(entry.title == state.title && entry.url == state.url)
            #expect(saved.frame == nil && saved.controlID == nil)
            #expect(runtime.requests.isEmpty && runtime.controls.isEmpty && service.remoteControls.isEmpty)
            #expect(try await service.handleBookmarks(.list, tab: state) == saved.bookmarks)
            let anotherViewer = try await service.handleBrowser(request(.bookmarks(.list)), viewerID: "viewer-b")
            #expect(anotherViewer.bookmarks == saved.bookmarks)
            await #expect(throws: (any Error).self) {
                try await service.handleBrowser(request(.navigate(entry.url)), viewerID: "viewer-a")
            }
            let control = try await service.handleBrowser(request(.takeControl), viewerID: "viewer-a").controlID
            _ = try await service.handleBrowser(request(.bookmarks(.remove(entry.id))), viewerID: "viewer-b")
            #expect(try await service.handleBookmarks(.list, tab: state).isEmpty)
            #expect(service.remoteControls[tab.id]?.id == control)
            await #expect(throws: (any Error).self) {
                try await service.handleBrowser(request(.navigate(entry.url), control: control), viewerID: "viewer-b")
            }
            _ = try await service.handleBrowser(request(.navigate(entry.url), control: control), viewerID: "viewer-a")
            #expect(runtime.requests.last?["url"] as? String == entry.url)
            await #expect(throws: (any Error).self) {
                try await service.handleBrowser(request(.bookmarks(.list), session: "other"), viewerID: "viewer-a")
            }
            service.releaseBrowserControl(tab.id)
            state.isClosed = true
            await #expect(throws: (any Error).self) {
                try await service.handleBrowser(request(.bookmarks(.saveCurrentPage)), viewerID: "viewer-a")
            }
        }
    }
}
