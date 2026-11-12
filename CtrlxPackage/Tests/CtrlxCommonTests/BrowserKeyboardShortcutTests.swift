#if os(macOS)
    import AppKit
    import Testing
    @testable import CtrlxCommon

    @MainActor
    @Suite(.serialized)
    struct BrowserKeyboardShortcutTests {
        final class Window: NSWindow {
            var key = true
            override var isKeyWindow: Bool {
                key
            }
        }

        @Test(arguments: ["r", "l", "[", "]"])
        func browserKeysAreConsumedBeforePageOrGlobalCommands(key: String) throws {
            let (window, root, anchor) = fixture()
            defer { anchor.stop()
                window.close()
            }
            var actions: [BrowserKeyboardShortcut] = []
            anchor.perform = { actions.append($0) }
            let editor = NSTextView(frame: root.bounds)
            root.addSubview(editor)
            window.makeFirstResponder(editor)
            let event = try event(key, in: window)
            #expect(anchor.handle(event) == nil)
            let expected: [String: BrowserKeyboardShortcut] = ["r": .reload, "l": .focusAddress, "[": .back, "]": .forward]
            #expect(try actions == [#require(expected[key])])
            #expect(window.firstResponder === editor)
        }

        @Test(arguments: [NSEvent.ModifierFlags(), .shift, .control, .option, [.command, .shift], [.command, .option], [.command, .control]])
        func unrelatedModifiersStayWithThePage(modifiers: NSEvent.ModifierFlags) throws {
            let (window, _, anchor) = fixture()
            defer { anchor.stop()
                window.close()
            }
            anchor.perform = { _ in Issue.record("Unrelated modifiers must not invoke Browser actions") }
            for key in ["r", "l", "[", "]"] {
                let event = try event(key, in: window, modifiers: modifiers)
                #expect(anchor.handle(event) === event)
            }
        }

        @Test
        func standardApplicationAndEditingKeysRemainAvailable() throws {
            let (window, _, anchor) = fixture()
            defer { anchor.stop()
                window.close()
            }
            anchor.perform = { _ in Issue.record("Existing app shortcuts must not be consumed") }
            for key in ["c", "v", "a", "z", "t", "w", "n", "p", "1", "+", "-", "0", ","] {
                let event = try event(key, in: window)
                #expect(anchor.handle(event) === event)
            }
        }

        @Test
        func onlyTheActiveSplitInTheKeyWindowHandlesShortcuts() throws {
            let (window, root, left) = fixture()
            let right = BrowserKeyboardShortcutView()
            root.addSubview(right)
            defer { left.stop()
                right.stop()
                window.close()
            }
            var leftCount = 0, rightCount = 0
            left.perform = { _ in leftCount += 1 }
            right.perform = { _ in rightCount += 1 }
            right.isActive = false
            let key = try event("r", in: window)
            #expect(right.handle(key) === key)
            #expect(left.handle(key) == nil)
            left.isActive = false
            right.isActive = true
            #expect(left.handle(key) === key)
            #expect(right.handle(key) == nil)
            #expect(leftCount == 1 && rightCount == 1)
            window.key = false
            #expect(right.handle(key) === key)
            window.key = true
            right.isHidden = true
            #expect(right.handle(key) === key)
            right.isHidden = false
            let (otherWindow, _, other) = fixture()
            defer { other.stop()
                otherWindow.close()
            }
            #expect(other.handle(key) === key)
            right.removeFromSuperview()
            #expect(right.handle(key) === key)
            #expect(leftCount == 1 && rightCount == 1)
        }

        @Test
        func readOnlyAndAnnotationCannotFallThroughToGlobalRefresh() throws {
            let (window, _, anchor) = fixture()
            defer { anchor.stop()
                window.close()
            }
            var count = 0
            anchor.perform = { _ in count += 1 }
            anchor.isEnabled = false
            for key in ["r", "l", "[", "]"] {
                #expect(try anchor.handle(event(key, in: window)) == nil)
            }
            #expect(count == 0)
            anchor.isEnabled = true
            #expect(try anchor.handle(event("r", in: window)) == nil)
            #expect(count == 1)
        }

        private func fixture() -> (Window, NSView, BrowserKeyboardShortcutView) {
            _ = NSApplication.shared
            let window = Window(contentRect: .init(x: -10_000, y: -10_000, width: 800, height: 600), styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = NSView(frame: window.contentLayoutRect)
            let anchor = BrowserKeyboardShortcutView()
            window.contentView = root
            root.addSubview(anchor)
            return (window, root, anchor)
        }

        private func event(_ key: String, in window: NSWindow, modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 15))
        }
    }
#endif
