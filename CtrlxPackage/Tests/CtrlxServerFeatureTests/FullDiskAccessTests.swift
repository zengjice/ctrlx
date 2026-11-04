#if os(macOS)
    import AppKit
    import CtrlxCommon
    import Dependencies
    import SwiftUI
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite(.serialized)
    struct FullDiskAccessTests {
        @Test("The introduction waits for foreground setup, then stays dismissed across launches")
        func startupIntroduction() {
            withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: {
                let settings = AppSettings()
                #expect(!settings.hasShownFullDiskAccessPrompt)
                #expect(!settings.takeFullDiskAccessPrompt(isReady: false, isActive: true, isTesting: false))
                #expect(!settings.takeFullDiskAccessPrompt(isReady: true, isActive: false, isTesting: false))
                #expect(!AppSettings().hasShownFullDiskAccessPrompt)

                #expect(settings.takeFullDiskAccessPrompt(isReady: true, isActive: true, isTesting: false))
                #expect(!settings.takeFullDiskAccessPrompt(isReady: true, isActive: true, isTesting: false))
                let relaunched = AppSettings()
                #expect(relaunched.hasShownFullDiskAccessPrompt)
                #expect(!relaunched.takeFullDiskAccessPrompt(isReady: true, isActive: true, isTesting: false))
            }
        }

        @Test("E2E launch does not consume the user's introduction")
        func isolatedLaunch() {
            withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: {
                let settings = AppSettings()
                #expect(!settings.takeFullDiskAccessPrompt(isReady: true, isActive: true, isTesting: true))
                #expect(!AppSettings().hasShownFullDiskAccessPrompt)
            }
        }

        @Test("The guide opens settings only on click and lets the user retry a failed launch")
        func guideActions() async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            var settingsOpens = 0
            var finderOpens = 0
            let guide = withDependencies {
                $0[FullDiskAccessClient.self] = .init(openSettings: {
                    settingsOpens += 1
                    if settingsOpens == 1 {
                        throw GuideTestError.openFailed
                    }
                }, revealApplication: { finderOpens += 1 })
            } operation: {
                FullDiskAccessPrompt()
            }
            let window = NSWindow(contentRect: .init(x: -2_000, y: -2_000, width: 560, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: guide)
            window.orderBack(nil)
            defer { window.close() }

            let open = try await element("full-disk-access-settings", in: window)
            #expect(settingsOpens == 0 && finderOpens == 0)
            #expect(action("accessibilityPerformPress", on: open))
            _ = try await element("Settings could not be opened for this test.", in: window)
            #expect(action("accessibilityPerformPress", on: open))
            #expect(settingsOpens == 2)
            let reveal = try await element("full-disk-access-reveal", in: window)
            #expect(action("accessibilityPerformPress", on: reveal))
            #expect(finderOpens == 1)
            let close = try await element("full-disk-access-dismiss", in: window)
            #expect(action("isAccessibilityEnabled", on: close))
            #expect(window.attachedSheet == nil)
        }

        private func element(_ value: String, in window: NSWindow) async throws -> NSObject {
            for _ in 0..<100 {
                var queue: [Any] = window.contentView.map { [$0] } ?? []
                while !queue.isEmpty {
                    guard let node = queue.removeFirst() as? NSObject else { continue }
                    if ["accessibilityIdentifier", "accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains(where: { attribute($0, from: node) as? String == value }) {
                        return node
                    }
                    queue += attribute("accessibilityChildren", from: node) as? [Any] ?? []
                    if let view = node as? NSView {
                        queue += view.subviews
                    }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw GuideTestError.missingElement(value)
        }

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
    }

    private enum GuideTestError: LocalizedError {
        case openFailed
        case missingElement(String)

        var errorDescription: String? {
            switch self {
            case .openFailed: "Settings could not be opened for this test."
            case let .missingElement(value): "Missing guide element: \(value)"
            }
        }
    }
#endif
