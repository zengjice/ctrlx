import CtrlxNetworking
import Foundation

public struct RichChatMessage: Codable, Equatable, Identifiable, Sendable {
    public struct Action: Codable, Equatable, Sendable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public struct Reference: Codable, Equatable, Sendable {
        public enum PreviewKind: String, Codable, Sendable {
            case image
            case html
        }

        public let target: String
        public let path: String
        public let previewKind: PreviewKind?

        init(target: String, path: String) {
            self.target = target
            self.path = path
            if target.removingPercentEncoding?.hasSuffix("/") == true {
                self.previewKind = nil
            } else {
                switch (path as NSString).pathExtension.lowercased() {
                case "png",
                     "jpg",
                     "jpeg",
                     "gif",
                     "heic",
                     "webp",
                     "tiff",
                     "bmp",
                     "svg": self.previewKind = .image
                case "html",
                     "htm": self.previewKind = .html
                default: self.previewKind = nil
                }
            }
        }
    }

    public let id: UUID
    public let text: String
    public let answer: String?
    public let activity: [String]
    public let pending: Bool
    public let issue: String?
    public let actions: [Action]
    public let references: [Reference]

    public init(id: UUID, text: String, answer: String?, activity: [String] = [], pending: Bool = false, issue: String? = nil, actions: [Action] = []) {
        self.id = id
        self.text = text
        self.answer = answer
        self.activity = activity
        self.pending = pending
        self.issue = issue
        self.actions = actions
        self.references = Self.references(in: answer ?? "")
    }

    /// Register validated targets; Marked decides which occurrences are links or examples.
    static func references(in text: String) -> [Reference] {
        var result: [Reference] = []
        var registered: Set<String> = []
        let separators = CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "<>()[]\"'`\\"))
        var cursor = text.startIndex
        while let start = text.range(of: "repo:", range: cursor..<text.endIndex) {
            cursor = start.upperBound
            let wrapper = start.lowerBound > text.startIndex ? text.index(before: start.lowerBound) : nil
            let limit = text.index(start.lowerBound, offsetBy: RepositoryFileLink.maximumLength, limitedBy: text.endIndex) ?? text.endIndex
            let delimiter = text.rangeOfCharacter(from: separators, range: start.upperBound..<limit)?.lowerBound
            guard let end = delimiter ?? (limit == text.endIndex ? limit : nil) else { continue }
            if let wrapper, text[wrapper] == "<", end == text.endIndex || text[end] != ">" {
                continue
            }
            let target = String(text[start.lowerBound..<end])
            guard let path = RepositoryFileLink.path(linkTarget: target), registered.insert(target).inserted else { continue }
            result.append(.init(target: target, path: path))
            cursor = end
        }
        return result
    }
}
