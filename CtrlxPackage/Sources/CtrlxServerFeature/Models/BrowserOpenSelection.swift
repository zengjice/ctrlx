import Foundation

/// Selection at request time, including content that shares the terminal's window ID.
struct BrowserOpenSelection: Equatable {
    private let localWindowID: String?
    private let remoteSession: RemoteSessionSelection?
    private let remoteWindowID: String?
    private let browserTabID: UUID?
    private let fileTabID: UUID?
    private let rightSelection: TabDragPayload?
    private let isGitActive: Bool
    private let isFileBrowserActive: Bool

    @MainActor
    init(localWindowID: String?, remoteSession: RemoteSessionSelection?, remoteWindowID: String?,
         tabs: SessionFileTabsState?, gitActiveWindowIDs: Set<String>, fileBrowserActiveWindowIDs: Set<String>) {
        self.localWindowID = localWindowID
        self.remoteSession = remoteSession
        self.remoteWindowID = remoteWindowID
        browserTabID = tabs?.selectedBrowserTabId
        fileTabID = tabs?.selectedFileTabId
        rightSelection = tabs?.selectedRight
        isGitActive = localWindowID.map(gitActiveWindowIDs.contains) ?? false
        isFileBrowserActive = localWindowID.map(fileBrowserActiveWindowIDs.contains) ?? false
    }
}
