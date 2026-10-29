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

        private func divider(in node: NSObject) -> NSObject? {
            if attribute("accessibilityIdentifier", from: node) as? String == "file-browser-divider" {
                return node
            }
            for child in attribute("accessibilityChildren", from: node) as? [NSObject] ?? [] {
                if let match = divider(in: child) {
                    return match
                }
            }
            if let view = node as? NSView {
                for child in view.subviews {
                    if let match = divider(in: child) {
                        return match
                    }
                }
            }
            return nil
        }

        private func adjust(_ action: String, in view: NSView) throws {
            let node = try #require(divider(in: view))
            let selector = NSSelectorFromString(action)
            try #require(node.responds(to: selector))
            let implementation = try #require(node.method(for: selector))
            let call = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            #expect(call(node, selector))
        }
    }
#endif
