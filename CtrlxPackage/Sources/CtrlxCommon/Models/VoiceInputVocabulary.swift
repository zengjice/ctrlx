import Foundation

enum VoiceInputVocabulary {
    private static let ctrlXTerms = [
        "CtrlX",
        "host",
        "pane",
        "relay",
        "session",
        "terminal",
        "viewer",
        "Voice",
        "会话",
        "标签页",
        "自适应",
        "分栏",
        "工作区",
        "剪贴板",
        "语音输入",
        "自动排序",
    ]

    private static let agentTerms = [
        "ChatGPT",
        "Claude",
        "Claude Code",
        "Codex",
        "GPT",
        "GPT-5",
        "OpenAI",
    ]

    private static let appleTerms = [
        "Apple",
        "Apple Intelligence",
        "iOS",
        "iPad",
        "iPhone",
        "iPhone Air",
        "Mac",
        "MacBook",
        "macOS",
    ]

    private static let developmentTerms = [
        "branch",
        "commit",
        "develop",
        "diff",
        "Docker",
        "Git",
        "GitHub",
        "Homebrew",
        "main",
        "master",
        "merge",
        "Nginx",
        "rebase",
        "SSH",
        "Swift",
        "SwiftTerm",
        "SwiftUI",
        "tmux",
        "Vapor",
        "WebSocket",
        "worktree",
        "Xcode",
        "xcodebuild",
    ]

    private static let infrastructureTerms = [
        "HK",
        "home",
        "office",
        "QCloud",
    ]

    static let terms = ctrlXTerms
        + agentTerms
        + appleTerms
        + developmentTerms
        + infrastructureTerms

    /// Only use the metadata we captured, never words mined from arbitrary output.
    static func terms(for context: VoiceInputContextSnapshot?) -> [String] {
        var result = terms
        var seen = Set(terms.map { $0.lowercased() })
        for line in (context?.paneMetadata ?? []).prefix(4) {
            let value: String
            if line.hasPrefix("Current path: ") {
                value = (String(line.dropFirst("Current path: ".count)) as NSString).lastPathComponent
            } else if line.hasPrefix("Session: ") || line.hasPrefix("Window: ") {
                value = String(line.dropFirst(line.hasPrefix("Session: ") ? 9 : 8))
            } else {
                continue
            }
            let pieces = [value] + value.components(separatedBy: CharacterSet(charactersIn: "-_ "))
            for piece in pieces {
                let term = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard
                    (2...48).contains(term.count), term.contains(where: \.isLetter),
                    term.allSatisfy({ $0.isLetter || $0.isNumber || "-_ .".contains($0) }),
                    seen.insert(term.lowercased()).inserted else { continue }
                result.append(term)
                if result.count == terms.count + 8 {
                    return result
                }
            }
        }
        return result
    }
}
