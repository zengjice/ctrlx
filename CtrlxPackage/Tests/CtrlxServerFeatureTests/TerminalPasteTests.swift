#if os(macOS)
    import ConcurrencyExtras
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Host terminal clipboard paste")
    @MainActor
    struct TerminalPasteTests {
        @Test("One Host paste loads exact bytes, requests bracket detection, and preserves LF")
        func clipboardBuffer() async throws {
            let text = "第一行🙂\r\nsecond\n\nlast\n"
            let commands = LockIsolated<[[String]]>([])
            let loaded = LockIsolated<Data?>(nil)
            let temporaryPath = LockIsolated<String?>(nil)
            let commandID = UUID()
            await withDependencies {
                $0[ProcessRunner.self].run = { _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    if arguments.first == "load-buffer", arguments.count > 3 {
                        let path = arguments[3]
                        temporaryPath.setValue(path)
                        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                        loaded.setValue(bytes)
                    }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            } operation: {
                let executor = TmuxCommandExecutor(tmuxService: TmuxService(tmuxPath: "/usr/bin/tmux"))
                let response = await executor.execute(CommandMessage(
                    id: commandID, paneId: "%7", command: PasteTerminalText(text: text).commandType
                ))
                #expect(response.success)
                #expect(response.commandId == commandID)
            }
            #expect(loaded.value == Data(text.utf8))
            #expect(commands.value.count == 1)
            let path = try #require(temporaryPath.value)
            #expect(commands.value.last == [
                "load-buffer", "-b", "ctrlx-paste-\(commandID.uuidString)", path, ";",
                "paste-buffer", "-p", "-d", "-b", "ctrlx-paste-\(commandID.uuidString)", "-t", "%7", "-r",
            ])
            #expect(!FileManager.default.fileExists(atPath: path))
        }

        @Test(
            "Empty, oversized and paste-end control payloads do not execute tmux",
            arguments: ["empty", "oversized", "terminator"]
        )
        func rejectedOrEmptyPayload(kind: String) async {
            let text = switch kind {
            case "empty": ""
            case "oversized": String(repeating: "中", count: 22_000)
            default: "one\u{1b}[201~two"
            }
            let commands = LockIsolated<[[String]]>([])
            await withDependencies {
                $0[ProcessRunner.self].run = { _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            } operation: {
                let executor = TmuxCommandExecutor(tmuxService: TmuxService(tmuxPath: "/usr/bin/tmux"))
                let response = await executor.execute(CommandMessage(
                    paneId: "%7", command: PasteTerminalText(text: text).commandType
                ))
                #expect(response.success == text.isEmpty)
            }
            #expect(commands.value.isEmpty)
        }

        @Test("A failed combined paste reports an error without falling back to Enter")
        func failedPaste() async {
            let commands = LockIsolated<[[String]]>([])
            await withDependencies {
                $0[ProcessRunner.self].run = { _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("paste failed".utf8))
                }
            } operation: {
                let executor = TmuxCommandExecutor(tmuxService: TmuxService(tmuxPath: "/usr/bin/tmux"))
                let response = await executor.execute(CommandMessage(
                    paneId: "%7", command: PasteTerminalText(text: "one\ntwo").commandType
                ))
                #expect(!response.success)
                #expect(response.error?.contains("paste failed") == true)
            }
            #expect(!commands.value.contains { $0.contains("send-keys") })
            #expect(commands.value.count == 1)
        }

        @Test("File-drop callers retain their existing paste flags")
        func fileDropIsUnchanged() async throws {
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            } operation: {
                try await TmuxService(tmuxPath: "/usr/bin/tmux").loadAndPasteBuffer(
                    target: "%7", content: "'/tmp/file name.png'", bufferName: "test-drop"
                )
            }
            let command = try #require(commands.value.first)
            #expect(commands.value.count == 1)
            #expect(command.count == 12)
            #expect(Array(command.prefix(3)) == ["load-buffer", "-b", "test-drop"])
            #expect(command[3].contains("ctrlx-drop-buf-"))
            #expect(Array(command.suffix(8)) == [";", "paste-buffer", "-p", "-d", "-b", "test-drop", "-t", "%7"])
        }

        @Test("Real tmux wraps only when the receiving app enables bracketed paste", arguments: [false, true])
        func realTmuxPaste(bracketed: Bool) async throws {
            let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
            let socket = "/tmp/ctrlx-paste-\(UUID().uuidString.prefix(8)).sock"
            let runner = ProcessRunner.liveValue
            defer {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tmuxPath)
                process.arguments = ["-S", socket, "kill-server"]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                try? process.run()
                process.waitUntilExit()
            }
            try await withDependencies {
                $0[ProcessRunner.self] = runner
                $0.continuousClock = ContinuousClock()
            } operation: {
                let tmux = TmuxService(tmuxPath: tmuxPath, socketPath: socket)
                let text = "中🙂\r\nsecond\n\nlast\n"
                let expected = (bracketed ? "\u{1b}[200~" : "") + text + (bracketed ? "\u{1b}[201~" : "")
                let mode = bracketed ? "\\033[?2004h" : "\\033[?2004l"
                let probe = "stty raw -echo; printf '\(mode)PASTE_READY\\r\\n'; "
                    + "dd bs=1 count=\(expected.utf8.count) 2>/dev/null | od -An -tx1; "
                    + "printf '\\r\\nPASTE_DONE\\r\\n'; cat"
                let created = try await runner.run(
                    tmuxPath,
                    ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "paste-test", "-x", "160", "-y", "24", "/bin/sh", "-c", probe],
                    nil, 5
                )
                #expect(created.isSuccess)
                #expect(try await waitFor("PASTE_READY", tmux: tmux))
                let executor = TmuxCommandExecutor(tmuxService: tmux)
                let response = await executor.execute(CommandMessage(
                    paneId: "%0", command: PasteTerminalText(text: text).commandType
                ))
                #expect(response.success)
                #expect(try await waitFor("PASTE_DONE", tmux: tmux))
                let content = try await tmux.capturePaneText("%0", scrollback: true)
                let hex = content.components(separatedBy: "PASTE_READY").last?
                    .components(separatedBy: "PASTE_DONE").first?
                    .split(whereSeparator: \.isWhitespace).joined()
                #expect(hex == expected.utf8.map { String(format: "%02x", $0) }.joined())
                let buffers = try await runner.run(tmuxPath, ["-S", socket, "list-buffers"], nil, 5)
                #expect(buffers.stdout.isEmpty)
            }
        }

        private func waitFor(_ marker: String, tmux: TmuxService) async throws -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            repeat {
                if try await tmux.capturePaneText("%0", scrollback: true).contains(marker) {
                    return true
                }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
            return false
        }
    }
#endif
