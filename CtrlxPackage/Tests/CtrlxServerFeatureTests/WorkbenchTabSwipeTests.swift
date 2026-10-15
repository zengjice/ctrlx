import AppKit
import Testing
@testable import CtrlxServerFeature

struct WorkbenchTabSwipeGestureTests {
    @Test("A completed horizontal gesture switches once and consumes its momentum", arguments: [-1.0, 1.0])
    func horizontal(sign: Double) {
        var gesture = WorkbenchTabSwipeGesture()
        #expect(gesture.consume(deltaX: 10 * sign, deltaY: 1, phase: .began).consumed)
        #expect(gesture.consume(deltaX: 80 * sign, deltaY: 2, phase: .changed).direction == nil)
        let end = gesture.consume(deltaX: 0, deltaY: 0, phase: .ended)
        #expect(end.consumed)
        #expect(end.direction == (sign < 0 ? 1 : -1))
        for phase: NSEvent.Phase in [.began, .changed, .ended] {
            let momentum = gesture.consume(deltaX: 120 * sign, deltaY: 0, phase: [], momentumPhase: phase)
            #expect(momentum.consumed)
            #expect(momentum.direction == nil)
        }
        #expect(gesture.consume(deltaX: 100, deltaY: 0, phase: .changed).direction == nil)
        #expect(gesture.consume(deltaX: 0, deltaY: 0, phase: .ended).direction == nil)
    }

    @Test("Vertical and diagonal scrolling cannot turn into tab navigation")
    func vertical() {
        for initialX in [0.0, 8.0] {
            var gesture = WorkbenchTabSwipeGesture()
            #expect(!gesture.consume(deltaX: 0, deltaY: 0, phase: .began).consumed)
            #expect(!gesture.consume(deltaX: initialX, deltaY: 10, phase: .changed).consumed)
            #expect(!gesture.consume(deltaX: 150, deltaY: 1, phase: .changed).consumed)
            #expect(gesture.consume(deltaX: 0, deltaY: 0, phase: .ended).direction == nil)
            #expect(!gesture.consume(deltaX: 100, deltaY: 0, phase: [], momentumPhase: .began).consumed)
        }
    }

    @Test("Short, reversed and cancelled gestures do not switch; the next gesture starts fresh")
    func abortedGestures() {
        var gesture = WorkbenchTabSwipeGesture()
        _ = gesture.consume(deltaX: -20, deltaY: 0, phase: .began)
        #expect(gesture.consume(deltaX: 0, deltaY: 0, phase: .ended).direction == nil)
        _ = gesture.consume(deltaX: -100, deltaY: 0, phase: .began)
        _ = gesture.consume(deltaX: 100, deltaY: 0, phase: .changed)
        #expect(gesture.consume(deltaX: 0, deltaY: 0, phase: .ended).direction == nil)
        _ = gesture.consume(deltaX: -100, deltaY: 0, phase: .began)
        #expect(gesture.consume(deltaX: 0, deltaY: 0, phase: .cancelled).direction == nil)
        _ = gesture.consume(deltaX: 80, deltaY: 0, phase: .began)
        #expect(gesture.consume(deltaX: 0, deltaY: 0, phase: .ended).direction == -1)
    }

    @Test("Tiny initial drift does not lock a vertical scroll into horizontal navigation")
    func initialDrift() {
        var gesture = WorkbenchTabSwipeGesture()
        _ = gesture.consume(deltaX: -0.5, deltaY: 0, phase: .began)
        #expect(!gesture.consume(deltaX: 0, deltaY: 20, phase: .changed).consumed)
        #expect(!gesture.consume(deltaX: -100, deltaY: 20, phase: .changed).consumed)
        #expect(gesture.consume(deltaX: 0, deltaY: 0, phase: .ended).direction == nil)
        _ = gesture.consume(deltaX: 0, deltaY: 0.5, phase: .began)
        #expect(gesture.consume(deltaX: -80, deltaY: 0, phase: .changed).consumed)
        #expect(gesture.consume(deltaX: 0, deltaY: 0, phase: .ended).direction == 1)
    }
}

@MainActor
@Suite(.serialized)
struct WorkbenchTabSwipeRoutingTests {
    @Test("Native content swipes retain their starting split and physical direction", arguments: [true, false])
    func splitAndDirection(natural: Bool) {
        let fixture = SwipeFixture()
        defer { fixture.close() }
        let leftwardDelta: CGFloat = natural ? -80 : 80
        #expect(fixture.send(x: 880, dx: leftwardDelta, phase: .began, natural: natural) == nil)
        #expect(fixture.send(x: 120, phase: .ended, natural: natural) == nil)
        #expect(fixture.switches.map(\.direction) == [1])
        #expect(fixture.switches.map(\.onRight) == [true])
        #expect(fixture.send(x: 120, dx: -leftwardDelta, phase: .began, natural: natural) == nil)
        _ = fixture.send(x: 880, phase: .ended, natural: natural)
        #expect(fixture.switches.map(\.direction) == [1, -1])
        #expect(fixture.switches.map(\.onRight) == [true, false])
        #expect(fixture.view.hitTest(.init(x: 10, y: 10)) == nil)
    }

