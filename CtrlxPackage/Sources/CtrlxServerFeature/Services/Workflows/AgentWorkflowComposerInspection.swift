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
    /// Nil when the tmux server cannot report this mode.
    let bracketedPaste: Bool?
    let inCopyMode: Bool
    let foregroundCommand: String

    static func parse(_ output: String) throws -> Self {
        guard let newline = output.firstIndex(of: "\n") else { throw AgentWorkflowError("The terminal snapshot is incomplete.") }
        let values = output[..<newline].components(separatedBy: "\u{1f}")
        guard
            values.count == 8,
            let width = Int(values[0]), let height = Int(values[1]), let x = Int(values[2]), let y = Int(values[3]),
            [values[4], values[6]].allSatisfy({ $0 == "0" || $0 == "1" }),
            ["", "0", "1"].contains(values[5]) else {
            throw AgentWorkflowError("Cannot inspect this tmux terminal's input mode.")
        }
        return .init(
            ansi: String(output[output.index(after: newline)...]), width: width, height: height, cursorX: x, cursorY: y,
            cursorVisible: values[4] == "1", bracketedPaste: values[5].isEmpty ? nil : values[5] == "1",
            inCopyMode: values[6] == "1", foregroundCommand: values[7]
        )
    }

    var plainLines: [String] {
        ansi.replacingOccurrences(of: "\u{1b}\\[[0-9;:]*m", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{a0}", with: " ")
            .components(separatedBy: "\n")
    }
}

@MainActor
enum AgentWorkflowComposerInspection {
    final private class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) { }
    }

    static func settledCapture(
        composer: AgentWorkflowComposer,
        capture: @MainActor () async throws -> AgentWorkflowTerminalCapture
    ) async throws -> AgentWorkflowTerminalCapture {
        var current = try await capture()
        // Focusing a tab can Fit it. Codex briefly moves its cursor onto a
        // blank row while redrawing, even though its composer is still empty.
        for _ in 0..<4 {
            guard !current.inCopyMode, readiness(current, composer: composer) == .unavailable else { return current }
            try await Task.sleep(for: .milliseconds(100))
            current = try await capture()
        }
        return current
    }

    static func hasImages(_ capture: AgentWorkflowTerminalCapture, composer: AgentWorkflowComposer, count: Int) -> Bool {
        imageNumbers(capture, composer: composer)?.count == count
    }

    static func imageNumbers(_ capture: AgentWorkflowTerminalCapture, composer: AgentWorkflowComposer) -> [Int]? {
        guard
            capture.bracketedPaste != false, !capture.inCopyMode,
            capture.cursorY >= 0, capture.cursorY < capture.height else { return nil }
        let lines = capture.plainLines
        guard
            lines.count >= capture.height,
            let start = (max(0, capture.cursorY - 16)...capture.cursorY).reversed().first(where: { lines[$0].hasPrefix(composer.prompt) }) else { return nil }
        let text = ([String(lines[start].dropFirst(composer.prompt.count))] + Array(lines[(start + 1)..<(capture.cursorY + 1)]))
            .joined().filter { !$0.isWhitespace }
        guard !text.isEmpty, text.replacingOccurrences(of: "\\[Image#[1-9][0-9]*\\]", with: "", options: .regularExpression).isEmpty else { return nil }
        let parts = text.components(separatedBy: "[Image#").dropFirst()
        let numbers = parts.compactMap { Int($0.dropLast()) }
        guard numbers.count == parts.count, Set(numbers).count == numbers.count else { return nil }
        return numbers
    }

    static func readiness(_ capture: AgentWorkflowTerminalCapture, composer: AgentWorkflowComposer, allowUnknownBracketedPaste: Bool = true) -> AgentWorkflowReadiness {
        inspect(capture, composer: composer, allowUnknownBracketedPaste: allowUnknownBracketedPaste).readiness
    }

    static func apply(_ capture: AgentWorkflowTerminalCapture, composer: AgentWorkflowComposer, to instance: inout AgentWorkflowInstance) {
        let inspection = inspect(capture, composer: composer)
        instance.readiness = inspection.readiness
        instance.inputIssue = inspection.issue
    }

    static func inspect(_ capture: AgentWorkflowTerminalCapture, composer: AgentWorkflowComposer, allowUnknownBracketedPaste: Bool = true) -> (readiness: AgentWorkflowReadiness, issue: String?) {
        if capture.inCopyMode {
            return (.unavailable, "The terminal is in tmux copy mode. Exit copy mode in the Agent tab, then try again.")
        }
        guard capture.bracketedPaste == true || (allowUnknownBracketedPaste && capture.bracketedPaste == nil) else {
            return (.unavailable, "The Agent's paste mode could not be verified. Finish startup in its terminal, then try again.")
        }
        guard
            capture.width >= 20, capture.width <= 4_096,
            capture.height > 0, capture.height <= 512,
            capture.cursorY >= 0, capture.cursorY < capture.height else {
            return (.unavailable, "The terminal snapshot has invalid dimensions or cursor coordinates. Open the Agent tab and try again.")
        }
        guard capture.cursorX == composer.prompt.count else {
            return (.unavailable, "The cursor is not at the start of the Agent input. Check its tab for an unsent draft or an open dialog.")
        }
        let rows = capture.ansi.components(separatedBy: "\n")
        guard rows.count >= capture.height else {
            return (.unavailable, "The terminal snapshot is incomplete. Open the Agent tab and try again.")
        }
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
                cells[capture.cursorX].attribute.style.contains(.inverse) else {
                return (.unavailable, "The Agent's input cursor is not visible. Check its tab for startup or an open dialog.")
            }
        }
        guard line == composer.prompt.trimmingCharacters(in: .whitespaces) || line.hasPrefix(composer.prompt) else {
            return (.unavailable, "The Agent's input prompt was not recognized. Open its tab to finish login, setup or any open dialog.")
        }
        for index in max(0, row - 8)..<row {
            if composer.pendingInputHints.contains(where: { text(index).contains($0) }) {
                return (.awaitingHuman, nil)
            }
        }
        if composer.enclosedByRules {
            func isRule(_ index: Int) -> Bool {
                guard index >= 0, index < capture.height else { return false }
                let value = text(index)
                return value.count >= capture.width - 1 && value.allSatisfy { $0 == "─" }
            }
            guard isRule(row - 1), isRule(row + 1) else { return (.draft, nil) }
        }
        let body = String(line.dropFirst(composer.prompt.count)).trimmingCharacters(in: .whitespaces)
        if let placeholder = composer.dimPlaceholder {
            guard body == placeholder, let cells = terminal.getLine(row: row) else { return (.draft, nil) }
            for column in capture.cursorX..<(capture.cursorX + placeholder.count) {
                guard column < capture.width, cells[column].attribute.style.contains(.dim) else { return (.draft, nil) }
            }
            return (.ready, nil)
        }
        return (body.isEmpty ? .ready : .draft, nil)
    }
}
