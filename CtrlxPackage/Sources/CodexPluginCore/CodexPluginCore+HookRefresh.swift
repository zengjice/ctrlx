import CtrlxPluginProtocol
import Foundation

extension CodexPluginCore {
    public nonisolated func hookTrustAllows(_ key: AgentHookTrustKey, lines: [String]) -> Bool {
        switch key {
        case .next: hookTrustPanel(lines: lines) == .trusted || hookDetails(lines) != nil
        case .details: hookTrustPanel(lines: lines) == .trusted && selectedHookEvent(lines) == "UserPromptSubmit"
        case .back: hookDetails(lines) != nil
        case .toggle: selectedHook(lines)?.canRefresh == true
        }
    }

    func refreshTrustedHooks(_ terminal: AgentHookTrustTerminal) async throws {
        let original = try await findRefreshHook(terminal)
        var needsRestore = false
        do {
            // Mark before sending: a failed transport can leave the outcome unknown.
            needsRestore = true
            try await toggleHook(original, enabled: false, terminal: terminal)
            // Native repaint is optimistic. Read back both saved states so a
            // failed write cannot look like a successful configuration refresh.
            let disabled = try await reopenHook(original, terminal: terminal)
            guard !disabled.enabled else {
                throw AgentHookTrustError("Codex did not save the temporary hook setting.")
            }
            try await toggleHook(original, enabled: true, terminal: terminal)
            let persisted = try await reopenHook(original, terminal: terminal)
            guard persisted.enabled else { throw AgentHookTrustError("Codex did not save the restored hook setting.") }
            needsRestore = false
            try await leaveHookDetails(terminal)
        } catch {
            if needsRestore {
                do {
                    let persisted = try await reopenHook(original, terminal: terminal)
                    if !persisted.enabled {
                        try await toggleHook(original, enabled: true, terminal: terminal)
                    }
                    guard try await reopenHook(original, terminal: terminal).enabled else {
                        throw AgentHookTrustError("The hook is still disabled.")
                    }
                    try await leaveHookDetails(terminal)
                } catch {
                    throw AgentHookTrustError("Hook refresh stopped and the original setting could not be verified. In /hooks → UserPromptSubmit, check CtrlX hook \(original.index) and turn it back on if disabled. \(error.localizedDescription)", preservePanel: true)
                }
            }
            throw error
        }
    }

    private func findRefreshHook(_ terminal: AgentHookTrustTerminal, matching original: HookHandler? = nil) async throws -> HookHandler {
        var events: Set<String> = []
        for _ in 0..<32 {
            let lines = try await waitForHookScreen(terminal) { self.hookTrustPanel(lines: $0) == .trusted }
            guard let event = selectedHookEvent(lines), events.insert(event).inserted else { break }
            if event == "UserPromptSubmit" {
                try await terminal.perform(.press(.details, screen: lines))
                return try await findHookHandler(terminal, matching: original)
            }
            try await terminal.perform(.press(.next, screen: lines))
        }
        throw AgentHookTrustError("Codex did not expose UserPromptSubmit. No hook settings were changed.")
    }

    private func findHookHandler(_ terminal: AgentHookTrustTerminal, matching original: HookHandler?) async throws -> HookHandler {
        var selections: Set<Int> = []
        for _ in 0..<64 {
            let lines = try await waitForHookScreen(terminal) { self.hookDetails($0) != nil }
            guard let index = selectedHookIndex(lines), selections.insert(index).inserted else { break }
            if let original, index == original.index {
                guard let hook = selectedHook(lines), hook.matches(original), hook.canRefresh else {
                    throw AgentHookTrustError("The CtrlX hook changed during refresh. Check /hooks before trying again.")
                }
                return hook
            }
            if original == nil, let hook = selectedHook(lines), hook.canRefresh, hook.enabled {
                return hook
            }
            try await terminal.perform(.press(.next, screen: lines))
        }
        throw AgentHookTrustError("No enabled, trusted CtrlX UserPromptSubmit hook is available to refresh. Existing disabled hooks were kept off.")
    }

    private func toggleHook(_ original: HookHandler, enabled: Bool, terminal: AgentHookTrustTerminal) async throws {
        let lines = try await terminal.read()
        guard let hook = selectedHook(lines), hook.matches(original), hook.canRefresh, hook.enabled != enabled else {
            throw AgentHookTrustError("The CtrlX hook selection changed. Nothing was toggled.")
        }
        try await terminal.perform(.press(.toggle, screen: lines))
        _ = try await waitForHookScreen(terminal) {
            guard let value = self.selectedHook($0) else { return false }
            return value.matches(original) && value.canRefresh && value.enabled == enabled
        }
    }

