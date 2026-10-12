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
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: Data(legacyResponse.utf8)).createdDirectory == nil)
        let legacyState = #"{"pairId":"old","paneStates":{},"homeDirectory":"/Users/old"}"#
        #expect(try JSONDecoder().decode(SessionStateMessage.self, from: Data(legacyState.utf8)).supportsDirectoryBrowsing == nil)
        #expect(try JSONDecoder().decode(SessionStateMessage.self, from: Data(legacyState.utf8)).supportsDirectoryCreation == nil)
        let state = SessionStateMessage(pairId: "", paneStates: [:], supportsDirectoryBrowsing: true, supportsDirectoryCreation: true).withPairId("office")
        let decoded = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(state))
        #expect(decoded.pairId == "office")
        #expect(decoded.supportsDirectoryBrowsing == true)
        #expect(decoded.supportsDirectoryCreation == true)
    }

    @Test("Folder creation has an acknowledged, pane-independent command and result")
    func creationRoundTrip() throws {
        let spec = CreateSessionDirectory(parentDirectory: "/Host/Projects", name: "新 repo")
        let command = CommandMessage(paneId: "", command: spec.commandType)
        let decoded = try JSONDecoder().decode(CommandMessage.self, from: JSONEncoder().encode(command))
        #expect(decoded.command == .createSessionDirectory(spec))
        #expect(decoded.command.requiresResponse)
        #expect(decoded.paneId.isEmpty)
        let response = CommandResponseMessage(commandId: command.id, success: true, createdDirectory: "/Host/Projects/新 repo")
        let result = try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(response))
        #expect(result.commandId == command.id)
        #expect(result.createdDirectory == response.createdDirectory)
    }

    @Test("Folder names are literal child names, not paths", arguments: ["", "  ", ".", "..", "../escape", "/absolute", "nested/child", "new\nline", "new\0name", String(repeating: "x", count: 256)])
    func rejectedName(name: String) { #expect(!SessionDirectoryName.isValid(name)) }

    @Test("Spaces, Unicode, hidden and shell-like names are preserved", arguments: ["new repo", "新项目", ".hidden", "a ' $(x)", "back\\slash", String(repeating: "x", count: 255)])
    func literalName(name: String) { #expect(SessionDirectoryName.isValid(name)) }
}
