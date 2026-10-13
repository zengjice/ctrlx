import Foundation

/// Read-only inspection of a directory on the Host, independent of any conversation.
public struct PrepareSessionWorktree: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public var commandType: CommandType {
        .prepareSessionWorktree(self)
    }
}
