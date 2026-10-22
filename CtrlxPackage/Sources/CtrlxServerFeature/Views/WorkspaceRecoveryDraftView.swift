import CtrlxCommon
import Dependencies
import SwiftUI

struct WorkspaceRecoveryDraftView: View {
    let paneID: String
    var hostID: String?
    @Environment(AppCoordinator.self) private var coordinator
    @State private var selectedDraft: WorkspaceRecoveryDraft?

    var body: some View {
        let store = coordinator.recoveredWorkspaceDrafts
        let drafts = hostID.map { store.remoteDrafts(paneID: paneID, hostID: $0) } ?? store.localDrafts(paneID: paneID)
        if !drafts.isEmpty {
            Menu("Recovered draft") {
                ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                    Button("Draft \(index + 1)") { selectedDraft = draft }
                }
            }
            .controlSize(.small)
            .lineLimit(1)
            .frame(maxWidth: 160)
            .padding(4)
            .sheet(item: $selectedDraft) { draft in
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recovered draft").font(.headline)
                    Text("Saved for this terminal. Copy the text when you are ready to use it.").foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { store.text(id: draft.id) }, set: { store.edit(id: draft.id, text: $0) }))
                        .font(.system(.body, design: .monospaced))
                    HStack {
                        Button("Discard", role: .destructive) {
                            store.discard(id: draft.id)
                            selectedDraft = nil
                        }
                        Spacer()
                        Button("Copy") {
                            @Dependency(ClipboardClient.self) var clipboard
                            clipboard.setString(store.text(id: draft.id))
                        }
                        Button("Done") { selectedDraft = nil }.keyboardShortcut(.cancelAction)
                    }
                }
                .padding()
                .frame(minWidth: 400, idealWidth: 560, minHeight: 300, idealHeight: 420)
            }
        }
    }
}
