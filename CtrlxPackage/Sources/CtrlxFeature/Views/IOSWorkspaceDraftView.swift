#if os(iOS)
    import CtrlxCommon
    import Dependencies
    import SwiftUI

    struct IOSWorkspaceDraftView: View {
        let paneID: String
        let hostID: String
        let activeDraftID: UUID?
        @Environment(IOSFileBrowserWorkspaceStore.self) private var workspaces
        @State private var selectedDraft: IOSWorkspaceRecoveryDraft?

        var body: some View {
            let drafts = workspaces.drafts(paneID: paneID, hostID: hostID).filter { $0.id != activeDraftID }
            if !drafts.isEmpty {
                Menu("Recovered draft") {
                    ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                        Button("Draft \(index + 1)") { selectedDraft = draft }
                    }
                }
                .padding(8)
                .sheet(item: $selectedDraft) { draft in
                    NavigationStack {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Saved for this terminal. Copy the text when you are ready to use it.")
                                .foregroundStyle(.secondary)
                            TextEditor(text: Binding(
                                get: { workspaces.recovery.drafts.first { $0.id == draft.id }?.text ?? "" },
                                set: { workspaces.editDraft(draft.id, text: $0) }
                            ))
                            .font(.system(.body, design: .monospaced))
                            HStack {
                                Button("Discard", role: .destructive) {
                                    workspaces.discardDraft(draft.id)
                                    selectedDraft = nil
                                }
                                Spacer()
                                Button("Copy") {
                                    @Dependency(ClipboardClient.self) var clipboard
                                    clipboard.setString(workspaces.recovery.drafts.first { $0.id == draft.id }?.text ?? "")
                                }
                            }
                        }
                        .padding()
                        .navigationTitle("Recovered draft")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { selectedDraft = nil }
                            }
                        }
                    }
                }
            }
        }
    }
#endif
