import CtrlxNetworking
import Foundation

/// Platform-neutral Agent presentation policy used by the app-wide iOS monitor.
///
/// The first `.idle` may describe the turn that existed before the prompt was
/// submitted, so it cannot complete a newly-observed turn. Once `.working` has
/// arrived, a later idle state is a valid terminal fallback. These decisions
/// update the card and notifications; the service ends the shared task after
/// the final tracked turn reaches a terminal decision.
public enum AgentBackgroundMonitoringPolicy {
    /// Acknowledges that iOS launched the system monitor for this turn.
    public static let initialActivityUnits: Int64 = 1

    /// Ten-second monitoring units provide a finite two-hour background budget.
    public static let maximumActivityUnits: Int64 = 720

    /// A full state snapshot is deliberately infrequent: live status frames are
    /// the primary path, while snapshots only repair a frame missed during a
    /// reconnect or suspension.
    public static let snapshotInterval: TimeInterval = 30

    /// Avoid requesting a full snapshot during the initial connection handshake.
    public static let initialSnapshotDelay: TimeInterval = 5

    /// Healthy sockets receive the production keepalive within this window.
    /// A continued-processing monitor probes and replaces a connection that has
    /// seen no inbound frame for longer than this.
    public static let connectionStaleInterval: Duration = .seconds(30)

    /// The global reporter ticks every ten seconds. Coalesce probes per Host in
    /// case scene transitions also request immediate maintenance.
    public static let connectionProbeInterval: TimeInterval = 8

    /// Diagnostics below this threshold are normal scheduling/network jitter and
    /// stay silent to avoid turning every Agent event into log noise.
    public static let deliveryWarningThreshold: TimeInterval = 3

    /// Status and notification frames are separate encrypted messages. Whichever
    /// one reaches iOS first owns the local alert; the other is discarded.
    public static let notificationDeduplicationInterval: TimeInterval = 5

    public enum Phase: Sendable, Equatable {
        case waitingForAgent
        case working
    }

    public enum TerminalReason: Sendable, Equatable {
        case completed
        case waitingForInput
    }

    public enum Decision: Sendable, Equatable {
        case keep(Phase)
        case terminal(TerminalReason)
    }

    public static func decision(for state: AgentState, phase: Phase) -> Decision {
        switch state {
        case .working:
            return .keep(.working)

        case .awaitingPlanApproval,
             .awaitingPermission,
             .awaitingReplies:
            return .terminal(.waitingForInput)

        case .doneWorking:
            return .terminal(.completed)

        case .idle:
            return phase == .working ? .terminal(.completed) : .keep(.waitingForAgent)
        }
    }

    /// A foreground response that can resume Agent work starts monitoring. Empty
    /// free-text submissions are ignored; structured decisions are explicit user
    /// actions and can start the Agent again after a blocking state.
    public static func shouldStart(for response: AgentResponse) -> Bool {
        let text: String
        switch response {
        case let .prompt(value), let .replyAfterStop(value):
            text = value
        case .permission,
             .askUserQuestion,
             .approvePlan:
            return true
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A working Agent can accept steering or a queued follow-up. Only a
    /// blocking form owns terminal input exclusively.
    public static func canSubmitPrompt(from state: AgentState) -> Bool {
        switch state {
        case .idle,
             .doneWorking,
             .working:
            return true
        case .awaitingPlanApproval,
             .awaitingPermission,
             .awaitingReplies:
            return false
        }
    }

    public static func nextActivityUnit(
        after current: Int64,
        limit: Int64 = maximumActivityUnits
    ) -> Int64? {
        let (next, overflow) = current.addingReportingOverflow(1)
        guard !overflow, next < limit else { return nil }
        return next
    }

    /// Restore one full monitoring window without replacing the active system task.
    public static func renewedActivityUnitLimit(after completed: Int64) -> Int64 {
        let (limit, overflow) = completed.addingReportingOverflow(maximumActivityUnits)
        return overflow ? Int64.max : limit
    }

    public static func shouldRequestSnapshot(
        sessionStartedAt: Date,
        lastSnapshotAt: Date?,
        now: Date
    ) -> Bool {
        guard now.timeIntervalSince(sessionStartedAt) >= initialSnapshotDelay else {
            return false
        }
        guard let lastSnapshotAt else { return true }
        return now.timeIntervalSince(lastSnapshotAt) >= snapshotInterval
    }

    public static func deliveryDelay(eventAt: Date, receivedAt: Date) -> TimeInterval {
        max(0, receivedAt.timeIntervalSince(eventAt))
    }

    public static func isDuplicateNotification(
        lastDeliveredAt: Date?,
        now: Date
    ) -> Bool {
        guard let lastDeliveredAt else { return false }
        let elapsed = now.timeIntervalSince(lastDeliveredAt)
        return elapsed >= 0 && elapsed < notificationDeduplicationInterval
    }

    public static func shouldEmitTerminalNotification(
        reason: TerminalReason,
        recoveredFromSnapshot: Bool
    ) -> Bool {
        recoveredFromSnapshot || reason == .completed
    }
}

/// Tracks enough of one terminal input line to distinguish a real prompt from
/// an empty Enter. History navigation marks the line as terminal-managed because
/// the recalled text is rendered remotely and never sent back through iOS.
public struct AgentPromptInputAccumulator: Sendable, Equatable {
    private var text = ""
    private var hasTerminalManagedText = false

    public init() { }

    public mutating func recordPaste(_ value: String) {
        // Newlines in a clipboard paste edit the draft; only Send submits it.
        text.append(value)
    }

    public mutating func consume(_ keys: [TmuxKey]) -> Bool {
        var submittedPrompt = false

        for key in keys {
            switch key {
            case let .text(value):
                for character in value {
                    if character.isNewline {
                        submittedPrompt = submitCurrentLine() || submittedPrompt
                    } else {
                        text.append(character)
                    }
                }
            case .space:
                text.append(" ")
            case .shiftEnter:
                text.append("\n")
            case .backspace:
                if !text.isEmpty { text.removeLast() }
            case .enter:
                submittedPrompt = submitCurrentLine() || submittedPrompt
            case let .ctrl(character) where character == "c" || character == "u" || character == "w":
                text = ""
                hasTerminalManagedText = false
            case .up,
                 .down:
                // Shell and Agent history replace the editable line inside the
                // remote TUI; no replacement text travels back through iOS.
                hasTerminalManagedText = true
            case .escape,
                 .tab,
                 .backtab,
                 .delete,
                 .left,
                 .right,
                 .home,
                 .end,
                 .pageUp,
                 .pageDown,
                 .ctrl,
                 .alt,
                 .ctrlAlt,
                 .delay:
                break
            }
        }

        return submittedPrompt
    }

    private mutating func submitCurrentLine() -> Bool {
        defer {
            text = ""
            hasTerminalManagedText = false
        }
        return hasTerminalManagedText
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
