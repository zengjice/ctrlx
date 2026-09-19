#if os(macOS)
    import AppKit
#endif
import CtrlxCommon
import CtrlxNetworking
import SwiftUI

/// Sidebar section for a remote Mac host's sessions, grouped by tmux session
struct RemoteHostSidebarSection: View {
    let host: PairedHost
    let connection: ViewerConnection?
    let sessionStore: SessionStore
    let creatingSelection: NewSessionCreatingState?
    @Binding var selectedRemoteSession: RemoteSessionSelection?
    let isHostDragging: Bool
    let isHostDropTargeted: Bool
    let onHeaderFrameChange: (CGRect?) -> Void
    let onHostDragChanged: (CGPoint) -> Void
    let onHostDragEnded: (CGPoint) -> Void
    let onSelect: (RemoteSessionSelection) -> Void
    let onCreate: (SessionLaunchRequest) -> Void
    let onRename: (String, String) -> Void
    let onSetDescription: (String, String?) -> Void
    let onSetColor: (String, SessionColor?) -> Void
    let onSetEmoji: (String, String?) -> Void
    let onSetState: (String, CLISessionState?) -> Void
    let onToggleYolo: (String, Bool) -> Void
    let onCloseSession: (String) -> Void

    @Environment(AppSettings.self) private var settings
    @State private var sessionRenameRequest: String?

    /// Remote sessions grouped by tmux session (mirrors local session grouping)
    private var tmuxSessions: [TmuxSession] {
        sessionStore.sessions(for: host.id)
    }

    private var hasContent: Bool {
        !tmuxSessions.isEmpty
    }

    private var sortedSessions: [TmuxSession] {
        SessionSortData.sortedRemoteSessions(
            tmuxSessions,
            mode: settings.sidebarSortMode,
            sidebarFields: settings.sidebarFields,
            sidebarTerminalFields: settings.sidebarTerminalFields,
            homeDirectory: sessionStore.homeDirectoryByHost[host.id],
            preferredSessionNames: settings.remoteSessionOrder(for: host.id)
        )
    }

