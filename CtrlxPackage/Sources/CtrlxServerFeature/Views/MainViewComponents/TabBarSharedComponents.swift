import CtrlxCommon
import CtrlxNetworking
import SwiftUI

struct TerminalWindowTabLabel: View {
    let name: String
    let hasAgent: Bool
    let needsAttention: Bool
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
            if needsAttention {
                Symbols.bellBadgeFill.image
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

func windowTabAccessibilityValue(isSelected: Bool, needsAttention: Bool, progress: TerminalProgressState?) -> String {
    var values: [String] = []
    if isSelected {
        values.append("selected")
    }
    if needsAttention {
        values.append("needs attention")
    }
    if let progress {
        values.append("Terminal progress \(progress.accessibilityValueString)")
    }
    return values.joined(separator: ", ")
}

/// Identifies which trailing drop zone is being targeted. The single section
/// is used when the tab bar is not split; left/right correspond to the two
/// sections of the split-mode bar. Shared by `WindowTabBar` and
/// `RemoteWindowTabBar` so any future drop-zone semantics stay aligned.
enum TabSection: Hashable {
    case single
    case left
    case right
}

/// Visual hint shown while a compatible drag is hovering a tab — a thin
/// vertical accent line on the leading edge that previews the drop slot.
struct DropIndicator: View {
    let visible: Bool

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2)
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.1), value: visible)
            .allowsHitTesting(false)
    }
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
        var items: [NewTabMenuItem] = [
            .init(id: .agent, title: "New Agent…", image: Symbols.sparkles.image) {
                presentedAgents = agentConfiguration
            },
            .init(id: .terminal, title: "New Terminal", image: Symbols.terminal.image, isEnabled: !isTerminalDisabled) {
                isPresented = false
                onNewTerminal()
            },
        ]
        if let onNewResource {
            for (kind, title, symbol) in [(ResourceTabKind.files, "New Files", Symbols.folder), (.browser, "New Browser", .globe), (.simulator, "New iOS Simulator", .iphone)] {
                items.append(.init(id: .resource(kind), title: title, image: symbol.image) {
                    isPresented = false
                    onNewResource(kind)
                })
            }
        }
        if let onOpenGit {
            items.append(.init(id: .git, title: "Open Git", image: CustomSymbol.gitLogo.image) {
                isPresented = false
                onOpenGit()
            })
        }
        return items
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
    let showsDropIndicator: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onToggleSplit: () -> Void
    let onDrop: ([TabDragPayload]) -> Bool
    let onTargetedChanged: (Bool) -> Void

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
        .overlay(alignment: .leading) {
            DropIndicator(visible: showsDropIndicator)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .workbenchDraggable(payload, label: tab.tabLabel) {
            TabDragPreview(label: tab.tabLabel, symbol: tab.isSimulator ? .iphone : .globe)
        }
        .workbenchDropDestination(before: payload) { payloads, _ in
            onDrop(payloads)
        } isTargeted: { isTargeted in
            onTargetedChanged(isTargeted)
        }
    }
}
