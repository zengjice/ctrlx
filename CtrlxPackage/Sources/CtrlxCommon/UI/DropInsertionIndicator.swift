import SwiftUI

package enum InsertionSide: Equatable, Sendable {
    case before
    case after

    package init(position: CGFloat, length: CGFloat) {
        self = position < length / 2 ? .before : .after
    }

    package static func tabEdge(position: CGFloat, length: CGFloat) -> Self? {
        let edge = min(16, length / 3)
        if position < edge {
            return .before
        }
        if position >= length - edge {
            return .after
        }
        return nil
    }
}

package struct DropInsertionIndicator: View {
    let axis: Axis

    package init(axis: Axis) {
        self.axis = axis
    }

    package var body: some View {
        Capsule().fill(Color.accentColor)
            .frame(width: axis == .horizontal ? 3 : nil, height: axis == .vertical ? 3 : nil)
            .padding(axis == .horizontal ? .vertical : .horizontal, axis == .horizontal ? 4 : 14)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
