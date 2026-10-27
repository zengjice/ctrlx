#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI

    struct SimulatorTabContentView: View {
        @Bindable var state: SimulatorTabState
        let workspaceID: UUID
        @Environment(\.browserAnnotationContext) private var annotationContext
        @State private var captureRequest: UUID?
        @State private var isAnnotating = false

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Label(state.handle.name, symbol: .iphone)
                        .lineLimit(1)
                    Spacer()
                    Text(state.writer == nil ? "Human control" : "Agent control")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Picker("Display mode", selection: $state.displayMode) {
                        Text("Synchronized").tag(SimulatorDisplayMode.synchronized)
                        Text("Low latency").tag(SimulatorDisplayMode.lowLatency)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .help("Low latency may show brief screen tearing. New devices default to synchronized display.")
                    Button {
                        state.service.manualHome(state)
                    } label: {
                        Symbols.house.image
                    }
                    .help("Home — take manual control")
                    Button { captureRequest = UUID() } label: {
                        Label("Annotate Screenshot", symbol: .pencilLine).labelStyle(.iconOnly)
                    }
                    .disabled(!state.hasPresentedFrame || state.isClosed || annotationContext?.isAvailable != true)
                    .help("Mark a screenshot and add it to an Agent input")
                    .accessibilityIdentifier("simulator-annotate")
                }
                .disabled(isAnnotating)
                .padding(8)
                Divider()
                if let error = state.error {
                    Text(error).font(.caption).foregroundStyle(.red).padding(6)
                }
                BrowserAnnotationSurface(
                    preferredTarget: preferredTarget,
                    requiresRecipientSelection: preferredTarget == nil,
                    capture: { try await state.service.annotationScreenshot(state) },
                    onEditingChanged: { editing in
                        isAnnotating = editing
                        state.view.setInputSuppressed(editing)
                    },
                    captureRequest: captureRequest,
                    identifierPrefix: "simulator"
                ) {
                    EmbeddedSimulatorView(state: state, workspaceID: workspaceID)
                        .id(state.workspaceID)
                }
            }
            .onDisappear { state.view.setInputSuppressed(false) }
            .accessibilityIdentifier("agent-simulator-tab-content")
        }

        private var preferredTarget: AgentImageTarget? {
            annotationContext?.targets.first { $0.paneID == state.paneID }
        }
    }

    private struct EmbeddedSimulatorView: NSViewRepresentable {
        let state: SimulatorTabState
        let workspaceID: UUID
        private var view: SimulatorMetalView {
            state.view
        }

        func makeNSView(context: Context) -> NSView {
            let host = NSView()
            attach(to: host)
            return host
        }

        func updateNSView(_ host: NSView, context: Context) {
            guard view.superview == nil else { return }
            attach(to: host)
        }

        private func attach(to host: NSView) {
            // Do not let a retiring window mount the renderer again.
            guard state.workspaceID == workspaceID, view.superview !== host else { return }
            view.removeFromSuperview()
            view.frame = host.bounds
            view.autoresizingMask = [.width, .height]
            host.addSubview(view)
        }
        static func dismantleNSView(_ host: NSView, coordinator: ()) {
            for view in host.subviews { view.removeFromSuperview() }
        }
    }

    struct SimulatorWorkspaceAnchor: NSViewRepresentable {
        let workspace: SimulatorWorkspace
        func makeNSView(context: Context) -> Anchor { Anchor(workspace: workspace) }
        func updateNSView(_ view: Anchor, context: Context) {}
        final class Anchor: NSView {
            let workspace: SimulatorWorkspace
            init(workspace: SimulatorWorkspace) {
                self.workspace = workspace
                super.init(frame: .zero)
            }
            required init?(coder: NSCoder) { nil }
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                workspace.window = window
            }
        }
    }
#endif
