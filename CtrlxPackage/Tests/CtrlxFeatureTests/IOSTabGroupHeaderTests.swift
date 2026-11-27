#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import CtrlxFeature

    @MainActor
    @Suite(.serialized)
    struct IOSTabGroupHeaderTests {
        @Test("The entire group row toggles expansion, with a separate actions menu", arguments: [false, true])
        func wholeRowToggles(manual: Bool) async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            var expanded = false
            var ungrouped = false
            let header = IOSTabGroupHeader(
                isExpanded: .init(get: { expanded }, set: { expanded = $0 }),
                onUngroup: manual ? { ungrouped = true } : nil
            ) {
                HStack {
                    Text("Development")
                    Spacer()
                    Text("3")
                }
            }
            let hosting = NSHostingView(rootView: header)
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 400, height: 44), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }

            for _ in 0..<100 {
                if element("tab-group-toggle", in: hosting) != nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            hosting.layoutSubtreeIfNeeded()
            let toggle = try #require(element("tab-group-toggle", in: hosting))
            let toggleFrame = try frame(toggle)
            let rowFrame = window.convertToScreen(hosting.convert(hosting.bounds, to: nil))
            #expect(abs(toggleFrame.minX - rowFrame.minX) < 1)
            #expect(toggleFrame.width >= rowFrame.width - (manual ? 60 : 1))
            #expect(toggleFrame.height >= 44)

            // Text, whitespace, count and chevron must all hit the same toggle.
            for fraction in [0.05, 0.5, 0.85, 0.99] {
                let point = CGPoint(x: toggleFrame.minX + toggleFrame.width * fraction, y: toggleFrame.midY)
                let hit = try #require(hosting.accessibilityHitTest(point) as? NSObject)
                #expect(isToggle(hit), "Expected the group toggle at \(point)")
            }
            #expect((element("tab-group-actions", in: hosting) != nil) == manual)
            if let menu = element("tab-group-actions", in: hosting) {
                let menuFrame = try frame(menu)
                #expect(menuFrame.minX >= toggleFrame.maxX - 1)
            }

            let selector = NSSelectorFromString("accessibilityPerformPress")
            let implementation = try #require(toggle.method(for: selector))
            let press = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            #expect(press(toggle, selector))
            #expect(expanded)
            #expect(press(toggle, selector))
            #expect(!expanded)
            #expect(!ungrouped)
        }

        private func attribute(_ name: String, from object: NSObject) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }

        private func element(_ id: String, in object: NSObject) -> NSObject? {
            if attribute("accessibilityIdentifier", from: object) as? String == id {
                return object
            }
            for child in attribute("accessibilityChildren", from: object) as? [NSObject] ?? [] {
                if let found = element(id, in: child) {
                    return found
                }
            }
            return nil
        }

        private func isToggle(_ object: NSObject) -> Bool {
            if attribute("accessibilityIdentifier", from: object) as? String == "tab-group-toggle" {
                return true
            }
            guard let parent = attribute("accessibilityParent", from: object) as? NSObject else { return false }
            return isToggle(parent)
        }

        private func frame(_ object: NSObject) throws -> CGRect {
            let selector = NSSelectorFromString("accessibilityFrame")
            let implementation = try #require(object.method(for: selector))
            return unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> CGRect).self)(object, selector)
        }
    }
#endif
