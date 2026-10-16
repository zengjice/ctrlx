import CtrlxNetworking
import Foundation

/// Information about a tmux pane
public struct PaneInfo: Identifiable, Sendable, Hashable {
    /// The tmux pane ID (e.g., "%5") - note: may not be unique across linked sessions
    public let paneId: String
    /// The full target string (e.g., "mysession:0.1") - used as unique identifier
    public let target: String

    /// Unique identifier for Identifiable conformance (uses target since paneId can repeat in linked sessions)
    public var id: String {
        target
    }

    /// The name of the session containing this pane
    public let sessionName: String
    /// The window index within the session
    public let windowIndex: Int
    /// tmux's stable window id (for example `@3`).
    public let tmuxWindowId: String?
    public let workspaceIdentity: WorkspacePaneIdentity?
    /// Available before recovery UUIDs have been assigned to the pane.
    public let tmuxServerID: String?
    let tmuxSessionID: String?
    /// The pane index within the window
    public let paneIndex: Int
    /// The command currently running in the pane
    public let command: String
    /// The current working directory of the pane
    public let currentPath: String
    /// Width of the pane in columns
    public let width: Int
    /// Height of the pane in rows
    public let height: Int
    /// Whether this pane is the active pane in its window
    public let isActive: Bool
    /// The terminal title set via OSC escape sequences (empty string means default/unset)
    public let paneTitle: String
    /// The tmux window layout string (e.g., "d0c6,191x50,0,0{95x50,0,0,5,95x50,96,0,6}")
    public let windowLayout: String
    /// The tmux window name
    public let windowName: String
    /// Whether this pane's window is the active window in its session
    public let isWindowActive: Bool
    /// Custom description set via the tmux `@ctrlx-description` user option,
    /// resolved with tmux's window-over-session inheritance. `nil` if unset.
    public let customDescription: String?
    /// Custom color set via the tmux `@ctrlx-color` user option, resolved
    /// with tmux's window-over-session inheritance. `nil` if unset or if the
    /// stored value isn't a recognised `SessionColor` case.
    public let customColor: SessionColor?
    /// Custom emoji set via the tmux `@ctrlx-emoji` user option, resolved
    /// with tmux's window-over-session inheritance. `nil` if unset. Free-form
    /// text so any platform-supported emoji works.
    public let customEmoji: String?

    /// Window identifier combining session name and window index (e.g., "mysession:0")
    public var windowId: String {
        "\(sessionName):\(windowIndex)"
    }

    /// Stable identity for state that must survive window reordering.
    public var stableWindowId: String {
        guard let tmuxWindowId, !tmuxWindowId.isEmpty else { return windowId }
        return tmuxWindowId
    }

    public init(
        paneId: String,
        target: String,
        sessionName: String,
        windowIndex: Int,
        tmuxWindowId: String? = nil,
        paneIndex: Int,
        command: String,
        currentPath: String,
        width: Int,
        height: Int,
        isActive: Bool,
        paneTitle: String = "",
        windowLayout: String = "",
        windowName: String = "",
        isWindowActive: Bool = false,
        customDescription: String? = nil,
        customColor: SessionColor? = nil,
        customEmoji: String? = nil,
        workspaceIdentity: WorkspacePaneIdentity? = nil,
        tmuxServerID: String? = nil,
        tmuxSessionID: String? = nil
    ) {
        self.paneId = paneId
        self.target = target
        self.sessionName = sessionName
        self.windowIndex = windowIndex
        self.tmuxWindowId = tmuxWindowId
        self.workspaceIdentity = workspaceIdentity
        self.tmuxServerID = tmuxServerID ?? workspaceIdentity?.serverID
        self.tmuxSessionID = tmuxSessionID
        self.paneIndex = paneIndex
        self.command = command
        self.currentPath = currentPath
        self.width = width
        self.height = height
        self.isActive = isActive
        self.paneTitle = paneTitle
        self.windowLayout = windowLayout
        self.windowName = windowName
        self.isWindowActive = isWindowActive
        self.customDescription = customDescription
        self.customColor = customColor
        self.customEmoji = customEmoji
    }
}

public extension PaneInfo {
    /// Field separator used between substituted tmux format variables.
    ///
    /// ASCII Unit Separator (U+001F) is the canonical "this byte exists for
    /// field separation and nothing else" choice — it can't legitimately appear
    /// in `pane_title`, `window_name`, paths, commands, or user-set
    /// descriptions, so the parser never has to defend against a field value
    /// that collides with the delimiter. tmux passes the byte through `#{...}`
    /// substitution untouched (verified against tmux 3.x).
    ///
    /// `|` was used before and broke as soon as a client (Codex CLI) set a
    /// `pane_title` containing `|`; the shifted parse parked the emoji glyph
    /// in the description slot.
    static let fieldSeparator: Character = "\u{1F}"

