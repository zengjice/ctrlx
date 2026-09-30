import CtrlxNetworking
import Dependencies
import DependenciesMacros
import Foundation

public enum AgentForkHistoryLayout: Sendable {
    case codex, claude
}

@DependencyClient
public struct AgentForkHistoryClient: Sendable {
    public var root: @Sendable (_ sessionID: String, _ roots: [String], _ layout: AgentForkHistoryLayout) async throws -> String
}

extension AgentForkHistoryClient: DependencyKey {
    public static let liveValue = Self(root: { try await AgentForkHistoryResolver.shared.root(sessionID: $0, roots: $1, layout: $2) })
}

private actor AgentForkHistoryResolver {
    static let shared = AgentForkHistoryResolver()

    func root(sessionID: String, roots: [String], layout: AgentForkHistoryLayout) throws -> String {
        guard let uuid = UUID(uuidString: sessionID) else { throw AgentForkError("The Agent conversation ID is invalid.") }
        let id = uuid.uuidString.lowercased()
        let files = FileManager.default
        var matches: Set<String> = []
        for root in roots {
            let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
            let storage = rootURL.appendingPathComponent(layout == .codex ? "sessions" : "projects")
            guard let entries = files.enumerator(at: storage, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in entries {
                try Task.checkCancellation()
                let name = url.lastPathComponent.lowercased()
                let match = layout == .codex ? name.hasSuffix("-\(id).jsonl") : name == "\(id).jsonl"
                if match, (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                    matches.insert(rootURL.path)
                    break
                }
            }
        }
        guard matches.count == 1, let root = matches.first else {
            throw AgentForkError(matches.isEmpty
                ? "The source conversation history is unavailable. Check this Agent's config directory in Host Settings."
                : "The conversation exists in multiple Agent config directories. Resolve the ambiguity before forking.")
        }
        return root
    }
}
