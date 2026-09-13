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
            #expect(accessory.configuration.buttonHeight == TerminalInputControlMetrics.buttonHeight)
            #expect(accessory.bounds.height == TerminalInputControlMetrics.buttonHeight + 8)
            #expect(accessory.views.count == 11)
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

            try press(#selector(TerminalAccessory.esc(_:)), in: accessory)
            try press(#selector(TerminalAccessory.tab(_:)), in: accessory)
            try press(#selector(TerminalAccessory.down(_:)), in: accessory)
            try press(#selector(TerminalAccessory.up(_:)), in: accessory)
            #expect(sent == [.escape, .tab, .down, .up])
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
