import Foundation

/// A live device on the Host. This descriptor grants no agent input authority.
public struct RemoteSimulatorTab: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sessionName: String
    public let windowID: String
    public let sourcePaneID: String
    public let title: String
    public let runtime: String
    public let isPrimary: Bool

    public init(
        id: UUID,
        sessionName: String,
        windowID: String,
        sourcePaneID: String,
        title: String,
        runtime: String,
        isPrimary: Bool
    ) {
        self.id = id
        self.sessionName = sessionName
        self.windowID = windowID
        self.sourcePaneID = sourcePaneID
        self.title = title
        self.runtime = runtime
        self.isPrimary = isPrimary
    }
}

/// Read-only: viewing never starts, closes, rotates or takes control of a device.
public struct BrowseSimulator: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage
    public let sessionName: String
    public let tabID: UUID
    public let frameMaxDimension: Int

    public let surfaceID: UUID?
    public let controlID: UUID?

    public init(sessionName: String, tabID: UUID, frameMaxDimension: Int = 1_024, surfaceID: UUID? = nil, controlID: UUID? = nil) {
        self.sessionName = sessionName
        self.tabID = tabID
        self.frameMaxDimension = frameMaxDimension
        self.surfaceID = surfaceID
        self.controlID = controlID
    }

    public var commandType: CommandType {
        .browseSimulator(self)
    }
}

/// Explicit human action: reuse or boot the source pane's default simulator.
public struct OpenPaneSimulator: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage
    public let sessionName: String
    public let sourcePaneID: String

    public init(sessionName: String, sourcePaneID: String) {
        self.sessionName = sessionName
        self.sourcePaneID = sourcePaneID
    }

    public var commandType: CommandType {
        .openPaneSimulator(self)
    }
}

public struct RemoteSimulatorFrame: Codable, Sendable, Equatable {
    public static let maximumBytes = 512 * 1_024
    public static let maximumDimension = 2_560
    public let jpeg: Data
    /// Encoded dimensions, already rotated to the device's displayed orientation.
    public let width: Int
    public let height: Int

    public let inputGeometry: RemoteSimulatorInputGeometry?

    public init(jpeg: Data, width: Int, height: Int, inputGeometry: RemoteSimulatorInputGeometry? = nil) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.inputGeometry = inputGeometry
    }

    public var isValid: Bool {
        !jpeg.isEmpty && jpeg.count <= Self.maximumBytes
            && (1...Self.maximumDimension).contains(width) && (1...Self.maximumDimension).contains(height)
    }
}

public struct RemoteSimulatorResponse: Codable, Sendable, Equatable {
    public let tab: RemoteSimulatorTab
    public let frame: RemoteSimulatorFrame

    public let controlID: UUID?
    public let generation: Int?

    public init(tab: RemoteSimulatorTab, frame: RemoteSimulatorFrame, controlID: UUID? = nil, generation: Int? = nil) {
        self.tab = tab
        self.frame = frame
        self.controlID = controlID
        self.generation = generation
    }
}

public struct RemoteSimulatorInputGeometry: Codable, Sendable, Equatable {
    public let epoch: String
    public let geometryVersion: UInt64
    public init(epoch: String, geometryVersion: UInt64) {
        self.epoch = epoch
        self.geometryVersion = geometryVersion
    }
}

public enum RemoteSimulatorControlOperation: Codable, Sendable, Equatable {
    case takeControl
    case releaseControl
    case touch(phase: Int, x: Double, y: Double, geometry: RemoteSimulatorInputGeometry)
    case copy
    case readClipboard
    case paste(WorkspaceClipboardContent)
}

public struct ControlSimulator: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage
    public let sessionName: String
    public let tabID: UUID
    public let surfaceID: UUID
    public let controlID: UUID?
    public let generation: Int?
    public let operation: RemoteSimulatorControlOperation

    public init(sessionName: String, tabID: UUID, surfaceID: UUID, controlID: UUID?, generation: Int?, operation: RemoteSimulatorControlOperation) {
        self.sessionName = sessionName
        self.tabID = tabID
        self.surfaceID = surfaceID
        self.controlID = controlID
        self.generation = generation
        self.operation = operation
    }

    public var commandType: CommandType {
        .controlSimulator(self)
    }
}

public struct RemoteSimulatorControlResponse: Codable, Sendable, Equatable {
    public let controlID: UUID?
    public let generation: Int
    public let clipboard: WorkspaceClipboardContent?
    public init(controlID: UUID?, generation: Int, clipboard: WorkspaceClipboardContent? = nil) {
        self.controlID = controlID
        self.generation = generation
        self.clipboard = clipboard
    }
}
