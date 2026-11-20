#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    struct IOSPendingAttentionView: View {
        let open: (IOSPendingAttention) -> Void
        @Environment(IOSSettings.self) private var settings
        @Environment(SessionStore.self) private var sessionStore
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            let items = IOSPendingAttention.items(
                hosts: settings.pairedHosts, paneStates: sessionStore.paneStates, catalogs: sessionStore.workspaceCatalogsByHost
            )
            NavigationStack {
                Group {
                    if items.isEmpty {
                        ContentUnavailableView {
                            Label("Nothing needs attention", symbol: .bellFill)
                        }
                    } else {
                        List {
                            section("Waiting for You", items: items.filter { $0.status != .completed })
                            section("Completed", items: items.filter { $0.status == .completed })
                        }
                    }
                }
                .navigationTitle("Needs Attention")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }

        @ViewBuilder
        private func section(_ title: String, items: [IOSPendingAttention]) -> some View {
            if !items.isEmpty {
                Section(title) {
                    ForEach(items) { item in
                        Button {
                            open(item)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.tabName)
                                        .font(.headline)
                                    Text(item.sessionName.isEmpty ? item.hostName : "\(item.hostName) · \(item.sessionName)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if item.agentID == nil {
                                        Text("Tab location unavailable")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else if item.status != .completed {
                                        Text(item.status.rawValue)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if item.agentID != nil {
                                    Symbols.chevronRight.image
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(item.agentID == nil)
                    }
                }
            }
        }
    }
#endif
