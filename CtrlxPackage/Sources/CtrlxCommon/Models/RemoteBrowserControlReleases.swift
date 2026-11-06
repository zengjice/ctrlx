import Foundation

/// Connection-owned releases outlive the tab view that initiated them.
@MainActor
final class RemoteBrowserControlReleases {
    private var pending: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]

    func enqueue(for tabID: UUID, operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        let previous = pending[tabID]?.task
        let task = Task { [weak self] in
            await previous?.value
            await operation()
            if self?.pending[tabID]?.id == id {
                self?.pending[tabID] = nil
            }
        }
        pending[tabID] = (id, task)
    }

    func wait(for tabID: UUID) async {
        while let task = pending[tabID]?.task {
            await task.value
            if Task.isCancelled {
                return
            }
        }
    }
}
