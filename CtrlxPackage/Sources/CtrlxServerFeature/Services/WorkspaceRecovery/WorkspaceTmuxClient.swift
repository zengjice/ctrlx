import CtrlxCommon
import Dependencies
import DependenciesMacros
import Foundation

struct WorkspaceTmuxState: Equatable, Sendable {
    var serverID: String?
    var sessions: [WorkspaceRecoverySession]
    var incompleteSessionIDs: Set<UUID> = []
    var incompleteWindowIDs: Set<UUID> = []
    var placeholderPaneIDs: Set<UUID> = []
    var deadPaneIDs: Set<UUID> = []
}

struct WorkspaceRecoveryFailure: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let reason: String
    var canResume = false
    var canUseShell = false
    var keepCurrentTerminal = false
    var blocksInput = false
    var canRetry = false
}

struct WorkspaceTmuxRestoreResult: Sendable {
    var state: WorkspaceTmuxState
    var failures: [WorkspaceRecoveryFailure]
    var createdPaneIDs: Set<UUID>
}

enum WorkspaceRecoveryClosedTarget: Equatable, Sendable {
    case session(UUID)
    case window(UUID)
    case pane(UUID)
}

typealias WorkspaceRecoveryCloseOperation = @MainActor () async throws -> WorkspaceRecoveryClosedTarget?
typealias WorkspaceRecoveryCloseHandler = @MainActor (WorkspaceRecoveryCloseOperation) async throws -> Void

@DependencyClient
struct WorkspaceTmuxClient: Sendable {
    var capture: @Sendable () async throws -> WorkspaceTmuxState
    var restore: @Sendable ([WorkspaceRecoverySession]) async throws -> WorkspaceTmuxRestoreResult
}

