import CtrlxNetworking
import Foundation

/// One per paired connection. No terminal input, snapshots or polling involved.
@MainActor
package final class QuickPhraseSyncSession {
    private let store: QuickPhraseStore
    private let pairID: String
    private let deviceID: String?
    private let send: @MainActor (QuickPhraseSyncMessage) async -> Void
    private var epoch = UUID()
    private var peer: QuickPhraseSyncOffer?
    private var helloSent = false
    private var peerHelloReceived = false
    private var observer: UUID?
    private var worker: Task<Void, Never>?
    private var dirty = false
    private var lastSent: QuickPhraseSyncMessage?

    package init(store: QuickPhraseStore, pairID: String, send: @escaping @MainActor (QuickPhraseSyncMessage) async -> Void) {
        self.store = store
        self.pairID = pairID
        self.deviceID = store.syncDeviceID(for: pairID)
        self.send = send
    }

    package var offer: QuickPhraseSyncOffer {
        QuickPhraseSyncOffer(epoch: epoch, enabled: enabled)
    }

    private var enabled: Bool {
        store.loadError == nil && deviceID == store.syncDeviceID(for: pairID) && store.isSyncEnabled(for: pairID)
    }

    package func didSendHello() {
        helloSent = true
        if observer == nil {
            observer = store.observe { [weak self] in self?.schedule() }
        }
        schedule()
    }

    package func receiveHello(_ offer: QuickPhraseSyncOffer?) {
        peerHelloReceived = true
        peer = offer?.version == 1 ? offer : nil
        lastSent = nil
        store.syncErrors[pairID] = nil
        schedule()
    }

    package func receive(_ message: QuickPhraseSyncMessage) {
        guard let peer, message.senderEpoch == peer.epoch, message.recipientEpoch == epoch else { return }
        let changedConsent = message.enabled != peer.enabled
        self.peer = QuickPhraseSyncOffer(epoch: peer.epoch, enabled: message.enabled)
        updateStatus()
        if enabled, message.enabled, let records = message.records {
            do {
                try store.merge(records)
                store.syncErrors[pairID] = nil
            } catch {
                store.syncErrors[pairID] = error.localizedDescription
            }
        }
        if changedConsent { schedule() }
    }

    package func reset() {
        store.clearSyncConnection(pairID: pairID, epoch: epoch)
        epoch = UUID()
        worker?.cancel()
        worker = nil
        if let observer { store.removeObserver(observer) }
        observer = nil
        peer = nil
        helloSent = false
        peerHelloReceived = false
        dirty = false
        lastSent = nil
    }

    private func schedule() {
        updateStatus()
        if enabled, peerHelloReceived, peer == nil {
            store.syncErrors[pairID] = "Update both devices to sync quick phrases."
        }
        dirty = true
        guard helloSent, peer != nil, worker == nil else { return }
        let generation = epoch
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.epoch == generation, self.dirty {
                self.dirty = false
                guard let peer = self.peer else { break }
                let message = QuickPhraseSyncMessage(
                    senderEpoch: generation, recipientEpoch: peer.epoch, enabled: self.enabled,
                    records: self.enabled && peer.enabled ? self.store.records : nil
                )
                guard message != self.lastSent else { continue }
                self.lastSent = message
                await self.send(message)
            }
            if self.epoch == generation { self.worker = nil }
        }
    }

    private func updateStatus() {
        guard deviceID == store.syncDeviceID(for: pairID) else { return }
        let status: QuickPhraseSyncStatus
        if !helloSent || !peerHelloReceived { status = .offline }
        else if let peer { status = peer.enabled ? .ready : .waitingForPeer }
        else { status = .unsupported }
        store.updateSyncConnection(pairID: pairID, epoch: epoch, status: status)
    }

    /// Wait for currently queued work (also used by deterministic in-memory tests).
    package func flush() async { await worker?.value }
}
