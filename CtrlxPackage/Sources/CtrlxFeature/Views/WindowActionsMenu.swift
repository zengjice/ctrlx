#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    /// A scrollable list for the terminal actions, with native menus for short choices.
    struct WindowActionsMenu: View, Equatable {
        let state: WindowTabMenuState
        let windowActions: WindowTabActions
        let trustHooks: @MainActor () -> Void
        let openWorkflow: @MainActor () -> Void
        let copyText: @MainActor () -> Void
        let setMouseReporting: @MainActor (Bool) -> Void
        let setYoloMode: @MainActor (Bool) -> Void
        let showSessionInfo: @MainActor () -> Void
        let choose: @MainActor (@escaping @MainActor () -> Void) -> Void
        @Environment(\.dismiss) private var dismiss

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.state == rhs.state
        }

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Text("Tab Actions").font(.headline)
                    Spacer()
                    Button("Done") { dismiss() }
                }
                .padding()

                List {
                    if state.showsHookTrust || state.panes.contains(where: { $0.pluginID != nil }) {
                        Section {
                            if state.showsHookTrust {
                                Button { choose(trustHooks) } label: {
                                    Label(AgentHookTrustMenu.title, symbol: .shield)
                                }
                                .disabled(!state.canTrustHooks)
                                .accessibilityHint(AgentHookTrustMenu.explanation)
                                .accessibilityIdentifier("trust-all-pending-hooks")
                            }
                            windowActions.agentSessionActions
                        }
                    }
                    if state.showsWorkflow {
                        Section {
                            Button { choose(openWorkflow) } label: {
                                Label("View Workflow", symbol: .flowchart)
                            }.disabled(!state.isConnected)
                        }
                    }
                    Section {
                        Button { choose(copyText) } label: {
                            Label("Copy Terminal Text", symbol: .docOnClipboard)
                        }.disabled(!state.canCopy)

                        if state.focusedPaneID != nil {
                            touchModeMenu
                        }
                    }
                    if state.hasActiveSession {
                        Section {
                            Button {
                                let enabled = !state.isYoloModeEnabled
                                choose { setYoloMode(enabled) }
                            } label: {
                                Label(state.isYoloModeEnabled ? "Disable Yolo Mode" : "Enable Yolo Mode", symbol: .bolt)
                            }
                            Button { choose(showSessionInfo) } label: {
                                Label("Session Info", symbol: .infoCircle)
                            }
                        }
                    }
                    Section { windowActions }
                }
                .listStyle(.insetGrouped)
                .scrollBounceBehavior(.basedOnSize)
            }
            .accessibilityIdentifier("window-actions-panel")
        }

        private var touchModeMenu: some View {
            Menu {
                Picker("Touch Mode", selection: Binding(get: { state.sendsMouseEvents }, set: { enabled in
                    choose { setMouseReporting(enabled) }
                })) {
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
    }
#endif
