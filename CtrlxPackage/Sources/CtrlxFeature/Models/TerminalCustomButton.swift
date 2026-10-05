import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Observation

struct TerminalCustomButton: Codable, Identifiable, Equatable, Sendable {
    enum Key: String, Codable, CaseIterable, Identifiable, Sendable {
        case tab, backtab, escape, enter, space, home, end, pageUp, pageDown
        case up, down, left, right, backspace, delete
        case ctrlC, ctrlD, ctrlZ, ctrlL, ctrlA, ctrlE, ctrlU, ctrlK, ctrlW

        var id: Self { self }

        var title: String {
            switch self {
            case .backtab: "Shift+Tab"
            case .escape: "Esc"
            case .pageUp: "Page Up"
            case .pageDown: "Page Down"
            case .ctrlC: "Ctrl+C"
            case .ctrlD: "Ctrl+D"
            case .ctrlZ: "Ctrl+Z"
            case .ctrlL: "Ctrl+L"
            case .ctrlA: "Ctrl+A"
            case .ctrlE: "Ctrl+E"
            case .ctrlU: "Ctrl+U"
            case .ctrlK: "Ctrl+K"
            case .ctrlW: "Ctrl+W"
            default: rawValue.capitalized
            }
        }

        var tmuxKey: TmuxKey {
            switch self {
            case .tab: .tab
            case .backtab: .backtab
            case .escape: .escape
            case .enter: .enter
            case .space: .space
            case .home: .home
            case .end: .end
            case .pageUp: .pageUp
            case .pageDown: .pageDown
            case .up: .up
            case .down: .down
            case .left: .left
            case .right: .right
            case .backspace: .backspace
            case .delete: .delete
            case .ctrlC: .ctrl("c")
            case .ctrlD: .ctrl("d")
            case .ctrlZ: .ctrl("z")
            case .ctrlL: .ctrl("l")
            case .ctrlA: .ctrl("a")
            case .ctrlE: .ctrl("e")
            case .ctrlU: .ctrl("u")
            case .ctrlK: .ctrl("k")
            case .ctrlW: .ctrl("w")
            }
        }
    }

    enum Action: Codable, Equatable, Sendable {
        case text(String, sendReturn: Bool = false)
        case key(Key)

        var keys: [TmuxKey] {
            switch self {
            case let .text(text, sendReturn):
                sendReturn ? [.text(text), .delay(200), .enter] : [.text(text)]
            case let .key(key): [key.tmuxKey]
            }
        }
    }

    let id: UUID
    let name: String
    let action: Action

    init(id: UUID = UUID(), name: String, action: Action) {
        self.id = id
        self.name = name
        self.action = action
    }

    func validated() throws -> Self {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ValidationError.emptyName }
        guard Self.isSingleLine(name) else { throw ValidationError.controlCharacters }
        if case let .text(text, _) = action {
            guard !text.isEmpty else { throw ValidationError.emptyText }
            guard Self.isSingleLine(text) else { throw ValidationError.controlCharacters }
        }
        return Self(id: id, name: name, action: action)
    }

    private static func isSingleLine(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value)
                && !CharacterSet.newlines.contains($0)
        }
    }

    enum ValidationError: LocalizedError {
        case emptyName, emptyText, controlCharacters, unreadableLibrary

        var errorDescription: String? {
            switch self {
            case .emptyName: "Enter a button name."
            case .emptyText: "Enter text to send."
            case .controlCharacters: "Use a single line without control characters. Choose a special key for key actions."
            case .unreadableLibrary: "Saved custom buttons could not be read. They have not been overwritten."
            }
        }
    }
}

/// Owned by iOS settings, not by a terminal, agent or remote host.
@Observable
@MainActor
final class TerminalCustomButtonStore {
    static let storageKey = "terminalCustomButtons.v1"
    private(set) var buttons: [TerminalCustomButton] = []
    private(set) var loadError: String?

    @ObservationIgnored
    @Dependency(PreferencesService.self) private var preferences

    init() {
        guard let data = preferences.data(Self.storageKey) else { return }
        do {
            let saved = try JSONDecoder().decode([TerminalCustomButton].self, from: data)
            guard Set(saved.map(\.id)).count == saved.count else { throw CocoaError(.coderReadCorrupt) }
            for button in saved {
                guard try button.validated() == button else { throw CocoaError(.coderReadCorrupt) }
            }
            buttons = saved
        } catch {
            loadError = "Saved custom buttons could not be read: \(error.localizedDescription)"
        }
    }

    func add(name: String, action: TerminalCustomButton.Action) throws {
        let button = try TerminalCustomButton(name: name, action: action).validated()
        try save(buttons + [button])
    }

    func remove(_ id: UUID) throws {
        guard buttons.contains(where: { $0.id == id }) else { return }
        try save(buttons.filter { $0.id != id })
    }

    private func save(_ buttons: [TerminalCustomButton]) throws {
        guard loadError == nil else { throw TerminalCustomButton.ValidationError.unreadableLibrary }
        let data = try JSONEncoder().encode(buttons)
        preferences.setData(data, Self.storageKey)
        self.buttons = buttons
    }
}

struct TerminalCustomButtonRequest: Sendable {
    let button: TerminalCustomButton
    let context: TerminalPhraseContext

    func isValid(in current: TerminalPhraseContext, savedButtons: [TerminalCustomButton]) -> Bool {
        context.canSend && current.canSend && context.hasSameInput(as: current)
            && savedButtons.contains(button)
    }
}
