import CtrlxCommon
import CtrlxNetworking
import SwiftUI

/// Keeps menu routing scene-local, including when several workbenches are visible.
struct MenuCommandsModifier: ViewModifier {
    let onOpenContentSearch: @MainActor () -> Void
    let tabCount: Int
    let canSelectAdjacentTab: Bool
    let onSelectTabAtIndex: @MainActor (Int) -> Void
    let onSelectPreviousTab: @MainActor () -> Void
    let onSelectNextTab: @MainActor () -> Void
    let onSelectPreviousSession: @MainActor () -> Void
    let onSelectNextSession: @MainActor () -> Void
    let onNewLocalSession: @MainActor () -> Void
    let onNewTerminal: (@MainActor () -> Void)?
    let onSwitchSession: (@MainActor () -> Void)?
    let onToggleVoiceInput: (@MainActor () -> Void)?
    let allowsSessionNavigation: Bool

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.workbenchMenuActions, WorkbenchMenuActions(
                openContentSearch: onOpenContentSearch,
                tabCount: tabCount,
                canSelectAdjacentTab: canSelectAdjacentTab,
                selectTabAtIndex: onSelectTabAtIndex,
                selectPreviousTab: onSelectPreviousTab,
                selectNextTab: onSelectNextTab,
                selectPreviousSession: allowsSessionNavigation ? onSelectPreviousSession : nil,
                selectNextSession: allowsSessionNavigation ? onSelectNextSession : nil,
                newLocalSession: allowsSessionNavigation ? onNewLocalSession : nil,
                newTerminal: onNewTerminal,
                switchSession: onSwitchSession,
                toggleVoiceInput: onToggleVoiceInput
            ))
    }
}

/// Publishes a logical terminal layout when the split is toggled, its divider
/// moves, or the selected right-side terminal changes. Terminal dimensions are
/// deliberately absent: only the explicit resize-to-fit button may change them.
/// Kept outside `MainView.body` to stay inside SwiftUI's type-checker budget.
struct SharedTerminalLayoutSyncModifier<Signal: Equatable>: ViewModifier {
    let splitSignal: Signal?
    let onSplitChanged: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: splitSignal) { _, _ in
            onSplitChanged()
        }
    }
}

/// One observer orders rename, catalog reconciliation and pruning for every scene.
struct RemoteSessionStructureModifier: ViewModifier {
    let structure: RemoteSessionStructure
    var browserCatalogs: [String: [RemoteBrowserTab]] = [:]
    var simulatorCatalogs: [String: [RemoteSimulatorTab]] = [:]
    var selection: RemoteSessionSelection?
    let onRename: (String, SessionRenameMapping) -> Void
    let onSyncBrowserTabs: () -> Void
    let onPrune: () -> Void

    private struct Snapshot: Equatable {
        let structure: RemoteSessionStructure
        let browserCatalogs: [String: [RemoteBrowserTab]]
        let simulatorCatalogs: [String: [RemoteSimulatorTab]]
        let selection: RemoteSessionSelection?
    }

    func body(content: Content) -> some View {
        content.onChange(of: Snapshot(structure: structure, browserCatalogs: browserCatalogs, simulatorCatalogs: simulatorCatalogs, selection: selection), initial: true) { previous, current in
            for rename in current.structure.renames(from: previous.structure) {
                onRename(rename.hostID, rename.mapping)
            }
            onSyncBrowserTabs()
            if previous.structure != current.structure {
                onPrune()
            }
        }
    }
}

/// Applies Host-owned terminal placement when a local or remote shared layout
/// changes. Kept out of `MainView.body` to avoid growing its SwiftUI generic
/// expression past the compiler's type-checking budget.
struct SharedTerminalLayoutObserversModifier<Local: Equatable, Remote: Equatable>: ViewModifier {
    let local: Local?
    let remote: Remote?
    let onLocalChanged: () -> Void
    let onRemoteChanged: () -> Void
    let onDisappear: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: local, initial: true) { _, _ in
                onLocalChanged()
            }
            .onChange(of: remote, initial: true) { _, _ in
                onRemoteChanged()
            }
            .onDisappear {
                onDisappear()
            }
    }
}

/// Hosts the transient error alert and the close-confirmation alert. Editor
/// launch failures are routed through here as well so the two alert
/// affordances stay co-located.
struct AlertsModifier: ViewModifier {
    @Binding var attachError: String?
    @Binding var closeConfirmation: CloseConfirmation?
    let onPerformClose: (CloseConfirmation.Target) -> Void

    func body(content: Content) -> some View {
        content
            // Routed through here so editor-launch failures surface via the
            // same alert affordance as other transient errors. Defined inside
            // the existing alerts modifier (rather than as a new chained
            // `.onReceive` in `MainView.body`) to keep the body's modifier
            // chain inside SwiftUI's type-checker budget.
            .onReceive(NotificationCenter.default.publisher(for: .editorLaunchFailed)) { notification in
                if let message = notification.userInfo?[editorLaunchFailedMessageKey] as? String {
                    attachError = message
                }
            }
            .alert("Terminal Error", isPresented: .init(
                get: { attachError != nil },
                set: {
                    if !$0 {
                        attachError = nil
                    }
                }
            )) {
                Button("OK") { attachError = nil }
            } message: {
                if let error = attachError {
                    Text(error)
                }
            }
            .alert(item: $closeConfirmation) { confirmation in
                Alert(
                    title: Text(confirmation.title),
                    message: Text(confirmation.message),
                    primaryButton: .destructive(Text(confirmation.closesLastWindow ? "Close Session" : "Close Anyway")) {
                        onPerformClose(confirmation.target)
                    },
                    secondaryButton: .cancel()
                )
            }
    }
}
