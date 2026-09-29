#if os(macOS)
    import ConcurrencyExtras
    import CryptoKit
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite("Raw terminal input transport")
    struct RawTerminalInputTests {
        @Test("Raw input is hex encoded without interpreting UTF8 or tmux syntax")
        func byteExactEncoding() {
            let bytes = Data([0x1b, 0x5b, 0x3c, 0x00, 0xff, 0x0a, 0x3b, 0x22])
            #expect(TmuxControlInputEncoder.commands(paneId: "%7", rawBytes: bytes) == [
                "send-keys -t %7 -H 1b 5b 3c 00 ff 0a 3b 22",
            ])
            #expect(TmuxControlInputEncoder.commands(paneId: "%7", rawBytes: Data()) == [])
        }

        @Test("Validate pane and byte budget before writing any raw input")
        func validatesWholeBatch() {
            for target in ["session:0.0", "%7; kill-server", "%7\n", "%", ""] {
                #expect(TmuxControlInputEncoder.commands(paneId: target, rawBytes: Data([1])) == nil)
            }
            let limit = TmuxControlInputEncoder.maximumHexBytes
            #expect(TmuxControlInputEncoder.commands(paneId: "%7", rawBytes: Data(repeating: 0, count: limit))?.count == 1)
            #expect(TmuxControlInputEncoder.commands(paneId: "%7", rawBytes: Data(repeating: 0, count: limit + 1)) == nil)
        }

        @Test("Raw fast path does not create a connection when none exists")
        func noConnection() async throws {
            let manager = TmuxControlClientManager(tmuxPath: "/must/not/run")
            let written = LockIsolated(false)
            let sent = try await manager.sendRawBytesIfConnected(
                paneId: "%7", sessionName: "missing", data: Data([0x1b]),
                onFirstCommandWritten: { written.setValue(true) }
            )
            #expect(!sent)
            #expect(!written.value)
        }

        @Test("Viewer falls back only on an explicit no-write result", arguments: [true, false])
        func viewerFallback(connected: Bool) async throws {
            let processes = LockIsolated<[[String]]>([])
            let calls = LockIsolated(0)
            let data = Data("\u{1b}[<64;3;4M".utf8)
            await withDependencies {
                $0[ProcessRunner.self].run = { _, args, _, _ in
                    processes.withValue { $0.append(args) }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            } operation: {
                let executor = TmuxCommandExecutor(tmuxService: TmuxService(tmuxPath: "/unused")) { pane, bytes in
                    #expect(pane == "%7")
                    #expect(bytes == data)
                    calls.withValue { $0 += 1 }
                    return connected
                }
                let response = await executor.execute(CommandMessage(paneId: "%7", command: SendRawInput(data: data).commandType))
                #expect(response.success)
            }
            #expect(calls.value == 1)
            let expected = ["send-keys", "-t", "%7", "-H"] + data.map { String(format: "%02x", $0) }
            #expect(processes.value == (connected ? [] : [expected]))
        }

        @Test("Disconnect after enqueue is ambiguous, not a safe pre-write failure")
        func disconnectDoesNotPermitReplay() async throws {
            let client = TmuxControlClient(tmuxPath: "/must/not/run")
            let pending = Task { try await client.testEnqueueCommand(id: 1) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await client.testPendingCommandCount == 0, ContinuousClock.now < deadline {
                await Task.yield()
            }
            #expect(await client.testPendingCommandCount == 1)
            await client.disconnect()
            do {
                _ = try await pending.value
                Issue.record("Pending command unexpectedly succeeded after disconnect")
            } catch TmuxControlError.processTerminated {
                // Correct: caller must not fall back and replay the input.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(await client.testPendingCommandCount == 0)
            do {
                _ = try await client.sendCommand("send-keys -t %7 -H 61")
                Issue.record("Disconnected pre-write command unexpectedly succeeded")
            } catch TmuxControlError.notConnected {
                // Correct: no write was attempted, so fallback is safe.
            }
        }

        @Test("Timeout, write failure and command rejection never replay input", arguments: [0, 1, 2])
        func ambiguousFailureDoesNotFallback(failure: Int) async {
            let processes = LockIsolated(0)
            await withDependencies {
                $0[ProcessRunner.self].run = { _, _, _, _ in
                    processes.withValue { $0 += 1 }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            } operation: {
                let executor = TmuxCommandExecutor(tmuxService: TmuxService(tmuxPath: "/unused")) { _, _ in
                    switch failure {
                    case 0: throw TmuxControlError.timeout
                    case 1: throw CocoaError(.fileWriteUnknown)
                    default: throw TmuxControlError.commandFailed(message: "rejected")
                    }
                }
                let response = await executor.execute(CommandMessage(paneId: "%7", command: SendRawInput(data: Data([0x1b])).commandType))
                #expect(!response.success)
            }
            #expect(processes.value == 0)
        }

        @Test("Local and viewer routes preserve rapid scroll, reversal, clicks and keys on real tmux", arguments: ["local", "viewer", "process"])
        func realTmuxInputOrder(transport: String) async throws {
            let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
            // Keep the Unix socket below Darwin's sockaddr_un path limit.
            let root = URL(fileURLWithPath: "/tmp/ctrlx-scroll-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let socket = root.appendingPathComponent("tmux.sock").path
            let runner = ProcessRunner.liveValue
            func run(_ args: [String]) async throws -> ProcessResult {
                try await runner.runOrThrow(executable: tmuxPath, arguments: ["-S", socket, "-f", "/dev/null"] + args)
            }
            // Exact byte reader, no Codex account, user shell or production tmux.
            let scrolls = (0..<120).map { index in
                Data("\u{1b}[<\(index < 60 ? 64 : 65);\(index % 9 + 1);4M".utf8)
            }
            let click = Data("\u{1b}[<0;3;4M\u{1b}[<0;3;4m".utf8)
            let prefix = Data("k".utf8)
            let suffix = Data("\u{1b}[1;2D".utf8)
            let expected = prefix + scrolls.reduce(Data(), +) + click + suffix
            let probe = "stty raw -echo; printf 'SCROLL_READY\\r\\n'; "
                + "dd bs=1 count=\(expected.count) 2>/dev/null | shasum -a 256; "
                + "printf '\\r\\nSCROLL_DONE\\r\\n'; exec /bin/cat"
            _ = try await run(["new-session", "-d", "-s", "fixture", "-x", "100", "-y", "24", "/bin/sh", "-c", probe])
            try await withDependencies {
                $0[ProcessRunner.self] = .liveValue
            } operation: {
                let tmux = TmuxService(tmuxPath: tmuxPath, socketPath: socket)
                let clients = TmuxControlClientManager(tmuxPath: tmuxPath, socketPath: socket)
                let streams = PaneStreamManager(tmuxService: tmux, controlClientManager: clients, fifoDirectory: root)
                do {
                    let pane = try #require(await tmux.refreshPanes().first)
                    try await waitForText("SCROLL_READY", tmux: tmux, pane: pane.paneId)
                    await streams.startMonitoring(panes: [pane])
                    _ = try await streams.subscribe(paneId: pane.paneId, target: pane.target, onData: { _ in })
                    let processes = LockIsolated(0)
                    let elapsed = try await withDependencies {
                        // Any process during the hot path is a regression; setup,
                        // capture and cleanup deliberately stay outside this scope.
                        $0[ProcessRunner.self].run = { executable, arguments, environment, timeout in
                            processes.withValue { $0 += 1 }
                            if transport == "process" {
                                return try await runner.run(executable, arguments, environment, timeout)
                            }
                            throw CocoaError(.fileReadUnknown)
                        }
                    } operation: {
                        // TmuxService captures its dependency at init, so use this
                        // scoped instance for the executor's fallback spy as well.
                        let inputTmux = TmuxService(tmuxPath: tmuxPath, socketPath: socket)
                        let executor = TmuxCommandExecutor(tmuxService: inputTmux) { pane, bytes in
                            try await streams.sendRawBytesIfConnected(paneId: pane, data: bytes)
                        }
                        let started = ContinuousClock.now
                        if transport == "process" {
                            try await inputTmux.sendKeystrokes(pane.paneId, keys: [.text("k")])
                        } else {
                            #expect(try await streams.sendKeystrokesIfConnected(paneId: pane.paneId, keys: [.text("k")]))
                        }
                        for bytes in scrolls + [click] {
                            if transport == "viewer" {
                                let command = CommandMessage(paneId: pane.paneId, command: SendRawInput(data: bytes).commandType)
                                let wire = try JSONEncoder().encode(command)
                                let response = await executor.execute(try JSONDecoder().decode(CommandMessage.self, from: wire))
                                #expect(response.success)
                            } else if transport == "process" {
                                try await inputTmux.sendRawBytes(pane.paneId, data: bytes)
                            } else {
                                #expect(try await streams.sendRawBytesIfConnected(paneId: pane.paneId, data: bytes))
                            }
                        }
                        if transport == "process" {
                            try await inputTmux.sendKeystrokes(pane.paneId, keys: TmuxKey.from(bytes: suffix))
                        } else {
                            #expect(try await streams.sendKeystrokesIfConnected(paneId: pane.paneId, keys: TmuxKey.from(bytes: suffix)))
                        }
                        return started.duration(to: .now)
                    }
                    #expect(processes.value == (transport == "process" ? 123 : 0))
                    try await waitForText("SCROLL_DONE", tmux: tmux, pane: pane.paneId)
                    let content = try await tmux.capturePaneText(pane.paneId, scrollback: true)
                    let digest = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
                    #expect(content.contains(digest))
                    let count = try await run(["list-clients", "-F", "#{client_control_mode}"])
                    #expect(count.stdoutString.split(separator: "\n").filter { $0 == "1" }.count == 1)
                    print("RAW_INPUT_PROBE transport=\(transport) batches=123 elapsed=\(elapsed) subprocesses=\(processes.value)")
                    if transport == "local" {
                        let written = LockIsolated(0)
                        do {
                            _ = try await clients.sendRawBytesIfConnected(
                                paneId: "%999999999", sessionName: pane.sessionName, data: click,
                                onFirstCommandWritten: { written.withValue { $0 += 1 } }
                            )
                            Issue.record("Rejected control command must throw, never permit fallback")
                        } catch TmuxControlError.commandFailed {
                            #expect(written.value == 1)
                        }
                    }
                } catch {
                    await streams.disconnectAll()
                    await clients.disconnectAll()
                    _ = try? await run(["kill-server"])
                    throw error
                }
                await streams.disconnectAll()
                await clients.disconnectAll()
                _ = try? await run(["kill-server"])
            }
        }

        private func waitForText(_ text: String, tmux: TmuxService, pane: String) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            repeat {
                if try await tmux.capturePaneText(pane, scrollback: true).contains(text) { return }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            throw TmuxControlError.timeout
        }
    }
#endif
