#if os(iOS)
    import CtrlxNetworking
    @testable import SwiftTerm
    import Testing
    import UIKit
    @testable import CtrlxFeature

    @MainActor
    @Suite("Terminal shortcut accessory", .serialized)
    struct TerminalShortcutAccessoryTests {
        @Test("Shortcut buttons share the first row's height")
        func sharedHeight() async throws {
            let fixture = TerminalSelectionRoutingTests()
            let (window, terminal) = await fixture.makeView()
            defer { fixture.close(window, terminal) }
            let accessory = try #require(terminal.inputAccessoryView as? TerminalAccessory)

            #expect(!accessory.configuration.showsHorizontalArrows)
            #expect(!accessory.configuration.showsFunctionKeys)
            #expect(!accessory.configuration.showsEscapeKey)
            #expect(accessory.configuration.buttonHeight == TerminalInputControlMetrics.buttonHeight)
            #expect(accessory.bounds.height == TerminalInputControlMetrics.buttonHeight + 8)
            #expect(accessory.views.count == 10)
            #expect(!accessory.views.compactMap { $0 as? UIButton }.contains {
                $0.actions(forTarget: accessory, forControlEvent: .touchDown)?
                    .contains(NSStringFromSelector(#selector(TerminalAccessory.esc(_:)))) == true
            })
            for button in accessory.views {
                #expect(button.frame.height == TerminalInputControlMetrics.buttonHeight)
            }

            terminal.updateInput(isEnabled: true, keyboardRequested: false)
            #expect(terminal.inputView?.bounds.height == accessory.bounds.height)
            terminal.updateInput(isEnabled: false, keyboardRequested: false)
        }

        @Test("Retained buttons still use SwiftTerm input, repeat and modifier handling")
        func retainedActions() throws {
            let terminal = makeTerminal()
            let accessory = try #require(terminal.inputAccessoryView as? TerminalAccessory)
            var sent: [TmuxKey] = []
            terminal.onInput = { sent += $0 }

            try press(#selector(TerminalAccessory.tab(_:)), in: accessory)
            try press(#selector(TerminalAccessory.down(_:)), in: accessory)
            try press(#selector(TerminalAccessory.up(_:)), in: accessory)
            #expect(sent == [.tab, .down, .up])
            #expect(accessory.repeatTask?.isCancelled == true)
            #expect(accessory.repeatTimer == nil)

            try press(#selector(TerminalAccessory.ctrl(_:)), in: accessory)
            #expect(accessory.controlModifier)
            terminal.insertText("c")
            #expect(sent.last == .ctrl("c"))
            #expect(!accessory.controlModifier)

            #expect(!terminal.allowMouseReporting)
            try press(#selector(TerminalAccessory.toggleTouch(_:)), in: accessory)
            #expect(terminal.allowMouseReporting)
            try press(#selector(TerminalAccessory.toggleTouch(_:)), in: accessory)
            #expect(!terminal.allowMouseReporting)
        }

        private func makeTerminal() -> InteractiveTerminalView {
            let terminal = InteractiveTerminalView(frame: CGRect(x: 0, y: 0, width: 420, height: 300), font: nil)
            terminal.updateInput(isEnabled: true, keyboardRequested: false)
            return terminal
        }

        @Test("Extended keyboard sends a complete chord once in either cursor mode",
              arguments: [false, true])
        func shiftChords(applicationCursor: Bool) throws {
            let terminal = makeTerminal()
            if applicationCursor { terminal.feed(text: "\u{1b}[?1h") }
            let accessory = try #require(terminal.inputAccessoryView as? TerminalAccessory)
            terminal.inputView = nil
            try press(#selector(TerminalAccessory.toggleInputKeyboard(_:)), in: accessory)
            let keyboard = try #require(terminal.inputView as? KeyboardView)
            #expect(keyboard.bounds.height >= KeyboardView.minimumHeight)
            #expect(accessory.views.count == 10)
            #expect(accessory.configuration.buttonHeight == TerminalInputControlMetrics.buttonHeight)
            var sent: [[TmuxKey]] = []
            terminal.onInput = { sent.append($0) }

            let chords: [(String, TmuxKey)] = [
                ("⇧←", .text("\u{1b}[1;2D")), ("⇧→", .text("\u{1b}[1;2C")),
                ("⇧↑", .text("\u{1b}[1;2A")), ("⇧↓", .text("\u{1b}[1;2B")),
                ("⇧Tab", .backtab), ("⇧Enter", .shiftEnter),
            ]
            for (title, expected) in chords {
                sent.removeAll()
                try press(title: title, in: keyboard)
                #expect(sent == [[expected]])
                #expect(!accessory.controlModifier)
                #expect(!terminal.metaModifier)
            }

            // A direct chord neither combines with nor clears a pending Ctrl.
            try press(#selector(TerminalAccessory.ctrl(_:)), in: accessory)
            sent.removeAll()
            try press(title: "⇧←", in: keyboard)
            #expect(sent == [[.text("\u{1b}[1;2D")]])
            #expect(accessory.controlModifier)
            terminal.insertText("c")
            #expect(sent.last == [.ctrl("c")])
            #expect(!accessory.controlModifier)

            // Existing arrows and text input remain unmodified afterward.
            sent.removeAll()
            try press(#selector(TerminalAccessory.up(_:)), in: accessory)
            terminal.insertText("x")
            let up = applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
            #expect(sent == [TmuxKey.from(bytes: Data(up)), [.text("x")]])
            try press(title: "F1", in: keyboard)
            #expect(sent.last == TmuxKey.from(bytes: Data(EscapeSequences.cmdF[0])))
            try press(title: "home", in: keyboard)
            let home = applicationCursor ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal
            #expect(sent.last == TmuxKey.from(bytes: Data(home)))
            try press(title: "end", in: keyboard)
            let end = applicationCursor ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal
            #expect(sent.last == TmuxKey.from(bytes: Data(end)))

            // Deferred focus release must not let the old keyboard send to a pane.
            terminal.updateInput(isEnabled: false, keyboardRequested: false)
            sent.removeAll()
            try press(title: "⇧Enter", in: keyboard)
            #expect(sent.isEmpty)
        }

        private func press(title: String, in keyboard: KeyboardView) throws {
            let button = try #require(keyboard.views.compactMap { $0 as? UIButton }.first {
                $0.title(for: .normal) == title
            })
            button.sendActions(for: .touchDown)
            button.sendActions(for: .touchUpInside)
        }

        private func press(_ action: Selector, in accessory: TerminalAccessory) throws {
            let button = try #require(accessory.views.compactMap { $0 as? UIButton }.first {
                $0.actions(forTarget: accessory, forControlEvent: .touchDown)?
                    .contains(NSStringFromSelector(action)) == true
            })
            button.sendActions(for: .touchDown)
            button.sendActions(for: .touchUpInside)
        }
    }
#endif
