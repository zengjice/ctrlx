import CtrlxSimulatorProtocol
import Foundation
import Testing

struct SimulatorTouchEdgeTests {
    private func geometry(_ orientation: Int) -> SimulatorGeometry {
        SimulatorGeometry(width: 1179, height: 2556, scale: 3, orientation: orientation,
            geometryVersion: 1, epoch: UUID().uuidString)
    }

    @Test(arguments: [(SimulatorTouchEdge.top, 1), (.left, 2), (.bottom, 3), (.right, 4)])
    func portraitUsesDTUHIDWireValues(_ value: (SimulatorTouchEdge, Int)) throws {
        #expect(try value.0.digitizerValue(in: geometry(1)) == value.1)
    }

    @Test(arguments: [1, 2, 3, 4], SimulatorTouchEdge.allCases)
    func edgeMatchesTheRotatedContact(_ orientation: Int, _ edge: SimulatorTouchEdge) throws {
        let g = geometry(orientation)
        let point: SimulatorPoint
        switch edge {
        case .top: point = SimulatorPoint(x: g.displayWidth / 2, y: 0)
        case .left: point = SimulatorPoint(x: 0, y: g.displayHeight / 2)
        case .bottom: point = SimulatorPoint(x: g.displayWidth / 2, y: g.displayHeight)
        case .right: point = SimulatorPoint(x: g.displayWidth, y: g.displayHeight / 2)
        }
        let contact = try g.normalizedDevicePoint(point)
        let expected = contact.y == 0 ? 1 : contact.x == 0 ? 2 : contact.y == 1 ? 3 : 4
        #expect(try edge.digitizerValue(in: g) == expected)
    }

    @Test func unknownOrientationCannotTagAContact() {
        #expect(throws: SimulatorFailure.self) { try SimulatorTouchEdge.bottom.digitizerValue(in: geometry(0)) }
    }
}
