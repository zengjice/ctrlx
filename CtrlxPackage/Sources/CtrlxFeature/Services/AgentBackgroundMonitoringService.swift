#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import os

    /// Owns one finite iOS 26 monitoring session for active Agent turns.
    ///
    /// Concurrent turns share one system task. The first foreground submission
    /// starts it and the last terminal turn completes it, avoiding both per-prompt
    /// request races and an idle task that iOS can later present as failed.
    @Observable
    @MainActor
    final public class AgentBackgroundMonitoringService {
        public static let shared = AgentBackgroundMonitoringService()

        public enum MonitoringStatus: Sendable, Equatable {
            case inactive
            case starting
            case active
        }

        public struct TerminalNotification: Sendable, Equatable {
            public let hostId: String
            public let paneId: String
            public let title: String
            public let subtitle: String
            public let body: String
        }

        private enum EventSource {
            case live
            case snapshot
        }

        private struct PaneContext {
            let sessionName: String
            let windowName: String
        }

        private struct MonitoringSession {
            let identifier: String
            let startedAt: Date
            var isLaunched: Bool
            var title: String
            var subtitle: String
            var completedActivityUnits: Int64
            var activityUnitLimit: Int64
        }

        @ObservationIgnored
        @Dependency(ContinuedProcessingClient.self) private var continuedProcessing

        /// The app wires its already-owned manager after async initialization.
        /// Weak ownership avoids a callback cycle (`manager -> service -> manager`).
        @ObservationIgnored
        public weak var connectionManager: ViewerConnectionManager?

        private let logger = Logger(
            subsystem: "com.jicezeng.ctrlx",
            category: "AgentBackgroundMonitoring"
        )
        private var monitoringSession: MonitoringSession?
        private var paneContexts: [PaneKey: PaneContext] = [:]
        private var panePhases: [PaneKey: AgentBackgroundMonitoringPolicy.Phase] = [:]
        /// Terminal line state belongs to the monitor, not a transient SwiftUI
        /// view. UIKit can retain an older callback while a pane view is replaced.
        private var terminalInputs: [PaneKey: AgentPromptInputAccumulator] = [:]
        private var lastConnectionProbeAtByHost: [String: Date] = [:]
        private var lastSnapshotAtByHost: [String: Date] = [:]
        private var pendingSnapshotRequestAtByHost: [String: Date] = [:]
        private var lastNotificationDeliveryAtByPane: [PaneKey: Date] = [:]
        private var sceneIsActive = true
        public private(set) var lastStartFailure: String?

        @ObservationIgnored
        private var activityReporter: Task<Void, Never>?

        public init() { }

        public var monitoringStatus: MonitoringStatus {
            guard let monitoringSession else { return .inactive }
            return monitoringSession.isLaunched ? .active : .starting
        }

        /// Reclaim system requests left by an earlier app process.
        public func prepare() {
            guard #available(iOS 26.0, *) else { return }
            continuedProcessing.prepare()
        }

        /// Start the shared monitoring lease from a foreground Agent submission.
        ///
        /// `BGContinuedProcessingTaskRequest` requires an explicit user action;
        /// app-launch and scene-phase callbacks must not call this method.
        private func startMonitoringSession() -> Bool {
            guard
                #available(iOS 26.0, *),
                sceneIsActive
            else { return false }
            if monitoringSession != nil { return true }

            lastStartFailure = nil
            let identifier = Self.makeIdentifier()
            let session = MonitoringSession(
                identifier: identifier,
                startedAt: Date(),
                isLaunched: false,
                title: "CtrlX",
                subtitle: "Waiting for Agent",
                completedActivityUnits: AgentBackgroundMonitoringPolicy.initialActivityUnits,
                activityUnitLimit: AgentBackgroundMonitoringPolicy.maximumActivityUnits
            )
            monitoringSession = session

            do {
                try continuedProcessing.start(ContinuedProcessingRequest(
                    identifier: identifier,
                    title: session.title,
                    subtitle: session.subtitle,
                    launchHandler: { [weak self] in
                        self?.handleLaunch(identifier: identifier)
                    },
                    expirationHandler: { [weak self] in
                        self?.handleExpiration(identifier: identifier)
                    }
                ))
                guard monitoringSession?.identifier == identifier else { return false }
                startActivityReporter(identifier: identifier)
                logger.info(
                    "Agent monitoring session submitted at \(session.startedAt.timeIntervalSince1970, privacy: .public)"
                )
                return true
            } catch {
                if monitoringSession?.identifier == identifier {
                    monitoringSession = nil
                }
                activityReporter?.cancel()
                activityReporter = nil
                let failure = error as NSError
                lastStartFailure = "\(failure.domain) (\(failure.code)): \(failure.localizedDescription)"
                logger.error(
                    "Continued processing unavailable; using notifications only: \(self.lastStartFailure ?? "unknown error", privacy: .public)"
                )
                return false
            }
        }

        public func startIfNeeded(
            for response: AgentResponse,
            hostId: String,
            paneId: String,
            sessionName: String,
            windowName: String
        ) {
            guard AgentBackgroundMonitoringPolicy.shouldStart(for: response) else { return }
            start(
                hostId: hostId,
                paneId: paneId,
                sessionName: sessionName,
                windowName: windowName
            )
        }

        /// Record a user-submitted turn in the shared monitor. Concurrent turns
        /// reuse the existing task.
        public func start(
            hostId: String,
            paneId: String,
            sessionName: String,
            windowName: String
        ) {
            guard #available(iOS 26.0, *) else { return }
            guard startMonitoringSession() else { return }

            let key = PaneKey(pairId: hostId, paneId: paneId)
            rememberContext(
                key: key,
                sessionName: sessionName,
                windowName: windowName
            )
            panePhases[key] = .waitingForAgent
            lastNotificationDeliveryAtByPane.removeValue(forKey: key)
            refreshCard()
        }

        public func handleTerminalInput(
            _ keys: [TmuxKey],
            hostId: String,
            paneId: String,
            sessionName: String,
            windowName: String,
            currentState: AgentState?
        ) {
            let key = PaneKey(pairId: hostId, paneId: paneId)
            var input = terminalInputs[key] ?? AgentPromptInputAccumulator()
            let submittedPrompt = input.consume(keys)
            terminalInputs[key] = input
            guard submittedPrompt else { return }

            // Remember the pane even before process classification completes.
            // A later real Agent state can then show the correct card title;
            // ordinary shell commands do not change the card by themselves.
            rememberContext(
                key: key,
                sessionName: sessionName,
                windowName: windowName
            )
            guard
                let currentState,
                AgentBackgroundMonitoringPolicy.canSubmitPrompt(from: currentState)
            else { return }

            guard startMonitoringSession() else { return }
            panePhases[key] = .waitingForAgent
            lastNotificationDeliveryAtByPane.removeValue(forKey: key)
            refreshCard()
        }

        public func handleTerminalPaste(_ text: String, hostId: String, paneId: String) {
            let key = PaneKey(pairId: hostId, paneId: paneId)
            var input = terminalInputs[key] ?? AgentPromptInputAccumulator()
            input.recordPaste(text)
            terminalInputs[key] = input
        }

        public func resetTerminalInput(hostId: String, paneId: String) {
            terminalInputs.removeValue(
                forKey: PaneKey(pairId: hostId, paneId: paneId)
            )
        }

        public func handle(
            _ status: AgentSessionStatusMessage,
            beforeFinishing: (TerminalNotification) -> Void
        ) {
            let key = PaneKey(pairId: status.pairId, paneId: status.sessionId)
            logDeliveryDelay(
                stage: "status received",
                eventAt: status.timestamp,
                observedAt: Date(),
                key: key
            )
            guard monitoringSession != nil else { return }
            apply(
                status.state,
                to: key,
                source: .live,
                beforeFinishing: beforeFinishing
            )
        }

        /// Reconcile Agent state missed while the Viewer transport was suspended.
        /// A terminal snapshot ends the system task when it closes the last turn.
        public func handle(
            _ state: SessionStateMessage,
            beforeFinishing: (TerminalNotification) -> Void
        ) {
            let receivedAt = Date()
            lastSnapshotAtByHost[state.pairId] = receivedAt
            if let requestedAt = pendingSnapshotRequestAtByHost.removeValue(forKey: state.pairId) {
                logSnapshotRoundTrip(
                    hostId: state.pairId,
                    requestedAt: requestedAt,
                    receivedAt: receivedAt
                )
            }

            for (paneId, paneState) in state.paneStates {
                let key = PaneKey(pairId: state.pairId, paneId: paneId)
                rememberContext(
                    key: key,
                    sessionName: paneState.sessionName,
                    windowName: paneState.windowName
                )
                guard
                    monitoringSession != nil,
                    let agentState = paneState.agentSession?.state
                else { continue }
                apply(
                    agentState,
                    to: key,
                    source: .snapshot,
                    beforeFinishing: beforeFinishing
                )
            }

            // A pane that disappeared after `.working` completed from the
            // viewer's perspective. Ignore missing panes that were already idle.
            let missingWorkingKeys = panePhases.keys.filter {
                $0.pairId == state.pairId
                    && panePhases[$0] == .working
                    && state.paneStates[$0.paneId] == nil
            }
            for key in missingWorkingKeys {
                apply(
                    .idle,
                    to: key,
                    source: .snapshot,
                    beforeFinishing: beforeFinishing
                )
            }
        }

        public func noteNotificationReceived(_ notification: AgentNotificationMessage) {
            let key = PaneKey(
                pairId: notification.pairId,
                paneId: notification.sessionId ?? "unknown"
            )
            logDeliveryDelay(
                stage: "notification received",
                eventAt: notification.timestamp,
                observedAt: Date(),
                key: key
            )
        }

        public func noteLocalNotificationScheduled(_ notification: AgentNotificationMessage) {
            let key = PaneKey(
                pairId: notification.pairId,
                paneId: notification.sessionId ?? "unknown"
            )
            logDeliveryDelay(
                stage: "local notification scheduled",
                eventAt: notification.timestamp,
                observedAt: Date(),
                key: key
            )
        }

        /// Status, recovery snapshot and rich notification frames can race.
        /// Only the first plain alert for a pane wins; actionable alerts always win.
        public func reserveNotificationDelivery(
            for notification: AgentNotificationMessage
        ) -> Bool {
            guard let paneId = notification.sessionId else { return true }
            return reserveNotificationDelivery(
                for: PaneKey(pairId: notification.pairId, paneId: paneId),
                alwaysAllow: notification.action != nil
            )
        }

        public func reserveNotificationDelivery(
            for notification: TerminalNotification
        ) -> Bool {
            reserveNotificationDelivery(
                for: PaneKey(pairId: notification.hostId, paneId: notification.paneId),
                alwaysAllow: false
            )
        }

        public func noteSceneActive(_ active: Bool) {
            let wasActive = sceneIsActive
            sceneIsActive = active
            logger.info(
                "Scene \(active ? "active" : "background", privacy: .public); globalMonitor=\(self.monitoringSession != nil, privacy: .public)"
            )

            if active {
                guard !wasActive else { return }
                renewMonitoringLease()
                return
            }

            guard let identifier = monitoringSession?.identifier else { return }
            kickConnectionMaintenance(identifier: identifier)
        }

        /// A Host lifecycle change removes its turns. Other active Hosts keep the
        /// shared task alive.
        public func removeHost(_ hostId: String) {
            paneContexts = paneContexts.filter { $0.key.pairId != hostId }
            panePhases = panePhases.filter { $0.key.pairId != hostId }
            terminalInputs = terminalInputs.filter { $0.key.pairId != hostId }
            lastNotificationDeliveryAtByPane = lastNotificationDeliveryAtByPane.filter {
                $0.key.pairId != hostId
            }
            lastConnectionProbeAtByHost.removeValue(forKey: hostId)
            lastSnapshotAtByHost.removeValue(forKey: hostId)
            pendingSnapshotRequestAtByHost.removeValue(forKey: hostId)
            refreshOrFinishMonitoring(finalSubtitle: "Monitoring ended")
        }

        public func removePane(hostId: String, paneId: String) {
            let key = PaneKey(pairId: hostId, paneId: paneId)
            paneContexts.removeValue(forKey: key)
            panePhases.removeValue(forKey: key)
            terminalInputs.removeValue(forKey: key)
            lastNotificationDeliveryAtByPane.removeValue(forKey: key)
            refreshOrFinishMonitoring(finalSubtitle: "Monitoring ended")
        }

        public func stopAll() {
            finishMonitoringSession(subtitle: "Monitoring off")
            resetAllState()
            lastStartFailure = nil
        }

        private func clearMonitoringSessionState() {
            monitoringSession = nil
            panePhases.removeAll()
            lastConnectionProbeAtByHost.removeAll()
            lastSnapshotAtByHost.removeAll()
            pendingSnapshotRequestAtByHost.removeAll()
            activityReporter?.cancel()
            activityReporter = nil
        }

        private func resetAllState() {
            clearMonitoringSessionState()
            paneContexts.removeAll()
            terminalInputs.removeAll()
            lastNotificationDeliveryAtByPane.removeAll()
        }

        private func apply(
            _ state: AgentState,
            to key: PaneKey,
            source: EventSource,
            beforeFinishing: (TerminalNotification) -> Void
        ) {
            guard monitoringSession != nil else { return }
            let phase = panePhases[key] ?? .waitingForAgent

            // A snapshot containing a terminal state for an unobserved pane is
            // usually stale. It cannot prove a transition, so do not manufacture
            // a completion alert. Live terminal states remain authoritative.
            if source == .snapshot, phase == .waitingForAgent, state != .working {
                return
            }

            switch AgentBackgroundMonitoringPolicy.decision(for: state, phase: phase) {
            case let .keep(nextPhase):
                // An unrelated idle pane is not an active turn. Only an observed
                // submission or a real working state may enter the shared task.
                guard panePhases[key] != nil || nextPhase == .working else { return }
                panePhases[key] = nextPhase
                if nextPhase == .working {
                    refreshCard()
                }

            case let .terminal(reason):
                guard panePhases[key] != nil else { return }
                let subtitle = switch reason {
                case .completed: "Finished"
                case .waitingForInput: "Needs input"
                }

                if AgentBackgroundMonitoringPolicy.shouldEmitTerminalNotification(
                    reason: reason,
                    recoveredFromSnapshot: source == .snapshot
                ) {
                    beforeFinishing(TerminalNotification(
                        hostId: key.pairId,
                        paneId: key.paneId,
                        title: title(for: key),
                        subtitle: subtitle,
                        body: Self.notificationBody(for: state, reason: reason)
                    ))
                }

                panePhases.removeValue(forKey: key)
                paneContexts.removeValue(forKey: key)
                terminalInputs.removeValue(forKey: key)
                refreshOrFinishMonitoring(finalSubtitle: subtitle)
            }
        }

        private func rememberContext(
            key: PaneKey,
            sessionName: String,
            windowName: String
        ) {
            paneContexts[key] = PaneContext(
                sessionName: sessionName,
                windowName: windowName
            )
        }

        private func refreshCard() {
            guard var session = monitoringSession, !panePhases.isEmpty else { return }
            let workingAgentCount = panePhases.values.lazy.filter { $0 == .working }.count
            session.title = "CtrlX"
            session.subtitle = switch workingAgentCount {
            case 0: "Waiting for Agent"
            case 1: "1 Agent working"
            default: "\(workingAgentCount) Agents working"
            }
            monitoringSession = session
            continuedProcessing.update(
                session.identifier,
                ContinuedProcessingUpdate(
                    title: session.title,
                    subtitle: session.subtitle,
                    completedUnitCount: session.completedActivityUnits,
                    totalUnitCount: session.activityUnitLimit
                )
            )
        }

        private func refreshOrFinishMonitoring(finalSubtitle: String) {
            if panePhases.isEmpty {
                finishMonitoringSession(subtitle: finalSubtitle)
            } else {
                refreshCard()
            }
        }

        private func finishMonitoringSession(subtitle: String) {
            guard var session = monitoringSession else { return }
            let identifier = session.identifier
            session.subtitle = subtitle
            session.completedActivityUnits = session.activityUnitLimit
            continuedProcessing.update(
                identifier,
                ContinuedProcessingUpdate(
                    title: session.title,
                    subtitle: subtitle,
                    completedUnitCount: session.activityUnitLimit,
                    totalUnitCount: session.activityUnitLimit
                )
            )
            clearMonitoringSessionState()
            continuedProcessing.finish(identifier)
            logger.info(
                "Agent monitoring session completed: \(identifier, privacy: .public)"
            )
        }

        private func renewMonitoringLease() {
            guard var session = monitoringSession else { return }
            let renewedLimit = AgentBackgroundMonitoringPolicy.renewedActivityUnitLimit(
                after: session.completedActivityUnits
            )
            guard renewedLimit > session.activityUnitLimit else { return }

            session.activityUnitLimit = renewedLimit
            monitoringSession = session
            continuedProcessing.update(
                session.identifier,
                ContinuedProcessingUpdate(
                    title: session.title,
                    subtitle: session.subtitle,
                    completedUnitCount: session.completedActivityUnits,
                    totalUnitCount: session.activityUnitLimit
                )
            )
            logger.info(
                "Agent monitoring session renewed at unit \(session.completedActivityUnits, privacy: .public); limit=\(session.activityUnitLimit, privacy: .public)"
            )
        }

        private func handleLaunch(identifier: String) {
            guard var session = monitoringSession, session.identifier == identifier else { return }
            session.isLaunched = true
            monitoringSession = session
            let delay = Date().timeIntervalSince(session.startedAt)
            logger.info(
                "Agent monitoring session launched after \(String(format: "%.3f", delay), privacy: .public)s"
            )
            kickConnectionMaintenance(identifier: identifier)
        }

        private func handleExpiration(identifier: String) {
            guard let session = monitoringSession, session.identifier == identifier else { return }
            let lifetime = Date().timeIntervalSince(session.startedAt)
            resetAllState()
            logger.warning(
                "Agent monitoring session expired after \(String(format: "%.3f", lifetime), privacy: .public)s"
            )
        }

        private func startActivityReporter(identifier: String) {
            activityReporter?.cancel()
            activityReporter = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(10))
                    } catch {
                        return
                    }

                    guard let self else { return }
                    await self.maintainConnections(identifier: identifier)
                    guard self.reportActivity(identifier: identifier) else { return }
                }
            }
        }

        private func kickConnectionMaintenance(identifier: String) {
            Task { [weak self] in
                await self?.maintainConnections(identifier: identifier)
            }
        }

        private func maintainConnections(identifier: String) async {
            guard
                monitoringSession?.identifier == identifier,
                let connectionManager
            else { return }

            for hostId in connectionManager.managedHostIDs {
                guard monitoringSession?.identifier == identifier else { return }
                let now = Date()
                if let lastProbeAt = lastConnectionProbeAtByHost[hostId],
                   now.timeIntervalSince(lastProbeAt)
                    < AgentBackgroundMonitoringPolicy.connectionProbeInterval {
                    continue
                }
                lastConnectionProbeAtByHost[hostId] = now

                let requestSnapshot = AgentBackgroundMonitoringPolicy.shouldRequestSnapshot(
                    sessionStartedAt: monitoringSession?.startedAt ?? now,
                    lastSnapshotAt: lastSnapshotAtByHost[hostId],
                    now: now
                )
                if requestSnapshot {
                    lastSnapshotAtByHost[hostId] = now
                    pendingSnapshotRequestAtByHost[hostId] = now
                }

                let requested = await connectionManager.maintainBackgroundConnection(
                    for: hostId,
                    requestSessionState: requestSnapshot,
                    staleAfter: AgentBackgroundMonitoringPolicy.connectionStaleInterval
                )
                guard requestSnapshot, !requested else { continue }
                if lastSnapshotAtByHost[hostId] == now {
                    lastSnapshotAtByHost.removeValue(forKey: hostId)
                }
                if pendingSnapshotRequestAtByHost[hostId] == now {
                    pendingSnapshotRequestAtByHost.removeValue(forKey: hostId)
                }
            }
        }

        private func reportActivity(identifier: String) -> Bool {
            guard var session = monitoringSession, session.identifier == identifier else {
                return false
            }
            guard let nextUnit = AgentBackgroundMonitoringPolicy.nextActivityUnit(
                after: session.completedActivityUnits,
                limit: session.activityUnitLimit
            ) else {
                finishMonitoringSession(subtitle: "Monitoring ended")
                return false
            }

            session.completedActivityUnits = nextUnit
            monitoringSession = session
            continuedProcessing.update(
                identifier,
                ContinuedProcessingUpdate(
                    title: session.title,
                    subtitle: session.subtitle,
                    completedUnitCount: nextUnit,
                    totalUnitCount: session.activityUnitLimit
                )
            )
            return true
        }

        private func reserveNotificationDelivery(
            for key: PaneKey,
            alwaysAllow: Bool
        ) -> Bool {
            let now = Date()
            lastNotificationDeliveryAtByPane = lastNotificationDeliveryAtByPane.filter {
                AgentBackgroundMonitoringPolicy.isDuplicateNotification(
                    lastDeliveredAt: $0.value,
                    now: now
                )
            }

            let duplicate = AgentBackgroundMonitoringPolicy.isDuplicateNotification(
                lastDeliveredAt: lastNotificationDeliveryAtByPane[key],
                now: now
            )
            guard alwaysAllow || !duplicate else {
                logger.debug(
                    "Suppressing duplicate Agent notification for host=\(key.pairId, privacy: .private(mask: .hash)) pane=\(key.paneId, privacy: .public)"
                )
                return false
            }
            lastNotificationDeliveryAtByPane[key] = now
            return true
        }

        private func logDeliveryDelay(
            stage: String,
            eventAt: Date,
            observedAt: Date,
            key: PaneKey
        ) {
            let delay = AgentBackgroundMonitoringPolicy.deliveryDelay(
                eventAt: eventAt,
                receivedAt: observedAt
            )
            guard delay >= AgentBackgroundMonitoringPolicy.deliveryWarningThreshold else {
                return
            }
            logger.warning(
                "Delayed Agent \(stage, privacy: .public): delay=\(String(format: "%.3f", delay), privacy: .public)s eventAt=\(eventAt.timeIntervalSince1970, privacy: .public) receivedAt=\(observedAt.timeIntervalSince1970, privacy: .public) host=\(key.pairId, privacy: .private(mask: .hash)) pane=\(key.paneId, privacy: .public)"
            )
        }

        private func logSnapshotRoundTrip(
            hostId: String,
            requestedAt: Date,
            receivedAt: Date
        ) {
            let delay = receivedAt.timeIntervalSince(requestedAt)
            guard delay >= AgentBackgroundMonitoringPolicy.deliveryWarningThreshold else {
                return
            }
            logger.warning(
                "Slow Agent reconciliation snapshot: delay=\(String(format: "%.3f", delay), privacy: .public)s requestedAt=\(requestedAt.timeIntervalSince1970, privacy: .public) receivedAt=\(receivedAt.timeIntervalSince1970, privacy: .public) host=\(hostId, privacy: .private(mask: .hash))"
            )
        }

        private func title(for key: PaneKey) -> String {
            guard let context = paneContexts[key] else { return "CtrlX" }
            return context.windowName.isEmpty
                ? context.sessionName
                : "\(context.sessionName) · \(context.windowName)"
        }

        private static func notificationBody(
            for state: AgentState,
            reason: AgentBackgroundMonitoringPolicy.TerminalReason
        ) -> String {
            if case let .doneWorking(summary) = state,
               let summary,
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return summary
            }
            return switch reason {
            case .completed: "Agent finished working."
            case .waitingForInput: "Agent is waiting for your input."
            }
        }

        private static func makeIdentifier() -> String {
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.jicezeng.ctrlx"
            return "\(bundleIdentifier).agent-monitor.\(UUID().uuidString)"
        }
    }
#endif
