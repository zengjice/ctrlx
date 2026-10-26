import ConcurrencyExtras
import CryptoKit
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
import Vapor
@testable import CtrlxCommon
@testable import CtrlxServerFeature

@MainActor
@Suite("File requests across Viewer reconnects", .serialized)
struct FileBrowserConnectionTests {
    @Test("Source-bound Files replies are rejected after Host reconstruction", arguments: [
        FileBrowserOperation.tabs(.open(sessionName: "test", new: false)),
        .list(path: nil, offset: 0, includeHidden: false),
        .repositoryInfo(path: "README.md", context: .init(pluginID: "codex", sessionID: "conversation", projectDirectory: "/Host/old")),
    ])
    func retiredFilesOpen(operation: FileBrowserOperation) async throws {
        let originalVersion = VersionCompatibility.appVersionOverride
        VersionCompatibility.appVersionOverride = "3.0.75"
        defer { VersionCompatibility.appVersionOverride = originalVersion }
        let relay = PhraseTestRelay()
        let app = try await Application.make(.testing)
        app.webSocket("api", "ws", maxFrameSize: .init(integerLiteral: RelayPayloadLimits.maxWebSocketFrameBytes)) { _, ws in
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
            let host = ConnectedViewer(pairedViewer: .init(
                id: "pair", deviceName: "Viewer", partnerPublicKey: viewerEncryption.publicKey.base64EncodedString(), partnerPublicKeyId: viewerEncryption.keyId
            ), e2eeService: hostEncryption)
            let connection = ViewerConnection(pairedDevice: .init(
                id: "pair", hostName: "Host", username: "test", partnerPublicKey: hostEncryption.publicKey.base64EncodedString(), partnerPublicKeyId: hostEncryption.keyId
            ), e2eeService: viewerEncryption)
            let viewer = connection.relayClient
            let hostID = UUID()
            let original = WorkspacePaneIdentity(serverID: "100:1", sessionID: UUID(), windowID: UUID(), paneID: UUID())
            let current = LockIsolated(original)
            let staleTab = HostFileTab(sessionName: "test", windowID: "@1", sourcePaneID: "%7", initialDirectory: "/Host/old")
            let (gate, release) = AsyncStream<Void>.makeStream()
            defer { release.finish() }
            var commands = 0
            host.onSessionStateRequest = {
                .init(
                    pairId: "",
                    paneStates: ["%7": .init(
                        paneId: "%7", sessionName: "test", tmuxWindowId: "@1", workspaceIdentity: current.value
                    )],
                    supportsFileBrowsing: true,
                    supportsRepositoryFileLinks: true,
                    supportsPaneFiles: true,
                    fileTabs: [],
                    workspaceIdentity: .init(hostID: hostID, serverID: current.value.serverID),
                    supportsWorkspaceInputIdentity: true
                )
            }
            host.onCommand = { command in
                guard case let .browseFiles(spec) = command.command else {
                    Issue.record("Unexpected command")
                    return .failure(for: command.id, error: "Unexpected command")
                }
                #expect(command.expectedWorkspacePane == (spec.operation.usesSourcePane ? original : nil))
                commands += 1
                for await _ in gate {
                    break
                }
                let files: FileBrowserResponse = switch spec.operation {
                case .tabs: .tab(staleTab)
                case .list: .listing(.init(directory: "/Host/old", homeDirectory: "/Host", entries: [], nextOffset: nil, revision: "1"))
                default: .info(.init(path: "/Host/old/README.md", name: "README.md", kind: .text, size: 0, revision: "1"))
                }
                return .init(commandId: command.id, success: true, fileBrowser: files)
            }
            await host.connect(serverURL: url, deviceId: "host", deviceName: "Host", username: "test", publicKey: hostEncryption.publicKey.base64EncodedString(), publicKeyId: hostEncryption.keyId)
            do {
                await connect(viewer, url: url, encryption: viewerEncryption, hostEncryption: hostEncryption)
                try await waitUntil { host.isViewerConnected && viewer.hostSupportsPaneFiles }
                let source = FileBrowserSource.remote(hostID: "pair", paneID: "%7", connection: connection)
                let pending = Task {
                    if case .tabs = operation {
                        return try await FileBrowserResponse.tab(HostFileTabClient.open(connection: connection, sessionName: "test", paneID: "%7"))
                    }
                    return try await source.request(operation)
                }
                defer { pending.cancel() }
                try await waitUntil { commands == 1 }
                let rebuilt = WorkspacePaneIdentity(serverID: "200:2", sessionID: original.sessionID, windowID: original.windowID, paneID: original.paneID)
                current.setValue(rebuilt)
                await host.pushSessionState()
                try await waitUntil { viewer.workspaceInputState.catalog?.scope.serverID == rebuilt.serverID }
                release.finish()
                await #expect(throws: (any Error).self) { try await pending.value }
                #expect(viewer.fileTabs.isEmpty)
                // A file-link path lookup may finish only after reconstruction.
                // Its original binding must reject the open before transmission.
                await #expect(throws: (any Error).self) {
                    if case .tabs = operation {
                        _ = try await HostFileTabClient.open(connection: connection, sessionName: "test", paneID: "%7", inputBinding: .pane(pairID: "pair", hostID: hostID, identity: original))
                    } else {
                        _ = try await source.request(operation)
                    }
                }
                #expect(commands == 1)
                // Browsing an explicit path remains useful after its terminal exits.
                _ = try await source.request(.info(path: "/Host/old/README.md"))
                #expect(commands == 2)
                #expect(await relay.errors.isEmpty)
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

    @Test
    func browserCapabilitySlowFramesAndReconnect() async throws {
        let originalVersion = VersionCompatibility.appVersionOverride
        VersionCompatibility.appVersionOverride = "3.0.51"
        defer { VersionCompatibility.appVersionOverride = originalVersion }
        #expect(ConnectedViewer.canCaptureBrowserFrame(.empty))
        #expect(!ConnectedViewer.canCaptureBrowserFrame(.init(depth: 3, oldestWaitMilliseconds: 1)))
        #expect(!ConnectedViewer.canCaptureBrowserFrame(.init(depth: 1, oldestWaitMilliseconds: 100)))
        let relay = PhraseTestRelay()
        let app = try await Application.make(.testing)
        app.webSocket("api", "ws", maxFrameSize: .init(integerLiteral: RelayPayloadLimits.maxWebSocketFrameBytes)) { _, ws in
            ws.onBinary { ws, bytes in
                let data = Data(bytes.readableBytesView)
                Task { await relay.receive(data, from: ws) }
            }
            ws.onClose.whenComplete { _ in Task { await relay.closed(ws) } }
        }
        try await app.asyncBoot()
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        do {
            let port = try #require(app.http.server.shared.localAddress?.port)
            let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
            let hostEncryption = try await encryption(), viewerEncryption = try await encryption()
            let host = ConnectedViewer(
                pairedViewer: .init(
                    id: "pair",
                    deviceName: "Viewer",
                    partnerPublicKey: viewerEncryption.publicKey.base64EncodedString(),
                    partnerPublicKeyId: viewerEncryption.keyId
                ),
                e2eeService: hostEncryption
            )
            let connection = ViewerConnection(pairedDevice: .init(
                id: "pair", hostName: "Host", username: "test",
                partnerPublicKey: hostEncryption.publicKey.base64EncodedString(), partnerPublicKeyId: hostEncryption.keyId
            ), e2eeService: viewerEncryption)
            let viewer = connection.relayClient
            let enabled = LockIsolated(false)
            let browserAudioEnabled = LockIsolated(false)
            let paneBrowserEnabled = LockIsolated(false)
            let paneFilesEnabled = LockIsolated(false)
            let filesClosed = LockIsolated(false)
            let rejectClose = LockIsolated(true)
            let fileTab = HostFileTab(sessionName: "test", windowID: "@1", sourcePaneID: "%7", initialDirectory: "/Host")
            var held: [CheckedContinuation<Void, Never>] = []
            var cancelled = 0
            var input = false
            defer { for continuation in held {
                continuation.resume()
            } }
            host.onSessionStateRequest = {
                .init(
                    pairId: "",
                    paneStates: [:],
                    supportsFileBrowsing: true,
                    supportsBrowserAudio: browserAudioEnabled.value ? true : nil,
                    supportsBrowserSharing: enabled.value ? true : nil,
                    supportsPaneBrowser: paneBrowserEnabled.value ? true : nil,
                    supportsPaneFiles: paneFilesEnabled.value ? true : nil,
                    fileTabs: paneFilesEnabled.value ? (filesClosed.value ? [] : [fileTab]) : nil
                )
            }
            host.onCommand = { command in
                if case let .browseFiles(spec) = command.command, case let .tabs(operation) = spec.operation {
                    if case .close = operation, !rejectClose.value {
                        filesClosed.setValue(true)
                        return .init(commandId: command.id, success: true, fileBrowser: .tabClosed)
                    }
                    return .init(commandId: command.id, success: true, fileBrowser: .tab(fileTab))
                }
                if case let .browseBrowser(spec) = command.command, spec.operation == .frame {
                    await withCheckedContinuation { held.append($0) }
                    if Task.isCancelled {
                        cancelled += 1
                    }
                }
                if case .sendKeystroke = command.command {
                    input = true
                }
                return .init(commandId: command.id, success: true, browser: .init())
            }
            await host.connect(
                serverURL: url,
                deviceId: "host",
                deviceName: "Host",
                username: "test",
                publicKey: hostEncryption.publicKey.base64EncodedString(),
                publicKeyId: hostEncryption.keyId
            )
            do {
                await connect(viewer, url: url, encryption: viewerEncryption, hostEncryption: hostEncryption)
                // Count only after the initial capability snapshot, not while it is in flight.
                try await waitUntil { host.isViewerConnected && viewer.hostSupportsFileBrowsing }
                let command = BrowseBrowser(sessionName: "test", surfaceID: UUID(), operation: .frame)
                let frames = await relay.encryptedFrames
                let rejected = await viewer.sendCommand(command, paneId: "")
                if case .success = rejected {
                    Issue.record("Legacy Host accepted browser input")
                }
                #expect(await relay.encryptedFrames == frames)
                let legacyAudio = await viewer.sendCommand(BrowseBrowser(sessionName: "test", surfaceID: UUID(), operation: .audio(streamID: UUID(), revision: 1, enabled: true)), paneId: "")
                if case .success = legacyAudio {
                    Issue.record("Legacy Host accepted audio")
                }
                #expect(await relay.encryptedFrames == frames)
                enabled.setValue(true)
                await host.pushSessionState()
                try await waitUntil { viewer.hostSupportsBrowserSharing }
                let beforeAudio = await relay.encryptedFrames
                let unsupportedAudio = await viewer.sendCommand(BrowseBrowser(sessionName: "test", surfaceID: UUID(), operation: .audio(streamID: UUID(), revision: 1, enabled: true)), paneId: "")
                if case .success = unsupportedAudio {
                    Issue.record("Browser-sharing-only Host accepted audio")
                }
                #expect(await relay.encryptedFrames == beforeAudio)
                browserAudioEnabled.setValue(true)
                await host.pushSessionState()
                try await waitUntil { viewer.hostSupportsBrowserAudio }
                let streamID = UUID()
                var receivedAudio: [RemoteBrowserAudio] = []
                viewer.registerBrowserAudio(streamID) { receivedAudio.append($0) }
                let audio = RemoteBrowserAudio(
                    tabID: UUID(),
                    surfaceID: UUID(),
                    controlID: UUID(),
                    streamID: streamID,
                    sequence: 1,
                    packets: [Data(repeating: 255, count: 4_096)]
                )
                let relayViewer = try #require(await relay.viewer)
                try await relayViewer.send(raw: JSONEncoder().encode(WebSocketMessage.browserAudio(audio)), opcode: .binary)
                try await Task.sleep(for: .milliseconds(20))
                #expect(receivedAudio.isEmpty)
                await host.sendBrowserAudio(audio)
                try await waitUntil { receivedAudio.count == 1 }
                #expect(receivedAudio == [audio])
                viewer.unregisterBrowserAudio(streamID)
                await host.sendBrowserAudio(audio)
                try await Task.sleep(for: .milliseconds(20))
                #expect(receivedAudio.count == 1)
                let open = BrowseBrowser(sessionName: "test", surfaceID: UUID(), operation: .openPane(url: nil), sourcePaneID: "%7")
                let legacyOpen = await viewer.sendCommand(open, paneId: "")
                if case .success = legacyOpen {
                    Issue.record("Browser-sharing-only Host accepted pane open")
                }
                #expect(!viewer.hostSupportsPaneBrowser)
                paneBrowserEnabled.setValue(true)
                await host.pushSessionState()
                try await waitUntil { viewer.hostSupportsPaneBrowser }
                #expect(try await viewer.sendCommand(open, paneId: "").get().success)
                let openFiles = BrowseFiles(.tabs(.open(sessionName: "test", new: false)))
                let beforeFiles = await relay.encryptedFrames
                if case .success = await viewer.sendCommand(openFiles, paneId: "%7") {
                    Issue.record("Old Host accepted shared Files")
                }
                #expect(await relay.encryptedFrames == beforeFiles)
                paneFilesEnabled.setValue(true)
                await host.pushSessionState()
                try await waitUntil { viewer.hostSupportsPaneFiles }
                #expect(viewer.fileTabs == [fileTab])
                #expect(try await viewer.sendCommand(openFiles, paneId: "%7").get().fileBrowser == .tab(fileTab))
                let requests = (0..<4).map { _ in Task { await viewer.sendCommand(command, paneId: "") } }
                defer { requests.forEach { $0.cancel() } }
                try await waitUntil { held.count == 4 }
                _ = await viewer.sendCommand(SendKeystroke([.text("typing")]), paneId: "%7")
                try await waitUntil { input }
                #expect(cancelled == 0, "Keyboard must not wait for browser capture")
                await viewer.disconnect()
                #expect(!viewer.hostSupportsBrowserSharing)
                #expect(!viewer.hostSupportsPaneBrowser)
                #expect(!viewer.hostSupportsPaneFiles)
                #expect(viewer.fileTabs == [fileTab], "Transient disconnect must not erase Host identities")
                try await waitUntil { !host.isViewerConnected }
                for request in requests {
                    _ = await request.value
                }
                await connect(viewer, url: url, encryption: viewerEncryption, hostEncryption: hostEncryption)
                try await waitUntil { viewer.hostSupportsBrowserSharing && host.isViewerConnected }
                let fresh = await viewer.sendCommand(BrowseBrowser(sessionName: "test", surfaceID: UUID(), operation: .create), paneId: "")
                #expect(try fresh.get().success, "Disconnected captures must free request slots")
                let old = held
                held.removeAll()
                old.forEach { $0.resume() }
                try await waitUntil { cancelled == 4 }
                await #expect(throws: FileBrowserError.self) {
                    try await HostFileTabClient.close(connection: connection, id: fileTab.id)
                }
                #expect(viewer.fileTabs == [fileTab], "An unconfirmed close must retain the tab")
                rejectClose.setValue(false)
                try await HostFileTabClient.close(connection: connection, id: fileTab.id)
                #expect(viewer.fileTabs.isEmpty, "Confirmed close must update the catalog without waiting for its snapshot")
                #expect(await relay.errors.isEmpty)
                #expect(await relay.unexpectedTypes.isEmpty)
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

    @Test("Downloads and app updates leave keyboard input responsive", arguments: [false, true])
    func backgroundRequestsLeaveKeyboardCommandsResponsive(duringAppUpdate: Bool) async throws {
        let originalVersion = VersionCompatibility.appVersionOverride
        VersionCompatibility.appVersionOverride = "3.0.43"
        defer { VersionCompatibility.appVersionOverride = originalVersion }
        let relay = PhraseTestRelay()
        let app = try await Application.make(.testing)
        app.webSocket("api", "ws", maxFrameSize: .init(integerLiteral: RelayPayloadLimits.maxWebSocketFrameBytes)) { _, ws in
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
                pairedViewer: .init(
                    id: "pair",
                    deviceName: "Viewer",
                    partnerPublicKey: viewerEncryption.publicKey.base64EncodedString(),
                    partnerPublicKeyId: viewerEncryption.keyId
                ), e2eeService: hostEncryption
            )
            let viewer = ViewerRelayClient()
            let block = FileBrowserLimits.chunkBytes
            let info = FileBrowserEntry(
                path: "/Host/movie.mp4",
                name: "movie.mp4",
                kind: .unsupported,
                size: 2 * block + 13,
                revision: "1"
            )
            let (gate, release) = AsyncStream<Void>.makeStream()
            defer { release.finish() }
            var reading = false
            var replied = false
            var keysArrived = false
            host.onSessionStateRequest = { .init(pairId: "", paneStates: [:], supportsFileBrowsing: true, supportsFileDownloads: true, supportsCtrlXAppUpdate: true) }
            host.onCommand = { command in
                if case .installCtrlXAppUpdate = command.command {
                    reading = true
                    for await _ in gate {
                        break
                    }
                    replied = true
                    return .success(for: command.id)
                }
                if
                    case let .browseFiles(spec) = command.command,
                    case let .download(path, offset, revision) = spec.operation {
                    if offset == block, !duringAppUpdate {
                        reading = true
                        for await _ in gate {
                            break
                        }
                        replied = true
                    }
                    return .init(
                        commandId: command.id,
                        success: true,
                        fileBrowser: .chunk(.init(
                            path: path,
                            revision: revision,
                            offset: offset,
                            data: Data(repeating: 0xFF, count: min(block, info.size - offset))
                        ))
                    )
                }
                if case .sendKeystroke = command.command {
                    keysArrived = true
                }
                return .success(for: command.id)
            }
            await host.connect(
                serverURL: url,
                deviceId: "host",
                deviceName: "Host",
                username: "test",
                publicKey: hostEncryption.publicKey.base64EncodedString(),
                publicKeyId: hostEncryption.keyId
            )
            do {
                await connect(viewer, url: url, encryption: viewerEncryption, hostEncryption: hostEncryption)
                try await waitUntil { host.isViewerConnected && viewer.hostSupportsFileDownloads }
                let source = FileBrowserSource(id: "remote", paneID: "%7") { operation in
                    let response = try await viewer.sendCommand(BrowseFiles(operation), paneId: "%7").get()
                    return try #require(response.fileBrowser)
                }
                let reader = try FileBrowserVideoReader(info: info, source: source)
                let request = Task {
                    if duringAppUpdate {
                        _ = try await viewer.sendCommand(InstallCtrlXAppUpdate(version: "3.0.99", build: "32"), paneId: "", timeout: InstallCtrlXAppUpdate.responseTimeout).get()
                    }
                    return try await reader.read(offset: block + 7, length: 4)
                }
                defer { request.cancel() }
                try await waitUntil { reading }
                _ = await viewer.sendCommand(SendKeystroke([.text("test")]), paneId: "%7")
                try await waitUntil { keysArrived }
                #expect(!replied, "Keyboard input must arrive before a blocked download or app update completes")
                release.yield()
                #expect(try await request.value == Data(repeating: 0xFF, count: 4))
                #expect(try await reader.read(offset: info.size - 2, length: 8) == Data(repeating: 0xFF, count: 2))
                #expect(reader.cachedBytes == block + 13)
                #expect(await relay.errors.isEmpty)
                #expect(await relay.unexpectedTypes.isEmpty)
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

    @Test
    func viewerDisconnectFreesSlotsBeforeOldIOFinishes() async throws {
        let uploadRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-wire-upload-\(UUID())")
        try FileManager.default.createDirectory(at: uploadRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: uploadRoot) }
        let uploadID = UUID()
        let originalVersion = VersionCompatibility.appVersionOverride
        VersionCompatibility.appVersionOverride = "3.0.43"
        defer { VersionCompatibility.appVersionOverride = originalVersion }
        let relay = PhraseTestRelay()
        let app = try await Application.make(.testing)
        app.webSocket("api", "ws", maxFrameSize: .init(integerLiteral: RelayPayloadLimits.maxWebSocketFrameBytes)) { _, ws in
            ws.onBinary { ws, bytes in
                let data = Data(bytes.readableBytesView)
                Task { await relay.receive(data, from: ws) }
            }
            ws.onClose.whenComplete { _ in Task { await relay.closed(ws) } }
        }
        try await app.asyncBoot()
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        do {
            let port = try #require(app.http.server.shared.localAddress?.port)
            let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
            let hostEncryption = try await encryption(), viewerEncryption = try await encryption()
            let host = ConnectedViewer(
                pairedViewer: .init(
                    id: "pair",
                    deviceName: "Viewer",
                    partnerPublicKey: viewerEncryption.publicKey.base64EncodedString(),
                    partnerPublicKeyId: viewerEncryption.keyId
                ),
                e2eeService: hostEncryption
            )
            let viewer = ViewerRelayClient()
            var waiters: [CheckedContinuation<Void, Never>] = []
            var finishedCancelled: [Bool] = []
            let downloadsEnabled = LockIsolated(false)
            defer { for waiter in waiters {
                waiter.resume()
            } }
            host.onSessionStateRequest = {
                .init(
                    pairId: "",
                    paneStates: [:],
                    supportsFileBrowsing: true,
                    supportsFileDownloads: downloadsEnabled.value ? true : nil,
                    supportsFileUploads: downloadsEnabled.value ? true : nil
                )
            }
            host.onCommand = { command in
                if
                    case let .browseFiles(spec) = command.command,
                    case let .info(path) = spec.operation, path.hasPrefix("/old/") {
                    // Simulates I/O that cannot finish immediately on cancellation.
                    await withCheckedContinuation { waiters.append($0) }
                    finishedCancelled.append(Task.isCancelled)
                }
                if
                    case let .browseFiles(spec) = command.command,
                    case let .download(path, offset, revision) = spec.operation {
                    return .init(
                        commandId: command.id,
                        success: true,
                        fileBrowser: .chunk(.init(
                            path: path,
                            revision: revision,
                            offset: offset,
                            data: Data(repeating: 7, count: FileBrowserLimits.chunkBytes)
                        ))
                    )
                }
                return .success(for: command.id)
            }
            await host.connect(
                serverURL: url,
                deviceId: "host",
                deviceName: "Host",
                username: "test",
                publicKey: hostEncryption.publicKey.base64EncodedString(),
                publicKeyId: hostEncryption.keyId
            )
            do {
                await connect(viewer, url: url, encryption: viewerEncryption, hostEncryption: hostEncryption)
                try await waitUntil { host.isViewerConnected && viewer.hostSupportsFileBrowsing }
                let frameCount = await relay.encryptedFrames
                let started = ContinuousClock.now
                let unsupported = await viewer.sendCommand(BrowseFiles(.download(path: "/movie.mp4", offset: 0, revision: "1")), paneId: "%7")
                if case .success = unsupported {
                    Issue.record("Legacy Host accepted a download")
                }
                #expect(ContinuousClock.now - started < .seconds(1))
                #expect(await relay.encryptedFrames == frameCount, "Do not send a new enum case to an old Host")
                let uploadBegin = BrowseFiles(.upload(.begin(id: uploadID, directory: uploadRoot.path, name: "file", size: 3)))
                if case .success = await viewer.sendCommand(uploadBegin, paneId: "") {
                    Issue.record("Legacy Host accepted an upload")
                }
                #expect(await relay.encryptedFrames == frameCount)
                downloadsEnabled.setValue(true)
                await host.pushSessionState()
                try await waitUntil { viewer.hostSupportsFileDownloads }
                #expect(viewer.hostSupportsFileUploads)
                #expect(try await viewer.sendCommand(uploadBegin, paneId: "").get().fileBrowser == .uploaded(offset: 0, path: nil))
                let append = BrowseFiles(.upload(.append(id: uploadID, offset: 0, data: Data([1, 2]))))
                #expect(try await viewer.sendCommand(append, paneId: "").get().fileBrowser == .uploaded(offset: 2, path: nil))
                #expect(try FileManager.default.contentsOfDirectory(atPath: uploadRoot.path).count == 1)
                let modern = await viewer.sendCommand(BrowseFiles(.download(path: "/movie.mp4", offset: 0, revision: "1")), paneId: "%7")
                if case let .chunk(chunk) = try modern.get().fileBrowser {
                    #expect(chunk.data == Data(repeating: 7, count: FileBrowserLimits.chunkBytes))
                } else {
                    Issue.record("Missing encrypted file chunk")
                }
                let requests = (0..<4).map { index in
                    Task { await viewer.sendCommand(BrowseFiles(.info(path: "/old/\(index)")), paneId: "%7", timeout: 5) }
                }
                try await waitUntil { waiters.count == 4 }
                requests[0].cancel()
                let cancelled = await requests[0].value
                if case let .failure(error) = cancelled {
                    #expect(error is CancellationError)
                } else {
                    Issue.record("Cancelled request unexpectedly succeeded")
                }
                await viewer.disconnect()
                #expect(!viewer.hostSupportsFileDownloads)
                #expect(!viewer.hostSupportsFileUploads)
                downloadsEnabled.setValue(false)
                try await waitUntil { !host.isViewerConnected }
                try await waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: uploadRoot.path).isEmpty) == true }
                #expect(host.state.isConnected, "This must exercise peer disconnect, not Host socket cleanup")
                for request in requests {
                    _ = await request.value
                }

                await connect(viewer, url: url, encryption: viewerEncryption, hostEncryption: hostEncryption)
                try await waitUntil { host.isViewerConnected && viewer.hostSupportsFileBrowsing }
                #expect(!viewer.hostSupportsFileDownloads)
                let result = await viewer.sendCommand(BrowseFiles(.info(path: "/new")), paneId: "%7", timeout: 5)
                #expect(try result.get().success, "Old requests must not retain the four slots after reconnect")
                downloadsEnabled.setValue(true)
                await host.pushSessionState()
                try await waitUntil { viewer.hostSupportsFileUploads }
                let oldUpload = await viewer.sendCommand(append, paneId: "")
                if case .success = oldUpload {
                    Issue.record("Reconnected Host reused an old upload")
                }
                let newID = UUID(), content = Data([4, 5, 6])
                let freshBegin = BrowseFiles(.upload(.begin(id: newID, directory: uploadRoot.path, name: "complete", size: content.count)))
                #expect(try await viewer.sendCommand(freshBegin, paneId: "").get().success)
                let freshAppend = BrowseFiles(.upload(.append(id: newID, offset: 0, data: content)))
                #expect(try await viewer.sendCommand(freshAppend, paneId: "").get().success)
                let finish = BrowseFiles(.upload(.finish(id: newID, sha256: SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined())))
                let savedPath = uploadRoot.appendingPathComponent("complete").path
                #expect(try await viewer.sendCommand(finish, paneId: "").get().fileBrowser == .uploaded(offset: 3, path: savedPath))
                #expect(try Data(contentsOf: URL(fileURLWithPath: savedPath)) == content)
                #expect(finishedCancelled.isEmpty, "New work must enter before old I/O finishes")
                let pending = waiters
                waiters.removeAll()
                for waiter in pending {
                    waiter.resume()
                }
                try await waitUntil { finishedCancelled.count == 4 }
                #expect(finishedCancelled.allSatisfy { $0 })
                #expect(await relay.errors.isEmpty)
                #expect(await relay.unexpectedTypes.isEmpty)
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

    private func connect(_ viewer: ViewerRelayClient, url: URL, encryption: E2EEService, hostEncryption: E2EEService) async {
        await viewer.connect(
            serverURL: url,
            pairId: "pair",
            deviceId: "viewer",
            deviceName: "Viewer",
            publicKey: encryption.publicKey.base64EncodedString(),
            publicKeyId: encryption.keyId,
            e2eeService: encryption,
            partnerPublicKey: hostEncryption.publicKey.base64EncodedString(),
            partnerPublicKeyId: hostEncryption.keyId
        )
    }

    private func encryption() async throws -> E2EEService {
        try await withDependencies { $0[SecretsService.self] = .inMemory() } operation: { try await E2EEService() }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let met = await condition()
        try #require(met, "File-request connection state did not converge")
    }
}
