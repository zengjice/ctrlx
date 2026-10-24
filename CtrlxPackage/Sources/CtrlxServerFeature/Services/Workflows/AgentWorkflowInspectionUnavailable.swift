import Foundation

/// A failed process scan is not evidence that the bound Agent was replaced.
struct AgentWorkflowInspectionUnavailable: LocalizedError, Sendable {
    var errorDescription: String? {
        "Agent process inspection is temporarily unavailable. Handoffs remain paused until verification succeeds and you continue."
    }
}
