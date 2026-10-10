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
        nonisolated private static let supportedHints = ["shift + ← to answer", "shift+← to answer", "shift← to answer"]
        nonisolated private static let supportedSuffixes = ["", " · 14s", " · 1m 02s"]

        nonisolated private static func screen(
            count: Int = 4,
            composer: String = "› Ask Codex to do anything",
            hint: String = "shift + ← to answer",
            suffix: String = ""
        ) -> [String] {
            ["output", "• Queued follow-up inputs", "  ? \(count) \(count == 1 ? "question" : "questions")\(suffix)",
             "    \(hint)", "", composer, "  gpt-6-astra · project"]
        }

        @Test("Recognizes old and new Codex footers at the empty live composer", arguments: [1, 2, 4, 999], supportedHints)
        func recognizesFooter(count: Int, hint: String) {
            #expect(CodexQuestionPrompt(lines: Self.screen(count: count, hint: hint), cursorRow: 5, cursorColumn: 2)?.count == count)
            #expect(CodexQuestionPrompt(lines: Self.screen(count: count, composer: "› ", hint: hint), cursorRow: 5, cursorColumn: 2)?.count == count)
        }

        @Test("Real Codex particle decoration does not hide the empty placeholder", arguments: supportedHints)
        func particles(hint: String) {
            var lines = Self.screen(hint: hint)
            lines[4] = "  ⠐       ⠐  ⠄    ⢀    ⠈ "
            lines[5] = "›⠁Ask Codex to do anything   ⠈       ⠂    ⠁"
            #expect(CodexQuestionPrompt(lines: lines, cursorRow: 5, cursorColumn: 2)?.count == 4)
        }

        @Test("Drafts including braille, shell prompts and unknown placeholders are untouched", arguments: [
            "› hello", "› 中", "› ⠐", "› Ask Codex to do anything else", "> ", "$ ", "› Find a bug in @file",
        ], supportedHints)
        func drafts(composer: String, hint: String) {
            #expect(CodexQuestionPrompt(lines: Self.screen(composer: composer, hint: hint), cursorRow: 5, cursorColumn: 2) == nil)
        }

        @Test("Rejects a cursor in output or a moved draft cursor", arguments: [0, 1, 3, 40], supportedHints)
        func cursor(column: Int, hint: String) {
            #expect(CodexQuestionPrompt(lines: Self.screen(hint: hint), cursorRow: 5, cursorColumn: column) == nil)
            #expect(CodexQuestionPrompt(lines: Self.screen(hint: hint), cursorRow: 0, cursorColumn: 2) == nil)
        }

        @Test("Partial, changed or malformed footer is not an empty queue", arguments: [
            "shift + → to answer", "shift+→ to answer", "", "shift + ← to answer later",
            "shift+← to answer later", "shift← to answer later", "shift→ to answer", "ctrl+← to answer", "shift+←", "shift←",
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

        @Test("A hint formatting change cannot reopen a dismissed queue")
        func hintFormattingDeduplication() throws {
            var state = CodexQuestionExpansionState()
            for (index, hint) in (Self.supportedHints + Self.supportedHints).enumerated() {
                let prompt = try #require(CodexQuestionPrompt(lines: Self.screen(hint: hint), cursorRow: 5, cursorColumn: 2))
                #expect(state.observe(prompt.count) == (index == 0))
            }
        }

        @Test("Current Codex footer spacing and age are recognized in the alternate screen", arguments: supportedHints, supportedSuffixes)
        func currentCodexSnapshot(hint: String, suffix: String) {
            let view = InteractiveTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
            view.getTerminal().resize(cols: 239, rows: 66)
            // Only the footer from the observed live screen; no transcript or
            // private question text is needed to reproduce the parser failure.
            let lines = [
                "• Working (2m 11s • esc to interrupt)", "",
                "• Queued follow-up inputs", "  ? 1 question\(suffix)", "    \(hint)",
                "", "", "› Ask Codex to do anything", "",
                "  GPT-6-Astra xhigh fast", "  ← for agents · ? for shortcuts",
            ]
            let bytes = Array(("\u{1b}[?1049h\u{1b}[56;1H" + lines.joined(separator: "\r\n") + "\u{1b}[63;3H").utf8)
            view.feed(byteArray: bytes[...])
            #expect(view.currentQuestionPrompt?.count == 1)
            #expect(!view.canExpandCodexQuestions)
        }

        @Test("Guarded intent has its own wire command, not unconditional keystrokes")
        func wireRoundTrip() throws {
            let command = CommandMessage(paneId: "%7", command: ExpandCodexQuestions(expectedCount: 4).commandType)
            let decoded = try JSONDecoder().decode(CommandMessage.self, from: JSONEncoder().encode(command))
            #expect(decoded.command == .expandCodexQuestions(ExpandCodexQuestions(expectedCount: 4)))
            #expect(!decoded.command.requiresResponse)
        }

        @Test("Host and multiple viewers share one deduplicated opener", arguments: supportedHints)
        func hostDeduplicates(hint: String) async throws {
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    let output = arguments.contains("capture-pane")
                        ? "codex\t2\t5\t0\n" + Self.screen(hint: hint).joined(separator: "\n") : ""
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
            #expect(!commands.value.contains { $0.first == "-eo" || $0.contains("list-panes") })
        }

        @Test("Host accepts elapsed footers but age changes cannot trigger duplicate opens", arguments: supportedHints)
        func hostTimerTicks(hint: String) async throws {
            let commands = LockIsolated<[[String]]>([])
            let suffix = LockIsolated(" · 14s")
            try await withDependencies {
                $0[ProcessRunner.self].run = { _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    let output = arguments.contains("capture-pane")
                        ? "codex\t2\t5\t0\n" + Self.screen(hint: hint, suffix: suffix.value).joined(separator: "\n") : ""
                    return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                // A stale viewer count must not consume the valid opener.
                try await tmux.expandCodexQuestions(paneID: "%7", expectedCount: 3)
                #expect(!commands.value.contains { $0.contains("send-keys") })
                for tick in [" · 14s", " · 15s", " · 1m 02s"] {
                    suffix.setValue(tick)
                    try await tmux.expandCodexQuestions(paneID: "%7", expectedCount: 4)
                }
            }
            #expect(commands.value.filter { $0.contains("send-keys") } == [["send-keys", "-t", "%7", "S-Left"]])
        }

        @Test("Host rejects stale viewer count, drafts, other agents and copy mode", arguments: [
            "codex\t2\t5\t1", "zsh\t2\t5\t0", "claude\t2\t5\t0", "codex\t8\t5\t0", "malformed",
        ], supportedHints)
        func hostGuards(metadata: String, hint: String) async throws {
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    return ProcessResult(exitCode: 0, stdout: Data((metadata + "\n" + Self.screen(hint: hint, suffix: " · 14s").joined(separator: "\n")).utf8), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                try await tmux.expandCodexQuestions(paneID: "%7", expectedCount: 4)
                try await tmux.expandCodexQuestions(paneID: "%7", expectedCount: 3)
                try await tmux.expandCodexQuestions(paneID: "session:1", expectedCount: 4)
            }
            #expect(!commands.value.contains { $0.contains("send-keys") })
        }

        @Test("A stale count and a newly typed host draft cannot open a question", arguments: [false, true], supportedHints)
        func staleViewer(draft: Bool, hint: String) async throws {
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    let screen = Self.screen(composer: draft ? "› draft" : "› Ask Codex to do anything", hint: hint, suffix: " · 14s")
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

        @Test("Native wrapper observes the rendered footer, not raw chunk boundaries", arguments: supportedHints, supportedSuffixes)
        func nativeSnapshot(hint: String, suffix: String) {
            let view = InteractiveTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
            view.getTerminal().resize(cols: 80, rows: 24)
            let bytes = Array((Self.screen(hint: hint, suffix: suffix).joined(separator: "\r\n") + "\u{1b}[6;3H").utf8)
            view.feed(byteArray: bytes.prefix(bytes.count / 2))
            #expect(view.currentQuestionPrompt?.count != 4)
            view.feed(byteArray: bytes.suffix(bytes.count - bytes.count / 2))
            #expect(view.currentQuestionPrompt?.count == 4)
            // Unmounted/background views must never dispatch an opener.
            #expect(!view.canExpandCodexQuestions)
        }
    }
#endif
