import CtrlxNetworking
import Foundation

/// Quick Fork has no form: only its new tab name differs from the source setup.
enum AgentForkShortcut {
    static func request(source: AgentForkSource, tabName: String, date: Date, timeZone: TimeZone = .current) -> ForkAgentSession {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return ForkAgentSession(source: source, windowName: tabName + "-" + formatter.string(from: date), inheritsSourceConfiguration: true)
    }
}

extension SessionFileTabsState {
    func showForkSplit(sourceWindowID: String, forkWindowID: String) {
        rightSide.remove(.window(sourceWindowID))
        rightSide.insert(.window(forkWindowID))
        selectedRight = .window(forkWindowID)
        splitRatio = 0.5
        isRightPaneFocused = true
    }
}
