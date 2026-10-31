import CtrlxPluginProtocol
import Foundation

extension CodexPluginCore: AgentHookTrustProviding {
    public nonisolated var hookTrustComposer: AgentWorkflowComposer {
        workflowComposer
    }

    public nonisolated func hookTrustPanel(lines: [String]) -> AgentHookTrustPanel? {
        let rows = lines.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.filter { !$0.isEmpty }
        guard
            let title = rows.lastIndex(of: "Hooks"),
            let table = rows.indices.dropFirst(title + 1).first(where: {
                rows[$0].hasPrefix("Event Installed Active ") || rows[$0] == "Event Active/Installed"
            }),
            rows[(title + 1)..<table].joined(separator: " ").hasPrefix("Lifecycle hooks from config and enabled plugins."),
            !rows.dropFirst(title + 1).contains("Issues"),
            let footer = rows.last else { return nil }
        switch footer {
        case "t trust all · enter review · esc close": return .needsReview
        case "enter details · esc close": return .trusted
        default: return nil
        }
    }

    public func trustHooks(terminal: AgentHookTrustTerminal) async throws {
        try await terminal.perform(.open)
        let panel = try await waitForHookTrustPanel(terminal)
        if panel == .needsReview {
            try await terminal.perform(.trustAll)
            // The first repaint is optimistic. Reopen to verify persisted trust
            // through Codex's own hooks/list request before reporting success.
            _ = try await waitForHookTrustPanel(terminal, expected: .trusted)
            try await terminal.perform(.close)
            try await terminal.perform(.open)
            guard try await waitForHookTrustPanel(terminal) == .trusted else {
                throw AgentHookTrustError("Codex still reports hooks requiring review. Check /hooks before trying again.")
            }
        }
        try await terminal.perform(.close)
    }

    private func waitForHookTrustPanel(_ terminal: AgentHookTrustTerminal, expected: AgentHookTrustPanel? = nil) async throws -> AgentHookTrustPanel {
        var previous: AgentHookTrustPanel?
        var stableReads = 0
        for _ in 0..<30 {
            try Task.checkCancellation()
            let panel = try hookTrustPanel(lines: await terminal.read())
            if let panel, expected == nil || panel == expected {
                stableReads = previous == panel ? stableReads + 1 : 1
                // Let Codex finish its rapid-paste window before the next key.
                if stableReads >= 4 {
                    return panel
                }
            } else {
                stableReads = 0
            }
            previous = panel
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AgentHookTrustError("Codex did not show the expected /hooks controls. Check its terminal; no automatic retry was performed.")
    }
}
