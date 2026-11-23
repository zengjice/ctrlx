import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// A delivery fact, not an Agent, task or workflow. Runtime evidence is immutable
/// after native acceptance; later messages resolve the Agent's current runtime.
struct AgentMessage: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    var instance: AgentWorkflowInstance
    let text: String
    var prompt: String
    var status: AgentWorkflowInvocationStatus = .pending
    var nativeEvent: PluginWorkflowEvent?
    struct Attachment: Codable, Equatable, Sendable {
        let metadata: AgentWorkflowAttachment
        let path: String
    }

    var attachments: [Attachment]?
    var activity: [AgentTurnActivity]?
    var needsFailureActivity: Bool?
    var activitySource: AgentActivitySnapshot.Source?
    var answer: String?
    var completedAt: Date?
    var issue: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case instance
        case text
        case prompt
        case status
        case nativeEvent
        case attachments
        case activity
        case needsFailureActivity
        case answer
        case completedAt
        case issue
        case activitySource = "failureActivitySource"
    }

    var agentID: AgentID {
        instance.agentID
    }

    var isPending: Bool {
        [.pending, .writing, .awaitingAcceptance, .running, .uncertain].contains(status)
    }

    var needsReplyRecovery: Bool {
        isPending || needsFailureActivity == true
    }

    mutating func recordNativeFailure(_ event: PluginWorkflowEvent) {
        nativeEvent = event
        status = .failed
        issue = event.text
        completedAt = Date()
        needsFailureActivity = true
    }

    @discardableResult
    mutating func mergeActivity(_ snapshot: AgentActivitySnapshot, finalizing: Bool = false, preferObservedOrder: Bool = true) -> Bool {
        let previous = activity
        let previousSource = activitySource
        let source = if let previousSource, let observedSource = snapshot.source, previousSource != observedSource {
            AgentActivitySnapshot.Source.rotated
        } else {
            previousSource ?? snapshot.source
        }
        let rotated = source == .rotated
        activity?.removeAll { snapshot.evictedActivityIDs.contains($0.id) }
        mergeActivity(snapshot.entries, preferTimestamps: rotated, preferObservedOrder: rotated && preferObservedOrder)
        activitySource = finalizing ? nil : source
        return activity != previous || activitySource != previousSource
    }

    @discardableResult
    mutating func mergeActivity(_ observed: [AgentTurnActivity], preferTimestamps: Bool = false, preferObservedOrder: Bool = false) -> Bool {
        guard !observed.isEmpty else { return false }
        let saved = activity ?? []
        let merged = if preferObservedOrder {
            AgentTurnActivity.merging(saved, into: observed, preferTimestamps: preferTimestamps)
        } else {
            AgentTurnActivity.merging(observed, into: saved, preferTimestamps: preferTimestamps)
        }
        // Keep shared IDs available until the result is merged with saved activity.
        let recent = Array(merged.suffix(AgentTurnActivityLog.maximumEntries))
        guard recent != activity else { return false }
        activity = recent
        return true
    }

    init(id: UUID = UUID(), instance: AgentWorkflowInstance, text: String, instructions: String = "", now: Date = Date()) {
        self.id = id
        self.createdAt = now
        self.instance = instance
        self.text = text
        self.prompt = [text, instructions, "[CtrlX message: \(id.uuidString)]"].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

extension AgentTurnActivity {
    static func merging(_ observed: [Self], into saved: [Self], preferTimestamps: Bool = false) -> [Self] {
        guard !saved.isEmpty else { return observed }
        var merged = saved
        let savedIDs = Set(saved.map(\.id))
        var insertionIndex = merged.endIndex
        for (position, entry) in observed.enumerated().reversed() {
            if let index = merged.firstIndex(where: { $0.id == entry.id }) {
                if merged[index].timestamp == nil {
                    merged[index].timestamp = entry.timestamp
                }
                insertionIndex = index
            } else {
                let precedingID = observed[..<position].last { savedIDs.contains($0.id) }?.id
                let precedingIndex = precedingID.flatMap { id in merged.firstIndex { $0.id == id } }
                // Timestamps cannot move an entry ahead of a known predecessor.
                let lowerBound = min(precedingIndex.map { $0 + 1 } ?? 0, insertionIndex)
                let index = (lowerBound..<insertionIndex).first { index in
                    let existing = merged[index]
                    if
                        let time = entry.timestamp, let existingTime = existing.timestamp,
                        preferTimestamps || (entry.hasAlignedSequence != true && existingTime != time) {
                        return existingTime > time
                    }
                    return entry.sequence.map { (existing.sequence ?? (index + 1)) >= $0 } ?? false
                }
                insertionIndex = index ?? insertionIndex
                if preferTimestamps, let time = entry.timestamp {
                    // Walk equal-time entries from the end to preserve their recorded order.
                    while
                        insertionIndex > lowerBound,
                        merged[insertionIndex - 1].timestamp == time,
                        merged[insertionIndex - 1].id > entry.id {
                        insertionIndex -= 1
                    }
                }
                merged.insert(entry, at: insertionIndex)
            }
        }
        return merged
    }
}

struct AgentMessagePage: Sendable {
    var messages: [AgentMessage] = []
    var olderPageEndID: UUID?
    var newerPageEndID: UUID?
}

/// Separate files keep saving a new receipt independent of accumulated history.
actor AgentMessageStore {
    let directory: URL
    private var authorizations: [UUID: AgentWorkflowWriteAuthorization] = [:]
    private var active: [UUID: AgentMessage]?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func message(_ id: UUID) throws -> AgentMessage? {
        let file = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let message = try JSONDecoder().decode(AgentMessage.self, from: Data(contentsOf: file))
        guard message.id == id else { throw AgentWorkflowError("The message record has an invalid identity. Its data was preserved.") }
        return message
    }

    func messages(_ ids: [UUID], limit: Int = 100) throws -> [AgentMessage] {
        try page(ids, limit: limit).messages
    }

    func page(_ ids: [UUID], endingAt id: UUID? = nil, limit: Int = 100) throws -> AgentMessagePage {
        let end: Int
        if let id {
            guard let index = ids.firstIndex(of: id) else { throw AgentWorkflowError("This history page is no longer available. Return to the latest messages.") }
            end = index + 1
        } else {
            end = ids.count
        }
        let count = max(1, min(limit, 200))
        let start = max(0, end - count)
        return try AgentMessagePage(
            messages: ids[start..<end].compactMap { try message($0) },
            olderPageEndID: start > 0 ? ids[start - 1] : nil,
            newerPageEndID: end < ids.count ? ids[min(ids.count, end + count) - 1] : nil
        )
    }

    func pending() throws -> [AgentMessage] {
        try recoverableReplies().filter(\.isPending)
    }

    func recoverableReplies() throws -> [AgentMessage] {
        if let active {
            return Array(active.values)
        }
        guard FileManager.default.fileExists(atPath: directory.path) else { active = [:]
            return []
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let messages = try files.filter { $0.pathExtension == "json" }.compactMap { file -> AgentMessage? in
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return nil }
            let entry = try message(id)
            return entry?.needsReplyRecovery == true ? entry : nil
        }
        active = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        return messages
    }

    func insert(_ message: AgentMessage) throws {
        guard try self.message(message.id) == nil else {
            throw AgentWorkflowError("This message already exists. It was not sent again.")
        }
        guard try !pending().contains(where: { $0.agentID == message.agentID }) else {
            throw AgentWorkflowError("This Agent has an unfinished message. Review it in its terminal before sending again.")
        }
        try save(message)
    }

    func update(_ id: UUID, _ change: @Sendable (inout AgentMessage) throws -> Void) throws {
        guard var message = try message(id) else { throw AgentWorkflowError("The message was not found.") }
        try change(&message)
        try save(message)
    }

    func updateActivity(_ activity: AgentActivitySnapshot, for context: AgentReplyContext) throws -> AgentMessage? {
        guard
            var message = try message(context.id), message.isPending,
            message.instance.matchesConversation(context.instance),
            message.nativeEvent?.nativeTurnID == context.candidate.nativeTurnID,
            message.nativeEvent?.transcriptPath == context.candidate.transcriptPath else { return nil }
        if message.mergeActivity(activity) {
            try save(message)
        }
        return message
    }

    func saveRecoveredActivity(_ result: AgentActivitySnapshot, for context: AgentReplyContext, finalizing: Bool = true) throws {
        guard
            var message = try message(context.id), message.status == .failed,
            message.nativeEvent == context.candidate, message.needsFailureActivity == true,
            message.instance.matchesConversation(context.instance) else { return }
        let isComplete = finalizing && result.isComplete
        // A complete replay supplies the cross-file order for IDs in a partial save.
        let changed = message.mergeActivity(result, finalizing: isComplete, preferObservedOrder: isComplete)
        if isComplete {
            message.needsFailureActivity = nil
        }
        guard changed || isComplete else { return }
        try save(message)
    }

    func importMessage(_ message: AgentMessage) throws {
        if try self.message(message.id) == nil {
            try save(message)
        }
    }

    func copyAttachments(_ files: [AgentWorkflowAttachmentFile], messageID: UUID) throws -> [AgentMessage.Attachment] {
        try files.map { source in
            let parent = directory.appendingPathComponent("attachments/\(messageID.uuidString)/\(source.attachment.id.uuidString)")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = parent.appendingPathComponent(source.url.lastPathComponent)
            if FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.contentsEqual(atPath: file.path, andPath: source.url.path) else {
                    throw AgentWorkflowError("The migrated attachment differs from its source. Both copies were preserved.")
                }
            } else {
                try FileManager.default.copyItem(at: source.url, to: file)
            }
            return AgentMessage.Attachment(metadata: source.attachment, path: file.path)
        }
    }

    func authorize(_ id: UUID) throws -> AgentWorkflowWriteAuthorization {
        guard try message(id)?.status == .writing else { throw AgentWorkflowError("This message is no longer authorized to submit input.") }
        let permit = AgentWorkflowWriteAuthorization(expiresAt: Date().addingTimeInterval(30))
        authorizations[id]?.revoke()
        authorizations[id] = permit
        return permit
    }

    func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func save(_ message: AgentMessage) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(message.id.uuidString).appendingPathExtension("json")
        try JSONEncoder().encode(message).write(to: file, options: .atomic)
        if message.status != .writing {
            authorizations.removeValue(forKey: message.id)?.revoke()
        }
        if active != nil {
            active?[message.id] = message.needsReplyRecovery ? message : nil
        }
        for observer in observers.values {
            observer.yield(())
        }
    }
}
