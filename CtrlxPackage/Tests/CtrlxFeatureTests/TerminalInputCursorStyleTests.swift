#if canImport(SwiftTerm)
    import SwiftTerm
    import Testing
    @testable import CtrlxFeature

    @Suite("Terminal input cursor presentation")
    struct TerminalInputCursorStyleTests {
        @Test("Editing restores every original cursor style", arguments: [
            "blinkBlock", "steadyBlock", "blinkUnderline", "steadyUnderline", "blinkBar", "steadyBar",
        ])
        func restoresStyle(name: String) throws {
            let style = try #require(CursorStyle.from(string: name))
            let terminal = Terminal(delegate: Delegate(), options: .init(cursorStyle: style))
            var presentation = TerminalInputCursorStyle()
            presentation.update(in: terminal, isEditing: true)
            presentation.update(in: terminal, isEditing: true)
            #expect(terminal.options.cursorStyle == .steadyBar)
            presentation.update(in: terminal, isEditing: false)
            presentation.update(in: terminal, isEditing: false)
            #expect(terminal.options.cursorStyle == style)
        }

        @Test("Host cursor requests received while editing survive keyboard dismissal", arguments: [
            (2, "steadyBlock"), (3, "blinkUnderline"), (6, "steadyBar"),
        ])
        func hostStyleChange(request: Int, name: String) throws {
            let style = try #require(CursorStyle.from(string: name))
            let terminal = Terminal(delegate: Delegate())
            var presentation = TerminalInputCursorStyle()
            presentation.update(in: terminal, isEditing: true)
            // Real transport chunks can split the cursor escape sequence.
            for chunk in ["\u{1B}[", "\(request) q"] {
                presentation.restore(in: terminal)
                terminal.feed(text: chunk)
                presentation.update(in: terminal, isEditing: true)
                #expect(terminal.options.cursorStyle == .steadyBar)
            }
            presentation.update(in: terminal, isEditing: false)
            #expect(terminal.options.cursorStyle == style)
        }

        @Test("The local bar preserves wide text, cursor position and Host visibility")
        func preservesTerminal() throws {
            let delegate = Delegate()
            let terminal = Terminal(delegate: delegate, options: .init(cols: 20, rows: 5))
            terminal.feed(text: "A中文B\u{1B}[1;2H")
            let line = try #require(terminal.getLine(row: 0))
            #expect(line[1].width == 2)
            let original = line[1]
            var presentation = TerminalInputCursorStyle()
            presentation.update(in: terminal, isEditing: true)
            for visible in [false, true] {
                presentation.restore(in: terminal)
                terminal.feed(text: visible ? "\u{1B}[?25h" : "\u{1B}[?25l")
                presentation.update(in: terminal, isEditing: true)
                #expect(terminal.isCursorVisible == visible)
                #expect(terminal.buffer.x == 1 && terminal.buffer.y == 0)
                #expect(terminal.getCharacter(for: line[1]) == terminal.getCharacter(for: original))
                #expect(line[1].width == original.width)
                #expect(line[1].attribute == original.attribute)
            }
            presentation.update(in: terminal, isEditing: false)
            #expect(delegate.sent.isEmpty)
        }

        final private class Delegate: TerminalDelegate {
            var sent: [UInt8] = []
            func send(source: Terminal, data: ArraySlice<UInt8>) {
                sent.append(contentsOf: data)
            }
        }
    }
#endif
