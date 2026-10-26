#if os(macOS)
    import AppKit
    import CtrlxNetworking
    import SwiftUI
    import Testing
    @testable import CtrlxCommon

    @MainActor
    struct AgentWorkflowConfigurationTests {
        private func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() {
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(condition(), "Timed out waiting for attachment metadata")
        }

        @Test(arguments: [false, true])
        func savedConfigurationLoadsInitialAndPresetAttachmentMetadata(content: Bool) async throws {
            _ = NSApplication.shared
            let hostID = UUID()
            let initial = AgentWorkflowAttachment(id: UUID(), name: "initial-diagram.png", mediaType: "image/png", byteCount: 900, sha256: String(repeating: "a", count: 64))
            let preset = AgentWorkflowAttachment(id: UUID(), name: "review-guide.md", mediaType: "text/markdown", byteCount: 300, sha256: String(repeating: "b", count: 64))
            let node = content
                ? AgentWorkflowNode(name: "Review instructions", content: .init(text: "$review-changes\nReview correctness and tests.", attachmentIDs: [preset.id]))
                : AgentWorkflowNode(name: "Developer", agentInstanceID: UUID(), input: .init(text: "Review", attachmentIDs: [preset.id]))
            let definition = AgentWorkflowDefinition(name: "Saved configuration", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id, initialInput: .init(text: "Initial task", attachmentIDs: [initial.id]))
            var requestedIDs: [UUID] = []
            let endpoint = AgentWorkflowEndpoint(id: "fixture", name: "Test Host", connected: { true }, supported: { true }) { request in
                #expect(request.expectedHostID == hostID)
                var response = AgentWorkflowResponse(hostID: hostID)
                switch request.operation {
                case .definition(definition.id): response.definition = definition
                case .catalog: response.instances = .init(items: [], nextOffset: nil)
                case let .attachments(ids):
                    requestedIDs = ids
                    response.attachments = ids.compactMap { id in [initial, preset].first { $0.id == id } }
                default: Issue.record("Unexpected configuration request")
                }
                return response
            }
            let hosting = NSHostingView(rootView: NavigationStack {
                AgentWorkflowConfigurationView(endpoint: endpoint, hostID: hostID, definitionID: definition.id, openAgent: { _ in }, createAgent: nil)
            })
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 700, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            try await wait { Set(requestedIDs) == [initial.id, preset.id] }
            if content, let directory = ProcessInfo.processInfo.environment["CTRLX_WORKFLOW_UI_EVIDENCE"] {
                try await capture(hosting, directory: directory, name: "content-configuration")
                let editor = NSHostingView(rootView: AgentWorkflowEditor(endpoint: endpoint, definition: definition, isNew: false, createAgent: nil))
                window.contentView = editor
                try await capture(editor, directory: directory, name: "content-editor")
            }
        }

        @Test(arguments: [false, true])
        func workflowRoutesReloadAfterRecreatingThePage(running: Bool) async throws {
            _ = NSApplication.shared
            let hostID = UUID()
            let instance = AgentWorkflowInstance(
                hostID: hostID, pluginID: "codex", processID: 123, processRuntimeID: "123:start",
                workspacePane: .init(serverID: "tmux", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
                paneID: "%1", conversationID: "native", displayName: "work · Developer", workingDirectory: "/work",
                capabilities: .init(maximumInputBytes: 100_000), readiness: .ready
            )
            let node = AgentWorkflowNode(name: "Developer", agentInstanceID: instance.id)
            let definition = AgentWorkflowDefinition(name: "Review", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id)
            let run = AgentWorkflowRun(definition: definition, instances: [instance], createdAt: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600))
            let navigation = AgentWorkflowNavigation()
            let destination: AgentWorkflowNavigation.Destination = running
                ? .run(route: "fixture", hostID: hostID, id: run.id)
                : .configuration(route: "fixture", hostID: hostID, id: definition.id)
            navigation.path = [.host("fixture"), destination]
            var reads: [ManageAgentWorkflows.Operation] = []
            let endpoint = AgentWorkflowEndpoint(id: "fixture", name: "Test Host", connected: { true }, supported: { true }) { request in
                reads.append(request.operation)
                var response = AgentWorkflowResponse(hostID: hostID)
                switch request.operation {
                case .definitions: response.definitions = .init(items: [.init(definition)], nextOffset: nil)
                case .runs: response.runs = .init(items: [.init(run)], nextOffset: nil)
                case .definition: response.definition = definition
                case .catalog: response.instances = .init(items: [instance], nextOffset: nil)
                case .attachments: response.attachments = []
                case .run: response.run = .init(run, currentInstances: [instance])
                case .invocations: response.invocations = .init(items: [], nextOffset: nil)
                default: Issue.record("Unexpected workflow UI request")
                }
                return response
            }
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 700, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            for iteration in 0..<2 {
                reads.removeAll()
                let hosting = NSHostingView(rootView: AgentWorkflowsView(endpoints: { [endpoint] }, openAgent: { _, _ in }, navigation: navigation)
                    .environment(\.scenePhase, .active))
                window.contentView = hosting
                window.orderBack(nil)
                try await wait {
                    running ? reads.contains(.run(run.id)) && reads.contains(.invocations(runID: run.id, offset: 0))
                        : reads.contains(.definition(definition.id)) && reads.contains(.catalog(offset: 0))
                }
                #expect(navigation.path == [.host("fixture"), destination])
                if iteration == 1, let directory = ProcessInfo.processInfo.environment["CTRLX_WORKFLOW_UI_EVIDENCE"] {
                    try await capture(hosting, directory: directory, name: running ? "restored-run-navigation" : "restored-configuration-navigation")
                }
                window.contentView = nil
            }
        }

        private func capture(_ view: NSView, directory: String, name: String) async throws {
            view.frame = CGRect(x: 0, y: 0, width: 700, height: 1_100)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            view.layoutSubtreeIfNeeded()
            view.window?.displayIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
#endif
