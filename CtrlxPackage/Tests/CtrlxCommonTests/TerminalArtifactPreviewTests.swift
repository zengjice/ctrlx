import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct TerminalArtifactPreviewTests {
    @Test(arguments: ["diagram.mmd", "图.MERMAID", "picture.PNG", "photo.jpeg", "a.webp", "a.heic", "README.md", "设计.MARKDOWN"])
    func supported(path: String) {
        #expect(TerminalArtifactPreview.supports(path: path))
    }

    @Test(arguments: ["a.pdf", "a.svg", "folder", "a.mmd.txt"])
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

    @Test
    func markdownLoadsWithoutOpeningATab() async throws {
        let fixture = Fixture(host: "A", text: "# 文档\n\n```mermaid\ngraph LR; A-->B\n```", filename: "docs/guide.md")
        #expect(try await fixture.preview.load() == fixture.data)
        #expect(fixture.tabRequests == 0)
        let request = try fixture.preview.documentLink("../images/图%20片.png?version=1#image")
        #expect(request.path == "images/图 片.png" && request.hostID == "A" && request.paneID == "%1")
        #expect(try fixture.preview.documentLink("../").path == ".")
        #expect(try fixture.preview.documentLink("../images/图%2520片.png").path == "images/图%20片.png")
    }

    @Test(arguments: ["../../secret.png", "%2e%2e/%2e%2e/secret.png", "/etc/file.png", "//other/file.png", "https://other/file.png", "file:///tmp/a.png", "data:image/png;base64,AA", "..\\secret.png"])
    func documentLinksCannotLeaveRepository(reference: String) {
        let fixture = Fixture(host: "A", text: "# Test", filename: "docs/guide.md")
        #expect(throws: FileBrowserError.self) { try fixture.preview.documentLink(reference) }
    }

    @Test
    func oversizedMarkdownIsRejected() async {
        let fixture = Fixture(host: "A", text: String(repeating: "x", count: FileBrowserLimits.maximumTextBytes + 1), filename: "README.md")
        await #expect(throws: FileBrowserError.self) { try await fixture.preview.load() }
    }

    @Test
    func documentImageUsesCapturedHostAndRevalidates() async throws {
        let data = Data([1, 2, 3])
        var paths: [String] = []
        let context = RepositoryFileContext(pluginID: "codex", sessionID: "doc", projectDirectory: "/Host/repo")
        let info = FileBrowserEntry(path: "/Host/repo/images/a.png", name: "a.png", kind: .image, size: data.count, revision: "1")
        let source = FileBrowserSource(id: "Host A", paneID: "%1") { operation in
            switch operation {
            case let .repositoryInfo(path, received):
                #expect(received == context)
                paths.append(path)
                return .info(info)
            case .info: return .info(info)
            case let .read(path, offset, revision): return .chunk(.init(path: path, revision: revision, offset: offset, data: data))
            default: throw FileBrowserError.message("Unexpected operation")
            }
        }
        let preview = TerminalArtifactPreview(link: .init(path: "docs/guide.md", paneID: "%1", hostID: "Host A"), context: context, source: source, path: "/Host/repo/docs/guide.md")
        #expect(try await preview.loadDocumentImage("../images/a.png") == data)
        #expect(paths == ["images/a.png", "images/a.png", "images/a.png"])
        await #expect(throws: FileBrowserError.self) { try await preview.loadDocumentImage("https://other/a.png") }
        #expect(paths.count == 3)
    }

    @MainActor
    final private class Fixture {
        let host: String
        let data: Data
        let filename: String
        let context = RepositoryFileContext(pluginID: "codex", sessionID: "conversation", projectDirectory: "/Host/worktree")
        var repositoryReads = 0
        var tabRequests = 0
        var replaceSource = false
        var changeRevision = false
        var wrongChunk = false
        var hasRead = false

        init(host: String, text: String, filename: String = "diagram.mmd") {
            self.host = host
            self.data = Data(text.utf8)
            self.filename = filename
        }

        var preview: TerminalArtifactPreview {
            .init(
                link: .init(path: filename, paneID: "%1", hostID: host),
                context: context,
                source: .init(id: host, paneID: "%1") { try self.request($0) },
                path: "/Host/worktree/\(filename)"
            )
        }

        func request(_ operation: FileBrowserOperation) throws -> FileBrowserResponse {
            let info = FileBrowserEntry(
                path: "/Host/worktree/\(filename)",
                name: filename,
                kind: TerminalArtifactPreview.isMarkdown(path: filename) ? .markdown : .text,
                size: data.count,
                revision: changeRevision && hasRead ? "new" : "original"
            )
            switch operation {
            case let .repositoryInfo(path, context):
                #expect(path == filename && context == self.context)
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
