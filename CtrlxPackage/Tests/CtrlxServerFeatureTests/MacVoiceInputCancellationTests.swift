#if os(macOS)
    import AppKit
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite("Mac inline voice cancellation", .serialized)
    struct MacVoiceInputCancellationTests {
        @Test("Only unmodified Escape in the recording window is consumed")
        func escapeScope() throws {
            let fixture = Fixture()
            let other = Fixture()
            defer { fixture.close()
                other.close()
            }
            fixture.anchor.setActive(true)
            #expect(fixture.anchor.hitTest(.zero) == nil)
            let otherEscape = try other.key()
            #expect(fixture.anchor.handle(otherEscape) === otherEscape)
            let modified = try fixture.key(modifiers: .option)
            #expect(fixture.anchor.handle(modified) === modified)
            let text = try fixture.key(code: 0, characters: "a")
            #expect(fixture.anchor.handle(text) === text)
            #expect(fixture.cancellations == 0)

            let escape = try fixture.key()
            #expect(fixture.anchor.handle(escape) == nil)
            #expect(fixture.cancellations == 1)
            #expect(fixture.anchor.handle(escape) === escape)
            #expect(fixture.cancellations == 1)
        }

        @Test("Idle and dismantled controls leave terminal Escape alone")
        func inactive() throws {
            let fixture = Fixture()
            defer { fixture.close() }
            let escape = try fixture.key()
            #expect(fixture.anchor.handle(escape) === escape)
            fixture.anchor.setActive(true)
            fixture.anchor.setActive(false)
            #expect(fixture.anchor.handle(escape) === escape)
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            #expect(fixture.cancellations == 0)
        }

        @Test("App deactivation and switching native windows cancel once", arguments: [false, true])
        func deactivation(windowOnly: Bool) {
            let fixture = Fixture()
            let other = Fixture()
            defer { fixture.close()
                other.close()
            }
            fixture.anchor.setActive(true)
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other.window)
            #expect(fixture.cancellations == 0)
            let name = windowOnly ? NSWindow.didResignKeyNotification : NSApplication.didResignActiveNotification
            let object: AnyObject = windowOnly ? fixture.window : NSApplication.shared
            NotificationCenter.default.post(name: name, object: object)
            NotificationCenter.default.post(name: name, object: object)
            #expect(fixture.cancellations == 1)
        }

        @Test("Detaching the view removes monitors without cancelling a completed result")
        func detach() throws {
            let fixture = Fixture()
            defer { fixture.close() }
            fixture.anchor.setActive(true)
            fixture.anchor.removeFromSuperview()
            let escape = try fixture.key()
            #expect(fixture.anchor.handle(escape) === escape)
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            #expect(fixture.cancellations == 0)
        }

        @MainActor
        final private class Fixture {
            let window: NSWindow
            let anchor = MacVoiceInputCancellationView(frame: NSRect(x: 0, y: 0, width: 320, height: 44))
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
            }

            func close() {
                anchor.setActive(false)
                window.close()
            }

            func key(code: UInt16 = 53, characters: String = "\u{1b}", modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
                try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
                ))
            }
        }
    }
#endif
