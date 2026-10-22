#if os(macOS)
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    private actor TestLatch {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume()
            }
        }
    }

    @MainActor
    @Suite("Pane lifecycle race guards")
    struct PaneLifecycleRaceTests {
        @Test("concurrent requests share one pane reader start")
        func readerStartIsSingleFlight() async {
            let gate = PaneReaderStartGate()
            let latch = TestLatch()
            var starts = 0

            let first = Task {
                await gate.run(paneId: "%8") {
                    starts += 1
                    await latch.wait()
                    return true
                }
            }
            while starts == 0 { await Task.yield() }

            let second = Task {
                await gate.run(paneId: "%8") {
                    starts += 1
                    await latch.wait()
                    return true
                }
            }
            await Task.yield()

            #expect(starts == 1)
            await latch.open()
            #expect(await first.value)
            #expect(await second.value)
            #expect(starts == 1)
        }

        @Test("failed pane reader start can be retried")
        func failedReaderStartIsRemoved() async {
            let gate = PaneReaderStartGate()
            var starts = 0

            let first = await gate.run(paneId: "%9") {
                starts += 1
                return false
            }
            let second = await gate.run(paneId: "%9") {
                starts += 1
                return true
            }

            #expect(!first)
            #expect(second)
            #expect(starts == 2)
        }

        @Test("cancelling starts drains the flight table")
        func cancelAllAllowsCleanRetry() async {
            let gate = PaneReaderStartGate()
            var started = false

            let pending = Task {
                await gate.run(paneId: "%10") {
                    started = true
                    while !Task.isCancelled {
                        await Task.yield()
                    }
                    return false
                }
            }
            while !started { await Task.yield() }

            await gate.cancelAll()
            #expect(!(await pending.value))
            #expect(await gate.run(paneId: "%10") { true })
        }

        @Test("new pane waits through stale window snapshots")
        func localWindowRetriesStaleCache() async {
            let expected = makeWindow(paneId: "%11")
            var cachedWindows: [LocalTmuxWindow] = []
            var refreshes = 0

            let result = await PaneSurfaceRetry.localWindow(
                containing: "%11",
                attempts: 3,
                delay: .zero,
                windows: { cachedWindows },
                refresh: {
                    refreshes += 1
                    if refreshes == 2 {
                        cachedWindows = [expected]
                    }
                }
            )

            #expect(result == expected)
            #expect(refreshes == 2)
        }

        @Test("visible pane does not trigger another refresh")
        func localWindowUsesCurrentCache() async {
            let expected = makeWindow(paneId: "%12")
            var refreshes = 0

            let result = await PaneSurfaceRetry.localWindow(
                containing: "%12",
                attempts: 2,
                delay: .zero,
                windows: { [expected] },
                refresh: { refreshes += 1 }
            )

            #expect(result == expected)
            #expect(refreshes == 0)
        }

        @Test("Creation selection ignores the same numeric pane on another tmux server")
        func createdPaneIncarnation() async {
            let replacement = makeWindow(paneId: "%0", serverID: "20:200")
            let created = makeWindow(paneId: "%0", serverID: "10:100")
            var windows = [replacement]
            let result = await PaneSurfaceRetry.localWindow(
                containing: "%0", serverID: "10:100", attempts: 2, delay: .zero,
                windows: { windows }, refresh: { windows = [created] }
            )
            #expect(result == created)
            let rejected = await PaneSurfaceRetry.localWindow(
                containing: "%0", serverID: "10:100", attempts: 1,
                windows: { [replacement] }, refresh: { }
            )
            #expect(rejected == nil)
        }

        private func makeWindow(paneId: String, serverID: String? = nil) -> LocalTmuxWindow {
            let pane = PaneInfo(
                paneId: paneId,
                target: "work:5.0",
                sessionName: "work",
                windowIndex: 5,
                paneIndex: 0,
                command: "zsh",
                currentPath: "/tmp",
                width: 120,
                height: 40,
                isActive: true,
                windowName: "terminal 6",
                isWindowActive: true,
                tmuxServerID: serverID
            )
            return LocalTmuxWindow(
                id: pane.windowId,
                sessionName: pane.sessionName,
                windowIndex: pane.windowIndex,
                windowName: pane.windowName,
                windowLayout: pane.windowLayout,
                isWindowActive: pane.isWindowActive,
                panes: [pane]
            )
        }
    }
#endif
