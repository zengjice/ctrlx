#if os(macOS)
    import AppKit
    import CtrlxNetworking
    import SwiftUI
    import Testing
    @testable import CtrlxCommon

    @MainActor
    @Suite(.serialized)
    struct AgentWorkflowModelSettingsUITests {
        private func element(_ id: String, in root: Any) -> NSObject? {
            guard let object = root as? NSObject else { return nil }
            let selector = NSSelectorFromString("accessibilityIdentifier")
            if object.responds(to: selector), object.perform(selector)?.takeUnretainedValue() as? String == id {
                return object
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: children), let values = object.perform(children)?.takeUnretainedValue() as? [Any] {
                for child in values {
                    if let result = element(id, in: child) {
                        return result
                    }
                }
            }
            if let view = object as? NSView {
                for child in view.subviews {
                    if let result = element(id, in: child) {
                        return result
                    }
                }
            }
            return nil
        }

        private func action(_ name: String, on object: NSObject) -> Bool {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
            return unsafeBitCast(method, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(object, selector)
        }

        private func waitFor(_ id: String, window: NSWindow, enabled: Bool? = nil) async throws -> NSObject {
            for _ in 0..<100 {
                for current in [window] + window.sheets {
                    if let value = element(id, in: current), enabled == nil || action("isAccessibilityEnabled", on: value) == enabled {
                        return value
                    }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw AgentWorkflowError("Missing model control: \(id)")
        }

        @Test(arguments: ["apply", "cancel", "inherit", "stale"])
        func modelSheetPreservesOverridesUntilConfirmedAndRejectsAChangedAgent(mode: String) async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let hostID = UUID()
            let instance = AgentWorkflowInstance(hostID: hostID, pluginID: "codex", processID: 42, processRuntimeID: "runtime", workspacePane: .init(serverID: "1:1", sessionID: UUID(), windowID: UUID(), paneID: UUID()), paneID: "%1", conversationID: "conversation", displayName: "Agent", workingDirectory: "/fixture", capabilities: .init(maximumInputBytes: 100_000), readiness: .ready)
            let override = AgentModelSelection(model: "special", effort: "high")
            var selected: AgentModelSelection? = override
            var reads = 0
            let endpoint = AgentWorkflowEndpoint(id: "fixture", name: "Host", connected: { true }, supported: { true }) { request in
                #expect(request.expectedHostID == hostID)
                guard case let .models(id, refresh) = request.operation else { throw AgentWorkflowError("Unexpected model request") }
                #expect(id == instance.id && !refresh)
                reads += 1
                var response = AgentWorkflowResponse(hostID: hostID)
                response.modelSnapshot = .init(runtimeID: mode == "stale" ? "replacement" : instance.processRuntimeID, models: [.init(id: "default", name: "Default", efforts: ["low"], defaultEffort: "low"), .init(id: "special", name: "Special", efforts: ["medium", "high"], defaultEffort: "medium")], selection: .init(model: "default", effort: "low"), unavailableReason: nil)
                return response
            }
            let hosting = NSHostingView(rootView: AgentWorkflowModelSettings(endpoint: endpoint, hostID: hostID, instance: instance, selection: Binding(get: { selected }, set: { selected = $0 })).padding())
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 600, height: 500), styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            #expect(try action("accessibilityPerformPress", on: await waitFor("workflow-model-open", window: window, enabled: true)))
            for _ in 0..<100 where reads == 0 {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(reads == 1 && selected == override)
            let target = mode == "apply" ? "workflow-model-apply" : mode == "inherit" ? "workflow-model-inherit" : "workflow-model-cancel"
            if mode == "stale" {
                _ = try await waitFor("workflow-model-apply", window: window, enabled: false)
            }
            #expect(try action("accessibilityPerformPress", on: await waitFor(target, window: window, enabled: true)))
            for _ in 0..<100 where !window.sheets.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(selected == (mode == "inherit" ? nil : override))
            #expect(window.sheets.isEmpty)
        }
    }
#endif
