import AppKit
import SwiftUI

private actor PreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false

    func pause() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor private final class Driver {
    var receive: (() -> Void)?
    var cancel: (() -> Void)?
    var cancelTask: (() -> Void)?
    var snapshot: (() -> (UUID?, Bool))?
    var completed: Set<UUID> = []
    let gates = [PreparationGate(), PreparationGate(), PreparationGate()]
    var nextGate = 0
}

private struct ImageUploadSource: Sendable {
    let displayName: String
    let data: Data
    let sharedItemID: UUID?
}

private enum ImageUploadError: Error { case unreadable(String) }
private enum StubBinding { case unavailable }

@MainActor private struct CancellationProbe: View {
    let driver: Driver
    let shareInbox: IOSShareInbox
    let sharedContext: TerminalPhraseContext?
    let shareReceiverID: UUID?
    @State private var sharedImport: SharedPhotoImport?
    @State private var operationTask: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var targetPaneId: String?
    @State private var targetBinding = StubBinding.unavailable
    @State private var draftImages: [Int] = []
    @State private var isPreviewPresented = false

    private var canStartInput: Bool {
        operationID == nil
    }

    var body: some View {
        driver.receive = { receiveSharedPhotos() }
        driver.cancel = { cancelOperation() }
        driver.cancelTask = { operationTask?.cancel() }
        driver.snapshot = { (operationID, sharedImport != nil) }
        return Text(operationID?.uuidString ?? "idle")
    }

    private func captureTargetPane() -> Bool {
        targetPaneId = "%1"; return true
    }

    private func presentSourceError(_ error: Error, operationID _: UUID) {
        preconditionFailure("Unexpected preparation error: \(error)")
    }

    private func prepareAndPresent(_: [ImageUploadSource], operationID: UUID) async throws {
        let gate = driver.gates[driver.nextGate]
        driver.nextGate += 1
        defer { driver.completed.insert(operationID) }
        // Replace thumbnail preparation only. Like production, detached work
        // finishes before the parent sees cancellation and checks its identity.
        await Task.detached { await gate.pause() }.value
        try Task.checkCancellation()
        guard self.operationID == operationID else { throw CancellationError() }
        isPreviewPresented = true
    }

    /* PRODUCTION_MEMBERS */
}

@main private struct SharedPhotoCancellationRegression {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.jpg")
        try Data("photo fixture".utf8).write(to: source)
        let storage = ShareInboxStore(root: root.appendingPathComponent("inbox"))
        let batch = try await storage.begin()
        let item = try PreparedSharedItem.copy(from: source, to: await storage.stagingDirectory(batch), name: "photo.jpg", kind: .photo)
        try await storage.commit(batch, entries: [item])
        let inbox = IOSShareInbox(storage: storage)
        await inbox.refresh()
        let savedURL = try require(inbox.items.first?.url)
        let context = TerminalPhraseContext(hostID: "fixture-host", paneID: "%1", inputRevision: 1, isConnected: true, isInputAvailable: true)
        let receiver = UUID()
        let driver = Driver()
        _ = NSApplication.shared
        let host = NSHostingView(rootView: CancellationProbe(driver: driver, shareInbox: inbox, sharedContext: context, shareReceiverID: receiver))
        host.frame = .init(x: 0, y: 0, width: 500, height: 100)
        host.layoutSubtreeIfNeeded()

        inbox.requestPhotos(for: context, receiverID: receiver)
        try require(driver.receive)()
        while !(await driver.gates[0].entered) {
            await Task.yield()
        }
        let first = try require(driver.snapshot?().0)
        try require(driver.cancel)()
        await settle(host)
        precondition(!inbox.photosBusy)

        inbox.requestPhotos(for: context, receiverID: receiver)
        try require(driver.receive)()
        while !(await driver.gates[1].entered) {
            await Task.yield()
        }
        let second = try require(driver.snapshot?().0)
        precondition(first != second && inbox.photosBusy)
        await driver.gates[0].release()
        while !driver.completed.contains(first) {
            await Task.yield()
        }
        await settle(host)
        let state = try require(driver.snapshot)()
        precondition(state.0 == second && state.1 && inbox.photosBusy,
                     "Old cancellation released the new import's reservation")
        inbox.requestPhotos(for: context, receiverID: UUID())
        precondition(inbox.photoRequest == nil, "Another window could claim the in-flight photo")
        await inbox.discard()
        precondition(inbox.items.count == 1 && FileManager.default.fileExists(atPath: savedURL.path),
                     "Discard removed the copy while the new import was reading it")
        print("PASS: late cancellation preserves the new import")

        try require(driver.cancel)()
        await driver.gates[1].release()
        while !driver.completed.contains(second) {
            await Task.yield()
        }
        await settle(host)
        inbox.requestPhotos(for: context, receiverID: receiver)
        try require(driver.receive)()
        while !(await driver.gates[2].entered) {
            await Task.yield()
        }
        let current = try require(driver.snapshot?().0)
        try require(driver.cancelTask)()
        await driver.gates[2].release()
        while !driver.completed.contains(current) {
            await Task.yield()
        }
        await settle(host)
        let finished = try require(driver.snapshot)()
        precondition(finished.0 == nil && !finished.1 && !inbox.photosBusy)
        precondition(inbox.items.count == 1 && FileManager.default.fileExists(atPath: savedURL.path))
        print("PASS: current cancellation releases the reservation and retains the copy")
        withExtendedLifetime(host) {}
    }

    @MainActor private static func settle(_ host: NSView) async {
        for _ in 0 ..< 3 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw ShareInboxError("Regression fixture did not initialize") }
        return value
    }
}
