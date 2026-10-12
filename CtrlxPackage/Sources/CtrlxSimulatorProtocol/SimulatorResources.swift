import Foundation

public enum SimulatorProfile: String, Codable, Sendable, CaseIterable {
    case standard
    case balanced
}

public struct SimulatorConfiguration: Codable, Sendable, Equatable {
    public var maximumDevices: Int
    public var memoryReserveMiB: Int
    public var diskReserveMiB: Int

    public init(maximumDevices: Int = 2, memoryReserveMiB: Int = 3072, diskReserveMiB: Int = 2048) {
        self.maximumDevices = maximumDevices
        self.memoryReserveMiB = memoryReserveMiB
        self.diskReserveMiB = diskReserveMiB
    }

    public func validate() throws {
        guard (1...32).contains(maximumDevices), (512...65536).contains(memoryReserveMiB), (512...65536).contains(diskReserveMiB) else {
            throw SimulatorFailure("Device limit must be 1...32; memory and disk reserves must be 512...65536 MiB")
        }
    }

    public func admit(_ resources: SimulatorResources) throws {
        try validate()
        guard resources.pressureLevel == 1 else {
            throw SimulatorFailure("Memory pressure is elevated; simulator admission refused")
        }
        guard resources.reclaimableBytes >= UInt64(memoryReserveMiB) * 1024 * 1024 else {
            throw SimulatorFailure("Insufficient reclaimable memory for the configured simulator reserve")
        }
        guard resources.freeDiskBytes >= UInt64(diskReserveMiB) * 1024 * 1024 else {
            throw SimulatorFailure("Insufficient free disk space for the configured simulator reserve")
        }
    }
}

public struct SimulatorResources: Codable, Sendable, Equatable {
    public let physicalBytes: UInt64
    public let reclaimableBytes: UInt64
    public let pressureLevel: Int
    public let swapUsedBytes: UInt64
    public let freeDiskBytes: UInt64

    public init(physicalBytes: UInt64, reclaimableBytes: UInt64, pressureLevel: Int, swapUsedBytes: UInt64, freeDiskBytes: UInt64) {
        self.physicalBytes = physicalBytes
        self.reclaimableBytes = reclaimableBytes
        self.pressureLevel = pressureLevel
        self.swapUsedBytes = swapUsedBytes
        self.freeDiskBytes = freeDiskBytes
    }
}
