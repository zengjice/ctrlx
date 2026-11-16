import CtrlxNetworking
import Darwin
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentInteractionResourceTests {
    @Test
    func onlyActiveMessagesKeepObserversAndHistoryReadsStayBounded() async throws {
        let f = try await AgentInteractionTestSupport()
        try await sample("idle", f: f, expectedAcknowledgements: 0)
        for index in 0..<5 {
            _ = try f.create(UUID(), pluginID: "codex", title: "Agent \(index)", directory: f.root.path)
        }
        let instances = try await f.catalog.snapshot(refresh: true)
        try await sample("five-idle-agents", f: f, expectedAcknowledgements: 0)
        var sent: [AgentMessage] = []
        for instance in instances {
            let message = AgentMessage(instance: instance, text: "hello")
            try await f.interaction.send(message)
            sent.append(message)
        }
        try await sample("five-pending-messages", f: f, expectedAcknowledgements: 5)
        for message in sent {
            try await f.complete(message)
        }
        try await Task.sleep(for: .milliseconds(250))
        try await sample("completed", f: f, expectedAcknowledgements: 0)
        var ids: [UUID] = []
        for index in 0..<250 {
            var message = AgentMessage(instance: instances[0], text: "saved \(index)")
            message.status = .succeeded
            message.answer = String(repeating: "reply ", count: 100)
            try await f.interaction.store.importMessage(message)
            ids.append(message.id)
        }
        let start = ContinuousClock.now
        #expect(try await f.interaction.store.messages(ids).count == 100)
        print("AGENT_RESOURCE history_read=\(start.duration(to: .now)) stored_messages=255")
        try await sample("retained-history", f: f, expectedAcknowledgements: 0)
        try await f.cleanup()
    }

    private func sample(_ label: String, f: AgentInteractionTestSupport, expectedAcknowledgements: Int) async throws {
        var before = rusage(), after = rusage()
        _ = getrusage(RUSAGE_SELF, &before)
        try await Task.sleep(for: .milliseconds(200))
        _ = getrusage(RUSAGE_SELF, &after)
        let cpu = Double(after.ru_utime.tv_sec - before.ru_utime.tv_sec + after.ru_stime.tv_sec - before.ru_stime.tv_sec)
            + Double(after.ru_utime.tv_usec - before.ru_utime.tv_usec + after.ru_stime.tv_usec - before.ru_stime.tv_usec) / 1_000_000
        let counts = await f.interaction.observationCounts()
        #expect(counts.receipts == 0 && counts.transcripts == 0 && counts.acknowledgements == expectedAcknowledgements)
        let directory = await f.interaction.store.directory
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = try files.filter { $0.pathExtension == "json" }.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        print("AGENT_RESOURCE state=\(label) observers=\(counts) cpu_seconds_200ms=\(cpu) process_peak_rss_bytes=\(after.ru_maxrss) message_bytes=\(bytes)")
    }
}
