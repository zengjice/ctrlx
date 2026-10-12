import Foundation
import Testing
@testable import CtrlxNetworking

struct FileBrowserProtocolTests {
    @Test func requestsRoundTripWithoutNewRelayMessageTypes() throws {
        let operations: [FileBrowserOperation] = [.list(path: nil, offset: 0, includeHidden: false), .info(path: "/Host"),
                                                .repositoryInfo(path: "output/file.pdf", context: .init(pluginID: "codex", sessionID: "session", projectDirectory: "/Host/project")),
                                                .read(path: "/Host/file", offset: 128, revision: "revision"),
                                                .download(path: "/Host/movie.mp4", offset: 128, revision: "revision"),
                                                .search(path: "/Host", query: "abc", mode: .content, includeHidden: true),
                                                .upload(.begin(id: UUID(), directory: "/Host", name: "中文.bin", size: 3)),
                                                .upload(.append(id: UUID(), offset: 0, data: Data([1, 2, 3]))),
                                                .upload(.finish(id: UUID(), sha256: "digest")), .upload(.cancel(id: UUID()))]
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
        #expect(try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(old)).supportsFileDownloads == nil)
        #expect(try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(old)).supportsFileUploads == nil)
        #expect(try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(old)).supportsRepositoryFileLinks == nil)
        let modern = SessionStateMessage(pairId: "pair", paneStates: [:], supportsFileBrowsing: true, supportsFileDownloads: true, supportsFileUploads: true, supportsRepositoryFileLinks: true)
        #expect(modern.withPairId("other").supportsFileBrowsing == true)
        #expect(modern.withPairId("other").supportsFileDownloads == true)
        #expect(modern.withPairId("other").supportsFileUploads == true)
        #expect(modern.withPairId("other").supportsRepositoryFileLinks == true)
        let response = CommandResponseMessage(commandId: UUID(), success: true, fileBrowser: .chunk(.init(path: "/host", revision: "1", offset: 0, data: Data([0, 1, 2]))))
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(response)).fileBrowser == response.fileBrowser)
        for payload in [FileBrowserResponse.uploaded(offset: 128, path: nil), .uploaded(offset: 128, path: "/Host/file")] {
            let reply = CommandResponseMessage(commandId: UUID(), success: true, fileBrowser: payload)
            #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(reply)).fileBrowser == payload)
        }
    }
}
