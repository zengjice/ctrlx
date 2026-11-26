#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Foundation

    /// Translates between the live, in-memory `SessionFileTabsState` (+ its
    /// `FileBrowserState`) and the serializable `SavedFolderLayout`.
    ///
    /// The two directions are not symmetric: capturing reads the live runtime
    /// types; restoring rebuilds them into a *fresh* session. Window references
    /// are translated by tmux window *index* via injected resolvers (the mapper
    /// stays free of any knowledge of tmux id formatting, which keeps it pure and
    /// unit-testable). Browser tabs are rebuilt through an injected factory so the
    /// mapper never touches `WKWebView`.
    enum LayoutSnapshotMapper {
        /// Minimal live-window input used when restoring the Host-owned terminal
        /// layout. Keeping this separate from the UI's `LocalTmuxWindow` lets the
        /// Host initialize layouts for background sessions directly from its
        /// pane-state snapshot, without materializing private file/browser tabs.
        struct TerminalWindow: Sendable, Equatable {
            let index: Int
            let stableId: String
            let isActive: Bool

            init(index: Int, stableId: String, isActive: Bool = false) {
                self.index = index
                self.stableId = stableId
                self.isActive = isActive
            }
        }

        /// Rebuilds the terminal-only portion of a persisted workbench as an
        /// explicit Host layout. A missing persisted record intentionally
        /// produces an explicit unsplit layout; on the wire, a missing session
        /// entry means "Host has not initialized this session yet", not
        /// "unsplit".
        static func sharedTerminalLayoutRequest(
            from layout: SavedFolderLayout?,
            sessionName: String,
            windows: [TerminalWindow],
            preferredLeftWindowId: String? = nil
        ) -> SetSharedTerminalLayout? {
            let orderedWindows = windows.sorted { lhs, rhs in
                if lhs.index != rhs.index {
                    return lhs.index < rhs.index
                }
                return lhs.stableId < rhs.stableId
            }
            guard !sessionName.isEmpty, !orderedWindows.isEmpty else { return nil }

            let rightIndices = Set((layout?.rightSide ?? []).compactMap(\.windowIndex))
            let localRightID = orderedWindows.first { $0.index == layout?.localRightTerminalIndex }?.stableId
            var seen: Set<String> = []
            var rightWindowIds = orderedWindows
                .filter { $0.stableId != localRightID && rightIndices.contains($0.index) && seen.insert($0.stableId).inserted }
                .map(\.stableId)

            let leftWindows = orderedWindows.filter { !rightWindowIds.contains($0.stableId) }
            let sharedLeft = leftWindows.filter { $0.stableId != localRightID }
            let leftCandidates = sharedLeft.isEmpty ? leftWindows : sharedLeft
            let preferredLeft = preferredLeftWindowId.flatMap { id in leftCandidates.contains { $0.stableId == id } ? id : nil }
            let leftWindowId = preferredLeft
                ?? leftCandidates.first(where: \.isActive)?.stableId
                ?? leftCandidates.first?.stableId
                ?? orderedWindows.first(where: \.isActive)?.stableId
                ?? orderedWindows[0].stableId

            // The shared protocol always names one terminal on the left. A
            // malformed/legacy snapshot that parked every terminal on the right
            // is normalized by moving the chosen left terminal out of that set.
            rightWindowIds.removeAll { $0 == leftWindowId }

            let preferredRightIndices = [layout?.selectedRightTerminalIndex, layout?.selectedRight?.windowIndex].compactMap { $0 }
            let selectedRightWindowId = preferredRightIndices.lazy.compactMap { index in
                orderedWindows.first { $0.index == index && rightWindowIds.contains($0.stableId) }?.stableId
            }.first ?? rightWindowIds.first

            return SetSharedTerminalLayout(
                sessionName: sessionName,
                leftWindowId: leftWindowId,
                rightWindowIds: rightWindowIds,
                selectedRightWindowId: selectedRightWindowId,
                splitRatio: Double(layout?.splitRatio ?? 0.5)
            )
        }

        // MARK: - Capture

        /// Snapshot the live workbench into a serializable layout.
        ///
        /// - Parameter windowIndexForId: maps a live tmux window id (as stored in
        ///   a `.window` tab payload) to its index within the session, or `nil`
        ///   if the window no longer exists. Window refs that don't resolve are
        ///   dropped from the snapshot.
        @MainActor
        static func snapshot(
            from tabs: SessionFileTabsState,
            fileBrowser: FileBrowserState?,
            includeHostFiles: Bool = false,
            includeUnavailableFiles: Bool = false,
            excluding excludedTabs: Set<TabDragPayload> = [],
            tabOrder: [TabDragPayload]? = nil,
            hiddenRightWindowIDs: [String] = [],
            windowIndexForId: (String) -> Int?
        ) -> SavedFolderLayout {
            // Deleted tabs reference files that no longer exist — don't persist them.
            let liveFileTabs = tabs.openFileTabs.filter {
                (includeUnavailableFiles || !$0.isDeleted)
                    && (includeHostFiles || tabs.directoryTabs[$0.id]?.hostTab == nil) && (!$0.isDirectory || tabs.directoryTabs[$0.id]?.snapshot != nil)
            }
            let fileTabs = liveFileTabs.map {
                SavedFileTab(id: $0.id, path: $0.path, directoryPath: $0.directoryPath, browser: tabs.directoryTabs[$0.id]?.snapshot)
            }
            let browserTabs = tabs.openBrowserTabs.filter { !$0.isTransient }.map { tab in
                SavedBrowserTab(
                    id: tab.id,
                    url: tab.url,
                    // Prefer the live page title the web view reported.
                    displayTitle: tabs.browserStates[tab.id]?.pageTitle ?? tab.displayTitle,
                    parentId: tab.parentTabId
                )
            }

            let keptFileIds = Set(fileTabs.map(\.id))
            let keptBrowserIds = Set(browserTabs.map(\.id))

            func ref(for payload: TabDragPayload) -> SavedTabRef? {
                if case let .file(id) = payload, !keptFileIds.contains(id) {
                    return nil
                }
                if case let .browser(id) = payload, !keptBrowserIds.contains(id) {
                    return nil
                }
                return savedRef(for: payload, windowIndexForId: windowIndexForId)
            }

            let selectedLeft: SavedTabRef? =
                if let id = tabs.selectedFileTabId, keptFileIds.contains(id) {
                    .file(id: id)
                } else if let id = tabs.selectedBrowserTabId, keptBrowserIds.contains(id) {
                    .browser(id: id)
                } else {
                    nil
                }

            let fileTree = fileBrowser.map {
                SavedFileTree(sidebarWidth: $0.sidebarWidth, expandedPaths: [])
            }

            let order = tabOrder ?? tabs.tabOrder
            let layout = SavedFolderLayout(
                fileTabs: fileTabs,
                browserTabs: browserTabs,
                tabOrder: order.compactMap(ref),
                linkedTabOrder: order.compactMap(\.linkedID),
                ordersTabGroups: tabs.ordersTabGroups ? true : nil,
                rightSide: tabs.rightSide.union(hiddenRightWindowIDs.map(TabDragPayload.window))
                    .union(tabs.locallySplitTerminalID.map { [TabDragPayload.window($0)] } ?? []).compactMap(ref),
                selectedLeft: selectedLeft,
                selectedRight: tabs.selectedRight.flatMap(ref),
                selectedRightTerminalIndex: tabs.appliedSharedTerminalLayout?.selectedRightWindowId.flatMap(windowIndexForId),
                localRightTerminalIndex: tabs.locallySplitTerminalID.flatMap(windowIndexForId),
                splitRatio: tabs.splitRatio,
                fileTree: fileTree
            )
            return excluding(excludedTabs, from: layout, windowIndexForId: windowIndexForId)
        }

        static func excluding(
            _ tabs: Set<TabDragPayload>, from layout: SavedFolderLayout, validateBrowserParents: Bool = true,
            windowIndexForId: (String) -> Int?
        ) -> SavedFolderLayout {
            guard !tabs.isEmpty || layout.browserTabs.contains(where: { $0.parentId != nil }) else { return layout }
            let excludedRefs = Set(tabs.compactMap { savedRef(for: $0, windowIndexForId: windowIndexForId) })
            let excludedLinkedIDs = Set(tabs.compactMap(\.linkedID))
            var result = layout
            result.fileTabs.removeAll { excludedRefs.contains(.file(id: $0.id)) }
            result.browserTabs.removeAll { excludedRefs.contains(.browser(id: $0.id)) }
            result.tabOrder.removeAll(where: excludedRefs.contains)
            result.linkedTabOrder?.removeAll(where: excludedLinkedIDs.contains)
            result.rightSide.removeAll(where: excludedRefs.contains)
            result.selectedLeft = result.selectedLeft.flatMap { excludedRefs.contains($0) ? nil : $0 }
            result.selectedRight = result.selectedRight.flatMap { excludedRefs.contains($0) ? nil : $0 }
            if let index = result.selectedRightTerminalIndex, excludedRefs.contains(.window(index: index)) {
                result.selectedRightTerminalIndex = nil
            }
            if let index = result.localRightTerminalIndex, excludedRefs.contains(.window(index: index)) {
                result.localRightTerminalIndex = nil
            }
            guard validateBrowserParents else { return result }
            let browserIDs = Set(result.browserTabs.map(\.id))
            for index in result.browserTabs.indices {
                if let parent = result.browserTabs[index].parentId, !browserIDs.contains(parent) {
                    result.browserTabs[index].parentId = nil
                }
            }
            return result
        }

        static func excludingEditors(at paths: Set<String>, from layout: SavedFolderLayout) -> SavedFolderLayout {
            guard !paths.isEmpty else { return layout }
            let tabs = layout.fileTabs.filter { $0.browser == nil && paths.contains($0.path) }
            return excluding(Set(tabs.map { .file($0.id) }), from: layout, windowIndexForId: { _ in nil })
        }

        enum BrowserEdit: Sendable {
            case navigate(URL)
            case close
        }

        static func applyingBrowserEdits(_ edits: [UUID: BrowserEdit], to layout: SavedFolderLayout) -> SavedFolderLayout {
            guard !edits.isEmpty else { return layout }
            var result = layout
            for index in result.browserTabs.indices {
                if case let .navigate(url) = edits[result.browserTabs[index].id] {
                    result.browserTabs[index].url = url
                }
            }
            let closedTabs = edits.compactMap { id, edit -> TabDragPayload? in
                guard case .close = edit else { return nil }
                return .browser(id)
            }
            return excluding(Set(closedTabs), from: result, windowIndexForId: { _ in nil })
        }

        @MainActor
        static func privateTabAdditions(
            _ additions: Set<TabDragPayload>, from tabs: SessionFileTabsState, includeSelection: Bool = false,
            windowIndexForId: (String) -> Int? = { _ in nil }
        ) -> SavedFolderLayout {
            let resources = tabs.openFileTabs.map { TabDragPayload.file($0.id) } + tabs.openBrowserTabs.map { .browser($0.id) }
            let terminals = tabs.tabOrder.filter { $0.windowId != nil }
            let layout = snapshot(
                from: tabs, fileBrowser: nil, tabOrder: PaneLinkedTabs.ordered(resources + terminals, stored: tabs.tabOrder),
                windowIndexForId: windowIndexForId
            )
            // A popup can refer to a parent already present in the destination layout.
            var result = excluding(Set(resources).subtracting(additions), from: layout, validateBrowserParents: false, windowIndexForId: { _ in nil })
            if !includeSelection {
                result.selectedLeft = nil
                result.selectedRight = nil
            }
            return result
        }

        static func mergingFolderEdit(
            _ draft: SavedFolderLayout, into saved: SavedFolderLayout, updatesTerminalPlacement: Bool, splitRatio: CGFloat?,
            updatesTabOrder: Bool = false, terminalSelectionSides: Set<Bool> = []
        ) -> SavedFolderLayout {
            var result = addingEarlyTabs(from: draft, to: saved, updatesTabOrder: updatesTabOrder)
            if updatesTerminalPlacement {
                let rightTerminals = draft.rightSide.filter(\.isWindow)
                result.rightSide.removeAll(where: \.isWindow)
                result.rightSide += rightTerminals
                result.localRightTerminalIndex = draft.localRightTerminalIndex
                result.selectedRightTerminalIndex = draft.selectedRightTerminalIndex ?? draft.selectedRight?.windowIndex
                if result.selectedRight?.isWindow != false {
                    result.selectedRight = draft.selectedRight.flatMap { rightTerminals.contains($0) ? $0 : nil }
                        ?? result.selectedRightTerminalIndex.map(SavedTabRef.window(index:))
                }
            }
            if terminalSelectionSides.contains(false), draft.selectedLeft == nil {
                result.selectedLeft = nil
            }
            if terminalSelectionSides.contains(true), let terminal = draft.selectedRight, terminal.isWindow, result.rightSide.contains(terminal) {
                result.selectedRight = terminal
                result.selectedRightTerminalIndex = draft.selectedRightTerminalIndex
            }
            if let splitRatio {
                result.splitRatio = splitRatio
            }
            return result
        }

        static func applyingSharedTerminalLayout(
            _ shared: SharedTerminalLayout, previousLeftWindowID: String?, indices windowIndices: [String: [Int]], to layout: SavedFolderLayout
        ) -> SavedFolderLayout {
            let indices = preferredWindowIndices(windowIndices, in: layout)
            guard indices[shared.leftWindowId] != nil else { return layout }
            let right = Set(layout.rightSide)
            let hasLeftResource = layout.fileTabs.contains { !right.contains(.file(id: $0.id)) }
                || layout.browserTabs.contains { !right.contains(.browser(id: $0.id)) }
                || layout.tabOrder.contains { ($0 == .git || $0 == .fileExplorer) && !right.contains($0) }
            // The Host can put the shared left terminal on the right, beside a private tab.
            let sharedRight = shared.rightWindowIds.compactMap { indices[$0].map(SavedTabRef.window(index:)) }
            let localIndex: Int? = if let index = layout.localRightTerminalIndex, indices.values.contains(index) {
                index
            } else if hasLeftResource, indices.values.allSatisfy({ right.contains(.window(index: $0)) }) {
                previousLeftWindowID.flatMap { indices[$0] }
            } else {
                nil
            }
            let localRight = localIndex.map(SavedTabRef.window(index:)).flatMap { sharedRight.contains($0) ? nil : $0 }
            var result = layout
            result.rightSide.removeAll(where: \.isWindow)
            result.rightSide += sharedRight
            if let localRight {
                result.rightSide.append(localRight)
            }
            result.localRightTerminalIndex = localRight?.windowIndex
            result.selectedRightTerminalIndex = shared.selectedRightWindowId.flatMap { indices[$0] }
            if result.selectedRight?.isWindow != false, localRight == nil || result.selectedRight != localRight {
                result.selectedRight = result.selectedRightTerminalIndex.map(SavedTabRef.window(index:))
                    ?? localRight
            }
            result.splitRatio = CGFloat(shared.splitRatio)
            return result
        }

        private static func preferredWindowIndices(_ windowIndices: [String: [Int]], in saved: SavedFolderLayout) -> [String: Int] {
            let preferred = [saved.localRightTerminalIndex, saved.selectedRightTerminalIndex, saved.selectedRight?.windowIndex].compactMap { $0 }
                + saved.rightSide.compactMap(\.windowIndex) + saved.tabOrder.compactMap(\.windowIndex)
            return windowIndices.compactMapValues { choices in preferred.first(where: choices.contains) ?? choices.min() }
        }

        static func preservingAliasedWindowIndices(
            in draft: SavedFolderLayout, from saved: SavedFolderLayout, windowIndices: [String: [Int]]
        ) -> SavedFolderLayout {
            let aliases = windowIndices.filter { $0.value.count > 1 }
            guard !aliases.isEmpty else { return draft }
            let preferred = preferredWindowIndices(aliases, in: saved)
            let remapped = Dictionary(uniqueKeysWithValues: aliases.flatMap { id, indices in
                indices.compactMap { index in preferred[id].map { (index, $0) } }
            })
            func remap(_ ref: SavedTabRef) -> SavedTabRef {
                guard let index = ref.windowIndex, let preferred = remapped[index] else { return ref }
                return .window(index: preferred)
            }
            var result = draft
            result.tabOrder = draft.tabOrder.map(remap)
            result.rightSide = draft.rightSide.map(remap)
            result.selectedLeft = draft.selectedLeft.map(remap)
            result.selectedRight = draft.selectedRight.map(remap)
            result.selectedRightTerminalIndex = draft.selectedRightTerminalIndex.map { remapped[$0] ?? $0 }
            result.localRightTerminalIndex = draft.localRightTerminalIndex.map { remapped[$0] ?? $0 }
            return result
        }

        /// Keep the slots of saved tabs outside the edited workbench.
        private static func applyingOrder<T: Hashable>(_ draft: [T], to saved: [T]) -> [T] {
            let savedSet = Set(saved)
            let draftSet = Set(draft)
            var seen = Set<T>()
            var reordered = draft.filter { savedSet.contains($0) && seen.insert($0).inserted }.makeIterator()
            return saved.map { draftSet.contains($0) ? reordered.next() ?? $0 : $0 }
        }

        static func applyingPrivateTabOrder(from draft: SavedFolderLayout, to saved: SavedFolderLayout) -> SavedFolderLayout {
            var result = saved
            // A new live terminal can be the anchor of this reorder even if the folder has not saved it yet.
            var known = Set(result.tabOrder)
            result.tabOrder += draft.tabOrder.filter { $0.isWindow && known.insert($0).inserted }
            let refs = Dictionary(uniqueKeysWithValues: draft.fileTabs.compactMap { file -> (SavedTabRef, SavedTabRef)? in
                guard let existing = matchingFile(file, in: saved) else { return nil }
                return (.file(id: file.id), .file(id: existing.id))
            })
            applyTabOrder(from: draft, remappedRefs: refs, to: &result)
            if saved.linkedTabOrder == nil {
                result.linkedTabOrder = nil
            }
            return result
        }

        private static func matchingFile(_ file: SavedFileTab, in layout: SavedFolderLayout) -> SavedFileTab? {
            layout.fileTabs.first { $0.id == file.id || (file.browser == nil && $0.browser == nil && $0.path == file.path) }
        }

        private static func applyTabOrder(from draft: SavedFolderLayout, remappedRefs: [SavedTabRef: SavedTabRef], to result: inout SavedFolderLayout) {
            if draft.ordersTabGroups == true {
                result.ordersTabGroups = true
            }
            result.tabOrder = applyingOrder(draft.tabOrder.map { remappedRefs[$0] ?? $0 }, to: result.tabOrder)
            if
                let order = draft.linkedTabOrder?.map({ id in
                    guard case let .file(fileID) = id, case let .file(savedID) = remappedRefs[.file(id: fileID)] else { return id }
                    return .file(savedID)
                }) {
                result.linkedTabOrder = result.linkedTabOrder.map { applyingOrder(order, to: $0) } ?? order
            }
        }

        /// Add private tabs to a folder while retaining its terminal split.
        static func addingEarlyTabs(from draft: SavedFolderLayout, to saved: SavedFolderLayout, updatesTabOrder: Bool = false) -> SavedFolderLayout {
            var result = saved
            var remappedRefs: [SavedTabRef: SavedTabRef] = [:]
            for file in draft.fileTabs {
                let existing = matchingFile(file, in: result)
                if existing == nil {
                    result.fileTabs.append(file)
                }
                remappedRefs[.file(id: file.id)] = .file(id: existing?.id ?? file.id)
            }
            for browser in draft.browserTabs {
                if !result.browserTabs.contains(where: { $0.id == browser.id }) {
                    result.browserTabs.append(browser)
                }
                remappedRefs[.browser(id: browser.id)] = .browser(id: browser.id)
            }
            result.tabOrder += draft.tabOrder.compactMap { remappedRefs[$0] }.filter { !result.tabOrder.contains($0) }
            result.rightSide += draft.rightSide.compactMap { remappedRefs[$0] }.filter { !result.rightSide.contains($0) }
            if updatesTabOrder {
                applyTabOrder(from: draft, remappedRefs: remappedRefs, to: &result)
            }
            if let left = draft.selectedLeft.flatMap({ remappedRefs[$0] }) {
                result.rightSide.removeAll { $0 == left }
                result.selectedLeft = left
            }
            if let right = draft.selectedRight.flatMap({ remappedRefs[$0] }), result.rightSide.contains(right) {
                result.selectedRight = right
            }
            if let right = result.selectedRight, !result.rightSide.contains(right) {
                result.selectedRight = nil
            }
            if let left = result.selectedLeft, result.rightSide.contains(left) {
                result.selectedLeft = nil
            }
            return result
        }

        /// Restricts a saved layout to state a remote Viewer can own and render.
        /// Terminal placement is Host-owned shared state, while remote file/Git
        /// views do not exist. Keeping those references in a Viewer record can
        /// leave `rightSide` non-empty with no renderable right pane, producing a
        /// permanent half-width terminal after restore.
        static func viewerPrivateLayout(from layout: SavedFolderLayout) -> SavedFolderLayout {
            let browserIds = Set(layout.browserTabs.map(\.id))
            let files = layout.fileTabs.filter { $0.browser != nil }
            let fileIDs = Set(files.map(\.id))

            func validBrowserRef(_ ref: SavedTabRef) -> SavedTabRef? {
                switch ref {
                case let .browser(id) where browserIds.contains(id): return ref
                case let .file(id) where fileIDs.contains(id): return ref
                default: return nil
                }
            }

            let rightSide = layout.rightSide.compactMap(validBrowserRef)
            let rightSideSet = Set(rightSide)
            let selectedRight = layout.selectedRight
                .flatMap(validBrowserRef)
                .flatMap { rightSideSet.contains($0) ? $0 : nil }
            let selectedLeft = layout.selectedLeft
                .flatMap(validBrowserRef)
                .flatMap { rightSideSet.contains($0) ? nil : $0 }

            return SavedFolderLayout(
                schemaVersion: layout.schemaVersion,
                fileTabs: files,
                browserTabs: layout.browserTabs,
                tabOrder: layout.tabOrder.compactMap(validBrowserRef),
                linkedTabOrder: layout.linkedTabOrder,
                ordersTabGroups: layout.ordersTabGroups,
                rightSide: rightSide,
                selectedLeft: selectedLeft,
                selectedRight: selectedRight,
                splitRatio: layout.splitRatio
            )
        }

        // MARK: - Restore

        /// Seed private content once, preserving Files already supplied by the Host.
        ///
        /// - Parameters:
        ///   - windowIdForIndex: maps a tmux window index back to the live
        ///     session's window id, or `nil` if the session has no window at that
        ///     index. Window refs that don't resolve are dropped.
        ///   - makeBrowserState: builds a live `BrowserTabState` (with its
        ///     `WKWebView`) for a restored browser tab. Injected so the mapper
        ///     stays UI-free and testable.
        @MainActor
        static func apply(
            _ layout: SavedFolderLayout,
            to tabs: SessionFileTabsState,
            fileBrowser: FileBrowserState?,
            includeHostFiles: Bool = false,
            includeGit: Bool = true,
            restoringFolder folder: String? = nil,
            windowIdForIndex: (Int) -> String?,
            makeBrowserState: (BrowserTab) -> BrowserTabState
        ) {
            let foreignTabs = folder.map { tabs.tabsOutsideFolder($0) } ?? []
            let preserveLiveResources = folder != nil
            let liveDirectories = tabs.directoryTabs.filter { preserveLiveResources || (!includeHostFiles && $0.value.hostTab != nil) }
            let liveFiles = tabs.openFileTabs.filter { preserveLiveResources || liveDirectories[$0.id] != nil }
            let liveFileIDs = Set(liveFiles.map(\.id)).union(liveDirectories.keys)
            let liveBrowsers = tabs.openBrowserTabs.filter { preserveLiveResources || $0.isTransient }
            let liveBrowserIDs = Set(liveBrowsers.map(\.id))
            let liveBrowserStates = tabs.browserStates.filter { liveBrowserIDs.contains($0.key) }
            func keepsLiveResource(_ payload: TabDragPayload) -> Bool {
                switch payload {
                case let .file(id): return liveFileIDs.contains(id)
                case let .browser(id): return liveBrowserIDs.contains(id)
                case .git: return preserveLiveResources
                default: return false
                }
            }
            let liveOrder = tabs.tabOrder.filter(keepsLiveResource)
            let liveRightSide = tabs.rightSide.filter(keepsLiveResource)
            let liveSelectedBrowser = tabs.selectedBrowserTabId.flatMap { liveBrowserIDs.contains($0) && !foreignTabs.contains(.browser($0)) ? $0 : nil }
            let keepGitSelected = preserveLiveResources && tabs.isGitSelected && !foreignTabs.contains(.git)
            let liveSplitRatio = tabs.splitRatio

            // Use the same path match as opening a file, keeping live editor state and saved references.
            var fileIDsByPath = Dictionary(
                liveFiles.filter { !$0.isDirectory && !$0.isDeleted }.map { ($0.path, $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
            var reusedFileIDs: [UUID: UUID] = [:]
            let privateFiles = layout.fileTabs.filter { saved in
                guard includeHostFiles || saved.browser?.hostOwned != true else { return false }
                if saved.browser == nil {
                    if let id = fileIDsByPath[saved.path] {
                        reusedFileIDs[saved.id] = id
                        // This folder already has a saved reference to the same editor.
                        if let folder {
                            tabs.tabFolders[.file(id)]?.insert(folder)
                        }
                        return false
                    }
                    guard !liveFileIDs.contains(saved.id) else { return false }
                    fileIDsByPath[saved.path] = saved.id
                }
                return !liveFileIDs.contains(saved.id)
            }
            let reusedLiveFiles = Set(reusedFileIDs.values.filter(liveFileIDs.contains).map(TabDragPayload.file))
            let foreignSelections = foreignTabs.subtracting(reusedLiveFiles)
            let liveSelectedRight = tabs.selectedRight.flatMap { keepsLiveResource($0) && !foreignSelections.contains($0) ? $0 : nil }
            let liveSelectedFile = tabs.selectedFileTabId.flatMap { liveFileIDs.contains($0) && !foreignSelections.contains(.file($0)) ? $0 : nil }
            tabs.openFileTabs = privateFiles.map {
                OpenFileTab(id: $0.id, path: $0.path, directoryPath: $0.directoryPath, isDirectory: $0.browser != nil)
            }
            if let folder {
                for file in privateFiles {
                    tabs.tabFolders[.file(file.id), default: []].insert(folder)
                }
            }
            tabs.directoryTabs = Dictionary(uniqueKeysWithValues: privateFiles.compactMap { saved in
                saved.browser.map { (saved.id, FileBrowserTab(snapshot: $0)) }
            })

            // Browser tabs — rebuild the value type and its live state.
            var restoredBrowserTabs: [BrowserTab] = []
            var restoredStates: [UUID: BrowserTabState] = [:]
            for saved in layout.browserTabs where !liveBrowserIDs.contains(saved.id) {
                let tab = BrowserTab(
                    id: saved.id,
                    url: saved.url,
                    displayTitle: saved.displayTitle,
                    parentTabId: saved.parentId
                )
                restoredBrowserTabs.append(tab)
                restoredStates[tab.id] = makeBrowserState(tab)
            }
            tabs.openBrowserTabs = restoredBrowserTabs
            tabs.browserStates = restoredStates
            if let folder {
                for browser in layout.browserTabs {
                    tabs.tabFolders[.browser(browser.id), default: []].insert(folder)
                }
            }

            let restoredFileIds = Set(tabs.openFileTabs.map(\.id))
            let restoredBrowserIds = Set(restoredBrowserTabs.map(\.id))

            func payload(for ref: SavedTabRef) -> TabDragPayload? {
                guard includeGit || ref != .git else { return nil }
                if case let .file(id) = ref, let reused = reusedFileIDs[id] {
                    return .file(reused)
                }
                return runtimePayload(
                    for: ref,
                    windowIdForIndex: windowIdForIndex,
                    restoredFileIds: restoredFileIds,
                    restoredBrowserIds: restoredBrowserIds
                )
            }

            tabs.tabOrder = PaneLinkedTabs.ordered(layout.tabOrder.compactMap(payload), stored: [])
            tabs.rightSide = Set(layout.rightSide.compactMap(payload)).subtracting(reusedLiveFiles)
            tabs.rightSide.formUnion(liveRightSide)
            tabs.locallySplitTerminalID = layout.localRightTerminalIndex.flatMap(windowIdForIndex).flatMap {
                tabs.rightSide.contains(.window($0)) ? $0 : nil
            }
            tabs.selectedRight = layout.selectedRight.flatMap(payload).flatMap { tabs.rightSide.contains($0) ? $0 : nil }

            tabs.isGitSelected = false
            let restoredLeft = layout.selectedLeft.flatMap(payload).flatMap { tabs.rightSide.contains($0) ? nil : $0 }
            switch restoredLeft {
            case .git:
                tabs.selectLeftGit()
            case let .file(id):
                tabs.selectedFileTabId = id
                tabs.selectedBrowserTabId = nil
            case let .browser(id):
                tabs.selectedBrowserTabId = id
                tabs.selectedFileTabId = nil
            default:
                tabs.selectedFileTabId = nil
                tabs.selectedBrowserTabId = nil
            }

            tabs.splitRatio = min(max(layout.splitRatio, SplitLayout.minRatio), SplitLayout.maxRatio)

            tabs.openFileTabs += liveFiles
            tabs.directoryTabs.merge(liveDirectories) { _, live in live }
            tabs.openBrowserTabs += liveBrowsers
            tabs.browserStates.merge(liveBrowserStates) { _, live in live }
            let restoredOrder = Set(tabs.tabOrder)
            tabs.tabOrder += liveOrder.filter { !restoredOrder.contains($0) }
            if let liveSelectedFile, !tabs.rightSide.contains(.file(liveSelectedFile)) {
                tabs.selectedFileTabId = liveSelectedFile
                tabs.selectedBrowserTabId = nil
            } else if let liveSelectedBrowser, !tabs.rightSide.contains(.browser(liveSelectedBrowser)) {
                tabs.selectedFileTabId = nil
                tabs.selectedBrowserTabId = liveSelectedBrowser
            } else if keepGitSelected {
                tabs.selectLeftGit()
            }
            if let liveSelectedRight {
                tabs.selectedRight = liveSelectedRight
            }
            if !liveRightSide.subtracting(foreignSelections).isEmpty {
                tabs.splitRatio = liveSplitRatio
            }

            tabs.ordersTabGroups = layout.ordersTabGroups == true
            tabs.restoreLinkedTabOrder(layout.linkedTabOrder?.map { id in
                if case let .file(fileID) = id, let reused = reusedFileIDs[fileID] {
                    return .file(reused)
                }
                return id
            })
            if let fileTree = layout.fileTree, let fileBrowser {
                fileBrowser.sidebarWidth = fileTree.sidebarWidth
            }
        }

        // MARK: - Ref translation

        private static func savedRef(
            for payload: TabDragPayload,
            windowIndexForId: (String) -> Int?
        ) -> SavedTabRef? {
            switch payload {
            case let .window(id):
                windowIndexForId(id).map { .window(index: $0) }
            case .fileExplorer:
                .fileExplorer
            case .git:
                .git
            case let .file(id):
                .file(id: id)
            case let .browser(id):
                .browser(id: id)
            }
        }

        static func runtimePayload(
            for ref: SavedTabRef,
            windowIdForIndex: (Int) -> String?,
            restoredFileIds: Set<UUID>,
            restoredBrowserIds: Set<UUID>
        ) -> TabDragPayload? {
            switch ref {
            case let .window(index):
                windowIdForIndex(index).map { .window($0) }
            case .fileExplorer:
                .fileExplorer
            case .git:
                .git
            case let .file(id):
                restoredFileIds.contains(id) ? .file(id) : nil
            case let .browser(id):
                restoredBrowserIds.contains(id) ? .browser(id) : nil
            }
        }
    }
#endif
