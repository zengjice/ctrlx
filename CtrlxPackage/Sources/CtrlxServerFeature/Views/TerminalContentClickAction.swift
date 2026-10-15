import SwiftUI

private struct TerminalContentClickActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (_ hostID: String?, _ paneID: String) -> Void)? = nil
}

extension EnvironmentValues {
    var terminalContentClick: (@MainActor (_ hostID: String?, _ paneID: String) -> Void)? {
        get { self[TerminalContentClickActionKey.self] }
        set { self[TerminalContentClickActionKey.self] = newValue }
    }
}
