import Foundation

/// AAC-LC, 48 kHz stereo. Identity is scoped to one paired connection and lease.
public struct RemoteBrowserAudio: Codable, Sendable, Equatable {
    public static let sampleRate = 48_000.0
    public static let channels: UInt32 = 2
    public static let maximumPackets = 8
    public static let maximumBytes = 16 * 1_024

    public let tabID: UUID
    public let surfaceID: UUID
    public let controlID: UUID
    public let streamID: UUID
    public let sequence: UInt64
    public let packets: [Data]
    public let magicCookie: Data?
    public let error: String?

    public init(
        tabID: UUID,
        surfaceID: UUID,
        controlID: UUID,
        streamID: UUID,
        sequence: UInt64,
        packets: [Data],
        magicCookie: Data? = nil,
        error: String? = nil
    ) {
        self.tabID = tabID
        self.surfaceID = surfaceID
        self.controlID = controlID
        self.streamID = streamID
        self.sequence = sequence
        self.packets = packets
        self.magicCookie = magicCookie
        self.error = error
    }

    public var isValid: Bool {
        packets.count <= Self.maximumPackets && packets.allSatisfy { !$0.isEmpty && $0.count <= 4_096 }
            && packets.reduce(0) { $0 + $1.count } <= Self.maximumBytes
            && (magicCookie?.count ?? 0) <= 1_024 && (error?.utf8.count ?? 0) <= 512
            && (!packets.isEmpty || error != nil)
    }
}
