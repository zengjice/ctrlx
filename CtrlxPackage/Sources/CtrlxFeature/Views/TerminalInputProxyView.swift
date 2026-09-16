import Foundation

/// The terminal operations needed to make one editable shadow document match
/// another. Deletions are counted in grapheme clusters because one terminal
/// Backspace removes one user-visible character, not one UTF-16 code unit.
struct TerminalInputDocumentDelta: Equatable {
    let deletionCount: Int
    let insertion: String
}

/// Tracks the text already forwarded to the terminal and computes the smallest
/// end-of-line edit for a new native text document.
struct TerminalInputDocumentSynchronizer {
    private(set) var forwardedText = ""

    mutating func advance(to text: String) -> TerminalInputDocumentDelta {
        var oldIndex = forwardedText.startIndex
        var newIndex = text.startIndex

        while
            oldIndex < forwardedText.endIndex,
            newIndex < text.endIndex,
            forwardedText[oldIndex] == text[newIndex] {
            forwardedText.formIndex(after: &oldIndex)
            text.formIndex(after: &newIndex)
        }

        let delta = TerminalInputDocumentDelta(
            deletionCount: forwardedText[oldIndex...].count,
            insertion: String(text[newIndex...])
        )
        forwardedText = text
        return delta
    }

    mutating func reset() {
        forwardedText = ""
    }
}

/// A keyboard edit is relative to its last forwarded caret, not the end of the
/// shadow document. Keep this separate from voice's append/correction stream.
struct TerminalInputCursorDelta: Equatable {
    let movementBeforeEdit: Int
    let deletionCount: Int
    let insertion: String
    let movementAfterEdit: Int
}

struct TerminalInputCursorSynchronizer {
    private(set) var forwardedText = ""
    private(set) var forwardedCaret = 0

    mutating func advance(to text: String, caretUTF16Offset: Int) -> TerminalInputCursorDelta {
        let old = Array(forwardedText)
        let new = Array(text)
        // UIKit uses UTF-16 positions; terminal arrows/backspace use characters.
        var caret = 0
        var utf16Offset = 0
        for character in new {
            utf16Offset += String(character).utf16.count
            guard utf16Offset <= caretUTF16Offset else { break }
            caret += 1
        }
        defer {
            forwardedText = text
            forwardedCaret = caret
        }

        guard old != new else {
            return TerminalInputCursorDelta(
                movementBeforeEdit: caret - forwardedCaret,
                deletionCount: 0, insertion: "", movementAfterEdit: 0
            )
        }

        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] {
            suffix += 1
        }
        let oldEditEnd = old.count - suffix
        let newEditEnd = new.count - suffix
        return TerminalInputCursorDelta(
            movementBeforeEdit: oldEditEnd - forwardedCaret,
            deletionCount: oldEditEnd - prefix,
            insertion: String(new[prefix..<newEditEnd]),
            movementAfterEdit: caret - newEditEnd
        )
    }

    mutating func reset() {
        forwardedText = ""
        forwardedCaret = 0
    }
}

