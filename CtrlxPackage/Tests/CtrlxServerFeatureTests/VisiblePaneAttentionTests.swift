#if os(macOS)
    import ConcurrencyExtras
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import Observation
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite("Visible pane attention")
    struct VisiblePaneAttentionTests {
        private func makeWindowManager() -> MirrorWindowManager {
            withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[ProcessRunner.self] = .previewValue
                $0[LoginItemService.self] = .previewValue
            } operation: {
                let tmux = TmuxService()
                let streams = PaneStreamManager(
                    tmuxService: tmux,
                    controlClientManager: TmuxControlClientManager()
                )
                return MirrorWindowManager(
                    settings: AppSettings(),
                    tmuxService: tmux,
                    paneStreamManager: streams,
                    editorSessionManager: EditorSessionManager()
                )
            }
        }

        private func apply(_ state: AgentState, paneId: String, to manager: MirrorWindowManager) {
            manager.applyState(
                pluginID: "codex", sessionID: "session-\(paneId)",
                state: state, tmuxPane: paneId, projectPath: nil
            )
        }

        @Test("Delayed attention and Yolo actions cannot mutate a replacement pane", arguments: [false, true])
        func replacementPaneActions(restarted: Bool) {
            let manager = makeWindowManager()
            let original = WorkspacePaneIdentity(serverID: "10:100", sessionID: UUID(), windowID: UUID(), paneID: UUID())
            var replacement = original
            if restarted {
                replacement.serverID = "11:100"
            } else {
                replacement.paneID = UUID()
            }
            manager.setPaneStatesForPreview([PaneState(
                paneId: "%7",
                agentSession: AgentSession(paneId: "%7", pluginID: "codex", state: .doneWorking(summary: "New task")),
                workspaceIdentity: replacement
            )])
            #expect(!manager.setYoloMode(enabled: true, for: "%7", expectedWorkspacePane: original))
            #expect(!manager.markSessionHandled(paneId: "%7", expectedWorkspacePane: original))
            #expect(!manager.isYoloModeEnabled(for: "%7"))
            #expect(manager.paneStates["%7"]?.agentSession?.needsAttention == true)
            #expect(!manager.setYoloMode(enabled: true, for: "%8", expectedWorkspacePane: replacement))
            #expect(manager.paneStates["%8"] == nil)

            // Moving the same physical pane between windows does not retire it.
            var moved = replacement
            moved.windowID = UUID()
            moved.sessionID = UUID()
            #expect(manager.setYoloMode(enabled: true, for: "%7", expectedWorkspacePane: moved))
            #expect(manager.markSessionHandled(paneId: "%7", expectedWorkspacePane: moved))
            #expect(manager.isYoloModeEnabled(for: "%7"))
            #expect(manager.paneStates["%7"]?.agentSession?.state == .idle)
        }

        private func acknowledge(
            _ target: VisiblePaneAttention,
            manager: MirrorWindowManager,
            store: SessionStore? = nil,
            visible: Bool = true,
            active: Bool = true
        ) -> Bool {
            target.markHandledIfNeeded(
                isVisible: visible, isAppActive: active,
                windowManager: manager, remoteStore: store
            )
        }

        @Test("Both visible split sides clear independently; hidden tabs stay unread", arguments: [false, true])
        func splitSides(remote: Bool) {
            let manager = makeWindowManager()
            let store = SessionStore()
            for paneId in ["%1", "%2", "%3"] {
                apply(.doneWorking(summary: "Finished"), paneId: paneId, to: manager)
            }
            store.handleStateUpdate(SessionStateMessage(pairId: "host", paneStates: manager.paneStates))
            func target(_ id: String) -> VisiblePaneAttention {
                remote ? .remote(hostId: "host", paneId: id) : .local(paneId: id)
            }

            // These readers belong to tiles, not the selected left window.
            #expect(acknowledge(target("%1"), manager: manager, store: store))
            #expect(acknowledge(target("%2"), manager: manager, store: store))
            #expect(!acknowledge(target("%3"), manager: manager, store: store, visible: false))
            #expect(target("%1").state(windowManager: manager, remoteStore: store) == .idle)
            #expect(target("%2").state(windowManager: manager, remoteStore: store) == .idle)
            #expect(target("%3").state(windowManager: manager, remoteStore: store)?.needsAttention == true)
            let states = remote ? Array(store.paneStates.values) : Array(manager.paneStates.values)
            #expect(states.pendingSessionCount == 1)
        }

        @Test("A pane's state changes even when the pending total stays the same", arguments: [false, true])
        func sameCountCompletionIsObserved(remote: Bool) {
            let manager = makeWindowManager()
            let store = SessionStore()
            apply(.working, paneId: "%1", to: manager)
            apply(.doneWorking(summary: nil), paneId: "%2", to: manager)
            store.handleStateUpdate(SessionStateMessage(pairId: "host", paneStates: manager.paneStates))
            let target: VisiblePaneAttention = remote ? .remote(hostId: "host", paneId: "%1") : .local(paneId: "%1")
            let before = target.state(windowManager: manager, remoteStore: store)
            let invalidations = LockIsolated(0)
            withObservationTracking {
                _ = target.state(windowManager: manager, remoteStore: store)
            } onChange: {
                invalidations.withValue { $0 += 1 }
            }

            // SwiftUI may coalesce these updates into one render. The total is
            // still one, but the displayed pane changed working → doneWorking.
            apply(.working, paneId: "%2", to: manager)
            apply(.doneWorking(summary: "New completion"), paneId: "%1", to: manager)
            store.handleStateUpdate(SessionStateMessage(pairId: "host", paneStates: manager.paneStates))
            #expect(manager.pendingSessionCount == 1)
            #expect(Array(store.paneStates.values).pendingSessionCount == 1)
            #expect(invalidations.value > 0)
            #expect(before != target.state(windowManager: manager, remoteStore: store))
            #expect(acknowledge(target, manager: manager, store: store))
            let states = remote ? Array(store.paneStates.values) : Array(manager.paneStates.values)
            #expect(states.pendingSessionCount == 0)
        }

        @Test("A remote completion is observed without any local pending-count change")
        func remoteCompletionWithoutLocalActivity() {
            let manager = makeWindowManager()
            let store = SessionStore()
            let fixture = makeWindowManager()
            apply(.working, paneId: "%7", to: fixture)
            store.handleStateUpdate(SessionStateMessage(pairId: "host", paneStates: fixture.paneStates))
            let target = VisiblePaneAttention.remote(hostId: "host", paneId: "%7")
            let before = target.state(windowManager: manager, remoteStore: store)
            let invalidations = LockIsolated(0)
            withObservationTracking {
                _ = target.state(windowManager: manager, remoteStore: store)
            } onChange: {
                invalidations.withValue { $0 += 1 }
            }
            apply(.doneWorking(summary: "Finished"), paneId: "%7", to: fixture)
            store.handleStateUpdate(SessionStateMessage(pairId: "host", paneStates: fixture.paneStates))
            #expect(manager.pendingSessionCount == 0)
            #expect(invalidations.value == 1)
            #expect(before != target.state(windowManager: manager, remoteStore: store))
            #expect(acknowledge(target, manager: manager, store: store))
            #expect(Array(store.paneStates.values).pendingSessionCount == 0)
        }

        @Test("Background completion remains unread until the app becomes active", arguments: [false, true])
        func activation(remote: Bool) {
            let manager = makeWindowManager()
            let store = SessionStore()
            apply(.doneWorking(summary: nil), paneId: "%1", to: manager)
            store.handleStateUpdate(SessionStateMessage(pairId: "host", paneStates: manager.paneStates))
            let target: VisiblePaneAttention = remote ? .remote(hostId: "host", paneId: "%1") : .local(paneId: "%1")
            #expect(!acknowledge(target, manager: manager, store: store, active: false))
            #expect(target.state(windowManager: manager, remoteStore: store)?.needsAttention == true)
            #expect(acknowledge(target, manager: manager, store: store))
            // Repeated activation/mount/state callbacks must not re-send a clear.
            #expect(!acknowledge(target, manager: manager, store: store))
        }

        @Test("Viewing never consumes working, idle, permission, question or plan states", arguments: [
            AgentState.working,
            .idle,
            .awaitingPermission(PermissionRequest(title: "Bash", description: "ls"), requestID: "p"),
            .awaitingReplies(AskUserQuestionRequest(questions: []), requestID: "q"),
            .awaitingPlanApproval(ApprovePlanRequest(title: "Plan", plan: "do it"), requestID: "a"),
        ], [false, true])
        func preservesNonCompletion(state: AgentState, remote: Bool) {
            let manager = makeWindowManager()
            let store = SessionStore()
            apply(state, paneId: "%1", to: manager)
            store.handleStateUpdate(SessionStateMessage(pairId: "host", paneStates: manager.paneStates))
            let target: VisiblePaneAttention = remote ? .remote(hostId: "host", paneId: "%1") : .local(paneId: "%1")
            #expect(!acknowledge(target, manager: manager, store: store))
            #expect(target.state(windowManager: manager, remoteStore: store) == state)
        }

        @Test("Read acknowledgement rechecks the current state, not a stale completion")
        func staleCompletionDoesNotConsumeNewForm() {
            let manager = makeWindowManager()
            let target = VisiblePaneAttention.local(paneId: "%1")
            apply(.doneWorking(summary: nil), paneId: "%1", to: manager)
            #expect(target.state(windowManager: manager, remoteStore: nil)?.needsAttention == true)
            let form = AgentState.awaitingReplies(AskUserQuestionRequest(questions: []), requestID: "new-question")
            apply(form, paneId: "%1", to: manager)
            #expect(!acknowledge(target, manager: manager))
            #expect(target.state(windowManager: manager, remoteStore: nil) == form)
        }

        @Test("Local and multiple remote hosts can reuse the same pane ID")
        func hostIdentity() {
            let manager = makeWindowManager()
            let store = SessionStore()
            apply(.doneWorking(summary: nil), paneId: "%1", to: manager)
            for host in ["host-a", "host-b"] {
                store.handleStateUpdate(SessionStateMessage(pairId: host, paneStates: manager.paneStates))
            }
            let local = VisiblePaneAttention.local(paneId: "%1")
            let first = VisiblePaneAttention.remote(hostId: "host-a", paneId: "%1")
            let second = VisiblePaneAttention.remote(hostId: "host-b", paneId: "%1")
            #expect(first != second)
            #expect(first != local)
            #expect(acknowledge(second, manager: manager, store: store))
            #expect(first.state(windowManager: manager, remoteStore: store)?.needsAttention == true)
            #expect(local.state(windowManager: manager, remoteStore: store)?.needsAttention == true)
            #expect(second.state(windowManager: manager, remoteStore: store) == .idle)
        }

        @Test("Missing and disconnected stores are no-ops")
        func missingPane() {
            let manager = makeWindowManager()
            #expect(!acknowledge(.local(paneId: "%missing"), manager: manager))
            #expect(!acknowledge(.remote(hostId: "missing", paneId: "%1"), manager: manager))
        }
    }
#endif
