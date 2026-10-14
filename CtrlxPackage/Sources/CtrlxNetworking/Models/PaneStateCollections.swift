import Foundation

/// A tmux session none of whose panes owns an agent session — the system
/// menu's terminal-only rows (issue #702 follow-on). Agent-owning sessions are
/// represented in the menu by their agent panes instead, so a session appears
/// exactly once whichever bucket it falls in.
public struct TerminalOnlySession: Equatable, Sendable, Identifiable {
    /// The tmux session name: the stable row identity and leading menu label
    /// regardless of description or working directory (see
    /// `displayTitle(homeDirectory:)` in CtrlxCommon).
    public let sessionName: String

    /// The manual "Set State" override, if the session is pinned. With no
    /// agent anywhere in the session this IS the displayed state
    /// (`CLISessionState.displayed(override:agentState:)` with a nil agent);
    /// `nil` renders the plain terminal glyph.
    public let displayedState: CLISessionState?

    /// The pane a menu-row click should select: the active window's active
    /// pane, else the first pane by `(windowIndex, paneIndex)`.
    public let representativePaneId: String

    /// The user's session description (session-scoped tmux option, scanned
    /// across panes in the same deterministic order as the override). When
    /// set, the menu row appends it after the session name.
    public let customDescription: String?

    /// The representative pane's working directory, appended to the session
    /// name when no description is set. `nil` when tmux hasn't reported one.
    public let currentPath: String?

    public var id: String { sessionName }

    public init(
        sessionName: String,
        displayedState: CLISessionState?,
        representativePaneId: String,
        customDescription: String? = nil,
        currentPath: String? = nil
    ) {
        self.sessionName = sessionName
        self.displayedState = displayedState
        self.representativePaneId = representativePaneId
        self.customDescription = customDescription
        self.currentPath = currentPath
    }
}

public extension Collection where Element == PaneState {
    /// The agent pane representing a session: attention, then working, then
    /// idle. Equal-priority agents retain the caller's window/pane order.
    var representativeAgentPane: PaneState? {
        var result: PaneState?
        for pane in self {
            guard let agent = pane.agentSession else { continue }
            if agent.needsAttention {
                return pane
            }
            if result == nil || (agent.isWorking && result?.agentSession?.isWorking != true) {
                result = pane
            }
        }
        return result
    }

    /// Progress displayed for a session's row. A real terminal progress value
    /// from any pane always wins. Only when the whole session has no terminal
    /// progress do we synthesize an indeterminate bar for a working agent.
    ///
    /// Keeping this derived avoids copying agent lifecycle state into
    /// `PaneState.progress`, where hook updates could overwrite explicit
    /// `OSC 9;4` or `ctrlx set-progress` values.
    var effectiveProgress: TerminalProgressState? {
        if let terminalProgress = lazy.compactMap(\.progress).first {
            return terminalProgress
        }
        return contains(where: { $0.agentSession?.isWorking == true })
            ? .indeterminate
            : nil
    }

    /// Groups these panes into terminal-only sessions: one entry per session
    /// whose panes ALL lack an agent session, sorted by session name — a
    /// deterministic output order; callers that need a display order sort the
    /// result themselves (the menu uses the sidebar's `SidebarSortMode`). The
    /// override is scanned across every pane in `(windowIndex, paneIndex)`
    /// order — a deterministic winner when siblings disagree, matching the
    /// sidebar's `TmuxSession.cliSessionState` scan — and a partial stamp
    /// still surfaces. Panes with an empty session name (agent-only upserts
    /// that haven't been reconciled with a tmux scan yet) never form a row.
    func terminalOnlySessions() -> [TerminalOnlySession] {
        Dictionary(grouping: self, by: \.sessionName)
            .compactMap { sessionName, panes -> TerminalOnlySession? in
                guard !sessionName.isEmpty,
                      panes.allSatisfy({ $0.agentSession == nil })
                else { return nil }
                let ordered = panes.sorted {
                    ($0.windowIndex, $0.paneIndex) < ($1.windowIndex, $1.paneIndex)
                }
                guard let representative = ordered.first(where: { $0.isWindowActive && $0.isActive })
                    ?? ordered.first
                else { return nil }
                return TerminalOnlySession(
                    sessionName: sessionName,
                    displayedState: ordered.compactMap(\.cliSessionState).first,
                    representativePaneId: representative.paneId,
                    customDescription: ordered.compactMap(\.customDescription).first,
                    currentPath: representative.currentPath
                )
            }
            .sorted {
                $0.sessionName.localizedCaseInsensitiveCompare($1.sessionName) == .orderedAscending
            }
    }

    /// The pending badge count over these panes: agent panes whose displayed
    /// state is `.waiting` (per agent pane, honoring the manual override in
    /// both directions — issue #702) PLUS terminal-only sessions pinned to
    /// `.waiting`, counted once per session even though the override stamps
    /// every sibling pane. Equals the number of bell rows the menu dropdown
    /// renders for the same panes — with one accepted transient: an agent
    /// pane whose hook arrived before any tmux scan (empty `sessionName`)
    /// counts here but isn't a row anywhere until the next scan (≤5s) fills
    /// its metadata in. Deliberate: the iOS badge INCREASE rides that
    /// session's alert push and is never re-pushed, so excluding the pane
    /// would freeze the phone's badge too low rather than briefly high.
    /// Callers with panes from several hosts must apply this per host so
    /// same-named sessions don't merge.
    var pendingSessionCount: Int {
        let agentPending = filter { $0.agentSession != nil && $0.displayedState == .waiting }.count
        let terminalPending = terminalOnlySessions().count { $0.displayedState == .waiting }
        return agentPending + terminalPending
    }
}
