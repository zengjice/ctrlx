#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite("Mac voice popover dismissal", .serialized)
    struct MacVoiceInputPopoverTests {
        @Test("The microphone remains clickable while its preview is open")
        func microphoneClick() throws {
            let fixture = Fixture()
            defer { fixture.close() }
            fixture.show()
            #expect(fixture.anchor.popover.behavior == .applicationDefined)
            #expect(fixture.anchor.popover.isShown)
            #expect(fixture.anchor.hitTest(.zero) == nil)

            let event = try fixture.mouse(.leftMouseDown, at: NSPoint(x: 60, y: 35))
            #expect(fixture.anchor.handle(event) === event)
            #expect(fixture.cancellations == 0)
            #expect(fixture.anchor.popover.isShown)
        }

        @Test("Outside and secondary clicks cancel once", arguments: [false, true])
        func outsideClick(secondary: Bool) throws {
            let fixture = Fixture()
            defer { fixture.close() }
            fixture.show()
            let event = try fixture.mouse(
                secondary ? .rightMouseDown : .leftMouseDown,
                at: secondary ? NSPoint(x: 60, y: 35) : NSPoint(x: 250, y: 100)
            )
            #expect(fixture.anchor.handle(event) === event)
            #expect(fixture.cancellations == 1)
            #expect(!fixture.anchor.popover.isShown)
            _ = fixture.anchor.handle(event)
            #expect(fixture.cancellations == 1)
        }

        @Test("Preview controls are not treated as outside clicks")
        func previewClick() throws {
            let fixture = Fixture()
            defer { fixture.close() }
            fixture.show()
            let window = try #require(fixture.anchor.popover.contentViewController?.view.window)
            let event = try fixture.mouse(.leftMouseDown, at: NSPoint(x: 40, y: 30), window: window)
            #expect(fixture.anchor.handle(event) === event)
            #expect(fixture.cancellations == 0)
        }

        @Test("Escape cancels and is consumed in either window", arguments: [false, true])
        func escape(inPreview: Bool) throws {
            let fixture = Fixture()
            defer { fixture.close() }
            fixture.show()
            let window = try #require(inPreview ? fixture.anchor.popover.contentViewController?.view.window : fixture.window)
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
            ))
            #expect(fixture.anchor.handle(event) == nil)
            #expect(fixture.cancellations == 1)
            #expect(!fixture.anchor.popover.isShown)
        }

        @Test("Completing or dismantling closes synchronously without cancellation", arguments: [false, true])
        func programmaticClose(animated: Bool) {
            let fixture = Fixture()
            defer { fixture.close() }
            fixture.show()
            fixture.anchor.popover.animates = animated
            fixture.anchor.close()
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            #expect(fixture.cancellations == 0)
            #expect(!fixture.anchor.popover.isShown)
            #expect(fixture.anchor.popover.animates == animated)

            fixture.show()
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            #expect(fixture.cancellations == 1)
            #expect(!fixture.anchor.popover.isShown)
        }

        @Test("A system close cancels rather than inserting")
        func systemClose() {
            let fixture = Fixture()
            defer { fixture.close() }
            fixture.show()
            fixture.anchor.popover.close()
            #expect(fixture.cancellations == 1)
        }

        @MainActor
        final private class Fixture {
            let window: NSWindow
            let anchor = MacVoiceInputPopoverAnchor(frame: NSRect(x: 20, y: 20, width: 80, height: 30))
            var cancellations = 0

            init() {
                _ = NSApplication.shared
                self.window = NSWindow(
                    contentRect: NSRect(x: 100, y: 100, width: 320, height: 160),
                    styleMask: [.titled], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView?.addSubview(anchor)
                anchor.onCancel = { [weak self] in self?.cancellations += 1 }
                window.orderFront(nil)
            }

            func show() {
                anchor.popover.animates = false
                anchor.show(content: Text("Voice preview").frame(width: 200, height: 90))
            }

            func close() {
                anchor.close()
                window.close()
            }

            func mouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow? = nil) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: (window ?? self.window).windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                ))
            }
        }
    }
#endif
