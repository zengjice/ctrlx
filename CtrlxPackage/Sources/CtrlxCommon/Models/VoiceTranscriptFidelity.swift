import Foundation

/// Conservative checks, not a semantic judge. Uncertain corrections keep the source.
enum VoiceTranscriptFidelity {
    private static let intentPattern = try! NSRegularExpression(
        pattern: #"不要|不得|不能|不必|不用|无需|无须|禁止|没有|沒有|还没|還沒|尚未|没|沒|未|除非|否则|只有|只要|如果|仅仅|仅|只|不|\b(?i:not|never|no|only|unless|if|without|[a-z]+n['’]t|cannot)\b"#
    )
    private static let restrictedActionPattern = try! NSRegularExpression(
        pattern: #"(?:不要|不得|不能|禁止|只|仅)(?:自动)?(?:提交|发布|推送|删除|发送|部署|检查|修改|安装)"#
    )

    static func normalized(_ text: String) -> [Character] {
        Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func isSubstantiallyShorter(_ candidate: String, than source: String) -> Bool {
        let originalCount = normalized(source).count
        let candidateCount = normalized(candidate).count
        return originalCount - candidateCount >= 8 && candidateCount * 4 < originalCount * 3
    }

    static func preservesIntentMarkers(_ candidate: String, from source: String) -> Bool {
        matches(intentPattern, in: candidate) == matches(intentPattern, in: source)
            && matches(restrictedActionPattern, in: candidate) == matches(restrictedActionPattern, in: source)
    }

    /// A shorter accurate pass may legitimately remove repetitions. Fall back only
    /// when it also omits source clauses, or loses an explicit intent constraint.
    static func shouldPreferLive(_ live: String, over final: String) -> Bool {
        guard !live.isEmpty else { return false }
        guard !final.isEmpty else { return true }
        if !matches(intentPattern, in: live).isEmpty, !preservesIntentMarkers(final, from: live) {
            return true
        }
        guard isSubstantiallyShorter(final, than: live) else { return false }
        let finalText = String(normalized(final))
        let clauses = live.components(separatedBy: CharacterSet(charactersIn: "，。；！？,.!?;\n"))
            .map { String(normalized($0)) }.filter { $0.count >= 4 }
        let sharesContent = String(normalized(live)).contains(finalText)
            || clauses.contains { finalText.contains($0) }
        return sharesContent && Set(clauses).contains { !finalText.contains($0) }
    }

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> [String] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            (text as NSString).substring(with: $0.range).lowercased().replacingOccurrences(of: "’", with: "'")
        }
    }
}
