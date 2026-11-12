import CtrlxShare
import Foundation
import Testing
@testable import CtrlxCommon
@testable import CtrlxFeature

@MainActor
struct IOSShareInboxTests {
    @Test("Photos and files have fixed destinations; photo requests keep the Host and pane identity")
    func routingAndAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-inbox-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("payload".utf8).write(to: source)
        let storage = ShareInboxStore(root: root.appendingPathComponent("inbox"))
        let batch = try await storage.begin()
        let directory = await storage.stagingDirectory(batch)
        let photo = try PreparedSharedItem.copy(from: source, to: directory, name: "photo.heic", kind: .photo)
        let file = try PreparedSharedItem.copy(from: source, to: directory, name: "file.pdf", kind: .file)
        try await storage.commit(batch, entries: [photo, file])

        let inbox = IOSShareInbox(storage: storage)
        await inbox.refresh()
        #expect(inbox.photos.map(\.name) == ["photo.heic"])
        #expect(inbox.files.map(\.name) == ["file.pdf"])
        let target = TerminalPhraseContext(hostID: "host-a", paneID: "%1", inputRevision: 1, isConnected: true, isInputAvailable: true)
        let receiver = UUID()
        inbox.requestPhotos(for: target, receiverID: receiver)
        #expect(inbox.takePhotos(for: .init(hostID: "host-b", paneID: "%1", inputRevision: 1, isConnected: true, isInputAvailable: true), receiverID: receiver) == nil)
        #expect(inbox.takePhotos(for: target, receiverID: UUID()) == nil, "Another window showing the same pane must not take the request")
        #expect(inbox.photoRequest?.target == target.target)
        #expect(inbox.takePhotos(for: target, receiverID: receiver)?.map(\.id) == [photo.id])
        #expect(inbox.photosBusy)
        inbox.finishPhotos()
        #expect(inbox.photos.count == 1, "Cancellation leaves the photo available for retry")
        inbox.requestPhotos(for: target, receiverID: receiver)
        #expect(inbox.takePhotos(for: .init(hostID: "host-a", paneID: "%1", inputRevision: 2, isConnected: true, isInputAvailable: true), receiverID: receiver) == nil)
        #expect(inbox.photoRequest == nil && !inbox.photosBusy, "A changed input binding must require another explicit attach")

        let files = inbox.claimFiles()
        #expect(files.map(\.id) == [file.id] && inbox.files.isEmpty)
        await inbox.discard()
        #expect(inbox.items.count == 2, "Discard cannot remove files while a transfer is reading them")
        inbox.finishFiles(Set(files.map(\.id)))
        #expect(inbox.files.count == 1, "A failed transfer becomes available for retry")

        inbox.acknowledge(photo.id)
        await inbox.refresh()
        #expect(inbox.photos.isEmpty && inbox.files.count == 1)
        let restarted = IOSShareInbox(storage: storage)
        await restarted.refresh()
        #expect(restarted.photos.isEmpty && restarted.files.count == 1)
        await restarted.discard()
        #expect(try await storage.pending().isEmpty)
    }
}
