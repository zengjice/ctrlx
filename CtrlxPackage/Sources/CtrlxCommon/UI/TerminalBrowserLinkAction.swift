import SwiftUI

public struct TerminalBrowserLinkRequest: Hashable, Sendable {
    public let id = UUID()
    public let url: URL?
    public let paneID: String
    public let hostID: String

    public init(url: URL? = nil, paneID: String, hostID: String) {
        self.url = url
        self.paneID = paneID
        self.hostID = hostID
    }
}

private struct TerminalBrowserLinkActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (TerminalBrowserLinkRequest) -> Void)? = nil
}

extension EnvironmentValues {
    public var openTerminalBrowserLink: (@MainActor (TerminalBrowserLinkRequest) -> Void)? {
        get { self[TerminalBrowserLinkActionKey.self] }
        set { self[TerminalBrowserLinkActionKey.self] = newValue }
    }
}
