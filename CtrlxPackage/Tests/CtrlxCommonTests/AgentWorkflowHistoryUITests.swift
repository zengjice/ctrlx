#if os(macOS)
    import AppKit
    import CtrlxNetworking
    import SwiftUI
    import Testing
    @testable import CtrlxCommon

    @MainActor
    @Suite(.serialized)
    struct AgentWorkflowHistoryUITests {
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

        private func attribute(_ name: String, from node: NSObject) -> Any? {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue()
        }

        private func press(_ node: NSObject) -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard node.responds(to: selector), let implementation = node.method(for: selector) else { return false }
            return unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(node, selector)
        }

        private func waitForElement(_ identifier: String) async throws -> NSObject {
            for _ in 0..<100 {
                for window in NSApplication.shared.windows where window.isVisible {
                    if let found = element(identifier, in: window) {
                        return found
                    }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw UIError.missing(identifier)
        }

        private enum UIError: Error { case missing(String) }

        @Test(arguments: [AgentWorkflowRunStatus.completed, .ended])
        func terminalHistoryRequiresConfirmationAndPreservesConfigurationAndNavigation(status: AgentWorkflowRunStatus) async throws {
            _ = NSApplication.shared
            NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let hostID = UUID()
            let node = AgentWorkflowNode(name: "Brief", content: .init(text: "Task"))
            let definition = AgentWorkflowDefinition(name: "Fixture", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id)
            func run(_ status: AgentWorkflowRunStatus) -> AgentWorkflowRun {
                var run = AgentWorkflowRun(definition: definition, instances: [], createdAt: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600))
                run.status = status
                run.revision = 7
                return run
            }
            let target = run(status), active = run(.running), paused = run(.paused)
            var runs = [target, active, paused]
            var deletions: [ManageAgentWorkflows] = []
            let endpoint = AgentWorkflowEndpoint(id: "fixture", name: "Private Host", connected: { true }, supported: { true }) { request in
                var response = AgentWorkflowResponse(hostID: hostID)
                switch request.operation {
                case .definitions:
                    response.definitions = .init(items: [.init(definition)], nextOffset: nil)
                case .runs:
                    response.runs = .init(items: runs.map(AgentWorkflowRunSummary.init), nextOffset: nil)
                case let .deleteRun(id, expectedRevision):
                    #expect(request.expectedHostID == hostID)
                    #expect(id == target.id && expectedRevision == target.revision)
                    deletions.append(request)
                    runs.removeAll { $0.id == id }
                default: Issue.record("Unexpected operation")
                }
                return response
            }
            let navigation = AgentWorkflowNavigation()
            navigation.path = [.host(endpoint.id)]
            let view = AgentWorkflowsView(endpoints: { [endpoint] }, openAgent: { _, _ in }, navigation: navigation)
                .environment(\.scenePhase, .active)
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 640, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: view)
            hosting.sizingOptions = []
            window.contentView = hosting
            NSApplication.shared.setActivationPolicy(.accessory)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            defer { window.close() }
            let entryID = "workflow-delete-run-\(target.id)"
            let entry = try await waitForElement(entryID)
            #expect(element("workflow-delete-run-\(active.id)", in: window) == nil)
            #expect(element("workflow-delete-run-\(paused.id)", in: window) == nil)
            #expect(press(entry))
            let confirm = try await waitForElement("workflow-confirm-delete-run")
            #expect(deletions.isEmpty)
            #expect(navigation.path == [.host(endpoint.id)])
            // The confirmation dismisses this accessibility node synchronously.
            // Verify its effect rather than the node's press return value.
            _ = press(confirm)
            for _ in 0..<100 where deletions.isEmpty || element(entryID, in: window) != nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(deletions.count == 1)
            #expect(element(entryID, in: window) == nil)
            #expect(runs.map(\.id) == [active.id, paused.id])
            #expect(navigation.path == [.host(endpoint.id)])
        }
    }
#endif
