import Foundation

public struct SimulatorPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct SimulatorGeometry: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let scale: Double
    /// UIKit interface orientation: 1 portrait, 2 upside-down, 3 right, 4 left.
    public let orientation: Int
    public let geometryVersion: UInt64
    public let epoch: String

    public init(width: Int, height: Int, scale: Double, orientation: Int, geometryVersion: UInt64, epoch: String) {
        self.width = width
        self.height = height
        self.scale = scale
        self.orientation = orientation
        self.geometryVersion = geometryVersion
        self.epoch = epoch
    }

    public var isValid: Bool {
        hasValidSurface && (1...4).contains(orientation)
    }

    public var isAwaitingOrientation: Bool {
        hasValidSurface && orientation == 0
    }

    private var hasValidSurface: Bool {
        width > 0 && height > 0 && width <= 16384 && height <= 16384
            && scale.isFinite && scale > 0
            && geometryVersion > 0 && UUID(uuidString: epoch) != nil
    }

    public var isLandscape: Bool { orientation == 3 || orientation == 4 }
    public var displayWidth: Double { Double(isLandscape ? height : width) / scale }
    public var displayHeight: Double { Double(isLandscape ? width : height) / scale }

    /// Points are measured from the displayed content's top-left, excluding letterbox.
    /// The transport receives normalized coordinates on the unrotated device surface.
    public func normalizedDevicePoint(_ point: SimulatorPoint) throws -> SimulatorPoint {
        guard isValid, point.x.isFinite, point.y.isFinite,
            point.x >= 0, point.x <= displayWidth, point.y >= 0, point.y <= displayHeight
        else {
            throw SimulatorFailure("Point is outside the current simulator geometry")
        }
        let x = point.x / displayWidth
        let y = point.y / displayHeight
        switch orientation {
        case 1: return SimulatorPoint(x: x, y: y)
        case 2: return SimulatorPoint(x: 1 - x, y: 1 - y)
        case 3: return SimulatorPoint(x: 1 - y, y: x)
        case 4: return SimulatorPoint(x: y, y: 1 - x)
        default: throw SimulatorFailure("Unsupported simulator orientation")
        }
    }
}

public struct SimulatorFailure: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct SimulatorOwner: Codable, Sendable, Equatable, Hashable {
    public let pid: Int32
    public let uid: UInt32
    public let startSeconds: UInt64
    public let startMicros: UInt64
    public var key: String { "\(uid):\(pid):\(startSeconds):\(startMicros)" }

    public init(pid: Int32, uid: UInt32, startSeconds: UInt64, startMicros: UInt64) {
        self.pid = pid
        self.uid = uid
        self.startSeconds = startSeconds
        self.startMicros = startMicros
    }
}
