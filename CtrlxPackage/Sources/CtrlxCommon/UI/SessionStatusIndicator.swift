import CtrlxNetworking
import Foundation
import SwiftUI

/// Attention shown on a session or tab. A question takes precedence when
/// another pane also needs attention.
public enum AgentAttention: Equatable, Sendable {
    case question
    case other

    public init?(state: AgentState) {
        guard state.needsAttention else { return nil }
        if case .awaitingReplies = state {
            self = .question
        } else {
            self = .other
        }
    }

    public init?(panes: some Sequence<PaneState>) {
        var hasAttention = false
        for pane in panes {
            guard let state = pane.agentSession?.state, let attention = Self(state: state) else { continue }
            if attention == .question {
                self = .question
                return
            }
            hasAttention = true
        }
        guard hasAttention else { return nil }
        self = .other
    }

    public var symbol: Symbols {
        self == .question ? .questionmarkCircle : .bellBadgeFill
    }

    public var accessibilityLabel: String {
        self == .question ? "Questions" : "Needs attention"
    }
}

public struct SessionStatusPresentation: Equatable, Sendable {
    enum Indicator: Equatable, Sendable {
        case attention(AgentAttention)
        case working
        case idle
    }

    let indicator: Indicator
    public let label: String

    public init?(agent: AgentSession?, cliState: CLISessionState?, panes: some Sequence<PaneState>) {
        if let cliState {
            self = .init(cliState: cliState)
            return
        }
        guard let agent else { return nil }
        if AgentAttention(panes: panes) == .question {
            self.indicator = .attention(.question)
            self.label = AgentAttention.question.accessibilityLabel
            return
        }
        if let attention = AgentAttention(state: agent.state) {
            self.indicator = .attention(attention)
        } else {
            self.indicator = agent.isWorking ? .working : .idle
        }
        self.label = agent.statusLabel
    }

    public init(cliState: CLISessionState) {
        switch cliState {
        case .working: self.indicator = .working
        case .idle: self.indicator = .idle
        case .waiting: self.indicator = .attention(.other)
        }
        self.label = cliState.statusLabel
    }
}

public struct SessionStatusIndicator: View {
    private let status: SessionStatusPresentation

    public init(status: SessionStatusPresentation) {
        self.status = status
    }

    public var body: some View {
        Group {
            switch status.indicator {
            case let .attention(attention):
                attention.symbol.image
                    .foregroundStyle(.orange)
            case .working:
                WorkingSpinner()
            case .idle:
                Symbols.sparkles.image
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(status.label)
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
