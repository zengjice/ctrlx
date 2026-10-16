import Foundation

/// Device-local dictation preference; resolve System once per recording.
public enum VoiceInputLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans-CN"
    case traditionalChinese = "zh-Hant-TW"
    case english = "en-US"
    case japanese = "ja-JP"

    public var id: String {
        rawValue
    }

    public var label: String {
        switch self {
        case .system: "System Language"
        case .simplifiedChinese: "中文（普通话）"
        case .traditionalChinese: "中文（臺灣）"
        case .english: "English"
        case .japanese: "日本語"
        }
    }

    var localeIdentifier: String {
        self == .system ? (Locale.preferredLanguages.first ?? Locale.current.identifier) : rawValue
    }
}
