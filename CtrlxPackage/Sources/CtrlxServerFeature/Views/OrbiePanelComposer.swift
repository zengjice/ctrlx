import AppKit
import SwiftUI

/// NSTextView owns IME composition; Return is intercepted only before composition starts.
struct OrbiePanelComposer: NSViewRepresentable {
    @Binding var text: String
    let focusID: String?
    let send: () -> Void
    let dismiss: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ComposerScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = TextView()
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .labelColor
        view.insertionPointColor = .controlAccentColor
        view.textContainerInset = .init(width: 0, height: 4)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.setAccessibilityIdentifier("orbie-panel-draft")
        view.setAccessibilityLabel("Message to the selected Agent")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? TextView else { return }
        context.coordinator.parent = self
        if view.string != text, !view.hasMarkedText() {
            // Native undo ranges refer to the previous draft, not its replacement.
            view.undoManager?.removeAllActions()
            view.string = text
        }
        view.send = send
        view.dismiss = dismiss
        if view.focusID != focusID {
            view.focusID = focusID
            if focusID != nil, view.window?.isKeyWindow == true {
                view.window?.makeFirstResponder(view)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let view = scroll.documentView as? TextView else { return nil }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 560
        let font = view.font ?? .systemFont(ofSize: 14)
        let line = view.layoutManager?.defaultLineHeight(for: font) ?? 20
        let height = (text as NSString).boundingRect(with: .init(width: width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, attributes: [.font: font]).height + 8
        let visible = min(max(height, line * 2 + 8), line * 6 + 8)
        return .init(width: width, height: visible)
    }

    final class ComposerScrollView: NSScrollView {
        override func layout() {
            super.layout()
            guard let view = documentView as? NSTextView else { return }
            // SwiftUI probes multiple widths; only the final clip view bounds
            // may size the live editor and its accessibility frame.
            if view.frame.width != contentSize.width || view.minSize.height != contentSize.height {
                view.minSize = .init(width: 0, height: contentSize.height)
                view.setFrameSize(.init(width: contentSize.width, height: max(view.frame.height, contentSize.height)))
                view.sizeToFit()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: OrbiePanelComposer
        init(_ parent: OrbiePanelComposer) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }

    final class TextView: NSTextView {
        private let editorUndoManager = UndoManager()
        override var undoManager: UndoManager? {
            editorUndoManager
        }

        var focusID: String?
        var send: (() -> Void)?
        var dismiss: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if focusID != nil, window?.isKeyWindow == true {
                window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            if !hasMarkedText() {
                if event.keyCode == 36 || event.keyCode == 76 {
                    if event.modifierFlags.intersection([.shift, .option, .control, .command]).isEmpty {
                        send?()
                        return
                    }
                }
                if event.keyCode == 53 {
                    dismiss?()
                    return
                }
            }
            super.keyDown(with: event)
        }
    }
}
