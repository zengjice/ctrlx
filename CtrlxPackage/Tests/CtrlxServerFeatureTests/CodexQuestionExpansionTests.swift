#if os(macOS)
    import AppKit
    import ConcurrencyExtras
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Codex question expansion")
    @MainActor
    struct CodexQuestionExpansionTests {
        nonisolated private static func screen(count: Int = 4, composer: String = "› Ask Codex to do anything") -> [String] {
            ["output", "• Queued follow-up inputs", "  ? \(count) \(count == 1 ? "question" : "questions")",
             "    shift + ← to answer", "", composer, "  gpt-6-astra · project"]
        }

        @Test("Recognizes only the collapsed footer at the empty live composer", arguments: [1, 2, 4, 999])
        func recognizesFooter(count: Int) {
            #expect(CodexQuestionPrompt(lines: Self.screen(count: count), cursorRow: 5, cursorColumn: 2)?.count == count)
            #expect(CodexQuestionPrompt(lines: Self.screen(count: count, composer: "› "), cursorRow: 5, cursorColumn: 2)?.count == count)
        }

        @Test("Real Codex particle decoration does not hide the empty placeholder")
        func particles() {
            var lines = Self.screen()
            lines[4] = "  ⠐       ⠐  ⠄    ⢀    ⠈ "
            lines[5] = "›⠁Ask Codex to do anything   ⠈       ⠂    ⠁"
            #expect(CodexQuestionPrompt(lines: lines, cursorRow: 5, cursorColumn: 2)?.count == 4)
        }

        @Test("Drafts including braille, shell prompts and unknown placeholders are untouched", arguments: [
            "› hello", "› 中", "› ⠐", "› Ask Codex to do anything else", "> ", "$ ", "› Find a bug in @file",
        ])
        func drafts(composer: String) {
            #expect(CodexQuestionPrompt(lines: Self.screen(composer: composer), cursorRow: 5, cursorColumn: 2) == nil)
        }

        @Test("Rejects a cursor in output or a moved draft cursor", arguments: [0, 1, 3, 40])
        func cursor(column: Int) {
            #expect(CodexQuestionPrompt(lines: Self.screen(), cursorRow: 5, cursorColumn: column) == nil)
            #expect(CodexQuestionPrompt(lines: Self.screen(), cursorRow: 0, cursorColumn: 2) == nil)
        }

        @Test("Partial, changed or malformed footer is not an empty queue", arguments: [
            "shift + → to answer", "", "shift + ← to answer later",
        ])
        func partialFooter(hint: String) {
            var lines = Self.screen()
            lines[3] = hint
            #expect(CodexQuestionPrompt(lines: lines, cursorRow: 5, cursorColumn: 2) == nil)
        }

        @Test("Unknown counts fail closed", arguments: [-1, 0, 1000])
        func invalidCount(count: Int) {
            #expect(CodexQuestionPrompt(lines: Self.screen(count: count), cursorRow: 5, cursorColumn: 2) == nil)
        }

        @Test("Only the known normal empty composer can report a cleared queue")
        func clearQueue() {
            #expect(CodexQuestionPrompt(lines: ["output", "› Ask Codex to do anything"], cursorRow: 1, cursorColumn: 2)?.count == 0)
            #expect(CodexQuestionPrompt(lines: ["Question?", "›"], cursorRow: 1, cursorColumn: 2) == nil)
            #expect(CodexQuestionPrompt(lines: [], cursorRow: 0, cursorColumn: 2) == nil)
        }

        @Test("Dismissed queues stay closed; only observed growth reopens")
        func deduplication() {
            var state = CodexQuestionExpansionState()
            let opened = [4, 4, 3, 4, 0, 1].map { state.observe($0) }
            #expect(opened == [true, false, false, true, false, true])
        }

        @Test("Guarded intent has its own wire command, not unconditional keystrokes")
        func wireRoundTrip() throws {
            let command = CommandMessage(paneId: "%7", command: ExpandCodexQuestions(expectedCount: 4).commandType)
            let decoded = try JSONDecoder().decode(CommandMessage.self, from: JSONEncoder().encode(command))
            #expect(decoded.command == .expandCodexQuestions(ExpandCodexQuestions(expectedCount: 4)))
            #expect(!decoded.command.requiresResponse)
        }

        @Test("Host and multiple viewers share one deduplicated opener")
        func hostDeduplicates() async throws {
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    let output = arguments.contains("capture-pane")
                        ? "codex\t2\t5\t0\n" + Self.screen().joined(separator: "\n") : ""
                    return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                let executor = TmuxCommandExecutor(tmuxService: tmux)
                try await tmux.expandCodexQuestions(paneID: "%7", expectedCount: 4)
                _ = await executor.execute(CommandMessage(paneId: "%7", command: ExpandCodexQuestions(expectedCount: 4).commandType))
                try await tmux.expandCodexQuestions(paneID: "%7", expectedCount: 4)
            }
            let keys = commands.value.filter { $0.contains("send-keys") }
            #expect(keys == [["send-keys", "-t", "%7", "S-Left"]])
        }

        @Test("Host rejects stale viewer count, drafts, other agents and copy mode", arguments: [
            "codex\t2\t5\t1", "zsh\t2\t5\t0", "claude\t2\t5\t0", "codex\t8\t5\t0", "malformed",
        ])
        func hostGuards(metadata: String) async throws {
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    return ProcessResult(exitCode: 0, stdout: Data((metadata + "\n" + Self.screen().joined(separator: "\n")).utf8), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                try await tmux.expandCodexQuestions(paneID: "%7", expectedCount: 4)
                try await tmux.expandCodexQuestions(paneID: "%7", expectedCount: 3)
                try await tmux.expandCodexQuestions(paneID: "session:1", expectedCount: 4)
            }
            #expect(!commands.value.contains { $0.contains("send-keys") })
        }

        @Test("A stale count and a newly typed host draft cannot open a question", arguments: [false, true])
        func staleViewer(draft: Bool) async throws {
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    let screen = Self.screen(composer: draft ? "› draft" : "› Ask Codex to do anything")
                    return ProcessResult(exitCode: 0, stdout: Data(("codex\t2\t5\t0\n" + screen.joined(separator: "\n")).utf8), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                try await tmux.expandCodexQuestions(paneID: "%7", expectedCount: draft ? 4 : 3)
            }
            #expect(!commands.value.contains { $0.contains("send-keys") })
        }

        @Test("Simultaneous viewers cannot race two expansion checks")
        func concurrentViewers() async throws {
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    await Task.yield()
                    let output = arguments.contains("capture-pane")
                        ? "codex\t2\t5\t0\n" + Self.screen().joined(separator: "\n") : ""
                    return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                async let first: Void = tmux.expandCodexQuestions(paneID: "%7", expectedCount: 4)
                async let second: Void = tmux.expandCodexQuestions(paneID: "%7", expectedCount: 4)
                _ = try await (first, second)
            }
            #expect(commands.value.filter { $0.contains("send-keys") }.count == 1)
        }

        @Test("Native wrapper observes the rendered footer, not raw chunk boundaries")
        func nativeSnapshot() {
            let view = InteractiveTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
            view.getTerminal().resize(cols: 80, rows: 24)
            let bytes = Array((Self.screen().joined(separator: "\r\n") + "\u{1b}[6;3H").utf8)
            view.feed(byteArray: bytes.prefix(bytes.count / 2))
            #expect(view.currentQuestionPrompt?.count != 4)
            view.feed(byteArray: bytes.suffix(bytes.count - bytes.count / 2))
            #expect(view.currentQuestionPrompt?.count == 4)
            // Unmounted/background views must never dispatch an opener.
            #expect(!view.canExpandCodexQuestions)
        }
    }
#endif
