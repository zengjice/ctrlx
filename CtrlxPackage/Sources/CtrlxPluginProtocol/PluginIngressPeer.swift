import Foundation

/// Captured by the Host from the socket and kernel process table. This type is
/// intentionally not Codable: hook JSON and sidecar output cannot supply it.
public struct PluginIngressPeer: Equatable, Sendable {
    public struct Process: Equatable, Sendable {
        public let processID: Int32
        public let parentProcessID: Int32
        public let userID: UInt32
        public let startSeconds: UInt64
        public let startMicroseconds: UInt64

        public init(processID: Int32, parentProcessID: Int32, userID: UInt32, startSeconds: UInt64, startMicroseconds: UInt64) {
            self.processID = processID
            self.parentProcessID = parentProcessID
            self.userID = userID
            self.startSeconds = startSeconds
            self.startMicroseconds = startMicroseconds
        }

        public var runtimeID: String {
            "\(userID):\(processID):\(startSeconds):\(startMicroseconds)"
        }

        func wasStarted(after parent: Self) -> Bool {
            startSeconds > parent.startSeconds
                || (startSeconds == parent.startSeconds && startMicroseconds >= parent.startMicroseconds)
        }
    }

    public let processes: [Process]

    private init(processes: [Process]) {
        self.processes = processes
    }

    public func contains(processID: Int32, runtimeID: String) -> Bool {
        processes.contains { $0.processID == processID && $0.runtimeID == runtimeID }
    }

    /// Capture while the hook waits for receipt. Recheck the observed chain so
    /// a dead/reparented child or reused PID cannot inherit an old Agent identity.
    public static func capture(
        peerPID: Int32,
        userID: UInt32,
        inspect: (Int32) -> Process?
    ) -> Self? {
        var chain: [Process] = []
        var pid = peerPID
        while pid > 1, chain.count < 64 {
            guard
                let process = inspect(pid), process.processID == pid, process.userID == userID,
                process.startSeconds > 0, !chain.contains(where: { $0.processID == pid }) else { break }
            if let child = chain.last, !child.wasStarted(after: process) {
                return nil
            }
            chain.append(process)
            pid = process.parentProcessID
        }
        guard !chain.isEmpty, chain.allSatisfy({ inspect($0.processID) == $0 }) else { return nil }
        return Self(processes: chain)
    }
}
