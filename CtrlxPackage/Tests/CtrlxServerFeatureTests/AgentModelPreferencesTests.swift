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
    @Test("Late recovery of creation defaults cannot be undone by an earlier edit acknowledgement")
    func lateDefaultsAdvanceRevision() throws {
        let store = AgentModelPreferences()
        let pane = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let earlier = try store.update(.init(pane: pane, hidden: .init(models: ["edit"])), current: pane)
        let saved = [pane.windowID: AgentModelPreferences.Snapshot(hidden: .init(models: ["old"]), defaults: .init(efforts: ["low"]))]
        store.restore(saved, hostID: "local", serverID: pane.serverID, windowIDs: [pane.windowID])
        let current = try #require(store.shared(identities: [pane])[pane.windowID])
        #expect(current.hidden == earlier.hidden)
        #expect(current.defaults == saved[pane.windowID]?.defaults)
        #expect((current.revision ?? 0) > (earlier.revision ?? 0))
        store.restore(saved, hostID: "local", serverID: pane.serverID, windowIDs: [pane.windowID])
        #expect(store.shared(identities: [pane])[pane.windowID] == current)
    }

    @Test("Explicitly showing all buttons is saved before any delayed recovery")
    func emptySelectionSurvivesRecovery() throws {
        let store = AgentModelPreferences()
        let pane = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let value = try store.update(.init(pane: pane, hidden: .init()), current: pane)
        store.restore([pane.windowID: .init(hidden: .init(models: ["old"]))], hostID: "local", serverID: pane.serverID, windowIDs: [pane.windowID])
        #expect(store.shared(identities: [pane])[pane.windowID] == value)
        #expect(store.capture(hostID: "local", serverID: pane.serverID, windowIDs: [pane.windowID])?[pane.windowID]?.hidden == .init())
    }

    @Test("Viewer edits become Host preferences and survive restoration with creation defaults")
    func sharedPreferencesSurviveRestore() throws {
        let store = AgentModelPreferences()
        let pane = WorkspacePaneIdentity(serverID: "old", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let defaults = AgentModelShortcuts(models: ["default-hidden"])
        store.initialize(.init(pane: pane, defaults: defaults), hostID: "local")
        let edit = SetAgentModelShortcuts(pane: pane, hidden: .init(models: ["viewer-hidden"], efforts: ["low"]))
        let saved = try store.update(edit, current: pane)
        #expect(saved.defaults == defaults)
        #expect(store.shared(identities: [pane])[pane.windowID] == saved)
        #expect(try store.update(edit, current: pane) == saved)
        let captured = try JSONDecoder().decode([UUID: AgentModelPreferences.Snapshot].self, from: JSONEncoder().encode(
            #require(store.capture(hostID: "local", serverID: pane.serverID, windowIDs: [pane.windowID]))
        ))
        let restored = AgentModelPreferences()
        var newPane = pane
        newPane.serverID = "new"
        restored.restore(captured, hostID: "local", serverID: newPane.serverID, windowIDs: [pane.windowID])
        #expect(restored.shared(identities: [newPane])[pane.windowID] == saved)
        let reset = try restored.update(.init(pane: newPane, hidden: defaults), current: newPane)
        #expect(reset.hidden == defaults && reset.defaults == defaults)
        #expect(reset.revision == (saved.revision ?? 0) + 1)
        restored.restore(captured, hostID: "local", serverID: newPane.serverID, windowIDs: [pane.windowID])
        #expect(restored.shared(identities: [newPane])[pane.windowID] == reset)
    }

    @Test("Shortcut writes reject replaced targets but allow linked session aliases", arguments: ["server", "window", "pane", "session"])
    func validatesShortcutTarget(_ changed: String) throws {
        let store = AgentModelPreferences()
        let pane = WorkspacePaneIdentity(serverID: "old", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        var current = pane
        switch changed {
        case "server": current.serverID = "new"
        case "window": current.windowID = UUID()
        case "pane": current.paneID = UUID()
        default: current.sessionID = UUID()
        }
        let request = SetAgentModelShortcuts(pane: pane, hidden: .init(models: ["hidden"]))
        if changed == "session" {
            #expect(try store.update(request, current: current).hidden == request.hidden)
        } else {
            #expect(throws: (any Error).self) { try store.update(request, current: current) }
            #expect(store.tabs.isEmpty)
        }
    }

    @Test("Untouched windows advertise all buttons and unchanged writes do not invalidate preferences")
    func unchangedSharedPreferences() throws {
        let store = AgentModelPreferences()
        let pane = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        #expect(store.shared(identities: [pane])[pane.windowID]?.hidden == .init())
        let edit = SetAgentModelShortcuts(pane: pane, hidden: .init(models: ["hidden"]))
        let saved = try store.update(edit, current: pane)
        let invalidations = LockIsolated(0)
        withObservationTracking { _ = store.shared(identities: [pane]) } onChange: { invalidations.withValue { $0 += 1 } }
        #expect(try store.update(edit, current: pane) == saved)
        store.prune(hostID: "local", identities: [pane])
        #expect(invalidations.value == 0)
    }

    @Test("Repeated workspace updates do not republish restored shortcut preferences", arguments: [false, true])
    func restoredPreferencesDoNotPublish(hasDefaults: Bool) {
        let store = AgentModelPreferences(), id = UUID()
        let saved = [id: AgentModelPreferences.Snapshot(hidden: .init(models: ["hidden"]), defaults: hasDefaults ? .init(efforts: ["low"]) : nil)]
        store.restore(saved, hostID: "pair", serverID: "new", windowIDs: [id])
        let invalidations = LockIsolated(0)
        withObservationTracking {
            _ = store.tabs
            _ = store.defaults
        } onChange: { invalidations.withValue { $0 += 1 } }
        store.restore(saved, hostID: "pair", serverID: "new", windowIDs: [id])
        #expect(invalidations.value == 0)
    }

    @Test("Pruning unchanged model preferences does not invalidate observers")
    func unchangedPruneDoesNotPublish() {
        let store = AgentModelPreferences()
        let invalidations = LockIsolated(0)
        withObservationTracking { _ = store.tabs } onChange: { invalidations.withValue { $0 += 1 } }
        store.prune(hostID: "local", identities: [])
        #expect(invalidations.value == 0)

        let identity = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let key = AgentModelPreferences.Key(hostID: "local", windowID: identity.windowID)
        store.tabs[key] = .init(models: ["hidden"])
        invalidations.setValue(0)
        withObservationTracking { _ = store.tabs } onChange: { invalidations.withValue { $0 += 1 } }
        var rebuilt = identity
        rebuilt.serverID = "new-server"
        store.prune(hostID: "local", identities: [rebuilt])
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
        let local = AgentModelPreferences.Key(hostID: "local", windowID: identity.windowID)
        let remote = AgentModelPreferences.Key(hostID: "other-host", windowID: identity.windowID)
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
