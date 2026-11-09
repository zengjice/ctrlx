import CtrlxCommon
import CtrlxNetworking
import SwiftUI

struct NewTabMenuItem: Identifiable {
    enum ID: Hashable {
        case agent
        case terminal
        case resource(ResourceTabKind)
        case git
    }

    let id: ID
    let title: String
    let image: Image
    var isEnabled = true
    let action: @MainActor () -> Void

    @MainActor
    static func creationItems(
        isTerminalDisabled: Bool = false,
        onNewAgent: @escaping @MainActor () -> Void,
        onNewTerminal: @escaping @MainActor () -> Void,
        onNewResource: (@MainActor (ResourceTabKind) -> Void)? = nil,
        onOpenGit: (@MainActor () -> Void)? = nil
    ) -> [Self] {
        var items: [Self] = [
            .init(id: .agent, title: "New Agent…", image: Symbols.sparkles.image, action: onNewAgent),
            .init(id: .terminal, title: "New Terminal", image: Symbols.terminal.image, isEnabled: !isTerminalDisabled, action: onNewTerminal),
        ]
        if let onNewResource {
            for (kind, title, symbol) in [(ResourceTabKind.files, "New Files", Symbols.folder), (.browser, "New Browser", .globe), (.simulator, "New iOS Simulator", .iphone)] {
                items.append(.init(id: .resource(kind), title: title, image: symbol.image) { onNewResource(kind) })
            }
        }
        if let onOpenGit {
            items.append(.init(id: .git, title: "Open Git", image: CustomSymbol.gitLogo.image, action: onOpenGit))
        }
        return items
    }
}

struct NewTabPicker: View {
    let items: [NewTabMenuItem]
    @Environment(\.dismiss) private var dismiss
    @State private var selection: NewTabMenuItem.ID = .agent
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 2) {
            ForEach(items) { item in
                if item.id == .git {
                    Divider().padding(.vertical, 3)
                }
                Button(action: item.action) {
                    Label { Text(item.title) } icon: { item.image }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .background(selection == item.id ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(!item.isEnabled)
                .onHover { hovering in
                    if hovering, item.isEnabled {
                        selection = item.id
                    }
                }
                .accessibilityValue(selection == item.id ? "selected" : "")
                .accessibilityIdentifier(item.id == .agent ? "new-agent-tab" : item.id == .git ? "open-git-tab" : item.title)
            }
        }
        .padding(6)
        .frame(width: 230)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onMoveCommand { direction in
            switch direction {
            case .up: moveSelection(by: -1)
            case .down: moveSelection(by: 1)
            default: break
            }
        }
        .onKeyPress(.return) {
            items.first { $0.id == selection && $0.isEnabled }?.action()
            return .handled
        }
        .onExitCommand { dismiss() }
        .accessibilityIdentifier("new-tab-picker")
    }

    private func moveSelection(by offset: Int) {
        let ids = items.filter(\.isEnabled).map(\.id)
        guard !ids.isEmpty else { return }
        let index = ids.firstIndex(of: selection) ?? 0
        selection = ids[(index + offset + ids.count) % ids.count]
    }
}