    private func reopenHook(_ original: HookHandler, terminal: AgentHookTrustTerminal) async throws -> HookHandler {
        let lines = try await terminal.read()
        if hookDetails(lines) != nil {
            try await leaveHookDetails(terminal)
        }
        if try hookTrustPanel(lines: await terminal.read()) != nil {
            try await terminal.perform(.close)
        }
        try await terminal.perform(.open)
        return try await findRefreshHook(terminal, matching: original)
    }

    private func leaveHookDetails(_ terminal: AgentHookTrustTerminal) async throws {
        let lines = try await terminal.read()
        guard hookDetails(lines) != nil else { throw AgentHookTrustError("The hook details changed. Check the terminal.") }
        try await terminal.perform(.press(.back, screen: lines))
        _ = try await waitForHookScreen(terminal) { self.hookTrustPanel(lines: $0) == .trusted }
    }

    private func waitForHookScreen(_ terminal: AgentHookTrustTerminal, matching predicate: ([String]) -> Bool) async throws -> [String] {
        var previous: [String]?
        var stableReads = 0
        for _ in 0..<30 {
            try Task.checkCancellation()
            let lines = try await terminal.read()
            if predicate(lines) {
                stableReads = previous == lines ? stableReads + 1 : 1
                if stableReads >= 4 {
                    return lines
                }
            } else {
                stableReads = 0
            }
            previous = lines
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AgentHookTrustError("Codex did not confirm the expected hook state. Check /hooks before trying again.")
    }

    private nonisolated func selectedHookEvent(_ lines: [String]) -> String? {
        let rows = hookRows(lines)
        guard let title = rows.lastIndex(of: "Hooks") else { return nil }
        return rows.dropFirst(title + 1).first { $0.hasPrefix("› ") }?.dropFirst(2).split(separator: " ").first.map(String.init)
    }

    private nonisolated func hookDetails(_ lines: [String]) -> [String]? {
        let rows = hookRows(lines)
        guard let title = rows.lastIndex(of: "UserPromptSubmit hooks") else { return nil }
        let details = Array(rows.dropFirst(title + 1))
        guard
            details.joined(separator: " ").hasPrefix("Turn hooks on or off. Your changes are saved automatically."),
            details.last == "space/enter toggle · esc back" || details.last == "esc back" else { return nil }
        return details
    }

    private nonisolated func selectedHookIndex(_ lines: [String]) -> Int? {
        guard let row = hookDetails(lines)?.first(where: { $0.hasPrefix("› [") }), let marker = row.firstIndex(of: "]") else { return nil }
        return row[row.index(after: marker)...].split(separator: " ").first.flatMap { Int($0) }
    }

    private nonisolated func selectedHook(_ lines: [String]) -> HookHandler? {
        guard
            let rows = hookDetails(lines), let index = selectedHookIndex(lines),
            let selected = rows.first(where: { $0.hasPrefix("› [") }),
            selected.hasPrefix("› [x] ") || selected.hasPrefix("› [ ] "),
            let sourceStart = rows.firstIndex(where: { $0.hasPrefix("Source ") }),
            let commandStart = rows.firstIndex(where: { $0.hasPrefix("Command ") }),
            let modeStart = rows.firstIndex(where: { $0.hasPrefix("Mode ") }),
            sourceStart < commandStart, commandStart < modeStart,
            rows.contains("Event UserPromptSubmit"),
            let trust = rows.first(where: { $0.hasPrefix("Trust ") }) else { return nil }
        return HookHandler(
            index: index,
            enabled: selected.hasPrefix("› [x] "),
            source: rows[sourceStart..<commandStart].joined(separator: " "),
            command: rows[commandStart..<modeStart].joined(separator: " "),
            canRefresh: trust == "Trust Trusted" && ["Source Plugin - ctrlx-hooks@ctrlx", "Source Plugin - ctrlx@ctrlx"].contains(rows[sourceStart..<commandStart].joined(separator: " ")) && rows.last == "space/enter toggle · esc back"
        )
    }

    private nonisolated func hookRows(_ lines: [String]) -> [String] {
        lines.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.filter { !$0.isEmpty }
    }
}

private struct HookHandler: Sendable {
    let index: Int
    let enabled: Bool
    let source: String
    let command: String
    let canRefresh: Bool

    func matches(_ other: Self) -> Bool {
        index == other.index && source == other.source && command == other.command
    }
}
