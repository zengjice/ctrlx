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
    public let sourceAgent: AgentImageTarget?
    /// Display association, not an Agent control grant. Also set for plain terminals.
    public let sourcePaneID: String?
    /// Native Chrome UI has a separate control scope from the page viewport.
    public let isExtensionWindow: Bool?
    /// Optional display-only result. Launch requests never come from Viewers.
    public let externalApplicationNotice: BrowserExternalApplicationNotice?
    /// Presence advertises support for responding to this exact pending request.
    public let networkPermission: BrowserNetworkPermission?

    public init(
        id: UUID,
        sessionName: String,
        windowID: String? = nil,
        parentID: UUID? = nil,
        title: String,
        url: String,
        isLoading: Bool,
        isAgentOwned: Bool,
        isControlled: Bool = false,
        sourceAgent: AgentImageTarget? = nil,
        sourcePaneID: String? = nil,
        isExtensionWindow: Bool? = nil,
        externalApplicationNotice: BrowserExternalApplicationNotice? = nil,
        networkPermission: BrowserNetworkPermission? = nil
    ) {
        self.id = id
        self.sessionName = sessionName
        self.windowID = windowID
        self.parentID = parentID
        self.title = title
        self.url = url
        self.isLoading = isLoading
        self.isAgentOwned = isAgentOwned
        self.isControlled = isControlled
        self.sourceAgent = sourceAgent
        self.sourcePaneID = sourcePaneID
        self.isExtensionWindow = isExtensionWindow
        self.externalApplicationNotice = externalApplicationNotice
        self.networkPermission = networkPermission
    }
}

public struct BrowserNetworkPermission: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let origin: String
    public let localNetwork: Bool
    public let loopbackNetwork: Bool

    public init(id: UUID, origin: String, localNetwork: Bool, loopbackNetwork: Bool) {
        self.id = id
        self.origin = origin
        self.localNetwork = localNetwork
        self.loopbackNetwork = loopbackNetwork
    }
}

public struct BrowserExternalApplicationNotice: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let message: String
    public let isError: Bool

    public init(id: UUID = UUID(), message: String, isError: Bool) {
        self.id = id
        self.message = message
        self.isError = isError
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
    /// Optional, so older Hosts ignore it and older Viewers keep the legacy size.
    public let frameMaxDimension: Int?
    public let operation: RemoteBrowserOperation
    public let sourcePaneID: String?

    public init(
        sessionName: String,
        tabID: UUID? = nil,
        surfaceID: UUID,
        controlID: UUID? = nil,
        generation: UInt64? = nil,
        frameMaxDimension: Int? = nil,
        operation: RemoteBrowserOperation,
        sourcePaneID: String? = nil
    ) {
        self.sessionName = sessionName
        self.tabID = tabID
        self.surfaceID = surfaceID
        self.controlID = controlID
        self.generation = generation
        self.frameMaxDimension = frameMaxDimension
        self.operation = operation
        self.sourcePaneID = sourcePaneID
    }

    public var commandType: CommandType {
        .browseBrowser(self)
    }
}

public enum RemoteBrowserOperation: Codable, Sendable, Equatable {
    case create
    /// Open/reuse the source pane's human page. Nil URL only reveals it.
    case openPane(url: String?)
    case frame
    case takeControl
    case releaseControl
    case navigate(String)
    case back
    case forward
    case reload
    case close
    case fit(width: Int, height: Int)
    case copy
    case paste(WorkspaceClipboardContent)
    case text(String)
    case key(RemoteBrowserKey)
    case pointer(RemoteBrowserPointer)
    case extensions(RemoteBrowserExtensionOperation)
    case networkPermission(id: UUID, allow: Bool)

    public var isClipboardPaste: Bool {
        if case .paste = self {
            return true
        }
        return false
    }
}

public enum BrowserWebURL {
    public static func isSupported(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return false }
        return ["http", "https"].contains(parts.scheme?.lowercased() ?? "")
            && !(parts.host ?? "").isEmpty && parts.user == nil && parts.password == nil
            && url.absoluteString.utf8.count <= 8_192
    }

    /// Match the browser's origin spelling without changing path/query/fragment semantics.
    public static func normalized(_ url: URL) -> URL? {
        guard isSupported(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "http" && parts.port == 80) || (parts.scheme == "https" && parts.port == 443) {
            parts.port = nil
        }
        if parts.percentEncodedPath.isEmpty {
            parts.percentEncodedPath = "/"
        }
        return parts.url
    }
}

public struct RemoteBrowserKey: Codable, Sendable, Equatable {
    public let key: String
    public let keyCode: Int
    /// CDP mask: Alt=1, Control=2, Meta=4, Shift=8.
    public let modifiers: Int
    public init(_ key: String, keyCode: Int, modifiers: Int = 0) {
        self.key = key
        self.keyCode = keyCode
        self.modifiers = modifiers
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

    public init(
        _ kind: Kind,
        x: Double,
        y: Double,
        button: Button = .none,
        buttons: Int = 0,
        modifiers: Int = 0,
        clickCount: Int = 1,
        deltaX: Double = 0,
        deltaY: Double = 0
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.buttons = buttons
        self.modifiers = modifiers
        self.clickCount = clickCount
        self.deltaX = deltaX
        self.deltaY = deltaY
    }

    public var isValid: Bool {
        x.isFinite && y.isFinite && (0...8_192).contains(x) && (0...8_192).contains(y)
            && deltaX.isFinite && deltaY.isFinite && abs(deltaX) <= 4_096 && abs(deltaY) <= 4_096
            && (0...7).contains(buttons) && (0...15).contains(modifiers) && (0...3).contains(clickCount)
    }
}

public struct RemoteBrowserFrame: Codable, Sendable, Equatable {
    public static let maximumBytes = 512 * 1_024
    public static let maximumDimension = 2_560
    public let jpeg: Data
    /// Source size: CSS viewport for pages, Host window points for extension UI.
    /// Neither is measured in JPEG pixels or Viewer points.
    public let width: Double
    public let height: Double
    public let generation: UInt64
    public init(jpeg: Data, width: Double, height: Double, generation: UInt64) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.generation = generation
    }

    public var isValid: Bool {
        !jpeg.isEmpty && jpeg.count <= Self.maximumBytes && width.isFinite && height.isFinite
            && (1...8_192).contains(width) && (1...8_192).contains(height)
    }
}

public struct RemoteBrowserResponse: Codable, Sendable, Equatable {
    public let tab: RemoteBrowserTab?
    public let frame: RemoteBrowserFrame?
    public let controlID: UUID?
    public let extensions: RemoteBrowserExtensionResult?
    public let clipboard: WorkspaceClipboardContent?
    public init(
        tab: RemoteBrowserTab? = nil,
        frame: RemoteBrowserFrame? = nil,
        controlID: UUID? = nil,
        extensions: RemoteBrowserExtensionResult? = nil,
        clipboard: WorkspaceClipboardContent? = nil
    ) {
        self.tab = tab
        self.frame = frame
        self.controlID = controlID
        self.extensions = extensions
        self.clipboard = clipboard
    }
}
