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
