#if os(macOS)
    import Clocks
    import ConcurrencyExtras
    import CtrlxBrowserBridge
    import CtrlxCommon
    import CtrlxEncryption
    import CtrlxNetworking
    import CtrlxSimulatorProtocol
    import Darwin
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("AppShutdownDelegate")
    @MainActor
    struct AppShutdownDelegateTests {
        @MainActor
        private final class Runtime: NSObject, @preconcurrency CXBrowserRuntime {
            var didFinishShutdown = false
            func start(with delegate: any CXBrowserHostDelegate, profile: String, state: String) throws {}
            func setHumanControl(_ token: String?, forTab identifier: String) -> Bool { true }
            func requestBrowserTab(_ identifier: String, request: Data, completion: @escaping (Data?, String?) -> Void) {
                completion(nil, "Not configured")
            }
            func isReady() -> Bool { true }
            func startupError() -> String? { nil }
            func openManualTab(route: [String: String], url: String, completion: @escaping (String?) -> Void) { completion(nil) }
            func navigateTab(_ identifier: String, url: String) {}
            func goBack(_ identifier: String) {}
            func goForward(_ identifier: String) {}
            func reloadTab(_ identifier: String) {}
            func showDevTools(_ identifier: String) {}
            func closeTab(_ identifier: String) {}
            func beginShutdown() {}
            func finishShutdown() -> Bool { didFinishShutdown = true; return true }
        }

        @Test("Slow storage cannot delay browser and terminal cleanup past the quit deadline")
        func slowStorageDoesNotBlockOtherShutdownServices() async throws {
            try await withMainSerialExecutor {
                let clock = TestClock()
                let entered = AsyncStream<Void>.makeStream()
                let release = AsyncStream<Void>.makeStream()
                let cleanupFinished = AsyncStream<Void>.makeStream()
                // The process has received cancellation but has not finished reaping yet.
                let reap = Task { for await _ in release.stream { break } }
                let owner = SimulatorOwner(pid: 10, uid: getuid(), startSeconds: 100, startMicros: 1)
                let udid = UUID().uuidString
                let inventory = try JSONSerialization.data(withJSONObject: [
                    "devices": ["runtime": [["udid": udid, "state": "Shutdown"]]],
                ])
                let runner = ProcessRunner(run: { _, arguments, _, _ in
                    if arguments.contains("erase") {
                        entered.continuation.yield(())
                        await reap.value
                        try Task.checkCancellation()
                    }
                    return ProcessResult(exitCode: 0, stdout: inventory, stderr: Data())
                })
                var system = SimulatorSystemClient()
                system.createDirectory = { _ in }
                system.inspect = { _ in SimulatorProcess(owner: owner, parentPID: 1, executable: "/fixture/codex") }
                let apiStopped = LockIsolated(false)
                let replies = LockIsolated(0)
                await withDependencies {
                    $0.continuousClock = clock
                    $0[PreferencesService.self] = .inMemory()
                    $0[SecretsService.self] = .inMemory()
                    $0[SimulatorSystemClient.self] = system
                    $0[ProcessRunner.self] = runner
                    $0[APISocketServer.self] = APISocketServer(stop: { apiStopped.setValue(true) })
                } operation: { @MainActor in
                    let runtime = Runtime()
                    let settings = AppSettings()
                    settings.tmuxPath = "/nonexistent-ctrlx-shutdown-test"
                    let coordinator = AppCoordinator(settings: settings, agentBrowser: AgentBrowserService(runtime: runtime))
                    coordinator.agentSimulator.start(root: URL(fileURLWithPath: "/unused-shutdown-test")) { _ in
                        throw SimulatorFailure("Storage does not resolve a pane")
                    }
                    let storage = Task {
                        await coordinator.agentSimulator.handle(JSONRPCRequest(id: "erase", method: "simulator.action", params: [
                            "_peerPID": .int(Int(owner.pid)), "command": .string("erase"), "udid": .string(udid),
                        ]))
                    }
                    for await _ in entered.stream { break }
                    let delegate = AppShutdownDelegate()
                    delegate.replyHandler = { replies.withValue { $0 += 1 } }
                    delegate.onShouldTerminate = {
                        await coordinator.shutdown()
                        cleanupFinished.continuation.yield(())
                    }
                    #expect(delegate.applicationShouldTerminate(.shared) == .terminateLater)
                    await Task.megaYield()
                    await clock.advance(by: .seconds(29))
                    #expect(apiStopped.value)
                    #expect(runtime.didFinishShutdown)
                    #expect(replies.value == 0)
                    var terminalsClosed = false
                    do {
                        _ = try await coordinator.controlClientManager.getClient(for: "must-stay-disconnected")
                    } catch {
                        if case TmuxControlError.notConnected = error { terminalsClosed = true }
                    }
                    #expect(terminalsClosed)
                    await clock.advance(by: .seconds(1))
                    #expect(replies.value == 1)
                    release.continuation.yield(())
                    _ = await storage.value
                    for await _ in cleanupFinished.stream { break }
                    await Task.megaYield()
                    #expect(replies.value == 1)
                }
            }
        }

        @Test("Coordinator shutdown removes its listening API socket")
        func coordinatorShutdownStopsAPIServer() async throws {
            let server = LiveAPISocketServer()
            let path = "/tmp/ctrlx-api-shutdown-\(UUID().uuidString).sock"
            try await server.start(socketPath: path)
            #expect(FileManager.default.fileExists(atPath: path))

            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[SecretsService.self] = .inMemory()
                $0[SimulatorSystemClient.self] = SimulatorSystemClient()
                $0[APISocketServer.self] = APISocketServer(stop: { await server.stop() })
            } operation: { @MainActor in
                let coordinator = AppCoordinator()
                await coordinator.shutdown()
                #expect(!FileManager.default.fileExists(atPath: path))
            }
            await server.stop()
        }

        @Test("Native quit keeps the event loop running and starts cleanup once")
        func nativeQuitAvoidsModalLoop() async {
            await withMainSerialExecutor {
                let clock = TestClock()
                let cleanupCount = LockIsolated(0)
                let terminateCount = LockIsolated(0)
                let modalReplyCount = LockIsolated(0)
                await withDependencies {
                    $0.continuousClock = clock
                } operation: { @MainActor in
                    let delegate = AppShutdownDelegate(shutdownTimeout: .seconds(3))
                    delegate.terminateHandler = { terminateCount.withValue { $0 += 1 } }
                    delegate.replyHandler = { modalReplyCount.withValue { $0 += 1 } }
                    delegate.onShouldTerminate = {
                        cleanupCount.withValue { $0 += 1 }
                        try? await clock.sleep(for: .seconds(1))
                    }
                    #expect(delegate.tryToTerminateWithoutModalLoop())
                    #expect(delegate.tryToTerminateWithoutModalLoop())
                    await Task.megaYield()
                    #expect(cleanupCount.value == 1)
                    #expect(terminateCount.value == 0)
                    await clock.advance(by: .seconds(1))
                    #expect(terminateCount.value == 1)
                    #expect(modalReplyCount.value == 0)
                    #expect(!delegate.tryToTerminateWithoutModalLoop())
                    #expect(delegate.applicationShouldTerminate(.shared) == .terminateNow)
                    await clock.advance(by: .seconds(5))
                    #expect(terminateCount.value == 1)
                }
            }
        }

        @Test("Native quit deadline permits termination even if cleanup hangs")
        func nativeQuitDeadline() async {
            await withMainSerialExecutor {
                let clock = TestClock()
                let terminateCount = LockIsolated(0)
                await withDependencies {
                    $0.continuousClock = clock
                } operation: { @MainActor in
                    let delegate = AppShutdownDelegate(shutdownTimeout: .seconds(3))
                    delegate.terminateHandler = { terminateCount.withValue { $0 += 1 } }
                    delegate.onShouldTerminate = { try? await clock.sleep(for: .seconds(60)) }
                    #expect(delegate.tryToTerminateWithoutModalLoop())
                    await Task.megaYield()
                    await clock.advance(by: .seconds(3))
                    #expect(terminateCount.value == 1)
                    #expect(!delegate.tryToTerminateWithoutModalLoop())
                    #expect(delegate.applicationShouldTerminate(.shared) == .terminateNow)
                    await clock.advance(by: .seconds(60))
                    #expect(terminateCount.value == 1)
                }
            }
        }

        @Test("Default shutdown allows cleanup to finish after five seconds")
        func defaultDeadlineAllowsSimulatorCleanup() async {
            await withMainSerialExecutor {
                let clock = TestClock()
                let replyCount = LockIsolated(0)
                await withDependencies {
                    $0.continuousClock = clock
                } operation: { @MainActor in
                    let delegate = AppShutdownDelegate()
                    delegate.replyHandler = { replyCount.withValue { $0 += 1 } }
                    delegate.onShouldTerminate = { try? await clock.sleep(for: .seconds(6)) }
                    #expect(delegate.applicationShouldTerminate(.shared) == .terminateLater)
                    await Task.megaYield()
                    await clock.advance(by: .seconds(5))
                    #expect(replyCount.value == 0)
                    await clock.advance(by: .seconds(1))
                    #expect(replyCount.value == 1)
                    await clock.advance(by: .seconds(30))
                    #expect(replyCount.value == 1)
                }
            }
        }

        /// Builds a delegate with a stubbed reply handler that signals when AppKit would have been told to terminate.
        private func makeDelegate(
            timeout: Duration,
            onReply: @escaping @MainActor () -> Void
        ) -> AppShutdownDelegate {
            let delegate = AppShutdownDelegate(shutdownTimeout: timeout)
            delegate.replyHandler = { onReply() }
            return delegate
        }

        @Test("Cleanup completing before the deadline replies immediately")
        func cleanupBeforeDeadline() async {
            await withMainSerialExecutor {
                let clock = TestClock()
                let replyCount = LockIsolated(0)
                await withDependencies {
                    $0.continuousClock = clock
                } operation: { @MainActor in
                    let delegate = makeDelegate(timeout: .seconds(3)) {
                        replyCount.withValue { $0 += 1 }
                    }
                    delegate.onShouldTerminate = { /* finishes immediately */ }
                    let reply = delegate.applicationShouldTerminate(.shared)
                    #expect(reply == .terminateLater)
                    // Cleanup task runs on the next main-actor hop, before any clock advance.
                    await Task.megaYield()
                    #expect(replyCount.value == 1)
                    // Advancing past the deadline must not double-fire the reply.
                    await clock.advance(by: .seconds(5))
                    #expect(replyCount.value == 1)
                }
            }
        }

        @Test("Cleanup hanging past the timeout fires the deadline reply")
        func cleanupExceedsDeadline() async {
            await withMainSerialExecutor {
                let clock = TestClock()
                let replyCount = LockIsolated(0)
                await withDependencies {
                    $0.continuousClock = clock
                } operation: { @MainActor in
                    let delegate = makeDelegate(timeout: .seconds(3)) {
                        replyCount.withValue { $0 += 1 }
                    }
                    // Cleanup awaits the same TestClock, so it cannot finish until we advance.
                    delegate.onShouldTerminate = {
                        try? await clock.sleep(for: .seconds(60))
                    }
                    _ = delegate.applicationShouldTerminate(.shared)
                    // Just under the timeout: deadline hasn't fired yet.
                    await clock.advance(by: .seconds(2))
                    #expect(replyCount.value == 0)
                    // Cross the deadline: the timeout task fires reply exactly once.
                    await clock.advance(by: .seconds(2))
                    #expect(replyCount.value == 1)
                }
            }
        }

        @Test("Without a cleanup handler the delegate replies immediately and never schedules a deadline")
        func noCleanupHandlerReturnsTerminateNow() async {
            await withMainSerialExecutor {
                let clock = TestClock()
                let replyCount = LockIsolated(0)
                await withDependencies {
                    $0.continuousClock = clock
                } operation: { @MainActor in
                    let delegate = makeDelegate(timeout: .seconds(3)) {
                        replyCount.withValue { $0 += 1 }
                    }
                    let reply = delegate.applicationShouldTerminate(.shared)
                    #expect(reply == .terminateNow)
                    // No tasks were spawned — advancing the clock must not fire replyHandler.
                    await clock.advance(by: .seconds(60))
                    #expect(replyCount.value == 0)
                }
            }
        }
    }
#endif
