#if os(macOS)
import AppKit
import ConcurrencyExtras
import CtrlxCommon
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@Suite("Embedded Agent Browser routing")
@MainActor
struct AgentBrowserRoutingTests {
    @Test("Native pages move between workspaces without closing or losing their view")
    func detachedPresentationOwnership() throws {
        _ = NSApplication.shared
        let service = AgentBrowserService()
        let main = AgentBrowserWorkspace()
        let detached = AgentBrowserWorkspace()
        var isDetached = false
        var mainCreates = 0
        var detachedCreates = 0
        var detachedRemovals = 0
        main.acceptsPane = { _ in !isDetached }
        detached.acceptsPane = { _ in isDetached }
        main.onCreate = { _, _ in mainCreates += 1 }
        detached.onCreate = { _, _ in detachedCreates += 1 }
        main.onDetach = { service.close($0) } // Existing UI callback must not destroy the moved page.
        detached.onDetach = { _ in detachedRemovals += 1 }
        service.register(main)
        service.register(detached)
        let source = pane("%1", session: "work")
        service.updateBrowserRoutes([source])
        let view = NSView()
        let id = UUID().uuidString
        service.browserTabCreated(id, view: view,
            route: ["workspace": main.id.uuidString, "pane": "%1", "session": "work", "window": source.windowId],
            owner: "agent-run", parent: nil)
        let state = try #require(service.tabs[id])
        isDetached = true
        service.register(detached)
        #expect(state.workspaceID == detached.id)
        #expect(state.view === view && !state.isClosed)
        #expect(mainCreates == 1 && detachedCreates == 1)
        isDetached = false
        service.unregister(detached)
        #expect(state.workspaceID == main.id)
        #expect(mainCreates == 2 && detachedRemovals == 1)
        #expect(state.view === view && state.owner == "agent-run" && !state.isClosed)
        service.browserTabClosed(id)
        service.unregister(main)
    }

    private func pane(_ id: String, session: String, window: Int = 0, active: Bool = false) -> PaneInfo {
        PaneInfo(paneId: id, target: "\(session):\(window).0", sessionName: session,
                 windowIndex: window, paneIndex: 0, command: "codex", currentPath: "/tmp",
                 width: 80, height: 24, isActive: active)
    }

    @Test("Source process wins even when another session has keyboard focus")
    func ignoresFocus() throws {
        let a = pane("%1", session: "office")
        let b = pane("%2", session: "home", active: true)
        #expect(try AgentBrowserRouting.resolve(panes: [b, a], matchingPaneIDs: ["%1"]) == a)
    }

    @Test("Split pane routes to its own window rather than the original pane")
    func splitPane() throws {
        let split = pane("%3", session: "office", window: 2)
        #expect(try AgentBrowserRouting.resolve(panes: [pane("%1", session: "office"), split], matchingPaneIDs: ["%3"]) == split)
    }

