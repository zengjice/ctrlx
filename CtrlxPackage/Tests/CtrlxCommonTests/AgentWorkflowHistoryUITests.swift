#if os(macOS)
    import AppKit
    import CtrlxNetworking
    import SwiftUI
    import Testing
    @testable import CtrlxCommon

    @MainActor
    @Suite(.serialized)
    struct AgentWorkflowHistoryUITests {
        private func element(_ identifier: String, in root: Any, attributeName: String = "accessibilityIdentifier") -> NSObject? {
            guard let node = root as? NSObject else { return nil }
            if attribute(attributeName, from: node) as? String == identifier {
                return node
            }
            for child in attribute("accessibilityChildren", from: node) as? [Any] ?? [] {
                if let match = element(identifier, in: child, attributeName: attributeName) {
                    return match
                }
            }
            if let view = node as? NSView {
                for child in view.subviews {
                    if let match = element(identifier, in: child, attributeName: attributeName) {
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

        private func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() {
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw UIError.missing("Workflow state")
        }

        @Test(arguments: [false, true])
        func configurationDuplicationOpensAFreshDraftBeforeSaving(failsFirstRead: Bool) async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let hostID = UUID()
            let node = AgentWorkflowNode(name: "Brief", content: .init(text: "Saved preset", attachmentIDs: [UUID()]))
            let original = AgentWorkflowDefinition(revision: 4, name: "Original", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id, initialInput: .init(text: "Old task", attachmentIDs: [UUID()]))
            var definitions = [original], saves = 0, reads = 0
            let endpoint = AgentWorkflowEndpoint(id: "duplicate-fixture", name: "Private Host", connected: { true }, supported: { true }) { request in
                var response = AgentWorkflowResponse(hostID: hostID)
                switch request.operation {
                case .definitions: response.definitions = .init(items: definitions.map(AgentWorkflowDefinitionSummary.init), nextOffset: nil)
                case .runs: response.runs = .init(items: [], nextOffset: nil)
                case let .definition(id):
                    #expect(id == original.id && request.expectedHostID == hostID)
                    reads += 1
                    if failsFirstRead && reads == 1 {
                        throw AgentWorkflowError("Fixture read failed")
                    }
                    response.definition = original
                case .catalog: response.instances = .init(items: [], nextOffset: nil)
                case let .save(copy, revision):
                    saves += 1
                    #expect(revision == nil && request.expectedHostID == hostID)
                    #expect(copy.id != original.id && copy.revision == 1)
                    #expect(copy.name == "Copy of Original" && copy.nodes.first?.input.text == "Saved preset")
                    #expect(copy.initialInput == .init() && copy.attachmentIDs.isEmpty && copy.agents.isEmpty)
                    definitions.append(copy)
                    response.definition = copy
                default: Issue.record("Duplicating must only read and save configurations")
                }
                return response
            }
            let navigation = AgentWorkflowNavigation()
            navigation.path = [.host(endpoint.id)]
            let hosting = NSHostingView(rootView: AgentWorkflowsView(endpoints: { [endpoint] }, openAgent: { _, _ in }, navigation: navigation)
                .environment(\.scenePhase, .active))
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            let entryID = "workflow-duplicate-\(original.id)"
            try await waitUntil { element(entryID, in: window) != nil }
            _ = try press(#require(element(entryID, in: window)))
            if failsFirstRead {
                try await waitUntil { reads == 1 && element("Fixture read failed", in: window, attributeName: "accessibilityValue") != nil }
                #expect(definitions == [original])
                _ = try press(#require(element(entryID, in: window)))
            }
            func saveButton() -> NSObject? {
                window.sheets.lazy.compactMap { element("workflow-editor-save", in: $0) }.first
            }
            try await waitUntil { saveButton() != nil }
            let save = try #require(saveButton())
            #expect(saves == 0 && definitions == [original])
            _ = press(save)
            try await waitUntil { definitions.count == 2 }
            let copy = try #require(definitions.last)
            try await waitUntil { element("workflow-duplicate-\(copy.id)", in: window) != nil }
            #expect(definitions.first == original)
            #expect(saves == 1 && reads == (failsFirstRead ? 2 : 1))
            #expect(navigation.path == [.host(endpoint.id)])
        }

        @Test(arguments: [AgentWorkflowRunStatus.running, .paused, .finishing])
        func toolbarStopRequiresConfirmationAndEndsTheSelectedRun(status: AgentWorkflowRunStatus) async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let hostID = UUID()
            let node = AgentWorkflowNode(name: "Brief", content: .init(text: "Task"))
            let definition = AgentWorkflowDefinition(name: "Stop fixture", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id)
            var run = AgentWorkflowRun(definition: definition, instances: [], createdAt: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600))
            run.status = status
            run.revision = 7
            var endings = 0
            let endpoint = AgentWorkflowEndpoint(id: "stop-fixture", name: "Private Host", connected: { true }, supported: { true }) { request in
                var response = AgentWorkflowResponse(hostID: hostID)
                switch request.operation {
                case .definitions: response.definitions = .init(items: [.init(definition)], nextOffset: nil)
                case .runs: response.runs = .init(items: [.init(run)], nextOffset: nil)
                case .run: response.run = .init(run, currentInstances: [])
                case .invocations: response.invocations = .init(items: [], nextOffset: nil)
                case let .end(id, revision):
                    #expect(request.expectedHostID == hostID && id == run.id && revision == 7)
                    endings += 1
                    run.status = .ended
                    run.revision += 1
                    response.run = .init(run, currentInstances: [])
                default: Issue.record("Unexpected operation while stopping")
                }
                return response
            }
            let navigation = AgentWorkflowNavigation()
            navigation.path = [.host(endpoint.id), .run(route: endpoint.id, hostID: hostID, id: run.id)]
            let path = navigation.path
            var closes = 0
            let hosting = NSHostingView(rootView: AgentWorkflowsView(endpoints: { [endpoint] }, openAgent: { _, _ in }, close: { closes += 1 }, navigation: navigation)
                .environment(\.scenePhase, .active))
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            try await waitUntil { element("workflow-run-stop", in: window) != nil }
            _ = try press(#require(element("workflow-run-stop", in: window)))
            let confirmation = try await waitForElement("workflow-confirm-end")
            #expect(endings == 0 && run.status == status)
            _ = press(confirmation)
            try await waitUntil { endings == 1 && element("workflow-run-stop", in: window) == nil }
            #expect(run.status == .ended && run.definition == definition)
            #expect(navigation.path == path && closes == 0)
            #expect(element("workflow-run-control", in: window) == nil)
            #expect(element("workflow-close", in: window) != nil)
        }

        @Test
        func terminalButtonPausesAndContinuesWithoutControlOwnership() async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let hostID = UUID()
            let pane = WorkspacePaneIdentity(serverID: "private", sessionID: UUID(), windowID: UUID(), paneID: UUID())
            let node = AgentWorkflowNode(name: "Developer", agentInstanceID: UUID())
            let definition = AgentWorkflowDefinition(name: "Control fixture", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id)
            var run = AgentWorkflowRun(definition: definition, instances: [], createdAt: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600))
            var mutations: [ManageAgentWorkflows.Operation] = []
            let endpoint = AgentWorkflowEndpoint(id: "control-fixture", name: "Host", connected: { true }, supported: { true }) { request in
                switch request.operation {
                case let .terminal(identity): #expect(identity == pane)
                case let .pause(id, revision):
                    #expect(id == run.id && revision == run.revision)
                    mutations.append(request.operation)
                    run.status = .paused
                    run.revision += 1
                case let .resume(id, revision, _):
                    #expect(id == run.id && revision == run.revision)
                    mutations.append(request.operation)
                    run.status = .running
                    run.revision += 1
                default: Issue.record("Unexpected terminal workflow control request")
                }
                var response = AgentWorkflowResponse(hostID: hostID)
                response.run = .init(run, currentInstances: [])
                return response
            }
            let hosting = NSHostingView(rootView: AgentWorkflowControlButton(endpoint: endpoint, pane: pane).padding().environment(\.scenePhase, .active))
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 180, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            for _ in 0..<100 {
                if element("workflow-terminal-control", in: window) != nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            for (title, expected) in [("Pause workflow", AgentWorkflowRunStatus.paused), ("Continue workflow", .running)] {
                let button = try #require(element("workflow-terminal-control", in: window))
                #expect(attribute("accessibilityLabel", from: button) as? String == title)
                #expect(attribute("accessibilityValue", from: button) as? String == run.status.title)
                #expect(press(button))
                for _ in 0..<100 {
                    if run.status == expected {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(run.status == expected)
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(mutations.count == 2)
        }

        @Test(arguments: [false, true])
        func quickStartEditsTheTaskAndUploadsNativeImagesWithoutSavingConfiguration(failFirstUpload: Bool) async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let hostID = UUID()
            let node = AgentWorkflowNode(name: "Developer", agentInstanceID: UUID())
            let saved = AgentWorkflowDefinition(name: "Reusable review", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id, initialInput: .init(text: "Saved default task"))
            let navigation = AgentWorkflowNavigation()
            navigation.path = [.host("quick-start-fixture")]
            var uploaded = 0, started: AgentWorkflowInput?, failedOnce = false
            let endpoint = AgentWorkflowEndpoint(id: "quick-start-fixture", name: "Host", connected: { true }, supported: { true }) { request in
                var response = AgentWorkflowResponse(hostID: hostID)
                switch request.operation {
                case .definition: response.definition = saved
                case let .uploadAttachment(.image(id, name, mediaType, bytes, hash)):
                    if failFirstUpload && !failedOnce {
                        failedOnce = true
                        throw AgentWorkflowError("Fixture temporary image upload failure.")
                    }
                    #expect(request.expectedHostID == hostID && mediaType == "image/png" && !bytes.isEmpty)
                    response.uploadedOffset = bytes.count
                    response.attachments = [.init(id: id, name: name, mediaType: mediaType, byteCount: Int64(bytes.count), sha256: hash)]
                    uploaded += 1
                case .uploadAttachment(.cancel),
                     .discardAttachments: break
                case let .start(_, revision, id, expires, input):
                    #expect(revision == saved.revision)
                    started = input
                    var definition = saved
                    definition.initialInput = try #require(input)
                    let run = AgentWorkflowRun(id: id, definition: definition, instances: [], createdAt: Date(), authorizationExpiresAt: expires)
                    response.run = .init(run, currentInstances: [])
                default: Issue.record("Quick start unexpectedly edited a saved configuration")
                }
                return response
            }
            let hosting = NSHostingView(rootView: AgentWorkflowStartView(endpoint: endpoint, hostID: hostID, definitionID: saved.id, navigation: navigation, openAgent: { _ in }))
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 640, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            func editor(_ view: NSView) -> AgentWorkflowTextInput.TextView? {
                (view as? AgentWorkflowTextInput.TextView) ?? view.subviews.lazy.compactMap { editor($0) }.first
            }
            for _ in 0..<100 where editor(hosting) == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            let input = try #require(editor(hosting))
            #expect(input.string == saved.initialInput.text)
            input.string = "This run only: implement the attached drawing"
            input.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: input))
            let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQaPjQAMIMMAYARzIIQdQEEEMAAAAASUVORK5CYII="))
            input.receive?([.image(.init(data: png, format: .png))])
            input.receive?([.image(.init(data: png, format: .png))])
            if failFirstUpload {
                for _ in 0..<100 where element("workflow-image-retry", in: window) == nil {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let retry = try #require(element("workflow-image-retry", in: window))
                // A new paste must not silently replace the two failed images.
                input.receive?([.image(.init(data: png, format: .png))])
                _ = press(retry)
            }
            for _ in 0..<100 where uploaded < 2 {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(uploaded == 2)
            try await Task.sleep(for: .milliseconds(100))
            if let directory = ProcessInfo.processInfo.environment["CTRLX_WORKFLOW_UI_EVIDENCE"] {
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("quick-start.png"))
            }
            let button = try #require(element("workflow-start-confirm", in: window))
            // AppKit toolbar proxies may return false after scheduling the action.
            // Verify the actual Host request and navigation below.
            _ = press(button)
            for _ in 0..<100 where started == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(started?.text == "This run only: implement the attached drawing")
            #expect(started?.attachmentIDs.count == 2)
            #expect(saved.initialInput.text == "Saved default task" && saved.initialInput.attachmentIDs.isEmpty)
            #expect(navigation.path.count == 2)
        }

        @Test(arguments: ["rejected-edit", "rejected-close", "rejected-not-ready", "timeout", "missing", "old-host"])
        func quickStartKeepsDraftsAndDistinguishesRefusalFromUnconfirmedStart(outcome: String) async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let hostID = UUID(), navigation = AgentWorkflowNavigation()
            navigation.path = [.host("start-refusal")]
            let node = AgentWorkflowNode(name: "Developer", agentInstanceID: UUID())
            let saved = AgentWorkflowDefinition(name: "New task", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id, initialInput: .init(text: "Draft with image"))
            var existing = saved
            existing.name = "Existing review"
            var occupied = AgentWorkflowRun(definition: existing, instances: [], createdAt: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600))
            occupied.status = .paused
            let rejection = outcome == "rejected-not-ready"
                ? AgentWorkflowStartRejection("global · dev: This Agent has not confirmed its workflow hook. Update its CtrlX plugin, then restart the Agent or submit a normal prompt before starting a workflow.")
                : AgentWorkflowStartRejection("These Agents already belong to an unfinished workflow.", conflicts: [.init(run: .init(occupied), agentNames: ["global · dev"])])
            let rejected = outcome.hasPrefix("rejected")
            var opened = false
            var attempts: [ManageAgentWorkflows.Operation] = [], uploaded: [UUID] = [], discarded: [UUID] = []
            let endpoint = AgentWorkflowEndpoint(id: "start-refusal", name: "Host", connected: { true }, supported: { true }) { request in
                var response = AgentWorkflowResponse(hostID: hostID)
                switch request.operation {
                case .definition: response.definition = saved
                case let .run(id):
                    #expect(id == occupied.id)
                    opened = true
                    response.run = .init(occupied, currentInstances: [])
                case .invocations: response.invocations = .init(items: [], nextOffset: nil)
                case let .uploadAttachment(.image(id, name, mediaType, bytes, hash)):
                    uploaded.append(id)
                    response.uploadedOffset = bytes.count
                    response.attachments = [.init(id: id, name: name, mediaType: mediaType, byteCount: Int64(bytes.count), sha256: hash)]
                case let .discardAttachments(ids): discarded += ids
                case .start:
                    attempts.append(request.operation)
                    if rejected {
                        response.startRejection = rejection
                    } else if outcome == "timeout" {
                        throw URLError(.timedOut)
                    } else if outcome == "old-host" {
                        throw AgentWorkflowError("An Agent is already reserved by another active workflow.")
                    }
                default: Issue.record("Unexpected start-refusal operation")
                }
                return response
            }
            let hosting = NSHostingView(rootView: AgentWorkflowStartView(endpoint: endpoint, hostID: hostID, definitionID: saved.id, navigation: navigation, openAgent: { _ in }).environment(\.scenePhase, .active))
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 640, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            func editor(_ view: NSView) -> AgentWorkflowTextInput.TextView? {
                (view as? AgentWorkflowTextInput.TextView) ?? view.subviews.lazy.compactMap { editor($0) }.first
            }
            func wait(_ condition: () -> Bool) async throws {
                for _ in 0..<100 {
                    if condition() {
                        return
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                throw UIError.missing("Start-refusal state")
            }
            try await wait { editor(hosting) != nil }
            var input = try #require(editor(hosting))
            let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQaPjQAMIMMAYARzIIQdQEEEMAAAAASUVORK5CYII="))
            input.receive?([.image(.init(data: png, format: .png))])
            try await wait { uploaded.count == 1 }
            try await Task.sleep(for: .milliseconds(100))
            _ = try press(#require(element("workflow-start-confirm", in: window)))
            try await wait { attempts.count == 1 }
            try await Task.sleep(for: .milliseconds(100))
            #expect(input.string == "Draft with image")
            #expect(input.isEditable == rejected)
            #expect(discarded.isEmpty)
            let confirm = try #require(element("workflow-start-confirm", in: window))
            #expect(attribute("accessibilityLabel", from: confirm) as? String == (rejected ? "Start" : "Retry"))
            #expect((element("workflow-start-unconfirmed", in: window) == nil) == rejected)
            #expect((element("workflow-start-rejection", in: window) != nil) == rejected)
            #expect((element("workflow-start-conflict-\(occupied.id)", in: window) != nil) == (rejected && !rejection.conflicts.isEmpty))
            #expect(navigation.path == [.host("start-refusal")])
            if rejected, let directory = ProcessInfo.processInfo.environment["CTRLX_WORKFLOW_UI_EVIDENCE"] {
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("start-refusal-\(outcome).png"))
            }
            if outcome == "rejected-edit" {
                _ = try press(#require(element("workflow-start-conflict-\(occupied.id)", in: window)))
                try await wait { opened }
                try await Task.sleep(for: .milliseconds(100))
                let back = try #require(element("Back", in: window, attributeName: "accessibilityLabel"))
                _ = press(back)
                try await wait { editor(hosting) != nil }
                input = try #require(editor(hosting))
                #expect(input.string == "Draft with image" && input.isEditable)
                #expect(discarded.isEmpty && navigation.path == [.host("start-refusal")])
            }
            if outcome != "rejected-close" {
                if rejected {
                    input.string = "Edited task with the same image"
                    input.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: input))
                    try await Task.sleep(for: .milliseconds(50))
                }
                _ = try press(#require(element("workflow-start-confirm", in: window)))
                try await wait { attempts.count == 2 }
                if rejected {
                    guard
                        case let .start(_, _, firstID, _, firstInput) = attempts[0],
                        case let .start(_, _, nextID, _, nextInput) = attempts[1] else {
                        Issue.record("Expected start operations")
                        return
                    }
                    #expect(firstID != nextID)
                    #expect(firstInput?.text == "Draft with image")
                    #expect(nextInput?.text == "Edited task with the same image")
                    #expect(firstInput?.attachmentIDs == uploaded && nextInput?.attachmentIDs == uploaded)
                } else {
                    #expect(attempts[0] == attempts[1])
                }
            }
            try await Task.sleep(for: .milliseconds(100))
            _ = try press(#require(element("workflow-start-close", in: window)))
            if rejected {
                try await wait { discarded == uploaded }
            } else {
                try await Task.sleep(for: .milliseconds(100))
                #expect(discarded.isEmpty)
            }
        }

        @Test(arguments: [false, true])
        func quickStartBatchesUnusedImagesAfterReplacingImports(startsRun: Bool) async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let hostID = UUID(), navigation = AgentWorkflowNavigation()
            navigation.path = [.host("cleanup-fixture")]
            let node = AgentWorkflowNode(name: "Developer", agentInstanceID: UUID())
            let saved = AgentWorkflowDefinition(name: "Cleanup fixture", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id, initialInput: .init(text: "Task"))
            var uploaded: [UUID] = [], remaining: Set<UUID> = [], owned: Set<UUID> = [], batches: [[UUID]] = []
            let endpoint = AgentWorkflowEndpoint(id: "cleanup-fixture", name: "Host", connected: { true }, supported: { true }) { request in
                #expect(request.expectedHostID == hostID)
                var response = AgentWorkflowResponse(hostID: hostID)
                switch request.operation {
                case .definition: response.definition = saved
                case let .uploadAttachment(.image(id, name, mediaType, bytes, hash)):
                    uploaded.append(id)
                    remaining.insert(id)
                    response.uploadedOffset = bytes.count
                    response.attachments = [.init(id: id, name: name, mediaType: mediaType, byteCount: Int64(bytes.count), sha256: hash)]
                case let .discardAttachments(ids):
                    batches.append(ids)
                    guard ids.count <= AgentWorkflowWire.maximumAttachments, owned.isDisjoint(with: ids) else {
                        throw AgentWorkflowError("The Host refuses oversized cleanup or removal of run-owned images.")
                    }
                    remaining.subtract(ids)
                case let .start(_, _, id, expires, input):
                    var definition = saved
                    definition.initialInput = try #require(input)
                    owned = Set(definition.initialInput.attachmentIDs)
                    response.run = .init(.init(id: id, definition: definition, instances: [], createdAt: Date(), authorizationExpiresAt: expires), currentInstances: [])
                default: Issue.record("Unexpected quick-start cleanup operation")
                }
                return response
            }
            let hosting = NSHostingView(rootView: AgentWorkflowStartView(endpoint: endpoint, hostID: hostID, definitionID: saved.id, navigation: navigation, openAgent: { _ in }))
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 640, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            func editor(_ view: NSView) -> AgentWorkflowTextInput.TextView? {
                (view as? AgentWorkflowTextInput.TextView) ?? view.subviews.lazy.compactMap { editor($0) }.first
            }
            let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQaPjQAMIMMAYARzIIQdQEEEMAAAAASUVORK5CYII="))
            func add(_ count: Int, total: Int) async throws {
                for _ in 0..<100 where editor(hosting) == nil {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let input = try #require(editor(hosting))
                input.receive?(Array(repeating: .image(.init(data: png, format: .png)), count: count))
                for _ in 0..<500 where uploaded.count < total {
                    try await Task.sleep(for: .milliseconds(20))
                }
                try #require(uploaded.count == total)
                try await Task.sleep(for: .milliseconds(100))
            }
            func remove(_ ids: [UUID]) async throws {
                for id in ids {
                    let identifier = "workflow-remove-attachment-\(id)"
                    let button = try #require(element(identifier, in: window))
                    _ = press(button)
                    for _ in 0..<100 {
                        guard element(identifier, in: window) != nil else { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    try #require(element(identifier, in: window) == nil)
                }
            }
            try await add(32, total: 32)
            if startsRun {
                try await remove(uploaded)
                try await add(32, total: 64)
            }
            try await remove([#require(uploaded.suffix(32).first)])
            try await add(1, total: startsRun ? 65 : 33)
            let action = try #require(element(startsRun ? "workflow-start-confirm" : "workflow-start-close", in: window))
            _ = press(action)
            for _ in 0..<100 where batches.count < 2 {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(batches.map(\.count) == [32, 1])
            #expect(Set(batches.flatMap { $0 }) == Set(uploaded).subtracting(owned))
            #expect(owned.count == (startsRun ? 32 : 0))
            #expect(remaining == owned)
            #expect(navigation.path.count == (startsRun ? 2 : 1))
        }

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
