/// Defaults for new user choices, not for decoding historical agent identity.
public enum AgentLaunchDefaults {
    public static let pluginID = "codex"

    /// Creation forms prefer the official Codex login when the Host offers it.
    public static func providerID(pluginID: String, availableIDs: [String]) -> String? {
        pluginID == Self.pluginID && availableIDs.contains("openai") ? "openai" : nil
    }

    /// Preserve explicit choices. Never select an agent absent from this Host.
    public static func selectedID(availableIDs: [String], selection: String? = nil) -> String? {
        if let selection, availableIDs.contains(selection) {
            return selection
        }
        return availableIDs.contains(pluginID) ? pluginID : availableIDs.first
    }
}
