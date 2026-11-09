import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct MarkdownFileLinkTests {
    private let document = "/host/callie/README.md"

    @Test("Markdown links resolve against the document, using the source Host for navigation", arguments: [
        ("docs/ARCHITECTURE.md", "/host/callie/docs/ARCHITECTURE.md"),
        ("../说明%20文档.md#标题", "/host/说明 文档.md"),
        ("docs/100%2520.md", "/host/callie/docs/100%20.md"),
        ("/other/project/design.md#details", "/other/project/design.md"),
    ])
    func resolvesDocumentLinks(destination: String, expected: String) async throws {
        let parsed = try AttributedString(markdown: "[技术架构](\(destination))", baseURL: URL(fileURLWithPath: document, isDirectory: false))
        let url = try #require(parsed.runs.compactMap(\.link).first)
        let tab = FileBrowserTab(path: "/unrelated-listing", sourcePaneID: "%7")
        tab.selectedFile = document
        var requests: [String] = []
        let source = FileBrowserSource(id: "original-host", paneID: "%7") { operation in
            guard case let .info(path) = operation else { throw FileBrowserError.message("Unexpected request") }
            requests.append(path)
            return .info(.init(path: path, name: "design.md", kind: .markdown, size: 0, revision: "1"))
        }
        try await tab.openMarkdownLink(url, from: document, source: source)
        #expect(requests == [expected])
        #expect(tab.path == (expected as NSString).deletingLastPathComponent)
        #expect(tab.selectedFile == expected)
        #expect(tab.sourcePaneID == "%7")
    }

    @Test("Following a folder link preserves independent and pane-linked Files identity", arguments: [false, true])
    func opensDirectory(independent: Bool) async throws {
        let descriptor = HostFileTab(sessionName: "work", windowID: independent ? nil : "@1", sourcePaneID: independent ? nil : "%1", isPrimary: false, initialDirectory: "/host/callie", resourceSessionID: independent ? UUID() : nil)
        let tab = FileBrowserTab(hostTab: descriptor)
        tab.selectedFile = document
        let source = FileBrowserSource(id: "host", paneID: tab.sourcePaneID) { operation in
            guard case .info(path: "/host/callie/docs") = operation else { throw FileBrowserError.message("Unexpected path") }
            return .info(.init(path: "/host/callie/docs", name: "docs", kind: .directory, size: 0, revision: "1"))
        }
        try await tab.openMarkdownLink(URL(fileURLWithPath: "/host/callie/docs", isDirectory: true), from: document, source: source)
        #expect(tab.path == "/host/callie/docs")
        #expect(tab.selectedFile == nil)
        #expect(tab.hostTab == descriptor)
        #expect(tab.id == descriptor.id)
        #expect(tab.sourcePaneID == descriptor.sourcePaneID)
    }

    @Test("Heading links in the current document never reload or read files")
    func keepsCurrentDocument() async throws {
        let tab = FileBrowserTab(path: "/host/callie")
        tab.selectedFile = document
        let refresh = tab.refresh
        let parsed = try AttributedString(markdown: "[当前实现](#当前实现)", baseURL: URL(fileURLWithPath: document, isDirectory: false))
        let url = try #require(parsed.runs.compactMap(\.link).first)
        let source = FileBrowserSource(id: "host", paneID: nil) { _ in
            Issue.record("A same-document anchor must not read or navigate")
            throw CancellationError()
        }
        try await tab.openMarkdownLink(url, from: document, source: source)
        #expect(tab.selectedFile == document)
        #expect(tab.refresh == refresh)
    }

    @Test("Failed navigation keeps the current document", arguments: ["missing", "wrong-response", "offline"])
    func failedNavigation(mode: String) async {
        let tab = FileBrowserTab(path: "/host/callie")
        tab.selectedFile = document
        let source = FileBrowserSource(id: "host", paneID: nil, unavailableReason: mode == "offline" ? "Host is offline" : nil) { _ in
            #expect(mode != "offline")
            if mode == "missing" {
                throw FileBrowserError.message("File does not exist")
            }
            return .chunk(.init(path: "/target.md", revision: "1", offset: 0, data: Data()))
        }
        await #expect(throws: FileBrowserError.self) {
            try await tab.openMarkdownLink(URL(fileURLWithPath: "/target.md"), from: document, source: source)
        }
        #expect(tab.selectedFile == document)
        #expect(tab.path == "/host/callie")
    }

    @Test("Late link responses cannot override a newer selection or a closed preview", arguments: ["selection", "navigate", "release", "cancel"])
    func ignoresLateResponse(change: String) async throws {
        let tab = FileBrowserTab(path: "/host/callie")
        tab.selectedFile = document
        let (started, notify) = AsyncStream<Void>.makeStream()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let source = FileBrowserSource(id: "host", paneID: nil) { _ in
            notify.yield()
            for await _ in gate {
                break
            }
            return .info(.init(path: "/old-target.md", name: "old-target.md", kind: .markdown, size: 0, revision: "1"))
        }
        let task = Task { try await tab.openMarkdownLink(URL(fileURLWithPath: "/old-target.md"), from: document, source: source) }
        for await _ in started {
            break
        }
        switch change {
        case "selection": tab.selectedFile = "/host/new-selection.md"
        case "navigate":
            tab.navigate("/host/new-directory")
            // Returning to the original selection must not revive its old request.
            tab.selectedFile = document
        case "release": tab.releasePreview()
        default: task.cancel()
        }
        let expectedPath = tab.path
        let expectedSelection = tab.selectedFile
        release.yield()
        release.finish()
        notify.finish()
        do { try await task.value }
        catch is CancellationError { #expect(change == "cancel") }
        #expect(tab.path == expectedPath)
        #expect(tab.selectedFile == expectedSelection)
    }
}
