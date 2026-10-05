import Foundation
import Testing
@testable import CtrlxNetworking

struct FileBrowserProtocolTests {
    @Test func requestsRoundTripWithoutNewRelayMessageTypes() throws {
        let operations: [FileBrowserOperation] = [.list(path: nil, offset: 0, includeHidden: false), .info(path: "/Host"),
                                                .read(path: "/Host/file", offset: 128, revision: "revision"),
                                                .search(path: "/Host", query: "abc", mode: .content, includeHidden: true)]
        for operation in operations {
            let message = CommandMessage(paneId: "%42", command: BrowseFiles(operation).commandType)
            let decoded = try JSONDecoder().decode(CommandMessage.self, from: JSONEncoder().encode(message))
            #expect(decoded.command == message.command)
            #expect(decoded.paneId == "%42")
            #expect(decoded.command.requiresResponse)
        }
    }

    @Test func legacyHostsDoNotAdvertiseFileAccess() throws {
        let old = SessionStateMessage(pairId: "pair", paneStates: [:])
        #expect(try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(old)).supportsFileBrowsing == nil)
        let modern = SessionStateMessage(pairId: "pair", paneStates: [:], supportsFileBrowsing: true)
        #expect(modern.withPairId("other").supportsFileBrowsing == true)
        let response = CommandResponseMessage(commandId: UUID(), success: true, fileBrowser: .chunk(.init(path: "/host", revision: "1", offset: 0, data: Data([0, 1, 2]))))
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(response)).fileBrowser == response.fileBrowser)
    }
}
