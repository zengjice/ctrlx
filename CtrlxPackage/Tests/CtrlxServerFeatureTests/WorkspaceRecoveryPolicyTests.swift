import CtrlxCommon
import Dependencies
import Foundation
import Synchronization
import Testing
@testable import CtrlxServerFeature

struct WorkspaceRecoveryPolicyTests {
    @MainActor
    @Test("Recovery choice persists independently of launch-at-login registration", arguments: WorkspaceRecoveryMode.allCases, [false, true])
    func loginCombinations(mode: WorkspaceRecoveryMode, loginEnabled: Bool) throws {
        let preferences = PreferencesService.inMemory()
        let registered = Mutex(false)
        let login = LoginItemService(
            isEnabled: { registered.withLock { $0 } },
            setEnabled: { enabled in registered.withLock { $0 = enabled } }
        )
        try withDependencies {
            $0[PreferencesService.self] = preferences
            $0[LoginItemService.self] = login
        } operation: {
            let settings = AppSettings()
            #expect(settings.workspaceRecoveryMode == .layoutAndAgents)
            settings.workspaceRecoveryMode = mode
            try settings.setLoginItemEnabled(loginEnabled)
            let reloaded = AppSettings()
            #expect(reloaded.workspaceRecoveryMode == mode)
            #expect(reloaded.launchAtLogin == loginEnabled)
            #expect(reloaded.isLoginItemEnabled == loginEnabled)
            let source = WorkspaceRecoveryStoreTests.snapshot()
            let live = WorkspaceTmuxState(serverID: nil, sessions: [])
            #expect(WorkspaceRecoveryPolicy.startup(snapshot: source, live: live, bootID: "new-boot", mode: reloaded.workspaceRecoveryMode) == (mode == .disabled ? .disabled : .restore))
            try reloaded.setLoginItemEnabled(!loginEnabled)
            #expect(reloaded.workspaceRecoveryMode == mode)
            #expect(reloaded.isLoginItemEnabled == !loginEnabled)
        }
    }

    @MainActor
    @Test("Failed login registration preserves both settings")
    func failedLoginRegistration() {
        struct RegistrationError: Error { }
        withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[LoginItemService.self] = .init(isEnabled: { false }, setEnabled: { _ in throw RegistrationError() })
        } operation: {
            let settings = AppSettings()
            settings.workspaceRecoveryMode = .layoutOnly
            #expect(throws: RegistrationError.self) { try settings.setLoginItemEnabled(true) }
            #expect(settings.workspaceRecoveryMode == .layoutOnly)
            #expect(settings.launchAtLogin == false)
            #expect(settings.isLoginItemEnabled == false)
        }
    }

    @Test("App restart preserves live tmux; only a reboot or unfinished recovery automatically restores")
    func startup() {
        var snapshot = WorkspaceRecoveryStoreTests.snapshot()
        var live = WorkspaceTmuxState(serverID: snapshot.serverID, sessions: snapshot.sessions)
        #expect(WorkspaceRecoveryPolicy.startup(snapshot: snapshot, live: live, bootID: snapshot.bootID, mode: .layoutAndAgents) == .observe)
        live.sessions = [] // A session deleted within the surviving server stays deleted.
        #expect(WorkspaceRecoveryPolicy.startup(snapshot: snapshot, live: live, bootID: snapshot.bootID, mode: .layoutOnly) == .observe)
        live.serverID = nil
        #expect(WorkspaceRecoveryPolicy.startup(snapshot: snapshot, live: live, bootID: snapshot.bootID, mode: .layoutAndAgents) == .offerRestore)
        #expect(WorkspaceRecoveryPolicy.startup(snapshot: snapshot, live: live, bootID: "new-boot", mode: .layoutAndAgents) == .restore)
        #expect(WorkspaceRecoveryPolicy.startup(snapshot: snapshot, live: live, bootID: "new-boot", mode: .layoutOnly) == .restore)
        #expect(WorkspaceRecoveryPolicy.startup(snapshot: snapshot, live: live, bootID: "new-boot", mode: .disabled) == .disabled)
        snapshot.recovery = .init(bootID: snapshot.bootID, pendingAgentPaneIDs: [])
        #expect(WorkspaceRecoveryPolicy.startup(snapshot: snapshot, live: live, bootID: snapshot.bootID, mode: .layoutAndAgents) == .restore)
        #expect(WorkspaceRecoveryPolicy.startup(snapshot: nil, live: live, bootID: "new-boot", mode: .layoutAndAgents) == .observe)
    }

    @Test("Reusing existing structure requires persistent identities, window positions and complete construction", arguments: [
        "complete", "extra-pane", "missing-session", "other-window", "other-pane", "moved-window", "incomplete-session", "incomplete-window",
    ])
    func existingStructure(state: String) {
        let source = WorkspaceRecoveryStoreTests.snapshot()
        var live = WorkspaceTmuxState(serverID: source.serverID, sessions: source.sessions)
        switch state {
        case "missing-session": live.sessions = []
        case "other-window": live.sessions[0].windows[0].id = UUID()
        case "other-pane": live.sessions[0].windows[0].panes[0].id = UUID()
        case "moved-window": live.sessions[0].windows[0].index += 1
        case "incomplete-session": live.incompleteSessionIDs = [source.sessions[0].id]
        case "incomplete-window": live.incompleteWindowIDs = [source.sessions[0].windows[0].id]
        case "extra-pane":
            live.sessions[0].windows[0].panes.append(.init(id: UUID(), runtimeID: "%2", directory: "/tmp"))
        default: break
        }
        #expect(WorkspaceRecoveryPolicy.containsSavedStructure(source.sessions, live: live) == (state == "complete" || state == "extra-pane"))
    }
}
