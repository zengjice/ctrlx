import Dependencies
import SwiftUI

#if os(macOS)
    import AppKit

    @MainActor
    struct AgentWorkflowTextInput: NSViewRepresentable {
        let title: String
        @Binding var text: String
        let receive: ([AgentWorkflowImageSource]) -> Void
        @Environment(\.isEnabled) private var isEnabled

        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            let view = TextView()
            view.isRichText = false
            view.allowsUndo = true
            view.drawsBackground = false
            view.font = .preferredFont(forTextStyle: .body)
            view.textColor = .labelColor
            view.textContainerInset = NSSize(width: 0, height: 8)
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.autoresizingMask = [.width]
            view.textContainer?.widthTracksTextView = true
            view.textContainer?.lineFragmentPadding = 0
            view.delegate = context.coordinator
            scroll.documentView = view
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            guard let view = scroll.documentView as? TextView else { return }
            context.coordinator.parent = self
            if view.string != text {
                view.string = text
            }
            view.isEditable = isEnabled
            view.receive = receive
            view.setAccessibilityLabel(title)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
            guard let view = scroll.documentView as? TextView, let container = view.textContainer, let layout = view.layoutManager else { return nil }
            let width = proposal.width ?? 320
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            let line = layout.defaultLineHeight(for: view.font ?? .systemFont(ofSize: NSFont.systemFontSize))
            let height = layout.usedRect(for: container).height + 16
            let visibleHeight = min(max(height, line * 3 + 16), line * 12 + 16)
            view.minSize = NSSize(width: 0, height: visibleHeight)
            view.setFrameSize(NSSize(width: width, height: max(height, visibleHeight)))
            return CGSize(width: width, height: visibleHeight)
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        final class Coordinator: NSObject, NSTextViewDelegate {
            var parent: AgentWorkflowTextInput
            init(_ parent: AgentWorkflowTextInput) {
                self.parent = parent
            }

            func textDidChange(_ notification: Notification) {
                guard let view = notification.object as? NSTextView else { return }
                parent.text = view.string
            }
        }

        final class TextView: NSTextView {
            var receive: (([AgentWorkflowImageSource]) -> Void)?
            @Dependency(ClipboardClient.self) private var clipboard

            override func paste(_ sender: Any?) {
                guard isEditable else { return }
                let files = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                if !files.isEmpty {
                    receive?(files.map(AgentWorkflowImageSource.file))
                } else if let image = clipboard.getImage() {
                    receive?([.image(image)])
                } else {
                    super.paste(sender)
                }
            }

            override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
                if
                    item.action == #selector(paste(_:)), isEditable,
                    clipboard.hasImage() || NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
                    return true
                }
                return super.validateUserInterfaceItem(item)
            }
        }
    }
#else
    import UIKit

    /// UIKit handles image Paste from both the edit menu and external keyboards
    /// on iOS 18; SwiftUI's onPasteCommand is unavailable there.
    @MainActor
    struct AgentWorkflowTextInput: UIViewRepresentable {
        let title: String
        @Binding var text: String
        let receive: ([AgentWorkflowImageSource]) -> Void
        @Environment(\.isEnabled) private var isEnabled

        func makeUIView(context: Context) -> TextView {
            let view = TextView()
            view.font = .preferredFont(forTextStyle: .body)
            view.adjustsFontForContentSizeCategory = true
            view.backgroundColor = .clear
            view.textColor = .label
            view.textContainer.lineFragmentPadding = 0
            view.delegate = context.coordinator
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return view
        }

        func updateUIView(_ view: TextView, context: Context) {
            context.coordinator.parent = self
            if view.text != text {
                view.text = text
            }
            view.accessibilityLabel = title
            view.isEditable = isEnabled
            view.receive = receive
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: TextView, context: Context) -> CGSize? {
            let width = proposal.width ?? 320
            let line = uiView.font?.lineHeight ?? 20
            let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
            let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            return CGSize(width: width, height: min(max(fitted.height, line * 3 + insets), line * 12 + insets))
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var parent: AgentWorkflowTextInput
            init(_ parent: AgentWorkflowTextInput) {
                self.parent = parent
            }

            func textViewDidChange(_ textView: UITextView) {
                parent.text = textView.text
            }
        }

        final class TextView: UITextView {
            var receive: (([AgentWorkflowImageSource]) -> Void)?

            override func paste(_ sender: Any?) {
                guard isEditable else { return }
                let images = AgentWorkflowImageSource.providers(UIPasteboard.general.itemProviders)
                if !images.isEmpty {
                    receive?(images)
                } else {
                    super.paste(sender)
                }
            }

            override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
                if action == #selector(paste(_:)), isEditable, UIPasteboard.general.hasImages || UIPasteboard.general.hasURLs {
                    return true
                }
                return super.canPerformAction(action, withSender: sender)
            }
        }
    }
#endif
