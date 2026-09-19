import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

struct SessionDirectoryBrowseStateTests {
    private func query(host: String = "office", path: String = "~/", retry: Int = 0) -> SessionDirectoryBrowseState.Query {
        .init(hostID: host, path: path, includeHidden: false, unavailableReason: nil, retry: retry)
    }
    private let result = SessionDirectoryListing(directory: "/Users/office", parentDirectory: "/Users", isExactDirectory: true, entries: [])

    @Test("Late results and errors cannot overwrite a newer path or Host")
    func outdatedReplies() {
        var state = SessionDirectoryBrowseState()
        let old = state.begin(query())
        let new = state.begin(query(host: "home", path: "~/Projects/"))
        state.finish(old, listing: result)
        state.fail(old, message: "Old connection failed")
        #expect(state.listing == nil)
        #expect(state.error == nil)
        #expect(state.isLoading)
        state.finish(new, listing: result)
        #expect(state.listing == result)
        #expect(!state.isLoading)
    }

    @Test("A → B → A and retry have distinct request ownership")
    func samePathAgain() {
        var state = SessionDirectoryBrowseState()
        let first = state.begin(query())
        _ = state.begin(query(path: "~/Projects/"))
        let last = state.begin(query())
        state.finish(first, listing: result)
        #expect(state.listing == nil)
        state.finish(last, listing: result)
        #expect(state.listing != nil)
        let retry = state.begin(query(retry: 1))
        #expect(state.listing == nil)
        state.fail(last, message: "Late failure")
        #expect(state.error == nil)
        state.fail(retry, message: "Permission denied")
        #expect(state.error == "Permission denied")
        #expect(!state.isLoading)
    }
}

@MainActor
struct SessionDirectoryCapabilityTests {
    @Test("Capabilities are isolated by Host and removed on downgrade/disconnect")
    func hostCapabilities() {
        let store = SessionStore()
        store.handleStateUpdate(.init(pairId: "office", paneStates: [:], supportsDirectoryBrowsing: true))
        store.handleStateUpdate(.init(pairId: "home", paneStates: [:]))
        #expect(store.hostsSupportingDirectoryBrowsing == ["office"])
        store.handleStateUpdate(.init(pairId: "home", paneStates: [:], supportsDirectoryBrowsing: true))
        store.handleStateUpdate(.init(pairId: "office", paneStates: [:], supportsDirectoryBrowsing: false))
        #expect(store.hostsSupportingDirectoryBrowsing == ["home"])
        store.clearSessions(for: "home")
        #expect(store.hostsSupportingDirectoryBrowsing.isEmpty)
    }

    @Test("Offline sources fail without routing a request elsewhere")
    func offline() async {
        let source = SessionDirectorySource.remote(hostID: "office", connection: nil, supportsBrowsing: true)
        #expect(source.id == "office")
        #expect(source.unavailableReason?.contains("offline") == true)
        await #expect(throws: SessionDirectorySource.LookupError.self) {
            try await source.list(.init(path: "~/"))
        }
    }
}
