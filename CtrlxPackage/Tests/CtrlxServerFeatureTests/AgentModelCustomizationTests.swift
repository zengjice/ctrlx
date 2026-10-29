import AppKit
import CtrlxNetworking
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite(.serialized)
struct AgentModelCustomizationTests {
    @Test("Native checkboxes apply multiple changes without dismissing the popover")
    func continuousCustomization() async throws {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let state = CustomizationState()
        let snapshot = AgentModelSnapshot(runtimeID: "test", models: [
            .init(id: "current", name: "Current Model", efforts: ["low", "high"], defaultEffort: "high"),
            .init(id: "second", name: "Second Model", efforts: ["low", "high"], defaultEffort: "high"),
            .init(id: "third", name: "Third Model", efforts: ["low", "high"], defaultEffort: "high"),
        ], selection: .init(model: "current", effort: "high"), unavailableReason: nil)
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 500, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSButton(frame: .init(x: 200, y: 100, width: 80, height: 30))
        window.contentView?.addSubview(anchor)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: AgentModelCustomization(
            snapshot: snapshot,
            hidden: Binding(get: { state.hidden }, set: { state.hidden = $0 }),
            unavailableReason: "Wait for the Agent to finish before switching models.",
            refreshing: false, refresh: { state.refreshes += 1 }, done: { popover.close() }
        ))
        defer { popover.close()
            window.close()
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        let content = try #require(popover.contentViewController?.view)

        for id in ["model-shortcut-visible-second", "model-shortcut-visible-third", "model-effort-visible-low"] {
            let checkbox = try await element(in: content, identifier: id)
            #expect(action("accessibilityPerformPress", on: checkbox))
            #expect(popover.isShown)
        }
        #expect(state.hidden.models == ["second", "third"])
        #expect(state.hidden.efforts == ["low"])
        let current = try await element(in: content, identifier: "model-shortcut-visible-current")
        #expect(!action("isAccessibilityEnabled", on: current))
        let restore = try await element(in: content, label: "Restore Defaults")
        #expect(action("accessibilityPerformPress", on: restore))
        #expect(state.hidden.models.isEmpty && state.hidden.efforts.isEmpty)
        #expect(popover.isShown)
        let refresh = try await element(in: content, label: "Refresh Models")
        #expect(action("accessibilityPerformPress", on: refresh))
        #expect(state.refreshes == 1 && popover.isShown)
        let done = try await element(in: content, label: "Done")
        #expect(action("accessibilityPerformPress", on: done))
        for _ in 0..<50 where popover.isShown {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!popover.isShown)
    }

    private func element(in root: NSView, identifier: String? = nil, label: String? = nil) async throws -> NSObject {
        for _ in 0..<50 {
            var queue: [Any] = [root]
            while !queue.isEmpty {
                guard let next = queue.removeFirst() as? NSObject else { continue }
                if let identifier, attribute("accessibilityIdentifier", from: next) as? String == identifier {
                    return next
                }
                if let label, attribute("accessibilityLabel", from: next) as? String == label || attribute("accessibilityTitle", from: next) as? String == label {
                    return next
                }
                queue += attribute("accessibilityChildren", from: next) as? [Any] ?? []
                if let view = next as? NSView {
                    queue += view.subviews
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CustomizationTestError.missingControl(identifier ?? label ?? "unknown")
    }

    /// SwiftUI accessibility nodes implement these selectors without declaring the full protocol.
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

@Observable
@MainActor
final private class CustomizationState {
    var hidden = AgentModelPreferences.Hidden()
    var refreshes = 0
}

private enum CustomizationTestError: Error {
    case missingControl(String)
}
