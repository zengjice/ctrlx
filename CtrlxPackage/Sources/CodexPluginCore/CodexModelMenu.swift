import CtrlxNetworking
import Foundation

struct CodexModelMenu {
    private let rows: [String]

    init?(lines: [String]) {
        let lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard
            let start = lines.lastIndex(where: { ["Select Model", "Select Model and Effort", "Loading models…"].contains($0) }),
            let end = lines.indices.last(where: { lines[$0] == "enter select · esc back" }),
            start < end else { return nil }
        self.rows = lines[(start + 1)..<end].compactMap { line in
            let row = line.hasPrefix("› ") ? String(line.dropFirst(2)) : line
            guard let dot = row.firstIndex(of: "."), let number = Int(row[..<dot]), (1...100).contains(number) else { return nil }
            return row[row.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        }
        guard !rows.isEmpty || lines[start] == "Loading models…" else { return nil }
    }

    func contains(_ model: AgentModelOption) -> Bool {
        rows.contains { row in
            guard row.hasPrefix(model.name) else { return false }
            let suffix = row.dropFirst(model.name.count)
            return suffix.isEmpty || suffix.hasPrefix("  ") || suffix.hasPrefix(" (current)")
        }
    }

    static func unavailableCount(modelID: String, lines: [String]) -> Int {
        // Join wrapped terminal lines, but require the native error marker and
        // exact model ID so transcript mentions and unrelated failures do not retry.
        let text = lines.joined().filter { !$0.isWhitespace }
        let error = "■ Model '\(modelID)' is unavailable. Use /model to see available models.".filter { !$0.isWhitespace }
        return text.components(separatedBy: error).count - 1
    }
}
