import Foundation

public struct SimulatorLogRequest: Sendable {
    public let bundle: String
    public let lastSeconds: Int
    public let maximumBytes: Int

    public init(bundle: String, lastSeconds: Int = 30, maximumBytes: Int = 65536) throws {
        try validateSimulatorBundle(bundle)
        guard (1...300).contains(lastSeconds), (1...262144).contains(maximumBytes) else {
            throw SimulatorFailure("Logs accept 1...300 seconds and 1...262144 bytes")
        }
        self.bundle = bundle
        self.lastSeconds = lastSeconds
        self.maximumBytes = maximumBytes
    }
}

public struct SimulatorCrashRequest: Sendable {
    public let bundle: String
    public let lastSeconds: Int
    public let limit: Int
    public let maximumBytes: Int

    public init(bundle: String, lastSeconds: Int = 3600, limit: Int = 5, maximumBytes: Int = 65536) throws {
        try validateSimulatorBundle(bundle)
        guard (1...86400).contains(lastSeconds), (1...10).contains(limit), (1...262144).contains(maximumBytes) else {
            throw SimulatorFailure("Crashes accept 1...86400 seconds, 1...10 reports and 1...262144 bytes total")
        }
        self.bundle = bundle
        self.lastSeconds = lastSeconds
        self.limit = limit
        self.maximumBytes = maximumBytes
    }
}
