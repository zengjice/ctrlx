import CtrlxNetworking
import Foundation
import SwiftTerm
import Testing
@testable import CtrlxCommon

@MainActor
struct TerminalFileLinkTests {
    private func row(_ text: String, number: Int = 0, wrapped: Bool = false) -> TerminalFileLinkDetector.Row {
        var column = 0
        let cells = text.map { character in
            let width = character.unicodeScalars.contains { $0.value >= 0x2E80 } ? 2 : 1
            defer { column += width }
            return TerminalFileLinkDetector.Cell(character, column: column, width: width)
        }
        return .init(number: number, cells: cells, wrapped: wrapped)
    }

    @Test("Common Host path spellings and quoted spaces are recognized", arguments: [
        "/host/out/video.mp4", "~/Movies/", "./output/图.png", "../out/视频.mp4", "episodes/A01/完整片.mp4", "file:///tmp/test%20video.mp4",
    ])
    func spellings(path: String) {
        let links = TerminalFileLinkDetector.links(rows: [row("结果 (\(path))")], columns: 160)
        #expect(links.map(\.path) == [path.hasPrefix("file:") ? "/tmp/test video.mp4" : path])
        #expect(links.first?.contains(column: 0, row: 0) == false)
        #expect(links.first?.contains(column: 6, row: 0) == true)
    }

    @Test("URLs, command switches, arbitrary words and nonlocal file authorities are not Host paths", arguments: [
        "https://example.com/output/video.mp4", "ftp://example.com/a", "--foo/bar", "ordinary", "file://another-host/tmp/a", "//server/share", "javascript://evil/a",
    ])
    func rejectsNonPaths(text: String) {
        #expect(TerminalFileLinkDetector.links(rows: [row(text)], columns: 160).isEmpty)
    }

    @Test("Plain web URLs never expose their parenthesized paths as file links", arguments: [
        "https://example.com/api(foo/bar)",
        "https://example.com/api(foo/bar)/next/file.txt",
        "https://example.com/api?arg=(foo/bar)",
        "https://example.com/api#section(foo/bar)/next/file.txt",
        "http://example.com/api[foo/bar]/next/file.txt",
        "ftp://example.com/api{foo/bar}/next/file.txt",
    ])
    func plainWebURLFragments(text: String) throws {
        let links = TerminalFileLinkDetector.links(rows: [row("中文 (\(text)) ./output/视频.mp4")], columns: 200)
        let link = try #require(links.first)
        #expect(links.map(\.path) == ["./output/视频.mp4"])
        let start = 5 + 1 + text.count + 2
        #expect(link.spans == [.init(row: 0, columns: start..<(start + 17))])

        let webLinks = TerminalURLDetector.detectURLs(row: 0, lineText: { _ in text })
        #expect(!webLinks.isEmpty)
        #expect(TerminalFileLinkDetector.links(rows: [row(text)], columns: 200).isEmpty)
    }

    @Test("Plain URL exclusion follows soft wraps, but keeps paths on the next hard line")
    func softWrappedWebURLFragments() {
        let links = TerminalFileLinkDetector.links(rows: [
            row("https://example.com/api(foo/"),
            row("bar)/next/file.txt", number: 1, wrapped: true),
            row("(./output/movie.mp4)", number: 2),
        ], columns: 40)
        #expect(links.map(\.path) == ["./output/movie.mp4"])
        #expect(links.first?.spans == [.init(row: 2, columns: 1..<19)])
    }

    @Test func quotedSpacesAndTrailingPunctuation() {
        let links = TerminalFileLinkDetector.links(rows: [row("\"/host/my movie.mp4\"; ./output/movie.mp4。 (my folder/video.mp4)")], columns: 160)
        #expect(links.map(\.path) == ["/host/my movie.mp4", "./output/movie.mp4", "my folder/video.mp4"])
    }