    @Test("Sidebar, tab strip, hidden and inactive workbenches cannot capture a swipe")
    func scope() {
        let fixture = SwipeFixture()
        defer { fixture.close() }
        for point in [NSPoint(x: 20, y: 200), NSPoint(x: 200, y: 580)] {
            #expect(fixture.send(x: point.x, y: point.y, dx: -80, phase: .began) != nil)
            #expect(fixture.send(phase: .ended) != nil)
        }
        fixture.view.isHidden = true
        #expect(fixture.send(dx: -80, phase: .began) != nil)
        fixture.view.isHidden = false
        #expect(fixture.send(phase: .ended) != nil)
        fixture.view.isEnabled = false
        #expect(fixture.send(dx: -80, phase: .began) != nil)
        fixture.view.isEnabled = true
        fixture.window.keyForTesting = false
        #expect(fixture.send(dx: -80, phase: .began) != nil)
        #expect(fixture.switches.isEmpty)
    }

    @Test("Modified scrolling and mouse wheels keep their existing routing")
    func bypass() {
        let fixture = SwipeFixture()
        defer { fixture.close() }
        for flags: NSEvent.ModifierFlags in [.option, .command, .control, .shift] {
            #expect(fixture.send(dx: -80, phase: .began, modifiers: flags) != nil)
            #expect(fixture.send(phase: .ended, modifiers: flags) != nil)
        }
        #expect(fixture.send(dx: -80, phase: [], precise: false) != nil)
        #expect(fixture.send(dx: -80, phase: []) != nil)
        #expect(fixture.send(dy: 20, phase: .began) != nil)
        #expect(fixture.send(phase: .ended) != nil)
        #expect(fixture.switches.isEmpty)
    }

    @Test("Once the content owns a swipe, neither its tail nor momentum reaches the next tab")
    func momentum() {
        let fixture = SwipeFixture()
        defer { fixture.close() }
        #expect(fixture.send(dx: -80, phase: .began) == nil)
        #expect(fixture.send(phase: .ended) == nil)
        for phase: NSEvent.Phase in [.began, .changed, .ended] {
            #expect(fixture.send(x: 20, dx: -120, phase: [], momentum: phase) == nil)
        }
        #expect(fixture.switches.count == 1)
        #expect(fixture.send(dy: 20, phase: .began) != nil)
        #expect(fixture.send(phase: .ended) != nil)
    }
}

@MainActor
final private class SwipeFixture {
    let window: SwipeTestWindow
    let view = WorkbenchTabSwipeView(frame: NSRect(x: 100, y: 50, width: 800, height: 500))
    let tabs = SessionFileTabsState()
    var switches: [(direction: Int, onRight: Bool)] = []

    init() {
        _ = NSApplication.shared
        self.window = SwipeTestWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: .init(x: 0, y: 0, width: 900, height: 600))
        window.contentView?.addSubview(view)
        tabs.rightSide = [.window("@2")]
        tabs.splitRatio = 0.85
        view.tabs = tabs
        view.onSwipe = { [weak self] direction, onRight in self?.switches.append((direction, onRight)) }
    }

    func send(
        x: CGFloat = 200, y: CGFloat = 200, dx: CGFloat = 0, dy: CGFloat = 0,
        phase: NSEvent.Phase, momentum: NSEvent.Phase = [],
        modifiers: NSEvent.ModifierFlags = [], precise: Bool = true, natural: Bool = true
    ) -> NSEvent? {
        view.handle(SwipeTestEvent(window: window, point: .init(x: x, y: y), dx: dx, dy: dy, phase: phase, momentum: momentum, modifiers: modifiers, precise: precise, natural: natural))
    }

    func close() {
        view.stop()
        window.close()
    }
}

@MainActor
final private class SwipeTestWindow: NSWindow {
    var keyForTesting = true
    override var isKeyWindow: Bool {
        keyForTesting
    }
}

final private class SwipeTestEvent: NSEvent {
    private let targetWindow: NSWindow
    private let point: NSPoint
    private let dx: CGFloat
    private let dy: CGFloat
    private let eventPhase: NSEvent.Phase
    private let momentum: NSEvent.Phase
    private let flags: NSEvent.ModifierFlags
    private let precise: Bool
    private let natural: Bool

    init(window: NSWindow, point: NSPoint, dx: CGFloat, dy: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase, modifiers: NSEvent.ModifierFlags, precise: Bool, natural: Bool) {
        self.targetWindow = window
        self.point = point
        self.dx = dx
        self.dy = dy
        self.eventPhase = phase
        self.momentum = momentum
        self.flags = modifiers
        self.precise = precise
        self.natural = natural
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var type: NSEvent.EventType {
        .scrollWheel
    }

    override var window: NSWindow? {
        targetWindow
    }

    override var locationInWindow: NSPoint {
        point
    }

    override var scrollingDeltaX: CGFloat {
        dx
    }

    override var scrollingDeltaY: CGFloat {
        dy
    }

    override var phase: NSEvent.Phase {
        eventPhase
    }

    override var momentumPhase: NSEvent.Phase {
        momentum
    }

    override var modifierFlags: NSEvent.ModifierFlags {
        flags
    }

    override var hasPreciseScrollingDeltas: Bool {
        precise
    }

    override var isDirectionInvertedFromDevice: Bool {
        natural
    }
}
