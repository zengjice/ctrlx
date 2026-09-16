import Testing
@testable import CtrlxFeature

@Suite("Native keyboard text and caret synchronization")
struct TerminalInputCursorSynchronizerTests {
    @Test("Paired delimiters keep the native caret inside, then allow typing outside", arguments: [
        ("\"", "\""), ("“", "”"), ("‘", "’"), ("(", ")"), ("（", "）"), ("[", "]"),
    ])
    func pairedDelimiters(pair: (String, String)) {
        let (open, close) = pair
        var sync = TerminalInputCursorSynchronizer()
        var editor = Editor()
        let pairEdit = sync.advance(to: open + close, caretUTF16Offset: open.utf16.count)
        editor.apply(pairEdit)
        #expect(editor.text == open + close)
        #expect(editor.caret == 1)
        #expect(pairEdit.movementAfterEdit == -1)

        let inside = sync.advance(to: open + "你好" + close, caretUTF16Offset: (open + "你好").utf16.count)
        #expect(inside.deletionCount == 0)
        #expect(inside.insertion == "你好") // Do not rewrite the closing delimiter.
        editor.apply(inside)
        #expect(editor.caret == 3)

        let outside = sync.advance(to: open + "你好" + close, caretUTF16Offset: (open + "你好" + close).utf16.count)
        #expect(outside.movementBeforeEdit == 1)
        #expect(outside.insertion.isEmpty)
        editor.apply(outside)
        editor.apply(sync.advance(to: open + "你好" + close + "之后", caretUTF16Offset: 6))
        #expect(editor.text == open + "你好" + close + "之后")
        #expect(editor.caret == 6)
    }

    @Test("External navigation abandons only local context, not the remote suffix")
    func externalNavigation() {
        var sync = TerminalInputCursorSynchronizer()
        var editor = Editor()
        editor.apply(sync.advance(to: "“你好”", caretUTF16Offset: 3))
        sync.reset() // Toolbar Right establishes a new input context.
        editor.caret += 1
        editor.apply(sync.advance(to: "之后", caretUTF16Offset: 2))
        #expect(editor.text == "“你好”之后")
        #expect(editor.caret == 6)

        sync.reset() // A later tap places the remote caret before 好.
        editor.caret = 2
        editor.apply(sync.advance(to: "真", caretUTF16Offset: 1))
        #expect(editor.text == "“你真好”之后")
        #expect(editor.caret == 3)
    }

    @Test("Deleting and replacing text in the middle preserves the suffix")
    func middleEdits() {
        var sync = TerminalInputCursorSynchronizer()
        var editor = Editor()
        editor.apply(sync.advance(to: "“你好”", caretUTF16Offset: 3))
        let deletion = sync.advance(to: "“你”", caretUTF16Offset: 2)
        #expect(deletion.deletionCount == 1)
        #expect(deletion.insertion.isEmpty)
        editor.apply(deletion)
        editor.apply(sync.advance(to: "“您好”", caretUTF16Offset: 3))
        #expect(editor.text == "“您好”")
        #expect(editor.caret == 3)
    }

    @Test("UTF-16 caret offsets do not count wide cells or emoji code units as arrows")
    func unicodeCaret() {
        var sync = TerminalInputCursorSynchronizer()
        var editor = Editor()
        let inside = "“中👨‍👩‍👧‍👦e\u{301}"
        editor.apply(sync.advance(to: inside + "”", caretUTF16Offset: inside.utf16.count))
        #expect(editor.caret == 4)
        let delta = sync.advance(to: "“中👨‍👩‍👧‍👦”", caretUTF16Offset: "“中👨‍👩‍👧‍👦".utf16.count)
        #expect(delta.deletionCount == 1)
        editor.apply(delta)
        #expect(editor.text == "“中👨‍👩‍👧‍👦”")
        #expect(editor.caret == 3)
    }

    @Test("Invalid offsets are clamped to whole-character boundaries")
    func clampsCaret() {
        var sync = TerminalInputCursorSynchronizer()
        _ = sync.advance(to: "🙂a", caretUTF16Offset: 1)
        #expect(sync.forwardedCaret == 0)
        _ = sync.advance(to: "🙂a", caretUTF16Offset: -1)
        #expect(sync.forwardedCaret == 0)
        _ = sync.advance(to: "🙂a", caretUTF16Offset: Int.max)
        #expect(sync.forwardedCaret == 2)
    }

    @Test("Repeated text and selection delegate callbacks are idempotent")
    func unchanged() {
        var sync = TerminalInputCursorSynchronizer()
        _ = sync.advance(to: "“”", caretUTF16Offset: 1)
        #expect(sync.advance(to: "“”", caretUTF16Offset: 1) == TerminalInputCursorDelta(
            movementBeforeEdit: 0, deletionCount: 0, insertion: "", movementAfterEdit: 0
        ))
    }

    @Test("Edits from every old caret to every new caret reproduce the native document")
    func editMatrix() {
        let documents = ["", "a", "aa", "abab", "“”", "“ab”", "中🙂", "e\u{301}", "a\nb"]
        for old in documents {
            for oldCaret in 0...old.count {
                for new in documents {
                    for newCaret in 0...new.count {
                        var sync = TerminalInputCursorSynchronizer()
                        var editor = Editor()
                        editor.apply(sync.advance(to: old, caretUTF16Offset: old.prefix(oldCaret).utf16.count))
                        editor.apply(sync.advance(to: new, caretUTF16Offset: new.prefix(newCaret).utf16.count))
                        #expect(editor.text == new)
                        #expect(editor.caret == newCaret)
                    }
                }
            }
        }
    }

    private struct Editor {
        var characters: [Character] = []
        var caret = 0
        var text: String { String(characters) }

        mutating func apply(_ delta: TerminalInputCursorDelta) {
            caret += delta.movementBeforeEdit
            #expect(caret >= delta.deletionCount && caret <= characters.count)
            guard caret >= delta.deletionCount, caret <= characters.count else { return }
            characters.removeSubrange((caret - delta.deletionCount)..<caret)
            caret -= delta.deletionCount
            characters.insert(contentsOf: Array(delta.insertion), at: caret)
            caret += delta.insertion.count + delta.movementAfterEdit
            #expect(caret >= 0 && caret <= characters.count)
        }
    }
}
