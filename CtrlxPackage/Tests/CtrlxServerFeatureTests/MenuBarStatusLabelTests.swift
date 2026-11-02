import AppKit
import ConcurrencyExtras
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite(.serialized)
struct MenuBarStatusLabelTests {
    @Test("Attention, manual overrides and quotas update without rebuilding the parent", arguments: [false, true])
    func liveStatus(hasRemoteStore: Bool) async throws {
        let badges = LockIsolated<[Int]>([])
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[ProcessRunner.self] = .previewValue
            $0[LoginItemService.self] = .previewValue
            $0[DockIconService.self].setBadgeCount = { count in badges.withValue { $0.append(count) } }
            $0[DashboardNotificationClient.self].notify = { _ in }
        } operation: {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let fixture = Fixture()
            let remote = hasRemoteStore ? SessionStore() : nil
            let renders = LockIsolated(0)
            let host = NSHostingView(rootView: ParentProbe(fixture: fixture, remote: remote, renders: renders))
            let window = makeWindow(host)
            defer { window.close() }

            try await expectLabel(host, pending: 0, lowQuota: 0)
            #expect(badges.value == [0])
            let initialRenders = renders.value

            // Agent attention is counted per pane, including siblings in one session.
            fixture.manager.setPaneStatesForPreview([pane("%1"), pane("%2")])
            try await expectLabel(host, pending: 2, lowQuota: 0)
            if let remote {
                // Both Hosts reuse the local session name and pane number.
                for hostID in ["A", "B"] {
                    remote.handleStateUpdate(.init(pairId: hostID, paneStates: ["%1": pane("%1")]))
                }
                try await expectLabel(host, pending: 4, lowQuota: 0)
            }
            let remoteCount = hasRemoteStore ? 2 : 0
            fixture.manager.setCLISessionState(.idle, forSession: "work")
            try await expectLabel(host, pending: remoteCount, lowQuota: 0)

            await fixture.dashboard.refresh([quotaEndpoint(used: 95)])
            try await expectLabel(host, pending: remoteCount, lowQuota: 1)
            let writesBeforeChurn = badges.value
            for index in 0..<20 {
                fixture.manager.updateTerminalTitle(paneId: "%1", title: "Title \(index)")
                if let remote {
                    var updated = pane("%1")
                    updated.progress = .normal(index)
                    remote.handleStateUpdate(.init(pairId: "A", paneStates: ["%1": updated]))
                }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            try await expectLabel(host, pending: remoteCount, lowQuota: 1)
            #expect(badges.value == writesBeforeChurn)
            #expect(renders.value == initialRenders)

            await fixture.dashboard.refresh([])
            try await expectLabel(host, pending: remoteCount, lowQuota: 0)
            if let remote {
                for hostID in ["A", "B"] {
                    remote.handleStateUpdate(.init(pairId: hostID, paneStates: [:]))
                }
                try await expectLabel(host, pending: 0, lowQuota: 0)
            }
            #expect(badges.value.last == 0)
            #expect(renders.value == initialRenders)
        }
    }

    private func pane(_ id: String) -> PaneState {
        PaneState(paneId: id, sessionName: "work", agentSession: .init(paneId: id, state: .doneWorking(summary: nil)))
    }

    private func quotaEndpoint(used: Double) -> DashboardEndpoint {
        .init(host: .init(id: "local", name: "This Mac", isConnected: true, isSupported: true)) {
            let now = Date()
            return .init(hostID: UUID(), generatedAt: now, timeZoneIdentifier: "UTC", accounts: [
                .init(
                    id: "default", pluginID: "codex", providerName: "Codex", label: "Personal", configurationLabel: "Default",
                    identity: .init(providerID: "codex", accountID: "person", workspaceID: "personal", poolID: "codex"),
                    authentication: .signedIn, availability: .available, quotaObservedAt: now,
                    windows: [.init(id: "week", title: "7 days", usedPercent: used)]
                ),
            ])
        }
    }

    private func makeWindow(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: .init(x: -10_000, y: -10_000, width: 250, height: 40),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func expectLabel(_ host: NSView, pending: Int, lowQuota: Int) async throws {
        let label = "CtrlX · \(pending) need attention · \(lowQuota) accounts low on quota"
        var observed: Set<String> = []
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            var queue: [Any] = [host]
            var visited: Set<ObjectIdentifier> = []
            while !queue.isEmpty {
                guard let node = queue.removeFirst() as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { continue }
                if let value = attribute("accessibilityLabel", from: node) as? String {
                    observed.insert(value)
                    if value == label {
                        return
                    }
                }
                queue += attribute("accessibilityChildren", from: node) as? [Any] ?? []
                if let view = node as? NSView {
                    queue += view.subviews
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "MenuBarStatusLabelTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Missing menu-bar label: \(label); observed: \(observed.sorted())",
        ])
    }

    private func attribute(_ name: String, from node: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue()
    }
}

@MainActor
private struct Fixture {
    let manager: MirrorWindowManager
    let dashboard = DashboardStore()

    init() {
        let tmux = TmuxService()
        let streams = PaneStreamManager(tmuxService: tmux, controlClientManager: TmuxControlClientManager())
        self.manager = MirrorWindowManager(
            settings: AppSettings(), tmuxService: tmux, paneStreamManager: streams,
            editorSessionManager: EditorSessionManager()
        )
    }
}

private struct ParentProbe: View {
    let fixture: Fixture
    let remote: SessionStore?
    let renders: LockIsolated<Int>

    var body: some View {
        let _ = renders.withValue { $0 += 1 }
        MenuBarStatusLabel(windowManager: fixture.manager, remoteStore: remote, dashboard: fixture.dashboard)
    }
}
