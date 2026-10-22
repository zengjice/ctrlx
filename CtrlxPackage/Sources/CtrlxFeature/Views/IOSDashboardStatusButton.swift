#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    @MainActor
    struct IOSDashboardStatusButton: View {
        let status: IOSDashboardStatus
        let openDashboard: () -> Void

        var body: some View {
            Button(action: openDashboard) {
                HStack(spacing: 6) {
                    connectionIndicator

                    (status.pendingCount > 0 ? Symbols.handsAndSparklesFill : .sparkles).image
                        .foregroundStyle(status.pendingCount > 0 ? Color.accentColor : .primary)
                    if let count = status.pendingText {
                        Text(count)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.accentColor)
                    }

                    if status.lowQuotaCount > 0 {
                        Symbols.exclamationmarkTriangle.image
                            .foregroundStyle(.orange)
                    }
                }
                .lineLimit(1)
                .fixedSize()
            }
            .accessibilityLabel("Dashboard")
            .accessibilityValue(status.accessibilityValue)
            .accessibilityHint("Open Dashboard")
            .accessibilityIdentifier("dashboard-open")
        }

        @ViewBuilder private var connectionIndicator: some View {
            switch status.connection {
            case .connected,
                 .partial:
                Circle()
                    .fill(status.connection == .connected ? Color.green : .orange)
                    .frame(width: 8, height: 8)
                if status.connection == .partial {
                    Text("\(status.connectedCount)/\(status.hostCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
            case .connecting:
                Symbols.arrowClockwise.image
                    .foregroundStyle(.orange)
            case .disconnected,
                 .unpaired:
                Symbols.wifiSlash.image
                    .foregroundStyle(status.connection == .disconnected ? Color.red : .secondary)
            }
        }
    }
#endif
