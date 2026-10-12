import Foundation

public struct SimulatorElementFrame: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var center: SimulatorPoint { SimulatorPoint(x: x + width / 2, y: y + height / 2) }
    public var isVisible: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }

    public func visibleCenter(in geometry: SimulatorGeometry) -> SimulatorPoint? {
        guard isVisible, geometry.isValid else { return nil }
        let left = max(0, x), top = max(0, y)
        let right = min(geometry.displayWidth, x + width), bottom = min(geometry.displayHeight, y + height)
        guard left < right, top < bottom else { return nil }
        return SimulatorPoint(x: (left + right) / 2, y: (top + bottom) / 2)
    }
}

public struct SimulatorElement: Codable, Sendable, Equatable {
    public let index: Int
    public let identifier: String?
    public let role: String?
    public let subrole: String?
    public let label: String?
    public let title: String?
    public let frame: SimulatorElementFrame
    public let visiblePoint: SimulatorPoint?
    public let visible: Bool?

    public init(index: Int, identifier: String? = nil, role: String? = nil, subrole: String? = nil,
        label: String? = nil, title: String? = nil, frame: SimulatorElementFrame, visiblePoint: SimulatorPoint? = nil, visible: Bool? = nil) {
        self.index = index; self.identifier = identifier; self.role = role; self.subrole = subrole
        self.label = label; self.title = title; self.frame = frame
        self.visiblePoint = visiblePoint
        self.visible = visible
    }

    public func isVisible(in geometry: SimulatorGeometry) -> Bool {
        visible == true && frame.visibleCenter(in: geometry) != nil
    }

    public func interactionPoint(in geometry: SimulatorGeometry) -> SimulatorPoint? {
        guard geometry.isValid, let visiblePoint, visiblePoint.x.isFinite, visiblePoint.y.isFinite,
            visiblePoint.x >= 0, visiblePoint.y >= 0,
            visiblePoint.x <= geometry.displayWidth, visiblePoint.y <= geometry.displayHeight
        else { return nil }
        return visiblePoint
    }

    public func hasSameIdentity(as other: Self) -> Bool {
        guard role == other.role, subrole == other.subrole else { return false }
        if let identifier, !identifier.isEmpty { return identifier == other.identifier }
        return identifier == other.identifier && label == other.label && title == other.title
    }
}

public struct SimulatorElementQuery: Sendable {
    public let identifier: String?
    public let label: String?
    public let role: String?

    public init(identifier: String? = nil, label: String? = nil, role: String? = nil) throws {
        let values = [identifier, label, role].compactMap { $0 }
        guard !values.isEmpty, values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else {
            throw SimulatorFailure("Provide a non-empty identifier, label or role selector (up to 1 KB each)")
        }
        self.identifier = identifier; self.label = label; self.role = role
    }

    public func matches(_ element: SimulatorElement) -> Bool {
        (identifier == nil || identifier == element.identifier)
            && (label == nil || label == element.label || label == element.title)
            && (role == nil || role == element.role)
    }
}
