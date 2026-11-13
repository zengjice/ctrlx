#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    /// Keep the native menu intact across unrelated updates of the terminal page.
    struct WindowActionsMenu: View, Equatable {
        let state: WindowTabMenuState
        let windowActions: WindowTabActions
        let trustHooks: () -> Void
        let openWorkflow: () -> Void
        let copyText: () -> Void
        let setMouseReporting: (Bool) -> Void
        let toggleYolo: () -> Void
        let showSessionInfo: () -> Void

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.state == rhs.state
        }

        var body: some View {
            Menu {
                if state.showsHookTrust {
                    Button(action: trustHooks) {
                        Label(AgentHookTrustMenu.title, symbol: .shield)
                    }
                    .disabled(!state.canTrustHooks)
                    .accessibilityHint(AgentHookTrustMenu.explanation)
                    .accessibilityIdentifier("trust-all-pending-hooks")
                }
                windowActions.agentSessionActions
                if state.showsHookTrust || state.panes.contains(where: { $0.pluginID != nil }) {
                    Divider()
                }
                if state.showsWorkflow {
                    Button(action: openWorkflow) {
                        Label("View Workflow", symbol: .flowchart)
                    }.disabled(!state.isConnected)
                    Divider()
                }
                Button(action: copyText) {
                    Label("Copy Terminal Text", symbol: .docOnClipboard)
                }.disabled(!state.canCopy)

                if state.focusedPaneID != nil {
                    Menu {
                        Picker("Touch Mode", selection: Binding(get: { state.sendsMouseEvents }, set: setMouseReporting)) {
                            Text("Select Text").tag(false)
                            Text("Send Mouse Events").tag(true)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Touch Mode", symbol: .handDraw)
                    }
                    .accessibilityHint("Controls whether double and triple taps select text or send mouse events.")
                    .accessibilityIdentifier("terminal-touch-mode")
                }

                if state.hasActiveSession {
                    Divider()
                    Button(action: toggleYolo) {
                        Label(state.isYoloModeEnabled ? "Disable Yolo Mode" : "Enable Yolo Mode", symbol: .bolt)
                    }
                    Button(action: showSessionInfo) {
                        Label("Session Info", symbol: .infoCircle)
                    }.tint(nil)
                }
                Divider()
                windowActions
            } label: {
                Label("More", symbol: .ellipsisCircle)
            }
            .menuOrder(.fixed)
            .accessibilityIdentifier("window-actions-\(state.windowID ?? "independent")")
            .tint(state.isYoloModeEnabled ? .red : nil)
        }
    }
#endif
