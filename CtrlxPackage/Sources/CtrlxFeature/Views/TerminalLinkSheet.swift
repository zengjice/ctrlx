#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import SwiftUI

    struct TerminalLinkSheet: View {
        let url: URL
        let isHostConnected: Bool
        let openHostURL: (@MainActor (URL) -> Void)?

        @Environment(\.dismiss) private var dismiss
        @Dependency(URLOpener.self) private var urlOpener
        @Dependency(ClipboardClient.self) private var clipboard

        var body: some View {
            NavigationStack {
                List {
                    Section {
                        Text(url.absoluteString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("terminal-link-url")
                    }
                    Section {
                        if BrowserWebURL.isSupported(url), let openHostURL {
                            Button {
                                dismiss()
                                openHostURL(url)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Open on Host")
                                        Text("View the Host's browser in CtrlX")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Symbols.macwindow.image
                                }
                            }
                            .disabled(!isHostConnected)
                            .accessibilityIdentifier("terminal-link-open-host")
                        }
                        Button {
                            dismiss()
                            urlOpener.openInDefaultBrowser(url)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Open on This Device")
                                    Text("Use this device's default browser")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Symbols.globe.image
                            }
                        }
                        .accessibilityIdentifier("terminal-link-open-device")
                        Button {
                            clipboard.setString(url.absoluteString)
                            dismiss()
                        } label: {
                            Label("Copy Link", symbol: .docOnClipboard)
                        }
                        .accessibilityIdentifier("terminal-link-copy")
                    }
                }
                .navigationTitle("Open Link")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCompactAdaptation(.sheet)
        }
    }
#endif
