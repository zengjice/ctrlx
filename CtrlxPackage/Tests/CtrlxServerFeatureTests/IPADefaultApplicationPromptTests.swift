#if os(macOS)
    import AppKit
    import CtrlxCommon
    import Dependencies
    import SwiftUI
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite(.serialized)
    struct IPADefaultApplicationPromptTests {
        @Test
        func cancellationRetrySuccessAndClosingWhileWaiting() async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            var completion: CheckedContinuation<Void, Error>?
            var reads = 0
            let prompt = withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[IPAFileAssociationClient.self] = .init(current: {
                    reads += 1
                    return .init(applicationName: "CtrlX", isCtrlX: true)
                }, setDefault: {
                    try await withCheckedThrowingContinuation { completion = $0 }
                })
            } operation: {
                IPADefaultApplicationPrompt(current: .init(applicationName: "Other App", isCtrlX: false))
                    .environment(AppSettings())
            }
            let presented = PromptPresentation()
            let root = Text("Isolated default application prompt test")
                .frame(width: 600, height: 500)
                .sheet(isPresented: Binding(get: { presented.isPresented }, set: { presented.isPresented = $0 })) {
                    prompt
                }
            let window = NSWindow(contentRect: .init(x: -2_000, y: -2_000, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: root)
            // All input targets this fixture's accessibility nodes. No real association changes.
            window.orderBack(nil)
            defer {
                completion?.resume(throwing: CancellationError())
                window.close()
            }
            presented.isPresented = true
            try await press("Set as Default", in: window)
            let close = try await element("Close", in: window)
            #expect(action("isAccessibilityEnabled", on: close))
            let set = try await element("Set as Default", in: window)
            #expect(!action("isAccessibilityEnabled", on: set))
            try #require(completion).resume(throwing: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            completion = nil
            _ = try await element("Setting the default application was cancelled.", in: window)
            #expect(presented.isPresented)

            try await press("Set as Default", in: window)
            _ = try await element("Close", in: window)
            try #require(completion).resume()
            completion = nil
            _ = try await element("CtrlX is now the default application for IPA files.", in: window)
            #expect(presented.isPresented)
            #expect(reads == 1)
            try await press("Done", in: window)
            try await waitForDismissal(presented, window: window)

            presented.isPresented = true
            try await press("Set as Default", in: window)
            _ = try await element("Close", in: window)
            try await press("Close", in: window)
            try await waitForDismissal(presented, window: window)
            try #require(completion).resume()
            completion = nil
            try await Task.sleep(for: .milliseconds(100))
            #expect(reads == 1)
            #expect(!presented.isPresented)
        }

        private func waitForDismissal(_ state: PromptPresentation, window: NSWindow) async throws {
            for _ in 0..<100 {
                if !state.isPresented, window.attachedSheet == nil {
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw PromptTestError.missingState("dismissed")
        }

        private func press(_ label: String, in window: NSWindow) async throws {
            let button = try await element(label, in: window)
            #expect(action("isAccessibilityEnabled", on: button))
            #expect(action("accessibilityPerformPress", on: button))
        }

        private func element(_ label: String, in window: NSWindow) async throws -> NSObject {
            for _ in 0..<100 {
                var queue: [Any] = window.attachedSheet?.contentView.map { [$0] } ?? []
                while !queue.isEmpty {
                    guard let next = queue.removeFirst() as? NSObject else { continue }
                    if ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains(where: { attribute($0, from: next) as? String == label }) {
                        return next
                    }
                    queue += attribute("accessibilityChildren", from: next) as? [Any] ?? []
                    if let view = next as? NSView {
                        queue += view.subviews
                    }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw PromptTestError.missingState(label)
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

    @MainActor @Observable
    final private class PromptPresentation {
        var isPresented = false
    }

    private enum PromptTestError: Error {
        case missingState(String)
    }
#endif
