import CtrlxNetworking
import SwiftUI

@MainActor
struct WorktreeReview: View {
    let plan: AgentForkWorktree
    let name: String
    @Binding var allowUncommittedChanges: Bool
    let acknowledgementIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Use letters, numbers, ., _ or -; start with a letter or number. Do not use HEAD, .., or end with . or .lock.")
                .font(.caption).foregroundStyle(.secondary)
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = "Base: \(plan.head.prefix(12))"
            let preview = AgentForkWorktree.isValidName(name) ? "Branch: \(name)\nDirectory: \(plan.directory(name: name))\n\(base)" : base
            Text(preview).font(.callout).textSelection(.enabled)
            Text("Starts from HEAD. Uncommitted, untracked and ignored files are not copied. The worktree remains after closing its tab.")
                .font(.callout).foregroundStyle(.secondary)
            if plan.hasUncommittedChanges {
                Toggle("I understand the source has changes that will not be copied", isOn: $allowUncommittedChanges)
                    .accessibilityIdentifier(acknowledgementIdentifier)
            }
        }
    }
}