    var body: some View {
        Section {
            hostHeader

            if connection?.hostSubscriptionInactive == true {
                HStack(alignment: .top, spacing: 8) {
                    Symbols.exclamationmarkTriangle.image
                        .font(.system(size: 16))
                        .foregroundStyle(.orange)
                        .frame(width: 20)
                        .accessibilityHidden(true)

                    Text("Host's subscription expired")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            } else if let mismatch = connection?.versionMismatch {
                RemoteHostVersionMismatchRow(host: host, mismatch: mismatch) {
                    Task { await connection?.enableReconnectAndRetry() }
                }
            } else if hasContent {
                // The remote host's cross-session usage rollup (issue #598),
                // from its SessionStateMessage — same collapsible cell the
                // local section and the iOS list show.
                if let overview = sessionStore.usageOverview(for: host.id), !overview.isEmpty {
                    UsageOverviewView(overview: overview)
                        .padding(.vertical, 2)
                        .accessibilityIdentifier("usage-overview-remote-\(host.id)")
                }
                ForEach(sortedSessions) { session in
                    remoteSessionButton(session)
                }
                .onMove(perform: moveSessions)
            } else if connection?.isHostConnected == true {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Text("Host offline")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private var hostHeader: some View {
        SectionHeader(
            title: host.displayName(showUsername: settings.hasDuplicateHostName(for: host)),
            symbol: .laptopcomputer,
            isNewSessionDisabled: connection?.isHostConnected != true,
            newSessionButtonIdentifier: "new-session-remote-\(host.id)",
            trailing: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(hostStatusColor)
                        .frame(width: 8, height: 8)

                    Symbols.line3Horizontal.image
                        .foregroundStyle(isHostDragging ? Color.accentColor : .secondary)
                        .frame(width: 32, height: 28)
                        .background(
                            isHostDragging ? Color.accentColor.opacity(0.14) : .clear,
                            in: .rect(cornerRadius: 5)
                        )
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                                .onChanged { value in
                                    onHostDragChanged(value.location)
                                }
                                .onEnded { value in
                                    onHostDragEnded(value.location)
                                }
                        )
                        .accessibilityLabel("Reorder \(host.displayName)")
                        .accessibilityHint("Drag onto another host")
                        .accessibilityAction(named: "Move Up") {
                            moveHost(by: -1)
                        }
                        .accessibilityAction(named: "Move Down") {
                            moveHost(by: 1)
                        }
                        .help("Drag to reorder remote hosts")
                        .animation(.easeOut(duration: 0.1), value: isHostDragging)
                }
            },
            popover: {
                NewSessionContent(
                    title: "New Session on \(host.displayName)",
                    projects: sessionStore.projects(for: host.id),
                    isLoadingProjects: !sessionStore.hasReceivedState(for: host.id),
                    creatingSelection: creatingSelection,
                    onCreate: onCreate,
                    launchAgents: sessionStore.launchAgents(for: host.id),
                    pluginShortName: { sessionStore.presentation(forPluginID: $0)?.shortName ?? $0 }
                )
            }
        )
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            onHeaderFrameChange(frame)
        }
        .onDisappear {
            onHeaderFrameChange(nil)
        }
        .background(isHostDropTargeted ? Color.accentColor.opacity(0.15) : .clear)
        .clipShape(.rect(cornerRadius: 6))
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func remoteSessionButton(_ session: TmuxSession) -> some View {
        let claudePane = session.windows.flatMap(\.panes).first(where: { $0.agentSession != nil })
        let isSelected = selectedRemoteSession?.sessionName == session.sessionName
            && selectedRemoteSession?.hostId == host.id
        // See `sessionButton` — when the row gains a "Working" indicator the
        // merged button becomes `AXBusyIndicator` and swallows the bar's
        // separate accessibility element. Mirror the bar AX info on a sibling
        // outside the Button label so `valueContains` queries keep working.
        let sessionProgress = session.windows.flatMap(\.panes).effectiveProgress

        Button {
            #if os(macOS)
                if NSApp.currentEvent?.clickCount == 2 {
                    sessionRenameRequest = session.sessionName
                } else {
                    selectRemoteSession(session)
                }
            #else
                selectRemoteSession(session)
            #endif
        } label: {
            RemoteSessionSidebarRow(
                session: session,
                claudeSession: claudePane?.agentSession,
                homeDirectory: sessionStore.homeDirectoryByHost[host.id]
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(
            settings.highlightSelectedSidebarSession && isSelected
                ? settings.theme.selectedSidebarRowBackgroundColor
                : nil
        )
        .accessibilityChildren {
            SessionProgressAccessibilityProxy(progress: sessionProgress)
        }
        .modifier(DescriptionEditingModifier(
            sessionName: session.sessionName,
            currentDescription: session.customDescription,
            currentEmoji: session.customEmoji,
            isDisabled: connection?.isHostConnected != true,
            renameRequest: Binding(
                get: { sessionRenameRequest == session.sessionName },
                set: { requested in
                    if !requested, sessionRenameRequest == session.sessionName {
                        sessionRenameRequest = nil
                    }
                }
            ),
            onRename: onRename,
            onSetDescription: onSetDescription,
            onSetEmoji: onSetEmoji,
            additionalMenu: {
                ColorContextMenuButtons(
                    currentColor: session.customColor,
                    isDisabled: connection?.isHostConnected != true
                ) { newColor in
                    onSetColor(session.sessionName, newColor)
                }

                StateContextMenuButtons(
                    currentState: session.displayedState,
                    hasOverride: session.cliSessionState != nil,
                    isDisabled: connection?.isHostConnected != true
                ) { newState in
                    onSetState(session.sessionName, newState)
                }

                Divider()

                if let claudePane {
                    Toggle(isOn: Binding(
                        get: { sessionStore.isYoloModeEnabled(paneId: claudePane.paneId, hostId: host.id) },
                        set: { onToggleYolo(claudePane.paneId, $0) }
                    )) {
                        Label("Yolo Mode", symbol: .bolt)
                    }
                    .disabled(connection?.isHostConnected != true)

                    Divider()
                }

                Button(role: .destructive) {
                    onCloseSession(session.sessionName)
                } label: {
                    Label("Close Session", symbol: .rectangleStackBadgeMinus)
                }
                .disabled(connection?.isHostConnected != true)

                Divider()
            }
        ))
    }

    private func selectRemoteSession(_ session: TmuxSession) {
        onSelect(RemoteSessionSelection(
            hostId: host.id,
            hostName: host.displayName,
            sessionName: session.sessionName
        ))
    }

    private func moveSessions(fromOffsets source: IndexSet, toOffset destination: Int) {
        settings.setRemoteSessionOrder(
            RemoteSessionOrder.moving(
                sortedSessions.map(\.sessionName),
                fromOffsets: source,
                toOffset: destination
            ),
            for: host.id
        )
    }

    private func moveHost(by offset: Int) {
        guard
            let sourceIndex = settings.pairedHosts.firstIndex(where: { $0.id == host.id }),
            settings.pairedHosts.indices.contains(sourceIndex + offset)
        else {
            return
        }
        settings.moveHostPairing(
            sourceID: host.id,
            targetID: settings.pairedHosts[sourceIndex + offset].id
        )
    }

    private var hostStatusColor: Color {
        guard let connection else { return .gray }
        if connection.hostSubscriptionInactive { return .orange }
        if connection.versionMismatch != nil { return .orange }
        if connection.isHostConnected { return .green }
        if connection.isRelayConnected { return .yellow }
        return .red
    }
}

enum RemoteHostDropTarget {
    static func hostID(
        at location: CGPoint,
        orderedHostIDs: [String],
        headerFrames: [String: CGRect],
        excluding sourceID: String
    ) -> String? {
        guard headerFrames[sourceID]?.contains(location) != true else { return nil }

        var closest: (hostID: String, distance: CGFloat)?
        for hostID in orderedHostIDs where hostID != sourceID {
            guard let frame = headerFrames[hostID] else { continue }
            let horizontalTarget = frame.insetBy(dx: -8, dy: 0)
            guard horizontalTarget.minX ... horizontalTarget.maxX ~= location.x else { continue }

            let distance = max(max(frame.minY - location.y, location.y - frame.maxY), 0)
            guard distance <= max(frame.height, 28) else { continue }
            if let current = closest {
                if distance < current.distance {
                    closest = (hostID, distance)
                }
            } else {
                closest = (hostID, distance)
            }
        }
        return closest?.hostID
    }
}
