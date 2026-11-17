import AppKit
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite(.serialized)
struct OrbiePanelRedesignTests {
    @Test
    func pendingEvidenceIsNotMistakenForAnApproval() async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbie()
        try await service.create(pluginID: "codex", providerID: nil)
        var instance = try #require(service.instance)
        var message = AgentMessage(instance: instance, text: "Work")
        for (delivery, expected) in [(AgentWorkflowInvocationStatus.awaitingAcceptance, OrbiePanelStatus.confirming), (.running, .working), (.uncertain, .uncertain(nil))] {
            message.status = delivery
            #expect(OrbiePanelStatus.conversation(instance: instance, messages: [message], availability: "Unfinished message") == expected)
        }
        instance.readiness = .awaitingHuman
        #expect(OrbiePanelStatus.conversation(instance: instance, messages: [message], availability: "Unfinished message") == .awaitingHuman)
        instance.readiness = .ready
        message.status = .running
        message.nativeEvent = .init(kind: .stopCandidate, nativeTurnID: "turn", transcriptPath: "/isolated/transcript", text: "candidate")
        #expect(OrbiePanelStatus.conversation(instance: instance, messages: [message], availability: "Unfinished message") == .verifying)
        message.status = .failed
        message.issue = "Native failure"
        #expect(OrbiePanelStatus.conversation(instance: instance, messages: [message], availability: nil) == .failed("Native failure"))
        try await f.cleanup()
    }

    @Test
    func stoppedRoleAndOldPendingMessageDoNotHideRecovery() async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbie()
        try await service.create(pluginID: "codex", providerID: nil)
        let original = try #require(service.instance)
        let message = AgentMessage(instance: original, text: "Old work")
        var replacement = original
        replacement.workspacePane = .init(serverID: "new", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        #expect(OrbiePanelStatus.conversation(instance: replacement, messages: [message], availability: nil) == .ready)
        #expect(OrbiePanelStatus.conversation(instance: nil, messages: [message], availability: "Resume saved conversation") == .unavailable("Resume saved conversation"))
        replacement.readiness = .draft
        #expect(OrbiePanelStatus.conversation(instance: replacement, messages: [], availability: "Draft") == .terminalDraft)
        try await f.cleanup()
    }

    @Test
    func composerReturnRespectsCompositionAndShift() throws {
        _ = NSApplication.shared
        let view = OrbiePanelComposer.TextView(frame: .init(x: 0, y: 0, width: 400, height: 100))
        var sent = 0
        view.send = { sent += 1 }
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        view.keyDown(with: enter)
        #expect(sent == 1)
        let shift = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        view.keyDown(with: shift)
        #expect(sent == 1 && view.string.contains("\n"))
        view.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        view.keyDown(with: enter)
        #expect(sent == 1)
    }

    @Test
    func nativeComposerClearsStaleUndoAfterSendingAndExternalReplacement() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let f = try await AgentInteractionTestSupport()
            let service = await f.orbie()
            try await service.create(pluginID: "codex", providerID: nil)
            let coordinator = AppCoordinator()
            coordinator.orbie = service
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 680, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: MacOrbiePanelView().environment(coordinator))
            window.contentView = hosting
            defer { window.close() }
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(200))
            let editor = try #require(textView(in: hosting))
            let undo = try #require(editor.undoManager)
            editor.insertText("Send this draft", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.breakUndoCoalescing()
            await service.refresh(inspect: false)
            try await Task.sleep(for: .milliseconds(100))
            #expect(service.draft == "Send this draft")
            #expect(undo.canUndo, "Refreshing an unchanged draft must preserve native undo")
            try press(#require(find("orbie-panel-send", in: hosting)))
            for _ in 0..<100 {
                if editor.string.isEmpty {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(editor.string.isEmpty && service.draft.isEmpty)
            #expect(f.writes.count == 1)
            try #require(!undo.canUndo && !undo.canRedo)
            undo.undo()
            #expect(editor.string.isEmpty)

            editor.insertText("Next draft", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.breakUndoCoalescing()
            try await Task.sleep(for: .milliseconds(100))
            try #require(undo.canUndo)
            undo.undo()
            #expect(editor.string.isEmpty && service.draft.isEmpty)
            undo.redo()
            #expect(editor.string == "Next draft" && service.draft == "Next draft")

            service.draft = "Externally replaced draft"
            try await Task.sleep(for: .milliseconds(100))
            #expect(editor.string == service.draft)
            #expect(!undo.canUndo && !undo.canRedo)
            window.contentView = nil
            coordinator.orbie = nil
            try await f.cleanup()
        }
    }

    private actor ScanGate {
        var started = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !released else { return }
            started = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    @Test(arguments: [false, true])
    func nativeOrbiterRefreshKeepsConversationUntilItCompletes(scanFails: Bool) async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let f = try await AgentInteractionTestSupport()
            let main = await f.orbie()
            try await main.create(pluginID: "codex", providerID: nil)
            let service = await f.orbiters()
            service.draft = .init(title: "Expert", goal: "Review the panel", directory: f.root.path)
            let id = try await service.create(pluginID: "codex", providerID: nil)
            try await service.send(id)
            let message = try #require(service.messages.first)
            try await f.complete(message, answer: String(repeating: "A verified reply that remains visible during refresh.\n", count: 20))
            await service.refresh()
            let previous = service.messages
            try #require(previous.count == 1 && previous[0].status == .succeeded)
            let coordinator = AppCoordinator()
            coordinator.orbie = main
            coordinator.orbiters = service
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 680, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: MacOrbiePanelView().environment(coordinator))
            window.contentView = hosting
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            window.orderBack(nil)
            try press(#require(find("orbie-panel-switcher", in: hosting)))
            try await Task.sleep(for: .milliseconds(200))
            try press(#require(NSApp.windows.compactMap { find("orbie-panel-agent-\(id)", in: $0) }.first))
            try await Task.sleep(for: .milliseconds(200))
            let height = window.frame.height
            try #require(height > 500)
            let gate = ScanGate()
            f.beforeScan = {
                await gate.wait()
                if scanFails {
                    throw AgentWorkflowInspectionUnavailable()
                }
            }
            let refreshing = Task { await service.refresh() }
            defer { Task { await gate.release()
                await refreshing.value
            } }
            for _ in 0..<100 {
                if await gate.started {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await gate.started && service.isBusy)
            for _ in 0..<3 {
                try await Task.sleep(for: .milliseconds(100))
                #expect(service.messages == previous)
                #expect(window.frame.height == height)
            }
            await gate.release()
            await refreshing.value
            f.beforeScan = nil
            try await Task.sleep(for: .milliseconds(100))
            #expect(service.messages == previous)
            #expect((service.issue != nil) == scanFails)
            if !scanFails {
                #expect(window.frame.height == height)
            }
            try await f.interaction.store.update(message.id) { $0.answer = "Updated reply" }
            await service.refresh(inspect: false)
            #expect(service.messages.first?.answer == "Updated reply")
            window.contentView = nil
            coordinator.orbie = nil
            coordinator.orbiters = nil
            try await f.cleanup()
        }
    }

    @Test
    func forkSelectedOrbiterUsesVerifiedSourceAndNeverSendsDraft() async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbiters()
        service.draft = .init(title: "Source", goal: "Original draft", directory: f.root.path)
        let id = try await service.create(pluginID: "codex", providerID: nil)
        let source = try #require(service.currentInstance(service.agents[0]))
        service.draft = .init(title: "Fork", goal: "Separate work", directory: f.root.path)
        let forkID = try await service.create(pluginID: "codex", providerID: nil, fork: true, requestedSource: source)
        let fork = try #require(service.agents.first { $0.id == forkID })
        #expect(fork.sourceAgentID == source.agentID)
        #expect(fork.creation?.forkSource == source)
        #expect(service.drafts[id] == "Original draft" && service.drafts[forkID] == "Separate work")
        #expect(f.writes.isEmpty)
        service.draft = .init(title: "Stale fork", goal: "Keep me", directory: f.root.path)
        f.observations[0].conversationID = UUID().uuidString
        await #expect(throws: AgentWorkflowError.self) {
            try await service.create(pluginID: "codex", providerID: nil, fork: true, requestedSource: source)
        }
        #expect(f.launches.count == 2 && service.draft.goal == "Keep me")
        try await f.cleanup()
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func nativePanelShowsActionablePendingReplyAndKeepsComposerVisible(scheme: ColorScheme) async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let f = try await AgentInteractionTestSupport()
            let original = await f.orbie()
            try await original.create(pluginID: "codex", providerID: nil)
            var message = try AgentMessage(instance: #require(original.instance), text: "Review the Orbie panel interaction and suggest the next step.")
            message.status = .uncertain
            try await f.interaction.store.insert(message)
            let store = OrbieStore(paths: f.paths, hostID: f.hostID)
            var saved = try await store.load()
            saved.messageIDs.append(message.id)
            try await store.save(saved)
            let service = OrbieService(store: store, interaction: f.interaction, launch: { _ in throw CancellationError() }, locateCreation: { _ in nil })
            await service.refresh(inspect: false)
            service.draft = "Keep my next question"
            let coordinator = AppCoordinator()
            coordinator.orbie = service
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 680, height: 590), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: MacOrbiePanelView().environment(coordinator).environment(\.colorScheme, scheme))
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(250))
            hosting.layoutSubtreeIfNeeded()
            for identifier in ["orbie-panel-terminal", "orbie-panel-open-agent", "orbie-panel-draft", "orbie-panel-send"] {
                let control = try #require(find(identifier, in: hosting))
                let selector = NSSelectorFromString("accessibilityFrame")
                let implementation = try #require(control.method(for: selector))
                let frame = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> CGRect).self)(control, selector)
                #expect(frame.width > 0 && frame.height > 0 && window.frame.contains(frame), Comment(rawValue: "\(identifier): \(frame), window: \(window.frame)"))
            }
            #expect(find("orbie-panel-search", in: hosting) == nil)
            if let evidence = ProcessInfo.processInfo.environment["CTRLX_ORBIE_UI_EVIDENCE"], let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: evidence).appendingPathComponent("orbie-redesign-\(scheme).png"))
            }
            #expect(service.availability != nil && service.draft == "Keep my next question" && f.writes.isEmpty)
            window.contentView = nil
            coordinator.orbie = nil
            try await f.cleanup()
        }
    }

    private func find(_ identifier: String, in node: NSObject) -> NSObject? {
        for name in ["accessibilityIdentifier", "accessibilityLabel", "accessibilityValue"] {
            let selector = NSSelectorFromString(name)
            if node.responds(to: selector), node.perform(selector)?.takeUnretainedValue() as? String == identifier {
                return node
            }
        }
        let children = NSSelectorFromString("accessibilityChildren")
        if node.responds(to: children) {
            for child in node.perform(children)?.takeUnretainedValue() as? [NSObject] ?? [] {
                if let match = find(identifier, in: child) {
                    return match
                }
            }
        }
        return nil
    }

    @Test
    func nativeSwitcherKeepsDraftsAndUndoWithTheirAgent() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let f = try await AgentInteractionTestSupport()
            let main = await f.orbie()
            try await main.create(pluginID: "codex", providerID: nil)
            main.draft = "Orbie draft"
            let service = await f.orbiters()
            service.draft = .init(title: "Expert", goal: "Orbiter draft", directory: f.root.path)
            let id = try await service.create(pluginID: "codex", providerID: nil)
            let coordinator = AppCoordinator()
            coordinator.orbie = main
            coordinator.orbiters = service
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 680, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: MacOrbiePanelView().environment(coordinator))
            window.contentView = hosting
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            window.orderBack(nil)
            try press(#require(find("orbie-panel-switcher", in: hosting)))
            try await Task.sleep(for: .milliseconds(200))
            let choice = try #require(NSApp.windows.compactMap { find("orbie-panel-agent-\(id)", in: $0) }.first)
            try press(choice)
            try await Task.sleep(for: .milliseconds(200))
            let editor = try #require(textView(in: hosting))
            #expect(editor.string == "Orbiter draft")
            #expect(editor.undoManager?.canUndo == false)
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertText(" edited", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(service.drafts[id] == "Orbiter draft edited" && main.draft == "Orbie draft")
            await main.setEnabled(false)
            try await Task.sleep(for: .milliseconds(100))
            #expect(find("Enable Orbie", in: hosting) != nil)
            await main.setEnabled(true)
            try press(#require(find("orbie-panel-switcher", in: hosting)))
            try await Task.sleep(for: .milliseconds(200))
            try press(#require(NSApp.windows.compactMap { find("orbie-panel-agent-orbie", in: $0) }.first))
            try await Task.sleep(for: .milliseconds(200))
            let mainEditor = try #require(textView(in: hosting))
            #expect(mainEditor.string == "Orbie draft" && mainEditor.undoManager?.canUndo == false)
            #expect(service.drafts[id] == "Orbiter draft edited" && f.writes.isEmpty)
            window.contentView = nil
            coordinator.orbie = nil
            coordinator.orbiters = nil
            try await f.cleanup()
        }
    }

    private func textView(in view: NSView) -> OrbiePanelComposer.TextView? {
        if let editor = view as? OrbiePanelComposer.TextView {
            return editor
        }
        return view.subviews.compactMap { textView(in: $0) }.first
    }

    @Test
    func nativeConversationFollowsLatestUnlessReadingEarlierMessages() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let f = try await AgentInteractionTestSupport()
            let service = await f.orbie()
            try await service.create(pluginID: "codex", providerID: nil)
            for index in 0..<3 {
                service.draft = "Question \(index)"
                await service.send()
                try await f.complete(#require(service.messages.last), answer: String(repeating: "Reply \(index)\n", count: 20))
                await service.refresh(inspect: false)
            }
            let orbiters = await f.orbiters()
            orbiters.draft = .init(title: "Expert", goal: "Expert question", directory: f.root.path)
            let orbiterID = try await orbiters.create(pluginID: "codex", providerID: nil)
            try await orbiters.send(orbiterID)
            try await f.complete(#require(orbiters.messages.last), answer: String(repeating: "Expert reply\n", count: 30))
            await orbiters.refresh(inspect: false)
            let coordinator = AppCoordinator()
            coordinator.orbie = service
            coordinator.orbiters = orbiters
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 680, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: MacOrbiePanelView().environment(coordinator))
            window.contentView = hosting
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(250))
            window.orderBack(nil)
            let scroll = try #require(conversationScroll(in: hosting))
            try #require((scroll.documentView?.bounds.height ?? 0) > scroll.contentSize.height + 200)
            #expect(atBottom(scroll), "Opening a conversation must reveal its latest exchange")

            service.draft = "New question"
            await service.send()
            try await Task.sleep(for: .milliseconds(150))
            #expect(atBottom(scroll), "The new message and pending status must stay visible")
            let latest = try #require(service.messages.last)
            try await f.complete(latest, answer: String(repeating: "Long new reply\n", count: 45))
            await service.refresh(inspect: false)
            try await Task.sleep(for: .milliseconds(150))
            #expect(atBottom(scroll), "A reader at the bottom follows reply growth")

            scroll.contentView.scroll(to: .init(x: 0, y: 100))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            try #require(!atBottom(scroll))
            let earlierOffset = scroll.documentVisibleRect.minY
            try await f.interaction.store.update(latest.id) { $0.answer = String(repeating: "Additional reply detail\n", count: 70) }
            await service.refresh(inspect: false)
            try await Task.sleep(for: .milliseconds(150))
            #expect(!atBottom(scroll))
            #expect(abs(scroll.documentVisibleRect.minY - earlierOffset) < 2, "New replies must not pull the reader away from earlier text")

            for id in [orbiterID, "orbie"] {
                try press(#require(find("orbie-panel-switcher", in: hosting)))
                try await Task.sleep(for: .milliseconds(150))
                try press(#require(NSApp.windows.compactMap { find("orbie-panel-agent-\(id)", in: $0) }.first))
                try await Task.sleep(for: .milliseconds(200))
                #expect(try atBottom(#require(conversationScroll(in: hosting))), "Switching conversations reveals the selected Agent's latest message")
            }
            window.contentView = nil
            coordinator.orbie = nil
            coordinator.orbiters = nil
            try await f.cleanup()
        }
    }

    private func conversationScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, !(scroll is OrbiePanelComposer.ComposerScrollView) {
            return scroll
        }
        return view.subviews.compactMap { conversationScroll(in: $0) }.first
    }

    private func atBottom(_ scroll: NSScrollView) -> Bool {
        let bottom = scroll.documentView?.bounds.maxY ?? 0
        return scroll.documentVisibleRect.maxY >= bottom - 2
    }

    @Test(arguments: ["identity", "bridges", "messages"])
    func nativeStartupFailureShowsReasonAndCanRetry(fault: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orbie-panel-startup-\(UUID())")
        let hostID = UUID()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            $0[HostIdentityClient.self].load = { hostID }
        } operation: {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let coordinator = AppCoordinator()
            coordinator.ctrlxPaths = CtrlxPaths(stateRootOverride: directory)
            let file = directory.appendingPathComponent(fault == "bridges" ? "AgentInteraction/bridges.json" : "AgentInteraction/messages/\(UUID().uuidString).json")
            if fault == "identity" {
                await withDependencies {
                    $0[HostIdentityClient.self].load = { throw AgentWorkflowError("Host identity temporarily unavailable") }
                } operation: { await coordinator.setupAgentWorkflows() }
            } else {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("invalid JSON".utf8).write(to: file)
                await coordinator.setupAgentWorkflows()
            }
            try #require(coordinator.orbie == nil)
            let issue = try #require(coordinator.agentWorkflowStartupError)
            let existingWorkflows = coordinator.agentWorkflowService
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 680, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: MacOrbiePanelView().environment(coordinator))
            window.contentView = hosting
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            #expect(find("Orbie could not start", in: hosting) != nil)
            #expect(find(issue, in: hosting) != nil)
            #expect(find("Loading…", in: hosting) == nil)
            if fault != "identity" {
                try FileManager.default.removeItem(at: file)
            }
            try press(#require(find("orbie-panel-recheck", in: hosting)))
            for _ in 0..<100 {
                if coordinator.orbie?.record != nil, coordinator.agentWorkflowStartupError == nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(coordinator.orbie != nil)
            #expect(coordinator.agentWorkflowStartupError == nil)
            if let existingWorkflows {
                #expect(coordinator.agentWorkflowService === existingWorkflows)
            }
            window.contentView = nil
            await coordinator.stopAgentWorkflows()
        }
    }

    private func press(_ object: NSObject) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try #require(object.method(for: selector))
        #expect(unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(object, selector))
    }
}
