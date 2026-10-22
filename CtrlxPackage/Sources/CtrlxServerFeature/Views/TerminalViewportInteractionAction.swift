import SwiftUI

private struct TerminalViewportInteractionActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (_ hostID: String?, _ paneID: String) -> Void)? = nil
}

extension EnvironmentValues {
    var terminalViewportInteraction: (@MainActor (_ hostID: String?, _ paneID: String) -> Void)? {
        get { self[TerminalViewportInteractionActionKey.self] }
        set { self[TerminalViewportInteractionActionKey.self] = newValue }
    }
}
