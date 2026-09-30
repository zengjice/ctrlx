import CtrlxCommon
import Foundation

enum TmuxWindowFitLayout {
    static func layoutString(_ layout: LayoutNode, width: Int, height: Int) -> String? {
        guard let fitted = resized(layout, width: width, height: height) else { return nil }
        let body = serialize(fitted, x: 0, y: 0)
        let checksum = body.utf8.reduce(UInt16(0)) { value, byte in
            ((value >> 1) | (value << 15)) &+ UInt16(byte)
        }
        return String(format: "%04x", checksum) + "," + body
    }

    private static func minimumSize(_ node: LayoutNode) -> (width: Int, height: Int) {
        switch node {
        case .pane:
            return (2, 2)
        case let .horizontal(children, _, _):
            let sizes = children.map(minimumSize)
            return (sizes.reduce(children.count - 1) { $0 + $1.width }, sizes.map(\.height).max() ?? 0)
        case let .vertical(children, _, _):
            let sizes = children.map(minimumSize)
            return (sizes.map(\.width).max() ?? 0, sizes.reduce(children.count - 1) { $0 + $1.height })
        }
    }

    private static func resized(_ node: LayoutNode, width: Int, height: Int) -> LayoutNode? {
        let minimum = minimumSize(node)
        guard width >= minimum.width, height >= minimum.height, node.width > 0, node.height > 0 else { return nil }
        switch node {
        case let .pane(id, _, _):
            return .pane(id: id, width: width, height: height)
        case let .horizontal(children, _, _), let .vertical(children, _, _):
            guard !children.isEmpty, children.allSatisfy({ $0.width > 0 && $0.height > 0 }) else { return nil }
            let horizontal: Bool = if case .horizontal = node { true } else { false }
            let weights = children.map { horizontal ? $0.width : $0.height }
            let minimums = children.map { child in
                let size = minimumSize(child)
                return horizontal ? size.width : size.height
            }
            var remaining = (horizontal ? width : height) - (children.count - 1)
            var remainingWeight = weights.reduce(0, +)
            var reserved = minimums.reduce(0, +)
            var fitted: [LayoutNode] = []
            for (index, child) in children.enumerated() {
                reserved -= minimums[index]
                // Round proportional shares, reserving enough room for every
                // remaining subtree instead of letting tmux collapse it to 1.
                let ideal = Int((Double(remaining) * Double(weights[index]) / Double(remainingWeight)).rounded())
                let size = min(remaining - reserved, max(minimums[index], ideal))
                guard let resizedChild = resized(child, width: horizontal ? size : width,
                                                height: horizontal ? height : size) else { return nil }
                fitted.append(resizedChild)
                remaining -= size
                remainingWeight -= weights[index]
            }
            return horizontal ? .horizontal(children: fitted, width: width, height: height)
                : .vertical(children: fitted, width: width, height: height)
        }
    }

    private static func serialize(_ node: LayoutNode, x: Int, y: Int) -> String {
        let prefix = "\(node.width)x\(node.height),\(x),\(y)"
        switch node {
        case let .pane(id, _, _):
            return prefix + ",\(id)"
        case let .horizontal(children, _, _), let .vertical(children, _, _):
            let horizontal: Bool = if case .horizontal = node { true } else { false }
            var offset = horizontal ? x : y
            let bodies = children.map { child in
                let body = serialize(child, x: horizontal ? offset : x, y: horizontal ? y : offset)
                offset += (horizontal ? child.width : child.height) + 1
                return body
            }
            return prefix + (horizontal ? "{" : "[") + bodies.joined(separator: ",") + (horizontal ? "}" : "]")
        }
    }
}
