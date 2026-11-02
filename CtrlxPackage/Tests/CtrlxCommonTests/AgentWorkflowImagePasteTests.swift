#if os(macOS)
    import AppKit
    import Dependencies
    import Foundation
    import SwiftUI
    import Testing
    @testable import CtrlxCommon

    @MainActor
    struct AgentWorkflowImagePasteTests {
        @Test
        func nativePasteRoutesImagesAndLeavesTextEditingIntact() async throws {
            guard ProcessInfo.processInfo.environment["CTRLX_WORKFLOW_IMAGE_PASTE_UI"] == "1" else {
                print("Skipping native Paste probe: set CTRLX_WORKFLOW_IMAGE_PASTE_UI=1 to use and restore the system clipboard.")
                return
            }
            try await withDependencies {
                $0[ClipboardClient.self] = .liveValue
            } operation: { try await nativePasteProbe() }
        }

        private func nativePasteProbe() async throws {
            let board = NSPasteboard.general
            let originalCount = board.changeCount
            let original = try (board.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    let data = try #require(item.data(forType: type), "The clipboard cannot be backed up; no test data was written.")
                    try #require(copy.setData(data, forType: type))
                }
                return copy
            }
            var ownedCount = originalCount
            defer {
                if ownedCount != originalCount, board.changeCount == ownedCount {
                    board.clearContents()
                    if !original.isEmpty {
                        board.writeObjects(original)
                    }
                }
            }
            _ = NSApplication.shared
            var text = ""
            var pasted: [AgentWorkflowImageSource] = []
            let root = AgentWorkflowTaskInput(
                title: "Initial task", text: Binding(get: { text }, set: { text = $0 }), ids: [], attachments: [:],
                add: { }, photos: nil, receive: { pasted = $0 }, remove: { _ in }, progress: nil, error: nil
            ).padding().frame(width: 500, height: 300)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            var field: NSView?
            while field == nil, ContinuousClock.now < deadline {
                field = descendants(host).first { ($0 as? NSTextField)?.isEditable == true || ($0 as? NSTextView)?.isEditable == true }
                if field == nil {
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            try #require(try window.makeFirstResponder(#require(field)))
            try #require(board.changeCount == ownedCount, "The clipboard changed during setup; no test data was written.")
            let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQaPjQAMIMMAYARzIIQdQEEEMAAAAASUVORK5CYII="))
            board.clearContents()
            board.setData(png, forType: .png)
            ownedCount = board.changeCount
            let input = try #require(field as? AgentWorkflowTextInput.TextView)
            #expect(input.validateUserInterfaceItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")))
            try #require(NSApp.sendAction(#selector(NSText.paste(_:)), to: window.firstResponder, from: nil))
            for _ in 0..<50 where pasted.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
            }
            let image = try await #require(pasted.first).load()
            #expect(image.data == png)
            try #require(board.changeCount == ownedCount, "Another app changed the clipboard; its contents were preserved.")
            board.clearContents()
            board.setString("ordinary task text", forType: .string)
            ownedCount = board.changeCount
            pasted = []
            try #require(NSApp.sendAction(#selector(NSText.paste(_:)), to: window.firstResponder, from: nil))
            for _ in 0..<50 where text.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(text == "ordinary task text")
            #expect(pasted.isEmpty)
        }

        private func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
    }
#endif
