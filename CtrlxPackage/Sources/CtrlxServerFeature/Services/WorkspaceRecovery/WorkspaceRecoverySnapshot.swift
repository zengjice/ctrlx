import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

enum WorkspaceRecoveryMode: String, Codable, CaseIterable, Sendable {
    case layoutAndAgents
    case layoutOnly
    case disabled
}

struct WorkspaceRecoverySnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 2
    var schemaVersion = currentVersion
    var generation: UInt64 = 0
    var savedAt = Date()
    var hostID: UUID
    var bootID: String
    var serverID: String?
    var sessions: [WorkspaceRecoverySession] = []
    var sessionOrder: [UUID] = []
    var scenes: [WorkspaceRecoveryScene] = []
    var drafts: [WorkspaceRecoveryDraft] = []
    var fileTabs: [WorkspaceRecoveryFileTab] = []
    var recovery: WorkspaceRecoveryAttempt?
    var viewerScenes: [WorkspaceRecoveryScene]?
    var resourceSessions: [ResourceSession]?
    var independentFileTabs: [HostFileTab]?

    /// Metadata changes alone must not turn the two-second capture into disk churn.
    func hasSameContents(as other: Self) -> Bool {
        var copy = self
        copy.generation = other.generation
        copy.savedAt = other.savedAt
        return copy == other
    }

    func validate() throws {
        guard schemaVersion == Self.currentVersion else {
            throw WorkspaceRecoveryError("Workspace snapshot version \(schemaVersion) is unsupported. The saved file has been kept.")
        }
        guard
            !bootID.isEmpty, Set(sessions.map(\.id)).count == sessions.count,
            Set(sessions.map(\.name)).count == sessions.count else {
            throw WorkspaceRecoveryError("Invalid or duplicate workspace session identity.")
        }
        let resources = resourceSessions ?? []
        let files = independentFileTabs ?? []
        guard
            Set(resources.map(\.id)).count == resources.count,
            Set(resources.map(\.name)).count == resources.count,
            resources.allSatisfy({ resource in
                !resource.name.isEmpty && resource.directory.hasPrefix("/") &&
                    sessions.allSatisfy { ($0.id != resource.id && $0.name != resource.name) || ($0.id == resource.id && $0.name == resource.name) }
            }),
            Set(files.map(\.id)).count == files.count,
            files.allSatisfy({ file in
                file.sourcePaneID == nil && file.windowID == nil && file.initialDirectory.hasPrefix("/") &&
                    resources.contains { $0.id == file.resourceSessionID && $0.name == file.sessionName }
            }) else { throw WorkspaceRecoveryError("Invalid independent resource identity.") }
        var sharedWindows: [UUID: WorkspaceRecoveryWindow] = [:]
        var paneWindows: [UUID: UUID] = [:]
        for session in sessions {
            guard
                !session.name.isEmpty, !session.windows.isEmpty,
                Set(session.windows.map(\.id)).count == session.windows.count,
                Set(session.windows.map(\.index)).count == session.windows.count,
                session.selectedWindowID.map({ id in session.windows.contains { $0.id == id } }) ?? true else {
                throw WorkspaceRecoveryError("Invalid saved windows in session '\(session.name)'.")
            }
            for window in session.windows {
                if var shared = sharedWindows[window.id] {
                    // A link has its own session index, but one physical window,
                    // layout and Agent description across all of its sessions.
                    shared.index = window.index
                    guard shared == window else {
                        throw WorkspaceRecoveryError("Conflicting saved links for window '\(window.name)'.")
                    }
                } else {
                    sharedWindows[window.id] = window
                }
                let ids = window.layout.paneIDs
                guard
                    window.index >= 0, window.layout.isValid,
                    !window.panes.isEmpty, ids.count == window.panes.count,
                    Set(ids).count == ids.count, Set(ids) == Set(window.panes.map(\.id)),
                    window.selectedPaneID.map({ ids.contains($0) }) ?? true,
                    window.panes.allSatisfy({ $0.directory.hasPrefix("/") }) else {
                    throw WorkspaceRecoveryError("Invalid saved panes in '\(session.name)/\(window.name)'.")
                }
                for id in ids {
                    guard paneWindows[id] == nil || paneWindows[id] == window.id else {
                        throw WorkspaceRecoveryError("A saved pane belongs to more than one physical window.")
                    }
                    paneWindows[id] = window.id
                }
            }
        }
        guard Set(scenes.map(\.id)).count == scenes.count else {
            throw WorkspaceRecoveryError("Duplicate saved native window identity.")
        }
        guard Set(drafts.map(\.id)).count == drafts.count, Set(fileTabs.map(\.id)).count == fileTabs.count else {
            throw WorkspaceRecoveryError("Duplicate saved draft or Files identity.")
        }
        for presentation in (scenes + (viewerScenes ?? [])).flatMap(\.sessions) {
            let files = presentation.layout.fileTabs
            let browsers = presentation.layout.browserTabs
            guard
                Set(files.map(\.id)).count == files.count, Set(browsers.map(\.id)).count == browsers.count,
                Set(presentation.ownedWindowIDs).count == presentation.ownedWindowIDs.count,
                Set(presentation.ownedWindowIDs).isSubset(of: Set(presentation.windowIDs.values)),
                presentation.selectedWindowID.map({ presentation.ownedWindowIDs.contains($0) }) ?? true,
                presentation.layout.splitRatio.isFinite else {
                throw WorkspaceRecoveryError("Invalid saved workbench tabs.")
            }
        }
        if let viewerScenes {
            guard Set(viewerScenes.map(\.id)).count == viewerScenes.count, viewerScenes.filter(\.isMain).count <= 1 else {
                throw WorkspaceRecoveryError("Duplicate saved Viewer scene identity.")
            }
            for scene in viewerScenes {
                guard Set(scene.sessions.compactMap(\.remoteReference)).count == scene.sessions.count else {
                    throw WorkspaceRecoveryError("Duplicate saved Viewer session identity.")
                }
                for presentation in scene.sessions {
                    guard
                        let reference = presentation.remoteReference,
                        reference.pairID == presentation.hostID, reference.sessionID == presentation.sessionID,
                        !reference.pairID.isEmpty, !presentation.sessionName.isEmpty,
                        reference.windowID == nil, reference.paneID == nil,
                        Set(presentation.ownedWindowIDs).isSubset(of: Set(presentation.windowIDs.values)),
                        presentation.fileSources?.allSatisfy({ id, source in
                            presentation.layout.fileTabs.contains { $0.id == id } && source.sessionReference == reference && source.paneID != nil && source.windowID != nil
                        }) ?? true else {
                        throw WorkspaceRecoveryError("Invalid saved Viewer workspace identity.")
                    }
                }
            }
        }
        for draft in drafts {
            if let hostID = draft.hostID {
                guard let reference = draft.remoteReference, reference.pairID == hostID, reference.paneID == draft.paneID else {
                    throw WorkspaceRecoveryError("Invalid saved Viewer draft identity.")
                }
            } else if draft.remoteReference != nil {
                throw WorkspaceRecoveryError("A local draft cannot refer to a remote Host.")
            }
        }
    }
}

