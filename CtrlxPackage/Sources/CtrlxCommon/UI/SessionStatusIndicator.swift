import CtrlxNetworking
import Foundation
import SwiftUI

/// Visual indicator for an agent session's current state:
/// - Needs attention: orange bell badge
/// - Working: spinning progress indicator
/// - Idle: gray sparkles
public struct SessionStatusIndicator: View {
    private enum DisplayState {
        case attention
        case working
        case idle
    }

    private let displayState: DisplayState
    private let label: String

    public init(session: AgentSession) {
        if session.needsAttention {
            self.displayState = .attention
        } else if session.isWorking {
            self.displayState = .working
        } else {
            self.displayState = .idle
        }
        self.label = session.statusLabel
    }

    public init(cliState: CLISessionState) {
        switch cliState {
        case .working: self.displayState = .working
        case .idle: self.displayState = .idle
        case .waiting: self.displayState = .attention
        }
        self.label = cliState.statusLabel
    }

    public var body: some View {
        Group {
            switch displayState {
            case .attention:
                Symbols.bellBadgeFill.image
                    .foregroundStyle(.orange)
            case .working:
                WorkingSpinner()
            case .idle:
                Symbols.sparkles.image
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(label)
    }
}

private struct WorkingSpinner: View {
    private static let refreshInterval: TimeInterval = 1.0 / 12.0
    private static let cycleDuration: TimeInterval = 1.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.cycleDuration)
                / Self.cycleDuration
            Circle()
                .trim(from: 0.12, to: 0.82)
                .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(phase * 360))
        }
        .frame(width: 12, height: 12)
    }
}
