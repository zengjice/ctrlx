import Foundation
import Testing
@testable import CtrlxNetworking

struct SessionDirectoryListingTests {
    @Test("Directory lookups round-trip as response-requiring, pane-independent commands")
    func commandRoundTrip() throws {
        let spec = ListSessionDirectories(path: "~/Projects/新 repo", includeHidden: true)
        let command = CommandMessage(paneId: "", command: spec.commandType)
        let decoded = try JSONDecoder().decode(CommandMessage.self, from: JSONEncoder().encode(command))
        #expect(decoded.id == command.id)
        #expect(decoded.paneId.isEmpty)
        #expect(decoded.command == .listSessionDirectories(spec))
        #expect(decoded.command.requiresResponse)
    }

    @Test("Directory response preserves paths and query context")
    func responseRoundTrip() throws {
        let listing = SessionDirectoryListing(
            directory: "/Users/office/Projects", parentDirectory: "/Users/office",
            isExactDirectory: true, entries: [.init(name: "new repo", path: "/Users/office/Projects/new repo")], isTruncated: true
        )
        let response = CommandResponseMessage(commandId: UUID(), success: true, directoryListing: listing)
        let decoded = try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(response))
        #expect(decoded.directoryListing == listing)
        #expect(decoded.commandId == response.commandId)
    }

    @Test("Legacy responses and state remain decodable; capability survives per-pair copying")
    func backwardCompatibility() throws {
        let legacyResponse = #"{"commandId":"00000000-0000-0000-0000-000000000001","success":true}"#
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: Data(legacyResponse.utf8)).directoryListing == nil)
        let legacyState = #"{"pairId":"old","paneStates":{},"homeDirectory":"/Users/old"}"#
        #expect(try JSONDecoder().decode(SessionStateMessage.self, from: Data(legacyState.utf8)).supportsDirectoryBrowsing == nil)
        let state = SessionStateMessage(pairId: "", paneStates: [:], supportsDirectoryBrowsing: true).withPairId("office")
        let decoded = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(state))
        #expect(decoded.pairId == "office")
        #expect(decoded.supportsDirectoryBrowsing == true)
    }
}
