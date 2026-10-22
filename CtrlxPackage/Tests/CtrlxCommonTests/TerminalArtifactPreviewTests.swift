import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct TerminalArtifactPreviewTests {
    @Test(arguments: ["diagram.mmd", "图.MERMAID", "picture.PNG", "photo.jpeg", "a.webp", "a.heic"])
    func supported(path: String) {
        #expect(TerminalArtifactPreview.supports(path: path))
    }

    @Test(arguments: ["document.md", "a.pdf", "a.svg", "folder", "a.mmd.txt"])
    func normalFile(path: String) {
        #expect(!TerminalArtifactPreview.supports(path: path))
    }

    @Test
    func loadsWithoutOpeningATabAndKeepsHostBinding() async throws {
        let a = Fixture(host: "A", text: "graph LR; A-->B")
        let b = Fixture(host: "B", text: "graph LR; B-->C")
        #expect(try await a.preview.load() == a.data)
        #expect(try await b.preview.load() == b.data)
        #expect(a.repositoryReads == 2 && b.repositoryReads == 2)
        #expect(a.tabRequests == 0 && b.tabRequests == 0)
        let files = a.preview.filesLink
        #expect(!files.prefersPreview && files.hostID == "A" && files.paneID == "%1" && files.path == "diagram.mmd")
    }

    @Test
    func replacedPaneCannotPublishACompletedRead() async {
        let fixture = Fixture(host: "A", text: "graph LR; A-->B")
        fixture.replaceSource = true
        await #expect(throws: FileBrowserError.self) { try await fixture.preview.load() }
        #expect(fixture.repositoryReads == 2)
    }

    @Test
    func changedRevisionIsRejected() async {
        let fixture = Fixture(host: "A", text: "graph LR; A-->B")
        fixture.changeRevision = true
        await #expect(throws: FileBrowserError.self) { try await fixture.preview.load() }
    }

    @Test
    func invalidChunkIsRejected() async {
        let fixture = Fixture(host: "A", text: "graph LR; A-->B")
        fixture.wrongChunk = true
        await #expect(throws: FileBrowserError.self) { try await fixture.preview.load() }
    }

    @Test
    func oversizedMermaidIsRejected() async {
        let fixture = Fixture(host: "A", text: String(repeating: "x", count: 64 * 1_024 + 1))
        await #expect(throws: FileBrowserError.self) { try await fixture.preview.load() }
    }

    @MainActor
    final private class Fixture {
        let host: String
        let data: Data
        let context = RepositoryFileContext(pluginID: "codex", sessionID: "conversation", projectDirectory: "/Host/worktree")
        var repositoryReads = 0
        var tabRequests = 0
        var replaceSource = false
        var changeRevision = false
        var wrongChunk = false
        var hasRead = false

        init(host: String, text: String) {
            self.host = host
            self.data = Data(text.utf8)
        }

        var preview: TerminalArtifactPreview {
            .init(
                link: .init(path: "diagram.mmd", paneID: "%1", hostID: host),
                context: context,
                source: .init(id: host, paneID: "%1") { try self.request($0) },
                path: "/Host/worktree/diagram.mmd"
            )
        }

        func request(_ operation: FileBrowserOperation) throws -> FileBrowserResponse {
            let info = FileBrowserEntry(
                path: "/Host/worktree/diagram.mmd",
                name: "diagram.mmd",
                kind: .text,
                size: data.count,
                revision: changeRevision && hasRead ? "new" : "original"
            )
            switch operation {
            case let .repositoryInfo(path, context):
                #expect(path == "diagram.mmd" && context == self.context)
                repositoryReads += 1
                if replaceSource && repositoryReads > 1 {
                    throw FileBrowserError.message("Source changed")
                }
                return .info(info)
            case .info: return .info(info)
            case let .read(path, offset, revision):
                hasRead = true
                return .chunk(.init(
                    path: wrongChunk ? "/another-host/file" : path,
                    revision: revision,
                    offset: offset,
                    data: data.subdata(in: offset..<min(data.count, offset + FileBrowserLimits.chunkBytes))
                ))
            case .tabs:
                tabRequests += 1
                throw FileBrowserError.message("Preview must not create a tab")
            default: throw FileBrowserError.message("Unexpected operation")
            }
        }
    }
}
