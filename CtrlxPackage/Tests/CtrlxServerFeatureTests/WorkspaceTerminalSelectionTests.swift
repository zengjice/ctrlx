import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@Suite @MainActor
struct WorkspaceTerminalSelectionTests {
    @Test("Selecting a terminal preserves Host right-pane order after tmux indices change", arguments: [false, true])
    func selectionDoesNotReorderHostTerminals(onRight: Bool) {
        let request = SetSharedTerminalLayout(
            sessionName: "work", leftWindowId: "@1", rightWindowIds: ["@2", "@3", "@4"], selectedRightWindowId: "@4"
        )
        let selected = WorkspaceTerminalSelection.splitRequest(
            request, windowID: onRight ? "@4" : "@1", onRight: onRight, select: true,
            windowIDs: ["@1", "@3", "@2", "@4"], activeWindowID: "@1"
        )
        #expect(selected.rightWindowIds == request.rightWindowIds)
        #expect(selected.selectedRightWindowId == "@4")
    }

    @Test("Returning a detached terminal to the same shared side only selects it", arguments: [false, true])
    func sameSideReturnDoesNotCreatePlacementEdit(pendingMove: Bool) throws {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@3", "@2", "@4"]
        let shared = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: pendingMove ? ["@2", "@3"] : ["@2", "@3", "@4"],
            selectedRightWindowId: "@3", revision: 1, sessionWindowIds: ids
        )
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(ids))
        if pendingMove {
            tabs.placeRemoteTerminal("@4", onRight: true, sessionWindowIDs: ids)
        }
        tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: ["@1", "@2", "@3"], sessionWindowIDs: Set(ids))
        tabs.placeRemoteTerminal("@4", onRight: true, sessionWindowIDs: ids)
        let request = try #require(tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: "@1", shared: shared
        ))
        #expect(request.rightWindowIds == (pendingMove ? ["@3", "@2", "@4"] : shared.rightWindowIds))
        #expect(request.selectedRightWindowId == "@4")
        #expect(tabs.remoteTerminalPlacements["@4"] == (pendingMove ? true : nil))
        #expect((tabs.pendingRemoteTerminalOrder != nil) == pendingMove)
    }

    @Test("An order edit must not replay a cancelled placement over a later Host move")
    func pendingOrderPreservesLaterHostPlacement() throws {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@3", "@2", "@4"]
        let original = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3", "@4"], selectedRightWindowId: "@4", revision: 1, sessionWindowIds: ids
        )
        tabs.applySharedTerminalLayout(original, liveWindowIds: Set(ids))
        tabs.placeRemoteTerminal("@2", onRight: false, sessionWindowIDs: ids)
        tabs.placeRemoteTerminal("@2", onRight: true, sessionWindowIDs: ids)
        tabs.selectRemoteRightTerminal("@4")
        let hostMove = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@3", "@4"], selectedRightWindowId: "@4", revision: 2, sessionWindowIds: ids
        )
        tabs.applySharedTerminalLayout(hostMove, liveWindowIds: Set(ids))
        let request = try #require(tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: "@1", shared: hostMove
        ))
        #expect(request.rightWindowIds == ["@3", "@4"])
        tabs.clearMatchingRemoteTerminalEdits(hostMove)
        #expect(tabs.pendingRemoteTerminalOrder == nil)
    }

    @Test("Closing an unselected left file preserves a hidden terminal's shared selection")
    func unselectedFileClosePreservesHiddenSelection() throws {
        let tabs = SessionFileTabsState()
        let shared = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@3", revision: 1, sessionWindowIds: ["@1", "@2", "@3"]
        )
        let file = FileBrowserTab(path: "/tmp/unselected.md")
        tabs.openFileTabs = [.init(id: file.id, path: "/tmp/unselected.md", directoryPath: "/tmp", isDirectory: false)]
        tabs.directoryTabs[file.id] = file
        tabs.applySharedTerminalLayout(shared, liveWindowIds: ["@1", "@2"])
        #expect(tabs.selectedRight == .window("@2"))
        let closed = try #require(tabs.removeFileTab(file.id))
        #expect(!closed.wasSelectedRight)
        tabs.reconcileRemoteRightPaneSelection(sessionWindowIDs: ["@1", "@2"], recordSelection: closed.wasSelectedRight)
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ["@1", "@2", "@3"], visibleWindowIDs: ["@1", "@2"], selectedLeftWindowID: "@1", shared: shared
        )
        #expect(request?.selectedRightWindowId == "@3")
        #expect(tabs.explicitRemoteRightTerminalID == nil)
    }

    @Test("A cancelled membership move still submits its order and survives a width reply", arguments: [false, true], [false, true])
    func cancelledMovePreservesOrderIntent(legacy: Bool, receivesWidthReply: Bool) throws {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@3", "@2", "@4"]
        let original = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3", "@4"], selectedRightWindowId: "@4", revision: 1,
            sessionWindowIds: legacy ? nil : ids
        )
        tabs.applySharedTerminalLayout(original, liveWindowIds: Set(ids))
        if receivesWidthReply {
            tabs.splitRatio = 0.58
            tabs.recordRemoteSplitRatio(0.58)
            tabs.remoteTerminalLayoutInFlight = .init(
                baseline: original,
                request: .init(sessionName: "work", leftWindowId: "@1", rightWindowIds: original.rightWindowIds, selectedRightWindowId: "@4", splitRatio: 0.58)
            )
        }
        tabs.placeRemoteTerminal("@2", onRight: false, sessionWindowIDs: ids)
        tabs.placeRemoteTerminal("@2", onRight: true, sessionWindowIDs: ids)
        tabs.selectRemoteRightTerminal("@4")
        let shared = receivesWidthReply ? SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: original.rightWindowIds, selectedRightWindowId: "@4", splitRatio: 0.58, revision: 2,
            sessionWindowIds: legacy ? nil : ids
        ) : original
        if receivesWidthReply {
            tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(ids))
            tabs.remoteTerminalLayoutInFlight = nil
        }
        let request = try #require(tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: "@1", shared: shared
        ))
        #expect(request.rightWindowIds == ["@3", "@2", "@4"])
        let confirmed = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: request.rightWindowIds, selectedRightWindowId: "@4", revision: shared.revision + 1,
            sessionWindowIds: legacy ? nil : ids
        )
        tabs.applySharedTerminalLayout(confirmed, liveWindowIds: Set(ids))
        tabs.clearMatchingRemoteTerminalEdits(confirmed)
        #expect(tabs.remoteTerminalPlacements.isEmpty)
        #expect(tabs.pendingRemoteTerminalOrder == nil)
    }

    @Test("A changed tmux index order alone must not reorder the shared right pane")
    func passiveViewerPreservesHostRightOrder() throws {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@3", "@2", "@4"]
        let shared = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3", "@4"], selectedRightWindowId: "@4", revision: 1, sessionWindowIds: ids
        )
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(ids))
        let request = try #require(tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: "@1", shared: shared
        ))
        #expect(request.rightWindowIds == shared.rightWindowIds)
        #expect(request.selectedRightWindowId == "@4")
        tabs.splitRatio = 0.64
        tabs.recordRemoteSplitRatio(0.64)
        let resized = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: "@1", shared: shared
        )
        #expect(resized?.rightWindowIds == shared.rightWindowIds)
    }

    @Test("Promoting a local-only terminal updates its shared selection", arguments: [false, true])
    func promotedLocalTerminalSupersedesPendingSelection(confirmed: Bool) throws {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@2", "@3"]
        let browser = BrowserTab(url: URL(fileURLWithPath: "/tmp/private"))
        tabs.openBrowserTabs = [browser]
        tabs.selectedBrowserTabId = browser.id
        let original = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@2"], selectedRightWindowId: "@2", revision: 1, sessionWindowIds: ids)
        tabs.applySharedTerminalLayout(original, liveWindowIds: Set(ids))
        tabs.placeRemoteTerminal("@3", onRight: true, sessionWindowIDs: ids)
        let first = try #require(tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: "@1", shared: original
        ))
        let reply = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: first.rightWindowIds, selectedRightWindowId: "@3", revision: 2, sessionWindowIds: ids)
        if confirmed {
            tabs.applySharedTerminalLayout(reply, liveWindowIds: Set(ids))
        } else {
            tabs.remoteTerminalLayoutInFlight = .init(baseline: original, request: first)
        }
        tabs.placeRemoteTerminal("@1", onRight: true, sessionWindowIDs: ids)
        tabs.placeRemoteTerminal("@2", onRight: false, sessionWindowIDs: ids)
        #expect(tabs.selectedRight == .window("@1"))
        if !confirmed {
            tabs.applySharedTerminalLayout(reply, liveWindowIds: Set(ids))
            tabs.remoteTerminalLayoutInFlight = nil
        }
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: "@2", shared: reply
        )
        #expect(tabs.selectedRight == .window("@1"))
        #expect(request?.selectedRightWindowId == "@1")
    }

    @Test("A user resource edit replaces an older pending terminal selection", arguments: [false, true], [false, true])
    func resourceEditRecordsFallbackSelection(confirmed: Bool, closesPage: Bool) throws {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@2", "@3"]
        let browser = BrowserTab(url: URL(fileURLWithPath: "/tmp/private"))
        tabs.openBrowserTabs = [browser]
        tabs.selectedBrowserTabId = browser.id
        let original = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2", revision: 1)
        tabs.applySharedTerminalLayout(original, liveWindowIds: Set(ids))
        tabs.selectRemoteRightTerminal("@3")
        let first = try #require(tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: "@1", shared: original
        ))
        let reply = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: first.rightWindowIds, selectedRightWindowId: "@3", revision: 2)
        if confirmed {
            tabs.applySharedTerminalLayout(reply, liveWindowIds: Set(ids))
        } else {
            tabs.remoteTerminalLayoutInFlight = .init(baseline: original, request: first)
        }
        tabs.rightSide.insert(.browser(browser.id))
        tabs.selectedRight = .browser(browser.id)
        if closesPage {
            tabs.openBrowserTabs.removeAll()
        }
        tabs.rightSide.remove(.browser(browser.id))
        tabs.selectedRight = nil
        tabs.reconcileRemoteRightPaneSelection(sessionWindowIDs: ids, recordSelection: true)
        #expect(tabs.selectedRight == .window("@2"))
        if !confirmed {
            tabs.applySharedTerminalLayout(reply, liveWindowIds: Set(ids))
            tabs.remoteTerminalLayoutInFlight = nil
        }
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: "@1", shared: reply
        )
        #expect(tabs.selectedRight == .window("@2"))
        #expect(request?.selectedRightWindowId == "@2")
    }

    @Test("Host membership takes priority over a deduplicated Viewer window catalog")
    func advertisedMembersPreservePrivatePosition() {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@2", "@3"]
        let browser = BrowserTab(url: URL(fileURLWithPath: "/tmp/private"))
        tabs.openBrowserTabs = [browser]
        tabs.selectedBrowserTabId = browser.id
        let shared = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2", revision: 1, sessionWindowIds: ids
        )
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(ids))
        tabs.placeRemoteTerminal("@1", onRight: true, sessionWindowIDs: ids)
        tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: ["@2", "@3"], sessionWindowIDs: ["@2", "@3"])
        #expect(tabs.locallySplitTerminalID == "@1")
        tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: Set(ids), sessionWindowIDs: Set(ids))
        #expect(tabs.rightSideWindowIds == Set(ids))
    }

    @Test("Batched and separately confirmed right moves have the same fallback order", arguments: [false, true])
    func rightMoveOrderDoesNotDependOnBatching(confirmed: Bool) throws {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@2", "@3", "@4"]
        var shared = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@4"], selectedRightWindowId: "@4", revision: 1, sessionWindowIds: ids
        )
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(ids))
        for id in ["@3", "@2"] {
            tabs.placeRemoteTerminal(id, onRight: true, sessionWindowIDs: ids)
            if confirmed {
                let request = try #require(tabs.remoteTerminalLayoutRequest(
                    sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: "@1", shared: shared
                ))
                shared = .init(
                    leftWindowId: request.leftWindowId, rightWindowIds: request.rightWindowIds,
                    selectedRightWindowId: request.selectedRightWindowId, revision: shared.revision + 1, sessionWindowIds: ids
                )
                tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(ids))
            }
        }
        tabs.selectRemoteRightTerminal("@4")
        let request = try #require(tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: "@1", shared: shared
        ))
        #expect(request.rightWindowIds == ["@2", "@3", "@4"])
    }

    @Test("Moving the selected terminal left replaces an older pending right selection", arguments: [false, true])
    func moveLeftUpdatesRightSelection(confirmed: Bool) throws {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@2", "@3"]
        let browser = BrowserTab(url: URL(fileURLWithPath: "/tmp/private"))
        tabs.openBrowserTabs = [browser]
        tabs.selectedBrowserTabId = browser.id
        let original = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@2"], selectedRightWindowId: "@2", revision: 1)
        tabs.applySharedTerminalLayout(original, liveWindowIds: Set(ids))
        tabs.placeRemoteTerminal("@3", onRight: true, sessionWindowIDs: ids)
        let first = try #require(tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: "@1", shared: original
        ))
        let reply = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: first.rightWindowIds, selectedRightWindowId: "@3", revision: 2)
        if confirmed {
            tabs.applySharedTerminalLayout(reply, liveWindowIds: Set(ids))
        } else {
            tabs.remoteTerminalLayoutInFlight = .init(baseline: original, request: first)
        }
        tabs.placeRemoteTerminal("@1", onRight: true, sessionWindowIDs: ids)
        tabs.placeRemoteTerminal("@1", onRight: false, sessionWindowIDs: ids)
        if !confirmed {
            tabs.applySharedTerminalLayout(reply, liveWindowIds: Set(ids))
            tabs.remoteTerminalLayoutInFlight = nil
        }
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: "@1", shared: reply
        )
        #expect(tabs.selectedRight == .window("@2"))
        #expect(request?.selectedRightWindowId == "@2")
    }

    @Test("Replacing an invisible left terminal prefers the explicit replacement")
    func replacementLeftSelectionSurvivesDetachment() {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@2", "@3"]
        let browser = BrowserTab(url: URL(fileURLWithPath: "/tmp/private"))
        tabs.openBrowserTabs = [browser]
        tabs.selectedBrowserTabId = browser.id
        let shared = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@3"], selectedRightWindowId: "@3", revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: ["@1", "@3"], sessionWindowIds: Set(ids))
        tabs.placeRemoteTerminal("@1", onRight: true, sessionWindowIDs: ids)
        tabs.placeRemoteTerminal("@3", onRight: false, sessionWindowIDs: ids)
        tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: ["@3"], sessionWindowIDs: Set(ids))
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ["@3"], selectedLeftWindowID: "@3", shared: shared
        )
        #expect(request?.leftWindowId == "@3")
        #expect(request?.rightWindowIds == ["@1"])
    }

    @Test("Queued width and selection survive detaching every terminal")
    func queuedEditsWithoutVisibleTerminals() {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@2", "@3"]
        let shared = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2", splitRatio: 0.58, revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(ids))
        tabs.splitRatio = 0.69
        tabs.recordRemoteSplitRatio(0.69)
        tabs.selectRemoteRightTerminal("@3")
        tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: [], sessionWindowIDs: Set(ids))
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: [], selectedLeftWindowID: nil, shared: shared
        )
        #expect(request?.splitRatio == 0.69)
        #expect(request?.selectedRightWindowId == "@3")
    }

    @Test("Old Hosts use the known session catalog to retain invisible moves")
    func pendingMoveWithLegacyHostMembers() {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@2", "@3"]
        let shared = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@3"], selectedRightWindowId: "@3", revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(ids))
        tabs.placeRemoteTerminal("@2", onRight: true, sessionWindowIDs: ids)
        tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: ["@1", "@3"], sessionWindowIDs: Set(ids))
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ["@1", "@3"], selectedLeftWindowID: "@1", shared: shared
        )
        #expect(request?.rightWindowIds == ["@2", "@3"])
        #expect(request?.selectedRightWindowId == "@2")
    }

    @Test("A private terminal position survives temporary invisibility and clears after removal")
    func privateTerminalPositionFollowsSessionMembership() {
        let tabs = SessionFileTabsState()
        let browser = BrowserTab(url: URL(fileURLWithPath: "/tmp/private"))
        tabs.openBrowserTabs = [browser]
        tabs.selectedBrowserTabId = browser.id
        let ids = Set(["@1", "@2", "@3"])
        let shared = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2", revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: ids, sessionWindowIds: ids)
        tabs.placeRemoteTerminal("@1", onRight: true, sessionWindowIDs: ids.sorted())
        tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: ["@2", "@3"], sessionWindowIDs: ids)
        #expect(tabs.locallySplitTerminalID == "@1")
        #expect(tabs.rightSideWindowIds == ["@2", "@3"])

        tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: ids, sessionWindowIDs: ids)
        #expect(tabs.rightSideWindowIds == ids)
        tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: ["@2", "@3"], sessionWindowIDs: ids)
        tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: ["@2", "@3"], sessionWindowIDs: ["@2", "@3"])
        #expect(tabs.locallySplitTerminalID == nil)
    }

    @Test("A pending right move stays in the shared request after the window becomes invisible")
    func pendingRightMoveUsesAdvertisedMembers() {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@2", "@3"]
        let shared = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@3"], selectedRightWindowId: "@3", revision: 1, sessionWindowIds: ids
        )
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(ids))
        tabs.placeRemoteTerminal("@2", onRight: true, sessionWindowIDs: ids)
        tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: ["@1", "@3"])
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ["@1", "@3"], visibleWindowIDs: ["@1", "@3"], selectedLeftWindowID: "@1", shared: shared
        )
        #expect(request?.rightWindowIds == ["@2", "@3"])
        #expect(request?.selectedRightWindowId == "@2")
    }

    @Test("A moved left terminal becoming invisible cannot occupy both sides of a shared request")
    func movedLeftTerminalUsesCompleteMembers() {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@2", "@3"]
        let shared = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@3"], selectedRightWindowId: "@3", revision: 1, sessionWindowIds: ids
        )
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(ids))
        tabs.placeRemoteTerminal("@1", onRight: true, sessionWindowIDs: ids)
        tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: ["@2", "@3"])
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ["@2", "@3"], visibleWindowIDs: ["@2", "@3"],
            selectedLeftWindowID: "@2", shared: shared
        )
        #expect(request?.leftWindowId == "@2")
        #expect(Set(request?.rightWindowIds ?? []) == ["@1", "@3"])
    }

    @Test("An explicit left selection remains shared when its terminal is detached")
    func explicitLeftSelectionUsesCompleteMembers() {
        let tabs = SessionFileTabsState()
        let shared = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@3",
            revision: 1, sessionWindowIds: ["@1", "@2", "@3"]
        )
        tabs.applySharedTerminalLayout(shared, liveWindowIds: ["@1", "@2", "@3"])
        tabs.placeRemoteTerminal("@2", onRight: false, sessionWindowIDs: ["@1", "@2", "@3"])
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ["@1", "@3"], visibleWindowIDs: ["@1", "@3"], selectedLeftWindowID: "@1", shared: shared
        )
        #expect(request?.leftWindowId == "@2")
        #expect(request?.rightWindowIds == ["@3"])
    }

    @Test("A queued divider edit survives hiding the last visible right terminal")
    func pendingWidthSurvivesHiddenRightPane() {
        let tabs = SessionFileTabsState()
        let shared = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@2"], selectedRightWindowId: "@2", revision: 1, sessionWindowIds: ["@1", "@2"])
        tabs.applySharedTerminalLayout(shared, liveWindowIds: ["@1", "@2"])
        tabs.splitRatio = 0.58
        tabs.recordRemoteSplitRatio(0.58)
        tabs.remoteTerminalLayoutInFlight = .init(
            baseline: shared,
            request: .init(sessionName: "work", leftWindowId: "@1", rightWindowIds: ["@2"], selectedRightWindowId: "@2", splitRatio: 0.58)
        )
        tabs.splitRatio = 0.69
        tabs.recordRemoteSplitRatio(0.69)
        tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: ["@1"])
        let confirmed = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@2"], selectedRightWindowId: "@2", splitRatio: 0.58, revision: 2, sessionWindowIds: ["@1", "@2"]
        )
        tabs.applySharedTerminalLayout(confirmed, liveWindowIds: ["@1"])
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ["@1"], visibleWindowIDs: ["@1"], selectedLeftWindowID: "@1", shared: confirmed
        )
        #expect(tabs.pendingRemoteSplitRatio == 0.69)
        #expect(request?.splitRatio == 0.69)
        #expect(request?.rightWindowIds == ["@2"])
    }

    @Test("Placing and clicking a local-only terminal preserves the last shared selection", arguments: [false, true])
    func localSplitPreservesSharedSelection(confirmed: Bool) {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@2", "@3"]
        let browser = BrowserTab(url: URL(fileURLWithPath: "/tmp/private"))
        tabs.openBrowserTabs = [browser]
        tabs.selectedBrowserTabId = browser.id
        let original = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2", revision: 1, sessionWindowIds: ids
        )
        tabs.applySharedTerminalLayout(original, liveWindowIds: Set(ids))
        tabs.selectRemoteRightTerminal("@3")
        let shared = confirmed ? SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@3", revision: 2, sessionWindowIds: ids
        ) : original
        if confirmed {
            tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(ids))
        }
        tabs.placeRemoteTerminal("@1", onRight: true, sessionWindowIDs: ids)
        tabs.selectRemoteRightTerminal("@1")
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: nil, shared: shared
        )
        #expect(tabs.locallySplitTerminalID == "@1")
        #expect(tabs.selectedRight == .window("@1"))
        #expect(request?.selectedRightWindowId == "@3")
    }

    @Test("Auto-collapsing the Viewer preserves a detached left terminal's shared split")
    func remoteMoveRightSurvivesLocalCollapse() {
        let tabs = SessionFileTabsState()
        let visible = ["@2", "@3"]
        let shared = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@3"], selectedRightWindowId: "@3", revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(visible))
        tabs.rightSide.insert(.window("@2"))
        tabs.recordRemoteTerminalPlacement("@2", onRight: true)
        #expect(tabs.reconcileRemoteRightPaneSelection(sessionWindowIDs: visible))
        #expect(tabs.rightSideWindowIds.isEmpty)

        let request = tabs.remoteTerminalLayoutRequest(sessionName: "work", sessionWindowIDs: ["@1", "@2", "@3"], visibleWindowIDs: visible, selectedLeftWindowID: "@2", shared: shared)
        #expect(request?.leftWindowId == "@1")
        #expect(request?.rightWindowIds == ["@2", "@3"])
        #expect(request?.selectedRightWindowId == "@2")
    }

    @Test("A detached terminal can anchor the shared left pane")
    func detachedTerminalCanBecomeSharedLeft() {
        let tabs = SessionFileTabsState()
        let visible = ["@1", "@3"]
        let shared = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@3"], selectedRightWindowId: "@3", revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(visible))
        tabs.rightSide.insert(.window("@1"))
        tabs.recordRemoteTerminalPlacement("@1", onRight: true)
        #expect(tabs.reconcileRemoteRightPaneSelection(sessionWindowIDs: visible))

        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ["@1", "@2", "@3"], visibleWindowIDs: visible, selectedLeftWindowID: "@1", shared: shared
        )
        #expect(request?.leftWindowId == "@2")
        #expect(request?.rightWindowIds == ["@1", "@3"])
        #expect(request?.selectedRightWindowId == "@1")
    }

    @Test("A linked terminal absent from the Viewer can become the shared left anchor")
    func linkedTerminalCanBecomeSharedLeft() {
        let tabs = SessionFileTabsState()
        let visible = ["@1", "@3"]
        let shared = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@3"], selectedRightWindowId: "@3",
            revision: 1, sessionWindowIds: ["@1", "@2", "@3"]
        )
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(visible))
        tabs.recordRemoteTerminalPlacement("@1", onRight: true)
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: visible, visibleWindowIDs: visible, selectedLeftWindowID: "@1", shared: shared
        )
        #expect(request?.leftWindowId == "@2")
        #expect(request?.rightWindowIds == ["@1", "@3"])
        #expect(request?.selectedRightWindowId == "@1")
    }

    @Test("Terminals already on the right cannot replace the last left terminal")
    func remoteSplitAlternativeExcludesRightTerminals() {
        let tabs = SessionFileTabsState()
        let shared = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2",
            revision: 1, sessionWindowIds: ["@1", "@2", "@3"]
        )
        tabs.applySharedTerminalLayout(shared, liveWindowIds: ["@1", "@2", "@3"])
        #expect(!tabs.hasRemoteSplitAlternative(to: "@1", sessionWindowIDs: ["@1", "@2", "@3"]))
        tabs.collapseRemoteTerminalSplit(leftWindowID: "@1")
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ["@1", "@2", "@3"], visibleWindowIDs: ["@1", "@2", "@3"],
            selectedLeftWindowID: "@1", shared: shared
        )
        #expect(request?.rightWindowIds.isEmpty == true)
        #expect(tabs.remoteTerminalPlacements["@1"] == nil)
    }

    @Test("Collapsing includes a terminal moved right before the previous reply", arguments: [false, true])
    func remoteCollapseIncludesPendingMove(firstMoveConfirmed: Bool) {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@2", "@3"]
        let original = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@3"], selectedRightWindowId: "@3",
            revision: 1, sessionWindowIds: ids
        )
        tabs.applySharedTerminalLayout(original, liveWindowIds: Set(ids))
        tabs.placeRemoteTerminal("@2", onRight: true, sessionWindowIDs: ids)
        let first = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: "@1", shared: original
        )
        let confirmed = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@3", "@2"], selectedRightWindowId: "@2",
            revision: 2, sessionWindowIds: ids
        )
        if firstMoveConfirmed {
            tabs.applySharedTerminalLayout(confirmed, liveWindowIds: Set(ids))
        } else if let first {
            tabs.remoteTerminalLayoutInFlight = .init(baseline: original, request: first)
        }
        tabs.placeRemoteTerminal("@1", onRight: true, sessionWindowIDs: ids)
        if !firstMoveConfirmed {
            tabs.applySharedTerminalLayout(confirmed, liveWindowIds: Set(ids))
            tabs.remoteTerminalLayoutInFlight = nil
        }
        let collapsed = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: "@1", shared: confirmed
        )
        #expect(collapsed?.rightWindowIds.isEmpty == true)
        #expect(tabs.remoteTerminalPlacements["@1"] == nil)
    }

    @Test("Returning a terminal beside a private page uses local placement until another terminal moves left")
    func returnedTerminalPromotesLocalSplitAfterLeftMove() {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@2", "@3"]
        let shared = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2",
            revision: 1, sessionWindowIds: ids
        )
        let browser = BrowserTab(url: URL(fileURLWithPath: "/tmp/private"))
        tabs.openBrowserTabs = [browser]
        tabs.selectedBrowserTabId = browser.id
        tabs.applySharedTerminalLayout(shared, liveWindowIds: ["@2", "@3"])
        tabs.placeRemoteTerminal("@1", onRight: true, sessionWindowIDs: ids)
        #expect(tabs.locallySplitTerminalID == "@1")
        #expect(tabs.remoteTerminalPlacements["@1"] == nil)
        #expect(tabs.explicitRemoteRightTerminalID == nil)
        tabs.selectRemoteRightTerminal("@3")
        tabs.splitRatio = 0.66
        let selected = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: nil, shared: shared
        )
        #expect(selected?.rightWindowIds == ["@2", "@3"])
        #expect(selected?.selectedRightWindowId == "@3")
        #expect(selected?.splitRatio == 0.66)

        tabs.placeRemoteTerminal("@2", onRight: false, sessionWindowIDs: ids)
        let moved = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: "@2", shared: shared
        )
        #expect(tabs.locallySplitTerminalID == nil)
        #expect(moved?.leftWindowId == "@2")
        #expect(Set(moved?.rightWindowIds ?? []) == ["@1", "@3"])
    }

    @Test("An explicit collapse removes a detached right terminal")
    func collapseIncludesHiddenTerminal() {
        let tabs = SessionFileTabsState()
        let visible = ["@1", "@2"]
        let shared = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2",
            revision: 1, sessionWindowIds: ["@1", "@2", "@3"]
        )
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(visible))
        tabs.collapseRemoteTerminalSplit(leftWindowID: "@1")
        let collapsed = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ["@1", "@2", "@3"], visibleWindowIDs: visible,
            selectedLeftWindowID: "@1", shared: shared
        )
        #expect(collapsed?.rightWindowIds.isEmpty == true)
        #expect(collapsed?.removedRightWindowIds == ["@2", "@3"])
    }

    @Test("Quickly moving back to an all-right private workspace retains a shared anchor")
    func privateSplitRapidSideChangesRetainAnchor() {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@2", "@3"]
        let shared = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2",
            revision: 1, sessionWindowIds: ids
        )
        let browser = BrowserTab(url: URL(fileURLWithPath: "/tmp/private"))
        tabs.openBrowserTabs = [browser]
        tabs.selectedBrowserTabId = browser.id
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(ids))
        tabs.placeRemoteTerminal("@1", onRight: true, sessionWindowIDs: ids)
        tabs.placeRemoteTerminal("@2", onRight: false, sessionWindowIDs: ids)
        tabs.placeRemoteTerminal("@2", onRight: true, sessionWindowIDs: ids)
        tabs.selectRemoteRightTerminal("@3")
        tabs.splitRatio = 0.64
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: nil, shared: shared
        )
        #expect(tabs.locallySplitTerminalID == "@1")
        #expect(request?.leftWindowId == "@1")
        #expect(request?.rightWindowIds == ["@2", "@3"])
        #expect(request?.selectedRightWindowId == "@3")
        #expect(request?.splitRatio == 0.64)
    }

    @Test("A delayed left-move reply preserves the newer private split and selection")
    func privateSplitRebasesOnDelayedLeftMove() {
        let tabs = SessionFileTabsState()
        let ids = ["@1", "@2", "@3"]
        let shared = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2",
            revision: 1, sessionWindowIds: ids
        )
        let browser = BrowserTab(url: URL(fileURLWithPath: "/tmp/private"))
        tabs.openBrowserTabs = [browser]
        tabs.selectedBrowserTabId = browser.id
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(ids))
        tabs.placeRemoteTerminal("@1", onRight: true, sessionWindowIDs: ids)
        tabs.placeRemoteTerminal("@2", onRight: false, sessionWindowIDs: ids)
        let first = SetSharedTerminalLayout(
            sessionName: "work", leftWindowId: "@2", rightWindowIds: ["@1", "@3"], selectedRightWindowId: "@1"
        )
        tabs.remoteTerminalLayoutInFlight = .init(baseline: shared, request: first)
        tabs.placeRemoteTerminal("@2", onRight: true, sessionWindowIDs: ids)
        tabs.selectRemoteRightTerminal("@3")
        let confirmed = SharedTerminalLayout(
            leftWindowId: "@2", rightWindowIds: ["@1", "@3"], selectedRightWindowId: "@1",
            revision: 2, sessionWindowIds: ids
        )
        tabs.applySharedTerminalLayout(confirmed, liveWindowIds: Set(ids))
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: nil, shared: confirmed
        )
        #expect(tabs.locallySplitTerminalID == "@2")
        #expect(request?.leftWindowId == "@2")
        #expect(Set(request?.rightWindowIds ?? []) == ["@1", "@3"])
        #expect(request?.selectedRightWindowId == "@3")
    }

    @Test("A width-only request does not retain a cancelled terminal selection")
    func remoteWidthSubmissionOnlyProtectsWidth() {
        let tabs = SessionFileTabsState()
        let ids = Set(["@1", "@2", "@3"])
        let shared = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2", revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: ids)
        tabs.remoteTerminalLayoutInFlight = .init(
            baseline: shared,
            request: .init(sessionName: "work", leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2", splitRatio: 0.66)
        )
        tabs.selectRemoteRightTerminal("@3")
        tabs.selectRemoteRightTerminal("@2")
        tabs.applySharedTerminalLayout(.init(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@3", splitRatio: 0.66, revision: 2
        ), liveWindowIds: ids)
        #expect(tabs.explicitRemoteRightTerminalID == nil)
        #expect(tabs.selectedRight == .window("@3"))
    }

    @Test("A local resource on the left keeps the shared anchor for right-side selection")
    func workspaceWithNoVisibleLeftTerminalCanSelectRight() {
        let tabs = SessionFileTabsState()
        let visible = ["@1", "@2", "@3"]
        let browser = BrowserTab(url: URL(fileURLWithPath: "/tmp/page"))
        tabs.openBrowserTabs = [browser]
        tabs.selectedBrowserTabId = browser.id
        tabs.locallySplitTerminalID = "@1"
        let shared = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2", revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(visible))
        tabs.selectRemoteRightTerminal("@3")

        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: visible, visibleWindowIDs: visible, selectedLeftWindowID: nil, shared: shared
        )
        #expect(request?.leftWindowId == "@1")
        #expect(request?.rightWindowIds == ["@2", "@3"])
        #expect(request?.selectedRightWindowId == "@3")
    }

    @Test("An equal layout consumes a cancelled edit only after any older request finishes", arguments: [false, true])
    func matchingLayoutDiscardsCancelledEdit(hasOlderRequest: Bool) {
        let tabs = SessionFileTabsState()
        let ids = Set(["@1", "@2", "@3"])
        let shared = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2", revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: ids)
        tabs.selectRemoteRightTerminal("@3")
        tabs.recordRemoteTerminalPlacement("@3", onRight: false)
        tabs.recordRemoteTerminalPlacement("@3", onRight: true)
        tabs.selectRemoteRightTerminal("@2")
        if hasOlderRequest {
            tabs.remoteTerminalLayoutInFlight = .init(
                baseline: shared,
                request: .init(sessionName: "work", leftWindowId: "@1", rightWindowIds: ["@2"], selectedRightWindowId: "@2")
            )
        }
        tabs.clearMatchingRemoteTerminalEdits(shared)
        #expect(tabs.remoteTerminalPlacements["@3"] == (hasOlderRequest ? true : nil))
        #expect(tabs.explicitRemoteRightTerminalID == nil)

        let incoming = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@3", revision: 2)
        tabs.applySharedTerminalLayout(incoming, liveWindowIds: ids)
        #expect(tabs.selectedRight == .window("@3"))
    }

    @Test("An incoming layout also discards an unsent cancellation during debounce")
    func hostSelectionArrivesBeforeCancelledRequestDebounces() {
        let tabs = SessionFileTabsState()
        let ids = Set(["@1", "@2", "@3"])
        tabs.applySharedTerminalLayout(.init(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2", revision: 1
        ), liveWindowIds: ids)
        tabs.selectRemoteRightTerminal("@3")
        tabs.selectRemoteRightTerminal("@2")

        tabs.applySharedTerminalLayout(.init(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@3", revision: 2
        ), liveWindowIds: ids)
        #expect(tabs.explicitRemoteRightTerminalID == nil)
        #expect(tabs.selectedRight == .window("@3"))
    }

    @Test("An older selection reply preserves width until the Host confirms it")
    func remoteSelectionReplyPreservesLaterWidth() {
        let tabs = SessionFileTabsState()
        let ids = Set(["@1", "@2", "@3"])
        let shared = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2", revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: ids)
        tabs.selectRemoteRightTerminal("@3")
        tabs.splitRatio = 0.66
        tabs.recordRemoteSplitRatio(0.66)
        let confirmedSelection = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@3", revision: 2
        )
        tabs.applySharedTerminalLayout(confirmedSelection, liveWindowIds: ids)
        #expect(tabs.splitRatio == 0.66)
        let visible = ["@1", "@2", "@3"]
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: visible, visibleWindowIDs: visible, selectedLeftWindowID: "@1", shared: confirmedSelection
        )
        #expect(request?.splitRatio == 0.66)

        tabs.applySharedTerminalLayout(.init(
            leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@3", splitRatio: 0.66, revision: 3
        ), liveWindowIds: ids)
        #expect(tabs.pendingRemoteSplitRatio == nil)
        #expect(tabs.splitRatio == 0.66)
    }

    @Test("A width reply preserves a later terminal move and selection until confirmed")
    func remoteResizeReplyPreservesLaterMove() {
        let tabs = SessionFileTabsState()
        let ids = Set(["@1", "@2", "@3"])
        tabs.applySharedTerminalLayout(
            .init(leftWindowId: "@1", rightWindowIds: ["@3"], selectedRightWindowId: "@3", splitRatio: 0.70, revision: 1), liveWindowIds: ids
        )
        tabs.recordRemoteTerminalPlacement("@2", onRight: true)
        tabs.applySharedTerminalLayout(
            .init(leftWindowId: "@1", rightWindowIds: ["@3"], selectedRightWindowId: "@3", splitRatio: 0.56, revision: 2), liveWindowIds: ids
        )
        #expect(tabs.remoteTerminalPlacements == ["@2": true])
        #expect(tabs.rightSideWindowIds == ["@2", "@3"])
        #expect(tabs.selectedRight == .window("@2"))

        tabs.applySharedTerminalLayout(
            .init(leftWindowId: "@1", rightWindowIds: ["@3", "@2"], selectedRightWindowId: "@2", splitRatio: 0.56, revision: 3), liveWindowIds: ids
        )
        #expect(tabs.remoteTerminalPlacements.isEmpty)
        #expect(tabs.explicitRemoteRightTerminalID == nil)
        #expect(tabs.selectedRight == .window("@2"))
    }

    @Test("An older move reply cannot clear a subsequent reversal")
    func remoteMoveReplyPreservesReversal() {
        let tabs = SessionFileTabsState()
        let ids = Set(["@1", "@2", "@3"])
        let shared = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@3"], selectedRightWindowId: "@3", revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: ids)
        tabs.recordRemoteTerminalPlacement("@2", onRight: true)
        tabs.remoteTerminalLayoutInFlight = .init(
            baseline: shared,
            request: .init(sessionName: "work", leftWindowId: "@1", rightWindowIds: ["@3", "@2"], selectedRightWindowId: "@2")
        )
        tabs.recordRemoteTerminalPlacement("@2", onRight: false)
        tabs.applySharedTerminalLayout(
            .init(leftWindowId: "@1", rightWindowIds: ["@3", "@2"], selectedRightWindowId: "@2", revision: 2), liveWindowIds: ids
        )
        #expect(tabs.remoteTerminalPlacements == ["@2": false])
        #expect(tabs.rightSideWindowIds == ["@3"])
    }

    @Test("The shared left tab returns unless the Viewer explicitly picked a different terminal", arguments: [false, true])
    func returningRemoteLeftRespectsExplicitSelection(selectsFallback: Bool) {
        let tabs = SessionFileTabsState()
        let visible = ["@1", "@2", "@3"]
        let shared = SharedTerminalLayout(leftWindowId: "@3", rightWindowIds: ["@2"], selectedRightWindowId: "@2", revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(visible))
        #expect(tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: ["@1", "@2"]) == nil)
        if selectsFallback {
            tabs.recordRemoteLeftTerminalSelection("@1")
        }

        let restored = tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: Set(visible))
        #expect(restored == (selectsFallback ? nil : "@3"))
        let request = tabs.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: visible, visibleWindowIDs: visible, selectedLeftWindowID: restored ?? "@1", shared: shared
        )
        #expect(request?.leftWindowId == (selectsFallback ? "@1" : "@3"))
    }

    @Test("Returning remote windows reapply shared placement and preserve explicit moves", arguments: [false, true])
    func remoteVisibilityReprojectsSharedSplit(movesLeft: Bool) {
        let tabs = SessionFileTabsState()
        let visible = ["@1", "@2", "@3"]
        let shared = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@3", splitRatio: 0.70, revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(visible))
        tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: ["@1", "@2"])
        #expect(tabs.rightSideWindowIds == ["@2"])
        if movesLeft {
            tabs.rightSide.remove(.window("@2"))
            tabs.recordRemoteTerminalPlacement("@2", onRight: false)
        }

        tabs.projectSharedTerminalVisibility(shared, liveWindowIDs: Set(visible))
        let expected = movesLeft ? ["@3"] : ["@2", "@3"]
        #expect(tabs.rightSideWindowIds == Set(expected))
        #expect(tabs.selectedRight == .window("@3"))
        tabs.splitRatio = 0.57
        let request = tabs.remoteTerminalLayoutRequest(sessionName: "work", sessionWindowIDs: ["@1", "@2", "@3"], visibleWindowIDs: visible, selectedLeftWindowID: "@1", shared: shared)
        #expect(request?.rightWindowIds == expected)
        #expect(request?.splitRatio == 0.57)
    }

    @Test("A Viewer can move a terminal left even if the shared left terminal is detached")
    func remoteExplicitLeftMoveSurvivesProjection() {
        let tabs = SessionFileTabsState()
        let visible = ["@2", "@3"]
        let shared = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: visible, selectedRightWindowId: "@2", revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(visible))
        #expect(tabs.reconcileRemoteRightPaneSelection(sessionWindowIDs: visible))
        let collapsed = tabs.remoteTerminalLayoutRequest(sessionName: "work", sessionWindowIDs: ["@1", "@2", "@3"], visibleWindowIDs: visible, selectedLeftWindowID: "@2", shared: shared)
        #expect(collapsed?.rightWindowIds == visible)

        let browser = BrowserTab(url: URL(fileURLWithPath: "/tmp/page"))
        tabs.openBrowserTabs = [browser]
        tabs.selectedBrowserTabId = browser.id
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(visible))
        tabs.rightSide.remove(.window("@2"))
        tabs.recordRemoteTerminalPlacement("@2", onRight: false)
        let moved = tabs.remoteTerminalLayoutRequest(sessionName: "work", sessionWindowIDs: ["@1", "@2", "@3"], visibleWindowIDs: visible, selectedLeftWindowID: "@2", shared: shared)
        #expect(moved?.leftWindowId == "@1")
        #expect(moved?.rightWindowIds == ["@3"])
    }

    @Test("An explicit Viewer selection overrides the detached shared right selection")
    func remoteExplicitSelectionOverridesDetachedTerminal() {
        let tabs = SessionFileTabsState()
        let visible = ["@1", "@2"]
        let shared = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@3", revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(visible))
        #expect(tabs.selectedRight == .window("@2"))
        let projected = tabs.remoteTerminalLayoutRequest(sessionName: "work", sessionWindowIDs: ["@1", "@2", "@3"], visibleWindowIDs: visible, selectedLeftWindowID: "@1", shared: shared)
        #expect(projected?.selectedRightWindowId == "@3")

        tabs.selectRemoteRightTerminal("@2")
        let selected = tabs.remoteTerminalLayoutRequest(sessionName: "work", sessionWindowIDs: ["@1", "@2", "@3"], visibleWindowIDs: visible, selectedLeftWindowID: "@1", shared: shared)
        #expect(selected?.selectedRightWindowId == "@2")
        #expect(selected?.rightWindowIds == ["@2", "@3"])
    }

    @Test("The sole terminal can remain on the right of a private file through shared refreshes")
    func keepsLocalOnlySplit() {
        let tabs = SessionFileTabsState()
        let file = UUID()
        tabs.openFileTabs = [.init(id: file, path: "/tmp/file.md", directoryPath: "/tmp")]
        tabs.selectedFileTabId = file
        tabs.locallySplitTerminalID = "@1"

        tabs.applySharedTerminalLayout(.init(leftWindowId: "@1", revision: 1), liveWindowIds: ["@1"])
        tabs.selectedRight = .window("@1")
        tabs.reconcileRightPaneSelection(sessionWindowIDs: ["@1"], includeLocalTabs: true)
        #expect(tabs.rightSideWindowIds == ["@1"])
        #expect(tabs.selectedFileTabId == file)

        tabs.openFileTabs.removeAll()
        tabs.reconcileRightPaneSelection(sessionWindowIDs: ["@1"], includeLocalTabs: true)
        #expect(tabs.rightSide.isEmpty)
        #expect(tabs.locallySplitTerminalID == nil)
    }

    @Test("The first shared layout supplies the placeholder for an all-right restored split", arguments: ["@1", "@2"])
    func restoresAllTerminalsOnRight(placeholder: String) {
        let tabs = SessionFileTabsState()
        let file = OpenFileTab(path: "/tmp/file.md", directoryPath: "/tmp")
        tabs.openFileTabs = [file]
        tabs.selectedFileTabId = file.id
        tabs.rightSide = [.window("@1"), .window("@2")]
        tabs.selectedRight = .window(placeholder)
        let windowIDs = ["@1", "@2"]
        tabs.restoreLocalOnlySplit(windowIDs: windowIDs)

        tabs.applySharedTerminalLayout(
            .init(leftWindowId: placeholder, rightWindowIds: windowIDs.filter { $0 != placeholder }, revision: 1),
            liveWindowIds: Set(windowIDs)
        )
        #expect(tabs.locallySplitTerminalID == placeholder)
        #expect(tabs.rightSideWindowIds == Set(windowIDs))
        #expect(tabs.selectedRight == .window(placeholder))
    }

    @Test("A split follows a transferred session and preserves a newer file selection")
    func deferredSplitPreservesLaterSelectionAfterTransfer() throws {
        let main = WorkbenchTabStore()
        let destination = WorkbenchTabStore()
        let tabs = main.tabs(hostID: nil, session: "work")
        main.userDidSelectTab(hostID: nil, session: "work")
        tabs.pendingTerminalSplits.append(.init(windowID: "@2", onRight: true, selectionRevision: tabs.tabSelectionRevision(onRight: true)))

        let file = TabDragPayload.file(UUID())
        main.userDidSelectTab(hostID: nil, session: "work")
        tabs.rightSide.insert(file)
        tabs.selectedRight = file
        main.moveSession(hostID: nil, session: "work", to: destination)

        let moved = try #require(destination.existing(hostID: nil, session: "work"))
        let placement = try #require(moved.pendingTerminalSplits.first)
        let left = moved.placeTerminal(
            placement.windowID, onRight: placement.onRight,
            select: moved.isLatestTerminalPlacement(placement),
            currentLeftWindowID: "@1", sessionWindowIDs: ["@1", "@2"], activeWindowID: "@1"
        )
        #expect(left == "@1")
        #expect(moved.rightSide == [file, .window("@2")])
        #expect(moved.selectedRight == file)
    }

    @Test("Selecting a left tab preserves a pending right selection")
    func selectionsAreIndependentBySide() {
        let store = WorkbenchTabStore()
        let tabs = store.tabs(hostID: nil, session: "work")
        store.userDidSelectTab(hostID: nil, session: "work", onRight: true)
        let right = SessionFileTabsState.TerminalPlacement(
            windowID: "@4", onRight: true, selectionRevision: tabs.tabSelectionRevision(onRight: true)
        )
        store.userDidSelectTab(hostID: nil, session: "work", onRight: false)

        #expect(tabs.isLatestTerminalPlacement(right))
        store.userDidSelectTab(hostID: nil, session: "work", onRight: true)
        #expect(!tabs.isLatestTerminalPlacement(right))
    }

    @Test("A terminal selected before restoration follows its restored side unless that side has a newer selection", arguments: [false, true])
    func deferredSelectionFollowsRestoredSide(selectRightLater: Bool) {
        let tabs = SessionFileTabsState()
        tabs.recordTabSelection(onRight: false)
        let earlySelection = SessionFileTabsState.TerminalPlacement(
            windowID: "@4", onRight: false, selectionRevision: tabs.tabSelectionRevision(onRight: false), deferred: true
        )
        tabs.recordTabSelection(onRight: selectRightLater)

        let resolved = tabs.latestTerminalSelections([earlySelection], rightWindowIDs: ["@3", "@4"])
        #expect(resolved[false] == nil)
        #expect(resolved[true]?.windowID == (selectRightLater ? nil : "@4"))
    }

    @Test("When queued selections land in the same pane, the newer click wins")
    func newestSelectionWinsAfterRestoredPlacement() {
        let tabs = SessionFileTabsState()
        tabs.recordTabSelection(onRight: true)
        let first = SessionFileTabsState.TerminalPlacement(
            windowID: "@3", onRight: true, selectionRevision: tabs.tabSelectionRevision(onRight: true), deferred: true
        )
        tabs.recordTabSelection(onRight: false)
        let second = SessionFileTabsState.TerminalPlacement(
            windowID: "@4", onRight: false, selectionRevision: tabs.tabSelectionRevision(onRight: false), deferred: true
        )

        let resolved = tabs.latestTerminalSelections([second, first], rightWindowIDs: ["@3", "@4"])
        #expect(resolved[true]?.windowID == "@4")
    }

    @Test("Moving the last left terminal publishes the collapsed layout unless a local resource holds the left pane", arguments: [false, true])
    func movingLastLeftTerminal(keepLocalSplit: Bool) {
        let layout = SetSharedTerminalLayout(
            sessionName: "work", leftWindowId: "@1", rightWindowIds: ["@2"], selectedRightWindowId: "@2", splitRatio: 0.7
        )
        let request = WorkspaceTerminalSelection.splitRequest(
            layout, windowID: "@1", onRight: true, select: true,
            windowIDs: ["@1", "@2"], activeWindowID: "@1", keepLocalSplit: keepLocalSplit
        )
        #expect(request.leftWindowId == "@1")
        #expect(request.rightWindowIds == (keepLocalSplit ? ["@2"] : []))
        #expect(request.selectedRightWindowId == (keepLocalSplit ? "@2" : nil))
        #expect(request.splitRatio == 0.7)
    }

    @Test("A Viewer layout update keeps the local-only right terminal and applies the new divider ratio")
    func updatesSharedLayoutWhenLeftShowsOnlyFiles() {
        let tabs = SessionFileTabsState()
        let file = OpenFileTab(path: "/tmp/file.md", directoryPath: "/tmp")
        tabs.openFileTabs = [file]
        tabs.selectedFileTabId = file.id
        tabs.locallySplitTerminalID = "@1"
        tabs.selectedRight = .window("@1")
        tabs.applySharedTerminalLayout(.init(leftWindowId: "@1", rightWindowIds: ["@2"], revision: 1), liveWindowIds: ["@1", "@2"])
        #expect(tabs.selectedRight == .window("@1"))
        tabs.applySharedTerminalLayout(.init(leftWindowId: "@2", splitRatio: 0.3, revision: 2), liveWindowIds: ["@1", "@2"])

        #expect(tabs.rightSideWindowIds == ["@1"])
        #expect(tabs.splitRatio == 0.3)
        #expect(tabs.selectedFileTabId == file.id)
    }

    @Test("Placing a terminal preserves the session-wide split and selects the destination", arguments: ["@1", "@2"])
    func placesTerminalOnLatestHostLayout(windowID: String) {
        let latest = SetSharedTerminalLayout(
            sessionName: "work", leftWindowId: "@4", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@3", splitRatio: 0.35
        )

        let split = WorkspaceTerminalSelection.splitRequest(
            latest, windowID: windowID, onRight: true, select: true,
            windowIDs: ["@1", "@2", "@3", "@4"], activeWindowID: "@1"
        )

        #expect(split.leftWindowId == "@4")
        #expect(Set(split.rightWindowIds) == Set(["@2", "@3", windowID]))
        #expect(split.selectedRightWindowId == windowID)
        #expect(split.splitRatio == 0.35)
    }

    @Test("A terminal move keeps a local divider edit when the Host layout has not changed")
    func keepsLocalDividerEdit() {
        let tabs = SessionFileTabsState()
        let windowIDs = ["@1", "@2", "@3"]
        let layout = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@3"], selectedRightWindowId: "@3", splitRatio: 0.5, revision: 1
        )
        tabs.applySharedTerminalLayout(layout, liveWindowIds: Set(windowIDs))
        tabs.splitRatio = 0.65

        let left = tabs.placeTerminal(
            "@2", onRight: true,
            currentLeftWindowID: "@1", sessionWindowIDs: windowIDs, activeWindowID: "@1"
        )

        #expect(left == "@1")
        #expect(tabs.rightSideWindowIds == ["@2", "@3"])
        #expect(tabs.splitRatio == 0.65)
    }

    @Test("Closing the selected window chooses the first eligible tab even if tmux changes active window", arguments: [false, true])
    func closedSelection(followsActive: Bool) {
        #expect(WorkspaceTerminalSelection.leftWindowID(
            current: "@closed", orderedIDs: ["@8", "@4", "@2"], activeID: "@2", rightSide: [],
            followsActive: followsActive, owns: { _ in true }
        ) == "@8")
        #expect(WorkspaceTerminalSelection.leftWindowID(
            current: "@closed", orderedIDs: ["@8", "@4", "@2"], activeID: "@2", rightSide: ["@8"],
            followsActive: followsActive, owns: { _ in true }
        ) == "@4")
    }

    @Test("Right-pane close follows visible tab order and preserves background selections")
    func rightCloseOrder() {
        let tabs = SessionFileTabsState()
        tabs.rightSide = [.window("@3"), .window("@2")]
        tabs.tabOrder = [.window("@1"), .window("@3"), .window("@2")]
        tabs.selectedRight = .window("@closed")
        tabs.reconcileRightPaneSelection(sessionWindowIDs: ["@1", "@2", "@3"], includeLocalTabs: true)
        #expect(tabs.selectedRight == .window("@3"))
        tabs.selectedRight = .window("@2")
        tabs.reconcileRightPaneSelection(sessionWindowIDs: ["@1", "@2", "@3"], includeLocalTabs: true)
        #expect(tabs.selectedRight == .window("@2"))
    }

    @Test("Mixed right tabs prefer the first remaining terminal on Host and Viewer", arguments: [false, true])
    func mixedRightCloseOrder(local: Bool) {
        let tabs = SessionFileTabsState()
        let file = OpenFileTab(path: "/tmp", directoryPath: "/tmp", isDirectory: true)
        tabs.openFileTabs = [file]
        let files: TabDragPayload = local ? .fileExplorer : .file(file.id)
        tabs.rightSide = [files, .window("@3"), .window("@2")]
        tabs.tabOrder = [files, .window("@1"), .window("@3"), .window("@2")]
        tabs.selectedRight = .window("@closed")
        func reconcile(_ windows: [String]) {
            if local {
                tabs.reconcileRightPaneSelection(sessionWindowIDs: windows, includeLocalTabs: true)
            } else {
                tabs.reconcileRemoteRightPaneSelection(sessionWindowIDs: windows)
            }
        }
        reconcile(["@1", "@2", "@3"])
        #expect(tabs.selectedRight == .window("@3"))
        // A background close must not take focus away from Files.
        tabs.selectedRight = files
        reconcile(["@1", "@2", "@3"])
        #expect(tabs.selectedRight == files)
        tabs.selectedRight = .window("@3")
        tabs.rightSide = [files]
        reconcile(["@1"])
        #expect(tabs.selectedRight == files)
        #expect(tabs.isSplit)
    }

    @Test(arguments: [nil, "remote-host"] as [String?])
    func draggingLeftTerminalAwaySkipsRightTerminal(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let a = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        _ = try #require(manager.detach(a, position: nil, session: { _ in "work" }))
        let selected = WorkspaceTerminalSelection.leftWindowID(
            current: "@1", orderedIDs: ["@1", "@2", "@3"], activeID: "@2", rightSide: ["@2"],
            owns: { manager.owner(hostID: host, windowID: $0) == nil }
        )
        #expect(selected == "@3")
    }

    @Test(arguments: [nil, "remote-host"] as [String?])
    func splitFallbackNeverSelectsMainWindow(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let a = try #require(DetachedTerminalTarget(hostID: host, windowID: "@2"))
        let b = try #require(DetachedTerminalTarget(hostID: host, windowID: "@3"))
        let group = try #require(manager.detach(a, position: nil, session: { _ in "work" }))
        #expect(manager.merge(b, into: group.id, session: { _ in "work" }))
        let selected = WorkspaceTerminalSelection.leftWindowID(
            current: "@2", orderedIDs: ["@1", "@2", "@3"], activeID: "@1", rightSide: ["@2"],
            owns: { manager.owner(hostID: host, windowID: $0) == group.id }
        )
        #expect(selected == "@3")
        let noLeft = WorkspaceTerminalSelection.leftWindowID(
            current: "@1", orderedIDs: ["@1", "@2", "@3"], activeID: "@1", rightSide: ["@2", "@3"],
            owns: { manager.owner(hostID: host, windowID: $0) == group.id }
        )
        #expect(noLeft == nil)
    }

    @Test(arguments: [nil, "remote-host"] as [String?])
    func terminalExitPreservesFilesAndAllowsNewTerminal(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let old = try #require(DetachedTerminalTarget(hostID: host, windowID: "@2"))
        let new = try #require(DetachedTerminalTarget(hostID: host, windowID: "@3"))
        let group = try #require(manager.detach(old, position: nil, session: { _ in "work" }))
        let tabs = group.tabs.tabs(hostID: host, session: "work")
        let directory = FileBrowserTab(path: "/tmp")
        tabs.openFileTabs = [.init(id: directory.id, path: "/tmp", directoryPath: "/tmp", isDirectory: true)]
        tabs.directoryTabs[directory.id] = directory
        let surviving = WorkspaceTerminalSelection.leftWindowID(
            current: old.windowID, orderedIDs: ["@1"], activeID: "@1", rightSide: [],
            owns: { manager.owner(hostID: host, windowID: $0) == group.id }
        )
        #expect(surviving == nil)
        tabs.repairLeftContent(hasTerminal: surviving != nil)
        #expect(tabs.selectedFileTabId == directory.id)
        // The old terminal no longer resolves; a terminal in the main window keeps the session alive.
        let session: (DetachedTerminalTarget) -> String? = { $0 == old ? nil : "work" }
        #expect(group.resolvedSession(using: session) == "work")
        #expect(manager.merge(new, into: group.id, session: session))
        #expect(manager.owner(hostID: host, windowID: new.windowID) == group.id)
        #expect(tabs.directoryTabs[directory.id] === directory)
    }

    @Test
    func filesOnlyWorkspaceStillAcceptsSameSessionDrops() throws {
        let manager = DetachedTerminalWindows()
        let old = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@2"))
        let group = try #require(manager.detach(old, position: nil, session: { _ in "work" }))
        let session: (DetachedTerminalTarget) -> String? = { $0.windowID == "@1" ? "work" : nil }
        let drag = WorkbenchTabDrag(workspaceID: nil, hostID: nil, sessionName: "work", tab: .window("@1"))
        #expect(manager.transfer(drag, to: group.id, session: session))
        #expect(manager.owner(hostID: nil, windowID: "@1") == group.id)
        let foreign = WorkbenchTabDrag(workspaceID: nil, hostID: "other", sessionName: "work", tab: .window("@1"))
        #expect(!manager.transfer(foreign, to: group.id, session: { _ in "work" }))
    }

    @Test
    func privateFallbackUsesLeftTabOrderAndPreservesValidSelection() throws {
        let tabs = SessionFileTabsState()
        let file = OpenFileTab(path: "/tmp", directoryPath: "/tmp", isDirectory: true)
        let browser = try BrowserTab(url: #require(URL(string: "about:blank")))
        tabs.openFileTabs = [file]
        tabs.openBrowserTabs = [browser]
        tabs.tabOrder = [.browser(browser.id), .file(file.id)]
        tabs.rightSide = [.browser(browser.id)]
        tabs.repairLeftContent(hasTerminal: false)
        #expect(tabs.selectedFileTabId == file.id)
        tabs.rightSide = []
        tabs.repairLeftContent(hasTerminal: false)
        #expect(tabs.selectedFileTabId == file.id)
        tabs.openFileTabs = []
        tabs.repairLeftContent(hasTerminal: false)
        #expect(tabs.selectedFileTabId == nil)
        #expect(tabs.selectedBrowserTabId == browser.id)
    }

    @Test
    func remainingPrivateRightTabCollapsesWithoutAnyTerminal() {
        let tabs = SessionFileTabsState()
        let file = OpenFileTab(path: "/tmp", directoryPath: "/tmp", isDirectory: true)
        tabs.openFileTabs = [file]
        tabs.rightSide = [.file(file.id)]
        tabs.selectedRight = .file(file.id)
        #expect(tabs.reconcileRemoteRightPaneSelection(sessionWindowIDs: []))
        tabs.repairLeftContent(hasTerminal: false)
        #expect(!tabs.isSplit)
        #expect(tabs.selectedFileTabId == file.id)
    }

    @Test
    func followActiveNeverEscapesOwnershipOrRightSide() {
        for active in ["@1", "@2"] {
            #expect(WorkspaceTerminalSelection.leftWindowID(
                current: "@3", orderedIDs: ["@1", "@2", "@3"], activeID: active,
                rightSide: ["@2"], followsActive: true, owns: { $0 != "@1" }
            ) == "@3")
        }
    }
}
