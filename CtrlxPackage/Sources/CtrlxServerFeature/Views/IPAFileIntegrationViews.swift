#if os(macOS)
    import AppKit
    import CtrlxCommon
    import Dependencies
    import SwiftUI

    public extension View {
        func handleIPAFileRequests(_ integration: IPAFileIntegration) -> some View {
            modifier(IPAFileRequestHandler(integration: integration))
        }

        func suggestDefaultIPAApplication(_ integration: IPAFileIntegration, isReady: Bool) -> some View {
            modifier(IPADefaultApplicationSuggestion(integration: integration, isReady: isReady))
        }
    }

    private struct IPAFileRequestHandler: ViewModifier {
        let integration: IPAFileIntegration
        @Environment(\.openWindow) private var openWindow

        func body(content: Content) -> some View {
            content.onChange(of: integration.pendingFiles, initial: true) { _, files in
                guard !files.isEmpty else { return }
                NSApp.setActivationPolicy(.regular)
                for file in integration.takeFiles() {
                    openWindow(id: IPAInstallerScene.fileWindowID, value: file)
                }
                NSApp.activate()
            }
        }
    }

    private struct IPADefaultApplicationSuggestion: ViewModifier {
        @Bindable var integration: IPAFileIntegration
        let isReady: Bool
        @Environment(AppSettings.self) private var settings

        func body(content: Content) -> some View {
            content
                .task(id: isReady) {
                    guard isReady else { return }
                    integration.checkDefaultApplication(remind: settings.askToHandleIPAFiles)
                }
                .sheet(item: $integration.defaultApplicationPrompt) { current in
                    IPADefaultApplicationPrompt(current: current)
                        .environment(settings)
                }
        }
    }

    private struct IPADefaultApplicationPrompt: View {
        let current: IPAFileAssociation
        @Environment(AppSettings.self) private var settings
        @Environment(\.dismiss) private var dismiss
        @Dependency(IPAFileAssociationClient.self) private var association
        @State private var isSettingDefault = false
        @State private var error: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text("Open IPA Files with CtrlX?").font(.title2.bold())
                Text("Current default: \(current.applicationName)")
                Text("Open IPA files in CtrlX to install them on an iPhone connected to this Mac. You choose the device and confirm before installation.")
                    .foregroundStyle(.secondary)
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Button("Don't Ask Again") {
                        settings.askToHandleIPAFiles = false
                        dismiss()
                    }
                    Spacer()
                    Button("Not Now") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Set as Default") { isSettingDefault = true }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("ipa-set-default-prompt")
                }
                .disabled(isSettingDefault)
                if isSettingDefault {
                    ProgressView("Waiting for macOS…")
                }
            }
            .padding(24)
            .frame(width: 480)
            .fixedSize(horizontal: false, vertical: true)
            .interactiveDismissDisabled(isSettingDefault)
            .task(id: isSettingDefault) {
                guard isSettingDefault else { return }
                error = nil
                defer { isSettingDefault = false }
                do {
                    _ = try await association.setDefaultAndVerify()
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    struct IPAFileAssociationSettingsSection: View {
        @Environment(AppSettings.self) private var settings
        @Environment(\.scenePhase) private var scenePhase
        @Dependency(IPAFileAssociationClient.self) private var association
        @State private var current: IPAFileAssociation?
        @State private var isSettingDefault = false
        @State private var error: String?

        var body: some View {
            @Bindable var settings = settings
            Section("IPA Files") {
                LabeledContent("Default application", value: current?.applicationName ?? "Checking…")
                Button("Set CtrlX as Default…") { isSettingDefault = true }
                    .disabled(current?.isCtrlX == true || isSettingDefault)
                    .accessibilityIdentifier("ipa-set-default-settings")
                Toggle("Ask at startup when CtrlX is not the default", isOn: $settings.askToHandleIPAFiles)
                if isSettingDefault {
                    ProgressView("Waiting for macOS…")
                }
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .task(id: scenePhase) {
                error = nil
                do { current = try association.current() }
                catch { self.error = error.localizedDescription }
            }
            .task(id: isSettingDefault) {
                guard isSettingDefault else { return }
                error = nil
                defer { isSettingDefault = false }
                do { current = try await association.setDefaultAndVerify() }
                catch { self.error = error.localizedDescription }
            }
        }
    }
#endif
