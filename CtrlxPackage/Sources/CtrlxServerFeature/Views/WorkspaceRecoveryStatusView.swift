import AppKit
import SwiftUI

struct WorkspaceRecoveryStatusView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @State private var expanded = false

    var body: some View {
        if let recovery = coordinator.workspaceRecovery, settings.workspaceRecoveryMode != .disabled {
            if !recovery.isReady {
                HStack { ProgressView().controlSize(.small)
                    Text("Restoring workspace…")
                    Spacer()
                }.padding(8)
            } else if recovery.phase == .needsRecovery || recovery.error != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        DisclosureGroup("Workspace recovery", isExpanded: $expanded) { EmptyView() }
                        Spacer()
                        if expanded {
                            Button("Collapse") { expanded = false }
                                .accessibilityIdentifier("workspace-recovery-collapse")
                        }
                        Button("Retry") { Task { await recovery.retry() } }
                            .accessibilityIdentifier("workspace-recovery-retry-all")
                    }
                    if expanded {
                        if recovery.failures.contains(where: { $0.keepCurrentTerminal && $0.canUseShell }) {
                            Button("Keep All Current Terminals") { Task { await recovery.keepCurrentTerminals() } }
                                .accessibilityIdentifier("workspace-recovery-keep-all")
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                if let error = recovery.error {
                                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                if recovery.phase == .needsRecovery, recovery.failures.isEmpty {
                                    Text("The tmux server stopped. Your saved workspace is available to restore.").foregroundStyle(.secondary)
                                }
                                ForEach(recovery.failures) { failure in
                                    WorkspaceRecoveryFailureView(recovery: recovery, failure: failure)
                                }
                            }
                        }
                        .frame(maxHeight: 280)
                    }
                }
                .font(.callout)
                .padding(8)
            }
        }
    }
}

struct WorkspaceRecoveryFailureView: View {
    let recovery: WorkspaceRecoveryController
    let failure: WorkspaceRecoveryFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(failure.name).fontWeight(.medium)
            Text(failure.reason).foregroundStyle(.secondary).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
            .disabled(!recovery.isReady)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var actions: some View {
        if failure.canRetry {
            Button("Retry") { Task { await recovery.useShell(failure.id) } }
                .accessibilityIdentifier("workspace-recovery-retry-\(failure.id.uuidString)")
        }
        if failure.canResume {
            Button("Resume") { Task { await recovery.resumeAgent(failure.id) } }
        }
        if failure.canUseShell {
            Button(failure.keepCurrentTerminal ? "Keep terminal" : "Use Shell") { Task { await recovery.useShell(failure.id) } }
        }
    }
}

struct WorkspaceRecoveryWindowAnchor: NSViewRepresentable {
    let windows: DetachedTerminalWindows
    let isMain: Bool
    func makeNSView(context: Context) -> Anchor {
        Anchor(windows: windows, isMain: isMain)
    }

    func updateNSView(_ nsView: Anchor, context: Context) { }

    final class Anchor: NSView {
        let windows: DetachedTerminalWindows
        let isMain: Bool
        init(windows: DetachedTerminalWindows, isMain: Bool) {
            self.windows = windows
            self.isMain = isMain
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard isMain, let window else { return }
            windows.mainWindow = window
            NotificationCenter.default.addObserver(self, selector: #selector(restoreFrame), name: NSWindow.didUpdateNotification, object: window)
            restoreFrame()
        }

        @objc
        private func restoreFrame() {
            windows.applyRestoredMainFrame()
        }
    }
}
