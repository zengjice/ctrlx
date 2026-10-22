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
        @State private var moreActionHandler: ((MoreAction) -> Void)?
        @State private var isEditingName = false
        @State private var editedName = ""
        @State private var pendingRename: ((String) -> Void)?
        @State private var isEditingDescription = false
        @State private var editedDescription = ""
        @State private var pendingDescription: ((String?) -> Void)?
        @State private var isEditingEmoji = false
        @State private var editedEmoji = ""
        @State private var pendingEmoji: ((String?) -> Void)?

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
                        pendingRename = { [sessionName = session.sessionName, onRename] name in
                            guard name != sessionName else { return }
                            onRename(sessionName, name)
                        }
                        isEditingName = true
                    } label: {
                        Label("Rename", symbol: .pencil)
                    }
                    .tint(.blue)
                    .disabled(isDisabled)
                    .accessibilityLabel("Rename Session")
                    .accessibilityIdentifier("rename-session")

                    Button {
                        beginMoreActions()
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
                        pendingRename?(name)
                        pendingRename = nil
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
                        pendingDescription?(description.isEmpty ? nil : description)
                        pendingDescription = nil
                    }
                ))
                .sheet(isPresented: $isEditingEmoji) {
                    CtrlxEmojiPicker(selectedEmoji: Binding(
                        get: { editedEmoji },
                        set: { emoji in
                            editedEmoji = emoji
                            guard !isDisabled, SessionEmoji.isValid(emoji) else { return }
                            isEditingEmoji = false
                            pendingEmoji?(emoji)
                            pendingEmoji = nil
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
            let handler = moreActionHandler
            moreActionHandler = nil
            guard !isDisabled, let action else { return }
            // Wait for More to dismiss before presenting an editor or a command error.
            handler?(action)
        }

        private func beginMoreActions() {
            moreActionHandler = { [session, onSetDescription, onSetEmoji, onSetColor, onSetState] action in
                switch action {
                case .editDescription:
                    editedDescription = session.customDescription ?? ""
                    pendingDescription = { onSetDescription(session.sessionName, $0) }
                    isEditingDescription = true
                case .removeDescription:
                    onSetDescription(session.sessionName, nil)
                case .editEmoji:
                    editedEmoji = session.customEmoji ?? ""
                    pendingEmoji = { onSetEmoji(session.sessionName, $0) }
                    isEditingEmoji = true
                case .removeEmoji:
                    onSetEmoji(session.sessionName, nil)
                case let .setColor(color):
                    onSetColor(session.sessionName, color)
                case let .setState(state):
                    onSetState(session.sessionName, state)
                }
            }
            isShowingMore = true
        }
    }
#endif
