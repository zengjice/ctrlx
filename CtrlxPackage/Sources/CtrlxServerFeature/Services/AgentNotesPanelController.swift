import AppKit
import CtrlxCommon
import SwiftUI

@MainActor
final class AgentNotesPanelController: NSObject, NSWindowDelegate {
    private(set) var window: NSPanel?
    private var closeRequest: ((Bool) -> Bool)?

    func show(scope: AgentNoteScope, title: String, store: AgentNotesStore, newNote: Bool, isAvailable: @escaping @MainActor () -> Bool) {
        if let old = window {
            if closeRequest?(false) == false, window === old {
                return
            }
            close(old)
        }
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let panel = NotesPanel(
            contentRect: .init(x: 0, y: 0, width: max(540, min(880, parent.frame.width - 32)), height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.appearance = parent.effectiveAppearance
        panel.delegate = self
        panel.setAccessibilityIdentifier("agent-notes-panel")
        panel.contentView = NSHostingView(rootView: AgentNotesView(
            store: store, scope: scope, title: title, newNote: newNote, isAvailable: isAvailable,
            registerClose: { [weak self, weak panel] handler in
                guard let self, self.window === panel else { return }
                self.closeRequest = handler
            },
            close: { [weak self, weak panel] in self?.close(panel) }
        ))
        let visible = parent.screen?.visibleFrame ?? parent.frame
        panel.setFrameOrigin(.init(
            x: min(max(parent.frame.midX - panel.frame.width / 2, visible.minX + 12), visible.maxX - panel.frame.width - 12),
            y: max(visible.minY + 16, min(parent.frame.midY - 240, visible.maxY - 496))
        ))
        window = panel
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        if let closeRequest {
            _ = closeRequest(false)
        } else {
            close(window)
        }
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        if let closeRequest {
            _ = closeRequest(true)
        } else {
            close(window)
        }
        return false
    }

    private func close(_ panel: NSPanel?) {
        guard let panel, window === panel else { return }
        let parent = panel.parent
        let restoreFocus = panel.isKeyWindow
        closeRequest = nil
        window = nil
        parent?.removeChildWindow(panel)
        panel.close()
        if restoreFocus {
            parent?.makeKeyAndOrderFront(nil)
        }
    }
}

final private class NotesPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
