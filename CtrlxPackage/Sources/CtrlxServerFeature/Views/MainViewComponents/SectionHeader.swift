import CtrlxCommon
import SwiftUI

/// A prominent section header with icon and title, optionally showing a "+" button with popover and trailing content
struct SectionHeader<Trailing: View, Popover: View>: View {
    let title: String
    let symbol: Symbols
    var isNewSessionDisabled: Bool
    let trailing: Trailing
    let popover: Popover
    let hasPopover: Bool
    let newSessionButtonIdentifier: String?
    var hasManualSessionOrder = false
    var onRestoreAutomaticOrder: (() -> Void)?
    @State private var showingPopover = false

    var body: some View {
        HStack(spacing: 6) {
            symbol.image
                .font(.headline.weight(.semibold))

            Text(title)
                .font(.headline.weight(.semibold))

            if hasPopover || onRestoreAutomaticOrder != nil || !(trailing is EmptyView) {
                Spacer()
            }

            if let onRestoreAutomaticOrder {
                Button(action: onRestoreAutomaticOrder) {
                    Symbols.arrowUpArrowDown.image
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(!hasManualSessionOrder)
                .accessibilityLabel("Restore Automatic Order")
                .help("Restore Automatic Order")
            }

            if hasPopover {
                Button {
                    showingPopover = true
                } label: {
                    Symbols.plus.image
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isNewSessionDisabled)
                .accessibilityLabel("Create new session")
                .accessibilityIdentifier(newSessionButtonIdentifier ?? "")
                .help(newSessionButtonIdentifier == "new-session-local" ? "Create new session (⌘N)" : "Create new session")
                .popover(isPresented: $showingPopover) {
                    popover
                }
            }

            trailing
        }
        .foregroundStyle(.primary)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .padding(.trailing, 8)
    }
}

// Convenience: no popover, no trailing
extension SectionHeader where Trailing == EmptyView, Popover == EmptyView {
    init(title: String, symbol: Symbols) {
        self.title = title
        self.symbol = symbol
        self.isNewSessionDisabled = false
        self.trailing = EmptyView()
        self.popover = EmptyView()
        self.hasPopover = false
        self.newSessionButtonIdentifier = nil
    }
}

// Convenience: popover only, no trailing
extension SectionHeader where Trailing == EmptyView {
    init(
        title: String,
        symbol: Symbols,
        isNewSessionDisabled: Bool = false,
        newSessionButtonIdentifier: String? = nil,
        hasManualSessionOrder: Bool = false,
        onRestoreAutomaticOrder: (() -> Void)? = nil,
        @ViewBuilder popover: () -> Popover
    ) {
        self.title = title
        self.symbol = symbol
        self.isNewSessionDisabled = isNewSessionDisabled
        self.trailing = EmptyView()
        self.popover = popover()
        self.hasPopover = true
        self.newSessionButtonIdentifier = newSessionButtonIdentifier
        self.hasManualSessionOrder = hasManualSessionOrder
        self.onRestoreAutomaticOrder = onRestoreAutomaticOrder
    }
}

// Convenience: popover + trailing
extension SectionHeader {
    init(
        title: String,
        symbol: Symbols,
        isNewSessionDisabled: Bool = false,
        newSessionButtonIdentifier: String? = nil,
        hasManualSessionOrder: Bool = false,
        onRestoreAutomaticOrder: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder popover: () -> Popover
    ) {
        self.title = title
        self.symbol = symbol
        self.isNewSessionDisabled = isNewSessionDisabled
        self.trailing = trailing()
        self.popover = popover()
        self.hasPopover = true
        self.newSessionButtonIdentifier = newSessionButtonIdentifier
        self.hasManualSessionOrder = hasManualSessionOrder
        self.onRestoreAutomaticOrder = onRestoreAutomaticOrder
    }
}
