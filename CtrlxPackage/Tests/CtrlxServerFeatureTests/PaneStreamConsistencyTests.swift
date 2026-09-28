#if os(macOS)
    import CtrlxCommon
    import Dependencies
    import Foundation
    import SwiftTerm
    import Testing
    @testable import CtrlxServerFeature

    /// Exercise the real control protocol, not two independently mocked streams.
    /// Every test owns a private tmux server and a raw echo pane (no user shell rc).
    @Suite("Pane stream consistency", .serialized)
    @MainActor
    struct PaneStreamConsistencyTests {
        @Test("Stable pane targets share the discovery session's control connection")
        func stableTargetUsesOneConnection() async throws {
            try await withPane { fixture in
                await fixture.streams.startMonitoring(panes: [fixture.pane])
                let subscription = try await fixture.streams.subscribe(
                    paneId: fixture.pane.paneId,
                    target: fixture.pane.paneId,
                    onData: { _ in }
                )
                #expect(try await fixture.controlClientCount() == 1)
                await fixture.streams.unsubscribe(subscription.subscriptionId)
            }
        }

        @Test("On-demand subscription resolves a pane ID to its owning session")
        func onDemandUsesCanonicalSession() async throws {
            try await withPane { fixture in
                let subscription = try await fixture.streams.subscribe(
                    paneId: fixture.pane.paneId,
                    target: fixture.pane.paneId,
                    onData: { _ in }
                )
                _ = try await fixture.clients.getClient(for: fixture.pane.sessionName)
                #expect(try await fixture.controlClientCount() == 1)
                await fixture.streams.updateMonitoring(panes: [fixture.pane])
                await fixture.streams.unsubscribe(subscription.subscriptionId)
            }
        }

        @Test("Reopening a pane never delivers a non-idempotent update twice")
        func reopeningDoesNotDuplicateOutput() async throws {
            try await withPane { fixture in
                await fixture.streams.startMonitoring(panes: [fixture.pane])
                let first = try await fixture.streams.subscribe(
                    paneId: fixture.pane.paneId,
                    target: fixture.pane.paneId,
                    onData: { _ in }
                )
                await fixture.streams.unsubscribe(first.subscriptionId)

                let rendered = CapturedTerminal(cols: fixture.pane.width, rows: fixture.pane.height)
                let second = try await fixture.streams.subscribe(
                    paneId: fixture.pane.paneId,
                    target: fixture.pane.target,
                    onData: { rendered.feed($0) }
                )
                rendered.feed(second.initialContent)
                let update = "\r\nLIVE_ONCE\r\n"
                try await fixture.write(update)
                // Let both control readers drain, including the obsolete reader
                // that the old pane-ID/session-name mismatch left enabled.
                try await Task.sleep(for: .milliseconds(100))

                #expect(rendered.text.components(separatedBy: "LIVE_ONCE").count - 1 == 1)
                #expect(rendered.text == (try await fixture.visibleText()))
                #expect(try await fixture.controlClientCount() == 1)
                await fixture.streams.unsubscribe(second.subscriptionId)
            }
        }

        @Test("Concurrent first requests create exactly one session control client")
        func concurrentConnectionCreationIsCoalesced() async throws {
            try await withPane { fixture in
                let manager = fixture.clients
                let sessionName = fixture.pane.sessionName
                let clients = try await withThrowingTaskGroup(of: TmuxControlClient.self) { group in
                    for _ in 0..<8 {
                        group.addTask {
                            try await manager.getClient(for: sessionName)
                        }
                    }
                    var clients: [TmuxControlClient] = []
                    for try await client in group { clients.append(client) }
                    return clients
                }
                #expect(Set(clients.map(ObjectIdentifier.init)).count == 1)
                // Process.run() precedes tmux's attach handshake. Wait for a
                // real response before counting server-side registrations.
                if let client = clients.first {
                    _ = try await client.sendCommand("display-message -p CONNECTED")
                }
                #expect(try await fixture.controlClientCount() == 1)
                // Reap every returned child even when testing the broken code.
                var reaped = Set<ObjectIdentifier>()
                for client in clients where reaped.insert(ObjectIdentifier(client)).inserted {
                    await client.disconnect()
                }
            }
        }

        @Test("A failed capture list cannot consume the next command's response")
        func failedCommandListKeepsResponseAlignment() async throws {
            try await withPane { fixture in
                let client = try await fixture.clients.getClient(for: fixture.pane.sessionName)
                let responses = try await client.sendCommandList([
                    "display-message -p BEFORE_ERROR",
                    "capture-pane -p -t %2147483647",
                    "display-message -p MUST_BE_SKIPPED",
                ])
                #expect(responses.count == 2)
                #expect(responses.first?.output == "BEFORE_ERROR")
                #expect(responses.last?.isError == true)
                let next = try await client.sendCommand("display-message -p AFTER_ERROR")
                #expect(next.output == "AFTER_ERROR")
                #expect(!next.isError)
            }
        }

        @Test("Long output remains identical for simultaneous and newly joined subscribers")
        func longOutputHasNoGapsAcrossSnapshotBoundaries() async throws {
            try await withPane { fixture in
                await fixture.streams.startMonitoring(panes: [fixture.pane])
                let writer = Task { @MainActor in
                    for revision in 1...80 {
                        try Task.checkCancellation()
                        try await fixture.tmux.sendRawBytes(
                            fixture.pane.paneId,
                            data: Data("\r\nROW_\(revision) 中文内容".utf8)
                        )
                    }
                }
                do {
                    var terminals: [CapturedTerminal] = []
                    for _ in 0..<10 {
                        let rendered = CapturedTerminal(cols: fixture.pane.width, rows: fixture.pane.height)
                        let subscription = try await fixture.streams.subscribe(
                            paneId: fixture.pane.paneId, target: fixture.pane.paneId,
                            onData: { rendered.feed($0) }
                        )
                        rendered.feed(subscription.initialContent)
                        terminals.append(rendered)
                    }
                    try await writer.value
                    try await fixture.waitForText("ROW_80")
                    try await Task.sleep(for: .milliseconds(100))
                    let expected = try await fixture.visibleText()
                    for rendered in terminals { #expect(rendered.text == expected) }
                    #expect(try await fixture.controlClientCount() == 1)
                } catch {
                    writer.cancel()
                    _ = try? await writer.value
                    throw error
                }
            }
        }

        @Test("Joining during resync retains live output", arguments: ResyncTrigger.allCases, [false, true])
        func joiningDuringResync(trigger: ResyncTrigger, dimensionQueryFails: Bool) async throws {
            let gate = DimensionQueryGate()
            try await withPane(dimensionGate: gate) { fixture in
                let existing = CapturedTerminal(cols: fixture.pane.width, rows: fixture.pane.height)
                var resets = 0
                let first = try await fixture.streams.subscribe(
                    paneId: fixture.pane.paneId, target: fixture.pane.paneId,
                    onData: { existing.feed($0) },
                    onResync: { result in
                        if case let .success(snapshot) = result {
                            existing.replace(with: snapshot)
                            resets += 1
                        }
                    }
                )
                existing.feed(first.initialContent)
                await gate.arm(failOnResume: dimensionQueryFails)
                trigger.request(fixture, subscriptionId: first.subscriptionId)
                try await waitUntil { await gate.isPaused }

                // Complete the new subscriber's own snapshot while the older
                // resync still holds a pre-await copy of the reader context.
                let joining = CapturedTerminal(cols: fixture.pane.width, rows: fixture.pane.height)
                let second = try await fixture.streams.subscribe(
                    paneId: fixture.pane.paneId, target: fixture.pane.paneId,
                    onData: { joining.feed($0) },
                    onResync: { result in
                        if case let .success(snapshot) = result { joining.replace(with: snapshot) }
                    }
                )
                joining.feed(second.initialContent)
                #expect(joining.text == (try await fixture.visibleText()))
                // Output after the newcomer's snapshot but before the shared
                // resync boundary must not vanish when that boundary commits.
                try await fixture.write("\r\nDURING_RESYNC\r\n")
                await gate.release()
                try await waitUntil { resets > 0 }

                try await fixture.write("\r\nAFTER_RESYNC 中文输入\r\n")
                try await waitUntil { existing.text.contains("AFTER_RESYNC") && joining.text.contains("AFTER_RESYNC") }
                let expected = try await fixture.visibleText()
                #expect(existing.text == expected)
                #expect(joining.text == expected)
                #expect(joining.text.components(separatedBy: "AFTER_RESYNC").count - 1 == 1)
                await fixture.streams.unsubscribe(first.subscriptionId)
                await fixture.streams.unsubscribe(second.subscriptionId)
                #expect(!fixture.streams.hasActiveStream(paneId: fixture.pane.paneId))
            }
        }

        @Test("Resync preserves unsubscribe and title changes across await", arguments: [false, true])
        func leavingDuringResync(dimensionQueryFails: Bool) async throws {
            let gate = DimensionQueryGate()
            try await withPane(dimensionGate: gate) { fixture in
                var resets = 0
                var removedSubscriberCallbacks = 0
                let first = try await fixture.streams.subscribe(
                    paneId: fixture.pane.paneId, target: fixture.pane.paneId,
                    onData: { _ in },
                    onResync: { if case .success = $0 { resets += 1 } }
                )
                let leaving = try await fixture.streams.subscribe(
                    paneId: fixture.pane.paneId, target: fixture.pane.paneId,
                    onData: { _ in removedSubscriberCallbacks += 1 },
                    onResync: { _ in removedSubscriberCallbacks += 1 }
                )
                await gate.arm(failOnResume: dimensionQueryFails)
                fixture.streams.requestResync(subscriptionId: first.subscriptionId)
                try await waitUntil { await gate.isPaused }
                await fixture.streams.unsubscribe(leaving.subscriptionId)
                removedSubscriberCallbacks = 0
                fixture.streams.reportTitleChange(
                    paneId: fixture.pane.paneId, title: "CHANGED_DURING_RESYNC",
                    fromSubscription: first.subscriptionId
                )
                await gate.release()
                try await waitUntil { resets == 1 }

                #expect(fixture.streams.terminalTitle(for: fixture.pane.paneId) == "CHANGED_DURING_RESYNC")
                #expect(removedSubscriberCallbacks == 0)
                await fixture.streams.unsubscribe(first.subscriptionId)
                // A removed ID resurrected only in ReaderContext otherwise
                // leaves a ghost active stream with no callback or owner.
                #expect(!fixture.streams.hasActiveStream(paneId: fixture.pane.paneId))
                #expect(fixture.streams.activeStreamPaneIds.isEmpty)
            }
        }

        @Test("Shutdown during a suspended resync cannot publish a stale snapshot")
        func shutdownDuringResync() async throws {
            let gate = DimensionQueryGate()
            try await withPane(dimensionGate: gate) { fixture in
                var resets = 0
                let first = try await fixture.streams.subscribe(
                    paneId: fixture.pane.paneId, target: fixture.pane.paneId,
                    onData: { _ in }, onResync: { _ in resets += 1 }
                )
                await gate.arm()
                fixture.streams.requestResync(subscriptionId: first.subscriptionId)
                try await waitUntil { await gate.isPaused }
                let shutdown = Task { await fixture.streams.disconnectAll() }
                // Teardown cancels and drains the in-flight resync before
                // removing its reader. Do not release until cancellation wins.
                try await waitUntil { await gate.cancellationObserved }
                await gate.release()
                await shutdown.value
                #expect(resets == 0)
                #expect(fixture.streams.dimensions(for: fixture.pane.paneId) == nil)
            }
        }

        enum ResyncTrigger: CaseIterable, Sendable {
            case backpressure, resize

            @MainActor fileprivate func request(_ fixture: Fixture, subscriptionId: UUID) {
                switch self {
                case .backpressure:
                    fixture.streams.requestResync(subscriptionId: subscriptionId)
                case .resize:
                    fixture.streams.updateDimensions(
                        paneId: fixture.pane.paneId, width: fixture.pane.width + 1, height: fixture.pane.height
                    )
                }
            }
        }

        @Test("Continuous output survives overlapping bootstraps and repeated resyncs")
        func outputAcrossRepeatedResyncs() async throws {
            try await withPane { fixture in
                let firstTerminal = CapturedTerminal(cols: fixture.pane.width, rows: fixture.pane.height)
                let first = try await fixture.streams.subscribe(
                    paneId: fixture.pane.paneId, target: fixture.pane.paneId,
                    onData: { firstTerminal.feed($0) },
                    onResync: { result in
                        if case let .success(snapshot) = result { firstTerminal.replace(with: snapshot) }
                    }
                )
                firstTerminal.feed(first.initialContent)
                let writer = Task { @MainActor in
                    for revision in 1...80 {
                        try Task.checkCancellation()
                        try await fixture.tmux.sendRawBytes(
                            fixture.pane.paneId, data: Data("\r\nRESYNC_ROW_\(revision) 中文".utf8)
                        )
                        if revision.isMultiple(of: 4) {
                            fixture.streams.requestResync(subscriptionId: first.subscriptionId)
                        }
                    }
                }
                do {
                    var terminals = [firstTerminal]
                    for _ in 0..<10 {
                        let rendered = CapturedTerminal(cols: fixture.pane.width, rows: fixture.pane.height)
                        let subscription = try await fixture.streams.subscribe(
                            paneId: fixture.pane.paneId, target: fixture.pane.paneId,
                            onData: { rendered.feed($0) },
                            onResync: { result in
                                if case let .success(snapshot) = result { rendered.replace(with: snapshot) }
                            }
                        )
                        rendered.feed(subscription.initialContent)
                        terminals.append(rendered)
                    }
                    try await writer.value
                    try await fixture.write("\r\nCOMPOSER_READY\r\n")
                    try await waitUntil { terminals.allSatisfy { $0.text.contains("COMPOSER_READY") } }
                    let expected = try await fixture.visibleText()
                    for rendered in terminals { #expect(rendered.text == expected) }
                } catch {
                    writer.cancel()
                    _ = try? await writer.value
                    throw error
                }
            }
        }

        /// Suspend exactly one dimension response using the existing process
        /// dependency; snapshots, subscriptions and byte delivery remain real.
        private actor DimensionQueryGate {
            private var armed = false
            private var failOnResume = false
            private var continuation: CheckedContinuation<Void, Never>?
            var isPaused: Bool { continuation != nil }
            private(set) var cancellationObserved = false

            func arm(failOnResume: Bool = false) {
                armed = true
                self.failOnResume = failOnResume
            }

            func pauseIfArmed() async throws {
                guard armed else { return }
                armed = false
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation = $0 }
                } onCancel: {
                    Task { await self.recordCancellation() }
                }
                if failOnResume { throw FixtureError.dimensionQueryFailed }
            }

            private func recordCancellation() { cancellationObserved = true }

            func release() {
                armed = false
                continuation?.resume()
                continuation = nil
            }
        }

        private func waitUntil(_ predicate: @MainActor () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            repeat {
                if try await predicate() { return }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            throw FixtureError.outputTimeout
        }

        @Test("A changing screen and its cursor are captured from the same instant", arguments: [0, 1_000])
        func captureDoesNotMixCursorAndScreenRevisions(scrollback: Int) async throws {
            try await withPane { fixture in
                try await fixture.tmux.sendRawBytes(
                    fixture.pane.paneId, data: Data("\u{1b}[2J\u{1b}[2;1HFRAME".utf8)
                )
                try await fixture.waitForText("FRAME")
                let writer = Task { @MainActor in
                    for revision in 0..<80 {
                        try Task.checkCancellation()
                        let row = 2 + revision % 8
                        try await fixture.tmux.sendRawBytes(
                            fixture.pane.paneId,
                            data: Data("\u{1b}[2J\u{1b}[\(row);1HFRAME".utf8)
                        )
                    }
                }
                do {
                    for _ in 0..<80 {
                        let snapshot = try await fixture.tmux.capturePaneViaControlMode(
                            paneId: fixture.pane.paneId, width: fixture.pane.width, height: fixture.pane.height,
                            controlClientManager: fixture.clients, sessionName: fixture.pane.sessionName,
                            scrollbackLineLimit: scrollback
                        )
                        let rendered = CapturedTerminal(cols: fixture.pane.width, rows: fixture.pane.height)
                        rendered.feed(snapshot)
                        #expect(rendered.cursorLine == "FRAME")
                    }
                    try await writer.value
                } catch {
                    writer.cancel()
                    _ = try? await writer.value
                    throw error
                }
            }
        }

        private func withPane(
            dimensionGate: DimensionQueryGate? = nil,
            _ operation: @MainActor (Fixture) async throws -> Void
        ) async throws {
            let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
            let socketPath = "/tmp/ctrlx-consistency-\(UUID().uuidString.prefix(8)).sock"
            // tmux pane IDs restart at %0 on each server. A private socket
            // alone does NOT isolate the scan-only FIFO from a running CtrlX.
            let fifoDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ctrlx-consistency-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: fifoDirectory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: fifoDirectory) }
            try await withDependencies {
                let live = ProcessRunner.liveValue
                $0[ProcessRunner.self] = ProcessRunner(run: { executable, arguments, environment, timeout in
                    let result = try await live.run(executable, arguments, environment, timeout)
                    if arguments.last == "#{pane_width} #{pane_height}" {
                        try await dimensionGate?.pauseIfArmed()
                    }
                    return result
                })
            } operation: {
                let runner = ProcessRunner.liveValue
                func run(_ arguments: [String]) async throws -> ProcessResult {
                    try await runner.runOrThrow(
                        executable: tmuxPath,
                        arguments: ["-S", socketPath, "-f", "/dev/null"] + arguments
                    )
                }
                _ = try await run([
                    "new-session", "-d", "-s", "fixture", "-x", "40", "-y", "12",
                    "/bin/sh -c 'stty raw -echo; printf CTRLX_READY; exec /bin/cat'",
                ])
                let tmux = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
                let clients = TmuxControlClientManager(tmuxPath: tmuxPath, socketPath: socketPath)
                let streams = PaneStreamManager(
                    tmuxService: tmux, controlClientManager: clients, fifoDirectory: fifoDirectory
                )
                do {
                    let pane = try #require(await tmux.refreshPanes().first)
                    let fixture = Fixture(tmux: tmux, clients: clients, streams: streams, pane: pane,
                                          tmuxPath: tmuxPath, socketPath: socketPath)
                    try await fixture.waitForText("CTRLX_READY")
                    try await operation(fixture)
                } catch {
                    await dimensionGate?.release()
                    await streams.disconnectAll()
                    await clients.disconnectAll()
                    _ = try? await run(["kill-server"])
                    throw error
                }
                await dimensionGate?.release()
                await streams.disconnectAll()
                await clients.disconnectAll()
                _ = try await run(["kill-server"])
            }
        }

        @MainActor
        fileprivate struct Fixture {
            let tmux: TmuxService
            let clients: TmuxControlClientManager
            let streams: PaneStreamManager
            let pane: PaneInfo
            let tmuxPath: String
            let socketPath: String

            func controlClientCount() async throws -> Int {
                let result = try await ProcessRunner.liveValue.runOrThrow(
                    executable: tmuxPath,
                    arguments: ["-S", socketPath, "list-clients", "-F", "#{client_control_mode}"]
                )
                return result.stdoutString.split(separator: "\n").filter { $0 == "1" }.count
            }

            func write(_ text: String) async throws {
                try await tmux.sendRawBytes(pane.paneId, data: Data(text.utf8))
                try await waitForText(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            func visibleText() async throws -> String {
                try await tmux.capturePaneText(pane.paneId).trimmingCharacters(in: .newlines)
            }

            func waitForText(_ text: String) async throws {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                repeat {
                    if try await visibleText().contains(text) { return }
                    try await Task.sleep(for: .milliseconds(10))
                } while ContinuousClock.now < deadline
                throw FixtureError.outputTimeout
            }
        }

        private enum FixtureError: Error { case outputTimeout, dimensionQueryFailed }

        @MainActor
        private final class CapturedTerminal: TerminalDelegate {
            private lazy var terminal = Terminal(delegate: self)

            init(cols: Int, rows: Int) {
                terminal.resize(cols: cols, rows: rows)
            }

            func feed(_ data: Data) { terminal.feed(byteArray: Array(data)) }

            func replace(with snapshot: PaneStreamManager.SubscriptionResult) {
                terminal = Terminal(delegate: self)
                terminal.resize(cols: snapshot.width, rows: snapshot.height)
                feed(snapshot.initialContent)
            }

            var cursorLine: String {
                terminal.getLine(row: terminal.buffer.y)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true)
                    .trimmingCharacters(in: .whitespaces) ?? ""
            }

            var text: String {
                (0..<terminal.rows).compactMap { terminal.getLine(row: $0) }
                    .map {
                        $0.translateToString(trimRight: true, skipNullCellsFollowingWide: true)
                            .trimmingCharacters(in: .whitespaces)
                    }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .newlines)
            }

            nonisolated func send(source _: Terminal, data _: ArraySlice<UInt8>) { }
            nonisolated func showCursor(source _: Terminal) { }
            nonisolated func hideCursor(source _: Terminal) { }
            nonisolated func setTerminalTitle(source _: Terminal, title _: String) { }
            nonisolated func setTerminalIconTitle(source _: Terminal, title _: String) { }
            nonisolated func sizeChanged(source _: Terminal) { }
            nonisolated func scrolled(source _: Terminal, yDisp _: Int) { }
            nonisolated func hostCurrentDirectoryUpdated(source _: Terminal) { }
            nonisolated func hostCurrentDocumentUpdated(source _: Terminal) { }
        }
    }
#endif
