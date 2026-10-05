import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

struct SessionDirectoryCreationStateTests {
    @Test("Creation is exclusive, preserves the chosen parent and never launches a session")
    func success() throws {
        var state = SessionDirectoryCreationState()
        let pending = state.begin(hostID: "office", path: "~/Projects/", parentDirectory: "/Host/Projects", name: "new repo")
        let request = try #require(pending)
        #expect(state.isCreating)
        #expect(request.command == .init(parentDirectory: "/Host/Projects", name: "new repo"))
        let duplicate = state.begin(hostID: "office", path: "~/Projects/", parentDirectory: "/Host/Projects", name: "duplicate")
        #expect(duplicate == nil)
        let destination = state.finish(request.id, directory: "/Host/Projects/new repo", hostID: "office", path: "~/Projects/")
        #expect(destination == "/Host/Projects/new repo")
        #expect(!state.isCreating)
        #expect(state.error == nil)
    }

    @Test("Late creation replies cannot navigate a different path or Host", arguments: ["home", "office"])
    func changedContext(host: String) throws {
        var state = SessionDirectoryCreationState()
        let pending = state.begin(hostID: "office", path: "~/", parentDirectory: "/Host", name: "new")
        let request = try #require(pending)
        let path = host == "office" ? "~/Projects/" : "~/"
        let destination = state.finish(request.id, directory: "/Host/new", hostID: host, path: path)
        #expect(destination == nil)
        #expect(!state.isCreating)
    }

    @Test("Cancelled requests cannot overwrite a later creation at the same path")
    func cancellation() throws {
        var state = SessionDirectoryCreationState()
        let oldPending = state.begin(hostID: "office", path: "~/", parentDirectory: "/Host", name: "old")
        let old = try #require(oldPending)
        state.cancel()
        let newPending = state.begin(hostID: "office", path: "~/", parentDirectory: "/Host", name: "new")
        let new = try #require(newPending)
        let destination = state.finish(old.id, directory: "/Host/old", hostID: "office", path: "~/")
        #expect(destination == nil)
        state.fail(old.id, message: "Late error", hostID: "office", path: "~/")
        #expect(state.request?.id == new.id)
        #expect(state.error == nil)
        state.fail(new.id, message: "Permission denied", hostID: "office", path: "~/")
        #expect(!state.isCreating)
        #expect(state.error == "Permission denied")
        let retry = state.begin(hostID: "office", path: "~/", parentDirectory: "/Host", name: "retry")
        #expect(retry != nil)
        #expect(state.error == nil)
    }

    @Test("Invalid names never enqueue a mutation")
    func invalidName() {
        var state = SessionDirectoryCreationState()
        let pending = state.begin(hostID: "office", path: "~/", parentDirectory: "/Host", name: "../escape")
        #expect(pending == nil)
        #expect(!state.isCreating)
    }
}
