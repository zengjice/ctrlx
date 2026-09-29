import CtrlxCommon
import Foundation
import Testing

@Suite("App-owned terminal scrolling")
struct TerminalMouseScrollTests {
    @Test("Three-row compensation belongs only to fullscreen Codex")
    func profiles() {
        #expect(TerminalMouseScroll.rowsPerEvent(agentID: "codex", alternateScreen: true) == 3)
        #expect(TerminalMouseScroll.rowsPerEvent(agentID: "codex", alternateScreen: false) == 1)
        for agentID in [nil, "claude-code", "opencode", "vim"] {
            #expect(TerminalMouseScroll.rowsPerEvent(agentID: agentID, alternateScreen: true) == 1)
        }
    }

    @Test("A 30-row gesture sends ten Codex events, not thirty", arguments: [1.0, -1.0])
    func distance(direction: Double) {
        var scroll = TerminalMouseScrollAccumulator()
        let counts = (0..<120).map { _ in scroll.consume(delta: 4 * direction, pointsPerEvent: 16 * 3) }
        #expect(counts.reduce(0, +) == Int(10 * direction))
        #expect(counts.allSatisfy { abs($0) <= 1 })
    }

    @Test("Fractional deltas accumulate without changing with callback frequency", arguments: [60, 120, 240])
    func frequency(samples: Int) {
        var scroll = TerminalMouseScrollAccumulator()
        let total = (0..<samples).reduce(0) { count, _ in
            count + scroll.consume(delta: 480.0 / Double(samples), pointsPerEvent: 48)
        }
        #expect(total == 10)
    }

    @Test("Reversal forgets the previous direction's partial row")
    func reversal() {
        var scroll = TerminalMouseScrollAccumulator()
        #expect(scroll.consume(delta: 45, pointsPerEvent: 48) == 0)
        #expect(scroll.consume(delta: -24, pointsPerEvent: 48) == 0)
        #expect(scroll.consume(delta: -24, pointsPerEvent: 48) == -1)
        #expect(scroll.consume(delta: 48, pointsPerEvent: 48) == 1)
    }

    @Test("Gesture boundaries and changed profiles cannot reuse residual motion")
    func resetAndProfileChange() {
        var scroll = TerminalMouseScrollAccumulator()
        #expect(scroll.consume(delta: 45, pointsPerEvent: 48) == 0)
        scroll.reset()
        #expect(scroll.consume(delta: 10, pointsPerEvent: 48) == 0)
        #expect(scroll.consume(delta: 1, pointsPerEvent: 16) == 0)
        #expect(scroll.consume(delta: 15, pointsPerEvent: 16) == 1)
        #expect(scroll.consume(delta: 1, pointsPerEvent: 1) == 1)
    }

    @Test("Normal TUI sensitivity and discrete wheel notches stay unchanged")
    func standardMotion() {
        var scroll = TerminalMouseScrollAccumulator()
        #expect(scroll.consume(delta: 160, pointsPerEvent: 16) == 10)
        #expect(scroll.consume(delta: 3, pointsPerEvent: 1) == 3)
        #expect(scroll.consume(delta: -2, pointsPerEvent: 1) == -2)
    }

    @Test("Invalid or unbounded native deltas fail safely")
    func invalidDeltas() {
        var scroll = TerminalMouseScrollAccumulator()
        for delta in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            #expect(scroll.consume(delta: delta, pointsPerEvent: 16) == 0)
        }
        for threshold in [Double.nan, .infinity, 0, -1] {
            #expect(scroll.consume(delta: 10, pointsPerEvent: threshold) == 0)
        }
        #expect(scroll.consume(delta: 16, pointsPerEvent: 16) == 1)
    }

    @Test("Momentum is monotonic, bounded, and stops without another touch", arguments: [1.0, -1.0])
    func momentum(direction: Double) {
        var motion = TerminalScrollDeceleration()
        motion.start(velocity: 2_000 * direction, timestamp: 0)
        var distance: Double = 0
        var lastDelta = Double.infinity
        for frame in 1...60 {
            let delta = motion.advance(to: Double(frame) / 60) * direction
            #expect(delta >= 0)
            #expect(delta <= lastDelta)
            distance += delta
            lastDelta = delta
        }
        #expect(!motion.isActive)
        #expect(distance > 190 && distance < 200)
    }

    @Test("Momentum distance is frame-rate independent")
    func momentumFrameRate() {
        func distance(fps: Int) -> Double {
            var motion = TerminalScrollDeceleration()
            motion.start(velocity: 2_000, timestamp: 0)
            return (1...fps / 4).reduce(0) { sum, frame in
                sum + motion.advance(to: Double(frame) / Double(fps))
            }
        }
        #expect(abs(distance(fps: 60) - distance(fps: 120)) < 0.000_001)
    }

    @Test("A slow drag or invalid velocity does not start a coast")
    func noUnintendedMomentum() {
        for velocity in [0.0, 79, -79, .nan, .infinity] {
            var motion = TerminalScrollDeceleration()
            motion.start(velocity: velocity, timestamp: 0)
            #expect(!motion.isActive)
            #expect(motion.advance(to: 1.0 / 60) == 0)
        }
    }

    @Test("Interruptions cancel momentum, not replay it later")
    func interruption() {
        var motion = TerminalScrollDeceleration()
        motion.start(velocity: 1_000, timestamp: 0)
        #expect(motion.advance(to: 0.01) > 0)
        motion.cancel()
        #expect(motion.advance(to: 0.02) == 0)
        motion.start(velocity: -1_000, timestamp: 0.02)
        #expect(motion.advance(to: 0.03) < 0)
        #expect(motion.advance(to: 1) == 0)
        #expect(!motion.isActive)
    }

    @Test("Fling speed is capped and clock anomalies cancel safely")
    func bounds() {
        var motion = TerminalScrollDeceleration()
        motion.start(velocity: 100_000, timestamp: 0)
        #expect(motion.advance(to: 1.0 / 60) < 40)
        #expect(motion.advance(to: 0) == 0)
        #expect(!motion.isActive)
        motion.start(velocity: 1_000, timestamp: 0)
        #expect(motion.advance(to: .nan) == 0)
        #expect(!motion.isActive)
    }
}
