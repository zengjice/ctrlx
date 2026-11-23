import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@Suite("Tmux window reorder")
@MainActor
struct WindowReorderTests {
    @Test("Only a terminal move changes tmux order, including after another workbench or tmux edits the session")
    func sharedLayoutReordersLiveSession() async throws {
        let path = try #require(TmuxBinaryLocator.liveValue.find())
        let socket = "/tmp/ctrlx-tab-\(UUID().uuidString.prefix(12)).sock"
        let runner = ProcessRunner.liveValue
        let run: ([String]) async throws -> ProcessResult = { arguments in
            try await runner.run(executable: path, arguments: ["-S", socket, "-f", "/dev/null"] + arguments, environment: ["TMUX": "", "TMUX_PANE": ""], timeout: 10)
        }
        try await withDependencies {
            $0[ProcessRunner.self] = runner
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[LoginItemService.self] = .previewValue
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            $0.continuousClock = ContinuousClock()
        } operation: {
            _ = try await run(["new-session", "-d", "-s", "tabs", "/bin/cat"])
            do {
                for name in ["second", "third"] {
                    _ = try await run(["new-window", "-t", "tabs:", "-n", name, "/bin/cat"])
                }
                let settings = AppSettings()
                settings.tmuxPath = path
                settings.tmuxSocket = socket
                let coordinator = AppCoordinator(settings: settings)
                let panes = await coordinator.tmuxService.refreshPanes()
                coordinator.resourceSessions.update(panes)
                let sessionID = try #require(panes.first?.workspaceIdentity?.sessionID)
                let order: [SessionTabID] = panes.sorted { $0.windowIndex < $1.windowIndex }.compactMap { $0.workspaceIdentity.map { .window($0.windowID) } }
                try #require(order.count == 3)
                #expect(coordinator.sharedSessionTabLayouts[sessionID]?.revision == 0)

                let session = try coordinator.resourceSessions.resolve(sessionID)
                let first = try SessionTabID.file(coordinator.hostFileTabs.open(session: session, directory: "/tmp").id)
                let second = try SessionTabID.file(coordinator.hostFileTabs.open(session: session, directory: "/").id)
                try await coordinator.editSessionTabLayout(.init(
                    sessionID: sessionID, edit: .group(first, with: [second]),
                    initialOrder: [order[0], order[2], second, first]
                ))
                #expect(coordinator.sharedSessionTabLayouts[sessionID]?.order == order + [second, first])
                #expect(try await run(["list-windows", "-t", "tabs", "-F", "#{window_id}"]).stdoutString == "@0\n@1\n@2\n")

                let placeFileBeforeDetachedWindow = EditSessionTabLayout(sessionID: sessionID, edit: .move(first, before: order[1]))
                try await coordinator.editSessionTabLayout(placeFileBeforeDetachedWindow)
                #expect(coordinator.sharedSessionTabLayouts[sessionID]?.order == [order[0], first, order[1], order[2], second])

                // Moving C across Files alone still has to reconcile the hidden B.
                try await coordinator.editSessionTabLayout(.init(
                    sessionID: sessionID, edit: .move(order[2], before: first),
                    visibleWindows: [order[0], order[2]]
                ))
                #expect(coordinator.sharedSessionTabLayouts[sessionID]?.order == order + [first, second])
                #expect(try await run(["list-windows", "-t", "tabs", "-F", "#{window_id}"]).stdoutString == "@0\n@1\n@2\n")

                try await coordinator.editSessionTabLayout(placeFileBeforeDetachedWindow)
                try await coordinator.editSessionTabLayout(.init(
                    sessionID: sessionID, edit: .move(order[2], before: order[0]),
                    visibleWindows: [order[0], order[2]]
                ))
                #expect(try await run(["list-windows", "-t", "tabs", "-F", "#{window_id}"]).stdoutString == "@2\n@1\n@0\n")
                #expect(coordinator.sharedSessionTabLayouts[sessionID]?.order == Array(order.reversed()) + [first, second])

                _ = try await run(["swap-window", "-d", "-s", "@0", "-t", "@2"])
                await coordinator.tmuxService.refreshPanes()
                try await coordinator.editSessionTabLayout(.init(sessionID: sessionID, edit: .group(second, with: [first])))
                #expect(coordinator.sharedSessionTabLayouts[sessionID]?.order == order + [first, second])
                #expect(try await run(["list-windows", "-t", "tabs", "-F", "#{window_id}"]).stdoutString == "@0\n@1\n@2\n")

                let request = EditSessionTabLayout(sessionID: sessionID, edit: .moveToEnd(order[0], after: order[2]))
                try await coordinator.editSessionTabLayout(request)
                let saved = try #require(coordinator.sharedSessionTabLayouts[sessionID])
                #expect(saved.order == [order[1], order[2], order[0], first, second])
                #expect(try await run(["list-windows", "-t", "tabs", "-F", "#{window_id}"]).stdoutString == "@1\n@2\n@0\n")

                let next = EditSessionTabLayout(sessionID: sessionID, edit: .moveToEnd(order[1], after: nil))
                try await withDependencies {
                    $0[ProcessRunner.self].run = { executable, arguments, environment, timeout in
                        if arguments.contains(where: { $0.contains("swap-window") }) {
                            return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("injected swap failure".utf8))
                        }
                        return try await runner.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
                    }
                } operation: {
                    await #expect(throws: (any Error).self) { try await coordinator.editSessionTabLayout(next) }
                }
                #expect(coordinator.sharedSessionTabLayouts[sessionID] == saved)
                #expect(try await run(["list-windows", "-t", "tabs", "-F", "#{window_id}"]).stdoutString == "@1\n@2\n@0\n")
            } catch {
                _ = try? await run(["kill-server"])
                throw error
            }
            _ = try await run(["kill-server"])
        }
    }

    @Test("A terminal returned after Git in a new session keeps its position after the next Host edit")
    func firstTerminalReturnSurvivesSubsequentGrouping() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let store = HostSessionTabLayouts()
            let sessionID = UUID()
            let a = TabDragPayload.window("@1"), b = TabDragPayload.window("@2")
            let x = TabDragPayload.file(UUID()), y = TabDragPayload.file(UUID())
            let aID = SessionTabID.window(UUID()), bID = SessionTabID.window(UUID())
            let xID = SessionTabID.file(UUID()), yID = SessionTabID.file(UUID())
            let ids = [a: aID, b: bID, x: xID, y: yID]
            var catalog = [aID, bID, xID, yID]
            let snapshot = store.snapshot(sessionID: sessionID, catalog: catalog)
            var request: EditSessionTabLayout?
            var complete: (@MainActor () -> Void)?
            let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: snapshot)) { edit, baseline, windows, _, confirm in
                request = .init(sessionID: sessionID, edit: edit, initialOrder: baseline, visibleWindows: windows)
                complete = confirm
            }
            let tabs = SessionFileTabsState()
            tabs.tabOrder = [b, .git, x, y]
            tabs.rightSide = [.git]
            let placement = WorkbenchTabDropPlacement.end([.git])
            #expect(shared.drop(a, at: placement, order: tabs.tabOrder) {
                tabs.tabOrder.append(a)
                tabs.recordTabDrop(a, at: placement)
                tabs.rightSide.insert(a)
            })
            let move = try #require(request)
            #expect(snapshot.revision == 0)
            #expect(move.visibleWindows == [bID, aID])
            try await store.apply(move, catalog: catalog) { layout in
                let windows = layout.order.filter { $0 == aID || $0 == bID }
                catalog = windows + [xID, yID]
                return windows
            }
            complete?()
            try await store.apply(.init(sessionID: sessionID, edit: .group(xID, with: [yID])), catalog: catalog) { _ in nil }

            let refreshed = store.snapshot(sessionID: sessionID, catalog: catalog)
            let displayed = tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: .init(ids: ids, layout: refreshed))
            #expect(refreshed.revision == 2)
            #expect(displayed.filter(tabs.rightSide.contains) == [.git, a])
        }
    }

    @Test
    func permanentSessionRemovalCannotBeUndoneByAnInFlightLayoutEdit() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let store = HostSessionTabLayouts()
            let closed = UUID(), other = UUID()
            let a = SessionTabID.file(UUID()), b = SessionTabID.file(UUID())
            let catalog = [a, b]
            let edit = SessionTabLayout.Edit.group(a, with: [b])
            try await store.apply(.init(sessionID: closed, edit: edit), catalog: catalog) { _ in nil }
            try await store.apply(.init(sessionID: other, edit: edit), catalog: catalog) { _ in nil }
            await #expect(throws: FileBrowserError.self) {
                try await store.apply(.init(sessionID: closed, edit: edit), catalog: catalog) { _ in
                    try store.remove(closed)
                    return nil
                }
            }
            let reopened = HostSessionTabLayouts()
            #expect(reopened.snapshot(sessionID: closed, catalog: catalog).revision == 0)
            #expect(reopened.snapshot(sessionID: other, catalog: catalog).revision == 1)
        }
    }

    private func pane(
        _ paneId: String,
        session: String,
        window: Int,
        stableId: String
    ) -> PaneInfo {
        PaneInfo(
            paneId: paneId,
            target: "\(session):\(window).0",
            sessionName: session,
            windowIndex: window,
            tmuxWindowId: stableId,
            paneIndex: 0,
            command: "zsh",
            currentPath: "/tmp",
            width: 80,
            height: 24,
            isActive: true
        )
    }

    @Test("Plans stable-id swaps without assuming a zero base index")
    func plansBaseIndexOneOrder() throws {
        let current = [
            TmuxService.WindowPosition(stableId: "@1", index: 1),
            TmuxService.WindowPosition(stableId: "@2", index: 2),
            TmuxService.WindowPosition(stableId: "@3", index: 3),
        ]

        let swaps = try TmuxService.windowReorderSwaps(
            current: current,
            desiredIds: ["@3", "@1", "@2"]
        )

        #expect(swaps == [
            TmuxService.WindowSwap(sourceId: "@3", targetIndex: 1),
            TmuxService.WindowSwap(sourceId: "@1", targetIndex: 2),
        ])
    }

    @Test("Preserves sparse tmux index slots")
    func preservesSparseIndices() throws {
        let current = [
            TmuxService.WindowPosition(stableId: "@4", index: 4),
            TmuxService.WindowPosition(stableId: "@8", index: 8),
            TmuxService.WindowPosition(stableId: "@12", index: 12),
        ]

        let swaps = try TmuxService.windowReorderSwaps(
            current: current,
            desiredIds: ["@8", "@12", "@4"]
        )

        #expect(swaps == [
            TmuxService.WindowSwap(sourceId: "@8", targetIndex: 4),
            TmuxService.WindowSwap(sourceId: "@12", targetIndex: 8),
        ])
    }

    @Test("Rejects stale, partial, and duplicate requests")
    func rejectsInvalidOrders() {
        let current = [
            TmuxService.WindowPosition(stableId: "@1", index: 1),
            TmuxService.WindowPosition(stableId: "@2", index: 2),
        ]

        for desired in [["@1"], ["@1", "@1"], ["@1", "@gone"]] {
            #expect(throws: TmuxError.self) {
                try TmuxService.windowReorderSwaps(current: current, desiredIds: desired)
            }
        }
    }

    @Test("Detects target changes without confusing linked sessions")
    func detectsReindexBySessionAndStableId() {
        let old = [
            pane("%1", session: "alpha", window: 1, stableId: "@7"),
            pane("%1", session: "beta", window: 4, stableId: "@7"),
            pane("%2", session: "alpha", window: 2, stableId: "@8"),
        ]
        let new = [
            pane("%1", session: "alpha", window: 2, stableId: "@7"),
            pane("%1", session: "beta", window: 4, stableId: "@7"),
            pane("%2", session: "alpha", window: 1, stableId: "@8"),
        ]

        #expect(WindowReindexMapping.detect(from: old, to: new) == [
            "alpha:1": "alpha:2",
            "alpha:2": "alpha:1",
        ])
    }

    @Test("Reorders a live tmux session without losing window identity")
    func reordersLiveSession() async throws {
        let tmuxPath = "/opt/homebrew/bin/tmux"
        try #require(FileManager.default.isExecutableFile(atPath: tmuxPath))

        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
        } operation: {
            let suffix = UUID().uuidString.lowercased()
            let sessionName = "ctrlx-reorder-\(suffix)"
            let socketPath = "/tmp/gw-\(suffix.prefix(8)).sock"
            let service = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
            defer { try? FileManager.default.removeItem(atPath: socketPath) }

            _ = try await service.createSession(baseName: sessionName, width: 80, height: 24)
            do {
                _ = try await service.newWindow(sessionName: sessionName, windowName: "second")
                _ = try await service.newWindow(sessionName: sessionName, windowName: "third")
                _ = await service.refreshPanes()

                let before = service.windows
                    .filter { $0.sessionName == sessionName }
                    .sorted { $0.windowIndex < $1.windowIndex }
                #expect(before.count == 3)
                #expect(before.allSatisfy { $0.stableId.hasPrefix("@") })

                let desired = [before[2].stableId, before[0].stableId, before[1].stableId]
                let originalPaneIds = Set(before.flatMap(\.panes).map(\.paneId))
                let originalIndices = before.map(\.windowIndex)
                let mapping = try await service.moveWindows(in: sessionName, to: desired)
                _ = await service.refreshPanes()

                let after = service.windows
                    .filter { $0.sessionName == sessionName }
                    .sorted { $0.windowIndex < $1.windowIndex }
                #expect(after.map(\.stableId) == desired)
                #expect(after.map(\.windowIndex) == originalIndices)
                #expect(Set(after.flatMap(\.panes).map(\.paneId)) == originalPaneIds)
                #expect(mapping.count == before.count)

                try await service.killSession(sessionName)
            } catch {
                try? await service.killSession(sessionName)
                throw error
            }
        }
    }
}
