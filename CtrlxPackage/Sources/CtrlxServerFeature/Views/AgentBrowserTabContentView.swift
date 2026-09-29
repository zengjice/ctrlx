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
                Button { state.service.forward(state) } label: { Label("Forward", symbol: .chevronRight) }
                Button { state.service.reload(state) } label: { Label("Reload", symbol: .arrowClockwise) }
                TextField("https://…", text: $address)
                    .focused($editingAddress)
                    .onSubmit(navigate)
                    .accessibilityIdentifier("agent-browser-address")
                Text(state.manualTarget == nil ? "Codex · \(state.owner.prefix(6))" : "Chromium")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(state.manualTarget == nil
                          ? "Shared Agent Browser logins; only this Codex instance controls this tab"
                          : "Shared CtrlX Chromium logins; this tab is not controlled by an agent")
                if state.isLoading { ProgressView().controlSize(.small) }
                Button {
                    state.service.showDevTools(state)
                } label: { Label("Developer Tools", symbol: .wrenchAndScrewdriver) }
                .help("Open Developer Tools for this Chromium tab")
                .accessibilityIdentifier("agent-browser-developer-tools")
                .disabled(state.isClosed)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(8)
            Divider()
            EmbeddedAgentBrowserView(view: state.view)
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
    let view: NSView

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
    static func dismantleNSView(_ host: NSView, coordinator: ()) {
        // Detach only: switching tabs must not close Chromium or reload the page.
        for view in host.subviews { view.removeFromSuperview() }
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
