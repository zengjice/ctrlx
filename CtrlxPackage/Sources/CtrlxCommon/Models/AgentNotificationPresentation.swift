import CtrlxNetworking
import Foundation

/// User-facing copy for an Agent notification.
///
/// The Agent plugin owns the event copy, while CtrlX adds the tmux location
/// already present in `PaneState`. Keeping this transformation pure lets the
/// Mac local, Mac Viewer and iOS APNs paths share the same notification copy.
public struct AgentNotificationPresentation: Equatable, Sendable {
    public let title: String
    public let subtitle: String?
    public let body: String
    public let agentID: AgentID?

    public init(
        title: String,
        subtitle: String? = nil,
        body: String,
        paneState: PaneState?,
        agentID: AgentID? = nil
    ) {
        self.agentID = agentID
        guard let paneState else {
            self.title = title
            self.subtitle = subtitle
            self.body = body
            return
        }

        let sessionName = paneState.sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionName.isEmpty else {
            self.title = title
            self.subtitle = subtitle
            self.body = body
            return
        }

        let windowName = paneState.windowName.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextTitle = windowName.isEmpty ? sessionName : "\(sessionName) · \(windowName)"
        self.title = Self.truncated(
            contextTitle,
            maximumUTF8Bytes: NotificationContent.maximumContextTitleBytes
        )
        self.subtitle = (subtitle ?? Self.statusTitle(for: title)).map {
            Self.truncated(
                $0,
                maximumUTF8Bytes: NotificationContent.maximumContextSubtitleBytes
            )
        }
        self.body = Self.removingRedundantContext(from: body, paneState: paneState)
    }

    private static func statusTitle(for title: String) -> String? {
        guard !title.isEmpty else { return nil }
        return title == "Session Idle" ? "Finished" : title
    }

    private static func truncated(_ value: String, maximumUTF8Bytes: Int) -> String {
        guard value.utf8.count > maximumUTF8Bytes else { return value }

        let ellipsis = "…"
        let ellipsisBytes = ellipsis.utf8.count
        var result = ""
        var usedBytes = 0
        for character in value {
            let characterBytes = String(character).utf8.count
            guard usedBytes + characterBytes + ellipsisBytes <= maximumUTF8Bytes else { break }
            result.append(character)
            usedBytes += characterBytes
        }
        return result + ellipsis
    }

    private static func removingRedundantContext(
        from body: String,
        paneState: PaneState
    ) -> String {
        let prefixes = [paneState.agentSession?.projectFolderName, paneState.sessionName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for prefix in prefixes {
            let marker = "\(prefix): "
            if body.hasPrefix(marker) {
                return String(body.dropFirst(marker.count))
            }
        }
        return body
    }
}