struct WorkspaceRecoverySession: Codable, Equatable, Sendable {
    var id: UUID
    var runtimeID: String
    var name: String
    var description: String?
    var color: String?
    var emoji: String?
    var selectedWindowID: UUID?
    var windows: [WorkspaceRecoveryWindow]
}

struct WorkspaceRecoveryWindow: Codable, Equatable, Sendable {
    var id: UUID
    var runtimeID: String
    var index: Int
    var name: String
    var selectedPaneID: UUID?
    var layout: WorkspaceRecoveryLayout
    var panes: [WorkspaceRecoveryPane]
}

struct WorkspaceRecoveryPane: Codable, Equatable, Sendable {
    var id: UUID
    var runtimeID: String
    var directory: String
    var agent: AgentResumeDescriptor?
    /// A recognized Agent whose conversation could not be verified must never silently
    /// become an auto-launched new conversation at the same directory.
    var unavailableAgentReason: String?
}

/// Geometry retains proportions; leaves use persistent identities, not recycled tmux IDs.
indirect enum WorkspaceRecoveryLayout: Codable, Equatable, Sendable {
    case pane(UUID, width: Int, height: Int)
    case horizontal([Self], width: Int, height: Int)
    case vertical([Self], width: Int, height: Int)

    var width: Int {
        switch self {
        case let .pane(_, width, _),
             let .horizontal(_, width, _),
             let .vertical(_, width, _): width
        }
    }

    var height: Int {
        switch self {
        case let .pane(_, _, height),
             let .horizontal(_, _, height),
             let .vertical(_, _, height): height
        }
    }

    var paneIDs: [UUID] {
        switch self {
        case let .pane(id, _, _): [id]
        case let .horizontal(children, _, _),
             let .vertical(children, _, _): children.flatMap(\.paneIDs)
        }
    }

    var isValid: Bool {
        guard width > 0, height > 0 else { return false }
        switch self {
        case .pane: return true
        case let .horizontal(children, width, height):
            return children.count >= 2 && children.allSatisfy { $0.isValid && $0.height == height }
                && children.reduce(0) { $0 + $1.width } + children.count - 1 == width
        case let .vertical(children, width, height):
            return children.count >= 2 && children.allSatisfy { $0.isValid && $0.width == width }
                && children.reduce(0) { $0 + $1.height } + children.count - 1 == height
        }
    }

    init(_ node: LayoutNode, identities: [String: UUID]) throws {
        switch node {
        case let .pane(id, width, height):
            guard let identity = identities["%\(id)"] else { throw WorkspaceRecoveryError("Pane identity changed during snapshot capture.") }
            self = .pane(identity, width: width, height: height)
        case let .horizontal(children, width, height):
            self = try .horizontal(children.map { try Self($0, identities: identities) }, width: width, height: height)
        case let .vertical(children, width, height):
            self = try .vertical(children.map { try Self($0, identities: identities) }, width: width, height: height)
        }
    }

    /// Closing a recovered pane also removes its saved slot. Remaining leaves
    /// keep their proportions and fill the original window rectangle.
    func removing(_ identities: Set<UUID>) -> Self? {
        switch self {
        case let .pane(id, _, _): return identities.contains(id) ? nil : self
        case let .horizontal(children, width, height):
            let remaining = children.compactMap { $0.removing(identities) }
            guard !remaining.isEmpty else { return nil }
            if remaining.count == 1 {
                return remaining[0].expanded(width: width, height: height)
            }
            let retainedWidth = remaining.reduce(0) { $0 + $1.width } + remaining.count - 1
            return Self.horizontal(remaining, width: retainedWidth, height: height).expanded(width: width, height: height)
        case let .vertical(children, width, height):
            let remaining = children.compactMap { $0.removing(identities) }
            guard !remaining.isEmpty else { return nil }
            if remaining.count == 1 {
                return remaining[0].expanded(width: width, height: height)
            }
            let retainedHeight = remaining.reduce(0) { $0 + $1.height } + remaining.count - 1
            return Self.vertical(remaining, width: width, height: retainedHeight).expanded(width: width, height: height)
        }
    }

    private func expanded(width: Int, height: Int) -> Self {
        switch self {
        case let .pane(id, _, _): return .pane(id, width: width, height: height)
        case let .horizontal(children, oldWidth, _):
            let extra = width - oldWidth
            var used = 0
            let resized = children.enumerated().map { index, child in
                let addition = index == children.count - 1 ? extra - used : extra * child.width / oldWidth
                used += addition
                return child.expanded(width: child.width + addition, height: height)
            }
            return .horizontal(resized, width: width, height: height)
        case let .vertical(children, _, oldHeight):
            let extra = height - oldHeight
            var used = 0
            let resized = children.enumerated().map { index, child in
                let addition = index == children.count - 1 ? extra - used : extra * child.height / oldHeight
                used += addition
                return child.expanded(width: width, height: child.height + addition)
            }
            return .vertical(resized, width: width, height: height)
        }
    }

    func tmuxLayout(panes: [UUID: String]) throws -> String {
        let body = try serialize(panes: panes, x: 0, y: 0)
        var checksum: UInt16 = 0
        for byte in body.utf8 {
            checksum = (checksum >> 1) | ((checksum & 1) << 15)
            checksum = checksum &+ UInt16(byte)
        }
        return String(format: "%04x", checksum) + "," + body
    }

    private func serialize(panes: [UUID: String], x: Int, y: Int) throws -> String {
        let prefix = "\(width)x\(height),\(x),\(y)"
        switch self {
        case let .pane(id, _, _):
            guard let runtime = panes[id], runtime.first == "%", let number = Int(runtime.dropFirst()), number >= 0 else {
                throw WorkspaceRecoveryError("A restored pane is missing its tmux identity.")
            }
            return prefix + ",\(number)"
        case let .horizontal(children, _, _):
            var offset = x
            let parts = try children.map { child in
                defer { offset += child.width + 1 }
                return try child.serialize(panes: panes, x: offset, y: y)
            }
            return prefix + "{" + parts.joined(separator: ",") + "}"
        case let .vertical(children, _, _):
            var offset = y
            let parts = try children.map { child in
                defer { offset += child.height + 1 }
                return try child.serialize(panes: panes, x: x, y: offset)
            }
            return prefix + "[" + parts.joined(separator: ",") + "]"
        }
    }
}

