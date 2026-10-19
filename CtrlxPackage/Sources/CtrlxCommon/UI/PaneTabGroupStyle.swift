import SwiftUI

public enum PaneTabGroupStyle {
    /// Deterministic across launches and reorders (Swift Hasher is process-random).
    public static func color(for source: String?) -> Color {
        guard let source else { return .secondary }
        let hash = source.utf8.reduce(UInt64(5_381)) { ($0 &* 33) &+ UInt64($1) }
        let colors: [Color] = [.teal, .blue, .purple, .orange, .pink, .indigo]
        return colors[Int(hash % UInt64(colors.count))]
    }
}

/// A List section's rows share one outline, without affecting native row moves.
public struct PaneTabGroupRowBorder: Shape {
    public var first: Bool
    public var last: Bool

    public init(first: Bool, last: Bool) {
        self.first = first
        self.last = last
    }

    public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 1, dy: 0)
        let radius: CGFloat
        if #available(iOS 26, *) {
            radius = 26
        } else {
            radius = 12
        }
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: last ? r.maxY - radius : r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: first ? r.minY + radius : r.minY))
        if first {
            path.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY + 1), control: CGPoint(x: r.minX, y: r.minY + 1))
            path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY + 1))
            path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + radius), control: CGPoint(x: r.maxX, y: r.minY + 1))
        } else {
            path.move(to: CGPoint(x: r.maxX, y: r.minY))
        }
        path.addLine(to: CGPoint(x: r.maxX, y: last ? r.maxY - radius : r.maxY))
        if last {
            path.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY - 1), control: CGPoint(x: r.maxX, y: r.maxY - 1))
            path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY - 1))
            path.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY - 1))
        }
        return path
    }
}
