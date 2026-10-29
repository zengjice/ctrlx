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
    @Suite("Local terminal state publishing")
    struct LocalTerminalStatePublishingTests {
        private func pane(path: String = "/tmp") -> PaneInfo {
            PaneInfo(
                paneId: "%5",
                target: "work:0.0",
                sessionName: "work",
                windowIndex: 0,
                paneIndex: 0,
                command: "zsh",
                currentPath: path,
                width: 80,
                height: 24,
                isActive: true
            )
        }

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

        @Test("Unchanged pane metadata performs no observable write")
        func unchangedPaneMetadataIsNoop() async {
            let manager = makeWindowManager()
            #expect(manager.updatePaneStates(from: [pane()]))

            let invalidations = LockIsolated(0)
            withObservationTracking {
                _ = manager.paneStates
            } onChange: {
                invalidations.withValue { $0 += 1 }
            }

            #expect(!manager.updatePaneStates(from: [pane()]))
            await Task.megaYield()
            #expect(invalidations.value == 0)
        }

        @Test("Metadata changes publish once and preserve runtime state")
        func metadataChangePreservesRuntimeState() {
            let manager = makeWindowManager()
            manager.updatePaneStates(from: [pane()])
            manager.applyState(
                pluginID: "codex",
                sessionID: "session-1",
                state: .working,
                tmuxPane: "%5",
                projectPath: "/tmp"
            )

            #expect(manager.updatePaneStates(from: [pane(path: "/tmp/renamed")]))
            #expect(manager.paneStates["%5"]?.currentPath == "/tmp/renamed")
            #expect(manager.paneStates["%5"]?.agentSession?.state == .working)
        }

        @Test("Viewer snapshot does not invalidate host pane state")
        func viewerSnapshotIsPureRead() async {
            let manager = makeWindowManager()
            manager.updatePaneStates(from: [pane()])
            let invalidations = LockIsolated(0)
            withObservationTracking {
                _ = manager.paneStates
            } onChange: {
                invalidations.withValue { $0 += 1 }
            }

            let snapshot = HostSessionStateSnapshot.make(
                windowManager: manager,
                editorManager: manager.editorSessionManager
            )
            await Task.megaYield()

            #expect(Set(snapshot.keys) == Set(manager.paneStates.keys))
            #expect(invalidations.value == 0)
        }

        @Test("Unchanged tmux refresh does not publish observable state")
        func unchangedRefreshIsNoop() async {
            let separator = String(PaneInfo.fieldSeparator)
            let paneLine = [
                "%5", "work", "0", "0", "zsh", "/tmp", "80", "24",
                "1", "zsh", "layout", "terminal 1", "1", "", "", "",
            ].joined(separator: separator)

            await withDependencies {
                $0[ProcessRunner.self].run = { @Sendable _, arguments, _, _ in
                    if arguments.contains("list-clients") {
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
                    if arguments.contains("list-panes") {
                        return ProcessResult(
                            exitCode: 0,
                            stdout: Data("\(paneLine)\n".utf8),
                            stderr: Data()
                        )
                    }
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("unexpected".utf8))
                }
            } operation: {
                let service = TmuxService(tmuxPath: "/usr/bin/true")
                #expect(!service.containsSession(named: "work"))
                _ = await service.refreshPanes()
                #expect(service.containsSession(named: "work"))
                #expect(!service.containsSession(named: "missing"))
                service.resourceSessions = [.init(id: UUID(), name: "resources", directory: "/tmp")]
                #expect(service.containsSession(named: "resources"))
                service.resourceSessions = []
                #expect(!service.containsSession(named: "resources"))
                let invalidations = LockIsolated(0)
                withObservationTracking {
                    _ = service.panes
                    _ = service.attachedSessionNames
                    _ = service.isRefreshing
                    _ = service.lastError
                } onChange: {
                    invalidations.withValue { $0 += 1 }
                }

                _ = await service.refreshPanes()
                await Task.megaYield()
                #expect(invalidations.value == 0)
            }
        }

        @Test("Resize immediately refreshes the authoritative pane dimensions")
        func resizePublishesDimensions() async throws {
            let dimensions = LockIsolated((width: 80, height: 24))

            try await withDependencies {
                $0[ProcessRunner.self].run = { @Sendable _, arguments, _, _ in
                    if arguments.contains("resize-window") {
                        guard
                            let xIndex = arguments.firstIndex(of: "-x"),
                            let yIndex = arguments.firstIndex(of: "-y"),
                            arguments.indices.contains(xIndex + 1),
                            arguments.indices.contains(yIndex + 1),
                            let width = Int(arguments[xIndex + 1]),
                            let height = Int(arguments[yIndex + 1])
                        else {
                            return ProcessResult(
                                exitCode: 1,
                                stdout: Data(),
                                stderr: Data("invalid resize".utf8)
                            )
                        }
                        dimensions.withValue { $0 = (width, height) }
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
                    if arguments.contains("list-clients") {
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
                    if arguments.contains("list-panes") {
                        let current = dimensions.withValue { $0 }
                        let separator = String(PaneInfo.fieldSeparator)
                        let paneLine = [
                            "%5", "work", "0", "0", "zsh", "/tmp",
                            String(current.width), String(current.height),
                            "1", "zsh", "layout", "terminal 1", "1", "", "", "",
                        ].joined(separator: separator)
                        return ProcessResult(
                            exitCode: 0,
                            stdout: Data("\(paneLine)\n".utf8),
                            stderr: Data()
                        )
                    }
                    return ProcessResult(
                        exitCode: 1,
                        stdout: Data(),
                        stderr: Data("unexpected".utf8)
                    )
                }
            } operation: {
                let service = TmuxService(tmuxPath: "/usr/bin/true")
                _ = await service.refreshPanes()
                #expect(service.panes.first?.width == 80)
                #expect(service.panes.first?.height == 24)

                try await service.resizePane("%5", width: 132, height: 48)

                #expect(service.panes.first?.width == 132)
                #expect(service.panes.first?.height == 48)
            }
        }

        @Test("Empty background refresh does not replay initial loading state")
        func emptyBackgroundRefreshIsNoop() async {
            let service = TmuxService(tmuxPath: "/nonexistent/ctrlx-tmux")
            _ = await service.refreshPanes()

            let invalidations = LockIsolated(0)
            withObservationTracking {
                _ = service.panes
                _ = service.isRefreshing
                _ = service.lastError
            } onChange: {
                invalidations.withValue { $0 += 1 }
            }

            _ = await service.refreshPanes()
            await Task.megaYield()
            #expect(invalidations.value == 0)
        }
    }
#endif
