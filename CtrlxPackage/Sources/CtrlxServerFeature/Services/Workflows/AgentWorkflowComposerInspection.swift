import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import SwiftTerm

struct AgentWorkflowTerminalCapture: Sendable {
    let ansi: String
    let width: Int
    let height: Int
    let cursorX: Int
    let cursorY: Int
    let cursorVisible: Bool
    let bracketedPaste: Bool
    let inCopyMode: Bool
    let foregroundCommand: String
}

@MainActor
enum AgentWorkflowComposerInspection {
    final private class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) { }
    }

    static func readiness(_ capture: AgentWorkflowTerminalCapture, composer: AgentWorkflowComposer) -> AgentWorkflowReadiness {
        guard
            capture.width >= 20, capture.width <= 4_096,
            capture.height > 0, capture.height <= 512,
            capture.cursorY >= 0, capture.cursorY < capture.height,
            capture.cursorX == composer.prompt.count,
            capture.bracketedPaste, !capture.inCopyMode else { return .unavailable }
        let rows = capture.ansi.components(separatedBy: "\n")
        guard rows.count >= capture.height else { return .unavailable }
        let delegate = Delegate()
        defer { withExtendedLifetime(delegate) { } }
        let terminal = Terminal(delegate: delegate, options: .init(cols: capture.width, rows: capture.height))
        // tmux preserves SGR across lines. Position each row explicitly so a
        // full-width row cannot introduce a second newline through autowrap.
        for row in 0..<capture.height {
            terminal.feed(text: "\u{1b}[\(row + 1);1H\(rows[row])")
        }
        func text(_ row: Int) -> String {
            terminal.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true, characterProvider: {
                let character = terminal.getCharacter(for: $0)
                return character == "\0" || character == "\u{a0}" ? " " : character
            }) ?? ""
        }
        let row = capture.cursorY
        let line = text(row)
        if !capture.cursorVisible {
            // Claude draws its caret as an inverse blank instead of showing
            // the terminal cursor. A hidden cursor alone is not readiness.
            guard
                composer.drawsInverseCursor, let cells = terminal.getLine(row: row),
                capture.cursorX < capture.width,
                terminal.getCharacter(for: cells[capture.cursorX]) == " ",
                cells[capture.cursorX].attribute.style.contains(.inverse) else { return .unavailable }
        }
        guard line == composer.prompt.trimmingCharacters(in: .whitespaces) || line.hasPrefix(composer.prompt) else { return .unavailable }
        for index in max(0, row - 8)..<row {
            if composer.pendingInputHints.contains(where: { text(index).contains($0) }) {
                return .awaitingHuman
            }
        }
        if composer.enclosedByRules {
            func isRule(_ index: Int) -> Bool {
                guard index >= 0, index < capture.height else { return false }
                let value = text(index)
                return value.count >= capture.width - 1 && value.allSatisfy { $0 == "─" }
            }
            guard isRule(row - 1), isRule(row + 1) else { return .draft }
        }
        let body = String(line.dropFirst(composer.prompt.count)).trimmingCharacters(in: .whitespaces)
        if let placeholder = composer.dimPlaceholder {
            guard body == placeholder, let cells = terminal.getLine(row: row) else { return .draft }
            for column in capture.cursorX..<(capture.cursorX + placeholder.count) {
                guard column < capture.width, cells[column].attribute.style.contains(.dim) else { return .draft }
            }
            return .ready
        }
        return body.isEmpty ? .ready : .draft
    }
}