struct WorkspaceRecoveryScene: Codable, Equatable, Sendable {
    var id: UUID
    var isMain: Bool
    var frame: CGRect?
    var sessions: [WorkspaceRecoveryPresentation]
    var selectedSessionID: UUID?
    var selectedHostID: String?
    var isSessionWindow: Bool?
}

struct WorkspaceRecoveryPresentation: Codable, Equatable, Sendable {
    var hostID: String?
    var sessionID: UUID
    var sessionName: String
    var layout: SavedFolderLayout
    /// Folder templates use indices; this map resolves them through persistent identity.
    var windowIDs: [Int: UUID]
    var ownedWindowIDs: [UUID]
    var focusedRight: Bool
    var fileScrollOffsets: [UUID: CGFloat] = [:]
    var gitDirectory: String?
    var gitState: WorkspaceGitState?
    /// The backing terminal selection also matters while a utility tab is visible.
    var selectedWindowID: UUID?
    var remoteReference: ViewerWorkspaceReference?
    var fileSources: [UUID: ViewerWorkspaceReference]?
}

struct WorkspaceRecoveryDraft: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var hostID: String?
    var paneID: UUID
    var text: String
    var remoteReference: ViewerWorkspaceReference?
}

struct WorkspaceRecoveryFileTab: Codable, Equatable, Sendable {
    var id: UUID
    var sessionID: UUID
    var windowID: UUID
    var paneID: UUID
    var group: PaneTabGroup
    var isPrimary: Bool
    var initialDirectory: String
}

/// Written before any reconstruction. On relaunch the source snapshot survives,
/// and uncertain Agent launches must be reconciled rather than sent a second time.
struct WorkspaceRecoveryAttempt: Codable, Equatable, Sendable {
    var id = UUID()
    var bootID: String
    // Includes ordinary shells waiting for their original directory to return.
    var pendingAgentPaneIDs: Set<UUID>
    var agentLaunches: [UUID: WorkspaceRecoveryAgentLaunch] = [:]
}

struct WorkspaceRecoveryAgentLaunch: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case resume, shell }
    var id = UUID()
    var serverID: String
    var runtimePaneID: String
    var kind: Kind
}

struct WorkspaceRecoveryError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
