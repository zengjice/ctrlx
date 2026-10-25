#if os(macOS)
    import CtrlxNetworking
    import SwiftUI

    /// View modifier that adds a "Rename Window" context menu and an alert for
    /// editing the window name. Kept parallel to `DescriptionEditingModifier` so
    /// tabs feel consistent with session description editing.
    public struct WindowRenamingModifier: ViewModifier {
        let currentName: String
        let isDisabled: Bool
        let onRename: (_ newName: String) -> Void
        let additionalMenu: @MainActor () -> [ContextMenuItem]

        @State private var isEditingName = false
        @State private var editedName = ""
        /// Keep the target captured when editing began, even if the tab is replaced.
        @State private var pendingRename: ((String) -> Void)?

        public init(
            currentName: String,
            isDisabled: Bool = false,
            onRename: @escaping (_ newName: String) -> Void,
            additionalMenu: @escaping @MainActor () -> [ContextMenuItem] = { [] }
        ) {
            self.currentName = currentName
            self.isDisabled = isDisabled
            self.onRename = onRename
            self.additionalMenu = additionalMenu
        }

        public func body(content: Content) -> some View {
            content
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded { beginRenaming() }
                )
                .stableContextMenu {
                    var items: [ContextMenuItem] = [
                        .button(title: "Rename Window", symbol: .pencil, isEnabled: !isDisabled) {
                            beginRenaming()
                        },
                    ]
                    items.append(contentsOf: additionalMenu())
                    return items
                }
                .modifier(TextEntryPresentation(
                    isPresented: $isEditingName,
                    title: "Rename Window",
                    message: "Enter a new name for this window",
                    placeholder: "Window Name",
                    text: $editedName,
                    onSave: { raw in
                        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        pendingRename?(trimmed)
                        pendingRename = nil
                    }
                ))
        }

        private func beginRenaming() {
            guard !isDisabled else { return }
            editedName = currentName
            pendingRename = onRename
            isEditingName = true
        }
    }
#endif
