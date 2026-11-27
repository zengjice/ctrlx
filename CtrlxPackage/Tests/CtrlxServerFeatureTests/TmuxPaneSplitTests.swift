import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@Suite("Tmux pane split")
@MainActor
struct TmuxPaneSplitTests {
    @Test("Sized splits preserve the current window, directory and pane order", arguments: [false, true], [Double?.none, 1.0 / 6.0])
    func sizedSplit(horizontal: Bool, fraction: Double?) async throws {
        try await withDependencies { $0[ProcessRunner.self] = .liveValue } operation: {
            let socket = "/tmp/ctrlx-cmdt-\(UUID().uuidString.prefix(8)).sock"
            let service = TmuxService(tmuxPath: "/opt/homebrew/bin/tmux", socketPath: socket)
            defer { try? FileManager.default.removeItem(atPath: socket) }
            let directory = FileManager.default.temporaryDirectory
            let created = try await service.createSession(baseName: "ctrlx-cmdt-\(UUID().uuidString.prefix(8))", width: 121, height: 61, workingDirectory: directory.path)
            do {
                let before = await service.refreshPanes()
                let source = try #require(before.first { $0.paneId == created.paneId })
                let identity = try #require(source.workspaceIdentity)
                let executor = TmuxCommandExecutor(tmuxService: service)
                let command = CommandMessage(paneId: source.paneId, command: SplitTmuxPane(direction: horizontal ? .horizontal : .vertical, sizeFraction: fraction).commandType, expectedWorkspacePane: identity)
                let response = await executor.execute(command)
                try #require(response.success, Comment(rawValue: response.error ?? "Pane split failed"))
                let newID = try #require(response.paneId)
                #expect(try await waitForCurrentPath(of: newID, in: service, expected: directory) == directory.resolvingSymlinksInPath())
                let after = await service.refreshPanes()
                let old = try #require(after.first { $0.paneId == source.paneId })
                let new = try #require(after.first { $0.paneId == newID })
                #expect(new.stableWindowId == source.stableWindowId && old.stableWindowId == source.stableWindowId)
                #expect(new.isActive && !old.isActive)
                #expect(after.filter { $0.sessionName == created.sessionName }.count == 2)
                let originalSize = horizontal ? source.width : source.height
                let oldSize = horizontal ? old.width : old.height, newSize = horizontal ? new.width : new.height
                #expect(newSize == Int((Double(originalSize - 1) * (fraction ?? 0.5)).rounded()))
                #expect(oldSize + newSize + 1 == originalSize)
                #expect(fraction == nil ? oldSize == newSize : oldSize == 5 * newSize)
                let layout = try #require(TmuxLayoutParser.parse(new.windowLayout))
                let children: [LayoutNode]
                switch layout {
                case let .vertical(parts, _, _) where !horizontal: children = parts
                case let .horizontal(parts, _, _) where horizontal: children = parts
                default: throw TmuxError.commandFailed(message: "Unexpected split direction")
                }
                try #require(children.count == 2)
                if case let .pane(id, _, _) = children[0] {
                    #expect(source.paneId == "%\(id)")
                } else {
                    Issue.record("Original pane is missing from the first position")
                }
                if case let .pane(id, _, _) = children[1] {
                    #expect(newID == "%\(id)")
                } else {
                    Issue.record("New pane is missing from the second position")
                }
                try await service.killSession(created.sessionName)
            } catch {
                try? await service.killSession(created.sessionName)
                throw error
            }
        }
    }

    @Test("Invalid pane fractions are rejected before executing tmux")
    func invalidFraction() async throws {
        try await withDependencies {
            $0[ProcessRunner.self].run = { _, _, _, _ in
                Issue.record("Invalid split sizing executed a process")
                throw TmuxError.commandFailed(message: "Unexpected process")
            }
        } operation: {
            let service = TmuxService(tmuxPath: "/unused/tmux")
            for fraction in [Double.nan, .infinity, -.infinity, -0.1, 0, 1, 1.1] {
                do {
                    _ = try await service.splitPane("%1", horizontal: false, sizeFraction: fraction)
                    Issue.record("Invalid split sizing was accepted")
                } catch {
                    #expect(error.localizedDescription.contains("size fraction"))
                }
            }
        }
    }

