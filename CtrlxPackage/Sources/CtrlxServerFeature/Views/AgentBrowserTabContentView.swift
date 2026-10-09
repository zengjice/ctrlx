import AppKit
import CtrlxCommon
import SwiftUI

/// Same workbench/split host as New Browser, with a Chromium native child.
/// The model owns the view; representables only attach/detach it.
@MainActor
struct AgentBrowserTabContentView: View {
    let state: AgentBrowserTabState
    @State private var address = ""
    @FocusState private var editingAddress: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { state.service.back(state) } label: { Label("Back", symbol: .chevronLeft) }
                    .disabled(state.isRemotelyControlled)
                Button { state.service.forward(state) } label: { Label("Forward", symbol: .chevronRight) }
                    .disabled(state.isRemotelyControlled)
                Button { state.service.reload(state) } label: { Label("Reload", symbol: .arrowClockwise) }
                    .disabled(state.isRemotelyControlled)
                TextField("https://…", text: $address)
                    .focused($editingAddress)
                    .onSubmit(navigate)
                    .accessibilityIdentifier("agent-browser-address")
                    .disabled(state.isRemotelyControlled)
                if state.isRemotelyControlled {
                    Button("Take Back Control") { state.service.releaseBrowserControl(state.id) }
                        .help("This page is controlled by a Viewer")
                } else {
                    Text(state.manualTarget == nil ? "Codex · \(state.owner.prefix(6))" : "Chromium")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(state.manualTarget == nil
                          ? "Shared Agent Browser logins; only this Codex instance controls this tab"
                          : "Shared CtrlX Chromium logins; this tab is not controlled by an agent")
                }
                if state.isLoading { ProgressView().controlSize(.small) }
                Button {
                    state.service.showDevTools(state)
                } label: { Label("Developer Tools", symbol: .wrenchAndScrewdriver) }
                .help("Open Developer Tools for this Chromium tab")
                .accessibilityIdentifier("agent-browser-developer-tools")
                .disabled(state.isClosed || state.isRemotelyControlled)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(8)
            Divider()
            EmbeddedAgentBrowserView(state: state)
                .overlay {
                    if state.isRemotelyControlled {
                        Color.black.opacity(0.05)
                            .contentShape(Rectangle())
                            .onTapGesture {}
                    }
                }
        }
        .onChange(of: state.url, initial: true) { _, url in
            if !editingAddress { address = url == "about:blank" ? "" : url }
        }
        .task {
            if state.requestsInitialAddressFocus {
                state.requestsInitialAddressFocus = false
                editingAddress = true
            }
        }
        .accessibilityIdentifier("agent-browser-tab-content")
    }

    private func navigate() {
        guard let url = BrowserTabState.normalizedURL(from: address) else { return }
        address = url.absoluteString
        state.service.navigate(state, url: address)
        editingAddress = false
    }
}

private struct EmbeddedAgentBrowserView: NSViewRepresentable {
    let state: AgentBrowserTabState
    private var view: NSView { state.view }
    func makeCoordinator() -> AgentBrowserTabState { state }

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        attach(to: host)
        return host
    }
    func updateNSView(_ host: NSView, context: Context) { attach(to: host) }
    private func attach(to host: NSView) {
        guard view.superview !== host else { return }
        view.removeFromSuperview()
        view.isHidden = false
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
    }
    static func dismantleNSView(_ host: NSView, coordinator: AgentBrowserTabState) {
        // Detach only: switching tabs must not close Chromium or reload the page.
        if coordinator.view.superview === host { coordinator.service.park(coordinator) }
    }
}

struct AgentBrowserWorkspaceAnchor: NSViewRepresentable {
    let workspace: AgentBrowserWorkspace
    func makeNSView(context: Context) -> Anchor { Anchor(workspace: workspace) }
    func updateNSView(_ view: Anchor, context: Context) {}
    final class Anchor: NSView {
        let workspace: AgentBrowserWorkspace
        init(workspace: AgentBrowserWorkspace) { self.workspace = workspace; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            workspace.window = window
        }
    }
}
