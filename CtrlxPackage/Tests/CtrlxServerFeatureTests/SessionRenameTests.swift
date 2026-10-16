import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@Suite("Tmux session rename")
struct SessionRenameTests {
    private func pane(_ paneID: String, session: String, window: Int, index: Int = 0, identity: WorkspacePaneIdentity? = nil) -> PaneInfo {
        PaneInfo(
            paneId: paneID,
            target: "\(session):\(window).\(index)",
            sessionName: session,
            windowIndex: window,
            paneIndex: index,
            command: "zsh",
            currentPath: "/tmp",
            width: 80,
            height: 24,
            isActive: index == 0,
            workspaceIdentity: identity
        )
    }

    @Test("User-entered names are trimmed without changing valid content")
    func trimsName() throws {
        #expect(try TmuxService.validatedSessionName("  feature work  ") == "feature work")
    }

    @Test("Empty, control-character, colon, and period names are rejected")
    func rejectsInvalidNames() {
        for name in ["", "   ", "bad:name", "bad.name", "bad\nname"] {
            #expect(throws: TmuxError.self) {
                try TmuxService.validatedSessionName(name)
            }
        }
    }

    @Test("A live tmux session is renamed without replacing its pane")
    @MainActor
    func renamesLiveSession() async throws {
        let tmuxPath = "/opt/homebrew/bin/tmux"
        try #require(FileManager.default.isExecutableFile(atPath: tmuxPath))

        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
        } operation: {
            let suffix = UUID().uuidString.lowercased()
            let oldName = "ctrlx-rename-old-\(suffix)"
            let newName = "ctrlx-rename-new-\(suffix)"
            let socketPath = "/tmp/gr-\(suffix.prefix(8)).sock"
            let service = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
            defer { try? FileManager.default.removeItem(atPath: socketPath) }

            let created = try await service.createSession(baseName: oldName, width: 80, height: 24)
            do {
                try await service.setSessionDescription("keep me", for: created.sessionName)
                try await service.renameSession(from: created.sessionName, to: newName)
                let panes = await service.refreshPanes()
                let oldExists = await service.sessionExists(named: oldName)
                let newExists = await service.sessionExists(named: newName)
                #expect(panes.map(\.paneId).contains(created.paneId))
                #expect(panes.allSatisfy { $0.sessionName == newName })
                #expect(panes.allSatisfy { $0.customDescription == "keep me" })
                #expect(!oldExists)
                #expect(newExists)
                try await service.killSession(newName)
            } catch {
                try? await service.killSession(oldName)
                try? await service.killSession(newName)
                throw error
            }
        }
    }

    @Test("Renaming to an existing session fails without changing either session")
    @MainActor
    func rejectsLiveNameCollision() async throws {
        let tmuxPath = "/opt/homebrew/bin/tmux"
        try #require(FileManager.default.isExecutableFile(atPath: tmuxPath))

        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
        } operation: {
            let suffix = UUID().uuidString.lowercased()
            let sourceName = "ctrlx-source-\(suffix)"
            let existingName = "ctrlx-existing-\(suffix)"
            let socketPath = "/tmp/gc-\(suffix.prefix(8)).sock"
            let service = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
            defer { try? FileManager.default.removeItem(atPath: socketPath) }

            _ = try await service.createSession(baseName: sourceName, width: 80, height: 24)
            _ = try await service.createSession(baseName: existingName, width: 80, height: 24)
            do {
                try await service.renameSession(from: sourceName, to: existingName)
                Issue.record("Expected the duplicate session name to be rejected")
            } catch {
                #expect(error.localizedDescription.contains("already exists"))
            }

            let sourceExists = await service.sessionExists(named: sourceName)
            let existingExists = await service.sessionExists(named: existingName)
            #expect(sourceExists)
            #expect(existingExists)
            try? await service.killSession(sourceName)
            try? await service.killSession(existingName)
        }
    }

    @Test("A full pane-set rename is detected with every window ID mapping")
    func detectsRename() throws {
        let old = [
            pane("%1", session: "old", window: 0),
            pane("%2", session: "old", window: 0, index: 1),
            pane("%3", session: "old", window: 1),
        ]
        let new = [
            pane("%1", session: "new", window: 0),
            pane("%2", session: "new", window: 0, index: 1),
            pane("%3", session: "new", window: 1),
        ]

        let detected = SessionRenameMapping.detect(from: old, to: new)
        #expect(detected.count == 1)
        let rename = try #require(detected.first)
        #expect(rename.oldName == "old")
        #expect(rename.newName == "new")
        #expect(rename.windowIDs == ["old:0": "new:0", "old:1": "new:1"])
    }

    @Test("Recycled pane numbers cannot migrate a replacement session's private state")
    func ignoresReconstructedSession() {
        let identity = WorkspacePaneIdentity(serverID: "1:2", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let old = [pane("%1", session: "old", window: 0, identity: identity)]
        #expect(SessionRenameMapping.detect(from: old, to: [pane("%1", session: "new", window: 0, identity: identity)]).count == 1)
        var restarted = identity
        restarted.serverID = "3:4"
        var replaced = identity
        replaced.sessionID = UUID()
        for current in [restarted, replaced, nil] {
            #expect(SessionRenameMapping.detect(from: old, to: [pane("%1", session: "new", window: 0, identity: current)]).isEmpty)
        }
    }

    @Test("Moving only part of a session is not treated as a rename")
    func ignoresWindowMove() {
        let old = [
            pane("%1", session: "old", window: 0),
            pane("%2", session: "old", window: 1),
        ]
        let new = [
            pane("%1", session: "old", window: 0),
            pane("%2", session: "other", window: 1),
        ]

        #expect(SessionRenameMapping.detect(from: old, to: new).isEmpty)
    }

    @Test("An unchanged linked session with the same pane IDs is not the rename target")
    func ignoresLinkedSessionAlias() throws {
        let old = [
            pane("%1", session: "old", window: 0),
            pane("%1", session: "linked", window: 4),
        ]
        let new = [
            pane("%1", session: "new", window: 0),
            pane("%1", session: "linked", window: 4),
        ]

        let detected = SessionRenameMapping.detect(from: old, to: new)
        #expect(detected.count == 1)
        let rename = try #require(detected.first)
        #expect(rename.oldName == "old")
        #expect(rename.newName == "new")
        #expect(rename.windowIDs == ["old:0": "new:0"])
    }

    @Test("Ambiguous linked-session replacements are not guessed")
    func ignoresAmbiguousLinkedSessionReplacements() {
        let old = [
            pane("%1", session: "old-a", window: 0),
            pane("%1", session: "old-b", window: 4),
        ]
        let new = [
            pane("%1", session: "new", window: 0),
        ]

        #expect(SessionRenameMapping.detect(from: old, to: new).isEmpty)
    }

    @Test("Session tab state rewrites all embedded window IDs")
    @MainActor
    func remapsTabState() throws {
        let tabs = SessionFileTabsState()
        let fileID = UUID()
        let browserID = UUID()
        let url = try #require(URL(string: "https://example.com"))
        tabs.openFileTabs = [OpenFileTab(
            id: fileID,
            path: "/tmp/a.swift",
            directoryPath: "/tmp",
            origin: .gitTab(windowId: "old:0")
        )]
        tabs.openBrowserTabs = [BrowserTab(
            id: browserID,
            url: url,
            originWindowId: "old:1"
        )]
        tabs.rightSide = [.window("old:0")]
        tabs.selectedRight = .window("old:0")
        tabs.tabOrder = [.window("old:0"), .file(fileID), .window("old:1"), .browser(browserID)]

        tabs.remapWindowIDs(["old:0": "new:0", "old:1": "new:1"])

        #expect(tabs.openFileTabs.first?.origin == .gitTab(windowId: "new:0"))
        #expect(tabs.openBrowserTabs.first?.originWindowId == "new:1")
        #expect(tabs.rightSide == [.window("new:0")])
        #expect(tabs.selectedRight == .window("new:0"))
        #expect(tabs.tabOrder == [.window("new:0"), .file(fileID), .window("new:1"), .browser(browserID)])
    }

    @Test("Pending markdown suggestion follows the renamed session")
    @MainActor
    func remapsMarkdownSuggestion() {
        let store = MarkdownOpenSuggestionStore()
        store.suggest(MarkdownOpenSuggestion(
            filePath: "/tmp/plan.md",
            directoryPath: "/tmp",
            sessionName: "old",
            isPlan: true
        ))

        store.sessionRenamed(from: "old", to: "new")

        #expect(store.suggestionsBySession["old"] == nil)
        #expect(store.suggestionsBySession["new"]?.sessionName == "new")
        #expect(store.suggestionsBySession["new"]?.filePath == "/tmp/plan.md")
    }
}
