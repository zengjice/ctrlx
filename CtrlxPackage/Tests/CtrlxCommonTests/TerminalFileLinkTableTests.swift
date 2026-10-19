import Foundation
import SwiftTerm
import Testing
@testable import CtrlxCommon

@MainActor
struct TerminalFileLinkTableTests {
    private let widths = [28, 12, 34]

    private func line(_ values: [String], widths: [Int]? = nil) -> String {
        zip(values, widths ?? self.widths).map { value, width in
            value + String(repeating: " ", count: max(0, width - value.count))
        }.joined(separator: "  ")
    }

    private func rule(_ character: Character = "─", widths: [Int]? = nil) -> String {
        (widths ?? self.widths).map { String(repeating: character, count: $0) }.joined(separator: "  ")
    }

    private func links(_ lines: [String]) -> [TerminalFileLink] {
        TerminalFileLinkDetector.links(rows: lines.enumerated().map { number, text in
            .init(number: number, cells: text.enumerated().map { .init($0.element, column: $0.offset) })
        }, columns: 100)
    }

    @Test("Wrapped directory references in a rendered table exclude the other columns", arguments: [Character("─"), "━", "-"])
    func screenshotDirectories(separator: Character) {
        let result = links([
            line(["Directory", "Size", "Description"]), rule(separator),
            line(["<repo:.build-local/", "1.99 GiB", "Recent simulator cache"]),
            line(["DerivedData/iOS-", "", ""]),
            line(["Simulator>", "", ""]), rule(separator),
            line(["<repo:.build-local/", "0.85 GiB", "Old simulator application"]),
            line(["DerivedData/macOS-", "", ""]),
            line(["Simulator45>", "", ""]), rule(separator),
        ])
        #expect(result.map(\.path) == [".build-local/DerivedData/iOS-Simulator", ".build-local/DerivedData/macOS-Simulator45"])
        #expect(result.first?.spans == [.init(row: 2, columns: 0..<19), .init(row: 3, columns: 0..<16), .init(row: 4, columns: 0..<10)])
        #expect(!result.contains { $0.contains(column: 30, row: 2) || $0.contains(column: 44, row: 6) })
    }

    @Test("Independent columns preserve prefix and percent-escape wraps")
    func simultaneousColumns() {
        let sizes = [12, 24, 24]
        let result = links([
            rule(widths: sizes),
            line(["Report", "<re", "<repo:outputs/"], widths: sizes),
            line(["", "po:folder%2", "final/"], widths: sizes),
            line(["", "0name/file.txt>", "film.mp4>"], widths: sizes),
        ])
        #expect(result.map(\.path) == ["folder name/file.txt", "outputs/final/film.mp4"])
        #expect(result.first?.spans.first == .init(row: 1, columns: 14..<17))
        #expect(result.last?.spans.first == .init(row: 1, columns: 40..<54))
        #expect(!result.contains { $0.contains(column: 38, row: 2) })
    }

    @Test("An incomplete reference cannot cross table boundaries or consume another column")
    func rejectedContinuations() {
        for continuation in [
            [rule(), line(["file.txt>", "", ""])],
            ["", line(["file.txt>", "", ""])],
            [line(["", "file.txt>", ""])],
            [line(["wrong column boundary crosses here", "", ""]), line(["file.txt>", "", ""])],
            [line(["bad file.txt>", "", ""])],
            [line(["<repo:new/file.txt", "", ""])],
        ] {
            #expect(links([rule(), line(["<repo:output/", "1 GiB", "Description"])] + continuation).isEmpty)
        }
        #expect(links([line(["<repo:output/", "1 GiB", "Description"]), line(["file.txt>", "", ""])]).isEmpty)
    }

    @Test("Table parsing does not change surrounding prose or a later table's column widths")
    func surroundingOutput() {
        let result = links([
            "Before: <repo:before.txt>", rule(),
            line(["<repo:first/", "1", ""]), line(["file.txt>", "", ""]), "",
            "After: <repo:after.txt>", rule(widths: [12, 24]),
            line(["Second", "<repo:second/"], widths: [12, 24]),
            line(["", "file.txt>"], widths: [12, 24]),
        ])
        #expect(result.map(\.path) == ["before.txt", "first/file.txt", "after.txt", "second/file.txt"])
    }

    final private class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) { }
    }

    @Test("Real terminal cells share table underline and hit targets, including wide characters")
    func terminalSnapshot() throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 100, rows: 10))
        terminal.feed(text: "\(rule())\r\n")
        terminal.feed(text: "\u{1b}[32m<repo:输出/\u{1b}[0m\u{1b}[31G1.99 GiB\u{1b}[45G缓存\r\n")
        terminal.feed(text: "成片.mp4>\u{1b}[31Gcontinued\r\n$ ")
        var snapshot = TerminalFileLinkSnapshot()
        let detected = snapshot.links(terminal: terminal, cellPayload: { _, _ in nil })
        let link = try #require(detected.first)
        #expect(detected.count == 1)
        #expect(link.path == "输出/成片.mp4")
        #expect(link.spans == [.init(row: 1, columns: 0..<11), .init(row: 2, columns: 0..<9)])
        for span in link.spans {
            for column in span.columns {
                #expect(snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).first { $0.contains(column: column, row: span.row) } == link)
            }
        }
        #expect(!link.contains(column: 30, row: 1))
        #expect(!link.contains(column: 44, row: 1))
        terminal.feed(text: "\u{1b}[3;1H\u{1b}[2Kother.txt>\r\n$ ")
        #expect(snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).map(\.path) == ["输出/other.txt"])
        terminal.feed(text: "\u{1b}[2;1H")
        #expect(snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).isEmpty)
        withExtendedLifetime(delegate) { }
    }

    @Test("Table columns retain OSC 8 ownership")
    func tableWebLink() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 100, rows: 10))
        terminal.feed(text: "\(rule())\r\n")
        terminal.feed(text: "<repo:output/\u{1b}[31G\u{1b}]8;;https://example.com\u{1b}\\Open\u{1b}]8;;\u{1b}\\\r\nfile.txt>\r\n$ ")
        #expect(TerminalFileLinkDetector.links(terminal: terminal, rows: 0..<10, cellPayload: { _, _ in nil }).map(\.path) == ["output/file.txt"])
        #expect(TerminalFileLinkDetector.links(terminal: terminal, rows: 0..<10, cellPayload: { _, row in
            row == 2 ? ";https://example.com" : nil
        }).isEmpty)
        withExtendedLifetime(delegate) { }
    }
}
