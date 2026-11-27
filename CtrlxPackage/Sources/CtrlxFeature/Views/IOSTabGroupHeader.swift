import CtrlxCommon
import SwiftUI

@MainActor
struct IOSTabGroupHeader<Content: View>: View {
    @Binding var isExpanded: Bool
    var canUngroup = true
    var onUngroup: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack {
                    content()
                    (isExpanded ? Symbols.chevronDown : .chevronRight).image
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("tab-group-toggle")

            if let onUngroup {
                Menu {
                    Button("Ungroup Tabs", action: onUngroup)
                        .disabled(!canUngroup)
                } label: {
                    Label("Tab Group Actions", symbol: .ellipsisCircle)
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("tab-group-actions")
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}
