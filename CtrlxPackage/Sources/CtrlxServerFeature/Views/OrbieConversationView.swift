import AppKit
import CtrlxCommon
import CtrlxNetworking
import SwiftUI

@MainActor
struct OrbieConversationView: View {
    let messages: [AgentMessage]
    let title: String
    var orbiterID: String?
    var onStop: (AgentMessage) -> Void
    var onHeight: (CGFloat) -> Void = { _ in }
    var onGiveToOrbie: ((AgentMessage) -> Void)?
    var onSelectOrbiter: ((String) -> Void)?
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @State private var issue: String?
    @State private var files: AgentMaterialFiles?
    @State private var artifact: TerminalArtifactPreview?
    @State private var request: FileRequest?
    @State private var requestAfterPreview: FileRequest?
    @State private var presentedMessages: [RichChatMessage] = []

    private struct PresentationInput: Equatable, Sendable {
        let messages: [AgentMessage]
        let agentTitles: [String: String]
        let offersGiveToOrbie: Bool
    }

    private var presentationInput: PresentationInput {
        .init(messages: messages, agentTitles: Dictionary(uniqueKeysWithValues: (coordinator.orbiters?.agents ?? []).map { ($0.id, $0.title) }), offersGiveToOrbie: onGiveToOrbie != nil)
    }

    private struct FileRequest: Equatable {
        let id = UUID()
        let messageID: UUID
        let path: String
        var prefersPreview = true
        var opensNewTab = false
    }

    var body: some View {
        VStack(spacing: 0) {
            RichChatConversation(messages: presentedMessages, title: title, onAction: action, onReference: { id, path in
                request = FileRequest(messageID: id, path: path)
            }, imageLoader: loadImage, htmlLoader: loadHTML, onHeight: onHeight)
            if let issue {
                Text(issue).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(8)
            }
        }
        .task(id: presentationInput) {
            let input = presentationInput
            let work = Task.detached(priority: .userInitiated) {
                input.messages.map { Self.presentation($0, agentTitles: input.agentTitles, offersGiveToOrbie: input.offersGiveToOrbie) }
            }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            presentedMessages = result
        }
        .task(id: request) {
            guard let request else { return }
            guard let message = messages.first(where: { $0.id == request.messageID }) else {
                issue = "The source reply is no longer in this view. Open the full conversation to use its file links."
                return
            }
            do {
                issue = nil
                let (context, source, pane) = try await source(for: message)
                let paneID = pane.paneId
                let destination = try await TerminalFileDestination.resolve(path: request.path, context: context, source: source)
                try Task.checkCancellation()
                if request.opensNewTab {
                    let link = TerminalFileLinkRequest(path: request.path, paneID: paneID, hostID: nil, prefersPreview: false, opensNewTab: true)
                    let owner = try coordinator.queueOrbieFileTab(link, context: context, pane: pane)
                    if !coordinator.detachedWindows.focusNativeWindow(workspaceID: owner) {
                        if let owner {
                            openWindow(id: "detached-terminal", value: owner)
                        } else {
                            openWindow(id: "panes")
                        }
                    }
                } else if let path = destination.file, request.prefersPreview, TerminalArtifactPreview.supports(path: path) {
                    artifact = .init(link: .init(path: request.path, paneID: paneID, hostID: nil), context: context, source: source, path: path)
                } else {
                    files = .init(directory: destination.directory, reveal: destination.file)
                }
            } catch is CancellationError { }
            catch { issue = error.localizedDescription }
        }
        .sheet(item: $files) { AgentMaterialFilesView(files: $0) }
        .sheet(item: $artifact, onDismiss: {
            if let next = requestAfterPreview {
                requestAfterPreview = nil
                request = next
            }
        }) { preview in
            TerminalArtifactPreviewSheet(preview: preview) { link in
                if let messageID = request?.messageID {
                    requestAfterPreview = FileRequest(messageID: messageID, path: link.path, prefersPreview: link.prefersPreview, opensNewTab: link.opensNewTab)
                }
                artifact = nil
            }
        }
    }

    private nonisolated static func presentation(_ message: AgentMessage, agentTitles: [String: String], offersGiveToOrbie: Bool) -> RichChatMessage {
        var actions: [RichChatMessage.Action] = []
        if message.answer != nil {
            actions.append(.init(id: "copy", title: "Copy Reply"))
            if offersGiveToOrbie {
                actions.append(.init(id: "give", title: "Give to Orbie…"))
            }
            for id in OrbieAgentCatalog.candidates(in: message.answer ?? "") {
                if let title = agentTitles[id] {
                    actions.append(.init(id: "orbiter:\(id)", title: title))
                }
            }
            for id in OrbieAgentCatalog.workflowCandidates(in: message.answer ?? "") {
                actions.append(.init(id: "workflow:\(id.uuidString)", title: "Open Suggested Workflow"))
            }
        }
        if message.attachments?.isEmpty == false {
            actions.append(.init(id: "attachments", title: "Saved Attachments…"))
        }
        if message.isPending {
            actions.append(.init(id: "stop", title: "Stop Waiting"))
        }
        return .init(id: message.id, text: message.text, answer: message.answer.map(OrbieAgentCatalog.displayAnswer), activity: (message.activity ?? []).map(\.text), pending: message.isPending, issue: message.issue, actions: actions)
    }

