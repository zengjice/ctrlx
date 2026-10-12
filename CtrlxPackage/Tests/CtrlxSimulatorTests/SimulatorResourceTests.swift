import CtrlxSimulatorProtocol
import Testing

struct SimulatorResourceTests {
    @Test func resourceAdmissionPreservesTheReserve() throws {
        let configuration = SimulatorConfiguration(maximumDevices: 8)
        let healthy = SimulatorResources(physicalBytes: 32 << 30, reclaimableBytes: 8 << 30, pressureLevel: 1,
            swapUsedBytes: 0, freeDiskBytes: 8 << 30)
        try configuration.admit(healthy)
        #expect(throws: SimulatorFailure.self) {
            try configuration.admit(SimulatorResources(physicalBytes: 32 << 30, reclaimableBytes: 2 << 30,
                pressureLevel: 1, swapUsedBytes: 0, freeDiskBytes: 8 << 30))
        }
        #expect(throws: SimulatorFailure.self) {
            try configuration.admit(SimulatorResources(physicalBytes: 32 << 30, reclaimableBytes: 8 << 30,
                pressureLevel: 1, swapUsedBytes: 0, freeDiskBytes: 1 << 30))
        }
    }

    @Test(arguments: [0, 2, 4]) func pressurePreventsNewBoots(level: Int) {
        #expect(throws: SimulatorFailure.self) {
            try SimulatorConfiguration().admit(SimulatorResources(physicalBytes: 32 << 30, reclaimableBytes: 16 << 30,
                pressureLevel: level, swapUsedBytes: 0, freeDiskBytes: 8 << 30))
        }
    }

    @Test(arguments: [0, 33]) func invalidDeviceLimitFails(limit: Int) {
        #expect(throws: SimulatorFailure.self) { try SimulatorConfiguration(maximumDevices: limit).validate() }
    }
}
