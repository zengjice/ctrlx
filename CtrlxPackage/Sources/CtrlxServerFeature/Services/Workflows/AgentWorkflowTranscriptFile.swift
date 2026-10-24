#if os(macOS)
    import CtrlxNetworking
    import CtrlxPluginProtocol
    import Darwin
    import Foundation

    /// Holds one native transcript descriptor and an incremental parser. Memory
    /// and work per poll are bounded even for an existing long-running session.
    actor AgentWorkflowTranscriptFile {
        struct Poll: Sendable {
            let outcome: AgentWorkflowTranscriptOutcome?
            let reachedEnd: Bool
        }

        private let handle: FileHandle
        private var parser: any AgentWorkflowTranscriptParser
        private var pending = AgentWorkflowTranscriptRecord()
        private var offset: UInt64 = 0

        init(path: String, parser: any AgentWorkflowTranscriptParser) throws {
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else {
                if errno == ENOENT {
                    throw CocoaError(.fileNoSuchFile)
                }
                throw AgentWorkflowError("The native transcript could not be opened.")
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
                close(fd)
                throw AgentWorkflowError("The native transcript must be a regular file owned by this user.")
            }
            self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            self.parser = parser
        }

        func poll() throws -> Poll {
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0, info.st_size >= 0, UInt64(info.st_size) >= offset else {
                throw AgentWorkflowError("The native transcript was truncated while verifying a turn.")
            }
            // Yield after 1 MiB so a large transcript cannot monopolize a task.
            for _ in 0..<16 {
                guard let bytes = try handle.read(upToCount: 64 * 1_024), !bytes.isEmpty else {
                    return .init(outcome: nil, reachedEnd: true)
                }
                offset += UInt64(bytes.count)
                var remaining = bytes[...]
                while let newline = remaining.firstIndex(of: 10) {
                    try pending.append(remaining[..<newline])
                    let value = try pending.finish()
                    pending = AgentWorkflowTranscriptRecord()
                    remaining = remaining[remaining.index(after: newline)...]
                    if !value.isEmpty, let outcome = try parser.consume(value) {
                        return .init(outcome: outcome, reachedEnd: false)
                    }
                }
                try pending.append(remaining)
            }
            return .init(outcome: nil, reachedEnd: false)
        }
    }
#endif
