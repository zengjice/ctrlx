import Foundation

public struct SimulatorPinch: Sendable {
    public let center: SimulatorPoint
    public let scale: Double
    public let durationMs: Int

    public init(center: SimulatorPoint, scale: Double, durationMs: Int = 500) throws {
        guard center.x.isFinite, center.y.isFinite, center.x >= 0, center.y >= 0,
              scale.isFinite, (0.25...4).contains(scale), scale != 1,
              (20...5000).contains(durationMs) else {
            throw SimulatorFailure("pinch requires a finite center, scale 0.25...4 other than 1 and duration 20...5000 ms")
        }
        self.center = center
        self.scale = scale
        self.durationMs = durationMs
    }

    public func contacts(in geometry: SimulatorGeometry) throws -> (start: [SimulatorPoint], end: [SimulatorPoint]) {
        _ = try geometry.normalizedDevicePoint(center)
        // Fit a horizontal pair around the center without clipping either endpoint.
        let room = min(center.x, geometry.displayWidth - center.x) - 1
        let radius = min(50, room / max(1, scale))
        guard min(radius, radius * scale) >= 5 else {
            throw SimulatorFailure("Pinch center is too close to the screen edge; choose a point farther inside")
        }
        func pair(_ radius: Double) throws -> [SimulatorPoint] {
            try [-radius, radius].map { offset in
                try geometry.normalizedDevicePoint(SimulatorPoint(x: center.x + offset, y: center.y))
            }
        }
        return try (pair(radius), pair(radius * scale))
    }
}
