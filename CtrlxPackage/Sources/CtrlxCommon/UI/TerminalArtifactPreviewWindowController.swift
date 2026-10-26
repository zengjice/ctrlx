#if os(macOS)
    import AppKit
    import SwiftUI

    @MainActor
    final public class TerminalArtifactPreviewWindowController: NSWindowController, NSWindowDelegate {
        public var onWindowClosed: (() -> Void)?

        public init(
            preview: TerminalArtifactPreview,
            colorScheme: ColorScheme,
            onOpenFiles: @escaping (TerminalFileLinkRequest) -> Void
        ) {
            let availableSize = NSScreen.main?.visibleFrame.size
                ?? ArtifactPreviewWindowSizing.preferredContentSize
            let initialSize = ArtifactPreviewWindowSizing.initialContentSize(availableSize: availableSize)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: initialSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = (preview.path as NSString).lastPathComponent
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.collectionBehavior.insert(.managed)

            super.init(window: window)

            window.delegate = self
            window.contentViewController = NSHostingController(
                rootView: TerminalArtifactPreviewSheet(
                    preview: preview,
                    onOpenFiles: onOpenFiles,
                    onClose: { [weak self] in self?.window?.performClose(nil) }
                )
                .preferredColorScheme(colorScheme)
            )
            ArtifactPreviewWindowSizing.configure(window, availableSize: availableSize)
            window.center()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        public func show() {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        }

        public func windowWillClose(_ notification: Notification) {
            onWindowClosed?()
        }
    }
#endif
