#if os(macOS)
    import AppKit
    import CtrlxNetworking
    import SwiftUI
    import Testing
    @testable import CtrlxCommon

    @MainActor
    @Suite(.serialized)
    struct BrowserBookmarksUITests {
        private func element(_ identifier: String, in root: Any) -> NSObject? {
            guard let node = root as? NSObject else { return nil }
            if attribute("accessibilityIdentifier", from: node) as? String == identifier {
                return node
            }
            for child in attribute("accessibilityChildren", from: node) as? [Any] ?? [] {
                if let match = element(identifier, in: child) {
                    return match
                }
            }
            if let view = node as? NSView {
                for child in view.subviews {
                    if let match = element(identifier, in: child) {
                        return match
                    }
                }
            }
            return nil
        }

        /// SwiftUI nodes implement AppKit's selectors without declaring the full protocol.
        private func attribute(_ name: String, from node: NSObject) -> Any? {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue()
        }

        private func action(_ name: String, on node: NSObject) -> Bool {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector), let implementation = node.method(for: selector) else { return false }
            let call = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            return call(node, selector)
        }

        private func waitForElement(_ identifier: String) async throws -> NSObject {
            for _ in 0..<100 {
                for window in NSApplication.shared.windows where window.isVisible {
                    if let element = element(identifier, in: window) {
                        return element
                    }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw UIError.missing(identifier)
        }

        private enum UIError: Error { case missing(String) }

        @Test(arguments: [false, true])
        func savesAndReopensNativePopoverWithoutReplayingSave(readOnly: Bool) async throws {
            _ = NSApplication.shared
            NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let bookmark = BrowserBookmark(title: "Test Page", url: "https://example.com/path?a=1#part")
            var saved: [BrowserBookmark] = []
            var operations: [BrowserBookmarkOperation] = []
            var navigations: [String] = []
            let view = BrowserBookmarksButton(
                url: bookmark.url,
                navigationUnavailableReason: readOnly ? "Take Control to open a bookmark." : nil,
                request: { operation in
                    operations.append(operation)
                    switch operation {
                    case .list: break
                    case .saveCurrentPage: saved = [bookmark]
                    case .remove: saved = []
                    }
                    return saved
                },
                navigate: { navigations.append($0) }
            ).padding()
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 120, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            window.contentView = host
            NSApplication.shared.setActivationPolicy(.accessory)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            defer { window.close() }
            let entry = try await waitForElement("browser-bookmarks")
            #expect(action("accessibilityPerformPress", on: entry))
            let save = try await waitForElement("browser-bookmark-save")
            for _ in 0..<100 where !action("isAccessibilityEnabled", on: save) {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(action("isAccessibilityEnabled", on: save))
            #expect(action("accessibilityPerformPress", on: save))
            for _ in 0..<100 where operations.filter({ $0 == .saveCurrentPage }).isEmpty {
                try await Task.sleep(for: .milliseconds(20))
            }
            let row = try await waitForElement("browser-bookmark-\(bookmark.id)")
            #expect(operations.filter { $0 == .saveCurrentPage }.count == 1)
            #expect(!action("isAccessibilityEnabled", on: save))
            #expect(action("isAccessibilityEnabled", on: row) == !readOnly)
            if !readOnly {
                #expect(action("accessibilityPerformPress", on: row))
                #expect(navigations == [bookmark.url])
                #expect(action("accessibilityPerformPress", on: entry))
                _ = try await waitForElement("browser-bookmark-save")
                try await Task.sleep(for: .milliseconds(50))
                #expect(operations.filter { $0 == .saveCurrentPage }.count == 1)
            } else {
                #expect(navigations.isEmpty)
            }
        }
    }
#endif
