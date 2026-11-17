import AppKit
import CtrlxCommon
import CtrlxNetworking
import SwiftUI

@MainActor
public struct MacOrbiePanelView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @State private var selectedID: String?
    @State private var query = ""
    @State private var notice: String?
    @State private var showsSwitcher = false
    @State private var showsActions = false
    @State private var stopMessage: AgentMessage?
    @State private var orbitersSheet: OrbitersSheet?
    @State private var sending = false
    @State private var retryingStartup = false
    @State private var conversationPosition = ScrollPosition(edge: .bottom)
    @State private var conversationHeight: CGFloat = 180
    @State private var composerHeight: CGFloat = 100

    public init() { }

    private var record: OrbiterRecord? {
        coordinator.orbiters?.agents.first { $0.id == selectedID }
    }

    private var title: String {
        selectedID == nil ? "Orbie" : record?.title ?? "Unavailable Agent"
    }

    private var instance: AgentWorkflowInstance? {
        if selectedID == nil {
            return coordinator.orbie?.instance
        }
        return record.flatMap { coordinator.orbiters?.currentInstance($0) }
    }

    private var messages: [AgentMessage] {
        if selectedID == nil {
            return Array((coordinator.orbie?.messages ?? []).suffix(3))
        }
        guard let record else { return [] }
        let ids = Set(record.messageIDs.suffix(3))
        return (coordinator.orbiters?.messages ?? []).filter { ids.contains($0.id) }
    }

    private var status: OrbiePanelStatus {
        if let startupIssue {
            return .startupFailed(startupIssue)
        }
        if coordinator.orbie?.record?.enabled == false {
            return .disabled
        }
        if selectedID == nil {
            return coordinator.orbie?.panelStatus ?? .loading
        }
        guard let record, let service = coordinator.orbiters else { return .unavailable("Select another Agent, or open Orbiters to locate its saved conversation.") }
        return service.panelStatus(record)
    }

    private var operationBusy: Bool {
        sending || retryingStartup || (selectedID == nil ? coordinator.orbie?.isBusy ?? (startupIssue == nil) : coordinator.orbiters?.isBusy ?? (startupIssue == nil))
    }

    private var availability: String? {
        if selectedID == nil {
            return coordinator.orbie?.availability ?? (coordinator.orbie == nil ? "Loading…" : nil)
        }
        guard let record, let service = coordinator.orbiters else { return "Agent unavailable" }
        return service.availability(record)
    }

    private var draft: Binding<String> {
        let id = selectedID
        return Binding(get: {
            if let id {
                return coordinator.orbiters?.drafts[id] ?? ""
            }
            return coordinator.orbie?.draft ?? ""
        }, set: { value in
            if let id {
                coordinator.orbiters?.drafts[id] = value
            } else {
                coordinator.orbie?.draft = value
            }
        })
    }

    private var canSend: Bool {
        !operationBusy && availability == nil && !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canOpenTerminal: Bool {
        if selectedID == nil {
            return coordinator.orbie?.record?.creation?.pane != nil && coordinator.orbie?.tabClosed != true
        }
        guard let record, let id = record.agentID else { return false }
        return record.pane != nil && coordinator.orbiters?.closedAgents.contains(id) != true
    }

    private var canRestore: Bool {
        guard coordinator.orbie?.record?.enabled == true else { return false }
        if selectedID == nil {
            return coordinator.orbie?.canRestore == true
        }
        guard let record, let id = record.agentID else { return false }
        return instance == nil && coordinator.orbiters?.restoringAgents.contains(id) != true
    }

    private var tabClosed: Bool {
        if selectedID == nil {
            return coordinator.orbie?.tabClosed == true
        }
        return record?.agentID.map { coordinator.orbiters?.closedAgents.contains($0) == true } ?? false
    }

    private var pending: AgentMessage? {
        messages.last { $0.isPending && $0.agentID == instance?.agentID }
    }

    private var serviceIssue: String? {
        selectedID == nil ? coordinator.orbie?.issue : coordinator.orbiters?.issue
    }

    private var startupIssue: String? {
        guard selectedID == nil ? coordinator.orbie == nil : coordinator.orbiters == nil else { return nil }
        return coordinator.agentWorkflowStartupError
    }

    private var showsConversation: Bool {
        !messages.isEmpty || status != .ready || notice != nil || serviceIssue != nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showsConversation {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(messages) { messageRow($0) }
                        if status != .ready {
                            statusCard
                        }
                        if let issue = notice ?? serviceIssue {
                            DisclosureGroup("Details") { Text(issue).textSelection(.enabled).font(.caption) }
                                .foregroundStyle(.secondary)
                        }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { conversationHeight = $0 }
                }
                .scrollPosition($conversationPosition)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
                    // Layout growth must use the previous viewport; the new bottom
                    // may already be outside it. User scrolling alone never follows.
                    guard old.contentSize != new.contentSize || old.containerSize != new.containerSize else { return }
                    if old.visibleRect.maxY >= old.contentSize.height + old.contentInsets.bottom - 24 {
                        conversationPosition.scrollTo(edge: .bottom)
                    }
                }
                .accessibilityIdentifier("orbie-panel-conversation")
                .frame(maxHeight: .infinity)
                Divider()
            }
            composer.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { composerHeight = $0 }
            footer
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 220)
        .background(.background)
        .background(OrbiePanelWindowAttachment(controller: coordinator.orbiePanel, preferredHeight: max(240, (showsConversation ? min(conversationHeight, 340) : 0) + composerHeight + 94)))
        .onExitCommand { dismissOrCloseMenu() }
        .onChange(of: coordinator.orbiePanel.isVisible) { _, visible in
            if visible {
                conversationPosition.scrollTo(edge: .bottom)
            } else {
                showsSwitcher = false
                showsActions = false
                Task { await saveDrafts() }
            }
        }
        .onChange(of: showsSwitcher || showsActions) { _, presented in coordinator.orbiePanel.setPopoverPresented(presented) }
        .onChange(of: coordinator.orbiters?.historyAgentID) { old, new in
            if let id = selectedID, old == id, new != nil, coordinator.orbiters?.agents.contains(where: { $0.id == id }) == false {
                selectedID = new
            }
        }
        .task(id: coordinator.orbiePanel.isVisible) {
            guard coordinator.orbiePanel.isVisible else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .task(id: draft.wrappedValue) {
            do { try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
            } catch { return }
            await saveDrafts()
        }
        .sheet(item: $orbitersSheet) { request in
            if let service = coordinator.orbiters {
                MacOrbitersView(service: service, initialSelection: request.selection, requestedForkSource: request.forkSource)
            }
        }
        .confirmationDialog("Stop waiting for this reply?", isPresented: Binding(get: { stopMessage != nil }, set: {
            if !$0 {
                stopMessage = nil
            }
        })) {
            if let message = stopMessage {
                Button("Stop Waiting") {
                    let isOrbie = selectedID == nil
                    perform {
                        if isOrbie {
                            await coordinator.orbie?.endMessage(message)
                        } else {
                            try await coordinator.orbiters?.stopWaiting(message)
                        }
                    }
                    stopMessage = nil
                }
            }
        } message: { Text("This ends reply observation. It does not stop the Agent or retract input already sent. Sending again still requires an idle terminal.") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                coordinator.orbiePanel.setPopoverPresented(true)
                showsSwitcher.toggle()
            } label: {
                HStack(spacing: 8) {
                    Symbols.sparkles.image.foregroundStyle(Color.accentColor)
                    Text(title).font(.headline).lineLimit(1)
                    Symbols.chevronDown.image.font(.caption2).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain).help("Switch Orbie or Orbiter").accessibilityIdentifier("orbie-panel-switcher")
                .popover(isPresented: $showsSwitcher, arrowEdge: .bottom) { switcher }
            Text(status.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Button { openTerminal() } label: { Label("Open Agent Tab", symbol: .terminal) }
                .help(canOpenTerminal ? "Open Agent Tab" : "The terminal is unavailable. Use the recovery controls below.")
                .disabled(!canOpenTerminal).accessibilityIdentifier("orbie-panel-terminal")
            Button { openFull() } label: { Label("Full Conversation", symbol: .arrowUpLeftAndArrowDownRight) }
                .keyboardShortcut("j", modifiers: .command).help("Full Conversation (⌘J)")
            Button { coordinator.orbiePanel.dismiss(restoreFocus: true) } label: { Label("Close", symbol: .xmark) }
                .help("Close (Esc)").accessibilityIdentifier("orbie-panel-close")
        }.labelStyle(.iconOnly).buttonStyle(.borderless).padding(.horizontal, 18).frame(height: 54)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                OrbiePanelComposer(text: draft, focusID: coordinator.orbiePanel.isVisible && !showsSwitcher && !showsActions && orbitersSheet == nil ? selectedID ?? "orbie" : nil, send: send, dismiss: dismissOrCloseMenu)
                    .id(selectedID ?? "orbie")
                    .overlay(alignment: .topLeading) {
                        if draft.wrappedValue.isEmpty {
                            Text(availability == nil ? "Continue with \(title)…" : "Write a draft to send when ready…")
                                .foregroundStyle(.tertiary).padding(.top, 4).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                Button(action: send) { Label("Send", symbol: .arrowUpCircleFill).font(.title2) }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .disabled(!canSend).help("Send (Return)").accessibilityIdentifier("orbie-panel-send")
            }
            HStack {
                Text("This Mac")
                Spacer()
                Text(availability == nil ? "⇧ Return for a new line" : "Draft kept · Send manually when ready")
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal, 22).padding(.vertical, 16).fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack {
            Label("Continue this conversation", symbol: .sparkles).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                coordinator.orbiePanel.setPopoverPresented(true)
                showsActions.toggle()
            } label: { Text("Actions  ⌘K") }
                .buttonStyle(.borderless).keyboardShortcut("k", modifiers: .command)
                .accessibilityIdentifier("orbie-panel-actions")
                .popover(isPresented: $showsActions, arrowEdge: .top) { actions }
        }.padding(.horizontal, 18).frame(height: 38).background(.quaternary.opacity(0.35))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(status.title, symbol: status.needsAttention ? .exclamationmarkTriangle : .sparkles).font(.subheadline.weight(.medium))
            if let detail = status.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                if canRestore {
                    AgentRoleResumeButton(tabClosed: tabClosed) {
                        let id = selectedID
                        perform {
                            if let id {
                                try await coordinator.orbiters?.restoreOriginalConversation(id)
                            } else {
                                await coordinator.orbie?.restoreOriginalConversation()
                            }
                        }
                    }.disabled(operationBusy)
                } else if status == .setup || status == .disabled {
                    Button(status == .disabled ? "Enable Orbie" : "Set Up Orbie…") {
                        if status == .disabled {
                            Task { await coordinator.orbie?.setEnabled(true) }
                        } else {
                            openFull()
                        }
                    }.disabled(operationBusy).accessibilityIdentifier("orbie-panel-setup")
                } else if canOpenTerminal {
                    Button("Open Agent Tab") { openTerminal() }.accessibilityIdentifier("orbie-panel-open-agent")
                }
                if status.needsAttention {
                    Button(startupIssue == nil ? "Recheck" : "Retry Startup") { Task { await recheck() } }
                        .disabled(operationBusy).accessibilityIdentifier("orbie-panel-recheck")
                }
                if canRestore {
                    Button("More…") { openFull() }
                }
            }.controlSize(.small)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(status.needsAttention ? Color.orange.opacity(0.07) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func messageRow(_ message: AgentMessage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer(minLength: 32)
                Text(OrbieAgentCatalog.bounded(message.text, bytes: 4_000)).textSelection(.enabled)
                    .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            if let answer = message.answer {
                Label(title, symbol: .sparkles).font(.caption).foregroundStyle(.secondary)
                Text(OrbieAgentCatalog.displayAnswer(OrbieAgentCatalog.bounded(answer, bytes: 8_000))).textSelection(.enabled)
                HStack {
                    Button { NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer, forType: .string)
                    } label: { Label("Copy Reply", symbol: .docOnDoc) }
                    if let attachments = message.attachments, !attachments.isEmpty {
                        Button("Saved Attachments…") { NSWorkspace.shared.activateFileViewerSelecting(attachments.map { URL(fileURLWithPath: $0.path) }) }
                    }
                }.font(.caption).buttonStyle(.borderless).foregroundStyle(.secondary)
                ForEach(OrbieAgentCatalog.candidates(in: answer), id: \.self) { id in
                    if let agent = coordinator.orbiters?.agents.first(where: { $0.id == id }) {
                        Button(agent.title) { selectAgent(id) }
                    }
                }
                ForEach(OrbieAgentCatalog.workflowCandidates(in: answer), id: \.self) { id in
                    Button("Open Suggested Workflow") { perform { try await coordinator.openOrbieWorkflow(id, openWindow: openWindow) } }
                }
            } else if !message.isPending {
                Text(message.issue ?? "Reply observation ended. Check the Agent tab for work already in progress.").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var switcher: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Find Agent or project", text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier("orbie-panel-search")
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if query.isEmpty || "Orbie".localizedStandardContains(query) {
                        agentChoice(id: nil, title: "Orbie", subtitle: "Main Agent")
                    }
                    if let service = coordinator.orbiters {
                        let entries = OrbieAgentCatalog.search(OrbieAgentCatalog.summaries(agents: service.agents, messages: service.messages, instances: service.instances), query: query, limit: service.agents.count)
                        ForEach(entries) { entry in agentChoice(id: entry.id, title: entry.title, subtitle: entry.project) }
                        if entries.isEmpty {
                            Text("No matching Orbiters").font(.caption).foregroundStyle(.secondary).padding(8)
                        }
                    }
                }
            }.frame(maxHeight: 250)
            Divider()
            Button("New Orbiter…") { showOrbiters(selection: nil) }
            Button("Manage Orbiters…") { showOrbiters(selection: selectedID) }
        }.padding(12).frame(width: 320)
    }

    private func agentChoice(id: String?, title: String, subtitle: String) -> some View {
        Button { selectAgent(id) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Label(title, symbol: id == nil ? .sparkles : .arrowTriangleBranch).lineLimit(1)
                    Spacer()
                    if selectedID == id {
                        Symbols.checkmark.image
                    }
                }
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }.buttonStyle(.plain).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedID == id ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("orbie-panel-agent-\(id ?? "orbie")")
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Open Agent Tab", action: openTerminal).disabled(!canOpenTerminal)
            Button("Full Conversation…", action: openFull)
            Divider()
            Button("New Orbiter…") { showOrbiters(selection: nil) }
            Button("Fork Current Conversation…") { showOrbiters(selection: nil, forkSource: instance) }
                .disabled(operationBusy || availability != nil || instance == nil)
            Divider()
            Button("Recheck Status") { showsActions = false
                Task { await recheck() }
            }.disabled(operationBusy)
            if let pending {
                Button("Stop Waiting…") { showsActions = false
                    stopMessage = pending
                }.disabled(operationBusy)
            }
            if selectedID == nil, coordinator.orbie?.record?.pendingMessageID != nil {
                Button("Review Unconfirmed Submission…") { openFull() }
            }
        }.buttonStyle(.borderless).padding(16).frame(width: 250, alignment: .leading)
    }

    private func selectAgent(_ id: String?) {
        selectedID = id
        conversationPosition.scrollTo(edge: .bottom)
        coordinator.orbiters?.historyAgentID = id
        query = ""
        notice = nil
        showsSwitcher = false
    }

    private func send() {
        guard canSend else { return }
        let id = selectedID
        sending = true
        notice = nil
        Task {
            defer { sending = false }
            do {
                if let id {
                    try await coordinator.orbiters?.send(id)
                } else {
                    await coordinator.orbie?.send()
                }
            } catch { notice = error.localizedDescription }
        }
    }

    private func refresh() async {
        if selectedID == nil {
            await coordinator.orbie?.refresh()
            await coordinator.orbiters?.refresh(inspect: false)
        } else {
            await coordinator.orbiters?.refresh()
            await coordinator.orbie?.refresh(inspect: false)
        }
    }

    private func recheck() async {
        guard !retryingStartup else { return }
        if startupIssue != nil {
            retryingStartup = true
            await coordinator.retryOrbieStartup()
            retryingStartup = false
        }
        await refresh()
    }

    private func saveDrafts() async {
        await coordinator.orbie?.saveDraft()
        await coordinator.orbiters?.saveDrafts()
    }

    private func openTerminal() {
        let id = selectedID
        showsActions = false
        perform {
            if let id {
                try await coordinator.openOrbiter(id, openWindow: openWindow)
            } else {
                try await coordinator.openOrbieTerminal(openWindow: openWindow)
            }
        }
    }

    private func openFull() {
        showsActions = false
        if let selectedID {
            showOrbiters(selection: selectedID)
        } else {
            coordinator.orbiePanel.dismiss(restoreFocus: false)
            openWindow(id: "orbie")
        }
    }

    private func showOrbiters(selection: String?, forkSource: AgentWorkflowInstance? = nil) {
        showsSwitcher = false
        showsActions = false
        orbitersSheet = .init(selection: selection, forkSource: selectedID == nil ? nil : forkSource)
    }

    private func dismissOrCloseMenu() {
        if showsSwitcher || showsActions {
            showsSwitcher = false
            showsActions = false
        } else {
            coordinator.orbiePanel.dismiss(restoreFocus: true)
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        notice = nil
        Task { do { try await operation() } catch { notice = error.localizedDescription } }
    }
}

private struct OrbitersSheet: Identifiable {
    let id = UUID()
    let selection: String?
    var forkSource: AgentWorkflowInstance?
}
