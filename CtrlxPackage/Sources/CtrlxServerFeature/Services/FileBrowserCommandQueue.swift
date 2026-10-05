import CtrlxNetworking
import Foundation

/// File I/O is bounded but must not hold up the WebSocket's next keyboard frame.
@MainActor
final class FileBrowserCommandQueue {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    @discardableResult
    func enqueue(_ command: CommandMessage,
                 execute: @escaping @MainActor (CommandMessage) async -> CommandResponseMessage?,
                 reply: @escaping @MainActor (CommandResponseMessage) async -> Void) -> Bool {
        guard tasks.count < 4, tasks[command.id] == nil else { return false }
        tasks[command.id] = Task { [weak self] in
            let response = await execute(command)
            self?.tasks.removeValue(forKey: command.id)
            guard !Task.isCancelled, let response else { return }
            await reply(response)
        }
        return true
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}
