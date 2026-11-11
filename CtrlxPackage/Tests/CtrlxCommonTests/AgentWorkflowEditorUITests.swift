#if os(macOS)
    import AppKit
    import CtrlxNetworking
    import SwiftUI
    import Testing
    @testable import CtrlxCommon

    @MainActor
    @Suite(.serialized)
    struct AgentWorkflowEditorUITests {
        private func attribute(_ name: String, from node: NSObject) -> Any? {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue()
        }

        private func element(_ id: String, in root: Any, attributeName: String = "accessibilityIdentifier") -> NSObject? {
            guard let object = root as? NSObject else { return nil }
            if attribute(attributeName, from: object) as? String == id {
                return object
            }
            for child in attribute("accessibilityChildren", from: object) as? [Any] ?? [] {
                if let found = element(id, in: child, attributeName: attributeName) {
                    return found
                }
            }
            if let view = object as? NSView {
                for child in view.subviews {
                    if let found = element(id, in: child, attributeName: attributeName) {
                        return found
                    }
                }
            }
            if let window = object as? NSWindow {
                for sheet in window.sheets {
                    if let found = element(id, in: sheet, attributeName: attributeName) {
                        return found
                    }
                }
            }
            return nil
        }

        private func press(_ object: NSObject) -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
            return unsafeBitCast(method, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(object, selector)
        }

        private func wait(_ message: String = "Workflow editor did not reach the expected UI state", _ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() {
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(condition(), "\(message)")
        }

        private func click(_ id: String, in window: NSWindow) async throws {
            try await wait { element(id, in: window) != nil }
            let object = try #require(element(id, in: window))
            try #require(object.responds(to: NSSelectorFromString("accessibilityPerformPress")), "Cannot press \(id)")
            _ = press(object)
            try await Task.sleep(for: .milliseconds(50))
        }

        private func inputs(in view: NSView) -> [AgentWorkflowTextInput.TextView] {
            guard !view.isHiddenOrHasHiddenAncestor else { return [] }
            if let text = view as? AgentWorkflowTextInput.TextView {
                return [text]
            }
            return view.subviews.flatMap { inputs(in: $0) }
        }

        private func capture(_ view: NSView, name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["CTRLX_WORKFLOW_UI_EVIDENCE"] else { return }
            view.layoutSubtreeIfNeeded()
            view.window?.displayIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }

        @Test(arguments: ["unchanged", "edit", "import", "restart"])
        func compactOverviewEditsOneStepAndPreservesCollapsedSettings(mode: String) async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let edit = mode == "edit"
            let hostID = UUID()
            let instances = ["Developer", "Reviewer"].enumerated().map { index, name in
                AgentWorkflowInstance(hostID: hostID, pluginID: "codex", processID: Int32(index + 42), processRuntimeID: "runtime-\(index)", workspacePane: .init(serverID: "1:1", sessionID: UUID(), windowID: UUID(), paneID: UUID()), paneID: "%\(index)", conversationID: "conversation-\(index)", displayName: name, workingDirectory: "/fixture", capabilities: .init(maximumInputBytes: 100_000), readiness: .ready)
            }
            let catalog = mode == "restart" ? instances.map { old in
                var pane = old.workspacePane
                pane.serverID = "restarted-server"
                return AgentWorkflowInstance(
                    hostID: old.hostID,
                    pluginID: old.pluginID,
                    processID: old.processID + 100,
                    processRuntimeID: "restarted-\(old.processRuntimeID)",
                    workspacePane: pane,
                    paneID: old.paneID,
                    conversationID: old.conversationID,
                    displayName: old.displayName,
                    workingDirectory: old.workingDirectory,
                    capabilities: old.capabilities,
                    readiness: .ready
                )
            } : instances
            let image = AgentWorkflowAttachment(id: UUID(), name: "task.png", mediaType: "image/png", byteCount: 100, sha256: String(repeating: "a", count: 64))
            var definition = AgentWorkflowDefinition(name: "Develop, review and repair", hostID: hostID, nodes: [], edges: [], entryNodeID: UUID(), initialInput: .init(text: "Build the requested feature", attachmentIDs: [image.id]))
            AgentWorkflowReviewTemplate.apply(to: &definition, developerID: instances[0].id, reviewerID: instances[1].id)
            definition.nodes[0].input.text = "Initial development instructions"
            definition.nodes[0].modelSelection = .init(model: "configured-model", effort: "high")
            definition.nodes[3].input.attachmentIDs = [image.id]
            definition.rememberTargets(from: instances)
            let original = definition
            try AgentWorkflowWire.validate(original)
            var saved: AgentWorkflowDefinition?
            var loaded = false
            var imageAttempts = 0
            var firstImageBytes = Data()
            var importedImage: AgentWorkflowAttachment?
            let endpoint = AgentWorkflowEndpoint(id: "fixture", name: "Host", connected: { true }, supported: { true }) { request in
                #expect(request.expectedHostID == hostID)
                var response = AgentWorkflowResponse(hostID: hostID)
                switch request.operation {
                case .catalog:
                    response.instances = .init(items: catalog, nextOffset: nil)
                    loaded = true
                case .attachments: response.attachments = [image]
                case let .uploadAttachment(.image(id, name, mediaType, bytes, sha256)):
                    #expect(mode == "import")
                    imageAttempts += 1
                    if imageAttempts == 1 {
                        firstImageBytes = bytes
                        throw AgentWorkflowError("Fixture upload failed")
                    }
                    #expect(bytes == firstImageBytes)
                    let attachment = AgentWorkflowAttachment(id: id, name: name, mediaType: mediaType, byteCount: Int64(bytes.count), sha256: sha256)
                    importedImage = attachment
                    response.uploadedOffset = bytes.count
                    response.attachments = [attachment]
                case .uploadAttachment(.cancel): response.uploadedOffset = 0
                case .discardAttachments: break
                case let .save(value, revision):
                    #expect(revision == original.revision)
                    saved = value
                    response.definition = value
                default: Issue.record("Unexpected editor request: \(request.operation)")
                }
                return response
            }
            let hosting = NSHostingView(rootView: AgentWorkflowEditor(endpoint: endpoint, definition: original, isNew: false, createAgent: nil))
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 700, height: 1_100), styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            try await wait { loaded }
            #expect(inputs(in: hosting).isEmpty)
            for node in original.nodes {
                #expect(element("workflow-step-toggle-\(node.id)", in: window) != nil)
            }
            try capture(hosting, name: "compact-overview")
            let first = original.nodes[0]
            let second = original.nodes[1]
            try await click("workflow-step-toggle-\(first.id)", in: window)
            try await wait("First step should expose one instruction editor") { inputs(in: hosting).count == 1 }
            let input = try #require(inputs(in: hosting).first)
            #expect(input.string == first.input.text)
            if mode == "import" {
                let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQaPjQAMIMMAYARzIIQdQEEEMAAAAASUVORK5CYII="))
                input.receive?([.image(.init(data: png, format: .png))])
                try await wait("Failed imports should stay visible for retry") { element("workflow-image-retry", in: window) != nil }
                for id in ["workflow-step-toggle-\(second.id)", "workflow-add-agent-step", "workflow-add-content-step"] {
                    let control = try #require(element(id, in: window))
                    let enabled = NSSelectorFromString("isAccessibilityEnabled")
                    let method = try #require(control.method(for: enabled))
                    #expect(!unsafeBitCast(method, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(control, enabled))
                }
                try await click("workflow-add-content-step", in: window)
                #expect(inputs(in: hosting).count == 1 && inputs(in: hosting).first?.string == first.input.text)
                #expect(imageAttempts == 1 && element("workflow-image-retry", in: window) != nil)
                try await click("workflow-image-retry", in: window)
                try await wait("Retry should upload the retained image without selecting it again") {
                    imageAttempts == 2 && importedImage != nil && element("workflow-image-retry", in: window) == nil
                }
            }
            if edit {
                input.string = "Updated instructions, kept after switching steps"
                input.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: input))
            }
            try await click("workflow-step-toggle-\(second.id)", in: window)
            try await wait("Switching steps should show only the second step's instructions") { inputs(in: hosting).count == 1 && inputs(in: hosting).first?.string == second.input.text }
            try await click("workflow-step-options-\(second.id)", in: window)
            #expect(element("workflow-model-\(second.id)", in: window) != nil)
            try await click("workflow-step-upstream-\(second.id)", in: window)
            try capture(hosting, name: "expanded-step-options")
            try await click("workflow-step-toggle-\(first.id)", in: window)
            try await wait { inputs(in: hosting).count == 1 }
            #expect(inputs(in: hosting).first?.string == (edit ? "Updated instructions, kept after switching steps" : first.input.text))
            try capture(hosting, name: "expanded-step")
            try await click("workflow-initial-task-toggle", in: window)
            try await wait { inputs(in: hosting).count == 2 }
            try await click("workflow-initial-task-toggle", in: window)
            try await click("workflow-agents-toggle", in: window)
            try await click("workflow-agents-toggle", in: window)
            try await click("workflow-execution-toggle", in: window)
            try await click("workflow-execution-toggle", in: window)
            try await click("workflow-editor-save", in: window)
            try await wait { saved != nil }
            var expected = original
            for index in [0, 2, 4] {
                expected.nodes[index].agentInstanceID = catalog[0].id
            }
            expected.nodes[1].agentInstanceID = catalog[1].id
            for index in catalog.indices {
                expected.participants?[index].agentInstanceID = catalog[index].id
            }
            expected.agentTargets = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0.target) })
            if edit {
                expected.nodes[0].input.text = "Updated instructions, kept after switching steps"
            }
            if let importedImage {
                expected.nodes[0].input.attachmentIDs.append(importedImage.id)
            }
            #expect(saved == expected)
        }

        @Test(arguments: [false, true])
        func newStepsOpenForEditingAndContentWorkflowsDoNotExpandAgentManagement(empty: Bool) async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let hostID = UUID()
            let node = AgentWorkflowNode(name: "Original content", content: .init(text: "Original instructions"))
            let definition = AgentWorkflowDefinition(name: "Content workflow", hostID: hostID, nodes: empty ? [] : [node], edges: [], entryNodeID: node.id)
            var loaded = false
            let endpoint = AgentWorkflowEndpoint(id: "fixture", name: "Host", connected: { true }, supported: { true }) { request in
                var response = AgentWorkflowResponse(hostID: hostID)
                switch request.operation {
                case .catalog:
                    response.instances = .init(items: [], nextOffset: nil)
                    loaded = true
                case .attachments: response.attachments = []
                default: Issue.record("Unexpected content editor request")
                }
                return response
            }
            let hosting = NSHostingView(rootView: AgentWorkflowEditor(endpoint: endpoint, definition: definition, isNew: empty, createAgent: nil))
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 600, height: 900), styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            try await wait { loaded }
            #expect(element("Refresh Agents", in: window, attributeName: "accessibilityLabel") == nil)
            #expect(inputs(in: hosting).isEmpty)
            try await click("workflow-add-content-step", in: window)
            try await wait("A new step should open its instruction editor") { inputs(in: hosting).count == 1 }
            #expect(inputs(in: hosting).first?.string == "")
        }

        @Test(arguments: [false, true])
        func addingAgentStepsChoosesInstancesDirectlyAndReusesParticipants(empty: Bool) async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let hostID = UUID()
            let instances = ["Developer", "Reviewer"].enumerated().map { index, name in
                AgentWorkflowInstance(hostID: hostID, pluginID: "codex", processID: Int32(index + 42), processRuntimeID: "runtime-\(index)", workspacePane: .init(serverID: "1:1", sessionID: UUID(), windowID: UUID(), paneID: UUID()), paneID: "%\(index)", conversationID: "conversation-\(index)", displayName: name, workingDirectory: "/fixture", capabilities: .init(maximumInputBytes: 100_000), readiness: .ready)
            }
            let content = AgentWorkflowNode(name: "Instructions", content: .init(text: "Build the feature"), initialTask: .textAndAttachments)
            let definition = AgentWorkflowDefinition(name: "Direct selection", hostID: hostID, nodes: empty ? [] : [content], edges: [], entryNodeID: content.id, initialInput: .init(text: "Build the feature"))
            var saved: AgentWorkflowDefinition?
            var loaded = false
            let endpoint = AgentWorkflowEndpoint(id: "fixture", name: "Host", connected: { true }, supported: { true }) { request in
                var response = AgentWorkflowResponse(hostID: hostID)
                switch request.operation {
                case .catalog:
                    response.instances = .init(items: instances, nextOffset: nil)
                    loaded = true
                case .attachments: response.attachments = []
                case let .save(value, revision):
                    #expect(revision == (empty ? nil : definition.revision))
                    try AgentWorkflowWire.validate(value)
                    saved = value
                    response.definition = value
                default: Issue.record("Unexpected Agent picker request")
                }
                return response
            }
            let hosting = NSHostingView(rootView: AgentWorkflowEditor(endpoint: endpoint, definition: definition, isNew: empty, createAgent: nil))
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 700, height: 1_100), styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            try await wait { loaded }
            try await click("workflow-add-agent-step", in: window)
            try await wait { element("workflow-choose-agent-\(instances[0].id)", in: window) != nil }
            if let contentView = window.sheets.first?.contentView {
                try capture(contentView, name: "agent-picker")
            }
            try await click("workflow-agent-picker-cancel", in: window)
            try await wait { window.sheets.isEmpty }
            for _ in 0..<2 {
                try await click("workflow-add-agent-step", in: window)
                try await click("workflow-choose-agent-\(instances[0].id)", in: window)
                try await wait { window.sheets.isEmpty && inputs(in: hosting).count == 1 }
            }
            try capture(hosting, name: "direct-agent-steps")
            try await click("workflow-editor-save", in: window)
            try await wait { saved != nil }
            let value = try #require(saved)
            #expect(value.nodes.count == (empty ? 2 : 3))
            #expect(value.agents.map(\.id) == [instances[0].id])
            #expect(value.nodes.suffix(2).allSatisfy { $0.agentInstanceID == instances[0].id })
            #expect(value.edges == zip(value.nodes, value.nodes.dropFirst()).map { .init(source: $0.0.id, target: $0.1.id) })
            #expect(value.entryNodeID == value.nodes.first?.id)
            #expect(value.nodes.first?.initialTask == .textAndAttachments)
            #expect(value.nodes.last?.initialTask == .omit)
        }
    }
#endif
