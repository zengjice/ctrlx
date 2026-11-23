#if os(macOS)
    import CtrlxCommon
    import CtrlxPluginProtocol
    import SwiftUI

    @MainActor
    struct OrbieMessageActivity: View {
        let entries: [AgentTurnActivity]
        let isPending: Bool

        var body: some View {
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if isPending {
                        if entries.count > 3 {
                            DisclosureGroup("Earlier activity") {
                                rows(entries.dropLast(3))
                            }
                        }
                        rows(entries.suffix(3))
                    } else {
                        DisclosureGroup("Agent activity") {
                            rows(entries[...])
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("orbie-message-activity")
            }
        }

        private func rows(_ items: ArraySlice<AgentTurnActivity>) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    Label(item.text, symbol: symbol(for: item.kind))
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func symbol(for kind: AgentTurnActivity.Kind) -> Symbols {
            switch kind {
            case .update: .textBubbleFill
            case .command: .terminal
            case .file: .docTextFill
            case .search: .magnifyingglass
            case .tool: .gearshape
            }
        }
    }
#endif
