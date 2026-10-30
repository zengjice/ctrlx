import CtrlxNetworking
import Foundation
import SwiftTerm
import Testing
@testable import CtrlxCommon

@MainActor
struct TerminalFileLinkTests {
    private let context = RepositoryFileContext(pluginID: "codex", sessionID: "session", projectDirectory: "/Host/project/nested")

    private func row(_ text: String, number: Int = 0, wrapped: Bool = false) -> TerminalFileLinkDetector.Row {
        .init(number: number, cells: text.enumerated().map { .init($0.element, column: $0.offset) }, wrapped: wrapped)
    }

    private final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) { }
    }

    @Test("Only complete explicit repository markers create Files links", arguments: [
        "/Users/remote/output.pdf", "~/Movies/", "./output/movie.mp4", "../report.pdf",
        "docs/report.md", ".build-local/script.py", "/review", "crayon/gouache", "size/",
        "file:///tmp/file.txt", "(./output/my report.pdf)", "[Report](/tmp/report.pdf)",
        "https://example.com/api(foo/bar)",
        "ctrlx://file/v1/L3RtcC9maWxl#end",
    ])
    func ordinaryText(text: String) {
        #expect(TerminalFileLinkDetector.links(rows: [row(text)], columns: 160).isEmpty)
        #expect(RepositoryFileLink.path(text) == nil)
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 160, rows: 4))
        terminal.feed(text: "\u{1b}]8;;\(text)\u{1b}\\Open file\u{1b}]8;;\u{1b}\\\r\n$ ")
        #expect(TerminalFileLinkDetector.links(terminal: terminal, rows: 0..<4, cellPayload: { _, _ in nil }).isEmpty)
        withExtendedLifetime(delegate) { }
    }

    @Test("Bare repo text requires delimiters; an explicit hyperlink target has its own boundary")
    func bareRepositoryText() {
        let text = "repo:output/file.txt"
        #expect(TerminalFileLinkDetector.links(rows: [row(text)], columns: 160).isEmpty)
        #expect(RepositoryFileLink.path(text) == nil)
        #expect(RepositoryFileLink.path(linkTarget: text) == "output/file.txt")
    }

    @Test("Markdown-rendered parenthesized references use the existing Host path contract")
    func markdownReference() async throws {
        let text = "视频: repo:outputs/movie.mp4 (repo:outputs/movie.mp4)"
        let links = TerminalFileLinkDetector.links(rows: [row(text)], columns: 160)
        #expect(links.map(\.path) == ["outputs/movie.mp4"])
        #expect(links.first?.spans == [.init(row: 0, columns: 27..<51)])
        var requests: [FileBrowserOperation] = []
        let source = FileBrowserSource(id: "host", paneID: "%42") { operation in
            requests.append(operation)
            return .info(.init(path: "/Host/project/outputs/movie.mp4", name: "movie.mp4", kind: .unsupported, size: 99, revision: "1"))
        }
        let link = try #require(links.first)
        let destination = try await TerminalFileDestination.resolve(path: link.path, context: context, source: source)
        #expect(destination.file == "/Host/project/outputs/movie.mp4")
        #expect(requests == [.repositoryInfo(path: "outputs/movie.mp4", context: context)])
    }

    @Test("Compatibility targets retain path validation", arguments: [
        "", "/tmp/file", "../file", "folder/../file", "./file", "~/file", "folder//file",
        "%2Ftmp/file", "%2e%2e/file", "%00file", "%0Afile", "bad%GGfile", "bad%FFfile",
        "bad file", "bad?query", "bad#fragment", "bad(file)", "bad<file>", "folder//",
        String(repeating: "a", count: 4_097),
    ])
    func invalidCompatibilityTarget(encoded: String) {
        let target = "repo:" + encoded
        #expect(RepositoryFileLink.path(linkTarget: target) == nil)
        #expect(TerminalFileLinkDetector.links(rows: [row("(\(target))")], columns: 160).isEmpty)
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 4))
        terminal.feed(text: "\u{1b}]8;;\(target)\u{1b}\\Open file\u{1b}]8;;\u{1b}\\\r\n$ ")
        #expect(TerminalFileLinkDetector.links(terminal: terminal, rows: 0..<4, cellPayload: { _, _ in nil }).isEmpty)
        withExtendedLifetime(delegate) { }
    }

    @Test("Explicit repo OSC 8 targets preserve encoded filenames and exclude the live composer", arguments: [
        ("Open generated movie", 20), ("查看猫图", 8),
    ])
    func repositoryHyperlink(label: (String, Int)) throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 32, rows: 6))
        let path = "输出/John's %27(猫).mp4"
        let marker = try #require(RepositoryFileLink.marker(path: path))
        let target = String(marker.dropFirst().dropLast())
        let hyperlink = "\u{1b}]8;id=movie;\(target)\u{1b}\\\(label.0)\u{1b}]8;;\u{1b}\\"
        terminal.feed(text: "\(hyperlink)\r\n$ \(hyperlink)")
        let links = TerminalFileLinkDetector.links(terminal: terminal, rows: 0..<6, cellPayload: { _, _ in nil })
        #expect(links.map(\.path) == [path])
        #expect(links.first?.spans == [.init(row: 0, columns: 0..<label.1)])
        withExtendedLifetime(delegate) { }
    }

    @Test("Parenthesized compatibility still needs a complete boundary")
    func truncatedCompatibility() {
        for text in ["(repo:outputs/movie.mp4", "https://example.com/(repo:outputs/movie.mp4)", "(repo:bad file)"] {
            #expect(TerminalFileLinkDetector.links(rows: [row(text)], columns: 160).isEmpty)
        }
    }

    @Test("Encoding preserves literal filenames without revealing an absolute path", arguments: [
        "output/John's report.pdf", "output/quoted\"report\".pdf", "output/back\\slash.pdf",
        "output/<report>|%27%0A.pdf", "输出/报告：最终，(三)...…片.mp4", ".build-local/script.py", ".",
    ])
    func roundTrip(path: String) throws {
        let marker = try #require(RepositoryFileLink.marker(path: path))
        #expect(RepositoryFileLink.path(marker) == path)
        let links = TerminalFileLinkDetector.links(rows: [row("Report (\(marker))")], columns: 400)
        #expect(links.map(\.path) == [path])
        #expect(links.first?.spans == [.init(row: 0, columns: 8..<(8 + marker.count))])
    }

    @Test("Directory markers normalize one trailing slash before Host resolution", arguments: [
        ("<repo:outputs/final_films>", "outputs/final_films"),
        ("<repo:outputs/final_films/>", "outputs/final_films"),
        ("<repo:outputs/final_films%2F>", "outputs/final_films"),
        ("<repo:输出/最终%20成片/>", "输出/最终 成片"),
        ("<repo:outputs/literal%252F/>", "outputs/literal%2F"),
    ])
    func directoryMarkers(marker: String, path: String) async throws {
        #expect(RepositoryFileLink.path(marker) == path)
        let links = TerminalFileLinkDetector.links(rows: [row(marker)], columns: 160)
        let link = try #require(links.first)
        #expect(links.count == 1)
        #expect(link.path == path)
        #expect(link.spans == [.init(row: 0, columns: 0..<marker.count)])
        #expect(link.contains(column: marker.count - 2, row: 0))
        #expect(RepositoryFileLink.isValid(path: link.path))
        var requests: [FileBrowserOperation] = []
        let directory = "/Host/project/" + path
        let source = FileBrowserSource(id: "host", paneID: "%1") { operation in
            requests.append(operation)
            return .info(.init(path: directory, name: "directory", kind: .directory, size: 0, revision: "1"))
        }
        let destination = try await TerminalFileDestination.resolve(path: link.path, context: context, source: source)
        #expect(destination == .init(directory: directory, file: nil))
        #expect(requests == [.repositoryInfo(path: path, context: context)])
    }

    @Test("Truncated, malformed and escaping markers fail closed", arguments: [
        "<repo:output/file.pdf", "<repo:>", "<repo:/tmp/file>", "<repo:../file>",
        "<repo:folder/../file>", "<repo:./file>", "<repo:folder//file>", "<repo:~/file>",
        "<repo:%2Ftmp/file>", "<repo:%2e%2e/file>", "<repo:%00file>", "<repo:%0Afile>",
        "<repo:bad%GGfile>", "<repo:bad%file>", "<repo:bad%FFfile>", "<repo:bad file>",
        "<repo:bad?query>", "<repo:bad#fragment>",
        "<repo:/>", "<repo://>", "<repo:./>", "<repo:../>", "<repo:~/>", "<repo:/tmp/folder/>",
        "<repo:folder//>", "<repo:folder///>", "<repo:folder//child/>", "<repo:folder/../>", "<repo:folder/./>",
        "<repo:folder/%2F>", "<repo:folder/%2e%2e/>", "<repo:%2Ftmp/folder/>", "<repo:folder/",
    ])
    func invalidProtocol(marker: String) {
        #expect(RepositoryFileLink.path(marker) == nil)
        #expect(TerminalFileLinkDetector.links(rows: [row(marker)], columns: 160).isEmpty)
    }

    @Test("Every soft/hard wrap boundary preserves the complete marker", arguments: [false, true], [
        ("<repo:输出/第%203%20集.mp4>", "输出/第 3 集.mp4"),
        ("<repo:outputs/final_films/>", "outputs/final_films"),
        ("<repo:输出/最终%20成片%2F>", "输出/最终 成片"),
        ("(repo:输出/第%203%20集.mp4)", "输出/第 3 集.mp4"),
        ("(repo:outputs/final_films/)", "outputs/final_films"),
    ])
    func everyWrapBoundary(soft: Bool, reference: (String, String)) throws {
        let (marker, path) = reference
        let chars = Array(marker)
        for split in 1..<chars.count {
            let second = String(chars[split...])
            let links = TerminalFileLinkDetector.links(rows: [
                row("(" + String(chars[..<split])),
                row("  " + second + ")", number: 1, wrapped: soft),
            ], columns: 160)
            let link = try #require(links.first)
            #expect(links.count == 1)
            #expect(link.path == path)
            #expect(link.spans == [.init(row: 0, columns: 1..<(split + 1)),
                                   .init(row: 1, columns: 2..<(2 + second.count))])
        }
    }

    @Test("Unrelated text, blank lines and embedded web targets are not joined")
    func rejectedFragments() throws {
        let marker = try #require(RepositoryFileLink.marker(path: "output/file.txt"))
        let split = marker.count / 2
        for rows in [
            [row(String(marker.prefix(split))), row("unrelated text", number: 1), row(String(marker.suffix(marker.count - split)), number: 2)],
            [row(String(marker.prefix(split))), row("", number: 1), row(String(marker.suffix(marker.count - split)), number: 2)],
            [row("https://example.com/api(\(marker))")],
            [row("https://example.com/?file=\(marker)")],
        ] {
            #expect(TerminalFileLinkDetector.links(rows: rows, columns: 160).isEmpty)
        }
    }

    @Test("Chinese hit cells survive wrapping; OSC 8 links retain ownership")
    func wideCellsAndWebPrecedence() throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 20, rows: 10))
        let marker = "<repo:输出/完整片.mp4>"
        terminal.feed(text: "\u{1b}]8;;https://example.com\u{1b}\\\(marker)\u{1b}]8;;\u{1b}\\\r\n\(marker)\r\n$ ")
        let links = TerminalFileLinkDetector.links(terminal: terminal, rows: 0..<10, cellPayload: { _, _ in nil })
        let link = try #require(links.first)
        #expect(links.count == 1)
        #expect(link.path == "输出/完整片.mp4")
        #expect(link.spans == [.init(row: 2, columns: 0..<20), .init(row: 3, columns: 0..<2)])
        withExtendedLifetime(delegate) { }
    }

    @Test("Multiline composer rows stay editable")
    func composerRows() throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 100, rows: 8))
        let marker = try #require(RepositoryFileLink.marker(path: "output/movie.mp4"))
        terminal.feed(text: "\(marker)\r\n\u{1b}[?1003h\u{1b}[48;5;236m\u{1b}[2K> \(marker)\r\n\u{1b}[2K  \(marker)\r\n\u{1b}[2K  editing\u{1b}[2;10H\u{1b}[?25l")
        #expect(TerminalFileLinkDetector.links(terminal: terminal, rows: 0..<8, cellPayload: { _, _ in nil }).map(\.path) == ["output/movie.mp4"])
        withExtendedLifetime(delegate) { }
    }

    @Test("Web links still belong to the web detector")
    func webLink() {
        let url = "https://example.com/api(foo/bar)"
        #expect(TerminalFileLinkDetector.links(rows: [row(url)], columns: 120).isEmpty)
        #expect(TerminalURLDetector.urlAt(col: 10, row: 0, lineText: { _ in url })?.hasPrefix("https://example.com/") == true)
    }

    @Test("Host resolution receives the captured Agent context, not a Viewer-joined path")
    func resolvesOnHost() async throws {
        var requests: [FileBrowserOperation] = []
        let source = FileBrowserSource(id: "remote-host", paneID: "%42") { operation in
            requests.append(operation)
            guard case let .repositoryInfo(path, context) = operation, context == self.context else {
                throw FileBrowserError.message("Unexpected directory scan/download")
            }
            let absolute = path == "." ? "/Host/project" : "/Host/project/" + path
            return .info(.init(path: absolute, name: "file", kind: path == "." ? .directory : .unsupported, size: 99, revision: "1"))
        }
        let path = "output/John's %27.pdf"
        let marker = try #require(RepositoryFileLink.marker(path: path))
        let decoded = try #require(RepositoryFileLink.path(marker))
        let file = try await TerminalFileDestination.resolve(path: decoded, context: context, source: source)
        #expect(file == .init(directory: "/Host/project/output", file: "/Host/project/" + path))
        let folder = try await TerminalFileDestination.resolve(path: ".", context: context, source: source)
        #expect(folder == .init(directory: "/Host/project", file: nil))
        #expect(requests == [.repositoryInfo(path: path, context: context), .repositoryInfo(path: ".", context: context)])
        await #expect(throws: (any Error).self) {
            _ = try await TerminalFileDestination.resolve(path: "output/file", context: nil, source: source)
        }
        #expect(requests.count == 2)
    }

    @Test("Invalid decoded paths fail before I/O", arguments: [
        "", "/tmp/file", "../file", "~/file", "dir/../file", "bad\0file", "bad\nfile", "bad\tfile", "bad\u{1b}file",
        "outputs/final_films/", "dir//file",
        String(repeating: "中", count: 1400),
    ])
    func invalidDecodedPaths(path: String) async {
        let source = FileBrowserSource(id: "host", paneID: "%1") { _ in
            Issue.record("Invalid path must not reach Host")
            throw FileBrowserError.message("Unexpected Host request")
        }
        await #expect(throws: (any Error).self) {
            _ = try await TerminalFileDestination.resolve(path: path, context: context, source: source)
        }
    }

    @Test func offlineAndUnsupportedHostDoNotSendRequests() async {
        let source = FileBrowserSource(id: "remote", paneID: "%1", unavailableReason: "Update Host") { _ in
            Issue.record("Unsupported Host must not receive requests")
            throw FileBrowserError.message("Unexpected")
        }
        await #expect(throws: (any Error).self) {
            _ = try await TerminalFileDestination.resolve(path: "output/file.mp4", context: context, source: source)
        }
    }

    @Test func missingFileAndCancelledResolutionDoNotProduceDestinations() async {
        var requests: [FileBrowserOperation] = []
        let missing = FileBrowserSource(id: "host", paneID: "%1") { operation in
            requests.append(operation)
            throw FileBrowserError.message("Not found")
        }
        await #expect(throws: (any Error).self) {
            _ = try await TerminalFileDestination.resolve(path: "missing/file", context: context, source: missing)
        }
        #expect(requests == [.repositoryInfo(path: "missing/file", context: context)])
        let delayed = FileBrowserSource(id: "host", paneID: "%1") { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return .info(.init(path: "/host/file", name: "file", kind: .text, size: 0, revision: "1"))
        }
        let task = Task {
            try await TerminalFileDestination.resolve(path: "file", context: context, source: delayed)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
