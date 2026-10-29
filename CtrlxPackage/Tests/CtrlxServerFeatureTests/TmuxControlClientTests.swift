#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Darwin
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    /// Captures every event a `PipePaneReader` emits so tests can assert on the
    /// exact stream the delegate sees. Lives on the main actor (matching the
    /// `PipePaneReaderDelegate` isolation).
    @MainActor
    final private class CapturingDelegate: PipePaneReaderDelegate {
        var notifications: [TerminalStreamMessage.TerminalNotification] = []
        var titles: [String] = []
        var clipboards: [String] = []
        var progress: [TerminalProgressState] = []
        var terminations: [PipePaneReaderTermination] = []

        func pipePaneReader(
            _ reader: PipePaneReader,
            paneId: String,
            didReceiveNotification notification: TerminalStreamMessage.TerminalNotification
        ) {
            notifications.append(notification)
        }

        func pipePaneReader(_ reader: PipePaneReader, paneId: String, didReceiveTitle title: String) {
            titles.append(title)
        }

        func pipePaneReader(_ reader: PipePaneReader, paneId: String, didReceiveClipboard content: String) {
            clipboards.append(content)
        }

        func pipePaneReader(_ reader: PipePaneReader, paneId: String, didReceiveProgress progress: TerminalProgressState) {
            self.progress.append(progress)
        }

        func pipePaneReader(
            _ reader: PipePaneReader,
            paneId: String,
            didTerminate reason: PipePaneReaderTermination
        ) {
            terminations.append(reason)
        }
    }

    @MainActor
    final private class CapturingControlOutput {
        var events: [String] = []
        var dataEvents: [Data] = []
    }

    @Suite("TmuxControlClient Tests")
    struct TmuxControlClientTests {
        @Suite("Control Output")
        struct ControlOutputTests {
            @Test("Octal escapes decode without changing UTF-8 bytes")
            func octalEscapesDecodeAtByteLevel() throws {
                var line = Data("%output %7 中文".utf8)
                line.append(Data(#"\012\033\134tail"#.utf8))

                let output = try #require(TmuxControlOutputDecoder.decode(line))

                #expect(output.paneId == "%7")
                var expected = Data("中文".utf8)
                expected.append(contentsOf: [0x0A, 0x1B, 0x5C])
                expected.append(Data("tail".utf8))
                #expect(output.data == expected)
            }

            @Test("Malformed escape remains literal")
            func malformedEscapeIsPreserved() throws {
                let output = try #require(TmuxControlOutputDecoder.decode(
                    Data(#"%output %2 keep\12x"#.utf8)
                ))
                #expect(output.data == Data(#"keep\12x"#.utf8))
            }

            @Test("A UTF-8 scalar split across output notifications is delivered byte-exactly")
            @MainActor
            func splitUTF8ScalarIsReassembled() async {
                let client = TmuxControlClient()
                let capture = CapturingControlOutput()
                await client.setOnOutput { _, data in
                    capture.dataEvents.append(data)
                }
                await client.testSetPaneOutputEnabled("%7", enabled: true)

                var first = Data("%output %7 ".utf8)
                first.append(0xE4)
                first.append(0x0A)
                var second = Data("%output %7 ".utf8)
                second.append(contentsOf: [0xB8, 0xAD, 0x0A])

                await client.testProcessIncomingData(first)
                #expect(capture.dataEvents.isEmpty)
                await client.testProcessIncomingData(second)

                #expect(capture.dataEvents == [Data("中".utf8)])
            }

            @Test("An ANSI token crossing a snapshot response stays after the boundary")
            @MainActor
            func splitANSISequenceStaysAtomicAcrossSnapshotBoundary() async throws {
                let client = TmuxControlClient()
                let capture = CapturingControlOutput()
                await client.testMarkInitialAttachHandled()
                await client.setOnOutput { _, data in
                    capture.dataEvents.append(data)
                    capture.events.append("output")
                }
                await client.testSetPaneOutputEnabled("%7", enabled: true)

                await client.testProcessIncomingData(Data(#"%output %7 \033[38;2;"#.utf8) + Data([0x0A]))
                #expect(capture.events.isEmpty)

                let command = Task {
                    try await client.testEnqueueCommand(id: 1) { _ in
                        capture.events.append("boundary")
                    }
                }
                while await client.testPendingCommandCount != 1 {
                    await Task.yield()
                }

                await client.testProcessIncomingData(Data("""
                %begin 1000 100 1
                snapshot
                %end 1000 100 1
                %output %7 48;226;213m&& rg --files

                """.utf8))
                _ = try await command.value

                #expect(capture.events == ["boundary", "output"])
                #expect(capture.dataEvents == [Data("\u{1B}[38;2;48;226;213m&& rg --files".utf8)])
            }

            @Test("A token prefix observed before subscription is retained")
            @MainActor
            func preSubscriptionPrefixIsRetained() async {
                let client = TmuxControlClient()
                let capture = CapturingControlOutput()
                await client.setOnOutput { _, data in
                    capture.dataEvents.append(data)
                }

                await client.testProcessIncomingData(
                    Data(#"%output %7 \033[38;2;"#.utf8) + Data([0x0A])
                )
                await client.testSetPaneOutputEnabled("%7", enabled: true)
                await client.testProcessIncomingData(Data("%output %7 48;226;213mX\n".utf8))

                #expect(capture.dataEvents == [Data("\u{1B}[38;2;48;226;213mX".utf8)])
            }

            @Test("Snapshot callback is ordered between surrounding output")
            @MainActor
            func snapshotBoundaryIsOrdered() async throws {
                let client = TmuxControlClient()
                let capture = CapturingControlOutput()
                await client.testMarkInitialAttachHandled()
                await client.setOnOutput { _, data in
                    capture.events.append("output:\(String(decoding: data, as: UTF8.self))")
                }
                await client.testSetPaneOutputEnabled("%7", enabled: true)

                let command = Task {
                    try await client.testEnqueueCommand(id: 1) { _ in
                        capture.events.append("boundary")
                    }
                }
                while await client.testPendingCommandCount != 1 {
                    await Task.yield()
                }

                await client.testProcessIncomingData(Data("""
                %output %7 before
                %begin 1000 100 1
                snapshot
                %end 1000 100 1
                %output %7 after

                """.utf8))
                _ = try await command.value

                #expect(capture.events == ["output:before", "boundary", "output:after"])
            }
        }

        @Suite("Control Client Environment")
        struct ControlClientEnvironmentTests {
            @Test("Unavailable TERM uses xterm-256color")
            func unavailableTermUsesFallback() {
                for term in [String?.none, "", "dumb", "DUMB"] {
                    var inherited = ["PATH": "/usr/bin"]
                    inherited["TERM"] = term

                    let environment = TmuxControlClient.controlClientEnvironment(inheriting: inherited)

                    #expect(environment["TERM"] == "xterm-256color")
                    #expect(environment["PATH"] == "/usr/bin")
                }
            }

            @Test("Existing terminal type is preserved")
            func existingTermIsPreserved() {
                let inherited = ["TERM": "tmux-256color", "PATH": "/opt/homebrew/bin"]

                let environment = TmuxControlClient.controlClientEnvironment(inheriting: inherited)

                #expect(environment == inherited)
            }
        }

        @Suite("Process Lifecycle")
        struct ProcessLifecycleTests {
            @Test("Disconnect reaps only the control client and preserves its tmux pane")
            @MainActor
            func disconnectReapsControlClient() async throws {
                let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
                let suffix = UUID().uuidString.lowercased()
                let socketPath = "/tmp/ctrlx-control-\(suffix.prefix(8)).sock"
                let sessionName = "ctrlx-control-\(suffix)"
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
                    let client = TmuxControlClient(tmuxPath: tmuxPath, socketPath: socketPath)

                    try await client.connect(sessionTarget: created.sessionName)
                    let firstPID = try #require(await client.testProcessIdentifier)
                    #expect(processExists(firstPID))
                    let firstFlags = try await client.sendCommand("display-message -p '#{client_flags}'")
                    #expect(firstFlags.output.split(separator: ",").contains("ignore-size"))

                    await client.disconnect()
                    #expect(await client.testProcessIdentifier == nil)
                    #expect(!processExists(firstPID))

                    // Reusing the same actor catches a stale termination handler
                    // clearing the next connection after the old process exits.
                    try await client.connect(sessionTarget: created.sessionName)
                    let secondPID = try #require(await client.testProcessIdentifier)
                    #expect(secondPID != firstPID)
                    #expect(processExists(secondPID))
                    let secondFlags = try await client.sendCommand("display-message -p '#{client_flags}'")
                    #expect(secondFlags.output.split(separator: ",").contains("ignore-size"))
                    await client.disconnect()
                    #expect(!processExists(secondPID))

                    let panes = await tmux.refreshPanes()
                    #expect(panes.contains { $0.paneId == created.paneId })
                    _ = try await tmux.capturePaneText(created.paneId)
                }
            }

            @Test("A real control client delivers pane output bytes")
            @MainActor
            func realControlOutputDelivery() async throws {
                let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
                let suffix = UUID().uuidString.lowercased()
                let socketPath = "/tmp/ctrlx-output-\(suffix.prefix(8)).sock"
                let sessionName = "ctrlx-output-\(suffix)"
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
                    let client = TmuxControlClient(tmuxPath: tmuxPath, socketPath: socketPath)
                    let capture = CapturingControlOutput()
                    await client.setOnOutput { _, data in
                        capture.events.append(String(decoding: data, as: UTF8.self))
                    }
                    try await client.connect(sessionTarget: created.sessionName)
                    await client.setPaneOutputEnabled(paneId: created.paneId, enabled: true)

                    let marker = "CTRLX_CONTROL_OUTPUT_\(suffix.prefix(8))"
                    try await tmux.sendKeys(created.paneId, keys: marker, literal: true)

                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while !capture.events.joined().contains(marker), ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(10))
                    }

                    #expect(capture.events.joined().contains(marker))
                    await client.disconnect()
                }
            }

            private func processExists(_ pid: Int32) -> Bool {
                kill(pid, 0) == 0 || errno == EPERM
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

        // MARK: - Session Name Extraction Tests

        @Suite("Session Name Extraction")
        struct SessionNameExtractionTests {
            @Test("Full pane target extracts session name")
            @MainActor
            func fullPaneTarget() {
                let result = TmuxControlClientManager.extractSessionName(from: "mysession:0.1")
                #expect(result == "mysession")
            }

            @Test("Window target extracts session name")
            @MainActor
            func windowTarget() {
                let result = TmuxControlClientManager.extractSessionName(from: "mysession:0")
                #expect(result == "mysession")
            }

            @Test("Session only returns session name")
            @MainActor
            func sessionOnly() {
                let result = TmuxControlClientManager.extractSessionName(from: "mysession")
                #expect(result == "mysession")
            }

            @Test("Session with spaces before colon")
            @MainActor
            func sessionWithSpaces() {
                let result = TmuxControlClientManager.extractSessionName(from: "my session:0.1")
                #expect(result == "my session")
            }

            @Test("Session with numbers")
            @MainActor
            func sessionWithNumbers() {
                let result = TmuxControlClientManager.extractSessionName(from: "session123:2.0")
                #expect(result == "session123")
            }

            @Test("Stable IDs require tmux resolution, not string parsing", arguments: ["%0", "@1", "$2", ""])
            @MainActor
            func stableIdFormat(target: String) {
                let result = TmuxControlClientManager.extractSessionName(from: target)
                #expect(result == nil)
            }
        }

        // MARK: - Command Response Tests

        @Suite("Command Response")
        struct CommandResponseTests {
            @Test("Lines property splits output correctly")
            func linesPropertySplits() {
                let response = CommandResponse(
                    commandNumber: 1,
                    output: "line1\nline2\nline3",
                    isError: false
                )
                #expect(response.lines == ["line1", "line2", "line3"])
            }

            @Test("Lines property handles empty output")
            func linesPropertyEmpty() {
                let response = CommandResponse(
                    commandNumber: 1,
                    output: "",
                    isError: false
                )
                #expect(response.lines == [""])
            }

            @Test("Lines property preserves empty lines")
            func linesPropertyPreservesEmpty() {
                let response = CommandResponse(
                    commandNumber: 1,
                    output: "line1\n\nline3",
                    isError: false
                )
                #expect(response.lines == ["line1", "", "line3"])
            }
        }

        // MARK: - Error Types Tests

        @Suite("Error Types")
        struct ErrorTypesTests {
            @Test("Not connected error has correct description")
            func notConnectedError() {
                let error = TmuxControlError.notConnected
                #expect(error.errorDescription?.contains("Not connected") == true)
            }

            @Test("Already connected error has correct description")
            func alreadyConnectedError() {
                let error = TmuxControlError.alreadyConnected
                #expect(error.errorDescription?.contains("Already connected") == true)
            }

            @Test("Connection failed error includes message")
            func connectionFailedError() {
                let error = TmuxControlError.connectionFailed(message: "test error")
                #expect(error.errorDescription?.contains("test error") == true)
            }

            @Test("Process terminated error includes reason")
            func processTerminatedError() {
                let error = TmuxControlError.processTerminated(reason: "Exit code: 1")
                #expect(error.errorDescription?.contains("Exit code: 1") == true)
            }

            @Test("Process terminated error handles nil reason")
            func processTerminatedNilReason() {
                let error = TmuxControlError.processTerminated(reason: nil)
                #expect(error.errorDescription?.contains("unknown") == true)
            }

            @Test("Timeout error has correct description")
            func timeoutError() {
                let error = TmuxControlError.timeout
                #expect(error.errorDescription?.contains("timed out") == true)
            }
        }
    }

    // MARK: - Block Parsing Tests

    @Suite("Block Parsing")
    struct BlockParsingTests {
        @Test("A timed-out capture drains its late responses without completing the next request")
        @MainActor
        func timeoutKeepsResponseAlignment() async throws {
            let client = TmuxControlClient()
            await client.testMarkInitialAttachHandled()
            let capture = CapturingControlOutput()
            let first = Task {
                try await client.testEnqueueCommandList(id: 1, count: 2) { _ in
                    capture.events.append("stale-boundary")
                }
            }
            try await waitForPendingCount(client, equals: 1)
            await client.testExpireCommand(id: 1)
            do {
                _ = try await first.value
                Issue.record("Expired command should throw")
            } catch TmuxControlError.timeout { /* Expected expiration. */ }
            let next = Task { try await client.testEnqueueCommand(id: 2) }
            try await waitForPendingCount(client, equals: 2)
            await client.testProcessIncomingData(Data("""
            %begin 1000 100 1
            stale-screen
            %end 1000 100 1
            %begin 1000 101 1
            stale-cursor
            %end 1000 101 1
            %begin 1000 102 1
            next-request
            %end 1000 102 1

            """.utf8))
            #expect(try await next.value.output == "next-request")
            #expect(capture.events.isEmpty)
            #expect(await client.testPendingCommandCount == 0)
        }

        @Test("A capture transaction marks its boundary only after its final response", arguments: [false, true])
        @MainActor
        func commandListBoundaryFollowsAllResponses(diagnostics: Bool) async throws {
            let metrics = HostPerformanceMetrics()
            metrics.setEnabled(diagnostics)
            let client = TmuxControlClient(performanceMetrics: metrics)
            await client.testMarkInitialAttachHandled()
            let capture = CapturingControlOutput()
            await client.setOnOutput { _, _ in capture.events.append("live") }
            await client.testSetPaneOutputEnabled("%7", enabled: true)
            let transaction = Task {
                try await client.testEnqueueCommandList(id: 1, count: 3) { _ in
                    capture.events.append("boundary")
                }
            }
            try await waitForPendingCount(client, equals: 1)
            await client.testProcessIncomingData(Data("""
            %begin 1000 100 1
            history
            %end 1000 100 1
            %begin 1000 101 1
            screen
            %end 1000 101 1

            """.utf8))
            #expect(capture.events.isEmpty)
            #expect(await client.testPendingCommandCount == 1)
            await client.testProcessIncomingData(Data("""
            %begin 1000 102 1
            5,8,1
            %end 1000 102 1
            %output %7 next

            """.utf8))
            let responses = try await transaction.value
            #expect(responses.map(\.output) == ["history", "screen", "5,8,1"])
            #expect(capture.events == ["boundary", "live"])
            #expect(await client.testPendingCommandCount == 0)
            #expect(metrics.snapshot().timings[.responseMainActorWait]?.count ?? 0 == (diagnostics ? 1 : 0))
            #expect(metrics.snapshot().timings[.outputMainActorWait]?.count ?? 0 == (diagnostics ? 1 : 0))
            #expect(metrics.snapshot().timings[.outputCallback]?.count ?? 0 == (diagnostics ? 1 : 0))
        }

        /// Regression: `%error` used to only set a flag without resolving the queued
        /// continuation. The next `%end` would then pop the wrong entry and subsequent
        /// commands would drift, eventually timing out after ~5s — visible to users as
        /// a blank terminal after closing a tmux window.
        @Test("`%error` resolves queued command with isError=true")
        func errorBlockResolvesPendingCommand() async throws {
            let client = TmuxControlClient()
            await client.testMarkInitialAttachHandled()

            // Start each enqueue as an explicit Task and wait for it to land in
            // the queue before starting the next — `async let` doesn't guarantee
            // child-task scheduling order, so under load the wrong continuation
            // can end up at index 0.
            let first = Task { try await client.testEnqueueCommand(id: 1) }
            try await waitForPendingCount(client, equals: 1)
            let second = Task { try await client.testEnqueueCommand(id: 2) }
            try await waitForPendingCount(client, equals: 2)

            let chunk = Data("""
            %begin 1000 100 1
            can't find pane: %1
            %error 1000 100 1
            %begin 1001 101 1
            %end 1001 101 1

            """.utf8)
            await client.testProcessIncomingData(chunk)

            let firstResponse = try await first.value
            let secondResponse = try await second.value
            #expect(firstResponse.commandNumber == 100)
            #expect(firstResponse.isError == true)
            #expect(firstResponse.output == "can't find pane: %1")
            #expect(secondResponse.commandNumber == 101)
            #expect(secondResponse.isError == false)
            #expect(await client.testPendingCommandCount == 0)
        }

        @Test("`%end` resolves queued command with isError=false")
        func endBlockResolvesPendingCommand() async throws {
            let client = TmuxControlClient()
            await client.testMarkInitialAttachHandled()

            let first = Task { try await client.testEnqueueCommand(id: 1) }
            try await waitForPendingCount(client, equals: 1)

            let chunk = Data("""
            %begin 1000 100 1
            output-line
            %end 1000 100 1

            """.utf8)
            await client.testProcessIncomingData(chunk)

            let response = try await first.value
            #expect(response.commandNumber == 100)
            #expect(response.isError == false)
            #expect(response.output == "output-line")
            #expect(await client.testPendingCommandCount == 0)
        }

        /// Yields until the client's pending queue reaches `count`, with a
        /// generous timeout. Replaces `Task.sleep`-based synchronisation, which
        /// is wall-clock-racy under parallel test load on slow CI VMs.
        private func waitForPendingCount(
            _ client: TmuxControlClient,
            equals count: Int,
            timeout: Duration = .seconds(5)
        ) async throws {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while await client.testPendingCommandCount != count {
                if ContinuousClock.now >= deadline {
                    break
                }
                await Task.yield()
            }
            #expect(await client.testPendingCommandCount == count)
        }
    }

    // MARK: - PipePaneReader Tests

    @Suite("PipePaneReader Tests")
    struct PipePaneReaderTests {
        @Suite("Non-blocking reads")
        struct NonBlockingReadTests {
            @Test("Positive reads deliver data")
            func positiveRead() {
                #expect(PipePaneReadDisposition.classify(bytesRead: 42, errorCode: 0) == .data)
            }

            @Test("Transient errors keep the FIFO stream alive", arguments: [EAGAIN, EWOULDBLOCK, EINTR])
            func transientError(errorCode: Int32) {
                #expect(
                    PipePaneReadDisposition.classify(bytesRead: -1, errorCode: errorCode) == .retry
                )
            }

            @Test("EOF and permanent read errors terminate the FIFO stream")
            func terminalReadResults() {
                #expect(
                    PipePaneReadDisposition.classify(bytesRead: 0, errorCode: 0)
                        == .terminate(.endOfFile)
                )
                #expect(
                    PipePaneReadDisposition.classify(bytesRead: -1, errorCode: EIO)
                        == .terminate(.readError(EIO))
                )
            }
        }

        @Suite("Ingress backpressure")
        struct IngressBackpressureTests {
            @Test("Overflow drops stale chunks and marks the exact retained boundary")
            func overflowBoundary() {
                let buffer = PipeIngressBuffer(paneId: "%0", maximumChunks: 2)

                buffer.enqueue(Data("A".utf8))
                buffer.enqueue(Data("B".utf8))
                #expect(buffer.dequeue()?.data == Data("A".utf8))

                // B and C fill the queue while A is already being processed.
                // D must discard both and carry the reset marker itself.
                buffer.enqueue(Data("C".utf8))
                buffer.enqueue(Data("D".utf8))

                let retained = buffer.dequeue()
                #expect(retained?.data == Data("D".utf8))
                #expect(retained?.requiresResyncBefore == true)
                #expect(buffer.dequeue()?.data == nil)
            }

            @Test("Normal FIFO delivery does not request a snapshot")
            func normalDelivery() {
                let buffer = PipeIngressBuffer(paneId: "%0", maximumChunks: 2)
                buffer.enqueue(Data("A".utf8))
                buffer.enqueue(Data("B".utf8))

                let first = buffer.dequeue()
                let second = buffer.dequeue()
                #expect(first?.data == Data("A".utf8))
                #expect(first?.requiresResyncBefore == false)
                #expect(second?.data == Data("B".utf8))
                #expect(second?.requiresResyncBefore == false)
            }
        }

        @Suite("Terminal output sanitizing")
        struct TerminalOutputSanitizingTests {
            @Test("Regular data passes through unchanged")
            func regularData() {
                var sanitizer = TerminalOutputSanitizer()
                let input = Data("Hello, World!".utf8)
                let result = sanitizer.sanitize(input)
                #expect(String(data: result, encoding: .utf8) == "Hello, World!")
            }

            @Test("ESC k title sequence is stripped")
            func escKTitleSequence() {
                var sanitizer = TerminalOutputSanitizer()
                // ESC k title ESC \ followed by regular data
                var input = Data()
                input.append(0x1B) // ESC
                input.append(0x6B) // k
                input.append(contentsOf: "title".utf8)
                input.append(0x1B) // ESC
                input.append(0x5C) // backslash
                input.append(contentsOf: "visible".utf8)

                let result = sanitizer.sanitize(input)
                #expect(String(data: result, encoding: .utf8) == "visible")
            }

            @Test("Other ESC sequences pass through")
            func otherEscSequences() {
                var sanitizer = TerminalOutputSanitizer()
                // ESC [ 31m (red color) should pass through
                let input = Data([0x1B, 0x5B, 0x33, 0x31, 0x6D]) // ESC[31m
                let result = sanitizer.sanitize(input)
                #expect(result == input)
            }

            @Test("Raw UTF-8 bytes pass through")
            func rawUtf8() {
                var sanitizer = TerminalOutputSanitizer()
                let input = Data([0xE2, 0x94, 0x80]) // ─ (box drawing)
                let result = sanitizer.sanitize(input)
                #expect(result == input)
                #expect(String(data: result, encoding: .utf8) == "─")
            }

            @Test("Mixed content with title sequence in the middle")
            func mixedContent() {
                var sanitizer = TerminalOutputSanitizer()
                var input = Data("before".utf8)
                input.append(0x1B) // ESC
                input.append(0x6B) // k
                input.append(contentsOf: "title".utf8)
                input.append(0x1B) // ESC
                input.append(0x5C) // backslash
                input.append(contentsOf: "after".utf8)

                let result = sanitizer.sanitize(input)
                #expect(String(data: result, encoding: .utf8) == "beforeafter")
            }

            @Test("A title sequence split across output events is stripped")
            func splitTitleSequence() {
                var sanitizer = TerminalOutputSanitizer()
                var first = Data("before".utf8)
                first.append(contentsOf: [0x1B, 0x6B])
                first.append(contentsOf: "partial".utf8)
                var second = Data(" title".utf8)
                second.append(contentsOf: [0x1B, 0x5C])
                second.append(contentsOf: "after".utf8)

                let prefix = sanitizer.sanitize(first)
                let suffix = sanitizer.sanitize(second)

                #expect(prefix == Data("before".utf8))
                #expect(suffix == Data("after".utf8))
            }

            @Test("Empty data returns empty")
            func emptyData() {
                var sanitizer = TerminalOutputSanitizer()
                let result = sanitizer.sanitize(Data())
                #expect(result.isEmpty)
            }
        }

        @Suite("FIFO Path")
        struct FifoPathTests {
            @Test("Pane ID is sanitized for filesystem")
            func paneIdSanitized() async {
                let reader = PipePaneReader(paneId: "%5")
                let path = await reader.testFifoPath
                let expectedDir = FileManager.default.temporaryDirectory.path
                #expect(path.hasPrefix("\(expectedDir)/ctrlx-pipe-5-"))
                #expect(path.hasSuffix(".fifo"))
                let replacement = PipePaneReader(paneId: "%5")
                #expect(await replacement.testFifoPath != path)
            }
        }

        @Suite("Scan-only OSC parsing")
        @MainActor
        struct ScanOnlyOSCParsingTests {
            @Test("Plain data is discarded while OSC events keep flowing")
            func scanOnlyStillEmitsOSC() async {
                let reader = PipePaneReader(paneId: "%0")
                let delegate = CapturingDelegate()
                await reader.setDelegate(delegate)

                // OSC 9 notification + plain text in one chunk.
                var input = Data()
                input.append(contentsOf: "before".utf8)
                input.append(0x1B) // ESC
                input.append(0x5D) // ]
                input.append(contentsOf: "9;hello".utf8)
                input.append(0x07) // BEL
                input.append(contentsOf: "after".utf8)

                await reader.testProcessIncomingData(input)
                await reader.testWaitForDelivery()

                #expect(delegate.notifications.count == 1, "OSC 9 notification must still flow")
            }

            @Test("A split OSC sequence is resumed even when the next chunk is plain")
            func splitOSCResumesSlowPath() async {
                let reader = PipePaneReader(paneId: "%0")
                let delegate = CapturingDelegate()
                await reader.setDelegate(delegate)

                await reader.testProcessIncomingData(Data([0x1B, 0x5D]) + Data("9;split".utf8))
                await reader.testProcessIncomingData(Data(" message".utf8) + Data([0x07]))
                await reader.testWaitForDelivery()

                #expect(delegate.notifications.map(\.body) == ["split message"])
            }
        }
    }
#endif
