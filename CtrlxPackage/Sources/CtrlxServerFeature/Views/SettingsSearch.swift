import CtrlxCommon
import SwiftUI

/// Stable anchors shared by the local search catalog and settings sections.
enum SettingsSection: String {
    case diskAccess
    case ipaAssociation
    case terminal
    case behavior
    case recovery
    case tmux
    case diagnostics
    case appAppearance
    case terminalAppearance
    case browserPlacement
    case browserDefault
    case browserRules
    case sidebarFields
    case sidebarSort
    case fileOpening
    case editors
    case promptEditor
    case connection
    case pairing
    case reconnection
    case relay
    case relayAccess
    case relayAuthorization
    case relayTraffic
    case agentStatus
    case agentCLI
    case agentCommand
    case agentProviders
    case agentBehavior
    case agentUpdates
    case agentAdvanced
    case updates
    case updateReminders
    case build
    case licenses
}

struct SettingsSearchItem: Identifiable {
    let title: String
    let tab: SettingsTab
    let section: SettingsSection?
    var keywords = ""

    var id: String {
        "\(tab.rawValue)-\(title)"
    }

    static func matching(_ query: String) -> [Self] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        let matches = all.filter { item in
            let text = "\(item.title) \(item.tab.title) \(item.keywords)"
            return words.allSatisfy { text.localizedStandardContains(String($0)) }
        }
        // Prefer named controls to incidental keyword matches on other pages.
        let named = matches.filter { item in words.allSatisfy { item.title.localizedStandardContains(String($0)) } }
        let namedIDs = Set(named.map(\.id))
        return named + matches.filter { !namedIDs.contains($0.id) }
    }

    static let all: [Self] = [
        .init(title: "Terminal App & Scrollback", tab: .general, section: .terminal, keywords: "terminal path history lines 终端 历史"),
        .init(title: "Launch at login", tab: .general, section: .behavior, keywords: "startup 登录 启动"),
        .init(title: "Open sessions window on launch", tab: .general, section: .behavior),
        .init(title: "Show status bar", tab: .general, section: .behavior),
        .init(title: "Auto-copy selected text", tab: .general, section: .behavior, keywords: "clipboard 复制"),
        .init(title: "Prevent sleep during active sessions", tab: .general, section: .behavior, keywords: "awake 休眠"),
        .init(title: "Workspace Recovery", tab: .general, section: .recovery, keywords: "restore startup 恢复"),
        .init(title: "tmux Configuration", tab: .general, section: .tmux, keywords: "command path socket restart 路径"),
        .init(title: "Debug Mode", tab: .general, section: .diagnostics, keywords: "diagnostics 调试"),
        .init(title: "Full Disk Access", tab: .general, section: .diskAccess, keywords: "permissions 权限"),
        .init(title: "IPA File Association", tab: .general, section: .ipaAssociation, keywords: "installer default application 安装"),
        .init(title: "App Appearance", tab: .appearance, section: .appAppearance, keywords: "system light dark 外观"),
        .init(title: "Font & Size", tab: .appearance, section: .terminalAppearance, keywords: "terminal preview 字体 字号"),
        .init(title: "Terminal Colors", tab: .appearance, section: .terminalAppearance, keywords: "theme palette preview 配色 主题"),
        .init(title: "Highlight selected session in sidebar", tab: .appearance, section: .terminalAppearance),
        .init(title: "Always open links in split tab", tab: .browser, section: .browserPlacement, keywords: "分栏"),
        .init(title: "When clicking web links in terminal", tab: .browser, section: .browserDefault, keywords: "default behavior 浏览器 链接"),
        .init(title: "Per-Domain Rules", tab: .browser, section: .browserRules, keywords: "domain override 域名"),
        .init(title: "Available & Visible Fields", tab: .sidebarLayout, section: .sidebarFields, keywords: "sidebar layout agent terminal 侧边栏 字段"),
        .init(title: "Sort Order", tab: .sidebarLayout, section: .sidebarSort, keywords: "manual automatic 排序"),
        .init(title: "File Opening", tab: .editors, section: .fileOpening, keywords: "clicked links split tab 文件 分栏"),
        .init(title: "External Editors", tab: .editors, section: .editors, keywords: "add detect remove rename 编辑器"),
        .init(title: "Prompt editor (Ctrl-G)", tab: .editors, section: .promptEditor, keywords: "VISUAL shell override 提示词"),
        .init(title: "Paired Viewers", tab: .remoteAccess, section: .pairing, keywords: "unpair devices iPhone 配对"),
        .init(title: "Paired Hosts", tab: .remoteHosts, section: .pairing, keywords: "pair Mac connect 配对"),
        .init(title: "Reconnection", tab: .relay, section: .reconnection, keywords: "auto reconnect delay 重连"),
        .init(title: "Server URL", tab: .relay, section: .relay, keywords: "relay auto-connect 中继"),
        .init(title: "Relay Access Key & Traffic", tab: .relay, section: .relayAccess, keywords: "account quota allowance 流量 配额"),
        .init(title: "Relay Authorization", tab: .relay, section: .relayAuthorization, keywords: "license activation key 授权 激活"),
        .init(title: "Remote Hosts Relay Traffic", tab: .relay, section: .relayTraffic, keywords: "account quota allowance 流量 配额"),
        .init(title: "Quick Phrase Sync", tab: .quickPhraseSync, section: nil, keywords: "devices sharing 快捷短语 同步"),
        .init(title: "Voice Input", tab: .voiceInput, section: nil, keywords: "microphone dictation language correction provider API key model 语音 语言"),
        .init(title: "CtrlX Plugin Status", tab: .agents, section: .agentStatus, keywords: "install setup Agent 状态 安装"),
        .init(title: "Agent Command Path", tab: .agents, section: .agentCommand, keywords: "apply browse CLI executable 命令 路径"),
        .init(title: "Launch Default Provider", tab: .agents, section: .agentProviders, keywords: "subscription OpenAI Anthropic API key model shortcuts 订阅"),
        .init(title: "Agent Startup Behavior", tab: .agents, section: .agentBehavior, keywords: "auto-run close session completion verify Apple Intelligence"),
        .init(title: "Agent CLI", tab: .agents, section: .agentCLI, keywords: "update version check installed repair 更新 安装"),
        .init(title: "Agent Plugin Updates", tab: .agents, section: .agentUpdates, keywords: "version check 自动更新"),
        .init(title: "Agent Advanced", tab: .agents, section: .agentAdvanced, keywords: "log level telemetry config folders 日志 遥测 配置目录"),
        .init(title: "CtrlX Updates", tab: .about, section: .updates, keywords: "version check download 更新"),
        .init(title: "Update Reminders", tab: .about, section: .updateReminders, keywords: "interval remind 提醒"),
        .init(title: "Version & Build", tab: .about, section: .build),
        .init(title: "Licenses", tab: .about, section: .licenses, keywords: "source origin AGPL 许可"),
    ]
}

