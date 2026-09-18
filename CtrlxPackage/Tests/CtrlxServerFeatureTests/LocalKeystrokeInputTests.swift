#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import ConcurrencyExtras
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    /// Covers the local-typing keystroke path that fixed Option-Backspace
    /// (PR #593). SwiftTerm delivers a Meta/Option sequence as two synchronous
    /// `send()` callbacks (ESC, then the key). The coalescer merges them into one
    /// batch, and `TmuxService.sendKeystrokes` turns that batch into a single
    /// `send-keys Escape BSpace` (contiguous `\u{1b}\u{7f}`) — sent one-by-one the
    /// app only deletes a character instead of a word.
    @MainActor
    struct LocalKeystrokeInputTests {
        @Test("Control mode encodes literal text as hex")
        func controlModeEncodesLiteralTextAsHex() {
            let commands = TmuxControlInputEncoder.commands(
                paneId: "%7",
                keys: [.text("a;\n中")]
            )

            #expect(commands == ["send-keys -t %7 -H 61 3b 0a e4 b8 ad"])
        }

        @Test("Modified arrows survive parsing, wire transport and both tmux input paths",
              arguments: ["A", "B", "C", "D"], 2 ... 8)
        func modifiedArrowsReachTmux(direction: String, modifier: Int) async throws {
            let sequence = "\u{1B}[1;\(modifier)\(direction)"
            let wire = try JSONEncoder().encode(TmuxKey.from(bytes: Data(sequence.utf8)))
            let keys = try JSONDecoder().decode([TmuxKey].self, from: wire)
            let hex = sequence.utf8.map { String(format: "%02x", $0) }.joined(separator: " ")
            #expect(TmuxControlInputEncoder.commands(paneId: "%7", keys: keys) == [
                "send-keys -t %7 -H \(hex)",
            ])

            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { @Sendable _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                try await tmux.sendKeystrokes("%7", keys: keys)
            }
            #expect(commands.value.filter { $0.contains("send-keys") } == [
                ["send-keys", "-t", "%7", "-l", "--", sequence],
            ])
        }

        @Test("Control mode keeps split Option-Backspace in one named command")
        func controlModeKeepsOptionBackspaceTogether() {
            let commands = TmuxControlInputEncoder.commands(
                paneId: "%7",
                keys: [.escape, .backspace]
            )

            #expect(commands == ["send-keys -t %7 Escape BSpace"])
        }

        @Test("Control mode preserves mixed input order")
        func controlModePreservesMixedInputOrder() {
            let commands = TmuxControlInputEncoder.commands(
                paneId: "%7",
                keys: [.text("a"), .left, .text("b"), .ctrl("c"), .alt("d"), .ctrlAlt("x")]
            )

            #expect(commands == [
                "send-keys -t %7 -H 61",
                "send-keys -t %7 Left",
                "send-keys -t %7 -H 62 03 1b 64 1b 18",
            ])
        }

        @Test("Control mode declines unsafe or heavyweight batches")
        func controlModeDeclinesFallbackCases() {
            #expect(TmuxControlInputEncoder.commands(paneId: "session:0.0", keys: [.text("a")]) == nil)
            #expect(TmuxControlInputEncoder.commands(paneId: "%7", keys: [.ctrl("中")]) == nil)
            #expect(TmuxControlInputEncoder.commands(paneId: "%7", keys: [.delay(1)]) == nil)
            #expect(
                TmuxControlInputEncoder.commands(
                    paneId: "%7",
                    keys: Array(repeating: .ctrl("a"), count: TmuxControlInputEncoder.maximumHexBytes + 1)
                ) == nil
            )
            #expect(
                TmuxControlInputEncoder.commands(
                    paneId: "%7",
                    keys: [.text(String(repeating: "a", count: TmuxControlInputEncoder.maximumHexBytes + 1))]
                ) == nil
            )
        }

        @Test("Control manager declines input without creating a connection")
        func controlManagerDeclinesWithoutConnection() async throws {
            let manager = TmuxControlClientManager(tmuxPath: "/path/that/must/not/run")

            let sent = try await manager.sendKeystrokesIfConnected(
                paneId: "%7",
                sessionName: "missing",
                keys: [.text("a")]
            )

            #expect(!sent)
        }

        @Test("Control manager sends input through an existing tmux connection")
        func controlManagerUsesExistingConnection() async throws {
            let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
            let suffix = UUID().uuidString.lowercased()
            let socketPath = "/tmp/ctrlx-input-\(suffix.prefix(8)).sock"
            let sessionName = "ctrlx-input-\(suffix)"
            defer { killTmuxServer(tmuxPath: tmuxPath, socketPath: socketPath) }

            try await withDependencies {
                $0[ProcessRunner.self] = .liveValue
            } operation: {
                let tmux = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
                let created = try await tmux.createSession(
                    baseName: sessionName,
                    width: 80,
                    height: 24
                )
                let manager = TmuxControlClientManager(tmuxPath: tmuxPath, socketPath: socketPath)
                try await manager.registerPaneDimensions(
                    paneId: created.paneId,
                    sessionName: created.sessionName,
                    dimensions: (80, 24)
                )

                let sent = try await manager.sendKeystrokesIfConnected(
                    paneId: created.paneId,
                    sessionName: created.sessionName,
                    keys: [.text("printf '\\nCTRLX_%s_OK\\n' STAGE18"), .enter]
                )

                #expect(sent)
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                var content = ""
                repeat {
                    content = try await tmux.capturePaneText(created.paneId, scrollback: true)
                    if content.contains("CTRLX_STAGE18_OK") { break }
                    await Task.yield()
                } while ContinuousClock.now < deadline
                #expect(content.contains("CTRLX_STAGE18_OK"))

                await manager.disconnectAll()
                try await tmux.killSession(created.sessionName)
            }
        }

        @Test("Keys enqueued in the same runloop turn coalesce into one batch")
        func coalescesSameTurnEnqueues() async {
            await withMainSerialExecutor {
                let batches = LockIsolated<[[TmuxKey]]>([])
                let coalescer = KeystrokeCoalescer { batch in
                    batches.withValue { $0.append(batch.keys) }
                }

                // SwiftTerm emits Option-Backspace as two synchronous callbacks.
                coalescer.enqueue([.escape])
                coalescer.enqueue([.backspace])
                await Task.megaYield()

                #expect(batches.value == [[.escape, .backspace]])
            }
        }

        @Test("Keys enqueued in separate runloop turns flush independently")
        func separateTurnsFlushSeparately() async {
            await withMainSerialExecutor {
                let batches = LockIsolated<[[TmuxKey]]>([])
                let coalescer = KeystrokeCoalescer { batch in
                    batches.withValue { $0.append(batch.keys) }
                }

                coalescer.enqueue([.text("a")])
                await Task.megaYield()
                coalescer.enqueue([.text("b")])
                await Task.megaYield()

                // Distinct presses land in their own turns — never merged.
                #expect(batches.value == [[.text("a")], [.text("b")]])
            }
        }

        @Test("flushPending drains buffered keys synchronously before the scheduled turn")
        func flushPendingDrainsImmediately() async {
            await withMainSerialExecutor {
                let batches = LockIsolated<[[TmuxKey]]>([])
                let coalescer = KeystrokeCoalescer { batch in
                    batches.withValue { $0.append(batch.keys) }
                }

                // A key buffered earlier in this turn must flush before a
                // following raw event is chained, keeping input FIFO.
                coalescer.enqueue([.escape])
                coalescer.flushPending()

                // The flush happened synchronously, not on the next turn.
                #expect(batches.value == [[.escape]])

                // The already-scheduled flush fires but finds an empty buffer:
                // it must not emit a second (empty) batch.
                await Task.megaYield()
                #expect(batches.value == [[.escape]])
            }
        }

        @Test("flushPending is a no-op when nothing is buffered")
        func flushPendingNoopWhenEmpty() async {
            await withMainSerialExecutor {
                let batches = LockIsolated<[[TmuxKey]]>([])
                let coalescer = KeystrokeCoalescer { batch in
                    batches.withValue { $0.append(batch.keys) }
                }

                coalescer.flushPending()
                await Task.megaYield()

                #expect(batches.value.isEmpty)
            }
        }

        @Test("sendKeystrokes batches a coalesced run into one send-keys invocation")
        func sendKeystrokesBatchesNamedKeys() async throws {
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { @Sendable _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                // The coalesced Option-Backspace batch must go out as a single
                // `send-keys Escape BSpace`, not two separate invocations.
                try await tmux.sendKeystrokes("%1", keys: [.escape, .backspace])
            }

            let sendKeysCalls = commands.value.filter { $0.contains("send-keys") }
            #expect(sendKeysCalls.count == 1)
            let args = try #require(sendKeysCalls.first)
            let escape = try #require(args.firstIndex(of: "Escape"))
            let bspace = try #require(args.firstIndex(of: "BSpace"))
            #expect(escape < bspace)
        }

        @Test("sendKeystrokes preserves delayed sequence boundaries")
        func sendKeystrokesPreservesDelays() async throws {
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { @Sendable _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                try await tmux.sendKeystrokes("%1", keys: [.text("choice"), .delay(1), .enter])
            }

            let sendKeysCalls = commands.value.filter { $0.contains("send-keys") }
            #expect(sendKeysCalls == [
                ["send-keys", "-t", "%1", "-l", "--", "choice"],
                ["send-keys", "-t", "%1", "Enter"],
            ])
        }

        @Test("Process path terminates options before literal input")
        func processPathTerminatesOptionsBeforeLiteralInput() async throws {
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { @Sendable _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                let input = "sudo scutil --set HostName -n"
                try await tmux.sendKeystrokes("%1", keys: TmuxKey.from(bytes: Data(input.utf8)))
            }

            let literalCalls = commands.value.filter { $0.contains("-l") }
            #expect(literalCalls == [
                ["send-keys", "-t", "%1", "-l", "--", "sudo"],
                ["send-keys", "-t", "%1", "-l", "--", "scutil"],
                ["send-keys", "-t", "%1", "-l", "--", "--set"],
                ["send-keys", "-t", "%1", "-l", "--", "HostName"],
                ["send-keys", "-t", "%1", "-l", "--", "-n"],
            ])
        }

        @Test("Process path pastes leading hyphen arguments into an isolated tmux pane")
        func processPathPastesLeadingHyphenArguments() async throws {
            let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
            let suffix = UUID().uuidString.lowercased()
            let socketPath = "/tmp/ctrlx-paste-\(suffix.prefix(8)).sock"
            let sessionName = "ctrlx-paste-\(suffix)"
            defer { killTmuxServer(tmuxPath: tmuxPath, socketPath: socketPath) }

            try await withDependencies {
                $0[ProcessRunner.self] = .liveValue
            } operation: {
                let tmux = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
                let created = try await tmux.createSession(
                    baseName: sessionName,
                    width: 80,
                    height: 24,
                    runCommand: "cat"
                )
                let input = "sudo scutil --set HostName -n"

                try await tmux.sendKeystrokes(
                    created.paneId,
                    keys: TmuxKey.from(bytes: Data(input.utf8))
                )

                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                var content = ""
                repeat {
                    content = try await tmux.capturePaneText(created.paneId, scrollback: true)
                    if content.contains(input) { break }
                    await Task.yield()
                } while ContinuousClock.now < deadline
                #expect(content.contains(input))

                try await tmux.killSession(created.sessionName)
            }
        }

        @Test("An isolated tmux PTY receives modified arrows verbatim", arguments: [false, true])
        func modifiedArrowsReachRealPTY(useControlMode: Bool) async throws {
            let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
            let socketPath = "/tmp/ctrlx-arrows-\(UUID().uuidString.prefix(8)).sock"
            defer { killTmuxServer(tmuxPath: tmuxPath, socketPath: socketPath) }

            try await withDependencies {
                $0[ProcessRunner.self] = .liveValue
                $0.continuousClock = ContinuousClock()
            } operation: {
                let tmux = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
                // Start the byte reader directly, without a login shell or
                // the user's tmux config/history. Readiness is real PTY output,
                // never an echoed command line containing the marker.
                let probe = "stty raw -echo; printf 'ARROW_READY\\r\\n'; "
                    + "dd bs=1 count=24 2>/dev/null | od -An -tx1; "
                    + "printf '\\r\\nARROW_DONE\\r\\n'; cat"
                let created = try await ProcessRunner.liveValue.run(
                    tmuxPath,
                    ["-f", "/dev/null", "-S", socketPath, "new-session", "-d", "-s", "arrows",
                     "-x", "100", "-y", "24", "-P", "-F", "#{pane_id}", "/bin/sh", "-c", probe],
                    nil, 5
                )
                try #require(created.exitCode == 0)
                let paneId = created.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                // Even a conflicting root binding must not intercept direct
                // pane injection. Never attach to or send input to user panes.
                let bound = try await ProcessRunner.liveValue.run(
                    tmuxPath, ["-S", socketPath, "bind-key", "-n", "S-Left", "previous-window"], nil, 5
                )
                #expect(bound.exitCode == 0)
                let manager = TmuxControlClientManager(tmuxPath: tmuxPath, socketPath: socketPath)
                if useControlMode {
                    try await manager.registerPaneDimensions(
                        paneId: paneId, sessionName: "arrows", dimensions: (100, 24)
                    )
                }

                let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                var content = ""
                repeat {
                    content = try await tmux.capturePaneText(paneId, scrollback: true)
                    if content.contains("ARROW_READY") { break }
                    await Task.yield()
                } while ContinuousClock.now < readyDeadline
                try #require(content.contains("ARROW_READY"))

                let sequence = ["D", "C", "A", "B"].map { "\u{1B}[1;2\($0)" }.joined()
                let keys = TmuxKey.from(bytes: Data(sequence.utf8))
                if useControlMode {
                    let sent = try await manager.sendKeystrokesIfConnected(
                        paneId: paneId, sessionName: "arrows", keys: keys
                    )
                    #expect(sent)
                } else {
                    try await tmux.sendKeystrokes(paneId, keys: keys)
                }

                let outputDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                repeat {
                    content = try await tmux.capturePaneText(paneId, scrollback: true)
                    if content.contains("ARROW_DONE") { break }
                    await Task.yield()
                } while ContinuousClock.now < outputDeadline
                let hex = sequence.utf8.map { String(format: "%02x", $0) }.joined(separator: " ")
                #expect(content.split(whereSeparator: \.isWhitespace).joined(separator: " ").contains(hex))
                #expect(content.contains("ARROW_DONE"))
                await manager.disconnectAll()
                try await tmux.killSession("arrows")
            }
        }

        private func killTmuxServer(tmuxPath: String, socketPath: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = ["-S", socketPath, "kill-server"]
            process.environment = [:]
            process.standardError = Pipe()
            process.standardOutput = Pipe()
            try? process.run()
        }
    }
#endif
