#if os(iOS)
    import BackgroundTasks
    import Dependencies
    import DependenciesMacros
    import Foundation
    import os

    public struct ContinuedProcessingRequest: Sendable {
        public let identifier: String
        public let title: String
        public let subtitle: String
        public let launchHandler: @MainActor @Sendable () -> Void
        public let expirationHandler: @MainActor @Sendable () -> Void

        public init(
            identifier: String,
            title: String,
            subtitle: String,
            launchHandler: @escaping @MainActor @Sendable () -> Void,
            expirationHandler: @escaping @MainActor @Sendable () -> Void
        ) {
            self.identifier = identifier
            self.title = title
            self.subtitle = subtitle
            self.launchHandler = launchHandler
            self.expirationHandler = expirationHandler
        }
    }

    public struct ContinuedProcessingUpdate: Sendable, Equatable {
        public let title: String
        public let subtitle: String
        public let completedUnitCount: Int64
        public let totalUnitCount: Int64

        public init(
            title: String,
            subtitle: String,
            completedUnitCount: Int64,
            totalUnitCount: Int64
        ) {
            self.title = title
            self.subtitle = subtitle
            self.completedUnitCount = completedUnitCount
            self.totalUnitCount = totalUnitCount
        }
    }

    /// Testable boundary around iOS 26 continued-processing APIs.
    @DependencyClient
    public struct ContinuedProcessingClient: Sendable {
        public var prepare: @MainActor @Sendable () -> Void
        public var start: @MainActor @Sendable (_ request: ContinuedProcessingRequest) throws -> Void
        public var update: @MainActor @Sendable (
            _ identifier: String,
            _ update: ContinuedProcessingUpdate
        ) -> Void
        public var finish: @MainActor @Sendable (_ identifier: String) -> Void
    }

    extension ContinuedProcessingClient: DependencyKey {
        public static var previewValue: ContinuedProcessingClient {
            ContinuedProcessingClient(
                prepare: { },
                start: { _ in },
                update: { _, _ in },
                finish: { _ in }
            )
        }

        public static var liveValue: ContinuedProcessingClient {
            ContinuedProcessingClient(
                prepare: {
                    guard #available(iOS 26.0, *) else { return }
                    ContinuedProcessingRuntime.shared.prepare()
                },
                start: { request in
                    guard #available(iOS 26.0, *) else {
                        throw ContinuedProcessingError.unsupportedSystem
                    }
                    try ContinuedProcessingRuntime.shared.start(request)
                },
                update: { identifier, update in
                    guard #available(iOS 26.0, *) else { return }
                    ContinuedProcessingRuntime.shared.update(identifier: identifier, update: update)
                },
                finish: { identifier in
                    guard #available(iOS 26.0, *) else { return }
                    ContinuedProcessingRuntime.shared.finish(identifier: identifier)
                }
            )
        }
    }

    public enum ContinuedProcessingError: Error {
        case unsupportedSystem
        case registrationFailed
        case duplicateIdentifier
    }

    @available(iOS 26.0, *)
    @MainActor
    final private class ContinuedProcessingRuntime {
        static let shared = ContinuedProcessingRuntime()

        private struct Entry {
            let request: ContinuedProcessingRequest
            var update: ContinuedProcessingUpdate
            var task: BGContinuedProcessingTask?
            var completionRequested: Bool
        }

        private let logger = Logger(
            subsystem: "com.jicezeng.ctrlx",
            category: "ContinuedProcessing"
        )
        private var entries: [String: Entry] = [:]
        private var isPrepared = false

        /// Reclaim requests left by a previous process. Cancelling an accepted
        /// continued-processing request makes iOS present it as a failed task,
        /// so stale requests get a handler that closes them successfully if
        /// the system launches them after this process starts.
        func prepare() {
            guard !isPrepared else { return }
            isPrepared = true

            let prefix = Self.identifierPrefix
            BGTaskScheduler.shared.getPendingTaskRequests { [weak self] requests in
                let identifiers = requests
                    .map(\.identifier)
                    .filter { $0.hasPrefix(prefix) }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let activeIdentifiers = Set(self.entries.keys)
                    let staleIdentifiers = identifiers.filter {
                        !activeIdentifiers.contains($0)
                    }
                    for identifier in staleIdentifiers {
                        self.registerRecoveryHandler(for: identifier)
                    }
                    if !staleIdentifiers.isEmpty {
                        self.logger.info(
                            "Registered recovery for \(staleIdentifiers.count, privacy: .public) stale continued-processing request(s)"
                        )
                    }
                }
            }
        }

        func start(_ request: ContinuedProcessingRequest) throws {
            prepare()
            guard entries[request.identifier] == nil else {
                throw ContinuedProcessingError.duplicateIdentifier
            }

            let initialUpdate = ContinuedProcessingUpdate(
                title: request.title,
                subtitle: request.subtitle,
                // The first unit means that system monitoring has started.
                // Publish it in the launch handler so iOS can create the Live
                // Activity before the app leaves the foreground.
                completedUnitCount: AgentBackgroundMonitoringPolicy.initialActivityUnits,
                totalUnitCount: AgentBackgroundMonitoringPolicy.maximumActivityUnits
            )
            entries[request.identifier] = Entry(
                request: request,
                update: initialUpdate,
                task: nil,
                completionRequested: false
            )

            let identifier = request.identifier
            // This closure inherits MainActor isolation from the runtime. The
            // scheduler must therefore invoke it on the main queue; `nil`
            // selects a private BGTaskScheduler queue and trips Swift 6's
            // executor precondition before the closure body can hop actors.
            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier,
                using: .main
            ) { task in
                ContinuedProcessingRuntime.shared.didLaunch(
                    task,
                    identifier: identifier
                )
            }
            guard registered else {
                entries.removeValue(forKey: identifier)
                throw ContinuedProcessingError.registrationFailed
            }

            let taskRequest = BGContinuedProcessingTaskRequest(
                identifier: identifier,
                title: request.title,
                subtitle: request.subtitle
            )
            // This is a user-visible foreground action. Either start it now or
            // report the scheduler error so the user can retry; an invisible
            // queued task is worse than an honest failure and has produced an
            // active task without system UI on iOS 26.6.
            taskRequest.strategy = .fail

            do {
                try BGTaskScheduler.shared.submit(taskRequest)
            } catch {
                entries.removeValue(forKey: identifier)
                throw error
            }
        }

        func update(identifier: String, update: ContinuedProcessingUpdate) {
            guard var entry = entries[identifier] else { return }
            entry.update = update
            apply(update, to: entry.task)
            entries[identifier] = entry
        }

        func finish(identifier: String) {
            guard var entry = entries[identifier] else { return }

            guard let task = entry.task else {
                guard !entry.completionRequested else { return }
                // A successful `.fail` submission starts now or shortly after
                // submission, but its MainActor launch callback can trail a
                // fast Agent completion or the foreground-to-background
                // transition. Keep this tombstone until that callback arrives;
                // cancelling an accepted request is rendered as task failure.
                entry.completionRequested = true
                entries[identifier] = entry
                logger.info(
                    "Continued-processing task completed before launch callback: \(identifier, privacy: .public)"
                )
                return
            }

            entries.removeValue(forKey: identifier)
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: true)
            logger.info(
                "Completed continued-processing task: \(identifier, privacy: .public)"
            )
        }

        private func didLaunch(_ task: BGTask, identifier: String) {
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                // This task is only a monitoring lease. A framework type
                // mismatch must not report that the remote Agent work failed.
                task.setTaskCompleted(success: true)
                entries.removeValue(forKey: identifier)
                logger.error(
                    "Unexpected task type for continued-processing identifier: \(identifier, privacy: .public)"
                )
                return
            }
            guard var entry = entries[identifier] else {
                // The monitored work disappeared before a delayed launch. It
                // is no longer actionable, but it is not an Agent failure.
                continuedTask.progress.totalUnitCount = 1
                continuedTask.progress.completedUnitCount = 1
                continuedTask.setTaskCompleted(success: true)
                return
            }
            if entry.completionRequested {
                entries.removeValue(forKey: identifier)
                continuedTask.progress.totalUnitCount = 1
                continuedTask.progress.completedUnitCount = 1
                continuedTask.setTaskCompleted(success: true)
                logger.info(
                    "Completed continued-processing task during launch handoff: \(identifier, privacy: .public)"
                )
                return
            }

            continuedTask.expirationHandler = {
                ContinuedProcessingRuntime.shared.expire(identifier: identifier)
            }
            entry.task = continuedTask
            apply(entry.update, to: continuedTask)
            entries[identifier] = entry
            entry.request.launchHandler()
        }

        private func registerRecoveryHandler(for identifier: String) {
            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier,
                using: .main
            ) { task in
                if let continuedTask = task as? BGContinuedProcessingTask {
                    continuedTask.progress.totalUnitCount = 1
                    continuedTask.progress.completedUnitCount = 1
                }
                task.setTaskCompleted(success: true)
                ContinuedProcessingRuntime.shared.logger.info(
                    "Recovered stale continued-processing task: \(identifier, privacy: .public)"
                )
            }
            if !registered {
                logger.error(
                    "Failed to register stale continued-processing recovery: \(identifier, privacy: .public)"
                )
            }
        }

        private func apply(
            _ update: ContinuedProcessingUpdate,
            to task: BGContinuedProcessingTask?
        ) {
            guard let task else { return }
            // Publish a determinate progress value before asking the system to
            // refresh its UI. The task starts with 0/0 progress; updating the
            // title first can snapshot that indeterminate state and omit the
            // continued-processing activity on iOS 26.6.
            task.progress.totalUnitCount = update.totalUnitCount
            task.progress.completedUnitCount = min(
                update.completedUnitCount,
                update.totalUnitCount
            )
            task.updateTitle(update.title, subtitle: update.subtitle)
        }

        private func expire(identifier: String) {
            guard let entry = entries.removeValue(forKey: identifier) else { return }
            // Expiration ends only CtrlX's finite local monitoring lease. The
            // Agent runs remotely and did not fail, so do not ask iOS to show a
            // misleading failure state in the system activity.
            if let task = entry.task {
                task.progress.completedUnitCount = task.progress.totalUnitCount
                task.setTaskCompleted(success: true)
            }
            logger.info(
                "Continued-processing monitoring lease expired: \(identifier, privacy: .public)"
            )
            entry.request.expirationHandler()
        }

        private static var identifierPrefix: String {
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.gravtice.ctrlx"
            return "\(bundleIdentifier).agent-monitor."
        }
    }
#endif
