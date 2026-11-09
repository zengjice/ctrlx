import Observation

/// Unapplied edits belong to the Settings window, not to the running services.
@MainActor
@Observable
final class SettingsDrafts {
    var selectedAgentID = ""
    var agentCommands: [String: String] = [:]
    var tmux: TmuxSettingsDraft?

    func discard() {
        agentCommands.removeAll()
        tmux = nil
    }
}
