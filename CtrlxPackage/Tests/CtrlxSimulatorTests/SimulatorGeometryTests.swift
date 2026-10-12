import CtrlxSimulatorProtocol
import Foundation
import Testing

private func geometry(_ orientation: Int) -> SimulatorGeometry {
    SimulatorGeometry(width: 1179, height: 2556, scale: 3, orientation: orientation, geometryVersion: 1, epoch: UUID().uuidString)
}

@Test func portraitCoordinatesUseDevicePoints() throws {
    #expect(try geometry(1).normalizedDevicePoint(SimulatorPoint(x: 196.5, y: 426)) == SimulatorPoint(x: 0.5, y: 0.5))
    #expect(try geometry(1).normalizedDevicePoint(SimulatorPoint(x: 0, y: 0)) == SimulatorPoint(x: 0, y: 0))
}

@Test(arguments: [2, 3, 4]) func rotatedCornersMapToUnrotatedSurface(_ orientation: Int) throws {
    let g = geometry(orientation)
    let expected = [2: SimulatorPoint(x: 1, y: 1), 3: SimulatorPoint(x: 1, y: 0), 4: SimulatorPoint(x: 0, y: 1)]
    #expect(try g.normalizedDevicePoint(SimulatorPoint(x: 0, y: 0)) == expected[orientation])
    #expect(try g.normalizedDevicePoint(SimulatorPoint(x: g.displayWidth / 2, y: g.displayHeight / 2)) == SimulatorPoint(x: 0.5, y: 0.5))
}

@Test func invalidAndLetterboxCoordinatesAreRejected() {
    #expect(throws: SimulatorFailure.self) { try geometry(1).normalizedDevicePoint(SimulatorPoint(x: -1, y: 10)) }
    #expect(throws: SimulatorFailure.self) { try geometry(1).normalizedDevicePoint(SimulatorPoint(x: 394, y: 10)) }
    #expect(throws: SimulatorFailure.self) { try geometry(1).normalizedDevicePoint(SimulatorPoint(x: Double.nan, y: 10)) }
    #expect(throws: SimulatorFailure.self) { try geometry(0).normalizedDevicePoint(SimulatorPoint(x: 10, y: 10)) }
}

@Test func reusedPIDDoesNotReuseOwnership() {
    let old = SimulatorOwner(pid: 42, uid: 501, startSeconds: 100, startMicros: 1)
    let new = SimulatorOwner(pid: 42, uid: 501, startSeconds: 101, startMicros: 1)
    #expect(old != new)
    #expect(old.key != new.key)
}
