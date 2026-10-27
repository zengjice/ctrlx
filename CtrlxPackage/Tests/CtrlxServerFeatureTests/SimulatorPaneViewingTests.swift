#if os(macOS)
    import AppKit
    import CtrlxCommon
    import CtrlxNetworking
    @preconcurrency import CtrlxSimulatorBridge
    import CtrlxSimulatorProtocol
    import Dependencies
    import Foundation
    import ImageIO
    import IOSurface
    import SwiftUI
    import Synchronization
    import Testing
    @testable import CtrlxServerFeature

    final private class PreviewTestConnection: CXSimulatorConnection, @unchecked Sendable {
        let commands = Mutex<[String]>([])
        let requests = Mutex<[[String: JSONValue]]>([])
        let hold = Mutex(false)
        let holdClipboard = Mutex(false)
        let failCancel = Mutex(false)
        let readClipboard = Mutex<(@Sendable ([String: JSONValue]) throws -> [String: JSONValue])?>(nil)
        let clipboardReplies = Mutex<[CXSimulatorDataReply]>([])
        let replies = Mutex<[CXSimulatorDataReply]>([])
        override func invalidate() { }
        override func request(_ data: Data, reply: @escaping CXSimulatorDataReply) {
            let request = try? JSONDecoder().decode([String: JSONValue].self, from: data)
            let command = request?["command"]?.stringValue ?? ""
            commands.withLock { $0.append(command) }
            if let request {
                requests.withLock { $0.append(request) }
            }
            if command == "cancel", failCancel.withLock({ $0 }) {
                reply(nil, NSError(domain: "ClipboardTests", code: 1))
            } else if command == "clipboard-write", holdClipboard.withLock({ $0 }) {
                clipboardReplies.withLock { $0.append(reply) }
            } else if command == "clipboard-read", let request, let read = readClipboard.withLock({ $0 }) {
                do {
                    try reply(JSONEncoder().encode(read(request)), nil)
                } catch {
                    reply(nil, error)
                }
            } else
            if command == "preview" {
                if hold.withLock({ $0 }) {
                    replies.withLock { $0.append(reply) }
                } else {
                    reply(Self.frame, nil)
                }
            } else {
                reply(Data("{}".utf8), nil)
            }
        }

        static let frame = Data(#"{"data":"AQ==","width":256,"height":512}"#.utf8)
        func release() {
            hold.withLock { $0 = false }
            let pending = replies.withLock { let values = $0
                $0.removeAll()
                return values
            }
            for reply in pending {
                reply(Self.frame, nil)
            }
        }
    }

    final private class PreviewTestState: Sendable {
        let calls = Mutex<[[String]]>([])
        let holdBoot = Mutex(false)
        let alive = Mutex(true)
        let agentUnavailable = Mutex(false)
    }

    @Suite("Simulator pane reuse and remote viewing", .serialized) @MainActor
    struct SimulatorPaneViewingTests {
        @MainActor
        final class Fixture {
            let service: AgentSimulatorService
            fileprivate let connection: PreviewTestConnection
            fileprivate let probe = PreviewTestState()
            var pane: PaneInfo
            var otherPanes: [PaneInfo] = []
            let workspace = SimulatorWorkspace()
            var created: [SimulatorTabState] = []
            var detached: [UUID] = []
            var sessionTabs: [String: SessionFileTabsState] = [:]
            init(attach: Bool = true) throws {
                _ = NSApplication.shared
                self.pane = Self.pane(session: "work", window: 0)
                let connection = PreviewTestConnection()
                let probe = probe
                self.connection = connection
                let inventory = try JSONSerialization.data(withJSONObject: [
                    "runtimes": [[
                        "isAvailable": true,
                        "platform": "iOS",
                        "version": "27.0",
                        "identifier": "runtime",
                        "supportedDeviceTypes": [["productFamily": "iPhone", "identifier": "iphone", "name": "iPhone"]],
                    ]],
                    "devices": ["runtime": (0..<4).map { _ in
                        [
                            "isAvailable": true,
                            "state": "Shutdown",
                            "udid": UUID().uuidString,
                            "deviceTypeIdentifier": "iphone",
                            "name": "CtrlX · iPhone",
                        ] as [String: Any]
                    }],
                ])
                let runner = ProcessRunner(run: { _, arguments, _, _ in
                    probe.calls.withLock { $0.append(arguments) }
                    if arguments.first == "on" {
                        while probe.holdBoot.withLock({ $0 }) {
                            try await Task.sleep(for: .milliseconds(5))
                        }
                    }
                    let output: Data
                    if arguments == ["version"] {
                        output = Data("simslim \(SimulatorCoordinator.simslimCommit)".utf8)
                    } else if arguments.first == "profiles" {
                        output = Data("[{\"id\":\"core\",\"labels\":[\"com.apple.apsd\"]}]".utf8)
                    } else if arguments.contains("--list") {
                        output = Data("[]".utf8)
                    } else if arguments.contains("list") {
                        output = inventory
                    } else if arguments == ["--find", "xcodebuild"] {
                        output = Data("/fixture/Xcode.app/Contents/Developer/usr/bin/xcodebuild".utf8)
                    } else {
                        output = Data()
                    }
                    return ProcessResult(exitCode: 0, stdout: output, stderr: Data())
                })
                var system = SimulatorSystemClient()
                system.createDirectory = { _ in }
                system.isExecutable = { _ in true }
                system.read = { _ in throw CocoaError(.fileReadNoSuchFile) }
                system.write = { _, _ in }
                system.remove = { _ in }
                system.inspect = { pid in
                    if pid != getpid(), probe.agentUnavailable.withLock({ $0 }) {
                        throw SimulatorFailure("No agent process")
                    }
                    guard probe.alive.withLock({ $0 }) else { throw SimulatorFailure("Owner exited") }
                    return SimulatorProcess(
                        owner: SimulatorOwner(pid: pid, uid: getuid(), startSeconds: 100, startMicros: 1),
                        parentPID: 1,
                        executable: "/fixture/codex"
                    )
                }
                system.connect = { _, _, _ in SimulatorTransport(connection: connection) }
                self.service = withDependencies {
                    $0[ProcessRunner.self] = runner
                    $0[SimulatorSystemClient.self] = system
                    $0[SimulatorResourceClient.self] = SimulatorResourceClient(read: { _ in
                        SimulatorResources(
                            physicalBytes: 32 << 30,
                            reclaimableBytes: 16 << 30,
                            pressureLevel: 1,
                            swapUsedBytes: 0,
                            freeDiskBytes: 16 << 30
                        )
                    })
                } operation: { AgentSimulatorService() }
                withDependencies {
                    $0[ProcessRunner.self] = runner
                    $0[SimulatorSystemClient.self] = system
                    $0[SimulatorResourceClient.self] = SimulatorResourceClient(read: { _ in
                        SimulatorResources(
                            physicalBytes: 32 << 30,
                            reclaimableBytes: 16 << 30,
                            pressureLevel: 1,
                            swapUsedBytes: 0,
                            freeDiskBytes: 16 << 30
                        )
                    })
                } operation: {
                    service.start(root: URL(fileURLWithPath: "/unused-pane-viewing"), resolveRoute: { [unowned self] _ in
                        AgentPaneRoute(pane: self.pane, panes: [self.pane] + self.otherPanes)
                    })
                }
                workspace.acceptsPane = { _ in true }
                service.updateSimulatorRoutes([pane])
                workspace.onCreate = { [unowned self] state in
                    self.created.append(state)
                    let tabs = self.sessionTabs[state.sourcePane.sessionName] ?? SessionFileTabsState()
                    self.sessionTabs[state.sourcePane.sessionName] = tabs
                    tabs.attachSimulator(state)
                }
                workspace.onDetach = { [unowned self] state in
                    self.detached.append(state.id)
                    guard let tabs = self.sessionTabs.values.first(where: { $0.simulatorStates[state.id] != nil }) else { return }
                    tabs.simulatorStates.removeValue(forKey: state.id)
                    tabs.openBrowserTabs.removeAll { $0.id == state.id }
                    tabs.rightSide.remove(.browser(state.id))
                    if tabs.selectedRight == .browser(state.id) {
                        tabs.selectedRight = nil
                    }
                    if tabs.selectedBrowserTabId == state.id {
                        tabs.selectedBrowserTabId = nil
                    }
                }
                workspace.onSelect = { [unowned self] state, _ in
                    guard let tabs = self.sessionTabs.values.first(where: { $0.simulatorStates[state.id] != nil }) else { return }
                    if tabs.rightSide.contains(.browser(state.id)) {
                        tabs.selectedRight = .browser(state.id)
                    } else {
                        tabs.selectedBrowserTabId = state.id
                    }
                }
                if attach {
                    service.register(workspace)
                }
            }

            static func pane(session: String, window: Int, stableID: String? = nil, paneID: String = "%1", identity: WorkspacePaneIdentity? = nil) -> PaneInfo {
                PaneInfo(
                    paneId: paneID,
                    target: "\(session):\(window).0",
                    sessionName: session,
                    windowIndex: window,
                    tmuxWindowId: stableID ?? "@\(window)",
                    paneIndex: 0,
                    command: "codex",
                    currentPath: "/fixture",
                    width: 80,
                    height: 24,
                    isActive: true,
                    workspaceIdentity: identity
                )
            }

            func action(_ command: String, _ parameters: [String: JSONValue] = [:], peer: Int = 10) async -> JSONRPCResponse {
                var params = parameters
                params["command"] = .string(command)
                params["_peerPID"] = .int(peer)
                return await service.handle(JSONRPCRequest(id: UUID().uuidString, method: "simulator.action", params: params))
            }

            var boots: Int {
                probe.calls.withLock { $0.filter { $0.first == "on" }.count }
            }
        }

        @Test
        func simulatorFollowsItsPaneBetweenSessionWindowsWithoutRebooting() async throws {
            let fixture = try Fixture()
            let response = await fixture.action("open")
            #expect(response.ok)
            let state = try #require(fixture.created.first)
            let detached = SimulatorWorkspace()
            detached.acceptsPane = { _ in true }
            var received: [UUID] = []
            detached.onCreate = { received.append($0.id) }
            fixture.workspace.acceptsPane = { _ in false }

            fixture.service.register(detached)

            #expect(state.workspaceID == detached.id)
            #expect(received == [state.id])
            #expect(fixture.detached == [state.id])
            #expect(!state.isClosed && fixture.boots == 1)
            fixture.workspace.acceptsPane = { _ in true }
            fixture.service.unregister(detached)
            #expect(state.workspaceID == fixture.workspace.id)
            #expect(!state.isClosed && fixture.boots == 1)
            await fixture.service.shutdown()
        }

        @Test
        func explicitTabPlacementOverridesTheSourcePaneWithoutRebooting() async throws {
            let fixture = try Fixture()
            #expect(await fixture.action("open").ok)
            let state = try #require(fixture.created.first)
            let view = state.view
            let owner = state.owner
            let target = SimulatorWorkspace()
            var received: [SimulatorTabState] = []
            target.acceptsTab = { $0.id == state.id }
            target.onCreate = { received.append($0) }
            fixture.workspace.acceptsTab = { _ in false }
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let source = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
            source.isReleasedWhenClosed = false
            source.contentView = NSHostingView(rootView: SimulatorTabContentView(state: state, workspaceID: fixture.workspace.id))
            source.orderBack(nil)
            defer { source.close() }
            try await wait { source.contentView?.layoutSubtreeIfNeeded()
                return state.view.window === source
            }
            window.contentView = NSHostingView(rootView: SimulatorTabContentView(state: state, workspaceID: target.id))
            window.orderBack(nil)
            defer { window.close() }

            fixture.service.register(target)
            fixture.service.register(fixture.workspace)

            try await wait { window.contentView?.layoutSubtreeIfNeeded()
                return state.view.window === window
            }
            #expect(state.workspaceID == target.id)
            #expect(received.count == 1 && received.first === state)
            #expect(state.view === view && state.owner == owner)
            #expect(!state.isClosed && fixture.boots == 1)
            fixture.workspace.acceptsTab = nil
            fixture.service.unregister(target)
            try await wait { source.contentView?.layoutSubtreeIfNeeded()
                return state.view.window === source
            }
            #expect(state.workspaceID == fixture.workspace.id)
            #expect(state.view === view && state.owner == owner)
            #expect(!state.isClosed && fixture.boots == 1)
            await fixture.service.shutdown()
        }

        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<500 {
                if condition() {
                    return
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw SimulatorFailure("Timed out waiting for test fixture")
        }

        private func humanFixture() throws -> (Fixture, WorkspacePaneIdentity, OpenPaneSimulator) {
            let fixture = try Fixture()
            let identity = WorkspacePaneIdentity(serverID: "server:1", sessionID: UUID(), windowID: UUID(), paneID: UUID())
            fixture.pane = Fixture.pane(session: "work", window: 0, identity: identity)
            fixture.service.updateSimulatorRoutes([fixture.pane])
            fixture.service.resolveSourcePane = { [unowned fixture] session, paneID in
                guard session == fixture.pane.sessionName, paneID == fixture.pane.paneId else {
                    throw SimulatorFailure("Source pane missing")
                }
                return fixture.pane
            }
            return (fixture, identity, OpenPaneSimulator(sessionName: "work", sourcePaneID: "%1"))
        }

        @Test
        func remoteCloseValidatesTabAndSessionThenShutsDownOnlyThatDevice() async throws {
            let (fixture, identity, open) = try humanFixture()
            let tab = try await fixture.service.openPaneSimulator(open, expectedWorkspacePane: identity)
            let state = try #require(fixture.created.first)
            let extra = await fixture.action("open", ["new": .bool(true)])
            #expect(extra.error == nil)
            let other = try #require(fixture.created.last)
            #expect(other.id != tab.id)
            for request in [CloseSimulator(sessionName: "other", tabID: tab.id), .init(sessionName: "work", tabID: UUID())] {
                await #expect(throws: SimulatorFailure.self) {
                    try await fixture.service.closeSimulator(request)
                }
            }
            #expect(!state.isClosed && !other.isClosed)
            try await fixture.service.closeSimulator(.init(sessionName: "work", tabID: tab.id))
            #expect(state.isClosed && !other.isClosed)
            #expect(!fixture.service.sharedSimulatorTabs.contains { $0.id == tab.id })
            #expect(fixture.probe.calls.withLock { $0.contains { $0.suffix(2) == ["shutdown", state.handle.udid] } })
            let replacement = try await fixture.service.openPaneSimulator(open, expectedWorkspacePane: identity)
            #expect(replacement.id != tab.id)
            await #expect(throws: SimulatorFailure.self) {
                try await fixture.service.closeSimulator(.init(sessionName: "work", tabID: tab.id))
            }
            #expect(fixture.service.sharedSimulatorTabs.contains { $0.id == replacement.id })
            await fixture.service.shutdown()
        }

        @Test
        func failedTakeoverDoesNotKeepViewerLease() async throws {
            let (fixture, identity, open) = try humanFixture()
            let tab = try await fixture.service.openPaneSimulator(open, expectedWorkspacePane: identity)
            let state = try #require(fixture.created.first)
            fixture.connection.failCancel.withLock { $0 = true }
            await #expect(throws: (any Error).self) {
                try await fixture.service.controlSimulator(.init(
                    sessionName: "work", tabID: tab.id, surfaceID: UUID(),
                    controlID: nil, generation: nil, operation: .takeControl
                ), viewerID: "viewer")
            }
            #expect(state.remoteControl == nil)
            fixture.connection.failCancel.withLock { $0 = false }
            await fixture.service.shutdown()
        }

        @Test
        func clipboardControlIsBoundToViewerAndSurfaceAndHostTakeoverCancelsPaste() async throws {
            let (fixture, identity, open) = try humanFixture()
            let tab = try await fixture.service.openPaneSimulator(open, expectedWorkspacePane: identity)
            let state = try #require(fixture.created.first)
            let surface = UUID()
            let acquired = try await fixture.service.controlSimulator(.init(
                sessionName: "work",
                tabID: tab.id,
                surfaceID: surface,
                controlID: nil,
                generation: nil,
                operation: .takeControl
            ), viewerID: "viewer-A")
            let lease = try #require(acquired.controlID)
            func paste(surfaceID: UUID = surface) -> ControlSimulator {
                .init(
                    sessionName: "work",
                    tabID: tab.id,
                    surfaceID: surfaceID,
                    controlID: lease,
                    generation: acquired.generation,
                    operation: .paste(.init(text: "intended paste"))
                )
            }
            await #expect(throws: (any Error).self) { try await fixture.service.controlSimulator(paste(), viewerID: "viewer-B") }
            await #expect(throws: (any Error).self) { try await fixture.service.controlSimulator(paste(surfaceID: UUID()), viewerID: "viewer-A") }
            #expect(!fixture.connection.commands.withLock { $0.contains("clipboard-write") })
            fixture.connection.holdClipboard.withLock { $0 = true }
            let task = Task { try await fixture.service.controlSimulator(paste(), viewerID: "viewer-A") }
            try await wait { fixture.connection.clipboardReplies.withLock { !$0.isEmpty } }
            fixture.service.manualHome(state)
            #expect(state.remoteControl == nil)
            for reply in fixture.connection.clipboardReplies.withLock({ $0 }) {
                reply(Data("{}".utf8), nil)
            }
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(!fixture.connection.requests.withLock { $0.contains { $0["command"]?.stringValue == "key" && $0["usage"]?.intValue == 25 } }, "A stale paste must never inject Cmd+V")
            await fixture.service.shutdown()
        }

        @Test(arguments: [false, true])
        func copyIgnoresLargeOldClipboardButChecksNewContent(oversizedSelection: Bool) async throws {
            let (fixture, identity, open) = try humanFixture()
            let tab = try await fixture.service.openPaneSimulator(open, expectedWorkspacePane: identity)
            let state = try #require(fixture.created.first)
            let surface = UUID()
            let acquired = try await fixture.service.controlSimulator(.init(
                sessionName: "work", tabID: tab.id, surfaceID: surface,
                controlID: nil, generation: nil, operation: .takeControl
            ), viewerID: "viewer")
            let reads = Mutex(0)
            let selected = oversizedSelection ? Data(repeating: 120, count: 400 * 1_024) : Data("selected 中文".utf8)
            fixture.connection.readClipboard.withLock {
                $0 = { request in
                    let attempt = reads.withLock { $0 += 1
                        return $0
                    }
                    // The first two polls after Cmd+C still see the oversized old snapshot.
                    let revision = attempt <= 3 ? "old" : "new"
                    if request["revisionOnly"]?.boolValue == true || request["afterRevision"]?.stringValue == revision {
                        return ["revision": .string(revision)]
                    }
                    let data = revision == "old" ? Data(repeating: 120, count: 400 * 1_024) : selected
                    guard data.count <= WorkspaceClipboardContent.maximumBytes else {
                        throw NSError(domain: "ClipboardTests", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Simulator clipboard exceeds 384 KiB",
                        ])
                    }
                    return ["revision": .string(revision), "content": .object([
                        "kind": .string("text"), "data": .string(data.base64EncodedString()),
                    ])]
                }
            }
            let request = ControlSimulator(
                sessionName: "work", tabID: tab.id, surfaceID: surface,
                controlID: acquired.controlID, generation: acquired.generation, operation: .copy
            )
            if oversizedSelection {
                await #expect(throws: (any Error).self) {
                    try await fixture.service.controlSimulator(request, viewerID: "viewer")
                }
                #expect(state.remoteControl == nil)
            } else {
                let response = try await fixture.service.controlSimulator(request, viewerID: "viewer")
                #expect(response.clipboard?.data == selected && response.clipboard?.kind == .text)
                #expect(state.remoteControl?.id == acquired.controlID)
            }
            let sent = fixture.connection.requests.withLock { $0 }
            let clipboardReads = sent.filter { $0["command"]?.stringValue == "clipboard-read" }
            #expect(clipboardReads.count == 4)
            #expect(clipboardReads.first?["revisionOnly"]?.boolValue == true)
            #expect(clipboardReads.dropFirst().allSatisfy { $0["afterRevision"]?.stringValue == "old" })
            #expect(sent.contains { $0["command"]?.stringValue == "key" && $0["usage"]?.intValue == 6 && $0["down"]?.boolValue == true })
            await fixture.service.shutdown()
        }

        @Test
        func viewerCreatesWithoutAgentAndRepeatedOpensReuse() async throws {
            let (fixture, identity, request) = try humanFixture()
            fixture.probe.agentUnavailable.withLock { $0 = true }
            let first = try await fixture.service.openPaneSimulator(request, expectedWorkspacePane: identity)
            let second = try await fixture.service.openPaneSimulator(request, expectedWorkspacePane: identity)
            #expect(first.id == second.id && fixture.boots == 1)
            let state = try #require(fixture.created.first)
            #expect(state.owner == nil && state.writer == nil)
            let preview = try await fixture.service.handleSimulator(BrowseSimulator(sessionName: "work", tabID: first.id))
            #expect(preview.tab.id == first.id && preview.frame.isValid)
            fixture.service.updateSimulatorRoutes([])
            #expect(state.isClosed && fixture.service.sharedSimulatorTabs.isEmpty)
            await fixture.service.shutdown()
        }

        @Test
        func viewerCanCreateAnotherDeviceForTheSamePane() async throws {
            let (fixture, identity, request) = try humanFixture()
            let first = try await fixture.service.openPaneSimulator(request, expectedWorkspacePane: identity)
            let second = try await fixture.service.openPaneSimulator(
                .init(sessionName: request.sessionName, sourcePaneID: request.sourcePaneID, createsNew: true),
                expectedWorkspacePane: identity
            )
            #expect(first.id != second.id && fixture.boots == 2)
            await fixture.service.shutdown()
        }

        @Test
        func simultaneousViewerOpensShareOneBoot() async throws {
            let (fixture, identity, request) = try humanFixture()
            fixture.probe.holdBoot.withLock { $0 = true }
            let first = Task { try await fixture.service.openPaneSimulator(request, expectedWorkspacePane: identity) }
            try await wait { fixture.boots == 1 }
            let second = Task { try await fixture.service.openPaneSimulator(request, expectedWorkspacePane: identity) }
            await Task.yield()
            fixture.probe.holdBoot.withLock { $0 = false }
            let a = try await first.value, b = try await second.value
            #expect(a.id == b.id && fixture.boots == 1)
            await fixture.service.shutdown()
        }

        @Test
        func viewerReusesAgentDeviceWithoutTakingOwnership() async throws {
            let (fixture, identity, request) = try humanFixture()
            #expect((await fixture.action("open")).ok)
            let state = try #require(fixture.created.first)
            let owner = state.owner
            let tab = try await fixture.service.openPaneSimulator(request, expectedWorkspacePane: identity)
            #expect(tab.id == state.id && state.owner == owner && state.writer == owner && fixture.boots == 1)
            await fixture.service.shutdown()
        }

        @Test
        func agentCannotAdoptHumanDefault() async throws {
            let (fixture, identity, request) = try humanFixture()
            let tab = try await fixture.service.openPaneSimulator(request, expectedWorkspacePane: identity)
            let state = try #require(fixture.created.first)
            let opened = await fixture.action("open")
            #expect(!opened.ok)
            #expect(state.owner == nil && state.writer == nil)
            for command in ["status", "claim", "close"] {
                #expect(!(await fixture.action(command, ["device": .string(tab.id.uuidString)])).ok)
            }
            #expect(!state.isClosed && fixture.boots == 1)
            let bypass = await fixture.action("open", ["new": .bool(true), "udid": .string(state.handle.udid)])
            #expect(!bypass.ok)
            let own = await fixture.action("open", ["new": .bool(true)])
            #expect(own.ok && own.result?["device"] != .string(tab.id.uuidString))
            let ownID = try #require(own.result?["device"])
            #expect((await fixture.action("status", ["device": ownID])).ok)
            #expect(!(await fixture.action("claim", ["device": ownID], peer: 20)).ok)
            let devices = await fixture.action("devices")
            guard case let .array(entries)? = devices.result?["devices"] else {
                throw SimulatorFailure("Missing device list")
            }
            #expect(entries.count == 1 && entries.first?.objectValue?["device"] == ownID)
            let reused = try await fixture.service.openPaneSimulator(request, expectedWorkspacePane: identity)
            #expect(reused.id == tab.id && state.owner == nil && state.writer == nil && fixture.boots == 2)
            let preview = try await fixture.service.handleSimulator(BrowseSimulator(sessionName: "work", tabID: tab.id))
            #expect(preview.frame.isValid)
            await fixture.service.shutdown()
        }

        @Test(arguments: [true, false])
        func concurrentHumanAndAgentOpenPreservesCreator(humanFirst: Bool) async throws {
            let (fixture, identity, request) = try humanFixture()
            fixture.probe.holdBoot.withLock { $0 = true }
            let human: Task<RemoteSimulatorTab, Error>
            let agent: Task<JSONRPCResponse, Never>
            if humanFirst {
                human = Task { try await fixture.service.openPaneSimulator(request, expectedWorkspacePane: identity) }
                try await wait { fixture.boots == 1 }
                agent = Task { await fixture.action("open") }
            } else {
                agent = Task { await fixture.action("open") }
                try await wait { fixture.boots == 1 }
                human = Task { try await fixture.service.openPaneSimulator(request, expectedWorkspacePane: identity) }
            }
            await Task.yield()
            fixture.probe.holdBoot.withLock { $0 = false }
            let tab = try await human.value
            let response = await agent.value
            let state = try #require(fixture.created.first)
            #expect(response.ok == !humanFirst)
            #expect((state.owner == nil) == humanFirst)
            #expect((state.writer == nil) == humanFirst)
            #expect(tab.id == state.id && fixture.boots == 1)
            await fixture.service.shutdown()
        }

        @Test
        func viewerRejectsMissingOrReplacedIdentityBeforeBoot() async throws {
            let (fixture, identity, request) = try humanFixture()
            await #expect(throws: (any Error).self) {
                try await fixture.service.openPaneSimulator(request, expectedWorkspacePane: nil)
            }
            fixture.pane = Fixture.pane(
                session: "work",
                window: 0,
                identity: .init(serverID: "replacement", sessionID: identity.sessionID, windowID: identity.windowID, paneID: identity.paneID)
            )
            await #expect(throws: (any Error).self) {
                try await fixture.service.openPaneSimulator(request, expectedWorkspacePane: identity)
            }
            #expect(fixture.boots == 0 && fixture.created.isEmpty)
            await fixture.service.shutdown()
        }

        @Test
        func paneReplacedDuringBootClosesUnpublishedDevice() async throws {
            let (fixture, identity, request) = try humanFixture()
            fixture.probe.holdBoot.withLock { $0 = true }
            let open = Task { try await fixture.service.openPaneSimulator(request, expectedWorkspacePane: identity) }
            try await wait { fixture.boots == 1 }
            fixture.pane = Fixture.pane(
                session: "work",
                window: 0,
                identity: .init(serverID: "replacement", sessionID: identity.sessionID, windowID: identity.windowID, paneID: UUID())
            )
            fixture.service.updateSimulatorRoutes([fixture.pane])
            fixture.probe.holdBoot.withLock { $0 = false }
            await #expect(throws: (any Error).self) { try await open.value }
            #expect(fixture.created.isEmpty && fixture.service.sharedSimulatorTabs.isEmpty)
            #expect(fixture.probe.calls.withLock { $0.contains { $0.contains("shutdown") } })
            await fixture.service.shutdown()
        }

        @Test
        func newerRouteSnapshotRejectsStaleSourceQuery() async throws {
            let (fixture, identity, request) = try humanFixture()
            let original = fixture.pane
            fixture.service.resolveSourcePane = { [unowned fixture] _, _ in
                fixture.service.updateSimulatorRoutes([])
                return original
            }
            await #expect(throws: (any Error).self) {
                try await fixture.service.openPaneSimulator(request, expectedWorkspacePane: identity)
            }
            #expect(fixture.boots == 0)
            await fixture.service.shutdown()
        }

        @Test
        func samePaneReusesAtCapacityButExplicitNewKeepsIndependentDevices() async throws {
            let fixture = try Fixture()
            let first = await fixture.action("open")
            let second = await fixture.action("open", ["new": .bool(true)])
            let reused = await fixture.action("open")
            #expect(first.ok && second.ok && reused.ok)
            #expect(first.result?["device"] == reused.result?["device"])
            #expect(first.result?["device"] != second.result?["device"])
            #expect(fixture.boots == 2 && fixture.created.count == 2)
            #expect(fixture.service.sharedSimulatorTabs.filter(\.isPrimary).count == 1)
            #expect(!(await fixture.action("open", ["profile": .string("balanced")])).ok)
            #expect(!(await fixture.action("open", peer: 20)).ok)
            await fixture.service.shutdown()
        }

        @Test
        func simultaneousDefaultOpensShareOneBoot() async throws {
            let fixture = try Fixture()
            fixture.probe.holdBoot.withLock { $0 = true }
            let first = Task { await fixture.action("open") }
            try await wait { fixture.boots == 1 }
            let second = Task { await fixture.action("open") }
            await Task.yield()
            fixture.probe.holdBoot.withLock { $0 = false }
            let a = await first.value, b = await second.value
            #expect(a.ok && b.ok && a.result?["device"] == b.result?["device"])
            #expect(fixture.boots == 1 && fixture.created.count == 1)
            await fixture.service.shutdown()
        }

        @Test
        func workspaceCanDetachAndAdoptTheSameLiveDevice() async throws {
            let fixture = try Fixture(attach: false)
            #expect((await fixture.action("open")).ok)
            let tab = try #require(fixture.service.sharedSimulatorTabs.first)
            #expect(fixture.created.isEmpty)
            fixture.service.register(fixture.workspace)
            let state = try #require(fixture.created.first)
            fixture.service.unregister(fixture.workspace)
            #expect(!state.isClosed && fixture.detached == [state.id])
            #expect(fixture.service.sharedSimulatorTabs.first?.id == tab.id)
            fixture.service.register(fixture.workspace)
            #expect(fixture.created.count == 2 && fixture.created[1] === state)
            #expect(fixture.service.sharedSimulatorTabs.first?.windowID == "@0")
            fixture.pane = Fixture.pane(session: "work", window: 0, stableID: "@9")
            fixture.service.updateSimulatorRoutes([fixture.pane])
            #expect(fixture.service.sharedSimulatorTabs.first?.windowID == "@9")
            #expect(fixture.detached == [state.id, state.id])
            #expect(fixture.created.count == 3 && fixture.created.last === state)
            fixture.pane = Fixture.pane(session: "moved", window: 2)
            fixture.service.updateSimulatorRoutes([fixture.pane])
            #expect(fixture.service.sharedSimulatorTabs.first?.sessionName == "moved")
            #expect(state.sourcePane.windowIndex == 2 && !state.isClosed)
            await fixture.service.shutdown()
        }

        @Test
        func closingDefaultClearsItsMapping() async throws {
            let fixture = try Fixture()
            let first = await fixture.action("open")
            let id = try #require(first.result?["device"])
            #expect((await fixture.action("close", ["device": id])).ok)
            let next = await fixture.action("open")
            #expect(next.ok && next.result?["device"] != id && fixture.boots == 2)
            await fixture.service.shutdown()
        }

        @Test(arguments: [false, true], [false, true])
        func sessionRenamePreservesWorkspaceTabs(migrateBeforeRoutes: Bool, split: Bool) async throws {
            try await verifySessionRename(migrateBeforeRoutes: migrateBeforeRoutes, split: split, openFirst: false)
        }

        @Test(arguments: [false, true])
        func ordinaryRefreshPublishesRenamedSimulatorBeforePreview(migrateBeforeRefresh: Bool) async throws {
            try await withDependencies {
                $0.continuousClock = .continuous
            } operation: {
                let tmuxPath = "/opt/homebrew/bin/tmux"
                try #require(FileManager.default.isExecutableFile(atPath: tmuxPath))
                let socket = "/tmp/ctrlx-route-\(UUID().uuidString.prefix(8)).sock"
                defer { try? FileManager.default.removeItem(atPath: socket) }
                let runner = ProcessRunner.liveValue
                func run(_ arguments: [String]) async throws -> ProcessResult {
                    try await runner.runOrThrow(
                        executable: tmuxPath,
                        arguments: ["-f", "/dev/null", "-S", socket] + arguments,
                        timeout: 5
                    )
                }
                let fixture = try Fixture()
                let queries = Mutex(0)
                let tmux = withDependencies {
                    $0[ProcessRunner.self] = ProcessRunner(run: { executable, arguments, environment, timeout in
                        if arguments.contains("list-panes") {
                            queries.withLock { $0 += 1 }
                        }
                        return try await runner.run(executable, arguments, environment, timeout)
                    })
                } operation: { TmuxService(tmuxPath: tmuxPath, socketPath: socket) }
                do {
                    _ = try await run(["new-session", "-d", "-s", "work", "/bin/sleep 60"])
                    fixture.pane = try #require(await tmux.refreshPanes().first)
                    let initialQueries = queries.withLock { $0 }
                    #expect((await fixture.action("open")).ok)
                    #expect((await fixture.action("open", ["new": .bool(true)])).ok)
                    let state = try #require(fixture.created.first)
                    let extra = try #require(fixture.created.last)
                    let tabs = try #require(fixture.sessionTabs["work"])
                    tabs.selectedBrowserTabId = extra.id
                    tabs.rightSide = [.browser(state.id)]
                    tabs.selectedRight = .browser(state.id)
                    let broadcasts = Mutex<[[RemoteSimulatorTab]]>([])
                    let windowManager = withDependencies {
                        $0[PreferencesService.self] = .inMemory()
                        $0[LoginItemService.self] = .previewValue
                    } operation: {
                        MirrorWindowManager(
                            settings: AppSettings(), tmuxService: tmux,
                            paneStreamManager: PaneStreamManager(tmuxService: tmux, controlClientManager: TmuxControlClientManager()),
                            editorSessionManager: EditorSessionManager()
                        )
                    }
                    windowManager.updatePaneStates(from: tmux.panes)
                    let publishedPanes = Mutex<[[String: PaneState]]>([])
                    AppCoordinator.wirePaneRefresh(tmuxService: tmux, windowManager: windowManager, agentSimulator: fixture.service) {
                        publishedPanes.withLock { $0.append(windowManager.paneStates) }
                        broadcasts.withLock { $0.append(fixture.service.sharedSimulatorTabs) }
                    }
                    let oldPane = fixture.pane
                    fixture.pane = Fixture.pane(
                        session: "renamed", window: oldPane.windowIndex,
                        stableID: oldPane.tmuxWindowId, paneID: oldPane.paneId,
                        identity: oldPane.workspaceIdentity
                    )
                    let rename = try #require(SessionRenameMapping.detect(from: [oldPane], to: [fixture.pane]).first)
                    if migrateBeforeRefresh {
                        SessionFileTabsState.migrateSession(rename, in: &fixture.sessionTabs)
                    }

                    // Bypass the app's rename/layout handlers; only ordinary discovery runs.
                    _ = try await run(["rename-session", "-t", "work", "renamed"])
                    let panes = await tmux.refreshPanes()
                    try await wait { broadcasts.withLock { !$0.isEmpty } }
                    if !migrateBeforeRefresh {
                        SessionFileTabsState.migrateSession(rename, in: &fixture.sessionTabs)
                    }

                    #expect(panes.count == 1 && panes.first?.sessionName == "renamed")
                    let published = broadcasts.withLock { $0 }
                    #expect(published.count == 1)
                    #expect(published.first?.count == 2)
                    #expect(published.first?.allSatisfy { $0.sessionName == "renamed" } == true)
                    #expect(publishedPanes.withLock { $0.first?.values.allSatisfy { $0.sessionName == "renamed" } } == true)
                    #expect(fixture.sessionTabs["renamed"] === tabs && fixture.sessionTabs["work"] == nil)
                    #expect(tabs.openBrowserTabs.map(\.id) == [state.id, extra.id])
                    #expect(tabs.selectedBrowserTabId == extra.id)
                    #expect(tabs.selectedRight == .browser(state.id) && tabs.rightSide == [.browser(state.id)])
                    #expect(fixture.detached.isEmpty && fixture.created.count == 2 && fixture.boots == 2)
                    let preview = try await fixture.service.handleSimulator(.init(sessionName: "renamed", tabID: state.id))
                    #expect(preview.tab.id == state.id && preview.tab.sessionName == "renamed" && preview.frame.isValid)
                    await #expect(throws: SimulatorFailure.self) {
                        try await fixture.service.handleSimulator(.init(sessionName: "work", tabID: state.id))
                    }
                    _ = await tmux.refreshPanes()
                    #expect(queries.withLock { $0 } == initialQueries + 2)
                    #expect(broadcasts.withLock { $0.count } == 1)

                    // Even an identity-only change must reach the Viewer before
                    // a new editor captures its target; the visible name is unchanged.
                    let replacementID = UUID()
                    _ = try await run(["set-option", "-t", "renamed", WorkspaceTmuxRecovery.sessionKey, replacementID.uuidString])
                    _ = await tmux.refreshPanes()
                    try await wait { publishedPanes.withLock { $0.count == 2 } }
                    #expect(publishedPanes.withLock { $0.last?.values.first?.workspaceIdentity?.sessionID } == replacementID)
                } catch {
                    await fixture.service.shutdown()
                    _ = try? await run(["kill-server"])
                    throw error
                }
                await fixture.service.shutdown()
                _ = try await run(["kill-server"])
            }
        }

        @Test(arguments: [false, true], [false, true])
        func openBeforeRouteRefreshPreservesRenamedWorkspaceTabs(migrateBeforeRoutes: Bool, split: Bool) async throws {
            try await verifySessionRename(migrateBeforeRoutes: migrateBeforeRoutes, split: split, openFirst: true)
        }

        private func verifySessionRename(migrateBeforeRoutes: Bool, split: Bool, openFirst: Bool) async throws {
            let fixture = try Fixture()
            let first = await fixture.action("open")
            let extra = await fixture.action("open", ["new": .bool(true)])
            #expect(first.ok && extra.ok)
            let state = try #require(fixture.created.first)
            let extraState = try #require(fixture.created.last)
            let tabs = try #require(fixture.sessionTabs["work"])
            tabs.selectedBrowserTabId = split ? nil : state.id
            if split {
                tabs.rightSide = [.browser(state.id)]
                tabs.selectedRight = .browser(state.id)
            }
            tabs.tabOrder = [.window(fixture.pane.windowId), .browser(state.id), .browser(extraState.id)]
            let oldPane = fixture.pane
            fixture.pane = Fixture.pane(session: "renamed", window: 0)
            let rename = try #require(SessionRenameMapping.detect(from: [oldPane], to: [fixture.pane]).first)

            if migrateBeforeRoutes {
                SessionFileTabsState.migrateSession(rename, in: &fixture.sessionTabs)
            }
            if openFirst {
                let reused = await fixture.action("open")
                #expect(reused.ok && reused.result?["device"] == first.result?["device"])
            }
            fixture.service.updateSimulatorRoutes([fixture.pane])
            SessionFileTabsState.migrateSession(rename, in: &fixture.sessionTabs)
            fixture.service.register(fixture.workspace)

            #expect(fixture.sessionTabs["work"] == nil)
            #expect(fixture.sessionTabs["renamed"] === tabs)
            #expect(tabs.simulatorStates[state.id] === state)
            #expect(tabs.simulatorStates[extraState.id] === extraState)
            #expect(tabs.openBrowserTabs.map(\.id) == [state.id, extraState.id])
            #expect(tabs.openBrowserTabs.allSatisfy { $0.originWindowId == "renamed:0" })
            #expect(tabs.tabOrder == [.window("renamed:0"), .browser(state.id), .browser(extraState.id)])
            #expect(tabs.selectedBrowserTabId == (split ? nil : state.id))
            #expect(tabs.selectedRight == (split ? .browser(state.id) : nil))
            #expect(tabs.rightSide == (split ? [.browser(state.id)] : []))
            #expect(fixture.detached.isEmpty && fixture.created.count == 2)
            #expect(!state.isClosed && state.workspaceID == fixture.workspace.id)
            #expect(fixture.service.sharedSimulatorTabs.allSatisfy { $0.sessionName == "renamed" })
            #expect((await fixture.action("show", ["device": .string(state.id.uuidString)])).ok)
            let reopened = await fixture.action("open")
            #expect(reopened.ok && reopened.result?["device"] == first.result?["device"])
            #expect(reopened.result?["udid"] == first.result?["udid"] && fixture.boots == 2)
            #expect(tabs.simulatorStates[state.id] === state)
            await fixture.service.shutdown()
        }

        @Test(arguments: [false, true], [false, true])
        func windowReindexPreservesWorkspaceTabs(remapBeforeRoutes: Bool, openFirst: Bool) async throws {
            let fixture = try Fixture()
            let oldPanes = [fixture.pane, Fixture.pane(session: "work", window: 3, paneID: "%2")]
            fixture.otherPanes = Array(oldPanes.dropFirst())
            fixture.service.updateSimulatorRoutes(oldPanes)
            let opened = await fixture.action("open")
            #expect(opened.ok)
            #expect((await fixture.action("open", ["new": .bool(true)])).ok)
            let state = try #require(fixture.created.first)
            let extra = try #require(fixture.created.last)
            let tabs = try #require(fixture.sessionTabs["work"])
            tabs.selectedBrowserTabId = extra.id
            tabs.rightSide = [.browser(state.id)]
            tabs.selectedRight = .browser(state.id)
            tabs.tabOrder = [.window("@0"), .browser(state.id), .browser(extra.id)]
            let originalOrder = tabs.tabOrder
            fixture.pane = Fixture.pane(session: "work", window: 3, stableID: "@0")
            let newPanes = [fixture.pane, Fixture.pane(session: "work", window: 0, stableID: "@3", paneID: "%2")]
            fixture.otherPanes = Array(newPanes.dropFirst())
            let mapping = WindowReindexMapping.detect(from: oldPanes, to: newPanes)
            #expect(mapping == ["work:0": "work:3", "work:3": "work:0"])

            if remapBeforeRoutes {
                tabs.remapWindowIDs(mapping)
            }
            if openFirst {
                let reused = await fixture.action("open")
                #expect(reused.ok && reused.result?["device"] == opened.result?["device"])
            }
            fixture.service.updateSimulatorRoutes(newPanes)
            if !remapBeforeRoutes {
                tabs.remapWindowIDs(mapping)
            }

            #expect(fixture.sessionTabs["work"] === tabs)
            #expect(tabs.simulatorStates[state.id] === state && tabs.simulatorStates[extra.id] === extra)
            #expect(tabs.openBrowserTabs.map(\.id) == [state.id, extra.id])
            #expect(tabs.openBrowserTabs.allSatisfy { $0.originWindowId == "work:3" })
            #expect(state.sourcePane.windowId == "work:3" && extra.sourcePane.windowId == "work:3")
            #expect(tabs.tabOrder == originalOrder)
            #expect(tabs.selectedBrowserTabId == extra.id)
            #expect(tabs.selectedRight == .browser(state.id))
            #expect(tabs.rightSide == [.browser(state.id)] && tabs.isSplit)
            #expect(fixture.detached.isEmpty && fixture.created.count == 2 && fixture.boots == 2)
            #expect(!state.isClosed && !extra.isClosed && state.workspaceID == fixture.workspace.id)
            #expect((await fixture.action("show", ["device": .string(state.id.uuidString)])).ok)
            #expect(tabs.selectedRight == .browser(state.id) && tabs.selectedBrowserTabId == extra.id)
            await fixture.service.shutdown()
        }

        @Test(arguments: [false, true])
        func movingPaneToAnotherSessionStillReattachesItsTab(openFirst: Bool) async throws {
            let fixture = try Fixture()
            let otherPane = Fixture.pane(session: "work", window: 1, paneID: "%2")
            fixture.otherPanes = [otherPane]
            fixture.service.updateSimulatorRoutes([fixture.pane, otherPane])
            #expect((await fixture.action("open")).ok)
            let state = try #require(fixture.created.first)
            let oldTabs = try #require(fixture.sessionTabs["work"])
            fixture.pane = Fixture.pane(session: "other", window: 0)
            if openFirst {
                #expect((await fixture.action("open")).ok)
            }
            fixture.service.updateSimulatorRoutes([fixture.pane, otherPane])

            #expect(fixture.detached == [state.id])
            #expect(oldTabs.simulatorStates.isEmpty && oldTabs.openBrowserTabs.isEmpty)
            #expect(fixture.sessionTabs["other"]?.simulatorStates[state.id] === state)
            #expect(fixture.created.count == 2 && fixture.created.last === state)
            #expect(fixture.boots == 1 && !state.isClosed)
            await fixture.service.shutdown()
        }

        @Test
        func shutdownCancelsDefaultBootAndCannotPublishALateTab() async throws {
            let fixture = try Fixture()
            fixture.probe.holdBoot.withLock { $0 = true }
            let opening = Task { await fixture.action("open") }
            try await wait { fixture.boots == 1 }
            await fixture.service.shutdown()
            #expect(!(await opening.value).ok)
            #expect(fixture.service.sharedSimulatorTabs.isEmpty && fixture.created.isEmpty)
        }

        @Test
        func previewCoalescesWithoutTakingControlAndRejectsMovedOrClosedDevices() async throws {
            let fixture = try Fixture()
            #expect((await fixture.action("open")).ok)
            let state = try #require(fixture.created.first)
            let writer = state.writer
            let request = BrowseSimulator(sessionName: "work", tabID: state.id)
            fixture.connection.hold.withLock { $0 = true }
            let first = Task { try await fixture.service.handleSimulator(request) }
            try await wait { fixture.connection.replies.withLock { $0.count == 1 } }
            let second = Task { try await fixture.service.handleSimulator(request) }
            await Task.yield()
            fixture.connection.release()
            let a = try await first.value, b = try await second.value
            #expect(a == b && state.writer == writer)
            #expect(fixture.connection.commands.withLock { $0.filter { $0 == "preview" }.count } == 1)
            await #expect(throws: SimulatorFailure.self) {
                try await fixture.service.handleSimulator(.init(sessionName: "wrong", tabID: state.id))
            }
            await #expect(throws: SimulatorFailure.self) {
                try await fixture.service.handleSimulator(.init(sessionName: "work", tabID: state.id, frameMaxDimension: 9_999))
            }
            fixture.connection.hold.withLock { $0 = true }
            let late = Task { try await fixture.service.handleSimulator(request) }
            try await wait { fixture.connection.replies.withLock { $0.count == 1 } }
            fixture.service.close(state)
            fixture.connection.release()
            await #expect(throws: (any Error).self) { try await late.value }
            await fixture.service.shutdown()
        }

        @Test
        func agentScreenshotDrainsPreviewAndBlocksNewCaptures() async throws {
            let fixture = try Fixture()
            #expect((await fixture.action("open")).ok)
            let state = try #require(fixture.created.first)
            let writer = state.writer
            let request = BrowseSimulator(sessionName: "work", tabID: state.id)
            fixture.connection.hold.withLock { $0 = true }
            let preview = Task { try await fixture.service.handleSimulator(request) }
            try await wait { fixture.connection.replies.withLock { $0.count == 1 } }
            let screenshot = Task { await fixture.action("screenshot", ["device": .string(state.id.uuidString)]) }
            // Let the screenshot reach the suspended capture before admitting another Viewer.
            try await Task.sleep(for: .milliseconds(20))
            #expect(!fixture.connection.commands.withLock { $0.contains("screenshot") })
            await #expect(throws: SimulatorFailure.self) { try await fixture.service.handleSimulator(request) }
            fixture.connection.release()
            _ = try await preview.value
            #expect((await screenshot.value).ok)
            #expect(fixture.connection.commands.withLock { $0.filter { ["preview", "screenshot"].contains($0) } } == ["preview", "screenshot"])
            #expect(state.writer == writer)
            await fixture.service.shutdown()
        }

        @Test
        func annotationUsesReadOnlyPreviewWithoutTakingAgentControl() async throws {
            let fixture = try Fixture()
            #expect((await fixture.action("open")).ok)
            let state = try #require(fixture.created.first)
            let writer = state.writer
            let generation = state.generation
            let inputRevision = state.manualInputRevision
            let commandCount = fixture.connection.commands.withLock { $0.count }
            #expect(!state.hasPresentedFrame)
            state.view.onFirstFrame()
            #expect(state.hasPresentedFrame)
            state.view.setInputSuppressed(true)
            let screenshot = try await fixture.service.annotationScreenshot(state)
            state.view.setInputSuppressed(false)
            #expect(screenshot == Data([1]))
            #expect(state.writer == writer && writer != nil)
            #expect(state.generation == generation && state.manualInputRevision == inputRevision)
            #expect(fixture.connection.commands.withLock { Array($0.dropFirst(commandCount)) } == ["preview"])
            let request = try #require(fixture.connection.requests.withLock { $0.last })
            #expect(request["readOnly"] == .bool(true))
            #expect(request["maximumDimension"] == .int(RemoteSimulatorFrame.maximumDimension))
            await fixture.service.shutdown()
        }

        @Test(arguments: ["window", "session", "close", "cancel"])
        func annotationRejectsLateCapturesAfterSourceChanges(_ change: String) async throws {
            let fixture = try Fixture()
            #expect((await fixture.action("open")).ok)
            let state = try #require(fixture.created.first)
            fixture.connection.hold.withLock { $0 = true }
            let capture = Task { try await fixture.service.annotationScreenshot(state) }
            try await wait { fixture.connection.replies.withLock { $0.count == 1 } }
            switch change {
            case "window",
                 "session":
                fixture.pane = Fixture.pane(session: change == "session" ? "moved" : "work", window: 2)
                fixture.service.updateSimulatorRoutes([fixture.pane])
            case "close": fixture.service.close(state)
            default: capture.cancel()
            }
            fixture.connection.release()
            await #expect(throws: (any Error).self) { try await capture.value }
            await fixture.service.shutdown()
        }

        @Test
        func noisyPreviewShrinksToTheWireBudget() throws {
            let surface = try #require(IOSurfaceCreate([
                kIOSurfaceWidth: 2_048, kIOSurfaceHeight: 2_048, kIOSurfaceBytesPerElement: 4,
                kIOSurfaceBytesPerRow: 8_192, kIOSurfacePixelFormat: 0x42475241,
            ] as CFDictionary))
            IOSurfaceLock(surface, [], nil)
            let pixels = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt32.self)
            var random: UInt32 = 1
            for index in 0..<(2_048 * 2_048) {
                random = random &* 1_664_525 &+ 1_013_904_223
                pixels[index] = random | 0xFF000000
            }
            IOSurfaceUnlock(surface, [], nil)
            let result = try #require(CXSimulatorCreatePreview(surface, 1, 2_560))
            let encoded = try #require(result["data"] as? String)
            let bytes = try #require(Data(base64Encoded: encoded))
            #expect(bytes.count <= RemoteSimulatorFrame.maximumBytes)
            #expect((result["width"] as? Int ?? 0) < 2_048)
        }

        @Test(arguments: [1, 2, 3, 4])
        func nativePreviewRespectsOrientationBoundsAndNeverUpscales(_ orientation: Int32) throws {
            let surface = try #require(IOSurfaceCreate([
                kIOSurfaceWidth: 400, kIOSurfaceHeight: 800, kIOSurfaceBytesPerElement: 4,
                kIOSurfaceBytesPerRow: 1_600, kIOSurfacePixelFormat: 0x42475241,
            ] as CFDictionary))
            let result = try #require(CXSimulatorCreatePreview(surface, orientation, 2_560))
            let encoded = try #require(result["data"] as? String)
            let data = try #require(Data(base64Encoded: encoded))
            #expect(data.count <= RemoteSimulatorFrame.maximumBytes)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == (orientation >= 3 ? 800 : 400))
            #expect(image.height == (orientation >= 3 ? 400 : 800))
            let thumbnail = try #require(CXSimulatorCreatePreview(surface, orientation, 256))
            #expect(max(thumbnail["width"] as? Int ?? 0, thumbnail["height"] as? Int ?? 0) == 256)
            #expect(CXSimulatorCreatePreview(surface, orientation, 9_999) == nil)
        }
    }
#endif
