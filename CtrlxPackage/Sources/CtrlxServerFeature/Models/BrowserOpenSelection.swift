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
    init(
        localWindowID: String?,
        remoteSession: RemoteSessionSelection?,
        remoteWindowID: String?,
        tabs: SessionFileTabsState?,
        fileBrowserActiveWindowIDs: Set<String>
    ) {
        self.localWindowID = localWindowID
        self.remoteSession = remoteSession
        self.remoteWindowID = remoteWindowID
        self.browserTabID = tabs?.selectedBrowserTabId
        self.fileTabID = tabs?.selectedFileTabId
        self.rightSelection = tabs?.selectedRight
        self.isGitActive = tabs?.isGitSelected == true
        self.isFileBrowserActive = localWindowID.map(fileBrowserActiveWindowIDs.contains) ?? false
    }
}
