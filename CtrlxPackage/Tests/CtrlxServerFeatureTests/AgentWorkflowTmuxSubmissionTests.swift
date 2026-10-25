import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowTmuxSubmissionTests {
    private let tmux = "/opt/homebrew/bin/tmux"

    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX")
        environment.removeValue(forKey: "TMUX_PANE")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw AgentWorkflowError(text) }
        return text
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux")))
    func privateTmuxReceivesOneLiteralPasteAndSubmitAndRejectsChangedProcess() async throws {
        // Darwin's Unix socket path is limited to 104 bytes.
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("ctrlx-workflow-tmux-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("tmux.sock").path
        let received = root.appendingPathComponent("received")
        let script = root.appendingPathComponent("receiver.py")
        try """
        import os, sys, tty
        tty.setraw(0)
        os.write(1, b'\u{1b}[?2004h\u{1b}[2J\u{1b}[2;3H')
        with open(sys.argv[1], 'ab', buffering=0) as output:
            while True:
                data = os.read(0, 65536)
                if not data: break
                output.write(data)
        """.write(to: script, atomically: true, encoding: .utf8)
        _ = try run(tmux, ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "test", "-x", "80", "-y", "20", "/usr/bin/python3", script.path, received.path])
        defer { _ = try? run(tmux, ["-S", socket, "kill-server"]) }
        var metadata: [String] = []
        for _ in 0..<100 {
            metadata = try run(tmux, ["-S", socket, "display-message", "-p", "-t", "test", "#{pane_id}|#{pane_current_command}|#{bracket_paste_flag}"])
                .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
            if metadata.count == 3, metadata[2] == "1", FileManager.default.fileExists(atPath: received.path) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(metadata.count == 3 && metadata[2] == "1")
        let instance = AgentWorkflowInstance(
            hostID: UUID(),
            pluginID: "test",
            processID: 42,
            processRuntimeID: "test",
            workspacePane: .init(serverID: "1:1", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: metadata[0],
            conversationID: "test",
            displayName: "Test",
            workingDirectory: root.path,
            capabilities: nil,
            readiness: .ready
        )
        let input = "$review-changes\n审查 `literal` $(literal); 'quoted'"
        let file = root.appendingPathComponent("input 'quoted'.txt")
        try input.write(to: file, atomically: true, encoding: .utf8)
        let capture = AgentWorkflowTerminalCapture(
            ansi: "",
            width: 80,
            height: 20,
            cursorX: 2,
            cursorY: 1,
            cursorVisible: true,
            bracketedPaste: true,
            inCopyMode: false,
            foregroundCommand: metadata[1]
        )
        let commands = try AgentWorkflowTmuxSubmission.commands(instance: instance, file: file, capture: capture)
        _ = try run(tmux, ["-S", socket] + commands.flatMap { $0 })
        let expected = Data("\u{1b}[200~\(input)\u{1b}[201~\r".utf8)
        for _ in 0..<100 {
            if try Data(contentsOf: received).count >= expected.count {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try Data(contentsOf: received) == expected)
        let changed = AgentWorkflowTerminalCapture(
            ansi: "",
            width: 80,
            height: 20,
            cursorX: 2,
            cursorY: 1,
            cursorVisible: true,
            bracketedPaste: true,
            inCopyMode: false,
            foregroundCommand: "exited-agent"
        )
        let denied = try AgentWorkflowTmuxSubmission.commands(instance: instance, file: file, capture: changed)
        #expect(try run(tmux, ["-S", socket] + denied.flatMap { $0 }).trimmingCharacters(in: .whitespacesAndNewlines) == AgentWorkflowTmuxSubmission.rejection)
        #expect(try Data(contentsOf: received) == expected)
    }
}
