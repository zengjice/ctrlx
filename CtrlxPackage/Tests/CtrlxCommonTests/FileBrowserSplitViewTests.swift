#if os(macOS)
    import AppKit
    import CtrlxNetworking
    import SwiftUI
    import Testing
    @testable import CtrlxCommon

    @MainActor
    @Suite(.serialized)
    struct FileBrowserSplitViewTests {
        @Test(arguments: [false, true])
        func resizingSurvivesPreviewChangesAndWindowResizes(remote: Bool) async throws {
            NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let tab = FileBrowserTab(path: "/fixture")
            let data = Data("# Preview\n\nA short document.\n".utf8)
            let file = FileBrowserEntry(path: "/fixture/document.md", name: "document.md", kind: .markdown, size: data.count, revision: "1")
            let localPreview: @MainActor @Sendable (FileBrowserEntry) async throws -> Data = { _ in data }
            let source = FileBrowserSource(id: "fixture", paneID: nil, localPreview: remote ? nil : localPreview) { operation in
                switch operation {
                case .list: .listing(.init(directory: "/fixture", homeDirectory: "/fixture", entries: [file], nextOffset: nil, revision: "1"))
                case .info: .info(file)
                case let .read(_, offset, _): .chunk(.init(path: file.path, revision: "1", offset: offset, data: Data(data.dropFirst(offset))))
                default: throw FileBrowserError.message("Unexpected fixture request")
                }
            }
            let host = NSHostingView(rootView: WorkspaceFileBrowserView(tab: tab, source: source))
            host.sizingOptions = []
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 1_200, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }

            try await settle(host)
            try expectDirectoryWidth(280, in: host)
            try adjust("accessibilityPerformIncrement", in: host)
            try await settle(host)
            try expectDirectoryWidth(320, in: host)
            try adjust("accessibilityPerformDecrement", in: host)
            try await settle(host)
            try expectDirectoryWidth(280, in: host)
            try adjust("accessibilityPerformIncrement", in: host)
            try await settle(host)

            for selected in [file.path, nil, file.path] {
                tab.selectedFile = selected
                try await settle(host)
                try expectDirectoryWidth(320, in: host)
            }
            #expect(tab.previewData == data)
            tab.refresh += 1
            try await settle(host)
            try expectDirectoryWidth(320, in: host)
            for (width, expected) in [(1_000.0, 320.0), (450, 242), (300, 146), (1_200, 320)] {
                window.setContentSize(.init(width: width, height: 700))
                try await settle(host)
                try expectDirectoryWidth(expected, in: host)
            }
        }

        @Test
        func markdownEditorWindowSurvivesRefreshAndReconnect() async throws {
            NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let tab = FileBrowserTab(path: "/fixture")
            let secondTab = FileBrowserTab(path: "/fixture")
            let bom = Data([0xEF, 0xBB, 0xBF])
            let initial = "# Original"
            let bytes = bom + Data(initial.utf8)
            let file = FileBrowserEntry(path: "/fixture/document.md", name: "document.md", kind: .markdown, size: bytes.count, revision: "1")
            var saved: Data?
            var saveAttempts = 0
            var currentConnection = UUID()
            var editorConnection = currentConnection
            func source(connectionID: UUID) -> FileBrowserSource {
                FileBrowserSource(id: "fixture", paneID: nil, connectionID: connectionID) { operation in
                    switch operation {
                    case .list:
                        return .listing(.init(directory: "/fixture", homeDirectory: "/fixture", entries: [file], nextOffset: nil, revision: "1"))
                    case .info:
                        return .info(file)
                    case let .read(path, offset, revision):
                        return .chunk(.init(path: path, revision: revision, offset: offset, data: Data(bytes.dropFirst(offset))))
                    case let .saveMarkdown(path, revision, data):
                        saveAttempts += 1
                        guard connectionID == currentConnection else {
                            throw FileBrowserError.message("The Host connection changed.")
                        }
                        #expect(path == file.path && revision == file.revision)
                        saved = data
                        return .info(.init(path: path, name: file.name, kind: .markdown, size: data.count, revision: "2"))
                    default: throw FileBrowserError.message("Unexpected fixture request")
                    }
                }
            }
            let host = NSHostingView(rootView: WorkspaceFileBrowserView(tab: tab, source: source(connectionID: currentConnection)) {
                source(connectionID: editorConnection)
            }.environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 1_200, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }

            try await settle(host)
            tab.selectedFile = file.path
            try await wait { tab.previewData == bytes }
            try await settle(host)
            try perform("accessibilityPerformPress", on: "file-edit-markdown", in: host)
            try await wait { markdownWindow(title: file.name) != nil }
            let editorWindow = try #require(markdownWindow(title: file.name))
            defer { editorWindow.close() }
            #expect(window.attachedSheet == nil)
            #expect(editorWindow.parent == nil)
            #expect(editorWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            #expect(editorWindow.styleMask.contains(.resizable))
            #expect(editorWindow.isMovable)
            #expect(editorWindow.collectionBehavior.contains(.managed))
            let initialWidth = editorWindow.frame.width
            editorWindow.setContentSize(.init(width: initialWidth + 80, height: 630))
            #expect(editorWindow.frame.width > initialWidth)
            let content = try #require(editorWindow.contentView)
            try await wait { editor(in: content) != nil }
            let textView = try #require(editor(in: content))
            #expect(textView.string == initial)
            let draft = "# 已编辑"
            textView.insertText(draft, replacementRange: NSRange(location: 0, length: (initial as NSString).length))
            try await settle(content)

            editorWindow.performClose(nil)
            try await chooseCloseAction("Keep Editing", in: editorWindow)
            #expect(editorWindow.isVisible)
            #expect(textView.string == draft)
            #expect(saveAttempts == 0)

            tab.refresh += 1
            try await settle(host)
            try perform("accessibilityPerformPress", on: "file-edit-markdown", in: host)
            #expect(markdownWindow(title: file.name) === editorWindow)
            #expect(editor(in: content)?.string == draft)

            let secondHost = NSHostingView(rootView: WorkspaceFileBrowserView(tab: secondTab, source: source(connectionID: currentConnection)) {
                source(connectionID: editorConnection)
            })
            window.contentView = secondHost
            secondTab.selectedFile = file.path
            try await wait { secondTab.previewData == bytes }
            try await settle(secondHost)
            try perform("accessibilityPerformPress", on: "file-edit-markdown", in: secondHost)
            #expect(markdownWindow(title: file.name) === editorWindow)
            window.contentView = nil

            currentConnection = UUID()
            try perform("accessibilityPerformPress", on: "file-markdown-save", in: content)
            try await wait { saveAttempts == 1 && element("file-markdown-save", in: content) != nil }
            #expect(saved == nil)
            editorConnection = currentConnection
            #expect(markdownWindow(title: file.name) === editorWindow)
            #expect(editor(in: content)?.string == draft)
            editorWindow.performClose(nil)
            try await chooseCloseAction("Save", in: editorWindow)
            try await wait { markdownWindow(title: file.name) == nil }
            #expect(saved == bom + Data(draft.utf8))
            #expect(saveAttempts == 2)
            #expect(tab.refresh == 2)
            #expect(secondTab.refresh == 1)
        }

        @Test
        func closingMarkdownEditorDiscardsOnlyWhenConfirmed() async throws {
            NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let tab = FileBrowserTab(path: "/fixture")
            let initial = "Original"
            let file = FileBrowserEntry(path: "/fixture/discard.md", name: "discard.md", kind: .markdown, size: initial.utf8.count, revision: "1")
            func open() throws -> NSWindow {
                FileBrowserMarkdownEditorWindow.present(file: file, data: Data(initial.utf8), tab: tab, sourceID: "fixture", colorScheme: .light) {
                    FileBrowserSource(id: "fixture", paneID: nil) { _ in
                        Issue.record("Closing without Save must not write the file")
                        throw FileBrowserError.message("Unexpected request")
                    }
                }
                return try #require(markdownWindow(title: file.name))
            }

            let cleanWindow = try open()
            defer { cleanWindow.close() }
            cleanWindow.performClose(nil)
            #expect(cleanWindow.attachedSheet == nil)
            #expect(!cleanWindow.isVisible)

            let window = try open()
            defer { window.close() }
            let content = try #require(window.contentView)
            try await wait { editor(in: content) != nil }
            let textView = try #require(editor(in: content))
            textView.insertText("Edited", replacementRange: NSRange(location: 0, length: initial.utf8.count))
            try await settle(content)
            try perform("accessibilityPerformPress", on: "file-markdown-cancel", in: content)
            try await chooseCloseAction("Discard Changes", in: window)
            try await wait { markdownWindow(title: file.name) == nil }

            let reopened = try open()
            defer { reopened.close() }
            let reopenedContent = try #require(reopened.contentView)
            try await wait { editor(in: reopenedContent)?.string == initial }
        }

        private func chooseCloseAction(_ title: String, in window: NSWindow) async throws {
            try await wait { window.attachedSheet?.contentView != nil }
            let content = try #require(window.attachedSheet?.contentView)
            let button = try #require(button(named: title, in: content))
            #expect(button.isEnabled)
            button.performClick(nil)
            try await wait { window.attachedSheet == nil }
        }

        private func button(named title: String, in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title {
                return button
            }
            return view.subviews.lazy.compactMap { button(named: title, in: $0) }.first
        }

        private func markdownWindow(title: String) -> NSWindow? {
            NSApplication.shared.windows.first {
                $0.identifier?.rawValue == "file-markdown-editor" && $0.title == title && $0.isVisible
            }
        }

        private func editor(in view: NSView) -> NSTextView? {
            if let editor = view as? NSTextView, editor.isEditable {
                return editor
            }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }

        private func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<100 {
                if predicate() {
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(predicate())
        }

        private func settle(_ host: NSView) async throws {
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
        }

        private func expectDirectoryWidth(_ expected: CGFloat, in view: NSView) throws {
            // A newly hosted preview can precede the List in AppKit's subview order.
            let scrollViews = scrollViews(in: view)
            let list = try #require(scrollViews.min {
                $0.convert(.zero, to: view).x < $1.convert(.zero, to: view).x
            })
            #expect(abs(list.frame.width - expected) < 2)
            for scroll in scrollViews {
                let frame = scroll.convert(scroll.bounds, to: view)
                #expect(frame.minX >= -1)
                #expect(frame.maxX <= view.bounds.width + 1)
            }
        }

        private func scrollViews(in view: NSView) -> [NSScrollView] {
            if let scroll = view as? NSScrollView {
                return [scroll]
            }
            return view.subviews.flatMap { scrollViews(in: $0) }
        }

        private func attribute(_ name: String, from node: NSObject) -> Any? {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue()
        }

        private func element(_ id: String, in node: NSObject) -> NSObject? {
            if attribute("accessibilityIdentifier", from: node) as? String == id {
                return node
            }
            for child in attribute("accessibilityChildren", from: node) as? [NSObject] ?? [] {
                if let match = element(id, in: child) {
                    return match
                }
            }
            if let view = node as? NSView {
                for child in view.subviews {
                    if let match = element(id, in: child) {
                        return match
                    }
                }
            }
            return nil
        }

        private func adjust(_ action: String, in view: NSView) throws {
            try perform(action, on: "file-browser-divider", in: view)
        }

        private func perform(_ action: String, on id: String, in view: NSView) throws {
            let node = try #require(element(id, in: view))
            let selector = NSSelectorFromString(action)
            try #require(node.responds(to: selector))
            let implementation = try #require(node.method(for: selector))
            let call = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            #expect(call(node, selector))
        }
    }
#endif
