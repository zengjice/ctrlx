#if os(macOS)
    import AppKit
    import Clocks
    import ConcurrencyExtras
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Installer Quit requests")
    @MainActor
    struct InstallerQuitRequestTests {
        private let now = Date(timeIntervalSince1970: 1_000)

        private func event(deadline: String? = "1010") -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEQuitApplication, targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            if let deadline {
                event.setParam(NSAppleEventDescriptor(string: deadline), forKeyword: InstallerQuitRequestClient.deadlineKeyword)
            }
            return event
        }

        @Test("Fresh installer requests require a live sender")
        func freshRequest() {
            #expect(InstallerQuitRequestClient.rejectionReason(event: event(), now: now, senderPID: 42, isProcessRunning: { $0 == 42 }) == nil)
            #expect(InstallerQuitRequestClient.rejectionReason(event: event(), now: now, senderPID: 42, isProcessRunning: { _ in false }) != nil)
            #expect(InstallerQuitRequestClient.rejectionReason(event: event(), now: now, senderPID: 0, isProcessRunning: { _ in true }) != nil)
            #expect(InstallerQuitRequestClient.rejectionReason(event: event(), now: now, senderPID: nil, isProcessRunning: { _ in true }) != nil)
        }

        @Test("Expired or malformed deadlines cannot start cleanup", arguments: ["1000", "999", "0", "", "nan", "inf", "invalid"])
        func invalidDeadline(deadline: String) {
            #expect(InstallerQuitRequestClient.rejectionReason(event: event(deadline: deadline), now: now, senderPID: 42, isProcessRunning: { _ in true }) != nil)
        }

        @Test("Interactive and legacy Quit requests retain normal behavior")
        func ordinaryQuit() {
            #expect(InstallerQuitRequestClient.rejectionReason(event: nil, now: now, senderPID: nil, isProcessRunning: { _ in false }) == nil)
            #expect(InstallerQuitRequestClient.rejectionReason(event: event(deadline: nil), now: now, senderPID: nil, isProcessRunning: { _ in false }) == nil)
        }

        @Test("Rejected requests do not start cleanup or poison the next Quit", arguments: [false, true])
        func rejectedQuit(native: Bool) async {
            await withMainSerialExecutor {
                let clock = TestClock()
                var expired = true
                await withDependencies {
                    $0.continuousClock = clock
                    $0[InstallerQuitRequestClient.self].rejectionReason = { expired ? "Fixture expired request" : nil }
                } operation: {
                    let delegate = AppShutdownDelegate()
                    var cleanups = 0, replies = 0, terminations = 0
                    delegate.onShouldTerminate = { cleanups += 1 }
                    delegate.replyHandler = { replies += 1 }
                    delegate.terminateHandler = { terminations += 1 }
                    if native {
                        #expect(delegate.tryToTerminateWithoutModalLoop())
                    } else {
                        #expect(delegate.applicationShouldTerminate(.shared) == .terminateCancel)
                    }
                    await Task.megaYield()
                    #expect(cleanups == 0 && replies == 0 && terminations == 0)
                    expired = false
                    #expect(delegate.applicationShouldTerminate(.shared) == .terminateLater)
                    await Task.megaYield()
                    #expect(cleanups == 1 && replies == 1 && terminations == 0)
                    await clock.advance(by: .seconds(30))
                }
            }
        }

        @Test("An accepted request finishes cleanup even after it expires")
        func expiryDuringCleanup() async {
            await withMainSerialExecutor {
                let clock = TestClock()
                var expired = false, validations = 0, replies = 0
                await withDependencies {
                    $0.continuousClock = clock
                    $0[InstallerQuitRequestClient.self].rejectionReason = {
                        validations += 1
                        return expired ? "Fixture expired request" : nil
                    }
                } operation: {
                    let delegate = AppShutdownDelegate()
                    delegate.onShouldTerminate = { try? await clock.sleep(for: .seconds(20)) }
                    delegate.replyHandler = { replies += 1 }
                    #expect(delegate.applicationShouldTerminate(.shared) == .terminateLater)
                    await Task.megaYield()
                    expired = true
                    #expect(delegate.applicationShouldTerminate(.shared) == .terminateLater)
                    await clock.advance(by: .seconds(20))
                    #expect(replies == 1 && validations == 1)
                    await clock.advance(by: .seconds(10))
                }
            }
        }
    }
#endif
