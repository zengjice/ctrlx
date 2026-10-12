import CtrlxSimulatorProtocol
import Foundation
import Testing

struct SimulatorPinchTests {
    @Test(arguments: [1, 2, 3, 4], [0.25, 0.5, 2, 4])
    func twoContactsPreserveCenterAndScaleThroughRotation(_ orientation: Int, _ scale: Double) throws {
        let geometry = SimulatorGeometry(width: 1179, height: 2556, scale: 3, orientation: orientation,
            geometryVersion: 1, epoch: UUID().uuidString)
        let center = SimulatorPoint(x: geometry.displayWidth / 2, y: geometry.displayHeight / 2)
        let (start, end) = try SimulatorPinch(center: center, scale: scale).contacts(in: geometry)
        #expect(start.count == 2 && end.count == 2)
        func distance(_ points: [SimulatorPoint]) -> Double {
            hypot(points[1].x - points[0].x, points[1].y - points[0].y)
        }
        #expect(abs(distance(end) / distance(start) - scale) < 0.000001)
        let expected = try geometry.normalizedDevicePoint(center)
        for pair in [start, end] {
            #expect(abs((pair[0].x + pair[1].x) / 2 - expected.x) < 0.000001)
            #expect(abs((pair[0].y + pair[1].y) / 2 - expected.y) < 0.000001)
            #expect(pair.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        }
    }

    @Test(arguments: [0.0, 1, 4.1, Double.nan, Double.infinity])
    func rejectsInvalidScale(_ scale: Double) {
        #expect(throws: SimulatorFailure.self) { try SimulatorPinch(center: .init(x: 100, y: 100), scale: scale) }
    }

    @Test(arguments: [SimulatorPoint(x: 0, y: 100), .init(x: 500, y: 100), .init(x: 100, y: 900)])
    func rejectsClippedOrDegenerateGesture(_ center: SimulatorPoint) throws {
        let gesture = try SimulatorPinch(center: center, scale: 2)
        let geometry = SimulatorGeometry(width: 1179, height: 2556, scale: 3, orientation: 1,
            geometryVersion: 1, epoch: UUID().uuidString)
        #expect(throws: SimulatorFailure.self) { try gesture.contacts(in: geometry) }
    }
}
