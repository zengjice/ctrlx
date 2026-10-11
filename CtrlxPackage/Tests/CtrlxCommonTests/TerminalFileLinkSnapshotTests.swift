import SwiftTerm
import Testing
@testable import CtrlxCommon

@MainActor
struct TerminalFileLinkSnapshotTests {
    private final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) { }
    }

    @Test("Every underlined cell of a seven-row path has the same activation target")
    func longWrappedPath() throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 30, rows: 12))
        let path = "/tmp/" + String(repeating: "segment/", count: 24) + "file.txt"
        terminal.feed(text: "\(path)\r\n$ ")
        var snapshot = TerminalFileLinkSnapshot()
        var payloadReads = 0
        func payload(_ column: Int, _ row: Int) -> String? { payloadReads += 1; return nil }
        let decorations = snapshot.links(terminal: terminal, cellPayload: payload)
        let link = try #require(decorations.first)
        #expect(link.path == path)
        #expect(link.spans.count == 7)
        let reads = payloadReads
        for span in link.spans {
            let hitTargets = snapshot.links(terminal: terminal, cellPayload: payload)
            for column in span.columns {
                #expect(hitTargets.first { $0.contains(column: column, row: span.row) } == link)
            }
        }
        #expect(payloadReads == reads)
        withExtendedLifetime(delegate) { }
    }

    @Test("In-place line edits and cursor moves invalidate hit targets")
    func contentAndCursorChanges() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 40, rows: 5))
        terminal.feed(text: "./first/file.txt\r\n$ ")
        var snapshot = TerminalFileLinkSnapshot()
        #expect(snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).map(\.path) == ["./first/file.txt"])
        terminal.feed(text: "\u{1b}[1;1H\u{1b}[2K./other/file.txt\r\n$ ")
        #expect(snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).map(\.path) == ["./other/file.txt"])
        terminal.feed(text: "\u{1b}[1;1H")
        #expect(snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).isEmpty)
        terminal.feed(text: "\u{1b}[2;3H")
        #expect(snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).map(\.path) == ["./other/file.txt"])
        withExtendedLifetime(delegate) { }
    }

    @Test("A resize or alternate-buffer switch cannot reuse old spans")
    func layoutChanges() throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 20, rows: 8))
        let path = "./output/long-directory/file.txt"
        terminal.feed(text: "\(path)\r\n$ ")
        var snapshot = TerminalFileLinkSnapshot()
        let before = try #require(snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).first)
        #expect(before.spans.count == 2)
        terminal.resize(cols: 50, rows: 8)
        let after = try #require(snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).first)
        #expect(after.path == path && after.spans.count == 1)
        terminal.feed(text: "\u{1b}[?1049h./alt/file.txt\r\n$ ")
        #expect(snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).map(\.path) == ["./alt/file.txt"])
        terminal.feed(text: "\u{1b}[?1049l")
        #expect(snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).map(\.path) == [path])
        withExtendedLifetime(delegate) { }
    }

    @Test("Scrollback trimming and viewport scrolling refresh the snapshot")
    func scrollAndTrim() throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 40, rows: 3, scrollback: 8))
        var snapshot = TerminalFileLinkSnapshot()
        for index in 0..<30 { terminal.feed(text: "./history/\(index).txt\r\n") }
        let start = terminal.buffer.yDisp
        let first = snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).first { $0.contains(column: 0, row: start) }
        #expect(first?.path == "./history/28.txt")
        terminal.feed(text: "./history/30.txt\r\n")
        let updated = snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).first { $0.contains(column: 0, row: terminal.buffer.yDisp) }
        #expect(updated?.path == "./history/29.txt")
        terminal.buffer.yDisp = 0
        let history = try #require(snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).first { $0.contains(column: 0, row: 0) })
        #expect(history.path != updated?.path)
        withExtendedLifetime(delegate) { }
    }

    @Test("External OSC 8 payload changes are invalidated after feeding")
    func externalPayloadChanges() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 40, rows: 4))
        terminal.feed(text: "./web/label\r\n$ ")
        var snapshot = TerminalFileLinkSnapshot()
        #expect(snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).map(\.path) == ["./web/label"])
        snapshot.invalidate()
        let web = snapshot.links(terminal: terminal, cellPayload: { column, row in
            row == 0 && column < 11 ? ";https://example.com" : nil
        })
        #expect(web.isEmpty)
        withExtendedLifetime(delegate) { }
    }

    @Test("Native visible rows refresh hit targets without changing the logical display row")
    func nativeViewportChanges() throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 40, rows: 6, scrollback: 100))
        for index in 0..<60 { terminal.feed(text: "./history/\(index).txt\r\n") }
        terminal.buffer.yDisp = 0
        var snapshot = TerminalFileLinkSnapshot()
        var payloadReads = 0
        func payload(_ column: Int, _ row: Int) -> String? { payloadReads += 1; return nil }
        let initial = snapshot.links(terminal: terminal, cellPayload: payload)
        #expect(!initial.contains { $0.contains(column: 0, row: 20) })

        // Momentum, viewport growth and scrolling back can all leave yDisp unchanged.
        for visibleRows in [20..<27, 35..<42, 35..<49, 5..<12] {
            let links = snapshot.links(terminal: terminal, visibleRows: visibleRows, cellPayload: payload)
            for row in visibleRows {
                let link = try #require(links.first { $0.contains(column: 0, row: row) })
                #expect(link.path == "./history/\(row).txt")
            }
            let reads = payloadReads
            #expect(snapshot.links(terminal: terminal, visibleRows: visibleRows, cellPayload: payload) == links)
            #expect(payloadReads == reads)
            #expect(terminal.buffer.yDisp == 0)
        }
        withExtendedLifetime(delegate) { }
    }

    @Test("An empty native viewport returns no targets and can become visible again")
    func emptyNativeViewport() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 40, rows: 5))
        terminal.feed(text: "./output/file.txt\r\n$ ")
        var snapshot = TerminalFileLinkSnapshot()
        let links = snapshot.links(terminal: terminal, visibleRows: 0..<5, cellPayload: { _, _ in nil })
        #expect(links.count == 1)
        #expect(snapshot.links(terminal: terminal, visibleRows: 0..<0, cellPayload: { _, _ in nil }).isEmpty)
        #expect(snapshot.links(terminal: terminal, visibleRows: 0..<5, cellPayload: { _, _ in nil }) == links)
        withExtendedLifetime(delegate) { }
    }

    @Test("Mouse-mode changes refresh the multiline input exclusion")
    func mouseModeChanges() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 40, rows: 5))
        terminal.feed(text: "./output/file.txt\r\n\u{1b}[48;5;236m\u{1b}[2K> ./editing/first\r\n\u{1b}[2K  ./editing/second")
        var snapshot = TerminalFileLinkSnapshot()
        #expect(snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).map(\.path) == ["./output/file.txt", "./editing/first"])
        terminal.feed(text: "\u{1b}[?1003h")
        #expect(snapshot.links(terminal: terminal, cellPayload: { _, _ in nil }).map(\.path) == ["./output/file.txt"])
        withExtendedLifetime(delegate) { }
    }
}
