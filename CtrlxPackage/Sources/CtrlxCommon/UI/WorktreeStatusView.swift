import CtrlxNetworking
import SwiftUI

public struct SessionWorktreeStatusModifier: ViewModifier {
    let repositories: [RepositoryWorktreeStatus]
    let paths: Set<String>

    public init(repositories: [RepositoryWorktreeStatus], paths: Set<String>) {
        self.repositories = repositories
        self.paths = paths
    }

    public func body(content: Content) -> some View {
        HStack(spacing: 4) {
            content.frame(maxWidth: .infinity, alignment: .leading)
            WorktreeStatusButton(repositories: repositories, paths: paths, pendingOnly: true, compact: true)
        }
    }
}

/// Use as a sibling of session navigation, never nested inside its Button or
/// NavigationLink. Keep the presentation anchor while its live list is open.
public struct WorktreeStatusButton: View {
    let repositories: [RepositoryWorktreeStatus]
    let paths: Set<String>?
    let pendingOnly: Bool
    let compact: Bool
    @State private var isPresented = false

    public init(repositories: [RepositoryWorktreeStatus], paths: Set<String>? = nil, pendingOnly: Bool = false, compact: Bool = false) {
        self.repositories = repositories
        self.paths = paths
        self.pendingOnly = pendingOnly
        self.compact = compact
    }

    public var body: some View {
        let selection = WorktreeStatusSelection(repositories: repositories, paths: paths)
        Group {
            if !selection.repositories.isEmpty, compact || !pendingOnly || selection.badgeText != nil || isPresented {
                Button { isPresented = true } label: {
                    if compact {
                        Label(selection.statusDescription, symbol: statusSymbol(selection.status))
                            .labelStyle(.iconOnly)
                            .font(.caption)
                            .foregroundStyle(selection.status == .pending ? Color.orange : .secondary)
                        #if os(iOS)
                            .frame(width: 44, height: 44)
                        #else
                            .frame(width: 24, height: 24)
                        #endif
                            .contentShape(.rect)
                    } else {
                        Label(pendingOnly ? selection.badgeText ?? "Worktrees" : "Worktrees", symbol: .arrowTriangleBranch)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.vertical, 3)
                        #if os(iOS)
                            .frame(minHeight: 44, alignment: .leading)
                        #endif
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(pendingOnly ? "worktree-pending-status" : "worktree-list-button")
                .help(compact ? selection.statusDescription : "Worktree commits not yet in their local base branch")
            }
        }
        #if os(macOS)
        .popover(isPresented: $isPresented) {
            WorktreeStatusList(repositories: selection.repositories)
                .frame(width: 420, height: 380)
        }
        #else
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                WorktreeStatusList(repositories: selection.repositories)
            }
        }
        #endif
    }

    private func statusSymbol(_ status: WorktreeStatusSelection.Status?) -> Symbols {
        switch status {
        case .pending: .arrowTriangleBranch
        case .merged: .checkmark
        case .unavailable,
             nil: .minus
        }
    }
}

public struct WorktreeStatusList: View {
    let repositories: [RepositoryWorktreeStatus]
    @Environment(\.dismiss) private var dismiss

    public init(repositories: [RepositoryWorktreeStatus]) {
        self.repositories = repositories
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(macOS)
                HStack {
                    Text("Worktrees").font(.headline)
                    Spacer()
                    Button("Done") { dismiss() }
                }
                .padding()
            #endif
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("Each repository uses its unique local main or master branch. Counts compare commit history; uncommitted changes and squash/cherry-pick equivalence are not included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(repositories) { repository in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(repository.worktrees.first.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "Repository")
                                .font(.headline)
                            if let reason = repository.unavailableReason {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Compared with local \(repository.baseBranch ?? "main")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(repository.worktrees) { worktree in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(worktree.branch ?? "Detached HEAD").font(.subheadline.weight(.medium))
                                    Text(status(worktree, baseBranch: repository.baseBranch ?? "main")).font(.caption)
                                    Text(worktree.path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("worktree-status-row")
                            }
                        }
                        Divider()
                    }
                    if repositories.isEmpty {
                        Text("Worktree status is no longer available.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Worktrees")
        #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        #endif
    }

    private func status(_ worktree: WorktreeMergeStatus, baseBranch: String) -> String {
        if let reason = worktree.unavailableReason {
            return reason
        }
        guard let count = worktree.pendingCommitCount else { return "Comparison unavailable" }
        if worktree.branch == baseBranch {
            return "Base branch"
        }
        return count == 0 ? "No commits pending merge" : "\(count) commits not yet in \(baseBranch)"
    }
}
