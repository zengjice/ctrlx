import CtrlxNetworking
import SwiftUI

@MainActor
struct AgentWorkflowReviewTemplatePicker: View {
    let instances: [AgentWorkflowInstance]
    let apply: (UUID, UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var developerID: UUID?
    @State private var reviewerID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section("Two Agents") {
                    Picker("Developer", selection: $developerID) {
                        Text("Choose an Agent").tag(UUID?.none)
                        ForEach(instances) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    Picker("Reviewer", selection: $reviewerID) {
                        Text("Choose an Agent").tag(UUID?.none)
                        ForEach(instances.filter { $0.id != developerID }) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    Text("Use two Agent tabs in the same working directory. Review reads the files directly; it does not receive the Developer's answer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Steps") {
                    Text("1. Developer: original task and images")
                    Text("2. Reviewer: review instructions only")
                    Text("3. Developer: judge the findings, without fixing yet")
                    Text("4. Content: prepare repair instructions")
                    Text("5. Developer: fix Accepted findings")
                    Text("6. Developer: commit the reviewed changes after approval")
                    Text("7. Developer: merge worktree branches in the primary working tree, or merge main into the current branch")
                    Text("Repeat from Review until no P2 or higher-priority findings remain, then continue to Commit and Merge. The default limit is 100 rounds. Edit the instructions and approval condition after applying this template.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Develop, review and repair")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use template") {
                        guard let developerID, let reviewerID, developerID != reviewerID else { return }
                        apply(developerID, reviewerID)
                        dismiss()
                    }.disabled(developerID == nil || reviewerID == nil || developerID == reviewerID)
                }
            }
        }
        .accessibilityIdentifier("workflow-review-template-picker")
        .onChange(of: developerID) { _, selected in
            if reviewerID == selected {
                reviewerID = nil
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 600, minHeight: 450)
        #endif
    }
}
