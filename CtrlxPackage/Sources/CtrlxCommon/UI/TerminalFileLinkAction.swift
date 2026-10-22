import SwiftUI

public struct TerminalFileLinkRequest: Hashable, Sendable {
    public let id = UUID()
    public let path: String
    public let paneID: String
    public let hostID: String?
    public let prefersPreview: Bool

    public init(path: String, paneID: String, hostID: String?, prefersPreview: Bool = true) {
        self.path = path
        self.paneID = paneID
        self.hostID = hostID
        self.prefersPreview = prefersPreview
    }
}

private struct TerminalFileLinkActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (TerminalFileLinkRequest) -> Void)? = nil
}

public extension EnvironmentValues {
    var openTerminalFileLink: (@MainActor (TerminalFileLinkRequest) -> Void)? {
        get { self[TerminalFileLinkActionKey.self] }
        set { self[TerminalFileLinkActionKey.self] = newValue }
    }
}
