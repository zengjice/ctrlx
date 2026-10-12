import CtrlxNetworking
import SwiftUI

/// Embedded in the existing form: no sheet or NavigationStack, and no launch
/// callback. Clicking a folder can only change the selected path.
@MainActor
public struct SessionDirectoryBrowser: View {
    @Binding var path: String
    @Binding private var isCreatingDirectory: Bool
    let source: SessionDirectorySource

    @State private var includeHidden = false
    @State private var retry = 0
    @State private var state = SessionDirectoryBrowseState()
    @State private var creation = SessionDirectoryCreationState()
    @State private var showsFolderPrompt = false
    @State private var folderName = ""
    @State private var folderPrompt: FolderPrompt?

    public init(path: Binding<String>, source: SessionDirectorySource, isCreatingDirectory: Binding<Bool> = .constant(false)) {
        _path = path
        _isCreatingDirectory = isCreatingDirectory
        self.source = source
    }

    private struct FolderPrompt {
        let hostID: String
        let path: String
        let parentDirectory: String
    }

    private var query: SessionDirectoryBrowseState.Query {
        .init(hostID: source.id, path: path, includeHidden: includeHidden, unavailableReason: source.unavailableReason, retry: retry)
    }

    private var listing: SessionDirectoryListing? {
        state.query == query ? state.listing : nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { navigate(to: "~/") } label: {
                    Label("Home", symbol: .house)
                }
                Button { if let parent = listing?.parentDirectory { navigate(to: parent) } } label: {
                    Label("Up", symbol: .arrowUpCircleFill)
                }
                .disabled(listing?.parentDirectory == nil)
                #if os(iOS)
                    Button {
                        guard let listing, listing.isExactDirectory else { return }
                        folderPrompt = .init(hostID: source.id, path: path, parentDirectory: listing.directory)
                        folderName = ""
                        showsFolderPrompt = true
                    } label: {
                        Label("New Folder", symbol: .folderBadgePlus)
                    }
                    .disabled(source.creationUnavailableReason != nil || listing?.isExactDirectory != true || state.isLoading || state.error != nil)
                    .accessibilityIdentifier("create-session-directory")
                #endif
                Spacer()
                Button { retry += 1 } label: {
                    Label("Refresh", symbol: .arrowClockwise)
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("refresh-session-directories")
            }
            .buttonStyle(.borderless)
            .disabled(source.unavailableReason != nil)

            #if os(iOS)
                if source.unavailableReason == nil, let reason = source.creationUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                if creation.isCreating {
                    ProgressView("Creating folder…").controlSize(.small)
                } else if let error = creation.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            #endif

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
        .disabled(creation.isCreating)
        .task(id: query) { await load() }
        #if os(iOS)
            .alert("New Folder", isPresented: $showsFolderPrompt) {
                TextField("Folder name", text: $folderName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Create", action: beginCreation)
                    .disabled(!SessionDirectoryName.isValid(folderName))
            } message: {
                Text("Create in \(folderPrompt?.parentDirectory ?? ""). Enter one folder name, without /. This does not start a session.")
            }
            .task(id: creation.request?.id) { await createDirectory() }
            .onDisappear {
                creation.cancel()
                isCreatingDirectory = false
            }
        #endif
    }

    private func beginCreation() {
        guard let prompt = folderPrompt,
              prompt.hostID == source.id, prompt.path == path,
              source.creationUnavailableReason == nil, source.create != nil,
              listing?.isExactDirectory == true, listing?.directory == prompt.parentDirectory,
              creation.begin(hostID: prompt.hostID, path: prompt.path, parentDirectory: prompt.parentDirectory, name: folderName) != nil
        else { return }
        isCreatingDirectory = true
    }

    private func createDirectory() async {
        guard let request = creation.request else { return }
        defer { isCreatingDirectory = creation.isCreating }
        guard request.hostID == source.id, request.path == path, let create = source.create else {
            creation.cancel()
            return
        }
        do {
            try Task.checkCancellation()
            let directory = try await create(request.command)
            try Task.checkCancellation()
            if let destination = creation.finish(request.id, directory: directory, hostID: source.id, path: path) {
                navigate(to: destination)
            }
        } catch {
            if Task.isCancelled {
                if creation.request?.id == request.id { creation.cancel() }
            } else {
                creation.fail(request.id, message: error.localizedDescription, hostID: source.id, path: path)
            }
        }
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