    /// Creates a PaneInfo from tmux format output.
    ///
    /// Expected field order (separated by `fieldSeparator`):
    /// id, session, window, pane, command, path, width, height, active,
    /// title, layout, windowName, windowActive, customColor, customEmoji,
    /// customDescription, tmuxWindowId, tmuxServerID, persistent session/window/pane UUIDs,
    /// tmuxSessionID. Trailing identity fields are optional for legacy records.
    init?(fromTmuxOutput line: String) {
        let components = line.split(separator: Self.fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 9 else { return nil }

        guard
            let windowIndex = Int(components[2]),
            let paneIndex = Int(components[3]),
            let width = Int(components[6]),
            let height = Int(components[7])
        else { return nil }

        self.paneId = components[0]
        self.sessionName = components[1]
        self.windowIndex = windowIndex
        if components.count >= 17 {
            let raw = components[16]
            self.tmuxWindowId = raw.isEmpty ? nil : raw
        } else {
            self.tmuxWindowId = nil
        }
        self.paneIndex = paneIndex
        self.command = components[4]
        self.currentPath = components[5]
        self.width = width
        self.height = height
        self.isActive = components[8] == "1"
        self.paneTitle = components.count >= 10 ? components[9] : ""
        self.windowLayout = components.count >= 11 ? components[10] : ""
        self.windowName = components.count >= 12 ? components[11] : ""
        self.isWindowActive = components.count >= 13 ? components[12] == "1" : false
        if components.count >= 14 {
            // tmux only ever stores the canonical `rawValue` we wrote via
            // `set-option @ctrlx-color`, so go straight from rawValue
            // here. `parse(_:)` accepts CLI/API aliases like "violet" → purple
            // and would silently bridge them to a color tmux never persisted,
            // blurring the distinction between input parsing and storage.
            let raw = components[13]
            self.customColor = raw.isEmpty ? nil : SessionColor(rawValue: raw.lowercased())
        } else {
            self.customColor = nil
        }
        if components.count >= 15 {
            let raw = components[14]
            self.customEmoji = raw.isEmpty ? nil : raw
        } else {
            self.customEmoji = nil
        }
        if components.count >= 16 {
            let raw = components[15]
            self.customDescription = raw.isEmpty ? nil : raw
        } else {
            self.customDescription = nil
        }
        self.target = "\(sessionName):\(windowIndex).\(paneIndex)"
        self.tmuxServerID = components.count > 17 && !components[17].isEmpty ? components[17] : nil
        self.tmuxSessionID = components.count > 21 && !components[21].isEmpty ? components[21] : nil
        if
            components.count >= 21, !components[17].isEmpty,
            let session = UUID(uuidString: components[18]),
            let window = UUID(uuidString: components[19]),
            let pane = UUID(uuidString: components[20]) {
            self.workspaceIdentity = .init(serverID: components[17], sessionID: session, windowID: window, paneID: pane)
        } else {
            self.workspaceIdentity = nil
        }
    }

    /// Creates a new PaneState from this pane's metadata.
    /// Claude session, terminal title, and yolo mode are left at defaults.
    func makePaneState() -> PaneState {
        PaneState(
            paneId: paneId,
            target: target,
            sessionName: sessionName,
            windowIndex: windowIndex,
            tmuxWindowId: tmuxWindowId,
            paneIndex: paneIndex,
            command: command,
            currentPath: currentPath,
            width: width,
            height: height,
            isActive: isActive,
            windowLayout: windowLayout,
            windowName: windowName,
            isWindowActive: isWindowActive,
            customDescription: customDescription,
            customColor: customColor,
            customEmoji: customEmoji,
            workspaceIdentity: workspaceIdentity
        )
    }

    /// Updates the tmux metadata fields of an existing PaneState, preserving
    /// Claude session, terminal title, yolo mode, and other runtime state.
    @discardableResult
    func updateMetadata(of state: inout PaneState) -> Bool {
        if let previous = state.workspaceIdentity, !previous.isSamePane(as: workspaceIdentity) {
            // A reused tmux number must not inherit an old Agent, request or editor.
            state = makePaneState()
            return true
        }
        guard
            state.target != target
            || state.sessionName != sessionName
            || state.windowIndex != windowIndex
            || state.tmuxWindowId != tmuxWindowId
            || state.paneIndex != paneIndex
            || state.command != command
            || state.currentPath != currentPath
            || state.width != width
            || state.height != height
            || state.isActive != isActive
            || state.windowLayout != windowLayout
            || state.windowName != windowName
            || state.isWindowActive != isWindowActive
            || state.customDescription != customDescription
            || state.customColor != customColor
            || state.customEmoji != customEmoji
            || state.workspaceIdentity != workspaceIdentity
        else { return false }

        state.target = target
        state.sessionName = sessionName
        state.windowIndex = windowIndex
        state.tmuxWindowId = tmuxWindowId
        state.paneIndex = paneIndex
        state.command = command
        state.currentPath = currentPath
        state.width = width
        state.height = height
        state.isActive = isActive
        state.windowLayout = windowLayout
        state.windowName = windowName
        state.isWindowActive = isWindowActive
        state.customDescription = customDescription
        state.customColor = customColor
        state.customEmoji = customEmoji
        state.workspaceIdentity = workspaceIdentity
        return true
    }
}
