import CtrlxCommon
import CtrlxNetworking
import SwiftUI

@MainActor
struct TerminalWindowStatusBar: View {
    let hostID: String?
    let paneIDs: [String]
    let sessionName: String
    let windowIndex: Int
    let terminalSize: String?
    let telemetry: SessionTelemetry?
    let permissionMode: String?

    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 0) {
            TerminalQuickActionStatusBarButtons(hostID: hostID, paneIDs: paneIDs)
            Spacer(minLength: 0)

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
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(settings.theme.chromeBackgroundColor)
    }
}
