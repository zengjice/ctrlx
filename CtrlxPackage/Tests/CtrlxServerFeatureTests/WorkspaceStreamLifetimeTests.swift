import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct WorkspaceStreamLifetimeTests {
    @Test("Pane refresh restores clipboard forwarding without replacing the Viewer lease", arguments: [false, true])
    func clipboardAfterPipeDisconnect(unlinkFIFO: Bool) async throws {
        try await withFixture { fixture in
            let identity = try await fixture.createSession("clipboard")
            let lease = UUID()
            try await fixture.service.startStreaming(
                paneId: "%0", target: "%0", viewerId: "viewer", leaseId: lease,
                expectedWorkspacePane: identity
            )
            try await fixture.copy("BEFORE_DISCONNECT")
            try await fixture.waitUntil { fixture.sender.clipboards == ["BEFORE_DISCONNECT"] }
            let initialCount = fixture.sender.frames.filter(\.isInitial).count
            let fifo = try #require(FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "fifo" })

            // The tmux pipe can disappear without FileHandle delivering EOF.
            // An unlinked FIFO reproduces interference from another App launch.
            if unlinkFIFO {
                try FileManager.default.removeItem(at: fifo)
            }
            _ = try await fixture.run(["pipe-pane", "-t", "%0"])
            try await fixture.write("LIVE_WHILE_PIPE_IS_DOWN")
            try await fixture.waitUntil { fixture.sender.containsOutput("LIVE_WHILE_PIPE_IS_DOWN") }

            await fixture.panes.updateMonitoring(panes: await fixture.tmux.refreshPanes())
            try await fixture.waitUntil {
                try await fixture.run(["display-message", "-p", "-t", "%0", "#{pane_pipe}"])
                    .stdoutString.trimmingCharacters(in: .newlines) == "1"
            }
            try await fixture.copy("AFTER_RECOVERY", tmuxWrapped: true)
            try await fixture.waitUntil { fixture.sender.clipboards == ["BEFORE_DISCONNECT", "AFTER_RECOVERY"] }
            #expect(fixture.sender.frames.allSatisfy { $0.leaseId == lease })
            #expect(fixture.sender.frames.filter(\.isInitial).count == initialCount)
            #expect(!fixture.sender.frames.contains { $0.updateType == .streamEnd })
            #expect(fixture.service.isStreaming(paneId: "%0"))
        }
    }

    @Test("Refreshing a healthy scanner keeps its FIFO and clipboard subscription")
    func healthyClipboardReader() async throws {
        try await withFixture { fixture in
            let identity = try await fixture.createSession("clipboard")
            try await fixture.service.startStreaming(
                paneId: "%0", target: "%0", viewerId: "viewer", leaseId: UUID(),
                expectedWorkspacePane: identity
            )
            try await fixture.copy("BEFORE_REFRESH")
            try await fixture.waitUntil { fixture.sender.clipboards == ["BEFORE_REFRESH"] }
            let fifo = try #require(FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "fifo" })
            let inode = try FileManager.default.attributesOfItem(atPath: fifo.path)[.systemFileNumber] as? NSNumber
            await fixture.panes.updateMonitoring(panes: await fixture.tmux.refreshPanes())
            #expect(try FileManager.default.attributesOfItem(atPath: fifo.path)[.systemFileNumber] as? NSNumber == inode)
            try await fixture.copy("AFTER_REFRESH")
            try await fixture.waitUntil { fixture.sender.clipboards == ["BEFORE_REFRESH", "AFTER_REFRESH"] }
        }
    }

    @Test("A reconnected control client cannot feed a reader from the previous server", arguments: [false, true])
    func reconnectOutput(guarded: Bool) async throws {
        try await withFixture { fixture in
            let original = try await fixture.createSession("same")
            var oldBytes = Data()
            let old = try await fixture.panes.subscribe(
                paneId: "%0", target: "%0", expectedWorkspacePane: guarded ? original : nil,
                onData: { oldBytes.append($0) }
            )
            _ = try await fixture.run(["kill-server"])
            let restored = try await fixture.createSession("same")
            try await fixture.waitUntil {
                (try? await fixture.clients.serverIdentity(for: "same")) == restored.serverID
            }
            try await fixture.write("NEW_SERVER")
            try await Task.sleep(for: .milliseconds(100))
            #expect(!String(decoding: oldBytes, as: UTF8.self).contains("NEW_SERVER"))
            #expect(await fixture.panes.currentContent(for: "%0") == nil)

            var freshBytes = Data()
            let fresh = try await fixture.panes.subscribe(
                paneId: "%0", target: "%0", expectedWorkspacePane: guarded ? restored : nil,
                onData: { freshBytes.append($0) }
            )
            #expect(String(decoding: fresh.initialContent, as: UTF8.self).contains("NEW_SERVER"))
            await fixture.panes.unsubscribe(old.subscriptionId)
            try await fixture.write("STILL_STREAMING")
            try await fixture.waitUntil { String(decoding: freshBytes, as: UTF8.self).contains("STILL_STREAMING") }
            #expect(!String(decoding: oldBytes, as: UTF8.self).contains("STILL_STREAMING"))

            var sideEffects = 0
            fixture.panes.onNotification = { _, _ in sideEffects += 1 }
            fixture.panes.onTitleChange = { _, _, _ in sideEffects += 1 }
            fixture.panes.onProgress = { _, _ in sideEffects += 1 }
            let obsolete = PipePaneReader(paneId: "%0", fifoDirectory: fixture.root)
            fixture.panes.pipePaneReader(obsolete, paneId: "%0", didReceiveTitle: "STALE")
            fixture.panes.pipePaneReader(obsolete, paneId: "%0", didReceiveNotification: .init(body: "STALE"))
            fixture.panes.pipePaneReader(obsolete, paneId: "%0", didReceiveProgress: .removed)
            #expect(sideEffects == 0)
            let stalePane = PaneInfo(
                paneId: "%0", target: "same:0.0", sessionName: "same", windowIndex: 0,
                tmuxWindowId: "@0", paneIndex: 0, command: "cat", currentPath: "/tmp",
                width: 15, height: 4, isActive: true, paneTitle: "STALE_TITLE",
                workspaceIdentity: guarded ? original : nil, tmuxServerID: original.serverID
            )
            await fixture.panes.updateMonitoring(panes: [stalePane])
            #expect(fixture.panes.dimensions(for: "%0")?.width == 100)
            #expect(fixture.panes.terminalTitle(for: "%0") != "STALE_TITLE")
            #expect(sideEffects == 0)
            await fixture.panes.unsubscribe(fresh.subscriptionId)
        }
    }

    @Test("A restored stream resolves its new session without discovery or the old session route")
    func renamedRestoredSession() async throws {
        try await withFixture { fixture in
            let original = try await fixture.createSession("before")
            let oldLease = UUID()
            try await fixture.service.startStreaming(paneId: "%0", target: "%0", viewerId: "viewer", leaseId: oldLease, expectedWorkspacePane: original)
            _ = try await fixture.run(["kill-server"])
            let restored = try await fixture.createSession("after")
            let newLease = UUID()
            try await fixture.service.startStreaming(paneId: "%0", target: "%0", viewerId: "viewer", leaseId: newLease, expectedWorkspacePane: restored)
            #expect(fixture.service.isStreaming(paneId: "%0"))
            #expect(fixture.sender.frames.contains { $0.leaseId == newLease && $0.isInitial })
            #expect(fixture.sender.frames.contains { $0.leaseId == oldLease && $0.updateType == .streamEnd })
            await fixture.service.stopStreaming(paneId: "%0", viewerId: "viewer", leaseId: oldLease)
            try await fixture.write("RESTORED_LIVE")
            try await fixture.waitUntil {
                fixture.sender.frames.filter { $0.leaseId == newLease }.contains {
                    guard case let .dataChunk(chunk) = $0.updateType, let data = chunk.data else { return false }
                    return String(decoding: data, as: UTF8.self).contains("RESTORED_LIVE")
                }
            }
        }
    }

    @Test("Destroying a native terminal before bootstrap does not leave a subscription behind")
    func cancelledNativeBootstrap() async throws {
        try await withFixture { fixture in
            let identity = try await fixture.createSession("same")
            let coordinator = TerminalContainerView.Coordinator()
            var connected = false
            coordinator.start(
                paneState: .init(paneId: "%0", sessionName: "same", tmuxWindowId: "@0", workspaceIdentity: identity),
                tmuxService: fixture.tmux, paneStreamManager: fixture.panes, settings: AppSettings(),
                onStateChange: {
                    state, _, _ in if state == .connected {
                        connected = true
                    }
                },
                onTitleChange: nil
            )
            coordinator.stop()
            _ = try await fixture.clients.serverIdentity(for: "same")
            try await Task.sleep(for: .milliseconds(100))
            #expect(!connected)
            #expect(!fixture.panes.hasActiveStream(paneId: "%0"))
        }
    }

    @Test("Stopping an old OSC reader cannot detach the replacement pipe or delete its FIFO")
    func obsoleteReaderStop() async throws {
        try await withFixture { fixture in
            let original = try await fixture.createSession("same")
            let old = PipePaneReader(paneId: "%0", fifoDirectory: fixture.root)
            try await old.startPipePane(controlClientManager: fixture.clients, sessionName: "same", expectedServerID: original.serverID)
            _ = try await fixture.run(["kill-server"])
            let restored = try await fixture.createSession("same")
            try await fixture.waitUntil { (try? await fixture.clients.serverIdentity(for: "same")) == restored.serverID }
            let fresh = PipePaneReader(paneId: "%0", fifoDirectory: fixture.root)
            let sink = SideEffects()
            await fresh.setDelegate(sink)
            do {
                try await fresh.startPipePane(controlClientManager: fixture.clients, sessionName: "same", expectedServerID: restored.serverID)
                await old.stopPipePane(controlClientManager: fixture.clients, sessionName: "same")
                let path = await fresh.testFifoPath
                #expect(FileManager.default.fileExists(atPath: path))
                #expect(await fresh.isHealthy)
                let pipe = try await fixture.run(["display-message", "-p", "-t", "%0", "#{pane_pipe}"])
                #expect(pipe.stdoutString.trimmingCharacters(in: .newlines) == "1")
                try await fixture.tmux.sendRawBytes("%0", data: Data("\u{1B}]0;STILL_SCANNING\u{7}".utf8))
                try await fixture.waitUntil { sink.titles.contains("STILL_SCANNING") }
            } catch {
                await old.stopPipePane(controlClientManager: fixture.clients, sessionName: "same")
                await fresh.stopPipePane(controlClientManager: fixture.clients, sessionName: "same")
                throw error
            }
            await fresh.stopPipePane(controlClientManager: fixture.clients, sessionName: "same")
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let path = try #require(TmuxBinaryLocator.liveValue.find())
        let root = URL(fileURLWithPath: "/tmp/ctrlx-stream-lifetime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0.continuousClock = ContinuousClock()
        } operation: {
            let fixture = Fixture(path: path, root: root)
            do { try await body(fixture) }
            catch {
                await fixture.stop()
                throw error
            }
            await fixture.stop()
        }
    }

    @MainActor
    final private class Fixture {
        let path: String
        let root: URL
        let socket: String
        let tmux: TmuxService
        let clients: TmuxControlClientManager
        let panes: PaneStreamManager
        let sender = Sender()
        let service: TerminalStreamService
        let persistentPaneID = UUID()

        init(path: String, root: URL) {
            self.path = path
            self.root = root
            self.socket = root.appendingPathComponent("tmux.sock").path
            self.tmux = TmuxService(tmuxPath: path, socketPath: socket)
            self.clients = TmuxControlClientManager(tmuxPath: path, socketPath: socket)
            self.panes = PaneStreamManager(tmuxService: tmux, controlClientManager: clients, fifoDirectory: root)
            self.service = TerminalStreamService(streamSender: sender, paneStreamManager: panes)
        }

        func run(_ args: [String]) async throws -> ProcessResult {
            try await ProcessRunner.liveValue.runOrThrow(
                executable: path, arguments: ["-S", socket, "-f", "/dev/null"] + args,
                environment: ["TMUX": "", "TMUX_PANE": ""], timeout: 10
            )
        }

        func createSession(_ name: String) async throws -> WorkspacePaneIdentity {
            _ = try await run(["new-session", "-d", "-s", name, "-x", "100", "-y", "24", "/bin/sh -c 'stty raw -echo; printf READY; exec /bin/cat'"])
            _ = try await run(["set-option", "-p", "-t", "%0", WorkspaceTmuxRecovery.paneKey, persistentPaneID.uuidString])
            try await waitUntil { try await self.tmux.capturePaneText("%0").contains("READY") }
            let server = try await run(["display-message", "-p", "-t", "%0", "#{pid}:#{start_time}"])
            return .init(serverID: server.stdoutString.trimmingCharacters(in: .newlines), sessionID: UUID(), windowID: UUID(), paneID: persistentPaneID)
        }

        func write(_ text: String) async throws {
            try await tmux.sendRawBytes("%0", data: Data(text.utf8))
            try await waitUntil { try await self.tmux.capturePaneText("%0").contains(text) }
        }

        func copy(_ text: String, tmuxWrapped: Bool = false) async throws {
            let encoded = Data(text.utf8).base64EncodedString()
            let sequence = tmuxWrapped
                ? "\u{1B}Ptmux;\u{1B}\u{1B}]52;c;\(encoded)\u{7}\u{1B}\\"
                : "\u{1B}]52;c;\(encoded)\u{7}"
            try await tmux.sendRawBytes("%0", data: Data(sequence.utf8))
        }

        func waitUntil(_ predicate: () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if try await predicate() {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw Timeout.waitingForStream
        }

        func stop() async {
            await service.stopAllStreams()
            await panes.disconnectAll()
            await clients.disconnectAll()
            _ = try? await run(["kill-server"])
        }
    }

    private enum Timeout: Error { case waitingForStream }

    @MainActor
    final private class Sender: TerminalStreamSending {
        var frames: [TerminalStreamMessage] = []

        var clipboards: [String] {
            frames.compactMap {
                guard case let .clipboardUpdate(update) = $0.updateType else { return nil }
                return update.content
            }
        }

        func containsOutput(_ text: String) -> Bool {
            let bytes = frames.reduce(into: Data()) { output, message in
                if case let .dataChunk(chunk) = message.updateType, let data = chunk.data {
                    output.append(data)
                }
            }
            return String(decoding: bytes, as: UTF8.self).contains(text)
        }

        func sendTerminalStream(_ message: TerminalStreamMessage, to viewers: Set<String>, leaseIDs: [String: UUID]) async {
            for viewer in viewers {
                frames.append(message.withLeaseId(leaseIDs[viewer]))
            }
        }
    }

    @MainActor
    final private class SideEffects: PipePaneReaderDelegate {
        var titles: [String] = []
        func pipePaneReader(_: PipePaneReader, paneId _: String, didReceiveTitle title: String) {
            titles.append(title)
        }

        func pipePaneReader(_: PipePaneReader, paneId _: String, didReceiveNotification _: TerminalStreamMessage.TerminalNotification) { }
        func pipePaneReader(_: PipePaneReader, paneId _: String, didReceiveClipboard _: String) { }
        func pipePaneReader(_: PipePaneReader, paneId _: String, didReceiveProgress _: TerminalProgressState) { }
        func pipePaneReader(_: PipePaneReader, paneId _: String, didTerminate _: PipePaneReaderTermination) { }
    }
}

private extension TerminalStreamMessage {
    var isInitial: Bool {
        if case .initialState = updateType {
            return true
        }
        return false
    }
}
