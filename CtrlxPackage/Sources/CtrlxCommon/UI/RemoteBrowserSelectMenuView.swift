#if os(macOS) || os(iOS)
    import CtrlxNetworking
    import SwiftUI

    struct RemoteBrowserSelectMenuView: View {
        let menu: RemoteBrowserSelectMenu
        let choose: (Int) -> Void
        let cancel: () -> Void

        var body: some View {
            NavigationStack {
                List(menu.options) { option in
                    Button { choose(option.index) } label: {
                        HStack {
                            Text(option.text.isEmpty ? "(Empty)" : option.text)
                                .foregroundStyle(.primary)
                            Spacer()
                            if option.selected {
                                Symbols.checkmark.image
                            }
                        }
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(option.disabled)
                    .opacity(option.disabled ? 0.45 : 1)
                    .accessibilityAddTraits(option.selected ? .isSelected : [])
                }
                .navigationTitle(menu.title.isEmpty ? "Select an Option" : menu.title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    }
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
            }
            #if os(macOS)
            .frame(width: 420, height: 400)
            #else
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #endif
        }
    }
#endif
