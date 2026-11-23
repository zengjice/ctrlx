#if os(macOS)
    import AppKit
    import CtrlxNetworking
    import SwiftUI

    @MainActor
    final class FileBrowserMarkdownEditorWindow: NSWindowController, NSWindowDelegate {
        private struct DocumentKey: Hashable {
            let sourceID: String
            let path: String
        }

        private static var openEditors: [DocumentKey: FileBrowserMarkdownEditorWindow] = [:]
        private let key: DocumentKey
        private let draft: FileBrowserMarkdownDraft
        private var refreshPreviews: [UUID: () -> Void] = [:]

        static func present(
            file: FileBrowserEntry,
            data: Data,
            tab: FileBrowserTab,
            sourceID: String,
            colorScheme: ColorScheme,
            source: @escaping () -> FileBrowserSource
        ) {
            let key = DocumentKey(sourceID: sourceID, path: file.path)
            let editor = openEditors[key] ?? FileBrowserMarkdownEditorWindow(
                key: key, file: file, data: data, source: source
            )
            openEditors[key] = editor
            editor.refreshPreviews[tab.id] = { [weak tab] in
                if let tab, tab.selectedFile == file.path {
                    tab.refresh += 1
                }
            }
            editor.window?.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
            editor.showWindow(nil)
            editor.window?.makeKeyAndOrderFront(nil)
        }

        private init(
            key: DocumentKey,
            file: FileBrowserEntry,
            data: Data,
            source: @escaping () -> FileBrowserSource
        ) {
            self.key = key
            self.draft = FileBrowserMarkdownDraft(data: data)

            let availableSize = NSApp.keyWindow?.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size
                ?? ArtifactPreviewWindowSizing.preferredContentSize
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: ArtifactPreviewWindowSizing.initialContentSize(availableSize: availableSize)),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = file.name
            window.identifier = NSUserInterfaceItemIdentifier("file-markdown-editor")
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.collectionBehavior.insert(.managed)
            super.init(window: window)

            window.delegate = self
            window.contentViewController = NSHostingController(rootView: FileBrowserMarkdownEditor(
                file: file,
                draft: draft,
                sourceID: key.sourceID,
                source: source,
                onSaved: { [weak self] in
                    guard let self else { return }
                    for refresh in refreshPreviews.values {
                        refresh()
                    }
                    close()
                },
                onCancel: { [weak self] in self?.window?.performClose(nil) },
                onSavingChanged: { [weak window] saving in
                    window?.standardWindowButton(.closeButton)?.isEnabled = !saving
                }
            ))
            ArtifactPreviewWindowSizing.configure(window, availableSize: availableSize)
            window.center()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard !draft.isSaving, sender.attachedSheet == nil else { return false }
            guard draft.hasChanges else { return true }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Save changes to “\(sender.title)”?"
            alert.informativeText = "Your changes will be lost if you discard them."
            alert.addButton(withTitle: "Save").isEnabled = draft.canSave
            alert.addButton(withTitle: "Discard Changes")
            alert.addButton(withTitle: "Keep Editing").keyEquivalent = "\u{1b}"
            alert.beginSheetModal(for: sender) { [weak self] response in
                switch response {
                case .alertFirstButtonReturn: self?.draft.requestSave()
                case .alertSecondButtonReturn: self?.close()
                default: break
                }
            }
            return false
        }

        func windowWillClose(_ notification: Notification) {
            Self.openEditors.removeValue(forKey: key)
        }
    }
#endif
