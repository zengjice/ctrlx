#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI

    /// Leaves long-press gestures to the List's native session reordering.
    @MainActor
    struct SessionSwipeActionsModifier: ViewModifier {
        let session: TmuxSession
        let isDisabled: Bool
        let isClosingSession: Bool
        let onRename: (String, String) -> Void
        let onSetDescription: (String, String?) -> Void
        let onSetEmoji: (String, String?) -> Void
        let onSetColor: (String, SessionColor?) -> Void
        let onSetState: (String, CLISessionState?) -> Void
        let onClose: (String) -> Void

        @State private var isShowingMore = false
        @State private var pendingAction: MoreAction?
        @State private var isEditingName = false
        @State private var editedName = ""
        @State private var isEditingDescription = false
        @State private var editedDescription = ""
        @State private var isEditingEmoji = false
        @State private var editedEmoji = ""

        private enum MoreAction {
            case editDescription
            case removeDescription
            case editEmoji
            case removeEmoji
            case setColor(SessionColor?)
            case setState(CLISessionState?)
        }

        func body(content: Content) -> some View {
            content
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        editedName = session.sessionName
                        isEditingName = true
                    } label: {
                        Label("Rename", symbol: .pencil)
                    }
                    .tint(.blue)
                    .disabled(isDisabled)
                    .accessibilityLabel("Rename Session")
                    .accessibilityIdentifier("rename-session")

                    Button {
                        isShowingMore = true
                    } label: {
                        Label("More", symbol: .ellipsisCircle)
                    }
                    .tint(.gray)
                    .disabled(isDisabled)
                    .accessibilityIdentifier("session-more-actions")

                    // Closing is asynchronous and may need confirmation; don't optimistically remove the row.
                    Button {
                        onClose(session.sessionName)
                    } label: {
                        Label("Close", symbol: .rectangleStackBadgeMinus)
                    }
                    .tint(.red)
                    .disabled(isDisabled || isClosingSession)
                    .accessibilityLabel("Close Session")
                    .accessibilityIdentifier("close-session")
                }
                .sheet(isPresented: $isShowingMore, onDismiss: performPendingAction) {
                    moreActions
                }
                .modifier(TextEntryPresentation(
                    isPresented: $isEditingName,
                    title: "Rename Session",
                    message: "Enter a new name for this tmux session",
                    placeholder: "Session Name",
                    text: $editedName,
                    onSave: { raw in
                        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !isDisabled, name != session.sessionName else { return }
                        onRename(session.sessionName, name)
                    }
                ))
                .modifier(TextEntryPresentation(
                    isPresented: $isEditingDescription,
                    title: "Session Description",
                    message: "Enter a custom description for this session",
                    placeholder: "Description",
                    text: $editedDescription,
                    onSave: { raw in
                        guard !isDisabled else { return }
                        let description = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSetDescription(session.sessionName, description.isEmpty ? nil : description)
                    }
                ))
                .sheet(isPresented: $isEditingEmoji) {
                    CtrlxEmojiPicker(selectedEmoji: Binding(
                        get: { editedEmoji },
                        set: { emoji in
                            editedEmoji = emoji
                            guard !isDisabled, SessionEmoji.isValid(emoji) else { return }
                            isEditingEmoji = false
                            onSetEmoji(session.sessionName, emoji)
                        }
                    ))
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
        }

        private var moreActions: some View {
            NavigationStack {
                List {
                    Section {
                        DescriptionContextMenuButtons(
                            currentDescription: session.customDescription,
                            isDisabled: isDisabled,
                            onEdit: { select(.editDescription) },
                            onRemove: { select(.removeDescription) }
                        )
                        EmojiContextMenuButtons(
                            currentEmoji: session.customEmoji,
                            isDisabled: isDisabled,
                            onEdit: { select(.editEmoji) },
                            onRemove: { select(.removeEmoji) }
                        )
                    }
                    Section {
                        ColorContextMenuButtons(
                            currentColor: session.customColor,
                            isDisabled: isDisabled
                        ) { select(.setColor($0)) }
                        StateContextMenuButtons(
                            currentState: session.displayedState,
                            hasOverride: session.cliSessionState != nil,
                            isDisabled: isDisabled
                        ) { select(.setState($0)) }
                    }
                }
                .navigationTitle(session.sessionName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isShowingMore = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }

        private func select(_ action: MoreAction) {
            pendingAction = action
            isShowingMore = false
        }

        private func performPendingAction() {
            let action = pendingAction
            pendingAction = nil
            guard !isDisabled, let action else { return }
            // Wait for More to dismiss before presenting an editor or a command error.
            switch action {
            case .editDescription:
                editedDescription = session.customDescription ?? ""
                isEditingDescription = true
            case .removeDescription:
                onSetDescription(session.sessionName, nil)
            case .editEmoji:
                editedEmoji = session.customEmoji ?? ""
                isEditingEmoji = true
            case .removeEmoji:
                onSetEmoji(session.sessionName, nil)
            case let .setColor(color):
                onSetColor(session.sessionName, color)
            case let .setState(state):
                onSetState(session.sessionName, state)
            }
        }
    }
#endif
