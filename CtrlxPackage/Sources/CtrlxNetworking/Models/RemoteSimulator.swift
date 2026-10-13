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

    public init(sessionName: String, tabID: UUID, frameMaxDimension: Int = 1_024) {
        self.sessionName = sessionName
        self.tabID = tabID
        self.frameMaxDimension = frameMaxDimension
    }

    public var commandType: CommandType {
        .browseSimulator(self)
    }
}

public struct RemoteSimulatorFrame: Codable, Sendable, Equatable {
    public static let maximumBytes = 512 * 1_024
    public static let maximumDimension = 2_560
    public let jpeg: Data
    /// Encoded dimensions, already rotated to the device's displayed orientation.
    public let width: Int
    public let height: Int

    public init(jpeg: Data, width: Int, height: Int) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        !jpeg.isEmpty && jpeg.count <= Self.maximumBytes
            && (1...Self.maximumDimension).contains(width) && (1...Self.maximumDimension).contains(height)
    }
}

public struct RemoteSimulatorResponse: Codable, Sendable, Equatable {
    public let tab: RemoteSimulatorTab
    public let frame: RemoteSimulatorFrame

    public init(tab: RemoteSimulatorTab, frame: RemoteSimulatorFrame) {
        self.tab = tab
        self.frame = frame
    }
}
