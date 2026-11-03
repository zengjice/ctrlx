#if os(macOS)
    import AppKit
    import CtrlxCommon
    import Dependencies
    import SwiftUI

    public struct FullDiskAccessPromptScene: Scene {
        static let windowID = "full-disk-access"

        public init() { }

        public var body: some Scene {
            Window("Host File Access", id: Self.windowID) {
                FullDiskAccessPrompt()
            }
            .windowResizability(.contentSize)
            .defaultPosition(.center)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
            .commandsRemoved()
        }
    }

    public extension View {
        func suggestFullDiskAccess(isReady: Bool) -> some View {
            modifier(FullDiskAccessSuggestion(isReady: isReady))
        }
    }

    private struct FullDiskAccessSuggestion: ViewModifier {
        let isReady: Bool
        @Environment(AppSettings.self) private var settings
        @Environment(\.openWindow) private var openWindow

        func body(content: Content) -> some View {
            content
                .onChange(of: isReady, initial: true) { _, _ in presentIfNeeded() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    presentIfNeeded()
                }
        }

        private func presentIfNeeded() {
            guard
                settings.takeFullDiskAccessPrompt(
                    isReady: isReady,
                    isActive: NSApp.isActive,
                    isTesting: CommandLine.arguments.contains("--e2e-test")
                ) else { return }
            openWindow(id: FullDiskAccessPromptScene.windowID)
        }
    }

    struct FullDiskAccessPrompt: View {
        @Environment(\.dismiss) private var dismiss
        @Dependency(FullDiskAccessClient.self) private var access
        @State private var errorMessage: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text("Allow Full Disk Access for This Host")
                    .font(.title2.bold())
                Text("Enable Full Disk Access so CtrlX can open files on this Mac for local sessions and connected Viewers without separate Desktop, Documents and Downloads prompts.")
                Text("This grants CtrlX access to protected files, including other apps’ data. You can revoke it at any time in System Settings.")
                    .foregroundStyle(.secondary)
                Text("In System Settings → Privacy & Security → Full Disk Access, enable CtrlX. If it is not listed, click + and select the CtrlX app shown in Finder.")
                Text("If access is already enabled, close this guide. If macOS asks you to quit and reopen CtrlX, do so when you are ready; connected Viewers will briefly disconnect.")
                    .foregroundStyle(.secondary)
                Button("Show CtrlX in Finder") { perform(access.revealApplication) }
                    .accessibilityIdentifier("full-disk-access-reveal")
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                }
                Text("You can reopen this guide in Settings → General → Host File Access.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Not Now") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("full-disk-access-dismiss")
                    Spacer()
                    Button("Open System Settings") { perform(access.openSettings) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("full-disk-access-settings")
                }
            }
            .padding(24)
            .frame(width: 520)
            .fixedSize(horizontal: false, vertical: true)
        }

        private func perform(_ action: @MainActor () throws -> Void) {
            errorMessage = nil
            do {
                try action()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    struct FullDiskAccessSettingsSection: View {
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Section("Host File Access") {
                Text("Enable Full Disk Access for CtrlX on this Mac to avoid separate folder permission prompts when using local or remote files.")
                Button("Set Up Full Disk Access…") {
                    openWindow(id: FullDiskAccessPromptScene.windowID)
                }
                .accessibilityIdentifier("full-disk-access-guide")
            }
        }
    }
#endif
