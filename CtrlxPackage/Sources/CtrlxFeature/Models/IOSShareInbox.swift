import CtrlxCommon
import CtrlxShare
import Foundation
import Observation

@MainActor @Observable
final class IOSShareInbox {
    static let shared = IOSShareInbox()
    struct PhotoRequest: Identifiable {
        let id = UUID()
        let context: TerminalPhraseContext
        let receiverID: UUID
        var target: TerminalPhraseContext.Target {
            context.target
        }

        let items: [SharedInboxItem]
    }

    private(set) var items: [SharedInboxItem] = []
    private(set) var error: String?
    private(set) var photoRequest: PhotoRequest?
    private(set) var photosBusy = false
    private(set) var filesBusy: Set<UUID> = []
    private(set) var isDiscarding = false
    @ObservationIgnored private var storage: ShareInboxStore?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var removals: Task<Void, Never>?

    init(storage: ShareInboxStore? = nil) {
        self.storage = storage
    }

    var photos: [SharedInboxItem] {
        items.filter { $0.kind == .photo }
    }

    var files: [SharedInboxItem] {
        items.filter { $0.kind == .file && !filesBusy.contains($0.id) }
    }

    func refresh() async {
        revision += 1
        let requestedRevision = revision
        do {
            if storage == nil {
                if CommandLine.arguments.contains("--e2e-test") {
                    storage = ShareInboxStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-share-test-\(UUID().uuidString)"))
                } else {
                    storage = try ShareInboxStore.appGroupStore()
                }
            }
            guard let storage else { return }
            await removals?.value
            let pending = try await storage.pending()
            guard revision == requestedRevision else { return }
            items = pending
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func requestPhotos(for context: TerminalPhraseContext, receiverID: UUID) {
        guard !isDiscarding, !photosBusy, photoRequest == nil, context.canSend, !photos.isEmpty else { return }
        photoRequest = .init(context: context, receiverID: receiverID, items: Array(photos.prefix(5)))
    }

    func takePhotos(for context: TerminalPhraseContext, receiverID: UUID) -> [SharedInboxItem]? {
        guard let request = photoRequest, request.receiverID == receiverID, request.target == context.target else { return nil }
        guard request.context.canSend, context.canSend, request.context.hasSameInput(as: context) else {
            photoRequest = nil
            return nil
        }
        photoRequest = nil
        photosBusy = true
        return request.items
    }

    func cancelPhotoRequest(for target: TerminalPhraseContext.Target, receiverID: UUID) {
        if photoRequest?.target == target, photoRequest?.receiverID == receiverID {
            photoRequest = nil
        }
    }

    func finishPhotos() {
        photosBusy = false
    }

    func claimFiles() -> [SharedInboxItem] {
        guard !isDiscarding else { return [] }
        let pending = files
        filesBusy.formUnion(pending.map(\.id))
        return pending
    }

    func finishFiles(_ ids: Set<UUID>) {
        filesBusy.subtract(ids)
    }

    func acknowledge(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), let storage else { return }
        revision += 1
        items.removeAll { $0.id == id }
        let previous = removals
        removals = Task {
            await previous?.value
            do { try await storage.remove(item) }
            catch { self.error = "The sent item could not be removed from Shared Items: \(error.localizedDescription)" }
        }
    }

    func discard() async {
        guard !isDiscarding, !photosBusy, photoRequest == nil, filesBusy.isEmpty, let storage else { return }
        isDiscarding = true
        defer { isDiscarding = false }
        revision += 1
        await removals?.value
        do {
            for item in items {
                try await storage.remove(item)
            }
            items = []
            photoRequest = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
