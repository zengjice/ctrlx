import AppKit
import CtrlxCommon
import CtrlxNetworking
import SwiftUI

/// Same workbench/split host as New Browser, with a Chromium native child.
/// The model owns the view; representables only attach/detach it.
@MainActor
struct AgentBrowserTabContentView: View {
    let state: AgentBrowserTabState
    let workspaceID: UUID
    @Environment(\.resourceTabActions) private var resourceActions
    @Environment(\.browserAnnotationContext) private var annotationContext
    @State private var address = ""
    @State private var captureRequest: UUID?
    @State private var isAnnotating = false
    @State private var actionError: String?
    private struct ExtensionRequest: Identifiable {
        let id = UUID()
        let storeID: String?
    }

    @State private var extensionRequest: ExtensionRequest?
    @FocusState private var editingAddress: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let sessionID = state.resourceSessionID, let actions = resourceActions {
                    ResourceAgentMenu(kind: .browser, tabID: state.id, sessionID: sessionID, grant: state.grant, request: actions.request)
                }
                Button { state.service.back(state) } label: { Label("Back", symbol: .chevronLeft) }
                    .disabled(state.isRemotelyControlled)
                Button { state.service.forward(state) } label: { Label("Forward", symbol: .chevronRight) }
                    .disabled(state.isRemotelyControlled)
                Button { state.service.reload(state) } label: { Label("Reload", symbol: .arrowClockwise) }
                    .disabled(state.isRemotelyControlled)
                TextField("Search Google or enter address", text: $address)
                    .focused($editingAddress)
                    .onSubmit(navigate)
                    .accessibilityIdentifier("agent-browser-address")
                    .disabled(state.isRemotelyControlled)
                if state.isRemotelyControlled {
                    Button { state.service.releaseBrowserControl(state.id) } label: {
                        Label("Take Back Control", symbol: .eye)
                    }
                    .help("This page is controlled by a Viewer")
                    .accessibilityValue("Read Only")
                } else {
                    Text(state.manualTarget == nil ? "Codex · \(state.owner.prefix(6))" : "Chromium")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(state.manualTarget == nil
                            ? "Shared Agent Browser logins; only this Codex instance controls this tab"
                            : "Shared CtrlX Chromium logins; this tab is not controlled by an agent")
                }
                if state.isLoading {
                    ProgressView().controlSize(.small)
                }
                if state.manualTarget?.hostID == nil {
                    Menu {
                        Button("General Settings") { showBrowserSettings(.general) }
                        Button("Password Manager") { showBrowserSettings(.passwords) }
                    } label: {
                        Label("Browser Settings", symbol: .gearshape)
                    }
                    .help("Open Chromium settings or the Host password manager")
                    .accessibilityIdentifier("agent-browser-settings")
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(state.isClosed)
                    if let id = BrowserExtensionStoreURL.extensionID(from: state.url) {
                        Button("Install on Host") {
                            extensionRequest = ExtensionRequest(storeID: id)
                        }
                        .disabled(state.isClosed || state.isRemotelyControlled)
                        .accessibilityIdentifier("browser-install-store-extension")
                    }
                    if !state.isExtensionWindow {
                        Button(action: openExtensionWindow) {
                            Label("Open Page as Chrome Window", symbol: .arrowUpRightSquare)
                        }
                        .help("Open this page with Chrome's extension, password-save, and autofill UI")
                        .accessibilityIdentifier("agent-browser-extension-window")
                        .disabled(state.isClosed || state.isRemotelyControlled)
                    }
                    Button { extensionRequest = ExtensionRequest(storeID: nil) } label: {
                        Label("Manage Extensions", symbol: .puzzlepiece)
                    }
                    .help("Install, configure, enable, or remove extensions")
                    .accessibilityIdentifier("agent-browser-extensions")
                    .disabled(state.isClosed || state.isRemotelyControlled)
                }
                Button {
                    state.service.showDevTools(state)
                } label: { Label("Developer Tools", symbol: .wrenchAndScrewdriver) }
                    .help("Open Developer Tools for this Chromium tab")
                    .accessibilityIdentifier("agent-browser-developer-tools")
                    .disabled(state.isClosed || state.isRemotelyControlled)
                if !state.isExtensionWindow {
                    Button { captureRequest = UUID() } label: {
                        Label("Annotate Screenshot", symbol: .pencilLine)
                    }
                    .help("Mark a screenshot and add it to an Agent input")
                    .accessibilityIdentifier("agent-browser-annotate")
                    .disabled(state.isClosed || annotationContext?.isAvailable != true)
                }
            }
            .labelStyle(.iconOnly)
            .disabled(isAnnotating)
            .buttonStyle(.borderless)
            .padding(8)
            Divider()
            BrowserNetworkPermissionBanner(permission: state.networkPermission, canRespond: !state.isRemotelyControlled) { id, allow in
                try await state.service.respondToNetworkPermission(id, tab: state, allow: allow)
            }
            if state.isExtensionWindow {
                VStack(spacing: 12) {
                    Label("Extension Window", symbol: .puzzlepiece)
                        .font(.headline)
                    Text("This page is open in a separate CtrlX browser window.")
                        .foregroundStyle(.secondary)
                    Button("Show Window") { state.service.showBrowserWindow(state) }
                        .disabled(state.isClosed || state.isRemotelyControlled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BrowserAnnotationSurface(
                    preferredTarget: state.sourceAgent,
                    requiresRecipientSelection: state.sourceAgent == nil,
                    capture: { try await state.service.annotationScreenshot(state) },
                    onEditingChanged: { editing in
                        isAnnotating = editing
                        if editing {
                            state.view.window?.makeFirstResponder(nil)
                        }
                    },
                    captureRequest: captureRequest
                ) {
                    EmbeddedAgentBrowserView(state: state, workspaceID: workspaceID)
                        .id(state.workspaceID)
                        .overlay {
                            if state.isRemotelyControlled {
                                Color.black.opacity(0.05)
                                    .contentShape(Rectangle())
                                    .onTapGesture { }
                            }
                        }
                }
            }
        }
        .overlay(alignment: .bottom) {
            BrowserExternalApplicationBanner(notice: state.externalApplicationNotice)
        }
        .onChange(of: state.url, initial: true) { _, url in
            if !editingAddress {
                address = url == "about:blank" ? "" : url
            }
        }
        .task {
            if state.requestsInitialAddressFocus {
                state.requestsInitialAddressFocus = false
                editingAddress = true
            }
        }
        .accessibilityIdentifier("agent-browser-tab-content")
        .sheet(item: $extensionRequest) { request in BrowserExtensionsView(tab: state, initialStoreID: request.storeID) }
        .alert("Browser Error", isPresented: Binding(
            get: { actionError != nil }, set: {
                if !$0 {
                    actionError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private func openExtensionWindow() {
        Task {
            do { _ = try await state.service.openExtensionWindow(state) }
            catch { actionError = error.localizedDescription }
        }
    }

    private func showBrowserSettings(_ section: AgentBrowserSettingsSection) {
        Task {
            do { try await state.service.showBrowserSettings(section) }
            catch { actionError = error.localizedDescription }
        }
    }

    private func navigate() {
        guard let url = BrowserWebURL.navigationURL(from: address) else { return }
        address = url.absoluteString
        state.service.navigate(state, url: address)
        editingAddress = false
    }
}

private struct EmbeddedAgentBrowserView: NSViewRepresentable {
    let state: AgentBrowserTabState
    let workspaceID: UUID
    private var view: NSView {
        state.view
    }

    func makeCoordinator() -> AgentBrowserTabState {
        state
    }

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        attach(to: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        guard view.superview == nil || view.window is AgentBrowserParkingWindow else { return }
        attach(to: host)
    }

    private func attach(to host: NSView) {
        // A retiring window can still create its old surface after the tab has moved.
        guard state.workspaceID == workspaceID, view.superview !== host else { return }
        view.removeFromSuperview()
        view.isHidden = false
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
    }

    static func dismantleNSView(_ host: NSView, coordinator: AgentBrowserTabState) {
        // Detach only: switching tabs must not close Chromium or reload the page.
        if coordinator.view.superview === host {
            coordinator.service.park(coordinator)
        }
    }
}

struct AgentBrowserWorkspaceAnchor: NSViewRepresentable {
    let workspace: AgentBrowserWorkspace
    func makeNSView(context: Context) -> Anchor {
        Anchor(workspace: workspace)
    }

    func updateNSView(_ view: Anchor, context: Context) { }
    final class Anchor: NSView {
        let workspace: AgentBrowserWorkspace
        init(workspace: AgentBrowserWorkspace) {
            self.workspace = workspace
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            workspace.window = window
        }
    }
}
