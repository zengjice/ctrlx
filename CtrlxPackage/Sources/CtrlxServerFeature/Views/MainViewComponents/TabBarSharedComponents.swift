import CtrlxCommon
import CtrlxNetworking
import SwiftUI

struct TerminalWindowTabLabel: View {
    let name: String
    let hasAgent: Bool
    let attention: AgentAttention?
    let progress: TerminalProgressState?

    var body: some View {
        HStack(spacing: 4) {
            if hasAgent {
                Symbols.sparkles.image
                    .font(.caption2)
                    .foregroundStyle(.purple)
            }
            Text(name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            if let attention {
                attention.symbol.image
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            if let progress {
                TerminalProgressBar(state: progress)
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .padding(.bottom, 3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

func windowTabAccessibilityValue(isSelected: Bool, attention: AgentAttention?, progress: TerminalProgressState?) -> String {
    var values: [String] = []
    if isSelected {
        values.append("selected")
    }
    if let attention {
        values.append(attention.accessibilityLabel)
    }
    if let progress {
        values.append("Terminal progress \(progress.accessibilityValueString)")
    }
    return values.joined(separator: ", ")
}

enum TabSection: String {
    case single
    case left
    case right
}

/// Compact preview view drawn under the cursor while a tab is being dragged.
/// Mirrors the on-strip styling so the user sees a recognisable "ghost" of
/// the tab they're moving.
struct TabDragPreview: View {
    let label: String
    private let image: Image

    /// Preview for a tab whose icon is a system symbol (the common case).
    init(label: String, symbol: Symbols) {
        self.label = label
        self.image = symbol.image
    }

    /// Preview for a tab whose icon is a custom (bundled) symbol — e.g. the Git
    /// tab's ``CustomSymbol/gitLogo``, which can't go through ``Symbols``.
    init(label: String, image: Image) {
        self.label = label
        self.image = image
    }

    var body: some View {
        HStack(spacing: 4) {
            image
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .cornerRadius(4)
        .shadow(radius: 2)
    }
}

/// The leading "+" button and ⌘T share one picker in the active workbench.
struct NewTabMenuButton: View {
    let helpText: String
    let agentConfiguration: NewAgentTabConfiguration
    @Binding var isPresented: Bool
    var isTerminalDisabled = false
    let onNewTerminal: () -> Void
    var onOpenGit: (() -> Void)?
    var onNewResource: ((ResourceTabKind) -> Void)?
    @State private var presentedAgents: NewAgentTabConfiguration?

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Symbols.plus.image
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("\(helpText) · ⌘T")
        .accessibilityLabel("New Tab")
        .popover(isPresented: $isPresented) {
            if let presentedAgents {
                NewAgentTabPanel(configuration: presentedAgents)
            } else {
                NewTabPicker(items: items)
            }
        }
        .onChange(of: isPresented) { _, presented in
            if !presented {
                presentedAgents = nil
            }
        }
        .onChange(of: agentConfiguration.id) {
            isPresented = false
            presentedAgents = nil
        }
    }

    var items: [NewTabMenuItem] {
        var newResource: (@MainActor (ResourceTabKind) -> Void)?
        if let onNewResource {
            newResource = { kind in
                isPresented = false
                onNewResource(kind)
            }
        }
        var openGit: (@MainActor () -> Void)?
        if let onOpenGit {
            openGit = {
                isPresented = false
                onOpenGit()
            }
        }
        return NewTabMenuItem.creationItems(
            isTerminalDisabled: isTerminalDisabled,
            onNewAgent: {
                presentedAgents = agentConfiguration
            },
            onNewTerminal: {
                isPresented = false
                onNewTerminal()
            },
            onNewResource: newResource,
            onOpenGit: openGit
        )
    }
}

/// Tab-strip entry for a single in-app browser tab. Identical between the
/// local and remote tab bars — both render the globe icon, the tab label with
/// the same truncation rules, the same split-toggle and close-button placement,
/// and expose the same drag/drop affordances.
struct BrowserTabStripItem: View {
    let tab: BrowserTab
    let isSelected: Bool
    let isOnRight: Bool
    let isSplit: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onToggleSplit: () -> Void

    @State private var isHovered = false

    var body: some View {
        let payload = TabDragPayload.browser(tab.id)

        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 4) {
                    (tab.isSimulator ? Symbols.iphone : Symbols.globe).image
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(tab.tabLabel)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 160, alignment: .leading)
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.isSimulator ? tab.tabLabel : tab.url.absoluteString)
            .accessibilityLabel("\(tab.isSimulator ? "Simulator" : "Browser") tab: \(tab.tabLabel)")
            .accessibilityValue(isSelected ? "selected" : "")

            TabReturnToMainButton(tab: payload, name: tab.tabLabel)

            TabSplitToggleButton(
                isSplit: isSplit,
                isOnRight: isOnRight,
                tabKind: tab.isSimulator ? "simulator tab" : "browser tab",
                tabName: tab.tabLabel,
                action: onToggleSplit
            )

            if tab.canClose {
                TabCloseButton(
                    isVisible: isSelected || isHovered,
                    accessibilityLabel: "Close \(tab.isSimulator ? "simulator" : "browser") tab: \(tab.tabLabel)",
                    action: onClose
                )
                .padding(.trailing, 6)
            }
        }
        .tabStripItemStyle(isSelected: isSelected, isOnRightSplit: isOnRight, isSplit: isSplit)
        .onHover { hovering in
            isHovered = hovering
        }
        .workbenchDraggable(payload, label: tab.tabLabel) {
            TabDragPreview(label: tab.tabLabel, symbol: tab.isSimulator ? .iphone : .globe)
        }
    }
}
