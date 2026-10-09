import Foundation

/// A Host page. Selection and zoom are device-local; cookies and DOM stay on Host.
public struct RemoteBrowserTab: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sessionName: String
    public let windowID: String?
    public let parentID: UUID?
    public let title: String
    public let url: String
    public let isLoading: Bool
    public let isAgentOwned: Bool
    public let isControlled: Bool

    public init(id: UUID, sessionName: String, windowID: String? = nil, parentID: UUID? = nil,
                title: String, url: String, isLoading: Bool, isAgentOwned: Bool, isControlled: Bool = false) {
        self.id = id; self.sessionName = sessionName; self.windowID = windowID; self.parentID = parentID
        self.title = title; self.url = url; self.isLoading = isLoading
        self.isAgentOwned = isAgentOwned; self.isControlled = isControlled
    }
}

public struct BrowseBrowser: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage
    public let sessionName: String
    public let tabID: UUID?
    /// Different surfaces on one Viewer cannot accidentally release each other.
    public let surfaceID: UUID
    public let controlID: UUID?
    public let generation: UInt64?
    public let operation: RemoteBrowserOperation

    public init(sessionName: String, tabID: UUID? = nil, surfaceID: UUID, controlID: UUID? = nil,
                generation: UInt64? = nil, operation: RemoteBrowserOperation) {
        self.sessionName = sessionName; self.tabID = tabID; self.surfaceID = surfaceID
        self.controlID = controlID; self.generation = generation; self.operation = operation
    }
    public var commandType: CommandType { .browseBrowser(self) }
}

public enum RemoteBrowserOperation: Codable, Sendable, Equatable {
    case create
    case frame
    case takeControl
    case releaseControl
    case navigate(String)
    case back, forward, reload, close
    case fit(width: Int, height: Int)
    case text(String)
    case key(RemoteBrowserKey)
    case pointer(RemoteBrowserPointer)
}

public struct RemoteBrowserKey: Codable, Sendable, Equatable {
    public let key: String
    public let keyCode: Int
    /// CDP mask: Alt=1, Control=2, Meta=4, Shift=8.
    public let modifiers: Int
    public init(_ key: String, keyCode: Int, modifiers: Int = 0) {
        self.key = key; self.keyCode = keyCode; self.modifiers = modifiers
    }
}

public struct RemoteBrowserPointer: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case down, up, move, scroll }
    public enum Button: String, Codable, Sendable { case none, left, right, middle }
    public let kind: Kind
    public let x: Double
    public let y: Double
    public let button: Button
    public let buttons: Int
    public let modifiers: Int
    public let clickCount: Int
    public let deltaX: Double
    public let deltaY: Double

    public init(_ kind: Kind, x: Double, y: Double, button: Button = .none, buttons: Int = 0,
                modifiers: Int = 0, clickCount: Int = 1, deltaX: Double = 0, deltaY: Double = 0) {
        self.kind = kind; self.x = x; self.y = y; self.button = button; self.buttons = buttons
        self.modifiers = modifiers; self.clickCount = clickCount; self.deltaX = deltaX; self.deltaY = deltaY
    }

    public var isValid: Bool {
        x.isFinite && y.isFinite && (0...8192).contains(x) && (0...8192).contains(y)
            && deltaX.isFinite && deltaY.isFinite && abs(deltaX) <= 4096 && abs(deltaY) <= 4096
            && (0...7).contains(buttons) && (0...15).contains(modifiers) && (0...3).contains(clickCount)
    }
}

public struct RemoteBrowserFrame: Codable, Sendable, Equatable {
    public static let maximumBytes = 180 * 1024
    public let jpeg: Data
    /// CSS viewport size, not JPEG pixels or Viewer points.
    public let width: Double
    public let height: Double
    public let generation: UInt64
    public init(jpeg: Data, width: Double, height: Double, generation: UInt64) {
        self.jpeg = jpeg; self.width = width; self.height = height; self.generation = generation
    }
    public var isValid: Bool {
        !jpeg.isEmpty && jpeg.count <= Self.maximumBytes && width.isFinite && height.isFinite
            && (1...8192).contains(width) && (1...8192).contains(height)
    }
}

public struct RemoteBrowserResponse: Codable, Sendable, Equatable {
    public let tab: RemoteBrowserTab?
    public let frame: RemoteBrowserFrame?
    public let controlID: UUID?
    public init(tab: RemoteBrowserTab? = nil, frame: RemoteBrowserFrame? = nil, controlID: UUID? = nil) {
        self.tab = tab; self.frame = frame; self.controlID = controlID
    }
}
