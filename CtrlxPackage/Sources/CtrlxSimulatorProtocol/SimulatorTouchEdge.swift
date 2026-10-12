public enum SimulatorTouchEdge: String, Codable, Sendable, CaseIterable {
    case top, left, bottom, right

    /// DTUHID encodes the origin edge on the unrotated device surface.
    public func digitizerValue(in geometry: SimulatorGeometry) throws -> Int {
        guard geometry.isValid else { throw SimulatorFailure("The touch edge requires valid display geometry") }
        let value: Int
        switch self {
        case .top: value = 1
        case .left: value = 2
        case .bottom: value = 3
        case .right: value = 4
        }
        let turns: Int
        switch geometry.orientation {
        case 2: turns = 2
        case 3: turns = 3
        case 4: turns = 1
        default: turns = 0
        }
        return (value - 1 + turns) % 4 + 1
    }
}
