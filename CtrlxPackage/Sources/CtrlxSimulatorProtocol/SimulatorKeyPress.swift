public struct SimulatorKeyPress: Sendable {
    public let events: [(usage: Int, down: Bool)]

    public init(usage: Int, modifiers: [String] = []) throws {
        guard (4...231).contains(usage) else {
            throw SimulatorFailure("key requires a USB HID keyboard usage (4...231)")
        }
        guard modifiers.count <= 4, Set(modifiers).count == modifiers.count else {
            throw SimulatorFailure("Provide each keyboard modifier at most once")
        }
        let supported = ["control": 224, "shift": 225, "alt": 226, "command": 227]
        let held = try modifiers.map { name in
            guard let modifier = supported[name] else {
                throw SimulatorFailure("Keyboard modifiers accept control, shift, alt or command")
            }
            guard !(224...231).contains(usage) else {
                throw SimulatorFailure("A modified key must use a non-modifier keyboard usage (4...223)")
            }
            return modifier
        }
        events = held.map { ($0, true) } + [(usage, true), (usage, false)] + held.reversed().map { ($0, false) }
    }
}
