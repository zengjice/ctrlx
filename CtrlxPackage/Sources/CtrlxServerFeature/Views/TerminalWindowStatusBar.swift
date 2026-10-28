import CtrlxCommon
import CtrlxNetworking
import SwiftUI

@MainActor
struct TerminalWindowStatusBar: View {
    let hostID: String?
    let paneIDs: [String]
    let activePaneID: String?
    let sessionName: String
    let windowIndex: Int
    let terminalSize: String?
    let telemetry: SessionTelemetry?
    let permissionMode: String?

    @Environment(AppSettings.self) private var settings
    @Environment(\.terminalQuickActions) private var router
    @State private var voiceSession = TerminalVoiceInputSession()

    static func modelTarget(
        hostID: String?, paneIDs: [String], activePaneID: String?,
        focused: TerminalQuickActionEndpoint?
    ) -> PaneKey? {
        let paneID: String?
        if let focused, focused.hostID == hostID, focused.isAvailable, paneIDs.contains(focused.paneID) {
            paneID = focused.paneID
        } else {
            paneID = activePaneID
        }
        guard let paneID, paneIDs.contains(paneID) else { return nil }
        return PaneKey(pairId: hostID ?? "local", paneId: paneID)
    }

    var body: some View {
        HStack(spacing: 0) {
            TerminalQuickActionStatusBarButtons(hostID: hostID, paneIDs: paneIDs, voiceSession: voiceSession)
            if let target = Self.modelTarget(hostID: hostID, paneIDs: paneIDs, activePaneID: activePaneID, focused: router?.active) {
                AgentModelStatusBar(hostID: hostID, paneID: target.paneId)
                    .id(target)
            } else {
                Spacer(minLength: 0)
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("\(sessionName):\(windowIndex)")
                        .font(.system(.caption, design: .monospaced))

                    if paneIDs.count > 1 {
                        Divider()
                            .frame(height: 12)

                        Text("\(paneIDs.count) panes")
                    }

                    if let terminalSize {
                        Divider()
                            .frame(height: 12)

                        Text(terminalSize)
                    }

                    SessionTelemetryStatusBar(
                        telemetry: telemetry,
                        permissionMode: permissionMode
                    )
                }
                .padding(.leading, 12)
                Text("\(sessionName):\(windowIndex)")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.leading, 12)
                // Hide details and their gap before they widen the workbench split.
                Color.clear.frame(width: 0, height: 0)
            }
            .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(settings.theme.workspaceSecondaryTextColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(settings.theme.chromeBackgroundColor)
        .modifier(MacVoiceInputOverlay(session: voiceSession))
    }
}