    @Test("Window resize survives the targeted pane exiting")
    func resizeUsesStableWindowTarget() async throws {
        let tmuxPath = "/opt/homebrew/bin/tmux"
        try #require(FileManager.default.isExecutableFile(atPath: tmuxPath))

        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
        } operation: {
            let suffix = UUID().uuidString.lowercased()
            let sessionName = "ctrlx-resize-\(suffix)"
            let socketPath = "/tmp/gr-\(suffix.prefix(8)).sock"
            let service = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
            defer { try? FileManager.default.removeItem(atPath: socketPath) }

            let created = try await service.createSession(
                baseName: sessionName,
                width: 120,
                height: 40
            )
            do {
                let exitingPaneID = try await service.splitPane(created.paneId, horizontal: true)
                let panes = await service.refreshPanes()
                let window = try #require(
                    LocalTmuxWindow.groupPanes(panes).first { $0.sessionName == created.sessionName }
                )
                #expect(window.stableId.hasPrefix("@"))

                try await service.killPane(exitingPaneID)
                try await service.resizePane(window.stableId, width: 100, height: 30)

                let remaining = await service.refreshPanes()
                    .filter { $0.sessionName == created.sessionName }
                #expect(remaining.count == 1)
                #expect(remaining.first?.width == 100)
                #expect(remaining.first?.height == 30)

                try await service.killSession(created.sessionName)
            } catch {
                try? await service.killSession(created.sessionName)
                throw error
            }
        }
    }

    @Test("A new pane inherits the target path unless explicitly overridden")
    func inheritsTargetPath() async throws {
        let tmuxPath = "/opt/homebrew/bin/tmux"
        try #require(FileManager.default.isExecutableFile(atPath: tmuxPath))

        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
        } operation: {
            let suffix = UUID().uuidString.lowercased()
            let sessionName = "ctrlx-split-\(suffix)"
            let socketPath = "/tmp/gs-\(suffix.prefix(8)).sock"
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ctrlx-split-\(suffix)", isDirectory: true)
            let sourceURL = rootURL.appendingPathComponent("source", isDirectory: true)
            let overrideURL = rootURL.appendingPathComponent("override", isDirectory: true)
            let service = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)

            try FileManager.default.createDirectory(
                at: sourceURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: overrideURL,
                withIntermediateDirectories: true
            )
            defer {
                try? FileManager.default.removeItem(at: rootURL)
                try? FileManager.default.removeItem(atPath: socketPath)
            }

            let created = try await service.createSession(
                baseName: sessionName,
                width: 120,
                height: 40,
                workingDirectory: sourceURL.path
            )
            do {
                let sourcePath = try await waitForCurrentPath(
                    of: created.paneId,
                    in: service,
                    expected: sourceURL
                )
                try #require(sourcePath == sourceURL.resolvingSymlinksInPath())

                let inheritedPaneID = try await service.splitPane(
                    created.paneId,
                    horizontal: true
                )
                let inheritedPath = try await waitForCurrentPath(
                    of: inheritedPaneID,
                    in: service,
                    expected: sourceURL
                )
                #expect(inheritedPath == sourcePath)

                let overriddenPaneID = try await service.splitPane(
                    created.paneId,
                    horizontal: false,
                    workingDirectory: overrideURL.path
                )
                let overriddenPath = try await waitForCurrentPath(
                    of: overriddenPaneID,
                    in: service,
                    expected: overrideURL
                )
                #expect(overriddenPath == overrideURL.resolvingSymlinksInPath())

                try await service.killSession(created.sessionName)
            } catch {
                try? await service.killSession(created.sessionName)
                throw error
            }
        }
    }

    /// tmux acknowledges a split before the child has necessarily completed
    /// exec. macOS may briefly report an empty/stale cwd during that transition.
    /// Wait for the observable path, then let the caller assert the exact result.
    private func waitForCurrentPath(
        of paneID: String,
        in service: TmuxService,
        expected: URL
    ) async throws -> URL? {
        let expectedPath = expected.resolvingSymlinksInPath()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            let panes = await service.refreshPanes()
            let currentPath = panes.first { $0.paneId == paneID }
                .flatMap { pane -> URL? in
                    guard !pane.currentPath.isEmpty else { return nil }
                    return URL(fileURLWithPath: pane.currentPath).resolvingSymlinksInPath()
                }
            if currentPath == expectedPath || ContinuousClock.now >= deadline {
                return currentPath
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
