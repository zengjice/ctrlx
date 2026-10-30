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

    public struct IPADefaultApplicationPromptScene: Scene {
        static let windowID = "ipa-default-application"
        private let settings: AppSettings

        public init(settings: AppSettings) {
            self.settings = settings
        }

        public var body: some Scene {
            WindowGroup("IPA Files", id: Self.windowID, for: String.self) { applicationName in
                if let applicationName = applicationName.wrappedValue {
                    IPADefaultApplicationPrompt(currentApplicationName: applicationName)
                        .environment(settings)
                }
            }
            .windowResizability(.contentSize)
            .defaultPosition(.center)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
            .commandsRemoved()
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
        let integration: IPAFileIntegration
        let isReady: Bool
        @Environment(AppSettings.self) private var settings
        @Environment(\.openWindow) private var openWindow

        func body(content: Content) -> some View {
            content
                .task(id: isReady) {
                    guard isReady else { return }
                    integration.checkDefaultApplication(remind: settings.askToHandleIPAFiles)
                    presentIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    presentIfNeeded()
                }
        }

        private func presentIfNeeded() {
            guard isReady, let current = integration.takeDefaultApplicationPrompt(isActive: NSApp.isActive) else { return }
            openWindow(id: IPADefaultApplicationPromptScene.windowID, value: current.applicationName)
        }
    }

    private enum IPAFileAssociationFeedback: Equatable {
        case success
        case cancelled
        case failure(String)

        var message: String {
            switch self {
            case .success: "CtrlX is now the default application for IPA files."
            case .cancelled: "Setting the default application was cancelled."
            case let .failure(message): message
            }
        }

        var color: Color {
            if case .failure = self {
                .red
            } else {
                .secondary
            }
        }
    }

    struct IPADefaultApplicationPrompt: View {
        let currentApplicationName: String
        @Environment(AppSettings.self) private var settings
        @Environment(\.dismiss) private var dismiss
        @Dependency(IPAFileAssociationClient.self) private var association
        @State private var isSettingDefault = false
        @State private var feedback: IPAFileAssociationFeedback?

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text(feedback == .success ? "Default Application Updated" : "Open IPA Files with CtrlX?")
                    .font(.title2.bold())
                if feedback != .success {
                    Text("Current default: \(currentApplicationName)")
                    Text("Open IPA files in CtrlX to install them on an iPhone connected to this Mac. You choose the device and confirm before installation.")
                        .foregroundStyle(.secondary)
                    Text("macOS may ask you to confirm this change.")
                        .foregroundStyle(.secondary)
                }
                if let feedback {
                    Text(feedback.message).foregroundStyle(feedback.color).textSelection(.enabled)
                        .accessibilityIdentifier("ipa-default-feedback")
                }
                if isSettingDefault {
                    ProgressView("Waiting for macOS…")
                    Text("You can close this prompt and check the result later in Settings → General → IPA Files.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    if feedback != .success {
                        Button("Don't Ask Again") {
                            settings.askToHandleIPAFiles = false
                            dismiss()
                        }
                        .disabled(isSettingDefault)
                    }
                    Spacer()
                    if feedback == .success {
                        Button("Done") { dismiss() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(isSettingDefault ? "Close" : "Not Now") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("ipa-close-default-prompt")
                        Button("Set as Default") { isSettingDefault = true }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(isSettingDefault)
                            .accessibilityIdentifier("ipa-set-default-prompt")
                    }
                }
            }
            .padding(24)
            .frame(width: 480)
            .fixedSize(horizontal: false, vertical: true)
            .task(id: isSettingDefault) {
                guard isSettingDefault else { return }
                feedback = nil
                defer { isSettingDefault = false }
                do {
                    _ = try await association.setDefaultAndVerify()
                    feedback = .success
                } catch {
                    guard !Task.isCancelled else { return }
                    feedback = error is CancellationError ? .cancelled : .failure(error.localizedDescription)
                }
            }
        }
    }

    struct IPAFileAssociationSettingsSection: View {
        @Environment(AppSettings.self) private var settings
        @Environment(\.scenePhase) private var scenePhase
        @Dependency(IPAFileAssociationClient.self) private var association
        @State private var current: IPAFileAssociation?
        @State private var isSettingDefault = false
        @State private var feedback: IPAFileAssociationFeedback?

        var body: some View {
            @Bindable var settings = settings
            Section("IPA Files") {
                LabeledContent("Default application", value: current?.applicationName ?? "Checking…")
                Button("Set CtrlX as Default…") { isSettingDefault = true }
                    .disabled(current?.isCtrlX == true || isSettingDefault)
                    .accessibilityIdentifier("ipa-set-default-settings")
                Text("macOS may ask you to confirm this change.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Ask at startup when CtrlX is not the default", isOn: $settings.askToHandleIPAFiles)
                if isSettingDefault {
                    ProgressView("Waiting for macOS…")
                }
                if let feedback {
                    Text(feedback.message).foregroundStyle(feedback.color).textSelection(.enabled)
                }
            }
            .task(id: scenePhase) {
                do {
                    current = try association.current()
                    if feedback == .success, current?.isCtrlX != true {
                        feedback = nil
                    }
                } catch { feedback = .failure(error.localizedDescription) }
            }
            .task(id: isSettingDefault) {
                guard isSettingDefault else { return }
                feedback = nil
                defer { isSettingDefault = false }
                do {
                    current = try await association.setDefaultAndVerify()
                    feedback = .success
                } catch {
                    guard !Task.isCancelled else { return }
                    feedback = error is CancellationError ? .cancelled : .failure(error.localizedDescription)
                }
            }
        }
    }
#endif
