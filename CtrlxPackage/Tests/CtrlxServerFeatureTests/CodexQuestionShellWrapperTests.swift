#if os(macOS)
    import ConcurrencyExtras
    import CtrlxCommon
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Codex questions through shell wrappers")
    @MainActor
    struct CodexQuestionShellWrapperTests {
        nonisolated private static let paneLine = "%7\u{001F}100\u{001F}/project\n"
        nonisolated private static let processTree = "100 1 /bin/zsh\n101 100 /bin/zsh\n102 101 /opt/homebrew/bin/codex\n"

        nonisolated private static func frame(
            command: String = "zsh", count: Int = 1, composer: String = "› Ask Codex to do anything",
            column: Int = 2, inMode: Bool = false, hint: String = "shift← to answer", suffix: String = ""
        ) -> String {
            let footer = count == 0 ? ["", "", ""] : [
                "• Queued follow-up inputs", "? \(count) \(count == 1 ? "question" : "questions")\(suffix)", hint,
            ]
            return "\(command)\t\(column)\t5\t\(inMode ? 1 : 0)\n" + (["output"] + footer + ["", composer]).joined(separator: "\n")
        }

        nonisolated private static func output(executable: String, arguments: [String], frame: String) -> String {
            if executable == "/bin/ps" { return processTree }
            if arguments.contains("list-panes") { return paneLine }
            if arguments.contains("capture-pane") { return frame }
            return ""
        }

        @Test("Nested wrappers expand all known hints; duplicate counts do not rescan", arguments: [
            "shift + ← to answer", "shift+← to answer", "shift← to answer",
        ])
        func wrappedQueue(hint: String) async throws {
            let commands = LockIsolated<[[String]]>([])
            let count = LockIsolated(4)
            let captures = LockIsolated(0)
            try await withDependencies {
                $0[ProcessRunner.self].run = { executable, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    // Age ticks between the first capture and the recheck must
                    // not make the same queue appear different.
                    if arguments.contains("capture-pane") { captures.withValue { $0 += 1 } }
                    let frame = Self.frame(count: count.value, hint: hint, suffix: " · \(captures.value)s")
                    let output = Self.output(executable: executable, arguments: arguments, frame: frame)
                    return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                for value in [4, 4, 3, 4, 0, 1] {
                    count.setValue(value)
                    try await tmux.expandCodexQuestions(paneID: "%7", expectedCount: value)
                }
                #expect(tmux.codexQuestionStates["%7"]?.count == 1)
            }
            #expect(commands.value.filter { $0.contains("send-keys") } == Array(repeating: ["send-keys", "-t", "%7", "S-Left"], count: 3))
            #expect(commands.value.filter { $0.first == "-eo" }.count == 5)
        }

        @Test("A shell footer cannot substitute for verified Codex in the same pane", arguments: [
            "no-codex", "other-agent", "other-pane", "ps-failed", "panes-failed",
        ])
        func unverifiedProcess(scenario: String) async throws {
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { executable, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    var output = Self.output(executable: executable, arguments: arguments, frame: Self.frame())
                    var exitCode: Int32 = 0
                    if executable == "/bin/ps" {
                        switch scenario {
                        case "no-codex": output = "100 1 zsh\n101 100 zsh\n"
                        case "other-agent": output = "100 1 zsh\n101 100 claude\n"
                        case "other-pane": output = "100 1 zsh\n200 1 zsh\n201 200 codex\n"
                        case "ps-failed": exitCode = 1
                        default: break
                        }
                    }
                    if arguments.contains("list-panes") {
                        if scenario == "other-pane" { output += "%8\u{001F}200\u{001F}/other\n" }
                        if scenario == "panes-failed" { exitCode = 1 }
                    }
                    return ProcessResult(exitCode: exitCode, stdout: Data(output.utf8), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                try await tmux.expandCodexQuestions(paneID: "%7", expectedCount: 1)
                #expect(tmux.codexQuestionStates["%7"] == nil)
            }
            #expect(!commands.value.contains { $0.contains("send-keys") })
        }

        @Test("A cached process identity cannot authorize an exited Codex")
        func staleProcessCache() async throws {
            let alive = LockIsolated(true)
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { executable, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    let output = executable == "/bin/ps" && !alive.value ? "100 1 zsh\n"
                        : Self.output(executable: executable, arguments: arguments, frame: Self.frame())
                    return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                #expect(await tmux.detectAgentPanes(processNamesByPlugin: ["codex": ["codex"]])["%7"] != nil)
                alive.setValue(false)
                try await tmux.expandCodexQuestions(paneID: "%7", expectedCount: 1)
            }
            #expect(commands.value.filter { $0.first == "-eo" }.count == 2)
            #expect(!commands.value.contains { $0.contains("send-keys") })
        }

        @Test("Recheck after process inspection protects new drafts and changed screens", arguments: [
            "draft", "cursor", "copy-mode", "other-agent", "count",
        ])
        func screenChangesDuringProbe(scenario: String) async throws {
            let invalidate = LockIsolated(true)
            let changed = LockIsolated(false)
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { executable, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    if executable == "/bin/ps", invalidate.value { changed.setValue(true) }
                    let frame = changed.value ? Self.frame(
                        command: scenario == "other-agent" ? "claude" : "zsh",
                        count: scenario == "count" ? 2 : 1,
                        composer: scenario == "draft" ? "› draft" : "› Ask Codex to do anything",
                        column: scenario == "cursor" ? 3 : 2, inMode: scenario == "copy-mode"
                    ) : Self.frame()
                    let output = Self.output(executable: executable, arguments: arguments, frame: frame)
                    return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                try await tmux.expandCodexQuestions(paneID: "%7", expectedCount: 1)
                #expect(!commands.value.contains { $0.contains("send-keys") })
                #expect(tmux.codexQuestionStates["%7"] == nil)
                // An invalidated check must not consume the valid opener.
                invalidate.setValue(false)
                changed.setValue(false)
                try await tmux.expandCodexQuestions(paneID: "%7", expectedCount: 1)
            }
            #expect(commands.value.filter { $0.contains("send-keys") }.count == 1)
        }

        @Test("Concurrent viewers share one shell-wrapper probe and one opener")
        func concurrentViewers() async throws {
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { executable, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    await Task.yield()
                    let output = Self.output(executable: executable, arguments: arguments, frame: Self.frame())
                    return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                async let first: Void = tmux.expandCodexQuestions(paneID: "%7", expectedCount: 1)
                async let second: Void = tmux.expandCodexQuestions(paneID: "%7", expectedCount: 1)
                _ = try await (first, second)
            }
            #expect(commands.value.filter { $0.first == "-eo" }.count == 1)
            #expect(commands.value.filter { $0.contains("send-keys") }.count == 1)
        }
    }
#endif
