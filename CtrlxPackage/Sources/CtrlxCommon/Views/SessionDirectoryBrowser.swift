import CtrlxNetworking
import SwiftUI

/// Embedded in the existing form: no sheet or NavigationStack, and no launch
/// callback. Clicking a folder can only change the selected path.
@MainActor
struct SessionDirectoryBrowser: View {
    @Binding var path: String
    let source: SessionDirectorySource

    @State private var includeHidden = false
    @State private var retry = 0
    @State private var state = SessionDirectoryBrowseState()

    private var query: SessionDirectoryBrowseState.Query {
        .init(hostID: source.id, path: path, includeHidden: includeHidden, unavailableReason: source.unavailableReason, retry: retry)
    }

    private var listing: SessionDirectoryListing? {
        state.query == query ? state.listing : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { navigate(to: "~/") } label: {
                    Label("Home", symbol: .house)
                }
                Button { if let parent = listing?.parentDirectory { navigate(to: parent) } } label: {
                    Label("Up", symbol: .arrowUpCircleFill)
                }
                .disabled(listing?.parentDirectory == nil)
                Spacer()
                Button { retry += 1 } label: {
                    Label("Refresh", symbol: .arrowClockwise)
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("refresh-session-directories")
            }
            .buttonStyle(.borderless)
            .disabled(source.unavailableReason != nil)

            if let reason = source.unavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else if !SessionDirectoryPath.isValid(path) {
                Text("Enter /… or ~/… to browse the Host.").font(.caption).foregroundStyle(.secondary)
            } else if state.query != query || state.isLoading {
                ProgressView("Loading directories…")
                    .controlSize(.small)
            } else if let error = state.error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let listing {
                Text(listing.isExactDirectory ? "Folders in \(listing.directory)" : "Matches in \(listing.directory)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if listing.entries.isEmpty {
                    Text(listing.isExactDirectory ? "No subdirectories. You can start here." : "No matching directories.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(listing.entries) { entry in
                                Button { navigate(to: entry.path) } label: {
                                    HStack {
                                        Label(entry.name, symbol: .folder)
                                            .lineLimit(2)
                                        Spacer()
                                        Symbols.chevronRight.image.foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("session-directory-\(entry.path)")
                            }
                        }
                    }
                    .frame(height: min(CGFloat(listing.entries.count) * 48, 240))
                    .id(listing.directory)
                }
                if listing.isTruncated {
                    Text("More folders are available. Type more of the path to narrow the results.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Show hidden folders", isOn: $includeHidden)
                .font(.caption)
                .disabled(source.unavailableReason != nil)
        }
        .task(id: query) { await load() }
    }

    private func navigate(to directory: String) {
        path = directory.hasSuffix("/") ? directory : directory + "/"
    }

    private func load() async {
        let requestedQuery = query
        let id = state.begin(requestedQuery)
        guard source.unavailableReason == nil, SessionDirectoryPath.isValid(path) else { return }
        do {
            // Debounce typing, and let SwiftUI cancel when query/Host changes.
            try await Task.sleep(for: .milliseconds(250))
            let result = try await source.list(.init(path: requestedQuery.path, includeHidden: requestedQuery.includeHidden))
            try Task.checkCancellation()
            state.finish(id, listing: result)
        } catch {
            guard !Task.isCancelled else { return }
            state.fail(id, message: error.localizedDescription)
        }
    }
}
