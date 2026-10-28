#if os(macOS)
    import AppKit
    import CtrlxBrowserBridge
    import Dependencies
    import Foundation
    import Logging

    /// NSApplicationDelegate that runs async cleanup before the app terminates.
    ///
    /// AppKit calls `applicationShouldTerminate(_:)` for both interactive Quit
    /// and AppleScript "quit". Ordinary AppKit quit uses `.terminateLater`;
    /// Chromium routes quit here before AppKit enters its modal loop so the
    /// native message loop can unwind during async cleanup.
    ///
    /// Without this, tmux is left with `cat > FIFO` subprocesses whose reader
    /// (us) has just disappeared. The source pane then stalls until `cat`
    /// notices the broken pipe on its next write — which can be a long time
    /// for an idle pane. Wiring this hook lets us send `pipe-pane -t` to tmux
    /// before exit, which terminates the `cat` subprocesses immediately.
    @MainActor
    final public class AppShutdownDelegate: NSObject, NSApplicationDelegate, @preconcurrency CXBrowserTerminationDelegate {
        public var onOpenFiles: (@MainActor ([URL]) -> Void)?

        public func application(_: NSApplication, open urls: [URL]) {
            onOpenFiles?(urls)
        }

        /// Async cleanup to run before the app terminates. Set this once at
        /// startup; if `nil` at quit time, AppKit terminates immediately.
        public var onShouldTerminate: (@MainActor () async -> Void)?

        /// Maximum time to wait for cleanup before forcing termination.
        public let shutdownTimeout: Duration

        private var didReply = false
        private var isCleaningUp = false
        private var usesModalReply = true
        private let logger = Logger(label: "com.jicezeng.ctrlx.shutdown")

        @Dependency(\.continuousClock) private var clock

        /// Hook invoked when the delegate decides termination should proceed.
        /// Defaults to `NSApp.reply(toApplicationShouldTerminate: true)`.
        /// Tests substitute this to observe replies without driving AppKit.
        var replyHandler: @MainActor () -> Void = {
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        var terminateHandler: @MainActor () -> Void = {
            NSApp.terminate(nil)
        }

        /// `@NSApplicationDelegateAdaptor` instantiates via Objective-C `init()`,
        /// which doesn't see Swift default arguments — so we need an explicit
        /// zero-arg initializer.
        public override init() {
            self.shutdownTimeout = .seconds(30)
            super.init()
        }

        public init(shutdownTimeout: Duration) {
            self.shutdownTimeout = shutdownTimeout
            super.init()
        }

        public func installNativeTerminationHandling() {
            CXBrowserSetTerminationDelegate(self)
        }

        public func tryToTerminateWithoutModalLoop() -> Bool {
            guard !didReply, let cleanup = onShouldTerminate else { return false }
            if !isCleaningUp {
                usesModalReply = false
                beginCleanup(cleanup)
            }
            return true
        }

        public func applicationShouldTerminate(
            _: NSApplication
        ) -> NSApplication.TerminateReply {
            guard !didReply else { return .terminateNow }
            guard let cleanup = onShouldTerminate else { return .terminateNow }
            if !isCleaningUp {
                usesModalReply = true
                beginCleanup(cleanup)
            }
            return .terminateLater
        }

        private func beginCleanup(_ cleanup: @escaping @MainActor () async -> Void) {
            isCleaningUp = true
            logger.info("applicationShouldTerminate: running async cleanup")
            // Race the cleanup against a hard deadline. Whichever finishes
            // first calls `replyOnce()`; the second call is a no-op. This
            // guarantees the app eventually terminates even if a tmux IPC
            // hangs longer than the per-command timeout allows for.
            let timeout = shutdownTimeout
            Task { @MainActor [weak self] in
                await cleanup()
                self?.replyOnce()
            }
            Task { @MainActor [weak self] in
                try? await self?.clock.sleep(for: timeout)
                guard let self else { return }
                if !self.didReply {
                    self.logger.warning("Shutdown cleanup exceeded \(timeout); terminating anyway")
                }
                self.replyOnce()
            }
        }

        private func replyOnce() {
            guard !didReply else { return }
            didReply = true
            if usesModalReply {
                replyHandler()
            } else {
                terminateHandler()
            }
        }
    }
#endif