#if os(iOS)
    import UIKit

    /// A native shadow editor for terminal keyboard input.
    ///
    /// Third-party keyboards read back the document after every insertion. A
    /// hand-written documentless `UITextInput` cannot satisfy that contract:
    /// the keyboard inserts recognized speech, reads an unchanged document and
    /// eventually abandons the session. `UITextView` owns the full UIKit text
    /// protocol here; this class only forwards its committed delta to tmux.
    final class TerminalInputProxyView: UITextView, UITextViewDelegate {
        private static let anchor = "\u{200B}"
        private static let anchorLength = (anchor as NSString).length
        private static let debugEnabled = ProcessInfo.processInfo.environment["CTRLX_TEXT_INPUT_DEBUG"] == "1"

        var onInsertText: ((String) -> Void)?
        var onDeleteBackward: (() -> Void)?
        var onMoveCursor: ((Int) -> Void)?
        var onFocusChange: ((Bool) -> Void)?
        var onCompositionStart: (() -> Void)?
        var inputAccessoryViewProvider: (() -> UIView?)?
        var inputViewProvider: (() -> UIView?)?
        weak var forwardedNextResponder: UIResponder?

        var inputEnabled = false

        private var synchronizer = TerminalInputCursorSynchronizer()
        private var isApplyingInternalEdit = false
        private var nativeEditDepth = 0
        private var assignedInputAccessoryView: UIView?
        private var assignedInputView: UIView?

        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            configureEditor()
        }

        convenience init(frame: CGRect) {
            self.init(frame: frame, textContainer: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var canBecomeFirstResponder: Bool {
            inputEnabled
        }

        /// The proxy is a sibling overlay of the terminal so it stays fixed in
        /// the visible viewport. Preserve the terminal's responder chain for
        /// hardware key commands that the native editor does not consume.
        override var next: UIResponder? {
            forwardedNextResponder ?? super.next
        }

        /// The shadow document is keyboard/IME context, not the visible text.
        /// Resolve terminal menu actions before UITextView can claim them for
        /// that document. In particular, Copy requires a terminal selection,
        /// and Select must use the position where its menu was opened.
        override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
            if let forwardedNextResponder {
                switch action {
                case #selector(copy(_:)), #selector(paste(_:)),
                     #selector(select(_:)), #selector(selectAll(_:)):
                    return forwardedNextResponder.target(forAction: action, withSender: sender)
                default:
                    break
                }
            }
            return super.target(forAction: action, withSender: sender)
        }

        override var inputAccessoryView: UIView? {
            get { inputAccessoryViewProvider?() ?? assignedInputAccessoryView }
            set { assignedInputAccessoryView = newValue }
        }

        override var inputView: UIView? {
            get { inputViewProvider?() ?? assignedInputView }
            set { assignedInputView = newValue }
        }

        /// The proxy covers the terminal so UIKit can lay out a real document,
        /// but all touches must continue to reach the visible terminal view.
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            false
        }

        override func becomeFirstResponder() -> Bool {
            let becameFirstResponder = super.becomeFirstResponder()
            if becameFirstResponder {
                trace("focus became-first-responder mode=\(textInputMode?.primaryLanguage ?? "unknown")")
                onFocusChange?(true)
            }
            return becameFirstResponder
        }

        override func resignFirstResponder() -> Bool {
            let resignedFirstResponder = super.resignFirstResponder()
            if resignedFirstResponder {
                trace("focus resigned-first-responder")
                onFocusChange?(false)
            }
            return resignedFirstResponder
        }

        func textViewDidChange(_: UITextView) {
            synchronizeCommittedDocument()
        }

        override func insertText(_ text: String) {
            performNativeEdit { super.insertText(text) }
        }

        override func deleteBackward() {
            performNativeEdit { super.deleteBackward() }
        }

        override func replace(_ range: UITextRange, withText text: String) {
            performNativeEdit { super.replace(range, withText: text) }
        }

        override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
            // Cancel remote navigation even if composition is later abandoned
            // without committing text or receiving a terminal output frame.
            if markedText != nil { onCompositionStart?() }
            performNativeEdit { super.setMarkedText(markedText, selectedRange: selectedRange) }
        }

        override func unmarkText() {
            performNativeEdit { super.unmarkText() }
        }

        private func performNativeEdit(_ edit: () -> Void) {
            nativeEditDepth += 1
            edit()
            nativeEditDepth -= 1
            synchronizeCommittedDocument()
        }

        /// An explicit remote edit/navigation establishes a new insertion point.
        /// Commit any candidate first, then forget only local keyboard context;
        /// never erase remote text or guess the remote draft from screen pixels.
        func prepareForExternalInput() {
            if inputEnabled, markedTextRange != nil { unmarkText() }
            resetDocument()
        }

        func textViewDidChangeSelection(_: UITextView) {
            // Committing marked text can change only the selection/marked state,
            // not the underlying characters. Observe both delegate callbacks so
            // an IME candidate is forwarded exactly when it becomes committed.
            synchronizeCommittedDocument()
        }

        private func synchronizeCommittedDocument() {
            guard !isApplyingInternalEdit, nativeEditDepth == 0 else { return }
            restoreAnchorIfNeeded()

            // An IME owns marked text until it commits. Forwarding provisional
            // pinyin/candidates would duplicate or corrupt the remote input line.
            guard markedTextRange == nil else {
                trace("marked document utf16=\(payload.utf16.count)")
                return
            }

            // Home/keyboard cursor gestures can reach the invisible anchor.
            // Keep it outside the editable selection without moving the remote
            // caret, which is already at the start of this local context.
            if selectedRange.location < Self.anchorLength {
                let end = NSMaxRange(selectedRange)
                isApplyingInternalEdit = true
                selectedRange = NSRange(location: Self.anchorLength, length: max(0, end - Self.anchorLength))
                isApplyingInternalEdit = false
            }

            let committedText = payload
            let delta = synchronizer.advance(
                to: committedText,
                caretUTF16Offset: max(0, selectedRange.location - Self.anchorLength)
            )
            trace(
                "document utf16=\(committedText.utf16.count) " +
                    "delete=\(delta.deletionCount) insert=\(delta.insertion.debugDescription)"
            )

            if delta.movementBeforeEdit != 0 { onMoveCursor?(delta.movementBeforeEdit) }
            for _ in 0..<delta.deletionCount {
                onDeleteBackward?()
            }
            if !delta.insertion.isEmpty {
                onInsertText?(delta.insertion)
            }
            if delta.movementAfterEdit != 0 { onMoveCursor?(delta.movementAfterEdit) }

            // Return starts a new terminal input line. The remote command has
            // already received the newline, so reset only the local context.
            if committedText.contains("\n") || committedText.contains("\r") {
                resetDocument()
            }
        }

        func textView(
            _: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard range.location < Self.anchorLength else { return true }

            // At this context's start there may still be text to its right and
            // older remote text to its left. Backspace must reach that remote
            // prefix without removing the anchor or rewriting the local suffix.
            if text.isEmpty, range.length == Self.anchorLength, selectedRange.length == 0 {
                onDeleteBackward?()
            }
            return false
        }

        private var payload: String {
            guard text.hasPrefix(Self.anchor) else { return text }
            return String(text.dropFirst())
        }

        private func configureEditor() {
            delegate = self
            backgroundColor = .clear
            textColor = .clear
            tintColor = .clear
            isAccessibilityElement = false
            isScrollEnabled = true
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            autocorrectionType = .no
            autocapitalizationType = .none
            spellCheckingType = .no
            smartQuotesType = .no
            smartDashesType = .no
            smartInsertDeleteType = .no
            textContainerInset = .zero
            textContainer.lineFragmentPadding = 0
            inputAssistantItem.leadingBarButtonGroups = []
            inputAssistantItem.trailingBarButtonGroups = []
            resetDocument()
        }

        private func restoreAnchorIfNeeded() {
            guard !text.hasPrefix(Self.anchor) else { return }
            let originalText = text ?? ""
            let originalSelection = selectedRange
            isApplyingInternalEdit = true
            text = Self.anchor + originalText
            selectedRange = NSRange(
                location: originalSelection.location + Self.anchorLength,
                length: originalSelection.length
            )
            isApplyingInternalEdit = false
        }

        private func resetDocument() {
            isApplyingInternalEdit = true
            text = Self.anchor
            selectedRange = NSRange(location: Self.anchorLength, length: 0)
            synchronizer.reset()
            isApplyingInternalEdit = false
        }

        private func trace(_ message: @autoclosure () -> String) {
            guard Self.debugEnabled else { return }
            print("[GallagerTextInput] \(message())")
        }
    }
#endif