struct SettingsSearchRequest: Identifiable {
    let id = UUID()
    let item: SettingsSearchItem
}

extension EnvironmentValues {
    @Entry var settingsSearchSection: SettingsSection?
    @Entry var settingsSearchRequestID: UUID?
}

extension View {
    func settingsAnchor(_ section: SettingsSection) -> some View {
        id(section)
    }
}

extension SettingsTab {
    var symbol: Symbols {
        switch self {
        case .general: .gearshape
        case .appearance: .circleLefthalfFilled
        case .browser: .globe
        case .sidebarLayout: .listBulletClipboard
        case .editors: .pencil
        case .relay: .wifi
        case .remoteAccess: .iphone
        case .remoteHosts: .laptopcomputer
        case .quickPhraseSync: .textBubbleFill
        case .voiceInput: .micFill
        case .agents: .puzzlepiece
        case .about: .infoCircle
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .browser: "Browser"
        case .sidebarLayout: "Sidebar"
        case .editors: "Files & Editors"
        case .relay: "Relay"
        case .remoteAccess: "Remote Access"
        case .remoteHosts: "Remote Hosts"
        case .quickPhraseSync: "Quick Phrase Sync"
        case .voiceInput: "Voice Input"
        case .agents: "Agents"
        case .about: "About"
        }
    }
}
