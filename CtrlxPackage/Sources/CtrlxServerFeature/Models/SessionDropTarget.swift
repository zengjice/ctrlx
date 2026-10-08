import CtrlxCommon
import Foundation

struct SessionDropTarget: Equatable, Sendable {
    let sessionName: String
    let insertAfter: Bool

    static func resolve(
        at location: CGPoint,
        sessionNames: [String],
        rowFrames: [String: CGRect],
        excluding source: String
    ) -> Self? {
        guard sessionNames.contains(source) else { return nil }
        let visibleRows = sessionNames.compactMap { name -> (String, CGRect)? in
            guard let frame = rowFrames[name], !frame.isEmpty else { return nil }
            return (name, frame)
        }
        guard let (name, frame) = visibleRows
            .filter({ $0.1.insetBy(dx: 0, dy: -4).contains(location) })
            .min(by: { abs($0.1.midY - location.y) < abs($1.1.midY - location.y) }),
            name != source else { return nil }

        return Self(sessionName: name, insertAfter: location.y >= frame.midY)
    }

    func moving(_ sessionNames: [String], source: String) -> [String] {
        guard source != sessionName,
              let sourceIndex = sessionNames.firstIndex(of: source),
              let targetIndex = sessionNames.firstIndex(of: sessionName) else { return sessionNames }
        return RemoteSessionOrder.moving(
            sessionNames,
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: targetIndex + (insertAfter ? 1 : 0)
        )
    }
}
