import SwiftUI

public struct TerminalFileLinkRequest: Hashable, Sendable {
    public let id = UUID()
    public let path: String
    public let paneID: String
    public let hostID: String?

    public init(path: String, paneID: String, hostID: String?) {
        self.path = path
        self.paneID = paneID
        self.hostID = hostID
    }
}

private struct TerminalFileLinkActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (TerminalFileLinkRequest) -> Void)? = nil
}

extension EnvironmentValues {
    public var openTerminalFileLink: (@MainActor (TerminalFileLinkRequest) -> Void)? {
        get { self[TerminalFileLinkActionKey.self] }
        set { self[TerminalFileLinkActionKey.self] = newValue }
    }
}
