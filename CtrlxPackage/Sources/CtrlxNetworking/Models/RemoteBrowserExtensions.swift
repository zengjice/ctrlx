import Foundation

/// Explicit profile management, separate from the ordinary page control lease.
/// Package paths and native window identifiers never cross this boundary.
public enum RemoteBrowserExtensionOperation: Codable, Sendable, Equatable {
    case acquire
    case release
    case list
    case openWindow
    case showSurface(RemoteBrowserExtensionSurface)
    case prepareStore(input: String, replacingID: String?)
    case beginUpload(id: UUID, name: String, size: Int, replacingID: String?)
    case appendUpload(id: UUID, offset: Int, data: Data)
    case finishUpload(id: UUID, sha256: String)
    case cancelUpload(UUID)
    case install(UUID)
    case discard(UUID)
    case setEnabled(id: String, enabled: Bool)
    case remove(String)
    case frame
    case text(String)
    case key(RemoteBrowserKey)
    case pointer(RemoteBrowserPointer)
    case fit(width: Int, height: Int)
}

public enum RemoteBrowserExtensionSurface: String, Codable, Sendable {
    case page
    case manager
}

public struct RemoteBrowserExtension: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let state: String
    public let canUpdate: Bool
    public var isEnabled: Bool {
        state == "ENABLED"
    }

    public init(id: String, name: String, version: String, state: String, canUpdate: Bool) {
        self.id = id
        self.name = name
        self.version = version
        self.state = state
        self.canUpdate = canUpdate
    }
}

/// A Host-issued receipt for exactly the package whose permissions were shown.
public struct RemoteBrowserExtensionPreview: Codable, Sendable, Equatable, Identifiable {
    public enum Source: String, Codable, Sendable { case zip, crx, webStore }
    public let id: UUID
    public let source: Source
    public let name: String
    public let version: String
    public let extensionID: String
    public let sha256: String
    public let permissions: [String]
    public let hostPermissions: [String]
    public let contentScriptMatches: [String]
    public let optionalPermissions: [String]
    public let optionalHostPermissions: [String]
    public let previousVersion: String?
    public let previousSource: Source?

    public init(
        id: UUID,
        source: Source,
        name: String,
        version: String,
        extensionID: String,
        sha256: String,
        permissions: [String],
        hostPermissions: [String],
        contentScriptMatches: [String],
        optionalPermissions: [String],
        optionalHostPermissions: [String],
        previousVersion: String? = nil,
        previousSource: Source? = nil
    ) {
        self.id = id
        self.source = source
        self.name = name
        self.version = version
        self.extensionID = extensionID
        self.sha256 = sha256
        self.permissions = permissions
        self.hostPermissions = hostPermissions
        self.contentScriptMatches = contentScriptMatches
        self.optionalPermissions = optionalPermissions
        self.optionalHostPermissions = optionalHostPermissions
        self.previousVersion = previousVersion
        self.previousSource = previousSource
    }
}

public struct RemoteBrowserExtensionResult: Codable, Sendable, Equatable {
    public let entries: [RemoteBrowserExtension]?
    public let prepared: RemoteBrowserExtensionPreview?
    public let uploadOffset: Int?
    public let surface: RemoteBrowserExtensionSurface?

    public init(
        entries: [RemoteBrowserExtension]? = nil,
        prepared: RemoteBrowserExtensionPreview? = nil,
        uploadOffset: Int? = nil,
        surface: RemoteBrowserExtensionSurface? = nil
    ) {
        self.entries = entries
        self.prepared = prepared
        self.uploadOffset = uploadOffset
        self.surface = surface
    }
}
