import CtrlxSimulatorProtocol
import Testing

struct SimulatorKeyPressTests {
    @Test func releasesTheMainKeyBeforeModifiersInReverseOrder() throws {
        let press = try SimulatorKeyPress(usage: 80, modifiers: ["command", "shift"])
        #expect(press.events.map(\.usage) == [227, 225, 80, 80, 225, 227])
        #expect(press.events.map(\.down) == [true, true, true, false, false, false])
    }

    @Test(arguments: [4, 223, 224, 231]) func preservesUnmodifiedKeyUsages(_ usage: Int) throws {
        let press = try SimulatorKeyPress(usage: usage)
        #expect(press.events.map(\.usage) == [usage, usage])
        #expect(press.events.map(\.down) == [true, false])
    }

    @Test(arguments: [
        (3, [String]()), (232, []), (4, ["shift", "shift"]), (4, ["meta"]),
        (4, [""]), (4, ["shift", "command", "alt", "control", "shift"]),
        (224, ["shift"]), (231, ["command"]),
    ]) func rejectsInvalidChordsBeforeProducingEvents(_ value: (Int, [String])) {
        #expect(throws: SimulatorFailure.self) { try SimulatorKeyPress(usage: value.0, modifiers: value.1) }
    }
}
