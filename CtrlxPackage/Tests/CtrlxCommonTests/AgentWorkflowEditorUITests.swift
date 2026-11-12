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

        private func click(_ id: String, in window: NSWindow, attributeName: String = "accessibilityIdentifier") async throws {
            try await wait("Missing control: \(id)") { element(id, in: window, attributeName: attributeName) != nil }
            let object = try #require(element(id, in: window, attributeName: attributeName))
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

        @Test
        func copiedStepsRequireNewAgentsAndKeepTheirInstructions() async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let hostID = UUID()
            let instances = ["New Developer", "New Reviewer"].enumerated().map { index, name in
                AgentWorkflowInstance(hostID: hostID, pluginID: "codex", processID: Int32(index + 42), processRuntimeID: "runtime-\(index)", workspacePane: .init(serverID: "private", sessionID: UUID(), windowID: UUID(), paneID: UUID()), paneID: "%\(index)", conversationID: "conversation-\(index)", displayName: name, workingDirectory: "/fixture", capabilities: .init(maximumInputBytes: 100_000), readiness: .ready)
            }
            var original = AgentWorkflowDefinition(name: "Review loop", hostID: hostID, nodes: [], edges: [], entryNodeID: UUID(), initialInput: .init(text: "Old task", attachmentIDs: [UUID()]))
            AgentWorkflowReviewTemplate.apply(to: &original, developerID: UUID(), reviewerID: UUID())
            original.nodes[1].input.attachmentIDs = [UUID()]
            let copy = original.duplicated()
            var saved: AgentWorkflowDefinition?
            let endpoint = AgentWorkflowEndpoint(id: "copy-editor-fixture", name: "Host", connected: { true }, supported: { true }) { request in
                var response = AgentWorkflowResponse(hostID: hostID)
                switch request.operation {
                case .catalog: response.instances = .init(items: instances, nextOffset: nil)
                case let .save(value, revision):
                    #expect(revision == nil)
                    try AgentWorkflowWire.validate(value)
                    saved = value
                    response.definition = value
                default: Issue.record("A copied draft must not load old images or start a workflow")
                }
                return response
            }
            let hosting = NSHostingView(rootView: AgentWorkflowEditor(endpoint: endpoint, definition: copy, isNew: true, createAgent: nil))
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 700, height: 1_100), styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            try await click("workflow-editor-save", in: window)
            #expect(saved == nil)
            for index in [0, 1, 2, 4] {
                let node = copy.nodes[index]
                try await click("workflow-step-toggle-\(node.id)", in: window)
                try await click("workflow-step-agent-\(node.id)", in: window)
                // Each unbound step can select a new participant, or reuse one already chosen.
                try await wait { element("workflow-choose-agent-\(instances[1].id)", in: window) != nil }
                let instance = instances[index == 1 ? 1 : 0]
                try await click("workflow-choose-agent-\(instance.id)", in: window)
                try await wait { window.sheets.isEmpty }
                #expect(inputs(in: hosting).first?.string == node.input.text)
                if index != 4 {
                    try await click("workflow-editor-save", in: window)
                    #expect(saved == nil)
                }
            }
            try await click("workflow-editor-save", in: window)
            try await wait { saved != nil }
            let value = try #require(saved)
            #expect(value.id == copy.id && value.id != original.id)
            #expect(value.agentInstanceIDs == Set(instances.map(\.id)))
            #expect(value.nodes[0].agentInstanceID == value.nodes[2].agentInstanceID && value.nodes[0].agentInstanceID == value.nodes[4].agentInstanceID)
            #expect(value.initialInput == .init() && value.attachmentIDs.isEmpty)
            #expect(value.nodes.map(\.input.text) == original.nodes.map(\.input.text))
            #expect(value.edges == original.edges && value.loop == original.loop)
            #expect(value.nodes.map(\.completion) == original.nodes.map(\.completion))
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
                for id in ["workflow-step-toggle-\(second.id)", "workflow-step-toggle-\(first.id)-remove", "workflow-step-toggle-\(second.id)-remove", "workflow-add-agent-step", "workflow-add-content-step"] {
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
            #expect(element("Original task", in: window, attributeName: "accessibilityLabel") == nil)
            #expect(element("Run as", in: window, attributeName: "accessibilityLabel") == nil)
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
            #expect(element("Role name", in: window, attributeName: "accessibilityLabel") == nil)
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

        @Test(arguments: [false, true], [false, true])
        func addingAgentStepsChoosesInstancesDirectlyAndReusesParticipants(empty: Bool, longName: Bool) async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let hostID = UUID()
            let instances = [longName ? String(repeating: "中", count: 86) : "Developer", "Reviewer"].enumerated().map { index, name in
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
            #expect(element("workflow-choose-agent-\(instances[1].id)", in: window) != nil)
            if let contentView = window.sheets.first?.contentView {
                try capture(contentView, name: "agent-picker")
            }
            try await click("workflow-agent-picker-cancel", in: window)
            try await wait { window.sheets.isEmpty }
            for index in 0..<2 {
                try await click("workflow-add-agent-step", in: window)
                try await wait { element("workflow-choose-agent-\(instances[0].id)", in: window) != nil }
                if index > 0 {
                    #expect(element("workflow-choose-agent-\(instances[1].id)", in: window) == nil)
                }
                try await click("workflow-choose-agent-\(instances[0].id)", in: window)
                try await wait { window.sheets.isEmpty && inputs(in: hosting).count == 1 }
            }
            try capture(hosting, name: "direct-agent-steps")
            try await click("workflow-editor-save", in: window)
            try await wait { saved != nil }
            let value = try #require(saved)
            #expect(value.nodes.count == (empty ? 2 : 3))
            #expect(value.agents.map(\.id) == [instances[0].id])
            #expect(value.agents.allSatisfy { $0.name.utf8.count <= 256 })
            #expect(value.nodes.allSatisfy { $0.name.utf8.count <= 256 })
            #expect(value.nodes.suffix(2).allSatisfy { $0.agentInstanceID == instances[0].id })
            #expect(value.edges == zip(value.nodes, value.nodes.dropFirst()).map { .init(source: $0.0.id, target: $0.1.id) })
            #expect(value.entryNodeID == value.nodes.first?.id)
            #expect(value.nodes.first?.initialTask == .textAndAttachments)
            #expect(value.nodes.last?.initialTask == .omit)
        }

        @Test(arguments: [false, true])
        func configuredAgentPickerNeverOffersUnrelatedInstances(unavailable: Bool) async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let hostID = UUID()
            let instances = ["Configured", "Unrelated"].enumerated().map { index, name in
                AgentWorkflowInstance(hostID: hostID, pluginID: "codex", processID: Int32(index + 42), processRuntimeID: "runtime-\(index)", workspacePane: .init(serverID: "1:1", sessionID: UUID(), windowID: UUID(), paneID: UUID()), paneID: "%\(index)", conversationID: "conversation-\(index)", displayName: name, workingDirectory: "/fixture", capabilities: .init(maximumInputBytes: 100_000), readiness: .ready)
            }
            let picker = AgentWorkflowAgentPicker(instances: unavailable ? [instances[1]] : instances, participants: [.init(agentInstanceID: instances[0].id, name: "Configured role")], refreshing: false, error: nil, refresh: { }) { _ in
                Issue.record("Inspecting the picker must not select an Agent")
            }
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 560, height: 500), styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: picker)
            window.orderBack(nil)
            defer { window.close() }
            if unavailable {
                try await wait { element("workflow-agent-picker-empty", in: window) != nil }
            } else {
                try await wait { element("workflow-choose-agent-\(instances[0].id)", in: window) != nil }
                let button = try #require(element("workflow-choose-agent-\(instances[0].id)", in: window))
                #expect((attribute("accessibilityLabel", from: button) as? String)?.contains("Configured") == true)
                #expect((attribute("accessibilityLabel", from: button) as? String)?.contains("Configured role") == false)
            }
            #expect(element("workflow-choose-agent-\(instances[1].id)", in: window) == nil)
        }

        @Test(arguments: ["first", "last", "only"])
        func deleteCollapsedStepRepairsEntryAndLoop(position: String) async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let nodes = (position == "only" ? ["Only"] : ["First", "Second", "Last"]).map { AgentWorkflowNode(name: $0, content: .init(text: $0), initialTask: .omit) }
            let definition = try AgentWorkflowDefinition(
                name: "Remove a step",
                hostID: UUID(),
                nodes: nodes,
                edges: zip(nodes, nodes.dropFirst()).map { .init(source: $0.0.id, target: $0.1.id) },
                entryNodeID: nodes[0].id,
                loop: .init(finalNodeID: #require(nodes.last?.id), maximumRounds: 3, entryNodeID: nodes[0].id)
            )
            var saved: AgentWorkflowDefinition?
            let endpoint = AgentWorkflowEndpoint(id: "fixture", name: "Host", connected: { true }, supported: { true }) { request in
                var response = AgentWorkflowResponse(hostID: definition.hostID)
                switch request.operation {
                case .catalog: response.instances = .init(items: [], nextOffset: nil)
                case .attachments: response.attachments = []
                case let .save(value, _):
                    try AgentWorkflowWire.validate(value)
                    saved = value
                    response.definition = value
                default: Issue.record("Unexpected delete-step request")
                }
                return response
            }
            let host = NSHostingView(rootView: AgentWorkflowEditor(endpoint: endpoint, definition: definition, isNew: false, createAgent: nil))
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 700, height: 900), styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer { window.close() }
            let removed = try #require(position == "last" ? nodes.last : nodes.first)
            try await wait { element("workflow-step-toggle-\(removed.id)-remove", in: window) != nil }
            #expect(inputs(in: host).isEmpty)
            try capture(host, name: "step-delete-overview")
            try await click("workflow-step-toggle-\(removed.id)-remove", in: window)
            try await wait { element("workflow-step-toggle-\(removed.id)", in: window) == nil }
            if position == "only" {
                try await click("workflow-add-content-step", in: window)
                try await wait { inputs(in: host).count == 1 }
            }
            try await click("workflow-editor-save", in: window)
            try await wait { saved != nil }
            let value = try #require(saved)
            if position == "only" {
                #expect(value.nodes.count == 1 && value.nodes.first?.kind == .content)
                #expect(value.nodes.first?.id != removed.id)
                #expect(value.edges.isEmpty && value.loop == nil)
                #expect(value.entryNodeID == value.nodes.first?.id)
            } else {
                #expect(value.nodes == nodes.filter { $0.id != removed.id })
                #expect(value.edges == definition.edges.filter { $0.source != removed.id && $0.target != removed.id })
                #expect(value.entryNodeID == value.nodes.first?.id)
                #expect(value.loop?.entryNodeID == value.nodes.first?.id)
                #expect(value.loop?.finalNodeID == value.nodes.last?.id)
                #expect(value.loop?.maximumRounds == 3)
            }
        }

        @Test(arguments: [false, true])
        func newAgentSheetUsesToolbarCloseAndPreventsDismissalDuringLaunch(success: Bool) async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let definition = AgentWorkflowDefinition(name: "Launch Agent", hostID: UUID(), nodes: [], edges: [], entryNodeID: UUID())
            let instance = AgentWorkflowInstance(hostID: definition.hostID, pluginID: "codex", processID: 42, processRuntimeID: "created-runtime", workspacePane: .init(serverID: "fixture-server", sessionID: UUID(), windowID: UUID(), paneID: UUID()), paneID: "%42", conversationID: "created-conversation", displayName: "Created Agent", workingDirectory: "/fixture", capabilities: .init(maximumInputBytes: 100_000), readiness: .ready)
            var completed = false
            var launchCount = 0
            var saved: AgentWorkflowDefinition?
            let endpoint = AgentWorkflowEndpoint(id: "fixture", name: "Host", connected: { true }, supported: { true }) { request in
                var response = AgentWorkflowResponse(hostID: definition.hostID)
                switch request.operation {
                case .catalog: response.instances = .init(items: completed ? [instance] : [], nextOffset: nil)
                case .attachments: response.attachments = []
                case let .save(value, _):
                    saved = value
                    response.definition = value
                default: Issue.record("Unexpected new-Agent request")
                }
                return response
            }
            var launched = false
            var finish = false
            let creation = AgentWorkflowAgentCreation(hostID: definition.hostID, sessions: [], agents: [.init(id: "codex", name: "Codex"), .init(id: "claude-code", name: "Claude Code")], directorySource: .init(id: "fixture") { _ in
                Issue.record("Opening the launch sheet must not browse directories")
                throw CancellationError()
            }) { _, _ in
                launched = true
                launchCount += 1
                while !finish {
                    try await Task.sleep(for: .milliseconds(10))
                }
                if success {
                    completed = true
                    return .init(paneID: instance.paneID, scope: .init(hostID: definition.hostID, serverID: instance.workspacePane.serverID), pluginID: instance.pluginID)
                }
                throw AgentWorkflowError("Fixture launch failed")
            }
            let host = NSHostingView(rootView: AgentWorkflowEditor(endpoint: endpoint, definition: definition, isNew: true, createAgent: { _ in creation }))
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 700, height: 900), styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer { finish = true
                window.close()
            }
            try await click("workflow-new-agent-tab", in: window)
            try await wait("New Agent must expose its toolbar close button") { element("workflow-new-agent-close", in: window) != nil }
            try await wait("The launch sheet must show two Agent cards at its initial height") { window.sheets.first?.frame.height ?? 0 >= 600 }
            try await Task.sleep(for: .milliseconds(150))
            let sheet = try #require(window.sheets.first)
            let closeButton = try #require(element("workflow-new-agent-close", in: window))
            let closeBounds = try frame(closeButton)
            #expect(closeBounds.midX > sheet.frame.midX)
            #expect(sheet.frame.maxY - closeBounds.maxY < 100)
            for title in ["Start Codex", "Start Claude Code"] {
                let button = try #require(element(title, in: sheet, attributeName: "accessibilityLabel"))
                let bounds = try frame(button)
                #expect(closeBounds.minY > bounds.maxY)
                #expect(closeBounds.maxY - bounds.minY < sheet.frame.height)
            }
            if let content = window.sheets.first?.contentView {
                try capture(content, name: "workflow-new-agent")
            }
            try await click("workflow-new-agent-close", in: window)
            try await wait("The toolbar X must dismiss the launch sheet") { window.sheets.isEmpty }
            try await Task.sleep(for: .milliseconds(300))
            try await click("workflow-new-agent-tab", in: window)
            try await wait("Reopening must load the Agent form") { element("workflow-new-agent-close", in: window) != nil }
            try await click("Start Codex", in: window, attributeName: "accessibilityLabel")
            try await wait("The Start button must reach the launch operation") { launched }
            let close = try #require(element("workflow-new-agent-close", in: window))
            let selector = NSSelectorFromString("isAccessibilityEnabled")
            let method = try #require(close.method(for: selector))
            let enabled = unsafeBitCast(method, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            #expect(!enabled(close, selector))
            finish = true
            if success {
                try await wait("Successful creation must dismiss the outer sheet") { window.sheets.isEmpty }
                #expect(launchCount == 1)
                try await click("workflow-add-agent-step", in: window)
                try await click("workflow-choose-agent-\(instance.id)", in: window)
                try await wait { window.sheets.isEmpty }
                try await click("workflow-editor-save", in: window)
                try await wait { saved != nil }
                let value = try #require(saved)
                #expect(value.agents.map(\.id) == [instance.id])
                #expect(value.nodes.map(\.agentInstanceID) == [instance.id])
                #expect(value.creationSession == AgentWorkflowSessionReference(instance.workspacePane))
                #expect(launchCount == 1)
            } else {
                try await wait("Close must become enabled after the launch fails") {
                    guard let current = element("workflow-new-agent-close", in: window) else { return false }
                    return enabled(current, selector)
                }
                try await click("workflow-new-agent-close", in: window)
                try await wait("The toolbar X must dismiss after a failed launch") { window.sheets.isEmpty }
                #expect(launchCount == 1)
            }
        }

        @Test(arguments: [false, true])
        func executionExposesRepeatEntryAndPreservesLaterStarts(repeating: Bool) async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let nodes = ["First", "Second", "Last"].map { AgentWorkflowNode(name: $0, content: .init(text: $0), initialTask: .omit) }
            let definition = AgentWorkflowDefinition(name: "Repeat entry", hostID: UUID(), nodes: nodes, edges: zip(nodes, nodes.dropFirst()).map { .init(source: $0.0.id, target: $0.1.id) }, entryNodeID: nodes[0].id, loop: repeating ? .init(finalNodeID: nodes[2].id, entryNodeID: nodes[1].id) : nil)
            var saved: AgentWorkflowDefinition?
            let endpoint = AgentWorkflowEndpoint(id: "fixture", name: "Host", connected: { true }, supported: { true }) { request in
                var response = AgentWorkflowResponse(hostID: definition.hostID)
                switch request.operation {
                case .catalog: response.instances = .init(items: [], nextOffset: nil)
                case .attachments: response.attachments = []
                case let .save(value, _):
                    try AgentWorkflowWire.validate(value)
                    saved = value
                    response.definition = value
                default: Issue.record("Unexpected execution editor request")
                }
                return response
            }
            let host = NSHostingView(rootView: AgentWorkflowEditor(endpoint: endpoint, definition: definition, isNew: false, createAgent: nil))
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 700, height: 1_100), styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer { window.close() }
            try await click("workflow-execution-toggle", in: window)
            try await wait { element("workflow-repeat-from", in: window) != nil }
            let picker = try #require(element("workflow-repeat-from", in: window))
            let selector = NSSelectorFromString("isAccessibilityEnabled")
            let method = try #require(picker.method(for: selector))
            let enabled = unsafeBitCast(method, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            #expect(enabled(picker, selector) == repeating)
            if !repeating {
                try await click("workflow-repeat-rounds", in: window)
                try await wait {
                    guard let current = element("workflow-repeat-from", in: window) else { return false }
                    return enabled(current, selector)
                }
            }
            let current = try #require(element("workflow-repeat-from", in: window))
            #expect(attribute("accessibilityValue", from: current) as? String == (repeating ? "2. Second" : "1. First"))
            try await click("workflow-editor-save", in: window)
            try await wait { saved != nil }
            let value = try #require(saved)
            #expect(value.entryNodeID == nodes[0].id)
            #expect(value.entryNodeID(round: 2) == nodes[repeating ? 1 : 0].id)
            #expect(value.loop?.finalNodeID == nodes[2].id)
            #expect(value.loop?.maximumRounds == 5)
        }

        private func frame(_ object: NSObject) throws -> CGRect {
            let selector = NSSelectorFromString("accessibilityFrame")
            let method = try #require(object.method(for: selector))
            return unsafeBitCast(method, to: (@convention(c) (AnyObject, Selector) -> CGRect).self)(object, selector)
        }
    }
#endif
