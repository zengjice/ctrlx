import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import ConcurrencyExtras
import Dependencies
import Foundation
import Testing
import Vapor
@testable import CtrlxServerFeature

@MainActor
@Suite("Terminal paste over encrypted WebSockets", .serialized)
struct TerminalPasteTransportTests {
    @Test("Acknowledged paste and question intents preserve Host input order", arguments: [false, true])
    func hostInputFIFO(questions: Bool) async throws {
        let originalVersion = VersionCompatibility.appVersionOverride
        VersionCompatibility.appVersionOverride = "3.0.43"
        defer { VersionCompatibility.appVersionOverride = originalVersion }
        let relay = PhraseTestRelay()
        let app = try await Application.make(.testing)
        app.webSocket("api", "ws") { _, ws in
            ws.onBinary { ws, bytes in
                let data = Data(bytes.readableBytesView)
                Task { await relay.receive(data, from: ws) }
            }
        }
        try await app.asyncBoot()
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        do {
            let port = try #require(app.http.server.shared.localAddress?.port)
            let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
            let hostEncryption = try await encryption(), viewerEncryption = try await encryption()
            let host = ConnectedViewer(
                pairedViewer: .init(id: "pair", deviceName: "Viewer",
                                    partnerPublicKey: viewerEncryption.publicKey.base64EncodedString(),
                                    partnerPublicKeyId: viewerEncryption.keyId),
                e2eeService: hostEncryption
            )
            let viewer = ViewerRelayClient()
            host.onSessionStateRequest = {
                SessionStateMessage(pairId: "", paneStates: [:], supportsSessionWorktrees: true, supportsTerminalPaste: true, supportsCodexQuestionAcknowledgement: true, supportsTerminalFit: true, supportsFileBrowsing: true)
            }
            let (keyGate, releaseKeys) = AsyncStream<Void>.makeStream()
            let (inputGate, releaseInput) = AsyncStream<Void>.makeStream()
            defer { releaseKeys.finish()
                releaseInput.finish()
            }
            var events: [String] = []
            host.onCommand = { command in
                switch command.command {
                case .sendKeystroke(.init([.text("before")])):
                    events.append("keys-start")
                    for await _ in keyGate { break }
                    events.append("keys-end")
                case .pasteTerminalText,
                     .expandCodexQuestions:
                    if case let .pasteTerminalText(paste) = command.command {
                        #expect(paste.text == "first\nsecond\n")
                    }
                    if case let .expandCodexQuestions(question) = command.command {
                        #expect(question.expectedQuestionID == "session:call")
                    }
                    events.append("input-start")
                    for await _ in inputGate {
                        break
                    }
                    events.append("input-end")
                case .sendKeystroke(.init([.enter])):
                    events.append("send")
                default:
                    break
                }
                return CommandResponseMessage(commandId: command.id, success: true, codexQuestionsHandled: true)
            }
            await host.connect(serverURL: url, deviceId: "host", deviceName: "Host", username: "test",
                               publicKey: hostEncryption.publicKey.base64EncodedString(), publicKeyId: hostEncryption.keyId)
            await viewer.connect(serverURL: url, pairId: "pair", deviceId: "viewer", deviceName: "Viewer",
                                 publicKey: viewerEncryption.publicKey.base64EncodedString(), publicKeyId: viewerEncryption.keyId,
                                 e2eeService: viewerEncryption, partnerPublicKey: hostEncryption.publicKey.base64EncodedString(),
                                 partnerPublicKeyId: hostEncryption.keyId)
            do {
                try await waitUntil { host.isViewerConnected && viewer.isHostConnected }
                try await waitUntil { viewer.hostSupportsTerminalPaste && viewer.hostSupportsCodexQuestionAcknowledgement }
                _ = await viewer.sendCommand(SendKeystroke([.text("before")]), paneId: "%7")
                try await waitUntil { events == ["keys-start"] }
                let frameCount = await relay.encryptedFrames
                let inputTask = Task {
                    if questions {
                        await viewer.sendCommand(ExpandCodexQuestions(expectedCount: 1, expectedQuestionID: "session:call"), paneId: "%7")
                    } else {
                        await viewer.sendCommand(PasteTerminalText(text: "first\nsecond\n"), paneId: "%7")
                    }
                }
                try await waitUntil { await relay.encryptedFrames > frameCount }
                _ = await viewer.sendCommand(SendKeystroke([.enter]), paneId: "%7")
                try await waitUntil { await relay.encryptedFrames >= frameCount + 2 }
                // Give the real receiver a turn while the preceding key is held.
                try await Task.sleep(for: .milliseconds(50))
                #expect(events == ["keys-start"])
                releaseKeys.yield()
                try await waitUntil { events.contains("input-start") }
                try await Task.sleep(for: .milliseconds(50))
                #expect(events == ["keys-start", "keys-end", "input-start"])
                releaseInput.yield()
                let result = await inputTask.value
                if case let .failure(error) = result {
                    Issue.record("Input did not acknowledge: \(error)")
                }
                try await waitUntil { events.last == "send" }
                #expect(events == ["keys-start", "keys-end", "input-start", "input-end", "send"])
                events.removeAll()
                let debouncer = KeystrokeDebouncer(paneId: "%7", relayClient: viewer)
                defer { debouncer.cancelAll() }
                debouncer.enqueuePasteText("first\nsecond\n") { events.append("draft") }
                debouncer.enqueueImmediately([.enter]) { events.append("observed-send") }
                try await waitUntil { events == ["input-start"] }
                try await Task.sleep(for: .milliseconds(50))
                #expect(events == ["input-start"])
                releaseInput.yield()
                try await waitUntil { events.contains("observed-send") && events.contains("send") }
                #expect(Array(events.prefix(3)) == ["input-start", "input-end", "draft"])
                let draftIndex = try #require(events.firstIndex(of: "draft"))
                let sendIndex = try #require(events.firstIndex(of: "observed-send"))
                #expect(draftIndex < sendIndex)
                // A deliberately slow file read must not hold the socket receive
                // loop, otherwise subsequent keystrokes cannot even reach the FIFO.
                try await waitUntil { viewer.hostSupportsFileBrowsing }
                let (fileGate, releaseFile) = AsyncStream<Void>.makeStream()
                defer { releaseFile.finish() }
                events.removeAll()
                host.onCommand = { command in
                    switch command.command {
                    case .browseFiles,
                         .prepareSessionWorktree,
                         .createTmuxSession:
                        events.append("file-start")
                        for await _ in fileGate { break }
                        events.append("file-end")
                    default: events.append("key")
                    }
                    return .success(for: command.id)
                }
                let worktreeSession = CreateTmuxSession(
                    sessionName: "new",
                    width: 80,
                    height: 24,
                    workingDirectory: "/Host",
                    worktree: .init(name: "new", expectedHead: "abc"),
                )
                for command in [BrowseFiles(.info(path: "/Host")).commandType, PrepareSessionWorktree(path: "/Host").commandType, worktreeSession.commandType] {
                    events.removeAll()
                    let fileTask = Task { await viewer.send(command, paneId: "%7") }
                    try await waitUntil { events.contains("file-start") }
                    _ = await viewer.sendCommand(SendKeystroke([.text("unblocked")]), paneId: "%7")
                    try await waitUntil { events.contains("key") }
                    #expect(events == ["file-start", "key"])
                    releaseFile.yield()
                    #expect(await fileTask.value)
                    #expect(events.last == "file-end")
                }
                if !questions {
                    let responses = LockIsolated<[AgentResponseSubmissionMessage]>([])
                    host.onAgentResponseSubmission = { response in responses.withValue { $0.append(response) } }
                    #expect(await viewer.submitAgentResponse(sessionId: "%7", pluginId: "echo", requestId: "legacy", response: .prompt(text: "old Host")))
                    try await waitUntil { responses.value.count == 1 }
                    #expect(responses.value.first?.expectedWorkspacePane == nil)
                    let hostID = UUID()
                    let original = WorkspacePaneIdentity(serverID: "10:100", sessionID: UUID(), windowID: UUID(), paneID: UUID())
                    let oldState = SessionStateMessage(
                        pairId: "", paneStates: ["%7": .init(paneId: "%7", sessionName: "input", tmuxWindowId: "@1", workspaceIdentity: original)],
                        supportsTerminalPaste: true, supportsCodexQuestionAcknowledgement: true, supportsTerminalFit: true,
                        workspaceIdentity: .init(hostID: hostID, serverID: original.serverID), supportsWorkspaceInputIdentity: true
                    )
                    host.onSessionStateRequest = { oldState }
                    await host.pushSessionState()
                    try await waitUntil { viewer.workspaceInputState.catalog?.scope.serverID == original.serverID }
                    let editorBinding = viewer.workspaceInputState.binding(paneID: "%7")
                    let windowBinding = viewer.workspaceInputState.windowBinding(target: "@1")
                    let sessionBinding = viewer.workspaceInputState.sessionBinding(name: "input")
                    #expect(await viewer.submitAgentResponse(sessionId: "%7", pluginId: "echo", requestId: "original", response: .prompt(text: "original"), inputBinding: editorBinding))
                    try await waitUntil { responses.value.count == 2 }
                    #expect(responses.value.last?.expectedWorkspacePane == original)
                    let (pasteGate, releasePaste) = AsyncStream<Void>.makeStream()
                    defer { releasePaste.finish() }
                    var delivered: [CommandMessage] = []
                    host.onCommand = { command in
                        delivered.append(command)
                        if case .pasteTerminalText = command.command {
                            for await _ in pasteGate {
                                break
                            }
                        }
                        return .success(for: command.id)
                    }
                    let oldQueue = KeystrokeDebouncer(paneId: "%7", relayClient: viewer)
                    defer { oldQueue.cancelAll() }
                    var queuedQuestionResult: Bool?
                    oldQueue.enqueuePasteText("before-restart")
                    oldQueue.enqueueImmediately([.text("must-not-cross-restart")])
                    oldQueue.enqueueCodexQuestionExpansion(expectedCount: 1) { queuedQuestionResult = $0 }
                    try await waitUntil { delivered.count == 1 }
                    #expect(delivered.first?.expectedWorkspacePane == original)
                    var restored = original
                    restored.serverID = "20:200"
                    let newState = SessionStateMessage(
                        pairId: "", paneStates: ["%7": .init(paneId: "%7", sessionName: "input", tmuxWindowId: "@1", workspaceIdentity: restored)],
                        supportsTerminalPaste: true, supportsCodexQuestionAcknowledgement: true, supportsTerminalFit: true,
                        workspaceIdentity: .init(hostID: hostID, serverID: restored.serverID), supportsWorkspaceInputIdentity: true
                    )
                    host.onSessionStateRequest = { newState }
                    await host.pushSessionState()
                    try await waitUntil { viewer.workspaceInputState.catalog?.scope.serverID == restored.serverID }
                    #expect(await !viewer.submitAgentResponse(sessionId: "%7", pluginId: "echo", requestId: "original", response: .prompt(text: "must not send"), inputBinding: editorBinding))
                    #expect(responses.value.count == 2)
                    #expect(await viewer.submitAgentResponse(sessionId: "%7", pluginId: "echo", requestId: "fresh", response: .prompt(text: "restored")))
                    try await waitUntil { responses.value.count == 3 }
                    #expect(responses.value.last?.expectedWorkspacePane == restored)
                    releasePaste.yield()
                    try await waitUntil { queuedQuestionResult != nil }
                    #expect(queuedQuestionResult == false)
                    #expect(delivered.count == 1)
                    let freshQueue = KeystrokeDebouncer(paneId: "%7", relayClient: viewer)
                    defer { freshQueue.cancelAll() }
                    freshQueue.enqueueImmediately([.text("after-restart")])
                    try await waitUntil { delivered.count == 2 }
                    #expect(delivered.last?.expectedWorkspacePane == restored)

                    let staleStart = await viewer.sendCommand(StartTerminalStream(leaseId: UUID()), paneId: "%7", inputBinding: editorBinding)
                    if case .success = staleStart {
                        Issue.record("Stale stream start crossed the Host restart")
                    }
                    #expect(delivered.count == 2)

                    let editorID = UUID()
                    let oldSubmit = await viewer.sendCommand(SubmitEditorContent(content: "stale editor", expectedSessionID: editorID), paneId: "%7", inputBinding: editorBinding)
                    let oldCancel = await viewer.sendCommand(CancelEditorSession(expectedSessionID: editorID), paneId: "%7", inputBinding: editorBinding)
                    if case .success = oldSubmit {
                        Issue.record("Stale editor submit crossed the Host restart")
                    }
                    if case .success = oldCancel {
                        Issue.record("Stale editor cancel crossed the Host restart")
                    }
                    #expect(delivered.count == 2)
                    let freshSubmit = await viewer.sendCommand(SubmitEditorContent(content: "current editor", expectedSessionID: editorID), paneId: "%7")
                    if case let .failure(error) = freshSubmit {
                        Issue.record("Current editor rejected: \(error)")
                    }
                    #expect(delivered.last?.expectedWorkspacePane == restored)
                    #expect(delivered.last?.command == SubmitEditorContent(content: "current editor", expectedSessionID: editorID).commandType)

                    let streamLease = UUID()
                    let freshStart = await viewer.sendCommand(StartTerminalStream(leaseId: streamLease), paneId: "%7")
                    if case let .failure(error) = freshStart {
                        Issue.record("Current stream rejected: \(error)")
                    }
                    #expect(delivered.last?.expectedWorkspacePane == restored)
                    #expect(delivered.last?.command == StartTerminalStream(leaseId: streamLease).commandType)

                    let beforeActions = delivered.count
                    let forkSource = try #require(AgentForkSource(pane: .init(
                        paneId: "%7", sessionName: "input", tmuxWindowId: "@1", currentPath: "/tmp",
                        agentSession: .init(paneId: "%7", pluginID: "codex"), claudeSessionID: UUID().uuidString,
                        workspaceIdentity: original
                    )))
                    let actions: [(CommandType, String, ViewerWorkspaceInputBinding)] = [
                        (SetYoloMode(enabled: true).commandType, "%7", editorBinding),
                        (MarkHandled().commandType, "%7", editorBinding),
                        (SplitTmuxPane(direction: .horizontal).commandType, "%7", editorBinding),
                        (SelectTmuxPane().commandType, "%7", editorBinding),
                        (SelectTmuxWindow().commandType, "input:0", windowBinding),
                        (SetWindowName(windowId: "@1", name: "renamed").commandType, "", windowBinding),
                        (RenameTmuxSession(sessionName: "input", newName: "renamed").commandType, "", sessionBinding),
                        (SetSessionDescription(sessionName: "input", description: "description").commandType, "", sessionBinding),
                        (SetSessionColor(sessionName: "input", color: .blue).commandType, "", sessionBinding),
                        (SetSessionEmoji(sessionName: "input", emoji: "🌿").commandType, "", sessionBinding),
                        (SetSessionState(sessionName: "input", state: .waiting).commandType, "", sessionBinding),
                        (MoveTmuxWindows(sessionName: "input", windowIds: ["@1"]).commandType, "", sessionBinding),
                        (CreateTmuxWindow(sessionName: "input").commandType, "", sessionBinding),
                        (PrepareAgentFork(source: forkSource).commandType, "", editorBinding),
                        (ForkAgentSession(source: forkSource).commandType, "", editorBinding),
                        (SetSharedTerminalLayout(sessionName: "input", leftWindowId: "@1").commandType, "", sessionBinding),
                        (ResizeTmuxPane(width: 100, height: 30, userInitiated: true).commandType, "@1", windowBinding),
                        (CheckRunningProcesses(target: .window("@1")).commandType, "", windowBinding),
                        (CheckRunningProcesses(target: .session("input")).commandType, "", sessionBinding),
                        (KillTmuxWindow(windowId: "@1").commandType, "", windowBinding),
                        (KillTmuxSession(sessionName: "input").commandType, "", sessionBinding),
                    ]
                    for (command, target, binding) in actions {
                        #expect(await !viewer.send(command, paneId: target, inputBinding: binding))
                    }
                    #expect(delivered.count == beforeActions)
                    for (index, action) in actions.enumerated() {
                        #expect(await viewer.send(action.0, paneId: action.1))
                        try await waitUntil { delivered.count == beforeActions + index + 1 }
                        #expect(delivered.last?.expectedWorkspacePane == restored)
                        #expect(delivered.last?.command == action.0)
                    }

                    for success in [false, true] {
                        let (completionGate, complete) = AsyncStream<Void>.makeStream()
                        defer { complete.finish() }
                        var received = false
                        var acknowledged: Bool?
                        host.onCommand = { command in
                            #expect(command.expectedWorkspacePane == restored)
                            #expect(command.command.requiresResponse)
                            received = true
                            for await _ in completionGate {
                                break
                            }
                            return success ? .success(for: command.id) : .failure(for: command.id, error: "Terminal changed")
                        }
                        let submission = Task {
                            let result = await viewer.sendCommand(SendKeystroke([.text("draft"), .enter], acknowledgeCompletion: true), paneId: "%7")
                            switch result {
                            case let .success(response): acknowledged = response.success
                            case .failure: acknowledged = false
                            }
                        }
                        try await waitUntil { received }
                        try await Task.sleep(for: .milliseconds(50))
                        #expect(acknowledged == nil)
                        complete.yield()
                        await submission.value
                        #expect(acknowledged == success)
                    }
                }
                #expect(await relay.unexpectedTypes.isEmpty)
                #expect(await relay.errors.isEmpty)
            } catch {
                releaseKeys.finish()
                releaseInput.finish()
                await viewer.disconnect()
                await host.disconnect()
                throw error
            }
            await viewer.disconnect()
            await host.disconnect()
        } catch {
            await app.server.shutdown()
            try await app.asyncShutdown()
            throw error
        }
        await app.server.shutdown()
        try await app.asyncShutdown()
    }

    @Test("Absent or false Host capabilities fail before sending and do not block following keys",
          arguments: [Optional<Bool>.none, false])
    func legacyHost(capability: Bool?) async throws {
        let originalVersion = VersionCompatibility.appVersionOverride
        VersionCompatibility.appVersionOverride = "3.0.43"
        defer { VersionCompatibility.appVersionOverride = originalVersion }
        let relay = PhraseTestRelay()
        let app = try await Application.make(.testing)
        app.webSocket("api", "ws") { _, ws in
            ws.onBinary { ws, bytes in
                let data = Data(bytes.readableBytesView)
                Task { await relay.receive(data, from: ws) }
            }
        }
        try await app.asyncBoot()
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        do {
            let port = try #require(app.http.server.shared.localAddress?.port)
            let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
            let hostEncryption = try await encryption(), viewerEncryption = try await encryption()
            let host = ConnectedViewer(
                pairedViewer: .init(id: "pair", deviceName: "Viewer",
                                    partnerPublicKey: viewerEncryption.publicKey.base64EncodedString(),
                                    partnerPublicKeyId: viewerEncryption.keyId),
                e2eeService: hostEncryption
            )
            let viewer = ViewerRelayClient()
            let receivedState = LockIsolated(false)
            viewer.onSessionState = { _ in receivedState.setValue(true) }
            host.onSessionStateRequest = {
                SessionStateMessage(
                    pairId: "", paneStates: [:], supportsDirectoryBrowsing: true,
                    supportsDirectoryCreation: capability, supportsSessionWorktrees: capability,
                    supportsTerminalPaste: capability, supportsCodexQuestionAcknowledgement: capability,
                    supportsTerminalFit: capability
                )
            }
            var commands: [CommandType] = []
            host.onCommand = { command in
                commands.append(command.command)
                return .success(for: command.id)
            }
            await host.connect(serverURL: url, deviceId: "host", deviceName: "Host", username: "test",
                               publicKey: hostEncryption.publicKey.base64EncodedString(), publicKeyId: hostEncryption.keyId)
            await viewer.connect(serverURL: url, pairId: "pair", deviceId: "viewer", deviceName: "Viewer",
                                 publicKey: viewerEncryption.publicKey.base64EncodedString(), publicKeyId: viewerEncryption.keyId,
                                 e2eeService: viewerEncryption, partnerPublicKey: hostEncryption.publicKey.base64EncodedString(),
                                 partnerPublicKeyId: hostEncryption.keyId)
            do {
                try await waitUntil { host.isViewerConnected && viewer.isHostConnected && receivedState.value }
                let frameCount = await relay.encryptedFrames
                #expect(!viewer.hostSupportsCodexQuestionAcknowledgement)
                let draft = await viewer.sendCommand(SendKeystroke([.text("draft")], acknowledgeCompletion: true), paneId: "%7")
                if case .success = draft {
                    Issue.record("Old Host accepted acknowledged draft submission")
                }
                let questions = await viewer.sendCommand(ExpandCodexQuestions(expectedCount: 1), paneId: "%7")
                if case .success = questions {
                    Issue.record("Old Host accepted acknowledged question expansion")
                }
                let started = ContinuousClock.now
                let fit = await viewer.sendCommand(ResizeTmuxPane(width: 64, height: 44, userInitiated: true), paneId: "@1")
                if case .success = fit { Issue.record("Old Host accepted Fit") }
                let paste = await viewer.sendCommand(PasteTerminalText(text: "one\ntwo"), paneId: "%7")
                if case .success = paste { Issue.record("Old Host accepted paste") }
                let create = await viewer.sendCommand(CreateSessionDirectory(parentDirectory: "/Host", name: "child"), paneId: "")
                if case .success = create { Issue.record("Old Host accepted directory creation") }
                let worktreeSession = CreateTmuxSession(
                    sessionName: "new",
                    width: 80,
                    height: 24,
                    workingDirectory: "/Host",
                    worktree: .init(name: "new", expectedHead: "abc"),
                )
                #expect(await !(viewer.send(PrepareSessionWorktree(path: "/Host").commandType, paneId: "")))
                #expect(await !(viewer.send(worktreeSession.commandType, paneId: "")))
                let browse = await viewer.sendCommand(BrowseFiles(.list(path: nil, offset: 0, includeHidden: false)), paneId: "%7")
                if case .success = browse { Issue.record("Old Host accepted file browsing") }
                #expect(ContinuousClock.now - started < .seconds(1))
                #expect(await relay.encryptedFrames == frameCount)
                var failures: [String] = []
                var observed: [String] = []
                let debouncer = KeystrokeDebouncer(paneId: "%7", relayClient: viewer) { failures.append($0) }
                defer { debouncer.cancelAll() }
                debouncer.enqueuePasteText("one\ntwo") { observed.append("rejected-paste") }
                debouncer.enqueueImmediately([.enter]) { observed.append("empty-enter") }
                debouncer.enqueueImmediately([.text("after")]) { observed.append("after") }
                try await waitUntil { commands == [SendKeystroke([.enter]).commandType, SendKeystroke([.text("after")]).commandType] }
                #expect(observed == ["empty-enter", "after"])
                #expect(failures.count == 1)
                #expect(failures.first?.contains("Update the Host Mac") == true)
                // A later capability offer enables the operation, but is never
                // carried over to a disconnected or replacement Host.
                host.onSessionStateRequest = {
                    SessionStateMessage(pairId: "", paneStates: [:], supportsDirectoryCreation: true, supportsSessionWorktrees: true, supportsTerminalPaste: true, supportsCodexQuestionAcknowledgement: true, supportsTerminalFit: true, supportsFileBrowsing: true)
                }
                await host.pushSessionState()
                try await waitUntil { viewer.hostSupportsCodexQuestionAcknowledgement && viewer.hostSupportsTerminalPaste && viewer.hostSupportsTerminalFit && viewer.hostSupportsDirectoryCreation && viewer.hostSupportsFileBrowsing && viewer.hostSupportsSessionWorktrees }
                #expect(await viewer.send(PrepareSessionWorktree(path: "/Host").commandType, paneId: ""))
                #expect(commands.last == PrepareSessionWorktree(path: "/Host").commandType)
                #expect(await viewer.send(worktreeSession.commandType, paneId: ""))
                #expect(commands.last == worktreeSession.commandType)
                let modernBrowse = await viewer.sendCommand(BrowseFiles(.info(path: "/Host/file")), paneId: "%7")
                if case .failure(let error) = modernBrowse { Issue.record("Modern file browsing rejected: \(error)") }
                let modernCreate = await viewer.sendCommand(CreateSessionDirectory(parentDirectory: "/Host", name: "child"), paneId: "")
                if case .failure(let error) = modernCreate { Issue.record("Modern directory creation rejected: \(error)") }
                #expect(commands.last == CreateSessionDirectory(parentDirectory: "/Host", name: "child").commandType)
                let modern = await viewer.sendCommand(PasteTerminalText(text: "one\ntwo"), paneId: "%7")
                if case .failure(let error) = modern { Issue.record("Modern paste rejected: \(error)") }
                #expect(commands.last == PasteTerminalText(text: "one\ntwo").commandType)
                host.onCommand = { command in
                    commands.append(command.command)
                    if case let .expandCodexQuestions(spec) = command.command {
                        return CommandResponseMessage(commandId: command.id, success: true, codexQuestionsHandled: spec.expectedCount == 3 ? nil : spec.expectedCount == 2)
                    }
                    if case .pasteTerminalText = command.command {
                        return .failure(for: command.id, error: "Paste rejected by tmux")
                    }
                    return .success(for: command.id)
                }
                var questionResults: [Bool] = []
                for count in [1, 2, 3] {
                    debouncer.enqueueCodexQuestionExpansion(expectedCount: count) { questionResults.append($0) }
                }
                try await waitUntil { questionResults.count == 3 }
                #expect(questionResults == [false, true, false])
                observed.removeAll()
                debouncer.enqueuePasteText("host-rejected") { observed.append("rejected-paste") }
                debouncer.enqueueImmediately([.enter]) { observed.append("empty-enter") }
                try await waitUntil { failures.count == 2 && observed == ["empty-enter"] }
                #expect(failures.last?.contains("Paste rejected by tmux") == true)
                await viewer.disconnect()
                #expect(!viewer.hostSupportsCodexQuestionAcknowledgement && !viewer.hostSupportsTerminalPaste && !viewer.hostSupportsTerminalFit && !viewer.hostSupportsDirectoryCreation && !viewer.hostSupportsSessionWorktrees)
            } catch {
                await viewer.disconnect()
                await host.disconnect()
                throw error
            }
            await viewer.disconnect()
            await host.disconnect()
        } catch {
            await app.server.shutdown()
            try await app.asyncShutdown()
            throw error
        }
        await app.server.shutdown()
        try await app.asyncShutdown()
    }

    private func encryption() async throws -> E2EEService {
        try await withDependencies { $0[SecretsService.self] = .inMemory() } operation: { try await E2EEService() }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let met = await condition()
        try #require(met, "Terminal input queue did not converge")
    }
}
