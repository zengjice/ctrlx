#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    @MainActor
    struct IOSDashboardStatusButton: View {
        let status: IOSDashboardStatus
        let openDashboard: () -> Void

        var body: some View {
            Button(action: openDashboard) {
                HStack(spacing: 4) {
                    connectionIndicator.accessibilityHidden(true)
                    HStack(alignment: .top, spacing: 3) {
                        Symbols.gaugeWithDotsNeedle50percent.image
                        if status.lowQuotaCount > 0 {
                            Symbols.exclamationmarkTriangle.image
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .accessibilityLabel("Dashboard")
            .accessibilityValue(status.dashboardAccessibilityValue)
            .accessibilityIdentifier("dashboard-open")
        }

        @ViewBuilder private var connectionIndicator: some View {
            switch status.connection {
            case .connected:
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
            case .partial:
                Text("\(status.connectedCount)/\(status.hostCount)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .fixedSize()
            case .connecting:
                Symbols.arrowClockwise.image
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .disconnected,
                 .unpaired:
                Symbols.wifiSlash.image
                    .font(.caption)
                    .foregroundStyle(status.connection == .disconnected ? Color.red : .secondary)
            }
        }
    }

    @MainActor
    struct IOSAttentionButton: View {
        let status: IOSDashboardStatus
        let openAttention: () -> Void

        var body: some View {
            Button(action: openAttention) {
                HStack(alignment: .top, spacing: 2) {
                    Symbols.bellFill.image
                        .foregroundStyle(status.pendingCount > 0 ? Color.accentColor : .primary)
                    if let count = status.pendingText {
                        Text(count)
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 3)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: .capsule)
                            .fixedSize()
                    }
                }
            }
            .accessibilityLabel("Needs Attention")
            .accessibilityValue(status.attentionAccessibilityValue)
            .accessibilityIdentifier("attention-open")
        }
    }
#endif