    @Test("Apostrophes inside prose do not swallow a following path", arguments: [
        "I've saved", "Don't forget", "John's report is", "It's ready at", "We're done; see", "Version2's report is", "I’ve saved",
    ])
    func wordApostrophes(prefix: String) {
        let path = "./output/report.pdf"
        let links = TerminalFileLinkDetector.links(rows: [row("\(prefix) \(path)")], columns: 160)
        #expect(links.map(\.path) == [path])
        let start = prefix.count + 1
        #expect(links.first?.spans == [.init(row: 0, columns: start..<(start + path.count))])
    }

    @Test("Single-quoted paths still preserve spaces after prose apostrophes", arguments: [
        "Saved", "I've saved", "Don't forget", "John's report is",
    ])
    func singleQuotedPaths(prefix: String) {
        let path = "./output/final report.pdf"
        let links = TerminalFileLinkDetector.links(rows: [row("\(prefix) '\(path)'")], columns: 160)
        #expect(links.map(\.path) == [path])
        let start = prefix.count + 2
        #expect(links.first?.spans == [.init(row: 0, columns: start..<(start + path.count))])
    }

    @Test("Unsupported apostrophes in filenames cannot expose a truncated path", arguments: [
        "someone's/report.pdf", "./someone's/report.pdf",
    ])
    func apostrophePathFragments(text: String) {
        let links = TerminalFileLinkDetector.links(rows: [row("\(text) ./output/report.pdf")], columns: 160)
        #expect(links.map(\.path) == ["./output/report.pdf"])
    }

    @Test("A soft wrap inside a contraction cannot hide later paths")
    func softWrappedApostrophe() {
        let first = "I've saved the report and I'"
        let links = TerminalFileLinkDetector.links(rows: [
            row(first),
            row("ve saved ./output/report.pdf", number: 1, wrapped: true),
        ], columns: first.count)
        #expect(links.map(\.path) == ["./output/report.pdf"])
        #expect(links.first?.spans == [.init(row: 1, columns: 9..<28)])
    }

    @Test("Nested filename brackets do not terminate the surrounding path", arguments: [
        "(./output/report (final).pdf)",
        "[./output/report [final].pdf]",
        "\"./output/report (final).pdf\"",
    ])
    func nestedBrackets(text: String) {
        let links = TerminalFileLinkDetector.links(rows: [row(text)], columns: 100)
        #expect(links.map(\.path) == [String(text.dropFirst().dropLast())])
    }

    @Test("An incomplete enclosure cannot hide later independent paths", arguments: ["(", "[", "\"", "'", "`"])
    func incompleteEnclosure(open: String) {
        let links = TerminalFileLinkDetector.links(rows: [
            row("Result \(open)./incomplete/file.txt"),
            row("An unrelated line", number: 1),
            row("./later/file.txt", number: 2),
        ], columns: 100)
        #expect(links.map(\.path) == ["./later/file.txt"])
    }

    @Test("An unrelated line's closing bracket cannot close an earlier truncated path")
    func unrelatedClosingBracket() {
        let links = TerminalFileLinkDetector.links(rows: [
            row("(./incomplete/file.txt"),
            row("./next/file.txt", number: 1),
            row("(./last/file.txt)", number: 2),
        ], columns: 100)
        #expect(links.map(\.path) == ["./next/file.txt", "./last/file.txt"])
    }

    @Test("An unfinished wrapped filename does not expose its tail as a relative path")
    func incompleteHardWrap() {
        let first = "(episodes/A01/very-long-directory"
        let links = TerminalFileLinkDetector.links(rows: [
            row(first),
            row("  tail/file.mp4", number: 1),
            row("./later/file.txt", number: 2),
        ], columns: first.count)
        #expect(links.map(\.path) == ["./later/file.txt"])
    }

    @Test("Codex's parenthesized hard wrap preserves Chinese character columns")
    func chineseHardWrap() throws {
        let first = row("结果 (episodes/A01/补齐开场_完整")
        let columns = try #require(first.cells.last).column + 2
        let second = row("    片.mp4)", number: 1)
        let link = try #require(TerminalFileLinkDetector.links(rows: [first, second], columns: columns).first)
        #expect(link.path == "episodes/A01/补齐开场_完整片.mp4")
        #expect(link.contains(column: 4, row: 1))
        #expect(link.contains(column: 5, row: 1))
        #expect(!link.contains(column: 3, row: 1))
        #expect(!link.contains(column: 10, row: 1))
    }

