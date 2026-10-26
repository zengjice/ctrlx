#if os(macOS)
    import AppKit
    import Testing
    @testable import CtrlxCommon

    @MainActor
    struct MarkdownPreviewScrollingTests {
        @Test("Vertical scrolling over a horizontal code block reaches its document unchanged", arguments: [false, true])
        func codeBlockScroll(precise: Bool) {
            let fixture = Fixture()
            defer { fixture.close() }
            let event = fixture.event(dx: 1, dy: -120, precise: precise)

            #expect(fixture.support.handle(event) == nil)
            #expect(fixture.outer.events.count == 1)
            #expect(fixture.outer.events.first === event)
            #expect(fixture.inner.events.isEmpty)
            #expect(fixture.support.hitTest(.zero) == nil)
        }

        @Test("Horizontal, modified and independently vertical regions retain their input")
        func keepsOtherScrolling() {
            let fixture = Fixture()
            defer { fixture.close() }
            let horizontal = fixture.event(dx: -120, dy: 2)
            #expect(fixture.support.handle(horizontal) === horizontal)
            for modifier: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
                let event = fixture.event(dx: 0, dy: -120, modifiers: modifier)
                #expect(fixture.support.handle(event) === event)
            }
            fixture.inner.hasVerticalScroller = true
            let vertical = fixture.event(dx: 0, dy: -120)
            #expect(fixture.support.handle(vertical) === vertical)
            #expect(fixture.outer.events.isEmpty)
        }

        @Test("Only the visible Markdown preview in the event's window can forward scrolling")
        func scopedToPreview() {
            let fixture = Fixture()
            defer { fixture.close() }
            let other = Fixture()
            defer { other.close() }
            let otherWindow = other.event(dx: 0, dy: -120)
            #expect(fixture.support.handle(otherWindow) === otherWindow)
            let outside = fixture.event(dx: 0, dy: -120, point: .init(x: 20, y: 20))
            #expect(fixture.support.handle(outside) === outside)
            let event = fixture.event(dx: 0, dy: -120)
            fixture.support.isHidden = true
            #expect(fixture.support.handle(event) === event)
            fixture.support.isHidden = false
            fixture.inner.removeFromSuperview()
            #expect(fixture.support.handle(event) === event)
            fixture.support.removeFromSuperview()
            #expect(fixture.support.handle(event) === event)
            #expect(fixture.outer.events.isEmpty)
        }

        @MainActor
        final private class Fixture {
            let window: NSWindow
            let outer = RecordingScrollView(frame: .init(x: 100, y: 100, width: 500, height: 300))
            let inner = RecordingScrollView(frame: .init(x: 0, y: 0, width: 400, height: 250))
            let support = MarkdownScrollSupportView(frame: .init(x: 0, y: 0, width: 500, height: 1_500))

            init() {
                _ = NSApplication.shared
                self.window = NSWindow(
                    contentRect: .init(x: -10_000, y: -10_000, width: 700, height: 500),
                    styleMask: .borderless,
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView = NSView(frame: .init(x: 0, y: 0, width: 700, height: 500))
                outer.hasVerticalScroller = true
                outer.documentView = NSView(frame: .init(x: 0, y: 0, width: 500, height: 1_500))
                inner.hasHorizontalScroller = true
                inner.documentView = NSView(frame: .init(x: 0, y: 0, width: 1_500, height: 250))
                outer.documentView?.addSubview(support)
                outer.documentView?.addSubview(inner)
                window.contentView?.addSubview(outer)
                outer.contentView.scroll(to: .zero)
            }

            func event(dx: CGFloat, dy: CGFloat, precise: Bool = true, modifiers: NSEvent.ModifierFlags = [], point: NSPoint? = nil) -> ScrollEvent {
                ScrollEvent(
                    window: window,
                    point: point ?? inner.convert(.init(x: 100, y: 100), to: nil),
                    dx: dx,
                    dy: dy,
                    precise: precise,
                    modifiers: modifiers
                )
            }

            func close() {
                support.stop()
                window.close()
            }
        }

        final private class RecordingScrollView: NSScrollView {
            var events: [NSEvent] = []
            override func scrollWheel(with event: NSEvent) {
                events.append(event)
            }
        }

        final private class ScrollEvent: NSEvent {
            let targetWindow: NSWindow
            let point: NSPoint
            let dx: CGFloat
            let dy: CGFloat
            let precise: Bool
            let modifiers: NSEvent.ModifierFlags

            init(window: NSWindow, point: NSPoint, dx: CGFloat, dy: CGFloat, precise: Bool, modifiers: NSEvent.ModifierFlags) {
                self.targetWindow = window
                self.point = point
                self.dx = dx
                self.dy = dy
                self.precise = precise
                self.modifiers = modifiers
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

            override var scrollingDeltaY: CGFloat {
                dy
            }

            override var scrollingDeltaX: CGFloat {
                dx
            }

            override var hasPreciseScrollingDeltas: Bool {
                precise
            }

            override var modifierFlags: NSEvent.ModifierFlags {
                modifiers
            }
        }
    }
#endif