/// A serial recovery transaction owns only newly created/incomplete objects. Existing
/// live sessions are never renamed, resized, killed, or sent saved commands.
actor WorkspaceTmuxRecovery {
    static let sessionKey = "@ctrlx-recovery-session"
    static let windowKey = "@ctrlx-recovery-window"
    static let paneKey = "@ctrlx-recovery-pane"
    static let agentPendingKey = "@ctrlx-recovery-agent-pending"
    static let agentLaunchKey = "@ctrlx-recovery-agent-launch"
    static let placeholderDirectoryKey = "@ctrlx-recovery-directory"
    static let sessionIncompleteKey = "@ctrlx-recovery-session-incomplete"
    static let windowIncompleteKey = "@ctrlx-recovery-window-incomplete"

    private let run: @Sendable ([String]) async throws -> ProcessResult
    private let shell: @Sendable () async -> (command: String, environment: [String])
    private let system: WorkspaceRecoverySystem
    private var operationInProgress = false

    init(
        run: @escaping @Sendable ([String]) async throws -> ProcessResult,
        shell: @escaping @Sendable () async -> (command: String, environment: [String]),
        system: WorkspaceRecoverySystem
    ) {
        self.run = run
        self.shell = shell
        self.system = system
    }

    nonisolated var client: WorkspaceTmuxClient {
        WorkspaceTmuxClient(capture: { try await self.capture() }, restore: { try await self.restore($0) })
    }

    private struct Row: Sendable {
        var fields: [String]
        var sessionID: String {
            fields[1]
        }

        var windowID: String {
            fields[7]
        }

        var paneID: String {
            fields[13]
        }
    }

    private static let format = [
        "#{pid}:#{start_time}", "#{session_id}", "#{session_name}", "#{\(sessionKey)}",
        "#{@ctrlx-description}", "#{@ctrlx-color}", "#{@ctrlx-emoji}",
        "#{window_id}", "#{window_index}", "#{window_name}", "#{window_active}",
        "#{window_layout}", "#{\(windowKey)}", "#{pane_id}", "#{?pane_dead,#{pane_start_path},#{pane_current_path}}",
        "#{pane_active}", "#{\(paneKey)}", "#{\(sessionIncompleteKey)}", "#{\(windowIncompleteKey)}",
        "#{\(agentPendingKey)}", "#{pane_dead}", "#{\(placeholderDirectoryKey)}", "#{\(agentLaunchKey)}",
    ].joined(separator: "\u{1f}")

    private func rows() async throws -> [Row] {
        // macOS can briefly lose the process cwd while a new shell execs. Reread
        // that metadata; never substitute the start directory into a checkpoint.
        for attempt in 0..<5 {
            let rows = try await readRows()
            if rows.allSatisfy({ !$0.fields[14].isEmpty }) {
                return rows
            }
            if attempt < 4 {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        throw WorkspaceRecoveryError("Tmux pane working directories are temporarily unavailable. The saved workspace has been kept.")
    }

    private func readRows() async throws -> [Row] {
        let result = try await run(["list-panes", "-a", "-F", Self.format])
        guard result.isSuccess else {
            let error = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            if error.hasPrefix("no server running") || error == "no sessions" {
                return []
            }
            let prefix = "error connecting to "
            let suffix = " (No such file or directory)"
            if error.hasPrefix(prefix), error.hasSuffix(suffix) {
                let path = String(error.dropFirst(prefix.count).dropLast(suffix.count))
                if !system.pathExists(path) {
                    return []
                }
            }
            throw WorkspaceRecoveryError("Cannot read tmux for workspace recovery: \(error)")
        }
        return try result.stdoutString.split(separator: "\n").map { line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 23 else { throw WorkspaceRecoveryError("Incomplete tmux workspace snapshot; the previous snapshot is kept.") }
            return Row(fields: fields)
        }.filter { !$0.fields[2].hasPrefix(EditorOverride.probeSessionPrefix) }
    }

    func capture() async throws -> WorkspaceTmuxState {
        guard !operationInProgress else { throw WorkspaceRecoveryError("Workspace recovery is already in progress.") }
        operationInProgress = true
        defer { operationInProgress = false }
        return try await captureCurrent()
    }

    private func captureCurrent(expectedServerID: String? = nil) async throws -> WorkspaceTmuxState {
        var captured = try await rows()
        if let expectedServerID, captured.first?.fields[0] != expectedServerID {
            throw RestoreTargetChanged()
        }
        var assigned: Set<String> = []
        var assignments: [[String]] = []
        for row in captured {
            for (target, field, scope, key) in [
                (row.sessionID, 3, [String](), Self.sessionKey),
                (row.windowID, 12, ["-w"], Self.windowKey),
                (row.paneID, 16, ["-p"], Self.paneKey),
            ] where row.fields[field].isEmpty && assigned.insert(target).inserted {
                assignments.append(Self.identityAssignment(serverID: row.fields[0], target: target, scope: scope, key: key))
            }
        }
        if !assignments.isEmpty {
            for batch in Self.identityAssignmentBatches(assignments) {
                try Task.checkCancellation()
                _ = try await checked(batch)
            }
            captured = try await rows()
            if let expectedServerID, captured.first?.fields[0] != expectedServerID {
                throw RestoreTargetChanged()
            }
        }
        return try Self.state(from: captured)
    }

    /// Discovery and recovery can observe the same missing UUID concurrently.
    /// Assign only on the observed server and only while the option is still empty.
    static func identityAssignment(serverID: String, target: String, scope: [String], key: String) -> [String] {
        let condition = "#{&&:#{==:#{pid}:#{start_time},\(serverID)},#{==:#{\(key)},}}"
        let command = (["set-option"] + scope + ["-t", target, key, UUID().uuidString])
            .map(\.posixSingleQuoted).joined(separator: " ")
        return ["if-shell", "-F", "-t", target, condition, command]
    }

    /// Identity commands contain only bounded runtime IDs/UUIDs. Sixteen per
    /// invocation leaves room under tmux's command-message size limit. Each
    /// assignment keeps its own server/empty-option check across batch awaits.
    static func identityAssignmentBatches(_ assignments: [[String]]) -> [[String]] {
        stride(from: 0, to: assignments.count, by: 16).map { start in
            var batch: [String] = []
            for assignment in assignments[start..<min(start + 16, assignments.count)] {
                if !batch.isEmpty {
                    batch.append(";")
                }
                batch += assignment
            }
            return batch
        }
    }

    private static func state(from rows: [Row]) throws -> WorkspaceTmuxState {
        var result = WorkspaceTmuxState(serverID: rows.first?.fields[0], sessions: [])
        guard rows.allSatisfy({ $0.fields[0] == result.serverID }) else { throw WorkspaceRecoveryError("Tmux changed during capture.") }
        for (sessionRuntime, sessionRows) in Dictionary(grouping: rows, by: \.sessionID).sorted(by: { $0.key < $1.key }) {
            guard let first = sessionRows.first, let sessionID = UUID(uuidString: first.fields[3]) else {
                throw WorkspaceRecoveryError("Missing persistent session identity.")
            }
            func optional(_ field: Int) -> String? {
                first.fields[field].isEmpty ? nil : first.fields[field]
            }
            var session = WorkspaceRecoverySession(
                id: sessionID, runtimeID: sessionRuntime, name: first.fields[2],
                description: optional(4), color: optional(5), emoji: optional(6), windows: []
            )
            if first.fields[17] == "1" {
                result.incompleteSessionIDs.insert(sessionID)
            }
            for (runtime, windowRows) in Dictionary(grouping: sessionRows, by: \.windowID) {
                guard
                    let row = windowRows.first, let id = UUID(uuidString: row.fields[12]),
                    let index = Int(row.fields[8]), let parsed = TmuxLayoutParser.parse(row.fields[11]) else {
                    throw WorkspaceRecoveryError("Invalid saved tmux window metadata.")
                }
                let panes = try windowRows.map { row -> WorkspaceRecoveryPane in
                    guard let paneID = UUID(uuidString: row.fields[16]) else { throw WorkspaceRecoveryError("Missing persistent pane identity.") }
                    let owned = UUID(uuidString: row.fields[19]) == paneID
                    let placeholder = owned && row.fields[20] == "1"
                    if row.fields[20] == "1" {
                        result.deadPaneIDs.insert(paneID)
                    }
                    // Include the initial inert process before it exits, but use
                    // actual cwd for live processes another client may have started.
                    if placeholder || (owned && !row.fields[21].isEmpty && row.fields[22].isEmpty) {
                        result.placeholderPaneIDs.insert(paneID)
                    }
                    let directory = placeholder && !row.fields[21].isEmpty ? row.fields[21] : row.fields[14]
                    return WorkspaceRecoveryPane(id: paneID, runtimeID: row.paneID, directory: directory)
                }
                let identities = Dictionary(panes.map { ($0.runtimeID, $0.id) }, uniquingKeysWith: { first, _ in first })
                let layout = try WorkspaceRecoveryLayout(parsed, identities: identities)
                let activePane = windowRows.first { $0.fields[15] == "1" }.flatMap { UUID(uuidString: $0.fields[16]) }
                let window = WorkspaceRecoveryWindow(
                    id: id,
                    runtimeID: runtime,
                    index: index,
                    name: row.fields[9],
                    selectedPaneID: activePane,
                    layout: layout,
                    panes: layout.paneIDs.compactMap { id in panes.first { $0.id == id } }
                )
                session.windows.append(window)
                if row.fields[10] == "1" {
                    session.selectedWindowID = id
                }
                if row.fields[18] == "1" {
                    result.incompleteWindowIDs.insert(id)
                }
            }
            session.windows.sort { $0.index < $1.index }
            result.sessions.append(session)
        }
        try WorkspaceRecoverySnapshot(hostID: UUID(), bootID: "validation", serverID: result.serverID, sessions: result.sessions).validate()
        return result
    }

    func restore(_ sessions: [WorkspaceRecoverySession]) async throws -> WorkspaceTmuxRestoreResult {
        guard !operationInProgress else { throw WorkspaceRecoveryError("Workspace recovery is already in progress.") }
        operationInProgress = true
        defer { operationInProgress = false }
        try WorkspaceRecoverySnapshot(hostID: UUID(), bootID: "validation", sessions: sessions).validate()
        var state = try await captureCurrent()
        var serverID = state.serverID
        let previousPaneIDs = Set(state.sessions.flatMap(\.windows).flatMap(\.panes).map(\.id))
        var failures: [WorkspaceRecoveryFailure] = []
        for saved in sessions {
            do {
                try Task.checkCancellation()
                if let live = state.sessions.first(where: { $0.id == saved.id }), !state.incompleteSessionIDs.contains(live.id) {
                    continue
                }
                if let conflict = state.sessions.first(where: { $0.name == saved.name && $0.id != saved.id }) {
                    throw WorkspaceRecoveryError("A different live session already uses '\(conflict.name)'. It has been kept.")
                }
                var live = state.sessions.first { $0.id == saved.id }
                if live == nil {
                    let linked = state.sessions.flatMap(\.windows).first { $0.id == saved.windows.first?.id }
                    serverID = try await createSession(saved, linking: linked, serverID: serverID)
                    state = try await captureCurrent(expectedServerID: serverID)
                    live = state.sessions.first { $0.id == saved.id }
                }
                guard let live else { throw WorkspaceRecoveryError("The created session could not be identified. Retry after checking tmux.") }
                guard let serverID else { throw RestoreTargetChanged() }
                let sessionTarget = RestoreTarget(live.runtimeID, key: Self.sessionKey, id: live.id)
                for window in saved.windows {
                    do {
                        try await restoreWindow(window, session: live, state: state)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as RestoreTargetChanged {
                        throw error
                    } catch {
                        if !failures.contains(where: { $0.id == window.id }) {
                            failures.append(.init(id: window.id, name: "\(saved.name) / \(window.name)", reason: error.localizedDescription))
                        }
                    }
                    state = try await captureCurrent(expectedServerID: serverID)
                }
                if !saved.windows.contains(where: { window in failures.contains { $0.id == window.id } }) {
                    if let active = saved.selectedWindowID, let window = state.sessions.first(where: { $0.id == saved.id })?.windows.first(where: { $0.id == active }) {
                        let target = "\(live.runtimeID):\(window.index)"
                        _ = try await checked(["select-window", "-t", target], serverID: serverID, targets: [
                            sessionTarget, RestoreTarget(target, key: Self.windowKey, id: window.id),
                        ])
                    }
                    _ = try await checked(["set-option", "-u", "-t", live.runtimeID, Self.sessionIncompleteKey], serverID: serverID, targets: [sessionTarget])
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as RestoreTargetChanged {
                throw error
            } catch {
                failures.append(.init(id: saved.id, name: saved.name, reason: error.localizedDescription))
            }
        }
        let finalState = try await captureCurrent(expectedServerID: serverID)
        let newPaneIDs = Set(finalState.sessions.flatMap(\.windows).flatMap(\.panes).map(\.id)).subtracting(previousPaneIDs)
        return WorkspaceTmuxRestoreResult(state: finalState, failures: failures, createdPaneIDs: newPaneIDs)
    }

    private static func initialCommand(placeholder: Bool, shell: String) -> String {
        placeholder ? "exec /bin/sleep 2147483647" : shell
    }

    private static func finishPlaceholder(for pane: WorkspaceRecoveryPane, target: String, placeholder: Bool) -> [String] {
        guard placeholder else { return [] }
        // Only this newly created inert process is replaced. Subsequent resume
        // uses respawn-pane without -k, so tmux refuses to replace a live process.
        return [
            ";",
            "set-option",
            "-p",
            "-t",
            target,
            "remain-on-exit",
            "on",
            ";",
            "set-option",
            "-p",
            "-t",
            target,
            agentPendingKey,
            pane.id.uuidString,
            ";", "set-option", "-p", "-t", target, placeholderDirectoryKey, pane.directory,
            ";",
            "respawn-pane",
            "-k",
            "-t",
            target,
            "/usr/bin/true",
        ]
    }

    private func createSession(_ saved: WorkspaceRecoverySession, linking linked: WorkspaceRecoveryWindow?, serverID: String?) async throws -> String {
        guard let first = saved.windows.first, let pane = first.panes.first else { throw WorkspaceRecoveryError("The saved session is empty.") }
        let directoryAvailable = system.directoryExists(pane.directory)
        let placeholder = !directoryAvailable || pane.agent != nil || pane.unavailableAgentReason != nil
        let config = await shell()
        let target = "=\(saved.name):"
        var args = [
            "new-session",
            "-d",
            "-P", "-F", "#{pid}:#{start_time}",
            "-s",
            saved.name,
            "-n",
            first.name,
            "-x",
            String(max(first.layout.width, first.panes.count * 3)),
            "-y",
            String(first.layout.height),
            "-c",
            linked == nil && directoryAvailable ? pane.directory : "/",
        ]
        args += config.environment.flatMap { ["-e", $0] }
        // tmux needs an initial window to create a session. When linking, replace
        // this inert bootstrap in the same command queue without launching a shell.
        args += linked == nil ? ["/bin/sh", "-c", Self.initialCommand(placeholder: placeholder, shell: config.command)] : ["/bin/sleep", "2147483647"]
        args += [
            ";",
            "set-option",
            "-t",
            target,
            Self.sessionKey,
            saved.id.uuidString,
            ";",
            "set-option",
            "-t",
            target,
            Self.sessionIncompleteKey,
            "1",
        ]
        for (key, value) in [("@ctrlx-description", saved.description), ("@ctrlx-color", saved.color), ("@ctrlx-emoji", saved.emoji)] {
            if let value {
                args += [";", "set-option", "-t", target, key, value]
            }
        }
        if let linked {
            args += [";", "link-window", "-d", "-k", "-s", linked.runtimeID, "-t", "\(target)^"]
        } else {
            args += [
                ";",
                "set-option",
                "-w",
                "-t",
                target,
                Self.windowKey,
                first.id.uuidString,
                ";",
                "set-option",
                "-w",
                "-t",
                target,
                Self.windowIncompleteKey,
                "1",
                ";",
                "set-option",
                "-p",
                "-t",
                target,
                Self.paneKey,
                pane.id.uuidString,
            ]
            args += Self.finishPlaceholder(for: pane, target: target, placeholder: placeholder)
        }
        let targets = linked.map { [RestoreTarget($0.runtimeID, key: Self.windowKey, id: $0.id)] } ?? []
        let createdServerID = try await checked(args, serverID: serverID, targets: targets).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !createdServerID.isEmpty, serverID == nil || createdServerID == serverID else { throw RestoreTargetChanged() }
        return createdServerID
    }

    private func restoreWindow(_ saved: WorkspaceRecoveryWindow, session: WorkspaceRecoverySession, state: WorkspaceTmuxState) async throws {
        let config = await shell()
        guard let serverID = state.serverID else { throw RestoreTargetChanged() }
        let sessionTarget = RestoreTarget(session.runtimeID, key: Self.sessionKey, id: session.id)
        guard let first = saved.panes.first else { throw WorkspaceRecoveryError("The saved window is empty.") }
        var live = state.sessions.first { $0.id == session.id }?.windows.first { $0.id == saved.id }
        var incomplete = state.incompleteWindowIDs.contains(saved.id)
        if live == nil, var linked = state.sessions.flatMap(\.windows).first(where: { $0.id == saved.id }) {
            _ = try await checked(["link-window", "-d", "-s", linked.runtimeID, "-t", "\(session.runtimeID):\(saved.index)"], serverID: serverID, targets: [
                sessionTarget, RestoreTarget(linked.runtimeID, key: Self.windowKey, id: linked.id),
            ])
            linked.index = saved.index
            live = linked
        }
        if live == nil {
            let directoryAvailable = system.directoryExists(first.directory)
            let placeholder = !directoryAvailable || first.agent != nil || first.unavailableAgentReason != nil
            let target = "\(session.runtimeID):\(saved.index)"
            var args = ["new-window", "-d", "-t", target, "-n", saved.name, "-c", directoryAvailable ? first.directory : "/"]
            args += config.environment.flatMap { ["-e", $0] }
            args += [
                "/bin/sh",
                "-c",
                Self.initialCommand(placeholder: placeholder, shell: config.command),
                ";",
                "set-option",
                "-w",
                "-t",
                target,
                Self.windowKey,
                saved.id.uuidString,
                ";",
                "set-option",
                "-w",
                "-t",
                target,
                Self.windowIncompleteKey,
                "1",
                ";",
                "set-option",
                "-p",
                "-t",
                target,
                Self.paneKey,
                first.id.uuidString,
            ]
            args += Self.finishPlaceholder(for: first, target: target, placeholder: placeholder)
            _ = try await checked(args, serverID: serverID, targets: [sessionTarget])
            live = try await captureCurrent(expectedServerID: serverID).sessions.first { $0.id == session.id }?.windows.first { $0.id == saved.id }
            incomplete = true
        }
        guard let live else { throw WorkspaceRecoveryError("The new window could not be identified.") }
        let windowTarget = RestoreTarget(live.runtimeID, key: Self.windowKey, id: live.id)
        let windowTargets = [sessionTarget, windowTarget]
        if live.index != saved.index {
            let source = "\(session.runtimeID):\(live.index)"
            _ = try await checked(["move-window", "-s", source, "-t", "\(session.runtimeID):\(saved.index)"], serverID: serverID, targets: [
                sessionTarget, RestoreTarget(source, key: Self.windowKey, id: live.id),
            ])
        }
        guard incomplete else { return }
        // An incomplete window may contain shells from an earlier attempt. Reuse only
        // those identities; unknown panes are user work and must not be rearranged.
        guard Set(live.panes.map(\.id)).isSubset(of: Set(saved.panes.map(\.id))) else {
            throw WorkspaceRecoveryError("The incomplete window contains new panes. Its live layout has been kept.")
        }
        _ = try await checked(["resize-window", "-t", live.runtimeID, "-x", String(max(saved.layout.width, saved.panes.count * 3)), "-y", String(saved.layout.height)], serverID: serverID, targets: windowTargets)
        var panes = Dictionary(uniqueKeysWithValues: live.panes.map { ($0.id, $0.runtimeID) })
        guard let source = live.panes.first else { throw WorkspaceRecoveryError("The incomplete window has no shell.") }
        for pane in saved.panes where panes[pane.id] == nil {
            let directoryAvailable = system.directoryExists(pane.directory)
            let placeholder = !directoryAvailable || pane.agent != nil || pane.unavailableAgentReason != nil
            var args = ["split-window", "-h", "-l", "1", "-t", source.runtimeID, "-c", directoryAvailable ? pane.directory : "/", "-P", "-F", "#{pane_id}"]
            args += config.environment.flatMap { ["-e", $0] }
            args += [
                "/bin/sh",
                "-c",
                Self.initialCommand(placeholder: placeholder, shell: config.command),
                ";",
                "set-option",
                "-p",
                "-t",
                live.runtimeID,
                Self.paneKey,
                pane.id.uuidString,
            ]
            args += Self.finishPlaceholder(for: pane, target: live.runtimeID, placeholder: placeholder)
            panes[pane.id] = try await checked(args, serverID: serverID, targets: [
                sessionTarget, RestoreTarget(source.runtimeID, key: Self.paneKey, id: source.id, windowID: live.id),
            ]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // select-layout assigns leaves in tmux's pane-list order, ignoring the
        // IDs embedded in the layout string. Reorder only this incomplete window
        // before applying geometry, otherwise equal-looking splits swap contents.
        var ordered = try await checked(["list-panes", "-t", live.runtimeID, "-F", "#{pane_id}"], serverID: serverID, targets: windowTargets)
            .split(separator: "\n").map(String.init)
        for (index, id) in saved.layout.paneIDs.enumerated() {
            guard let target = panes[id], let currentIndex = ordered.firstIndex(of: target), ordered.indices.contains(index) else {
                throw WorkspaceRecoveryError("Pane membership changed while restoring layout.")
            }
            if currentIndex != index {
                guard let otherID = panes.first(where: { $0.value == ordered[index] })?.key else { throw RestoreTargetChanged() }
                _ = try await checked(["swap-pane", "-d", "-s", target, "-t", ordered[index]], serverID: serverID, targets: [
                    sessionTarget,
                    RestoreTarget(target, key: Self.paneKey, id: id, windowID: live.id),
                    RestoreTarget(ordered[index], key: Self.paneKey, id: otherID, windowID: live.id),
                ])
                ordered.swapAt(index, currentIndex)
            }
        }
        var args = try [
            "select-layout",
            "-t",
            live.runtimeID,
            saved.layout.tmuxLayout(panes: panes),
            ";",
            "resize-window",
            "-t",
            live.runtimeID,
            "-x",
            String(saved.layout.width),
            "-y",
            String(saved.layout.height),
        ]
        var layoutTargets = windowTargets
        if let selectedID = saved.selectedPaneID, let selected = panes[selectedID] {
            args += [";", "select-pane", "-t", selected]
            layoutTargets.append(RestoreTarget(selected, key: Self.paneKey, id: selectedID, windowID: live.id))
        }
        _ = try await checked(args, serverID: serverID, targets: layoutTargets)
        let verified = try await captureCurrent(expectedServerID: serverID).sessions.first { $0.id == session.id }?.windows.first { $0.id == saved.id }
        guard verified?.layout == saved.layout else { throw WorkspaceRecoveryError("Tmux did not restore the expected pane layout. The recovery remains retryable.") }
        _ = try await checked(["set-option", "-w", "-u", "-t", live.runtimeID, Self.windowIncompleteKey], serverID: serverID, targets: windowTargets)
    }

    private struct RestoreTarget {
        let runtimeID: String
        let condition: String

        init(_ runtimeID: String, key: String, id: UUID, windowID: UUID? = nil) {
            self.runtimeID = runtimeID
            let identity = "#{==:#{\(key)},\(id.uuidString)}"
            self.condition = windowID.map { "#{&&:\(identity),#{==:#{\(windowKey)},\($0.uuidString)}}" } ?? identity
        }
    }

    private struct RestoreTargetChanged: LocalizedError {
        var errorDescription: String? {
            "The tmux server or recovery target changed. Recovery stopped; retry after checking the current workspace."
        }
    }

    private func checked(_ arguments: [String], serverID: String? = nil, targets: [RestoreTarget] = []) async throws -> String {
        let rejection = "ctrlx-workspace-restore-target-changed"
        func command(_ arguments: [String]) -> String {
            arguments.map { $0 == ";" ? ";" : $0.posixSingleQuoted }.joined(separator: " ")
        }
        var guarded = arguments
        if let serverID {
            // Synchronous format guards and their mutations share tmux's command
            // queue. A separate read before an await cannot protect runtime IDs.
            let serverCondition = "#{==:#{pid}:#{start_time},\(serverID)}"
            for (index, target) in targets.enumerated().reversed() {
                let condition = index == 0 ? "#{&&:\(serverCondition),\(target.condition)}" : target.condition
                guarded = ["if-shell", "-F", "-t", target.runtimeID, condition, command(guarded), "display-message -p \(rejection)"]
            }
            if targets.isEmpty {
                guarded = ["if-shell", "-F", serverCondition, command(guarded), "display-message -p \(rejection)"]
            }
        }
        let result = try await run(guarded)
        if result.stdoutString.split(separator: "\n").contains(Substring(rejection)) {
            throw RestoreTargetChanged()
        }
        guard result.isSuccess else { throw WorkspaceRecoveryError(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return result.stdoutString
    }
}
