#if os(macOS)
    import AppKit
    import CtrlxCommon
    import CtrlxNetworking
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Host browser audio") @MainActor
    struct AgentBrowserAudioTests {
        @Test(arguments: [false, true])
        func slowSendDoesNotBlockCaptureAndBacklogStaysBounded(stopBeforeRelease: Bool) async throws {
            let (service, runtime, tab) = try await RemoteBrowserControlTests().fixture()
            runtime.audioPCM = Data(repeating: 0, count: 4_096 * 8)
            var release: CheckedContinuation<Void, Never>?
            var delivered: [UInt64] = []
            service.sendBrowserAudio = { _, message in
                delivered.append(message.sequence)
                if delivered.count == 1 {
                    await withCheckedContinuation { release = $0 }
                }
            }
            defer { release?.resume() }
            let surface = UUID(), id = UUID()
            let control = try #require(try await service.handleBrowser(.init(sessionName: "test", tabID: tab.id, surfaceID: surface, operation: .takeControl), viewerID: "a").controlID)
            _ = try await service.handleBrowser(.init(
                sessionName: "test",
                tabID: tab.id,
                surfaceID: surface,
                controlID: control,
                operation: .audio(streamID: id, revision: 1, enabled: true)
            ), viewerID: "a")
            let stream = try #require(service.browserAudioStreams[tab.id])
            for _ in 0..<200 where stream.droppedFrames == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(delivered == [1])
            #expect(stream.droppedFrames > 0)
            #expect(stream.pendingFrames <= BrowserAudioBuffering.maximumFrames - 4_096)
            if stopBeforeRelease {
                service.releaseBrowserControl(tab.id)
            }
            release?.resume()
            release = nil
            try await Task.sleep(for: .milliseconds(60))
            if stopBeforeRelease {
                #expect(delivered == [1])
                #expect(stream.pendingFrames == 0)
            } else {
                #expect(delivered.count > 1)
                #expect(delivered.dropFirst().first.map { $0 > 2 } == true)
                #expect(delivered == delivered.sorted())
                #expect(stream.pendingFrames <= BrowserAudioBuffering.maximumFrames)
            }
            await service.shutdown()
        }

        @Test
        func aLateMuteForAnotherSurfaceCannotStopTheCurrentStream() async throws {
            let (service, _, first) = try await RemoteBrowserControlTests().fixture()
            service.sendBrowserAudio = { _, _ in }
            let second = UUID()
            service.browserTabCreated(
                second.uuidString,
                view: NSView(),
                route: ["workspace": UUID().uuidString, "pane": "%2", "session": "test", "window": "@2"],
                owner: "owner",
                parent: nil
            )
            let firstSurface = UUID(), secondSurface = UUID()
            let firstLease = try #require(try await service.handleBrowser(.init(sessionName: "test", tabID: first.id, surfaceID: firstSurface, operation: .takeControl), viewerID: "a").controlID)
            let secondLease = try #require(try await service.handleBrowser(.init(sessionName: "test", tabID: second, surfaceID: secondSurface, operation: .takeControl), viewerID: "a").controlID)
            let stream = UUID()
            _ = try await service.handleBrowser(.init(
                sessionName: "test",
                tabID: second,
                surfaceID: secondSurface,
                controlID: secondLease,
                operation: .audio(streamID: stream, revision: 1, enabled: true)
            ), viewerID: "a")
            _ = try await service.handleBrowser(.init(
                sessionName: "test",
                tabID: first.id,
                surfaceID: firstSurface,
                controlID: firstLease,
                operation: .audio(streamID: UUID(), revision: 2, enabled: false)
            ), viewerID: "a")
            #expect(service.browserAudioStreams[second]?.id == stream)
            #expect(service.browserAudioStreams[second]?.task != nil)
            await service.shutdown()
        }

        @Test
        func audioRequiresExactViewerSurfaceAndLiveControl() async throws {
            let (service, runtime, tab) = try await RemoteBrowserControlTests().fixture()
            service.sendBrowserAudio = { _, _ in }
            let surface = UUID()
            let control = try #require(try await service.handleBrowser(.init(sessionName: "test", tabID: tab.id, surfaceID: surface, operation: .takeControl), viewerID: "a").controlID)
            for (viewer, targetSurface, grant) in [("b", surface, control), ("a", UUID(), control), ("a", surface, UUID())] {
                await #expect(throws: (any Error).self) {
                    try await service.handleBrowser(.init(
                        sessionName: "test",
                        tabID: tab.id,
                        surfaceID: targetSurface,
                        controlID: grant,
                        operation: .audio(streamID: UUID(), revision: 1, enabled: true)
                    ), viewerID: viewer)
                }
            }
            #expect(runtime.audioRoutes.isEmpty)
            _ = try await service.handleBrowser(.init(
                sessionName: "test",
                tabID: tab.id,
                surfaceID: surface,
                controlID: control,
                operation: .audio(streamID: UUID(), revision: 1, enabled: false)
            ), viewerID: "a")
            #expect(runtime.audioRoutes.last?.1 == false)
            #expect(service.browserAudioStreams[tab.id]?.task == nil)
            service.disconnectBrowserViewer("a")
            #expect(runtime.controls[tab.id.uuidString] == nil)
            #expect(service.browserAudioStreams.isEmpty && service.browserAudioRevisions.isEmpty)
            await service.shutdown()
        }

        @Test
        func lateEnableCannotOverrideNewerMuteAndReleaseDropsPendingSamples() async throws {
            let (service, runtime, tab) = try await RemoteBrowserControlTests().fixture()
            var messages: [RemoteBrowserAudio] = []
            service.sendBrowserAudio = { _, message in messages.append(message) }
            let surface = UUID()
            let control = try #require(try await service.handleBrowser(.init(sessionName: "test", tabID: tab.id, surfaceID: surface, operation: .takeControl), viewerID: "a").controlID)
            func configure(_ revision: UInt64, enabled: Bool) async throws {
                _ = try await service.handleBrowser(.init(
                    sessionName: "test",
                    tabID: tab.id,
                    surfaceID: surface,
                    controlID: control,
                    operation: .audio(streamID: UUID(), revision: revision, enabled: enabled)
                ), viewerID: "a")
            }
            try await configure(2, enabled: false)
            let calls = runtime.audioRoutes.count
            try await configure(1, enabled: true)
            #expect(runtime.audioRoutes.count == calls)
            runtime.holdAudioRead = true
            try await configure(3, enabled: true)
            for _ in 0..<100 where runtime.pendingAudioRead == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            let read = try #require(runtime.pendingAudioRead)
            service.releaseBrowserControl(tab.id)
            read(Data(repeating: 0, count: 4_096 * 8), nil)
            try await Task.sleep(for: .milliseconds(60))
            #expect(messages.isEmpty)
            #expect(service.browserAudioStreams.isEmpty)
            #expect(runtime.controls[tab.id.uuidString] == nil)
            await service.shutdown()
        }

        @Test
        func capturedPcmReachesOnlyItsControllerAsBoundedAac() async throws {
            let (service, runtime, tab) = try await RemoteBrowserControlTests().fixture()
            runtime.audioPCM = [Float](repeating: 0.15, count: 4_096 * 2).withUnsafeBytes { Data($0) }
            var messages: [(String, RemoteBrowserAudio)] = []
            service.sendBrowserAudio = { messages.append(($0, $1)) }
            let surface = UUID(), stream = UUID()
            let control = try #require(try await service.handleBrowser(.init(sessionName: "test", tabID: tab.id, surfaceID: surface, operation: .takeControl), viewerID: "a").controlID)
            _ = try await service.handleBrowser(.init(
                sessionName: "test",
                tabID: tab.id,
                surfaceID: surface,
                controlID: control,
                operation: .audio(streamID: stream, revision: 1, enabled: true)
            ), viewerID: "a")
            for _ in 0..<100 where messages.isEmpty {
                try await Task.sleep(for: .milliseconds(5))
            }
            let (viewer, message) = try #require(messages.first)
            #expect(viewer == "a" && message.streamID == stream && message.controlID == control && message.tabID == tab.id)
            #expect(message.isValid && message.error == nil && !message.packets.isEmpty)
            #expect(message.packets.reduce(0) { $0 + $1.count } < runtime.audioPCM.count)
            await service.shutdown()
            #expect(service.browserAudioStreams.isEmpty)
        }
    }
#endif
