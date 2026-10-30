import CtrlxCommon
import CtrlxNetworking
import SwiftUI

/// Sidebar row displaying a remote tmux session, grouped by session name
struct RemoteSessionSidebarRow: View, Equatable {
    @Environment(AppSettings.self) private var settings
    let data: SessionSidebarData
    var homeDirectory: String?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data == rhs.data && lhs.homeDirectory == rhs.homeDirectory
    }

    var body: some View {
        rowContent
            .overlay(alignment: .leading) {
                SessionColorBar(color: data.customColor)
                    .padding(.leading, -16)
            }
            .overlay(alignment: .bottom) {
                if let sessionProgress = data.progress {
                    TerminalProgressBar(state: sessionProgress)
                        .padding(.bottom, -4)
                }
            }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 8) {
            SessionStatusBadge(
                cliSessionState: data.cliState,
                claudeSession: data.agent,
                customEmoji: data.customEmoji
            )

            SessionFieldsView(
                fields: data.agent != nil ? settings.sidebarFields : settings.sidebarTerminalFields,
                customDescription: data.customDescription,
                projectName: data.agent?.displayName,
                sessionName: data.sessionName,
                windowName: data.metadata.windowName,
                terminalTitle: data.metadata.terminalTitle,
                command: data.metadata.command,
                currentPath: data.metadata.currentPath,
                gitBranch: data.metadata.gitBranch,
                latestEvent: nil,
                homeDirectory: homeDirectory,
                primaryTextColor: settings.theme.sidebarPrimaryTextColor,
                secondaryTextColor: settings.theme.workspaceSecondaryTextColor
            )

            Spacer()
        }
        // Expose session name to macOS accessibility tree so e2e tests can find sessions
        // regardless of which sidebar fields are configured.
        .accessibilityValue(data.sessionName)
        // Invisible text exposing session status and project name to macOS accessibility
        // tree for e2e tests. The Button that wraps this row can combine children into a
        // single label, dropping leaf Texts — these hidden labels give tests stable targets.
        .overlay {
            SessionAccessibilityOverlay(
                status: data.cliState?.statusLabel ?? data.agent?.statusLabel,
                projectName: data.agent?.displayName
            )
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