    private func action(_ id: UUID, _ action: String) {
        guard let message = messages.first(where: { $0.id == id }) else { return }
        switch action {
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.answer ?? "", forType: .string)
        case "give": onGiveToOrbie?(message)
        case "stop": onStop(message)
        case "attachments":
            NSWorkspace.shared.activateFileViewerSelecting((message.attachments ?? []).map { URL(fileURLWithPath: $0.path) })
        default:
            Task {
                do {
                    if action.hasPrefix("orbiter:") {
                        let id = String(action.dropFirst("orbiter:".count))
                        if let onSelectOrbiter {
                            onSelectOrbiter(id)
                        } else {
                            try await coordinator.openOrbiter(id, openWindow: openWindow)
                        }
                    } else if action.hasPrefix("workflow:"), let id = UUID(uuidString: String(action.dropFirst("workflow:".count))) {
                        try await coordinator.openOrbieWorkflow(id, openWindow: openWindow)
                    }
                } catch { issue = error.localizedDescription }
            }
        }
    }

    static func fileContext(saved: AgentWorkflowInstance, current: AgentWorkflowInstance, pane: PaneState) throws -> RepositoryFileContext {
        guard
            saved.hostID == current.hostID, saved.pluginID == current.pluginID,
            !saved.conversationID.isEmpty, saved.conversationID == current.conversationID,
            saved.workingDirectory == current.workingDirectory,
            current.workspacePane.isSamePane(as: pane.workspaceIdentity),
            let context = RepositoryFileContext(pane: pane), context.pluginID == current.pluginID,
            context.sessionID == current.conversationID, context.projectDirectory == current.workingDirectory else {
            throw AgentWorkflowError("The reply’s original Agent workspace is unavailable or changed. Restore its original conversation before opening this file.")
        }
        return context
    }

    private func source(for message: AgentMessage) async throws -> (RepositoryFileContext, FileBrowserSource, PaneState) {
        let current: AgentWorkflowInstance? = if let orbiterID, let record = coordinator.orbiters?.agents.first(where: { $0.id == orbiterID }) {
            coordinator.orbiters?.currentInstance(record)
        } else if orbiterID == nil {
            coordinator.orbie?.instance
        } else {
            nil
        }
        guard let current else {
            throw AgentWorkflowError("The source Agent tab is unavailable. Restore the original conversation before opening this file.")
        }
        if coordinator.windowManager.paneStates[current.paneID] == nil {
            coordinator.windowManager.updatePaneStates(from: await coordinator.tmuxService.refreshPanes())
        }
        guard let pane = coordinator.windowManager.paneStates[current.paneID] else {
            throw AgentWorkflowError("The source Agent tab is unavailable. Restore the original conversation before opening this file.")
        }
        let context = try Self.fileContext(saved: message.instance, current: current, pane: pane)
        return (context, .local(paneID: current.paneID, tmux: coordinator.tmuxService, windows: coordinator.windowManager, expectedWorkspacePane: current.workspacePane), pane)
    }

    private func loadImage(_ id: UUID, _ path: String) async throws -> Data {
        guard
            TerminalArtifactPreview.isImage(path: path) || (path as NSString).pathExtension.lowercased() == "svg" else {
            throw AgentWorkflowError("Only images inside this Agent’s workspace can be loaded.")
        }
        return try await loadArtifact(id, path: path)
    }

    private func loadHTML(_ id: UUID, _ path: String) async throws -> Data {
        guard ["html", "htm"].contains((path as NSString).pathExtension.lowercased()) else {
            throw AgentWorkflowError("Only HTML files inside this Agent’s workspace can be loaded.")
        }
        return try await loadArtifact(id, path: path)
    }

    private func loadArtifact(_ id: UUID, path: String) async throws -> Data {
        guard let message = messages.first(where: { $0.id == id }) else {
            throw AgentWorkflowError("The source reply is no longer in this view.")
        }
        let (context, source, pane) = try await source(for: message)
        let destination = try await TerminalFileDestination.resolve(path: path, context: context, source: source)
        guard let file = destination.file else { throw AgentWorkflowError("The preview link points to a folder.") }
        return try await TerminalArtifactPreview(link: .init(path: path, paneID: pane.paneId, hostID: nil), context: context, source: source, path: file).load()
    }
}