    @Test func softWrappedPath() {
        let links = TerminalFileLinkDetector.links(rows: [row("episodes/A01/"), row("opening/完整片.mp4", number: 1, wrapped: true)], columns: 40)
        #expect(links.map(\.path) == ["episodes/A01/opening/完整片.mp4"])
    }

    @Test("Recognition cannot combine separate short prose lines into a filename")
    func noArbitraryLineJoin() {
        let links = TerminalFileLinkDetector.links(rows: [row("(episodes/one"), row("two.mp4)", number: 1)], columns: 80)
        #expect(links.isEmpty)
    }

    @Test("Host validation uses the captured pane directory and never downloads contents")
    func resolvesOnHost() async throws {
        var requests: [String] = []
        let source = FileBrowserSource(id: "remote", paneID: "%42") { operation in
            guard case let .info(path) = operation else { throw FileBrowserError.message("Unexpected directory scan/download") }
            requests.append(path)
            let expanded = path == "~/Movies/" ? "/Host/Home/Movies" : path
            return .info(.init(path: expanded, name: "video.mp4", kind: path == "~/Movies/" ? .directory : .unsupported, size: 99, revision: "1"))
        }
        let file = try await TerminalFileDestination.resolve(path: "episodes/完整片.mp4", baseDirectory: "/Host/reel", source: source)
        #expect(file.directory == "/Host/reel/episodes" && file.file == "/Host/reel/episodes/完整片.mp4")
        let folder = try await TerminalFileDestination.resolve(path: "~/Movies/", baseDirectory: "/wrong", source: source)
        #expect(folder.directory == "/Host/Home/Movies" && folder.file == nil)
        #expect(requests == ["/Host/reel/episodes/完整片.mp4", "~/Movies/"])
        await #expect(throws: (any Error).self) {
            _ = try await TerminalFileDestination.resolve(path: "output/movie.mp4", baseDirectory: nil, source: source)
        }
        #expect(requests.count == 2)
    }

    @Test("Real OSC 8 file links reach the Host with their decoded filename intact", arguments: [
        ("file:///tmp/John%27s%20report.pdf", "/tmp/John's report.pdf"),
        ("file:///tmp/quoted%22report%22.pdf", "/tmp/quoted\"report\".pdf"),
        ("file:///tmp/pipe%7Creport.pdf", "/tmp/pipe|report.pdf"),
        ("file:///tmp/back%5Cslash.pdf", "/tmp/back\\slash.pdf"),
        ("file:///tmp/%3Creport%3E%60.pdf", "/tmp/<report>`.pdf"),
        ("file:///tmp/literal%2527.pdf", "/tmp/literal%27.pdf"),
        ("file:///tmp/literal%250A.pdf", "/tmp/literal%0A.pdf"),
    ])
    func decodedOSC8Resolution(uri: String, expected: String) async throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 4))
        terminal.feed(text: "\u{1b}]8;;\(uri)\u{1b}\\Open file\u{1b}]8;;\u{1b}\\\r\n$ ")
        let links = TerminalFileLinkDetector.links(terminal: terminal, rows: 0..<4, cellPayload: { _, _ in nil })
        let link = try #require(links.first)
        #expect(links.count == 1)
        #expect(link.path == expected)
        #expect(link.spans == [.init(row: 0, columns: 0..<9)])

        var requests: [String] = []
        let source = FileBrowserSource(id: "host", paneID: "%1") { operation in
            guard case let .info(path) = operation else { throw FileBrowserError.message("Unexpected operation") }
            requests.append(path)
            return .info(.init(path: path, name: (path as NSString).lastPathComponent, kind: .text, size: 0, revision: "1"))
        }
        let destination = try await TerminalFileDestination.resolve(path: link.path, baseDirectory: "/wrong", source: source)
        #expect(requests == [expected])
        #expect(destination == .init(directory: "/tmp", file: expected))
        withExtendedLifetime(delegate) { }
    }

    @Test("Decoded paths retain empty, control-character and UTF-8 length checks", arguments: [
        "", "/tmp/bad\0file", "/tmp/bad\nfile", "/tmp/bad\tfile", "/tmp/bad\u{1b}file",
        "/tmp/" + String(repeating: "中", count: 1400),
    ])
    func invalidDecodedPaths(path: String) async {
        var requests = 0
        let source = FileBrowserSource(id: "host", paneID: "%1") { _ in
            requests += 1
            throw FileBrowserError.message("Unexpected Host request")
        }
        await #expect(throws: (any Error).self) {
            _ = try await TerminalFileDestination.resolve(path: path, baseDirectory: "/host", source: source)
        }
        #expect(requests == 0)
    }

    @Test("OSC 8 rejects nonlocal file authorities and decoded control characters", arguments: [
        "file://another-host/tmp/John%27s.pdf", "file:///tmp/bad%00file",
        "file:///tmp/bad%0Afile", "file:///tmp/bad%1Bfile", "https://example.com/John%27s/report.pdf",
    ])
    func invalidOSC8FileLinks(uri: String) {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 4))
        terminal.feed(text: "\u{1b}]8;;\(uri)\u{1b}\\Open file\u{1b}]8;;\u{1b}\\\r\n$ ")
        #expect(TerminalFileLinkDetector.links(terminal: terminal, rows: 0..<4, cellPayload: { _, _ in nil }).isEmpty)
        withExtendedLifetime(delegate) { }
    }

    @Test func offlineAndUnsupportedHostDoNotSendRequests() async {
        let source = FileBrowserSource(id: "remote", paneID: "%1", unavailableReason: "Update Host") { _ in
            Issue.record("Unsupported Host must not receive requests")
            throw FileBrowserError.message("Unexpected")
        }
        await #expect(throws: (any Error).self) {
            _ = try await TerminalFileDestination.resolve(path: "/host/file.mp4", baseDirectory: nil, source: source)
        }
    }

    @Test func truncatedSoftWrapIsNotAPath() {
        #expect(TerminalFileLinkDetector.links(rows: [row("partial/path.mp4", wrapped: true)], columns: 80).isEmpty)
        #expect(TerminalFileLinkDetector.links(rows: [row("结果 (episodes/incomplete/path")], columns: 80).isEmpty)
    }

    @Test func missingFileAndCancelledResolutionDoNotProduceDestinations() async {
        let missing = FileBrowserSource(id: "host", paneID: "%1") { _ in
            throw FileBrowserError.message("Not found")
        }
        await #expect(throws: (any Error).self) {
            _ = try await TerminalFileDestination.resolve(path: "./missing/file", baseDirectory: "/host", source: missing)
        }
        let delayed = FileBrowserSource(id: "host", paneID: "%1") { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return .info(.init(path: "/host/file", name: "file", kind: .text, size: 0, revision: "1"))
        }
        let task = Task {
            try await TerminalFileDestination.resolve(path: "/host/file", baseDirectory: nil, source: delayed)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("A missing relative path reports failure without guessing another directory")
    func noDirectoryGuessing() async {
        var requests: [String] = []
        let source = FileBrowserSource(id: "host", paneID: "%1") { operation in
            guard case let .info(path) = operation else { throw FileBrowserError.message("Unexpected search") }
            requests.append(path)
            throw FileBrowserError.message("Not found")
        }
        await #expect(throws: (any Error).self) {
            _ = try await TerminalFileDestination.resolve(path: "./output/file.txt", baseDirectory: "/host/project", source: source)
        }
        #expect(requests == ["/host/project/./output/file.txt"])
    }

    @Test("A hard-wrapped Codex composer stays editable even with a hidden cursor")
    func composerRows() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 40, rows: 8))
        terminal.feed(text: "./output/movie.mp4\r\n\u{1b}[?1003h\u{1b}[48;5;236m\u{1b}[2K> ./editing/first\r\n\u{1b}[2K  ./editing/second\r\n\u{1b}[2K  ./editing/third\u{1b}[2;10H\u{1b}[?25l")
        let links = TerminalFileLinkDetector.links(terminal: terminal, rows: 0..<8, cellPayload: { _, _ in nil })
        #expect(links.map(\.path) == ["./output/movie.mp4"])
        withExtendedLifetime(delegate) { }
    }

    @Test("Path hit targets survive scrollback trimming and scrolling into history")
    func trimmedScrollback() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 40, rows: 3, scrollback: 8))
        for index in 0..<30 { terminal.feed(text: "./history/\(index).txt\r\n") }
        terminal.feed(text: "$ ./editing/path")
        #expect(terminal.buffer.totalLinesTrimmed > 0)
        let start = terminal.buffer.yDisp
        let links = TerminalFileLinkDetector.links(terminal: terminal, rows: start..<(start + 3), cellPayload: { _, _ in nil })
        #expect(links.map(\.path) == ["./history/28.txt", "./history/29.txt"])
        #expect(links.first?.contains(column: 0, row: start) == true)
        terminal.buffer.yDisp = 0
        let history = TerminalFileLinkDetector.links(terminal: terminal, rows: 0..<3, cellPayload: { _, _ in nil })
        #expect(history.count == 3)
        withExtendedLifetime(delegate) { }
    }

    private final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) { }
    }

    @Test("Real SwiftTerm wide/soft-wrapped cells are clickable, but the live input row is not")
    func nativeCells() throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 25, rows: 8))
        terminal.feed(text: "中文 ./output/补齐开场_完整片.mp4\r\n$ ./editing/path")
        let links = TerminalFileLinkDetector.links(terminal: terminal, rows: 0..<8, cellPayload: { _, _ in nil })
        let link = try #require(links.first)
        #expect(link.path == "./output/补齐开场_完整片.mp4")
        #expect(link.spans.count == 2)
        #expect(link.contains(column: 5, row: 0))
        #expect(!links.contains { $0.path == "./editing/path" })
        withExtendedLifetime(delegate) { }
    }

    @Test("Plain URL hit targets remain web links without OSC 8 payloads")
    func nativePlainWebLink() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 120, rows: 4))
        let url = "https://example.com/api(foo/bar)"
        terminal.feed(text: "\(url) ./output/movie.mp4\r\n$ ")
        let links = TerminalFileLinkDetector.links(terminal: terminal, rows: 0..<4, cellPayload: { _, _ in nil })
        #expect(links.map(\.path) == ["./output/movie.mp4"])
        #expect(!(0..<url.count).contains { column in links.contains { $0.contains(column: column, row: 0) } })
        #expect(TerminalURLDetector.urlAt(
            col: 25, row: 0, cols: terminal.cols,
            lineText: { terminal.getLine(row: $0)?.translateToString(trimRight: true) },
            cellPayload: { _, _ in nil }
        ) != nil)
        withExtendedLifetime(delegate) { }
    }

    @Test("Explicit web links keep precedence over path-looking labels; file labels keep wide-cell hit targets")
    func explicitLinks() throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 40, rows: 5))
        terminal.feed(text: "./web/label\r\n文件\r\n$ ")
        let links = TerminalFileLinkDetector.links(terminal: terminal, rows: 0..<5) { col, row in
            if row == 0, col < 11 { return ";https://example.com" }
            if row == 1, col < 10 { return ";file:///host/video.mp4" }
            return nil
        }
        let link = try #require(links.first)
        #expect(links.count == 1)
        #expect(link.path == "/host/video.mp4")
        #expect(link.contains(column: 3, row: 1))
        #expect(!link.contains(column: 4, row: 1))
        withExtendedLifetime(delegate) { }
    }
}
