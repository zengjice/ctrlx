import AppKit
import ConcurrencyExtras
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import Foundation
import Observation
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentModelPreferencesTests {
    @Test("Pruning unchanged model preferences does not invalidate observers")
    func unchangedPruneDoesNotPublish() {
        let store = AgentModelPreferences()
        let invalidations = LockIsolated(0)
        withObservationTracking { _ = store.tabs } onChange: { invalidations.withValue { $0 += 1 } }
        store.prune(hostID: "local", identities: [])
        #expect(invalidations.value == 0)

        let identity = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let key = AgentModelPreferences.Key(hostID: "local", serverID: identity.serverID, windowID: identity.windowID)
        store.tabs[key] = .init(models: ["hidden"])
        invalidations.setValue(0)
        withObservationTracking { _ = store.tabs } onChange: { invalidations.withValue { $0 += 1 } }
        store.prune(hostID: "local", identities: [identity])
        #expect(invalidations.value == 0)
        store.prune(hostID: "local", identities: [])
        #expect(invalidations.value == 1)
        #expect(store.tabs.isEmpty)
    }

    @Test(arguments: [120.0, 260.0, 1_000.0], [false, true])
    func expandedButtonsKeepTheirHeightAndScrollWithinNarrowSplits(_ width: Double, _ dark: Bool) throws {
        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
        } operation: {
            _ = NSApplication.shared
            let settings = AppSettings()
            let models = (0..<12).map { AgentModelOption(id: "model-\($0)", name: "Model \($0)", efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "medium") }
            let snapshot = AgentModelSnapshot(runtimeID: "fixture", models: models, selection: .init(model: "model-1", effort: "high"), unavailableReason: nil)
            let size = Measurement()
            let view = AgentModelChoices(snapshot: snapshot, hidden: .init(), unavailableReason: nil, change: { _ in }, hide: { _, _ in })
                .environment(settings)
                .environment(\.colorScheme, dark ? .dark : .light)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size.value = $0 }
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: width, height: 32)
            host.layoutSubtreeIfNeeded()
            let measured = try #require(size.value)
            #expect(measured.width <= width)
            #expect(measured.height == 32)
        }
    }

    private class Measurement { var value: CGSize? }

    @Test
    func currentSelectionRemainsVisibleAndResetOnlyChangesDisplay() {
        var hidden = AgentModelPreferences.Hidden(models: ["a", "b"], efforts: ["high", "low"])
        let selected = AgentModelSelection(model: "a", effort: "high")
        let a = AgentModelOption(id: "a", name: "A", efforts: [], defaultEffort: nil)
        let b = AgentModelOption(id: "b", name: "B", efforts: [], defaultEffort: nil)
        #expect(hidden.shows(model: a, selection: selected))
        #expect(!hidden.shows(model: b, selection: selected))
        #expect(hidden.shows(effort: "high", selection: selected))
        #expect(!hidden.shows(effort: "low", selection: selected))
        hidden = .init()
        #expect(hidden.shows(model: b, selection: selected))
        #expect(selected.model == "a")
    }

    @Test
    func tabIdentitySurvivesDisplayMoveButNeverCrossesHostsOrClosedTabs() {
        let store = AgentModelPreferences()
        let identity = WorkspacePaneIdentity(serverID: "1:2", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let local = AgentModelPreferences.Key(hostID: "local", serverID: identity.serverID, windowID: identity.windowID)
        let remote = AgentModelPreferences.Key(hostID: "other-host", serverID: identity.serverID, windowID: identity.windowID)
        store.tabs[local] = .init(models: ["a"])
        store.tabs[remote] = .init(models: ["b"])
        store.prune(hostID: "local", identities: [identity])
        #expect(store.tabs[local]?.models == ["a"])
        store.prune(hostID: "local", identities: [])
        #expect(store.tabs[local] == nil)
        #expect(store.tabs[remote]?.models == ["b"])
    }

    @Test
    func wireIsOptionalForOldPeersAndRoundTripsSelection() throws {
        let old = try JSONDecoder().decode(CommandResponseMessage.self, from: Data("{\"commandId\":\"\(UUID())\",\"success\":true}".utf8))
        #expect(old.agentModels == nil)
        let identity = WorkspacePaneIdentity(serverID: "1:2", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let request = AgentModelControls(workspacePane: identity, runtimeID: "process-start", selection: .init(model: "a", effort: "high"))
        #expect(try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(request.commandType)) == request.commandType)
    }
}
