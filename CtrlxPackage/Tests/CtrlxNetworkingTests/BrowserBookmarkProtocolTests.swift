import Foundation
import Testing
@testable import CtrlxNetworking

struct BrowserBookmarkProtocolTests {
    @Test
    func compatibility() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let legacy = SessionStateMessage(pairId: "a", paneStates: [:])
        #expect(try decoder.decode(SessionStateMessage.self, from: encoder.encode(legacy)).supportsBrowserBookmarks == nil)
        let current = SessionStateMessage(pairId: "a", paneStates: [:], supportsBrowserBookmarks: true).withPairId("b")
        #expect(try decoder.decode(SessionStateMessage.self, from: encoder.encode(current)).supportsBrowserBookmarks == true)
        #expect(current.pairId == "b")
        #expect(try decoder.decode(RemoteBrowserResponse.self, from: Data("{}".utf8)).bookmarks == nil)
        struct LegacyResponse: Decodable { let controlID: UUID? }
        let response = RemoteBrowserResponse(bookmarks: [.init(title: "Page", url: "https://example.com/path?q=1#part")])
        #expect(try decoder.decode(RemoteBrowserResponse.self, from: encoder.encode(response)) == response)
        #expect(try decoder.decode(LegacyResponse.self, from: encoder.encode(response)).controlID == nil)
    }

    @Test
    func operationsRoundTripWithoutAControlToken() throws {
        for operation in [BrowserBookmarkOperation.list, .saveCurrentPage, .remove(UUID())] {
            let request = BrowseBrowser(sessionName: "test", tabID: UUID(), surfaceID: UUID(), operation: .bookmarks(operation))
            let data = try JSONEncoder().encode(request)
            #expect(try JSONDecoder().decode(BrowseBrowser.self, from: data) == request)
            #expect(request.controlID == nil && request.generation == nil)
        }
    }
}
