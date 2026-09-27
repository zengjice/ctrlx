#if os(macOS)
import AppKit
import CtrlxCommon
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@Suite("Embedded Agent Browser routing")
@MainActor
struct AgentBrowserRoutingTests {
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

    nonisolated private static func row(session: String) -> String {
        ["100", "%1", session, "1", "0", "codex", "/tmp", "80", "24", "1"]
            .joined(separator: String(PaneInfo.fieldSeparator))
    }

    @Test("Routing reads live panes while the first UI refresh is still in flight")
    func duringInitialRefresh() async throws {
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
                return ProcessResult(exitCode: 0, stdout: Data(" PID PPID COMM\n100 1 zsh\n200 100 codex\n".utf8), stderr: Data())
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