    @Test("Missing or exited source never falls back to the active terminal")
    func missing() {
        #expect(throws: AgentBrowserRoutingError.self) {
            try AgentBrowserRouting.resolve(panes: [pane("%1", session: "office", active: true)], matchingPaneIDs: [])
        }
    }

    @Test("Linked tmux sessions are ambiguous and fail closed")
    func linked() {
        #expect(throws: AgentBrowserRoutingError.self) {
            try AgentBrowserRouting.resolve(panes: [pane("%1", session: "a"), pane("%1", session: "b")], matchingPaneIDs: ["%1"])
        }
    }

    @Test("Renamed/moved source uses current metadata")
    func moved() throws {
        let current = pane("%7", session: "renamed", window: 4)
        #expect(try AgentBrowserRouting.resolve(panes: [current], matchingPaneIDs: ["%7"]).windowId == "renamed:4")
    }

        private nonisolated static func row(session: String, paneID: String = "%1", shellPID: String = "100") -> String {
            [shellPID, paneID, session, "1", "0", "codex", "/tmp", "80", "24", "1", "@1", "123:456", "00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002", "00000000-0000-0000-0000-000000000003"]
                .joined(separator: String(PaneInfo.fieldSeparator))
        }

        @Test("Agent route returns the complete live snapshot without another tmux query")
        func completeLiveRoute() async throws {
            let calls = LockIsolated(0)
            let rows = Self.row(session: "renamed") + "\n" + Self.row(session: "work", paneID: "%2", shellPID: "300")
            let runner = ProcessRunner(run: { _, arguments, _, _ in
                calls.withValue { $0 += 1 }
                #expect(arguments.contains("list-panes") && arguments.contains("-a"))
                return ProcessResult(exitCode: 0, stdout: Data(rows.utf8), stderr: Data())
            })
            try await withDependencies {
                $0[ProcessRunner.self] = runner
            } operation: {
                let service = TmuxService(tmuxPath: "/usr/bin/true")
                let route = try await service.agentPaneRoute(processID: 200, ancestorPIDs: [200, 100, 1])
                #expect(route.pane.paneId == "%1" && route.pane.sessionName == "renamed")
                #expect(route.panes.map(\.paneId) == ["%1", "%2"])
                #expect(route.panes.map(\.sessionName) == ["renamed", "work"])
                #expect(route.panes.first == route.pane && service.panes.isEmpty)
                #expect(calls.value == 1)
                #expect(route.pane.workspaceIdentity?.serverID == "123:456")
            }
        }

    @Test("Manual browser routing validates live pane membership without requiring an agent")
    func manualPaneRouting() async throws {
        func output(_ session: String) -> String {
            String(Self.row(session: session).split(separator: PaneInfo.fieldSeparator, maxSplits: 1)[1])
                .replacingOccurrences(of: "codex", with: "zsh")
        }
        let initialRows = output("work")
        let movedRows = output("moved")
        let linkedRows = initialRows + "\n" + output("linked")
        let rows = LockIsolated(initialRows)
        let runner = ProcessRunner(run: { _, arguments, _, _ in
            #expect(arguments.contains("list-panes") && arguments.contains("-a"))
            return ProcessResult(exitCode: 0, stdout: Data(rows.value.utf8), stderr: Data())
        })
        try await withDependencies {
            $0[ProcessRunner.self] = runner
        } operation: {
            let service = TmuxService(tmuxPath: "/usr/bin/true")
            let pane = try await service.browserSourcePane(sessionName: "work", paneID: "%1")
            #expect(pane.command == "zsh" && service.panes.isEmpty)
            await #expect(throws: (any Error).self) { try await service.browserSourcePane(sessionName: "work", paneID: "%9") }
            rows.setValue(movedRows)
            await #expect(throws: (any Error).self) { try await service.browserSourcePane(sessionName: "work", paneID: "%1") }
            #expect(try await service.browserSourcePane(sessionName: "moved", paneID: "%1").sessionName == "moved")
            rows.setValue(linkedRows)
            await #expect(throws: (any Error).self) { try await service.browserSourcePane(sessionName: "work", paneID: "%1") }
            rows.setValue("")
            await #expect(throws: (any Error).self) { try await service.browserSourcePane(sessionName: "work", paneID: "%1") }
            #expect(service.panes.isEmpty)
        }
    }

    @Test("Routing reads live panes while the first UI refresh is still in flight", arguments: ["codex", "claude"])
    func duringInitialRefresh(command: String) async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish(); entered.continuation.finish() }
        let runner = ProcessRunner(run: { executable, arguments, _, _ in
            if arguments.contains("list-clients") {
                entered.continuation.yield(())
                for await _ in release.stream { break }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            if executable == "/bin/ps" {
                return ProcessResult(exitCode: 0, stdout: Data(" PID PPID COMM\n100 1 zsh\n200 100 \(command)\n".utf8), stderr: Data())
            }
            let row = Self.row(session: "live")
            let output = arguments.last?.hasPrefix("#{pane_pid}") == true
                ? row : String(row.split(separator: PaneInfo.fieldSeparator, maxSplits: 1)[1])
            return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
        })
        try await withDependencies {
            $0[ProcessRunner.self] = runner
        } operation: {
            // Executable existence is checked by the UI refresh, but all actual
            // subprocess calls are mocked. No real tmux state is accessed.
            let service = TmuxService(tmuxPath: "/usr/bin/true")
            let refresh = Task { await service.refreshPanes() }
            defer { release.continuation.yield(()) }
            for await _ in entered.stream { break }
            #expect(service.panes.isEmpty)
            let source = try await service.agentBrowserPane(processID: 200)
            #expect(source.sessionName == "live")
            #expect(service.panes.isEmpty) // routing must not mutate the UI cache
            release.continuation.yield(())
            _ = await refresh.value
        }
    }

    @Test("Live routing preserves linked-session ambiguity before UI deduplication")
    func liveLinkedSessions() async throws {
        let runner = ProcessRunner(run: { executable, _, _, _ in
            let output = executable == "/bin/ps"
                ? " PID PPID COMM\n100 1 zsh\n200 100 codex\n"
                : Self.row(session: "office") + "\n" + Self.row(session: "home")
            return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
        })
        await withDependencies {
            $0[ProcessRunner.self] = runner
        } operation: {
            let service = TmuxService(tmuxPath: "/usr/bin/true")
            do {
                _ = try await service.agentBrowserPane(processID: 200)
                Issue.record("Ambiguous linked panes must not pick an arbitrary session")
            } catch AgentBrowserRoutingError.ambiguousPane {
                // Expected: both live session mappings reach the resolver.
            } catch {
                Issue.record("Unexpected routing error: \(error)")
            }
        }
    }

    @Test("Chromium tabs cannot be persisted/restored as ordinary WebKit tabs")
    func persistence() {
        let tabs = SessionFileTabsState()
        let url = URL(string: "https://example.com")!
        let manual = BrowserTab(url: url)
        var agent = BrowserTab(url: url)
        agent.isAgentBrowser = true
        tabs.openBrowserTabs = [manual, agent]
        tabs.selectedBrowserTabId = agent.id
        tabs.rightSide = [.browser(agent.id)]
        tabs.selectedRight = .browser(agent.id)
        tabs.tabOrder = [.browser(manual.id), .browser(agent.id)]
        let saved = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, windowIndexForId: { _ in nil })
        #expect(saved.browserTabs.map(\.id) == [manual.id])
        #expect(saved.tabOrder == [.browser(id: manual.id)])
        #expect(saved.selectedLeft == nil)
        #expect(saved.selectedRight == nil)
        #expect(saved.rightSide.isEmpty)
    }

    @Test("Native view and run ownership survive changes of metadata")
    func stableView() {
        let service = AgentBrowserService()
        let workspace = AgentBrowserWorkspace()
        let id = UUID()
        let view = NSView()
        var created: AgentBrowserTabState?
        var selected: UUID?
        var closed: UUID?
        workspace.onCreate = { state, _ in created = state }
        workspace.onSelect = { selected = $0.id }
        workspace.onClose = { closed = $0.id }
        service.register(workspace)
        service.browserTabCreated(id.uuidString, view: view,
            route: ["workspace": workspace.id.uuidString, "pane": "%3"], owner: "run-A", parent: nil)
        service.browserTabChanged(id.uuidString, title: "Loaded", url: "https://example.com", loading: false)
        service.browserTabSelected(id.uuidString)
        #expect(created?.view === view)
        #expect(created?.owner == "run-A")
        #expect(created?.title == "Loaded")
        #expect(selected == id)
        service.browserTabClosed(id.uuidString)
        #expect(closed == id)
        #expect(created?.isClosed == true)
        // A late callback cannot resurrect a tab already closed.
        service.browserTabChanged(id.uuidString, title: "Late", url: "https://example.com", loading: true)
        #expect(created?.title == "Loaded")
        service.unregister(workspace)
    }
}
#endif
